# SPDX-License-Identifier: GPL-3.0-or-later
function Test-PSTSMTaskExists {
    <#
    .SYNOPSIS
        Answers "is a task already registered under this name?" without enumerating Task Scheduler.
    .DESCRIPTION
        Get-ScheduledTask -TaskName still walks every folder and filters afterwards, so the
        question costs the same as listing the whole machine - about 380ms here against 290 tasks.
        That was tolerable when only Register-PSTSMPlan asked it. It stopped being tolerable when
        Test-PSTSMPlan started running on every keystroke in the editor, where it was 94% of the
        387ms each character cost.

        The Schedule.Service COM API answers the same question with a direct folder+name lookup
        and no enumeration, in about 0.3ms. Both agree on the two cases that exist - the task is
        there, or it is not - which is all this is asked.

        The service handle is cached because Connect() is the expensive half. Any COM failure
        falls back to the cmdlet rather than reporting a wrong answer: a false negative here
        would let the caller silently overwrite somebody's registered task.
    .PARAMETER TaskName
        Name of the task, without a path.
    .PARAMETER TaskPath
        Task Scheduler folder. Default '\'.
    .OUTPUTS
        [bool]
    .EXAMPLE
        Test-PSTSMTaskExists -TaskName 'Nightly Report' -TaskPath '\Custom\'
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$TaskName,

        [string]$TaskPath = '\'
    )

    # COM wants '\' for the root and no trailing separator anywhere else; PSTSM carries paths in
    # the cmdlet's shape ('\', '\Custom\'), so normalise rather than making every caller do it.
    $folderPath = if ([string]::IsNullOrWhiteSpace($TaskPath)) { '\' } else { $TaskPath.TrimEnd('\') }
    if ([string]::IsNullOrEmpty($folderPath)) { $folderPath = '\' }

    if (-not $script:PSTSMScheduleService) {
        try {
            $svc = New-Object -ComObject 'Schedule.Service'
            $svc.Connect()
            $script:PSTSMScheduleService = $svc
        }
        catch {
            Write-Verbose "Schedule.Service unavailable, falling back to Get-ScheduledTask: $($_.Exception.Message)"
            $script:PSTSMScheduleService = $null
        }
    }

    if ($script:PSTSMScheduleService) {
        try {
            $folder = $script:PSTSMScheduleService.GetFolder($folderPath)
            $null = $folder.GetTask($TaskName)
            return $true
        }
        catch {
            # Matched on the HRESULT, not the exception type. A missing folder and a missing task
            # both surface as 0x80070002 (ERROR_FILE_NOT_FOUND), and both mean the same thing here:
            # no task is registered under that name.
            #
            # The .NET type is a translation artifact and cannot be relied on. The runtime maps
            # this HRESULT to System.IO.FileNotFoundException - not COMException, and not
            # MethodInvocationException - on both Windows PowerShell 5.1 and PowerShell 7. An
            # earlier version of this caught MethodInvocationException, matched nothing, and fell
            # through to the cmdlet on every miss: correct answers, at the 380ms this exists to avoid.
            $ex = $_.Exception
            while ($ex.InnerException) { $ex = $ex.InnerException }
            if ($ex.HResult -eq -2147024894) { return $false }   # 0x80070002

            # Anything else is a real failure. Drop the cached handle so the next call reconnects,
            # and let the cmdlet answer rather than guessing - a wrong "no" here would let the
            # caller silently overwrite a registered task.
            Write-Verbose "Schedule.Service lookup failed, falling back to Get-ScheduledTask: $($_.Exception.Message)"
            $script:PSTSMScheduleService = $null
        }
    }

    [bool](Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue)
}
