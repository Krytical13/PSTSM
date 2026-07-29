# SPDX-License-Identifier: GPL-3.0-or-later
function Get-PSTSMTaskRunLog {
    <#
    .SYNOPSIS
        Retrieves what actually happened the last time a task ran.
    .DESCRIPTION
        "Last Run Result: 0x1" tells you a task failed and nothing else. This finds the detail,
        from whichever of two sources exists:

          Transcript - for a task PSTSM built with logging on, the generated wrapper writes a
          per-run transcript. This is the good source: it has the arguments, the account, the
          script's own output and the real error. Found by reading the log directory back out
          of the wrapper, so it works even if the task was built on another machine.

          Event log - Microsoft-Windows-TaskScheduler/Operational, for any task at all. Worth
          knowing: that log is DISABLED by default on Windows, so on most machines it holds
          nothing until somebody turns it on. When it is off this says so, and how to enable it,
          rather than reporting "no history" as though the task had never run.
    .PARAMETER TaskName
        Task to look up.
    .PARAMETER TaskPath
        Folder the task is in. Default '\'.
    .PARAMETER Newest
        How many transcripts / event batches to return. Default 1.
    .OUTPUTS
        [pscustomobject] Source, Available, Path, Timestamp, Content, Note
    .EXAMPLE
        Get-PSTSMTaskRunLog -TaskName 'Send-NightlyReport' -TaskPath '\Custom\'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TaskName,

        [string]$TaskPath = '\',

        [ValidateRange(1, 50)]
        [int]$Newest = 1
    )

    $task = $null
    try { $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop }
    catch { throw "Task '$TaskPath$TaskName' not found: $($_.Exception.Message)" }

    # --- 1. transcript, if this is one of ours ------------------------------------------
    $logDir = $null
    $action = @($task.Actions | Where-Object { $null -ne $_ })[0]
    if ($action -and $action.CimClass.CimClassName -eq 'MSFT_TaskExecAction') {
        $parsed = ConvertFrom-PSTSMAction -Execute ([string]$action.Execute) -Arguments ([string]$action.Arguments)
        if ($parsed.ScriptPath -and $parsed.ScriptPath -match '\\\.pstsm\\.+\.wrapper\.ps1$') {
            try {
                $wrapperText = Get-Content -LiteralPath $parsed.ScriptPath -Raw -ErrorAction Stop
                if ($wrapperText -match "(?m)^\s*\`$logDirectory\s*=\s*'(?<d>.+?)'\s*$") { $logDir = $Matches['d'] -replace "''", "'" }
            }
            catch { Write-Verbose "Could not read the wrapper: $($_.Exception.Message)" }
        }
    }

    if ($logDir -and (Test-Path -LiteralPath $logDir)) {
        $logs = @(Get-ChildItem -LiteralPath $logDir -Filter '*.log' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First $Newest)
        if ($logs.Count -gt 0) {
            foreach ($l in $logs) {
                [PSCustomObject]@{
                    PSTypeName = 'PSTSM.RunLog'
                    Source     = 'Transcript'
                    Available  = $true
                    Path       = $l.FullName
                    Timestamp  = $l.LastWriteTime
                    Content    = (Get-Content -LiteralPath $l.FullName -Raw -ErrorAction SilentlyContinue)
                    Note       = $null
                }
            }
            return
        }
        [PSCustomObject]@{
            PSTypeName = 'PSTSM.RunLog'; Source = 'Transcript'; Available = $false
            Path       = $logDir; Timestamp = $null; Content = $null
            Note       = "Logging is on for this task but $logDir holds no transcripts yet - it has not run since logging was enabled."
        }
        return
    }

    # --- 2. fall back to the operational log --------------------------------------------
    $logName = 'Microsoft-Windows-TaskScheduler/Operational'
    $log = Get-WinEvent -ListLog $logName -ErrorAction SilentlyContinue

    if (-not $log) {
        [PSCustomObject]@{
            PSTypeName = 'PSTSM.RunLog'; Source = 'EventLog'; Available = $false
            Path       = $logName; Timestamp = $null; Content = $null
            Note       = 'The Task Scheduler operational log is not present on this machine.'
        }
        return
    }

    if (-not $log.IsEnabled) {
        [PSCustomObject]@{
            PSTypeName = 'PSTSM.RunLog'; Source = 'EventLog'; Available = $false
            Path       = $logName; Timestamp = $null; Content = $null
            Note       = ("Windows ships the Task Scheduler operational log DISABLED, so there is no history for any task " +
                "on this machine - not just this one. Turn it on with:" + [Environment]::NewLine + [Environment]::NewLine +
                "    wevtutil set-log `"$logName`" /enabled:true" + [Environment]::NewLine + [Environment]::NewLine +
                "It only records from that point on. For detail you can rely on, build the task with PSTSM's " +
                "Transcript logging - that writes a full per-run log regardless of this setting.")
        }
        return
    }

    $full = "$TaskPath$TaskName"
    try {
        # TaskName is the first property on these events, so filter on it rather than reading
        # the whole log and matching message text.
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = $logName } -MaxEvents 2000 -ErrorAction Stop |
                Where-Object { $_.Properties.Count -gt 0 -and [string]$_.Properties[0].Value -eq $full } |
                Select-Object -First ($Newest * 20))

        if ($events.Count -eq 0) {
            [PSCustomObject]@{
                PSTypeName = 'PSTSM.RunLog'; Source = 'EventLog'; Available = $false
                Path       = $logName; Timestamp = $null; Content = $null
                Note       = "The operational log is enabled but holds no entries for $full yet."
            }
            return
        }

        $text = ($events | Sort-Object TimeCreated |
                ForEach-Object { "{0:yyyy-MM-dd HH:mm:ss}  [{1,-4}] {2}" -f $_.TimeCreated, $_.Id, (($_.Message -split "`r?`n")[0]) }) -join [Environment]::NewLine

        [PSCustomObject]@{
            PSTypeName = 'PSTSM.RunLog'
            Source     = 'EventLog'
            Available  = $true
            Path       = $logName
            Timestamp  = ($events | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
            Content    = $text
            Note       = 'From the Task Scheduler operational log. It records that things happened, not what the script printed.'
        }
    }
    catch {
        [PSCustomObject]@{
            PSTypeName = 'PSTSM.RunLog'; Source = 'EventLog'; Available = $false
            Path       = $logName; Timestamp = $null; Content = $null
            Note       = "Could not read the operational log: $($_.Exception.Message)"
        }
    }
}
