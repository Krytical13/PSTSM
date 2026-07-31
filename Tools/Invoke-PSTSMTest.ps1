# SPDX-License-Identifier: GPL-3.0-or-later

<#
.SYNOPSIS
    Runs the PSTSM test suites the way they are meant to be run.
.DESCRIPTION
    Development scaffolding, not part of the module. Nothing under Tools\ ships or is imported.

    It exists because running the suites correctly needs three pieces of knowledge that are easy
    to lack and unpleasant to discover:

      1. Pester 5 is required, and Windows ships Pester 3.4. Worse, `Install-Module -Scope
         CurrentUser` from pwsh installs into Documents\PowerShell\, which Windows PowerShell
         cannot see - so "I installed Pester 5" and "5.1 can find Pester 5" are different facts.
         This searches both module roots and imports by full path.
      2. Both engines matter. Windows PowerShell 5.1 is where the parameter-binder differences
         surface; pwsh is where most people run. A green run on one proves little.
      3. The UI suite needs an STA apartment, and silently skips its form tests without one -
         reporting success while testing almost nothing. This forces -STA and says which
         apartment it got.

    It also sets PSTSM_NODIALOG, without which an exception inside a WinForms handler puts a
    modal message box on the desktop of whoever is at the machine and blocks the run until it is
    dismissed.
.PARAMETER Suite
    Which suites to run. Default: both.
.PARAMETER Engine
    Which PowerShell hosts to run under. Default: whichever are installed.
.PARAMETER Detailed
    Show per-test output rather than a summary.
.OUTPUTS
    None. Exits non-zero if any test failed, so CI can gate on it.
.EXAMPLE
    .\Tools\Invoke-PSTSMTest.ps1
.EXAMPLE
    .\Tools\Invoke-PSTSMTest.ps1 -Suite UI -Engine powershell -Detailed
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'This is a console entry point whose output IS a report for a person, and it uses colour to mark failures. The rule exists to stop library code bypassing the pipeline; a runner that emitted its summary to the success stream would also emit it into any caller capturing results.')]
[CmdletBinding()]
param(
    [ValidateSet('Engine', 'UI', 'All')]
    [string]$Suite = 'All',

    [ValidateSet('powershell', 'pwsh', 'All')]
    [string]$Engine = 'All',

    [switch]$Detailed
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

# --- find Pester 5 wherever it landed ------------------------------------------------------
# Get-Module -ListAvailable only searches the CURRENT host's module path, which is the whole
# problem, so look in both roots directly.
$searchRoots = @(
    [System.Environment]::GetFolderPath('MyDocuments') | ForEach-Object {
        Join-Path $_ 'WindowsPowerShell\Modules\Pester'
        Join-Path $_ 'PowerShell\Modules\Pester'
    }
    Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\Pester'
    Join-Path $env:ProgramFiles 'PowerShell\Modules\Pester'
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

$pesterManifest = $null
$best = [version]'0.0'
foreach ($r in $searchRoots) {
    foreach ($d in Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue) {
        $v = $null
        if (-not [version]::TryParse($d.Name, [ref]$v)) { continue }
        if ($v.Major -lt 5 -or $v -le $best) { continue }
        $m = Join-Path $d.FullName 'Pester.psd1'
        if (Test-Path -LiteralPath $m) { $best = $v; $pesterManifest = $m }
    }
}

if (-not $pesterManifest) {
    Write-Host 'Pester 5 was not found.' -ForegroundColor Red
    Write-Host ''
    Write-Host '  Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force'
    Write-Host ''
    Write-Host 'Run that from the host you intend to test with: -Scope CurrentUser installs into'
    Write-Host 'Documents\PowerShell\ from pwsh and Documents\WindowsPowerShell\ from powershell.exe,'
    Write-Host 'and neither host reads the other''s folder.'
    exit 2
}
Write-Host "Pester $best  ($pesterManifest)" -ForegroundColor DarkGray

# --- what to run ---------------------------------------------------------------------------
$suites = switch ($Suite) {
    'Engine' { , 'PSTSM.Tests.ps1' }
    'UI' { , 'PSTSM.UI.Tests.ps1' }
    default { 'PSTSM.Tests.ps1', 'PSTSM.UI.Tests.ps1' }
}

$engines = @()
foreach ($e in @('powershell', 'pwsh')) {
    if ($Engine -ne 'All' -and $Engine -ne $e) { continue }
    $cmd = Get-Command $e -ErrorAction SilentlyContinue
    if ($cmd) { $engines += $cmd.Source } else { Write-Host "  $e not installed - skipping" -ForegroundColor DarkGray }
}
if (-not $engines) { Write-Host 'No PowerShell host to run under.' -ForegroundColor Red; exit 2 }

$verbosity = if ($Detailed) { 'Detailed' } else { 'None' }
$totalFailed = 0
$rows = @()

foreach ($enginePath in $engines) {
    foreach ($s in $suites) {
        $suitePath = Join-Path $root "Tests\$s"
        if (-not (Test-Path -LiteralPath $suitePath)) { continue }

        # Written to a file and run with -File rather than passed as -Command. A multi-line
        # -Command argument is re-parsed by the child and does not survive intact - which is the
        # same class of problem the module itself exists to get right.
        $childScript = Join-Path ([System.IO.Path]::GetTempPath()) ("pstsmtest_{0}.ps1" -f [guid]::NewGuid().ToString('N'))
        @"
`$env:PSTSM_NODIALOG = '1'
Import-Module '$pesterManifest' -Force
`$c = New-PesterConfiguration
`$c.Run.Path = '$suitePath'
`$c.Run.PassThru = `$true
`$c.Output.Verbosity = '$verbosity'
`$r = Invoke-Pester -Configuration `$c
"RESULT|`$(`$r.PassedCount)|`$(`$r.FailedCount)|`$(`$r.SkippedCount)"
foreach (`$t in `$r.Failed) { "FAILED|`$(`$t.ExpandedPath)" }
"@ | Set-Content -LiteralPath $childScript -Encoding UTF8

        try {
            # -STA: the UI suite skips its form tests under MTA and still reports success, so a
            # run without it proves far less than it appears to.
            $output = & $enginePath -NoProfile -STA -ExecutionPolicy Bypass -File $childScript 2>&1
        }
        finally {
            try { [System.IO.File]::Delete($childScript) } catch { Write-Verbose "Left $childScript behind." }
        }

        $line = @($output | Where-Object { $_ -match '^RESULT\|' })[0]
        $failedTests = @($output | Where-Object { $_ -match '^FAILED\|' } | ForEach-Object { ($_ -split '\|', 2)[1] })
        if ($Detailed) { $output | Where-Object { $_ -notmatch '^(RESULT|FAILED)\|' } | ForEach-Object { $_ } }

        if (-not $line) {
            $rows += [pscustomobject]@{ Engine = (Split-Path $enginePath -Leaf); Suite = $s; Passed = '?'; Failed = '?'; Skipped = '?' }
            $totalFailed++
            Write-Host "  $s under $(Split-Path $enginePath -Leaf): produced no result" -ForegroundColor Red
            continue
        }

        $parts = $line -split '\|'
        $rows += [pscustomobject]@{
            Engine  = (Split-Path $enginePath -Leaf)
            Suite   = if ($s -like '*UI*') { 'UI' } else { 'Engine' }
            Passed  = [int]$parts[1]
            Failed  = [int]$parts[2]
            Skipped = [int]$parts[3]
        }
        $totalFailed += [int]$parts[2]
        foreach ($f in $failedTests) { Write-Host "  FAIL  $f" -ForegroundColor Red }
    }
}

Write-Host ''
$rows | Format-Table -AutoSize | Out-String | Write-Host

if ($totalFailed -gt 0) {
    Write-Host "$totalFailed test(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'All green.' -ForegroundColor Green
exit 0
