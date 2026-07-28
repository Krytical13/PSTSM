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
