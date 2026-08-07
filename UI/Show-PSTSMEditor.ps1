# SPDX-License-Identifier: GPL-3.0-or-later
function Show-PSTSMEditor {
    <#
    .SYNOPSIS
        The create/edit window: pick a script, everything derivable fills itself in, change
        anything you disagree with, see the exact command and the preflight before saving.
    .DESCRIPTION
        Left pane is the form, right pane is a live preview plus preflight. Every control edit
        rebuilds the plan and refreshes both, so what you read on the right is always what
        Register-PSTSMPlan would write - there is no separate "generate" step to fall out of
        sync.

        The parameter section is generated from the script's own param() block: switches become
        checkboxes, ValidateSet becomes a combo box, path-like parameters get a Browse button,
        and mandatory ones are marked and enforced by the preflight.

        Opening an existing task (-Plan from ConvertFrom-PSTSMDefinition) uses the same form.
        If that task was not built by this tool and its action cannot be modelled, the argument
        string is shown read-only and saving is blocked rather than silently rewriting it.
    .PARAMETER ScriptPath
        Create a new task for this script.
    .PARAMETER Plan
        Edit this existing plan.
    .PARAMETER Owner
        Parent form for modal centring.
    .PARAMETER BuildOnly
        Test seam. Builds the window and returns the Form without showing it, so the offline
        harness can force layout and assert control bounds. LAYOUT INSPECTION ONLY - once this
        function returns, its stack frame is gone and the event handlers can no longer resolve
        the locals they close over, so do not Show() the returned form. Use -SelfTest for that.
    .PARAMETER SelfTest
        Test seam. Realises the window off-screen without activating it, pumps the message loop
        briefly, then closes it -
        all inside this function, so handlers still see their locals. This is the only way to
        catch show-time failures; DrawToBitmap renders chrome and misses them entirely.
    .OUTPUTS
        [pscustomobject] the saved plan, or $null if cancelled.
        [System.Windows.Forms.Form] when -BuildOnly is used.
    .EXAMPLE
        Show-PSTSMEditor -ScriptPath 'D:\Scripts\Send-Report.ps1'
    .EXAMPLE
        Show-PSTSMEditor -Plan (ConvertFrom-PSTSMDefinition -TaskName 'Nightly' -TaskPath '\Custom\')
    #>
    [CmdletBinding(DefaultParameterSetName = 'New')]
    param(
        [Parameter(ParameterSetName = 'New')]
        [string]$ScriptPath,

        [Parameter(Mandatory, ParameterSetName = 'Edit')]
        [object]$Plan,

        [System.Windows.Forms.Form]$Owner,

        [switch]$BuildOnly,

        [switch]$SelfTest
    )

    Initialize-PSTSMUIHost
    $t = Get-PSTSMUITheme

    # --- state ----------------------------------------------------------------------
    # A hashtable rather than $script: scope, so two editor windows can never collide.
    $state = @{
        Profile       = $null
        ParamControls = [ordered]@{}
        Triggers      = @()
        Settings      = $null
        Logging       = $null
        Suspend       = $true      # blocks refresh while controls are being populated
        SavedPlan     = $null
        IsEdit        = [bool]$Plan
        # 'PowerShellScript' (the full script + parameters form), 'Executable' (a bare command
        # line, edited as three verbatim fields), or 'Unsupported' (an action with no command line
        # to preserve, or more actions than the plan shape holds). A new task is always the first.
        ActionKind    = 'PowerShellScript'
        Locked        = $false     # action cannot be rewritten - only the schedule around it
        BasePlan      = $null      # the loaded plan, kept whole so Executable edits overlay it
        # Working copies of an Executable task's command lines, and which one the three fields are
        # currently showing. Edits land in the list when the selection changes or the plan is
        # built, so switching between actions does not lose what was typed into the last one.
        ExecActions   = @()
        ExecIndex     = 0
        OriginalName  = $null
        OriginalPath  = $null
        # Read once. A session cannot gain an administrator token while it runs, so re-asking on
        # every keystroke would only cost time - and any elevated work happens in a child process
        # that does not change the answer here.
        IsElevated       = (Test-PSTSMElevated)
        # Cache for "is the task's principal an administrator", which can reach a domain
        # controller. Keyed by the principal so changing the account re-asks and nothing else does.
        AdminCheckFor    = $null
        PrincipalIsAdmin = $null
    }

    if ($Plan) {
        $ScriptPath = $Plan.ScriptPath
        $state.Settings = $Plan.Settings
        $state.Logging = $Plan.Logging
        $state.Triggers = @($Plan.Triggers)
        $state.OriginalName = $Plan.TaskName
        $state.OriginalPath = $Plan.TaskPath
        $state.BasePlan = $Plan

        # ActionKind, not IsFullyRecognized. The old flag was false for four unrelated reasons and
        # this window locked entirely on any of them - so "change the schedule on my robocopy task"
        # was refused, even though that action is simpler than the ones the tool does model.
        # Only Unsupported still locks, and now it locks the ACTION rather than the whole form.
        if ($Plan.PSObject.Properties['ActionKind'] -and $Plan.ActionKind) {
            $state.ActionKind = [string]$Plan.ActionKind
        }
        elseif ($Plan.PSObject.Properties['IsFullyRecognized'] -and -not $Plan.IsFullyRecognized) {
            # A plan from an older export, which predates ActionKind. Treat it the way it was
            # treated then rather than guessing it is safe to edit.
            $state.ActionKind = 'Unsupported'
        }
        $state.Locked = ($state.ActionKind -eq 'Unsupported')
    }

    # Product name first, then what this window is doing. Consistent across every window so the
    # tool is identifiable in a crowded taskbar.
    $title = if ($Plan) { "PSTSM - Edit task: $($Plan.TaskName)" } else { 'PSTSM - New task' }
    $form = New-PSTSMUIForm -Title $title -Width 1180 -Height 780

    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.Dock = 'Fill'
    $root.ColumnCount = 2
    $root.RowCount = 2
    $root.Padding = New-Object System.Windows.Forms.Padding(10, 10, 10, 4)
    [void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 60)))
    [void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 40)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))

    # =================================================================================
    # LEFT: the form
    # =================================================================================
    $leftScroll = New-Object System.Windows.Forms.Panel
    $leftScroll.Dock = 'Fill'
    $leftScroll.AutoScroll = $true
    $leftScroll.Padding = New-Object System.Windows.Forms.Padding(0, 0, 12, 0)

    $leftStack = New-Object System.Windows.Forms.TableLayoutPanel
    $leftStack.Dock = 'Top'
    $leftStack.AutoSize = $true
    $leftStack.AutoSizeMode = 'GrowAndShrink'
    $leftStack.ColumnCount = 1
    # No explicit Width. Dock='Top' inside the AutoScroll panel already tracks the parent's
    # client width, and a pixel constant here would be too narrow once the font scales up.

    # --- script ---------------------------------------------------------------------
    $secScript = New-PSTSMUISection -Title 'Script'
    $txtScript = New-PSTSMUITextBox -Text $ScriptPath
    $btnBrowseScript = New-PSTSMUIButton -Text 'Browse...' -Width 90

    # A task can run several programs in order. One selector, three fields, rather than N sets of
    # fields: the count is not known until a task is opened and the section would otherwise change
    # height with it.
    #
    # Added ONLY when there is more than one action, never added-then-hidden - a hidden control is
    # still measured by the layout, and Control.Visible reads false for everything on a form that
    # has never been shown, so "hidden" is not something the offline layout checks can even see.
    $cboExecAction = $null
    if ($state.ActionKind -eq 'Executable' -and $Plan -and
        $Plan.PSObject.Properties['RawActions'] -and @($Plan.RawActions).Count -gt 1) {
        $cboExecAction = New-Object System.Windows.Forms.ComboBox
        $cboExecAction.DropDownStyle = 'DropDownList'
        $cboExecAction.Dock = 'Top'
        $cboExecAction.AccessibleName = 'Which action to edit'
        Add-PSTSMUIStacked -Stack $secScript.Content -Control $cboExecAction
    }

    $scriptRow = New-Object System.Windows.Forms.TableLayoutPanel
    $scriptRow.Dock = 'Top'; $scriptRow.AutoSize = $true; $scriptRow.ColumnCount = 2; $scriptRow.RowCount = 1
    [void]$scriptRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$scriptRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $scriptRow.Controls.Add($txtScript, 0, 0)
    $scriptRow.Controls.Add($btnBrowseScript, 1, 0)
    Add-PSTSMUIStacked -Stack $secScript.Content -Control $scriptRow

    $lblDerived = New-PSTSMUILabel -Text '' -ForeColor $t.Muted
    Add-PSTSMUIStacked -Stack $secScript.Content -Control $lblDerived
    Add-PSTSMUIStacked -Stack $leftStack -Control $secScript.Container

    # --- task identity --------------------------------------------------------------
    $secTask = New-PSTSMUISection -Title 'Task'
    $tblTask = New-PSTSMUIFieldTable
    $txtName = New-PSTSMUITextBox
    $txtFolder = New-PSTSMUITextBox -Text '\'
    $txtDesc = New-PSTSMUITextBox
    Add-PSTSMUIField -Table $tblTask -Label 'Name' -Control $txtName
    Add-PSTSMUIField -Table $tblTask -Label 'Folder' -Control $txtFolder
    Add-PSTSMUIField -Table $tblTask -Label 'Description' -Control $txtDesc
    Add-PSTSMUIStacked -Stack $secTask.Content -Control $tblTask
    Add-PSTSMUIStacked -Stack $leftStack -Control $secTask.Container

    # --- engine ---------------------------------------------------------------------
    $secEngine = New-PSTSMUISection -Title 'Engine'
    $tblEngine = New-PSTSMUIFieldTable
    $cboEngine = New-Object System.Windows.Forms.ComboBox
    $cboEngine.Dock = 'Fill'; $cboEngine.DropDownStyle = 'DropDownList'
    $engines = @(Get-PSTSMEngine)
    foreach ($e in $engines) { [void]$cboEngine.Items.Add($e.DisplayName) }
    $txtWorkDir = New-PSTSMUITextBox
    Add-PSTSMUIField -Table $tblEngine -Label 'Run with' -Control $cboEngine
    Add-PSTSMUIField -Table $tblEngine -Label 'Start in' -Control $txtWorkDir
    Add-PSTSMUIStacked -Stack $secEngine.Content -Control $tblEngine
    Add-PSTSMUIStacked -Stack $leftStack -Control $secEngine.Container

    # --- parameters -----------------------------------------------------------------
    $secParams = New-PSTSMUISection -Title 'Parameters'
    $paramHost = New-Object System.Windows.Forms.TableLayoutPanel
    $paramHost.Dock = 'Top'; $paramHost.AutoSize = $true; $paramHost.AutoSizeMode = 'GrowAndShrink'; $paramHost.ColumnCount = 1
    Add-PSTSMUIStacked -Stack $secParams.Content -Control $paramHost
    Add-PSTSMUIStacked -Stack $leftStack -Control $secParams.Container

    # --- triggers -------------------------------------------------------------------
    $secTrig = New-PSTSMUISection -Title 'Schedule'
    $lstTrig = New-Object System.Windows.Forms.ListBox
    # Sized in rows of the actual font rather than pixels, so it still shows ~5 triggers at any
    # display scale instead of clipping to two and a half.
    $lstTrig.Height = [int]($t.FontBase.Height * 5.5)
    $lstTrig.Dock = 'Top'
    $lstTrig.BorderStyle = 'FixedSingle'
    $lstTrig.IntegralHeight = $false
    $btnTrigAdd = New-PSTSMUIButton -Text 'Add...' -Width 80
    $btnTrigEdit = New-PSTSMUIButton -Text 'Edit...' -Width 80
    $btnTrigDel = New-PSTSMUIButton -Text 'Remove' -Width 80
    $trigBar = New-Object System.Windows.Forms.FlowLayoutPanel
    $trigBar.Dock = 'Top'; $trigBar.AutoSize = $true; $trigBar.WrapContents = $false
    foreach ($b in @($btnTrigAdd, $btnTrigEdit, $btnTrigDel)) { [void]$trigBar.Controls.Add($b) }
    Add-PSTSMUIStacked -Stack $secTrig.Content -Control $lstTrig
    Add-PSTSMUIStacked -Stack $secTrig.Content -Control $trigBar
    Add-PSTSMUIStacked -Stack $leftStack -Control $secTrig.Container

    # --- principal ------------------------------------------------------------------
    $secWho = New-PSTSMUISection -Title 'Run as'
    $tblWho = New-PSTSMUIFieldTable
    # Two controls, not one. A single list mixed up two orthogonal questions - WHAT KIND of
    # account ("gMSA", "SYSTEM", "a group") and WHEN it runs ("only while logged on") - so
    # half the entries did not answer the label above them.
    #
    #   Account type  ->  what you are running as
    #   When          ->  logged-on requirement and how the password is handled
    #
    # 'When' is only a real choice for an ordinary user account. For the other three the answer
    # is fixed by the account type, so the combo shows that single answer and greys out rather
    # than hiding, which would leave the question silently unanswered.
    $cboAccountType = New-Object System.Windows.Forms.ComboBox
    $cboAccountType.Dock = 'Fill'; $cboAccountType.DropDownStyle = 'DropDownList'
    $accountTypes = [ordered]@{
        'User'    = 'User or service account'
        'gMSA'    = 'Group managed service account (gMSA)'
        'BuiltIn' = 'Built-in service account (SYSTEM, LOCAL/NETWORK SERVICE)'
        'Group'   = 'Group'
    }
    foreach ($k in $accountTypes.Keys) { [void]$cboAccountType.Items.Add($accountTypes[$k]) }

    $cboWhen = New-Object System.Windows.Forms.ComboBox
    $cboWhen.Dock = 'Fill'; $cboWhen.DropDownStyle = 'DropDownList'

    # Only the User row is selectable; the rest are the fixed consequence of the account type.
    $whenChoicesForUser = [ordered]@{
        'S4U'         = 'Whether logged on or not - no password stored (S4U)'
        'Password'    = 'Whether logged on or not - using a stored password'
        'Interactive' = 'Only while this user is logged on'
    }
    $whenFixed = [ordered]@{
        'gMSA'    = 'Whether logged on or not - Active Directory supplies the password'
        'BuiltIn' = 'Whether logged on or not - no password needed'
        'Group'   = 'Runs for members of the group'
    }

    # The plan still speaks a single LogonType, so the pair collapses back to one on the way out
    # and splits apart on the way in.
    $getLogonType = {
        $typeKeys = @($accountTypes.Keys)
        $type = if ($cboAccountType.SelectedIndex -ge 0) { $typeKeys[$cboAccountType.SelectedIndex] } else { 'User' }
        switch ($type) {
            'gMSA' { 'gMSA' }
            'BuiltIn' { 'ServiceAccount' }
            'Group' { 'Group' }
            default {
                $whenKeys = @($whenChoicesForUser.Keys)
                if ($cboWhen.SelectedIndex -ge 0 -and $cboWhen.SelectedIndex -lt $whenKeys.Count) { $whenKeys[$cboWhen.SelectedIndex] }
                else { 'S4U' }
            }
        }
    }

    $applyAccountType = {
        $typeKeys = @($accountTypes.Keys)
        if ($cboAccountType.SelectedIndex -lt 0) { return }
        $type = $typeKeys[$cboAccountType.SelectedIndex]

        $previous = if ($cboWhen.SelectedIndex -ge 0) { [string]$cboWhen.SelectedItem } else { $null }
        $cboWhen.Items.Clear()

        if ($type -eq 'User') {
            foreach ($k in $whenChoicesForUser.Keys) { [void]$cboWhen.Items.Add($whenChoicesForUser[$k]) }
            $cboWhen.Enabled = $true
            # ObjectCollection.IndexOf throws on $null, which is exactly what $previous is the
            # first time through - so only try to restore when there is something to restore.
            $restored = -1
            if ($null -ne $previous) { $restored = $cboWhen.Items.IndexOf($previous) }
            $cboWhen.SelectedIndex = $(if ($restored -ge 0) { $restored } else { 0 })
        }
        else {
            [void]$cboWhen.Items.Add($whenFixed[$type])
            $cboWhen.SelectedIndex = 0
            $cboWhen.Enabled = $false
        }
    }
    $txtUser = New-PSTSMUITextBox
    $chkHighest = New-Object System.Windows.Forms.CheckBox
    $chkHighest.Text = 'Run with highest privileges'
    $chkHighest.AutoSize = $true
    # Explains the box whenever it is greyed out. A disabled control with no reason attached is
    # just a dead end.
    $tipHighest = New-Object System.Windows.Forms.ToolTip
    $tipHighest.AutoPopDelay = 20000
    # Browse, not "Create gMSA" - picking an account that already exists is the normal case.
    # The picker covers gMSAs, user/service accounts and the built-in principals, sets the
    # matching logon type, and offers creation as a side door for the rarer case.
    $btnPickAccount = New-PSTSMUIButton -Text 'Browse...' -Width 96
    $acctRow = New-Object System.Windows.Forms.TableLayoutPanel
    $acctRow.Dock = 'Top'; $acctRow.AutoSize = $true; $acctRow.ColumnCount = 2; $acctRow.RowCount = 1
    $acctRow.Margin = New-Object System.Windows.Forms.Padding(0)
    [void]$acctRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$acctRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $acctRow.Controls.Add($txtUser, 0, 0)
    $acctRow.Controls.Add($btnPickAccount, 1, 0)

    Add-PSTSMUIField -Table $tblWho -Label 'Account type' -Control $cboAccountType
    Add-PSTSMUIField -Table $tblWho -Label 'Account' -Control $acctRow
    Add-PSTSMUIField -Table $tblWho -Label 'When' -Control $cboWhen
    Add-PSTSMUIField -Table $tblWho -Label '' -Control $chkHighest
    Add-PSTSMUIStacked -Stack $secWho.Content -Control $tblWho
    Add-PSTSMUIStacked -Stack $leftStack -Control $secWho.Container

    # --- advanced -------------------------------------------------------------------
    $chkAdvanced = New-Object System.Windows.Forms.CheckBox
    $chkAdvanced.Text = 'Show advanced settings'
    $chkAdvanced.AutoSize = $true
    $chkAdvanced.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)
    Add-PSTSMUIStacked -Stack $leftStack -Control $chkAdvanced

    $secAdv = New-PSTSMUISection -Title 'Reliability, logging and engine switches'
    $secAdv.Container.Visible = $false
    $tblAdv = New-PSTSMUIFieldTable

    $cboInstances = New-Object System.Windows.Forms.ComboBox
    $cboInstances.Dock = 'Fill'; $cboInstances.DropDownStyle = 'DropDownList'
    foreach ($x in @('IgnoreNew', 'Parallel', 'Queue', 'StopExisting')) { [void]$cboInstances.Items.Add($x) }
    $txtTimeLimit = New-PSTSMUITextBox
    $txtRestartCount = New-PSTSMUITextBox
    $txtRestartInterval = New-PSTSMUITextBox
    $chkStartWhenAvail = New-Object System.Windows.Forms.CheckBox; $chkStartWhenAvail.Text = 'Run as soon as possible after a missed start'; $chkStartWhenAvail.AutoSize = $true
    $chkBatteryStop = New-Object System.Windows.Forms.CheckBox; $chkBatteryStop.Text = "Don't start on battery power"; $chkBatteryStop.AutoSize = $true
    $chkNetwork = New-Object System.Windows.Forms.CheckBox; $chkNetwork.Text = 'Only run when a network is available'; $chkNetwork.AutoSize = $true
    $chkWake = New-Object System.Windows.Forms.CheckBox; $chkWake.Text = 'Wake the computer to run'; $chkWake.AutoSize = $true
    $chkHidden = New-Object System.Windows.Forms.CheckBox; $chkHidden.Text = 'Hidden'; $chkHidden.AutoSize = $true

    $cboLogging = New-Object System.Windows.Forms.ComboBox
    $cboLogging.Dock = 'Fill'; $cboLogging.DropDownStyle = 'DropDownList'
    [void]$cboLogging.Items.Add('Transcript - wrap the script so each run leaves a log')
    [void]$cboLogging.Items.Add('None - run the script directly')
    $txtLogDir = New-PSTSMUITextBox
    $txtLogRetain = New-PSTSMUITextBox

    $cboExecPolicy = New-Object System.Windows.Forms.ComboBox
    $cboExecPolicy.Dock = 'Fill'; $cboExecPolicy.DropDownStyle = 'DropDownList'
    foreach ($x in @('Bypass', 'RemoteSigned', 'AllSigned', 'Unrestricted', 'Restricted', 'Default', 'None')) { [void]$cboExecPolicy.Items.Add($x) }
    $chkNoProfile = New-Object System.Windows.Forms.CheckBox; $chkNoProfile.Text = '-NoProfile'; $chkNoProfile.AutoSize = $true
    $chkNonInteractive = New-Object System.Windows.Forms.CheckBox; $chkNonInteractive.Text = '-NonInteractive'; $chkNonInteractive.AutoSize = $true
    $cboWindowStyle = New-Object System.Windows.Forms.ComboBox
    $cboWindowStyle.Dock = 'Fill'; $cboWindowStyle.DropDownStyle = 'DropDownList'
    foreach ($x in @('Hidden', 'Minimized', 'Normal', 'Maximized', 'None')) { [void]$cboWindowStyle.Items.Add($x) }
    $txtExtraArgs = New-PSTSMUITextBox

    Add-PSTSMUIField -Table $tblAdv -Label 'If already running' -Control $cboInstances
    Add-PSTSMUIField -Table $tblAdv -Label 'Stop after' -Control $txtTimeLimit
    Add-PSTSMUIField -Table $tblAdv -Label 'Restart attempts' -Control $txtRestartCount
    Add-PSTSMUIField -Table $tblAdv -Label 'Restart every' -Control $txtRestartInterval
    Add-PSTSMUIField -Table $tblAdv -Label '' -Control $chkStartWhenAvail
    Add-PSTSMUIField -Table $tblAdv -Label '' -Control $chkBatteryStop
    Add-PSTSMUIField -Table $tblAdv -Label '' -Control $chkNetwork
    Add-PSTSMUIField -Table $tblAdv -Label '' -Control $chkWake
    Add-PSTSMUIField -Table $tblAdv -Label '' -Control $chkHidden
    Add-PSTSMUIField -Table $tblAdv -Label 'Logging' -Control $cboLogging
    Add-PSTSMUIField -Table $tblAdv -Label 'Log folder' -Control $txtLogDir
    Add-PSTSMUIField -Table $tblAdv -Label 'Keep logs (days)' -Control $txtLogRetain
    Add-PSTSMUIField -Table $tblAdv -Label 'Execution policy' -Control $cboExecPolicy
    Add-PSTSMUIField -Table $tblAdv -Label 'Window style' -Control $cboWindowStyle
    Add-PSTSMUIField -Table $tblAdv -Label '' -Control $chkNoProfile
    Add-PSTSMUIField -Table $tblAdv -Label '' -Control $chkNonInteractive
    Add-PSTSMUIField -Table $tblAdv -Label 'Extra arguments' -Control $txtExtraArgs
    Add-PSTSMUIStacked -Stack $secAdv.Content -Control $tblAdv
    Add-PSTSMUIStacked -Stack $leftStack -Control $secAdv.Container

    [void]$leftScroll.Controls.Add($leftStack)

    # =================================================================================
    # RIGHT: preview + preflight
    # =================================================================================
    $rightCol = New-Object System.Windows.Forms.TableLayoutPanel
    $rightCol.Dock = 'Fill'; $rightCol.ColumnCount = 1; $rightCol.RowCount = 4
    [void]$rightCol.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$rightCol.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 42)))
    [void]$rightCol.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$rightCol.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 58)))

    $lblPreview = New-PSTSMUILabel -Text 'What will be registered' -Header
    $lblPreview.ForeColor = $t.Accent
    $txtPreview = New-PSTSMUITextBox -ReadOnly -Multiline -Monospace

    $lblChecks = New-PSTSMUILabel -Text 'Preflight' -Header
    $lblChecks.ForeColor = $t.Accent

    $checkHost = New-Object System.Windows.Forms.TableLayoutPanel
    $checkHost.Dock = 'Fill'; $checkHost.ColumnCount = 1; $checkHost.RowCount = 2
    [void]$checkHost.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 60)))
    [void]$checkHost.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 40)))

    $lvChecks = New-Object System.Windows.Forms.ListView
    $lvChecks.Dock = 'Fill'
    $lvChecks.View = 'Details'
    $lvChecks.FullRowSelect = $true
    $lvChecks.MultiSelect = $false
    $lvChecks.HideSelection = $false
    $lvChecks.BorderStyle = 'FixedSingle'
    # Add columns one at a time: Columns.AddRange needs a typed ColumnHeader[], which a
    # PowerShell @(...) (Object[]) will not bind to.
    # Widths are set by $sizeCheckColumns below rather than as pixel constants - a fixed 52px
    # severity column truncates 'ERROR' to 'ERR...' as soon as the font scales up.
    [void]$lvChecks.Columns.Add('', 10)
    [void]$lvChecks.Columns.Add('Check', 10)

    $txtCheckDetail = New-PSTSMUITextBox -ReadOnly -Multiline
    $txtCheckDetail.Height = [int]($t.FontBase.Height * 7)

    $checkHost.Controls.Add($lvChecks, 0, 0)
    $checkHost.Controls.Add($txtCheckDetail, 0, 1)

    $rightCol.Controls.Add($lblPreview, 0, 0)
    $rightCol.Controls.Add($txtPreview, 0, 1)
    $rightCol.Controls.Add($lblChecks, 0, 2)
    $rightCol.Controls.Add($checkHost, 0, 3)

    # =================================================================================
    # Behaviour
    # =================================================================================

    # Reads the current control values into a plan. Single source of truth is the controls,
    # so the preview can never drift from what Save would register.
    # Collects the settings the form controls, over whatever the task already had. Shared by both
    # plan shapes: an executable task has exactly the same reliability settings as a script one.
    $collectSettings = {
        $s = @{}
        if ($state.Settings) {
            foreach ($k in $state.Settings.Keys) { $s[$k] = $state.Settings[$k] }
        }
        $s['MultipleInstances'] = [string]$cboInstances.SelectedItem
        $s['StartWhenAvailable'] = $chkStartWhenAvail.Checked
        $s['ExecutionTimeLimit'] = $txtTimeLimit.Text.Trim()
        $s['RestartInterval'] = $txtRestartInterval.Text.Trim()
        $s['DisallowStartIfOnBatteries'] = $chkBatteryStop.Checked
        $s['StopIfGoingOnBatteries'] = $chkBatteryStop.Checked
        $s['RunOnlyIfNetworkAvailable'] = $chkNetwork.Checked
        $s['WakeToRun'] = $chkWake.Checked
        $s['Hidden'] = $chkHidden.Checked
        if (-not $s.ContainsKey('RestartCount')) { $s['RestartCount'] = 0 }
        $rc = 0
        if ([int]::TryParse($txtRestartCount.Text.Trim(), [ref]$rc)) { $s['RestartCount'] = $rc }
        $s
    }

    # An executable task has no script to profile, so New-PSTSMPlan cannot build it - that command
    # starts from a .ps1 by definition. The loaded plan already has the right shape, so the form
    # overlays onto a copy of it.
    #
    # The three command-line fields go across as typed. Nothing here re-quotes, re-parses or
    # regenerates them, which is the whole guarantee for this action kind: what was read from the
    # task is what goes back unless the operator changed it themselves.
    # Reads the three command-line fields into whichever action is currently selected. Called
    # before the selection moves and before the plan is built - the two moments the on-screen
    # values have to become part of the list rather than just sitting in the controls.
    $captureExecFields = {
        if ($state.ActionKind -ne 'Executable') { return }
        if (@($state.ExecActions).Count -eq 0) { return }
        $i = $state.ExecIndex
        if ($i -lt 0 -or $i -ge @($state.ExecActions).Count) { return }
        $entry = $state.ExecActions[$i]
        $entry.Execute = $txtScript.Text.Trim()
        $entry.Arguments = $txtExtraArgs.Text
        $entry.WorkingDirectory = $txtWorkDir.Text.Trim()
        $entry.Summary = (@($entry.Execute, $entry.Arguments) | Where-Object { $_ }) -join ' '
    }

    # The other direction: put a stored action into the fields.
    $showExecAction = {
        param($Index)
        if (@($state.ExecActions).Count -eq 0) { return }
        if ($Index -lt 0 -or $Index -ge @($state.ExecActions).Count) { return }
        $entry = $state.ExecActions[$Index]
        $state.ExecIndex = $Index
        # Suspended so filling three fields does not queue three refreshes of a plan that is
        # halfway between two actions.
        $wasSuspended = $state.Suspend
        $state.Suspend = $true
        $txtScript.Text = [string]$entry.Execute
        $txtExtraArgs.Text = [string]$entry.Arguments
        $txtWorkDir.Text = [string]$entry.WorkingDirectory
        $state.Suspend = $wasSuspended
    }

    $buildExecPlan = {
        if (-not $state.BasePlan) { return $null }

        # Shallow copy, then replace every nested container this touches. Mutating them in place
        # would edit the plan the window was opened with, so Cancel would not actually cancel.
        $p = $state.BasePlan.PSObject.Copy()

        $p.TaskName = $txtName.Text.Trim()
        $p.TaskPath = $(if ($txtFolder.Text.Trim()) { $txtFolder.Text.Trim() } else { '\' })
        $p.Description = $txtDesc.Text

        if ($state.ActionKind -eq 'Executable') {
            # Fold whatever is on screen back into the action it belongs to before reading the
            # list, so the currently-shown action is not a keystroke behind the others.
            & $captureExecFields

            $p.RawActions = @($state.ExecActions)
            # RawAction stays the first action: callers and tests read it, and for the common
            # single-action case the two say the same thing.
            $p.RawAction = @($state.ExecActions)[0]
            # Kept in step: Test-PSTSMPlan's WORKDIR and PROGRAM checks read these.
            $p.WorkingDirectory = [string]$p.RawAction.WorkingDirectory
        }
        # Unsupported: the action is not on screen and not in the write. Carried through untouched
        # so nothing downstream has to special-case a plan with a missing one.

        $p.Principal = [ordered]@{
            UserId    = $(if ($txtUser.Text.Trim()) { $txtUser.Text.Trim() } else { $state.BasePlan.Principal.UserId })
            LogonType = (& $getLogonType)
            RunLevel  = $(if ($chkHighest.Checked) { 'Highest' } else { 'Limited' })
        }

        $p.Settings = (& $collectSettings)
        $p.Triggers = @($state.Triggers)
        # No wrapper for a program: transcript logging works by re-pointing the action at a
        # generated .ps1, which would replace the very command line this kind exists to preserve.
        $p.Logging = [ordered]@{ Mode = 'None'; Directory = $null; RetentionDays = 30 }
        $p
    }

    $buildPlan = {
        # Both non-script kinds build from the loaded plan rather than from a script profile:
        # Executable edits its command line, Unsupported carries it through untouched. Neither has
        # a .ps1 for New-PSTSMPlan to start from.
        if ($state.ActionKind -in 'Executable', 'Unsupported') { return & $buildExecPlan }
        if (-not $state.Profile) { return $null }

        $params = [ordered]@{}
        foreach ($name in $state.ParamControls.Keys) {
            $entry = $state.ParamControls[$name]
            $ctl = $entry.Control
            $meta = $entry.Meta

            if ($meta.IsCredential -or $meta.IsSecure) { continue }

            if ($ctl -is [System.Windows.Forms.CheckBox]) {
                $params[$name] = [bool]$ctl.Checked
                continue
            }

            $text = [string]$ctl.Text
            if ([string]::IsNullOrWhiteSpace($text)) { continue }

            if ($meta.TypeName -match '^(Int32|Int64|Int16|Byte)$') {
                $n = 0
                if ([int]::TryParse($text, [ref]$n)) { $params[$name] = $n } else { $params[$name] = $text }
            }
            else {
                $params[$name] = $text
            }
        }

        $engineChoice = $null
        if ($cboEngine.SelectedIndex -ge 0 -and $cboEngine.SelectedIndex -lt $engines.Count) {
            $engineChoice = $engines[$cboEngine.SelectedIndex]
        }

        $logonType = & $getLogonType

        # Start from what the task already had, then overlay only the keys this form actually
        # controls. Rebuilding the hashtable from scratch dropped every setting without a control
        # on screen - RunOnlyIfIdle, AllowDemandStart, DontStopOnIdleEnd, Priority and
        # Compatibility - so opening an existing task and pressing Save silently reset five
        # settings to New-PSTSMPlan's defaults. This is also what $state.Settings is for; it was
        # being seeded from the plan and then never read.
        $settings = & $collectSettings

        $retain = 30
        if (-not [int]::TryParse($txtLogRetain.Text.Trim(), [ref]$retain)) { $retain = 30 }
        $logging = @{
            Mode          = $(if ($cboLogging.SelectedIndex -eq 0) { 'Transcript' } else { 'None' })
            Directory     = $txtLogDir.Text.Trim()
            RetentionDays = $retain
        }

        # NOT $args - that is the automatic parameter-array variable, and shadowing it inside a
        # scriptblock invoked with & is a good way to lose arguments in a way nothing reports.
        $planArgs = @{
            ScriptProfile = $state.Profile
            TaskName      = $txtName.Text.Trim()
            TaskPath      = $(if ($txtFolder.Text.Trim()) { $txtFolder.Text.Trim() } else { '\' })
            Description   = $txtDesc.Text
            Parameters    = $params
            LogonType     = $logonType
            RunLevel      = $(if ($chkHighest.Checked) { 'Highest' } else { 'Limited' })
            Settings      = $settings
            Logging       = $logging
        }
        if ($engineChoice) {
            $planArgs['EngineId'] = $engineChoice.Id
            $planArgs['EnginePath'] = $engineChoice.Path
        }
        if ($txtWorkDir.Text.Trim()) { $planArgs['WorkingDirectory'] = $txtWorkDir.Text.Trim() }
        if ($txtUser.Text.Trim()) { $planArgs['UserId'] = $txtUser.Text.Trim() }
        if ($state.Triggers -and $state.Triggers.Count -gt 0) { $planArgs['Trigger'] = $state.Triggers }

        $p = New-PSTSMPlan @planArgs

        # The form is authoritative for parameters. New-PSTSMPlan seeds the script's declared
        # defaults for scripted callers, but here the controls are already pre-filled with
        # them, so re-seeding would make a deliberately cleared field reappear on the command
        # line with no way to remove it. Clearing a field now means "don't pass it" - the
        # script applies its own default at run time, which is the same result and is honest
        # about where the value came from.
        $p.Parameters = $params

        $p.NoProfile = $chkNoProfile.Checked
        $p.NonInteractive = $chkNonInteractive.Checked
        $p.ExecutionPolicy = [string]$cboExecPolicy.SelectedItem
        $p.WindowStyle = [string]$cboWindowStyle.SelectedItem
        $p.ExtraArguments = $txtExtraArgs.Text.Trim()
        $p
    }

    # Severity column sized to its widest token in the current font; the Check column takes the
    # rest, so nothing truncates until the text genuinely will not fit.
    $sizeCheckColumns = {
        if ($lvChecks.Items.Count -gt 0) {
            # -2 is ListView's own "fit the widest item" sizing. TextRenderer.MeasureText
            # under-measures here because it does not account for the control's internal cell
            # padding, which left 'ERROR' rendering as 'ERR...'.
            $lvChecks.Columns[0].Width = -2
        }
        else {
            $lvChecks.Columns[0].Width = [System.Windows.Forms.TextRenderer]::MeasureText('ERROR', $lvChecks.Font).Width +
            [int]($lvChecks.Font.Height)
        }
        # Reserve room for a vertical scrollbar even when there is not one yet, otherwise the
        # columns overrun the moment the list grows and a horizontal scrollbar appears.
        $rest = $lvChecks.ClientSize.Width - $lvChecks.Columns[0].Width -
        [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth - 2
        if ($rest -gt 40) { $lvChecks.Columns[1].Width = $rest }
    }
    $lvChecks.add_Resize({ if ($sizeCheckColumns) { & $sizeCheckColumns } })

    $refresh = {
        if ($state.Suspend) { return }
        $plan = & $buildPlan
        if (-not $plan) {
            # An empty screen is an invitation to act, not a status report.
            $txtPreview.Text = 'Choose a .ps1 above.' + [Environment]::NewLine + [Environment]::NewLine +
            'The engine, parameters, elevation, working directory and description are read from the' + [Environment]::NewLine +
            'script itself. The exact command that will be registered appears here, and anything that' + [Environment]::NewLine +
            'would break the task unattended appears below it.'
            $lvChecks.Items.Clear()
            $lblChecks.Text = 'Preflight'
            $lblChecks.ForeColor = $t.Accent
            $btnTest.Enabled = $false
            return
        }
        # Deliberately NOT tied to the error count the way Save is. A plan with preflight errors
        # is often exactly the one worth running, because the run explains why. Only a task whose
        # action this tool cannot model is excluded - there is nothing meaningful to run.
        $btnTest.Enabled = -not $state.Locked

        # --- "Run with highest privileges", where it can do nothing --------------------------
        # HighestAvailable is literal: the task runs at the highest privilege AVAILABLE TO ITS
        # PRINCIPAL. For an account that is not an administrator there is no higher level, so the
        # box would be a no-op. Better to grey it out than to let it be ticked and then explain
        # afterwards why it did nothing.
        #
        # It is left ENABLED when already ticked. An existing task may have been created with it
        # on, and disabling the control would trap that setting - the operator could neither keep
        # it deliberately nor turn it off. The preflight warning covers that case instead.
        #
        # Cached per principal: this can reach a domain controller, and $refresh runs on every
        # keystroke in the form.
        $principalNow = "$($plan.Principal.LogonType)|$($plan.Principal.UserId)"
        if ($state.AdminCheckFor -ne $principalNow) {
            $state.AdminCheckFor = $principalNow
            $state.PrincipalIsAdmin = if ($plan.Principal.LogonType -in @('ServiceAccount', 'Group')) {
                $null      # RunLevel is ignored for one and meaningless for the other
            }
            else {
                Test-PSTSMPrincipalIsAdministrator -UserId $plan.Principal.UserId
            }
        }

        if ($false -eq $state.PrincipalIsAdmin -and -not $chkHighest.Checked) {
            $chkHighest.Enabled = $false
            $tipHighest.SetToolTip($chkHighest,
                "$($plan.Principal.UserId) is not an administrator on this machine, so this would " +
                "have no effect - 'highest available' is already their normal privilege level. " +
                'Choose an account that is an administrator to enable it.')
        }
        else {
            $chkHighest.Enabled = $true
            $tipHighest.SetToolTip($chkHighest, '')
        }

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('Program')
        [void]$sb.AppendLine("  $($plan.EnginePath)")
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('Arguments')
        [void]$sb.AppendLine("  $($plan.ArgumentString)")
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("Start in   $($plan.WorkingDirectory)")
        [void]$sb.AppendLine("Run as     $($plan.Principal.UserId)  [$($plan.Principal.LogonType) / $($plan.Principal.RunLevel)]")
        [void]$sb.AppendLine("Task       $($plan.TaskPath)$($plan.TaskName)")
        if ($plan.Logging.Mode -eq 'Transcript') {
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine('The action points at a generated wrapper so each run leaves a transcript')
            [void]$sb.AppendLine("in $($plan.Logging.Directory).")
        }
        $txtPreview.Text = $sb.ToString()

        $lvChecks.BeginUpdate()
        $lvChecks.Items.Clear()
        # -CanElevate: this window does not have to be elevated to save a privileged task, it
        # hands the plan to an elevated helper. Saying so keeps NEEDS_ELEVATION out of the error
        # count, which would otherwise disable the very button that resolves it.
        $checks = @(Test-PSTSMPlan -Plan $plan -CanElevate)

        # The shield is the standard signal that a control leads to a consent prompt. It confers
        # nothing by itself - the elevation still happens in the handler - but it means the prompt
        # is never a surprise. SystemIcons is used rather than BCM_SETSHIELD because that message
        # only draws on FlatStyle=System buttons, and these are FlatStyle=Flat by theme.
        $needsElevation = @(Test-PSTSMPlanNeedsElevation -Plan $plan).Count -gt 0
        $wantShield = $needsElevation -and -not $state.IsElevated
        if ($wantShield -ne [bool]$btnSave.Image) {
            if ($wantShield) {
                # ToBitmap() hands back a NEW bitmap at the icon's native size, and the resizing
                # constructor copies from it rather than taking ownership - so without this the
                # full-size original leaks on every toggle. SystemIcons::Shield itself is a shared
                # static and must not be disposed.
                $raw = [System.Drawing.SystemIcons]::Shield.ToBitmap()
                try { $btnSave.Image = New-Object System.Drawing.Bitmap($raw, 16, 16) }
                finally { $raw.Dispose() }
                $btnSave.ImageAlign = [System.Drawing.ContentAlignment]::MiddleLeft
                $btnSave.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
                $btnSave.TextImageRelation = [System.Windows.Forms.TextImageRelation]::ImageBeforeText
            }
            else {
                if ($btnSave.Image) { $btnSave.Image.Dispose() }
                $btnSave.Image = $null
                $btnSave.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
            }
        }
        $ordered = $checks | Sort-Object @{ Expression = { (Get-PSTSMUISeverityStyle -Severity $_.Severity).Rank } }
        $errorCount = 0
        foreach ($c in $ordered) {
            $style = Get-PSTSMUISeverityStyle -Severity $c.Severity
            if ($c.Severity -eq 'Error') { $errorCount++ }
            $item = New-Object System.Windows.Forms.ListViewItem($style.Token)
            [void]$item.SubItems.Add($c.Title)
            $item.ForeColor = $style.Color
            $item.Tag = $c
            [void]$lvChecks.Items.Add($item)
        }
        $lvChecks.EndUpdate()
        & $sizeCheckColumns

        # The button keeps its name. It used to become the status readout - "1 error(s)",
        # "Cannot save" - which is the wrong job for a control: a button should say what happens
        # when you press it, and keep saying it through the whole flow. The count belongs to the
        # thing being counted, so it goes on the Preflight heading instead.
        # $state.Locked no longer disables Save. It means the ACTION cannot be rewritten, and the
        # save path honours that by editing the registered task in place instead of replacing it -
        # so the schedule, settings and run-as account are still savable.
        $btnSave.Enabled = ($errorCount -eq 0)

        $warnCount = @($checks | Where-Object { $_.Severity -eq 'Warning' }).Count
        $summary = @()
        if ($errorCount -gt 0) { $summary += "$errorCount error$(if ($errorCount -ne 1) { 's' })" }
        if ($warnCount -gt 0) { $summary += "$warnCount warning$(if ($warnCount -ne 1) { 's' })" }

        if ($summary.Count -gt 0) { $lblChecks.Text = "Preflight - $($summary -join ', ')" }
        else { $lblChecks.Text = "Preflight - all clear" }
        $lblChecks.ForeColor = $(if ($errorCount -gt 0) { $t.Danger } else { $t.Accent })

        # A disabled control with no stated reason is a dead end, so say why in a tooltip.
        $tipSave = New-Object System.Windows.Forms.ToolTip
        if ($state.Locked) {
            $tipSave.SetToolTip($btnSave, "Saves the schedule, settings and run-as account. This task's action cannot be modelled by PSTSM, so it is left exactly as it is - change that in Task Scheduler.")
        }
        elseif ($errorCount -gt 0) {
            $tipSave.SetToolTip($btnSave, "Fix the $errorCount blocking issue$(if ($errorCount -ne 1) { 's' }) listed under Preflight first.")
        }
        else {
            $tipSave.SetToolTip($btnSave, '')
        }
    }

    # Coalesces a burst of keystrokes into one refresh.
    #
    # Every text field used to call $refresh directly on TextChanged, so a full preflight ran on
    # each character typed. That is the wrong shape regardless of what the pass costs - typing a
    # 12-character task name meant 12 sequential validations on the UI thread, and WinForms cannot
    # paint while one is running, so the window visibly locked up as you typed.
    #
    # Discrete events (checkboxes, combo selections) still refresh immediately: one action, one
    # result, and nothing to coalesce.
    $refreshTimer = New-Object System.Windows.Forms.Timer
    $refreshTimer.Interval = 200
    # Every handler here is guarded on $refreshTimer for the same reason add_Shown is guarded on
    # $reload in Show-PSTSM: on a -BuildOnly form handed to a harness this function has already
    # returned, the closed-over locals resolve to nothing, and .Stop() on $null throws into the
    # global thread-exception handler rather than failing quietly.
    $refreshTimer.add_Tick({
            # Stop FIRST. A Windows.Forms.Timer repeats until told otherwise, and $refresh below
            # can pump messages - so leaving it running here re-enters this handler on a loop.
            if ($refreshTimer) { $refreshTimer.Stop() }
            if ($refresh) { & $refresh }
        })

    # Restarting the timer is what makes it a debounce: each keystroke pushes the deadline out, so
    # the pass runs once the typing stops rather than once per character.
    $refreshSoon = {
        if ($refreshTimer) { $refreshTimer.Stop(); $refreshTimer.Start() }
        elseif ($refresh) { & $refresh }
    }

    # The form owns the timer; without this it outlives the window and keeps a reference to every
    # control the Tick handler closes over.
    $form.add_FormClosed({
            if ($refreshTimer) {
                $refreshTimer.Stop()
                $refreshTimer.Dispose()
            }
        })

    # Rebuilds the parameter controls for the current script profile.
    $rebuildParams = {
        $paramHost.Controls.Clear()
        $state.ParamControls = [ordered]@{}

        if (-not $state.Profile -or -not $state.Profile.HasParameters) {
            $none = New-PSTSMUILabel -Text 'This script declares no parameters.' -ForeColor $t.Muted
            Add-PSTSMUIStacked -Stack $paramHost -Control $none
            return
        }

        $tbl = New-PSTSMUIFieldTable
        foreach ($meta in $state.Profile.Parameters) {
            # Two variables on purpose. For most parameters they are the same control, but a
            # path-like parameter is a textbox plus a Browse button inside a panel: the panel
            # goes in the row, the textbox holds the value. Do NOT collapse these into one
            # variable and test it with '-is [PSCustomObject]' - that accelerator resolves to
            # PSObject, while [PSCustomObject]@{} produces a PSCustomObject, so the test is
            # always false and the row control comes out null.
            $rowControl = $null
            $valueControl = $null

            if ($meta.IsCredential -or $meta.IsSecure) {
                $box = New-PSTSMUITextBox -ReadOnly
                $box.Text = 'Cannot be supplied on a command line - have the script fetch the secret itself, or use a gMSA.'
                $rowControl = $box
                $valueControl = $box
            }
            elseif ($meta.IsSwitch) {
                $chk = New-Object System.Windows.Forms.CheckBox
                $chk.Text = ''
                $chk.AutoSize = $true
                $chk.Margin = New-Object System.Windows.Forms.Padding(3, 8, 3, 3)
                if ($meta.DefaultValue -and $meta.DefaultValue -match '(?i)\$true') { $chk.Checked = $true }
                $chk.add_CheckedChanged({ & $refresh })
                $rowControl = $chk
                $valueControl = $chk
            }
            elseif ($meta.ValidateSet -and $meta.ValidateSet.Count -gt 0) {
                $cbo = New-Object System.Windows.Forms.ComboBox
                $cbo.Dock = 'Fill'
                $cbo.DropDownStyle = 'DropDownList'
                [void]$cbo.Items.Add('')          # blank = not supplied
                foreach ($v in $meta.ValidateSet) { [void]$cbo.Items.Add($v) }
                $cbo.SelectedIndex = 0
                $cbo.add_SelectedIndexChanged({ & $refresh })
                $rowControl = $cbo
                $valueControl = $cbo
            }
            elseif ($meta.IsPathLike) {
                $panel = New-Object System.Windows.Forms.TableLayoutPanel
                $panel.Dock = 'Top'; $panel.AutoSize = $true; $panel.ColumnCount = 2; $panel.RowCount = 1
                $panel.Margin = New-Object System.Windows.Forms.Padding(0)
                [void]$panel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
                [void]$panel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
                $inner = New-PSTSMUITextBox
                $browse = New-PSTSMUIButton -Text '...' -Width 34
                $browse.Tag = $inner
                $browse.add_Click({
                        $box = $args[0].Tag
                        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
                        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $box.Text = $dlg.SelectedPath }
                        $dlg.Dispose()
                    })
                $inner.add_TextChanged({ & $refreshSoon })
                $panel.Controls.Add($inner, 0, 0)
                $panel.Controls.Add($browse, 1, 0)
                $rowControl = $panel
                $valueControl = $inner
            }
            else {
                $box = New-PSTSMUITextBox
                $box.add_TextChanged({ & $refreshSoon })
                $rowControl = $box
                $valueControl = $box
            }

            # Defaults are handled in two different ways on purpose.
            #
            #   Literal   ('Normal', 14)  - pre-filled as a real VALUE, so the form and the
            #                               command preview agree.
            #   Resolved  ((Join-Path $env:ProgramData 'Acme\Logs'))
            #                             - shown as a greyed CUE, never as a value. The script
            #                               computes it itself at run time; passing it would
            #                               freeze anything time-dependent and hide where the
            #                               value came from. Nothing was executed to work it
            #                               out - see Resolve-PSTSMDefaultValue.
            #   Unresolved                - the source text is shown as the cue, so the operator
            #                               still sees what the script will do.
            if ($meta.HasDefault -and -not $meta.IsSwitch) {
                $kind = [string]$meta.DefaultKind

                if ($kind -eq 'Literal') {
                    $literal = [string]$meta.ResolvedDefault.Value
                    if ($valueControl -is [System.Windows.Forms.ComboBox]) {
                        $i = $valueControl.Items.IndexOf($literal)
                        if ($i -ge 0) { $valueControl.SelectedIndex = $i }
                    }
                    elseif ($valueControl -is [System.Windows.Forms.TextBox] -and -not $valueControl.ReadOnly) {
                        $valueControl.Text = $literal
                    }
                }
                elseif ($valueControl -is [System.Windows.Forms.TextBox] -and -not $valueControl.ReadOnly) {
                    $cue = if ($kind -eq 'Resolved') { [string]$meta.ResolvedDefault.Value } else { [string]$meta.DefaultValue }
                    if ($cue) { Set-PSTSMUICueBanner -TextBox $valueControl -Text $cue }
                }
            }

            $label = $meta.Name
            if ($meta.IsMandatory) { $label = "$label *" }
            Add-PSTSMUIField -Table $tbl -Label $label -Control $rowControl

            if ($meta.IsMandatory) {
                $pos = $tbl.GetPositionFromControl($rowControl)
                $lbl = $tbl.GetControlFromPosition(0, $pos.Row)
                if ($lbl) { $lbl.ForeColor = $t.Accent; $lbl.Font = $t.FontBold }
            }

            $tipLines = @()
            if ($meta.Description) { $tipLines += $meta.Description }
            if ($meta.HasDefault -and $meta.DefaultKind -eq 'Resolved') {
                $tipLines += "Script default: $($meta.ResolvedDefault.Value)"
                $tipLines += "  from  $($meta.DefaultValue)"
                $tipLines += 'Leave blank to let the script work this out itself.'
            }
            elseif ($meta.HasDefault -and $meta.DefaultKind -eq 'Unresolved') {
                $tipLines += "Script default: $($meta.DefaultValue)"
                $tipLines += 'Computed by the script at run time; leave blank to use it.'
            }
            if ($tipLines.Count -gt 0) {
                $tip = New-Object System.Windows.Forms.ToolTip
                $tip.SetToolTip($valueControl, ($tipLines -join [Environment]::NewLine))
            }

            $state.ParamControls[$meta.Name] = @{ Control = $valueControl; Meta = $meta }
        }
        Add-PSTSMUIStacked -Stack $paramHost -Control $tbl
    }

    $refreshTriggers = {
        $lstTrig.Items.Clear()
        if (-not $state.Triggers -or $state.Triggers.Count -eq 0) {
            [void]$lstTrig.Items.Add('(no triggers - the task will only run on demand)')
        }
        else {
            foreach ($spec in $state.Triggers) {
                $desc = switch ($spec.Type) {
                    'Daily' { "Daily at $(([datetime]$spec.At).ToString('HH:mm', [cultureinfo]::InvariantCulture))" + $(if ($spec.DaysInterval -gt 1) { " every $($spec.DaysInterval) days" } else { '' }) }
                    'Weekly' { "Weekly $($spec.DaysOfWeek -join ',') at $(([datetime]$spec.At).ToString('HH:mm', [cultureinfo]::InvariantCulture))" }
                    'Once' { "Once on $(([datetime]$spec.At).ToString('yyyy-MM-dd HH:mm', [cultureinfo]::InvariantCulture))" }
                    'AtStartup' { 'At system startup' }
                    'AtLogOn' { if ($spec.UserId) { "At logon of $($spec.UserId)" } else { 'At any user logon' } }
                    'OnIdle' { 'When the computer is idle' }
                    default { $spec.Type }
                }
                if ($spec.RepetitionInterval) { $desc += " (repeat every $($spec.RepetitionInterval))" }
                if ($spec.RandomDelay) { $desc += " [+ up to $($spec.RandomDelay) random]" }
                if ($spec.Delay) { $desc += " [after $($spec.Delay)]" }
                if (-not $spec.Enabled) { $desc += '  - DISABLED' }
                [void]$lstTrig.Items.Add($desc)
            }
        }
        & $refresh
    }

    # Loads a script and repopulates every derived field.
    $loadScript = {
        param($path)
        try {
            $prof = Get-PSTSMScriptProfile -Path $path
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Cannot read script',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $state.Profile = $prof
        $state.Suspend = $true

        $bits = @()
        $bits += "Engine: $($prof.EngineId) ($($prof.EngineConfidence.ToLowerInvariant()) - $($prof.EngineReason))"
        if ($prof.RequiresElevation) { $bits += 'Requires elevation' }
        if ($prof.RequiredModules.Count -gt 0) { $bits += "Modules: $(($prof.RequiredModules | ForEach-Object { $_.Name }) -join ', ')" }
        if (-not $prof.IsParseable) { $bits += 'SCRIPT DOES NOT PARSE' }
        $lblDerived.Text = $bits -join '   |   '

        if (-not $txtName.Text.Trim()) { $txtName.Text = $prof.SuggestedTaskName }
        if (-not $txtDesc.Text.Trim() -and $prof.Synopsis) { $txtDesc.Text = $prof.Synopsis }
        if (-not $txtWorkDir.Text.Trim()) { $txtWorkDir.Text = $prof.SuggestedWorkDir }
        if (-not $txtLogDir.Text.Trim()) { $txtLogDir.Text = (Join-Path $prof.Directory 'Logs') }
        if ($prof.RequiresElevation) { $chkHighest.Checked = $true }

        # Select the engine the script asked for, preferring 64-bit.
        $wanted = @($engines | Where-Object { $_.Id -eq $prof.EngineId })
        $pick = @($wanted | Where-Object { $_.Bitness -eq 'x64' } | Select-Object -First 1)
        if (-not $pick) { $pick = @($wanted | Select-Object -First 1) }
        if ($pick) {
            $idx = [array]::IndexOf($engines, $pick[0])
            if ($idx -ge 0) { $cboEngine.SelectedIndex = $idx }
        }

        & $rebuildParams
        $state.Suspend = $false
        & $refresh
    }

    # Keeps the left pane from growing sideways. It is a vertically-scrolling column, but every
    # AutoSize label in it reports whatever width its text wants - and the derived-engine line
    # ("Engine: ... | Modules: a, b, c, d, e") is easily 1000px for a script with several
    # #Requires -Modules. That widened the whole stack and pushed the Browse button off the
    # right edge, which only showed up on the SECOND script picked, because the first happened
    # to have a short line.
    #
    # Capping MaximumSize makes such labels wrap instead of widen. It is applied to the stack
    # as well, so any control added later cannot reintroduce this.
    $fitLeftPane = {
        if (-not $leftScroll -or $leftScroll.IsDisposed) { return }
        $w = $leftScroll.ClientSize.Width - [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth - 2
        if ($w -lt 200) { return }
        $cap = New-Object System.Drawing.Size($w, 0)     # 0 height = unbounded, grow downward
        $leftStack.MaximumSize = $cap
        $lblDerived.MaximumSize = $cap
    }
    $leftScroll.add_Resize({ if ($fitLeftPane) { & $fitLeftPane } })

    # --- wiring ----------------------------------------------------------------------
    $btnBrowseScript.add_Click({
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Filter = 'PowerShell scripts (*.ps1)|*.ps1|All files (*.*)|*.*'
            $dlg.Title = 'Select the script this task will run'
            if ($txtScript.Text -and (Test-Path -LiteralPath $txtScript.Text)) {
                $dlg.InitialDirectory = Split-Path $txtScript.Text -Parent
            }
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $txtScript.Text = $dlg.FileName
                & $loadScript $dlg.FileName
            }
            $dlg.Dispose()
        })

    $chkAdvanced.add_CheckedChanged({ $secAdv.Container.Visible = $chkAdvanced.Checked })

    $btnTrigAdd.add_Click({
            $spec = Show-PSTSMTriggerDialog -Owner $form
            if ($spec) {
                $state.Triggers = $state.Triggers + $spec
                & $refreshTriggers
            }
        })

    $btnTrigEdit.add_Click({
            $i = $lstTrig.SelectedIndex
            if ($i -lt 0 -or $i -ge $state.Triggers.Count) { return }
            $spec = Show-PSTSMTriggerDialog -Trigger $state.Triggers[$i] -Owner $form
            if ($spec) {
                $copy = @($state.Triggers)
                $copy[$i] = $spec
                $state.Triggers = $copy
                & $refreshTriggers
            }
        })

    $btnTrigDel.add_Click({
            $i = $lstTrig.SelectedIndex
            if ($i -lt 0 -or $i -ge $state.Triggers.Count) { return }
            $keep = @()
            for ($n = 0; $n -lt $state.Triggers.Count; $n++) { if ($n -ne $i) { $keep += $state.Triggers[$n] } }
            $state.Triggers = $keep
            & $refreshTriggers
        })

    $lstTrig.add_DoubleClick({ $btnTrigEdit.PerformClick() })

    $lvChecks.add_SelectedIndexChanged({
            if ($lvChecks.SelectedItems.Count -eq 0) { $txtCheckDetail.Text = ''; return }
            $c = $lvChecks.SelectedItems[0].Tag
            $lines = @("$($c.Severity.ToUpperInvariant()): $($c.Title)")
            if ($c.Detail) { $lines += ''; $lines += $c.Detail }
            if ($c.Recommendation) { $lines += ''; $lines += "-> $($c.Recommendation)" }
            $txtCheckDetail.Text = ($lines -join [Environment]::NewLine)
        })

    foreach ($c in @($txtName, $txtFolder, $txtDesc, $txtWorkDir, $txtUser, $txtTimeLimit,
            $txtRestartCount, $txtRestartInterval, $txtLogDir, $txtLogRetain, $txtExtraArgs)) {
        $c.add_TextChanged({ & $refreshSoon })
    }
    # $cboAccountType is deliberately absent: it has its own handler that re-populates $cboWhen
    # before refreshing, and adding a second handler here would refresh against a stale pair.
    foreach ($c in @($cboEngine, $cboWhen, $cboInstances, $cboLogging, $cboExecPolicy, $cboWindowStyle)) {
        $c.add_SelectedIndexChanged({ & $refresh })
    }
    foreach ($c in @($chkHighest, $chkStartWhenAvail, $chkBatteryStop, $chkNetwork, $chkWake,
            $chkHidden, $chkNoProfile, $chkNonInteractive)) {
        $c.add_CheckedChanged({ & $refresh })
    }

    # --- action bar --------------------------------------------------------------------
    # Sits beside Export because both act on the plan as it stands rather than committing it.
    # Named for what it does - it really runs the script - rather than "Check" or "Validate",
    # which would imply something safe and read-only that this is not.
    $btnTest = New-PSTSMUIButton -Text 'Test run' -Width 100
    $btnExport = New-PSTSMUIButton -Text 'Export plan...' -Width 118
    # Named for what it does, once, and it never changes afterwards.
    $btnSave = New-PSTSMUIButton -Text $(if ($state.IsEdit) { 'Save changes' } else { 'Create task' }) -Primary -Width 130
    $btnCancel = New-PSTSMUIButton -Text 'Cancel'

    $btnExport.add_Click({
            $plan = & $buildPlan
            if (-not $plan) { return }
            $dlg = New-Object System.Windows.Forms.SaveFileDialog
            $dlg.Filter = 'Task plan (*.json)|*.json'
            $dlg.FileName = "$($plan.TaskName).task.json"
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                try {
                    Export-PSTSMPlan -Plan $plan -Path $dlg.FileName
                    [System.Windows.Forms.MessageBox]::Show("Saved to $($dlg.FileName)", 'Plan exported',
                        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
                }
                catch {
                    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Export failed',
                        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                }
            }
            $dlg.Dispose()
        })

    $btnSave.add_Click({
            $plan = & $buildPlan
            if (-not $plan) { return }

            # Renaming an existing task creates a new one; remove the old registration so the
            # edit does not silently leave a duplicate behind.
            $renamed = $state.IsEdit -and
                       (($state.OriginalName -ne $plan.TaskName) -or ($state.OriginalPath -ne $plan.TaskPath))

            # An Unsupported action cannot be re-created from the plan, which is the whole reason
            # this mode exists - so the save edits the registered task in place instead.
            $scheduleOnly = ($state.ActionKind -eq 'Unsupported')

            if ($scheduleOnly -and $renamed) {
                # Renaming means create-then-delete, and the "create" half would have to rebuild an
                # action nothing here can rebuild. Refused explicitly rather than half-done: the
                # alternative is a new task missing the action and the original deleted.
                [System.Windows.Forms.MessageBox]::Show(
                    ("This task's action cannot be re-created by PSTSM, so it can only be edited where it is - " +
                    "renaming or moving it would mean building a new task around an action this tool cannot model.`n`n" +
                    "Put the name and folder back to '$($state.OriginalPath)$($state.OriginalName)' to save your other changes, " +
                    'or rename it in Task Scheduler.'),
                    'Cannot rename this task', [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                return
            }

            $needsElevation = @(Test-PSTSMPlanNeedsElevation -Plan $plan).Count -gt 0

            if ($needsElevation -and -not $state.IsElevated) {
                # Elevate for this one registration rather than for the whole session. Windows
                # cannot raise the privileges of a running process, so "elevate on save" means
                # handing the finished plan to a short-lived elevated helper - which is also what
                # keeps everything typed into this window if the operator declines the prompt.
                $prev = $form.Cursor
                $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
                try {
                    $elevArgs = @{ Plan = $plan; Confirm = $false }
                    if ($scheduleOnly) { $elevArgs['ScheduleOnly'] = $true }
                    if ($renamed) {
                        $elevArgs['RemoveTaskName'] = $state.OriginalName
                        $elevArgs['RemoveTaskPath'] = $state.OriginalPath
                    }
                    $outcome = Invoke-PSTSMElevatedRegistration @elevArgs
                }
                finally { $form.Cursor = $prev }

                # Declining the prompt is a decision, not an error. Say nothing and leave the
                # window exactly as it was so the choice can be revisited or changed.
                if ($outcome.Cancelled) { return }

                if (-not $outcome.Success) {
                    [System.Windows.Forms.MessageBox]::Show($outcome.Error, 'Could not register the task',
                        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                    return
                }

                foreach ($w in @($outcome.Warnings)) {
                    [System.Windows.Forms.MessageBox]::Show($w, 'Saved, with one thing to note',
                        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                }
            }
            else {
                $password = $null
                if ($plan.Principal.LogonType -eq 'Password') {
                    $cred = $host.UI.PromptForCredential('Task account password',
                        "Enter the password for $($plan.Principal.UserId). It is handed straight to Task Scheduler and never stored in the plan.",
                        $plan.Principal.UserId, '')
                    if (-not $cred) { return }
                    $password = $cred.Password
                }

                try {
                    # Update-PSTSMTaskSchedule leaves the action out of the write entirely; the
                    # register path replaces the whole task. Which one runs is decided by whether
                    # the action can be rebuilt, not by what the operator changed.
                    $writeArgs = @{ Plan = $plan; Confirm = $false }
                    if ($password) { $writeArgs['Password'] = $password }
                    if ($scheduleOnly) { Update-PSTSMTaskSchedule @writeArgs | Out-Null }
                    else { Register-PSTSMPlan @writeArgs }

                    if ($renamed) {
                        try {
                            Unregister-ScheduledTask -TaskName $state.OriginalName -TaskPath $state.OriginalPath -Confirm:$false -ErrorAction Stop
                        }
                        catch {
                            [System.Windows.Forms.MessageBox]::Show(
                                "The task was saved as '$($plan.TaskName)', but the original '$($state.OriginalName)' could not be removed:`n$($_.Exception.Message)",
                                'Old task still present', [System.Windows.Forms.MessageBoxButtons]::OK,
                                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                        }
                    }
                }
                catch {
                    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Could not register the task',
                        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                    return
                }
            }

            $state.SavedPlan = $plan
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        })

    $btnCancel.add_Click({
            $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
            $form.Close()
        })

    $btnTest.add_Click({
            $plan = & $buildPlan
            if (-not $plan) { return }
            # The action on screen, not always the first: for a multi-program task the operator is
            # asking about the one they are looking at.
            $idx = if ($state.ActionKind -eq 'Executable') { [int]$state.ExecIndex } else { 0 }
            Show-PSTSMTestRun -Plan $plan -ActionIndex $idx -Owner $form
        })

    $bar = New-PSTSMUIActionBar -LeftButton @($btnTest, $btnExport) -RightButton @($btnCancel, $btnSave)

    $root.Controls.Add($leftScroll, 0, 0)
    $root.Controls.Add($rightCol, 1, 0)
    $root.Controls.Add($bar, 0, 1)
    $root.SetColumnSpan($bar, 2)
    [void]$form.Controls.Add($root)
    $form.CancelButton = $btnCancel

    # --- seed defaults ------------------------------------------------------------------
    $cboAccountType.SelectedIndex = 0
    & $applyAccountType

    # Show the account that will actually be used. New-PSTSMPlan falls back to the current user
    # when this is blank, so leaving the box empty made the form disagree with its own preview -
    # the preview named an account the form did not show.
    $txtUser.Text = "$env:USERDOMAIN\$env:USERNAME"

    $cboAccountType.add_SelectedIndexChanged({
            & $applyAccountType

            # SYSTEM is the only sensible default for a built-in principal, so offer it - but
            # never overwrite an account the operator typed themselves.
            $typeKeys = @($accountTypes.Keys)
            if ($cboAccountType.SelectedIndex -lt 0) { return }
            $type = $typeKeys[$cboAccountType.SelectedIndex]
            if ($type -eq 'BuiltIn' -and $txtUser.Text -eq "$env:USERDOMAIN\$env:USERNAME") {
                $txtUser.Text = 'SYSTEM'
            }
            elseif ($type -ne 'BuiltIn' -and $txtUser.Text -eq 'SYSTEM') {
                $txtUser.Text = "$env:USERDOMAIN\$env:USERNAME"
            }
            & $refresh
        })

    $btnPickAccount.add_Click({
            # Open the picker on the tab matching the current choice, so someone who already
            # selected gMSA is not shown every user in the domain.
            $typeKeys = @($accountTypes.Keys)
            $current = if ($cboAccountType.SelectedIndex -ge 0) { $typeKeys[$cboAccountType.SelectedIndex] } else { 'All' }
            $initial = switch ($current) {
                'gMSA' { 'gMSA' }
                'BuiltIn' { 'BuiltIn' }
                'User' { 'User' }
                default { 'All' }
            }

            $picked = Show-PSTSMAccountPicker -InitialType $initial -Owner $form
            if (-not $picked) { return }

            $txtUser.Text = $picked.Name

            # Move both controls together. Picking a gMSA and leaving the type on User/S4U
            # produces a task that cannot register.
            $newType = switch ($picked.SuggestedLogonType) {
                'gMSA' { 'gMSA' }
                'ServiceAccount' { 'BuiltIn' }
                'Group' { 'Group' }
                default { 'User' }
            }
            $ti = [array]::IndexOf($typeKeys, $newType)
            if ($ti -ge 0) { $cboAccountType.SelectedIndex = $ti }
            & $applyAccountType

            if ($newType -eq 'User') {
                $wi = [array]::IndexOf(@($whenChoicesForUser.Keys), $picked.SuggestedLogonType)
                if ($wi -ge 0) { $cboWhen.SelectedIndex = $wi }
            }
            & $refresh
        })

    $cboInstances.SelectedItem = 'IgnoreNew'
    $cboLogging.SelectedIndex = 0
    $cboExecPolicy.SelectedItem = 'Bypass'
    $cboWindowStyle.SelectedItem = 'Hidden'
    $chkNoProfile.Checked = $true
    $chkNonInteractive.Checked = $true
    $chkStartWhenAvail.Checked = $true
    $txtTimeLimit.Text = '04:00:00'
    $txtRestartCount.Text = '3'
    $txtRestartInterval.Text = '00:05:00'
    $txtLogRetain.Text = '30'

    if ($Plan) {
        $txtName.Text = $Plan.TaskName
        $txtFolder.Text = $Plan.TaskPath
        $txtDesc.Text = [string]$Plan.Description
        $txtWorkDir.Text = [string]$Plan.WorkingDirectory
        $txtUser.Text = [string]$Plan.Principal.UserId
        $txtExtraArgs.Text = [string]$Plan.ExtraArguments

        # Split the plan's single LogonType back into the account-type / when pair.
        $existingLogon = [string]$Plan.Principal.LogonType
        $existingType = switch ($existingLogon) {
            'gMSA' { 'gMSA' }
            'ServiceAccount' { 'BuiltIn' }
            'Group' { 'Group' }
            default { 'User' }
        }
        $ti = [array]::IndexOf(@($accountTypes.Keys), $existingType)
        if ($ti -ge 0) { $cboAccountType.SelectedIndex = $ti }
        & $applyAccountType
        if ($existingType -eq 'User') {
            $wi = [array]::IndexOf(@($whenChoicesForUser.Keys), $existingLogon)
            if ($wi -ge 0) { $cboWhen.SelectedIndex = $wi }
        }

        $chkHighest.Checked = ($Plan.Principal.RunLevel -eq 'Highest')

        $s = $Plan.Settings
        if ($s.MultipleInstances) { $cboInstances.SelectedItem = [string]$s.MultipleInstances }
        $chkStartWhenAvail.Checked = [bool]$s.StartWhenAvailable
        $chkBatteryStop.Checked = [bool]$s.DisallowStartIfOnBatteries
        $chkNetwork.Checked = [bool]$s.RunOnlyIfNetworkAvailable
        $chkWake.Checked = [bool]$s.WakeToRun
        $chkHidden.Checked = [bool]$s.Hidden
        if ($s.ExecutionTimeLimit) { $txtTimeLimit.Text = [string]$s.ExecutionTimeLimit }
        $txtRestartCount.Text = [string]$s.RestartCount
        if ($s.RestartInterval) { $txtRestartInterval.Text = [string]$s.RestartInterval }

        $cboLogging.SelectedIndex = $(if ($Plan.Logging.Mode -eq 'Transcript') { 0 } else { 1 })
        $txtLogDir.Text = [string]$Plan.Logging.Directory
        $txtLogRetain.Text = [string]$Plan.Logging.RetentionDays

        $chkNoProfile.Checked = [bool]$Plan.NoProfile
        $chkNonInteractive.Checked = [bool]$Plan.NonInteractive
        if ($Plan.ExecutionPolicy) { $cboExecPolicy.SelectedItem = [string]$Plan.ExecutionPolicy }
        if ($Plan.WindowStyle) { $cboWindowStyle.SelectedItem = [string]$Plan.WindowStyle }
    }

    if ($ScriptPath -and (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        & $loadScript $ScriptPath

        # Existing plans carry their own parameter values; apply them over the derived controls.
        if ($Plan -and $Plan.Parameters) {
            $state.Suspend = $true
            foreach ($k in $Plan.Parameters.Keys) {
                if (-not $state.ParamControls.Contains($k)) { continue }
                $ctl = $state.ParamControls[$k].Control
                $v = $Plan.Parameters[$k]
                if ($ctl -is [System.Windows.Forms.CheckBox]) { $ctl.Checked = [bool]$v }
                elseif ($ctl -is [System.Windows.Forms.ComboBox]) {
                    $i = $ctl.Items.IndexOf([string]$v)
                    if ($i -ge 0) { $ctl.SelectedIndex = $i }
                }
                else { $ctl.Text = [string]$v }
            }
            $state.Suspend = $false
        }
    }
    else {
        $lblDerived.Text = 'Choose a .ps1 - the engine, parameters, elevation and working directory fill themselves in.'
    }

    $state.Suspend = $false
    & $fitLeftPane
    & $refreshTriggers

    if ($state.ActionKind -eq 'Executable') {
        # A bare command line. Task Scheduler's own model for this action is exactly three fields,
        # and all three are here and editable - so this round-trips more strictly than the script
        # form does, because nothing is regenerated from parsed pieces.
        $state.Suspend = $true

        # Working copies, so Cancel leaves the loaded plan untouched.
        $state.ExecActions = @(
            foreach ($a in @($Plan.RawActions)) {
                [ordered]@{
                    Execute          = [string]$a.Execute
                    Arguments        = [string]$a.Arguments
                    WorkingDirectory = [string]$a.WorkingDirectory
                    Summary          = [string]$a.Summary
                }
            }
        )
        if (@($state.ExecActions).Count -eq 0) {
            $state.ExecActions = @([ordered]@{
                    Execute          = [string]$Plan.RawAction.Execute
                    Arguments        = [string]$Plan.RawAction.Arguments
                    WorkingDirectory = [string]$Plan.RawAction.WorkingDirectory
                    Summary          = [string]$Plan.RawAction.Summary
                })
        }

        $count = @($state.ExecActions).Count
        $secScript.Header.Text = if ($count -gt 1) { "Programs ($count)" } else { 'Program' }
        $lblDerived.Text = if ($count -gt 1) {
            "This task runs $count programs in order. Pick one above to edit it; all of them are " +
            'written back exactly as you leave them.'
        }
        else {
            'This task runs a program directly rather than a PowerShell script. ' +
            'The three fields below are written back exactly as you leave them.'
        }
        $lblDerived.Visible = $true

        if ($cboExecAction) {
            [void]$cboExecAction.Items.Clear()
            for ($i = 0; $i -lt $count; $i++) {
                $leaf = try { [System.IO.Path]::GetFileName(([string]$state.ExecActions[$i].Execute).Trim('"', ' ')) } catch { '' }
                if (-not $leaf) { $leaf = '(no program)' }
                [void]$cboExecAction.Items.Add(("{0} of {1}:  {2}" -f ($i + 1), $count, $leaf))
            }
            $cboExecAction.SelectedIndex = 0
            $cboExecAction.add_SelectedIndexChanged({
                    if (-not $cboExecAction -or -not $showExecAction) { return }
                    # Save what is on screen into the action being left, THEN load the new one.
                    if ($captureExecFields) { & $captureExecFields }
                    & $showExecAction $cboExecAction.SelectedIndex
                    if ($refresh) { & $refresh }
                })
        }

        & $showExecAction 0

        # Browse filters for .ps1, which is the wrong picker for a program.
        $btnBrowseScript.Visible = $false

        # Everything that only means something to a PowerShell host. Left visible but disabled, so
        # it stays obvious WHY the option is unavailable rather than the section quietly changing
        # shape between task types.
        foreach ($c in @($cboEngine, $cboExecPolicy, $cboWindowStyle, $chkNoProfile, $chkNonInteractive,
                $cboLogging, $txtLogDir, $txtLogRetain)) {
            if ($c) { $c.Enabled = $false }
        }

        $paramHost.Controls.Clear()
        $noParams = New-PSTSMUILabel -Text 'Arguments for a program are a single command line, edited above.' -ForeColor $t.Muted
        Add-PSTSMUIStacked -Stack $paramHost -Control $noParams

        # Test-run works here too, and is a stricter reproduction than it is for a script: what runs
        # is character-for-character the command line on screen, with nothing re-quoted. For a task
        # with several programs it runs the one currently selected, not all of them - running three
        # because someone wanted to check the second is not a favour.
        $tipTest = New-Object System.Windows.Forms.ToolTip
        $tipTest.SetToolTip($btnTest, $(if ($count -gt 1) {
                    'Runs the selected program once, as you, and shows what it printed. The other programs are not run.'
                }
                else { 'Runs this program once, as you, and shows what it printed.' }))

        $state.Suspend = $false
        & $refresh
    }

    if ($state.Locked) {
        # Read-only view. Say what the task actually runs - for a COM handler there is no
        # command line at all, so RawAction.Summary carries the description instead of three
        # empty strings.
        # RawAction is an ordered DICTIONARY, so PSObject.Properties[...] finds nothing on it -
        # that guard silently failed and every COM-handler task reported "(nothing recorded)"
        # even though the summary was sitting right there. Plain member access works.
        $what = [string]$Plan.RawAction.Summary
        if (-not $what) { $what = (@($Plan.RawAction.Execute, $Plan.RawAction.Arguments) | Where-Object { $_ }) -join ' ' }
        if (-not $what) { $what = '(nothing recorded)' }

        $txtPreview.Text = "This task's ACTION is read-only. Its schedule is not." + [Environment]::NewLine + [Environment]::NewLine +
        'It runs:' + [Environment]::NewLine +
        "  $what" + [Environment]::NewLine + [Environment]::NewLine +
        'Why the action cannot be changed here:' + [Environment]::NewLine +
        (@($Plan.ParseNotes) | ForEach-Object { "  - $_" }) -join [Environment]::NewLine +
        [Environment]::NewLine + [Environment]::NewLine +
        'PSTSM only rewrites actions it can model exactly, so it will not touch this one. Saving' + [Environment]::NewLine +
        'edits the registered task in place - triggers, settings and the run-as account - and' + [Environment]::NewLine +
        'leaves the action out of the write entirely. To change what it runs, use Task Scheduler.' + [Environment]::NewLine + [Environment]::NewLine +
        'The name and folder are fixed too: renaming means creating a new task, which would mean' + [Environment]::NewLine +
        'rebuilding this action.'

        # The action is not editable, so the controls that describe it must not invite edits.
        foreach ($c in @($txtScript, $btnBrowseScript, $txtExtraArgs, $cboEngine, $cboExecPolicy,
                $cboWindowStyle, $chkNoProfile, $chkNonInteractive, $cboLogging, $txtLogDir, $txtLogRetain,
                $txtName, $txtFolder)) {
            if ($c) { $c.Enabled = $false }
        }
        & $refresh
    }

    if ($BuildOnly) { return $form }

    if ($SelfTest) {
        # Shown from inside this function so the handlers' locals are still on the stack,
        # exactly as they are under ShowDialog.
        Show-PSTSMUIForTest -Form $form
        for ($i = 0; $i -lt 40; $i++) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 15
        }
        $form.Close()
        $form.Dispose()
        return $null
    }

    if ($Owner) { [void]$form.ShowDialog($Owner) } else { [void]$form.ShowDialog() }
    $result = $state.SavedPlan
    $form.Dispose()
    $result
}
