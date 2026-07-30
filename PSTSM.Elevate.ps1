# SPDX-License-Identifier: GPL-3.0-or-later
<#
.SYNOPSIS
    The elevated half of PSTSM's save. Registers one task plan, reports back, exits.
.DESCRIPTION
    Windows cannot raise the privileges of a process that is already running - elevation
    happens only at process creation. Microsoft's answer to "mostly unprivileged app that
    occasionally needs admin" is the Administrator Broker Model: keep the main program at
    asInvoker and launch a separate elevated program for just the operations that need it.
    This is that separate program.

    It exists because the Task Scheduler service refuses a few registrations outright when the
    caller holds an un-elevated token - verified here, not merely read: with a real UAC-filtered
    token (TokenElevationType=3), RunLevel=Limited registers fine and RunLevel=Highest returns
    Access Denied. Rather than make the operator restart PSTSM and lose whatever they were
    editing, PSTSM hands the finished plan to this script behind a single consent prompt.

    The channel is deliberately dull. The plan is plain JSON that Export-PSTSMPlan already
    guarantees carries no secret, and the reply is plain JSON. Nothing is passed on the command
    line that would show up in another user's process list.

    A stored-password task is the one case needing a credential, so this script prompts for it
    itself. The password is therefore only ever held by the elevated process that consumes it -
    it is never written to disk, and never crosses the process boundary.
.PARAMETER PlanPath
    JSON task plan written by Export-PSTSMPlan.
.PARAMETER ResultPath
    Where to write the JSON reply. Always written, including on failure.
.PARAMETER PromptForPassword
    Ask for the run-as account's password before registering (LogonType 'Password' only).
.PARAMETER RemoveTaskName
    A task to unregister after a successful save - set when a rename left a stale registration.
.PARAMETER RemoveTaskPath
    Folder of -RemoveTaskName.
.NOTES
    Not meant to be run by hand. PSTSM invokes it through Invoke-PSTSMElevatedRegistration.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PlanPath,
    [Parameter(Mandatory)][string]$ResultPath,
    [switch]$PromptForPassword,
    [string]$RemoveTaskName,
    [string]$RemoveTaskPath
)

$ErrorActionPreference = 'Stop'

$reply = [ordered]@{
    Success    = $false
    Error      = $null
    Stage      = 'start'
    TaskName   = $null
    TaskPath   = $null
    Warnings   = @()
    RanAs      = $null
    WasElevated = $false
}

function Write-Reply {
    # $Path is passed rather than closed over: the reply is the only channel back to the parent,
    # so it should be obvious at the call site which file that is.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Reply)

    # The parent has no other way to learn what happened, so a reply is written even when
    # something throws on the way to writing one.
    try {
        $json = [pscustomobject]$Reply | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch {
        # Last resort. If even the minimal reply cannot be written the parent will report the
        # helper as having exited without reporting back, which is the truth.
        try {
            [System.IO.File]::WriteAllText($Path, '{"Success":false,"Error":"could not serialise reply"}')
        }
        catch {
            Write-Verbose "Could not write a reply to $Path : $($_.Exception.Message)"
        }
    }
}

try {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $reply.RanAs = $id.Name
    $reply.WasElevated = (New-Object System.Security.Principal.WindowsPrincipal($id)).IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $reply.WasElevated) {
        # Being launched without the token we were launched for is worth saying plainly rather
        # than letting the registration fail further down with a bare "Access is denied".
        throw 'This helper was started without an administrator token, so it cannot do anything the caller could not already do itself.'
    }

    $reply.Stage = 'import-module'
    $manifest = Join-Path $PSScriptRoot 'PSTSM.psd1'
    if (-not (Test-Path -LiteralPath $manifest)) { throw "PSTSM.psd1 not found next to this script ($PSScriptRoot)." }
    Import-Module $manifest -Force -ErrorAction Stop

    $reply.Stage = 'import-plan'
    # KeepEnginePath: the operator picked an engine in the parent window and saw the command it
    # produced. Re-resolving here could silently register a different one.
    $plan = Import-PSTSMPlan -Path $PlanPath -KeepEnginePath
    $reply.TaskName = $plan.TaskName
    $reply.TaskPath = $plan.TaskPath

    $password = $null
    if ($PromptForPassword) {
        $reply.Stage = 'prompt-password'
        $cred = $host.UI.PromptForCredential('Task account password',
            "Enter the password for $($plan.Principal.UserId). It goes straight to Task Scheduler and is not stored by PSTSM.",
            $plan.Principal.UserId, '')
        if (-not $cred) { throw 'Cancelled at the password prompt; nothing was registered.' }
        $password = $cred.Password
    }

    $reply.Stage = 'register'
    $registerArgs = @{ Plan = $plan; Confirm = $false }
    if ($password) { $registerArgs['Password'] = $password }
    Register-PSTSMPlan @registerArgs -WarningVariable warnings | Out-Null
    $reply.Warnings = @($warnings | ForEach-Object { $_.ToString() })

    if ($RemoveTaskName) {
        $reply.Stage = 'remove-renamed'
        try {
            Unregister-ScheduledTask -TaskName $RemoveTaskName -TaskPath $RemoveTaskPath -Confirm:$false -ErrorAction Stop
        }
        catch {
            # The save itself worked; a leftover old task is a warning, not a failure.
            $reply.Warnings += "The task was saved, but the original '$RemoveTaskName' could not be removed: $($_.Exception.Message)"
        }
    }

    $reply.Stage = 'done'
    $reply.Success = $true
}
catch {
    $reply.Error = $_.Exception.Message
}
finally {
    Write-Reply -Path $ResultPath -Reply $reply
}

if ($reply.Success) { exit 0 } else { exit 1 }
