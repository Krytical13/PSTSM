# SPDX-License-Identifier: GPL-3.0-or-later
function Test-PSTSMHealth {
    <#
    .SYNOPSIS
        Sweeps every scheduled task and reports the ones that are quietly broken.
    .DESCRIPTION
        Task Scheduler will happily show "Ready" for a task whose script was deleted months ago,
        whose account can no longer reach the network, or that has never once run. Nothing
        surfaces that until somebody notices the thing it was supposed to do never happened.

        This answers "what is rotting?" by combining two sources:

          The plan preflight - the same Test-PSTSMPlan used when building a task, re-run against
          what is actually registered. That catches a missing script, a module that has since
          been uninstalled, a settings file that has gone, S4U against a script that needs the
          network, and the rest.

          Runtime state - what Task Scheduler itself recorded. A non-zero last result, a task
          that has never run despite having triggers, missed runs, an enabled task with triggers
          but no next run time.

        Only the first is available for tasks PSTSM cannot model, so a non-PowerShell task still
        gets its runtime checked. Nothing here changes anything; it is read-only.
    .PARAMETER TaskPath
        Restrict to one Task Scheduler folder.
    .PARAMETER PowerShellOnly
        Only tasks whose action runs powershell.exe or pwsh.exe. Default: on, since that is what
        this tool understands deeply.
    .PARAMETER IncludeMicrosoft
        Include the built-in \Microsoft\ tree. Off by default - those are Windows' problem, and
        several hundred of them would drown the result.
    .OUTPUTS
        [pscustomobject] TaskName, TaskPath, FullName, Origin, Severity, Id, Title, Detail,
        Recommendation - one row per finding.
    .EXAMPLE
        Test-PSTSMHealth | Format-Table FullName, Severity, Title
    .EXAMPLE
        Test-PSTSMHealth -PowerShellOnly:$false | Where-Object Severity -eq 'Error'
    #>
    [CmdletBinding()]
    param(
        [string]$TaskPath,
        [bool]$PowerShellOnly = $true,
        [switch]$IncludeMicrosoft
    )

    $invParams = @{ ErrorAction = 'SilentlyContinue' }
    if ($TaskPath) { $invParams['TaskPath'] = $TaskPath }
    if ($PowerShellOnly) { $invParams['PowerShellOnly'] = $true }
    if ($IncludeMicrosoft) { $invParams['IncludeMicrosoft'] = $true }

    $rows = @(Get-PSTSMInventory @invParams)
    Write-Verbose "Checking $($rows.Count) task(s)."

    foreach ($row in $rows) {
        $findings = New-Object System.Collections.Generic.List[object]

        function Add-Finding($id, $severity, $title, $detail, $recommendation) {
            $findings.Add([PSCustomObject]@{
                    PSTypeName     = 'PSTSM.HealthFinding'
                    TaskName       = $row.TaskName
                    TaskPath       = $row.TaskPath
                    FullName       = $row.FullName
                    Origin         = $row.Origin
                    Severity       = $severity
                    Id             = $id
                    Title          = $title
                    Detail         = $detail
                    Recommendation = $recommendation
                })
        }

        # --- runtime state, available for every task ------------------------------------
        $result = $row.LastTaskResult
        $hasTriggers = ($row.TriggerCount -gt 0)
        $enabled = ($row.State -ne 'Disabled')

        if ($null -ne $result) {
            $u = [uint32]([int64]$result -band 0xFFFFFFFF)
            # 0x41300-0x41304 are status codes, not failures: ready, running, disabled, never
            # run, no more runs. Everything else non-zero is the task telling you it failed.
            $isStatus = ($u -ge 0x41300 -and $u -le 0x41304)
            if ($u -ne 0 -and -not $isStatus) {
                Add-Finding 'RUN_FAILED' 'Error' 'Last run failed' `
                    "$($row.LastResultText)$(if ($row.LastRunTime) { " on $($row.LastRunTime)" })" `
                    'Task Scheduler records only this code. If the task was built by PSTSM its transcript will say what actually happened.'
            }
            if ($u -eq 0x41303 -and $hasTriggers -and $enabled) {
                Add-Finding 'NEVER_RAN' 'Warning' 'Has triggers but has never run' `
                    'Registered with a schedule, yet Task Scheduler has no record of it ever starting.' `
                    'Usually a trigger that never fires, or a start boundary in the past. Check the schedule, or run it once by hand to prove it works.'
            }
        }

        if ($row.NumberOfMissedRuns -and [int]$row.NumberOfMissedRuns -gt 0) {
            Add-Finding 'MISSED_RUNS' 'Warning' "$($row.NumberOfMissedRuns) missed run(s)" `
                'Task Scheduler wanted to start this and could not.' `
                'Usually the machine was off or asleep. "Run as soon as possible after a missed start" makes it catch up.'
        }

        # Only a TIME-based trigger has a predictable next run. A task that fires at logon, on
        # idle, at startup or on an event has no next run time by nature, and flagging those
        # would bury the real findings - on a stock machine it fired on nearly every vendor
        # task, which is exactly how a health check trains people to ignore it.
        $timeBased = @($row.Task.Triggers | Where-Object {
                $null -ne $_ -and $_.CimClass.CimClassName -in @(
                    'MSFT_TaskDailyTrigger', 'MSFT_TaskWeeklyTrigger', 'MSFT_TaskTimeTrigger',
                    'MSFT_TaskMonthlyTrigger', 'MSFT_TaskMonthlyDOWTrigger'
                )
            })

        if ($enabled -and $timeBased.Count -gt 0 -and -not $row.NextRunTime) {
            Add-Finding 'NO_NEXT_RUN' 'Warning' 'Scheduled, but nothing is due' `
                "Has $($timeBased.Count) time-based trigger(s), yet Task Scheduler reports no next run time." `
                'Every schedule has expired or its end boundary has passed. It will never run again as configured.'
        }

        if (-not $enabled -and $hasTriggers) {
            Add-Finding 'DISABLED' 'Info' 'Disabled, but still has a schedule' `
                'Somebody turned this off and left the triggers in place.' `
                'If it is meant to be off, consider deleting it so it stops looking like a live task.'
        }

        if ($row.ScriptExists -eq $false) {
            Add-Finding 'SCRIPT_GONE' 'Error' 'The script it runs no longer exists' `
                $row.ScriptPath `
                'The task will fail on every run. Restore the script, repoint the task, or delete it.'
        }

        # --- full preflight, only where the action can be modelled -----------------------
        if ($row.IsPowerShell -and $row.IsRecognized -and $row.ScriptExists) {
            try {
                $plan = ConvertFrom-PSTSMDefinition -Task $row.Task -ErrorAction Stop
                foreach ($c in @(Test-PSTSMPlan -Plan $plan -SkipExistingTaskCheck -ErrorAction Stop)) {
                    # Ok/Info from the builder are noise in a sweep - only what is wrong matters.
                    if ($c.Severity -notin 'Error', 'Warning') { continue }
                    # Already reported above, with better wording for this context.
                    if ($c.Id -in 'SCRIPT_MISSING', 'NO_TRIGGERS') { continue }
                    Add-Finding $c.Id $c.Severity $c.Title $c.Detail $c.Recommendation
                }
            }
            catch {
                Add-Finding 'CHECK_FAILED' 'Warning' 'Could not be checked' `
                    $_.Exception.Message `
                    'Open it in the editor to see what PSTSM makes of it.'
            }
        }

        foreach ($f in $findings) { $f }
    }
}
