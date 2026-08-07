# SPDX-License-Identifier: GPL-3.0-or-later
function ConvertFrom-PSTSMDefinition {
    <#
    .SYNOPSIS
        Turns an already-registered scheduled task back into an editable plan.
    .DESCRIPTION
        The other half of the round trip. Get-PSTSMInventory shows the list; this opens a row
        in the same form that created it, so "change the schedule" and "change the account" do
        not mean dropping into taskschd.msc.

        Fidelity rules:
          - A task whose action this tool understands (-File against a .ps1) round-trips fully.
          - A task built some other way still produces a plan, but IsFullyRecognized is $false
            and RawAction carries the original Execute/Arguments untouched. The editor shows
            that action read-only and disables Save; silently rewriting somebody's working task
            into our preferred shape is how you break production at 3am.
          - Settings and triggers are read from the live task, so anything set outside this
            tool survives an edit here.
    .PARAMETER Task
        A scheduled task object from Get-ScheduledTask.
    .PARAMETER TaskName
        Name of the task to load. Used with TaskPath instead of -Task.
    .PARAMETER TaskPath
        Folder of the task to load. Default '\'.
    .OUTPUTS
        [pscustomobject] PSTSM.TaskPlan, with extra IsFullyRecognized / RawAction /
        ParseNotes members.
    .EXAMPLE
        $plan = ConvertFrom-PSTSMDefinition -TaskName 'Nightly Report' -TaskPath '\Custom\'
        $plan.Triggers = @(New-PSTSMTriggerSpec -Type Daily -At '06:00')
        Register-PSTSMPlan -Plan $plan
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

        $realActions = @($Task.Actions | Where-Object { $null -ne $_ })
        $action = if ($realActions.Count -gt 0) { $realActions[0] } else { $null }
        $notes = New-Object System.Collections.Generic.List[string]

        # Not every action runs a program. Roughly half the built-in Windows tasks use a
        # ComHandler action, which has a ClassId instead of an Execute, so reading .Execute
        # yields nothing and the "what does this run" answer has to come from elsewhere.
        $actionClass = if ($action) { $action.CimClass.CimClassName } else { '<none>' }
        $isExec = ($actionClass -eq 'MSFT_TaskExecAction')

        # Every action, not just the first. A task that runs two programs has nothing
        # unrepresentable about it - the plan simply used to hold one, and the difference between
        # "we cannot model this" and "we only kept one of them" was invisible from the outside.
        # All-exec is what matters: one COM handler anywhere in the list and the whole task stays
        # read-only, because that action genuinely cannot be rebuilt from a plan.
        $allExec = ($realActions.Count -gt 0) -and
            (@($realActions | Where-Object { $_.CimClass.CimClassName -ne 'MSFT_TaskExecAction' }).Count -eq 0)

        $rawActions = @(
            foreach ($a in $realActions) {
                $aIsExec = ($a.CimClass.CimClassName -eq 'MSFT_TaskExecAction')
                [ordered]@{
                    Execute          = [string]$(if ($aIsExec) { $a.Execute })
                    Arguments        = [string]$(if ($aIsExec) { $a.Arguments })
                    WorkingDirectory = [string]$(if ($aIsExec) { $a.WorkingDirectory })
                    ActionType       = [string]$a.CimClass.CimClassName
                    Summary          = $(
                        if ($aIsExec) { (@([string]$a.Execute, [string]$a.Arguments) | Where-Object { $_ }) -join ' ' }
                        elseif ($a.PSObject.Properties['ClassId'] -and $a.ClassId) { "$($a.CimClass.CimClassName) - COM class $($a.ClassId)" }
                        else { [string]$a.CimClass.CimClassName }
                    )
                }
            }
        )

        if ($realActions.Count -gt 1 -and -not $allExec) {
            $notes.Add("Task has $($realActions.Count) actions and at least one is not a program to run, so it cannot be rebuilt here. The schedule around it can still be changed.")
        }
        elseif ($realActions.Count -gt 1) {
            $notes.Add("Task runs $($realActions.Count) programs in order. All of them are kept.")
        }

        if (-not $action) {
            $notes.Add('Task has no actions at all, so there is nothing for it to run.')
        }
        elseif (-not $isExec) {
            $comId = if ($action.PSObject.Properties['ClassId']) { $action.ClassId } else { $null }
            $notes.Add("Action type is $actionClass, not a program to run$(if ($comId) { " (COM class $comId)" }). PSTSM models only executable actions, so this task is read-only here.")
        }

        $parsed = ConvertFrom-PSTSMAction `
            -Execute ([string]$(if ($isExec) { $action.Execute })) `
            -Arguments ([string]$(if ($isExec) { $action.Arguments })) `
            -WorkingDirectory ([string]$(if ($isExec) { $action.WorkingDirectory }))
        # Only for executable actions. For a COM handler the parser was handed an empty Execute
        # and would add "Action runs '', which is not a PowerShell host" on top of the accurate
        # explanation already recorded above - two notes for one fact, one of them nonsense.
        if ($isExec) { foreach ($n in $parsed.Notes) { $notes.Add($n) } }

        # If the action points at a generated wrapper, resolve back to the real script so the
        # form shows the user's script, not our shim.
        $scriptPath = $parsed.ScriptPath
        $loggingMode = 'None'
        $logDirectory = $null
        $retentionDays = 30

        if ($scriptPath -and $scriptPath -match '\\\.pstsm\\.+\.wrapper\.ps1$') {
            $loggingMode = 'Transcript'
            try {
                $wrapperText = Get-Content -LiteralPath $scriptPath -Raw -ErrorAction Stop
                if ($wrapperText -match "(?m)^\s*\`$scriptPath\s*=\s*'(?<p>.+?)'\s*$") { $scriptPath = $Matches['p'] -replace "''", "'" }
                if ($wrapperText -match "(?m)^\s*\`$logDirectory\s*=\s*'(?<d>.+?)'\s*$") { $logDirectory = $Matches['d'] -replace "''", "'" }
                if ($wrapperText -match '(?m)^\s*\$retentionDays\s*=\s*(?<r>\d+)\s*$') { $retentionDays = [int]$Matches['r'] }
            }
            catch {
                $notes.Add("Action targets a PSTSM wrapper that could not be read: $scriptPath")
            }
        }

        # --- triggers back to specs -----------------------------------------------------
        # Where-Object, not a bare @(). A task with NO triggers has $Task.Triggers = $null, and
        # @($null) is a ONE-element array containing $null - so the loop ran once with nothing
        # and the mandatory -Trigger parameter refused to bind. That made every manual-only task
        # impossible to open: 65 of the 288 tasks on a stock machine.
        $triggerSpecs = New-Object System.Collections.Generic.List[object]
        foreach ($t in @($Task.Triggers | Where-Object { $null -ne $_ })) {
            $spec = ConvertFrom-PSTSMCimTrigger -Trigger $t
            if ($spec) { $triggerSpecs.Add($spec) }
            else { $notes.Add("Trigger type '$($t.CimClass.CimClassName)' is not editable here and will be preserved as-is only if you do not re-register.") }
        }

        # --- settings back to plan shape ------------------------------------------------
        $ts = $Task.Settings
        $settings = [ordered]@{
            MultipleInstances          = [string]$ts.MultipleInstances
            StartWhenAvailable         = [bool]$ts.StartWhenAvailable
            ExecutionTimeLimit         = (ConvertFrom-PSTSMDuration -Value $ts.ExecutionTimeLimit)
            RestartCount               = [int]$ts.RestartCount
            RestartInterval            = (ConvertFrom-PSTSMDuration -Value $ts.RestartInterval)
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

        # Re-derive which switches the script defaults to $true, so re-registering an existing
        # task keeps writing -X:$false for any that were turned off. Best effort: a task whose
        # script has since moved or been deleted still opens, it just cannot know this - and
        # the preflight already reports the missing script far more loudly.
        $switchDefaultTrue = @()
        if ($scriptPath -and (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            try {
                $prof = Get-PSTSMScriptProfile -Path $scriptPath -ErrorAction Stop
                $switchDefaultTrue = @($prof.Parameters | Where-Object {
                        $_.IsSwitch -and $_.HasDefault -and $_.DefaultKind -eq 'Literal' -and
                        $null -ne $_.ResolvedDefault -and [bool]$_.ResolvedDefault.Value
                    } | ForEach-Object { $_.Name })
            }
            catch {
                Write-Verbose "Could not re-read switch defaults from $scriptPath : $($_.Exception.Message)"
            }
        }

        $plan = [PSCustomObject]@{
            PSTypeName        = 'PSTSM.TaskPlan'
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
            SwitchDefaultTrue = @($switchDefaultTrue)

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

            # Round-trip safety. A single executable action that parses back to a .ps1 is the
            # only shape that can be re-saved through the SCRIPT model without rewriting
            # somebody's working task. Kept as-is: callers and tests read it as "does the
            # script-and-parameters form apply", which is still exactly what it answers.
            IsFullyRecognized = [bool]($parsed.IsRecognized -and $isExec -and $realActions.Count -eq 1)

            # How much of the action can be edited, which is a finer question than the flag above
            # and the reason this exists. IsFullyRecognized was false for four unrelated causes,
            # and the editor locked completely on any of them - including on tasks that are
            # simpler than the ones it does model.
            #
            #   PowerShellScript - single exec action that parses back to a .ps1. The full
            #                      script + parameters form applies.
            #   Executable       - single exec action that does not (robocopy.exe, a .cmd, or
            #                      powershell.exe with inline -Command). There is nothing lossy
            #                      here: Task Scheduler's own model for such an action IS
            #                      Execute + Arguments + WorkingDirectory, all three of which are
            #                      carried verbatim in RawAction. What is missing is the
            #                      script-parameter layer above it, not fidelity. Editing writes
            #                      back the exact strings shown - PSTSM re-quotes nothing, which
            #                      makes this a stricter guarantee than the PowerShell path, where
            #                      the argument string is reconstructed from parsed parameters.
            #   Unsupported      - at least one action has no command line to preserve (a COM
            #                      handler), or there are no actions at all. Re-registering
            #                      through the plan would drop something, so the actions stay
            #                      read-only and only the schedule around them can be edited.
            #
            # Action COUNT is deliberately not part of this. A task that runs two programs is not
            # less modellable than one that runs a single program - the plan used to hold one, and
            # that was a limit of the shape rather than of the task.
            ActionKind        = $(
                if ($parsed.IsRecognized -and $isExec -and $realActions.Count -eq 1) { 'PowerShellScript' }
                elseif ($allExec -and $rawActions[0].Execute) { 'Executable' }
                else { 'Unsupported' }
            )
            ActionType        = $actionClass

            # Every action in order. RawAction below stays the first one, unchanged, because
            # callers and tests read it - but RawActions is what Register-PSTSMPlan writes.
            RawActions        = $rawActions
            RawAction         = [ordered]@{
                Execute          = [string]$(if ($isExec) { $action.Execute })
                Arguments        = [string]$(if ($isExec) { $action.Arguments })
                WorkingDirectory = [string]$(if ($isExec) { $action.WorkingDirectory })
                # For a non-executable action there is no command line to show, so carry
                # something that actually describes it instead of three empty strings.
                Summary          = $(
                    if (-not $action) { 'This task has no actions.' }
                    elseif ($isExec) { (@([string]$action.Execute, [string]$action.Arguments) | Where-Object { $_ }) -join ' ' }
                    elseif ($action.PSObject.Properties['ClassId'] -and $action.ClassId) { "$actionClass - COM class $($action.ClassId)" }
                    else { $actionClass }
                )
            }
            ParseNotes        = $notes.ToArray()
        }

        $plan | Add-Member -MemberType ScriptProperty -Name 'ArgumentString' -Value {
            ConvertTo-PSTSMArgument -ScriptPath $this.ScriptPath `
                -Parameters $this.Parameters `
                -ExtraArguments $this.ExtraArguments `
                -ExecutionPolicy $this.ExecutionPolicy `
                -NoProfile $this.NoProfile `
                -NonInteractive $this.NonInteractive `
                -WindowStyle $this.WindowStyle `
            -SwitchDefaultTrue $this.SwitchDefaultTrue
        }

        $plan
    }
}

function ConvertFrom-PSTSMCimTrigger {
    <#
    .SYNOPSIS
        Converts a live CIM trigger back into a New-PSTSMTriggerSpec-shaped object.
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
        # InvariantCulture on BOTH sides. This is the sibling of the writer in
        # New-PSTSMTriggerSpec, and it was missed when that one was fixed - so opening an existing
        # task on fi-FI or id-ID produced 07.00.00, and on ar-SA a Hijri year, while every reader
        # parses invariantly. Fixing one end of a round trip and not the other is worse than
        # fixing neither, because it turns a read into a silent rewrite.
        try {
            $at = ([datetime]::Parse($Trigger.StartBoundary, [cultureinfo]::InvariantCulture)).ToString(
                'yyyy-MM-ddTHH:mm:ss', [cultureinfo]::InvariantCulture)
        }
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
        PSTypeName         = 'PSTSM.TriggerSpec'
        Type               = $type
        At                 = $at
        DaysOfWeek         = $daysOfWeek
        DaysInterval       = if ($Trigger.PSObject.Properties['DaysInterval'] -and $Trigger.DaysInterval) { [int]$Trigger.DaysInterval } else { 1 }
        WeeksInterval      = if ($Trigger.PSObject.Properties['WeeksInterval'] -and $Trigger.WeeksInterval) { [int]$Trigger.WeeksInterval } else { 1 }
        UserId             = if ($Trigger.PSObject.Properties['UserId']) { $Trigger.UserId } else { $null }
        RepetitionInterval = if ($Trigger.Repetition) { ConvertFrom-PSTSMDuration -Value $Trigger.Repetition.Interval } else { $null }
        RepetitionDuration = if ($Trigger.Repetition) { ConvertFrom-PSTSMDuration -Value $Trigger.Repetition.Duration } else { $null }
        RandomDelay        = if ($Trigger.PSObject.Properties['RandomDelay']) { ConvertFrom-PSTSMDuration -Value $Trigger.RandomDelay } else { $null }
        Delay              = if ($Trigger.PSObject.Properties['Delay']) { ConvertFrom-PSTSMDuration -Value $Trigger.Delay } else { $null }
        Enabled            = [bool]$Trigger.Enabled
    }
}

function ConvertFrom-PSTSMDuration {
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
