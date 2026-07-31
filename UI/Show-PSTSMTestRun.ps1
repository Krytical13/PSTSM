# SPDX-License-Identifier: GPL-3.0-or-later
function Show-PSTSMTestRun {
    <#
    .SYNOPSIS
        Runs the plan once and shows what happened, before the task exists.
    .DESCRIPTION
        Opened from the editor's "Test run" button. Runs exactly what the preview pane shows, then
        reports the decoded exit code, how long it took, and everything the script printed.

        The dialog leads with what the run does NOT prove - that it ran as you rather than as the
        task's account - because a test that quietly implies more coverage than it has is worse
        than no test. Everything else here is just presenting Invoke-PSTSMTestRun's result.
    .PARAMETER Plan
        The plan to run.
    .PARAMETER Owner
        Parent form, for correct modal centring.
    .PARAMETER SelfTest
        Test seam. Builds the dialog against an already-computed result and closes it without
        running anything or taking focus.
    .PARAMETER Result
        A pre-computed Invoke-PSTSMTestRun result. Used by -SelfTest; omit for real use.
    .OUTPUTS
        None.
    .EXAMPLE
        Show-PSTSMTestRun -Plan $plan -Owner $form
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Plan,

        [System.Windows.Forms.Form]$Owner,

        [switch]$SelfTest,

        [object]$Result
    )

    Initialize-PSTSMUIHost
    $t = Get-PSTSMUITheme

    $form = New-PSTSMUIForm -Title "Test run - $($Plan.TaskName)" -Width 760 -Height 560
    $form.FormBorderStyle = 'Sizable'
    $form.MinimizeBox = $false

    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.Dock = 'Fill'
    $root.ColumnCount = 1
    $root.RowCount = 3
    $root.Padding = New-Object System.Windows.Forms.Padding(12, 12, 12, 6)
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))

    $lblHead = New-PSTSMUILabel -Text 'Running...'
    $lblHead.Font = $t.FontHeader
    $lblHead.Dock = 'Top'

    $lblWho = New-PSTSMUILabel -Text '' -ForeColor $t.Muted
    $lblWho.Dock = 'Top'
    $lblWho.Margin = New-Object System.Windows.Forms.Padding(3, 2, 3, 8)

    $head = New-Object System.Windows.Forms.TableLayoutPanel
    $head.Dock = 'Top'; $head.AutoSize = $true; $head.ColumnCount = 1; $head.RowCount = 2
    $head.Controls.Add($lblHead, 0, 0)
    $head.Controls.Add($lblWho, 0, 1)

    $txtOut = New-PSTSMUITextBox -ReadOnly -Multiline -Monospace
    $txtOut.Dock = 'Fill'
    $txtOut.ScrollBars = 'Both'
    $txtOut.WordWrap = $false
    $txtOut.Text = 'Starting...'

    $btnClose = New-PSTSMUIButton -Text 'Close' -Primary
    $btnCopy = New-PSTSMUIButton -Text 'Copy output' -Width 120
    $bar = New-PSTSMUIActionBar -LeftButton @($btnCopy) -RightButton @($btnClose)

    $root.Controls.Add($head, 0, 0)
    $root.Controls.Add($txtOut, 0, 1)
    $root.Controls.Add($bar, 0, 2)
    $form.Controls.Add($root)

    $btnClose.add_Click({ $form.Close() })
    $btnCopy.add_Click({
            if ($txtOut.Text) {
                try { [System.Windows.Forms.Clipboard]::SetText($txtOut.Text) }
                catch { Write-Verbose "Clipboard unavailable: $($_.Exception.Message)" }
            }
        })
    # Escape closes; Enter closes. Nothing here is destructive, so both are safe.
    $form.CancelButton = $btnClose
    $form.AcceptButton = $btnClose

    $render = {
        param($r)
        $verdict = if ($r.Error) { "Could not start: $($r.Error)" }
        elseif ($r.TimedOut) { 'Timed out and was stopped' }
        elseif ($r.ExitCode -eq 0) { 'Finished, exit code 0' }
        else { "Finished, exit code $($r.ExitCode)" }
        $lblHead.Text = $verdict

        # The caveat goes above the output, not below it, because it changes how the output should
        # be read. A script that works as you and fails as SYSTEM is precisely what this misses.
        $principal = "$($Plan.Principal.UserId) [$($Plan.Principal.LogonType)]"
        $lblWho.Text = "Ran as $($r.RanAs) - the task will run as $principal. " +
        "Took $([math]::Round($r.Duration.TotalSeconds, 1))s."

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine($r.Command)
        [void]$sb.AppendLine()
        if ($r.ExitText) {
            [void]$sb.AppendLine("Last Run Result would read: $($r.ExitText)")
            [void]$sb.AppendLine()
        }
        if ($r.TimedOut) {
            [void]$sb.AppendLine('The script was still running and was stopped. Unattended it would keep going until')
            [void]$sb.AppendLine('the task''s execution time limit, so check for anything waiting on input.')
            [void]$sb.AppendLine()
        }
        if ($r.Output) { [void]$sb.AppendLine($r.Output) }
        else { [void]$sb.AppendLine('(the script printed nothing)') }
        $txtOut.Text = $sb.ToString()
        $txtOut.Select(0, 0)
    }

    if ($SelfTest) {
        if ($Result) { & $render $Result }
        Show-PSTSMUIForTest -Form $form
        for ($i = 0; $i -lt 10; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 10 }
        if (-not $form.IsDisposed) { $form.Close(); $form.Dispose() }
        return
    }

    # Run once the window is up, so the operator sees "Running..." rather than a frozen rectangle
    # while a slow script starts. Shown() fires after the handle exists and the form is painted.
    $form.add_Shown({
            $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            [System.Windows.Forms.Application]::DoEvents()
            try { $r = Invoke-PSTSMTestRun -Plan $Plan -Confirm:$false }
            finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
            & $render $r
        })

    if ($Owner) { [void]$form.ShowDialog($Owner) } else { [void]$form.ShowDialog() }
    $form.Dispose()
}
