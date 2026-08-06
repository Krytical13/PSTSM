# SPDX-License-Identifier: GPL-3.0-or-later
Import-Module D:\Github\PSTSM\PSTSM.psd1 -Force
$ErrorActionPreference = 'Stop'

$name = 'PSTSM-E2E-Multi'
$path = '\PSTSM-E2E\'
Unregister-ScheduledTask -TaskName $name -TaskPath $path -Confirm:$false -ErrorAction SilentlyContinue

$a1 = New-ScheduledTaskAction -Execute 'C:\Windows\System32\robocopy.exe' -Argument '"C:\A" "C:\B" /MIR /LOG:"C:\x y.txt"'
$a2 = New-ScheduledTaskAction -Execute 'C:\Windows\System32\cmd.exe' -Argument '/c echo "second action"'
$tr = New-ScheduledTaskTrigger -Daily -At '03:00'
$pr = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U -RunLevel Limited
$null = Register-ScheduledTask -TaskName $name -TaskPath $path -Action @($a1, $a2) -Trigger $tr -Principal $pr -Description 'original' -Force

$before = Get-ScheduledTask -TaskName $name -TaskPath $path
$plan = ConvertFrom-PSTSMDefinition -TaskName $name -TaskPath $path
Write-Output "=== a two-action task ==="
"  ActionKind : $($plan.ActionKind)   (Unsupported - only the first action fits a plan)"
"  actions    : $(@($before.Actions).Count)"
"  trigger    : $(@($before.Triggers)[0].StartBoundary)"
"  wake       : $($before.Settings.WakeToRun)"

Write-Output ""
Write-Output "=== change ONLY the schedule via Update-PSTSMTaskSchedule ==="
$plan.Triggers = @(New-PSTSMTriggerSpec -Type Weekly -DaysOfWeek 'Monday' -At '07:15')
$plan.Settings.WakeToRun = $true
$plan.Description = 'edited by Update-PSTSMTaskSchedule'
$null = Update-PSTSMTaskSchedule -Plan $plan -Confirm:$false

$after = Get-ScheduledTask -TaskName $name -TaskPath $path
"  actions    : $(@($after.Actions).Count)"
"  trigger    : $(@($after.Triggers)[0].StartBoundary)"
"  wake       : $($after.Settings.WakeToRun)"
"  desc       : $($after.Description)"

Write-Output ""
Write-Output "=== both actions byte-identical? ==="
$allSame = $true
for ($i = 0; $i -lt @($before.Actions).Count; $i++) {
    $b = @($before.Actions)[$i]; $a = @($after.Actions)[$i]
    $same = ($b.Execute -ceq $a.Execute) -and ($b.Arguments -ceq $a.Arguments)
    if (-not $same) { $allSame = $false }
    "  [$i] $($b.Execute | Split-Path -Leaf)  same=$same"
    "      '$($b.Arguments)'"
    "      '$($a.Arguments)'"
}
"  ALL PRESERVED: $allSame"

Write-Output ""
Write-Output "=== refuses to create a task that does not exist ==="
$plan.TaskName = 'PSTSM-E2E-NoSuchTask'
try { Update-PSTSMTaskSchedule -Plan $plan -Confirm:$false; "  FAIL - it created one" }
catch { "  threw as expected: $($_.Exception.Message.Substring(0,60))..." }

Unregister-ScheduledTask -TaskName $name -TaskPath $path -Confirm:$false -ErrorAction SilentlyContinue
try { $svc = New-Object -ComObject 'Schedule.Service'; $svc.Connect(); $svc.GetFolder('\').DeleteFolder('PSTSM-E2E', 0) } catch { }
Write-Output ""
Write-Output "cleaned up"
