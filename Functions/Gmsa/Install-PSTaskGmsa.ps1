function Install-PSTaskGmsa {
    <#
    .SYNOPSIS
        Prepares THIS machine to run a task as a gMSA: caches the account, verifies it, and
        grants the batch-logon right.
    .DESCRIPTION
        The half of gMSA setup that happens on the host rather than in the directory, and the
        half that is easiest to forget because creating the account looks like the finish line.

        Runs, in order:
          1. Install-ADServiceAccount  - caches the account locally
          2. Test-ADServiceAccount     - confirms the password can actually be retrieved
          3. Grant-PSTaskBatchLogonRight - unless -SkipBatchLogonRight

        The failure worth understanding: if the host was added to the gMSA's
        PrincipalsAllowedToRetrieveManagedPassword through a GROUP, its Kerberos ticket still
        reflects the membership it had at boot, so retrieval fails until it REBOOTS. That is not
        a misconfiguration and no amount of retrying fixes it, so it is reported as such rather
        than as a generic failure.
    .PARAMETER Name
        gMSA name, with or without the trailing '$'.
    .PARAMETER SkipBatchLogonRight
        Do not touch local user rights. Use where rights are managed by Group Policy.
    .OUTPUTS
        [pscustomobject] Name, Installed, Usable, BatchLogonRight, Message
    .EXAMPLE
        Install-PSTaskGmsa -Name 'svc_reports'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [switch]$SkipBatchLogonRight
    )

    if (-not (Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue)) {
        throw 'The ActiveDirectory module is required. Install RSAT AD PowerShell.'
    }
    Import-Module ActiveDirectory -ErrorAction Stop

    $bare = $Name.TrimEnd('$')

    $result = [PSCustomObject]@{
        PSTypeName      = 'PSTaskBuilder.GmsaInstallResult'
        Name            = "$bare`$"
        Installed       = $false
        Usable          = $false
        BatchLogonRight = 'not attempted'
        Message         = $null
    }

    $account = $null
    try { $account = Get-ADServiceAccount -Identity $bare -Properties PrincipalsAllowedToRetrieveManagedPassword -ErrorAction Stop }
    catch { throw "Could not read gMSA '$bare': $($_.Exception.Message)" }

    if (-not $PSCmdlet.ShouldProcess("$env:COMPUTERNAME", "Install and verify gMSA $bare`$")) { return $result }

    # --- cache it locally ----------------------------------------------------------------
    try {
        Install-ADServiceAccount -Identity $bare -ErrorAction Stop
        $result.Installed = $true
    }
    catch {
        $result.Message = "Install-ADServiceAccount failed: $($_.Exception.Message)"
        # Do not return yet - Test-ADServiceAccount usually gives the more diagnostic answer.
        Write-Verbose $result.Message
    }

    # --- can this host actually retrieve the password? -----------------------------------
    try { $result.Usable = [bool](Test-ADServiceAccount -Identity $bare -ErrorAction Stop) }
    catch {
        $result.Usable = $false
        Write-Verbose "Test-ADServiceAccount threw: $($_.Exception.Message)"
    }

    if (-not $result.Usable) {
        $principals = @($account.PrincipalsAllowedToRetrieveManagedPassword)
        $thisComputer = "$env:COMPUTERNAME$"
        $namedDirectly = [bool](@($principals | Where-Object { $_ -match [regex]::Escape($thisComputer) }).Count -gt 0)

        if ($principals.Count -eq 0) {
            $result.Message = "The gMSA has no PrincipalsAllowedToRetrieveManagedPassword, so no host can use it. Set it with Set-ADServiceAccount."
        }
        elseif ($namedDirectly) {
            $result.Message = "This computer is named on the gMSA but the password still could not be retrieved. Check the Microsoft-Windows-Security-Netlogon/Operational log, and confirm the KDS root key is effective (a key created with -EffectiveImmediately is unusable for about 10 hours)."
        }
        else {
            $result.Message = ("This computer is not named directly on the gMSA - access is presumably via a group. " +
                "A group membership only takes effect after the machine gets a new Kerberos ticket, which in practice means a REBOOT. " +
                "If it was just added, reboot and run this again.")
        }
        return $result
    }

    # --- batch logon right ----------------------------------------------------------------
    if ($SkipBatchLogonRight) {
        $result.BatchLogonRight = 'skipped'
    }
    else {
        try {
            $domain = (Get-ADDomain).NetBIOSName
            $granted = Grant-PSTaskBatchLogonRight -Account "$domain\$bare`$" -PassThru -Confirm:$false
            $result.BatchLogonRight = if ($granted.AlreadyHeld) { 'already held' } elseif ($granted.Granted) { 'granted' } else { 'not granted' }
        }
        catch {
            $result.BatchLogonRight = "failed: $($_.Exception.Message)"
        }
    }

    $result.Message = 'Ready. The task can now be registered with this account.'
    $result
}
