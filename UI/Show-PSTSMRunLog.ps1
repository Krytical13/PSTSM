# SPDX-License-Identifier: GPL-3.0-or-later
function Show-PSTSMRunLog {
    <#
    .SYNOPSIS
        Window showing what actually happened the last time a task ran.
    .DESCRIPTION
        A view over Get-PSTSMTaskRunLog. "Last Run Result: 0x1" is all Task Scheduler offers;
        this shows the transcript a PSTSM-built task wrote, or the operational event log for
        anything else.

        When no history exists the window says WHY - most often because Windows ships the Task
        Scheduler operational log disabled - rather than showing an empty box that reads as
        "this task has never run".
    .PARAMETER TaskName
        Task to show.
    .PARAMETER TaskPath
        Folder the task is in.
    .PARAMETER Owner
        Parent form for modal centring.
    .PARAMETER SelfTest
        Test seam. Shows, pumps and closes inside this function.
    .PARAMETER BuildOnly
        Test seam. Realises the window off-screen without activating it, pumps the message loop
        briefly, then closes it. It does NOT return the form - the handlers close over this
        function's locals, which are gone once it returns.
    .OUTPUTS
        None.
    .EXAMPLE
        Show-PSTSMRunLog -TaskName 'Send-NightlyReport' -TaskPath '\Custom\'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [string]$TaskPath = '\',
        [System.Windows.Forms.Form]$Owner,
        [switch]$BuildOnly,
        [switch]$SelfTest
    )

    Initialize-PSTSMUIHost
    $t = Get-PSTSMUITheme

    $form = New-PSTSMUIForm -Title "PSTSM - Last run: $TaskName" -Width 1000 -Height 640
    $form.MinimumSize = New-Object System.Drawing.Size(0, 0)

    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.Dock = 'Fill'; $root.ColumnCount = 1; $root.RowCount = 3
    $root.Padding = New-Object System.Windows.Forms.Padding(12, 10, 12, 6)
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))

    $lblHead = New-PSTSMUILabel -Text 'Reading...' -Header
    $lblHead.ForeColor = $t.Accent

    # Monospace: this is program output, and transcripts line up in columns.
    $txt = New-PSTSMUITextBox -ReadOnly -Multiline -Monospace
    $txt.ScrollBars = 'Both'

    $logs = @()
    try { $logs = @(Get-PSTSMTaskRunLog -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop) }
    catch {
        $logs = @([PSCustomObject]@{ Source = 'None'; Available = $false; Path = $null; Timestamp = $null; Content = $null; Note = $_.Exception.Message })
    }

    $first = $logs[0]
    if ($first -and $first.Available) {
        $when = if ($first.Timestamp) { " - $($first.Timestamp)" } else { '' }
        $lblHead.Text = "$($first.Source)$when"
        $lblHead.ForeColor = $t.Good
        $txt.Text = [string]$first.Content
        if ($first.Note) { $txt.Text = "# $($first.Note)" + [Environment]::NewLine + [Environment]::NewLine + $txt.Text }
        # Transcript lines are pre-formatted; wrapping them would destroy the alignment.
        $txt.WordWrap = $false
    }
    else {
        $lblHead.Text = 'No run history available'
        $lblHead.ForeColor = $t.Warn
        # The reason is the content here - an empty box would read as "never ran".
        $txt.Text = [string]$first.Note
        # This one is prose, so wrap it rather than making the operator scroll sideways to
        # read the sentence that explains the whole situation.
        $txt.WordWrap = $true
    }

    # Populating a TextBox leaves everything selected, which renders as a wall of highlight.
    $txt.SelectionStart = 0
    $txt.SelectionLength = 0

    $btnFolder = New-PSTSMUIButton -Text 'Open folder' -Width 118
    $btnFolder.Enabled = [bool]($first -and $first.Source -eq 'Transcript' -and $first.Path)
    $btnFolder.add_Click({
            $p = $first.Path
            if (-not $p) { return }
            $dir = if (Test-Path -LiteralPath $p -PathType Leaf) { Split-Path $p -Parent } else { $p }
            if (Test-Path -LiteralPath $dir) { Start-Process explorer.exe $dir }
        })

    $btnCopy = New-PSTSMUIButton -Text 'Copy' -Width 90
    $btnCopy.add_Click({ if ($txt.Text) { [System.Windows.Forms.Clipboard]::SetText($txt.Text) } })

    $btnClose = New-PSTSMUIButton -Text 'Close' -Primary
    $btnClose.add_Click({ $form.DialogResult = [System.Windows.Forms.DialogResult]::OK; $form.Close() })

    $bar = New-PSTSMUIActionBar -LeftButton @($btnFolder, $btnCopy) -RightButton @($btnClose)

    $root.Controls.Add($lblHead, 0, 0)
    $root.Controls.Add($txt, 0, 1)
    $root.Controls.Add($bar, 0, 2)
    [void]$form.Controls.Add($root)
    $form.CancelButton = $btnClose
    $form.AcceptButton = $btnClose

    if ($BuildOnly) { return $form }
    if ($SelfTest) {
        Show-PSTSMUIForTest -Form $form
        for ($i = 0; $i -lt 15; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 10 }
        if (-not $form.IsDisposed) { $form.Close(); $form.Dispose() }
        return
    }

    if ($Owner) { [void]$form.ShowDialog($Owner) } else { [void]$form.ShowDialog() }
    $form.Dispose()
}
