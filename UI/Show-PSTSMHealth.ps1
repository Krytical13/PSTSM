# SPDX-License-Identifier: GPL-3.0-or-later
function Show-PSTSMHealth {
    <#
    .SYNOPSIS
        Window listing every scheduled task that is quietly broken.
    .DESCRIPTION
        A view over Test-PSTSMHealth. Task Scheduler shows "Ready" for a task whose script was
        deleted months ago; this shows what is actually wrong across the whole machine in one
        pass, worst first.

        Nothing here changes anything. Double-clicking a row opens that task in the editor,
        which is where a fix would be made.
    .PARAMETER Owner
        Parent form for modal centring.
    .PARAMETER BuildOnly
        Test seam. Returns the Form without showing it. Layout inspection only.
    .PARAMETER SelfTest
        Test seam. Shows, pumps and closes inside this function.
    .OUTPUTS
        [string] full name of a task the operator asked to open, or $null.
    .EXAMPLE
        Show-PSTSMHealth
    #>
    [CmdletBinding()]
    param(
        [System.Windows.Forms.Form]$Owner,
        [switch]$BuildOnly,
        [switch]$SelfTest
    )

    Initialize-PSTSMUIHost
    $t = Get-PSTSMUITheme
    $dlg = @{ OpenTask = $null; Findings = @(); Checked = 0 }

    $form = New-PSTSMUIForm -Title 'PSTSM - Task health' -Width 1000 -Height 640
    $form.MinimumSize = New-Object System.Drawing.Size(0, 0)

    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.Dock = 'Fill'; $root.ColumnCount = 1; $root.RowCount = 5
    $root.Padding = New-Object System.Windows.Forms.Padding(12, 10, 12, 6)
    foreach ($h in @('AutoSize', 'AutoSize', 'Percent', 'AutoSize', 'AutoSize')) {
        if ($h -eq 'Percent') { [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) }
        else { [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) }
    }

    $lblSummary = New-PSTSMUILabel -Text 'Scanning...' -Header
    $lblSummary.ForeColor = $t.Accent

    $opts = New-Object System.Windows.Forms.FlowLayoutPanel
    $opts.Dock = 'Top'; $opts.AutoSize = $true; $opts.WrapContents = $true
    $opts.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 6)
    $chkPsOnly = New-Object System.Windows.Forms.CheckBox
    $chkPsOnly.Text = 'PowerShell tasks only'; $chkPsOnly.AutoSize = $true; $chkPsOnly.Checked = $true
    $chkPsOnly.Margin = New-Object System.Windows.Forms.Padding(3, 6, 16, 3)
    $chkMs = New-Object System.Windows.Forms.CheckBox
    $chkMs.Text = "Include built-in Microsoft tasks"; $chkMs.AutoSize = $true
    $chkMs.Margin = New-Object System.Windows.Forms.Padding(3, 6, 3, 3)
    [void]$opts.Controls.Add($chkPsOnly); [void]$opts.Controls.Add($chkMs)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Dock = 'Fill'; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $false
    $lv.HideSelection = $false; $lv.BorderStyle = 'FixedSingle'
    [void]$lv.Columns.Add('', 10)
    [void]$lv.Columns.Add('Task', 10)
    [void]$lv.Columns.Add('What is wrong', 10)

    $txtDetail = New-PSTSMUITextBox -ReadOnly -Multiline
    $txtDetail.Height = [int]($t.FontBase.Height * 6)

    $sizeCols = {
        $scale = Get-PSTSMUIScale
        if ($lv.Items.Count -gt 0) { $lv.Columns[0].Width = -2 }
        else { $lv.Columns[0].Width = [int](60 * $scale) }
        $lv.Columns[1].Width = [int](300 * $scale)
        $rest = $lv.ClientSize.Width - $lv.Columns[0].Width - $lv.Columns[1].Width -
        [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth - 2
        if ($rest -gt 80) { $lv.Columns[2].Width = $rest }
    }
    $lv.add_Resize({ if ($sizeCols) { & $sizeCols } })

    $scan = {
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $lv.BeginUpdate()
        $lv.Items.Clear()
        try {
            $p = @{ PowerShellOnly = $chkPsOnly.Checked }
            if ($chkMs.Checked) { $p['IncludeMicrosoft'] = $true }
            $checked = 0
            $dlg.Findings = @(Test-PSTSMHealth @p -CheckedCount ([ref]$checked) -ErrorAction SilentlyContinue)
            $dlg.Checked = $checked

            $ordered = $dlg.Findings | Sort-Object `
            @{ Expression = { (Get-PSTSMUISeverityStyle -Severity $_.Severity).Rank } },
            @{ Expression = { $_.FullName } }

            foreach ($f in $ordered) {
                $style = Get-PSTSMUISeverityStyle -Severity $f.Severity
                $item = New-Object System.Windows.Forms.ListViewItem($style.Token)
                [void]$item.SubItems.Add($f.FullName)
                [void]$item.SubItems.Add($f.Title)
                $item.ForeColor = $style.Color
                $item.Tag = $f
                [void]$lv.Items.Add($item)
            }

            $errors = @($dlg.Findings | Where-Object Severity -eq 'Error').Count
            $warns = @($dlg.Findings | Where-Object Severity -eq 'Warning').Count
            $tasks = @($dlg.Findings | Group-Object FullName).Count

            # Branch on COVERAGE first, then on findings. "Nothing wrong found" in green after
            # checking zero tasks is indistinguishable from a clean machine, and the default view
            # filters to PowerShell tasks outside \Microsoft\ - so a machine with real problems can
            # produce an all-clear simply because the sweep matched nothing.
            if ($dlg.Checked -eq 0) {
                $lblSummary.Text = 'No tasks to check'
                $lblSummary.ForeColor = $t.Warn
                $txtDetail.Text = 'The sweep matched no tasks, so this is not an all-clear. ' +
                'Widen the filters in the main window - "PowerShell tasks only" and the built-in ' +
                'Microsoft tree are both excluded by default - and run it again.'
            }
            elseif ($dlg.Findings.Count -eq 0) {
                $lblSummary.Text = "Nothing wrong found in $($dlg.Checked) task$(if ($dlg.Checked -ne 1) { 's' })"
                $lblSummary.ForeColor = $t.Good
                $txtDetail.Text = 'Every task checked has a script that exists, a schedule that can still fire, and a last run that did not fail.'
            }
            else {
                $bits = @()
                if ($errors -gt 0) { $bits += "$errors error$(if ($errors -ne 1) { 's' })" }
                if ($warns -gt 0) { $bits += "$warns warning$(if ($warns -ne 1) { 's' })" }
                $lblSummary.Text = "$($bits -join ', ') across $tasks task$(if ($tasks -ne 1) { 's' })"
                $lblSummary.ForeColor = $(if ($errors -gt 0) { $t.Danger } else { $t.Warn })
                $txtDetail.Text = 'Select a row for the detail. Double-click to open that task.'
            }
        }
        finally {
            $lv.EndUpdate()
            & $sizeCols
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    }

    $lv.add_SelectedIndexChanged({
            # Gate the primary on selection. A lit accent-filled button whose handler returns
            # immediately is worse than a disabled one: the operator presses it, nothing happens,
            # and there is no way to tell a broken tool from a wrong click.
            $btnOpen.Enabled = ($lv.SelectedItems.Count -gt 0)
            if ($lv.SelectedItems.Count -eq 0) { return }
            $f = $lv.SelectedItems[0].Tag
            $lines = @("$($f.Severity.ToUpperInvariant()): $($f.Title)", '', "Task:   $($f.FullName)", "Origin: $($f.Origin)")
            if ($f.Detail) { $lines += ''; $lines += $f.Detail }
            if ($f.Recommendation) { $lines += ''; $lines += "-> $($f.Recommendation)" }
            $txtDetail.Text = ($lines -join [Environment]::NewLine)
        })

    $lv.add_DoubleClick({
            if ($lv.SelectedItems.Count -eq 0) { return }
            $dlg.OpenTask = $lv.SelectedItems[0].Tag.FullName
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        })

    $chkPsOnly.add_CheckedChanged({ & $scan })
    $chkMs.add_CheckedChanged({ & $scan })

    $btnRescan = New-PSTSMUIButton -Text 'Re-scan' -Width 96
    $btnOpen = New-PSTSMUIButton -Text 'Open task' -Primary -Width 110
    # Nothing is selected when the window opens.
    $btnOpen.Enabled = $false
    $lv.AccessibleName = 'Health findings'
    $lv.AccessibleDescription = 'One row per problem found. Select a row to read the detail and recommendation below.'
    $btnClose = New-PSTSMUIButton -Text 'Close'
    $btnRescan.add_Click({ & $scan })
    $btnOpen.add_Click({
            if ($lv.SelectedItems.Count -eq 0) { return }
            $dlg.OpenTask = $lv.SelectedItems[0].Tag.FullName
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        })
    $btnClose.add_Click({ $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $form.Close() })

    $bar = New-PSTSMUIActionBar -LeftButton @($btnRescan) -RightButton @($btnClose, $btnOpen)

    $root.Controls.Add($lblSummary, 0, 0)
    $root.Controls.Add($opts, 0, 1)
    $root.Controls.Add($lv, 0, 2)
    $root.Controls.Add($txtDetail, 0, 3)
    $root.Controls.Add($bar, 0, 4)
    [void]$form.Controls.Add($root)
    $form.CancelButton = $btnClose

    & $scan

    if ($BuildOnly) { return $form }
    if ($SelfTest) {
        Show-PSTSMUIForTest -Form $form
        for ($i = 0; $i -lt 20; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 10 }
        if (-not $form.IsDisposed) { $form.Close(); $form.Dispose() }
        return $dlg.OpenTask
    }

    if ($Owner) { [void]$form.ShowDialog($Owner) } else { [void]$form.ShowDialog() }
    $form.Dispose()
    $dlg.OpenTask
}
