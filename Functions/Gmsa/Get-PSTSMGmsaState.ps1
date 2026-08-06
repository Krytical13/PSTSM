# SPDX-License-Identifier: GPL-3.0-or-later
function Get-PSTSMGmsaState {
    <#
    .SYNOPSIS
        Reads a gMSA's directory state - does it exist, and can this machine retrieve its password -
        and remembers the answer briefly.
    .DESCRIPTION
        Both questions cost a directory round trip, and Test-PSTSMPlan asks them on every pass. On
        a domain-joined machine editing a gMSA task that meant two DC calls each time the preflight
        ran, which is every refresh of the editor - so on a slow link or over VPN the window
        stalled on the directory while the operator was typing in a field that has nothing to do
        with the account.

        The answers are cached against the identity for a few seconds. That is long enough to
        collapse a burst of refreshes into one lookup, and short enough that creating the account
        in another window and coming back shows the new answer without anyone having to know a
        cache exists. Nothing here is authoritative for longer than that on purpose: a stale "this
        gMSA is fine" is a worse failure than a slow check.
    .PARAMETER Identity
        The gMSA sAMAccountName, with or without the trailing '$' and with or without a domain
        prefix.
    .PARAMETER Force
        Ignore any cached answer and re-read the directory.
    .OUTPUTS
        [pscustomobject] Identity, Exists, Account, Usable, UsableKnown
    .EXAMPLE
        $state = Get-PSTSMGmsaState -Identity 'DOMAIN\svc_reports$'
        if (-not $state.Exists) { 'no such account' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Identity,

        [switch]$Force
    )

    $leaf = (($Identity -split '\\')[-1]).TrimEnd('$')

    if (-not $script:PSTSMGmsaCache) { $script:PSTSMGmsaCache = @{} }

    # Seconds. Short deliberately - see the note above about a stale pass being worse than a slow
    # one. This only has to outlive a burst of keystrokes.
    $ttl = 5

    $hit = $script:PSTSMGmsaCache[$leaf]
    # Stopwatch timestamps, not Get-Date: this compares two moments on the same monotonic clock, so
    # it cannot be thrown off by a clock adjustment mid-session.
    if (-not $Force -and $hit -and (([System.Diagnostics.Stopwatch]::GetTimestamp() - $hit.Stamp) /
            [System.Diagnostics.Stopwatch]::Frequency) -lt $ttl) {
        return $hit.State
    }

    $account = $null
    try { $account = Get-ADServiceAccount -Identity $leaf -ErrorAction Stop }
    catch { Write-Verbose "Get-ADServiceAccount failed for '$leaf': $($_.Exception.Message)" }

    # Only asked when the account exists - there is nothing to test otherwise, and the call is a
    # second round trip. UsableKnown separates "tested and false" from "could not test", which are
    # different things to tell an operator.
    $usable = $null
    $usableKnown = $false
    if ($account) {
        try {
            $usable = Test-ADServiceAccount -Identity $leaf -ErrorAction Stop
            $usableKnown = $true
        }
        catch { Write-Verbose "Test-ADServiceAccount failed for '$leaf': $($_.Exception.Message)" }
    }

    $state = [PSCustomObject]@{
        PSTypeName  = 'PSTSM.GmsaState'
        Identity    = $leaf
        Exists      = [bool]$account
        Account     = $account
        Usable      = $usable
        UsableKnown = $usableKnown
    }

    $script:PSTSMGmsaCache[$leaf] = @{
        Stamp = [System.Diagnostics.Stopwatch]::GetTimestamp()
        State = $state
    }

    $state
}
