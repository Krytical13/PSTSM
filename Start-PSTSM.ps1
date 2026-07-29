# SPDX-License-Identifier: GPL-3.0-or-later
<#
.SYNOPSIS
    Launches the PSTSM window, elevating and switching to STA as needed.
.DESCRIPTION
    The entry point. Double-clicking PSTSM.cmd runs this; it can also be called directly.

    Two things have to be true before the window can open, and this sorts out both in a SINGLE
    relaunch rather than bouncing the process twice:

      STA apartment - WinForms requires it. powershell.exe has defaulted to STA since v3, but
      pwsh starts MTA, where showing a form either throws or produces a window that deadlocks
      on its first dialog.

      Elevation - registering, editing or deleting a scheduled task outside your own folder
      needs an administrator token, and Install-ADServiceAccount and the batch-logon right
      need one too. Without it the list still loads and everything is readable, so -NoElevate
      is there for a look around.

    Elevating keeps you as YOU, with an administrator token. If your own account is not an
    administrator, UAC will ask for one that is, and Windows then runs the tool as THAT
    account - which changes whose tasks you see and who new tasks are attributed to. That is a
    Windows behaviour, not a choice this script makes, but it is worth knowing before you
    wonder why the list looks different.
.PARAMETER ScriptPath
    Skip the task list and open the editor directly for this script.
.PARAMETER NoElevate
    Do not ask for elevation. The list, the editor and the health sweep all work read-only;
    saving a task will fail if the account lacks the rights.
.PARAMETER Relaunched
    Internal. Set on the relaunch so it cannot loop.
.EXAMPLE
    .\Start-PSTSM.ps1
.EXAMPLE
    .\Start-PSTSM.ps1 -NoElevate
.EXAMPLE
    .\Start-PSTSM.ps1 -ScriptPath 'D:\Scripts\Send-Report.ps1'
#>
[CmdletBinding()]
param(
    [string]$ScriptPath,
    [switch]$NoElevate,
    [switch]$Relaunched
)

$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isElevated = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
$isSta = ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA')

$needsSta = -not $isSta
$needsElevation = (-not $isElevated) -and (-not $NoElevate)

if (($needsSta -or $needsElevation) -and -not $Relaunched -and -not $env:PSTSM_NOLAUNCH) {
    $self = $PSCommandPath
    if (-not $self) { $self = $MyInvocation.MyCommand.Path }

    # Relaunch on the same host so a PowerShell 7 user stays on PowerShell 7.
    $hostExe = (Get-Process -Id $PID).Path

    # Built as one quoted string rather than an array: Start-Process quotes array elements
    # inconsistently, and both of these paths can contain spaces.
    $argString = '-STA -NoProfile -ExecutionPolicy Bypass -File "{0}" -Relaunched' -f $self
    if ($ScriptPath) { $argString += ' -ScriptPath "{0}"' -f $ScriptPath }
    if ($NoElevate) { $argString += ' -NoElevate' }

    $startParams = @{
        FilePath     = $hostExe
        ArgumentList = $argString
        ErrorAction  = 'Stop'
    }
    if ($needsElevation) { $startParams['Verb'] = 'RunAs' }

    try {
        Start-Process @startParams
    }
    catch {
        # The usual cause is the UAC prompt being dismissed. Say so plainly and offer the way
        # to carry on without it, rather than surfacing a raw Win32 exception.
        Write-Warning ("PSTSM could not start elevated: $($_.Exception.Message)" + [Environment]::NewLine +
            'If you cancelled the prompt, run it again and accept, or start it read-only with:' + [Environment]::NewLine +
            "    .\Start-PSTSM.ps1 -NoElevate")
    }
    return
}

if ($needsElevation) {
    # Reached only when -Relaunched is set and elevation still did not happen.
    Write-Warning 'Running without administrator rights. Tasks can be viewed but saving one will fail.'
}

if ($needsSta) {
    # Only reachable if something called this with -Relaunched but without -STA. WinForms in an
    # MTA apartment fails in confusing ways - a window that never paints, or a deadlock on the
    # first dialog - so name the cause rather than letting it happen.
    throw ('PSTSM needs a single-threaded apartment and this process is ' +
        "$([System.Threading.Thread]::CurrentThread.GetApartmentState()). " +
        'Launch it with PSTSM.cmd, or start the host with -STA.')
}

$moduleManifest = Join-Path $PSScriptRoot 'PSTSM.psd1'
if (-not (Test-Path -LiteralPath $moduleManifest)) {
    throw "PSTSM.psd1 not found next to this script ($PSScriptRoot)."
}
Import-Module $moduleManifest -Force

if ($ScriptPath) { Show-PSTSM -ScriptPath $ScriptPath } else { Show-PSTSM }
