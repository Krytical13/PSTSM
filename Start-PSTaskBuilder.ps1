<#
.SYNOPSIS
    Launches the PSTaskBuilder window.
.DESCRIPTION
    Double-click entry point. Imports the module and opens the task list.

    Handles the apartment state itself: WinForms requires STA, and while powershell.exe has
    defaulted to STA since v3, pwsh starts MTA, where showing a form either throws or produces
    a window that deadlocks on the first dialog. If this is running MTA it relaunches itself
    with -STA and exits.
.PARAMETER ScriptPath
    Skip the task list and open the editor directly for this script.
.PARAMETER Relaunched
    Internal. Set on the STA relaunch so it cannot loop.
.EXAMPLE
    .\Start-PSTaskBuilder.ps1
.EXAMPLE
    .\Start-PSTaskBuilder.ps1 -ScriptPath 'D:\Scripts\Send-Report.ps1'
#>
[CmdletBinding()]
param(
    [string]$ScriptPath,
    [switch]$Relaunched
)

$ErrorActionPreference = 'Stop'

$apartment = [System.Threading.Thread]::CurrentThread.GetApartmentState()
if ($apartment -ne 'STA' -and -not $Relaunched -and -not $env:PSTASKBUILDER_NOLAUNCH) {
    $self = $PSCommandPath
    if (-not $self) { $self = $MyInvocation.MyCommand.Path }

    # Relaunch on the same host, just in STA.
    $host_exe = (Get-Process -Id $PID).Path
    $relaunchArgs = @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $self, '-Relaunched')
    if ($ScriptPath) { $relaunchArgs += @('-ScriptPath', $ScriptPath) }

    Write-Verbose "Current apartment is $apartment; relaunching STA via $host_exe"
    & $host_exe @relaunchArgs
    return
}

$moduleManifest = Join-Path $PSScriptRoot 'PSTaskBuilder.psd1'
if (-not (Test-Path -LiteralPath $moduleManifest)) {
    throw "PSTaskBuilder.psd1 not found next to this script ($PSScriptRoot)."
}
Import-Module $moduleManifest -Force

if ($ScriptPath) { Show-PSTaskBuilder -ScriptPath $ScriptPath } else { Show-PSTaskBuilder }
