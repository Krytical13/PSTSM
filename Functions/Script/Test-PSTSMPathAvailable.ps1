# SPDX-License-Identifier: GPL-3.0-or-later
function Test-PSTSMPathAvailable {
    <#
    .SYNOPSIS
        Does this path exist? - answered without letting an unreachable share hang the caller.
    .DESCRIPTION
        Test-Path against a UNC path whose server is gone does not fail quickly. It blocks for the
        full SMB/TCP timeout, measured here at 42 SECONDS on one unroutable address. That is not a
        slow check, it is a hang, and it happens on the UI thread: Get-PSTSMInventory asks it once
        per row, so a single task pointing at a decommissioned file server froze the whole list.
        Test-PSTSMPlan asks it seven more times, so the editor froze too.

        Local paths - the overwhelming majority - keep the plain synchronous call, which costs
        0.29ms. Only a UNC path gets the bounded treatment: the probe runs on its own runspace and
        the caller waits a fixed budget for it, after which the answer is $null.

        $null means "could not determine", which is deliberately NOT the same as $false. Reporting
        a file as missing because the network was slow would send someone to fix a script that was
        never broken; callers are expected to say "could not verify" instead.

        Answers are memoised briefly, because the list re-asks about every row on every refresh and
        the second stall is as bad as the first. The window is short enough that reconnecting a VPN
        shows up on the next refresh rather than requiring a restart.
    .PARAMETER Path
        The path to test. Empty or null yields $null.
    .PARAMETER PathType
        Any, Leaf or Container - as Test-Path.
    .PARAMETER TimeoutMs
        How long to wait for a network path before giving up and answering $null.
    .PARAMETER Force
        Ignore any memoised answer.
    .OUTPUTS
        [bool] or $null when it could not be determined.
    .EXAMPLE
        switch (Test-PSTSMPathAvailable -Path $p -PathType Leaf) {
            $true   { 'there' }
            $false  { 'missing' }
            default { 'could not check - network path did not answer' }
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Path,

        [ValidateSet('Any', 'Leaf', 'Container')]
        [string]$PathType = 'Any',

        [ValidateRange(100, 60000)]
        [int]$TimeoutMs = 2000,

        [switch]$Force
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    # A rooted \\server\share, not a \\?\ or \\.\ device path - those are local and must not be
    # pushed down the slow branch.
    $isNetwork = $Path -match '^\\\\[^\\?.]'

    if (-not $isNetwork) {
        try { return [bool](Test-Path -LiteralPath $Path -PathType $PathType) }
        catch {
            # An invalid path shape, or a provider that refused. Unknown, not missing.
            Write-Verbose "Test-Path failed for '$Path': $($_.Exception.Message)"
            return $null
        }
    }

    if (-not $script:PSTSMPathCache) { $script:PSTSMPathCache = @{} }
    if (-not $script:PSTSMPathProbes) { $script:PSTSMPathProbes = New-Object System.Collections.ArrayList }

    # Dispose any earlier probe that has since finished. Deliberately opportunistic: a probe that
    # timed out is still blocked inside SMB, and calling Dispose on it would block this thread for
    # exactly as long as the wait we just refused to do.
    for ($i = $script:PSTSMPathProbes.Count - 1; $i -ge 0; $i--) {
        $p = $script:PSTSMPathProbes[$i]
        if ($p.Handle.IsCompleted) {
            try { $null = $p.Shell.EndInvoke($p.Handle); $p.Shell.Dispose() } catch { }
            $script:PSTSMPathProbes.RemoveAt($i)
        }
    }

    $key = "$PathType|$Path"
    $ttl = 30
    $hit = $script:PSTSMPathCache[$key]
    if (-not $Force -and $hit -and (([System.Diagnostics.Stopwatch]::GetTimestamp() - $hit.Stamp) /
            [System.Diagnostics.Stopwatch]::Frequency) -lt $ttl) {
        return $hit.Result
    }

    $result = $null
    $shell = [powershell]::Create()
    try {
        $null = $shell.AddScript({
                param($p, $t)
                try { Test-Path -LiteralPath $p -PathType $t } catch { $null }
            }).AddArgument($Path).AddArgument($PathType)

        $handle = $shell.BeginInvoke()
        if ($handle.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            $out = $shell.EndInvoke($handle)
            if ($out -and $out.Count -gt 0 -and $null -ne $out[0]) { $result = [bool]$out[0] }
            $shell.Dispose()
        }
        else {
            # Stop() asks politely; it cannot interrupt a thread parked in a blocking socket call.
            # So the runspace is parked until SMB gives up on its own - which is fine, because
            # nothing waits on it. It is queued for disposal instead of leaked.
            try { $null = $shell.BeginStop($null, $null) } catch { }
            $null = $script:PSTSMPathProbes.Add(@{ Shell = $shell; Handle = $handle })
            Write-Verbose "Network path '$Path' did not answer within ${TimeoutMs}ms; reporting unknown."
        }
    }
    catch {
        Write-Verbose "Could not probe '$Path': $($_.Exception.Message)"
        try { $shell.Dispose() } catch { }
    }

    $script:PSTSMPathCache[$key] = @{
        Stamp  = [System.Diagnostics.Stopwatch]::GetTimestamp()
        Result = $result
    }
    $result
}
