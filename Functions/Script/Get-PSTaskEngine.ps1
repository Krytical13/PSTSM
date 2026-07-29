# SPDX-License-Identifier: GPL-3.0-or-later
function Get-PSTaskEngine {
    <#
    .SYNOPSIS
        Enumerates the PowerShell engines installed on this machine that a scheduled task
        could be pointed at.
    .DESCRIPTION
        Task Scheduler needs a literal path to an executable, not "pwsh". This finds every
        engine that is actually present so the UI can offer a real list instead of a free-text
        box, and so a plan can be validated against the target machine before it is registered.

        Discovered:
          - Windows PowerShell 5.1, 64-bit  (System32\WindowsPowerShell\v1.0\powershell.exe)
          - Windows PowerShell 5.1, 32-bit  (SysWOW64\WindowsPowerShell\v1.0\powershell.exe)
          - PowerShell 6+                   (Program Files\PowerShell\<n>\pwsh.exe)

        Bitness matters: Task Scheduler launches 64-bit by default, and a script that needs a
        32-bit-only module (older provider DLLs, some vendor snap-ins) has to be pointed at
        the SysWOW64 copy explicitly.
    .PARAMETER Id
        Optional filter: 'powershell' (Windows PowerShell) or 'pwsh' (PowerShell 6+).
    .OUTPUTS
        [pscustomobject] Id, DisplayName, Path, Version, Edition, Bitness, IsDefault
    .EXAMPLE
        Get-PSTaskEngine | Format-Table DisplayName, Path, Version
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('powershell', 'pwsh')]
        [string]$Id
    )

    $engines = New-Object System.Collections.Generic.List[object]

    # A scriptblock rather than a nested function: this only shapes an object, and a 'New-*'
    # helper trips PSUseShouldProcessForStateChangingFunctions for no benefit.
    $newEngineInfo = {
        param($id, $display, $path, $version, $edition, $bitness)
        [PSCustomObject]@{
            Id          = $id
            DisplayName = $display
            Path        = $path
            Version     = $version
            Edition     = $edition
            Bitness     = $bitness
            IsDefault   = $false
        }
    }

    # --- Windows PowerShell 5.1 -------------------------------------------------------
    # ProductVersion on powershell.exe reports the OS build, not the engine version, so the
    # 5.1 label is hard-coded: every supported Windows release ships exactly 5.1 here.
    $winPsRelative = 'WindowsPowerShell\v1.0\powershell.exe'
    $sysRoot = $env:SystemRoot

    $winPs64 = Join-Path $sysRoot (Join-Path 'System32' $winPsRelative)
    if (Test-Path -LiteralPath $winPs64) {
        $engines.Add((& $newEngineInfo 'powershell' 'Windows PowerShell 5.1 (64-bit)' $winPs64 '5.1' 'Desktop' 'x64'))
    }

    $winPs32 = Join-Path $sysRoot (Join-Path 'SysWOW64' $winPsRelative)
    if (Test-Path -LiteralPath $winPs32) {
        $engines.Add((& $newEngineInfo 'powershell' 'Windows PowerShell 5.1 (32-bit)' $winPs32 '5.1' 'Desktop' 'x86'))
    }

    # --- PowerShell 6+ ----------------------------------------------------------------
    $pwshRoots = @(
        $env:ProgramFiles
        ${env:ProgramFiles(x86)}
    ) | Where-Object { $_ } | Select-Object -Unique

    foreach ($root in $pwshRoots) {
        $psRoot = Join-Path $root 'PowerShell'
        if (-not (Test-Path -LiteralPath $psRoot)) { continue }

        # Only numbered version folders; skip '7-preview' side-by-side installs unless they
        # are the only thing present (they are still perfectly valid task targets).
        Get-ChildItem -LiteralPath $psRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $exe = Join-Path $_.FullName 'pwsh.exe'
            if (-not (Test-Path -LiteralPath $exe)) { return }

            $version = try { (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion } catch { $_.Name }
            if ($version) { $version = ($version -split '[-+ ]')[0] }   # 7.4.6-preview.1 -> 7.4.6

            $bitness = if ($root -eq ${env:ProgramFiles(x86)}) { 'x86' } else { 'x64' }
            $label = "PowerShell $version ($bitness)"
            $engines.Add((& $newEngineInfo 'pwsh' $label $exe $version 'Core' $bitness))
        }
    }

    # --- Default ----------------------------------------------------------------------
    # Highest-version 64-bit pwsh if present, else 64-bit Windows PowerShell. This is only a
    # starting point for the UI; Get-PSTaskScriptProfile overrides it when the script says so.
    $preferred =
    @($engines | Where-Object { $_.Id -eq 'pwsh' -and $_.Bitness -eq 'x64' } |
        Sort-Object { try { [version]$_.Version } catch { [version]'0.0' } } -Descending |
        Select-Object -First 1)

    if (-not $preferred) {
        $preferred = @($engines | Where-Object { $_.Id -eq 'powershell' -and $_.Bitness -eq 'x64' } | Select-Object -First 1)
    }
    if ($preferred) { $preferred[0].IsDefault = $true }

    $output = $engines
    if ($Id) { $output = $engines | Where-Object { $_.Id -eq $Id } }

    # Sort so the list reads sensibly in a combo box: newest first, 64-bit before 32-bit.
    $output |
        Sort-Object `
        @{ Expression = { if ($_.Id -eq 'pwsh') { 0 } else { 1 } } },
        @{ Expression = { try { [version]$_.Version } catch { [version]'0.0' } }; Descending = $true },
        @{ Expression = { if ($_.Bitness -eq 'x64') { 0 } else { 1 } } }
}
