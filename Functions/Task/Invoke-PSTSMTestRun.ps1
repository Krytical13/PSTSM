# SPDX-License-Identifier: GPL-3.0-or-later
function Invoke-PSTSMTestRun {
    <#
    .SYNOPSIS
        Runs a plan's command line once, right now, and reports what happened.
    .DESCRIPTION
        The gap this closes: everything else in PSTSM tells you what WILL happen. This tells you
        what DOES. You get the answer before the task exists, rather than at 3am from a Last Run
        Result of 0x1.

        It runs exactly what the preview pane shows - the same engine, the same quoted argument
        string, the same working directory - because a test that runs something slightly different
        is worse than no test at all. In particular the arguments keep -NonInteractive, so a script
        that stops to ask a question fails here the same way it would fail unattended, instead of
        appearing to work because someone was sitting in front of it.

        Two deliberate differences from the registered task, both of which the caller must surface:

        1. It runs as YOU. Impersonating the task's principal - a gMSA, SYSTEM, another user -
           needs credentials this tool does not hold. A script that works for you and fails as
           SYSTEM is exactly the failure this cannot catch, so RanAs is returned to be shown.
        2. It bypasses the transcript wrapper even when logging is on. The wrapper's job is to
           write to the real log directory and prune it; a test should not leave anything there.
           The output is captured here instead.

        Nothing is registered, and nothing is written outside whatever the script itself does -
        which is the operator's business, and the reason the button says "run", not "check".

        One honest limitation, in the OUTPUT only. Windows PowerShell 5.1 writes redirected
        standard output through the console's legacy code page, which cannot represent CJK at all
        and mangles accented Latin. So a script that PRINTS non-ASCII may show approximated
        characters here. Nothing else is affected and it is worth being precise about why:
        arguments reach the script byte-for-byte (verified against a real engine, including
        unicode), and a real task's transcript preserves unicode exactly, because the wrapper
        writes to a file rather than to a pipe. Only this preview is lossy, and only for
        characters the console code page lacks.
        For an 'Executable' plan there is no script and no generated argument string - the action
        IS a command line. That case runs exactly the three fields the editor shows, with no
        re-quoting, which makes it a stricter reproduction than the script path: what runs here is
        character-for-character what Task Scheduler will run.
    .PARAMETER Plan
        The plan to run. For a script plan: ScriptPath, EnginePath, ArgumentString and
        WorkingDirectory. For an Executable plan: the chosen entry of RawActions.
    .PARAMETER ActionIndex
        Which action to run, for a task that runs several programs in order. Ignored for a script
        plan. Only one is run per press, and the caller says which - running all three of a
        three-program task because someone wanted to check the second is not a favour.
    .PARAMETER TimeoutSeconds
        Kill the process after this long. A script that hangs must not hang the window that
        started it.
    .OUTPUTS
        [pscustomobject] with Command, RanAs, ExitCode, ExitText, Output, Duration, TimedOut,
        Started.
    .EXAMPLE
        $r = Invoke-PSTSMTestRun -Plan $plan
        if ($r.ExitCode -ne 0) { $r.Output }
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)]
        [object]$Plan,

        [ValidateRange(0, 31)]
        [int]$ActionIndex = 0,

        [ValidateRange(5, 3600)]
        [int]$TimeoutSeconds = 120
    )

    # What to run, and from where. A script plan renders its command from the engine plus the
    # generated arguments; an executable plan already IS a command line and is used verbatim.
    $isExecPlan = ($Plan.PSObject.Properties['ActionKind'] -and $Plan.ActionKind -eq 'Executable')

    $execTarget = $null
    if ($isExecPlan) {
        $actions = @(
            if ($Plan.PSObject.Properties['RawActions'] -and @($Plan.RawActions).Count -gt 0) { $Plan.RawActions }
            else { $Plan.RawAction }
        )
        $idx = [Math]::Min([Math]::Max($ActionIndex, 0), $actions.Count - 1)
        $execTarget = $actions[$idx]
    }

    $runFile = if ($isExecPlan) { [string]$execTarget.Execute } else { [string]$Plan.EnginePath }
    $runArgs = if ($isExecPlan) { [string]$execTarget.Arguments } else { [string]$Plan.ArgumentString }
    $runDir = if ($isExecPlan) { [string]$execTarget.WorkingDirectory } else { [string]$Plan.WorkingDirectory }

    $result = [pscustomobject]@{
        Command   = (@($runFile, $runArgs) | Where-Object { $_ }) -join ' '
        RanAs     = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        ExitCode  = $null
        ExitText  = $null
        Output    = ''
        Duration  = [timespan]::Zero
        TimedOut  = $false
        Started   = $false
        Error     = $null
    }

    $shouldTarget = if ($isExecPlan) { $runFile } else { $Plan.ScriptPath }
    if (-not $PSCmdlet.ShouldProcess($shouldTarget, 'Run once now')) { return $result }

    if ([string]::IsNullOrWhiteSpace($runFile)) {
        $result.Error = 'This action has no program to run.'
        return $result
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $runFile
    $psi.Arguments = $runArgs
    # Redirection requires UseShellExecute = $false, which is also what keeps the console hidden.
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    # Test-PSTSMPathAvailable, not Test-Path: a working directory on a share that has gone would
    # otherwise block this for the full SMB timeout before the process even starts. An unknown
    # answer means "do not set it" - the process then starts in this one's directory, which is the
    # same thing that happens when the directory is simply absent.
    if ($runDir -and (Test-PSTSMPathAvailable -Path $runDir) -eq $true) {
        $psi.WorkingDirectory = $runDir
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $result.Started = $true

        # Both streams must be drained WHILE the process runs. Waiting first and reading after
        # deadlocks the moment a script writes more than the pipe buffer holds - which for a
        # chatty script is a few kilobytes, so it would work in testing and hang in the field.
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()

        if ($proc.WaitForExit($TimeoutSeconds * 1000)) {
            $result.ExitCode = $proc.ExitCode
            $result.ExitText = ConvertFrom-PSTSMResultCode -Code $proc.ExitCode
        }
        else {
            $result.TimedOut = $true
            try { $proc.Kill() } catch { Write-Verbose "Could not stop the test run: $($_.Exception.Message)" }
        }

        $parts = @()
        $o = $stdout.Result
        $e = $stderr.Result
        if ($o) { $parts += $o.TrimEnd() }
        # Errors are labelled rather than merged. A script whose only output is a red line should
        # not look like it printed nothing.
        if ($e) { $parts += ('--- stderr ---' + [Environment]::NewLine + $e.TrimEnd()) }
        $result.Output = ($parts -join ([Environment]::NewLine + [Environment]::NewLine))
    }
    catch {
        $result.Error = $_.Exception.Message
    }
    finally {
        $sw.Stop()
        $result.Duration = $sw.Elapsed
    }

    $result
}
