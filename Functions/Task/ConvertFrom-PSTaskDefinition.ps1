# SPDX-License-Identifier: GPL-3.0-or-later
function ConvertFrom-PSTaskDefinition {
    <#
    .SYNOPSIS
        Turns an already-registered scheduled task back into an editable plan.
    .DESCRIPTION
        The other half of the round trip. Get-PSTaskInventory shows the list; this opens a row
        in the same form that created it, so "change the schedule" and "change the account" do
        not mean dropping into taskschd.msc.

        Fidelity rules:
          - A task whose action this tool understands (-File against a .ps1) round-trips fully.
          - A task built some other way still produces a plan, but IsFullyRecognized is $false
            and RawAction carries the original Execute/Arguments untouched. The UI must show
            a raw-arguments box in that case; silently rewriting somebody's working task into
            our preferred shape is how you break production at 3am.
          - Settings and triggers are read from the live task, so anything set outside this
            tool survives an edit here.
    .PARAMETER Task
        A scheduled task object from Get-ScheduledTask.
    .PARAMETER TaskName
        Name of the task to load. Used with TaskPath instead of -Task.
    .PARAMETER TaskPath
        Folder of the task to load. Default '\'.
    .OUTPUTS
        [pscustomobject] PSTaskBuilder.TaskPlan, with extra IsFullyRecognized / RawAction /
        ParseNotes members.
    .EXAMPLE
        $plan = ConvertFrom-PSTaskDefinition -TaskName 'Nightly Report' -TaskPath '\Custom\'
        $plan.Triggers = @(New-PSTaskTriggerSpec -Type Daily -At '06:00')
        Register-PSTaskPlan -Plan $plan
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByObject')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByObject', ValueFromPipeline)]
        [object]$Task,

        [Parameter(Mandatory, ParameterSetName = 'ByName')]
        [string]$TaskName,

        [Parameter(ParameterSetName = 'ByName')]
        [string]$TaskPath = '\'
    )

    process {
        if ($PSCmdlet.ParameterSetName -eq 'ByName') {
            $Task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop
        }

        $action = @($Task.Actions)[0]
        $notes = New-Object System.Collections.Generic.List[string]

        if (@($Task.Actions).Count -gt 1) {
            $notes.Add("Task has $(@($Task.Actions).Count) actions; only the first is modelled. Saving will drop the others.")
        }

        $parsed = ConvertFrom-PSTaskAction -Execute $action.Execute `
            -Arguments $action.Arguments `
            -WorkingDirectory $action.WorkingDirectory
        foreach ($n in $parsed.Notes) { $notes.Add($n) }

        # If the action points at a generated wrapper, resolve back to the real script so the
        # form shows the user's script, not our shim.
        $scriptPath = $parsed.ScriptPath
        $loggingMode = 'None'
        $logDirectory = $null
        $retentionDays = 30

        if ($scriptPath -and $scriptPath -match '\\\.pstask\\.+\.wrapper\.ps1$') {
            $loggingMode = 'Transcript'
            try {
                $wrapperText = Get-Content -LiteralPath $scriptPath -Raw -ErrorAction Stop
                if ($wrapperText -match "(?m)^\s*\`$scriptPath\s*=\s*'(?<p>.+?)'\s*$") { $scriptPath = $Matches['p'] -replace "''", "'" }
                if ($wrapperText -match "(?m)^\s*\`$logDirectory\s*=\s*'(?<d>.+?)'\s*$") { $logDirectory = $Matches['d'] -replace "''", "'" }
                if ($wrapperText -match '(?m)^\s*\$retentionDays\s*=\s*(?<r>\d+)\s*$') { $retentionDays = [int]$Matches['r'] }
            }
            catch {
                $notes.Add("Action targets a PSTaskBuilder wrapper that could not be read: $scriptPath")
            }
        }

        # --- triggers back to specs -----------------------------------------------------
        $triggerSpecs = New-Object System.Collections.Generic.List[object]
        foreach ($t in @($Task.Triggers)) {
            $spec = ConvertFrom-PSTaskCimTrigger -Trigger $t
            if ($spec) { $triggerSpecs.Add($spec) }
            else { $notes.Add("Trigger type '$($t.CimClass.CimClassName)' is not editable here and will be preserved as-is only if you do not re-register.") }
        }

        # --- settings back to plan shape ------------------------------------------------
        $ts = $Task.Settings
        $settings = [ordered]@{
            MultipleInstances          = [string]$ts.MultipleInstances
            StartWhenAvailable         = [bool]$ts.StartWhenAvailable
            ExecutionTimeLimit         = (ConvertFrom-PSTaskDuration -Value $ts.ExecutionTimeLimit)
            RestartCount               = [int]$ts.RestartCount
            RestartInterval            = (ConvertFrom-PSTaskDuration -Value $ts.RestartInterval)
            DisallowStartIfOnBatteries = [bool]$ts.DisallowStartIfOnBatteries
            StopIfGoingOnBatteries     = [bool]$ts.StopIfGoingOnBatteries
            RunOnlyIfNetworkAvailable  = [bool]$ts.RunOnlyIfNetworkAvailable
            RunOnlyIfIdle              = [bool]$ts.RunOnlyIfIdle
            WakeToRun                  = [bool]$ts.WakeToRun
            Hidden                     = [bool]$ts.Hidden
            AllowDemandStart           = [bool]$ts.AllowDemandStart
            DontStopOnIdleEnd          = [bool]$ts.DontStopOnIdleEnd
            Priority                   = [int]$ts.Priority
            Compatibility              = [string]$ts.Compatibility
        }

        $engineId = if ($parsed.EngineId) { $parsed.EngineId } else { 'powershell' }

        $plan = [PSCustomObject]@{
            PSTypeName        = 'PSTaskBuilder.TaskPlan'
            SchemaVersion     = 1

            TaskName          = $Task.TaskName
            TaskPath          = $Task.TaskPath
            Description       = $Task.Description

            ScriptPath        = $scriptPath
            EngineId          = $engineId
            EnginePath        = $action.Execute
            WorkingDirectory  = $action.WorkingDirectory

            Parameters        = $parsed.Parameters
            ExtraArguments    = $parsed.ExtraArguments

            NoProfile         = $parsed.NoProfile
            NonInteractive    = $parsed.NonInteractive
            ExecutionPolicy   = $parsed.ExecutionPolicy
            WindowStyle       = $parsed.WindowStyle

            Triggers          = $triggerSpecs.ToArray()

            Principal         = [ordered]@{
                UserId    = $Task.Principal.UserId
                # A gMSA is stored as LogonType Password, so the registered task cannot say
                # which it is. An account name ending in '$' is the sAMAccountName convention
                # for a managed service account, and a normal user cannot have one, so this is
                # a safe reading - and it matters, because re-saving as 'Password' would demand
                # a password the account does not have.
                LogonType = $(
                    if ([string]$Task.Principal.LogonType -eq 'Password' -and $Task.Principal.UserId -match '\$$') { 'gMSA' }
                    else { [string]$Task.Principal.LogonType }
                )
                RunLevel  = [string]$Task.Principal.RunLevel
            }

            Settings          = $settings

            Logging           = [ordered]@{
                Mode          = $loggingMode
                Directory     = if ($logDirectory) { $logDirectory } elseif ($scriptPath) { Join-Path (Split-Path $scriptPath -Parent) 'Logs' } else { $null }
                RetentionDays = $retentionDays
            }

            Source            = [ordered]@{
                EngineConfidence = 'FromExistingTask'
                EngineReason     = "read from registered task $($Task.TaskPath)$($Task.TaskName)"
                DerivedFrom      = "$($Task.TaskPath)$($Task.TaskName)"
            }

            # Round-trip safety
            IsFullyRecognized = [bool]($parsed.IsRecognized -and @($Task.Actions).Count -eq 1)
            RawAction         = [ordered]@{
                Execute          = $action.Execute
                Arguments        = $action.Arguments
                WorkingDirectory = $action.WorkingDirectory
            }
            ParseNotes        = $notes.ToArray()
        }

        $plan | Add-Member -MemberType ScriptProperty -Name 'ArgumentString' -Value {
            ConvertTo-PSTaskArgument -ScriptPath $this.ScriptPath `
                -Parameters $this.Parameters `
                -ExtraArguments $this.ExtraArguments `
                -ExecutionPolicy $this.ExecutionPolicy `
                -NoProfile $this.NoProfile `
                -NonInteractive $this.NonInteractive `
                -WindowStyle $this.WindowStyle
        }

        $plan
    }
}

function ConvertFrom-PSTaskCimTrigger {
    <#
    .SYNOPSIS
        Converts a live CIM trigger back into a New-PSTaskTriggerSpec-shaped object.
    .PARAMETER Trigger
        A trigger from a registered task.
    .OUTPUTS
        [pscustomobject] or $null when the trigger type is not modelled.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Trigger
    )

    $class = $Trigger.CimClass.CimClassName

    $at = $null
    if ($Trigger.StartBoundary) {
        try { $at = ([datetime]::Parse($Trigger.StartBoundary)).ToString('yyyy-MM-ddTHH:mm:ss') }
        catch { Write-Verbose "Unparseable StartBoundary '$($Trigger.StartBoundary)'" }
    }

    $type = switch ($class) {
        'MSFT_TaskDailyTrigger' { 'Daily' }
        'MSFT_TaskWeeklyTrigger' { 'Weekly' }
        'MSFT_TaskTimeTrigger' { 'Once' }
        'MSFT_TaskBootTrigger' { 'AtStartup' }
        'MSFT_TaskLogonTrigger' { 'AtLogOn' }
        'MSFT_TaskIdleTrigger' { 'OnIdle' }
        default { $null }
    }
    if (-not $type) { return $null }

    $daysOfWeek = @()
    if ($class -eq 'MSFT_TaskWeeklyTrigger' -and $Trigger.DaysOfWeek) {
        # Bit mask, Sunday = bit 0.
        $names = @('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')
        for ($i = 0; $i -lt 7; $i++) {
            if ($Trigger.DaysOfWeek -band (1 -shl $i)) { $daysOfWeek += $names[$i] }
        }
    }

    [PSCustomObject]@{
        PSTypeName         = 'PSTaskBuilder.TriggerSpec'
        Type               = $type
        At                 = $at
        DaysOfWeek         = $daysOfWeek
        DaysInterval       = if ($Trigger.PSObject.Properties['DaysInterval'] -and $Trigger.DaysInterval) { [int]$Trigger.DaysInterval } else { 1 }
        WeeksInterval      = if ($Trigger.PSObject.Properties['WeeksInterval'] -and $Trigger.WeeksInterval) { [int]$Trigger.WeeksInterval } else { 1 }
        UserId             = if ($Trigger.PSObject.Properties['UserId']) { $Trigger.UserId } else { $null }
        RepetitionInterval = if ($Trigger.Repetition) { ConvertFrom-PSTaskDuration -Value $Trigger.Repetition.Interval } else { $null }
        RepetitionDuration = if ($Trigger.Repetition) { ConvertFrom-PSTaskDuration -Value $Trigger.Repetition.Duration } else { $null }
        RandomDelay        = if ($Trigger.PSObject.Properties['RandomDelay']) { ConvertFrom-PSTaskDuration -Value $Trigger.RandomDelay } else { $null }
        Delay              = if ($Trigger.PSObject.Properties['Delay']) { ConvertFrom-PSTaskDuration -Value $Trigger.Delay } else { $null }
        Enabled            = [bool]$Trigger.Enabled
    }
}

function ConvertFrom-PSTaskDuration {
    <#
    .SYNOPSIS
        Converts an ISO 8601 duration (as Task Scheduler stores them) to hh:mm:ss.
    .DESCRIPTION
        Task Scheduler persists durations as 'PT4H', 'P1D', 'PT15M' and so on. [timespan] cannot
        parse those, so plans store the readable form and only the registration path converts
        back. Returns $null for an absent or unparseable value rather than throwing - a
        malformed duration on one trigger must not stop the whole list from loading.
    .PARAMETER Value
        The ISO 8601 duration string.
    .OUTPUTS
        [string] hh:mm:ss or d.hh:mm:ss, or $null.
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    if ($Value -notmatch '^P(?:(?<d>\d+)D)?(?:T(?:(?<h>\d+)H)?(?:(?<m>\d+)M)?(?:(?<s>\d+(?:\.\d+)?)S)?)?$') {
        return $null
    }

    $days = if ($Matches['d']) { [int]$Matches['d'] } else { 0 }
    $hours = if ($Matches['h']) { [int]$Matches['h'] } else { 0 }
    $mins = if ($Matches['m']) { [int]$Matches['m'] } else { 0 }
    $secs = if ($Matches['s']) { [int][double]$Matches['s'] } else { 0 }

    $ts = New-TimeSpan -Days $days -Hours $hours -Minutes $mins -Seconds $secs
    if ($ts.TotalSeconds -eq 0) { return $null }

    if ($ts.Days -gt 0) { return ('{0}.{1:00}:{2:00}:{3:00}' -f $ts.Days, $ts.Hours, $ts.Minutes, $ts.Seconds) }
    # $ts.Hours, not [int]$ts.TotalHours - the latter rounds 1.5h up to 02:30:00.
    '{0:00}:{1:00}:{2:00}' -f $ts.Hours, $ts.Minutes, $ts.Seconds
}
