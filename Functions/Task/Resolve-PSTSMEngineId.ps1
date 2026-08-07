# SPDX-License-Identifier: GPL-3.0-or-later
function Resolve-PSTSMEngineId {
    <#
    .SYNOPSIS
        'powershell', 'pwsh', or $null - which PowerShell host, if any, an Execute value names.
    .DESCRIPTION
        One definition, two callers. ConvertFrom-PSTSMAction uses it to decide whether an action is
        worth parsing at all, and Get-PSTSMInventory uses it to answer -PowerShellOnly WITHOUT
        parsing, which is the point: the inventory used to tokenise all 290 actions and then throw
        most of them away.

        Written as a shared function rather than the same regex in two places on purpose. These two
        must agree exactly - if the cheap check and the real parse ever disagreed, -PowerShellOnly
        would hide a task the editor would happily open, or show one it cannot.

        Matched on the file name only. A quoted path, a SysWOW64 path and a bare 'powershell' all
        name the same host; the bitness question is answered separately, from the directory.
    .PARAMETER Execute
        A task action's Execute value.
    .OUTPUTS
        [string] 'powershell' or 'pwsh', or $null when it is neither.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Execute
    )

    if ([string]::IsNullOrWhiteSpace($Execute)) { return $null }

    $leaf = ''
    try { $leaf = [System.IO.Path]::GetFileName($Execute.Trim('"', ' ')) }
    catch {
        Write-Verbose "Could not parse Execute value '$Execute': $($_.Exception.Message)"
        return $null
    }

    switch -Regex ($leaf) {
        '(?i)^powershell(\.exe)?$' { return 'powershell' }
        '(?i)^pwsh(\.exe)?$' { return 'pwsh' }
    }
    $null
}
