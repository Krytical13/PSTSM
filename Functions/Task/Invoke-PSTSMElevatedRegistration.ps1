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

function Start-PSTSMBrokerProcess {
    <#
    .SYNOPSIS
        Launches the elevated helper and waits for it. The one impure step of the broker.
    .DESCRIPTION
        Split out for a reason: everything after this call - cancellation, timeout, reply
        parsing, the stage fallback, temp cleanup - was untestable while the process launch was
        inline, because exercising any of it meant a real consent prompt and a real elevated
        child. With this as a seam the whole downstream path is covered offline.

        ProcessStartInfo rather than Start-Process, so the ShellExecute failure arrives intact.
        Start-Process wraps it in an InvalidOperationException and discards the Win32Exception,
        which made the cancellation branch unreachable: declining the prompt - the single most
        likely outcome of showing one - fell through to the generic handler and put an error
        dialog on screen for what is simply the operator saying no.
    .PARAMETER FilePath
        Executable to launch.
    .PARAMETER Arguments
        Fully quoted argument string.
    .PARAMETER Visible
        Show the window. Required when the helper has to prompt for a password, since a hidden
        prompt would just hang until the timeout.
    .PARAMETER ReplyPath
        Where the helper is expected to write its reply. Polled briefly after exit.
    .PARAMETER TimeoutSeconds
        How long to wait before giving up and killing the child.
    .OUTPUTS
        [pscustomobject] ExitCode, Exited, ReplyWritten.
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Arguments,
        [switch]$Visible,
        [Parameter(Mandatory)][string]$ReplyPath,
        [int]$TimeoutSeconds = 600
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $true          # required for the runas verb, and precludes redirection
    $psi.Verb = 'runas'
    $psi.WindowStyle = if ($Visible) {
        [System.Diagnostics.ProcessWindowStyle]::Normal
    }
    else {
        [System.Diagnostics.ProcessWindowStyle]::Hidden
    }

    $proc = [System.Diagnostics.Process]::Start($psi)
    $exited = $proc.WaitForExit($TimeoutSeconds * 1000)
    if (-not $exited) {
        # Best effort: it may have exited between the wait timing out and this call.
        try { $proc.Kill() } catch { Write-Verbose "Could not stop the helper: $($_.Exception.Message)" }
    }

    # The helper writes its reply from a finally block, so give the filesystem a moment rather
    # than declaring "exited without reporting back" on a race.
    $replyWritten = $false
    if ($exited) {
        for ($i = 0; $i -lt 20; $i++) {
            if (Test-Path -LiteralPath $ReplyPath) { $replyWritten = $true; break }
            Start-Sleep -Milliseconds 50
        }
    }

    [pscustomobject]@{
        ExitCode     = if ($exited) { $proc.ExitCode } else { $null }
        Exited       = $exited
        ReplyWritten = $replyWritten
    }
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
    .PARAMETER ScheduleOnly
        Apply the plan's schedule to an already-registered task and leave its action untouched,
        instead of replacing the whole task. For an action PSTSM will not rewrite.
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

        [switch]$ScheduleOnly,

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
        if ($ScheduleOnly) { $helperArgs += '-ScheduleOnly' }
        if ($RemoveTaskName) {
            $helperArgs += @('-RemoveTaskName', $RemoveTaskName)
            if ($RemoveTaskPath) { $helperArgs += @('-RemoveTaskPath', $RemoveTaskPath) }
        }

        # Quote every argument as one string. Start-Process quotes an array inconsistently
        # between engines, and a path with a space would otherwise arrive split in two.
        #
        # Uses the module's own encoder rather than a local one. The local version escaped quotes
        # but not backslash runs, so a value ending in a backslash - and RemoveTaskPath always
        # does, being a task folder - emitted "\My Tasks\" , where the trailing backslash escapes
        # the closing quote. The unregister then failed, and because a failed cleanup is only a
        # warning, the old privileged task kept firing alongside its replacement.
        $argLine = ($helperArgs | ForEach-Object { ConvertTo-PSTSMQuotedValue -Value $_ }) -join ' '

        try {
            $outcome = Start-PSTSMBrokerProcess -FilePath $psExe -Arguments $argLine `
                -Visible:$needsPassword -ReplyPath $replyPath -TimeoutSeconds $TimeoutSeconds
        }
        catch {
            # Unwrap before testing. PowerShell wraps any exception thrown by a .NET METHOD call
            # in a MethodInvocationException, so `catch [Win32Exception]` never matched and the
            # cancellation branch was unreachable - confirmed on a real machine, where declining
            # consent surfaced as MethodInvocationException with the Win32Exception one level
            # down. This is the same trap that made Start-Process unusable here; swapping to
            # ProcessStartInfo fixed the discarded inner exception but not the wrapping.
            $win32 = $null
            $ex = $_.Exception
            while ($ex) {
                if ($ex -is [System.ComponentModel.Win32Exception]) { $win32 = $ex; break }
                $ex = $ex.InnerException
            }

            # 1223 ERROR_CANCELLED is the operator dismissing the UAC prompt. That is a decision,
            # not a fault, so it is reported separately and the caller stays silent about it.
            if ($win32 -and $win32.NativeErrorCode -eq 1223) {
                $result.Cancelled = $true
                return $result
            }

            # Anything else is a real failure, but the raw text is unhelpful on its own - 1060
            # ("service does not exist") is what a disabled Application Information service looks
            # like, and nobody would guess that from the message.
            $result.Error = if ($win32) {
                "Could not start the elevated helper: $($win32.Message) (Win32 $($win32.NativeErrorCode))." +
                $(if ($win32.NativeErrorCode -eq 1060) {
                        ' The Application Information service handles elevation; if it is disabled, no UAC prompt can appear.'
                    })
            }
            else { $_.Exception.Message }
            return $result
        }

        if (-not $outcome.Exited) {
            $result.Error = "The elevated helper did not finish within $TimeoutSeconds seconds."
            return $result
        }

        if (-not (Test-Path -LiteralPath $replyPath)) {
            $result.Error = "The elevated helper exited with code $($outcome.ExitCode) without reporting back."
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
