# SPDX-License-Identifier: GPL-3.0-or-later
function ConvertFrom-PSTSMAction {
    <#
    .SYNOPSIS
        Reverses an existing scheduled task's action back into engine + script + parameters,
        so a task that already exists can be opened in the same form that created it.
    .DESCRIPTION
        This is what makes the browse-and-edit half of the tool work. Given the Execute and
        Arguments of a registered task, it recovers:

          Engine      - powershell.exe / pwsh.exe (and bitness, from the path)
          ScriptPath  - from -File, or from -Command '& "path"' for tasks built the old way
          Parameters  - the script's own named parameters, as an ordered dictionary
          Switches    - -NoProfile / -NonInteractive / -ExecutionPolicy / -WindowStyle

        IsRecognized reports whether the round-trip is safe. When a task was hand-built in an
        unusual shape - an inline -Command scriptblock, a .cmd wrapper, an .exe that is not a
        PowerShell host - IsRecognized is $false and RawArguments is returned untouched. The UI
        must fall back to a plain arguments text box in that case rather than silently
        normalising somebody's working task into a different one.
    .PARAMETER Execute
        The task action's Execute value (the program path).
    .PARAMETER Arguments
        The task action's Arguments value.
    .PARAMETER WorkingDirectory
        The task action's WorkingDirectory, passed through untouched.
    .OUTPUTS
        [pscustomobject] IsPowerShell, IsRecognized, EngineId, EnginePath, Bitness, ScriptPath,
                         Parameters, ExtraArguments, NoProfile, NonInteractive, ExecutionPolicy,
                         WindowStyle, RawArguments, Notes
    .EXAMPLE
        $a = (Get-ScheduledTask -TaskName 'Nightly').Actions[0]
        ConvertFrom-PSTSMAction -Execute $a.Execute -Arguments $a.Arguments
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Execute,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Arguments,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$WorkingDirectory
    )

    $notes = New-Object System.Collections.Generic.List[string]

    $exeLeaf = ''
    try { $exeLeaf = [System.IO.Path]::GetFileName($Execute.Trim('"', ' ')) }
    catch { Write-Verbose "Could not parse Execute value '$Execute': $($_.Exception.Message)" }

    $engineId = $null
    switch -Regex ($exeLeaf) {
        '(?i)^powershell(\.exe)?$' { $engineId = 'powershell' }
        '(?i)^pwsh(\.exe)?$' { $engineId = 'pwsh' }
    }

    $bitness = if ($Execute -match '(?i)\\SysWOW64\\') { 'x86' } elseif ($engineId) { 'x64' } else { $null }

    $result = [PSCustomObject]@{
        PSTypeName       = 'PSTSM.ParsedAction'
        IsPowerShell     = [bool]$engineId
        IsRecognized     = $false
        EngineId         = $engineId
        EnginePath       = $Execute
        Bitness          = $bitness
        ScriptPath       = $null
        Parameters       = [ordered]@{}
        ExtraArguments   = $null
        NoProfile        = $false
        NonInteractive   = $false
        ExecutionPolicy  = 'None'
        WindowStyle      = 'None'
        WorkingDirectory = $WorkingDirectory
        RawArguments     = $Arguments
        Notes            = @()
    }

    if (-not $engineId) {
        $notes.Add("Action runs '$exeLeaf', which is not a PowerShell host. Edit as a raw action.")
        $result.Notes = $notes.ToArray()
        return $result
    }

    if ([string]::IsNullOrWhiteSpace($Arguments)) {
        $notes.Add('Action has no arguments - the engine would start an interactive session.')
        $result.Notes = $notes.ToArray()
        return $result
    }

    # Split respecting double quotes.
    $tokens = New-Object System.Collections.Generic.List[string]
    $current = New-Object System.Text.StringBuilder
    $inQuotes = $false
    for ($i = 0; $i -lt $Arguments.Length; $i++) {
        $ch = $Arguments[$i]
        if ($ch -eq '"') {
            # \" is an escaped quote, not a delimiter.
            if ($i -gt 0 -and $Arguments[$i - 1] -eq '\') { [void]$current.Append('"'); continue }
            $inQuotes = -not $inQuotes
            continue
        }
        if ($ch -eq ' ' -and -not $inQuotes) {
            if ($current.Length -gt 0) { [void]$tokens.Add($current.ToString()); [void]$current.Clear() }
            continue
        }
        [void]$current.Append($ch)
    }
    if ($current.Length -gt 0) { [void]$tokens.Add($current.ToString()) }

    # --- engine switches, up to -File / -Command ---------------------------------------
    # PowerShell abbreviates host switches down to any unambiguous prefix, so -nop, -noni and
    # -ex all appear in the wild and are matched here alongside their full spellings.
    $idx = 0
    $sawFile = $false
    $sawCommand = $false

    while ($idx -lt $tokens.Count -and $tokens[$idx] -match '^-') {
        $t = $tokens[$idx]

        if ($t -match '(?i)^-f(i(l(e)?)?)?$') { $sawFile = $true; $idx++; break }
        if ($t -match '(?i)^-c(o(m(m(a(n(d)?)?)?)?)?)?$') { $sawCommand = $true; $idx++; break }

        if ($t -match '(?i)^-nop(r(o(f(i(l(e)?)?)?)?)?)?$') { $result.NoProfile = $true; $idx++; continue }
        if ($t -match '(?i)^-noni(n(t(e(r(a(c(t(i(v(e)?)?)?)?)?)?)?)?)?)?$') { $result.NonInteractive = $true; $idx++; continue }
        if ($t -match '(?i)^-nol(o(g(o)?)?)?$') { $idx++; continue }
        if ($t -match '(?i)^-(sta|mta)$') { $notes.Add("Apartment switch '$t' is preserved."); $idx++; continue }

        if ($t -match '(?i)^-ex(e(c(u(t(i(o(n(p(o(l(i(c(y)?)?)?)?)?)?)?)?)?)?)?)?)?$') {
            if ($idx + 1 -lt $tokens.Count) { $result.ExecutionPolicy = $tokens[$idx + 1]; $idx += 2 } else { $idx++ }
            continue
        }
        if ($t -match '(?i)^-w(i(n(d(o(w(s(t(y(l(e)?)?)?)?)?)?)?)?)?)?$') {
            if ($idx + 1 -lt $tokens.Count) { $result.WindowStyle = $tokens[$idx + 1]; $idx += 2 } else { $idx++ }
            continue
        }

        # An engine switch we do not model - stop rather than mis-attribute it to the script.
        $notes.Add("Unrecognised engine switch '$t'.")
        break
    }

    if ($sawCommand) {
        # Old-style: -Command "& 'C:\path\x.ps1' -A 1". Recoverable only when it is a plain
        # call operator against a .ps1 - anything else is real inline code we must not touch.
        $rest = ($tokens[$idx..($tokens.Count - 1)]) -join ' '
        if ($rest -match "^&\s*['""]?(?<p>[^'""]+\.ps1)['""]?\s*(?<a>.*)$") {
            $result.ScriptPath = $Matches['p'].Trim()
            $result.ExtraArguments = $Matches['a'].Trim()
            $notes.Add('Task uses -Command; -File is safer (correct quoting and exit-code propagation). Saving will convert it.')
            $result.IsRecognized = $true
        }
        else {
            $notes.Add('Task uses -Command with inline code rather than a script file. Edit as raw arguments.')
        }
        $result.Notes = $notes.ToArray()
        return $result
    }

    if (-not $sawFile) {
        $notes.Add('No -File or -Command found in the action arguments.')
        $result.Notes = $notes.ToArray()
        return $result
    }

    if ($idx -ge $tokens.Count) {
        $notes.Add('-File was given with no script path.')
        $result.Notes = $notes.ToArray()
        return $result
    }

    $result.ScriptPath = $tokens[$idx]
    $idx++

    # --- script parameters -------------------------------------------------------------
    $params = [ordered]@{}
    $leftover = New-Object System.Collections.Generic.List[string]

    while ($idx -lt $tokens.Count) {
        $t = $tokens[$idx]

        if ($t -match '^-(?<n>[A-Za-z_][A-Za-z0-9_]*):(?<v>.*)$') {
            # -Switch:$false form. Capture both groups BEFORE any further -match, which would
            # overwrite $Matches and leave the name null.
            $name = $Matches['n']
            $v = $Matches['v']
            $params[$name] = if ($v -match '(?i)^\$?true$') { $true } elseif ($v -match '(?i)^\$?false$') { $false } else { $v }
            $idx++
            continue
        }

        if ($t -match '^-(?<n>[A-Za-z_][A-Za-z0-9_]*)$') {
            $name = $Matches['n']
            $next = if ($idx + 1 -lt $tokens.Count) { $tokens[$idx + 1] } else { $null }

            if ($null -eq $next -or $next -match '^-[A-Za-z_]') {
                $params[$name] = $true          # bare switch
                $idx++
            }
            else {
                if ($next -match ',') { $params[$name] = @($next -split ',') }
                elseif ($next -match '(?i)^\$?true$') { $params[$name] = $true }
                elseif ($next -match '(?i)^\$?false$') { $params[$name] = $false }
                elseif ($next -match '^-?\d+$') { $params[$name] = [int]$next }
                else { $params[$name] = $next }
                $idx += 2
            }
            continue
        }

        $leftover.Add($t)
        $idx++
    }

    $result.Parameters = $params
    if ($leftover.Count -gt 0) {
        $result.ExtraArguments = $leftover -join ' '
        $notes.Add("Positional or unrecognised arguments preserved verbatim: $($result.ExtraArguments)")
    }

    $result.IsRecognized = $true
    $result.Notes = $notes.ToArray()
    $result
}
