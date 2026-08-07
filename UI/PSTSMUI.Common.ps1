# SPDX-License-Identifier: GPL-3.0-or-later
# PSTSMUI.Common.ps1
# Shared WinForms scaffolding: theme, control factories, and the host setup every window needs.
#
# Constraints baked in here, all learned the hard way on Windows PowerShell 5.1:
#   - Layout uses TableLayoutPanel / FlowLayoutPanel only. Absolute Location plus a right
#     Anchor inside a TLP cell can fling controls off-screen at non-100% DPI.
#   - Only ONE Dock='Fill' child of a parent may be visible at a time; two visible Fill
#     siblings starve each other and the front one can end up with zero size.
#   - Never wrap a [List[object]] in @(). It throws "Argument types do not match" on 5.1.
#     Use .ToArray().
#   - Event handlers are plain scriptblocks. .GetNewClosure() severs module session-state
#     affinity on 5.1, so module functions become "not recognized" inside the handler.
#   - GroupBox.Font cascades to every child, so section headers are standalone Labels.

Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

# TextBox.PlaceholderText only exists from .NET Core 3.0, and this has to work on Windows
# PowerShell 5.1 / .NET Framework. EM_SETCUEBANNER is the native equivalent and has been on
# every Edit control since XP.
if (-not ('PSTSMNative.Win32' -as [type])) {
    try {
        Add-Type -Namespace 'PSTSMNative' -Name 'Win32' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr SendMessage(System.IntPtr hWnd, int msg, System.IntPtr wParam, string lParam);

[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@ -ErrorAction Stop
    }
    catch { Write-Verbose "Cue-banner interop unavailable: $($_.Exception.Message)" }
}

function Show-PSTSMUIForTest {
    <#
    .SYNOPSIS
        Realises a form for a test seam without stealing focus from whoever is at the machine.
    .DESCRIPTION
        Several seams have to SHOW the form rather than merely build it: PerformClick goes
        through CanSelect, which is false on a form that has never been shown, so a click on an
        unshown form is silently a no-op and would prove nothing.

        The obvious way to do that quietly - WindowState='Minimized' plus Show() - is not quiet
        at all. Show() activates the window, so running the UI suite yanked focus away once per
        dialog and left the operator's own window behind. SW_SHOWNOACTIVATE displays the window
        without activating it, and parking it off-screen keeps it from flashing up as well.

        Falls back to a plain Show() if the interop is unavailable, because a noisy test run is
        better than one that cannot run at all.
    .PARAMETER Form
        The form to realise.
    .EXAMPLE
        Show-PSTSMUIForTest -Form $form
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Windows.Forms.Form]$Form)

    $Form.StartPosition = 'Manual'
    $Form.Location = New-Object System.Drawing.Point(-32000, -32000)
    $Form.ShowInTaskbar = $false

    if ('PSTSMNative.Win32' -as [type]) {
        $handle = $Form.Handle          # forces handle creation without showing
        [void][PSTSMNative.Win32]::ShowWindow($handle, 4)   # SW_SHOWNOACTIVATE

        # ShowWindow puts the window on screen at the Win32 level, which is the whole point of
        # using it - but it goes around WinForms, so WinForms never raises Shown. Every add_Shown
        # handler in the tool was therefore dead in this seam: the main window's test asserted it
        # "exercises Get-PSTSMInventory via the add_Shown handler" and had never once run it.
        #
        # OnShown is protected, so reflection is the only way to raise it faithfully. Raising it
        # rather than calling the handler directly is deliberate: it also proves the handler is
        # actually wired up, which is half of what a show-time test is for.
        try {
            $onShown = [System.Windows.Forms.Form].GetMethod('OnShown',
                [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance)
            # [void], because MethodInfo.Invoke emits its return value even for a void method - and
            # a stray $null on this function's output stream flows all the way up into whatever the
            # caller collected. In the smoke tests that is the list of caught thread exceptions, so
            # an un-suppressed $null read as "a thread exception with an empty message".
            if ($onShown) { [void]$onShown.Invoke($Form, @([System.EventArgs]::Empty)) }
        }
        catch {
            Write-Verbose "Could not raise Shown for the test seam: $($_.Exception.Message)"
        }
    }
    else {
        # Show() raises Shown by itself.
        $Form.WindowState = 'Minimized'
        $Form.Show()
    }
}

function Set-PSTSMUICueBanner {
    <#
    .SYNOPSIS
        Shows greyed hint text inside an empty textbox, which disappears as soon as the user
        types.
    .DESCRIPTION
        Used for parameter defaults the script computes for itself. The value must be VISIBLE
        (so the form does not look like it knows nothing) without being a VALUE (so it is not
        put on the command line and the script still evaluates it at run time). A cue banner is
        exactly that distinction rendered in the UI.

        Silently does nothing if the interop is unavailable - a missing hint is cosmetic.
    .PARAMETER TextBox
        Target textbox.
    .PARAMETER Text
        Hint to display.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Windows.Forms.TextBox]$TextBox,
        [AllowEmptyString()][string]$Text
    )

    if (-not ('PSTSMNative.Win32' -as [type])) { return }
    try {
        # wParam 1 keeps the cue visible while the box has focus, until a character is typed.
        [void][PSTSMNative.Win32]::SendMessage($TextBox.Handle, 0x1501, [IntPtr]1, $Text)
    }
    catch { Write-Verbose "Could not set cue banner: $($_.Exception.Message)" }
}

function Get-PSTSMUITheme {
    <#
    .SYNOPSIS
        Returns the colour and font palette shared by every PSTSM window.
    .DESCRIPTION
        Contrast ratios are chosen against SC 1.4.3 (text, 4.5:1) and SC 1.4.11 (control
        boundaries, 3:1) on the white surface these windows use:

          Accent  #016595  6.37:1 both as white-on-fill and fill-on-white, so it works for the
                           primary button, section rules and focus rings.
          Danger  #B3261E  5.9:1
          Warn    #8A6D00  4.6:1  (dark amber - mid amber fails as text)
          Good    #1B6E2F  5.2:1

        Severity is never communicated by colour alone; the preflight list carries an explicit
        ERROR / WARN / INFO / OK token as well (SC 1.4.1).

        Under Windows High Contrast the whole palette is handed back to the system. A fixed
        palette is exactly wrong there: the user has asked the OS for specific colours, and every
        hardcoded value overrides one of them. The visible symptom was a task list rendering as
        blank bands - a fixed near-black cell foreground over the system window colour, about
        1.02:1 - so half the rows were invisible while the alternating ones read fine.
    .OUTPUTS
        [hashtable]
    #>
    [CmdletBinding()]
    param()

    if ([System.Windows.Forms.SystemInformation]::HighContrast) {
        return @{
            Accent      = [System.Drawing.SystemColors]::Highlight
            AccentHover = [System.Drawing.SystemColors]::Highlight
            Danger      = [System.Drawing.SystemColors]::WindowText
            Warn        = [System.Drawing.SystemColors]::WindowText
            Good        = [System.Drawing.SystemColors]::WindowText
            Muted       = [System.Drawing.SystemColors]::GrayText
            Border      = [System.Drawing.SystemColors]::WindowFrame
            Surface     = [System.Drawing.SystemColors]::Window
            SurfaceAlt  = [System.Drawing.SystemColors]::Control
            Text        = [System.Drawing.SystemColors]::WindowText

            FontBase    = New-Object System.Drawing.Font('Segoe UI', 9)
            FontBold    = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
            FontHeader  = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5, [System.Drawing.FontStyle]::Bold)
            FontMono    = New-Object System.Drawing.Font('Consolas', 9)
        }
    }

    @{
        Accent      = [System.Drawing.Color]::FromArgb(0x01, 0x65, 0x95)
        AccentHover = [System.Drawing.Color]::FromArgb(0x01, 0x50, 0x76)   # hover goes DARKER; lighter drops white text below 4.5:1
        Danger      = [System.Drawing.Color]::FromArgb(0xB3, 0x26, 0x1E)
        Warn        = [System.Drawing.Color]::FromArgb(0x8A, 0x6D, 0x00)
        Good        = [System.Drawing.Color]::FromArgb(0x1B, 0x6E, 0x2F)
        Muted       = [System.Drawing.Color]::FromArgb(0x4A, 0x55, 0x68)
        Border      = [System.Drawing.Color]::FromArgb(0x6E, 0x76, 0x81)   # 3.6:1 on white, satisfies 1.4.11
        Surface     = [System.Drawing.Color]::White
        SurfaceAlt  = [System.Drawing.Color]::FromArgb(0xF5, 0xF6, 0xF8)
        Text        = [System.Drawing.Color]::FromArgb(0x1A, 0x1D, 0x21)

        FontBase    = New-Object System.Drawing.Font('Segoe UI', 9)
        FontBold    = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
        FontHeader  = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5, [System.Drawing.FontStyle]::Bold)
        FontMono    = New-Object System.Drawing.Font('Consolas', 9)
    }
}

function Initialize-PSTSMUIHost {
    <#
    .SYNOPSIS
        One-time process setup for showing WinForms windows from PowerShell.
    .DESCRIPTION
        Enables visual styles and DPI awareness, and installs a thread-exception handler so an
        unhandled error in an event handler shows a dialog and keeps the app alive instead of
        killing it with the raw .NET crash window.
    #>
    [CmdletBinding()]
    param()

    # The flag lives on the AppDomain, not in $script: scope. Start-PSTSM.ps1 does
    # Import-Module -Force on every launch, which resets module scope - so a second run in the
    # same PowerShell session re-entered this after windows already existed.
    if ([System.AppDomain]::CurrentDomain.GetData('PSTSMUIHostReady')) { return }

    [System.Windows.Forms.Application]::EnableVisualStyles()

    # Throws "must be called before the first IWin32Window object is created" once anything in
    # the process has made a window - another PowerShell GUI, a file dialog, a previous run.
    # It only selects the text-rendering back end, so losing it is cosmetic and must never stop
    # the tool from opening.
    try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) }
    catch { Write-Verbose "SetCompatibleTextRenderingDefault skipped: $($_.Exception.Message)" }

    # No-op on Windows PowerShell 5.1; present from .NET Core 3.0 onwards.
    try { [System.Windows.Forms.Application]::SetHighDpiMode([System.Windows.Forms.HighDpiMode]::SystemAware) | Out-Null } catch { Write-Verbose 'SetHighDpiMode unavailable on this runtime.' }

    try {
        [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
        [System.Windows.Forms.Application]::add_ThreadException({
                param($src, $e)   # not $sender - PSScriptAnalyzer treats that as an automatic variable
                $null = $src
                # Set PSTSM_NODIALOG in automated runs. Without it a handler bug in a
                # headless harness pops a modal message box on the desktop of whoever is at the
                # machine, and blocks until somebody dismisses it.
                if ($env:PSTSM_NODIALOG) {
                    Write-Warning "PSTSM UI exception: $($e.Exception.Message)"
                    return
                }
                [System.Windows.Forms.MessageBox]::Show(
                    "$($e.Exception.Message)`n`n$($e.Exception.StackTrace)",
                    'PSTSM - unexpected error',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            })
    }
    catch { Write-Verbose "Could not install thread-exception handler: $($_.Exception.Message)" }

    [System.AppDomain]::CurrentDomain.SetData('PSTSMUIHostReady', $true)
}

function Get-PSTSMUIScale {
    <#
    .SYNOPSIS
        Returns the display scale factor (1.0 at 100%, 1.5 at 150%).
    .DESCRIPTION
        These forms run with AutoScaleMode 'None' because WinForms' font-based scaling resizes
        the form out from under any explicit ClientSize (see New-PSTSMUIForm). That makes the
        scale factor ours to apply.

        Anything that can size itself should: AutoSize controls and AutoSize table columns need
        no factor at all. This is only for the few dimensions that must be given a number, such
        as the initial window size and a filter box width.
    .OUTPUTS
        [double]
    #>
    [CmdletBinding()]
    param()

    try {
        $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
        $dpi = $g.DpiX
        $g.Dispose()
        if ($dpi -gt 0) { return [double]($dpi / 96.0) }
    }
    catch { Write-Verbose "Could not read display DPI: $($_.Exception.Message)" }
    1.0
}

function New-PSTSMUIForm {
    <#
    .SYNOPSIS
        Creates a themed top-level form with sane scaling defaults.
    .DESCRIPTION
        Width and Height are given at 100% scaling and multiplied by the current display scale,
        because nothing here scales itself.
    .PARAMETER Title
        Window title.
    .PARAMETER Width
        Client width at 100% scaling.
    .PARAMETER Height
        Client height at 100% scaling.
    .OUTPUTS
        [System.Windows.Forms.Form]
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory WinForms control. Changes no system state.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [int]$Width = 1100,
        [int]$Height = 720
    )

    $t = Get-PSTSMUITheme
    $scale = Get-PSTSMUIScale
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title

    # AutoScaleMode 'None', deliberately. With 'Font', assigning Form.Font RESIZES the form by
    # the ratio between the new font and AutoScaleDimensions - measured here turning a 1180x780
    # design into 1377x900 - which happens after any ClientSize we set and silently invalidates
    # the clamp below. Every control in this UI is AutoSize or laid out by a TableLayoutPanel,
    # so it absorbs a larger font on its own and WinForms' scaling buys nothing but surprises.
    $form.AutoScaleMode = 'None'
    $form.Font = $t.FontBase

    $form.ClientSize = New-Object System.Drawing.Size([int]($Width * $scale), [int]($Height * $scale))
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = $t.Surface
    $form.ForeColor = $t.Text

    # Clamp the OUTER size - Width/Height include the caption and borders, which ClientSize does
    # not, and it is the outer size that has to fit on screen. Laptops at high scaling have far
    # less logical room than the design assumes: 1512x901 is a real, common working area.
    if ($form.Width -gt $screen.Width) { $form.Width = $screen.Width }
    if ($form.Height -gt $screen.Height) { $form.Height = $screen.Height }

    # MinimumSize must never exceed what actually fits, or the form cannot be shrunk to the
    # screen and the bottom stays unreachable.
    $form.MinimumSize = New-Object System.Drawing.Size(
        [Math]::Min([int](700 * $scale), $screen.Width),
        [Math]::Min([int](480 * $scale), $screen.Height))
    $form
}

function New-PSTSMUILabel {
    <#
    .SYNOPSIS
        Creates an auto-sizing label.
    .PARAMETER Text
        Label text.
    .PARAMETER Bold
        Use the bold face.
    .PARAMETER Header
        Use the larger section-header face.
    .PARAMETER ForeColor
        Optional explicit colour.
    .OUTPUTS
        [System.Windows.Forms.Label]
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory WinForms control. Changes no system state.')]
    [CmdletBinding()]
    param(
        [string]$Text = '',
        [switch]$Bold,
        [switch]$Header,
        [System.Drawing.Color]$ForeColor
    )

    $t = Get-PSTSMUITheme
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.AutoSize = $true
    $l.Margin = New-Object System.Windows.Forms.Padding(3, 6, 3, 3)
    if ($Header) { $l.Font = $t.FontHeader }
    elseif ($Bold) { $l.Font = $t.FontBold }
    if ($PSBoundParameters.ContainsKey('ForeColor')) { $l.ForeColor = $ForeColor }
    $l
}

function New-PSTSMUIButton {
    <#
    .SYNOPSIS
        Creates a flat button, optionally styled as the one primary action.
    .DESCRIPTION
        FlatStyle suppresses the native focus rectangle, so an explicit focus ring is added by
        thickening the border on GotFocus. Those handlers read only $args[0] and therefore need
        no closure - which matters, because .GetNewClosure() would sever module affinity.
    .PARAMETER Text
        Button caption.
    .PARAMETER Primary
        Render as the accent-filled primary action.
    .PARAMETER Danger
        Put the danger colour on the border (survives greyscale and colour-blindness better
        than colouring only the text).
    .PARAMETER Width
        Fixed width.
    .OUTPUTS
        [System.Windows.Forms.Button]
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory WinForms control. Changes no system state.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [switch]$Primary,
        [switch]$Danger,
        [int]$Width = 104
    )

    $t = Get-PSTSMUITheme
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text

    # AutoSize, with -Width acting only as a MINIMUM. A fixed Width/Height clips the caption on
    # any machine that is not at 100% scaling: the font renders larger while a hardcoded 104x30
    # button stays literally 104x30, so the text is cut off. Letting the button measure its own
    # caption is correct at every DPI and needs no scale factor - which matters because the
    # forms here run with AutoScaleMode 'None' (see New-PSTSMUIForm) and get no help from
    # WinForms' own scaling.
    $b.AutoSize = $true
    $b.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $b.MinimumSize = New-Object System.Drawing.Size($Width, 0)
    $b.Padding = New-Object System.Windows.Forms.Padding(10, 5, 10, 5)
    $b.Margin = New-Object System.Windows.Forms.Padding(4, 3, 4, 3)
    $b.FlatStyle = 'Flat'
    $b.UseVisualStyleBackColor = $false
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand

    if ($Primary) {
        $b.BackColor = $t.Accent
        $b.ForeColor = [System.Drawing.Color]::White
        $b.FlatAppearance.BorderColor = $t.Accent
        $b.FlatAppearance.MouseOverBackColor = $t.AccentHover
    }
    else {
        $b.BackColor = $t.Surface
        $b.ForeColor = $t.Text
        if ($Danger) { $b.FlatAppearance.BorderColor = $t.Danger } else { $b.FlatAppearance.BorderColor = $t.Border }
        $b.FlatAppearance.MouseOverBackColor = $t.SurfaceAlt
    }
    $b.FlatAppearance.BorderSize = 1

    $b.add_GotFocus({ $args[0].FlatAppearance.BorderSize = 2 })
    $b.add_LostFocus({ $args[0].FlatAppearance.BorderSize = 1 })
    $b
}

function New-PSTSMUITextBox {
    <#
    .SYNOPSIS
        Creates a bordered textbox that fills its cell.
    .PARAMETER Text
        Initial value.
    .PARAMETER ReadOnly
        Make it read-only (and visually recessed).
    .PARAMETER Multiline
        Multi-line with vertical scrollbar.
    .PARAMETER Monospace
        Use the monospace face - for command previews, where alignment matters.
    .OUTPUTS
        [System.Windows.Forms.TextBox]
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory WinForms control. Changes no system state.')]
    [CmdletBinding()]
    param(
        [string]$Text = '',
        [switch]$ReadOnly,
        [switch]$Multiline,
        [switch]$Monospace
    )

    $t = Get-PSTSMUITheme
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Text = $Text
    $tb.Dock = 'Fill'
    $tb.Margin = New-Object System.Windows.Forms.Padding(3)
    $tb.BorderStyle = 'FixedSingle'
    if ($Monospace) { $tb.Font = $t.FontMono }
    if ($Multiline) {
        $tb.Multiline = $true
        $tb.ScrollBars = 'Vertical'
        $tb.WordWrap = $true
    }
    if ($ReadOnly) {
        $tb.ReadOnly = $true
        # Both, always. Setting only the background leaves the foreground on the system default,
        # which under High Contrast is light-on-light and unreadable. Colour assignments have to
        # come in pairs or not at all.
        $tb.BackColor = $t.SurfaceAlt
        $tb.ForeColor = $t.Text
    }
    $tb
}

function New-PSTSMUIActionBar {
    <#
    .SYNOPSIS
        Builds a bottom action bar with left- and right-aligned button groups.
    .DESCRIPTION
        A 2-column TableLayoutPanel holding two FlowLayoutPanels. The right group uses
        RightToLeft flow so buttons stay pinned to the right edge at any width - absolute
        coordinates plus anchoring is what throws controls off-screen when DPI changes.

        Buttons are added right-to-left, so pass the primary action FIRST in -RightButton.
    .PARAMETER LeftButton
        Buttons for the left group, in display order.
    .PARAMETER RightButton
        Buttons for the right group. The first element renders rightmost.
    .OUTPUTS
        [System.Windows.Forms.TableLayoutPanel]
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory WinForms control. Changes no system state.')]
    [CmdletBinding()]
    param(
        [System.Windows.Forms.Control[]]$LeftButton,
        [System.Windows.Forms.Control[]]$RightButton
    )

    $bar = New-Object System.Windows.Forms.TableLayoutPanel
    $bar.Dock = 'Fill'
    $bar.ColumnCount = 2
    $bar.RowCount = 1
    $bar.Margin = New-Object System.Windows.Forms.Padding(0)
    $bar.Padding = New-Object System.Windows.Forms.Padding(6, 4, 6, 4)
    [void]$bar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
    [void]$bar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))

    $left = New-Object System.Windows.Forms.FlowLayoutPanel
    $left.Dock = 'Fill'
    $left.FlowDirection = 'LeftToRight'
    $left.WrapContents = $false
    $left.AutoSize = $true
    foreach ($b in $LeftButton) { if ($b) { [void]$left.Controls.Add($b) } }

    $right = New-Object System.Windows.Forms.FlowLayoutPanel
    $right.Dock = 'Fill'
    $right.FlowDirection = 'RightToLeft'
    $right.WrapContents = $false
    $right.AutoSize = $true
    foreach ($b in $RightButton) { if ($b) { [void]$right.Controls.Add($b) } }

    # Tab order must follow the eye, not the add order. $right flows RightToLeft, so the LAST
    # button added is the visually leftmost - which left Cancel ahead of the primary in every
    # dialog using this bar. Reindexing here fixes all of them at once and moves nothing on screen.
    $n = 0
    foreach ($b in $left.Controls) { $b.TabIndex = $n++ }
    for ($i = $right.Controls.Count - 1; $i -ge 0; $i--) { $right.Controls[$i].TabIndex = $n++ }

    $bar.Controls.Add($left, 0, 0)
    $bar.Controls.Add($right, 1, 0)
    $bar
}

function New-PSTSMUIFieldTable {
    <#
    .SYNOPSIS
        Creates a two-column label/control table that grows downward.
    .DESCRIPTION
        Used for every form section. Add rows with Add-PSTSMUIField.
    .OUTPUTS
        [System.Windows.Forms.TableLayoutPanel]
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory WinForms control. Changes no system state.')]
    [CmdletBinding()]
    param()

    $tlp = New-Object System.Windows.Forms.TableLayoutPanel
    $tlp.Dock = 'Top'
    $tlp.AutoSize = $true
    $tlp.AutoSizeMode = 'GrowAndShrink'
    $tlp.ColumnCount = 2
    $tlp.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
    # AutoSize, not a fixed 132px: at 125%/150% scaling a longer label ("Restart attempts",
    # "Keep logs (days)") renders wider than any pixel constant chosen at 100% and gets clipped.
    [void]$tlp.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$tlp.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $tlp
}

function Add-PSTSMUIField {
    <#
    .SYNOPSIS
        Appends a labelled row to a field table.
    .PARAMETER Table
        The table from New-PSTSMUIFieldTable.
    .PARAMETER Label
        Row label. Pass an empty string to span the control across both columns.
    .PARAMETER Control
        The control to place in the value column.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Windows.Forms.TableLayoutPanel]$Table,
        [AllowEmptyString()][string]$Label,
        [Parameter(Mandatory)][System.Windows.Forms.Control]$Control
    )

    $row = $Table.RowCount
    $Table.RowCount = $row + 1
    [void]$Table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))

    if ([string]::IsNullOrEmpty($Label)) {
        $Table.Controls.Add($Control, 0, $row)
        $Table.SetColumnSpan($Control, 2)
    }
    else {
        $l = New-PSTSMUILabel -Text $Label
        $l.Anchor = 'Left'
        $l.Margin = New-Object System.Windows.Forms.Padding(3, 9, 3, 3)
        $Table.Controls.Add($l, 0, $row)
        $Table.Controls.Add($Control, 1, $row)
    }
}

function New-PSTSMUISection {
    <#
    .SYNOPSIS
        Creates a titled section: a header label, an accent rule, and a content panel.
    .DESCRIPTION
        Deliberately not a GroupBox - GroupBox.Font cascades to every child, so a larger title
        font would enlarge the whole section.
    .PARAMETER Title
        Section heading.
    .OUTPUTS
        [pscustomobject] Container (add to the parent) and Content (add your controls to).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory WinForms control. Changes no system state.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title
    )

    $t = Get-PSTSMUITheme

    $container = New-Object System.Windows.Forms.TableLayoutPanel
    $container.Dock = 'Top'
    $container.AutoSize = $true
    $container.AutoSizeMode = 'GrowAndShrink'
    $container.ColumnCount = 1
    $container.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 12)

    $header = New-PSTSMUILabel -Text $Title -Header
    $header.ForeColor = $t.Accent
    $header.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 2)

    $rule = New-Object System.Windows.Forms.Panel
    $rule.Height = 2
    $rule.Dock = 'Top'
    $rule.BackColor = $t.Accent
    $rule.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)

    $content = New-Object System.Windows.Forms.TableLayoutPanel
    $content.Dock = 'Top'
    $content.AutoSize = $true
    $content.AutoSizeMode = 'GrowAndShrink'
    $content.ColumnCount = 1
    $content.Margin = New-Object System.Windows.Forms.Padding(0)

    foreach ($c in @($header, $rule, $content)) {
        $r = $container.RowCount
        $container.RowCount = $r + 1
        [void]$container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
        $container.Controls.Add($c, 0, $r)
    }

    [PSCustomObject]@{ Container = $container; Content = $content; Header = $header }
}

function Add-PSTSMUIStacked {
    <#
    .SYNOPSIS
        Appends a control as a new auto-sized row of a single-column stack panel.
    .PARAMETER Stack
        A single-column TableLayoutPanel.
    .PARAMETER Control
        The control to append.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Windows.Forms.TableLayoutPanel]$Stack,
        [Parameter(Mandatory)][System.Windows.Forms.Control]$Control
    )

    $r = $Stack.RowCount
    $Stack.RowCount = $r + 1
    [void]$Stack.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $Stack.Controls.Add($Control, 0, $r)
}

function Get-PSTSMUISeverityStyle {
    <#
    .SYNOPSIS
        Maps a preflight severity to its display token and colour.
    .DESCRIPTION
        The token is the accessible channel: colour alone must not carry meaning (SC 1.4.1).
    .PARAMETER Severity
        Error, Warning, Info or Ok.
    .OUTPUTS
        [pscustomobject] Token, Color, Rank
    #>
    [CmdletBinding()]
    param([string]$Severity)

    $t = Get-PSTSMUITheme
    switch ($Severity) {
        'Error' { [PSCustomObject]@{ Token = 'ERROR'; Color = $t.Danger; Rank = 0 } }
        'Warning' { [PSCustomObject]@{ Token = 'WARN '; Color = $t.Warn; Rank = 1 } }
        'Info' { [PSCustomObject]@{ Token = 'INFO '; Color = $t.Muted; Rank = 2 } }
        'Ok' { [PSCustomObject]@{ Token = 'OK   '; Color = $t.Good; Rank = 3 } }
        default { [PSCustomObject]@{ Token = '     '; Color = $t.Text; Rank = 4 } }
    }
}
