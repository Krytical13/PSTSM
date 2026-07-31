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

    # Tokenise by the CommandLineToArgvW rules - the exact inverse of what
    # ConvertTo-PSTSMQuotedValue writes. This has to be the inverse, or reopening a task in the
    # editor silently rewrites its own arguments.
    #
    # The rules, which are not the obvious ones:
    #   - backslashes are literal EXCEPT immediately before a double quote
    #   - 2n backslashes + quote  -> n backslashes, and the quote toggles quoting
    #   - 2n+1 backslashes + quote -> n backslashes and a LITERAL quote
    #
    # The previous implementation treated any quote preceded by a single backslash as escaped and
    # never consumed the backslashes. A value ending in one - every "C:\Program Files\App\" - is
    # emitted by the quoter as \\" , which it read as an escaped quote, so $inQuotes stuck on and
    # the remainder of the command line was swallowed into that one value. Every later parameter
    # vanished, and a switch that had been present came back absent.
    $tokens = New-Object System.Collections.Generic.List[string]
    # Parallel to $tokens: whether that token carried any quoting. A quoted token can never be a
    # parameter name, which is how a VALUE beginning with a dash is told apart from one.
    $quoted = New-Object System.Collections.Generic.List[bool]
    $current = New-Object System.Text.StringBuilder
    $wasQuoted = $false
    $inQuotes = $false
    # Tracked separately from $current.Length so that an explicitly empty argument ("") survives
    # as an empty token instead of disappearing.
    $started = $false
    $i = 0
    while ($i -lt $Arguments.Length) {
        $ch = $Arguments[$i]

        if ($ch -eq '\') {
            $slashes = 0
            while ($i -lt $Arguments.Length -and $Arguments[$i] -eq '\') { $slashes++; $i++ }
            if ($i -lt $Arguments.Length -and $Arguments[$i] -eq '"') {
                [void]$current.Append('\' * [math]::Floor($slashes / 2))
                if ($slashes % 2 -eq 1) { [void]$current.Append('"') }   # escaped, literal quote
                else { $inQuotes = -not $inQuotes; $wasQuoted = $true }    # delimiter
                $i++
            }
            else {
                [void]$current.Append('\' * $slashes)                     # not before a quote: literal
            }
            $started = $true
            continue
        }

        if ($ch -eq '"') {
            $inQuotes = -not $inQuotes
            $wasQuoted = $true
            $started = $true
            $i++
            continue
        }

        if (($ch -eq ' ' -or $ch -eq "`t") -and -not $inQuotes) {
            if ($started) {
                [void]$tokens.Add($current.ToString()); [void]$quoted.Add($wasQuoted)
                [void]$current.Clear(); $started = $false; $wasQuoted = $false
            }
            $i++
            continue
        }

        [void]$current.Append($ch)
        $started = $true
        $i++
    }
    if ($started) { [void]$tokens.Add($current.ToString()); [void]$quoted.Add($wasQuoted) }

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
            $notes.Add('Task uses -Command with inline code rather than a script file, so this editor shows it read-only. Change it in Task Scheduler, or rebuild it here against a .ps1.')
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

        if (-not $quoted[$idx] -and $t -match '^-(?<n>[\p{L}_][\p{L}\p{N}_]*):(?<v>.*)$') {
            # -Switch:$false form. Capture both groups BEFORE any further -match, which would
            # overwrite $Matches and leave the name null.
            $name = $Matches['n']
            $v = $Matches['v']
            $params[$name] = if ($v -match '(?i)^\$?true$') { $true } elseif ($v -match '(?i)^\$?false$') { $false } else { $v }
            $idx++
            continue
        }

        if (-not $quoted[$idx] -and $t -match '^-(?<n>[\p{L}_][\p{L}\p{N}_]*)$') {
            $name = $Matches['n']
            $next = if ($idx + 1 -lt $tokens.Count) { $tokens[$idx + 1] } else { $null }

            $nextIsName = ($idx + 1 -lt $tokens.Count) -and (-not $quoted[$idx + 1]) -and ($next -match '^-[\p{L}_]')
            if ($null -eq $next -or $nextIsName) {
                $params[$name] = $true          # bare switch
                $idx++
            }
            else {
                # A value that arrived as its OWN token is a string, and nothing else. This used
                # to guess at a type, and every guess was destructive:
                #
                #   -Val False  became $false, which the renderer then OMITS   -> parameter deleted
                #   -Val True   became $true, which renders as a bare -Val     -> unbindable, and
                #               the task fails on every run
                #   -Val 007    became 7                                       -> leading zeros lost
                #
                # There is nothing to gain from the guess. PowerShell hands -File arguments to the
                # script as strings and lets the script's own param() block do the conversion, so
                # keeping the string is both simpler and exactly what the script will receive.
                #
                # A genuine Boolean can still arrive: -Val:$false is handled above, where the
                # colon makes the intent explicit, and a bare -Val is handled in the branch above
                # this one. Those are the only two forms that can honestly mean a switch.
                #
                # No comma-splitting either. $next has already been through the tokeniser, so a
                # comma in it was inside quotes and is part of the value.
                $params[$name] = $next
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
