# SPDX-License-Identifier: GPL-3.0-or-later
function Test-PSTSMGmsaPrerequisite {
    <#
    .SYNOPSIS
        Checks whether this machine and forest can create and use a group managed service
        account, and reports what is missing.
    .DESCRIPTION
        gMSA setup fails in a handful of predictable ways, each with an unhelpful error and each
        documented on a different page. This gathers them into one answer before anything is
        written to the directory:

          - RSAT ActiveDirectory module present (nothing works without it)
          - the session is elevated (Install-ADServiceAccount requires it)
          - a domain controller is reachable
          - forest schema is 2012 or later (gMSAs did not exist before)
          - the KDS root key exists AND is already effective

        The KDS root key is the one people trip over. It is a one-time, forest-wide,
        Enterprise Admin operation, and a key created with -EffectiveImmediately is not usable
        for about ten hours while it replicates - so a gMSA created immediately afterwards fails
        to install with a misleading error. This reports the key's effective time rather than
        just its existence, which is the difference between "you have a key" and "you can use
        one".
    .OUTPUTS
        [pscustomobject] Id, Severity, Title, Detail, Recommendation - the same shape
        Test-PSTSMPlan returns, so the UI renders both with one code path.
    .EXAMPLE
        Test-PSTSMGmsaPrerequisite | Where-Object Severity -in 'Error','Warning'
    #>
    [CmdletBinding()]
    param()

    $results = New-Object System.Collections.Generic.List[object]

    function Add-GmsaCheck($id, $severity, $title, $detail, $recommendation) {
        $results.Add([PSCustomObject]@{
                PSTypeName     = 'PSTSM.CheckResult'
                Id             = $id
                Severity       = $severity
                Title          = $title
                Detail         = $detail
                Recommendation = $recommendation
            })
    }

    # --- RSAT ---------------------------------------------------------------------------
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue)) {
        Add-GmsaCheck 'GMSAPRE_RSAT' 'Error' 'ActiveDirectory module not installed' `
            'Nothing here can run without it.' `
            'Install RSAT AD PowerShell: Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0 (client), or Install-WindowsFeature RSAT-AD-PowerShell (server).'
        return $results.ToArray()
    }
    Add-GmsaCheck 'GMSAPRE_RSAT_OK' 'Ok' 'ActiveDirectory module available' $null $null

    # --- elevation ----------------------------------------------------------------------
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $elevated = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($elevated) {
        Add-GmsaCheck 'GMSAPRE_ELEVATED_OK' 'Ok' 'Running elevated' $null $null
    }
    else {
        Add-GmsaCheck 'GMSAPRE_ELEVATED' 'Warning' 'Not running elevated' `
            'Creating the account may work, but Install-ADServiceAccount will not.' `
            'Restart the tool as administrator to complete the whole sequence in one go.'
    }

    Add-GmsaCheck 'GMSAPRE_WHOAMI' 'Info' 'Creating as your own account' `
        "$($identity.Name) - the tool passes no credentials of its own." `
        'You need rights to create msDS-GroupManagedServiceAccount objects in the target OU. Domain Admins and Account Operators have this by default; otherwise it must be delegated.'

    # --- domain reachable ---------------------------------------------------------------
    $rootDse = $null
    try { $rootDse = Get-ADRootDSE -ErrorAction Stop }
    catch { Write-Verbose "Get-ADRootDSE failed: $($_.Exception.Message)" }

    if (-not $rootDse) {
        Add-GmsaCheck 'GMSAPRE_NODC' 'Error' 'No domain controller reachable' `
            'Get-ADRootDSE returned nothing.' `
            'This machine must be domain-joined and able to reach a DC. gMSAs are a domain feature; there is no local equivalent.'
        return $results.ToArray()
    }
    Add-GmsaCheck 'GMSAPRE_DC_OK' 'Ok' 'Domain controller reachable' "$($rootDse.dnsHostName)" $null

    # --- schema version -----------------------------------------------------------------
    # objectVersion 56 is Windows Server 2012, the release that introduced gMSAs.
    try {
        $schema = Get-ADObject -Identity $rootDse.schemaNamingContext -Properties objectVersion -ErrorAction Stop
        if ([int]$schema.objectVersion -lt 56) {
            Add-GmsaCheck 'GMSAPRE_SCHEMA' 'Error' 'Forest schema predates gMSA support' `
                "Schema objectVersion is $($schema.objectVersion); 56 (Windows Server 2012) is the minimum." `
                'The schema must be upgraded before any gMSA can exist.'
        }
        else {
            Add-GmsaCheck 'GMSAPRE_SCHEMA_OK' 'Ok' 'Forest schema supports gMSAs' "objectVersion $($schema.objectVersion)" $null
        }
    }
    catch {
        Add-GmsaCheck 'GMSAPRE_SCHEMA_UNKNOWN' 'Info' 'Could not read the schema version' `
            $_.Exception.Message 'Not fatal; creation will fail clearly if the schema is too old.'
    }

    # --- KDS root key -------------------------------------------------------------------
    # Read the container directly rather than using Get-KdsRootKey, which lives in the Kds
    # module and is not present with RSAT AD PowerShell alone.
    $keyContainer = "CN=Master Root Keys,CN=Group Key Distribution Service,CN=Services,$($rootDse.configurationNamingContext)"
    $keys = @()
    try {
        $keys = @(Get-ADObject -SearchBase $keyContainer -Filter { objectClass -eq 'msKds-ProvRootKey' } `
                -Properties msKds-CreateTime, msKds-UseStartTime, whenCreated -ErrorAction Stop)
    }
    catch { Write-Verbose "Could not read KDS root keys: $($_.Exception.Message)" }

    if ($keys.Count -eq 0) {
        Add-GmsaCheck 'GMSAPRE_NOKDSKEY' 'Error' 'No KDS root key in this forest' `
            ('The KDS root key is a single secret, created once per forest, that domain controllers use to ' +
            'COMPUTE gMSA passwords. Without it the directory cannot generate a password for any gMSA, so ' +
            'creation fails. You only need it if nobody has ever created a gMSA in this forest - if any gMSA ' +
            'already exists, the key does too and you never think about it again.') `
            ('Run once, by an Enterprise Admin:  Add-KdsRootKey -EffectiveImmediately' + [Environment]::NewLine +
            'Despite the name it becomes usable after about 10 hours - that delay lets it replicate to every DC ' +
            'before anything depends on it. This tool will not run it for you, because a button that appears to ' +
            'succeed and then does nothing for 10 hours is worse than no button.' + [Environment]::NewLine +
            'The -EffectiveTime ((Get-Date).AddHours(-10)) trick you will find online skips the wait; it is safe ' +
            'only in a single-DC lab, since it can hand out a key the other DCs do not have yet.')
        return $results.ToArray()
    }

    $effective = @($keys | Where-Object {
            $start = $_.'msKds-UseStartTime'
            $start -and ([datetime]::FromFileTimeUtc([int64]$start) -le [datetime]::UtcNow)
        })

    if ($effective.Count -gt 0) {
        Add-GmsaCheck 'GMSAPRE_KDS_OK' 'Ok' 'KDS root key present and effective' `
            "$($keys.Count) key(s) found, $($effective.Count) already usable." $null
    }
    else {
        $soonest = ($keys | ForEach-Object {
                if ($_.'msKds-UseStartTime') { [datetime]::FromFileTimeUtc([int64]$_.'msKds-UseStartTime') }
            } | Sort-Object | Select-Object -First 1)
        Add-GmsaCheck 'GMSAPRE_KDS_PENDING' 'Warning' 'KDS root key exists but is not effective yet' `
            $(if ($soonest) { "Usable from $($soonest.ToLocalTime()) local time." } else { 'No usable start time could be read.' }) `
            'A gMSA created now will not install until the key is effective. This is the ten-hour replication window after Add-KdsRootKey, and it is the most common cause of a brand-new gMSA failing to install.'
    }

    $results.ToArray()
}
