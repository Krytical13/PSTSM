function Show-PSTaskTriggerDialog {
    <#
    .SYNOPSIS
        Modal dialog for adding or editing a single task trigger.
    .DESCRIPTION
        Produces a New-PSTaskTriggerSpec object. Fields that do not apply to the selected
        trigger type are hidden rather than disabled, so the dialog never shows a weekly
        day-picker on a startup trigger.

        Validation is delegated to New-PSTaskTriggerSpec, so the dialog and the scripted API
        can never disagree about what is legal.
    .PARAMETER Trigger
        An existing spec to edit. Omit to create a new one.
    .PARAMETER Owner
        Parent form, for correct modal centring.
    .PARAMETER SelfTest
        Test seam. Builds the dialog, selects a daily 07:00 trigger, clicks OK through the real
        handler and returns the result without showing anything.
    .OUTPUTS
        [pscustomobject] the trigger spec, or $null if cancelled.
    .EXAMPLE
        $spec = Show-PSTaskTriggerDialog
    #>
    [CmdletBinding()]
    param(
        [object]$Trigger,
        [System.Windows.Forms.Form]$Owner,
        [switch]$SelfTest
    )

    Initialize-PSTaskUIHost
    $t = Get-PSTaskUITheme

    $form = New-PSTaskUIForm -Title $(if ($Trigger) { 'Edit trigger' } else { 'Add trigger' }) -Width 470 -Height 470
    # Sizable, not FixedDialog: a fixed dialog cannot be resized if the content still overflows
    # at an unusual scale or font size, which leaves the OK button unreachable.
    $form.FormBorderStyle = 'Sizable'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.MinimumSize = New-Object System.Drawing.Size(0, 0)

    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.Dock = 'Fill'
    $root.ColumnCount = 1
    $root.RowCount = 2
    $root.Padding = New-Object System.Windows.Forms.Padding(12, 12, 12, 6)
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))

    $scroll = New-Object System.Windows.Forms.Panel
    $scroll.Dock = 'Fill'
    $scroll.AutoScroll = $true

    $stack = New-Object System.Windows.Forms.TableLayoutPanel
    $stack.Dock = 'Top'
    $stack.AutoSize = $true
    $stack.AutoSizeMode = 'GrowAndShrink'
    $stack.ColumnCount = 1
    # No explicit Width - Dock='Top' tracks the scroll panel, which tracks the form.

    # --- controls -------------------------------------------------------------------
    $cboType = New-Object System.Windows.Forms.ComboBox
    $cboType.Dock = 'Fill'
    $cboType.DropDownStyle = 'DropDownList'
    foreach ($x in @('Daily', 'Weekly', 'Once', 'AtStartup', 'AtLogOn', 'OnIdle')) { [void]$cboType.Items.Add($x) }

    $dtDate = New-Object System.Windows.Forms.DateTimePicker
    $dtDate.Dock = 'Fill'
    $dtDate.Format = 'Short'

    $dtTime = New-Object System.Windows.Forms.DateTimePicker
    $dtTime.Dock = 'Fill'
    $dtTime.Format = 'Time'
    $dtTime.ShowUpDown = $true

    $dayPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $dayPanel.Dock = 'Fill'
    $dayPanel.AutoSize = $true
    $dayPanel.WrapContents = $true
    $dayPanel.Margin = New-Object System.Windows.Forms.Padding(3)
    $dayChecks = @{}
    foreach ($d in @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')) {
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = $d.Substring(0, 3)
        $cb.AutoSize = $true
        $cb.Tag = $d
        $cb.Margin = New-Object System.Windows.Forms.Padding(0, 3, 8, 3)
        $dayChecks[$d] = $cb
        [void]$dayPanel.Controls.Add($cb)
    }

    $numDays = New-Object System.Windows.Forms.NumericUpDown
    $numDays.Dock = 'Fill'; $numDays.Minimum = 1; $numDays.Maximum = 365; $numDays.Value = 1

    $numWeeks = New-Object System.Windows.Forms.NumericUpDown
    $numWeeks.Dock = 'Fill'; $numWeeks.Minimum = 1; $numWeeks.Maximum = 52; $numWeeks.Value = 1

    $txtUser = New-PSTaskUITextBox
    $txtDelay = New-PSTaskUITextBox
    $txtRandom = New-PSTaskUITextBox
    $txtRepInterval = New-PSTaskUITextBox
    $txtRepDuration = New-PSTaskUITextBox

    $chkEnabled = New-Object System.Windows.Forms.CheckBox
    $chkEnabled.Text = 'Trigger is enabled'
    $chkEnabled.AutoSize = $true
    $chkEnabled.Checked = $true

    # --- rows, kept as objects so visibility can be toggled by type -----------------
    $tbl = New-PSTaskUIFieldTable
    Add-PSTaskUIField -Table $tbl -Label 'Type' -Control $cboType
    Add-PSTaskUIField -Table $tbl -Label 'Start date' -Control $dtDate
    Add-PSTaskUIField -Table $tbl -Label 'At time' -Control $dtTime
    Add-PSTaskUIField -Table $tbl -Label 'Days' -Control $dayPanel
    Add-PSTaskUIField -Table $tbl -Label 'Every N days' -Control $numDays
    Add-PSTaskUIField -Table $tbl -Label 'Every N weeks' -Control $numWeeks
    Add-PSTaskUIField -Table $tbl -Label 'For user' -Control $txtUser
    Add-PSTaskUIField -Table $tbl -Label 'Delay' -Control $txtDelay
    Add-PSTaskUIField -Table $tbl -Label 'Random delay' -Control $txtRandom
    Add-PSTaskUIField -Table $tbl -Label 'Repeat every' -Control $txtRepInterval
    Add-PSTaskUIField -Table $tbl -Label 'Repeat for' -Control $txtRepDuration
    Add-PSTaskUIField -Table $tbl -Label '' -Control $chkEnabled

    $hint = New-PSTaskUILabel -Text "Durations are hh:mm:ss (or d.hh:mm:ss). Leave blank for none.`nA random delay spreads load when the same task runs on many machines." -ForeColor $t.Muted
    Add-PSTaskUIField -Table $tbl -Label '' -Control $hint

    Add-PSTaskUIStacked -Stack $stack -Control $tbl
    [void]$scroll.Controls.Add($stack)

    # --- type-driven visibility ------------------------------------------------------
    # Row visibility is driven by hiding the control AND its label, found by cell position.
    $setRowVisible = {
        param($control, $visible)
        $control.Visible = $visible
        $pos = $tbl.GetPositionFromControl($control)
        if ($pos.Column -eq 1) {
            $lbl = $tbl.GetControlFromPosition(0, $pos.Row)
            if ($lbl) { $lbl.Visible = $visible }
        }
    }

    $applyType = {
        $type = [string]$cboType.SelectedItem
        $isTime = ($type -eq 'Once' -or $type -eq 'Daily' -or $type -eq 'Weekly')
        & $setRowVisible $dtDate ($type -eq 'Once')
        & $setRowVisible $dtTime $isTime
        & $setRowVisible $dayPanel ($type -eq 'Weekly')
        & $setRowVisible $numDays ($type -eq 'Daily')
        & $setRowVisible $numWeeks ($type -eq 'Weekly')
        & $setRowVisible $txtUser ($type -eq 'AtLogOn')
        & $setRowVisible $txtDelay ($type -eq 'AtStartup' -or $type -eq 'AtLogOn')
        & $setRowVisible $txtRandom $isTime
        & $setRowVisible $txtRepInterval ($type -ne 'OnIdle')
        & $setRowVisible $txtRepDuration ($type -ne 'OnIdle')
    }

    # Plain scriptblock, no GetNewClosure: it must keep module affinity and see these locals.
    $cboType.add_SelectedIndexChanged({ & $applyType })

    # --- seed from an existing spec --------------------------------------------------
    if ($Trigger) {
        $cboType.SelectedItem = $Trigger.Type
        if ($Trigger.At) {
            try {
                $dt = [datetime]::Parse($Trigger.At, [System.Globalization.CultureInfo]::InvariantCulture)
                $dtDate.Value = $dt
                $dtTime.Value = $dt
            }
            catch { Write-Verbose "Could not parse trigger start '$($Trigger.At)'" }
        }
        foreach ($d in $Trigger.DaysOfWeek) { if ($dayChecks.ContainsKey($d)) { $dayChecks[$d].Checked = $true } }
        if ($Trigger.DaysInterval) { $numDays.Value = [Math]::Min(365, [Math]::Max(1, [int]$Trigger.DaysInterval)) }
        if ($Trigger.WeeksInterval) { $numWeeks.Value = [Math]::Min(52, [Math]::Max(1, [int]$Trigger.WeeksInterval)) }
        $txtUser.Text = [string]$Trigger.UserId
        $txtDelay.Text = [string]$Trigger.Delay
        $txtRandom.Text = [string]$Trigger.RandomDelay
        $txtRepInterval.Text = [string]$Trigger.RepetitionInterval
        $txtRepDuration.Text = [string]$Trigger.RepetitionDuration
        $chkEnabled.Checked = [bool]$Trigger.Enabled
    }
    else {
        $cboType.SelectedItem = 'Daily'
        $dtTime.Value = [datetime]::Today.AddHours(7)
    }
    & $applyType

    # --- actions ---------------------------------------------------------------------
    # A hashtable, not a plain [object]$result. Assigning a bare variable inside an event
    # handler creates it in the HANDLER's scope, leaving the outer variable untouched - so the
    # dialog returned $null no matter what was picked, and "Add trigger" silently did nothing.
    # Mutating a reference type reaches the caller's object correctly.
    $dlg = @{ Result = $null }

    $btnOk = New-PSTaskUIButton -Text 'OK' -Primary
    $btnCancel = New-PSTaskUIButton -Text 'Cancel'

    $btnOk.add_Click({
            $type = [string]$cboType.SelectedItem
            $p = @{ Type = $type; Enabled = $chkEnabled.Checked }

            if ($type -eq 'Once') {
                $p['At'] = [datetime]::new($dtDate.Value.Year, $dtDate.Value.Month, $dtDate.Value.Day,
                    $dtTime.Value.Hour, $dtTime.Value.Minute, 0)
            }
            elseif ($type -eq 'Daily' -or $type -eq 'Weekly') {
                $p['At'] = $dtTime.Value
            }

            if ($type -eq 'Weekly') {
                $picked = @()
                foreach ($k in $dayChecks.Keys) { if ($dayChecks[$k].Checked) { $picked += $k } }
                if ($picked.Count -gt 0) { $p['DaysOfWeek'] = $picked }
            }
            if ($type -eq 'Daily') { $p['DaysInterval'] = [int]$numDays.Value }
            if ($type -eq 'Weekly') { $p['WeeksInterval'] = [int]$numWeeks.Value }
            if ($type -eq 'AtLogOn' -and $txtUser.Text.Trim()) { $p['UserId'] = $txtUser.Text.Trim() }
            if ($txtDelay.Visible -and $txtDelay.Text.Trim()) { $p['Delay'] = $txtDelay.Text.Trim() }
            if ($txtRandom.Visible -and $txtRandom.Text.Trim()) { $p['RandomDelay'] = $txtRandom.Text.Trim() }
            if ($txtRepInterval.Visible -and $txtRepInterval.Text.Trim()) { $p['RepetitionInterval'] = $txtRepInterval.Text.Trim() }
            if ($txtRepDuration.Visible -and $txtRepDuration.Text.Trim()) { $p['RepetitionDuration'] = $txtRepDuration.Text.Trim() }

            try {
                $spec = New-PSTaskTriggerSpec @p
            }
            catch {
                [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Invalid trigger',
                    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                return
            }

            $dlg.Result = $spec
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        })

    $btnCancel.add_Click({
            $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
            $form.Close()
        })

    $bar = New-PSTaskUIActionBar -RightButton @($btnOk, $btnCancel)

    $root.Controls.Add($scroll, 0, 0)
    $root.Controls.Add($bar, 0, 1)
    [void]$form.Controls.Add($root)
    $form.AcceptButton = $btnOk
    $form.CancelButton = $btnCancel

    if ($SelfTest) {
        # Drives the real OK handler so the handler-to-caller result path is exercised rather
        # than assumed. The form has to be SHOWN first: PerformClick() goes through CanSelect,
        # which is false on a form that was never shown (Visible reads the effective value, and
        # nothing is effectively visible without a shown ancestor), so on a hidden form the
        # click is silently a no-op and this seam would prove nothing.
        $cboType.SelectedItem = 'Daily'
        $dtTime.Value = [datetime]::Today.AddHours(7)
        $form.WindowState = 'Minimized'
        $form.ShowInTaskbar = $false
        $form.Show()
        for ($i = 0; $i -lt 10; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 10 }

        $btnOk.PerformClick()
        [System.Windows.Forms.Application]::DoEvents()

        # The Click handler closes the form, which disposes a non-modal one.
        if (-not $form.IsDisposed) { $form.Close(); $form.Dispose() }
        return $dlg.Result
    }

    if ($Owner) { [void]$form.ShowDialog($Owner) } else { [void]$form.ShowDialog() }
    $form.Dispose()

    $dlg.Result
}
