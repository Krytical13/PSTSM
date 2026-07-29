function Show-PSTaskBuilder {
    <#
    .SYNOPSIS
        Main window: the list of scheduled tasks, with everything needed to create, inspect,
        run and edit the PowerShell ones.
    .DESCRIPTION
        Defaults to showing only tasks whose action runs powershell.exe or pwsh.exe, and
        excludes the built-in \Microsoft\ tree - both are toggles. Unlike the Task Scheduler
        console the grid shows the actual script each task runs, the engine, a readable
        schedule, and a decoded Last Run Result, so a broken task is visible without opening
        anything.

        New and Edit both open Show-PSTaskEditor. Editing round-trips the registered task back
        into a plan first, so a task created here can be reopened exactly as it was saved.
    .PARAMETER TaskPath
        Restrict the initial listing to one Task Scheduler folder.
    .PARAMETER ScriptPath
        Open straight into the editor for this script, skipping the list.
    .PARAMETER BuildOnly
        Test seam. Returns the built Form without showing it, so the offline harness can force
        layout and assert control bounds. LAYOUT INSPECTION ONLY - the handlers close over this
        function's locals, which are gone once it returns, so do not Show() the returned form.
    .PARAMETER SelfTest
        Test seam. Shows the window minimised, pumps the message loop, then closes it - inside
        this function, so handlers still resolve. Catches show-time failures that a headless
        build cannot.
    .OUTPUTS
        None, or [System.Windows.Forms.Form] when -BuildOnly is used.
    .EXAMPLE
        Show-PSTaskBuilder
    .EXAMPLE
        Show-PSTaskBuilder -ScriptPath 'D:\Scripts\Send-Report.ps1'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'TaskPath',
        Justification = 'Used inside the $reload scriptblock, which the analyzer does not follow.')]
    [CmdletBinding()]
    param(
        [string]$TaskPath,
        [string]$ScriptPath,
        [switch]$BuildOnly,
        [switch]$SelfTest
    )

    Initialize-PSTaskUIHost
    $t = Get-PSTaskUITheme

    if ($ScriptPath -and -not $BuildOnly -and -not $SelfTest) {
        [void](Show-PSTaskEditor -ScriptPath $ScriptPath)
        return
    }

    $state = @{ Rows = @() }

    $form = New-PSTaskUIForm -Title 'PSTaskBuilder' -Width 1220 -Height 700

    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.Dock = 'Fill'
    $root.ColumnCount = 1
    $root.RowCount = 4
    $root.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 4)
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))

    # --- toolbar ---------------------------------------------------------------------
    $btnNew = New-PSTaskUIButton -Text 'New task' -Primary -Width 100
    $btnEdit = New-PSTaskUIButton -Text 'Edit'
    $btnRun = New-PSTaskUIButton -Text 'Run now'
    $btnToggle = New-PSTaskUIButton -Text 'Disable'
    $btnDelete = New-PSTaskUIButton -Text 'Delete' -Danger
    $btnExport = New-PSTaskUIButton -Text 'Export plan' -Width 110
    $btnConsole = New-PSTaskUIButton -Text 'Task Scheduler' -Width 130
    $btnRefresh = New-PSTaskUIButton -Text 'Refresh'

    $toolbar = New-Object System.Windows.Forms.FlowLayoutPanel
    $toolbar.Dock = 'Top'
    $toolbar.AutoSize = $true
    $toolbar.WrapContents = $true
    $toolbar.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
    foreach ($b in @($btnNew, $btnEdit, $btnRun, $btnToggle, $btnDelete, $btnExport, $btnConsole, $btnRefresh)) {
        [void]$toolbar.Controls.Add($b)
    }

    # --- filter row ------------------------------------------------------------------
    $filterRow = New-Object System.Windows.Forms.FlowLayoutPanel
    $filterRow.Dock = 'Top'
    $filterRow.AutoSize = $true
    $filterRow.WrapContents = $false
    $filterRow.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)

    $lblFind = New-PSTaskUILabel -Text 'Filter'
    $lblFind.Margin = New-Object System.Windows.Forms.Padding(3, 9, 6, 3)
    $txtFilter = New-Object System.Windows.Forms.TextBox
    $txtFilter.Width = [int](240 * (Get-PSTaskUIScale))
    $txtFilter.BorderStyle = 'FixedSingle'
    $txtFilter.Margin = New-Object System.Windows.Forms.Padding(3, 6, 12, 3)

    $chkPsOnly = New-Object System.Windows.Forms.CheckBox
    $chkPsOnly.Text = 'PowerShell tasks only'
    $chkPsOnly.AutoSize = $true
    $chkPsOnly.Checked = $true
    $chkPsOnly.Margin = New-Object System.Windows.Forms.Padding(3, 8, 16, 3)

    $chkMicrosoft = New-Object System.Windows.Forms.CheckBox
    $chkMicrosoft.Text = 'Include built-in Microsoft tasks'
    $chkMicrosoft.AutoSize = $true
    $chkMicrosoft.Margin = New-Object System.Windows.Forms.Padding(3, 8, 3, 3)

    foreach ($c in @($lblFind, $txtFilter, $chkPsOnly, $chkMicrosoft)) { [void]$filterRow.Controls.Add($c) }

    # --- grid -------------------------------------------------------------------------
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = 'Fill'
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.SelectionMode = 'FullRowSelect'
    $grid.MultiSelect = $false
    $grid.AutoGenerateColumns = $false
    $grid.RowHeadersVisible = $false
    $grid.BackgroundColor = $t.Surface
    $grid.BorderStyle = 'FixedSingle'
    $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersDefaultCellStyle.BackColor = $t.SurfaceAlt
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $t.Text
    $grid.ColumnHeadersDefaultCellStyle.Font = $t.FontBold
    $grid.AlternatingRowsDefaultCellStyle.BackColor = $t.SurfaceAlt

    # Row and header heights do not follow the font, so at 125%/150% scaling the default 22px
    # row clips the text it contains. Derive them from the font actually in use.
    $grid.RowTemplate.Height = [int]($t.FontBase.Height * 1.6)
    $grid.ColumnHeadersHeightSizeMode = [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::AutoSize

    $addColumn = {
        param($name, $header, $width, $fill)
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.Name = $name
        $col.HeaderText = $header
        if ($fill) {
            $col.AutoSizeMode = 'Fill'
            $col.FillWeight = $width
        }
        else {
            $col.Width = $width
        }
        [void]$grid.Columns.Add($col)
    }

    # Fill weights, not pixels. 'State' gets more than its text suggests because 'Disabled' and
    # 'Running' are the values that matter and they truncate first; 'Folder' is usually '\'.
    & $addColumn 'TaskName' 'Name' 130 $true
    & $addColumn 'TaskPath' 'Folder' 65 $true
    & $addColumn 'State' 'State' 80 $true
    & $addColumn 'ScriptName' 'Script' 130 $true
    & $addColumn 'EngineId' 'Engine' 60 $true
    & $addColumn 'TriggerSummary' 'Schedule' 140 $true
    & $addColumn 'LastRunTime' 'Last run' 100 $true
    & $addColumn 'LastResultText' 'Result' 130 $true
    & $addColumn 'NextRunTime' 'Next run' 100 $true
    & $addColumn 'UserId' 'Run as' 90 $true

    # --- status ------------------------------------------------------------------------
    $lblStatus = New-PSTaskUILabel -Text '' -ForeColor $t.Muted
    $lblStatus.Dock = 'Fill'
    $lblStatus.Margin = New-Object System.Windows.Forms.Padding(3, 6, 3, 3)

    # =================================================================================
    # Behaviour
    # =================================================================================
    $getSelected = {
        if ($grid.SelectedRows.Count -eq 0) { return $null }
        $grid.SelectedRows[0].Tag
    }

    $reload = {
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $p = @{}
            if ($TaskPath) { $p['TaskPath'] = $TaskPath }
            if ($chkPsOnly.Checked) { $p['PowerShellOnly'] = $true }
            if ($chkMicrosoft.Checked) { $p['IncludeMicrosoft'] = $true }
            $state.Rows = @(Get-PSTaskInventory @p -ErrorAction SilentlyContinue)
        }
        catch {
            $state.Rows = @()
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Could not read scheduled tasks',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
        finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
        & $applyFilter
    }

    $applyFilter = {
        $needle = $txtFilter.Text.Trim()
        $rows = $state.Rows
        if ($needle) {
            $rows = @($rows | Where-Object {
                    ("$($_.TaskName) $($_.TaskPath) $($_.ScriptName) $($_.ScriptPath) $($_.UserId) $($_.Description)") -like "*$needle*"
                })
        }

        $grid.SuspendLayout()
        $grid.Rows.Clear()
        foreach ($r in $rows) {
            $lastRun = ''
            if ($r.LastRunTime -and $r.LastRunTime.Year -gt 1900) { $lastRun = $r.LastRunTime.ToString('yyyy-MM-dd HH:mm') }
            $nextRun = ''
            if ($r.NextRunTime -and $r.NextRunTime.Year -gt 1900) { $nextRun = $r.NextRunTime.ToString('yyyy-MM-dd HH:mm') }

            $result = [string]$r.LastResultText
            if ($result.Length -gt 60) { $result = $result.Substring(0, 57) + '...' }

            $i = $grid.Rows.Add(
                $r.TaskName,
                $r.TaskPath,
                $r.State,
                $(if ($r.ScriptName) { $r.ScriptName } else { '-' }),
                $(if ($r.EngineId) { $r.EngineId } else { '-' }),
                $r.TriggerSummary,
                $lastRun,
                $result,
                $nextRun,
                $r.UserId
            )
            $row = $grid.Rows[$i]
            $row.Tag = $r

            if ($r.State -eq 'Disabled') { $row.DefaultCellStyle.ForeColor = $t.Muted }
            if ($r.IsPowerShell -and -not $r.IsRecognized) { $row.Cells['ScriptName'].Style.ForeColor = $t.Warn }
            if ($r.ScriptExists -eq $false) {
                $row.Cells['ScriptName'].Style.ForeColor = $t.Danger
                $row.Cells['ScriptName'].ToolTipText = 'The script this task points at no longer exists.'
            }
        }
        $grid.ResumeLayout()

        $lblStatus.Text = "$($grid.Rows.Count) task(s) shown of $($state.Rows.Count) loaded."
        & $syncButtons
    }

    $syncButtons = {
        $sel = & $getSelected
        $has = [bool]$sel
        $btnEdit.Enabled = $has
        $btnRun.Enabled = $has
        $btnToggle.Enabled = $has
        $btnDelete.Enabled = $has
        $btnExport.Enabled = $has -and $sel.IsPowerShell
        if ($has) {
            if ($sel.State -eq 'Disabled') { $btnToggle.Text = 'Enable' } else { $btnToggle.Text = 'Disable' }
            $detail = "$($sel.TaskPath)$($sel.TaskName)"
            if ($sel.ScriptPath) { $detail += "   ->   $($sel.ScriptPath)" }
            if ($sel.IsPowerShell -and -not $sel.IsRecognized) { $detail += '   [action not modelled by this tool]' }
            $lblStatus.Text = $detail
        }
    }

    $openEditor = {
        param($summary)
        $plan = $null
        try {
            $plan = ConvertFrom-PSTaskDefinition -TaskName $summary.TaskName -TaskPath $summary.TaskPath
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Could not read the task',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            return
        }
        $saved = Show-PSTaskEditor -Plan $plan -Owner $form
        if ($saved) { & $reload }
    }

    # --- wiring ---------------------------------------------------------------------
    $btnNew.add_Click({
            $saved = Show-PSTaskEditor -Owner $form
            if ($saved) { & $reload }
        })

    $btnEdit.add_Click({
            $sel = & $getSelected
            if ($sel) { & $openEditor $sel }
        })

    $grid.add_CellDoubleClick({
            $sel = & $getSelected
            if ($sel) { & $openEditor $sel }
        })

    # Guarded like add_Shown: SelectionChanged also fires without user action - adding rows
    # programmatically raises it - so it can run on a form shown outside this function, where
    # $syncButtons no longer resolves.
    $grid.add_SelectionChanged({ if ($syncButtons) { & $syncButtons } })

    $btnRun.add_Click({
            $sel = & $getSelected
            if (-not $sel) { return }
            try {
                Start-ScheduledTask -TaskName $sel.TaskName -TaskPath $sel.TaskPath -ErrorAction Stop
                $lblStatus.Text = "Started $($sel.TaskName). Refresh to see the result."
            }
            catch {
                [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Could not start the task',
                    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            }
        })

    $btnToggle.add_Click({
            $sel = & $getSelected
            if (-not $sel) { return }
            try {
                if ($sel.State -eq 'Disabled') {
                    Disable-ScheduledTask -TaskName $sel.TaskName -TaskPath $sel.TaskPath -ErrorAction Stop | Out-Null
                    Enable-ScheduledTask -TaskName $sel.TaskName -TaskPath $sel.TaskPath -ErrorAction Stop | Out-Null
                }
                else {
                    Disable-ScheduledTask -TaskName $sel.TaskName -TaskPath $sel.TaskPath -ErrorAction Stop | Out-Null
                }
                & $reload
            }
            catch {
                [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Could not change the task state',
                    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            }
        })

    $btnDelete.add_Click({
            $sel = & $getSelected
            if (-not $sel) { return }
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "Delete '$($sel.TaskPath)$($sel.TaskName)'?`n`nThis removes the scheduled task. The script itself is not touched.",
                'Confirm delete',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning,
                [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            try {
                Unregister-ScheduledTask -TaskName $sel.TaskName -TaskPath $sel.TaskPath -Confirm:$false -ErrorAction Stop
                & $reload
            }
            catch {
                [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Could not delete the task',
                    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            }
        })

    $btnExport.add_Click({
            $sel = & $getSelected
            if (-not $sel) { return }
            try {
                $plan = ConvertFrom-PSTaskDefinition -TaskName $sel.TaskName -TaskPath $sel.TaskPath
            }
            catch {
                [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Could not read the task',
                    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                return
            }
            $dlg = New-Object System.Windows.Forms.SaveFileDialog
            $dlg.Filter = 'Task plan (*.json)|*.json'
            $dlg.FileName = "$($sel.TaskName).task.json"
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                try { Export-PSTaskPlan -Plan $plan -Path $dlg.FileName; $lblStatus.Text = "Exported to $($dlg.FileName)" }
                catch {
                    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Export failed',
                        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                }
            }
            $dlg.Dispose()
        })

    $btnConsole.add_Click({ Start-Process 'taskschd.msc' })
    $btnRefresh.add_Click({ & $reload })
    $txtFilter.add_TextChanged({ & $applyFilter })
    $chkPsOnly.add_CheckedChanged({ & $reload })
    $chkMicrosoft.add_CheckedChanged({ & $reload })

    $root.Controls.Add($toolbar, 0, 0)
    $root.Controls.Add($filterRow, 0, 1)
    $root.Controls.Add($grid, 0, 2)
    $root.Controls.Add($lblStatus, 0, 3)
    [void]$form.Controls.Add($root)

    # Guarded on purpose. This is the only handler that fires without user interaction, so it
    # is the one that runs even on a form shown outside this function (a -BuildOnly form handed
    # to a harness, say). In that case the stack frame is gone and $reload resolves to nothing;
    # invoking it would throw straight into the global thread-exception handler and pop a
    # message box at whoever happens to be at the keyboard.
    $form.add_Shown({ if ($reload) { & $reload } })

    if ($BuildOnly) { return $form }

    if ($SelfTest) {
        $form.WindowState = 'Minimized'
        $form.ShowInTaskbar = $false
        $form.Show()
        for ($i = 0; $i -lt 60; $i++) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 15
        }
        $form.Close()
        $form.Dispose()
        return
    }

    [void]$form.ShowDialog()
    $form.Dispose()
}
