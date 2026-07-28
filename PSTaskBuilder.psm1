# PSTaskBuilder.psm1
# Loads every function under Functions\ and exports the PSTask-prefixed commands.
# Packaged as a module so the engine is a single versioned, testable unit that the WinForms
# front end (and Pester) import, rather than dot-sourcing a directory.

$functionRoot = Join-Path $PSScriptRoot 'Functions'
Get-ChildItem -Path $functionRoot -Recurse -Filter '*.ps1' -ErrorAction Stop | ForEach-Object {
    . $_.FullName
}

Export-ModuleMember -Function '*-PSTask*'
