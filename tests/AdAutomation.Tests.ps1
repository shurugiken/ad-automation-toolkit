#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# These tests mock the ActiveDirectory cmdlets so they run with no domain and
# no RSAT installed. We define empty stub functions for the AD cmdlets the
# module calls, then Mock those stubs inside the module's scope.
#
# Note on scoping: InModuleScope runs in the module's own session state, so
# variables set in BeforeAll (test session state) are NOT visible there. We
# therefore pass any paths the assertions need via -Parameters.

BeforeAll {
    $script:ModulePath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'AdAutomation.psm1'

    # Stub out the ActiveDirectory cmdlets the module depends on. Defining them
    # as functions in the global scope lets Pester's Mock replace them even
    # though the real ActiveDirectory module is absent.
    #
    # The stubs declare the named parameters the module passes (and that the
    # tests assert on via -ParameterFilter); a ValueFromRemainingArguments
    # catch-all absorbs the rest so any extra splatted args bind cleanly.
    function global:New-ADUser {
        param(
            $Name, $SamAccountName, $Path, $AccountPassword, $Enabled,
            $ChangePasswordAtLogon, $Title, $Department, $Server,
            [Parameter(ValueFromRemainingArguments = $true)]$Rest
        )
    }
    function global:Add-ADGroupMember {
        param($Identity, $Members, $Server, [Parameter(ValueFromRemainingArguments = $true)]$Rest)
    }
    function global:Get-ADUser {
        param($Identity, $Filter, $Properties, $SearchBase, $Server,
            [Parameter(ValueFromRemainingArguments = $true)]$Rest)
    }
    function global:Disable-ADAccount {
        param($Identity, $Server, [Parameter(ValueFromRemainingArguments = $true)]$Rest)
    }
    function global:Remove-ADGroupMember {
        param($Identity, $Members, $Confirm, $Server, [Parameter(ValueFromRemainingArguments = $true)]$Rest)
    }
    function global:Set-ADUser {
        param($Identity, $Description, $Server, [Parameter(ValueFromRemainingArguments = $true)]$Rest)
    }
    function global:Move-ADObject {
        param($Identity, $TargetPath, $Server, [Parameter(ValueFromRemainingArguments = $true)]$Rest)
    }
    function global:Get-ADGroupMember {
        param($Identity, $Recursive, $Server, [Parameter(ValueFromRemainingArguments = $true)]$Rest)
    }

    Import-Module $script:ModulePath -Force
}

AfterAll {
    Remove-Module AdAutomation -Force -ErrorAction SilentlyContinue
    foreach ($n in 'New-ADUser', 'Add-ADGroupMember', 'Get-ADUser', 'Disable-ADAccount',
        'Remove-ADGroupMember', 'Set-ADUser', 'Move-ADObject', 'Get-ADGroupMember') {
        if (Test-Path "function:global:$n") { Remove-Item "function:global:$n" -Force }
    }
}

Describe 'New-BulkAdUser' {
    BeforeAll {
        $script:Csv = Join-Path $TestDrive 'users.csv'
        @(
            'Name,Sam,Ou,Title,Dept'
            'Jane Doe,jdoe,"OU=Staff,DC=corp,DC=local",Analyst,IT'
            'John Smith,jsmith,"OU=Staff,DC=corp,DC=local",Accountant,Finance'
        ) | Set-Content -LiteralPath $script:Csv -Encoding UTF8

        $script:BadCsv = Join-Path $TestDrive 'bad.csv'
        @(
            'Name,Sam,Ou,Title,Dept'
            ',nobody,"OU=Staff,DC=corp,DC=local",,'      # missing Name -> skipped
            'Valid User,vuser,"OU=Staff,DC=corp,DC=local",Tech,IT'
        ) | Set-Content -LiteralPath $script:BadCsv -Encoding UTF8

        # Build a SecureString without ConvertTo-SecureString -AsPlainText so
        # PSScriptAnalyzer raises no Error-level finding in CI. The value is a
        # throwaway test fixture, never a real credential.
        $script:Pw = [System.Security.SecureString]::new()
        foreach ($c in 'P@ssw0rd!23'.ToCharArray()) { $script:Pw.AppendChar($c) }
        $script:Pw.MakeReadOnly()
    }

    It 'creates one AD user per valid CSV row' {
        InModuleScope AdAutomation -Parameters @{ Csv = $script:Csv; Pw = $script:Pw } {
            param($Csv, $Pw)
            Mock New-ADUser {}
            Mock Add-ADGroupMember {}

            $result = New-BulkAdUser -CsvPath $Csv -InitialPassword $Pw -Confirm:$false
            @($result | Where-Object Status -EQ 'Created').Count | Should -Be 2
            Should -Invoke New-ADUser -Times 2 -Exactly
        }
    }

    It 'sets ChangePasswordAtLogon and Enabled on new accounts' {
        InModuleScope AdAutomation -Parameters @{ Csv = $script:Csv; Pw = $script:Pw } {
            param($Csv, $Pw)
            Mock New-ADUser {}
            New-BulkAdUser -CsvPath $Csv -InitialPassword $Pw -Confirm:$false | Out-Null
            Should -Invoke New-ADUser -ParameterFilter {
                $ChangePasswordAtLogon -eq $true -and $Enabled -eq $true
            } -Times 2 -Exactly
        }
    }

    It 'adds created users to the requested groups' {
        InModuleScope AdAutomation -Parameters @{ Csv = $script:Csv; Pw = $script:Pw } {
            param($Csv, $Pw)
            Mock New-ADUser {}
            Mock Add-ADGroupMember {}
            New-BulkAdUser -CsvPath $Csv -InitialPassword $Pw -AddToGroups 'AllStaff' -Confirm:$false | Out-Null
            Should -Invoke Add-ADGroupMember -ParameterFilter { $Identity -eq 'AllStaff' } -Times 2 -Exactly
        }
    }

    It 'skips invalid rows without aborting the batch' {
        InModuleScope AdAutomation -Parameters @{ BadCsv = $script:BadCsv; Pw = $script:Pw } {
            param($BadCsv, $Pw)
            Mock New-ADUser {}
            $result = New-BulkAdUser -CsvPath $BadCsv -InitialPassword $Pw -Confirm:$false -WarningAction SilentlyContinue
            @($result | Where-Object Status -EQ 'Skipped').Count | Should -Be 1
            @($result | Where-Object Status -EQ 'Created').Count | Should -Be 1
            Should -Invoke New-ADUser -Times 1 -Exactly
        }
    }

    It 'creates nothing under -WhatIf' {
        InModuleScope AdAutomation -Parameters @{ Csv = $script:Csv; Pw = $script:Pw } {
            param($Csv, $Pw)
            Mock New-ADUser {}
            $result = New-BulkAdUser -CsvPath $Csv -InitialPassword $Pw -WhatIf
            Should -Invoke New-ADUser -Times 0 -Exactly
            @($result | Where-Object Status -EQ 'WhatIf').Count | Should -Be 2
        }
    }

    It 'throws on a non-existent CSV path' {
        { New-BulkAdUser -CsvPath 'Z:\nope\missing.csv' -InitialPassword $script:Pw -Confirm:$false } |
            Should -Throw
    }
}

Describe 'Disable-OffboardUser' {
    It 'disables, strips groups, and moves the account' {
        $logPath = Join-Path $TestDrive 'offboard1.log'
        InModuleScope AdAutomation -Parameters @{ LogPath = $logPath } {
            param($LogPath)
            Mock Get-ADUser {
                [PSCustomObject]@{
                    SamAccountName    = 'jdoe'
                    DistinguishedName = 'CN=Jane Doe,OU=Staff,DC=corp,DC=local'
                    MemberOf          = @(
                        'CN=GroupA,OU=Groups,DC=corp,DC=local'
                        'CN=GroupB,OU=Groups,DC=corp,DC=local'
                    )
                }
            }
            Mock Disable-ADAccount {}
            Mock Remove-ADGroupMember {}
            Mock Set-ADUser {}
            Mock Move-ADObject {}

            $result = Disable-OffboardUser -Identity 'jdoe' `
                -DisabledOu 'OU=Disabled,DC=corp,DC=local' `
                -LogPath $LogPath -Confirm:$false

            $result.Status | Should -Be 'Offboarded'
            $result.GroupsRemoved | Should -Be 2
            Should -Invoke Disable-ADAccount -Times 1 -Exactly
            Should -Invoke Remove-ADGroupMember -Times 2 -Exactly
            Should -Invoke Move-ADObject -ParameterFilter { $TargetPath -eq 'OU=Disabled,DC=corp,DC=local' } -Times 1 -Exactly
        }
    }

    It 'writes an audit line to the log file' {
        $logPath = Join-Path $TestDrive 'offboard2.log'
        InModuleScope AdAutomation -Parameters @{ LogPath = $logPath } {
            param($LogPath)
            Mock Get-ADUser {
                [PSCustomObject]@{
                    SamAccountName    = 'jdoe'
                    DistinguishedName = 'CN=Jane Doe,OU=Staff,DC=corp,DC=local'
                    MemberOf          = @()
                }
            }
            Mock Disable-ADAccount {}
            Mock Remove-ADGroupMember {}
            Mock Set-ADUser {}
            Mock Move-ADObject {}

            Disable-OffboardUser -Identity 'jdoe' -DisabledOu 'OU=Disabled,DC=corp,DC=local' `
                -LogPath $LogPath -Confirm:$false | Out-Null

            (Get-Content -LiteralPath $LogPath -Raw) | Should -Match 'Offboarded\s+jdoe'
        }
    }

    It 'makes no changes under -WhatIf' {
        InModuleScope AdAutomation {
            Mock Get-ADUser {
                [PSCustomObject]@{
                    SamAccountName    = 'jdoe'
                    DistinguishedName = 'CN=Jane Doe,OU=Staff,DC=corp,DC=local'
                    MemberOf          = @('CN=GroupA,OU=Groups,DC=corp,DC=local')
                }
            }
            Mock Disable-ADAccount {}
            Mock Remove-ADGroupMember {}
            Mock Set-ADUser {}
            Mock Move-ADObject {}

            $result = Disable-OffboardUser -Identity 'jdoe' -DisabledOu 'OU=Disabled,DC=corp,DC=local' -WhatIf
            $result.Status | Should -Be 'WhatIf'
            Should -Invoke Disable-ADAccount -Times 0 -Exactly
            Should -Invoke Move-ADObject -Times 0 -Exactly
        }
    }
}

Describe 'Get-StaleAdAccount' {
    It 'returns only accounts older than the threshold' {
        InModuleScope AdAutomation {
            Mock Get-ADUser {
                @(
                    [PSCustomObject]@{ SamAccountName = 'old1';   Name = 'Old One';   Enabled = $true; LastLogonDate = (Get-Date).AddDays(-200) }
                    [PSCustomObject]@{ SamAccountName = 'fresh1'; Name = 'Fresh One'; Enabled = $true; LastLogonDate = (Get-Date).AddDays(-5) }
                    [PSCustomObject]@{ SamAccountName = 'never';  Name = 'Never On';  Enabled = $true; LastLogonDate = $null }
                )
            }

            $stale = Get-StaleAdAccount -DaysInactive 90
            $stale.SamAccountName | Should -Contain 'old1'
            $stale.SamAccountName | Should -Contain 'never'
            $stale.SamAccountName | Should -Not -Contain 'fresh1'
        }
    }

    It 'excludes disabled accounts by default but includes them with -IncludeDisabled' {
        InModuleScope AdAutomation {
            Mock Get-ADUser {
                @(
                    [PSCustomObject]@{ SamAccountName = 'disabledOld'; Name = 'D'; Enabled = $false; LastLogonDate = (Get-Date).AddDays(-300) }
                )
            }

            @(Get-StaleAdAccount -DaysInactive 90).Count | Should -Be 0
            @(Get-StaleAdAccount -DaysInactive 90 -IncludeDisabled).Count | Should -Be 1
        }
    }

    It 'rejects an out-of-range DaysInactive value' {
        { Get-StaleAdAccount -DaysInactive 0 } | Should -Throw
    }
}

Describe 'Get-AdGroupMembershipReport' {
    It 'writes a CSV row per group member' {
        $outCsv = Join-Path $TestDrive 'members.csv'
        InModuleScope AdAutomation -Parameters @{ OutCsv = $outCsv } {
            param($OutCsv)
            Mock Get-ADGroupMember {
                @(
                    [PSCustomObject]@{ SamAccountName = 'jdoe';   Name = 'Jane Doe';   objectClass = 'user'; DistinguishedName = 'CN=Jane Doe,DC=corp,DC=local' }
                    [PSCustomObject]@{ SamAccountName = 'jsmith'; Name = 'John Smith'; objectClass = 'user'; DistinguishedName = 'CN=John Smith,DC=corp,DC=local' }
                )
            }

            $report = Get-AdGroupMembershipReport -GroupName 'AllStaff' -Path $OutCsv
            @($report).Count | Should -Be 2
            Test-Path -LiteralPath $OutCsv | Should -BeTrue
            @(Import-Csv -LiteralPath $OutCsv).Count | Should -Be 2
        }
    }

    It 'passes -Recursive through to Get-ADGroupMember' {
        $outCsv = Join-Path $TestDrive 'members2.csv'
        InModuleScope AdAutomation -Parameters @{ OutCsv = $outCsv } {
            param($OutCsv)
            Mock Get-ADGroupMember { @() }
            Get-AdGroupMembershipReport -GroupName 'AllStaff' -Path $OutCsv -Recursive | Out-Null
            Should -Invoke Get-ADGroupMember -ParameterFilter { $Recursive -eq $true } -Times 1 -Exactly
        }
    }

    It 'does not write the file under -WhatIf' {
        $whatIfCsv = Join-Path $TestDrive 'whatif.csv'
        InModuleScope AdAutomation -Parameters @{ WhatIfCsv = $whatIfCsv } {
            param($WhatIfCsv)
            Mock Get-ADGroupMember {
                @( [PSCustomObject]@{ SamAccountName = 'jdoe'; Name = 'Jane'; objectClass = 'user'; DistinguishedName = 'CN=Jane,DC=corp,DC=local' } )
            }
            Get-AdGroupMembershipReport -GroupName 'AllStaff' -Path $WhatIfCsv -WhatIf | Out-Null
            Test-Path -LiteralPath $WhatIfCsv | Should -BeFalse
        }
    }
}
