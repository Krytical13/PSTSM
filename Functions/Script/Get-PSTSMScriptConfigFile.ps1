# SPDX-License-Identifier: GPL-3.0-or-later
function Get-PSTSMScriptConfigFile {
    <#
    .SYNOPSIS
        Finds the settings file a script reads alongside itself, and reports whether it is
        actually usable.
    .DESCRIPTION
        Scripts built for unattended use very often keep their real configuration next door:

            [string]$ConfigPath = (Join-Path $PSScriptRoot 'settings.psd1')
            $cfg = Import-PowerShellDataFile -Path $ConfigPath

        That file is then a hard dependency of the scheduled task, and it fails in exactly the
        same ways the script does - missing, unparseable, or sitting somewhere the task account
        cannot read. Nothing in Task Scheduler will ever mention it; the task simply throws at
        3am with a message about a file nobody remembers configuring.

        Detection is deliberately conservative. A parameter is treated as a config reference
        only when its NAME looks like one and its default RESOLVES to a real path through
        Resolve-PSTSMDefaultValue - which never executes anything.

        Content is read only for formats that can be parsed without running code:
        Import-PowerShellDataFile refuses anything with a dynamic expression in it, and
        ConvertFrom-Json is inert. Top-level keys are listed purely so the operator can confirm
        it is the file they think it is. Nothing is interpreted, because the tool cannot know
        what any of those keys mean.
    .PARAMETER ScriptProfile
        Output of Get-PSTSMScriptProfile.
    .OUTPUTS
        [pscustomobject] ParameterName, Path, Exists, Format, Parses, Keys, ParseError
    .EXAMPLE
        Get-PSTSMScriptConfigFile -ScriptProfile (Get-PSTSMScriptProfile -Path .\Run.ps1)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$ScriptProfile
    )

    $out = New-Object System.Collections.Generic.List[object]

    foreach ($p in $ScriptProfile.Parameters) {
        # Name has to look like configuration, not merely like a path - otherwise every
        # -OutputPath in the world gets treated as settings.
        if ($p.Name -notmatch '(?i)(config|settings|conf|ini|profile)(path|file|)$') { continue }
        if (-not $p.ResolvedDefault -or $p.ResolvedDefault.Kind -eq 'Unresolved') { continue }

        $path = [string]$p.ResolvedDefault.Value
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if ($path -notmatch '\.\w{2,6}$') { continue }   # must look like a file, not a folder

        $exists = Test-Path -LiteralPath $path -PathType Leaf
        $format = switch -Regex ([System.IO.Path]::GetExtension($path)) {
            '(?i)^\.psd1$' { 'PowerShellData' }
            '(?i)^\.json$' { 'Json' }
            '(?i)^\.xml$' { 'Xml' }
            default { 'Other' }
        }

        $parses = $null
        $keys = @()
        $parseError = $null

        if ($exists) {
            switch ($format) {
                'PowerShellData' {
                    # Safe by design: Import-PowerShellDataFile rejects any dynamic expression
                    # rather than evaluating it.
                    try {
                        $data = Import-PowerShellDataFile -LiteralPath $path -ErrorAction Stop
                        $parses = $true
                        $keys = @($data.Keys)
                    }
                    catch { $parses = $false; $parseError = $_.Exception.Message }
                }
                'Json' {
                    try {
                        $data = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                        $parses = $true
                        if ($data -is [System.Management.Automation.PSCustomObject]) { $keys = @($data.PSObject.Properties.Name) }
                    }
                    catch { $parses = $false; $parseError = $_.Exception.Message }
                }
                default {
                    # Not parsed. XML would need a schema to say anything useful, and anything
                    # else is opaque - existence and readability are the checks that matter.
                    $parses = $null
                }
            }
        }

        $out.Add([PSCustomObject]@{
                PSTypeName    = 'PSTSM.ConfigFile'
                ParameterName = $p.Name
                Path          = $path
                Exists        = $exists
                Format        = $format
                Parses        = $parses
                Keys          = $keys
                ParseError    = $parseError
            })
    }

    $out.ToArray()
}
