# SPDX-License-Identifier: GPL-3.0-or-later
#Requires -Modules Pester

<#
    Unit tests for the PSTSM engine. Nothing here writes to Task Scheduler - no test registers,
    edits or deletes a task, so the suite is safe to run on a working machine. Most checks run
    entirely against fixture scripts in $TestDrive.

    Some tests do READ live Task Scheduler state, deliberately: parsing every task on the machine
    is what caught the tokeniser and health-check bugs that fixtures never would. Those are
    read-only, and they adapt to whatever the machine happens to have rather than requiring
    anything of it.

    Run:  Invoke-Pester -Path .\PSTSM.Tests.ps1

    Covers the parts that are easy to get subtly wrong and expensive to debug later: AST
    derivation, command-line quoting, the parse/render round trip, and the preflight rules.
#>

BeforeAll {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'PSTSM.psd1'
    Import-Module $modulePath -Force

    # --- fixtures ---------------------------------------------------------------------
    $script:StandardScript = Join-Path $TestDrive 'Send-NightlyReport.ps1'
    @'
<#
.SYNOPSIS
    Sends the nightly report to the service desk.
.DESCRIPTION
    Longer description that should not become the task description.
.PARAMETER SmtpServer
    The relay to send through.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SmtpServer,

    [ValidateSet('Low', 'Normal', 'High')]
    [string]$Priority = 'Normal',

    [int]$DaysOut = 14,

    [switch]$TestMode,

    [Alias('Out')]
    [string]$OutputPath = 'C:\Reports'
)

Get-ADUser -Filter *
Invoke-RestMethod -Uri 'https://example.invalid/report'
exit 0
'@ | Set-Content -LiteralPath $script:StandardScript -Encoding UTF8

    $script:AdminScript = Join-Path $TestDrive 'Repair-Thing.ps1'
    @'
#Requires -RunAsAdministrator
param(
    [switch]$Force,
    [switch]$Verbose2 = $true
)
$answer = Read-Host 'Continue?'
'@ | Set-Content -LiteralPath $script:AdminScript -Encoding UTF8

    $script:CoreScript = Join-Path $TestDrive 'Modern.ps1'
    @'
#Requires -Version 7.0
param([string]$Name)
Write-Output $Name
'@ | Set-Content -LiteralPath $script:CoreScript -Encoding UTF8

    $script:QuietScript = Join-Path $TestDrive 'Quiet.ps1'
    @'
param([string]$Message = 'hello')
Set-Content -Path (Join-Path $PSScriptRoot 'out.txt') -Value $Message
exit 0
'@ | Set-Content -LiteralPath $script:QuietScript -Encoding UTF8
}

Describe 'Get-PSTSMScriptProfile' {
    Context 'a standard parameterised script' {
        BeforeAll { $script:p = Get-PSTSMScriptProfile -Path $script:StandardScript }

        It 'parses cleanly' {
            $script:p.IsParseable | Should -BeTrue
            $script:p.ParseErrors.Count | Should -Be 0
        }
        It 'finds every declared parameter' {
            $script:p.Parameters.Count | Should -Be 5
            ($script:p.Parameters | ForEach-Object Name) | Should -Contain 'SmtpServer'
        }
        It 'detects the mandatory parameter' {
            ($script:p.Parameters | Where-Object Name -eq 'SmtpServer').IsMandatory | Should -BeTrue
            ($script:p.Parameters | Where-Object Name -eq 'DaysOut').IsMandatory | Should -BeFalse
        }
        It 'extracts a ValidateSet so the UI can render a combo box' {
            $pr = $script:p.Parameters | Where-Object Name -eq 'Priority'
            $pr.ValidateSet | Should -HaveCount 3
            $pr.ValidateSet | Should -Contain 'High'
        }
        It 'captures declared defaults as source text, unevaluated' {
            ($script:p.Parameters | Where-Object Name -eq 'DaysOut').DefaultValue | Should -Be '14'
            ($script:p.Parameters | Where-Object Name -eq 'Priority').DefaultValue | Should -Be "'Normal'"
        }
        It 'identifies switches' {
            ($script:p.Parameters | Where-Object Name -eq 'TestMode').IsSwitch | Should -BeTrue
            ($script:p.Parameters | Where-Object Name -eq 'SmtpServer').IsSwitch | Should -BeFalse
        }
        It 'reads aliases' {
            ($script:p.Parameters | Where-Object Name -eq 'OutputPath').Aliases | Should -Contain 'Out'
        }
        It 'flags path-like parameters for a Browse button' {
            ($script:p.Parameters | Where-Object Name -eq 'OutputPath').IsPathLike | Should -BeTrue
            ($script:p.Parameters | Where-Object Name -eq 'Priority').IsPathLike | Should -BeFalse
        }
        It 'takes the task description from .SYNOPSIS, not .DESCRIPTION' {
            $script:p.Synopsis | Should -Be 'Sends the nightly report to the service desk.'
        }
        It 'pulls per-parameter help text' {
            ($script:p.Parameters | Where-Object Name -eq 'SmtpServer').Description | Should -Be 'The relay to send through.'
        }
        It 'suggests a task name and working directory' {
            $script:p.SuggestedTaskName | Should -Be 'Send-NightlyReport'
            $script:p.SuggestedWorkDir | Should -Be (Split-Path $script:StandardScript -Parent)
        }
        It 'detects outbound network calls, which is what breaks S4U tasks' {
            $script:p.Signals.NetworkCommands | Should -Contain 'Get-ADUser'
            $script:p.Signals.NetworkCommands | Should -Contain 'Invoke-RestMethod'
        }
        It 'notices the script sets an exit code' {
            $script:p.Signals.HasExitStatement | Should -BeTrue
        }
        It 'treats "#Requires -Version 5.1" as a floor, not a demand for a specific engine' {
            $script:p.EngineId | Should -Be 'powershell'
            $script:p.EngineConfidence | Should -Be 'Inferred'
        }
    }

    Context 'a script that demands elevation and prompts' {
        BeforeAll { $script:a = Get-PSTSMScriptProfile -Path $script:AdminScript }

        It 'reports the elevation requirement' { $script:a.RequiresElevation | Should -BeTrue }
        It 'flags the interactive prompt' { $script:a.Signals.InteractiveCommands | Should -Contain 'Read-Host' }
        It 'notices there is no exit code' { $script:a.Signals.HasExitStatement | Should -BeFalse }
    }

    Context 'a script that requires PowerShell 7' {
        BeforeAll { $script:c = Get-PSTSMScriptProfile -Path $script:CoreScript }

        It 'selects pwsh and marks the choice as non-negotiable' {
            $script:c.EngineId | Should -Be 'pwsh'
            $script:c.EngineConfidence | Should -Be 'Required'
        }
    }

    It 'throws on a path that does not exist' {
        { Get-PSTSMScriptProfile -Path (Join-Path $TestDrive 'nope.ps1') } | Should -Throw '*not found*'
    }
}

Describe 'Resolve-PSTSMDefaultValue' {
    BeforeAll { $script:FakeScript = Join-Path $TestDrive 'Sub\Runner.ps1' }

    It 'reports plain values as literals' {
        (Resolve-PSTSMDefaultValue -Expression "'Normal'").Kind | Should -Be 'Literal'
        (Resolve-PSTSMDefaultValue -Expression "'Normal'").Value | Should -Be 'Normal'
        (Resolve-PSTSMDefaultValue -Expression '14').Value | Should -Be 14
    }

    It 'resolves $PSScriptRoot against the script it came from' {
        $r = Resolve-PSTSMDefaultValue -Expression '(Join-Path $PSScriptRoot ''settings.psd1'')' -ScriptPath $script:FakeScript
        $r.Kind | Should -Be 'Resolved'
        $r.Value | Should -Be (Join-Path (Split-Path $script:FakeScript -Parent) 'settings.psd1')
    }

    It 'resolves environment variables' {
        $r = Resolve-PSTSMDefaultValue -Expression '(Join-Path $env:ProgramData ''Acme\Logs'')'
        $r.Kind | Should -Be 'Resolved'
        $r.Value | Should -Be (Join-Path $env:ProgramData 'Acme\Logs')
    }

    It 'resolves an interpolated string of safe parts' {
        $r = Resolve-PSTSMDefaultValue -Expression '"$env:ProgramData\Acme"'
        $r.Kind | Should -Be 'Resolved'
        $r.Value | Should -Be "$env:ProgramData\Acme"
    }

    It 'refuses to evaluate anything that could have a side effect' {
        # The whole safety argument: this tool is pointed at scripts the operator may not have
        # written, so opening one must never be a way to run it.
        foreach ($e in @(
                '(Get-Content C:\secrets\key.txt)',
                '(Invoke-RestMethod https://example.invalid)',
                '(Get-Date)',
                '(Remove-Item C:\temp -Recurse)',
                '(& $someCommand)',
                '([System.IO.File]::ReadAllText(''C:\x''))'
            )) {
            (Resolve-PSTSMDefaultValue -Expression $e).Kind | Should -Be 'Unresolved'
            (Resolve-PSTSMDefaultValue -Expression $e).Value | Should -BeNullOrEmpty
        }
    }

    It 'keeps the source text when it cannot resolve, so it can still be shown' {
        $r = Resolve-PSTSMDefaultValue -Expression '(Get-Date).AddDays(-7)'
        $r.Kind | Should -Be 'Unresolved'
        $r.Text | Should -Be '(Get-Date).AddDays(-7)'
    }

    It 'does not resolve an unset environment variable to an empty path' {
        (Resolve-PSTSMDefaultValue -Expression '$env:PSTSM_NOT_SET_ANYWHERE').Kind | Should -Be 'Unresolved'
    }
}

Describe 'ConvertTo-PSTSMQuotedValue' {
    It 'leaves a simple token bare so the preview stays readable' {
        ConvertTo-PSTSMQuotedValue -Value 'simple' | Should -Be 'simple'
    }
    It 'leaves numbers bare' {
        ConvertTo-PSTSMQuotedValue -Value 14 | Should -Be '14'
        ConvertTo-PSTSMQuotedValue -Value -3 | Should -Be '-3'
    }
    It 'quotes anything containing whitespace' {
        ConvertTo-PSTSMQuotedValue -Value 'has space' | Should -Be '"has space"'
    }
    It 'doubles a trailing backslash so it cannot escape the closing quote' {
        # Without this, C:\Logs\ swallows the next argument.
        ConvertTo-PSTSMQuotedValue -Value 'C:\Logs\' -AlwaysQuote | Should -Be '"C:\Logs\\"'
    }
    It 'escapes embedded double quotes' {
        ConvertTo-PSTSMQuotedValue -Value 'said "hi"' | Should -Be '"said \"hi\""'
    }
    It 'renders an empty value as an explicit empty string' {
        ConvertTo-PSTSMQuotedValue -Value '' | Should -Be '""'
    }
    It 'quotes on demand even when the value looks safe' {
        ConvertTo-PSTSMQuotedValue -Value 'safe' -AlwaysQuote | Should -Be '"safe"'
    }
    It 'keeps $true unquoted so it does not arrive as the string "True"' {
        ConvertTo-PSTSMQuotedValue -Value $true | Should -Be '$true'
    }
}

Describe 'ConvertTo-PSTSMArgument' {
    BeforeAll {
        $script:args1 = ConvertTo-PSTSMArgument -ScriptPath 'C:\My Scripts\Run.ps1' -Parameters ([ordered]@{
                SmtpServer = 'mail.contoso.com'
                DaysOut    = 14
                TestMode   = $true
                Skipped    = $false
                Nothing    = $null
            })
    }

    It 'always leads with -NoProfile and -NonInteractive' {
        $script:args1 | Should -BeLike '-NoProfile -NonInteractive *'
    }
    It 'sets the execution policy per process' {
        $script:args1 | Should -BeLike '*-ExecutionPolicy Bypass*'
    }
    It 'uses -File, never -Command' {
        $script:args1 | Should -BeLike '*-File *'
        $script:args1 | Should -Not -BeLike '*-Command*'
    }
    It 'quotes a script path containing spaces' {
        $script:args1 | Should -BeLike '*-File "C:\My Scripts\Run.ps1"*'
    }
    It 'puts -File after every engine switch, so the rest belongs to the script' {
        $fileIdx = $script:args1.IndexOf('-File')
        $script:args1.IndexOf('-NoProfile') | Should -BeLessThan $fileIdx
        $script:args1.IndexOf('-WindowStyle') | Should -BeLessThan $fileIdx
        $script:args1.IndexOf('-SmtpServer') | Should -BeGreaterThan $fileIdx
    }
    It 'emits a true switch as a bare flag' {
        $script:args1 | Should -BeLike '*-TestMode*'
        $script:args1 | Should -Not -BeLike '*-TestMode `$true*'
    }
    It 'omits a false switch' {
        $script:args1 | Should -Not -BeLike '*-Skipped*'
    }
    It 'omits null values entirely' {
        $script:args1 | Should -Not -BeLike '*-Nothing*'
    }
    It 'refuses a multi-value array instead of emitting one -File cannot deliver' {
        # This test used to assert the comma-joined form, pinning a bug in place. Measured against
        # a real [string[]] parameter, every encoding arrives as ONE element:
        #   -Days Mon,Tue      -> the single string "Mon,Tue"
        #   -Days Mon Tue      -> "Mon" only
        #   -Days "Mon","Tue"  -> one element, quotes included
        # PowerShell splits on commas when it PARSES a command line; under -File the arguments are
        # already tokenised, so nothing splits them. A command line that looks right and delivers
        # the wrong value on every run is worse than a refusal.
        { ConvertTo-PSTSMArgument -ScriptPath 'C:\s.ps1' -Parameters ([ordered]@{ Days = @('Mon', 'Tue') }) } |
            Should -Throw -ExpectedMessage '*-File cannot deliver*'
    }

    It 'still passes a single-element array through as a plain value' {
        # One value survives -File intact, so there is nothing to refuse.
        ConvertTo-PSTSMArgument -ScriptPath 'C:\s.ps1' -Parameters ([ordered]@{ Days = @('Mon') }) |
            Should -BeLike '*-Days Mon*'
    }

    It 'emits -Switch:$false when the script defaults that switch to true' {
        # Otherwise omitting it silently leaves the switch on.
        $prof = Get-PSTSMScriptProfile -Path $script:AdminScript
        $a = ConvertTo-PSTSMArgument -ScriptPath $script:AdminScript `
            -Parameters ([ordered]@{ Verbose2 = $false }) -ScriptProfile $prof
        $a | Should -BeLike '*-Verbose2:$false*'
    }

    It 'honours switch suppression' {
        $a = ConvertTo-PSTSMArgument -ScriptPath 'C:\x.ps1' -NoProfile $false -NonInteractive $false -ExecutionPolicy 'None' -WindowStyle 'None'
        $a | Should -Be '-File "C:\x.ps1"'
    }
}

Describe 'ConvertFrom-PSTSMAction' {
    It 'round-trips what ConvertTo-PSTSMArgument produced' {
        $params = [ordered]@{ SmtpServer = 'mail.contoso.com'; DaysOut = 14; TestMode = $true }
        $rendered = ConvertTo-PSTSMArgument -ScriptPath 'C:\My Scripts\Run.ps1' -Parameters $params

        $parsed = ConvertFrom-PSTSMAction -Execute 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Arguments $rendered

        $parsed.IsPowerShell | Should -BeTrue
        $parsed.IsRecognized | Should -BeTrue
        $parsed.EngineId | Should -Be 'powershell'
        $parsed.ScriptPath | Should -Be 'C:\My Scripts\Run.ps1'
        $parsed.NoProfile | Should -BeTrue
        $parsed.NonInteractive | Should -BeTrue
        $parsed.ExecutionPolicy | Should -Be 'Bypass'
        $parsed.Parameters['SmtpServer'] | Should -Be 'mail.contoso.com'
        $parsed.Parameters['DaysOut'] | Should -Be 14
        $parsed.Parameters['TestMode'] | Should -BeTrue
    }

    It 'understands abbreviated engine switches that real tasks use' {
        $parsed = ConvertFrom-PSTSMAction -Execute 'pwsh.exe' -Arguments '-nop -noni -ex Bypass -File "C:\a.ps1" -X 1'
        $parsed.EngineId | Should -Be 'pwsh'
        $parsed.NoProfile | Should -BeTrue
        $parsed.NonInteractive | Should -BeTrue
        $parsed.ExecutionPolicy | Should -Be 'Bypass'
        $parsed.ScriptPath | Should -Be 'C:\a.ps1'
    }

    It 'recovers a script path from the old -Command "& path" form and flags it' {
        $parsed = ConvertFrom-PSTSMAction -Execute 'powershell.exe' -Arguments '-ExecutionPolicy Bypass -Command "& ''C:\Scripts\Old.ps1'' -Mode Fast"'
        $parsed.ScriptPath | Should -Be 'C:\Scripts\Old.ps1'
        $parsed.IsRecognized | Should -BeTrue
        ($parsed.Notes -join ' ') | Should -BeLike '*-File is safer*'
    }

    It 'refuses to normalise inline -Command code' {
        $parsed = ConvertFrom-PSTSMAction -Execute 'powershell.exe' -Arguments '-Command "Get-Service | Restart-Service"'
        $parsed.IsRecognized | Should -BeFalse
        $parsed.RawArguments | Should -BeLike '*Get-Service*'
    }

    It 'reports a non-PowerShell action rather than guessing' {
        $parsed = ConvertFrom-PSTSMAction -Execute 'C:\Windows\System32\cmd.exe' -Arguments '/c echo hi'
        $parsed.IsPowerShell | Should -BeFalse
        $parsed.IsRecognized | Should -BeFalse
    }

    It 'detects the 32-bit host' {
        $parsed = ConvertFrom-PSTSMAction -Execute 'C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe' -Arguments '-File "C:\a.ps1"'
        $parsed.Bitness | Should -Be 'x86'
    }

    It 'treats a trailing bare switch as $true' {
        $parsed = ConvertFrom-PSTSMAction -Execute 'powershell.exe' -Arguments '-File "C:\a.ps1" -Force'
        $parsed.Parameters['Force'] | Should -BeTrue
    }

    It 'reads the -Switch:$false form' {
        $parsed = ConvertFrom-PSTSMAction -Execute 'powershell.exe' -Arguments '-File "C:\a.ps1" -Force:$false'
        $parsed.Parameters['Force'] | Should -BeFalse
    }
}

Describe 'ConvertFrom-PSTSMDuration' {
    It 'converts ISO 8601 durations Task Scheduler stores' {
        ConvertFrom-PSTSMDuration -Value 'PT4H' | Should -Be '04:00:00'
        ConvertFrom-PSTSMDuration -Value 'PT15M' | Should -Be '00:15:00'
        ConvertFrom-PSTSMDuration -Value 'PT30S' | Should -Be '00:00:30'
        ConvertFrom-PSTSMDuration -Value 'P1D' | Should -Be '1.00:00:00'
        ConvertFrom-PSTSMDuration -Value 'PT1H30M' | Should -Be '01:30:00'
    }
    It 'returns null rather than throwing on absent or malformed input' {
        ConvertFrom-PSTSMDuration -Value $null | Should -BeNullOrEmpty
        ConvertFrom-PSTSMDuration -Value '' | Should -BeNullOrEmpty
        ConvertFrom-PSTSMDuration -Value 'garbage' | Should -BeNullOrEmpty
    }
}

Describe 'New-PSTSMTriggerSpec' {
    It 'normalises a bare time to a full start boundary' {
        (New-PSTSMTriggerSpec -Type Daily -At '07:00').At | Should -BeLike '*T07:00:00'
    }
    It 'requires a time for time-based triggers' {
        { New-PSTSMTriggerSpec -Type Daily } | Should -Throw '*requires -At*'
    }
    It 'requires days for a weekly trigger' {
        { New-PSTSMTriggerSpec -Type Weekly -At '07:00' } | Should -Throw '*DaysOfWeek*'
    }
    It 'rejects a repetition duration with no interval' {
        { New-PSTSMTriggerSpec -Type Daily -At '07:00' -RepetitionDuration '01:00:00' } | Should -Throw '*requires RepetitionInterval*'
    }
    It 'rejects an unparseable timespan' {
        { New-PSTSMTriggerSpec -Type Daily -At '07:00' -RandomDelay 'soon' } | Should -Throw '*not a valid timespan*'
    }
    It 'accepts a startup trigger with no time' {
        (New-PSTSMTriggerSpec -Type AtStartup -Delay '00:02:00').Type | Should -Be 'AtStartup'
    }
}

Describe 'New-PSTSMPlan' {
    It 'fills the plan from the script with no other input' {
        $plan = New-PSTSMPlan -ScriptPath $script:StandardScript
        $plan.TaskName | Should -Be 'Send-NightlyReport'
        $plan.Description | Should -Be 'Sends the nightly report to the service desk.'
        $plan.WorkingDirectory | Should -Be (Split-Path $script:StandardScript -Parent)
        $plan.EngineId | Should -Be 'powershell'
        $plan.TaskPath | Should -Be '\'
    }
    It 'seeds parameters from the script declared defaults' {
        $plan = New-PSTSMPlan -ScriptPath $script:StandardScript
        $plan.Parameters['DaysOut'] | Should -Be 14
        $plan.Parameters['Priority'] | Should -Be 'Normal'
    }
    It 'does not evaluate expression defaults' {
        $plan = New-PSTSMPlan -ScriptPath $script:StandardScript
        # OutputPath default is a literal and survives; nothing executes.
        $plan.Parameters['OutputPath'] | Should -Be 'C:\Reports'
    }
    It 'lets explicit parameters win' {
        $plan = New-PSTSMPlan -ScriptPath $script:StandardScript -Parameters ([ordered]@{ DaysOut = 30 })
        $plan.Parameters['DaysOut'] | Should -Be 30
    }
    It 'raises RunLevel automatically when the script requires elevation' {
        (New-PSTSMPlan -ScriptPath $script:AdminScript).Principal.RunLevel | Should -Be 'Highest'
        (New-PSTSMPlan -ScriptPath $script:StandardScript).Principal.RunLevel | Should -Be 'Limited'
    }
    It 'applies reliability defaults that differ from Task Scheduler own' {
        $s = (New-PSTSMPlan -ScriptPath $script:StandardScript).Settings
        $s.MultipleInstances | Should -Be 'IgnoreNew'
        $s.StartWhenAvailable | Should -BeTrue
        $s.ExecutionTimeLimit | Should -Be '04:00:00'
        $s.DisallowStartIfOnBatteries | Should -BeFalse
    }
    It 'normalises the task folder' {
        (New-PSTSMPlan -ScriptPath $script:StandardScript -TaskPath 'Custom').TaskPath | Should -Be '\Custom\'
    }
    It 'exposes a live ArgumentString that tracks edits' {
        $plan = New-PSTSMPlan -ScriptPath $script:QuietScript
        $plan.Parameters['Message'] = 'changed'
        $plan.ArgumentString | Should -BeLike '*-Message changed*'
    }
    It 'orders parameters the way the script declares them' {
        # Seeding defaults first used to put -Count ahead of the mandatory -Label.
        $plan = New-PSTSMPlan -ScriptPath $script:StandardScript `
            -Parameters ([ordered]@{ SmtpServer = 'mail.contoso.com' })
        $keys = @($plan.Parameters.Keys)
        $keys[0] | Should -Be 'SmtpServer'
        $keys.IndexOf('Priority') | Should -BeLessThan $keys.IndexOf('DaysOut')
    }
}

Describe 'Test-PSTSMPlan' {
    BeforeAll {
        $script:basePlan = New-PSTSMPlan -ScriptPath $script:StandardScript `
            -Parameters ([ordered]@{ SmtpServer = 'mail.contoso.com' }) `
            -Trigger (New-PSTSMTriggerSpec -Type Daily -At '07:00')

        # Built here rather than inside the first It that happens to need it. Two separate tests
        # use this fixture, and creating it in one of them meant the other failed whenever the
        # suite was filtered to a single test - green as a whole, broken in isolation, which is
        # the worst way round.
        $script:DpapiScript = Join-Path $TestDrive 'Uses-Dpapi.ps1'
        @'
param([string]$CredentialPath = 'C:\secrets\api.dat')
$secure = Get-Content -LiteralPath $CredentialPath | ConvertTo-SecureString
exit 0
'@ | Set-Content -LiteralPath $script:DpapiScript -Encoding UTF8
    }

    It 'passes a well-formed plan with no errors' {
        $r = Test-PSTSMPlan -Plan $script:basePlan -SkipExistingTaskCheck
        @($r | Where-Object Severity -eq 'Error') | Should -HaveCount 0
    }
    It 'blocks on a missing mandatory parameter' {
        $plan = New-PSTSMPlan -ScriptPath $script:StandardScript
        $r = Test-PSTSMPlan -Plan $plan -SkipExistingTaskCheck
        ($r | Where-Object Id -eq 'PARAM_MANDATORY').Severity | Should -Be 'Error'
    }
    It 'catches a typo in a parameter name' {
        $plan = New-PSTSMPlan -ScriptPath $script:StandardScript `
            -Parameters ([ordered]@{ SmtpServer = 'x'; DaysOutt = 5 })
        $r = Test-PSTSMPlan -Plan $plan -SkipExistingTaskCheck
        ($r | Where-Object Id -eq 'PARAM_UNKNOWN').Detail | Should -BeLike '*DaysOutt*'
    }
    It 'does not flag common parameters as unknown' {
        $plan = New-PSTSMPlan -ScriptPath $script:StandardScript `
            -Parameters ([ordered]@{ SmtpServer = 'x'; ErrorAction = 'Stop' })
        $r = Test-PSTSMPlan -Plan $plan -SkipExistingTaskCheck
        @($r | Where-Object Id -eq 'PARAM_UNKNOWN') | Should -HaveCount 0
    }
    It 'warns that S4U cannot authenticate to the machines the script talks to' {
        $r = Test-PSTSMPlan -Plan $script:basePlan -SkipExistingTaskCheck
        $c = $r | Where-Object Id -eq 'S4U_NETWORK'
        $c.Severity | Should -Be 'Warning'
        $c.Detail | Should -BeLike '*Get-ADUser*'
        # The wording must not imply the network is unreachable - it is authentication that
        # fails, and S4U presents as ANONYMOUS rather than falling back to the machine account.
        $c.Detail | Should -BeLike '*ANONYMOUS*'
        $c.Recommendation | Should -BeLike '*does NOT fall back to the machine account*'
    }

    It 'warns that S4U cannot decrypt DPAPI-protected secrets' {
        # The non-obvious half of Microsoft's "no access to either the network or encrypted
        # files": the DPAPI master key is unlocked from the password S4U does not have.
        $plan = New-PSTSMPlan -ScriptPath $script:DpapiScript
        $r = Test-PSTSMPlan -Plan $plan -SkipExistingTaskCheck
        ($r | Where-Object Id -eq 'S4U_DPAPI').Severity | Should -Be 'Warning'
    }

    It 'does not flag an explicitly keyed SecureString as DPAPI' {
        # -Key means AES, which survives an S4U logon; only the keyless form is DPAPI.
        $aes = Join-Path $TestDrive 'Uses-Aes.ps1'
        @'
param([byte[]]$Key)
$secure = 'x' | ConvertTo-SecureString -AsPlainText -Force
$blob = $secure | ConvertFrom-SecureString -Key $Key
exit 0
'@ | Set-Content -LiteralPath $aes -Encoding UTF8

        (Get-PSTSMScriptProfile -Path $aes).Signals.DpapiCommands | Should -BeNullOrEmpty
        $r = Test-PSTSMPlan -Plan (New-PSTSMPlan -ScriptPath $aes) -SkipExistingTaskCheck
        @($r | Where-Object Id -eq 'S4U_DPAPI') | Should -HaveCount 0
    }

    It 'does not raise the DPAPI warning for a logon type that has credentials' {
        $plan = New-PSTSMPlan -ScriptPath $script:DpapiScript -LogonType 'Password' -UserId 'CONTOSO\svc_x'
        $r = Test-PSTSMPlan -Plan $plan -SkipExistingTaskCheck
        @($r | Where-Object Id -eq 'S4U_DPAPI') | Should -HaveCount 0
    }
    It 'does not raise the S4U warning for a script that stays local' {
        $plan = New-PSTSMPlan -ScriptPath $script:QuietScript
        $r = Test-PSTSMPlan -Plan $plan -SkipExistingTaskCheck
        @($r | Where-Object Id -eq 'S4U_NETWORK') | Should -HaveCount 0
        ($r | Where-Object Id -eq 'S4U_OK').Severity | Should -Be 'Ok'
    }
    It 'blocks when the script needs elevation the plan does not grant' {
        $plan = New-PSTSMPlan -ScriptPath $script:AdminScript -RunLevel 'Limited'
        $r = Test-PSTSMPlan -Plan $plan -SkipExistingTaskCheck
        ($r | Where-Object Id -eq 'ELEVATION').Severity | Should -Be 'Error'
    }
    It 'blocks a PowerShell 7 script pointed at Windows PowerShell' {
        $plan = New-PSTSMPlan -ScriptPath $script:CoreScript -EngineId 'powershell'
        $r = Test-PSTSMPlan -Plan $plan -SkipExistingTaskCheck
        ($r | Where-Object Id -eq 'ENGINE_VERSION').Severity | Should -Be 'Error'
    }
    It 'warns about an interactive prompt' {
        $plan = New-PSTSMPlan -ScriptPath $script:AdminScript
        $r = Test-PSTSMPlan -Plan $plan -SkipExistingTaskCheck
        ($r | Where-Object Id -eq 'INTERACTIVE').Detail | Should -BeLike '*Read-Host*'
    }
    It 'warns when nothing sets an exit code' {
        $plan = New-PSTSMPlan -ScriptPath $script:AdminScript
        $r = Test-PSTSMPlan -Plan $plan -SkipExistingTaskCheck
        ($r | Where-Object Id -eq 'EXIT_CODE').Severity | Should -Be 'Warning'
    }
    It 'warns about a task with no triggers' {
        $plan = New-PSTSMPlan -ScriptPath $script:QuietScript
        $r = Test-PSTSMPlan -Plan $plan -SkipExistingTaskCheck
        ($r | Where-Object Id -eq 'NO_TRIGGERS').Severity | Should -Be 'Warning'
    }
    It 'treats a gMSA as needing no password and no rotation' {
        # A gMSA registers as LogonType Password with NO password - Task Scheduler fetches the
        # managed one. Modelling it as its own logon type is what stops the "a password is
        # required" rule and the password-rotation warning from applying to it.
        $plan = New-PSTSMPlan -ScriptPath $script:QuietScript -LogonType 'gMSA' -UserId 'CONTOSO\svc_reports$'
        $r = Test-PSTSMPlan -Plan $plan -SkipExistingTaskCheck

        ($r | Where-Object Id -eq 'GMSA_NO_SECRET').Severity | Should -Be 'Ok'
        @($r | Where-Object Id -eq 'PASSWORD_ROTATION') | Should -HaveCount 0
        @($r | Where-Object Id -eq 'S4U_NETWORK') | Should -HaveCount 0
        ($r | Where-Object Id -eq 'BATCH_RIGHT').Recommendation | Should -BeLike '*gMSA almost never has it by default*'
    }

    It 'warns when a gMSA name does not end with $' {
        $plan = New-PSTSMPlan -ScriptPath $script:QuietScript -LogonType 'gMSA' -UserId 'CONTOSO\svc_reports'
        $r = Test-PSTSMPlan -Plan $plan -SkipExistingTaskCheck
        ($r | Where-Object Id -eq 'GMSA_NAME').Severity | Should -Be 'Warning'
    }

    It 'does not warn about the name when the gMSA is correctly suffixed' {
        $plan = New-PSTSMPlan -ScriptPath $script:QuietScript -LogonType 'gMSA' -UserId 'CONTOSO\svc_reports$'
        $r = Test-PSTSMPlan -Plan $plan -SkipExistingTaskCheck
        @($r | Where-Object Id -eq 'GMSA_NAME') | Should -HaveCount 0
    }

    It 'blocks a task that needs administrator rights when the session has none' {
        # Measured, not assumed. Under a genuine UAC-filtered token (TokenElevationType=3,
        # TokenIsElevated=0) RunLevel=Limited registers and RunLevel=Highest returns
        # "Access is denied" - Windows refuses outright rather than silently downgrading, so a
        # caller that cannot elevate deserves a hard stop rather than a bare Win32 error later.
        $system = New-PSTSMPlan -ScriptPath $script:QuietScript -LogonType 'ServiceAccount' -UserId 'SYSTEM'
        $r = Test-PSTSMPlan -Plan $system -SkipExistingTaskCheck -IsElevated $false
        ($r | Where-Object Id -eq 'NEEDS_ELEVATION').Severity | Should -Be 'Error' -Because 'it runs as SYSTEM'

        $highest = New-PSTSMPlan -ScriptPath $script:QuietScript -RunLevel 'Highest'
        $r = Test-PSTSMPlan -Plan $highest -SkipExistingTaskCheck -IsElevated $false
        ($r | Where-Object Id -eq 'NEEDS_ELEVATION').Severity | Should -Be 'Error' -Because 'it runs with highest privileges'

        $group = New-PSTSMPlan -ScriptPath $script:QuietScript -LogonType 'Group' -UserId 'CONTOSO\Operators'
        $r = Test-PSTSMPlan -Plan $group -SkipExistingTaskCheck -IsElevated $false
        ($r | Where-Object Id -eq 'NEEDS_ELEVATION').Severity | Should -Be 'Error' -Because 'it runs for a group'
    }

    It 'downgrades NEEDS_ELEVATION to information for a caller that can elevate on demand' {
        # The UI hands a privileged plan to an elevated helper, so there is nothing for the
        # operator to fix. Left as an Error it would count towards the error total and disable
        # the very Save button that resolves it.
        $highest = New-PSTSMPlan -ScriptPath $script:QuietScript -RunLevel 'Highest'
        $r = Test-PSTSMPlan -Plan $highest -SkipExistingTaskCheck -IsElevated $false -CanElevate
        $check = $r | Where-Object Id -eq 'NEEDS_ELEVATION'
        $check.Severity | Should -Be 'Info'
        @($r | Where-Object { $_.Severity -eq 'Error' }) | Should -HaveCount 0 -Because 'nothing here blocks a save'
    }

    It 'does not mention elevation for a task that runs as you at normal privilege' {
        # This is the case that must keep working unelevated, and the reason the tool no longer
        # demands a UAC prompt just to open: a standard user managing their own scheduled work.
        $plan = New-PSTSMPlan -ScriptPath $script:QuietScript -LogonType 'Interactive' -RunLevel 'Limited'
        $r = Test-PSTSMPlan -Plan $plan -SkipExistingTaskCheck -IsElevated $false
        @($r | Where-Object Id -eq 'NEEDS_ELEVATION') | Should -HaveCount 0
    }

    It 'does not mention elevation when the session already has it' {
        $plan = New-PSTSMPlan -ScriptPath $script:QuietScript -LogonType 'ServiceAccount' -UserId 'SYSTEM'
        $r = Test-PSTSMPlan -Plan $plan -SkipExistingTaskCheck -IsElevated $true
        @($r | Where-Object Id -eq 'NEEDS_ELEVATION') | Should -HaveCount 0
    }

    It 'reports a missing script as a hard error and stops' {
        $plan = New-PSTSMPlan -ScriptPath $script:QuietScript
        $plan.ScriptPath = Join-Path $TestDrive 'gone.ps1'
        $r = Test-PSTSMPlan -Plan $plan -SkipExistingTaskCheck
        $r | Should -HaveCount 1
        $r[0].Id | Should -Be 'SCRIPT_MISSING'
    }
}

Describe 'Settings-file detection' {
    BeforeAll {
        $script:CfgDir = Join-Path $TestDrive 'WithConfig'
        New-Item -ItemType Directory -Path $script:CfgDir -Force | Out-Null

        $script:CfgScript = Join-Path $script:CfgDir 'Run-Reports.ps1'
        @'
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'settings.psd1'),
    [string]$LogDirectory = (Join-Path $env:ProgramData 'Acme\Logs'),
    [string]$OutputPath = 'C:\Out'
)
$cfg = Import-PowerShellDataFile -Path $ConfigPath
exit 0
'@ | Set-Content -LiteralPath $script:CfgScript -Encoding UTF8

        $script:CfgFile = Join-Path $script:CfgDir 'settings.psd1'
        "@{ Recipients = @('a@x'); Threshold = 14 }" | Set-Content -LiteralPath $script:CfgFile -Encoding UTF8
    }

    It 'resolves an expression default without executing anything' {
        $p = Get-PSTSMScriptProfile -Path $script:CfgScript
        $cfgParam = $p.Parameters | Where-Object Name -eq 'ConfigPath'
        $cfgParam.DefaultKind | Should -Be 'Resolved'
        $cfgParam.ResolvedDefault.Value | Should -Be $script:CfgFile

        $logParam = $p.Parameters | Where-Object Name -eq 'LogDirectory'
        $logParam.DefaultKind | Should -Be 'Resolved'
        $logParam.ResolvedDefault.Value | Should -Be (Join-Path $env:ProgramData 'Acme\Logs')
    }

    It 'finds the settings file and reads its keys' {
        $p = Get-PSTSMScriptProfile -Path $script:CfgScript
        @($p.ConfigFiles).Count | Should -Be 1
        $p.ConfigFiles[0].ParameterName | Should -Be 'ConfigPath'
        $p.ConfigFiles[0].Exists | Should -BeTrue
        $p.ConfigFiles[0].Parses | Should -BeTrue
        $p.ConfigFiles[0].Keys | Should -Contain 'Recipients'
    }

    It 'does not mistake an ordinary output path for configuration' {
        $p = Get-PSTSMScriptProfile -Path $script:CfgScript
        @($p.ConfigFiles | Where-Object ParameterName -eq 'OutputPath') | Should -HaveCount 0
    }

    It 'raises no error when the settings file is present and parses' {
        # $TestDrive lives under C:\Users\<you>\AppData\Local\Temp, so the correct verdict here
        # is the in-profile WARNING, not a clean OK - a task running as SYSTEM really could not
        # read this path. Asserting CONFIG_OK would have been asserting a bug.
        $r = Test-PSTSMPlan -Plan (New-PSTSMPlan -ScriptPath $script:CfgScript) -SkipExistingTaskCheck
        @($r | Where-Object Id -in 'CONFIG_MISSING', 'CONFIG_UNPARSEABLE') | Should -HaveCount 0

        $verdict = @($r | Where-Object Id -in 'CONFIG_OK', 'CONFIG_IN_PROFILE')
        $verdict | Should -HaveCount 1
        $verdict[0].Detail | Should -BeLike "*$($script:CfgFile)*"
    }

    It 'warns that a settings file in a user profile is unreadable by the task account' {
        $r = Test-PSTSMPlan -Plan (New-PSTSMPlan -ScriptPath $script:CfgScript) -SkipExistingTaskCheck
        ($r | Where-Object Id -eq 'CONFIG_IN_PROFILE').Severity | Should -Be 'Warning'
    }

    It 'lists the settings keys so the file can be recognised' {
        $p = Get-PSTSMScriptProfile -Path $script:CfgScript
        $p.ConfigFiles[0].Keys | Should -Contain 'Recipients'
    }

    It 'blocks when the settings file is missing' {
        Remove-Item -LiteralPath $script:CfgFile -Force
        try {
            $r = Test-PSTSMPlan -Plan (New-PSTSMPlan -ScriptPath $script:CfgScript) -SkipExistingTaskCheck
            ($r | Where-Object Id -eq 'CONFIG_MISSING').Severity | Should -Be 'Error'
        }
        finally { "@{ Recipients = @('a@x') }" | Set-Content -LiteralPath $script:CfgFile -Encoding UTF8 }
    }

    It 'blocks when the settings file does not parse' {
        Set-Content -LiteralPath $script:CfgFile -Value 'this is not @{ valid' -Encoding UTF8
        try {
            $r = Test-PSTSMPlan -Plan (New-PSTSMPlan -ScriptPath $script:CfgScript) -SkipExistingTaskCheck
            ($r | Where-Object Id -eq 'CONFIG_UNPARSEABLE').Severity | Should -Be 'Error'
        }
        finally { "@{ Recipients = @('a@x') }" | Set-Content -LiteralPath $script:CfgFile -Encoding UTF8 }
    }

    It 'never puts a resolved expression default on the command line' {
        # It is shown in the form as a cue, not passed - the script must evaluate it itself.
        $plan = New-PSTSMPlan -ScriptPath $script:CfgScript
        $plan.Parameters.Contains('ConfigPath') | Should -BeFalse
        $plan.Parameters.Contains('LogDirectory') | Should -BeFalse
        $plan.Parameters['OutputPath'] | Should -Be 'C:\Out'      # literal, so it IS seeded
        $plan.ArgumentString | Should -Not -BeLike '*-ConfigPath*'
    }
}

Describe 'Get-PSTSMTaskOrigin' {
    BeforeAll {
        # Must be inside BeforeAll: a function declared in the Describe body only exists during
        # Pester's DISCOVERY phase, so It blocks would not see it at run time.
        # Only Author, Source and TaskPath are read, so a plain object stands in for a real task.
        function New-FakeTask($path, $author, $source) {
            [PSCustomObject]@{ TaskPath = $path; Author = $author; Source = $source }
        }
    }

    It 'calls anything under \Microsoft\ a Windows task' {
        (Get-PSTSMTaskOrigin -Task (New-FakeTask '\Microsoft\Windows\Defrag\' 'Whatever')).Origin | Should -Be 'Windows'
    }

    It 'treats a resource-string author as Windows even outside \Microsoft\' {
        # Only OS components register an Author that has to be looked up in a DLL.
        (Get-PSTSMTaskOrigin -Task (New-FakeTask '\' '$(@%SystemRoot%\system32\dmclient.dll,-100)')).Origin | Should -Be 'Windows'
    }

    It 'identifies a task a person created' {
        $r = Get-PSTSMTaskOrigin -Task (New-FakeTask '\' 'CONTOSO\alice')
        $r.Origin | Should -Be 'Person'
        $r.Detail | Should -BeLike '*CONTOSO\alice*'
    }

    It 'does not mistake an installer for a person' {
        # These look like DOMAIN\user but are a service and a computer account. Getting this
        # wrong would put every vendor installer in the "somebody here made this" bucket, which
        # is the one bucket that needs to stay trustworthy.
        (Get-PSTSMTaskOrigin -Task (New-FakeTask '\' 'NT AUTHORITY\SYSTEM')).Origin | Should -Be 'App'
        (Get-PSTSMTaskOrigin -Task (New-FakeTask '\' 'WORKGROUP\SOMEPC$')).Origin | Should -Be 'App'
    }

    It 'attributes a vendor string to an application' {
        (Get-PSTSMTaskOrigin -Task (New-FakeTask '\' 'NVIDIA Corporation')).Origin | Should -Be 'App'
        (Get-PSTSMTaskOrigin -Task (New-FakeTask '\' '' 'Zoom Communications, Inc.')).Origin | Should -Be 'App'
    }

    It 'admits when it does not know' {
        (Get-PSTSMTaskOrigin -Task (New-FakeTask '\' '' '')).Origin | Should -Be 'Unknown'
    }

    It 'claims its own tasks first, whatever the author says' {
        $r = Get-PSTSMTaskOrigin -Task (New-FakeTask '\Microsoft\Windows\Foo\' 'Microsoft Corporation') -IsManagedByTool $true
        $r.Origin | Should -Be 'PSTSM'
    }

    It 'classifies every real task on this machine into a known bucket' {
        $inv = @(Get-PSTSMInventory -IncludeMicrosoft -ErrorAction SilentlyContinue)
        if ($inv.Count -eq 0) { Set-ItResult -Skipped -Because 'no tasks on this machine'; return }
        @($inv | Where-Object { $_.Origin -notin 'Windows', 'App', 'Person', 'PSTSM', 'Unknown' }) | Should -BeNullOrEmpty
        @($inv | Where-Object { -not $_.OriginDetail }) | Should -BeNullOrEmpty
    }
}

Describe 'Test-PSTSMHealth' {
    It 'sweeps the machine and returns well-formed findings' {
        $findings = @(Test-PSTSMHealth -PowerShellOnly $false -ErrorAction SilentlyContinue)
        foreach ($f in $findings) {
            $f.Severity | Should -BeIn @('Error', 'Warning', 'Info')
            $f.FullName | Should -Not -BeNullOrEmpty
            $f.Title | Should -Not -BeNullOrEmpty
            $f.Id | Should -Not -BeNullOrEmpty
        }
    }

    It 'does not flag a logon or idle task for having no next run time' {
        # Regression, and the reason the check is narrowed to time-based triggers: a task that
        # fires at logon/idle/startup/on-event has no predictable next run BY NATURE. Flagging
        # those fired on nearly every vendor task - 16 of 28 findings on a stock machine were
        # this one false positive, which is how a health check teaches people to ignore it.
        $findings = @(Test-PSTSMHealth -PowerShellOnly $false -ErrorAction SilentlyContinue)
        $noNext = @($findings | Where-Object Id -eq 'NO_NEXT_RUN')

        foreach ($f in $noNext) {
            $task = Get-ScheduledTask -TaskName $f.TaskName -TaskPath $f.TaskPath -ErrorAction SilentlyContinue
            $timeBased = @($task.Triggers | Where-Object {
                    $null -ne $_ -and $_.CimClass.CimClassName -in @(
                        'MSFT_TaskDailyTrigger', 'MSFT_TaskWeeklyTrigger', 'MSFT_TaskTimeTrigger',
                        'MSFT_TaskMonthlyTrigger', 'MSFT_TaskMonthlyDOWTrigger')
                })
            $timeBased.Count | Should -BeGreaterThan 0 -Because "$($f.FullName) was flagged with no next run, so it must actually have a time-based trigger"
        }
    }

    It 'reports a status code as status, not as a failure' {
        # 0x41300-0x41304 mean ready / running / disabled / never run / no more runs. Treating
        # those as failures would make almost every task on the machine look broken.
        $findings = @(Test-PSTSMHealth -PowerShellOnly $false -ErrorAction SilentlyContinue)
        foreach ($f in @($findings | Where-Object Id -eq 'RUN_FAILED')) {
            $info = Get-ScheduledTaskInfo -TaskName $f.TaskName -TaskPath $f.TaskPath -ErrorAction SilentlyContinue
            $u = [uint32]([int64]$info.LastTaskResult -band 0xFFFFFFFF)
            $u | Should -Not -Be 0
            ($u -ge 0x41300 -and $u -le 0x41304) | Should -BeFalse
        }
    }
}

Describe 'Get-PSTSMTaskRunLog' {
    It 'explains why there is no history rather than implying the task never ran' {
        # Windows ships the Task Scheduler operational log DISABLED. An empty result would read
        # as "this task has never run", which is a different and wrong conclusion.
        $t = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notlike '\Microsoft\*' })[0]
        if (-not $t) { Set-ItResult -Skipped -Because 'no non-Microsoft task available'; return }

        $log = @(Get-PSTSMTaskRunLog -TaskName $t.TaskName -TaskPath $t.TaskPath)[0]
        $log.Source | Should -BeIn @('Transcript', 'EventLog', 'None')
        if (-not $log.Available) {
            $log.Note | Should -Not -BeNullOrEmpty
        }
    }

    It 'throws a clear error for a task that does not exist' {
        { Get-PSTSMTaskRunLog -TaskName 'PSTSM-NoSuchTask-ZZZ' -TaskPath '\' } | Should -Throw '*not found*'
    }
}

Describe 'Editing existing tasks of every shape' {
    # These run against whatever is registered on the machine. That is deliberate: the built-in
    # \Microsoft\ tree is a free corpus of shapes nobody would think to synthesise - COM handler
    # actions, trigger-less tasks, multi-action tasks - and it is what caught the bug below.
    It 'converts every task registered on this machine without throwing' {
        $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue)
        if ($tasks.Count -eq 0) { Set-ItResult -Skipped -Because 'this machine has no scheduled tasks'; return }

        $failed = @()
        foreach ($t in $tasks) {
            try { $null = ConvertFrom-PSTSMDefinition -Task $t -ErrorAction Stop }
            catch { $failed += "$($t.TaskPath)$($t.TaskName) [$(@($t.Actions)[0].CimClass.CimClassName)]: $($_.Exception.Message)" }
        }
        $failed | Should -BeNullOrEmpty
    }

    It 'opens a task that has no triggers' {
        # Regression: @($null) is a ONE-element array containing $null, so a trigger-less task
        # looped once with nothing and the mandatory -Trigger parameter refused to bind. That
        # made 65 of 288 tasks on a stock machine impossible to open.
        $t = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { -not $_.Triggers })[0]
        if (-not $t) { Set-ItResult -Skipped -Because 'no trigger-less task on this machine'; return }

        $plan = ConvertFrom-PSTSMDefinition -Task $t
        @($plan.Triggers) | Should -HaveCount 0
        $plan.TaskName | Should -Be $t.TaskName
    }

    It 'describes a non-executable action rather than showing an empty command' {
        # Roughly half of Windows' own tasks use a ComHandler action, which has a ClassId and no
        # Execute at all. Reading .Execute yields nothing, so the description has to come from
        # the action type instead of three empty strings.
        $t = @(Get-ScheduledTask -ErrorAction SilentlyContinue |
                Where-Object { @($_.Actions)[0].CimClass.CimClassName -eq 'MSFT_TaskComHandlerAction' })[0]
        if (-not $t) { Set-ItResult -Skipped -Because 'no COM-handler task on this machine'; return }

        $plan = ConvertFrom-PSTSMDefinition -Task $t
        $plan.IsFullyRecognized | Should -BeFalse
        $plan.ActionType | Should -Be 'MSFT_TaskComHandlerAction'
        $plan.RawAction.Summary | Should -Not -BeNullOrEmpty
        # ...and must not also claim it "runs ''", which is both redundant and untrue.
        ($plan.ParseNotes -join ' ') | Should -Not -Match "runs ''"
    }

    It 'marks a non-PowerShell executable task read-only but still shows its command' {
        $t = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
                $a = @($_.Actions)[0]
                $a.CimClass.CimClassName -eq 'MSFT_TaskExecAction' -and $a.Execute -and $a.Execute -notmatch '(?i)powershell|pwsh'
            })[0]
        if (-not $t) { Set-ItResult -Skipped -Because 'no non-PowerShell exec task on this machine'; return }

        $plan = ConvertFrom-PSTSMDefinition -Task $t
        $plan.IsFullyRecognized | Should -BeFalse      # never silently rewrite someone else's task
        $plan.RawAction.Execute | Should -Not -BeNullOrEmpty
        $plan.RawAction.Summary | Should -Match ([regex]::Escape((Split-Path $t.Actions[0].Execute -Leaf)))
    }
}

Describe 'Register-PSTSMPlan password handling' {
    It 'refuses a Password principal with no password, and points at gMSA' {
        $plan = New-PSTSMPlan -ScriptPath $script:QuietScript -LogonType 'Password' -UserId 'CONTOSO\svc_x'
        { Register-PSTSMPlan -Plan $plan -Force -Confirm:$false -WhatIf } |
            Should -Throw "*use LogonType 'gMSA'*"
    }

    It 'does not demand a password for a gMSA' {
        # -WhatIf stops short of registering, so this exercises everything up to and including
        # the password rule without touching Task Scheduler.
        $plan = New-PSTSMPlan -ScriptPath $script:QuietScript -LogonType 'gMSA' -UserId 'CONTOSO\svc_reports$'
        { Register-PSTSMPlan -Plan $plan -Force -Confirm:$false -WhatIf } | Should -Not -Throw
    }
}

Describe 'Export-PSTSMPlan / Import-PSTSMPlan' {
    It 'round-trips a plan through JSON without losing anything that matters' {
        $plan = New-PSTSMPlan -ScriptPath $script:StandardScript `
            -Parameters ([ordered]@{ SmtpServer = 'mail.contoso.com'; DaysOut = 30; TestMode = $true }) `
            -TaskPath 'Custom' `
            -Trigger (New-PSTSMTriggerSpec -Type Weekly -At '18:30' -DaysOfWeek Monday, Thursday)

        $file = Join-Path $TestDrive 'plan.json'
        Export-PSTSMPlan -Plan $plan -Path $file

        $back = Import-PSTSMPlan -Path $file

        $back.TaskName | Should -Be $plan.TaskName
        $back.TaskPath | Should -Be '\Custom\'
        $back.Parameters['SmtpServer'] | Should -Be 'mail.contoso.com'
        $back.Parameters['DaysOut'] | Should -Be 30
        $back.Parameters['TestMode'] | Should -BeTrue
        $back.Principal.LogonType | Should -Be 'S4U'
        $back.Settings.MultipleInstances | Should -Be 'IgnoreNew'
        @($back.Triggers) | Should -HaveCount 1
        @($back.Triggers)[0].DaysOfWeek | Should -Contain 'Thursday'
        $back.ArgumentString | Should -Be $plan.ArgumentString
    }

    It 'records the account for a Password logon but never a secret' {
        # 'Password' legitimately appears as the LogonType value; what must never appear is a
        # field carrying the secret itself. The plan has no property to hold one.
        $plan = New-PSTSMPlan -ScriptPath $script:QuietScript -LogonType 'Password' -UserId 'CONTOSO\svc_x'
        $file = Join-Path $TestDrive 'pw.json'
        Export-PSTSMPlan -Plan $plan -Path $file

        $json = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        $json.Principal.LogonType | Should -Be 'Password'
        $json.Principal.UserId | Should -Be 'CONTOSO\svc_x'
        $json.Principal.PSObject.Properties.Name | Should -Not -Contain 'Password'
        $json.PSObject.Properties.Name | Should -Not -Contain 'Password'
        $plan.PSObject.Properties.Name | Should -Not -Contain 'Password'
    }
}

Describe 'New-PSTSMLogWrapper' {
    It 'generates a wrapper that targets the real script and is safely quoted' {
        $plan = New-PSTSMPlan -ScriptPath $script:QuietScript
        $wrapper = New-PSTSMLogWrapper -Plan $plan

        Test-Path -LiteralPath $wrapper | Should -BeTrue
        $wrapper | Should -BeLike '*\.pstsm\*'

        $text = Get-Content -LiteralPath $wrapper -Raw
        $text | Should -BeLike '*DO NOT EDIT*'
        $text | Should -BeLike "*`$scriptPath    = '$($script:QuietScript -replace '\\','\')'*"
        $text | Should -BeLike '*exit $exitCode*'
        $text | Should -BeLike '*Start-Transcript*'
    }

    It 'forwards named parameters, quoted values and switches to the real script intact' {
        # Regression. The first implementation used [CmdletBinding()] with
        # ValueFromRemainingArguments; that swallows the '-Name' tokens and re-binds the
        # values positionally, so '-Label "hello world"' reached the script as two positional
        # arguments and every task with a quoted argument failed at run time. Only an
        # end-to-end execution catches this, so this test really launches the engine.
        $payload = Join-Path $TestDrive 'Payload.ps1'
        $outFile = Join-Path $TestDrive 'payload-out.txt'
        @"
param(
    [Parameter(Mandatory)][string]`$Label,
    [int]`$Count = 3,
    [switch]`$DryRun,
    [string]`$OutPath
)
Set-Content -LiteralPath '$outFile' -Value "<`$Label|`$Count|`$DryRun|`$OutPath>"
exit 0
"@ | Set-Content -LiteralPath $payload -Encoding UTF8

        $plan = New-PSTSMPlan -ScriptPath $payload -Parameters ([ordered]@{
                Label   = 'hello world'
                Count   = 7
                DryRun  = $true
                OutPath = 'C:\Logs\'
            })

        $wrapper = New-PSTSMLogWrapper -Plan $plan
        $argString = ConvertTo-PSTSMArgument -ScriptPath $wrapper -Parameters $plan.Parameters

        $engine = (Get-PSTSMEngine -Id 'powershell' | Where-Object Bitness -eq 'x64' | Select-Object -First 1).Path
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $engine
        $psi.Arguments = $argString
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $null = $proc.StandardOutput.ReadToEnd()
        $proc.WaitForExit(60000) | Out-Null

        Test-Path -LiteralPath $outFile | Should -BeTrue
        (Get-Content -LiteralPath $outFile -Raw).Trim() | Should -Be '<hello world|7|True|C:\Logs\>'
        $proc.ExitCode | Should -Be 0
    }

    It 'writes the wrapper with a BOM so Windows PowerShell reads it correctly' {
        $plan = New-PSTSMPlan -ScriptPath $script:QuietScript
        $wrapper = New-PSTSMLogWrapper -Plan $plan
        $bytes = if ($PSVersionTable.PSVersion.Major -ge 6) {
            Get-Content -LiteralPath $wrapper -AsByteStream -TotalCount 3
        }
        else {
            Get-Content -LiteralPath $wrapper -Encoding Byte -TotalCount 3
        }
        $bytes[0] | Should -Be 0xEF
        $bytes[1] | Should -Be 0xBB
        $bytes[2] | Should -Be 0xBF
    }
}

Describe 'Get-PSTSMEngine' {
    It 'finds at least Windows PowerShell on a Windows host' {
        $engines = @(Get-PSTSMEngine)
        $engines.Count | Should -BeGreaterThan 0
        @($engines | Where-Object { Test-Path -LiteralPath $_.Path }).Count | Should -Be $engines.Count
    }
    It 'marks exactly one engine as the default' {
        @(Get-PSTSMEngine | Where-Object IsDefault) | Should -HaveCount 1
    }
    It 'filters by id' {
        @(Get-PSTSMEngine -Id 'powershell' | Where-Object { $_.Id -ne 'powershell' }) | Should -HaveCount 0
    }
}

Describe 'ConvertFrom-PSTSMResultCode' {
    It 'decodes the codes people misread' {
        ConvertFrom-PSTSMResultCode -Code 0x41303 | Should -BeLike '*never run*'
        ConvertFrom-PSTSMResultCode -Code 0x41301 | Should -BeLike '*currently running*'
        ConvertFrom-PSTSMResultCode -Code 0 | Should -BeLike '*Success*'
        ConvertFrom-PSTSMResultCode -Code 2 | Should -BeLike '*File not found*'
    }
    It 'falls back to hex for anything unmapped' {
        ConvertFrom-PSTSMResultCode -Code 0x12345 | Should -Be '0x12345'
    }
    It 'returns null for no result' {
        ConvertFrom-PSTSMResultCode -Code $null | Should -BeNullOrEmpty
    }
}

Describe 'Elevation boundary' {
    # These encode behaviour measured on a real Windows 11 box across four distinct token
    # shapes, because the documentation and the observed behaviour disagree in a way that is
    # easy to get wrong twice:
    #
    #   elevated (ElevType=2)                     Limited OK   Highest OK
    #   UAC-filtered admin (ElevType=3)           Limited OK   Highest ACCESS DENIED
    #   SAFER-restricted (runas /trustlevel)      IsElevated=1, so NOT a valid proxy for
    #                                             "un-elevated" even though IsInRole is false
    #   true standard user (ElevType=1)           cannot register at all
    #
    # The third row is the trap: runas /trustlevel strips the Administrators SID to deny-only,
    # so IsInRole() reports false while the kernel still reports TokenIsElevated=1. Measuring
    # elevation with IsInRole against such a token gives the wrong answer.

    It 'names every property that requires an administrator token, and nothing else' {
        # Highest on its own is exactly one reason.
        $highest = New-PSTSMPlan -ScriptPath $script:QuietScript -RunLevel 'Highest'
        @(Test-PSTSMPlanNeedsElevation -Plan $highest) | Should -Be @('it runs with highest privileges')

        # A service account cannot be isolated: New-PSTSMPlan pins RunLevel to Highest for one,
        # because those principals are built-in SIDs that always run elevated. So this asserts
        # the logon type is *named*, and that both reasons accumulate rather than one masking the
        # other - the operator should be told everything that needs consent, not just the first.
        $system = New-PSTSMPlan -ScriptPath $script:QuietScript -LogonType 'ServiceAccount' -UserId 'SYSTEM'
        $systemReasons = @(Test-PSTSMPlanNeedsElevation -Plan $system)
        $systemReasons | Should -Contain 'it runs as SYSTEM'
        $systemReasons | Should -Contain 'it runs with highest privileges'
        $systemReasons | Should -HaveCount 2

        $group = New-PSTSMPlan -ScriptPath $script:QuietScript -LogonType 'Group' -UserId 'CONTOSO\Operators' -RunLevel 'Limited'
        @(Test-PSTSMPlanNeedsElevation -Plan $group) | Should -Be @('it runs for a group')

        # The case that must stay unprivileged: your own task, at your own privilege level.
        $ordinary = New-PSTSMPlan -ScriptPath $script:QuietScript -LogonType 'Interactive' -RunLevel 'Limited'
        @(Test-PSTSMPlanNeedsElevation -Plan $ordinary) | Should -HaveCount 0
    }

    It 'treats an at-startup trigger as needing administrator rights' {
        # Documented on the RegisterTaskDefinition reference rather than the security page:
        # "Only a member of the Administrators group can create a task with a boot trigger."
        $plan = New-PSTSMPlan -ScriptPath $script:QuietScript -LogonType 'Interactive' -RunLevel 'Limited' `
            -Trigger @(New-PSTSMTriggerSpec -Type 'AtStartup')
        @(Test-PSTSMPlanNeedsElevation -Plan $plan) | Should -HaveCount 1

        # A time-based trigger is not privileged, so it must not drag a consent prompt in with it.
        $daily = New-PSTSMPlan -ScriptPath $script:QuietScript -LogonType 'Interactive' -RunLevel 'Limited' `
            -Trigger @(New-PSTSMTriggerSpec -Type 'Daily' -At '03:00')
        @(Test-PSTSMPlanNeedsElevation -Plan $daily) | Should -HaveCount 0
    }

    It 'agrees with the preflight check, so the tool never elevates for nothing' {
        # One definition, two consumers. If they drift, PSTSM either raises a consent prompt no
        # registration needed, or lets one fail with a bare "Access is denied".
        foreach ($plan in @(
                (New-PSTSMPlan -ScriptPath $script:QuietScript -RunLevel 'Highest'),
                (New-PSTSMPlan -ScriptPath $script:QuietScript -LogonType 'Interactive' -RunLevel 'Limited'),
                (New-PSTSMPlan -ScriptPath $script:QuietScript -LogonType 'ServiceAccount' -UserId 'SYSTEM')
            )) {
            $viaHelper = @(Test-PSTSMPlanNeedsElevation -Plan $plan).Count -gt 0
            $viaCheck = @(Test-PSTSMPlan -Plan $plan -SkipExistingTaskCheck -IsElevated $false |
                    Where-Object Id -eq 'NEEDS_ELEVATION').Count -gt 0
            $viaCheck | Should -Be $viaHelper -Because "both must agree about $($plan.Principal.RunLevel)/$($plan.Principal.LogonType)"
        }
    }

    It 'reports elevation from the token, not from group membership' {
        # Test-PSTSMElevated must answer "is this token elevated", which is what the Task
        # Scheduler service checks - not "is this account an administrator".
        Test-PSTSMElevated | Should -BeOfType [bool]
        $expected = (New-Object Security.Principal.WindowsPrincipal(
                [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
        Test-PSTSMElevated | Should -Be $expected
    }
}

Describe 'Invoke-PSTSMElevatedRegistration' {
    It 'reports a missing helper instead of throwing' {
        $plan = New-PSTSMPlan -ScriptPath $script:QuietScript -RunLevel 'Highest'
        $r = Invoke-PSTSMElevatedRegistration -Plan $plan -HelperPath (Join-Path $TestDrive 'nope.ps1') -Confirm:$false
        $r.Success | Should -BeFalse
        $r.Error | Should -BeLike '*not found*'
    }

    It 'does nothing under -WhatIf' {
        $plan = New-PSTSMPlan -ScriptPath $script:QuietScript -RunLevel 'Highest'
        $r = Invoke-PSTSMElevatedRegistration -Plan $plan -WhatIf
        $r.Success | Should -BeFalse
        $r.Error | Should -BeNullOrEmpty -Because 'it never got as far as trying'
    }

    It 'carries the plan through a real export/import round trip without a secret' {
        # This is the broker's data channel, so what crosses it has to be both complete and
        # free of credentials.
        $plan = New-PSTSMPlan -ScriptPath $script:QuietScript -RunLevel 'Highest' `
            -Parameters ([ordered]@{ Path = 'C:\a b\c.txt' })
        $f = Join-Path $TestDrive 'channel.json'
        Export-PSTSMPlan -Plan $plan -Path $f
        (Get-Content -LiteralPath $f -Raw) | Should -Not -Match '(?i)password\s*"?\s*:\s*"[^"]+"'
        $back = Import-PSTSMPlan -Path $f -KeepEnginePath
        $back.TaskName | Should -Be $plan.TaskName
        $back.Principal.RunLevel | Should -Be 'Highest'
        $back.ArgumentString | Should -Be $plan.ArgumentString
    }

    It 'ships a helper that parses and takes the parameters the broker passes' {
        $helper = Join-Path (Split-Path $PSScriptRoot -Parent) 'PSTSM.Elevate.ps1'
        Test-Path -LiteralPath $helper | Should -BeTrue
        $errs = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($helper, [ref]$null, [ref]$errs)
        @($errs) | Should -HaveCount 0
        $cmd = Get-Command $helper
        foreach ($p in 'PlanPath', 'ResultPath', 'PromptForPassword', 'RemoveTaskName', 'RemoveTaskPath') {
            $cmd.Parameters.Keys | Should -Contain $p
        }
    }
}

Describe 'Release metadata' {
    BeforeAll {
        $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
        $script:Manifest = Import-PowerShellDataFile (Join-Path $script:ModuleRoot 'PSTSM.psd1')
        $script:Readme = Get-Content -LiteralPath (Join-Path $script:ModuleRoot 'README.md') -Raw
    }

    It 'states the same version in the manifest and the README' {
        # These drifted apart silently for two releases - the manifest said 0.3.0 while the
        # README still advertised 0.2.0 - which is exactly the sort of thing nobody notices
        # until it is on a public repository.
        $script:Readme | Should -Match ([regex]::Escape("v$($script:Manifest.ModuleVersion)"))
    }

    It 'has a release note for the current version' {
        $notes = $script:Manifest.PrivateData.PSData.ReleaseNotes
        $notes | Should -Match ([regex]::Escape($script:Manifest.ModuleVersion) + '\s*-')
    }

    It 'leaves no function that is neither exported nor used' {
        # The point is dead weight, not export-for-its-own-sake. A function that is unexported
        # BUT called by other module code is deliberate encapsulation - Start-PSTSMBrokerProcess
        # is exactly that, the impure seam the broker tests mock. What should never survive is a
        # function nothing calls and nobody can call.
        $defined = @(Get-ChildItem (Join-Path $script:ModuleRoot 'Functions') -Recurse -Filter *.ps1 |
                ForEach-Object {
                    $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$null)
                    $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
                        ForEach-Object { $_.Name }
                }) | Sort-Object -Unique

        $exported = @($script:Manifest.FunctionsToExport)
        # Everything the module ships, so "is it called anywhere" can be answered honestly.
        $allSource = (Get-ChildItem $script:ModuleRoot -Recurse -Filter *.ps1 |
                ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"

        $orphans = @()
        foreach ($fn in $defined) {
            if ($fn -in $exported) { continue }
            # More than one occurrence means something beyond its own definition mentions it.
            $uses = ([regex]::Matches($allSource, [regex]::Escape($fn))).Count
            if ($uses -le 1) { $orphans += $fn }
        }
        $orphans | Should -BeNullOrEmpty -Because "these are neither exported nor called: $($orphans -join ', ')"
    }

    It 'carries an SPDX identifier in every script, matching the declared licence' {
        $files = @(Get-ChildItem $script:ModuleRoot -Recurse -Filter *.ps1)
        $without = @($files | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -notmatch 'SPDX-License-Identifier' })
        $without | Should -BeNullOrEmpty -Because "these have no SPDX header: $($without.Name -join ', ')"

        # One licence, stated the same way everywhere. Mixing -only and -or-later across files
        # is a real ambiguity for anyone forking.
        $ids = @($files | ForEach-Object {
                if ((Get-Content -LiteralPath $_.FullName -Raw) -match 'SPDX-License-Identifier:\s*(\S+)') { $Matches[1] }
            }) | Sort-Object -Unique
        $ids | Should -HaveCount 1 -Because "found: $($ids -join ', ')"
    }

    It 'ships the elevation helper, which the module cannot save privileged tasks without' {
        Test-Path -LiteralPath (Join-Path $script:ModuleRoot 'PSTSM.Elevate.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:ModuleRoot 'PSTSM.cmd') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:ModuleRoot 'LICENSE') | Should -BeTrue
    }
}

Describe 'Launcher stays in step with the script it launches' {
    BeforeAll {
        $script:Root = Split-Path $PSScriptRoot -Parent
        $script:Cmd = Get-Content -LiteralPath (Join-Path $script:Root 'PSTSM.cmd') -Raw
        $script:StartParams = (Get-Command (Join-Path $script:Root 'Start-PSTSM.ps1')).Parameters.Keys
    }

    It 'documents only switches Start-PSTSM.ps1 actually accepts' {
        # This drifted unnoticed into a published repo: PSTSM.cmd still advertised -NoElevate two
        # commits after it became -Elevated. The earlier stale-reference audit globbed *.ps1 and
        # *.md and never looked at the launcher, so the file type is the point of this test.
        $advertised = [regex]::Matches($script:Cmd, '(?m)^rem\s+PSTSM\.cmd\s+(-\w+)') |
            ForEach-Object { $_.Groups[1].Value.TrimStart('-') }
        $advertised | Should -Not -BeNullOrEmpty -Because 'the examples are the thing being checked'
        foreach ($a in $advertised) {
            $script:StartParams | Should -Contain $a -Because "PSTSM.cmd advertises -$a"
        }
    }

    It 'names no switch that has been removed' {
        $script:Cmd | Should -Not -Match '(?i)-NoElevate'
    }

    It 'forwards arguments and pins the host it launches' {
        $script:Cmd | Should -Match '%\*'          # arguments passed through
        $script:Cmd | Should -Match '-STA'         # WinForms apartment
        $script:Cmd | Should -Match '%~dp0'        # runs from its own folder, not the caller's
    }

    It 'describes the current elevation behaviour, not the old relaunch' {
        $script:Cmd | Should -Not -Match '(?i)relaunches itself elevated'
    }
}

Describe 'Regressions from the 0.4.1 review pass' {
    # Every bug below shipped while 197 tests were green, so each gets a test that fails against
    # the old behaviour. The pattern is the same throughout: the happy path was covered and the
    # values that actually break things were not.

    Context 'Argument round trip is lossless' {
        # ConvertFrom-PSTSMAction must be the exact inverse of ConvertTo-PSTSMArgument. It was
        # not: it treated any quote preceded by one backslash as escaped and never consumed the
        # backslashes, so a value ending in one - every "C:\Program Files\App\" - left the parser
        # stuck inside a quoted run and swallowed the rest of the command line. Later parameters
        # silently disappeared and a switch that had been set came back unset.
        $cases = @(
            @{ Name = 'plain'; Value = 'mail.contoso.com' }
            @{ Name = 'spaced path'; Value = 'C:\Program Files\App' }
            @{ Name = 'trailing slash'; Value = 'C:\Program Files\App\' }
            @{ Name = 'bare trailing'; Value = 'C:\Logs\' }
            @{ Name = 'embedded quote'; Value = 'said "hi"' }
            @{ Name = 'comma'; Value = 'Quarter close, please review' }
            @{ Name = 'apostrophe'; Value = "O'Brien" }
            @{ Name = 'double backslash'; Value = 'a\\b' }
            @{ Name = 'quote then slash'; Value = 'x"y\' }
            @{ Name = 'semicolon amp'; Value = 'a; b & c' }
        )
        It 'survives <Name> without losing the value or the parameters after it' -TestCases $cases {
            param($Name, $Value)
            $params = [ordered]@{ Value = $Value; Marker = 'SENTINEL'; Flag = $true }
            $rendered = ConvertTo-PSTSMArgument -ScriptPath 'C:\s.ps1' -Parameters $params
            $back = ConvertFrom-PSTSMAction -Execute 'powershell.exe' -Arguments $rendered

            $back.Parameters['Value'] | Should -Be $Value -Because "a $Name value must survive verbatim"
            # The sentinel is the real assertion. A tokeniser that mishandles the value tends to
            # eat everything after it, and that is the damaging half of the bug.
            $back.Parameters['Marker'] | Should -Be 'SENTINEL' -Because "a $Name value must not swallow later parameters"
            $back.Parameters['Flag'] | Should -BeTrue -Because "a $Name value must not lose a trailing switch"
        }

        It 'keeps a comma inside one value instead of splitting it into an array' {
            $back = ConvertFrom-PSTSMAction -Execute 'powershell.exe' `
                -Arguments '-File "C:\s.ps1" -Subject "Quarter close, please review"'
            $back.Parameters['Subject'] | Should -BeOfType [string]
        }

        It 'does not throw on a numeric argument too large for Int32' {
            # A phone number is enough. The cast threw, nothing up the chain caught it, and
            # Get-PSTSMInventory discarded even the rows it had already produced - so one bad
            # task anywhere on the machine emptied the entire list.
            # Called directly, not inside a { } | Should -Not -Throw: a scriptblock gets its own
            # scope, so the assignment would not escape it and every later assertion would run
            # against $null. A throw still fails the test, just as an error rather than a
            # failed expectation.
            $back = ConvertFrom-PSTSMAction -Execute 'powershell.exe' `
                -Arguments '-File "C:\s.ps1" -Phone 5551234567'
            $back.Parameters['Phone'] | Should -Be '5551234567'
        }
    }

    Context 'Generated log wrapper' {
        BeforeAll {
            $script:WrapDir = Join-Path $TestDrive 'wrap'
            New-Item -ItemType Directory -Path $script:WrapDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:WrapDir 'demo.ps1') -Value 'param([string]$X) "hi"'
        }

        It 'parses when the task name contains an apostrophe' {
            # __TASK_NAME__ lands inside a single-quoted string and was the one placeholder
            # without doubling. The task registered fine and then failed every run with a parse
            # error and no transcript to explain it.
            $plan = New-PSTSMPlan -ScriptPath (Join-Path $script:WrapDir 'demo.ps1') -TaskName "O'Brien Report"
            $plan.Logging.Mode = 'Transcript'
            $wrapper = New-PSTSMLogWrapper -Plan $plan
            $errs = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($wrapper, [ref]$null, [ref]$errs)
            @($errs) | Should -HaveCount 0
        }

        It 'scopes log retention to its own transcripts' {
            # A bare *.log swept the whole directory. The default directory is the script's own
            # Logs folder, so it deleted the script's application logs and other tasks'
            # transcripts - inside a finally, behind SilentlyContinue, reporting nothing.
            $plan = New-PSTSMPlan -ScriptPath (Join-Path $script:WrapDir 'demo.ps1') -TaskName 'Scoped'
            $plan.Logging.Mode = 'Transcript'
            $text = Get-Content -LiteralPath (New-PSTSMLogWrapper -Plan $plan) -Raw
            $text | Should -Not -Match ([regex]::Escape("-Filter '*.log'"))
            $text | Should -Match ([regex]::Escape("-Filter 'Scoped_*.log'"))
        }
    }

    Context 'Culture independence' {
        # ':' in a .NET custom format string means DateTimeFormatInfo.TimeSeparator, not a colon.
        $cultures = @(
            @{ Culture = 'en-US' }, @{ Culture = 'fi-FI' }, @{ Culture = 'da-DK' }, @{ Culture = 'id-ID' }
        )
        It 'writes an invariant trigger time under <Culture>' -TestCases $cultures {
            param($Culture)
            $saved = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [System.Threading.Thread]::CurrentThread.CurrentCulture =
                [System.Globalization.CultureInfo]::GetCultureInfo($Culture)
                $spec = New-PSTSMTriggerSpec -Type Daily -At '07:00'
                $spec.At | Should -Match 'T\d{2}:\d{2}:\d{2}$'
            }
            finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $saved }
        }
    }

    Context 'Result code decoding' {
        # An 8-digit hex literal with the high bit set is a NEGATIVE Int32 in PowerShell, so every
        # HRESULT case label was unreachable - and the mask meant to normalise the input was
        # itself written 0xFFFFFFFF, i.e. -1, so it did nothing and the following [uint32] cast
        # threw on exactly the codes it was supposed to handle.
        $codes = @(
            @{ Code = 0x80070534; Expect = 'batch job' }
            @{ Code = 0x80070005; Expect = 'Access denied' }
            @{ Code = 0x8004131F; Expect = 'already running' }
            @{ Code = 0x800704DD; Expect = 'Not logged on' }
            @{ Code = 0x8007010B; Expect = 'Directory name' }
        )
        It 'decodes HRESULT <Code> rather than echoing it' -TestCases $codes {
            param($Code, $Expect)
            # Direct call for the same reason as above - the old form asserted against $null and
            # would have passed on a function that returned nothing at all.
            $text = ConvertFrom-PSTSMResultCode -Code $Code
            $text | Should -BeLike "*$Expect*"
        }

        It 'still decodes the small positive codes' {
            ConvertFrom-PSTSMResultCode -Code 0x41303 | Should -BeLike '*never run*'
            ConvertFrom-PSTSMResultCode -Code 0 | Should -BeLike '*Success*'
        }
    }

    Context 'Cross-function agreement' {
        BeforeAll { $script:Root = Split-Path $PSScriptRoot -Parent }

        It 'emits the missed-run property name the health check reads' {
            # These disagreed - inventory emitted NumberOfMissed, the check read
            # NumberOfMissedRuns - so MISSED_RUNS could never fire, on a machine that had missed
            # runs to report. Asserted against source so it holds on any machine.
            $inv = Get-Content -LiteralPath (Join-Path $script:Root 'Functions/Task/Get-PSTSMInventory.ps1') -Raw
            $health = Get-Content -LiteralPath (Join-Path $script:Root 'Functions/Task/Test-PSTSMHealth.ps1') -Raw
            $emitted = @([regex]::Matches($inv, 'NumberOfMissed\w*') | ForEach-Object { $_.Value }) | Sort-Object -Unique
            $read = @([regex]::Matches($health, '\$row\.(NumberOfMissed\w*)') | ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique
            $read | Should -Not -BeNullOrEmpty -Because 'the check must actually read something'
            foreach ($r in $read) { $emitted | Should -Contain $r -Because "Test-PSTSMHealth reads $r" }
        }

        It 'quotes elevated-helper arguments with the module encoder rather than a local one' {
            # The local version escaped quotes but not backslash runs, so a task folder - which
            # always ends in one - produced a trailing backslash that escaped the closing quote.
            # The stale task then survived a rename as a live privileged duplicate.
            $src = Get-Content -LiteralPath (Join-Path $script:Root 'Functions/Task/Invoke-PSTSMElevatedRegistration.ps1') -Raw
            $src | Should -Match 'ConvertTo-PSTSMQuotedValue'
            ConvertTo-PSTSMQuotedValue -Value '\My Tasks\' | Should -Be '"\My Tasks\\"'
        }
    }
}


Describe 'Documentation cannot drift from the code' {
    # The README has now gone stale three separate ways - test counts, an elevation claim that
    # contradicted the feature, and a command list eighteen exports out of date - and each was
    # found by a person reading it rather than by anything automated. These are the cheap
    # mechanical guards.
    BeforeAll {
        $script:Root = Split-Path $PSScriptRoot -Parent
        $script:Readme = Get-Content -LiteralPath (Join-Path $script:Root 'README.md') -Raw
        $script:Manifest = Import-PowerShellDataFile (Join-Path $script:Root 'PSTSM.psd1')
    }

    It 'documents every exported command' {
        $missing = @($script:Manifest.FunctionsToExport | Where-Object {
                $script:Readme -notmatch [regex]::Escape($_)
            })
        $missing | Should -BeNullOrEmpty -Because "these are exported but appear nowhere in the README: $($missing -join ', ')"
    }

    It 'names no command the module does not export' {
        # Catches the reverse drift: a command renamed in code but left in the docs.
        $named = @([regex]::Matches($script:Readme, '`([A-Za-z]+-PSTSM[A-Za-z]*)`') |
                ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique
        $named | Should -Not -BeNullOrEmpty
        $ghost = @($named | Where-Object { $_ -notin $script:Manifest.FunctionsToExport })
        $ghost | Should -BeNullOrEmpty -Because "the README names these but the module does not export them: $($ghost -join ', ')"
    }

    It 'keeps every shipped script reachable through Get-Help' {
        # A plain comment directly above <# suppresses the whole comment-based help block, with no
        # error and no warning - Get-Help just returns the filename as the synopsis. Start-PSTSM
        # and PSTSM.Elevate both shipped that way, so their carefully written help was unreachable.
        $offenders = @()
        foreach ($file in Get-ChildItem $script:Root -Recurse -Filter *.ps1) {
            $lines = Get-Content -LiteralPath $file.FullName
            for ($i = 1; $i -lt $lines.Count; $i++) {
                if ($lines[$i].TrimStart().StartsWith('<#') -and $lines[$i - 1].TrimStart().StartsWith('#')) {
                    $offenders += "$($file.Name):$($i + 1)"
                    break
                }
            }
        }
        $offenders | Should -BeNullOrEmpty -Because "a comment adjacent to <# hides the help topic: $($offenders -join ', ')"
    }

    It 'advertises no launcher switch that Start-PSTSM.ps1 does not accept' {
        # Already caught once: PSTSM.cmd offered -NoElevate two commits after it became -Elevated.
        # This widens that check to the README, which is where most people will read the flags.
        $accepted = (Get-Command (Join-Path $script:Root 'Start-PSTSM.ps1')).Parameters.Keys
        $advertised = @([regex]::Matches($script:Readme, '(?:PSTSM\.cmd|Start-PSTSM\.ps1)\s+(-\w+)') |
                ForEach-Object { $_.Groups[1].Value.TrimStart('-') }) | Sort-Object -Unique
        foreach ($a in $advertised) {
            $accepted | Should -Contain $a -Because "the README shows -$a"
        }
    }
}


Describe 'Switch parameters that default to $true' {
    # A [switch]$X = $true cannot be turned off by omitting it - the script's own default turns
    # it back on. Only -X:$false does. ConvertTo-PSTSMArgument always knew that, but it could
    # only learn WHICH switches from a -ScriptProfile no production caller passed, so unticking
    # the box in the editor registered a task that still ran with the switch on.
    BeforeAll {
        $script:SwitchScript = Join-Path $TestDrive 'Switchy.ps1'
        @'
param(
    [string]$Server = 'mail.contoso.com',
    [switch]$SendMail = $true,
    [switch]$Extra
)
exit 0
'@ | Set-Content -LiteralPath $script:SwitchScript -Encoding UTF8
    }

    It 'records which switches the script defaults on' {
        $plan = New-PSTSMPlan -ScriptPath $script:SwitchScript
        $plan.SwitchDefaultTrue | Should -Contain 'SendMail'
        $plan.SwitchDefaultTrue | Should -Not -Contain 'Extra' -Because 'it defaults to $false'
    }

    It 'writes -X:$false when the operator turns one off' {
        $plan = New-PSTSMPlan -ScriptPath $script:SwitchScript
        $plan.Parameters['SendMail'] = $false
        $plan.ArgumentString | Should -Match ([regex]::Escape('-SendMail:$false'))
    }

    It 'writes a bare -X when it is left on' {
        $plan = New-PSTSMPlan -ScriptPath $script:SwitchScript
        $plan.Parameters['SendMail'] = $true
        $plan.ArgumentString | Should -Match '-SendMail(?!:)'
    }

    It 'still omits a switch that defaults off and is left off' {
        $plan = New-PSTSMPlan -ScriptPath $script:SwitchScript
        $plan.Parameters['Extra'] = $false
        $plan.ArgumentString | Should -Not -Match 'Extra'
    }

    It 'survives export and import onto a machine without the script' {
        # This is why the list lives on the plan instead of being re-derived at registration.
        $plan = New-PSTSMPlan -ScriptPath $script:SwitchScript
        $plan.Parameters['SendMail'] = $false
        $file = Join-Path $TestDrive 'switchy.task.json'
        Export-PSTSMPlan -Plan $plan -Path $file
        $back = Import-PSTSMPlan -Path $file -KeepEnginePath
        $back.SwitchDefaultTrue | Should -Contain 'SendMail'
        $back.ArgumentString | Should -Match ([regex]::Escape('-SendMail:$false'))
    }
}

Describe 'Generated wrapper exit codes' {
    # The only ExitCode assertion in the suite belonged to a parameter-forwarding test whose
    # payload exits 0 - which is also what the wrapper returns by default, so the entire
    # exit-code path could be deleted and the suite stayed green.
    BeforeAll {
        $script:ExitDir = Join-Path $TestDrive 'exit'
        New-Item -ItemType Directory -Path $script:ExitDir -Force | Out-Null

        function script:Invoke-Wrapper {
            param([string]$Body, [string]$Name)
            $target = Join-Path $script:ExitDir "$Name.ps1"
            Set-Content -LiteralPath $target -Value $Body -Encoding UTF8
            $plan = New-PSTSMPlan -ScriptPath $target -TaskName $Name
            $plan.Logging.Mode = 'Transcript'
            $wrapper = New-PSTSMLogWrapper -Plan $plan
            $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            & $psExe -NoProfile -ExecutionPolicy Bypass -File $wrapper | Out-Null
            $LASTEXITCODE
        }
    }

    It 'propagates a non-zero exit from the wrapped script' {
        script:Invoke-Wrapper -Name 'ExitsThree' -Body 'exit 3' | Should -Be 3
    }

    It 'reports failure when the wrapped script throws' {
        # A throw must not surface as 0. "Last Run Result: 0x0" on a script that blew up is the
        # single most misleading thing Task Scheduler can show.
        script:Invoke-Wrapper -Name 'Throws' -Body 'throw "boom"' | Should -Not -Be 0
    }

    It 'returns zero for a script that succeeds' {
        script:Invoke-Wrapper -Name 'Succeeds' -Body '"fine"; exit 0' | Should -Be 0
    }

    It 'leaves a transcript behind' {
        $target = Join-Path $script:ExitDir 'Logged.ps1'
        Set-Content -LiteralPath $target -Value '"hello from the task"; exit 0' -Encoding UTF8
        $plan = New-PSTSMPlan -ScriptPath $target -TaskName 'Logged'
        $plan.Logging.Mode = 'Transcript'
        $wrapper = New-PSTSMLogWrapper -Plan $plan
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        & $psExe -NoProfile -ExecutionPolicy Bypass -File $wrapper | Out-Null
        $logs = @(Get-ChildItem -LiteralPath $plan.Logging.Directory -Filter 'Logged_*.log' -ErrorAction SilentlyContinue)
        $logs.Count | Should -BeGreaterThan 0
        (Get-Content -LiteralPath $logs[0].FullName -Raw) | Should -Match 'hello from the task'
    }
}

Describe 'Elevated registration broker paths' {
    # Everything after Process::Start was dark: cancellation, timeout, reply mapping and the
    # stage fallback. Mocking keeps all of it offline - no consent prompt, no elevated child,
    # nothing registered.
    BeforeAll {
        $script:BrokerPlan = New-PSTSMPlan -ScriptPath $script:QuietScript -TaskName 'BrokerCase' -RunLevel 'Highest'
    }

    It 'reports Cancelled, not an error, when the consent prompt is dismissed' {
        # ERROR_CANCELLED (1223) is the operator saying no. It must not raise a dialog.
        Mock -ModuleName PSTSM -CommandName 'Start-PSTSMBrokerProcess' -MockWith {
            throw (New-Object System.ComponentModel.Win32Exception 1223)
        }
        $r = Invoke-PSTSMElevatedRegistration -Plan $script:BrokerPlan -Confirm:$false
        $r.Cancelled | Should -BeTrue
        $r.Success | Should -BeFalse
        $r.Error | Should -BeNullOrEmpty -Because 'declining is a decision, not a fault'
    }

    It 'rethrows a ShellExecute failure that is not a cancellation' {
        Mock -ModuleName PSTSM -CommandName 'Start-PSTSMBrokerProcess' -MockWith {
            throw (New-Object System.ComponentModel.Win32Exception 5)   # access denied
        }
        $r = Invoke-PSTSMElevatedRegistration -Plan $script:BrokerPlan -Confirm:$false
        $r.Cancelled | Should -BeFalse
        $r.Success | Should -BeFalse
        $r.Error | Should -Not -BeNullOrEmpty
    }

    It 'surfaces the helper error when the reply reports failure' {
        Mock -ModuleName PSTSM -CommandName 'Start-PSTSMBrokerProcess' -MockWith {
            param($ReplyPath)   # only the reply path matters to the simulation
            '{"Success":false,"Error":"the helper said no","Stage":"register","Warnings":[]}' |
                Set-Content -LiteralPath $ReplyPath -Encoding UTF8
            [pscustomobject]@{ ExitCode = 1; Exited = $true }
        }
        $r = Invoke-PSTSMElevatedRegistration -Plan $script:BrokerPlan -Confirm:$false
        $r.Success | Should -BeFalse
        $r.Error | Should -Be 'the helper said no'
    }

    It 'passes warnings back from a successful elevated save' {
        Mock -ModuleName PSTSM -CommandName 'Start-PSTSMBrokerProcess' -MockWith {
            param($ReplyPath)   # only the reply path matters to the simulation
            '{"Success":true,"Error":null,"Stage":"done","Warnings":["old task left behind"],"RanAs":"CONTOSO\\adm"}' |
                Set-Content -LiteralPath $ReplyPath -Encoding UTF8
            [pscustomobject]@{ ExitCode = 0; Exited = $true }
        }
        $r = Invoke-PSTSMElevatedRegistration -Plan $script:BrokerPlan -Confirm:$false
        $r.Success | Should -BeTrue
        $r.Warnings | Should -Contain 'old task left behind'
        $r.RanAs | Should -Be 'CONTOSO\adm'
    }

    It 'explains a helper that exits without reporting back' {
        Mock -ModuleName PSTSM -CommandName 'Start-PSTSMBrokerProcess' -MockWith {
            [pscustomobject]@{ ExitCode = 9009; Exited = $true }   # writes no reply file
        }
        $r = Invoke-PSTSMElevatedRegistration -Plan $script:BrokerPlan -Confirm:$false
        $r.Success | Should -BeFalse
        $r.Error | Should -BeLike '*without reporting back*'
    }

    It 'reports a timeout rather than hanging' {
        Mock -ModuleName PSTSM -CommandName 'Start-PSTSMBrokerProcess' -MockWith {
            [pscustomobject]@{ ExitCode = $null; Exited = $false }
        }
        $r = Invoke-PSTSMElevatedRegistration -Plan $script:BrokerPlan -TimeoutSeconds 5 -Confirm:$false
        $r.Success | Should -BeFalse
        $r.Error | Should -BeLike '*did not finish*'
    }

    It 'removes the temporary plan file whatever happens' {
        # The plan describes a scheduled task in full. It should not outlive the call.
        $before = @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'PSTSM_elev_*' -ErrorAction SilentlyContinue).Count
        Mock -ModuleName PSTSM -CommandName 'Start-PSTSMBrokerProcess' -MockWith {
            throw (New-Object System.ComponentModel.Win32Exception 1223)
        }
        $null = Invoke-PSTSMElevatedRegistration -Plan $script:BrokerPlan -Confirm:$false
        @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'PSTSM_elev_*' -ErrorAction SilentlyContinue).Count |
            Should -Be $before
    }
}

Describe 'PSTSM.Elevate.ps1 behaviour' {
    # Previously asserted only to parse and to declare the right parameter names, which would
    # hold for a file whose body had been deleted.
    It 'always writes a reply, even when the plan cannot be read' {
        $helper = Join-Path (Split-Path $PSScriptRoot -Parent) 'PSTSM.Elevate.ps1'
        $reply = Join-Path $TestDrive 'reply.json'
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

        # A plan path that does not exist: it fails early, before anything is registered, and the
        # parent has no other way to learn what happened.
        & $psExe -NoProfile -ExecutionPolicy Bypass -File $helper `
            -PlanPath (Join-Path $TestDrive 'no-such-plan.json') -ResultPath $reply | Out-Null
        $exit = $LASTEXITCODE

        Test-Path -LiteralPath $reply | Should -BeTrue -Because 'the reply is the only channel back'
        $parsed = Get-Content -LiteralPath $reply -Raw | ConvertFrom-Json
        $parsed.Success | Should -BeFalse
        $parsed.Error | Should -Not -BeNullOrEmpty
        $exit | Should -Be 1
    }
}


Describe 'User-visible text is culture-independent' {
    # The trigger-time bug was one instance of "a culture-sensitive .NET default reached
    # user-visible output". This is the other: casing.
    #
    # Turkish and Azerbaijani have a dotted and a dotless I as separate letters, so
    # 'Warning'.ToUpper() is WARNİNG there and 'Inferred'.ToLower() is ınferred. The preflight
    # list, the health list and the engine line all render through those calls, so on a Turkish
    # machine the tool's own status words looked misspelt. ToUpperInvariant/ToLowerInvariant are
    # the correct calls for text that is not being compared, only displayed.

    It 'never uses culture-sensitive casing on displayed text' {
        $root = Split-Path $PSScriptRoot -Parent
        $offenders = @()
        foreach ($file in Get-ChildItem $root -Recurse -Filter *.ps1) {
            if ($file.FullName -like '*\Tests\*') { continue }
            $n = 0
            foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
                $n++
                if ($line -match '\.ToUpper\(\)|\.ToLower\(\)') {
                    $offenders += "$($file.Name):$n"
                }
            }
        }
        $offenders | Should -BeNullOrEmpty -Because "use ToUpperInvariant/ToLowerInvariant: $($offenders -join ', ')"
    }

    It 'renders the severity words identically under a Turkish locale' {
        $saved = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture =
            [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            # These are the exact strings the preflight and health lists put on screen.
            #
            # -cmatch, not -match. The default is case-INSENSITIVE, and under tr-TR an uppercase
            # 'I' case-folds to the dotless 'ı' - so 'WARNING' -match '[İı]' is TRUE and this
            # assertion failed against text that was perfectly correct. The trap being tested for
            # bit the test itself.
            foreach ($word in 'Warning', 'Error', 'Info', 'Ok', 'Verified', 'Inferred') {
                $word.ToUpperInvariant() | Should -Not -CMatch '[İı]' -Because "$word must not gain a Turkish I"
            }
            # And the culture-sensitive form really would break, which is what makes this worth a test.
            'Warning'.ToUpper() | Should -CMatch 'İ' -Because 'this is the behaviour ToUpperInvariant avoids'
            'Inferred'.ToLowerInvariant() | Should -BeExactly 'inferred'
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $saved }
    }
}


Describe 'Invoke-PSTSMTestRun' {
    # This is the one place the tool executes the operator's script rather than describing it,
    # so the tests actually run things. Fixtures only; nothing is registered.
    BeforeAll {
        $script:RunDir = Join-Path $TestDrive 'testrun'
        New-Item -ItemType Directory -Path $script:RunDir -Force | Out-Null

        function script:New-RunFixture {
            param([string]$Name, [string]$Body)
            $p = Join-Path $script:RunDir "$Name.ps1"
            Set-Content -LiteralPath $p -Value $Body -Encoding UTF8
            $p
        }
    }

    It 'runs the script and reports a zero exit code' {
        $plan = New-PSTSMPlan -ScriptPath (script:New-RunFixture 'Ok' '"hello from the script"; exit 0')
        $r = Invoke-PSTSMTestRun -Plan $plan -Confirm:$false
        $r.Started | Should -BeTrue
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'hello from the script'
        $r.TimedOut | Should -BeFalse
    }

    It 'reports a non-zero exit code and decodes it' {
        $plan = New-PSTSMPlan -ScriptPath (script:New-RunFixture 'Fails' 'exit 2')
        $r = Invoke-PSTSMTestRun -Plan $plan -Confirm:$false
        $r.ExitCode | Should -Be 2
        # The decoded text is the point: it is what Task Scheduler will show as Last Run Result.
        $r.ExitText | Should -BeLike '*File not found*'
    }

    It 'captures stderr separately so a failing script does not look silent' {
        $plan = New-PSTSMPlan -ScriptPath (script:New-RunFixture 'Noisy' 'Write-Error "went wrong"; exit 1')
        $r = Invoke-PSTSMTestRun -Plan $plan -Confirm:$false
        $r.Output | Should -Match 'stderr'
        $r.Output | Should -Match 'went wrong'
    }

    It 'passes the plan''s parameters through, quoted as they will be registered' {
        # The whole value of running the REAL argument string: this is the layer that has broken
        # before, and a value with a space and a trailing backslash is what broke it.
        $body = 'param([string]$Path, [int]$Days) "path=[$Path] days=[$Days]"; exit 0'
        $plan = New-PSTSMPlan -ScriptPath (script:New-RunFixture 'Params' $body) `
            -Parameters ([ordered]@{ Path = 'C:\Program Files\App\'; Days = 14 })
        $r = Invoke-PSTSMTestRun -Plan $plan -Confirm:$false
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match ([regex]::Escape('path=[C:\Program Files\App\]'))
        $r.Output | Should -Match ([regex]::Escape('days=[14]'))
    }

    It 'surfaces a script that waits for input, instead of hanging on it' {
        # -NonInteractive is part of the registered argument string, so Read-Host fails here
        # exactly as it would at 3am rather than blocking on a prompt nobody will ever answer.
        #
        # Note what it does NOT do: with the default ErrorActionPreference the script carries on
        # past the failure and still reaches exit 0. So this run reports SUCCESS while having
        # silently done nothing - which is the precise trap PSTSM's own EXIT_CODE check warns
        # about, and the reason this dialog shows stderr and the decoded result together rather
        # than a green tick.
        $plan = New-PSTSMPlan -ScriptPath (script:New-RunFixture 'Prompts' '$x = Read-Host "name"; exit 0')
        $r = Invoke-PSTSMTestRun -Plan $plan -TimeoutSeconds 20 -Confirm:$false
        $r.TimedOut | Should -BeFalse -Because 'NonInteractive must make it fail fast, not block'
        $r.Output | Should -Match '(?i)non-?interactive' -Because 'the reason must be visible even though the exit code is 0'
    }

    It 'stops a script that runs too long and says so' {
        $plan = New-PSTSMPlan -ScriptPath (script:New-RunFixture 'Hangs' 'Start-Sleep -Seconds 120; exit 0')
        $r = Invoke-PSTSMTestRun -Plan $plan -TimeoutSeconds 5 -Confirm:$false
        $r.TimedOut | Should -BeTrue
        $r.Duration.TotalSeconds | Should -BeLessThan 30
    }

    It 'runs in the plan''s working directory' {
        $plan = New-PSTSMPlan -ScriptPath (script:New-RunFixture 'Cwd' '(Get-Location).Path; exit 0')
        $r = Invoke-PSTSMTestRun -Plan $plan -Confirm:$false
        $r.Output.Trim() | Should -Be $plan.WorkingDirectory
    }

    It 'reports who it ran as, because that is what it cannot prove' {
        # A script that works as you and fails as SYSTEM is precisely what this misses, so the
        # identity has to come back for the dialog to show.
        $plan = New-PSTSMPlan -ScriptPath (script:New-RunFixture 'Who' 'exit 0')
        $r = Invoke-PSTSMTestRun -Plan $plan -Confirm:$false
        $r.RanAs | Should -Be ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
    }

    It 'does not drain into a deadlock on a chatty script' {
        # Reading both streams only after WaitForExit deadlocks once a script writes more than the
        # pipe buffer holds - a few KB. It would pass every small test and hang in the field.
        $plan = New-PSTSMPlan -ScriptPath (script:New-RunFixture 'Chatty' '1..4000 | ForEach-Object { "line $_ of output padding padding padding" }; exit 0')
        $r = Invoke-PSTSMTestRun -Plan $plan -TimeoutSeconds 60 -Confirm:$false
        $r.TimedOut | Should -BeFalse -Because 'both streams are drained while the process runs'
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'line 4000'
    }

    It 'does nothing under -WhatIf' {
        $marker = Join-Path $script:RunDir 'sideeffect.txt'
        $plan = New-PSTSMPlan -ScriptPath (script:New-RunFixture 'Writes' "'ran' | Set-Content -LiteralPath '$marker'; exit 0")
        $r = Invoke-PSTSMTestRun -Plan $plan -WhatIf
        $r.Started | Should -BeFalse
        Test-Path -LiteralPath $marker | Should -BeFalse -Because '-WhatIf must not run the script'
    }

    It 'registers nothing' {
        # The feature exists to avoid committing anything. Assert that plainly.
        $before = @(Get-ScheduledTask -ErrorAction SilentlyContinue).Count
        $plan = New-PSTSMPlan -ScriptPath (script:New-RunFixture 'NoReg' 'exit 0') -TaskName 'PSTSM_ShouldNeverExist'
        $null = Invoke-PSTSMTestRun -Plan $plan -Confirm:$false
        @(Get-ScheduledTask -ErrorAction SilentlyContinue).Count | Should -Be $before
        @(Get-ScheduledTask -TaskName 'PSTSM_ShouldNeverExist' -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
    }
}


Describe 'Regressions from the second review pass' {
    # This batch came from fuzzing and from switching CurrentCulture - angles the code-reading
    # pass could not reach. Every one was reproduced before it was fixed.

    Context 'The tokeniser does not invent types' {
        # A value that arrived as its own token is a string. Guessing was destructive in three
        # distinct ways, and the round trip is what made each one damaging: the parsed value goes
        # straight back through the renderer when the task is saved again.
        $cases = @(
            @{ Name = 'False';        Arg = 'False';   Expect = 'False' }
            @{ Name = 'True';         Arg = 'True';    Expect = 'True' }
            @{ Name = 'leading zero'; Arg = '007';     Expect = '007' }
            @{ Name = 'plain number'; Arg = '14';      Expect = '14' }
            @{ Name = 'text';         Arg = 'plain';   Expect = 'plain' }
        )
        It 'keeps <Name> as the string it arrived as' -TestCases $cases {
            param($Name, $Arg, $Expect)
            $p = ConvertFrom-PSTSMAction -Execute 'powershell.exe' -Arguments "-File `"C:\s.ps1`" -Val $Arg -After keep"
            $p.Parameters['Val'] | Should -BeExactly $Expect -Because "a $Name value must arrive verbatim"
            $p.Parameters['Val'] | Should -BeOfType [string]
            $p.Parameters['After'] | Should -Be 'keep' -Because "a $Name value must not disturb what follows"
        }

        It 'survives the round trip that made those guesses damaging' {
            # -Val False became $false, which the renderer OMITS -> the parameter vanished.
            # -Val True became $true, which renders bare -> unbindable for a string parameter.
            foreach ($v in 'False', 'True', '007') {
                $parsed = ConvertFrom-PSTSMAction -Execute 'powershell.exe' -Arguments "-File `"C:\s.ps1`" -Val $v"
                $again = ConvertTo-PSTSMArgument -ScriptPath 'C:\s.ps1' -Parameters $parsed.Parameters
                $again | Should -BeLike "*-Val $v*" -Because "$v must survive a save"
            }
        }

        It 'still reads an explicit -X:$false as a real Boolean' {
            # The colon form is the only one where a Boolean is unambiguous, and the
            # switch-default-true feature emits exactly it. That path must not regress.
            $p = ConvertFrom-PSTSMAction -Execute 'powershell.exe' -Arguments '-File "C:\s.ps1" -Flag:$false'
            $p.Parameters['Flag'] | Should -BeOfType [bool]
            $p.Parameters['Flag'] | Should -BeFalse
        }

        It 'reads a genuinely bare switch as a Boolean' {
            $p = ConvertFrom-PSTSMAction -Execute 'powershell.exe' -Arguments '-File "C:\s.ps1" -Flag -Other x'
            $p.Parameters['Flag'] | Should -BeOfType [bool]
            $p.Parameters['Flag'] | Should -BeTrue
        }

        It 'accepts a parameter name with a non-ASCII letter' {
            # An ASCII-only identifier class demoted it to ExtraArguments while the editor still
            # built a control from the script's param() block - so saving emitted the parameter
            # TWICE and the task died on every run with "specified more than once".
            $name = "Gr$([char]0xF6)sse"
            $p = ConvertFrom-PSTSMAction -Execute 'powershell.exe' -Arguments "-File `"C:\s.ps1`" -$name LARGE"
            $p.Parameters[$name] | Should -Be 'LARGE'
            $p.ExtraArguments | Should -BeNullOrEmpty -Because 'it must not also land in the raw arguments'
        }
    }

    Context 'Arrays are refused rather than silently mangled' {
        It 'throws for a multi-value array, naming the reason' {
            { ConvertTo-PSTSMArgument -ScriptPath 'C:\s.ps1' -Parameters ([ordered]@{ Days = @('Mon', 'Tue') }) } |
                Should -Throw -ExpectedMessage '*-File cannot deliver*'
        }

        It 'proves the refusal is warranted, by running the encoding that was there before' {
            # Not taken on faith: the old comma form is executed against a real [string[]]
            # parameter and observed to arrive as a single element.
            $f = Join-Path $TestDrive 'arr.ps1'
            'param([string[]]$Arr) "count=$($Arr.Count)"; exit 0' | Set-Content -LiteralPath $f -Encoding UTF8
            $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File $f -Arr 'alpha,beta'
            $out | Should -Match 'count=1' -Because 'under -File nothing splits on commas'
        }

        It 'still allows a single-element array' {
            ConvertTo-PSTSMArgument -ScriptPath 'C:\s.ps1' -Parameters ([ordered]@{ Days = @('Mon') }) |
                Should -BeLike '*-Days Mon*'
        }
    }

    Context 'Culture cannot reach the data path' {
        # fi-FI substitutes '.' for the time separator; ar-SA substitutes a Hijri YEAR, which is
        # far worse because the result still looks like a plausible date.
        $cultures = @(
            @{ Culture = 'en-US' }, @{ Culture = 'fi-FI' }, @{ Culture = 'id-ID' }, @{ Culture = 'ar-SA' }
        )

        It 'writes an invariant trigger time when reading a task back under <Culture>' -TestCases $cultures {
            param($Culture)
            # The sibling of New-PSTSMTriggerSpec's writer. It was missed when that one was fixed,
            # so the read half of the round trip silently rewrote the schedule.
            $saved = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [System.Threading.Thread]::CurrentThread.CurrentCulture =
                [System.Globalization.CultureInfo]::GetCultureInfo($Culture)
                $src = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/Task/ConvertFrom-PSTSMDefinition.ps1') -Raw
                $src | Should -Match 'InvariantCulture' -Because 'the reader must pin the culture too'
                # And the writer it pairs with.
                $spec = New-PSTSMTriggerSpec -Type Daily -At '07:00'
                $spec.At | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$'
            }
            finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $saved }
        }

        It 'renders a [datetime] parameter value invariantly under <Culture>' -TestCases $cultures {
            param($Culture)
            # PS7's ConvertFrom-Json turns an exported ISO value back into a real DateTime, so a
            # plan that has been through JSON reaches the renderer as [datetime] - and would be
            # written onto the live command line in the local calendar.
            $saved = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [System.Threading.Thread]::CurrentThread.CurrentCulture =
                [System.Globalization.CultureInfo]::GetCultureInfo($Culture)
                $a = ConvertTo-PSTSMArgument -ScriptPath 'C:\s.ps1' `
                    -Parameters ([ordered]@{ When = [datetime]'2026-07-30T07:00:00' })
                $a | Should -Match '-When 2026-07-30T07:00:00'
            }
            finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $saved }
        }
    }
}


Describe 'Second review pass - remaining findings' {
    BeforeAll { $script:Root2 = Split-Path $PSScriptRoot -Parent }

    Context 'A file that could not be read is not a file with errors' {
        It 'reports a locked file as unreadable, not as three invented defects' {
            # A genuinely unreadable file, produced by holding an exclusive lock - no ACL games,
            # and it reproduces the real FileReadError that ParseFile returns. That error used to
            # be folded into the syntax-error list, so the tool asserted "fix the syntax errors",
            # "parameters the script does not declare" and "no exit code" about a file it had
            # never opened, and blocked Save with the wrong reason.
            $locked = Join-Path $TestDrive 'locked.ps1'
            'param([string]$Real) exit 0' | Set-Content -LiteralPath $locked -Encoding UTF8
            $stream = [System.IO.File]::Open($locked, 'Open', 'Read', 'None')
            try {
                $prof = Get-PSTSMScriptProfile -Path $locked
                $prof.IsReadable | Should -BeFalse -Because 'the parser could not read it'
                $prof.ParseErrors | Should -Not -BeNullOrEmpty

                $plan = New-PSTSMPlan -ScriptPath $script:QuietScript
                $plan.ScriptPath = $locked
                $r = @(Test-PSTSMPlan -Plan $plan -ScriptProfile $prof -SkipExistingTaskCheck)
                ($r | Where-Object Id -eq 'SCRIPT_UNREADABLE').Severity | Should -Be 'Error'
                @($r | Where-Object Id -eq 'SCRIPT_PARSE') | Should -HaveCount 0 -Because 'it is not a syntax problem'
                @($r | Where-Object Id -eq 'EXIT_CODE') | Should -HaveCount 0 -Because '"no exit statement" is true of every unread file'
            }
            finally { $stream.Dispose() }
        }

        It 'still reports a genuine syntax error as one' {
            $bad = Join-Path $TestDrive 'broken.ps1'
            'param(' | Set-Content -LiteralPath $bad -Encoding UTF8
            $plan = New-PSTSMPlan -ScriptPath $script:QuietScript
            $plan.ScriptPath = $bad
            $r = @(Test-PSTSMPlan -Plan $plan -SkipExistingTaskCheck)
            ($r | Where-Object Id -eq 'SCRIPT_PARSE').Severity | Should -Be 'Error'
            @($r | Where-Object Id -eq 'SCRIPT_UNREADABLE') | Should -HaveCount 0
        }
    }

    Context 'Transcript logging cannot fail in silence' {
        It 'warns when the log directory is not usable' {
            # The wrapper deliberately lets the task run when Start-Transcript fails, so the exit
            # code stays truthful - which means a broken log path produces no signal anywhere at
            # run time. Preflight is the only place to say it.
            $plan = New-PSTSMPlan -ScriptPath $script:QuietScript
            $plan.Logging.Mode = 'Transcript'
            $plan.Logging.Directory = 'Z:\no-such-volume\logs'
            $r = @(Test-PSTSMPlan -Plan $plan -SkipExistingTaskCheck)
            @($r | Where-Object Id -eq 'LOG_DIR') | Should -Not -BeNullOrEmpty
        }

        It 'flags a UNC log path, which an S4U task cannot reach' {
            $plan = New-PSTSMPlan -ScriptPath $script:QuietScript
            $plan.Logging.Mode = 'Transcript'
            $plan.Logging.Directory = '\\server\share\logs'
            $r = @(Test-PSTSMPlan -Plan $plan -SkipExistingTaskCheck)
            @($r | Where-Object Id -in 'LOG_DIR', 'LOG_DIR_UNC') | Should -Not -BeNullOrEmpty
        }

        It 'blocks a wrapper path that would exceed MAX_PATH' {
            # Fails at Save naming a directory that visibly exists - and on PowerShell 7 it
            # SUCCEEDS and the task then fails on every run.
            $plan = New-PSTSMPlan -ScriptPath $script:QuietScript -TaskName ('L' * 240)
            $plan.Logging.Mode = 'Transcript'
            $r = @(Test-PSTSMPlan -Plan $plan -SkipExistingTaskCheck)
            ($r | Where-Object Id -eq 'LOG_WRAPPER_PATH').Severity | Should -Be 'Error'
        }
    }

    Context 'Generated wrapper substitution' {
        It 'does not substitute into its own output' {
            # Chained .Replace calls let each replacement rewrite the previous one's output: a task
            # named "Has__RETENTION__Inside" came out as "Has30Inside" and failed every run.
            $d = Join-Path $TestDrive 'sub'
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $d 'demo.ps1') -Value 'exit 0' -Encoding UTF8
            $plan = New-PSTSMPlan -ScriptPath (Join-Path $d 'demo.ps1') -TaskName 'Has__RETENTION__Inside'
            $plan.Logging.Mode = 'Transcript'
            $text = Get-Content -LiteralPath (New-PSTSMLogWrapper -Plan $plan) -Raw
            $text | Should -Not -Match 'Has30Inside'
            $text | Should -Match ([regex]::Escape('Has__RETENTION__Inside'))
        }
    }

    Context 'Default-value resolution declines what it cannot do honestly' {
        It 'refuses a numeric + instead of pasting the digits together' {
            # [int]$Port = 8000 + 80 was shown in the cue banner as 800080. The resolver
            # stringifies both operands, so '+' silently meant concatenation for numbers too.
            (Resolve-PSTSMDefaultValue -Expression '8000 + 80').Kind | Should -Not -Be 'Resolved'
            (Resolve-PSTSMDefaultValue -Expression '1 + 2').Kind | Should -Not -Be 'Resolved'
        }
        It 'still resolves genuine string concatenation' {
            $r = Resolve-PSTSMDefaultValue -Expression "'a' + 'b'"
            $r.Kind | Should -Be 'Resolved'
            $r.Value | Should -Be 'ab'
        }
    }

    Context 'Health reports coverage, not just findings' {
        It 'returns how many tasks it swept' {
            # "Nothing wrong found" in green after checking ZERO tasks is byte-identical to a clean
            # machine, and the default view excludes non-PowerShell and \Microsoft\ tasks - so a
            # machine with real problems could produce an all-clear.
            $checked = -1
            $null = Test-PSTSMHealth -TaskPath '\NoSuchFolderAnywhere\' -CheckedCount ([ref]$checked) -ErrorAction SilentlyContinue
            $checked | Should -Be 0 -Because 'the caller must be able to tell "clean" from "nothing looked at"'
        }
    }

    Context 'Non-English Windows' {
        It 'classifies a service-account author by SID, not by an English string' {
            # "NT AUTHORITY" is localised - NT-AUTORITAT on German Windows - so a literal match
            # classified every service-authored task as Person there.
            $src = Get-Content -LiteralPath (Join-Path $script:Root2 'Functions/Task/Get-PSTSMTaskOrigin.ps1') -Raw
            $src | Should -Match 'S-1-5-18'
            $src | Should -Match 'SecurityIdentifier'
        }

        It 'formats every displayed date invariantly' {
            # An ISO-shaped slot filled with a Hijri or Buddhist year reads as a plausible-but-
            # wrong Gregorian date in Last run / Next run / the run log.
            $offenders = @()
            foreach ($f in Get-ChildItem $script:Root2 -Recurse -Filter *.ps1) {
                if ($f.FullName -like '*\Tests\*') { continue }
                $n = 0
                foreach ($line in (Get-Content -LiteralPath $f.FullName)) {
                    $n++
                    if ($line -match "ToString\('[^']*(yyyy|HH:mm)[^']*'\)") { $offenders += "$($f.Name):$n" }
                }
            }
            $offenders | Should -BeNullOrEmpty -Because "these format a date without pinning the culture: $($offenders -join ', ')"
        }
    }

    Context 'Accessibility' {

        It 'hands the whole palette to the system under High Contrast' {
            $src = Get-Content -LiteralPath (Join-Path $script:Root2 'UI/PSTSMUI.Common.ps1') -Raw
            $src | Should -Match 'HighContrast'
            $src | Should -Match 'SystemColors'
        }
    }
}


Describe 'Argument round trip survives hostile values' {
    # The fuzz table that found the tokeniser bugs, kept as a test so it keeps finding them.
    # Every value goes ConvertTo -> ConvertFrom and must come back byte-identical, AND must not
    # disturb the parameters after it - a tokeniser that mishandles a value usually swallows the
    # rest of the command line, which is the damaging half.
    BeforeDiscovery {
        $script:FuzzValues = @(
            'plain', ' ', '  spaced  '
            'C:\Logs', 'C:\Logs\', 'C:\Program Files\App', 'C:\Program Files\App\'
            '\\server\share', '\\server\share\', '\\server\share\path with space\'
            'a\b', 'a\\b', 'a\\\b', 'ends\\', 'ends\\\'
            'said "hi"', '"quoted"', 'mid"quote', 'quote"then\'
            "O'Brien", "it's", '`backtick`', '$var', '$(cmd)', '@{a=1}'
            'comma,sep', 'a,b,c', 'semi;colon', 'amp&and', 'pipe|bar', 'lt<gt>'
            'caret^', 'percent%', 'hash#', 'star*', 'question?', 'bang!', 'tilde~'
            '007', '-42', '3.14', '5551234567', '99999999999999999999'
            'True', 'False', '$true', '$false', 'null'
            '-leadingdash', '--double'
            'ünïcödé', 'ключ', '日本語'
            'trailing ', ' leading', '/slash', 'C:/forward/slash', '%TEMP%'
        )
    }

    It 'round-trips <_> without loss or collateral damage' -ForEach $script:FuzzValues {
        $value = $_
        $rendered = ConvertTo-PSTSMArgument -ScriptPath 'C:\s.ps1' `
            -Parameters ([ordered]@{ Val = $value; Marker = 'SENTINEL'; Tail = 'END' })
        $back = ConvertFrom-PSTSMAction -Execute 'powershell.exe' -Arguments $rendered

        [string]$back.Parameters['Val'] | Should -BeExactly $value
        [string]$back.Parameters['Marker'] | Should -Be 'SENTINEL' -Because 'the value must not swallow what follows'
        [string]$back.Parameters['Tail'] | Should -Be 'END'
    }

    It 'quotes a value beginning with a dash so it cannot be read back as a parameter name' {
        # Unquoted, -Val -leadingdash parsed as a bare switch plus an invented parameter, so
        # reopening and saving such a task silently lost the value. The engine binds it either
        # way, so quoting costs nothing and makes the round trip unambiguous.
        $a = ConvertTo-PSTSMArgument -ScriptPath 'C:\s.ps1' -Parameters ([ordered]@{ Val = '-leadingdash' })
        $a | Should -Match ([regex]::Escape('-Val "-leadingdash"'))
    }

    It 'still treats a genuinely unquoted -Name as a parameter' {
        # The other side of that fix: quoting must not make every dash a value.
        $back = ConvertFrom-PSTSMAction -Execute 'powershell.exe' -Arguments '-File "C:\s.ps1" -Flag -Other x'
        $back.Parameters['Flag'] | Should -BeTrue
        $back.Parameters['Other'] | Should -Be 'x'
    }
}

Describe 'Values reach the script intact' {
    # The round trip above proves PSTSM is self-consistent. This proves the command line it
    # produces actually delivers, which is a different claim and the one that matters at 3am.
    BeforeAll {
        $script:DeliverScript = Join-Path $TestDrive 'deliver.ps1'
        # UTF-8 WITH BOM: Windows PowerShell 5.1 reads a BOM-less UTF-8 .ps1 as ANSI, which
        # mangles any non-ASCII literal inside it. PSTSM's own generated wrapper writes a BOM for
        # exactly this reason.
        [System.IO.File]::WriteAllText($script:DeliverScript,
            'param([string]$Val, [string]$Marker) if ($Marker -ne "SENTINEL") { exit 9 }; [IO.File]::WriteAllText($env:PSTSM_TEST_OUT, $Val, [Text.UTF8Encoding]::new($false)); exit 0',
            (New-Object System.Text.UTF8Encoding($true)))
    }

    $cases = @(
        @{ Name = 'trailing backslash'; Value = 'C:\Program Files\App\' }
        @{ Name = 'embedded quote'; Value = 'said "hi"' }
        @{ Name = 'comma'; Value = 'Quarter close, please review' }
        @{ Name = 'leading dash'; Value = '-leadingdash' }
        @{ Name = 'unicode'; Value = 'ünïcödé-日本語' }
        @{ Name = 'shell metacharacters'; Value = 'a&b|c;d^e' }
    )
    It 'delivers a <Name> value to the script byte-for-byte' -TestCases $cases {
        param($Name, $Value)
        # Read back through a FILE, not stdout: PowerShell 5.1 writes redirected output through a
        # legacy code page that cannot represent CJK at all, so stdout would fail this for reasons
        # that have nothing to do with argument delivery.
        $outFile = Join-Path $TestDrive "delivered_$([guid]::NewGuid().ToString('N')).txt"
        $env:PSTSM_TEST_OUT = $outFile
        try {
            $plan = New-PSTSMPlan -ScriptPath $script:DeliverScript `
                -Parameters ([ordered]@{ Val = $Value; Marker = 'SENTINEL' })
            $r = Invoke-PSTSMTestRun -Plan $plan -TimeoutSeconds 30 -Confirm:$false
            $r.ExitCode | Should -Be 0 -Because "a $Name value must not break binding"
            Test-Path -LiteralPath $outFile | Should -BeTrue
            [System.IO.File]::ReadAllText($outFile, (New-Object System.Text.UTF8Encoding($false))) |
                Should -BeExactly $Value
        }
        finally { $env:PSTSM_TEST_OUT = $null }
    }
}


Describe 'Broker cancellation survives PowerShell exception wrapping' {
    # Confirmed on a real machine: declining consent does NOT surface as a bare Win32Exception.
    # PowerShell wraps anything thrown by a .NET METHOD call in a MethodInvocationException, so
    # `catch [Win32Exception]` never matched and the Cancelled branch was unreachable - the
    # operator got an error dialog for having said no.
    BeforeAll {
        $script:BrokerPlan2 = New-PSTSMPlan -ScriptPath $script:QuietScript -TaskName 'WrapCase' -RunLevel 'Highest'
    }

    It 'reports Cancelled when ERROR_CANCELLED arrives wrapped' {
        Mock -ModuleName PSTSM -CommandName 'Start-PSTSMBrokerProcess' -MockWith {
            $inner = New-Object System.ComponentModel.Win32Exception 1223
            throw (New-Object System.Management.Automation.MethodInvocationException 'Exception calling "Start"', $inner)
        }
        $r = Invoke-PSTSMElevatedRegistration -Plan $script:BrokerPlan2 -Confirm:$false
        $r.Cancelled | Should -BeTrue -Because 'the Win32Exception is one level down, not at the top'
        $r.Error | Should -BeNullOrEmpty
    }

    It 'still reports Cancelled when it arrives unwrapped' {
        Mock -ModuleName PSTSM -CommandName 'Start-PSTSMBrokerProcess' -MockWith {
            throw (New-Object System.ComponentModel.Win32Exception 1223)
        }
        $r = Invoke-PSTSMElevatedRegistration -Plan $script:BrokerPlan2 -Confirm:$false
        $r.Cancelled | Should -BeTrue
    }

    It 'explains a disabled Application Information service rather than echoing Win32 1060' {
        # 1060 is what a disabled AppInfo service looks like. Nobody would guess that from
        # "The specified service does not exist as an installed service".
        Mock -ModuleName PSTSM -CommandName 'Start-PSTSMBrokerProcess' -MockWith {
            $inner = New-Object System.ComponentModel.Win32Exception 1060
            throw (New-Object System.Management.Automation.MethodInvocationException 'Exception calling "Start"', $inner)
        }
        $r = Invoke-PSTSMElevatedRegistration -Plan $script:BrokerPlan2 -Confirm:$false
        $r.Cancelled | Should -BeFalse
        $r.Error | Should -BeLike '*Application Information*'
    }
}
