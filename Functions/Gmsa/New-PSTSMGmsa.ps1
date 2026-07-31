# SPDX-License-Identifier: GPL-3.0-or-later
function New-PSTSMGmsa {
    <#
    .SYNOPSIS
        Creates a group managed service account, using the caller's own Windows credentials.
    .DESCRIPTION
        A thin, opinionated wrapper over New-ADServiceAccount that supplies the parts people get
        wrong rather than the parts the cmdlet already handles:

          - validates the name against the 15-character sAMAccountName limit BEFORE calling AD,
            because the native failure is a generic constraint violation
          - defaults DNSHostName to <name>.<domain>, which is mandatory and has no default
          - defaults the OU to the forest's Managed Service Accounts container, which is where
            gMSAs are expected to live and which is hidden in ADUC unless Advanced Features is on
          - warns when PrincipalsAllowedToRetrieveManagedPassword names computers rather than a
            group, because that is the choice you regret on the second host

        No credentials are handled or stored. The call runs as whoever is running the tool, so it
        succeeds or fails purely on their own rights - Domain Admins and Account Operators can do
        this by default, otherwise it must be delegated on the target OU.

        Creating the account is only step one. The host that will run the task still needs
        Install-PSTSMGmsa.
    .PARAMETER Name
        gMSA name WITHOUT the trailing '$'. Maximum 15 characters, and unique across the whole
        FOREST - not merely the domain.
    .PARAMETER PrincipalsAllowedToRetrieveManagedPassword
        Who may retrieve the password. Strongly prefer a security group containing the computer
        accounts; naming computers directly means editing the gMSA every time a host is added.
    .PARAMETER DnsHostName
        Defaults to <Name>.<current domain DNS root>.
    .PARAMETER Path
        Target OU. Defaults to the domain's Managed Service Accounts container.
    .PARAMETER Description
        Free text stored on the account. Worth setting - an unlabelled service account is a
        future mystery.
    .PARAMETER ManagedPasswordIntervalInDays
        Password rotation interval. Cannot be changed after creation. Default 30.
    .PARAMETER PassThru
        Emit the created account.
    .OUTPUTS
        The created account when -PassThru is used.
    .EXAMPLE
        New-PSTSMGmsa -Name 'svc_reports' -PrincipalsAllowedToRetrieveManagedPassword 'gg_ReportHosts'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword',
        'PrincipalsAllowedToRetrieveManagedPassword',
        Justification = 'Not a password. This is the list of computer and group principals permitted to retrieve the managed password, and it is the name Set-ADServiceAccount uses; renaming it would only obscure the mapping to the directory attribute.')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$PrincipalsAllowedToRetrieveManagedPassword,

        [string]$DnsHostName,
        [string]$Path,
        [string]$Description,

        [ValidateRange(1, 3650)]
        [int]$ManagedPasswordIntervalInDays = 30,

        [switch]$PassThru
    )

    # Offline validation FIRST - before the RSAT check, before the import, before anything that
    # asks the machine a question. It needs nothing installed and nothing reachable, and the help
    # has always promised it comes first.
    #
    # It did not. The name check sat below both the RSAT guard and the module import, so on a
    # machine without RSAT a plainly bad name produced "The ActiveDirectory module is required" -
    # the least useful of the two errors, and the one that sends somebody to install software
    # they may not even need for the thing they got wrong. Caught by CI on a runner with no RSAT,
    # and my first attempt at the fix moved it only below the guard, which CI then caught again.
    #
    # Checked here rather than left to AD, whose error for this is an opaque constraint
    # violation. The sAMAccountName is <name>$, and the limit applies to the whole thing.
    $bare = $Name.TrimEnd('$')
    if ($bare.Length -gt 15) {
        throw "gMSA name '$bare' is $($bare.Length) characters. The sAMAccountName is '$bare`$' and cannot exceed 15 characters."
    }
    if ($bare -match '[\\/:*?"<>|\[\]; +=,]') {
        throw "gMSA name '$bare' contains a character that is not valid in a sAMAccountName."
    }

    if (-not (Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue)) {
        throw 'The ActiveDirectory module is required to create a gMSA. Install RSAT AD PowerShell.'
    }
    Import-Module ActiveDirectory -ErrorAction Stop

    $domain = Get-ADDomain -ErrorAction Stop

    if (-not $DnsHostName) { $DnsHostName = "$bare.$($domain.DNSRoot)" }
    if (-not $Path) { $Path = "CN=Managed Service Accounts,$($domain.DistinguishedName)" }

    # Unique per FOREST. Creating a duplicate in a different domain fails, and the reason is
    # not obvious from the error, so say it up front.
    $existing = $null
    try { $existing = Get-ADServiceAccount -Identity $bare -ErrorAction Stop } catch { Write-Verbose "No existing gMSA named '$bare'." }
    if ($existing) {
        throw "A managed service account named '$bare' already exists ($($existing.DistinguishedName)). gMSA names must be unique across the forest."
    }

    # Naming computers directly works, but every new host then means editing the gMSA. A group
    # is the shape that scales, so flag it rather than silently doing the thing you regret.
    $computerish = @($PrincipalsAllowedToRetrieveManagedPassword | Where-Object { $_ -match '\$$' })
    if ($computerish.Count -gt 0) {
        Write-Warning ("PrincipalsAllowedToRetrieveManagedPassword names computer account(s) directly: $($computerish -join ', '). " +
            'Adding a second host later means modifying the gMSA. A security group containing the computers avoids that.')
    }

    $params = @{
        Name                                       = $bare
        DNSHostName                                = $DnsHostName
        Path                                       = $Path
        PrincipalsAllowedToRetrieveManagedPassword = $PrincipalsAllowedToRetrieveManagedPassword
        ManagedPasswordIntervalInDays              = $ManagedPasswordIntervalInDays
        Enabled                                    = $true
        ErrorAction                                = 'Stop'
    }
    if ($Description) { $params['Description'] = $Description }

    $target = "$bare`$ in $Path"
    $action = "Create gMSA (password retrievable by: $($PrincipalsAllowedToRetrieveManagedPassword -join ', '))"
    if (-not $PSCmdlet.ShouldProcess($target, $action)) { return }

    New-ADServiceAccount @params
    Write-Verbose "Created gMSA '$bare`$' in $Path."

    if ($PassThru) { Get-ADServiceAccount -Identity $bare -Properties * }
}
