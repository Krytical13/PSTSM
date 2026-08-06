# SPDX-License-Identifier: GPL-3.0-or-later
function Update-PSTSMTaskSchedule {
    <#
    .SYNOPSIS
        Changes the schedule around an existing task's action without touching the action itself.
    .DESCRIPTION
        For tasks whose action this tool cannot model - a COM handler, which has no command line
        at all, or a task with more actions than one plan holds - re-registering through
        Register-PSTSMPlan would drop something. That is why those stay read-only there.

        But the reason to open such a task is almost never the action. It is "run this an hour
        later", or "stop it waking the machine", or "it should run as a different account" - and
        every one of those is expressible without knowing what the task runs.

        Set-ScheduledTask updates only the components it is given and leaves the rest of the
        registered definition alone, so the actions are not rebuilt, re-serialised or re-quoted
        here: they are simply not part of the write. Verified against a two-action task, where
        both actions came back byte-identical after changing only the trigger.

        Description is applied through the task object rather than a parameter, because
        Set-ScheduledTask does not expose one.
    .PARAMETER Plan
        A PSTSM.TaskPlan whose TaskName/TaskPath identify an already-registered task. Its
        Triggers, Principal and Settings are applied; its action fields are ignored.
    .PARAMETER Password
        Required only when the principal's LogonType is 'Password'. A gMSA needs none.
    .OUTPUTS
        The updated scheduled task.
    .EXAMPLE
        $plan = ConvertFrom-PSTSMDefinition -TaskName 'Vendor Agent' -TaskPath '\'
        $plan.Triggers = @(New-PSTSMTriggerSpec -Type Daily -At '02:00')
        Update-PSTSMTaskSchedule -Plan $plan
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [object]$Plan,

        [securestring]$Password
    )

    process {
        $target = "$($Plan.TaskPath)$($Plan.TaskName)"

        # This command edits in place. It cannot create, and it must not be the path by which a
        # task silently appears somewhere the operator did not expect.
        if (-not (Test-PSTSMTaskExists -TaskName $Plan.TaskName -TaskPath $Plan.TaskPath)) {
            throw "No task registered at $target. Update-PSTSMTaskSchedule changes an existing task's schedule; use Register-PSTSMPlan to create one."
        }

        if ($Plan.Principal.LogonType -eq 'Password' -and -not $Password) {
            throw "Principal.LogonType is 'Password' but no -Password was supplied. For a group managed service account use LogonType 'gMSA', which needs none."
        }

        $components = ConvertTo-PSTSMTaskComponent -Plan $Plan

        $setParams = @{
            TaskName  = $Plan.TaskName
            TaskPath  = $Plan.TaskPath
            Settings  = $components.Settings
            Principal = $components.Principal
        }
        # An empty -Trigger removes every trigger, which is a real edit ("manual only") but not one
        # to make by accident: omitting the key leaves the registered triggers alone instead.
        if ($components.Triggers.Count -gt 0) { $setParams['Trigger'] = $components.Triggers }

        if ($Password) {
            $setParams['User'] = $Plan.Principal.UserId
            $setParams['Password'] = [System.Net.NetworkCredential]::new('', $Password).Password
        }

        if (-not $PSCmdlet.ShouldProcess($target, 'Update scheduled task schedule (action left untouched)')) { return }

        $updated = Set-ScheduledTask @setParams -ErrorAction Stop

        # Description last, and only when it changed. Set-ScheduledTask has no -Description, so it
        # goes through the object - a second write, which is worth avoiding when there is nothing
        # to write.
        if ($null -ne $Plan.Description) {
            $current = Get-ScheduledTask -TaskName $Plan.TaskName -TaskPath $Plan.TaskPath -ErrorAction Stop
            if ([string]$current.Description -cne [string]$Plan.Description) {
                $current.Description = [string]$Plan.Description
                $updated = Set-ScheduledTask -InputObject $current -ErrorAction Stop
            }
        }

        $updated
    }
}
