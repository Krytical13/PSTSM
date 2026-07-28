function Test-PSTaskPlan {
    <#
    .SYNOPSIS
        Preflights a task plan and returns the reasons it would fail at 3am rather than now.
    .DESCRIPTION
        Every check answers the same question: "this script works when I run it in my console -
        will it still work when Task Scheduler runs it?" The gap between those two is where
        scheduled PowerShell actually breaks, and it is almost always one of:

          - a prompt nobody is there to answer
          - S4U having no network credentials
          - a module that is only installed in your user profile
          - a working directory that is not what you assumed
          - a script that never sets an exit code, so the task reports success forever

        Severities: Error blocks registration. Warning is a real risk the operator should
        acknowledge. Info is context. Ok is a check that passed and is worth showing.
    .PARAMETER Plan
        A New-PSTaskPlan object.
    .PARAMETER ScriptProfile
        Pre-computed Get-PSTaskScriptProfile output. Re-derived from the plan if omitted.
    .PARAMETER SkipExistingTaskCheck
        Do not query Task Scheduler for a name collision. Used by tests and by offline
        plan validation.
    .OUTPUTS
        [pscustomobject] Id, Severity, Title, Detail, Recommendation
    .EXAMPLE
        Test-PSTaskPlan -Plan $plan | Where-Object Severity -in 'Error','Warning'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Plan,

        [object]$ScriptProfile,

        [switch]$SkipExistingTaskCheck
    )

    $results = New-Object System.Collections.Generic.List[object]

    function Add-PSTaskCheck($id, $severity, $title, $detail, $recommendation) {
        $results.Add([PSCustomObject]@{
                PSTypeName     = 'PSTaskBuilder.CheckResult'
                Id             = $id
                Severity       = $severity
                Title          = $title
                Detail         = $detail
                Recommendation = $recommendation
            })
    }

    # --- script present and parseable ---------------------------------------------------
    if (-not (Test-Path -LiteralPath $Plan.ScriptPath -PathType Leaf)) {
        Add-PSTaskCheck 'SCRIPT_MISSING' 'Error' 'Script not found' `
            "No file at $($Plan.ScriptPath)." `
            'Pick the script again, or move it to a path the scheduled account can read.'
        return $results.ToArray()
    }

    if (-not $ScriptProfile) {
        $ScriptProfile = Get-PSTaskScriptProfile -Path $Plan.ScriptPath -DefaultEngineId $Plan.EngineId
    }

    if (-not $ScriptProfile.IsParseable) {
        Add-PSTaskCheck 'SCRIPT_PARSE' 'Error' 'Script does not parse' `
            ($ScriptProfile.ParseErrors -join '; ') `
            'Fix the syntax errors; the task would fail immediately on every run.'
    }

    # --- engine ------------------------------------------------------------------------
    if (-not $Plan.EnginePath -or -not (Test-Path -LiteralPath $Plan.EnginePath -PathType Leaf)) {
        Add-PSTaskCheck 'ENGINE_MISSING' 'Error' 'PowerShell engine not found' `
            "No executable at '$($Plan.EnginePath)'." `
            'Choose an engine that exists on the machine this task will run on.'
    }
    else {
        Add-PSTaskCheck 'ENGINE_OK' 'Ok' 'Engine resolved' "$($Plan.EnginePath)" $null
    }

    if ($ScriptProfile.RequiredVersion) {
        $needsCore = ([version]$ScriptProfile.RequiredVersion).Major -ge 6
        if ($needsCore -and $Plan.EngineId -eq 'powershell') {
            Add-PSTaskCheck 'ENGINE_VERSION' 'Error' 'Engine cannot satisfy #Requires' `
                "Script requires PowerShell $($ScriptProfile.RequiredVersion) but the task targets Windows PowerShell 5.1." `
                'Switch the engine to pwsh, or remove the requirement.'
        }
    }
    if ($ScriptProfile.RequiredEditions -contains 'Core' -and $Plan.EngineId -eq 'powershell') {
        Add-PSTaskCheck 'ENGINE_EDITION' 'Error' 'Engine edition mismatch' `
            'Script requires PSEdition Core but the task targets Windows PowerShell (Desktop).' `
            'Switch the engine to pwsh.'
    }

    # --- parameters --------------------------------------------------------------------
    $planParamNames = @()
    if ($Plan.Parameters) { $planParamNames = @($Plan.Parameters.Keys) }

    $missingMandatory = @()
    foreach ($sp in $ScriptProfile.Parameters) {
        if (-not $sp.IsMandatory) { continue }
        $supplied = $planParamNames | Where-Object { $_ -eq $sp.Name }
        if (-not $supplied) { $missingMandatory += $sp.Name; continue }
        $v = $Plan.Parameters[$sp.Name]
        if ($null -eq $v -or ($v -is [string] -and $v.Trim() -eq '')) { $missingMandatory += $sp.Name }
    }
    if ($missingMandatory.Count -gt 0) {
        Add-PSTaskCheck 'PARAM_MANDATORY' 'Error' 'Mandatory parameters have no value' `
            ("Not supplied: " + ($missingMandatory -join ', ')) `
            'Fill them in. Unattended, a missing mandatory parameter is a hard failure under -NonInteractive, not a prompt.'
    }

    $knownNames = @($ScriptProfile.Parameters | ForEach-Object { $_.Name })
    $knownNames += @($ScriptProfile.Parameters | ForEach-Object { $_.Aliases } | Where-Object { $_ })
    # Common parameters are always legal even though they are not in the param block.
    $knownNames += @('Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction',
        'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable',
        'OutBuffer', 'PipelineVariable', 'WhatIf', 'Confirm')

    $unknown = @($planParamNames | Where-Object { $n = $_; -not ($knownNames | Where-Object { $_ -eq $n }) })
    if ($unknown.Count -gt 0) {
        Add-PSTaskCheck 'PARAM_UNKNOWN' 'Warning' 'Parameters the script does not declare' `
            ($unknown -join ', ') `
            'Check for a typo. The script will fail to bind and exit before doing any work.'
    }

    $credParams = @($ScriptProfile.Parameters | Where-Object { $_.IsCredential -or $_.IsSecure })
    if ($credParams.Count -gt 0) {
        $mandatoryCred = @($credParams | Where-Object { $_.IsMandatory })
        $sev = if ($mandatoryCred.Count -gt 0) { 'Error' } else { 'Warning' }
        Add-PSTaskCheck 'PARAM_CREDENTIAL' $sev 'Script takes a credential parameter' `
            ("Cannot be passed on a command line: " + (($credParams | ForEach-Object { $_.Name }) -join ', ')) `
            'Have the script read the secret itself (SecretManagement, DPAPI file, or gMSA so it needs none), or run the task as an account that already has the access.'
    }

    # --- interactivity -----------------------------------------------------------------
    if ($ScriptProfile.Signals.InteractiveCommands.Count -gt 0) {
        Add-PSTaskCheck 'INTERACTIVE' 'Warning' 'Script prompts for input' `
            ("Found: " + ($ScriptProfile.Signals.InteractiveCommands -join ', ')) `
            'Unattended there is nobody to answer. With -NonInteractive these throw instead of hanging, so the task fails fast - but it still fails. Parameterise the input.'
    }
    if ($ScriptProfile.Signals.UsesGui) {
        Add-PSTaskCheck 'GUI' 'Warning' 'Script shows a window' `
            'References WinForms/WPF types or a dialog.' `
            'A task running as S4U/SYSTEM has no desktop; the window is invisible and the task never ends.'
    }

    # --- principal ---------------------------------------------------------------------
    $logonType = $Plan.Principal.LogonType
    $networkish = @($ScriptProfile.Signals.NetworkCommands) + @($ScriptProfile.Signals.UncPaths)

    if ($logonType -eq 'S4U' -and $networkish.Count -gt 0) {
        Add-PSTaskCheck 'S4U_NETWORK' 'Warning' 'S4U logon has no network credentials' `
            ("Script reaches the network: " + (($networkish | Select-Object -First 6) -join ', ')) `
            "This is the single most common cause of 'works when I run it, fails on the schedule'. Use a stored password, a gMSA, or SYSTEM if machine-account access is enough."
    }
    elseif ($logonType -eq 'S4U') {
        Add-PSTaskCheck 'S4U_OK' 'Ok' 'S4U logon is appropriate' 'No outbound network calls detected.' $null
    }

    if ($logonType -in @('S4U', 'Password')) {
        Add-PSTaskCheck 'BATCH_RIGHT' 'Info' 'Account needs "Log on as a batch job"' `
            "$($Plan.Principal.UserId) must hold SeBatchLogonRight on this machine." `
            'Usually granted already for admins; enforced by GPO in locked-down environments. Registration fails with 0x80070534 if it is missing.'
    }
    if ($logonType -eq 'Password') {
        Add-PSTaskCheck 'PASSWORD_ROTATION' 'Info' 'Stored password will expire' `
            'The task stops running the next time this account rotates its password.' `
            'Prefer a gMSA where the domain supports it - it rotates itself and stores nothing.'
    }

    if ($ScriptProfile.RequiresElevation -and $Plan.Principal.RunLevel -ne 'Highest') {
        Add-PSTaskCheck 'ELEVATION' 'Error' 'Script requires elevation' `
            "'#Requires -RunAsAdministrator' is present but the task runs with RunLevel $($Plan.Principal.RunLevel)." `
            'Tick "Run with highest privileges".'
    }

    # --- modules -----------------------------------------------------------------------
    foreach ($m in $ScriptProfile.RequiredModules) {
        $found = @(Get-Module -ListAvailable -Name $m.Name -ErrorAction SilentlyContinue)
        if ($found.Count -eq 0) {
            Add-PSTaskCheck 'MODULE_MISSING' 'Error' "Required module not installed: $($m.Name)" `
                "'#Requires -Modules $($m.Name)' cannot be satisfied on this machine." `
                'Install it for AllUsers (Install-Module -Scope AllUsers) so every account can load it.'
            continue
        }

        $userScopeOnly = -not (@($found | Where-Object { $_.ModuleBase -notlike "$env:USERPROFILE*" }).Count -gt 0)
        if ($userScopeOnly) {
            Add-PSTaskCheck 'MODULE_USERSCOPE' 'Warning' "Module only installed for you: $($m.Name)" `
                "Found only under $env:USERPROFILE." `
                'A task running as SYSTEM, a gMSA, or another user will not see it. Reinstall with -Scope AllUsers.'
        }
        else {
            Add-PSTaskCheck 'MODULE_OK' 'Ok' "Module available machine-wide: $($m.Name)" $null $null
        }
    }

    # --- encoding ----------------------------------------------------------------------
    if ($Plan.EngineId -eq 'powershell' -and $ScriptProfile.Encoding.HasNonAscii -and -not $ScriptProfile.Encoding.HasBom) {
        Add-PSTaskCheck 'ENCODING' 'Warning' 'UTF-8 without BOM under Windows PowerShell' `
            'The file contains non-ASCII bytes and has no byte-order mark.' `
            'Windows PowerShell 5.1 reads BOM-less files as ANSI, so those characters will be mangled at run time even though the file looks correct in an editor. Re-save as UTF-8 with BOM.'
    }

    # --- exit codes --------------------------------------------------------------------
    if (-not $ScriptProfile.Signals.HasExitStatement) {
        Add-PSTaskCheck 'EXIT_CODE' 'Warning' 'Script never sets an exit code' `
            'No exit or throw statement found.' `
            "Task Scheduler will record 'Last Run Result: 0x0' whether the script worked or not, so a broken task looks healthy. Add an exit code, or leave logging on Transcript so there is something to read."
    }

    # --- paths -------------------------------------------------------------------------
    if ($Plan.WorkingDirectory -and -not (Test-Path -LiteralPath $Plan.WorkingDirectory -PathType Container)) {
        Add-PSTaskCheck 'WORKDIR' 'Warning' 'Working directory does not exist' `
            $Plan.WorkingDirectory `
            'Task Scheduler does not create it; the action fails with 0x2 (file not found).'
    }

    if ($Plan.ScriptPath -like "$env:USERPROFILE*" -and $Plan.Principal.LogonType -eq 'ServiceAccount') {
        Add-PSTaskCheck 'SCRIPT_IN_PROFILE' 'Warning' 'Script lives in your user profile' `
            "$($Plan.ScriptPath) runs as $($Plan.Principal.UserId)." `
            'SYSTEM and service accounts cannot reliably read another user profile. Move the script somewhere machine-wide such as C:\Scripts.'
    }
    if ($Plan.ScriptPath -match '^\\\\') {
        Add-PSTaskCheck 'SCRIPT_ON_UNC' 'Warning' 'Script is on a network share' `
            $Plan.ScriptPath `
            'The share must be readable by the task account at run time - and S4U cannot authenticate to it at all. Prefer a local copy.'
    }

    # --- triggers ----------------------------------------------------------------------
    if (-not $Plan.Triggers -or @($Plan.Triggers).Count -eq 0) {
        Add-PSTaskCheck 'NO_TRIGGERS' 'Warning' 'Task has no triggers' `
            'It will only ever run when started by hand.' `
            'Add at least one trigger, or keep it deliberately as a manual/on-demand task.'
    }

    # --- settings sanity ---------------------------------------------------------------
    if ($Plan.Settings.DisallowStartIfOnBatteries) {
        Add-PSTaskCheck 'BATTERY' 'Info' 'Task will be skipped on battery' `
            'DisallowStartIfOnBatteries is on.' `
            'Fine for a server; on a laptop this silently skips runs.'
    }
    if (-not $Plan.Settings.ExecutionTimeLimit -or $Plan.Settings.ExecutionTimeLimit -eq '00:00:00') {
        Add-PSTaskCheck 'NO_TIMEOUT' 'Info' 'No execution time limit' `
            'A wedged run will hold the task in Running indefinitely.' `
            'With MultipleInstances = IgnoreNew that blocks every later run until someone notices.'
    }

    # --- name collision ----------------------------------------------------------------
    if (-not $SkipExistingTaskCheck) {
        try {
            $existing = Get-ScheduledTask -TaskName $Plan.TaskName -TaskPath $Plan.TaskPath -ErrorAction SilentlyContinue
            if ($existing) {
                Add-PSTaskCheck 'TASK_EXISTS' 'Info' 'A task with this name already exists' `
                    "$($Plan.TaskPath)$($Plan.TaskName)" `
                    'Registering will overwrite it. Use Export-PSTaskPlan first if you want a way back.'
            }
        }
        catch { Write-Verbose "Could not query Task Scheduler for an existing task: $($_.Exception.Message)" }
    }

    $results.ToArray()
}
