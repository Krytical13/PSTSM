# SPDX-License-Identifier: GPL-3.0-or-later
#
# PSTaskBuilder - build, validate and edit Windows scheduled tasks that run PowerShell.
# Copyright (C) 2026 Krytical13
#
# This program is free software: you can redistribute it and/or modify it under the terms of
# the GNU General Public License as published by the Free Software Foundation, either version 3
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
# without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
# See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with this program.
# If not, see <https://www.gnu.org/licenses/>.
#
# PSTaskBuilder.psm1
# Loads every function under Functions\ (the headless engine) and UI\ (the WinForms front end)
# and exports the PSTask-prefixed commands.
#
# Packaged as a module so the engine is a single versioned, testable unit that the UI - and
# Pester - import, rather than dot-sourcing a directory. The engine never references the UI, so
# it stays usable from a console, a build agent, or a scheduled task of its own.

foreach ($subdir in @('Functions', 'UI')) {
    $root = Join-Path $PSScriptRoot $subdir
    if (-not (Test-Path -LiteralPath $root)) { continue }
    Get-ChildItem -Path $root -Recurse -Filter '*.ps1' -ErrorAction Stop | ForEach-Object {
        . $_.FullName
    }
}

Export-ModuleMember -Function '*-PSTask*'
