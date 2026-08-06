# SPDX-License-Identifier: GPL-3.0-or-later
function Register-PSTSMPlan {
    <#
    .SYNOPSIS
        Registers (or updates) a Windows scheduled task from a plan.
    .DESCRIPTION
        Turns the plan's plain data into the CIM objects the ScheduledTasks module wants, then
        registers it. Runs Test-PSTSMPlan first and refuses on any Error unless -Force.

        When Logging.Mode is 'Transcript' the action points at a generated wrapper rather than
        the script itself, so every run leaves a log and a truthful exit code. The wrapper is
        regenerated here on every save so it can never drift from the plan.
    .PARAMETER Plan
        A New-PSTSMPlan object.
    .PARAMETER Password
        Required when Principal.LogonType is 'Password'. Never persisted to the plan; it goes
        straight to Task Scheduler's own credential store.
    .PARAMETER Force
        Register even when preflight reports Errors.
    .PARAMETER PassThru
        Emit the registered task object.
    .OUTPUTS
        The registered scheduled task when -PassThru is used.
    .EXAMPLE
        Register-PSTSMPlan -Plan $plan
    .EXAMPLE
        Register-PSTSMPlan -Plan $plan -Password (Read-Host -AsSecureString)
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        # ValueFromPipeline so the documented config-as-code flow actually runs:
        #   Import-PSTSMPlan -Path .\Plans\Nightly.task.json | Register-PSTSMPlan
        # That example ships in the README and in Export-PSTSMPlan's help, and failed at bind
        # time - there was no pipeline binding and no process block, so a piped plan never
        # arrived, and piping several would have registered only the last.
        [Parameter(Mandatory, ValueFromPipeline)]
        [object]$Plan,

        [securestring]$Password,

        [switch]$Force,

        [switch]$PassThru
    )
    process {

        # --- preflight ---------------------------------------------------------------------
        $checks = Test-PSTSMPlan -Plan $Plan
        $errors = @($checks | Where-Object { $_.Severity -eq 'Error' })
        if ($errors.Count -gt 0 -and -not $Force) {
            $detail = ($errors | ForEach-Object { "  [$($_.Id)] $($_.Title): $($_.Detail)" }) -join [Environment]::NewLine
            throw ("Preflight failed with $($errors.Count) error(s). Fix them or use -Force:" + [Environment]::NewLine + $detail)
        }
        foreach ($w in @($checks | Where-Object { $_.Severity -eq 'Warning' })) {
            Write-Warning "[$($w.Id)] $($w.Title): $($w.Detail)"
        }

        if ($Plan.Principal.LogonType -eq 'Password' -and -not $Password) {
            throw "Principal.LogonType is 'Password' but no -Password was supplied. For a group managed service account use LogonType 'gMSA', which needs none."
        }

        # --- action ------------------------------------------------------------------------
        # An 'Executable' plan is a bare command line - something that is not a .ps1 behind a
        # PowerShell host, or a host invoked with inline -Command. Its three fields go through
        # untouched: no wrapper, no argument generation, no re-quoting. Whatever the operator saw
        # in the form is exactly what gets registered, which is the only honest way to re-save an
        # action this tool did not build.
        if ($Plan.PSObject.Properties['ActionKind'] -and $Plan.ActionKind -eq 'Executable') {
            $actionParams = @{
                Execute = [string]$Plan.RawAction.Execute
            }
            # Passed only when non-empty: New-ScheduledTaskAction writes an empty <Arguments/>
            # element for an empty string, which is a difference from a task that never had one.
            if ($Plan.RawAction.Arguments) { $actionParams['Argument'] = [string]$Plan.RawAction.Arguments }
            if ($Plan.RawAction.WorkingDirectory) { $actionParams['WorkingDirectory'] = [string]$Plan.RawAction.WorkingDirectory }
            $action = New-ScheduledTaskAction @actionParams
        }
        else {
            $targetScript = $Plan.ScriptPath
            if ($Plan.Logging -and $Plan.Logging.Mode -eq 'Transcript') {
                $targetScript = New-PSTSMLogWrapper -Plan $Plan
                Write-Verbose "Action targets log wrapper: $targetScript"
            }

            $argumentString = ConvertTo-PSTSMArgument -ScriptPath $targetScript `
                -Parameters $Plan.Parameters `
                -ExtraArguments $Plan.ExtraArguments `
                -ExecutionPolicy $Plan.ExecutionPolicy `
                -NoProfile $Plan.NoProfile `
                -NonInteractive $Plan.NonInteractive `
                -WindowStyle $Plan.WindowStyle `
                -SwitchDefaultTrue $Plan.SwitchDefaultTrue

            $actionParams = @{
                Execute  = $Plan.EnginePath
                Argument = $argumentString
            }
            if ($Plan.WorkingDirectory) { $actionParams['WorkingDirectory'] = $Plan.WorkingDirectory }
            $action = New-ScheduledTaskAction @actionParams
        }

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

        # --- register ----------------------------------------------------------------------
        $newTaskParams = @{
            Action    = $action
            Principal = $principal
            Settings  = $settings
        }
        if ($triggers.Count -gt 0) { $newTaskParams['Trigger'] = $triggers }
        if ($Plan.Description) { $newTaskParams['Description'] = $Plan.Description }

        $definition = New-ScheduledTask @newTaskParams

        $target = "$($Plan.TaskPath)$($Plan.TaskName)"
        if (-not $PSCmdlet.ShouldProcess($target, 'Register scheduled task')) { return }

        $registerParams = @{
            TaskName    = $Plan.TaskName
            TaskPath    = $Plan.TaskPath
            InputObject = $definition
            Force       = $true
        }
        $bstr = [IntPtr]::Zero
        try {
            if ($Plan.Principal.LogonType -eq 'Password') {
                # The BSTR has to be zero-freed, not just abandoned. Without this the cleartext
                # password stays in the process heap until something happens to overwrite it.
                #
                # Being honest about the limit of this: Register-ScheduledTask takes -Password as a
                # System.String, so a managed cleartext copy exists regardless and cannot be wiped.
                # Zero-freeing the BSTR removes the copy we are responsible for; it does not make the
                # password absent from memory. Registering through the elevated helper is the better
                # answer, because that process is short-lived.
                $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
                $registerParams['User'] = $Plan.Principal.UserId
                $registerParams['Password'] = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            }

            $registered = Register-ScheduledTask @registerParams
        }
        finally {
            if ($bstr -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
        }

        if ($PassThru) { $registered }
    }
}

function ConvertTo-PSTSMCimTrigger {
    <#
    .SYNOPSIS
        Converts one New-PSTSMTriggerSpec object into the CIM trigger instance
        Register-ScheduledTask expects.
    .PARAMETER Spec
        A PSTSM.TriggerSpec object.
    .OUTPUTS
        A scheduled task trigger CIM instance.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Spec
    )

    $at = if ($Spec.At) { [datetime]::Parse($Spec.At, [System.Globalization.CultureInfo]::InvariantCulture) } else { $null }

    $params = @{}
    switch ($Spec.Type) {
        'Once' { $params['Once'] = $true; $params['At'] = $at }
        'Daily' { $params['Daily'] = $true; $params['At'] = $at; $params['DaysInterval'] = $Spec.DaysInterval }
        'Weekly' {
            $params['Weekly'] = $true; $params['At'] = $at
            $params['DaysOfWeek'] = $Spec.DaysOfWeek
            $params['WeeksInterval'] = $Spec.WeeksInterval
        }
        'AtStartup' { $params['AtStartup'] = $true }
        'AtLogOn' {
            $params['AtLogOn'] = $true
            if ($Spec.UserId) { $params['User'] = $Spec.UserId }
        }
        'OnIdle' {
            # New-ScheduledTaskTrigger has no -OnIdle; build the CIM class directly.
            $idle = New-CimInstance -CimClass (Get-CimClass -ClassName MSFT_TaskIdleTrigger `
                    -Namespace Root/Microsoft/Windows/TaskScheduler) -ClientOnly
            $idle.Enabled = [bool]$Spec.Enabled
            return $idle
        }
        default { throw "Unsupported trigger type '$($Spec.Type)'." }
    }

    # Time-based triggers randomise with RandomDelay; boot and logon triggers take a fixed Delay.
    # They are different CIM properties on different classes, and the cmdlet does NOT map one to
    # the other: MSFT_TaskBootTrigger and MSFT_TaskLogonTrigger have Delay and no RandomDelay at
    # all. Passing -RandomDelay to -AtStartup is accepted without error and simply produces a
    # trigger with Delay empty, so the operator's delay was discarded in silence - and the
    # trigger dialog offers that field for exactly those two types.
    $isFixedDelay = $Spec.Type -in @('AtStartup', 'AtLogOn')
    $delayValue = if ($isFixedDelay) { $Spec.Delay } else { $Spec.RandomDelay }
    $delaySpan = $null
    if ($delayValue) {
        try { $delaySpan = [timespan]::Parse($delayValue) }
        catch { Write-Warning "Ignoring unparseable delay '$delayValue' on $($Spec.Type) trigger." }
    }
    # RandomDelay can go in as a cmdlet parameter; Delay has to be set on the instance afterwards.
    if ($delaySpan -and -not $isFixedDelay) { $params['RandomDelay'] = $delaySpan }

    $trigger = New-ScheduledTaskTrigger @params
    $trigger.Enabled = [bool]$Spec.Enabled

    if ($delaySpan -and $isFixedDelay) {
        # ISO 8601 duration: the CIM property is a string, not a TimeSpan.
        $trigger.Delay = [System.Xml.XmlConvert]::ToString($delaySpan)
    }

    if ($Spec.RepetitionInterval) {
        # New-ScheduledTaskTrigger only accepts -RepetitionInterval alongside -Once, so build a
        # throwaway Once trigger and lift its Repetition block onto this one. This is the
        # supported way to repeat a Daily/Weekly/Boot trigger.
        $repParams = @{
            Once               = $true
            At                 = (Get-Date)
            RepetitionInterval = [timespan]::Parse($Spec.RepetitionInterval)
        }
        if ($Spec.RepetitionDuration -and $Spec.RepetitionDuration -ne 'Indefinitely') {
            $repParams['RepetitionDuration'] = [timespan]::Parse($Spec.RepetitionDuration)
        }
        $trigger.Repetition = (New-ScheduledTaskTrigger @repParams).Repetition
    }

    $trigger
}
