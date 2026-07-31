# SPDX-License-Identifier: GPL-3.0-or-later
function Show-PSTSMGmsaDialog {
    <#
    .SYNOPSIS
        Small utility dialog for creating a group managed service account and preparing this
        machine to use it.
    .DESCRIPTION
        A side utility, not part of the task-building flow. It exists because gMSA setup is six
        steps spread across the directory and the local machine, documented on separate pages,
        with a container that is hidden in ADUC and a reboot trap in the middle - exactly the
        kind of scattered boilerplate the rest of this tool exists to collapse.

        Runs entirely on the caller's own Windows credentials: no credential fields, nothing
        stored, and it simply fails if the operator lacks the rights.

        Prerequisites are shown before anything can be created, and the exact command is
        previewed before it runs - the same contract as the task editor.

        Deliberately does NOT run Add-KdsRootKey. That is one-time, forest-wide and Enterprise
        Admin, and a key is unusable for about ten hours after creation regardless of the switch
        name; the dialog shows the command and the caveat instead of hiding a ten-hour delay
        behind a button.
    .PARAMETER Owner
        Parent form for modal centring.
    .PARAMETER SelfTest
        Test seam. Builds the dialog, runs the prerequisite pass, and closes without creating
        anything.
    .OUTPUTS
        [string] the created account as DOMAIN\name$, or $null if nothing was created.
    .EXAMPLE
        $account = Show-PSTSMGmsaDialog
    #>
    [CmdletBinding()]
    param(
        [System.Windows.Forms.Form]$Owner,
        [switch]$SelfTest,
        [switch]$BuildOnly
    )

    Initialize-PSTSMUIHost
    $t = Get-PSTSMUITheme

    # Handler results must cross the boundary through a reference type; a bare variable assigned
    # inside a Click handler stays in the handler's scope.
    $dlg = @{ Created = $null; Prereqs = @() }

    $form = New-PSTSMUIForm -Title 'Create a group managed service account' -Width 760 -Height 660
    $form.MinimumSize = New-Object System.Drawing.Size(0, 0)

    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.Dock = 'Fill'; $root.ColumnCount = 1; $root.RowCount = 2
    $root.Padding = New-Object System.Windows.Forms.Padding(12, 12, 12, 6)
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))

    $scroll = New-Object System.Windows.Forms.Panel
    $scroll.Dock = 'Fill'; $scroll.AutoScroll = $true
    $stack = New-Object System.Windows.Forms.TableLayoutPanel
    $stack.Dock = 'Top'; $stack.AutoSize = $true; $stack.AutoSizeMode = 'GrowAndShrink'; $stack.ColumnCount = 1

    # --- what this is ------------------------------------------------------------------------
    # Written for someone who has created one or two gMSAs, ever. The whole reason this dialog
    # exists is that the process is scattered and none of the steps explain themselves.
    $secWhat = New-PSTSMUISection -Title 'What this does'
    $lblWhat = New-PSTSMUILabel -ForeColor $t.Muted -Text (
        'A gMSA is a domain account whose password Active Directory generates, rotates and hands out - nobody ever' + [Environment]::NewLine +
        'sees or stores it. That solves both problems S4U has: it can authenticate on the network, and there is no' + [Environment]::NewLine +
        'secret to expire or leak.' + [Environment]::NewLine + [Environment]::NewLine +
        'Three things have to happen, and only the first two are in the directory:' + [Environment]::NewLine +
        '   1.  Create the account, and say which machines may read its password (a GROUP is the answer that scales).' + [Environment]::NewLine +
        '   2.  Each of those machines caches the account locally  -  Install-ADServiceAccount.' + [Environment]::NewLine +
        '   3.  Each machine grants it "Log on as a batch job", or Task Scheduler refuses to register the task.' + [Environment]::NewLine + [Environment]::NewLine +
        'The checkbox below does 2 and 3 for THIS machine. Other machines need the same treatment.')
    Add-PSTSMUIStacked -Stack $secWhat.Content -Control $lblWhat
    Add-PSTSMUIStacked -Stack $stack -Control $secWhat.Container

    # --- prerequisites --------------------------------------------------------------------
    $secPre = New-PSTSMUISection -Title 'Prerequisites'
    $lvPre = New-Object System.Windows.Forms.ListView
    $lvPre.View = 'Details'; $lvPre.FullRowSelect = $true; $lvPre.MultiSelect = $false
    $lvPre.HideSelection = $false; $lvPre.BorderStyle = 'FixedSingle'; $lvPre.Dock = 'Top'
    $lvPre.Height = [int]($t.FontBase.Height * 8)
    [void]$lvPre.Columns.Add('', 10)
    [void]$lvPre.Columns.Add('Check', 10)
    $txtPreDetail = New-PSTSMUITextBox -ReadOnly -Multiline
    $txtPreDetail.Height = [int]($t.FontBase.Height * 5)
    Add-PSTSMUIStacked -Stack $secPre.Content -Control $lvPre
    Add-PSTSMUIStacked -Stack $secPre.Content -Control $txtPreDetail
    Add-PSTSMUIStacked -Stack $stack -Control $secPre.Container

    # --- account --------------------------------------------------------------------------
    $secAcct = New-PSTSMUISection -Title 'Account'
    $tbl = New-PSTSMUIFieldTable
    $txtName = New-PSTSMUITextBox
    $txtPrincipals = New-PSTSMUITextBox
    $txtDescription = New-PSTSMUITextBox
    $txtOu = New-PSTSMUITextBox
    $numInterval = New-Object System.Windows.Forms.NumericUpDown
    $numInterval.Dock = 'Fill'; $numInterval.Minimum = 1; $numInterval.Maximum = 3650; $numInterval.Value = 30

    Add-PSTSMUIField -Table $tbl -Label 'Name' -Control $txtName
    Add-PSTSMUIField -Table $tbl -Label 'Password readable by' -Control $txtPrincipals
    Add-PSTSMUIField -Table $tbl -Label 'Description' -Control $txtDescription
    Add-PSTSMUIField -Table $tbl -Label 'OU' -Control $txtOu
    Add-PSTSMUIField -Table $tbl -Label 'Rotate every (days)' -Control $numInterval

    $hint = New-PSTSMUILabel -ForeColor $t.Muted -Text (
        "Name is without the trailing `$ and must be 15 characters or fewer - it is unique across the whole FOREST, not just this domain." +
        [Environment]::NewLine +
        'Password readable by: prefer a security GROUP containing the computer accounts. Naming computers directly means editing the gMSA every time a host is added.')
    Add-PSTSMUIField -Table $tbl -Label '' -Control $hint

    $chkPrepare = New-Object System.Windows.Forms.CheckBox
    $chkPrepare.Text = 'Also prepare this machine (cache the account, verify it, grant "Log on as a batch job")'
    $chkPrepare.AutoSize = $true
    $chkPrepare.Checked = $true
    Add-PSTSMUIField -Table $tbl -Label '' -Control $chkPrepare

    Add-PSTSMUIStacked -Stack $secAcct.Content -Control $tbl
    Add-PSTSMUIStacked -Stack $stack -Control $secAcct.Container

    # --- preview ---------------------------------------------------------------------------
    $secPrev = New-PSTSMUISection -Title 'What will run'
    $txtPreview = New-PSTSMUITextBox -ReadOnly -Multiline -Monospace
    $txtPreview.Height = [int]($t.FontBase.Height * 6)
    Add-PSTSMUIStacked -Stack $secPrev.Content -Control $txtPreview
    Add-PSTSMUIStacked -Stack $stack -Control $secPrev.Container

    [void]$scroll.Controls.Add($stack)

    # --- behaviour ---------------------------------------------------------------------------
    $sizePreColumns = {
        if ($lvPre.Items.Count -gt 0) { $lvPre.Columns[0].Width = -2 }
        else { $lvPre.Columns[0].Width = [System.Windows.Forms.TextRenderer]::MeasureText('ERROR', $lvPre.Font).Width + [int]$lvPre.Font.Height }
        $rest = $lvPre.ClientSize.Width - $lvPre.Columns[0].Width -
        [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth - 2
        if ($rest -gt 40) { $lvPre.Columns[1].Width = $rest }
    }
    $lvPre.add_Resize({ if ($sizePreColumns) { & $sizePreColumns } })

    $refreshPreview = {
        $name = $txtName.Text.Trim().TrimEnd('$')
        $principals = @($txtPrincipals.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if (-not $name -or $principals.Count -eq 0) {
            $txtPreview.Text = 'Enter a name and at least one principal.'
            $btnCreate.Enabled = $false
            return
        }

        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("New-PSTSMGmsa -Name '$name' ``")
        $lines.Add("    -PrincipalsAllowedToRetrieveManagedPassword $(($principals | ForEach-Object { "'$_'" }) -join ', ') ``")
        if ($txtDescription.Text.Trim()) { $lines.Add("    -Description '$($txtDescription.Text.Trim())' ``") }
        if ($txtOu.Text.Trim()) { $lines.Add("    -Path '$($txtOu.Text.Trim())' ``") }
        $lines.Add("    -ManagedPasswordIntervalInDays $([int]$numInterval.Value)")
        if ($chkPrepare.Checked) {
            $lines.Add('')
            $lines.Add("Install-PSTSMGmsa -Name '$name'")
        }
        $txtPreview.Text = ($lines -join [Environment]::NewLine)

        $blocking = @($dlg.Prereqs | Where-Object { $_.Severity -eq 'Error' })
        $btnCreate.Enabled = ($blocking.Count -eq 0) -and ($name.Length -le 15)
    }

    $runPrereqs = {
        $lvPre.BeginUpdate()
        $lvPre.Items.Clear()
        $checks = @()
        try { $checks = @(Test-PSTSMGmsaPrerequisite) }
        catch {
            $checks = @([PSCustomObject]@{ Id = 'GMSAPRE_FAILED'; Severity = 'Error'; Title = 'Prerequisite check failed'; Detail = $_.Exception.Message; Recommendation = $null })
        }
        $dlg.Prereqs = $checks
        foreach ($c in ($checks | Sort-Object @{ Expression = { (Get-PSTSMUISeverityStyle -Severity $_.Severity).Rank } })) {
            $style = Get-PSTSMUISeverityStyle -Severity $c.Severity
            $item = New-Object System.Windows.Forms.ListViewItem($style.Token)
            [void]$item.SubItems.Add($c.Title)
            $item.ForeColor = $style.Color
            $item.Tag = $c
            [void]$lvPre.Items.Add($item)
        }
        $lvPre.EndUpdate()
        & $sizePreColumns
        & $refreshPreview
    }

    $lvPre.add_SelectedIndexChanged({
            if ($lvPre.SelectedItems.Count -eq 0) { $txtPreDetail.Text = ''; return }
            $c = $lvPre.SelectedItems[0].Tag
            $lines = @("$($c.Severity.ToUpperInvariant()): $($c.Title)")
            if ($c.Detail) { $lines += ''; $lines += $c.Detail }
            if ($c.Recommendation) { $lines += ''; $lines += "-> $($c.Recommendation)" }
            $txtPreDetail.Text = ($lines -join [Environment]::NewLine)
        })

    foreach ($c in @($txtName, $txtPrincipals, $txtDescription, $txtOu)) { $c.add_TextChanged({ & $refreshPreview }) }
    $numInterval.add_ValueChanged({ & $refreshPreview })
    $chkPrepare.add_CheckedChanged({ & $refreshPreview })

    # --- actions ------------------------------------------------------------------------------
    $btnRecheck = New-PSTSMUIButton -Text 'Re-check' -Width 96
    $btnCreate = New-PSTSMUIButton -Text 'Create' -Primary -Width 110
    $btnCancel = New-PSTSMUIButton -Text 'Cancel'

    $btnRecheck.add_Click({ & $runPrereqs })

    $btnCreate.add_Click({
            $name = $txtName.Text.Trim().TrimEnd('$')
            $principals = @($txtPrincipals.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

            $answer = [System.Windows.Forms.MessageBox]::Show(
                "Create gMSA '$name`$' in Active Directory?`n`nPassword readable by: $($principals -join ', ')`n`nThis runs as $([Security.Principal.WindowsIdentity]::GetCurrent().Name).",
                'Confirm', [System.Windows.Forms.MessageBoxButtons]::OKCancel,
                [System.Windows.Forms.MessageBoxIcon]::Question, [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
            if ($answer -ne [System.Windows.Forms.DialogResult]::OK) { return }

            $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            try {
                $p = @{
                    Name                                       = $name
                    PrincipalsAllowedToRetrieveManagedPassword = $principals
                    ManagedPasswordIntervalInDays              = [int]$numInterval.Value
                    Confirm                                    = $false
                }
                if ($txtDescription.Text.Trim()) { $p['Description'] = $txtDescription.Text.Trim() }
                if ($txtOu.Text.Trim()) { $p['Path'] = $txtOu.Text.Trim() }

                New-PSTSMGmsa @p

                $summary = "The account $name`$ was created."
                if ($chkPrepare.Checked) {
                    $installed = Install-PSTSMGmsa -Name $name -Confirm:$false
                    $summary += [Environment]::NewLine + [Environment]::NewLine +
                    "  Cached on this machine   : $($installed.Installed)" + [Environment]::NewLine +
                    "  Password readable here   : $($installed.Usable)" + [Environment]::NewLine +
                    "  Log on as a batch job    : $($installed.BatchLogonRight)"

                    if (-not $installed.Usable) {
                        # The account is fine; the host just is not ready yet. Framed as the
                        # next step rather than a failure, because it usually only needs a
                        # reboot and people otherwise assume they did something wrong.
                        $summary += [Environment]::NewLine + [Environment]::NewLine +
                        'The account exists and is correct - this machine simply cannot read its password yet.' +
                        [Environment]::NewLine + [Environment]::NewLine + $installed.Message +
                        [Environment]::NewLine + [Environment]::NewLine +
                        'You can still finish building the task now; it will run once this machine is ready.'
                    }
                    else {
                        $summary += [Environment]::NewLine + [Environment]::NewLine + $installed.Message
                    }
                }

                $netbios = try { (Get-ADDomain).NetBIOSName } catch { $env:USERDOMAIN }
                $dlg.Created = "$netbios\$name`$"

                [System.Windows.Forms.MessageBox]::Show($summary, 'gMSA created',
                    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null

                $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
                $form.Close()
            }
            catch {
                [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Could not create the gMSA',
                    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            }
            finally {
                $form.Cursor = [System.Windows.Forms.Cursors]::Default
            }
        })

    $btnCancel.add_Click({
            $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
            $form.Close()
        })

    $bar = New-PSTSMUIActionBar -LeftButton @($btnRecheck) -RightButton @($btnCancel, $btnCreate)
    $root.Controls.Add($scroll, 0, 0)
    $root.Controls.Add($bar, 0, 1)
    [void]$form.Controls.Add($root)
    $form.CancelButton = $btnCancel

    & $runPrereqs

    if ($BuildOnly) { return $form }

    if ($SelfTest) {
        Show-PSTSMUIForTest -Form $form
        for ($i = 0; $i -lt 20; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 10 }
        if (-not $form.IsDisposed) { $form.Close(); $form.Dispose() }
        return $dlg.Created
    }

    if ($Owner) { [void]$form.ShowDialog($Owner) } else { [void]$form.ShowDialog() }
    $form.Dispose()
    $dlg.Created
}
