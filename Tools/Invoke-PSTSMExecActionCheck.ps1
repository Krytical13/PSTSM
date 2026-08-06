# SPDX-License-Identifier: GPL-3.0-or-later
Import-Module D:\Github\PSTSM\PSTSM.psd1 -Force
$ErrorActionPreference = 'Stop'

$name = 'PSTSM-E2E-Exec'
$path = '\PSTSM-E2E\'
$exe = 'C:\Windows\System32\robocopy.exe'
$argStr = '"C:\Temp\A" "C:\Temp\B" /MIR /R:2 /W:5 /LOG:"C:\Temp\log with space.txt"'
$wd = 'C:\Windows'

function Cleanup {
    Unregister-ScheduledTask -TaskName $name -TaskPath $path -Confirm:$false -ErrorAction SilentlyContinue
}
Cleanup

# --- register a non-PowerShell task the way a human would, outside PSTSM -------------------
$a = New-ScheduledTaskAction -Execute $exe -Argument $argStr -WorkingDirectory $wd
$t = New-ScheduledTaskTrigger -Daily -At '03:00'
$p = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U -RunLevel Limited
$null = Register-ScheduledTask -TaskName $name -TaskPath $path -Action $a -Trigger $t -Principal $p -Force
Write-Output "registered: $path$name"

$origAction = (Get-ScheduledTask -TaskName $name -TaskPath $path).Actions[0]
Write-Output ""
Write-Output "=== 1. does PSTSM classify it as editable? ==="
$plan = ConvertFrom-PSTSMDefinition -TaskName $name -TaskPath $path
"  ActionKind        : $($plan.ActionKind)"
"  IsFullyRecognized : $($plan.IsFullyRecognized)   (still false - the SCRIPT form does not apply)"
"  RawAction.Execute : $($plan.RawAction.Execute)"
"  Arguments match   : $($plan.RawAction.Arguments -ceq $origAction.Arguments)"

Write-Output ""
Write-Output "=== 2. does preflight let it save? ==="
$checks = @(Test-PSTSMPlan -Plan $plan -CanElevate)
$errs = @($checks | Where-Object Severity -eq 'Error')
"  errors: $($errs.Count)   (0 means Save is enabled)"
foreach ($c in $checks | Where-Object { $_.Severity -in 'Error', 'Warning' }) { "    [$($c.Severity)] $($c.Id): $($c.Title)" }
"  script-specific checks leaked in? : $([bool](@($checks | Where-Object { $_.Id -in 'SCRIPT_MISSING','ENGINE_MISSING','EXIT_CODE','SCRIPT_PARSE' }).Count))"

Write-Output ""
Write-Output "=== 3. change ONLY the schedule, then re-register ==="
$plan.Triggers = @(New-PSTSMTriggerSpec -Type Daily -At '05:30')
$plan.Description = 'Edited by PSTSM end-to-end test'
$null = Register-PSTSMPlan -Plan $plan -Force
$after = Get-ScheduledTask -TaskName $name -TaskPath $path
$newAction = $after.Actions[0]

Write-Output ""
Write-Output "=== 4. is the action byte-identical? ==="
"  Execute          : $($newAction.Execute -ceq $origAction.Execute)"
"  Arguments        : $($newAction.Arguments -ceq $origAction.Arguments)"
"  WorkingDirectory : $($newAction.WorkingDirectory -ceq $origAction.WorkingDirectory)"
"  action count     : $(@($after.Actions).Count) (was 1)"
Write-Output ""
"  original args : $($origAction.Arguments)"
"  now           : $($newAction.Arguments)"
Write-Output ""
"  new trigger   : $(@($after.Triggers)[0].StartBoundary)"
"  description   : $($after.Description)"

Cleanup
Unregister-ScheduledTask -TaskPath $path -Confirm:$false -ErrorAction SilentlyContinue
try { (New-Object -ComObject 'Schedule.Service').Connect(); $svc = New-Object -ComObject 'Schedule.Service'; $svc.Connect(); $svc.GetFolder('\').DeleteFolder('PSTSM-E2E', 0) } catch { }
Write-Output ""
Write-Output "cleaned up"
