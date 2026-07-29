function Show-PSTaskEditor {
    <#
    .SYNOPSIS
        The create/edit window: pick a script, everything derivable fills itself in, change
        anything you disagree with, see the exact command and the preflight before saving.
    .DESCRIPTION
        Left pane is the form, right pane is a live preview plus preflight. Every control edit
        rebuilds the plan and refreshes both, so what you read on the right is always what
        Register-PSTaskPlan would write - there is no separate "generate" step to fall out of
        sync.

        The parameter section is generated from the script's own param() block: switches become
        checkboxes, ValidateSet becomes a combo box, path-like parameters get a Browse button,
        and mandatory ones are marked and enforced by the preflight.

        Opening an existing task (-Plan from ConvertFrom-PSTaskDefinition) uses the same form.
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
        Test seam. Shows the window minimised, pumps the message loop briefly, then closes it -
        all inside this function, so handlers still see their locals. This is the only way to
        catch show-time failures; DrawToBitmap renders chrome and misses them entirely.
    .OUTPUTS
        [pscustomobject] the saved plan, or $null if cancelled.
        [System.Windows.Forms.Form] when -BuildOnly is used.
    .EXAMPLE
        Show-PSTaskEditor -ScriptPath 'D:\Scripts\Send-Report.ps1'
    .EXAMPLE
        Show-PSTaskEditor -Plan (ConvertFrom-PSTaskDefinition -TaskName 'Nightly' -TaskPath '\Custom\')
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

    Initialize-PSTaskUIHost
    $t = Get-PSTaskUITheme

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
        Locked        = $false     # existing task whose action we must not rewrite
        OriginalName  = $null
        OriginalPath  = $null
    }

    if ($Plan) {
        $ScriptPath = $Plan.ScriptPath
        $state.Settings = $Plan.Settings
        $state.Logging = $Plan.Logging
        $state.Triggers = @($Plan.Triggers)
        $state.OriginalName = $Plan.TaskName
        $state.OriginalPath = $Plan.TaskPath
        if ($Plan.PSObject.Properties['IsFullyRecognized'] -and -not $Plan.IsFullyRecognized) { $state.Locked = $true }
    }

    $title = if ($Plan) { "Edit task - $($Plan.TaskName)" } else { 'New scheduled task' }
    $form = New-PSTaskUIForm -Title $title -Width 1180 -Height 780

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
    $secScript = New-PSTaskUISection -Title 'Script'
    $txtScript = New-PSTaskUITextBox -Text $ScriptPath
    $btnBrowseScript = New-PSTaskUIButton -Text 'Browse...' -Width 90

    $scriptRow = New-Object System.Windows.Forms.TableLayoutPanel
    $scriptRow.Dock = 'Top'; $scriptRow.AutoSize = $true; $scriptRow.ColumnCount = 2; $scriptRow.RowCount = 1
    [void]$scriptRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$scriptRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $scriptRow.Controls.Add($txtScript, 0, 0)
    $scriptRow.Controls.Add($btnBrowseScript, 1, 0)
    Add-PSTaskUIStacked -Stack $secScript.Content -Control $scriptRow

    $lblDerived = New-PSTaskUILabel -Text '' -ForeColor $t.Muted
    Add-PSTaskUIStacked -Stack $secScript.Content -Control $lblDerived
    Add-PSTaskUIStacked -Stack $leftStack -Control $secScript.Container

    # --- task identity --------------------------------------------------------------
    $secTask = New-PSTaskUISection -Title 'Task'
    $tblTask = New-PSTaskUIFieldTable
    $txtName = New-PSTaskUITextBox
    $txtFolder = New-PSTaskUITextBox -Text '\'
    $txtDesc = New-PSTaskUITextBox
    Add-PSTaskUIField -Table $tblTask -Label 'Name' -Control $txtName
    Add-PSTaskUIField -Table $tblTask -Label 'Folder' -Control $txtFolder
    Add-PSTaskUIField -Table $tblTask -Label 'Description' -Control $txtDesc
    Add-PSTaskUIStacked -Stack $secTask.Content -Control $tblTask
    Add-PSTaskUIStacked -Stack $leftStack -Control $secTask.Container

    # --- engine ---------------------------------------------------------------------
    $secEngine = New-PSTaskUISection -Title 'Engine'
    $tblEngine = New-PSTaskUIFieldTable
    $cboEngine = New-Object System.Windows.Forms.ComboBox
    $cboEngine.Dock = 'Fill'; $cboEngine.DropDownStyle = 'DropDownList'
    $engines = @(Get-PSTaskEngine)
    foreach ($e in $engines) { [void]$cboEngine.Items.Add($e.DisplayName) }
    $txtWorkDir = New-PSTaskUITextBox
    Add-PSTaskUIField -Table $tblEngine -Label 'Run with' -Control $cboEngine
    Add-PSTaskUIField -Table $tblEngine -Label 'Start in' -Control $txtWorkDir
    Add-PSTaskUIStacked -Stack $secEngine.Content -Control $tblEngine
    Add-PSTaskUIStacked -Stack $leftStack -Control $secEngine.Container

    # --- parameters -----------------------------------------------------------------
    $secParams = New-PSTaskUISection -Title 'Parameters'
    $paramHost = New-Object System.Windows.Forms.TableLayoutPanel
    $paramHost.Dock = 'Top'; $paramHost.AutoSize = $true; $paramHost.AutoSizeMode = 'GrowAndShrink'; $paramHost.ColumnCount = 1
    Add-PSTaskUIStacked -Stack $secParams.Content -Control $paramHost
    Add-PSTaskUIStacked -Stack $leftStack -Control $secParams.Container

    # --- triggers -------------------------------------------------------------------
    $secTrig = New-PSTaskUISection -Title 'Schedule'
    $lstTrig = New-Object System.Windows.Forms.ListBox
    # Sized in rows of the actual font rather than pixels, so it still shows ~5 triggers at any
    # display scale instead of clipping to two and a half.
    $lstTrig.Height = [int]($t.FontBase.Height * 5.5)
    $lstTrig.Dock = 'Top'
    $lstTrig.BorderStyle = 'FixedSingle'
    $lstTrig.IntegralHeight = $false
    $btnTrigAdd = New-PSTaskUIButton -Text 'Add...' -Width 80
    $btnTrigEdit = New-PSTaskUIButton -Text 'Edit...' -Width 80
    $btnTrigDel = New-PSTaskUIButton -Text 'Remove' -Width 80
    $trigBar = New-Object System.Windows.Forms.FlowLayoutPanel
    $trigBar.Dock = 'Top'; $trigBar.AutoSize = $true; $trigBar.WrapContents = $false
    foreach ($b in @($btnTrigAdd, $btnTrigEdit, $btnTrigDel)) { [void]$trigBar.Controls.Add($b) }
    Add-PSTaskUIStacked -Stack $secTrig.Content -Control $lstTrig
    Add-PSTaskUIStacked -Stack $secTrig.Content -Control $trigBar
    Add-PSTaskUIStacked -Stack $leftStack -Control $secTrig.Container

    # --- principal ------------------------------------------------------------------
    $secWho = New-PSTaskUISection -Title 'Run as'
    $tblWho = New-PSTaskUIFieldTable
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
    $txtUser = New-PSTaskUITextBox
    $chkHighest = New-Object System.Windows.Forms.CheckBox
    $chkHighest.Text = 'Run with highest privileges'
    $chkHighest.AutoSize = $true
    # Browse, not "Create gMSA" - picking an account that already exists is the normal case.
    # The picker covers gMSAs, user/service accounts and the built-in principals, sets the
    # matching logon type, and offers creation as a side door for the rarer case.
    $btnPickAccount = New-PSTaskUIButton -Text 'Browse...' -Width 96
    $acctRow = New-Object System.Windows.Forms.TableLayoutPanel
    $acctRow.Dock = 'Top'; $acctRow.AutoSize = $true; $acctRow.ColumnCount = 2; $acctRow.RowCount = 1
    $acctRow.Margin = New-Object System.Windows.Forms.Padding(0)
    [void]$acctRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$acctRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $acctRow.Controls.Add($txtUser, 0, 0)
    $acctRow.Controls.Add($btnPickAccount, 1, 0)

    Add-PSTaskUIField -Table $tblWho -Label 'Account type' -Control $cboAccountType
    Add-PSTaskUIField -Table $tblWho -Label 'Account' -Control $acctRow
    Add-PSTaskUIField -Table $tblWho -Label 'When' -Control $cboWhen
    Add-PSTaskUIField -Table $tblWho -Label '' -Control $chkHighest
    Add-PSTaskUIStacked -Stack $secWho.Content -Control $tblWho
    Add-PSTaskUIStacked -Stack $leftStack -Control $secWho.Container

    # --- advanced -------------------------------------------------------------------
    $chkAdvanced = New-Object System.Windows.Forms.CheckBox
    $chkAdvanced.Text = 'Show advanced settings'
    $chkAdvanced.AutoSize = $true
    $chkAdvanced.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)
    Add-PSTaskUIStacked -Stack $leftStack -Control $chkAdvanced

    $secAdv = New-PSTaskUISection -Title 'Reliability, logging and engine switches'
    $secAdv.Container.Visible = $false
    $tblAdv = New-PSTaskUIFieldTable

    $cboInstances = New-Object System.Windows.Forms.ComboBox
    $cboInstances.Dock = 'Fill'; $cboInstances.DropDownStyle = 'DropDownList'
    foreach ($x in @('IgnoreNew', 'Parallel', 'Queue', 'StopExisting')) { [void]$cboInstances.Items.Add($x) }
    $txtTimeLimit = New-PSTaskUITextBox
    $txtRestartCount = New-PSTaskUITextBox
    $txtRestartInterval = New-PSTaskUITextBox
    $chkStartWhenAvail = New-Object System.Windows.Forms.CheckBox; $chkStartWhenAvail.Text = 'Run as soon as possible after a missed start'; $chkStartWhenAvail.AutoSize = $true
    $chkBatteryStop = New-Object System.Windows.Forms.CheckBox; $chkBatteryStop.Text = "Don't start on battery power"; $chkBatteryStop.AutoSize = $true
    $chkNetwork = New-Object System.Windows.Forms.CheckBox; $chkNetwork.Text = 'Only run when a network is available'; $chkNetwork.AutoSize = $true
    $chkWake = New-Object System.Windows.Forms.CheckBox; $chkWake.Text = 'Wake the computer to run'; $chkWake.AutoSize = $true
    $chkHidden = New-Object System.Windows.Forms.CheckBox; $chkHidden.Text = 'Hidden'; $chkHidden.AutoSize = $true

    $cboLogging = New-Object System.Windows.Forms.ComboBox
    $cboLogging.Dock = 'Fill'; $cboLogging.DropDownStyle = 'DropDownList'
    [void]$cboLogging.Items.Add('Transcript - wrap the script so each run leaves a log')
    [void]$cboLogging.Items.Add('None - run the script directly')
    $txtLogDir = New-PSTaskUITextBox
    $txtLogRetain = New-PSTaskUITextBox

    $cboExecPolicy = New-Object System.Windows.Forms.ComboBox
    $cboExecPolicy.Dock = 'Fill'; $cboExecPolicy.DropDownStyle = 'DropDownList'
    foreach ($x in @('Bypass', 'RemoteSigned', 'AllSigned', 'Unrestricted', 'Restricted', 'Default', 'None')) { [void]$cboExecPolicy.Items.Add($x) }
    $chkNoProfile = New-Object System.Windows.Forms.CheckBox; $chkNoProfile.Text = '-NoProfile'; $chkNoProfile.AutoSize = $true
    $chkNonInteractive = New-Object System.Windows.Forms.CheckBox; $chkNonInteractive.Text = '-NonInteractive'; $chkNonInteractive.AutoSize = $true
    $cboWindowStyle = New-Object System.Windows.Forms.ComboBox
    $cboWindowStyle.Dock = 'Fill'; $cboWindowStyle.DropDownStyle = 'DropDownList'
    foreach ($x in @('Hidden', 'Minimized', 'Normal', 'Maximized', 'None')) { [void]$cboWindowStyle.Items.Add($x) }
    $txtExtraArgs = New-PSTaskUITextBox

    Add-PSTaskUIField -Table $tblAdv -Label 'If already running' -Control $cboInstances
    Add-PSTaskUIField -Table $tblAdv -Label 'Stop after' -Control $txtTimeLimit
    Add-PSTaskUIField -Table $tblAdv -Label 'Restart attempts' -Control $txtRestartCount
    Add-PSTaskUIField -Table $tblAdv -Label 'Restart every' -Control $txtRestartInterval
    Add-PSTaskUIField -Table $tblAdv -Label '' -Control $chkStartWhenAvail
    Add-PSTaskUIField -Table $tblAdv -Label '' -Control $chkBatteryStop
    Add-PSTaskUIField -Table $tblAdv -Label '' -Control $chkNetwork
    Add-PSTaskUIField -Table $tblAdv -Label '' -Control $chkWake
    Add-PSTaskUIField -Table $tblAdv -Label '' -Control $chkHidden
    Add-PSTaskUIField -Table $tblAdv -Label 'Logging' -Control $cboLogging
    Add-PSTaskUIField -Table $tblAdv -Label 'Log folder' -Control $txtLogDir
    Add-PSTaskUIField -Table $tblAdv -Label 'Keep logs (days)' -Control $txtLogRetain
    Add-PSTaskUIField -Table $tblAdv -Label 'Execution policy' -Control $cboExecPolicy
    Add-PSTaskUIField -Table $tblAdv -Label 'Window style' -Control $cboWindowStyle
    Add-PSTaskUIField -Table $tblAdv -Label '' -Control $chkNoProfile
    Add-PSTaskUIField -Table $tblAdv -Label '' -Control $chkNonInteractive
    Add-PSTaskUIField -Table $tblAdv -Label 'Extra arguments' -Control $txtExtraArgs
    Add-PSTaskUIStacked -Stack $secAdv.Content -Control $tblAdv
    Add-PSTaskUIStacked -Stack $leftStack -Control $secAdv.Container

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

    $lblPreview = New-PSTaskUILabel -Text 'What will be registered' -Header
    $lblPreview.ForeColor = $t.Accent
    $txtPreview = New-PSTaskUITextBox -ReadOnly -Multiline -Monospace

    $lblChecks = New-PSTaskUILabel -Text 'Preflight' -Header
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

    $txtCheckDetail = New-PSTaskUITextBox -ReadOnly -Multiline
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
    $buildPlan = {
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

        $settings = @{
            MultipleInstances          = [string]$cboInstances.SelectedItem
            StartWhenAvailable         = $chkStartWhenAvail.Checked
            ExecutionTimeLimit         = $txtTimeLimit.Text.Trim()
            RestartCount               = 0
            RestartInterval            = $txtRestartInterval.Text.Trim()
            DisallowStartIfOnBatteries = $chkBatteryStop.Checked
            StopIfGoingOnBatteries     = $chkBatteryStop.Checked
            RunOnlyIfNetworkAvailable  = $chkNetwork.Checked
            WakeToRun                  = $chkWake.Checked
            Hidden                     = $chkHidden.Checked
        }
        $rc = 0
        if ([int]::TryParse($txtRestartCount.Text.Trim(), [ref]$rc)) { $settings['RestartCount'] = $rc }

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

        $p = New-PSTaskPlan @planArgs

        # The form is authoritative for parameters. New-PSTaskPlan seeds the script's declared
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
            $txtPreview.Text = 'Select a script to begin.'
            $lvChecks.Items.Clear()
            return
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
        $checks = @(Test-PSTaskPlan -Plan $plan)
        $ordered = $checks | Sort-Object @{ Expression = { (Get-PSTaskUISeverityStyle -Severity $_.Severity).Rank } }
        $errorCount = 0
        foreach ($c in $ordered) {
            $style = Get-PSTaskUISeverityStyle -Severity $c.Severity
            if ($c.Severity -eq 'Error') { $errorCount++ }
            $item = New-Object System.Windows.Forms.ListViewItem($style.Token)
            [void]$item.SubItems.Add($c.Title)
            $item.ForeColor = $style.Color
            $item.Tag = $c
            [void]$lvChecks.Items.Add($item)
        }
        $lvChecks.EndUpdate()
        & $sizeCheckColumns

        $btnSave.Enabled = ($errorCount -eq 0) -and (-not $state.Locked)
        if ($state.Locked) {
            $btnSave.Text = 'Cannot save'
        }
        elseif ($errorCount -gt 0) {
            $btnSave.Text = "$errorCount error(s)"
        }
        else {
            $btnSave.Text = $(if ($state.IsEdit) { 'Save changes' } else { 'Create task' })
        }
    }

    # Rebuilds the parameter controls for the current script profile.
    $rebuildParams = {
        $paramHost.Controls.Clear()
        $state.ParamControls = [ordered]@{}

        if (-not $state.Profile -or -not $state.Profile.HasParameters) {
            $none = New-PSTaskUILabel -Text 'This script declares no parameters.' -ForeColor $t.Muted
            Add-PSTaskUIStacked -Stack $paramHost -Control $none
            return
        }

        $tbl = New-PSTaskUIFieldTable
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
                $box = New-PSTaskUITextBox -ReadOnly
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
                $inner = New-PSTaskUITextBox
                $browse = New-PSTaskUIButton -Text '...' -Width 34
                $browse.Tag = $inner
                $browse.add_Click({
                        $box = $args[0].Tag
                        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
                        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $box.Text = $dlg.SelectedPath }
                        $dlg.Dispose()
                    })
                $inner.add_TextChanged({ & $refresh })
                $panel.Controls.Add($inner, 0, 0)
                $panel.Controls.Add($browse, 1, 0)
                $rowControl = $panel
                $valueControl = $inner
            }
            else {
                $box = New-PSTaskUITextBox
                $box.add_TextChanged({ & $refresh })
                $rowControl = $box
                $valueControl = $box
            }

            # Pre-fill from the script's own declared default, so the form shows what will
            # actually be used. Without this the preview showed '-DaysOut 14' while the DaysOut
            # box sat empty, which reads as a bug even though both were "right".
            # Expression defaults - (Get-Date), $PSScriptRoot - are deliberately left blank:
            # they are the script's to evaluate at run time, and this must never execute them.
            if ($meta.HasDefault -and -not $meta.IsSwitch) {
                $literal = $null
                $dv = [string]$meta.DefaultValue
                if ($dv -match '^[''"](.*)[''"]$') { $literal = $Matches[1] }
                elseif ($dv -match '^-?\d+(\.\d+)?$') { $literal = $dv }

                if ($null -ne $literal) {
                    if ($valueControl -is [System.Windows.Forms.ComboBox]) {
                        $i = $valueControl.Items.IndexOf($literal)
                        if ($i -ge 0) { $valueControl.SelectedIndex = $i }
                    }
                    elseif ($valueControl -is [System.Windows.Forms.TextBox] -and -not $valueControl.ReadOnly) {
                        $valueControl.Text = $literal
                    }
                }
            }

            $label = $meta.Name
            if ($meta.IsMandatory) { $label = "$label *" }
            Add-PSTaskUIField -Table $tbl -Label $label -Control $rowControl

            if ($meta.IsMandatory) {
                $pos = $tbl.GetPositionFromControl($rowControl)
                $lbl = $tbl.GetControlFromPosition(0, $pos.Row)
                if ($lbl) { $lbl.ForeColor = $t.Accent; $lbl.Font = $t.FontBold }
            }

            if ($meta.Description) {
                $tip = New-Object System.Windows.Forms.ToolTip
                $tip.SetToolTip($valueControl, $meta.Description)
            }

            $state.ParamControls[$meta.Name] = @{ Control = $valueControl; Meta = $meta }
        }
        Add-PSTaskUIStacked -Stack $paramHost -Control $tbl
    }

    $refreshTriggers = {
        $lstTrig.Items.Clear()
        if (-not $state.Triggers -or $state.Triggers.Count -eq 0) {
            [void]$lstTrig.Items.Add('(no triggers - the task will only run on demand)')
        }
        else {
            foreach ($spec in $state.Triggers) {
                $desc = switch ($spec.Type) {
                    'Daily' { "Daily at $(([datetime]$spec.At).ToString('HH:mm'))" + $(if ($spec.DaysInterval -gt 1) { " every $($spec.DaysInterval) days" } else { '' }) }
                    'Weekly' { "Weekly $($spec.DaysOfWeek -join ',') at $(([datetime]$spec.At).ToString('HH:mm'))" }
                    'Once' { "Once on $(([datetime]$spec.At).ToString('yyyy-MM-dd HH:mm'))" }
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
            $prof = Get-PSTaskScriptProfile -Path $path
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Cannot read script',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $state.Profile = $prof
        $state.Suspend = $true

        $bits = @()
        $bits += "Engine: $($prof.EngineId) ($($prof.EngineConfidence.ToLower()) - $($prof.EngineReason))"
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
            $spec = Show-PSTaskTriggerDialog -Owner $form
            if ($spec) {
                $state.Triggers = $state.Triggers + $spec
                & $refreshTriggers
            }
        })

    $btnTrigEdit.add_Click({
            $i = $lstTrig.SelectedIndex
            if ($i -lt 0 -or $i -ge $state.Triggers.Count) { return }
            $spec = Show-PSTaskTriggerDialog -Trigger $state.Triggers[$i] -Owner $form
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
            $lines = @("$($c.Severity.ToUpper()): $($c.Title)")
            if ($c.Detail) { $lines += ''; $lines += $c.Detail }
            if ($c.Recommendation) { $lines += ''; $lines += "-> $($c.Recommendation)" }
            $txtCheckDetail.Text = ($lines -join [Environment]::NewLine)
        })

    foreach ($c in @($txtName, $txtFolder, $txtDesc, $txtWorkDir, $txtUser, $txtTimeLimit,
            $txtRestartCount, $txtRestartInterval, $txtLogDir, $txtLogRetain, $txtExtraArgs)) {
        $c.add_TextChanged({ & $refresh })
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
    $btnExport = New-PSTaskUIButton -Text 'Export plan...' -Width 118
    $btnSave = New-PSTaskUIButton -Text 'Create task' -Primary -Width 130
    $btnCancel = New-PSTaskUIButton -Text 'Cancel'

    $btnExport.add_Click({
            $plan = & $buildPlan
            if (-not $plan) { return }
            $dlg = New-Object System.Windows.Forms.SaveFileDialog
            $dlg.Filter = 'Task plan (*.json)|*.json'
            $dlg.FileName = "$($plan.TaskName).task.json"
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                try {
                    Export-PSTaskPlan -Plan $plan -Path $dlg.FileName
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

            $password = $null
            if ($plan.Principal.LogonType -eq 'Password') {
                $cred = $host.UI.PromptForCredential('Task account password',
                    "Enter the password for $($plan.Principal.UserId). It is handed straight to Task Scheduler and never stored in the plan.",
                    $plan.Principal.UserId, '')
                if (-not $cred) { return }
                $password = $cred.Password
            }

            # Renaming an existing task creates a new one; remove the old registration so the
            # edit does not silently leave a duplicate behind.
            $renamed = $state.IsEdit -and
                       (($state.OriginalName -ne $plan.TaskName) -or ($state.OriginalPath -ne $plan.TaskPath))

            try {
                if ($password) {
                    Register-PSTaskPlan -Plan $plan -Password $password -Confirm:$false
                }
                else {
                    Register-PSTaskPlan -Plan $plan -Confirm:$false
                }

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

            $state.SavedPlan = $plan
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        })

    $btnCancel.add_Click({
            $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
            $form.Close()
        })

    $bar = New-PSTaskUIActionBar -LeftButton @($btnExport) -RightButton @($btnCancel, $btnSave)

    $root.Controls.Add($leftScroll, 0, 0)
    $root.Controls.Add($rightCol, 1, 0)
    $root.Controls.Add($bar, 0, 1)
    $root.SetColumnSpan($bar, 2)
    [void]$form.Controls.Add($root)
    $form.CancelButton = $btnCancel

    # --- seed defaults ------------------------------------------------------------------
    $cboAccountType.SelectedIndex = 0
    & $applyAccountType

    # Show the account that will actually be used. New-PSTaskPlan falls back to the current user
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

            $picked = Show-PSTaskAccountPicker -InitialType $initial -Owner $form
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
    & $refreshTriggers

    if ($state.Locked) {
        $txtPreview.Text = "This task's action was not built by PSTaskBuilder and cannot be modelled safely:" +
        [Environment]::NewLine + [Environment]::NewLine +
        "  $($Plan.RawAction.Execute) $($Plan.RawAction.Arguments)" +
        [Environment]::NewLine + [Environment]::NewLine +
        ($Plan.ParseNotes -join [Environment]::NewLine) +
        [Environment]::NewLine + [Environment]::NewLine +
        'Saving is blocked so a working task is not silently rewritten. Edit it in Task Scheduler, or create a new task alongside it.'
        $btnSave.Enabled = $false
    }

    if ($BuildOnly) { return $form }

    if ($SelfTest) {
        # Shown from inside this function so the handlers' locals are still on the stack,
        # exactly as they are under ShowDialog.
        $form.WindowState = 'Minimized'
        $form.ShowInTaskbar = $false
        $form.Show()
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
