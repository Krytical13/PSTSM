#Requires -Modules Pester
<#
    UI tests for PSTaskBuilder.

    WinForms bugs mostly do not show up as exceptions - they show up as a control sized to
    zero, or flung off-screen at a DPI you did not test. So these do three things:

      1. Source lint for the two patterns that fail specifically on Windows PowerShell 5.1
         (.GetNewClosure() in a handler, and @() around a List[object]).
      2. Build every window headlessly via the -BuildOnly test seam, force layout, and assert
         no control ended up at a negative position or zero size.
      3. Actually Show() the windows and pump the message loop with a thread-exception trap.
         DrawToBitmap does not reproduce show-time failures; only a live pump does.

    Run:  Invoke-Pester -Path .\PSTaskBuilder.UI.Tests.ps1
    The live tests need an STA apartment and are skipped automatically under MTA (pwsh's
    default), so run this under powershell.exe or `pwsh -STA` for full coverage.
#>

# Evaluated during Pester's DISCOVERY phase, which is when -Skip: on a Describe is read.
# Setting this in BeforeAll (run phase) would be too late and every form test would skip
# silently while still reporting STA - which is exactly what happened the first time.
$script:IsSta = ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA')

BeforeAll {
    # Without this, an exception inside any WinForms handler reaches the global thread-exception
    # handler, which pops a MODAL message box on the desktop of whoever is at the machine and
    # blocks the run until it is dismissed. That happened while these tests were being written.
    $env:PSTASKBUILDER_NODIALOG = '1'

    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:ModuleRoot 'PSTaskBuilder.psd1') -Force

    $script:UIRoot = Join-Path $script:ModuleRoot 'UI'
    $script:UIFiles = @(Get-ChildItem -Path $script:UIRoot -Filter '*.ps1' -Recurse)

    # A real script to drive the editor with.
    $script:Fixture = Join-Path $TestDrive 'Invoke-Fixture.ps1'
    @'
<#
.SYNOPSIS
    Fixture used by the UI tests.
.PARAMETER Server
    Where to send it.
#>
param(
    [Parameter(Mandatory)][string]$Server,
    [ValidateSet('Low','Normal','High')][string]$Priority = 'Normal',
    [int]$Retries = 3,
    [switch]$DryRun,
    [string]$OutputPath = 'C:\Out'
)
exit 0
'@ | Set-Content -LiteralPath $script:Fixture -Encoding UTF8

    # Walks a control tree and returns every descendant.
    function Get-AllControl {
        param([System.Windows.Forms.Control]$Root)
        $out = New-Object System.Collections.Generic.List[object]
        $stack = New-Object System.Collections.Generic.Stack[object]
        $stack.Push($Root)
        while ($stack.Count -gt 0) {
            $c = $stack.Pop()
            foreach ($child in $c.Controls) {
                $out.Add($child)
                $stack.Push($child)
            }
        }
        # .ToArray(), never @($out) - wrapping a List[object] in @() throws
        # "Argument types do not match" on Windows PowerShell 5.1.
        $out.ToArray()
    }

    function Initialize-FormLayout {
        param([System.Windows.Forms.Form]$Form)
        $null = $Form.Handle          # force handle creation so layout actually runs
        $Form.CreateControl()
        $Form.PerformLayout()
    }

    # Any control whose rendered size is smaller than the size it says it needs is clipping.
    function Get-ClippedControl {
        param([System.Windows.Forms.Control]$Root)
        $bad = New-Object System.Collections.Generic.List[string]
        foreach ($c in (Get-AllControl -Root $Root)) {
            if ($c -isnot [System.Windows.Forms.Button] -and $c -isnot [System.Windows.Forms.Label]) { continue }
            $p = $c.PreferredSize
            if ($c.Width -lt $p.Width -or $c.Height -lt $p.Height) {
                $bad.Add("$($c.GetType().Name) '$($c.Text)': $($c.Width)x$($c.Height) < needs $($p.Width)x$($p.Height)")
            }
        }
        $bad.ToArray()
    }
}

Describe 'UI source lint (Windows PowerShell 5.1 hazards)' {
    It 'has UI files to check' {
        $script:UIFiles.Count | Should -BeGreaterThan 0
    }

    It 'never uses .GetNewClosure() in the UI' {
        # On 5.1 a .GetNewClosure() scriptblock loses module session-state affinity: module
        # functions become "not recognized" and $script: variables read empty. Every handler
        # here is a plain scriptblock relying on module affinity plus on-stack locals.
        $offenders = @()
        foreach ($f in $script:UIFiles) {
            $text = Get-Content -LiteralPath $f.FullName -Raw
            $tokens = $null; $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
            $found = $ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                    $n.Member.Extent.Text -eq 'GetNewClosure'
                }, $true)
            foreach ($x in $found) { $offenders += "$($f.Name):$($x.Extent.StartLineNumber)" }
        }
        $offenders | Should -BeNullOrEmpty
    }

    It 'never wraps a List[object] variable in @()' {
        # @($list) where $list is [List[object]] throws "Argument types do not match" on 5.1.
        # Verified directly: plain arrays are fine, List[object] is not. Always use .ToArray().
        $offenders = @()
        foreach ($f in $script:UIFiles) {
            $lines = Get-Content -LiteralPath $f.FullName
            $listVars = @()
            foreach ($l in $lines) {
                if ($l -match '\$(\w+)\s*=\s*New-Object\s+System\.Collections\.Generic\.List') { $listVars += $Matches[1] }
            }
            foreach ($v in ($listVars | Select-Object -Unique)) {
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -match "@\(\s*\`$$v\s*\)") { $offenders += "$($f.Name):$($i + 1) @(`$$v)" }
                }
            }
        }
        $offenders | Should -BeNullOrEmpty
    }

    It 'parses cleanly' {
        foreach ($f in $script:UIFiles) {
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
            if ($errors -and $errors.Count -gt 0) {
                throw "$($f.Name): $($errors[0].Message) at line $($errors[0].Extent.StartLineNumber)"
            }
        }
    }
}

Describe 'Headless form construction' -Skip:(-not $script:IsSta) {
    Context 'the editor, with no script selected' {
        BeforeAll {
            $script:formA = Show-PSTaskEditor -BuildOnly
            Initialize-FormLayout -Form $script:formA
        }
        AfterAll { if ($script:formA) { $script:formA.Dispose() } }

        It 'builds' { $script:formA | Should -Not -BeNullOrEmpty }
        It 'has content' { $script:formA.Controls.Count | Should -BeGreaterThan 0 }
        It 'places no control at a negative coordinate' {
            # The classic symptom of absolute Location plus anchoring inside a TableLayoutPanel.
            $bad = @(Get-AllControl -Root $script:formA | Where-Object { $_.Left -lt 0 -or $_.Top -lt 0 } |
                    ForEach-Object { "$($_.GetType().Name)/$($_.Name) at $($_.Left),$($_.Top)" })
            $bad | Should -BeNullOrEmpty
        }
    }

    Context 'the editor, with a script selected' {
        BeforeAll {
            $script:formB = Show-PSTaskEditor -ScriptPath $script:Fixture -BuildOnly
            Initialize-FormLayout -Form $script:formB
            $script:allB = Get-AllControl -Root $script:formB
        }
        AfterAll { if ($script:formB) { $script:formB.Dispose() } }

        It 'generates one control per script parameter' {
            # Server, Priority, Retries, DryRun, OutputPath = 5 labels in the parameter table.
            $labels = @($script:allB | Where-Object { $_ -is [System.Windows.Forms.Label] } | ForEach-Object { $_.Text })
            $labels | Should -Contain 'Server *'          # mandatory gets the marker
            $labels | Should -Contain 'Retries'
            $labels | Should -Contain 'DryRun'
        }
        It 'renders a ValidateSet parameter as a combo box with a blank "not supplied" entry' {
            $combos = @($script:allB | Where-Object { $_ -is [System.Windows.Forms.ComboBox] })
            $priority = @($combos | Where-Object { $_.Items.Contains('High') -and $_.Items.Contains('Low') })
            $priority.Count | Should -Be 1
            $priority[0].Items[0] | Should -Be ''
        }
        It 'renders a switch parameter as a check box' {
            @($script:allB | Where-Object { $_ -is [System.Windows.Forms.CheckBox] }).Count | Should -BeGreaterThan 0
        }
        It 'pre-fills parameter controls with the script declared defaults' {
            # The form and the preview must agree. Blank boxes next to a preview showing
            # '-DaysOut 14' reads as a bug even when both are technically correct.
            $boxes = @($script:allB | Where-Object { $_ -is [System.Windows.Forms.TextBox] -and -not $_.ReadOnly })
            @($boxes | ForEach-Object { $_.Text }) | Should -Contain '3'          # Retries = 3
            @($boxes | ForEach-Object { $_.Text }) | Should -Contain 'C:\Out'     # OutputPath
            $combos = @($script:allB | Where-Object { $_ -is [System.Windows.Forms.ComboBox] -and $_.Items.Contains('High') })
            $combos[0].SelectedItem | Should -Be 'Normal'                          # Priority default
        }

        It 'pre-fills the run-as account so the form agrees with the preview' {
            # Regression. New-PSTaskPlan falls back to the current user when the box is blank,
            # so the preview named an account the form left empty.
            $boxes = @($script:allB | Where-Object { $_ -is [System.Windows.Forms.TextBox] -and -not $_.ReadOnly })
            @($boxes | ForEach-Object { $_.Text }) | Should -Contain "$env:USERDOMAIN\$env:USERNAME"

            $preview = @($script:allB | Where-Object {
                    $_ -is [System.Windows.Forms.TextBox] -and $_.ReadOnly -and $_.Multiline -and $_.Text -like '*Run as*'
                })
            $preview[0].Text | Should -BeLike "*$env:USERDOMAIN\$env:USERNAME*"
        }

        It 'shows the derived command in the preview' {
            $previews = @($script:allB | Where-Object {
                    $_ -is [System.Windows.Forms.TextBox] -and $_.ReadOnly -and $_.Multiline -and $_.Text -like '*Arguments*'
                })
            $previews.Count | Should -BeGreaterThan 0
            $previews[0].Text | Should -BeLike '*-NoProfile -NonInteractive -ExecutionPolicy Bypass*'
            $previews[0].Text | Should -BeLike "*-File `"$($script:Fixture)`"*"
        }
        It 'runs the preflight and surfaces the missing mandatory parameter' {
            $lv = @($script:allB | Where-Object { $_ -is [System.Windows.Forms.ListView] })
            $lv.Count | Should -Be 1
            $titles = @($lv[0].Items | ForEach-Object { $_.SubItems[1].Text })
            $titles | Should -Contain 'Mandatory parameters have no value'
        }
        It 'blocks saving while a preflight error stands' {
            $save = @($script:allB | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -like '*error*' })
            $save.Count | Should -Be 1
            $save[0].Enabled | Should -BeFalse
        }
        It 'places no control at a negative coordinate' {
            $bad = @($script:allB | Where-Object { $_.Left -lt 0 -or $_.Top -lt 0 } |
                    ForEach-Object { "$($_.GetType().Name)/$($_.Name) at $($_.Left),$($_.Top)" })
            $bad | Should -BeNullOrEmpty
        }
    }

    Context 'the main window' {
        BeforeAll {
            $script:formC = Show-PSTaskBuilder -BuildOnly
            Initialize-FormLayout -Form $script:formC
            $script:allC = Get-AllControl -Root $script:formC
        }
        AfterAll { if ($script:formC) { $script:formC.Dispose() } }

        It 'builds a grid with the expected columns' {
            $grids = @($script:allC | Where-Object { $_ -is [System.Windows.Forms.DataGridView] })
            $grids.Count | Should -Be 1
            $names = @($grids[0].Columns | ForEach-Object { $_.Name })
            $names | Should -Contain 'ScriptName'
            $names | Should -Contain 'LastResultText'
            $names | Should -Contain 'TriggerSummary'
        }
        It 'places no control at a negative coordinate' {
            $bad = @($script:allC | Where-Object { $_.Left -lt 0 -or $_.Top -lt 0 } |
                    ForEach-Object { "$($_.GetType().Name)/$($_.Name) at $($_.Left),$($_.Top)" })
            $bad | Should -BeNullOrEmpty
        }

        It 'survives being shown outside its building function' {
            # Regression. The Shown handler is the only one that fires without user action, so
            # on a -BuildOnly form handed to a harness it runs after the frame is gone and
            # $reload no longer resolves. Unguarded, that threw into the global handler and
            # popped a modal error dialog on the desktop. It must now be a quiet no-op.
            $caught = $null
            $f = Show-PSTaskBuilder -BuildOnly
            try {
                $f.WindowState = 'Minimized'
                $f.ShowInTaskbar = $false
                $f.Show()
                for ($i = 0; $i -lt 10; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 10 }
            }
            catch { $caught = $_ }
            finally { $f.Close(); $f.Dispose() }
            $caught | Should -BeNullOrEmpty
        }
    }

    Context 'display scaling' {
        # Regression. The first build gave every button a fixed Width/Height and the field
        # tables a fixed 132px label column. That is fine at 100% and clips the caption on any
        # machine at 125% or 150% - which is most of them. A form built in PowerShell never
        # auto-scales (AutoScaleMode works off AutoScaleDimensions, which only the designer
        # emits), so the font grows with DPI while pixel constants do not.
        #
        # These tests run at whatever DPI the host reports, then re-run at an inflated font,
        # which reproduces exactly that mismatch without needing a high-DPI machine.
        It 'clips no button or label in the editor at the current font' {
            $f = Show-PSTaskEditor -ScriptPath $script:Fixture -BuildOnly
            try {
                Initialize-FormLayout -Form $f
                Get-ClippedControl -Root $f | Should -BeNullOrEmpty
            }
            finally { $f.Dispose() }
        }

        It 'clips no button or label in the editor at a 150%-sized font' {
            $f = Show-PSTaskEditor -ScriptPath $script:Fixture -BuildOnly
            try {
                Initialize-FormLayout -Form $f
                $f.Font = New-Object System.Drawing.Font('Segoe UI', 13.5)   # 9pt * 1.5
                $f.PerformLayout()
                Get-ClippedControl -Root $f | Should -BeNullOrEmpty
            }
            finally { $f.Dispose() }
        }

        It 'clips no button or label in the main window at a 150%-sized font' {
            $f = Show-PSTaskBuilder -BuildOnly
            try {
                Initialize-FormLayout -Form $f
                $f.Font = New-Object System.Drawing.Font('Segoe UI', 13.5)
                $f.PerformLayout()
                Get-ClippedControl -Root $f | Should -BeNullOrEmpty
            }
            finally { $f.Dispose() }
        }

        It 'clips nothing in the account picker or the gMSA dialog at a 150%-sized font' {
            # These two carry the most explanatory text, so they are the likeliest to overflow
            # once the font grows.
            foreach ($build in @({ Show-PSTaskAccountPicker -BuildOnly }, { Show-PSTaskGmsaDialog -BuildOnly })) {
                $f = & $build
                try {
                    Initialize-FormLayout -Form $f
                    $f.Font = New-Object System.Drawing.Font('Segoe UI', 13.5)
                    $f.PerformLayout()
                    Get-ClippedControl -Root $f | Should -BeNullOrEmpty
                    @(Get-AllControl -Root $f | Where-Object { $_.Left -lt 0 -or $_.Top -lt 0 }) | Should -BeNullOrEmpty
                    $f.Height | Should -BeLessOrEqual ([System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height)
                }
                finally { $f.Dispose() }
            }
        }

        It 'opens no larger than the screen' {
            # A 1180x780 design becomes 1770x1170 at 150%, which would put the action bar below
            # the bottom edge of a 1080p display.
            $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
            $f = Show-PSTaskEditor -BuildOnly
            try {
                $f.Width | Should -BeLessOrEqual $screen.Width
                $f.Height | Should -BeLessOrEqual $screen.Height
            }
            finally { $f.Dispose() }
        }
    }

    Context 'the account picker and gMSA utility' {
        It 'always offers the built-in principals, even with no domain' {
            # A workgroup machine must not get an empty picker - SYSTEM is a valid and often
            # correct answer, and is available without any directory at all.
            $rows = @(Get-PSTaskRunAsAccount -Type BuiltIn)
            @($rows | ForEach-Object { $_.Name }) | Should -Contain 'SYSTEM'
            ($rows | Where-Object Name -eq 'SYSTEM').SuggestedLogonType | Should -Be 'ServiceAccount'
        }

        It 'pairs every account with the logon type it needs' {
            # Account and logon type are one decision; a row that did not carry its own type
            # would let the editor set a gMSA with LogonType S4U, which cannot register.
            foreach ($r in @(Get-PSTaskRunAsAccount)) {
                $r.SuggestedLogonType | Should -BeIn @('gMSA', 'Password', 'ServiceAccount', 'S4U')
            }
        }

        It 'reports gMSA prerequisites without hanging when there is no domain' {
            $checks = @(Test-PSTaskGmsaPrerequisite)
            $checks.Count | Should -BeGreaterThan 0
            @($checks | ForEach-Object { $_.Severity }) | Should -Not -Contain $null
        }

        It 'explains what the KDS root key is, not just that it is missing' {
            # The whole point of the guided flow: an admin who has never used gMSAs should
            # learn why this exists rather than be handed a command to paste.
            $checks = @(Test-PSTaskGmsaPrerequisite)
            $kds = $checks | Where-Object Id -in 'GMSAPRE_NOKDSKEY', 'GMSAPRE_KDS_OK', 'GMSAPRE_KDS_PENDING', 'GMSAPRE_NODC'
            $kds | Should -Not -BeNullOrEmpty
        }

        It 'refuses to guess a gMSA name that cannot fit in a sAMAccountName' {
            { New-PSTaskGmsa -Name 'this_name_is_far_too_long' `
                    -PrincipalsAllowedToRetrieveManagedPassword 'grp' -WhatIf } |
                Should -Throw '*cannot exceed 15 characters*'
        }

        It 'builds the picker and the gMSA dialog without a domain' {
            { $null = Show-PSTaskAccountPicker -SelfTest } | Should -Not -Throw
            { $null = Show-PSTaskGmsaDialog -SelfTest } | Should -Not -Throw
        }
    }

    Context 'the trigger dialog' {
        It 'validates through the engine rather than its own rules' {
            { New-PSTaskTriggerSpec -Type Weekly -At '07:00' } | Should -Throw '*DaysOfWeek*'
            (New-PSTaskTriggerSpec -Type Daily -At '07:00').Type | Should -Be 'Daily'
        }

        It 'returns the trigger the OK handler built' {
            # Regression, and the reason this seam exists. The result was originally assigned to
            # a bare $result inside the Click handler, which creates it in the HANDLER's scope
            # and leaves the caller's variable untouched - so the dialog always returned $null
            # and "Add trigger" silently did nothing. Only driving the real handler catches it.
            $spec = Show-PSTaskTriggerDialog -SelfTest
            $spec | Should -Not -BeNullOrEmpty
            $spec.Type | Should -Be 'Daily'
            $spec.At | Should -BeLike '*T07:00:00'
            $spec.Enabled | Should -BeTrue
        }
    }
}

Describe 'Live show-and-pump smoke test' -Skip:(-not $script:IsSta) {
    # These use -SelfTest, which shows and pumps INSIDE the Show-* function. A form returned by
    # -BuildOnly cannot be shown: the handlers close over that function's locals, and the frame
    # is gone once it has returned, so every handler fails with "the expression after '&' ...
    # produced an object that was not valid". Real usage calls ShowDialog inside the frame, so
    # -SelfTest is what actually exercises the shipping path.
    BeforeAll {
        function Invoke-WithThreadExceptionTrap {
            param([scriptblock]$Action)
            $caught = New-Object System.Collections.Generic.List[object]
            $handler = [System.Threading.ThreadExceptionEventHandler] {
                param($src, $e)
                $null = $src
                $caught.Add($e.Exception)
            }
            [System.Windows.Forms.Application]::add_ThreadException($handler)
            try { & $Action }
            finally { [System.Windows.Forms.Application]::remove_ThreadException($handler) }
            $caught.ToArray()
        }
    }

    It 'shows the editor and pumps the message loop without a thread exception' {
        # DrawToBitmap renders chrome only and misses show-time failures; a real Show() plus a
        # DoEvents pump is what catches them.
        $fixture = $script:Fixture
        $caught = Invoke-WithThreadExceptionTrap -Action { Show-PSTaskEditor -ScriptPath $fixture -SelfTest }
        if ($caught.Count -gt 0) { throw "Thread exception during show: $($caught[0].Message)" }
        $caught.Count | Should -Be 0
    }

    It 'shows the main window, loads the real task list, and pumps without a thread exception' {
        # This one also exercises Get-PSTaskInventory against the machine's real tasks via the
        # add_Shown handler, so a bad row breaks the test rather than the user's first launch.
        $caught = Invoke-WithThreadExceptionTrap -Action { Show-PSTaskBuilder -SelfTest }
        if ($caught.Count -gt 0) { throw "Thread exception during show: $($caught[0].Message)" }
        $caught.Count | Should -Be 0
    }
}

Describe 'Apartment state' {
    It 'reports which apartment these tests ran in' {
        # A record, not an assertion: under MTA the form tests skip, and a green run then means
        # far less than it looks like. Re-read the apartment here rather than reusing the
        # discovery-time $script:IsSta - that variable lives in the discovery scope and reads
        # empty at run time, which made this line claim SKIPPED on a run that actually passed.
        $apartment = [System.Threading.Thread]::CurrentThread.GetApartmentState()
        $ran = ($apartment -eq 'STA')
        # Write-Host on purpose: this is operator-facing test output, and Write-Output would be
        # captured as a test result rather than shown.
        Write-Information "    Apartment: $apartment (form tests $(if ($ran) { 'RAN' } else { 'SKIPPED - rerun under powershell.exe or pwsh -STA' }))" -InformationAction Continue
        $apartment | Should -BeIn @('STA', 'MTA')
    }
}
