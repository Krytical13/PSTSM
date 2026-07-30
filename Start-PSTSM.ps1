# SPDX-License-Identifier: GPL-3.0-or-later

<#
.SYNOPSIS
    Launches the PSTSM window, switching to STA and elevating only if asked.
.DESCRIPTION
    The entry point. Double-clicking PSTSM.cmd runs this; it can also be called directly.

    Starts UNELEVATED, the same as Task Scheduler itself. A standard user can already register
    a task that runs as themselves, so demanding a UAC prompt up front would lock out exactly
    the people managing their own work, and would be heavier-handed than the tool it replaces.

    The line is narrow, and it was measured rather than taken on trust: with a genuine
    UAC-filtered token (TokenElevationType=3) RunLevel=Limited registers and RunLevel=Highest
    comes back "Access is denied". The same goes for a service account, a group principal and an
    at-startup trigger. Everything else - registering, editing and deleting a task that runs as
    you at normal privilege - works unelevated, as does the whole read-only side: the list, the
    editor, the health sweep, run logs.

    So elevation belongs to what a task DOES, not to opening the tool. When a plan needs rights
    this session does not have, the Save button takes a UAC shield and elevates for that one
    registration through a short-lived helper - one consent prompt, no restart, and everything
    typed into the editor is still there afterwards. Declining the prompt does nothing at all.

    Use -Elevated to hold an administrator token for the whole session instead. That is the
    better option for a run of privileged work - installing a gMSA, granting the batch-logon
    right - where per-save prompts would just be a nuisance.

    The apartment still has to be sorted before a window can open: WinForms requires STA, and
    while powershell.exe has defaulted to STA since v3, pwsh starts MTA, where showing a form
    either throws or deadlocks on the first dialog. That and any requested elevation are handled
    in a SINGLE relaunch rather than bouncing the process twice.

    One thing worth knowing when you do elevate: it keeps you as YOU with an administrator
    token, but if your own account is not an administrator, UAC asks for one that is and Windows
    then runs the tool as THAT account - which changes whose tasks you see and who new ones are
    attributed to. That is Windows' behaviour, not a choice this script makes.
.PARAMETER ScriptPath
    Skip the task list and open the editor directly for this script.
.PARAMETER Elevated
    Ask for administrator rights up front. Only needed for tasks that run as SYSTEM, as a group,
    or with highest privileges - and for the gMSA helpers.
.PARAMETER Relaunched
    Internal. Set on the relaunch so it cannot loop.
.EXAMPLE
    .\Start-PSTSM.ps1
.EXAMPLE
    .\Start-PSTSM.ps1 -Elevated
.EXAMPLE
    .\Start-PSTSM.ps1 -ScriptPath 'D:\Scripts\Send-Report.ps1'
#>
[CmdletBinding()]
param(
    [string]$ScriptPath,
    [switch]$Elevated,
    [switch]$Relaunched
)

$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isElevated = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
$isSta = ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA')

$needsSta = -not $isSta
# Only when explicitly asked for. Opening the tool is not itself a privileged operation.
$needsElevation = $Elevated -and (-not $isElevated)

if (($needsSta -or $needsElevation) -and -not $Relaunched -and -not $env:PSTSM_NOLAUNCH) {
    $self = $PSCommandPath
    if (-not $self) { $self = $MyInvocation.MyCommand.Path }

    # Relaunch on the same host so a PowerShell 7 user stays on PowerShell 7.
    $hostExe = (Get-Process -Id $PID).Path

    # Built as one quoted string rather than an array: Start-Process quotes array elements
    # inconsistently, and both of these paths can contain spaces.
    $argString = '-STA -NoProfile -ExecutionPolicy Bypass -File "{0}" -Relaunched' -f $self
    if ($ScriptPath) { $argString += ' -ScriptPath "{0}"' -f $ScriptPath }
    if ($Elevated) { $argString += ' -Elevated' }

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
        # The usual cause is the UAC prompt being dismissed. Say so plainly, and point out that
        # most work does not need elevation at all, rather than surfacing a raw Win32 exception.
        Write-Warning ("PSTSM could not start elevated: $($_.Exception.Message)" + [Environment]::NewLine +
            'If you cancelled the prompt, run it again and accept - or just run it normally:' + [Environment]::NewLine +
            '    .\Start-PSTSM.ps1' + [Environment]::NewLine +
            'Only tasks that run as SYSTEM, as a group, or with highest privileges need administrator rights.')
    }
    return
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
