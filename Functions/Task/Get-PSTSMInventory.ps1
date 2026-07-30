# SPDX-License-Identifier: GPL-3.0-or-later
function Get-PSTSMInventory {
    <#
    .SYNOPSIS
        Lists registered scheduled tasks with the PowerShell-specific detail the built-in
        Task Scheduler console does not show.
    .DESCRIPTION
        Backs the task list view. For every task it joins the definition (action, principal,
        triggers) with runtime state (last run, next run, result) and, for PowerShell tasks,
        reverse-parses the action so the grid can show the actual script path and engine
        instead of a wall of identical 'powershell.exe' rows.

        LastTaskResult is decoded, because 0x41303 meaning "has never run" and 0x0 meaning
        "the script may well have failed silently" are the two codes people misread most.
    .PARAMETER TaskPath
        Task Scheduler folder to list, e.g. '\Custom\'. Default: every folder.
    .PARAMETER TaskName
        Filter by task name. Wildcards accepted.
    .PARAMETER PowerShellOnly
        Return only tasks whose action runs powershell.exe or pwsh.exe. This is the default
        view in the UI; the toggle shows everything.
    .PARAMETER IncludeMicrosoft
        Include the built-in \Microsoft\ tree, which is several hundred OS tasks and is
        excluded by default.
    .OUTPUTS
        [pscustomobject]
    .EXAMPLE
        Get-PSTSMInventory -PowerShellOnly | Format-Table TaskName, State, LastRunTime, LastResultText, ScriptName
    #>
    [CmdletBinding()]
    param(
        [string]$TaskPath,
        [string]$TaskName = '*',
        [switch]$PowerShellOnly,
        [switch]$IncludeMicrosoft
    )

    $getParams = @{ ErrorAction = 'SilentlyContinue' }
    if ($TaskPath) { $getParams['TaskPath'] = $TaskPath }

    $tasks = @(Get-ScheduledTask @getParams | Where-Object { $_.TaskName -like $TaskName })

    if (-not $IncludeMicrosoft) {
        $tasks = @($tasks | Where-Object { $_.TaskPath -notlike '\Microsoft\*' })
    }

    foreach ($task in $tasks) {
        $action = @($task.Actions)[0]

        $parsed = $null
        if ($action -and $action.PSObject.Properties['Execute']) {
            $parsed = ConvertFrom-PSTSMAction -Execute $action.Execute `
                -Arguments $action.Arguments `
                -WorkingDirectory $action.WorkingDirectory
        }

        if ($PowerShellOnly -and -not ($parsed -and $parsed.IsPowerShell)) { continue }

        $info = $null
        try { $info = Get-ScheduledTaskInfo -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop }
        catch { Write-Verbose "No runtime info for $($task.TaskPath)$($task.TaskName): $($_.Exception.Message)" }

        $principal = $task.Principal

        $managedByTool = [bool]($parsed -and $parsed.ScriptPath -and $parsed.ScriptPath -match '\\\.pstsm\\.+\.wrapper\.ps1$')
        $origin = Get-PSTSMTaskOrigin -Task $task -IsManagedByTool $managedByTool

        [PSCustomObject]@{
            PSTypeName       = 'PSTSM.TaskSummary'

            TaskName         = $task.TaskName
            TaskPath         = $task.TaskPath
            FullName         = "$($task.TaskPath)$($task.TaskName)"
            State            = [string]$task.State
            Enabled          = ($task.Settings.Enabled)
            Description      = $task.Description
            Author           = $task.Author

            # Runtime
            LastRunTime      = if ($info) { $info.LastRunTime } else { $null }
            LastTaskResult   = if ($info) { $info.LastTaskResult } else { $null }
            LastResultText   = if ($info) { ConvertFrom-PSTSMResultCode -Code $info.LastTaskResult } else { $null }
            NextRunTime      = if ($info) { $info.NextRunTime } else { $null }
            # Named for the source property, not shortened. Test-PSTSMHealth reads
            # NumberOfMissedRuns, so the abbreviation here meant its MISSED_RUNS check compared
            # $null against 0 forever and could never fire - silently, on a machine that had
            # tasks with missed runs to report.
            NumberOfMissedRuns = if ($info) { $info.NumberOfMissedRuns } else { $null }

            # Principal
            UserId           = $principal.UserId
            LogonType        = [string]$principal.LogonType
            RunLevel         = [string]$principal.RunLevel

            # PowerShell detail
            IsPowerShell     = [bool]($parsed -and $parsed.IsPowerShell)
            IsRecognized     = [bool]($parsed -and $parsed.IsRecognized)
            EngineId         = if ($parsed) { $parsed.EngineId } else { $null }
            EnginePath       = if ($action) { $action.Execute } else { $null }
            Bitness          = if ($parsed) { $parsed.Bitness } else { $null }
            ScriptPath       = if ($parsed) { $parsed.ScriptPath } else { $null }
            ScriptName       = if ($parsed -and $parsed.ScriptPath) { Split-Path $parsed.ScriptPath -Leaf } else { $null }
            ScriptExists     = if ($parsed -and $parsed.ScriptPath) { Test-Path -LiteralPath $parsed.ScriptPath } else { $null }
            WorkingDirectory = if ($action) { $action.WorkingDirectory } else { $null }
            Arguments        = if ($action) { $action.Arguments } else { $null }

            # True when the action points at a wrapper this tool generated.
            IsManagedByTool  = $managedByTool

            # Who put this here: Windows / App / Person / PSTSM / Unknown. The question an admin
            # is actually asking of a 288-row list.
            Origin           = $origin.Origin
            OriginDetail     = $origin.Detail

            TriggerSummary   = (ConvertFrom-PSTSMTriggerSummary -Triggers $task.Triggers)
            TriggerCount     = @($task.Triggers).Count
            ActionCount      = @($task.Actions).Count

            Task             = $task
            ParsedAction     = $parsed
        }
    }
}

function ConvertFrom-PSTSMResultCode {
    <#
    .SYNOPSIS
        Turns a Task Scheduler Last Run Result code into something readable.
    .PARAMETER Code
        The integer result code.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Code)

    if ($null -eq $Code) { return $null }
    $c = [int64]$Code
    # Result codes are reported as signed ints; compare on the unsigned 32-bit value.
    #
    # Both halves of this need the L suffix, and neither had it. An 8-digit hex literal with the
    # high bit set is an Int32 in PowerShell, so 0xFFFFFFFF is -1 and the mask was a no-op that
    # left $c negative - then [uint32] on a negative number threw, which took out the caller.
    # The case labels below are the same literal form, so every one of them was a negative Int32
    # that a non-negative value could never equal: all eight HRESULT decodes were unreachable,
    # including the batch-logon-right one the preflight names to the operator.
    $u = $c -band 0xFFFFFFFFL

    switch ($u) {
        0x0 { return 'Success (0x0) - note: also what an unhandled failure reports if the script sets no exit code' }
        0x1 { return 'Incorrect function / generic failure (0x1)' }
        0x2 { return 'File not found (0x2) - engine, script, or working directory is wrong' }
        0xA { return 'Environment incorrect (0xA)' }
        0x41300 { return 'Task is ready (0x41300)' }
        0x41301 { return 'Task is currently running (0x41301)' }
        0x41302 { return 'Task is disabled (0x41302)' }
        0x41303 { return 'Task has never run (0x41303)' }
        0x41304 { return 'No more runs scheduled (0x41304)' }
        0x41306 { return 'Task was terminated by the user (0x41306)' }
        0x41307 { return 'Task terminated - execution time limit exceeded (0x41307)' }
        0x41308 { return 'Task terminated - could not start (0x41308)' }
        0x8004131FL { return 'An instance is already running (0x8004131F)' }
        0x80041309L { return "Trigger does not have a set run time (0x80041309)" }
        0x8007010BL { return 'Directory name is invalid (0x8007010B) - check "Start in"' }
        0x80070002L { return 'File not found (0x80070002)' }
        0x80070005L { return 'Access denied (0x80070005)' }
        0x80070534L { return 'Account has no "Log on as a batch job" right (0x80070534)' }
        0x800704DDL { return 'Not logged on - S4U/Interactive task needs an interactive session (0x800704DD)' }
        0x800710E0L { return 'Operator/administrator refused the request (0x800710E0)' }
        default { return ('0x{0:X}' -f $u) }
    }
}

function ConvertFrom-PSTSMTriggerSummary {
    <#
    .SYNOPSIS
        Renders a task's triggers as one short human-readable line for the list view.
    .PARAMETER Triggers
        The task's trigger collection.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    param([AllowNull()][object[]]$Triggers)

    if (-not $Triggers -or $Triggers.Count -eq 0) { return 'Manual only' }

    $parts = foreach ($t in $Triggers) {
        $class = $t.CimClass.CimClassName
        $start = $null
        if ($t.StartBoundary) {
            try { $start = ([datetime]::Parse($t.StartBoundary)).ToString('HH:mm') }
            catch { Write-Verbose "Unparseable StartBoundary '$($t.StartBoundary)'" }
        }

        switch ($class) {
            'MSFT_TaskDailyTrigger' {
                $every = if ($t.DaysInterval -and $t.DaysInterval -gt 1) { "every $($t.DaysInterval)d" } else { 'daily' }
                "$every at $start"
            }
            'MSFT_TaskWeeklyTrigger' {
                # DaysOfWeek is a bit mask starting at Sunday = 1.
                $names = @('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat')
                $set = @()
                for ($i = 0; $i -lt 7; $i++) { if ($t.DaysOfWeek -band (1 -shl $i)) { $set += $names[$i] } }
                "weekly $($set -join ',') at $start"
            }
            'MSFT_TaskTimeTrigger' { "once at $start" }
            'MSFT_TaskBootTrigger' { 'at startup' }
            'MSFT_TaskLogonTrigger' { if ($t.UserId) { "at logon ($($t.UserId))" } else { 'at logon' } }
            'MSFT_TaskIdleTrigger' { 'on idle' }
            'MSFT_TaskEventTrigger' { 'on event' }
            'MSFT_TaskRegistrationTrigger' { 'at registration' }
            'MSFT_TaskSessionStateChangeTrigger' { 'on session change' }

            # The generic base class. The CIM provider reports it for trigger types it does not
            # model individually - custom COM and WNF-backed triggers, which most of the
            # built-in \Microsoft\ tasks use. Stripping the class name here yields an empty
            # string, so it needs its own case.
            'MSFT_TaskTrigger' { 'custom trigger' }

            default {
                $short = $class -replace '^MSFT_Task', '' -replace 'Trigger$', ''
                if ([string]::IsNullOrWhiteSpace($short)) { 'custom trigger' } else { $short.ToLowerInvariant() }
            }
        }
    }

    $line = (@($parts | Where-Object { $_ }) -join '; ')
    if ([string]::IsNullOrWhiteSpace($line)) { $line = 'custom trigger' }

    $repeating = @($Triggers | Where-Object { $_.Repetition -and $_.Repetition.Interval })
    if ($repeating.Count -gt 0) {
        # Task Scheduler stores ISO 8601 durations; 'P1D' is not readable as 'repeat P1D'.
        $iv = ConvertFrom-PSTSMDuration -Value $repeating[0].Repetition.Interval
        if ($iv) { $line += " (repeat $iv)" }
    }
    $line
}
