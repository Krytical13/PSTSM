# SPDX-License-Identifier: GPL-3.0-or-later
function New-PSTSMTriggerSpec {
    <#
    .SYNOPSIS
        Builds a plain, serialisable trigger description for a task plan.
    .DESCRIPTION
        Deliberately NOT a CimInstance. Plans are exported to JSON and applied to other
        machines, so triggers are stored as data and only converted to real
        New-ScheduledTaskTrigger output at registration time by Register-PSTSMPlan.

        Repetition is expressed here rather than bolted on afterwards because
        New-ScheduledTaskTrigger cannot set RepetitionInterval for every trigger type
        directly - Register-PSTSMPlan applies it to the CIM object after construction.
    .PARAMETER Type
        Once, Daily, Weekly, AtStartup, AtLogOn, OnIdle.
    .PARAMETER At
        Start time. Accepts 'HH:mm', a full datetime string, or a [datetime].
        Required for Once/Daily/Weekly.
    .PARAMETER DaysOfWeek
        Weekly only. Monday..Sunday.
    .PARAMETER DaysInterval
        Daily only. Every N days. Default 1.
    .PARAMETER WeeksInterval
        Weekly only. Every N weeks. Default 1.
    .PARAMETER UserId
        AtLogOn only. Restricts the trigger to one user; omit for any user.
    .PARAMETER RepetitionInterval
        Repeat every, as 'hh:mm:ss' (e.g. '00:15:00'). Optional.
    .PARAMETER RepetitionDuration
        How long to keep repeating, as 'd.hh:mm:ss', or 'Indefinitely'. Optional.
    .PARAMETER RandomDelay
        Random delay window, as 'hh:mm:ss'. Spreads load when the same task lands on many
        machines at the same minute.
    .PARAMETER Delay
        AtStartup/AtLogOn only. Fixed delay before running, as 'hh:mm:ss'. A boot task with no
        delay races the services it usually depends on.
    .PARAMETER Enabled
        Whether the trigger is active. Default $true.
    .OUTPUTS
        [pscustomobject]
    .EXAMPLE
        New-PSTSMTriggerSpec -Type Daily -At '07:00' -RandomDelay '00:05:00'
    .EXAMPLE
        New-PSTSMTriggerSpec -Type Weekly -At '18:30' -DaysOfWeek Monday,Thursday
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory trigger description only; nothing is registered until Register-PSTSMPlan runs.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Once', 'Daily', 'Weekly', 'AtStartup', 'AtLogOn', 'OnIdle')]
        [string]$Type,

        [object]$At,

        [ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')]
        [string[]]$DaysOfWeek,

        [ValidateRange(1, 365)]
        [int]$DaysInterval = 1,

        [ValidateRange(1, 52)]
        [int]$WeeksInterval = 1,

        [string]$UserId,

        [string]$RepetitionInterval,

        [string]$RepetitionDuration,

        [string]$RandomDelay,

        [string]$Delay,

        [bool]$Enabled = $true
    )

    if ($Type -in @('Once', 'Daily', 'Weekly') -and -not $At) {
        throw "Trigger type '$Type' requires -At."
    }
    if ($Type -eq 'Weekly' -and -not $DaysOfWeek) {
        throw 'Weekly triggers require -DaysOfWeek.'
    }

    # Normalise to a datetime so the UI and the registration path agree on what '07:00' means.
    $startBoundary = $null
    if ($At) {
        if ($At -is [datetime]) {
            $startBoundary = $At
        }
        elseif ($At -match '^\d{1,2}:\d{2}(:\d{2})?$') {
            $startBoundary = [datetime]::Today.Add([timespan]::Parse($At))
        }
        else {
            $startBoundary = [datetime]::Parse([string]$At, [System.Globalization.CultureInfo]::CurrentCulture)
        }
    }

    foreach ($pair in @(
            @{ Name = 'RepetitionInterval'; Value = $RepetitionInterval },
            @{ Name = 'RepetitionDuration'; Value = $RepetitionDuration },
            @{ Name = 'RandomDelay'; Value = $RandomDelay },
            @{ Name = 'Delay'; Value = $Delay }
        )) {
        $v = $pair.Value
        if (-not $v) { continue }
        if ($pair.Name -eq 'RepetitionDuration' -and $v -eq 'Indefinitely') { continue }
        try { [void][timespan]::Parse($v) }
        catch { throw "$($pair.Name) '$v' is not a valid timespan (expected hh:mm:ss or d.hh:mm:ss)." }
    }

    if ($RepetitionDuration -and -not $RepetitionInterval) {
        throw 'RepetitionDuration requires RepetitionInterval.'
    }

    [PSCustomObject]@{
        PSTypeName         = 'PSTSM.TriggerSpec'
        Type               = $Type
        At                 = if ($startBoundary) { $startBoundary.ToString('yyyy-MM-ddTHH:mm:ss') } else { $null }
        DaysOfWeek         = if ($DaysOfWeek) { @($DaysOfWeek) } else { @() }
        DaysInterval       = $DaysInterval
        WeeksInterval      = $WeeksInterval
        UserId             = $UserId
        RepetitionInterval = $RepetitionInterval
        RepetitionDuration = $RepetitionDuration
        RandomDelay        = $RandomDelay
        Delay              = $Delay
        Enabled            = $Enabled
    }
}
