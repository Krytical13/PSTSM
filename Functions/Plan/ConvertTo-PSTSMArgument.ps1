# SPDX-License-Identifier: GPL-3.0-or-later
function ConvertTo-PSTSMArgument {
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
        Optional Get-PSTSMScriptProfile output. Used only so a switch that defaults to $true
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
        ConvertTo-PSTSMArgument -ScriptPath 'D:\Scripts\Send-Mail.ps1' `
                                 -Parameters ([ordered]@{ SmtpServer = 'mail.contoso.com'; DaysOut = 14; TestMode = $true })

        -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "D:\Scripts\Send-Mail.ps1" -SmtpServer mail.contoso.com -DaysOut 14 -TestMode

        Only values that need quoting get quoted, so the preview stays readable.
    .EXAMPLE
        ConvertTo-PSTSMArgument -ScriptPath 'C:\My Scripts\Run.ps1' `
                                 -Parameters ([ordered]@{ OutDir = 'C:\My Logs\'; Note = 'said "hi"' })

        ... -File "C:\My Scripts\Run.ps1" -OutDir "C:\My Logs\\" -Note "said \"hi\""

        The doubled trailing backslash and the escaped quotes are what CreateProcess needs to
        deliver the original values; PowerShell receives C:\My Logs\ and said "hi".

        Note the doubling only appears once a value is quoted at all. 'C:\Logs\' has no space in
        it, so it emits bare as -OutDir C:\Logs\ and needs no escaping.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [System.Collections.IDictionary]$Parameters,

        [object]$ScriptProfile,

        # Names of [switch]$X = $true parameters, so an unticked one is rendered -X:$false
        # instead of being omitted. A plan carries this, which is what makes it work after an
        # export/import onto a machine where the script is not present.
        [string[]]$SwitchDefaultTrue,

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
    $parts.Add("-File $(ConvertTo-PSTSMQuotedValue -Value $ScriptPath -AlwaysQuote)")

    if ($Parameters) {
        # Which switches the script declares as [switch]$X = $true, so an unticked one is written
        # -X:$false rather than omitted. Omitting it would let the script's own default turn it
        # back ON, which is the opposite of what the operator asked for.
        #
        # -SwitchDefaultTrue is the path that actually gets used: the plan carries the list, so it
        # survives export/import and needs no access to the script at registration time. The
        # -ScriptProfile form is kept for direct callers who already have a profile in hand - and
        # because it was the only form for a while, during which no production caller passed it
        # and the whole branch was dead.
        $switchDefaults = @{}
        foreach ($n in @($SwitchDefaultTrue)) {
            if ($n) { $switchDefaults[$n] = $true }
        }
        if ($ScriptProfile -and $ScriptProfile.Parameters) {
            foreach ($sp in $ScriptProfile.Parameters) {
                if ($sp.IsSwitch -and $sp.HasDefault -and $sp.DefaultKind -eq 'Literal' -and
                    $null -ne $sp.ResolvedDefault -and [bool]$sp.ResolvedDefault.Value) {
                    $switchDefaults[$sp.Name] = $true
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
                elseif ($switchDefaults.ContainsKey($key)) {
                    # Script defaults this on; omitting would silently leave it on.
                    $parts.Add("-${key}:`$false")
                }
                continue
            }

            # --- arrays ---
            if ($value -is [array] -or ($value -is [System.Collections.IEnumerable] -and $value -isnot [string])) {
                $items = @($value | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-PSTSMQuotedValue -Value $_ })
                if ($items.Count -eq 0) { continue }
                $parts.Add("-$key $($items -join ',')")
                continue
            }

            $parts.Add("-$key $(ConvertTo-PSTSMQuotedValue -Value $value)")
        }
    }

    if ($ExtraArguments -and $ExtraArguments.Trim()) {
        $parts.Add($ExtraArguments.Trim())
    }

    $parts -join ' '
}

function ConvertTo-PSTSMQuotedValue {
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
