# SPDX-License-Identifier: GPL-3.0-or-later
@{
    RootModule        = 'PSTSM.psm1'
    ModuleVersion     = '0.4.0'
    GUID              = 'c9e4a7f2-58b1-4d36-9a0e-7b2c15d8e034'
    Author            = 'Krytical13'
    CompanyName       = ''
    # Deliberately NOT "All rights reserved" - that phrase asserts you are granting nothing,
    # which contradicts the licence. Under the GPL you retain copyright and grant specific,
    # stated rights.
    Copyright         = 'Copyright (c) 2026 Krytical13. Licensed under the GNU General Public License v3.0 or later.'
    Description       = 'Engine for building, validating, registering and editing Windows scheduled tasks that run PowerShell scripts. Derives engine, parameters, elevation and working directory from the script itself, generates the correct launch arguments, and preflights the plan for the failures that only show up unattended.'
    PowerShellVersion = '5.1'

    # Intentionally empty. Only the register/inventory commands need the ScheduledTasks module,
    # and it is present on every supported Windows build. Keeping this empty lets the pure
    # derivation and argument-building logic import (and unit-test) anywhere.
    RequiredModules   = @()

    FunctionsToExport = @(
        # Script analysis - the "select the script and the form fills itself in" half
        'Get-PSTSMEngine'
        'Get-PSTSMScriptProfile'
        'Resolve-PSTSMDefaultValue'
        'Get-PSTSMScriptConfigFile'

        # Plan construction and validation
        'New-PSTSMPlan'
        'New-PSTSMTriggerSpec'
        'Test-PSTSMPlan'
        'ConvertTo-PSTSMArgument'
        'ConvertTo-PSTSMQuotedValue'
        'Export-PSTSMPlan'
        'Import-PSTSMPlan'

        # Task Scheduler round trip - the browse-and-edit half
        'Get-PSTSMInventory'
        'Get-PSTSMTaskOrigin'
        'Test-PSTSMHealth'
        'Get-PSTSMTaskRunLog'
        'Register-PSTSMPlan'
        'Invoke-PSTSMElevatedRegistration'
        'Test-PSTSMPlanNeedsElevation'
        'Test-PSTSMElevated'
        'New-PSTSMLogWrapper'
        'ConvertTo-PSTSMCimTrigger'
        'ConvertFrom-PSTSMAction'
        'ConvertFrom-PSTSMDefinition'
        'ConvertFrom-PSTSMCimTrigger'
        'ConvertFrom-PSTSMDuration'
        'ConvertFrom-PSTSMResultCode'
        'ConvertFrom-PSTSMTriggerSummary'

        # Accounts: pick an existing one, or bridge the scattered steps of creating a gMSA
        'Get-PSTSMRunAsAccount'
        'Test-PSTSMGmsaPrerequisite'
        'New-PSTSMGmsa'
        'Install-PSTSMGmsa'
        'Grant-PSTSMBatchLogonRight'

        # WinForms front end
        'Show-PSTSM'
        'Show-PSTSMEditor'
        'Show-PSTSMTriggerDialog'
        'Show-PSTSMGmsaDialog'
        'Show-PSTSMAccountPicker'
        'Show-PSTSMHealth'
        'Show-PSTSMRunLog'
        'Initialize-PSTSMUIHost'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData       = @{
        PSData = @{
            Tags         = @('ScheduledTask', 'TaskScheduler', 'Automation', 'PowerShell', 'WinForms', 'gMSA')

            # Required by the PowerShell Gallery, and what GitHub reads for the licence badge.
            # Update ProjectUri if the public repository ends up under a different name.
            LicenseUri   = 'https://www.gnu.org/licenses/gpl-3.0.html'
            ProjectUri   = 'https://github.com/Krytical13/PSTSM'

            # Must stay a single constant expression. String concatenation with '+' here makes
            # the manifest a "dynamic expression" that Import-PowerShellDataFile refuses to read.
            ReleaseNotes = @'
0.4.0 - Elevation moved to where the privilege is actually needed. The tool opens unelevated;
saving a task that needs administrator rights elevates for that one registration behind a single
consent prompt, keeping whatever is in the editor. Windows cannot raise a running process's
privileges, so this uses Microsoft's Administrator Broker Model - a short-lived elevated helper.
The boundary was measured rather than read: with a UAC-filtered token RunLevel=Highest, service
accounts, group principals and at-startup triggers are refused, and everything else registers.
Adds a health sweep, per-task run logs, and an Origin column separating Windows, app, and
person-created tasks.

0.3.0 - Tasks can run as a gMSA (LogonType Password with no password, which the plan models
separately so the password rules do not apply). Adds a side utility that creates a gMSA and
prepares the local machine, since that is six steps across the directory and the host. Clarifies
what S4U actually breaks - connectivity works, authentication does not - and detects DPAPI use,
which S4U also cannot do.

0.2.0 - Adds the WinForms front end: task list with live filtering, the create/edit window
with a parameter form generated from the script's own param() block, a live command preview,
inline preflight, and round-trip editing of existing tasks. Start-PSTSM.ps1 handles
the STA relaunch pwsh needs.

0.1.0 - Engine only. AST-derived script profile (engine, parameters, elevation, help,
interactivity/network signals), verified argument quoting, plan model with reliability
defaults, preflight checks, transcript wrapper, register/inventory, and full round-trip
editing of existing tasks.
'@
        }
    }
}
