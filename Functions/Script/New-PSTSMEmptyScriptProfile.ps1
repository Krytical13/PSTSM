# SPDX-License-Identifier: GPL-3.0-or-later
function New-PSTSMEmptyScriptProfile {
    <#
    .SYNOPSIS
        A Get-PSTSMScriptProfile-shaped object describing a script that was never examined.
    .DESCRIPTION
        Test-PSTSMPlan has two cases where there is no script to profile: an Executable plan, which
        has no .ps1 at all, and a script on a network path that did not answer in time. Both still
        run every check below that reads the profile, so both need something of the right shape to
        read from.

        Empty is the truthful value. Nothing was examined, so nothing was found - which is not the
        same as "examined and clean", and is why the callers add their own check saying so.

        The property names have to mirror Get-PSTSMScriptProfile exactly. A typo here reads as
        $null, '-not $null' is $true, and the warnings this exists to suppress fire anyway - only
        for these two cases, and silently. HasExitStatement is the one that must be $true: an
        unexamined script has not been shown to lack an exit code, and EXIT_CODE would otherwise
        accuse every one of them.
    .OUTPUTS
        [pscustomobject]
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory object. Changes no state.')]
    [CmdletBinding()]
    param()

    [PSCustomObject]@{
        Parameters        = @()
        HasParameters     = $false
        IsParseable       = $true
        IsReadable        = $true
        ParseErrors       = @()
        RequiresElevation = $false
        RequiredVersion   = $null
        RequiredEditions  = @()
        RequiredModules   = @()
        ConfigFiles       = @()
        Signals           = [PSCustomObject]@{
            InteractiveCommands = @()
            NetworkCommands     = @()
            UncPaths            = @()
            DpapiCommands       = @()
            HasExitStatement    = $true
            UsesGui             = $false
            CommandNames        = @()
        }
        Encoding          = [PSCustomObject]@{
            HasBom      = $true
            HasNonAscii = $false
        }
    }
}
