# SPDX-License-Identifier: GPL-3.0-or-later
function ConvertTo-PSTaskArgument {
    <#
    .SYNOPSIS
        Builds the exact argument string Task Scheduler will hand to powershell.exe / pwsh.exe.
    .DESCRIPTION
        This is the piece every hand-rolled task gets wrong. The rules it enforces:

          -NoProfile        the scheduled account's profile is usually absent or, worse,
                            present and different from yours. Also saves ~200ms per run.
          -NonInteractive   turns a prompt into a fast, logged error instead of a task that
                            sits at 'Running' forever holding the next run off.
          -ExecutionPolicy  set per-process; does not touch machine policy.
          -File             NOT -Command. -File passes arguments verbatim and, critically,
                            propagates the script's exit code to Task Scheduler's Last Run
                            Result. -Command re-parses the string (so a path with a space or
                            an apostrophe breaks) and returns 0 even when the script threw.

        -File must be the last engine switch: everything after the script path belongs to the
        script, so the order here is deliberate.

        Values are quoted with the CommandLineToArgvW rules that CreateProcess actually applies
        - embedded quotes escaped as \" and any run of backslashes doubled before a quote or
        end-of-argument. That is what makes C:\Logs\ and O'Brien and -Message "a b" survive.
    .PARAMETER ScriptPath
        Full path to the .ps1.
    .PARAMETER Parameters
        Ordered dictionary of parameter name -> value. $null values are omitted.
    .PARAMETER ScriptProfile
        Optional Get-PSTaskScriptProfile output. Used only so a switch that defaults to $true
        in the script but is set to $false here emits -Name:$false instead of being dropped.
    .PARAMETER ExtraArguments
        Free-text appended verbatim after the generated parameters. Escape hatch for anything
        the form cannot express.
    .PARAMETER ExecutionPolicy
        Per-process execution policy. 'None' omits the switch entirely.
    .PARAMETER NoProfile
        Emit -NoProfile. Default $true.
    .PARAMETER NonInteractive
        Emit -NonInteractive. Default $true.
    .PARAMETER WindowStyle
        Emit -WindowStyle. 'None' omits it. Default 'Hidden', which suppresses the console
        flash for tasks that run while the user is logged on and is inert otherwise.
    .OUTPUTS
        [string]
    .EXAMPLE
        ConvertTo-PSTaskArgument -ScriptPath 'D:\Scripts\Send-Mail.ps1' `
                                 -Parameters ([ordered]@{ SmtpServer = 'mail.contoso.com'; DaysOut = 14; TestMode = $true })

        -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "D:\Scripts\Send-Mail.ps1" -SmtpServer mail.contoso.com -DaysOut 14 -TestMode

        Only values that need quoting get quoted, so the preview stays readable.
    .EXAMPLE
        ConvertTo-PSTaskArgument -ScriptPath 'C:\My Scripts\Run.ps1' `
                                 -Parameters ([ordered]@{ OutDir = 'C:\Logs\'; Note = 'said "hi"' })

        ... -File "C:\My Scripts\Run.ps1" -OutDir "C:\Logs\\" -Note "said \"hi\""

        The doubled trailing backslash and the escaped quotes are what CreateProcess needs to
        deliver the original values; PowerShell receives C:\Logs\ and said "hi".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [System.Collections.IDictionary]$Parameters,

        [object]$ScriptProfile,

        [string]$ExtraArguments,

        [ValidateSet('Bypass', 'RemoteSigned', 'AllSigned', 'Restricted', 'Unrestricted', 'Default', 'Undefined', 'None')]
        [string]$ExecutionPolicy = 'Bypass',

        [bool]$NoProfile = $true,

        [bool]$NonInteractive = $true,

        [ValidateSet('None', 'Hidden', 'Minimized', 'Normal', 'Maximized')]
        [string]$WindowStyle = 'Hidden'
    )

    $parts = New-Object System.Collections.Generic.List[string]

    if ($NoProfile) { $parts.Add('-NoProfile') }
    if ($NonInteractive) { $parts.Add('-NonInteractive') }
    if ($ExecutionPolicy -ne 'None') { $parts.Add("-ExecutionPolicy $ExecutionPolicy") }
    if ($WindowStyle -ne 'None') { $parts.Add("-WindowStyle $WindowStyle") }

    # -File last: everything after it is the script's.
    $parts.Add("-File $(ConvertTo-PSTaskQuotedValue -Value $ScriptPath -AlwaysQuote)")

    if ($Parameters) {
        # Look up declared switch defaults once so we know when $false must be explicit.
        $switchDefaultTrue = @{}
        if ($ScriptProfile -and $ScriptProfile.Parameters) {
            foreach ($sp in $ScriptProfile.Parameters) {
                if ($sp.IsSwitch -and $sp.DefaultValue -and $sp.DefaultValue -match '(?i)\$true') {
                    $switchDefaultTrue[$sp.Name] = $true
                }
            }
        }

        foreach ($key in $Parameters.Keys) {
            $value = $Parameters[$key]
            if ($null -eq $value) { continue }

            # --- switches / booleans ---
            if ($value -is [bool] -or $value -is [System.Management.Automation.SwitchParameter]) {
                $isTrue = [bool]$value
                if ($isTrue) {
                    $parts.Add("-$key")
                }
                elseif ($switchDefaultTrue.ContainsKey($key)) {
                    # Script defaults this on; omitting would silently leave it on.
                    $parts.Add("-${key}:`$false")
                }
                continue
            }

            # --- arrays ---
            if ($value -is [array] -or ($value -is [System.Collections.IEnumerable] -and $value -isnot [string])) {
                $items = @($value | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-PSTaskQuotedValue -Value $_ })
                if ($items.Count -eq 0) { continue }
                $parts.Add("-$key $($items -join ',')")
                continue
            }

            $parts.Add("-$key $(ConvertTo-PSTaskQuotedValue -Value $value)")
        }
    }

    if ($ExtraArguments -and $ExtraArguments.Trim()) {
        $parts.Add($ExtraArguments.Trim())
    }

    $parts -join ' '
}

function ConvertTo-PSTaskQuotedValue {
    <#
    .SYNOPSIS
        Quotes a single command-line value using the rules CreateProcess/CommandLineToArgvW
        actually apply.
    .DESCRIPTION
        Numbers and simple tokens pass through bare so the preview stays readable. Anything
        containing whitespace, a quote, or a shell-significant character is wrapped, with:
          - each run of backslashes preceding a double quote doubled, then the quote escaped
          - each run of trailing backslashes doubled, so C:\Logs\ does not escape the closing
            quote and swallow the next argument
    .PARAMETER Value
        The value to render.
    .PARAMETER AlwaysQuote
        Quote even when the value looks safe. Used for the script path so the preview always
        shows it the way it will be registered.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value,

        [switch]$AlwaysQuote
    )

    if ($null -eq $Value) { return '""' }

    if ($Value -is [datetime]) { $text = $Value.ToString('yyyy-MM-ddTHH:mm:ss') }
    elseif ($Value -is [bool]) { $text = if ($Value) { '$true' } else { '$false' } }
    else { $text = [string]$Value }

    if ($text -eq '') { return '""' }

    # Bare numbers stay bare; PowerShell coerces quoted numerics fine either way, but an
    # unquoted 14 reads better in the preview pane than "14".
    if (-not $AlwaysQuote -and $text -match '^-?\d+(\.\d+)?$') { return $text }

    # $true / $false must not be quoted or they arrive as the strings "True"/"False".
    if (-not $AlwaysQuote -and $text -match '^\$(true|false)$') { return $text }

    if (-not $AlwaysQuote -and $text -notmatch '[\s"''`$&|<>^,;(){}\[\]]') { return $text }

    $escaped = [regex]::Replace($text, '(\\*)"', '$1$1\"')      # \ runs before a quote, then the quote
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')     # trailing \ runs before the closing quote

    '"' + $escaped + '"'
}
