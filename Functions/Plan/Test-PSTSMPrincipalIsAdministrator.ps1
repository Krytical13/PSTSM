# SPDX-License-Identifier: GPL-3.0-or-later
function Test-PSTSMPrincipalIsAdministrator {
    <#
    .SYNOPSIS
        Is this account an administrator of this machine? Returns $null when it cannot be known.
    .DESCRIPTION
        Exists to answer one question honestly: will "Run with highest privileges" actually give
        this task anything?

        RunLevel HIGHEST maps to the XML value HighestAvailable, and the name is literal - the
        task runs at the highest privilege AVAILABLE TO ITS PRINCIPAL. For an account that is not
        an administrator there is no higher level to reach, so the setting is a no-op. The task
        runs with exactly the same rights either way, and a script that needed elevation still
        fails - just later, and with a worse error.

        Three-valued on purpose. $null means "could not determine", and callers must stay silent
        rather than guess: telling somebody their domain account is not an administrator because a
        directory lookup timed out would be worse than saying nothing at all.

        Membership is checked by SID, and nested groups are followed one level - a domain account
        is far more often an administrator through Domain Admins or a workstation-admins group
        than by being listed directly.
    .PARAMETER UserId
        The account to test, in any form Windows can resolve: DOMAIN\user, user@domain,
        .\localuser, a bare name, or a SID.
    .OUTPUTS
        [bool] or $null when undeterminable.
    .EXAMPLE
        Test-PSTSMPrincipalIsAdministrator -UserId 'CONTOSO\alice'
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$UserId
    )

    if ([string]::IsNullOrWhiteSpace($UserId)) { return $null }

    # Resolve to a SID first. Everything below compares SIDs, because account NAMES are localised
    # and formatted half a dozen ways, and because a SID is the only form that survives a rename.
    $sid = $null
    try {
        $sid = if ($UserId -match '^S-1-') { $UserId }
        else { (New-Object System.Security.Principal.NTAccount($UserId)).Translate(
                [System.Security.Principal.SecurityIdentifier]).Value }
    }
    catch {
        Write-Verbose "Could not resolve '$UserId' to a SID: $($_.Exception.Message)"
        return $null
    }

    # SYSTEM is already the most privileged principal on the machine; the others are deliberately
    # minimal and cannot be made administrators by this question.
    if ($sid -eq 'S-1-5-18') { return $true }
    if ($sid -in @('S-1-5-19', 'S-1-5-20')) { return $false }

    try {
        # Resolve the group by SID and pipe the OBJECT through. Translating the SID to a name
        # yields "BUILTIN\Administrators", and Get-LocalGroupMember rejects that qualified form
        # outright - so every lookup failed and this function answered "unknown" for everybody,
        # which would have made the check that consumes it permanently silent.
        # -SID also sidesteps the localised group name, which was the original reason for not
        # hardcoding "Administrators".
        $members = @(Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop |
                Get-LocalGroupMember -ErrorAction Stop)
    }
    catch {
        Write-Verbose "Could not read the local Administrators group: $($_.Exception.Message)"
        return $null
    }

    foreach ($m in $members) {
        if ($m.SID.Value -eq $sid) { return $true }
    }

    # One level of nesting. Anything deeper is a directory question this tool has no business
    # asking, and getting it wrong in the confident direction is the failure mode to avoid.
    foreach ($m in $members) {
        if ($m.ObjectClass -ne 'Group') { continue }
        try {
            $nested = @(Get-ADGroupMember -Identity $m.SID.Value -Recursive -ErrorAction Stop)
            if ($nested | Where-Object { $_.SID.Value -eq $sid }) { return $true }
        }
        catch {
            # No directory, no rights to read it, or not a domain group. Cannot rule membership
            # in OR out from here, so the whole answer becomes "unknown".
            Write-Verbose "Could not expand nested group $($m.Name): $($_.Exception.Message)"
            return $null
        }
    }

    $false
}
