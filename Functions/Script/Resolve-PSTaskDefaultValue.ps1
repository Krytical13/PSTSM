function Resolve-PSTaskDefaultValue {
    <#
    .SYNOPSIS
        Works out what a parameter's default expression will evaluate to, WITHOUT executing it.
    .DESCRIPTION
        A script's most useful defaults are usually expressions, not literals:

            [string]$LogDirectory = (Join-Path $env:ProgramData 'Acme\Logs')
            [string]$ConfigPath   = (Join-Path $PSScriptRoot 'settings.psd1')

        Showing those as empty boxes makes the form look like it does not know something it
        could easily tell you. Evaluating them, though, means running arbitrary code out of a
        file the operator may not have written and is only inspecting - a default could just as
        easily be (Get-Content C:\secrets\key.txt) or (Invoke-RestMethod ...). This tool must
        never be a way to execute a script by opening it.

        So this walks the AST and computes the value only for a small, provably side-effect-free
        shape:

            string / number / boolean literals
            $PSScriptRoot, $PSCommandPath
            $env:ANYTHING
            Join-Path, where every argument is itself resolvable
            "interpolated $env:strings" whose every nested expression is one of the above
            + concatenation and @(...) arrays of the above

        Anything else - a command call, a method invocation, arithmetic on a function result -
        is reported as Unresolved with its source text, so the UI can still show the operator
        what the script will do without anything being run.

        Even a resolvable value is only ever DISPLAYED. It is not put on the command line: the
        script computes the same thing at run time, and passing a value the operator never chose
        would freeze anything time-dependent and hide where the value came from.
    .PARAMETER Expression
        The default's source text, as captured by Get-PSTaskScriptProfile.
    .PARAMETER ScriptPath
        Path of the script the default came from, so $PSScriptRoot and $PSCommandPath resolve.
    .OUTPUTS
        [pscustomobject] Kind ('Literal' | 'Resolved' | 'Unresolved'), Value, Text
    .EXAMPLE
        Resolve-PSTaskDefaultValue -Expression "(Join-Path `$PSScriptRoot 'settings.psd1')" -ScriptPath 'C:\s\Run.ps1'
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Expression,

        [string]$ScriptPath
    )

    $unresolved = [PSCustomObject]@{
        PSTypeName = 'PSTaskBuilder.DefaultValue'
        Kind       = 'Unresolved'
        Value      = $null
        Text       = $Expression
    }

    if ([string]::IsNullOrWhiteSpace($Expression)) { return $unresolved }

    $scriptRoot = if ($ScriptPath) { Split-Path -Path $ScriptPath -Parent } else { $null }

    $errors = $null
    $ast = $null
    try { $ast = [System.Management.Automation.Language.Parser]::ParseInput($Expression, [ref]$null, [ref]$errors) }
    catch { return $unresolved }
    if ($errors -and $errors.Count -gt 0) { return $unresolved }

    # Unwrap "<expr>" down to the expression itself.
    $expr = $null
    try {
        $statement = $ast.EndBlock.Statements[0]
        if ($statement -is [System.Management.Automation.Language.PipelineAst] -and
            $statement.PipelineElements.Count -eq 1 -and
            $statement.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
            $expr = $statement.PipelineElements[0].Expression
        }
        elseif ($statement -is [System.Management.Automation.Language.PipelineAst] -and
            $statement.PipelineElements.Count -eq 1) {
            $expr = $statement.PipelineElements[0]
        }
    }
    catch { return $unresolved }
    if (-not $expr) { return $unresolved }

    # Recursive resolver. Returns a hashtable so 'resolved to $null / empty string' stays
    # distinguishable from 'could not resolve'.
    $resolve = {
        param($node)

        # Unwrap parentheses. The element inside is a CommandExpressionAst for a value like
        # ('x'), but a CommandAst for a call like (Join-Path a b) - and a CommandAst has no
        # .Expression, so assuming one silently produced $null and lost every Join-Path default.
        while ($node -is [System.Management.Automation.Language.ParenExpressionAst]) {
            $element = $node.Pipeline.PipelineElements[0]
            if ($element -is [System.Management.Automation.Language.CommandExpressionAst]) { $node = $element.Expression }
            else { $node = $element }
        }
        if (-not $node) { return @{ Ok = $false } }

        # --- literals ---
        if ($node -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            return @{ Ok = $true; Value = $node.Value; Literal = $true }
        }
        if ($node -is [System.Management.Automation.Language.ConstantExpressionAst]) {
            return @{ Ok = $true; Value = $node.Value; Literal = $true }
        }

        # --- variables: only the ones with no side effects and a knowable value ---
        if ($node -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $path = $node.VariablePath.UserPath
            if ($path -match '^(?i)env:(.+)$') {
                $envName = $Matches[1]
                $envValue = [Environment]::GetEnvironmentVariable($envName)
                if ($null -eq $envValue) { return @{ Ok = $false } }
                return @{ Ok = $true; Value = $envValue; Literal = $false }
            }
            if ($path -eq 'PSScriptRoot' -and $scriptRoot) { return @{ Ok = $true; Value = $scriptRoot; Literal = $false } }
            if ($path -eq 'PSCommandPath' -and $ScriptPath) { return @{ Ok = $true; Value = $ScriptPath; Literal = $false } }
            if ($path -eq 'true') { return @{ Ok = $true; Value = $true; Literal = $true } }
            if ($path -eq 'false') { return @{ Ok = $true; Value = $false; Literal = $true } }
            return @{ Ok = $false }
        }

        # --- "text $env:VAR more" ---
        # Safe only when every nested expression is itself safe; verified through the AST first,
        # then substituted textually, so nothing is ever handed to the engine to evaluate.
        if ($node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
            $text = $node.Value
            foreach ($nested in $node.NestedExpressions) {
                $inner = & $resolve $nested
                if (-not $inner.Ok) { return @{ Ok = $false } }
                $text = $text.Replace($nested.Extent.Text, [string]$inner.Value)
            }
            return @{ Ok = $true; Value = $text; Literal = $false }
        }

        # --- 'a' + 'b' ---
        if ($node -is [System.Management.Automation.Language.BinaryExpressionAst] -and
            $node.Operator -eq [System.Management.Automation.Language.TokenKind]::Plus) {
            $l = & $resolve $node.Left
            $r = & $resolve $node.Right
            if (-not $l.Ok -or -not $r.Ok) { return @{ Ok = $false } }
            return @{ Ok = $true; Value = ("$($l.Value)" + "$($r.Value)"); Literal = $false }
        }

        # --- @('a','b') ---
        if ($node -is [System.Management.Automation.Language.ArrayLiteralAst]) {
            $items = @()
            foreach ($el in $node.Elements) {
                $inner = & $resolve $el
                if (-not $inner.Ok) { return @{ Ok = $false } }
                $items += $inner.Value
            }
            return @{ Ok = $true; Value = $items; Literal = $false }
        }
        if ($node -is [System.Management.Automation.Language.ArrayExpressionAst]) {
            $items = @()
            foreach ($st in $node.SubExpression.Statements) {
                foreach ($pe in $st.PipelineElements) {
                    $inner = & $resolve $pe.Expression
                    if (-not $inner.Ok) { return @{ Ok = $false } }
                    $items += $inner.Value
                }
            }
            return @{ Ok = $true; Value = $items; Literal = $false }
        }

        # --- Join-Path only ---
        # Deliberately a one-command allow-list. It covers the overwhelming majority of real
        # path defaults, and every other command is a potential side effect.
        if ($node -is [System.Management.Automation.Language.CommandAst]) {
            $name = $node.GetCommandName()
            if ($name -notmatch '(?i)^Join-Path$') { return @{ Ok = $false } }

            $parts = @()
            for ($i = 1; $i -lt $node.CommandElements.Count; $i++) {
                $el = $node.CommandElements[$i]
                # Skip -Path / -ChildPath names; the positional values are what matter.
                if ($el -is [System.Management.Automation.Language.CommandParameterAst]) { continue }
                $inner = & $resolve $el
                if (-not $inner.Ok) { return @{ Ok = $false } }
                $parts += [string]$inner.Value
            }
            if ($parts.Count -lt 2) { return @{ Ok = $false } }

            $joined = $parts[0]
            for ($i = 1; $i -lt $parts.Count; $i++) { $joined = Join-Path $joined $parts[$i] }
            return @{ Ok = $true; Value = $joined; Literal = $false }
        }

        @{ Ok = $false }
    }

    $result = & $resolve $expr
    if (-not $result.Ok) { return $unresolved }

    [PSCustomObject]@{
        PSTypeName = 'PSTaskBuilder.DefaultValue'
        Kind       = $(if ($result.Literal) { 'Literal' } else { 'Resolved' })
        Value      = $result.Value
        Text       = $Expression
    }
}
