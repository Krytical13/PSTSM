@{
    RootModule        = 'PSTaskBuilder.psm1'
    ModuleVersion     = '0.3.0'
    GUID              = 'c9e4a7f2-58b1-4d36-9a0e-7b2c15d8e034'
    Author            = 'PSTaskBuilder contributors'
    CompanyName       = ''
    Copyright         = ''
    Description       = 'Engine for building, validating, registering and editing Windows scheduled tasks that run PowerShell scripts. Derives engine, parameters, elevation and working directory from the script itself, generates the correct launch arguments, and preflights the plan for the failures that only show up unattended.'
    PowerShellVersion = '5.1'

    # Intentionally empty. Only the register/inventory commands need the ScheduledTasks module,
    # and it is present on every supported Windows build. Keeping this empty lets the pure
    # derivation and argument-building logic import (and unit-test) anywhere.
    RequiredModules   = @()

    FunctionsToExport = @(
        # Script analysis - the "select the script and the form fills itself in" half
        'Get-PSTaskEngine'
        'Get-PSTaskScriptProfile'

        # Plan construction and validation
        'New-PSTaskPlan'
        'New-PSTaskTriggerSpec'
        'Test-PSTaskPlan'
        'ConvertTo-PSTaskArgument'
        'ConvertTo-PSTaskQuotedValue'
        'Export-PSTaskPlan'
        'Import-PSTaskPlan'

        # Task Scheduler round trip - the browse-and-edit half
        'Get-PSTaskInventory'
        'Register-PSTaskPlan'
        'New-PSTaskLogWrapper'
        'ConvertTo-PSTaskCimTrigger'
        'ConvertFrom-PSTaskAction'
        'ConvertFrom-PSTaskDefinition'
        'ConvertFrom-PSTaskCimTrigger'
        'ConvertFrom-PSTaskDuration'
        'ConvertFrom-PSTaskResultCode'
        'ConvertFrom-PSTaskTriggerSummary'

        # Accounts: pick an existing one, or bridge the scattered steps of creating a gMSA
        'Get-PSTaskRunAsAccount'
        'Test-PSTaskGmsaPrerequisite'
        'New-PSTaskGmsa'
        'Install-PSTaskGmsa'
        'Grant-PSTaskBatchLogonRight'

        # WinForms front end
        'Show-PSTaskBuilder'
        'Show-PSTaskEditor'
        'Show-PSTaskTriggerDialog'
        'Show-PSTaskGmsaDialog'
        'Show-PSTaskAccountPicker'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData       = @{
        PSData = @{
            Tags         = @('ScheduledTask', 'TaskScheduler', 'Automation', 'PowerShell', 'WinForms')

            # Must stay a single constant expression. String concatenation with '+' here makes
            # the manifest a "dynamic expression" that Import-PowerShellDataFile refuses to read.
            ReleaseNotes = @'
0.3.0 - Tasks can run as a gMSA (LogonType Password with no password, which the plan models
separately so the password rules do not apply). Adds a side utility that creates a gMSA and
prepares the local machine, since that is six steps across the directory and the host. Clarifies
what S4U actually breaks - connectivity works, authentication does not - and detects DPAPI use,
which S4U also cannot do.

0.2.0 - Adds the WinForms front end: task list with live filtering, the create/edit window
with a parameter form generated from the script's own param() block, a live command preview,
inline preflight, and round-trip editing of existing tasks. Start-PSTaskBuilder.ps1 handles
the STA relaunch pwsh needs.

0.1.0 - Engine only. AST-derived script profile (engine, parameters, elevation, help,
interactivity/network signals), verified argument quoting, plan model with reliability
defaults, preflight checks, transcript wrapper, register/inventory, and full round-trip
editing of existing tasks.
'@
        }
    }
}
