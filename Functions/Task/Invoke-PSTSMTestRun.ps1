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
    .PARAMETER Plan
        The plan to run. Only ScriptPath, EnginePath, ArgumentString and WorkingDirectory are used.
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

        [ValidateRange(5, 3600)]
        [int]$TimeoutSeconds = 120
    )

    $result = [pscustomobject]@{
        Command   = "$($Plan.EnginePath) $($Plan.ArgumentString)"
        RanAs     = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        ExitCode  = $null
        ExitText  = $null
        Output    = ''
        Duration  = [timespan]::Zero
        TimedOut  = $false
        Started   = $false
        Error     = $null
    }

    if (-not $PSCmdlet.ShouldProcess($Plan.ScriptPath, 'Run once now')) { return $result }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Plan.EnginePath
    $psi.Arguments = $Plan.ArgumentString
    # Redirection requires UseShellExecute = $false, which is also what keeps the console hidden.
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ($Plan.WorkingDirectory -and (Test-Path -LiteralPath $Plan.WorkingDirectory)) {
        $psi.WorkingDirectory = $Plan.WorkingDirectory
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
