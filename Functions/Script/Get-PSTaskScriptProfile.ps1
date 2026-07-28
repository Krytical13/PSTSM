function Get-PSTaskScriptProfile {
    <#
    .SYNOPSIS
        Reads a .ps1 and derives everything a scheduled task needs to know about it: engine,
        parameters, elevation, help text, and the behavioural signals that decide whether it
        can survive running unattended.
    .DESCRIPTION
        This is the "select the script and the form fills itself in" half of PSTaskBuilder.
        It never executes the script - everything comes from the abstract syntax tree, so it is
        safe to point at anything.

        Derived:
          Engine          - from #Requires -Version / -PSEdition, else the machine default.
          Elevation       - from #Requires -RunAsAdministrator.
          Modules         - from #Requires -Modules.
          Parameters      - from the param() block, including type, mandatory, default and
                            ValidateSet, so the UI can render real controls instead of asking
                            for an argument string.
          Description     - from .SYNOPSIS in comment-based help.
          Signals         - command/AST patterns that predict unattended failure (see below).

        Signals collected (consumed by Test-PSTaskPlan):
          InteractiveCommands - Read-Host, Get-Credential, Out-GridView, Pause and friends.
          NetworkCommands     - anything that authenticates outbound, which is what makes the
                                S4U ("no password stored") logon type fail at 3am.
          UncPaths            - literal \\server\share references, same reason.
          HasExitStatement    - whether Task Scheduler's "Last Run Result" will mean anything.
          UsesWriteHost       - output that goes nowhere unattended.
    .PARAMETER Path
        Path to the .ps1 to inspect.
    .PARAMETER DefaultEngineId
        Engine to assume when the script states no requirement. Defaults to 'powershell'
        (Windows PowerShell 5.1) because that is the compatible choice for the AD/Exchange
        style scripts these tasks usually run. Reported as Confidence = 'Default' so the UI
        can show it as an assumption rather than a fact.
    .OUTPUTS
        [pscustomobject] - see the object built at the end of this function.
    .EXAMPLE
        $p = Get-PSTaskScriptProfile -Path .\Send-UserPassExpMail.ps1
        $p.Parameters | Format-Table Name, TypeName, IsMandatory, DefaultValue
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [ValidateSet('powershell', 'pwsh')]
        [string]$DefaultEngineId = 'powershell'
    )

    $resolved = $null
    try { $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath }
    catch { Write-Verbose "Could not resolve '$Path': $($_.Exception.Message)" }

    if (-not $resolved -or -not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Script not found: $Path"
    }

    $item = Get-Item -LiteralPath $resolved

    # --- Parse ------------------------------------------------------------------------
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($resolved, [ref]$tokens, [ref]$parseErrors)

    $errorMessages = @()
    if ($parseErrors) {
        $errorMessages = @($parseErrors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" })
    }

    # --- #Requires --------------------------------------------------------------------
    $req = $ast.ScriptRequirements
    $requiredVersion = if ($req) { $req.RequiredPSVersion } else { $null }
    $requiredEditions = if ($req -and $req.RequiredPSEditions) { @($req.RequiredPSEditions) } else { @() }
    $elevationRequired = [bool]($req -and $req.IsElevationRequired)
    $requiredModules = @()
    if ($req -and $req.RequiredModules) {
        $requiredModules = @($req.RequiredModules | ForEach-Object {
                [PSCustomObject]@{
                    Name    = $_.Name
                    Version = if ($_.Version) { $_.Version.ToString() } elseif ($_.RequiredVersion) { $_.RequiredVersion.ToString() } else { $null }
                }
            })
    }

    # --- Engine selection -------------------------------------------------------------
    # 'Required' means the script said so and the choice is not ours to make.
    $engineId = $DefaultEngineId
    $engineConfidence = 'Default'
    $engineReason = "script states no version or edition requirement; defaulting to $DefaultEngineId"

    if ($requiredEditions -contains 'Core') {
        $engineId = 'pwsh'; $engineConfidence = 'Required'
        $engineReason = '#Requires -PSEdition Core'
    }
    elseif ($requiredEditions -contains 'Desktop') {
        $engineId = 'powershell'; $engineConfidence = 'Required'
        $engineReason = '#Requires -PSEdition Desktop'
    }
    elseif ($requiredVersion -and $requiredVersion.Major -ge 6) {
        $engineId = 'pwsh'; $engineConfidence = 'Required'
        $engineReason = "#Requires -Version $requiredVersion"
    }
    elseif ($requiredVersion -and $requiredVersion.Major -le 5) {
        # 5.1 runs on both engines, so this is a floor, not a ceiling - keep the default but
        # record that we saw it.
        $engineConfidence = 'Inferred'
        $engineReason = "#Requires -Version $requiredVersion is satisfied by $DefaultEngineId"
    }

    # --- Comment-based help -----------------------------------------------------------
    # PowerShell's help parser treats contiguous '#' comment lines immediately after the
    # <# ... #> block as a continuation of its last section. In practice that means a
    # '#Requires -Version 5.1' sitting under the help block gets appended to whatever the
    # final .PARAMETER or .DESCRIPTION was, so it has to be stripped back out here.
    function Get-PSTaskCleanHelpText([string]$text) {
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        $t = ($text -replace '\s+', ' ').Trim()
        $t = $t -replace '(?i)\s*Requires\s+-(Version|Modules|PSEdition|RunAsAdministrator|Assembly|ShellId|PSSnapin)\b.*$', ''
        $t = $t.Trim()
        if ($t -eq '') { return $null }
        $t
    }

    $synopsis = $null
    $helpDescription = $null
    $paramHelp = @{}
    try {
        $help = $ast.GetHelpContent()
        if ($help) {
            $synopsis = Get-PSTaskCleanHelpText $help.Synopsis
            $helpDescription = Get-PSTaskCleanHelpText $help.Description
            if ($help.Parameters) {
                foreach ($k in $help.Parameters.Keys) {
                    $paramHelp[$k] = Get-PSTaskCleanHelpText $help.Parameters[$k]
                }
            }
        }
    }
    catch { Write-Verbose "Could not read comment-based help: $($_.Exception.Message)" }

    # --- param() block ----------------------------------------------------------------
    $parameters = New-Object System.Collections.Generic.List[object]

    if ($ast.ParamBlock -and $ast.ParamBlock.Parameters) {
        foreach ($p in $ast.ParamBlock.Parameters) {
            $name = $p.Name.VariablePath.UserPath

            $typeName = 'Object'
            $fullType = 'System.Object'
            if ($p.StaticType) {
                $typeName = $p.StaticType.Name
                $fullType = $p.StaticType.FullName
            }
            $isSwitch = ($fullType -eq 'System.Management.Automation.SwitchParameter')

            $isMandatory = $false
            $position = $null
            $helpMessage = $null
            $validateSet = @()
            $validateRange = $null
            $aliases = @()

            foreach ($attr in $p.Attributes) {
                if ($attr -isnot [System.Management.Automation.Language.AttributeAst]) { continue }
                $attrName = $attr.TypeName.Name

                switch -Regex ($attrName) {
                    '^Parameter$' {
                        foreach ($na in $attr.NamedArguments) {
                            switch ($na.ArgumentName) {
                                'Mandatory' {
                                    # [Parameter(Mandatory)] omits the value and means $true.
                                    $isMandatory = $na.ExpressionOmitted -or ($na.Argument.Extent.Text -match '(?i)\$true|^1$')
                                }
                                'Position' { $position = $na.Argument.Extent.Text }
                                'HelpMessage' { $helpMessage = $na.Argument.Extent.Text.Trim('"', "'") }
                            }
                        }
                    }
                    '^ValidateSet$' {
                        $validateSet = @($attr.PositionalArguments | ForEach-Object {
                                if ($_.PSObject.Properties['Value']) { $_.Value } else { $_.Extent.Text.Trim('"', "'") }
                            })
                    }
                    '^ValidateRange$' {
                        $vals = @($attr.PositionalArguments | ForEach-Object { $_.Extent.Text })
                        if ($vals.Count -eq 2) { $validateRange = [PSCustomObject]@{ Min = $vals[0]; Max = $vals[1] } }
                    }
                    '^Alias$' {
                        $aliases = @($attr.PositionalArguments | ForEach-Object {
                                if ($_.PSObject.Properties['Value']) { $_.Value } else { $_.Extent.Text.Trim('"', "'") }
                            })
                    }
                }
            }

            # Kept as source text, not evaluated - a default of (Get-Date) must not run here.
            $defaultText = if ($p.DefaultValue) { $p.DefaultValue.Extent.Text } else { $null }

            # UI hints. Path-like parameters get a Browse button; credentials get blocked with
            # an explanation rather than a text box that would store a password in task XML.
            $isPathLike = ($typeName -eq 'String' -or $typeName -eq 'String[]') -and
                          ($name -match '(?i)(path|file|folder|directory|dir|location|share)$')
            $isCredential = ($fullType -eq 'System.Management.Automation.PSCredential')
            $isSecure = ($fullType -eq 'System.Security.SecureString')

            $desc = $null
            foreach ($k in $paramHelp.Keys) {
                if ($k -eq $name -or $k -eq $name.ToUpperInvariant()) { $desc = $paramHelp[$k]; break }
            }
            if (-not $desc -and $helpMessage) { $desc = $helpMessage }

            $parameters.Add([PSCustomObject]@{
                    Name          = $name
                    TypeName      = $typeName
                    FullTypeName  = $fullType
                    IsSwitch      = $isSwitch
                    IsMandatory   = $isMandatory
                    DefaultValue  = $defaultText
                    HasDefault    = [bool]$defaultText
                    ValidateSet   = $validateSet
                    ValidateRange = $validateRange
                    Aliases       = $aliases
                    Position      = $position
                    Description   = $desc
                    IsPathLike    = $isPathLike
                    IsCredential  = $isCredential
                    IsSecure      = $isSecure
                })
        }
    }

    # --- Behavioural signals ----------------------------------------------------------
    $commandNames = @()
    try {
        $commandAsts = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)
        $commandNames = @($commandAsts | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ }) | Select-Object -Unique
    }
    catch { Write-Verbose "Could not enumerate commands: $($_.Exception.Message)" }

    $interactivePattern = '^(Read-Host|Get-Credential|Out-GridView|Pause|Wait-Debugger|Show-Command|Read-SecureString)$'
    $interactive = @($commandNames | Where-Object { $_ -match $interactivePattern })

    # Anything that authenticates outbound. S4U tasks hold no network credentials, so these
    # are exactly the calls that work when you test interactively and fail on the schedule.
    $networkPattern = '^(Connect-\w+|Invoke-RestMethod|Invoke-WebRequest|Invoke-Command|New-PSSession|Enter-PSSession|Send-MailMessage|New-PSDrive|Get-AD\w+|Set-AD\w+|New-AD\w+|Remove-AD\w+|Get-Mailbox|Set-Mailbox|Get-MgUser|Test-NetConnection|Copy-Item)$'
    $network = @($commandNames | Where-Object { $_ -match $networkPattern })

    # Literal UNC paths anywhere in the script's string constants.
    $uncPaths = @()
    try {
        $strings = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)
        $uncPaths = @($strings | Where-Object { $_.Value -match '^\\\\[^\\]+\\' } | ForEach-Object { $_.Value }) | Select-Object -Unique
    }
    catch { Write-Verbose "Could not scan string literals for UNC paths: $($_.Exception.Message)" }

    $hasExit = $false
    try {
        $hasExit = [bool]$ast.Find({ $args[0] -is [System.Management.Automation.Language.ExitStatementAst] }, $true)
        if (-not $hasExit) {
            $hasExit = [bool]$ast.Find({ $args[0] -is [System.Management.Automation.Language.ThrowStatementAst] }, $true)
        }
    }
    catch { Write-Verbose "Could not search for exit/throw statements: $($_.Exception.Message)" }

    $usesGui = @($commandNames | Where-Object { $_ -match '^(Show-\w+Dialog|New-UDDashboard)$' }).Count -gt 0
    if (-not $usesGui) {
        $usesGui = [bool]($ast.Extent.Text -match 'System\.Windows\.Forms|PresentationFramework|System\.Windows\.MessageBox')
    }

    # --- Encoding ---------------------------------------------------------------------
    # Windows PowerShell 5.1 assumes ANSI for files with no BOM, so a UTF-8-no-BOM script
    # containing accented characters or box-drawing output silently mojibakes under
    # powershell.exe while looking perfect in pwsh and in VS Code.
    $hasBom = $false
    $hasNonAscii = $false
    try {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $bytes = Get-Content -LiteralPath $resolved -AsByteStream -TotalCount 4096 -ErrorAction Stop
        }
        else {
            $bytes = Get-Content -LiteralPath $resolved -Encoding Byte -TotalCount 4096 -ErrorAction Stop
        }
        if ($bytes.Count -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $hasBom = $true }
        if ($bytes.Count -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) { $hasBom = $true }
        $hasNonAscii = [bool](@($bytes | Where-Object { $_ -ge 0x80 }).Count -gt 0)
    }
    catch { Write-Verbose "Could not read file bytes for the encoding check: $($_.Exception.Message)" }

    [PSCustomObject]@{
        PSTypeName        = 'PSTaskBuilder.ScriptProfile'

        Path              = $resolved
        FileName          = $item.Name
        BaseName          = $item.BaseName
        Directory         = $item.DirectoryName
        LastWriteTime     = $item.LastWriteTime

        # Suggested task fields - all of these land in the form pre-filled and editable.
        SuggestedTaskName = ($item.BaseName -replace '[\\/:*?"<>|]', '-')
        SuggestedWorkDir  = $item.DirectoryName
        Synopsis          = $synopsis
        HelpDescription   = $helpDescription

        EngineId          = $engineId
        EngineConfidence  = $engineConfidence
        EngineReason      = $engineReason

        RequiresElevation = $elevationRequired
        RequiredVersion   = if ($requiredVersion) { $requiredVersion.ToString() } else { $null }
        RequiredEditions  = $requiredEditions
        RequiredModules   = $requiredModules

        Parameters        = $parameters.ToArray()
        HasParameters     = ($parameters.Count -gt 0)

        Signals           = [PSCustomObject]@{
            InteractiveCommands = $interactive
            NetworkCommands     = $network
            UncPaths            = $uncPaths
            HasExitStatement    = $hasExit
            UsesGui             = $usesGui
            CommandNames        = $commandNames
        }

        Encoding          = [PSCustomObject]@{
            HasBom      = $hasBom
            HasNonAscii = $hasNonAscii
        }

        ParseErrors       = $errorMessages
        IsParseable       = ($errorMessages.Count -eq 0)
    }
}
