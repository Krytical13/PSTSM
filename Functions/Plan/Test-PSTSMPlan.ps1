# SPDX-License-Identifier: GPL-3.0-or-later
function Test-PSTSMPlan {
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
        A New-PSTSMPlan object.
    .PARAMETER ScriptProfile
        Pre-computed Get-PSTSMScriptProfile output. Re-derived from the plan if omitted.
    .PARAMETER SkipExistingTaskCheck
        Do not query Task Scheduler for a name collision. Used by tests and by offline
        plan validation.
    .PARAMETER IsElevated
        Whether the current session holds an administrator token. Defaults to the real answer;
        it is a parameter so the elevation rules can be tested from either side without having
        to run the suite twice under different tokens.
    .PARAMETER CanElevate
        The caller is able to elevate on demand - it will hand the plan to an elevated helper
        rather than register it here. Downgrades NEEDS_ELEVATION from a blocking error to
        information, because with this set the operator has nothing to fix. The UI passes it;
        anything registering in-process must not.
    .OUTPUTS
        [pscustomobject] Id, Severity, Title, Detail, Recommendation
    .EXAMPLE
        Test-PSTSMPlan -Plan $plan | Where-Object Severity -in 'Error','Warning'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Plan,

        [object]$ScriptProfile,

        [switch]$SkipExistingTaskCheck,

        [bool]$IsElevated = (New-Object Security.Principal.WindowsPrincipal(
                [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator),

        [switch]$CanElevate
    )

    $results = New-Object System.Collections.Generic.List[object]

    function Add-PSTSMCheck($id, $severity, $title, $detail, $recommendation) {
        $results.Add([PSCustomObject]@{
                PSTypeName     = 'PSTSM.CheckResult'
                Id             = $id
                Severity       = $severity
                Title          = $title
                Detail         = $detail
                Recommendation = $recommendation
            })
    }

    # --- script present and parseable ---------------------------------------------------
    if (-not (Test-Path -LiteralPath $Plan.ScriptPath -PathType Leaf)) {
        Add-PSTSMCheck 'SCRIPT_MISSING' 'Error' 'Script not found' `
            "No file at $($Plan.ScriptPath)." `
            'Pick the script again, or move it to a path the scheduled account can read.'
        return $results.ToArray()
    }

    if (-not $ScriptProfile) {
        $ScriptProfile = Get-PSTSMScriptProfile -Path $Plan.ScriptPath -DefaultEngineId $Plan.EngineId
    }

    if (-not $ScriptProfile.IsParseable) {
        Add-PSTSMCheck 'SCRIPT_PARSE' 'Error' 'Script does not parse' `
            ($ScriptProfile.ParseErrors -join '; ') `
            'Fix the syntax errors; the task would fail immediately on every run.'
    }

    # --- engine ------------------------------------------------------------------------
    if (-not $Plan.EnginePath -or -not (Test-Path -LiteralPath $Plan.EnginePath -PathType Leaf)) {
        Add-PSTSMCheck 'ENGINE_MISSING' 'Error' 'PowerShell engine not found' `
            "No executable at '$($Plan.EnginePath)'." `
            'Choose an engine that exists on the machine this task will run on.'
    }
    else {
        Add-PSTSMCheck 'ENGINE_OK' 'Ok' 'Engine resolved' "$($Plan.EnginePath)" $null
    }

    if ($ScriptProfile.RequiredVersion) {
        $needsCore = ([version]$ScriptProfile.RequiredVersion).Major -ge 6
        if ($needsCore -and $Plan.EngineId -eq 'powershell') {
            Add-PSTSMCheck 'ENGINE_VERSION' 'Error' 'Engine cannot satisfy #Requires' `
                "Script requires PowerShell $($ScriptProfile.RequiredVersion) but the task targets Windows PowerShell 5.1." `
                'Switch the engine to pwsh, or remove the requirement.'
        }
    }
    if ($ScriptProfile.RequiredEditions -contains 'Core' -and $Plan.EngineId -eq 'powershell') {
        Add-PSTSMCheck 'ENGINE_EDITION' 'Error' 'Engine edition mismatch' `
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
        Add-PSTSMCheck 'PARAM_MANDATORY' 'Error' 'Mandatory parameters have no value' `
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
        Add-PSTSMCheck 'PARAM_UNKNOWN' 'Warning' 'Parameters the script does not declare' `
            ($unknown -join ', ') `
            'Check for a typo. The script will fail to bind and exit before doing any work.'
    }

    $credParams = @($ScriptProfile.Parameters | Where-Object { $_.IsCredential -or $_.IsSecure })
    if ($credParams.Count -gt 0) {
        $mandatoryCred = @($credParams | Where-Object { $_.IsMandatory })
        $sev = if ($mandatoryCred.Count -gt 0) { 'Error' } else { 'Warning' }
        Add-PSTSMCheck 'PARAM_CREDENTIAL' $sev 'Script takes a credential parameter' `
            ("Cannot be passed on a command line: " + (($credParams | ForEach-Object { $_.Name }) -join ', ')) `
            'Have the script read the secret itself (SecretManagement, DPAPI file, or gMSA so it needs none), or run the task as an account that already has the access.'
    }

    # --- interactivity -----------------------------------------------------------------
    if ($ScriptProfile.Signals.InteractiveCommands.Count -gt 0) {
        Add-PSTSMCheck 'INTERACTIVE' 'Warning' 'Script prompts for input' `
            ("Found: " + ($ScriptProfile.Signals.InteractiveCommands -join ', ')) `
            'Unattended there is nobody to answer. With -NonInteractive these throw instead of hanging, so the task fails fast - but it still fails. Parameterise the input.'
    }
    if ($ScriptProfile.Signals.UsesGui) {
        Add-PSTSMCheck 'GUI' 'Warning' 'Script shows a window' `
            'References WinForms/WPF types or a dialog.' `
            'A task running as S4U/SYSTEM has no desktop; the window is invisible and the task never ends.'
    }

    # --- principal ---------------------------------------------------------------------
    $logonType = $Plan.Principal.LogonType
    $networkish = @($ScriptProfile.Signals.NetworkCommands) + @($ScriptProfile.Signals.UncPaths)

    if ($logonType -eq 'S4U' -and $networkish.Count -gt 0) {
        Add-PSTSMCheck 'S4U_NETWORK' 'Warning' 'S4U cannot authenticate to other machines' `
            ("Connectivity itself is fine - sockets, DNS and plain HTTPS all work. What fails is anything " +
            "authenticating AS THIS USER, because an S4U token carries no credentials and presents as ANONYMOUS. " +
            "Found: " + (($networkish | Select-Object -First 6) -join ', ')) `
            ("This is the most common cause of 'works when I run it, fails on the schedule'. Note S4U does NOT fall back to the machine account - " +
            "SYSTEM and NETWORK SERVICE are the ones that authenticate as DOMAIN\COMPUTER`$, which is why SYSTEM is a real alternative here. " +
            'Otherwise use a gMSA, or a stored password.')
    }
    elseif ($logonType -eq 'S4U') {
        Add-PSTSMCheck 'S4U_OK' 'Ok' 'S4U logon is appropriate' 'Nothing that authenticates to another machine was detected.' $null
    }

    if ($logonType -eq 'S4U' -and $ScriptProfile.Signals.DpapiCommands.Count -gt 0) {
        Add-PSTSMCheck 'S4U_DPAPI' 'Warning' 'S4U cannot decrypt DPAPI-protected secrets' `
            ("The user's DPAPI master key is unlocked from their password, and an S4U logon has none - this is the " +
            "'or encrypted files' half of Microsoft's S4U note. Found: " + ($ScriptProfile.Signals.DpapiCommands -join ', ')) `
            ('The secret decrypts by hand and fails on the schedule. Use a stored password, a gMSA (no secret to store), ' +
            'or machine-scoped protection the task account can actually open. A helper function wrapping these calls will not be detected, ' +
            'so check any credential-loading code of your own.')
    }

    if ($logonType -in @('S4U', 'Password', 'gMSA')) {
        Add-PSTSMCheck 'BATCH_RIGHT' 'Info' 'Account needs "Log on as a batch job"' `
            "$($Plan.Principal.UserId) must hold SeBatchLogonRight on this machine." `
            'Usually granted already for admins; enforced by GPO in locked-down environments. Registration fails with 0x80070534 if it is missing. A gMSA almost never has it by default - grant it explicitly.'
    }

    # --- gMSA ---------------------------------------------------------------------------
    if ($logonType -eq 'gMSA') {
        $gmsa = $Plan.Principal.UserId

        if ($gmsa -notmatch '\$$') {
            Add-PSTSMCheck 'GMSA_NAME' 'Warning' 'gMSA name does not end with $' `
                "'$gmsa' looks like a normal account name." `
                "A gMSA is referenced by its sAMAccountName, which ends in '$' - for example DOMAIN\svc_reports$."
        }

        $adAvailable = [bool](Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue)
        if (-not $adAvailable) {
            Add-PSTSMCheck 'GMSA_NO_RSAT' 'Info' 'Cannot verify the gMSA from here' `
                'The ActiveDirectory module is not installed, so the account and this host''s eligibility cannot be checked.' `
                'Install RSAT AD PowerShell to have these checks run, or verify manually with Test-ADServiceAccount on the machine that will run the task.'
        }
        else {
            $leaf = ($gmsa -split '\\')[-1]
            $account = $null
            try { $account = Get-ADServiceAccount -Identity ($leaf.TrimEnd('$')) -ErrorAction Stop }
            catch { Write-Verbose "Get-ADServiceAccount failed for '$leaf': $($_.Exception.Message)" }

            if (-not $account) {
                Add-PSTSMCheck 'GMSA_MISSING' 'Error' 'gMSA not found in the directory' `
                    "No managed service account matching '$leaf' could be read." `
                    'Check the name, or create it first. Note gMSA names are unique per FOREST, not per domain.'
            }
            else {
                # Test-ADServiceAccount answers the question that actually matters: can THIS
                # machine retrieve the password? It needs elevation, and it stays false until
                # the host has a Kerberos ticket reflecting its membership of whatever group is
                # in PrincipalsAllowedToRetrieveManagedPassword - which in practice means a
                # reboot after being added.
                $usable = $null
                try { $usable = Test-ADServiceAccount -Identity $leaf.TrimEnd('$') -ErrorAction Stop }
                catch { Write-Verbose "Test-ADServiceAccount failed: $($_.Exception.Message)" }

                if ($usable -eq $true) {
                    Add-PSTSMCheck 'GMSA_OK' 'Ok' 'This machine can use the gMSA' "$gmsa is installed and retrievable here." $null
                }
                elseif ($usable -eq $false) {
                    Add-PSTSMCheck 'GMSA_NOT_USABLE' 'Error' 'This machine cannot retrieve the gMSA password' `
                        "Test-ADServiceAccount returned false for '$leaf'." `
                        'Add this computer (ideally via a group) to the gMSA''s PrincipalsAllowedToRetrieveManagedPassword, then REBOOT so the host gets a Kerberos ticket carrying the new membership, then run Install-ADServiceAccount.'
                }
                else {
                    Add-PSTSMCheck 'GMSA_UNVERIFIED' 'Info' 'gMSA exists but could not be tested here' `
                        'Test-ADServiceAccount did not return a result - it requires an elevated session.' `
                        'Re-run elevated on the machine that will host the task.'
                }
            }
        }

        Add-PSTSMCheck 'GMSA_NO_SECRET' 'Ok' 'No password to store or rotate' `
            'The directory manages the password and the host retrieves it.' $null
    }
    if ($logonType -eq 'Password') {
        Add-PSTSMCheck 'PASSWORD_ROTATION' 'Info' 'Stored password will expire' `
            'The task stops running the next time this account rotates its password.' `
            'Prefer a gMSA where the domain supports it - it rotates itself and stores nothing.'
    }

    # --- can THIS session register what is being asked for? ------------------------------
    # Verified rather than assumed: with a genuine UAC-filtered token (TokenElevationType=3,
    # TokenIsElevated=0) RunLevel=Limited registers and RunLevel=Highest returns "Access is
    # denied". Windows refuses outright instead of quietly downgrading, so this has to be caught
    # before the operator waits on a save that cannot succeed.
    #
    # Everything off that list - a task that runs as you at normal privilege, plus the entire
    # read-only surface - needs no elevation, which is why PSTSM does not ask for a UAC prompt
    # merely to open.
    if (-not $IsElevated) {
        $needsAdmin = @(Test-PSTSMPlanNeedsElevation -Plan $Plan)

        if ($needsAdmin.Count -gt 0) {
            # Severity depends on whether the caller can actually do something about it. The UI
            # can: it hands the plan to an elevated helper behind one consent prompt, so this is
            # information, not a blocker. A script calling Register-PSTSMPlan directly has no
            # such route, and a clear stop here beats a bare "Access is denied" from the service.
            if ($CanElevate) {
                Add-PSTSMCheck 'NEEDS_ELEVATION' 'Info' 'Saving this task will ask for administrator consent' `
                    ("PSTSM is not running elevated, and $($needsAdmin -join ', and ').") `
                    'Nothing to do - you will get one consent prompt when you save, and your work here is kept.'
            }
            else {
                Add-PSTSMCheck 'NEEDS_ELEVATION' 'Error' 'This task needs administrator rights to register' `
                    ("This session is not elevated, and $($needsAdmin -join ', and ').") `
                    'Run this from an elevated session, or change the account so the task runs as you at normal privilege. Windows rejects the registration outright rather than silently downgrading it.'
            }
        }
    }

    if ($ScriptProfile.RequiresElevation -and $Plan.Principal.RunLevel -ne 'Highest') {
        Add-PSTSMCheck 'ELEVATION' 'Error' 'Script requires elevation' `
            "'#Requires -RunAsAdministrator' is present but the task runs with RunLevel $($Plan.Principal.RunLevel)." `
            'Tick "Run with highest privileges".'
    }

    # --- modules -----------------------------------------------------------------------
    foreach ($m in $ScriptProfile.RequiredModules) {
        $found = @(Get-Module -ListAvailable -Name $m.Name -ErrorAction SilentlyContinue)
        if ($found.Count -eq 0) {
            Add-PSTSMCheck 'MODULE_MISSING' 'Error' "Required module not installed: $($m.Name)" `
                "'#Requires -Modules $($m.Name)' cannot be satisfied on this machine." `
                'Install it for AllUsers (Install-Module -Scope AllUsers) so every account can load it.'
            continue
        }

        $userScopeOnly = -not (@($found | Where-Object { $_.ModuleBase -notlike "$env:USERPROFILE*" }).Count -gt 0)
        if ($userScopeOnly) {
            Add-PSTSMCheck 'MODULE_USERSCOPE' 'Warning' "Module only installed for you: $($m.Name)" `
                "Found only under $env:USERPROFILE." `
                'A task running as SYSTEM, a gMSA, or another user will not see it. Reinstall with -Scope AllUsers.'
        }
        else {
            Add-PSTSMCheck 'MODULE_OK' 'Ok' "Module available machine-wide: $($m.Name)" $null $null
        }
    }

    # --- encoding ----------------------------------------------------------------------
    if ($Plan.EngineId -eq 'powershell' -and $ScriptProfile.Encoding.HasNonAscii -and -not $ScriptProfile.Encoding.HasBom) {
        Add-PSTSMCheck 'ENCODING' 'Warning' 'UTF-8 without BOM under Windows PowerShell' `
            'The file contains non-ASCII bytes and has no byte-order mark.' `
            'Windows PowerShell 5.1 reads BOM-less files as ANSI, so those characters will be mangled at run time even though the file looks correct in an editor. Re-save as UTF-8 with BOM.'
    }

    # --- exit codes --------------------------------------------------------------------
    if (-not $ScriptProfile.Signals.HasExitStatement) {
        Add-PSTSMCheck 'EXIT_CODE' 'Warning' 'Script never sets an exit code' `
            'No exit or throw statement found.' `
            "Task Scheduler will record 'Last Run Result: 0x0' whether the script worked or not, so a broken task looks healthy. Add an exit code, or leave logging on Transcript so there is something to read."
    }

    # --- paths -------------------------------------------------------------------------
    if ($Plan.WorkingDirectory -and -not (Test-Path -LiteralPath $Plan.WorkingDirectory -PathType Container)) {
        Add-PSTSMCheck 'WORKDIR' 'Warning' 'Working directory does not exist' `
            $Plan.WorkingDirectory `
            'Task Scheduler does not create it; the action fails with 0x2 (file not found).'
    }

    if ($Plan.ScriptPath -like "$env:USERPROFILE*" -and $Plan.Principal.LogonType -eq 'ServiceAccount') {
        Add-PSTSMCheck 'SCRIPT_IN_PROFILE' 'Warning' 'Script lives in your user profile' `
            "$($Plan.ScriptPath) runs as $($Plan.Principal.UserId)." `
            'SYSTEM and service accounts cannot reliably read another user profile. Move the script somewhere machine-wide such as C:\Scripts.'
    }
    if ($Plan.ScriptPath -match '^\\\\') {
        Add-PSTSMCheck 'SCRIPT_ON_UNC' 'Warning' 'Script is on a network share' `
            $Plan.ScriptPath `
            'The share must be readable by the task account at run time - and S4U cannot authenticate to it at all. Prefer a local copy.'
    }

    # --- config files -------------------------------------------------------------------
    # A settings file next to the script is a hard dependency of the task, and it fails in
    # exactly the same ways the script does. Task Scheduler will never mention it.
    foreach ($cfg in @($ScriptProfile.ConfigFiles)) {
        # An explicitly supplied path wins over the script's default.
        $effectivePath = $cfg.Path
        $overridden = $false
        if ($Plan.Parameters -and $Plan.Parameters.Contains($cfg.ParameterName)) {
            $supplied = [string]$Plan.Parameters[$cfg.ParameterName]
            if ($supplied) { $effectivePath = $supplied; $overridden = $true }
        }

        $source = if ($overridden) { "supplied via -$($cfg.ParameterName)" } else { "the script's default for -$($cfg.ParameterName)" }

        if (-not (Test-Path -LiteralPath $effectivePath -PathType Leaf)) {
            Add-PSTSMCheck 'CONFIG_MISSING' 'Error' 'Settings file does not exist' `
                "$effectivePath ($source)." `
                'The script reads its configuration from here, so the task fails on the first run. Create it, or point the parameter somewhere else.'
            continue
        }

        if ($cfg.Parses -eq $false -and -not $overridden) {
            Add-PSTSMCheck 'CONFIG_UNPARSEABLE' 'Error' 'Settings file does not parse' `
                "$effectivePath - $($cfg.ParseError)" `
                'The script will throw as soon as it reads this. Fix the file before scheduling.'
            continue
        }

        if ($effectivePath -like "$env:USERPROFILE*") {
            Add-PSTSMCheck 'CONFIG_IN_PROFILE' 'Warning' 'Settings file is in your user profile' `
                "$effectivePath ($source)." `
                "The task account is not you. SYSTEM and service accounts cannot reliably read another user's profile - move it somewhere machine-wide."
        }
        elseif ($effectivePath -match '^\\\\') {
            Add-PSTSMCheck 'CONFIG_ON_UNC' 'Warning' 'Settings file is on a network share' `
                "$effectivePath ($source)." `
                'The task account must be able to read the share at run time - and an S4U logon cannot authenticate to it at all.'
        }
        else {
            $detail = "$effectivePath"
            if ($cfg.Keys -and $cfg.Keys.Count -gt 0) {
                $shown = @($cfg.Keys | Select-Object -First 8) -join ', '
                if ($cfg.Keys.Count -gt 8) { $shown += ", ... ($($cfg.Keys.Count) settings)" }
                $detail += " - $shown"
            }
            Add-PSTSMCheck 'CONFIG_OK' 'Ok' "Settings file found for -$($cfg.ParameterName)" $detail $null
        }
    }

    # --- triggers ----------------------------------------------------------------------
    if (-not $Plan.Triggers -or @($Plan.Triggers).Count -eq 0) {
        Add-PSTSMCheck 'NO_TRIGGERS' 'Warning' 'Task has no triggers' `
            'It will only ever run when started by hand.' `
            'Add at least one trigger, or keep it deliberately as a manual/on-demand task.'
    }

    # --- settings sanity ---------------------------------------------------------------
    if ($Plan.Settings.DisallowStartIfOnBatteries) {
        Add-PSTSMCheck 'BATTERY' 'Info' 'Task will be skipped on battery' `
            'DisallowStartIfOnBatteries is on.' `
            'Fine for a server; on a laptop this silently skips runs.'
    }
    if (-not $Plan.Settings.ExecutionTimeLimit -or $Plan.Settings.ExecutionTimeLimit -eq '00:00:00') {
        Add-PSTSMCheck 'NO_TIMEOUT' 'Info' 'No execution time limit' `
            'A wedged run will hold the task in Running indefinitely.' `
            'With MultipleInstances = IgnoreNew that blocks every later run until someone notices.'
    }

    # --- name collision ----------------------------------------------------------------
    if (-not $SkipExistingTaskCheck) {
        try {
            $existing = Get-ScheduledTask -TaskName $Plan.TaskName -TaskPath $Plan.TaskPath -ErrorAction SilentlyContinue
            if ($existing) {
                Add-PSTSMCheck 'TASK_EXISTS' 'Info' 'A task with this name already exists' `
                    "$($Plan.TaskPath)$($Plan.TaskName)" `
                    'Registering will overwrite it. Use Export-PSTSMPlan first if you want a way back.'
            }
        }
        catch { Write-Verbose "Could not query Task Scheduler for an existing task: $($_.Exception.Message)" }
    }

    $results.ToArray()
}
