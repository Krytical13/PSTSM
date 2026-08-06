# SPDX-License-Identifier: GPL-3.0-or-later
function Show-PSTSM {
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

        New and Edit both open Show-PSTSMEditor. Editing round-trips the registered task back
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
        Test seam. Realises the window off-screen without activating it, pumps the message loop,
        then closes it - inside this function, so handlers still resolve. Catches show-time
        failures a headless build cannot. It does not take focus: a suite that steals the desktop
        once per dialog is not one anybody will run twice.
    .OUTPUTS
        None, or [System.Windows.Forms.Form] when -BuildOnly is used.
    .EXAMPLE
        Show-PSTSM
    .EXAMPLE
        Show-PSTSM -ScriptPath 'D:\Scripts\Send-Report.ps1'
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

    Initialize-PSTSMUIHost
    $t = Get-PSTSMUITheme

    if ($ScriptPath -and -not $BuildOnly -and -not $SelfTest) {
        [void](Show-PSTSMEditor -ScriptPath $ScriptPath)
        return
    }

    $state = @{ Rows = @() }

    $form = New-PSTSMUIForm -Title 'PSTSM - PowerShell Task Scheduler Manager' -Width 1220 -Height 700

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
    $btnNew = New-PSTSMUIButton -Text 'New task' -Primary -Width 100
    $btnEdit = New-PSTSMUIButton -Text 'Edit'
    $btnHealth = New-PSTSMUIButton -Text 'Health' -Width 90
    $btnLog = New-PSTSMUIButton -Text 'Last run' -Width 96
    $btnRun = New-PSTSMUIButton -Text 'Run now'
    $btnToggle = New-PSTSMUIButton -Text 'Disable'
    $btnDelete = New-PSTSMUIButton -Text 'Delete' -Danger
    $btnExport = New-PSTSMUIButton -Text 'Export plan' -Width 110
    $btnConsole = New-PSTSMUIButton -Text 'Task Scheduler' -Width 130
    $btnRefresh = New-PSTSMUIButton -Text 'Refresh'

    # Elevation is a property of what a task DOES, not of opening this window, so the tool runs
    # unelevated like Task Scheduler does. Saving a privileged task elevates for that one
    # registration, so this is no longer the route to getting work done - it is here for the
    # operator doing a run of privileged work who would rather not answer a prompt each time.
    # Hence out of the toolbar and into the footer.
    $isElevated = (Test-PSTSMElevated)
    $btnElevate = New-PSTSMUIButton -Text 'Restart as admin' -Width 140

    $toolbar = New-Object System.Windows.Forms.FlowLayoutPanel
    $toolbar.Dock = 'Top'
    $toolbar.AutoSize = $true
    $toolbar.WrapContents = $true
    $toolbar.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
    $toolbarButtons = @($btnNew, $btnEdit, $btnRun, $btnLog, $btnHealth, $btnToggle, $btnDelete, $btnExport, $btnConsole, $btnRefresh)
    foreach ($b in $toolbarButtons) { [void]$toolbar.Controls.Add($b) }

    # --- filter row ------------------------------------------------------------------
    $filterRow = New-Object System.Windows.Forms.FlowLayoutPanel
    $filterRow.Dock = 'Top'
    $filterRow.AutoSize = $true
    $filterRow.WrapContents = $false
    $filterRow.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)

    $lblFind = New-PSTSMUILabel -Text 'Filter'
    $lblFind.Margin = New-Object System.Windows.Forms.Padding(3, 9, 6, 3)
    $txtFilter = New-Object System.Windows.Forms.TextBox
    $txtFilter.Width = [int](240 * (Get-PSTSMUIScale))
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
    # Without this a screen reader announces the control type, not what it holds.
    $grid.AccessibleName = 'Scheduled tasks'
    $grid.AccessibleDescription = 'One row per scheduled task. Columns include the script it runs, its schedule, and the decoded result of its last run.'
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
    # Paired. Setting only the alternating BACKground left normal rows drawing a themed foreground
    # over the system window colour - about 1.02:1 under High Contrast Black, so every other row
    # was blank while the alternating ones read fine.
    $grid.DefaultCellStyle.BackColor = $t.Surface
    $grid.DefaultCellStyle.ForeColor = $t.Text
    $grid.AlternatingRowsDefaultCellStyle.BackColor = $t.SurfaceAlt
    $grid.AlternatingRowsDefaultCellStyle.ForeColor = $t.Text

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
    & $addColumn 'Origin' 'Origin' 62 $true
    & $addColumn 'TaskPath' 'Folder' 60 $true
    & $addColumn 'State' 'State' 78 $true
    & $addColumn 'ScriptName' 'Script' 130 $true
    & $addColumn 'EngineId' 'Engine' 60 $true
    & $addColumn 'TriggerSummary' 'Schedule' 140 $true
    & $addColumn 'LastRunTime' 'Last run' 100 $true
    & $addColumn 'LastResultText' 'Result' 130 $true
    & $addColumn 'NextRunTime' 'Next run' 100 $true
    & $addColumn 'UserId' 'Run as' 90 $true

    # --- status ------------------------------------------------------------------------
    # The status line and the session-elevation offer share the footer row: the offer is a quiet
    # aside, not a call to action, because saving a privileged task no longer depends on it.
    $footer = New-Object System.Windows.Forms.TableLayoutPanel
    $footer.Dock = 'Fill'
    $footer.AutoSize = $true
    $footer.ColumnCount = 2
    $footer.RowCount = 1
    [void]$footer.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$footer.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))

    $lblStatus = New-PSTSMUILabel -Text '' -ForeColor $t.Muted
    $lblStatus.Dock = 'Fill'
    $lblStatus.Margin = New-Object System.Windows.Forms.Padding(3, 6, 3, 3)
    $footer.Controls.Add($lblStatus, 0, 0)
    # Omitted entirely rather than added-then-hidden. A hidden control is still measured by the
    # layout, and Control.Visible reads false for everything on a form that has never been
    # shown - so "hidden" is not something the offline layout checks can even see.
    if (-not $isElevated) { $footer.Controls.Add($btnElevate, 1, 0) }

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
            # Always load the SUPERSET, then narrow in $applyFilter.
            #
            # Both checkboxes used to re-query Task Scheduler, which meant ticking one cost a full
            # re-enumeration - about two seconds - to compute something already present on every
            # row: IsPowerShell, and whether TaskPath is under \Microsoft\. Loading everything
            # costs nothing extra, because the enumeration walks all folders either way and the
            # per-row work that follows is what the flags would have skipped, not the read itself.
            # -TaskPath stays server-side: that one genuinely narrows what gets enumerated.
            $p = @{ IncludeMicrosoft = $true }
            if ($TaskPath) { $p['TaskPath'] = $TaskPath }
            $state.Rows = @(Get-PSTSMInventory @p -ErrorAction SilentlyContinue)
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

        # The two checkbox predicates, applied to the loaded superset. Both read fields that are
        # already on the row, so toggling either is instant instead of a re-query.
        if ($chkPsOnly.Checked) { $rows = @($rows | Where-Object { $_.IsPowerShell }) }
        if (-not $chkMicrosoft.Checked) { $rows = @($rows | Where-Object { $_.TaskPath -notlike '\Microsoft\*' }) }

        if ($needle) {
            # Origin is searchable too, so "person" or "pstsm" narrows the list to what somebody
            # here actually created - the usual reason for opening this window.
            $rows = @($rows | Where-Object {
                    ("$($_.TaskName) $($_.TaskPath) $($_.ScriptName) $($_.ScriptPath) $($_.UserId) $($_.Description) $($_.Origin) $($_.Author)") -like "*$needle*"
                })
        }

        $grid.SuspendLayout()
        $grid.Rows.Clear()
        foreach ($r in $rows) {
            $lastRun = ''
            if ($r.LastRunTime -and $r.LastRunTime.Year -gt 1900) { $lastRun = $r.LastRunTime.ToString('yyyy-MM-dd HH:mm', [cultureinfo]::InvariantCulture) }
            $nextRun = ''
            if ($r.NextRunTime -and $r.NextRunTime.Year -gt 1900) { $nextRun = $r.NextRunTime.ToString('yyyy-MM-dd HH:mm', [cultureinfo]::InvariantCulture) }

            $result = [string]$r.LastResultText
            if ($result.Length -gt 60) { $result = $result.Substring(0, 57) + '...' }

            $i = $grid.Rows.Add(
                $r.TaskName,
                $r.Origin,
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

            # Origin is carried by the word itself; colour only reinforces it, so the column
            # still reads correctly in greyscale or for a colour-blind operator.
            $row.Cells['Origin'].ToolTipText = [string]$r.OriginDetail
            switch ($r.Origin) {
                'PSTSM' { $row.Cells['Origin'].Style.ForeColor = $t.Accent }
                'Person' { $row.Cells['Origin'].Style.ForeColor = $t.Good }
                'Windows' { $row.Cells['Origin'].Style.ForeColor = $t.Muted }
                'Unknown' { $row.Cells['Origin'].Style.ForeColor = $t.Warn }
            }

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
        $btnLog.Enabled = $has
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
            $plan = ConvertFrom-PSTSMDefinition -TaskName $summary.TaskName -TaskPath $summary.TaskPath
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Could not read the task',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            return
        }
        $saved = Show-PSTSMEditor -Plan $plan -Owner $form
        if ($saved) { & $reload }
    }

    # --- wiring ---------------------------------------------------------------------
    $btnNew.add_Click({
            $saved = Show-PSTSMEditor -Owner $form
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
                $plan = ConvertFrom-PSTSMDefinition -TaskName $sel.TaskName -TaskPath $sel.TaskPath
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
                try { Export-PSTSMPlan -Plan $plan -Path $dlg.FileName; $lblStatus.Text = "Exported to $($dlg.FileName)" }
                catch {
                    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Export failed',
                        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                }
            }
            $dlg.Dispose()
        })

    $btnLog.add_Click({
            $sel = & $getSelected
            if (-not $sel) { return }
            Show-PSTSMRunLog -TaskName $sel.TaskName -TaskPath $sel.TaskPath -Owner $form
        })

    $btnHealth.add_Click({
            # Health is machine-wide, so it needs no selection. If the operator picks a task to
            # fix, drop them straight into the editor for it.
            $open = Show-PSTSMHealth -Owner $form
            if (-not $open) { return }
            $leaf = Split-Path $open -Leaf
            $folder = Split-Path $open -Parent
            if (-not $folder.EndsWith('\')) { $folder += '\' }
            $summary = @($state.Rows | Where-Object { $_.FullName -eq $open })[0]
            if ($summary) { & $openEditor $summary }
            else {
                try { & $openEditor (Get-PSTSMInventory -TaskPath $folder -TaskName $leaf | Select-Object -First 1) }
                catch {
                    [System.Windows.Forms.MessageBox]::Show("Could not open $open : $($_.Exception.Message)", 'PSTSM',
                        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                }
            }
        })

    $btnElevate.add_Click({
            $launcher = Join-Path (Split-Path $PSScriptRoot -Parent) 'Start-PSTSM.ps1'
            if (-not (Test-Path -LiteralPath $launcher)) {
                [System.Windows.Forms.MessageBox]::Show("Could not find $launcher", 'PSTSM',
                    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                return
            }
            try {
                $hostExe = (Get-Process -Id $PID).Path
                Start-Process -FilePath $hostExe -Verb RunAs -ErrorAction Stop `
                    -ArgumentList ('-STA -NoProfile -ExecutionPolicy Bypass -File "{0}" -Relaunched' -f $launcher)
                $form.Close()     # the elevated copy takes over
            }
            catch {
                # Almost always a dismissed UAC prompt. Not an error worth a stack trace.
                Write-Verbose "Elevation declined: $($_.Exception.Message)"
            }
        })

    # Same debounce as the editor: $applyFilter tears down and rebuilds every grid row, so running
    # it per character made the list stutter while typing. The checkboxes are single events and
    # filter in memory now, so they stay immediate.
    $filterTimer = New-Object System.Windows.Forms.Timer
    $filterTimer.Interval = 150
    # Guarded like add_Shown below, and for the same reason: on a -BuildOnly form handed to a
    # harness this function has already returned, so $filterTimer resolves to nothing and
    # .Stop() on it throws straight into the global thread-exception handler.
    $filterTimer.add_Tick({
            if ($filterTimer) { $filterTimer.Stop() }
            if ($applyFilter) { & $applyFilter }
        })
    $form.add_FormClosed({
            if ($filterTimer) {
                $filterTimer.Stop()
                $filterTimer.Dispose()
            }
        })

    $btnConsole.add_Click({ Start-Process 'taskschd.msc' })
    $btnRefresh.add_Click({ & $reload })
    $txtFilter.add_TextChanged({
            if ($filterTimer) { $filterTimer.Stop(); $filterTimer.Start() }
            elseif ($applyFilter) { & $applyFilter }
        })
    $chkPsOnly.add_CheckedChanged({ & $applyFilter })
    $chkMicrosoft.add_CheckedChanged({ & $applyFilter })

    $root.Controls.Add($toolbar, 0, 0)
    $root.Controls.Add($filterRow, 0, 1)
    $root.Controls.Add($grid, 0, 2)
    $root.Controls.Add($footer, 0, 3)
    [void]$form.Controls.Add($root)

    # Guarded on purpose. This is the only handler that fires without user interaction, so it
    # is the one that runs even on a form shown outside this function (a -BuildOnly form handed
    # to a harness, say). In that case the stack frame is gone and $reload resolves to nothing;
    # invoking it would throw straight into the global thread-exception handler and pop a
    # message box at whoever happens to be at the keyboard.
    $form.add_Shown({ if ($reload) { & $reload } })

    if ($BuildOnly) { return $form }

    if ($SelfTest) {
        Show-PSTSMUIForTest -Form $form
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
