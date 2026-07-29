# SPDX-License-Identifier: GPL-3.0-or-later
#Requires -Modules Pester
<#
    Offline unit tests for the PSTSM engine. Nothing here registers a real scheduled
    task or touches Task Scheduler; every check runs against fixture scripts in $TestDrive.

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
                Days       = @('Mon', 'Tue')
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
    It 'joins arrays with commas' {
        $script:args1 | Should -BeLike '*-Days Mon,Tue*'
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
        $dpapi = Join-Path $TestDrive 'Uses-Dpapi.ps1'
        @'
param([string]$CredentialPath = 'C:\secrets\api.dat')
$secure = Get-Content -LiteralPath $CredentialPath | ConvertTo-SecureString
exit 0
'@ | Set-Content -LiteralPath $dpapi -Encoding UTF8

        $plan = New-PSTSMPlan -ScriptPath $dpapi
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
        $dpapi = Join-Path $TestDrive 'Uses-Dpapi.ps1'
        $plan = New-PSTSMPlan -ScriptPath $dpapi -LogonType 'Password' -UserId 'CONTOSO\svc_x'
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
