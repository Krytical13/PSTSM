@echo off
rem SPDX-License-Identifier: GPL-3.0-or-later
rem
rem PSTSM - PowerShell Task Scheduler Manager
rem
rem Double-click this. Windows will not run a .ps1 on double-click - it opens it in an editor -
rem so this is the entry point, and all it does is hand off to Start-PSTSM.ps1.
rem
rem powershell.exe rather than pwsh: it is on every Windows machine, and it defaults to the STA
rem apartment that WinForms needs. Start-PSTSM.ps1 handles elevation and, if you launch it some
rem other way, the apartment too.
rem
rem Any arguments are passed straight through, so this works:
rem     PSTSM.cmd -Elevated
rem     PSTSM.cmd -ScriptPath "C:\Scripts\Nightly.ps1"

setlocal

set "PSTSM_HOST=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSTSM_HOST%" (
    echo.
    echo Could not find Windows PowerShell at:
    echo     %PSTSM_HOST%
    echo.
    echo PSTSM needs Windows PowerShell 5.1 or PowerShell 7 on Windows.
    echo.
    pause
    exit /b 1
)

if not exist "%~dp0Start-PSTSM.ps1" (
    echo.
    echo Start-PSTSM.ps1 is missing from:
    echo     %~dp0
    echo.
    echo Keep PSTSM.cmd in the same folder as the rest of the module.
    echo.
    pause
    exit /b 1
)

rem start "" so this console closes immediately rather than sitting there for as long as the
rem window is open. Nothing is elevated here: PSTSM runs unelevated and asks for consent only
rem when saving a task that genuinely needs it.
start "" "%PSTSM_HOST%" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Start-PSTSM.ps1" %*

endlocal
exit /b 0
