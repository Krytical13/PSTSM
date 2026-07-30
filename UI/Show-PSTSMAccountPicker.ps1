# SPDX-License-Identifier: GPL-3.0-or-later
function Show-PSTSMAccountPicker {
    <#
    .SYNOPSIS
        Picks the account a task runs as - an existing gMSA, an existing user/service account,
        or a built-in principal - and returns the logon type that account needs.
    .DESCRIPTION
        Choosing the account and choosing the logon type are one decision, and getting them out
        of step is what produces a task that will not register. The picker returns both together
        so the editor can set them as a pair.

        Selecting something existing is the normal case; creating a gMSA is available from here
        too, but it is a side door rather than the main path.
    .PARAMETER InitialType
        Which tab of accounts to show first. Default All.
    .PARAMETER Owner
        Parent form for modal centring.
    .PARAMETER SelfTest
        Test seam. Builds the dialog, loads the list, and closes without selecting.
    .OUTPUTS
        [pscustomobject] Name, SuggestedLogonType - or $null if cancelled.
    .EXAMPLE
        $picked = Show-PSTSMAccountPicker
        if ($picked) { $account = $picked.Name; $logon = $picked.SuggestedLogonType }
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('All', 'gMSA', 'User', 'BuiltIn')]
        [string]$InitialType = 'All',

        [System.Windows.Forms.Form]$Owner,
        [switch]$SelfTest,
        [switch]$BuildOnly
    )

    Initialize-PSTSMUIHost
    $t = Get-PSTSMUITheme

    $dlg = @{ Picked = $null; Rows = @() }

    $form = New-PSTSMUIForm -Title 'Select the account to run as' -Width 820 -Height 600
    $form.MinimumSize = New-Object System.Drawing.Size(0, 0)

    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.Dock = 'Fill'; $root.ColumnCount = 1; $root.RowCount = 4
    $root.Padding = New-Object System.Windows.Forms.Padding(12, 12, 12, 6)
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))

    # --- filter row -------------------------------------------------------------------------
    $filterRow = New-Object System.Windows.Forms.FlowLayoutPanel
    $filterRow.Dock = 'Top'; $filterRow.AutoSize = $true; $filterRow.WrapContents = $true
    $filterRow.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)

    $lblShow = New-PSTSMUILabel -Text 'Show'
    $lblShow.Margin = New-Object System.Windows.Forms.Padding(3, 9, 6, 3)
    $cboType = New-Object System.Windows.Forms.ComboBox
    $cboType.DropDownStyle = 'DropDownList'
    $cboType.Width = [int](210 * (Get-PSTSMUIScale))
    $cboType.Margin = New-Object System.Windows.Forms.Padding(3, 6, 16, 3)
    $typeMap = [ordered]@{
        'All'     = 'Everything'
        'gMSA'    = 'Managed service accounts (gMSA)'
        'User'    = 'User / service accounts'
        'BuiltIn' = 'Built-in (SYSTEM, LOCAL/NETWORK SERVICE)'
    }
    foreach ($k in $typeMap.Keys) { [void]$cboType.Items.Add($typeMap[$k]) }

    $lblFind = New-PSTSMUILabel -Text 'Name contains'
    $lblFind.Margin = New-Object System.Windows.Forms.Padding(3, 9, 6, 3)
    $txtFind = New-Object System.Windows.Forms.TextBox
    $txtFind.Width = [int](200 * (Get-PSTSMUIScale))
    $txtFind.BorderStyle = 'FixedSingle'
    $txtFind.Margin = New-Object System.Windows.Forms.Padding(3, 6, 8, 3)
    $btnFind = New-PSTSMUIButton -Text 'Search' -Width 90

    foreach ($c in @($lblShow, $cboType, $lblFind, $txtFind, $btnFind)) { [void]$filterRow.Controls.Add($c) }

    # --- list ---------------------------------------------------------------------------------
    $lv = New-Object System.Windows.Forms.ListView
    $lv.Dock = 'Fill'; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $false
    $lv.HideSelection = $false; $lv.BorderStyle = 'FixedSingle'
    [void]$lv.Columns.Add('Account', 10)
    [void]$lv.Columns.Add('Type', 10)
    [void]$lv.Columns.Add('Description', 10)

    $lblDetail = New-PSTSMUILabel -Text '' -ForeColor $t.Muted
    $lblDetail.Dock = 'Top'
    $lblDetail.MaximumSize = New-Object System.Drawing.Size(760, 0)
    $lblDetail.Margin = New-Object System.Windows.Forms.Padding(3, 8, 3, 4)

    # --- behaviour ------------------------------------------------------------------------------
    $sizeColumns = {
        $scale = Get-PSTSMUIScale
        $lv.Columns[0].Width = [int](230 * $scale)
        $lv.Columns[1].Width = [int](90 * $scale)
        $rest = $lv.ClientSize.Width - $lv.Columns[0].Width - $lv.Columns[1].Width -
        [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth - 2
        if ($rest -gt 60) { $lv.Columns[2].Width = $rest }
    }
    $lv.add_Resize({ if ($sizeColumns) { & $sizeColumns } })

    $reload = {
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $keys = @($typeMap.Keys)
            $type = if ($cboType.SelectedIndex -ge 0) { $keys[$cboType.SelectedIndex] } else { 'All' }
            $p = @{ Type = $type }
            if ($txtFind.Text.Trim()) { $p['Filter'] = $txtFind.Text.Trim() }
            try { $dlg.Rows = @(Get-PSTSMRunAsAccount @p) }
            catch { $dlg.Rows = @(); Write-Verbose $_.Exception.Message }

            $lv.BeginUpdate()
            $lv.Items.Clear()
            foreach ($r in $dlg.Rows) {
                $item = New-Object System.Windows.Forms.ListViewItem($r.Name)
                [void]$item.SubItems.Add($r.Type)
                [void]$item.SubItems.Add([string]$r.Description)
                if ($r.Enabled -eq $false) { $item.ForeColor = $t.Danger }
                elseif ($r.Type -eq 'gMSA') { $item.ForeColor = $t.Good }
                $item.Tag = $r
                [void]$lv.Items.Add($item)
            }
            $lv.EndUpdate()
            & $sizeColumns

            $lblDetail.Text = if ($dlg.Rows.Count -eq 0) {
                'Nothing found. Without a reachable domain controller only the built-in principals are listed.'
            }
            else { "$($dlg.Rows.Count) account(s). Select one to see what it means for this task." }
        }
        finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
    }

    $lv.add_SelectedIndexChanged({
            if ($lv.SelectedItems.Count -eq 0) { $btnSelect.Enabled = $false; return }
            $r = $lv.SelectedItems[0].Tag
            $btnSelect.Enabled = ($r.Enabled -ne $false)
            $bits = @("Logon type: $($r.SuggestedLogonType)")
            if ($r.Detail) { $bits += $r.Detail }
            if ($r.Enabled -eq $false) { $bits += 'This account is disabled and cannot run a task.' }
            $lblDetail.Text = $bits -join '   |   '
        })

    $cboType.add_SelectedIndexChanged({ & $reload })
    $btnFind.add_Click({ & $reload })
    $txtFind.add_KeyDown({ if ($args[1].KeyCode -eq [System.Windows.Forms.Keys]::Enter) { $args[1].SuppressKeyPress = $true; & $reload } })

    # --- actions ------------------------------------------------------------------------------
    $btnNewGmsa = New-PSTSMUIButton -Text 'Create a gMSA...' -Width 140
    $btnSelect = New-PSTSMUIButton -Text 'Select' -Primary -Width 100
    $btnCancel = New-PSTSMUIButton -Text 'Cancel'
    $btnSelect.Enabled = $false

    $btnNewGmsa.add_Click({
            $created = Show-PSTSMGmsaDialog -Owner $form
            if ($created) {
                $dlg.Picked = [PSCustomObject]@{ Name = $created; SuggestedLogonType = 'gMSA' }
                $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
                $form.Close()
            }
        })

    $btnSelect.add_Click({
            if ($lv.SelectedItems.Count -eq 0) { return }
            $r = $lv.SelectedItems[0].Tag
            $dlg.Picked = [PSCustomObject]@{ Name = $r.Name; SuggestedLogonType = $r.SuggestedLogonType }
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        })

    $lv.add_DoubleClick({ if ($btnSelect.Enabled) { $btnSelect.PerformClick() } })

    $btnCancel.add_Click({
            $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
            $form.Close()
        })

    $bar = New-PSTSMUIActionBar -LeftButton @($btnNewGmsa) -RightButton @($btnCancel, $btnSelect)

    $root.Controls.Add($filterRow, 0, 0)
    $root.Controls.Add($lv, 0, 1)
    $root.Controls.Add($lblDetail, 0, 2)
    $root.Controls.Add($bar, 0, 3)
    [void]$form.Controls.Add($root)
    $form.CancelButton = $btnCancel

    $cboType.SelectedIndex = [array]::IndexOf(@($typeMap.Keys), $InitialType)
    if ($cboType.SelectedIndex -lt 0) { $cboType.SelectedIndex = 0 }
    & $reload

    if ($BuildOnly) { return $form }

    if ($SelfTest) {
        Show-PSTSMUIForTest -Form $form
        for ($i = 0; $i -lt 20; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 10 }
        if (-not $form.IsDisposed) { $form.Close(); $form.Dispose() }
        return $dlg.Picked
    }

    if ($Owner) { [void]$form.ShowDialog($Owner) } else { [void]$form.ShowDialog() }
    $form.Dispose()
    $dlg.Picked
}
