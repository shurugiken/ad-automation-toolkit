#Requires -Version 5.1

<#
.SYNOPSIS
    AdAutomation - PowerShell helpers for common Active Directory admin tasks.

.DESCRIPTION
    A small, defensive toolkit that wraps the Microsoft ActiveDirectory module
    cmdlets for the everyday jobs an IT support / sysadmin runs: bulk user
    creation, offboarding, stale-account discovery, and group membership
    reporting.

    Every function supports -WhatIf (via SupportsShouldProcess), validates its
    parameters, and carries comment-based help. The functions call the
    ActiveDirectory cmdlets directly so they can be mocked in tests and run
    without a live domain.

.NOTES
    Requires the Microsoft ActiveDirectory module (RSAT) at runtime.
    Import-Module ActiveDirectory
#>

Set-StrictMode -Version Latest

function New-BulkAdUser {
    <#
    .SYNOPSIS
        Creates Active Directory users in bulk from a CSV file.

    .DESCRIPTION
        Reads a CSV with the columns: Name, Sam, Ou, Title, Dept (header row
        required). For each row it creates an enabled AD user with the given
        sAMAccountName, sets an initial password, and forces a password change
        at next logon. Optional group memberships can be applied to every
        created user via -AddToGroups.

        Rows that fail validation (missing Name/Sam/Ou) are skipped with a
        warning so one bad row does not abort the whole batch.

    .PARAMETER CsvPath
        Path to the source CSV file. Must exist and have a .csv extension.

    .PARAMETER InitialPassword
        SecureString used as the initial password for every created account.
        Accounts are flagged to change the password at next logon.

    .PARAMETER AddToGroups
        Optional list of group identities (name, SID, or DN) that each created
        user is added to.

    .PARAMETER Server
        Optional domain controller / AD web service endpoint to target.

    .EXAMPLE
        $pw = Read-Host -AsSecureString 'Initial password'
        New-BulkAdUser -CsvPath .\users.csv -InitialPassword $pw -WhatIf

        Shows what would be created without making changes.

    .EXAMPLE
        $pw = ConvertTo-SecureString 'P@ssw0rd!23' -AsPlainText -Force
        New-BulkAdUser -CsvPath .\users.csv -InitialPassword $pw -AddToGroups 'AllStaff'

        Creates the users and adds each to the 'AllStaff' group.

    .OUTPUTS
        PSCustomObject per processed row with Sam, Status, and Message.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([System.Management.Automation.PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateScript({
            if (-not (Test-Path -LiteralPath $_ -PathType Leaf)) {
                throw "CSV file not found: $_"
            }
            if ([System.IO.Path]::GetExtension($_) -ne '.csv') {
                throw "Expected a .csv file but got: $_"
            }
            $true
        })]
        [string]$CsvPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [System.Security.SecureString]$InitialPassword,

        [Parameter()]
        [ValidateNotNull()]
        [string[]]$AddToGroups = @(),

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Server
    )

    begin {
        $serverParam = @{}
        if ($PSBoundParameters.ContainsKey('Server')) {
            $serverParam['Server'] = $Server
        }
    }

    process {
        $rows = Import-Csv -LiteralPath $CsvPath

        foreach ($row in $rows) {
            $sam = ($row.Sam | ForEach-Object { "$_".Trim() })

            if ([string]::IsNullOrWhiteSpace($row.Name) -or
                [string]::IsNullOrWhiteSpace($sam) -or
                [string]::IsNullOrWhiteSpace($row.Ou)) {
                Write-Warning "Skipping row with missing Name/Sam/Ou: '$($row.Name)'"
                [PSCustomObject]@{
                    Sam     = $sam
                    Status  = 'Skipped'
                    Message = 'Missing required field (Name, Sam, or Ou)'
                }
                continue
            }

            $target = "$($row.Name) ($sam)"
            if (-not $PSCmdlet.ShouldProcess($target, 'Create AD user')) {
                [PSCustomObject]@{
                    Sam     = $sam
                    Status  = 'WhatIf'
                    Message = 'Skipped due to -WhatIf'
                }
                continue
            }

            try {
                $newUser = @{
                    Name                  = $row.Name
                    SamAccountName        = $sam
                    Path                  = $row.Ou
                    AccountPassword       = $InitialPassword
                    Enabled               = $true
                    ChangePasswordAtLogon = $true
                }
                if (-not [string]::IsNullOrWhiteSpace($row.Title)) {
                    $newUser['Title'] = $row.Title
                }
                if (-not [string]::IsNullOrWhiteSpace($row.Dept)) {
                    $newUser['Department'] = $row.Dept
                }

                New-ADUser @newUser @serverParam -ErrorAction Stop

                foreach ($group in $AddToGroups) {
                    Add-ADGroupMember -Identity $group -Members $sam @serverParam -ErrorAction Stop
                }

                [PSCustomObject]@{
                    Sam     = $sam
                    Status  = 'Created'
                    Message = "Created in $($row.Ou)"
                }
            }
            catch {
                Write-Error "Failed to create '$sam': $($_.Exception.Message)"
                [PSCustomObject]@{
                    Sam     = $sam
                    Status  = 'Error'
                    Message = $_.Exception.Message
                }
            }
        }
    }
}

function Disable-OffboardUser {
    <#
    .SYNOPSIS
        Offboards an Active Directory user account.

    .DESCRIPTION
        Performs the standard leaver workflow for a single account:
          1. Disables the account.
          2. Removes the user from all non-primary group memberships.
          3. Moves the account into a Disabled OU.
          4. Appends a line to a log file recording the action.

        The account's description is stamped with the offboard date so the
        change is auditable in AD itself.

    .PARAMETER Identity
        sAMAccountName, DN, GUID, or SID of the user to offboard.

    .PARAMETER DisabledOu
        Distinguished name of the OU the account is moved to.

    .PARAMETER LogPath
        Optional path to an append-only log file. Defaults to
        'offboard.log' in the current directory.

    .PARAMETER Server
        Optional domain controller / AD web service endpoint to target.

    .EXAMPLE
        Disable-OffboardUser -Identity jdoe -DisabledOu 'OU=Disabled,DC=corp,DC=local' -WhatIf

        Shows the offboarding steps without changing anything.

    .EXAMPLE
        Disable-OffboardUser -Identity jdoe -DisabledOu 'OU=Disabled,DC=corp,DC=local'

        Disables jdoe, strips group memberships, and moves the account.

    .OUTPUTS
        PSCustomObject describing the result.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([System.Management.Automation.PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Identity,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$DisabledOu,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath = (Join-Path -Path (Get-Location).Path -ChildPath 'offboard.log'),

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Server
    )

    begin {
        $serverParam = @{}
        if ($PSBoundParameters.ContainsKey('Server')) {
            $serverParam['Server'] = $Server
        }
    }

    process {
        $user = Get-ADUser -Identity $Identity -Properties MemberOf @serverParam -ErrorAction Stop

        if (-not $PSCmdlet.ShouldProcess($user.SamAccountName, 'Offboard AD user')) {
            return [PSCustomObject]@{
                Sam     = $user.SamAccountName
                Status  = 'WhatIf'
                Message = 'Skipped due to -WhatIf'
            }
        }

        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

        Disable-ADAccount -Identity $user.DistinguishedName @serverParam -ErrorAction Stop

        $groups = @($user.MemberOf)
        foreach ($group in $groups) {
            Remove-ADGroupMember -Identity $group -Members $user.DistinguishedName -Confirm:$false @serverParam -ErrorAction Stop
        }

        Set-ADUser -Identity $user.DistinguishedName -Description "Offboarded $stamp" @serverParam -ErrorAction Stop

        Move-ADObject -Identity $user.DistinguishedName -TargetPath $DisabledOu @serverParam -ErrorAction Stop

        $logLine = "$stamp`tOffboarded`t$($user.SamAccountName)`tremoved $($groups.Count) group(s)`tmoved to $DisabledOu"
        Add-Content -LiteralPath $LogPath -Value $logLine

        [PSCustomObject]@{
            Sam            = $user.SamAccountName
            Status         = 'Offboarded'
            GroupsRemoved  = $groups.Count
            MovedTo        = $DisabledOu
            Message        = "Disabled and moved at $stamp"
        }
    }
}

function Get-StaleAdAccount {
    <#
    .SYNOPSIS
        Finds AD accounts that have not signed in for N days.

    .DESCRIPTION
        Returns enabled user accounts whose LastLogonDate is older than the
        given threshold (or that have never logged on). Useful for cleanup and
        license reclamation. Read-only; makes no changes.

    .PARAMETER DaysInactive
        Number of days of inactivity that marks an account stale. Must be
        1 - 3650.

    .PARAMETER SearchBase
        Optional OU distinguished name to scope the search.

    .PARAMETER IncludeDisabled
        Include disabled accounts in the results. By default only enabled
        accounts are returned.

    .PARAMETER Server
        Optional domain controller / AD web service endpoint to target.

    .EXAMPLE
        Get-StaleAdAccount -DaysInactive 90

        Lists enabled accounts inactive for 90+ days.

    .EXAMPLE
        Get-StaleAdAccount -DaysInactive 180 -SearchBase 'OU=Staff,DC=corp,DC=local' |
            Export-Csv stale.csv -NoTypeInformation

        Exports stale Staff accounts to CSV.

    .OUTPUTS
        PSCustomObject per stale account.
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateRange(1, 3650)]
        [int]$DaysInactive,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$SearchBase,

        [Parameter()]
        [switch]$IncludeDisabled,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Server
    )

    $cutoff = (Get-Date).AddDays(-$DaysInactive)

    $getParams = @{
        Filter     = '*'
        Properties = @('LastLogonDate', 'Enabled')
    }
    if ($PSBoundParameters.ContainsKey('SearchBase')) {
        $getParams['SearchBase'] = $SearchBase
    }
    if ($PSBoundParameters.ContainsKey('Server')) {
        $getParams['Server'] = $Server
    }

    Get-ADUser @getParams |
        Where-Object {
            ($IncludeDisabled -or $_.Enabled) -and
            ($null -eq $_.LastLogonDate -or $_.LastLogonDate -lt $cutoff)
        } |
        ForEach-Object {
            $daysSince = if ($null -eq $_.LastLogonDate) {
                $null
            }
            else {
                [int][math]::Floor(((Get-Date) - $_.LastLogonDate).TotalDays)
            }

            [PSCustomObject]@{
                SamAccountName = $_.SamAccountName
                Name           = $_.Name
                Enabled        = $_.Enabled
                LastLogonDate  = $_.LastLogonDate
                DaysInactive   = $daysSince
            }
        }
}

function Get-AdGroupMembershipReport {
    <#
    .SYNOPSIS
        Exports the members of an AD group to CSV.

    .DESCRIPTION
        Resolves the members of a group and writes a report with each
        member's sAMAccountName, name, object class, and enabled state. Use
        -Recursive to expand nested groups. Read-only apart from writing the
        report file.

    .PARAMETER GroupName
        Identity of the group to report on (name, SID, GUID, or DN).

    .PARAMETER Path
        Destination CSV path. Parent directory must already exist.

    .PARAMETER Recursive
        Expand nested group memberships.

    .PARAMETER Server
        Optional domain controller / AD web service endpoint to target.

    .EXAMPLE
        Get-AdGroupMembershipReport -GroupName 'Domain Admins' -Path .\admins.csv

        Writes a CSV of the direct members of Domain Admins.

    .EXAMPLE
        Get-AdGroupMembershipReport -GroupName 'AllStaff' -Path .\staff.csv -Recursive -WhatIf

        Shows what would be written without creating the file.

    .OUTPUTS
        PSCustomObject per member (also written to the CSV).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([System.Management.Automation.PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$GroupName,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateScript({
            $parent = Split-Path -Path $_ -Parent
            if ([string]::IsNullOrEmpty($parent)) { return $true }
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                throw "Destination directory does not exist: $parent"
            }
            $true
        })]
        [string]$Path,

        [Parameter()]
        [switch]$Recursive,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Server
    )

    $memberParams = @{ Identity = $GroupName }
    if ($Recursive) {
        $memberParams['Recursive'] = $true
    }
    if ($PSBoundParameters.ContainsKey('Server')) {
        $memberParams['Server'] = $Server
    }

    $members = Get-ADGroupMember @memberParams -ErrorAction Stop

    $report = foreach ($member in $members) {
        [PSCustomObject]@{
            SamAccountName = $member.SamAccountName
            Name          = $member.Name
            ObjectClass   = $member.objectClass
            DistinguishedName = $member.DistinguishedName
        }
    }

    if ($PSCmdlet.ShouldProcess($Path, "Write membership report for '$GroupName'")) {
        $report | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
    }

    $report
}

Export-ModuleMember -Function New-BulkAdUser, Disable-OffboardUser, Get-StaleAdAccount, Get-AdGroupMembershipReport
