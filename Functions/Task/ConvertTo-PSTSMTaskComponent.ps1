# SPDX-License-Identifier: GPL-3.0-or-later
function ConvertTo-PSTSMTaskComponent {
    <#
    .SYNOPSIS
        Turns a plan's triggers, principal and settings into the Task Scheduler objects that
        register them.
    .DESCRIPTION
        Extracted so the two commands that write a task cannot drift apart. Register-PSTSMPlan
        replaces a whole task; Update-PSTSMTaskSchedule changes the schedule around an action it
        must not touch. Both need these three components built identically - a difference between
        them would mean "edit the schedule" quietly applied different settings than "save".

        The action is deliberately NOT built here: it is the one component the two callers treat
        differently, and it is the whole reason the second command exists.
    .PARAMETER Plan
        A PSTSM.TaskPlan.
    .OUTPUTS
        [pscustomobject] Triggers, Principal, Settings
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Plan
    )

    # --- triggers ----------------------------------------------------------------------
    $triggers = @()
    foreach ($spec in @($Plan.Triggers)) {
        $triggers += ConvertTo-PSTSMCimTrigger -Spec $spec
    }

    # --- principal ---------------------------------------------------------------------
    # A gMSA is registered as LogonType Password with NO password: Task Scheduler retrieves the
    # managed password from the directory itself. There is no gMSA-specific value in
    # TASK_LOGON_TYPE, which is why the plan models it separately and collapses it here.
    $effectiveLogonType = $Plan.Principal.LogonType
    if ($effectiveLogonType -eq 'gMSA') { $effectiveLogonType = 'Password' }

    $principalParams = @{ LogonType = $effectiveLogonType }
    if ($Plan.Principal.LogonType -eq 'Group') {
        $principalParams['GroupId'] = $Plan.Principal.UserId
    }
    else {
        $principalParams['UserId'] = $Plan.Principal.UserId
        # RunLevel is meaningless for Group principals and rejected for some built-ins.
        $principalParams['RunLevel'] = $Plan.Principal.RunLevel
    }
    $principal = New-ScheduledTaskPrincipal @principalParams

    # --- settings ----------------------------------------------------------------------
    $s = $Plan.Settings
    $settingsParams = @{
        MultipleInstances = $s.MultipleInstances
        Compatibility     = $s.Compatibility
        Priority          = $s.Priority
    }
    if ($s.StartWhenAvailable) { $settingsParams['StartWhenAvailable'] = $true }
    if ($s.RunOnlyIfNetworkAvailable) { $settingsParams['RunOnlyIfNetworkAvailable'] = $true }
    if ($s.WakeToRun) { $settingsParams['WakeToRun'] = $true }
    if ($s.Hidden) { $settingsParams['Hidden'] = $true }
    if ($s.RunOnlyIfIdle) { $settingsParams['RunOnlyIfIdle'] = $true }
    if ($s.DontStopOnIdleEnd) { $settingsParams['DontStopOnIdleEnd'] = $true }

    # The cmdlet exposes these as the positive form of the opposite condition.
    if (-not $s.DisallowStartIfOnBatteries) { $settingsParams['AllowStartIfOnBatteries'] = $true }
    if (-not $s.StopIfGoingOnBatteries) { $settingsParams['DontStopIfGoingOnBatteries'] = $true }

    if ($s.ExecutionTimeLimit -and $s.ExecutionTimeLimit -ne '00:00:00') {
        $settingsParams['ExecutionTimeLimit'] = [timespan]::Parse($s.ExecutionTimeLimit)
    }
    if ($s.RestartCount -and [int]$s.RestartCount -gt 0) {
        $settingsParams['RestartCount'] = [int]$s.RestartCount
        # RestartInterval is mandatory whenever RestartCount is set, and must be >= 1 minute.
        $interval = if ($s.RestartInterval) { [timespan]::Parse($s.RestartInterval) } else { [timespan]::FromMinutes(5) }
        if ($interval.TotalMinutes -lt 1) { $interval = [timespan]::FromMinutes(1) }
        $settingsParams['RestartInterval'] = $interval
    }

    $settings = New-ScheduledTaskSettingsSet @settingsParams
    # Not exposed as a cmdlet parameter; set on the instance.
    if ($null -ne $s.AllowDemandStart) { $settings.AllowDemandStart = [bool]$s.AllowDemandStart }

    [PSCustomObject]@{
        Triggers  = $triggers
        Principal = $principal
        Settings  = $settings
    }
}
