# SPDX-License-Identifier: GPL-3.0-or-later
function Get-PSTaskRunAsAccount {
    <#
    .SYNOPSIS
        Lists accounts a task could run as - gMSAs, ordinary/service user accounts, and the
        built-in service principals - with the logon type each one needs.
    .DESCRIPTION
        Backs the account picker. The point is that choosing the account and choosing the logon
        type are the same decision, and getting them out of step is what produces a task that
        will not register: a gMSA needs LogonType gMSA, SYSTEM needs ServiceAccount, a normal
        user needs Password or S4U. Every row here carries its own SuggestedLogonType so the UI
        can set both together.

        Everything runs on the caller's ambient Windows credentials. With no ActiveDirectory
        module or no reachable DC it still returns the built-in principals, so the picker is
        never empty and a workgroup machine is not a dead end.
    .PARAMETER Type
        gMSA, User, BuiltIn, or All (default).
    .PARAMETER Filter
        Substring matched against name and description. Wildcards are added automatically.
        A gMSA/user lookup without a filter is capped by -MaxResults.
    .PARAMETER MaxResults
        Ceiling on directory results per type. Default 200.
    .PARAMETER TestGmsaUsability
        Run Test-ADServiceAccount against each gMSA to report whether THIS machine can retrieve
        its password. Off by default: it is a per-account round trip and needs elevation, so the
        picker only asks for it once something is selected.
    .OUTPUTS
        [pscustomobject] Name, DisplayName, Type, SuggestedLogonType, Description, Enabled,
        UsableHere, Detail
    .EXAMPLE
        Get-PSTaskRunAsAccount -Type gMSA
    .EXAMPLE
        Get-PSTaskRunAsAccount -Type User -Filter 'svc'
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('gMSA', 'User', 'BuiltIn', 'All')]
        [string]$Type = 'All',

        [string]$Filter,

        [ValidateRange(1, 5000)]
        [int]$MaxResults = 200,

        [switch]$TestGmsaUsability
    )

    $out = New-Object System.Collections.Generic.List[object]

    function New-RunAsAccount($name, $display, $kind, $logon, $description, $enabled, $usable, $detail) {
        [PSCustomObject]@{
            PSTypeName         = 'PSTaskBuilder.RunAsAccount'
            Name               = $name
            DisplayName        = $display
            Type               = $kind
            SuggestedLogonType = $logon
            Description        = $description
            Enabled            = $enabled
            UsableHere         = $usable
            Detail             = $detail
        }
    }

    # --- built-ins ------------------------------------------------------------------------
    # Always available, and the correct answer more often than people expect: SYSTEM
    # authenticates on the network as the machine account, which S4U cannot do at all.
    if ($Type -in @('BuiltIn', 'All')) {
        $builtIns = @(
            @{ N = 'SYSTEM'; D = 'Local System'; T = 'Full rights on this machine; authenticates on the network as DOMAIN\COMPUTER$.' }
            @{ N = 'LOCAL SERVICE'; D = 'Local Service'; T = 'Minimal local rights; anonymous on the network.' }
            @{ N = 'NETWORK SERVICE'; D = 'Network Service'; T = 'Minimal local rights; authenticates on the network as DOMAIN\COMPUTER$.' }
        )
        foreach ($b in $builtIns) {
            $out.Add((New-RunAsAccount $b.N $b.D 'BuiltIn' 'ServiceAccount' $b.T $true $true 'Built-in principal. No password, nothing to rotate.'))
        }
    }

    $adAvailable = [bool](Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue)
    if (-not $adAvailable) {
        Write-Verbose 'ActiveDirectory module not present; returning built-in principals only.'
        return ($out.ToArray() | Where-Object { -not $Filter -or $_.Name -like "*$Filter*" })
    }
    try { Import-Module ActiveDirectory -ErrorAction Stop } catch { return $out.ToArray() }

    $domainNetbios = $null
    try { $domainNetbios = (Get-ADDomain -ErrorAction Stop).NetBIOSName }
    catch {
        Write-Verbose "No domain reachable: $($_.Exception.Message)"
        return ($out.ToArray() | Where-Object { -not $Filter -or $_.Name -like "*$Filter*" })
    }

    $like = if ($Filter) { "*$Filter*" } else { '*' }

    # --- gMSAs ----------------------------------------------------------------------------
    if ($Type -in @('gMSA', 'All')) {
        try {
            $accounts = @(Get-ADServiceAccount -Filter { Name -like $like } `
                    -Properties Description, Enabled, PrincipalsAllowedToRetrieveManagedPassword, objectClass `
                    -ResultSetSize $MaxResults -ErrorAction Stop)

            foreach ($a in $accounts) {
                # msDS-ManagedServiceAccount is the standalone (single-host) flavour; the group
                # one is msDS-GroupManagedServiceAccount. Both register the same way, but only
                # the group one is usable from more than one machine, so label it honestly.
                $isGroup = ($a.objectClass -eq 'msDS-GroupManagedServiceAccount')
                $kind = if ($isGroup) { 'gMSA' } else { 'sMSA' }

                $usable = $null
                $detail = if ($isGroup) { 'Directory manages the password; this host retrieves it.' }
                else { 'Standalone MSA - tied to a single computer.' }

                if ($TestGmsaUsability) {
                    try { $usable = [bool](Test-ADServiceAccount -Identity $a.SamAccountName.TrimEnd('$') -ErrorAction Stop) }
                    catch { $usable = $null; Write-Verbose "Test-ADServiceAccount failed for $($a.SamAccountName): $($_.Exception.Message)" }

                    if ($usable -eq $false) {
                        $principals = @($a.PrincipalsAllowedToRetrieveManagedPassword)
                        $detail = if ($principals.Count -eq 0) {
                            'No principals may retrieve the password, so no host can use it yet.'
                        }
                        else {
                            'This machine cannot retrieve the password yet. If it was recently added via a group, it needs a reboot to pick up the membership.'
                        }
                    }
                }

                $out.Add((New-RunAsAccount "$domainNetbios\$($a.SamAccountName)" $a.Name $kind 'gMSA' $a.Description $a.Enabled $usable $detail))
            }
        }
        catch { Write-Verbose "gMSA lookup failed: $($_.Exception.Message)" }
    }

    # --- user accounts ---------------------------------------------------------------------
    if ($Type -in @('User', 'All')) {
        try {
            # Unfiltered this is every user in the domain, so it is capped and the picker
            # nudges toward typing a filter.
            $users = @(Get-ADUser -Filter { (Name -like $like) -or (SamAccountName -like $like) } `
                    -Properties Description, Enabled, PasswordNeverExpires `
                    -ResultSetSize $MaxResults -ErrorAction Stop)

            foreach ($u in $users) {
                $detail = if (-not $u.Enabled) { 'Account is DISABLED - a task cannot run as it.' }
                elseif ($u.PasswordNeverExpires) { 'Password never expires, so a stored password will not silently go stale.' }
                else { 'Password expires - a stored-password task stops working when it rotates. Consider a gMSA.' }

                $out.Add((New-RunAsAccount "$domainNetbios\$($u.SamAccountName)" $u.Name 'User' 'Password' $u.Description $u.Enabled $null $detail))
            }
        }
        catch { Write-Verbose "User lookup failed: $($_.Exception.Message)" }
    }

    $out.ToArray()
}
