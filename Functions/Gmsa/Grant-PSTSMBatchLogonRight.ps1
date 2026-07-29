# SPDX-License-Identifier: GPL-3.0-or-later
function Grant-PSTSMBatchLogonRight {
    <#
    .SYNOPSIS
        Grants "Log on as a batch job" (SeBatchLogonRight) to an account on this machine.
    .DESCRIPTION
        There is no cmdlet for this, which is why it is the step everyone skips - and a task
        whose account lacks the right fails to register with 0x80070534, an error that names
        nothing useful. A gMSA effectively never has it by default.

        Implemented with secedit export/modify/import because it needs no P/Invoke and no extra
        module. The important safety property is that the EXISTING member list is read and the
        new SID APPENDED - secedit's import replaces a privilege's membership wholesale, so
        writing only the new account would silently strip Administrators, Backup Operators and
        Performance Log Users of the same right.

        If the exported policy has no SeBatchLogonRight line at all, this refuses rather than
        creating one, because a created line would define the entire membership as just this
        account and quietly remove everyone else's.

        Machine-local and requires elevation. Note that a domain GPO can overwrite this at the
        next refresh; in a locked-down environment grant it through policy instead.
    .PARAMETER Account
        Account to grant, as DOMAIN\name. For a gMSA include the trailing '$'.
    .PARAMETER PassThru
        Emit a result object describing what changed.
    .OUTPUTS
        [pscustomobject] Account, Sid, AlreadyHeld, Granted - when -PassThru is used.
    .EXAMPLE
        Grant-PSTSMBatchLogonRight -Account 'CONTOSO\svc_reports$'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Account,

        [switch]$PassThru
    )

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Granting a user right requires an elevated session.'
    }

    $sid = $null
    try {
        $sid = (New-Object System.Security.Principal.NTAccount($Account)).Translate(
            [System.Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        throw "Could not resolve '$Account' to a SID: $($_.Exception.Message)"
    }

    $work = Join-Path $env:TEMP ("pstb-sec-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $exportInf = Join-Path $work 'export.inf'
    $importInf = Join-Path $work 'import.inf'
    $db = Join-Path $work 'secedit.sdb'

    try {
        $out = & secedit.exe /export /cfg $exportInf /areas USER_RIGHTS 2>&1
        if (-not (Test-Path -LiteralPath $exportInf)) {
            throw "secedit could not export the local policy: $out"
        }

        # secedit writes Unicode (UTF-16LE); reading it as anything else yields mojibake.
        $lines = [System.IO.File]::ReadAllLines($exportInf, [System.Text.Encoding]::Unicode)

        $current = $null
        foreach ($line in $lines) {
            if ($line -match '^\s*SeBatchLogonRight\s*=\s*(.*)$') { $current = $Matches[1].Trim(); break }
        }

        if ($null -eq $current) {
            throw ('The exported local policy contains no SeBatchLogonRight entry. Refusing to create one, ' +
                'because doing so would define its entire membership as just this account and remove the ' +
                'existing holders. Grant the right manually via secpol.msc or Group Policy.')
        }

        $members = @($current -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $alreadyHeld = [bool](@($members | Where-Object { $_.TrimStart('*') -eq $sid }).Count -gt 0)

        $result = [PSCustomObject]@{
            PSTypeName  = 'PSTSM.BatchRightResult'
            Account     = $Account
            Sid         = $sid
            AlreadyHeld = $alreadyHeld
            Granted     = $false
        }

        if ($alreadyHeld) {
            Write-Verbose "$Account already holds SeBatchLogonRight."
            if ($PassThru) { return $result }
            return
        }

        if (-not $PSCmdlet.ShouldProcess("$Account on $env:COMPUTERNAME", 'Grant "Log on as a batch job"')) {
            if ($PassThru) { return $result }
            return
        }

        $newMembers = ($members + "*$sid") -join ','
        $inf = @(
            '[Unicode]'
            'Unicode=yes'
            '[Version]'
            'signature="$CHICAGO$"'
            'Revision=1'
            '[Privilege Rights]'
            "SeBatchLogonRight = $newMembers"
        )
        [System.IO.File]::WriteAllLines($importInf, $inf, [System.Text.Encoding]::Unicode)

        $out = & secedit.exe /configure /db $db /cfg $importInf /areas USER_RIGHTS 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "secedit failed to apply the policy (exit $LASTEXITCODE): $out"
        }

        $result.Granted = $true
        Write-Verbose "Granted SeBatchLogonRight to $Account ($sid)."
        if ($PassThru) { $result }
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
