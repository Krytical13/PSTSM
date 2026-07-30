# SPDX-License-Identifier: GPL-3.0-or-later
function Test-PSTSMPlanNeedsElevation {
    <#
    .SYNOPSIS
        Reports whether registering this plan needs an administrator token.
    .DESCRIPTION
        The Task Scheduler service refuses a short, specific list of registrations when the
        caller's token is un-elevated. This is that list, and it is behaviour that was measured
        rather than inferred: with a genuine UAC-filtered token (TokenElevationType=3,
        TokenIsElevated=0), RunLevel=Limited registers and RunLevel=Highest comes back
        "Access is denied".

        Everything absent from this list - a task that runs as you at normal privilege, and the
        whole read-only surface - works without elevation, which is why PSTSM does not ask for a
        UAC prompt merely to open.

        Keep this the single definition. Test-PSTSMPlan reports it to the operator and
        Invoke-PSTSMElevatedRegistration acts on it; if the two ever disagree, the tool either
        elevates for nothing or lets a registration fail with a bare "Access is denied".
    .PARAMETER Plan
        A task plan.
    .OUTPUTS
        [string[]] Human-readable reasons, empty when no elevation is needed.
    .EXAMPLE
        if (Test-PSTSMPlanNeedsElevation -Plan $plan) { ... }
    #>
    [OutputType([string[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Plan
    )

    $reasons = @()
    if ($Plan.Principal.RunLevel -eq 'Highest') { $reasons += 'it runs with highest privileges' }
    if ($Plan.Principal.LogonType -eq 'ServiceAccount') { $reasons += "it runs as $($Plan.Principal.UserId)" }
    if ($Plan.Principal.LogonType -eq 'Group') { $reasons += 'it runs for a group' }
    # A boot trigger is Administrators-only too, per the RegisterTaskDefinition reference.
    if (@($Plan.Triggers | Where-Object { $_ -and $_.Type -eq 'AtStartup' }).Count -gt 0) {
        $reasons += 'it has an at-startup trigger'
    }
    # Emitted unwrapped on purpose. A leading comma would preserve the array through the
    # pipeline, but for an EMPTY result it yields a one-element array containing an empty array -
    # so "nothing needs elevation" would read as one reason. Callers wrap in @() instead.
    $reasons
}

function Test-PSTSMElevated {
    <#
    .SYNOPSIS
        True when this session holds an administrator token.
    .DESCRIPTION
        Deliberately a function rather than an inline check so tests can stub it, and so the
        answer is computed the same way everywhere.

        This asks whether the token is elevated, not whether the account is an administrator.
        The distinction is the whole point: an administrator's ordinary window carries a filtered
        token that Windows treats as un-elevated, and that is the case PSTSM has to handle.
    .OUTPUTS
        [bool]
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param()

    (New-Object System.Security.Principal.WindowsPrincipal(
            [System.Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-PSTSMElevatedRegistration {
    <#
    .SYNOPSIS
        Registers a task plan through a short-lived elevated helper, behind one consent prompt.
    .DESCRIPTION
        Windows offers no way to elevate a process that is already running - elevation happens at
        process creation and nowhere else. So "elevate at the moment of saving" has to mean
        "start something elevated that does the saving", which is Microsoft's documented
        Administrator Broker Model. This is the parent half of it.

        The alternative would be relaunching the whole tool elevated, which throws away whatever
        the operator was editing and asks for far more privilege than one registration needs.

        What crosses the boundary is plain and inspectable: a plan file that Export-PSTSMPlan
        already guarantees holds no secret, and a reply file. A stored-password task is the only
        case needing a credential and the helper prompts for that itself, so the password lives
        only inside the elevated process that consumes it.

        Both files are written to a private directory under the user's temp and deleted
        afterwards - including when the helper crashes, and including when the operator dismisses
        the consent prompt.
    .PARAMETER Plan
        The task plan to register.
    .PARAMETER RemoveTaskName
        A task to unregister once the save succeeds. Set this when a rename would otherwise
        leave the original registration behind.
    .PARAMETER RemoveTaskPath
        Folder of -RemoveTaskName.
    .PARAMETER TimeoutSeconds
        How long to wait for the helper. The default is generous because the operator may be
        typing a password into it.
    .PARAMETER HelperPath
        Override the helper script location. Present for tests.
    .OUTPUTS
        [pscustomobject] with Success, Error, Cancelled, Warnings, TaskName, TaskPath, RanAs.
    .EXAMPLE
        $r = Invoke-PSTSMElevatedRegistration -Plan $plan
        if (-not $r.Success -and -not $r.Cancelled) { Write-Error $r.Error }
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)]
        [object]$Plan,

        [string]$RemoveTaskName,

        [string]$RemoveTaskPath,

        [ValidateRange(5, 3600)]
        [int]$TimeoutSeconds = 600,

        [string]$HelperPath
    )

    $result = [pscustomobject]@{
        Success   = $false
        Cancelled = $false
        Error     = $null
        Warnings  = @()
        TaskName  = $Plan.TaskName
        TaskPath  = $Plan.TaskPath
        RanAs     = $null
    }

    if (-not $HelperPath) {
        # Functions/Task/... -> module root
        $HelperPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'PSTSM.Elevate.ps1'
    }
    if (-not (Test-Path -LiteralPath $HelperPath -PathType Leaf)) {
        $result.Error = "Elevation helper not found: $HelperPath"
        return $result
    }

    if (-not $PSCmdlet.ShouldProcess("$($Plan.TaskPath)$($Plan.TaskName)", 'Register elevated')) {
        return $result
    }

    # A private directory rather than loose files in %TEMP%: it keeps the two files together and
    # makes cleanup a single delete that cannot miss one of them.
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ("PSTSM_elev_" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $work -Force
    $planPath = Join-Path $work 'plan.json'
    $replyPath = Join-Path $work 'reply.json'

    try {
        Export-PSTSMPlan -Plan $Plan -Path $planPath -Confirm:$false

        # Windows PowerShell, not $PSHOME: the helper is 5.1-compatible and this keeps the
        # elevated child on a predictable engine regardless of what is hosting the UI.
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }

        $helperArgs = @(
            '-NoProfile'
            '-ExecutionPolicy', 'Bypass'
            '-File', $HelperPath
            '-PlanPath', $planPath
            '-ResultPath', $replyPath
        )
        # A helper that has to ask for a password must be visible. Hiding its window would leave
        # the operator waiting on a prompt they cannot see until the timeout expires - and whether
        # PromptForCredential draws a GUI dialog or falls back to the console depends on the
        # ConsolePrompting registry value, so this cannot rely on it being a dialog.
        $needsPassword = $Plan.Principal.LogonType -eq 'Password'
        if ($needsPassword) { $helperArgs += '-PromptForPassword' }
        if ($RemoveTaskName) {
            $helperArgs += @('-RemoveTaskName', $RemoveTaskName)
            if ($RemoveTaskPath) { $helperArgs += @('-RemoveTaskPath', $RemoveTaskPath) }
        }

        # Quote every argument as one string. Start-Process quotes an array inconsistently
        # between engines, and a path with a space would otherwise arrive split in two.
        $argLine = ($helperArgs | ForEach-Object {
                if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
            }) -join ' '

        try {
            $startArgs = @{
                FilePath     = $psExe
                ArgumentList = $argLine
                Verb         = 'RunAs'
                PassThru     = $true
                ErrorAction  = 'Stop'
                WindowStyle  = if ($needsPassword) { 'Normal' } else { 'Hidden' }
            }
            $proc = Start-Process @startArgs
        }
        catch [System.ComponentModel.Win32Exception] {
            # 1223 ERROR_CANCELLED is the operator dismissing the UAC prompt. That is a decision,
            # not a fault, so it is reported separately and the caller stays silent about it.
            if ($_.Exception.NativeErrorCode -eq 1223) {
                $result.Cancelled = $true
                return $result
            }
            throw
        }

        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            $result.Error = "The elevated helper did not finish within $TimeoutSeconds seconds."
            # Best effort: it may have exited between the wait timing out and this call.
            try { $proc.Kill() } catch { Write-Verbose "Could not stop the helper: $($_.Exception.Message)" }
            return $result
        }

        if (-not (Test-Path -LiteralPath $replyPath)) {
            $result.Error = "The elevated helper exited with code $($proc.ExitCode) without reporting back."
            return $result
        }

        $reply = Get-Content -LiteralPath $replyPath -Raw | ConvertFrom-Json
        $result.Success = [bool]$reply.Success
        $result.Error = $reply.Error
        $result.Warnings = @($reply.Warnings)
        $result.RanAs = $reply.RanAs
        if ($reply.TaskName) { $result.TaskName = $reply.TaskName }
        if ($reply.TaskPath) { $result.TaskPath = $reply.TaskPath }
        if (-not $result.Success -and -not $result.Error) {
            $result.Error = "The elevated helper failed at stage '$($reply.Stage)'."
        }
        return $result
    }
    catch {
        $result.Error = $_.Exception.Message
        return $result
    }
    finally {
        # The plan file describes a scheduled task in full; there is no reason to leave it lying
        # in the temp directory once the helper has read it. Failing to clean up must not turn a
        # successful registration into a reported failure, so this only ever gets a verbose note.
        try {
            if (Test-Path -LiteralPath $work) {
                Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Stop
            }
        }
        catch {
            Write-Verbose "Could not remove the temporary directory $work : $($_.Exception.Message)"
        }
    }
}
