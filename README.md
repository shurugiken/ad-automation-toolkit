# ad-automation-toolkit

A small PowerShell module that wraps the Microsoft `ActiveDirectory` cmdlets for the routine account-lifecycle jobs an IT support tech or sysadmin runs every week: bulk user creation, offboarding leavers, finding stale accounts, and reporting group membership.

Every function supports `-WhatIf`, validates its inputs, and ships with comment-based help. Because the functions call the AD cmdlets directly, the behavior is fully unit-tested by **mocking** those cmdlets — the test suite runs with no domain, no RSAT, and on Linux in CI.

## Why this exists

These four tasks are the bread and butter of AD administration, and they are exactly the operations where a fat-fingered one-liner does real damage (disabling the wrong account, deleting group members, creating users in the wrong OU). This toolkit puts each one behind:

- **`SupportsShouldProcess`** so you can dry-run with `-WhatIf` before committing,
- **parameter validation** so bad input fails fast instead of halfway through a batch,
- **per-row error handling** so one bad CSV line doesn't abort the whole job,
- **an audit log** for the destructive offboarding path.

It's a clean reference implementation, not a replacement for your change-control process.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- The **`ActiveDirectory`** module (part of RSAT) at runtime, plus rights to perform the operations
- For development/CI: [Pester](https://pester.dev/) 5.x and [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer)

## Install

Clone the repo and import the module:

```powershell
git clone https://github.com/YOUR_USERNAME/ad-automation-toolkit.git
Import-Module .\ad-automation-toolkit\AdAutomation.psm1
```

On a machine that will actually touch AD, make sure RSAT is present:

```powershell
Import-Module ActiveDirectory
```

## Functions

| Function | What it does |
| --- | --- |
| `New-BulkAdUser` | Create users from a CSV (`Name,Sam,Ou,Title,Dept`), set an initial password, optionally add to groups |
| `Disable-OffboardUser` | Disable an account, strip group memberships, move it to a Disabled OU, and log the action |
| `Get-StaleAdAccount` | List accounts whose `LastLogonDate` is older than N days (or that never logged on) |
| `Get-AdGroupMembershipReport` | Export a group's members to CSV (optionally recursive) |

Run `Get-Help <FunctionName> -Full` for the complete help on any of them.

## Usage

### Bulk-create users

The CSV needs a header row with `Name,Sam,Ou,Title,Dept` (see [`users.example.csv`](users.example.csv)):

```csv
Name,Sam,Ou,Title,Dept
Jane Doe,jdoe,"OU=Staff,DC=corp,DC=local",Support Analyst,IT
```

Always dry-run first:

```powershell
$pw = Read-Host -AsSecureString 'Initial password'
New-BulkAdUser -CsvPath .\users.csv -InitialPassword $pw -WhatIf
```

Then run it for real, optionally adding everyone to a group:

```powershell
New-BulkAdUser -CsvPath .\users.csv -InitialPassword $pw -AddToGroups 'AllStaff'
```

New accounts are created enabled with **change-password-at-next-logon** set. The function returns one object per row with a `Status` of `Created`, `Skipped`, `WhatIf`, or `Error`.

### Offboard a leaver

```powershell
# Preview every step
Disable-OffboardUser -Identity jdoe -DisabledOu 'OU=Disabled,DC=corp,DC=local' -WhatIf

# Do it
Disable-OffboardUser -Identity jdoe -DisabledOu 'OU=Disabled,DC=corp,DC=local' -LogPath .\offboard.log
```

This disables the account, removes it from its group memberships, stamps the description with the offboard date, moves it to the Disabled OU, and appends an audit line to the log.

### Find stale accounts

```powershell
# Enabled accounts inactive for 90+ days
Get-StaleAdAccount -DaysInactive 90

# Scope to an OU and export
Get-StaleAdAccount -DaysInactive 180 -SearchBase 'OU=Staff,DC=corp,DC=local' |
    Export-Csv stale.csv -NoTypeInformation
```

Disabled accounts are excluded unless you pass `-IncludeDisabled`. This function is read-only.

### Report group membership

```powershell
Get-AdGroupMembershipReport -GroupName 'Domain Admins' -Path .\admins.csv
Get-AdGroupMembershipReport -GroupName 'AllStaff' -Path .\staff.csv -Recursive
```

## How it works

Each function builds a hashtable of arguments and splats it into the corresponding AD cmdlet (`New-ADUser`, `Get-ADUser`, `Disable-ADAccount`, `Move-ADObject`, `Get-ADGroupMember`, etc.). Optional inputs like `-Server` and `-SearchBase` are only added to the splat when supplied, so defaults behave the same as the underlying cmdlets.

Because the AD cmdlets are called by name, the tests in [`tests/AdAutomation.Tests.ps1`](tests/AdAutomation.Tests.ps1) define lightweight stub functions for them and use Pester's `Mock`/`Should -Invoke` to assert the right calls happen with the right parameters — no domain required. That's also what runs in CI on `ubuntu-latest`.

## Running the tests

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser
Invoke-Pester ./tests -Output Detailed
```

Lint with the same rule CI enforces (fail only on `Error` severity):

```powershell
Invoke-ScriptAnalyzer -Path ./AdAutomation.psm1, ./tests/AdAutomation.Tests.ps1
```

## Limitations

- Wraps a **subset** of common operations; it is not a full AD management suite.
- `Get-StaleAdAccount` relies on `LastLogonDate` (replicated `lastLogonTimestamp`), which can lag real activity by up to ~14 days by design — fine for cleanup, not for precise auditing.
- Group removal in `Disable-OffboardUser` iterates the account's `MemberOf`; the user's *primary* group is not in `MemberOf` and is left untouched (this is the expected AD behavior).
- No rollback. Use `-WhatIf` and a backup/restore plan for destructive runs.
- Designed and tested against the Microsoft `ActiveDirectory` module on Windows; behavior on third-party AD shims is out of scope.

## License

MIT — see [LICENSE](LICENSE).
