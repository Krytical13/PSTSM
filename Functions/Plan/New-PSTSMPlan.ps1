# SPDX-License-Identifier: GPL-3.0-or-later
function New-PSTSMPlan {
    <#
    .SYNOPSIS
        Produces a complete, serialisable scheduled-task plan from a script path, filling in
        every field that can be derived and leaving the rest at defaults that work.
    .DESCRIPTION
        The plan is the single object the UI binds to, Test-PSTSMPlan validates,
        Register-PSTSMPlan applies, and Export-PSTSMPlan writes to JSON. Nothing downstream
        reads the script again.

        Defaults are chosen to be right for the common case rather than to mirror Task
        Scheduler's own defaults, which are tuned for interactive desktop tasks:

          MultipleInstances  IgnoreNew  - a slow run must not stack on top of itself.
          StartWhenAvailable $true      - catch up after the machine was off at the run time.
          ExecutionTimeLimit 4h         - Task Scheduler's default is 3 days; a wedged task
                                          then blocks every later run until someone notices.
          RestartCount       3 / 5 min  - transient DC or network blips resolve themselves.
          Batteries          allowed    - the Task Scheduler default silently skips runs on
                                          any laptop, which is a classic "why didn't it run".

        The default principal is S4U ('run whether logged on or not', no stored password).
        That is the usual intent, but it holds no network credentials - Test-PSTSMPlan raises
        that specifically when the script's signals show outbound calls.
    .PARAMETER ScriptPath
        Path to the .ps1 the task will run.
    .PARAMETER ScriptProfile
        Pre-computed Get-PSTSMScriptProfile output. Supply it to avoid re-parsing.
    .PARAMETER TaskName
        Defaults to the script's base name.
    .PARAMETER TaskPath
        Task Scheduler folder. Default '\'. A dedicated folder like '\Custom\' keeps your tasks
        away from the Microsoft tree.
    .PARAMETER Description
        Defaults to the script's .SYNOPSIS.
    .PARAMETER EngineId
        'powershell' or 'pwsh'. Defaults to the profile's derived engine.
    .PARAMETER EnginePath
        Explicit engine executable. Defaults to the best match for EngineId on this machine.
    .PARAMETER Parameters
        Ordered dictionary of script parameter values.
    .PARAMETER ExtraArguments
        Verbatim text appended after generated parameters.
    .PARAMETER WorkingDirectory
        Defaults to the script's own folder, so relative paths inside the script resolve the
        way they do when you run it by hand.
    .PARAMETER Trigger
        One or more New-PSTSMTriggerSpec objects.
    .PARAMETER UserId
        Account to run as. Defaults to the current user.
    .PARAMETER LogonType
        Interactive, S4U, Password, gMSA, ServiceAccount (SYSTEM/LOCAL SERVICE/NETWORK SERVICE),
        or Group. Default S4U.

        gMSA registers as LogonType Password but supplies NO password - Task Scheduler retrieves
        the managed one from the directory. It is modelled separately from Password precisely so
        the "a password is required" rule does not apply to it.
    .PARAMETER RunLevel
        Limited or Highest. Defaults to Highest when the script has
        '#Requires -RunAsAdministrator', otherwise Limited.
    .PARAMETER Settings
        Hashtable overriding any of the reliability defaults.
    .PARAMETER Logging
        Hashtable overriding logging: Mode ('Transcript' or 'None'), Directory, RetentionDays.
    .OUTPUTS
        [pscustomobject] PSTSM.TaskPlan
    .EXAMPLE
        $plan = New-PSTSMPlan -ScriptPath .\Send-UserPassExpMail.ps1 `
                               -Parameters ([ordered]@{ DaysOut = 14 }) `
                               -Trigger (New-PSTSMTriggerSpec -Type Daily -At '07:00')
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory plan object only. Register-PSTSMPlan is the command that changes system state, and it does support ShouldProcess.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ParameterSetName = 'FromPath')]
        [string]$ScriptPath,

        [Parameter(Mandatory, ParameterSetName = 'FromProfile')]
        [object]$ScriptProfile,

        [string]$TaskName,
        [string]$TaskPath = '\',
        [string]$Description,

        [ValidateSet('powershell', 'pwsh')]
        [string]$EngineId,
        [string]$EnginePath,

        [System.Collections.IDictionary]$Parameters,
        [string]$ExtraArguments,
        [string]$WorkingDirectory,

        [object[]]$Trigger,

        [string]$UserId,

        [ValidateSet('Interactive', 'S4U', 'Password', 'gMSA', 'ServiceAccount', 'Group')]
        [string]$LogonType = 'S4U',

        [ValidateSet('Limited', 'Highest')]
        [string]$RunLevel,

        [hashtable]$Settings,
        [hashtable]$Logging
    )

    if (-not $ScriptProfile) {
        $ScriptProfile = Get-PSTSMScriptProfile -Path $ScriptPath
    }

    $resolvedEngineId = if ($EngineId) { $EngineId } else { $ScriptProfile.EngineId }

    $resolvedEnginePath = $EnginePath
    if (-not $resolvedEnginePath) {
        $candidates = @(Get-PSTSMEngine -Id $resolvedEngineId)
        # Prefer 64-bit; the list is already ordered newest-first.
        $pick = @($candidates | Where-Object { $_.Bitness -eq 'x64' } | Select-Object -First 1)
        if (-not $pick) { $pick = @($candidates | Select-Object -First 1) }
        $resolvedEnginePath = if ($pick) { $pick[0].Path } else { $null }
    }

    # Start from the script's declared defaults so the form opens populated, then let explicit
    # -Parameters win. Defaults that are expressions (e.g. (Get-Date)) are left unset rather
    # than evaluated - the script will apply them itself at run time.
    $resolvedParameters = [ordered]@{}
    foreach ($p in $ScriptProfile.Parameters) {
        if ($p.IsCredential -or $p.IsSecure) { continue }
        if (-not $p.HasDefault) { continue }

        # Only LITERAL defaults are seeded. An expression default - even one whose value is
        # known, like (Join-Path $PSScriptRoot 'settings.psd1') - is deliberately left out, so
        # the script evaluates it at run time. Passing it would freeze anything time-dependent
        # and put a value on the command line that the operator never chose.
        if ($p.DefaultKind -ne 'Literal') { continue }
        $resolvedParameters[$p.Name] = $p.ResolvedDefault.Value
    }
    if ($Parameters) {
        foreach ($k in $Parameters.Keys) { $resolvedParameters[$k] = $Parameters[$k] }
    }

    # Re-order to match the script's own param() block so the generated command line and the
    # form read the same way the script is written. Seeding defaults first would otherwise put
    # a defaulted parameter ahead of a mandatory one that was supplied afterwards.
    $orderedParameters = [ordered]@{}
    foreach ($p in $ScriptProfile.Parameters) {
        if ($resolvedParameters.Contains($p.Name)) { $orderedParameters[$p.Name] = $resolvedParameters[$p.Name] }
    }
    # Anything the script does not declare (common parameters, typos) keeps its position at
    # the end rather than being silently dropped - Test-PSTSMPlan reports on it.
    foreach ($k in $resolvedParameters.Keys) {
        if (-not $orderedParameters.Contains($k)) { $orderedParameters[$k] = $resolvedParameters[$k] }
    }
    $resolvedParameters = $orderedParameters

    # Switches the script declares as [switch]$X = $true need special handling on the command
    # line: leaving one off does NOT turn it off, it lets the script's own default turn it ON.
    # Only -X:$false will do it. ConvertTo-PSTSMArgument has always known that, but it could only
    # learn which switches those were from a -ScriptProfile that no production caller passed - so
    # unticking such a box in the editor silently registered a task that still ran with it on.
    #
    # Carried on the plan rather than re-derived at registration, so it survives export/import
    # and does not need the script to still be readable on the machine doing the registering.
    $switchDefaultTrue = @($ScriptProfile.Parameters | Where-Object {
            $_.IsSwitch -and $_.HasDefault -and $_.DefaultKind -eq 'Literal' -and
            $null -ne $_.ResolvedDefault -and [bool]$_.ResolvedDefault.Value
        } | ForEach-Object { $_.Name })

    $defaultSettings = [ordered]@{
        MultipleInstances          = 'IgnoreNew'
        StartWhenAvailable         = $true
        ExecutionTimeLimit         = '04:00:00'
        RestartCount               = 3
        RestartInterval            = '00:05:00'
        DisallowStartIfOnBatteries = $false
        StopIfGoingOnBatteries     = $false
        RunOnlyIfNetworkAvailable  = $false
        RunOnlyIfIdle              = $false
        WakeToRun                  = $false
        Hidden                     = $false
        AllowDemandStart           = $true
        DontStopOnIdleEnd          = $true
        Priority                   = 7
        Compatibility              = 'Win8'
    }
    if ($Settings) {
        foreach ($k in $Settings.Keys) {
            if (-not $defaultSettings.Contains($k)) {
                Write-Warning "Unknown setting '$k' - it will be ignored at registration."
            }
            $defaultSettings[$k] = $Settings[$k]
        }
    }

    $defaultLogging = [ordered]@{
        Mode          = 'Transcript'
        Directory     = Join-Path $ScriptProfile.Directory 'Logs'
        RetentionDays = 30
    }
    if ($Logging) {
        foreach ($k in $Logging.Keys) { $defaultLogging[$k] = $Logging[$k] }
    }

    $resolvedRunLevel = if ($RunLevel) { $RunLevel } elseif ($ScriptProfile.RequiresElevation) { 'Highest' } else { 'Limited' }
    $resolvedUserId = if ($UserId) { $UserId } else { "$env:USERDOMAIN\$env:USERNAME" }

    # ServiceAccount principals are built-in SIDs and always run elevated; RunLevel is not
    # meaningful for them and setting it produces a confusing task.
    if ($LogonType -eq 'ServiceAccount') { $resolvedRunLevel = 'Highest' }

    $normalisedTaskPath = $TaskPath
    if (-not $normalisedTaskPath.StartsWith('\')) { $normalisedTaskPath = '\' + $normalisedTaskPath }
    if (-not $normalisedTaskPath.EndsWith('\')) { $normalisedTaskPath = $normalisedTaskPath + '\' }

    $plan = [PSCustomObject]@{
        PSTypeName       = 'PSTSM.TaskPlan'
        SchemaVersion    = 1

        TaskName         = if ($TaskName) { $TaskName } else { $ScriptProfile.SuggestedTaskName }
        TaskPath         = $normalisedTaskPath
        Description      = if ($PSBoundParameters.ContainsKey('Description')) { $Description } else { $ScriptProfile.Synopsis }

        ScriptPath       = $ScriptProfile.Path
        EngineId         = $resolvedEngineId
        EnginePath       = $resolvedEnginePath
        WorkingDirectory = if ($WorkingDirectory) { $WorkingDirectory } else { $ScriptProfile.SuggestedWorkDir }

        Parameters       = $resolvedParameters
        ExtraArguments   = $ExtraArguments

        # Engine switches. Exposed so the UI can surface them, but changing them off the
        # defaults is the exception, not the rule.
        NoProfile        = $true
        NonInteractive   = $true
        ExecutionPolicy  = 'Bypass'
        WindowStyle      = 'Hidden'

        Triggers         = if ($Trigger) { @($Trigger) } else { @() }

        Principal        = [ordered]@{
            UserId    = if ($LogonType -eq 'ServiceAccount' -and -not $UserId) { 'SYSTEM' } else { $resolvedUserId }
            LogonType = $LogonType
            RunLevel  = $resolvedRunLevel
        }

        Settings         = $defaultSettings
        Logging          = $defaultLogging

        # Names of [switch]$X = $true parameters. Rendering needs these to emit -X:$false.
        SwitchDefaultTrue = @($switchDefaultTrue)

        Source           = [ordered]@{
            EngineConfidence = $ScriptProfile.EngineConfidence
            EngineReason     = $ScriptProfile.EngineReason
            DerivedFrom      = $ScriptProfile.Path
        }
    }

    # Convenience: the exact command line, recomputed on read so the preview pane can never
    # drift from what will actually be registered.
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
