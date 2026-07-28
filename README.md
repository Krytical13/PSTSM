# PSTaskBuilder

Build, validate, register and edit Windows scheduled tasks that run PowerShell scripts —
with the launch boilerplate derived from the script instead of retyped every time.

**Status: engine complete (v0.1.0). The WinForms UI is not built yet.** Every command below
works today from the console and is what the UI will bind to.

## Why

Nothing maintained does this. The Task Scheduler console knows nothing about PowerShell, so
every task means retyping `-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "..."`,
guessing at a logon type, and finding out at 3am which guess was wrong. This derives what can
be derived, defaults the rest sensibly, and names the specific ways a task fails unattended.

## Quick start

```powershell
Import-Module .\PSTaskBuilder.psd1

# Everything below the script path is derived and overridable.
$plan = New-PSTaskPlan -ScriptPath 'D:\Scripts\Send-NightlyReport.ps1' `
                       -Parameters ([ordered]@{ SmtpServer = 'mail.contoso.com'; DaysOut = 14 }) `
                       -TaskPath   'Custom' `
                       -Trigger    (New-PSTaskTriggerSpec -Type Daily -At '07:00' -RandomDelay '00:05:00')

$plan.ArgumentString          # exactly what gets registered
Test-PSTaskPlan -Plan $plan   # preflight before anything is written
Register-PSTaskPlan -Plan $plan
```

Browse and edit what already exists:

```powershell
Get-PSTaskInventory -PowerShellOnly |
    Format-Table TaskName, State, LastResultText, ScriptName, TriggerSummary

$plan = ConvertFrom-PSTaskDefinition -TaskName 'Send-NightlyReport' -TaskPath '\Custom\'
$plan.Triggers = @(New-PSTaskTriggerSpec -Type Daily -At '06:00')
Register-PSTaskPlan -Plan $plan
```

Config-as-code:

```powershell
Export-PSTaskPlan -Plan $plan -Path .\Plans\NightlyReport.task.json
Import-PSTaskPlan -Path .\Plans\NightlyReport.task.json | Register-PSTaskPlan
```

## What gets derived from the script

One `Parser::ParseFile` call — the script is never executed.

| Field | Source |
|---|---|
| Engine (`pwsh` / `powershell`, 32- or 64-bit) | `#Requires -Version` / `-PSEdition`, else machine default |
| Elevation | `#Requires -RunAsAdministrator` |
| Required modules | `#Requires -Modules` |
| Task name | script base name |
| Description | `.SYNOPSIS` |
| Working directory | script's own folder |
| **Parameters** | `param()` block: name, type, switch, mandatory, default, `ValidateSet`, `ValidateRange`, aliases, per-parameter help |

`Get-PSTaskScriptProfile` also returns UI hints (`IsPathLike` → Browse button, `IsCredential` →
refuse rather than put a secret on a command line) and the behavioural signals the preflight
consumes.

## Preflight (`Test-PSTaskPlan`)

Every check answers one question: *this works in my console — will it still work when Task
Scheduler runs it?* `Error` blocks registration, `Warning` is a real risk to acknowledge.

- `S4U_NETWORK` — S4U holds **no network credentials**. Raised only when the script actually
  reaches the network. This is the single most common "works by hand, fails on the schedule".
- `MODULE_USERSCOPE` — module installed only under your profile; SYSTEM/gMSA will not see it.
- `INTERACTIVE` / `GUI` — `Read-Host`, `Get-Credential`, WinForms: nobody is there to answer.
- `EXIT_CODE` — no `exit`/`throw`, so Last Run Result reads `0x0` even when the script failed.
- `ENCODING` — UTF-8 without BOM under Windows PowerShell 5.1 silently mangles non-ASCII.
- `ENGINE_VERSION` / `ENGINE_EDITION`, `ELEVATION`, `PARAM_MANDATORY`, `PARAM_UNKNOWN`,
  `PARAM_CREDENTIAL`, `WORKDIR`, `SCRIPT_IN_PROFILE`, `SCRIPT_ON_UNC`, `NO_TRIGGERS`,
  `BATCH_RIGHT`, `PASSWORD_ROTATION`, `TASK_EXISTS`.

## Defaults that differ from Task Scheduler's

Task Scheduler's defaults are tuned for interactive desktop tasks. These are not:

| Setting | Here | Built-in | Why |
|---|---|---|---|
| `MultipleInstances` | `IgnoreNew` | Parallel | a slow run must not stack on itself |
| `ExecutionTimeLimit` | 4 hours | 3 days | a wedged task otherwise blocks every later run |
| `DisallowStartIfOnBatteries` | off | **on** | the built-in default silently skips every run on a laptop |
| `StartWhenAvailable` | on | off | catch up after the machine was off |
| `RestartCount` / `Interval` | 3 / 5 min | none | transient DC and network blips resolve themselves |

## Logging

`Logging.Mode = 'Transcript'` (default) generates `<ScriptDir>\.pstask\<TaskName>.wrapper.ps1`
and points the action at it. The wrapper starts a transcript, forwards the arguments
unchanged, converts a terminating error into `exit 1`, propagates `$LASTEXITCODE`, and prunes
logs past `RetentionDays`. It is regenerated on every save and carries a do-not-edit header —
it is build output, not source. `ConvertFrom-PSTaskDefinition` sees through it, so editing a
task shows your script, not the shim. Set `Mode = 'None'` to point the action straight at the
script.

If your scripts live in a repo, add `.pstask/` to its `.gitignore` — the wrappers are
generated per machine and per task, and there is no reason to track them.

## Verified behaviour

Two things here were established by experiment, not assumption, and both are load-bearing:

1. **Argument quoting.** Five candidate encoders were run against 11 hostile values (trailing
   backslash, embedded quotes, UNC, `&`, `;`, `$`, backtick, parens) on both Windows PowerShell
   5.1 and PowerShell 7. Only the `CommandLineToArgvW` rule — doubling backslash runs before a
   quote and at end-of-argument — is correct in every case. That is what
   `ConvertTo-PSTaskQuotedValue` implements.

2. **Wrapper argument forwarding.** An advanced function with
   `[Parameter(ValueFromRemainingArguments)]` **swallows the `-Name` tokens and re-binds the
   values positionally**, so `-Label "hello world"` arrives as two positional arguments and
   binding fails. Confirmed broken on both engines. The wrapper deliberately has no `param()`
   block and uses the automatic `$args` with array splatting, which round-trips exactly.

Do not "tidy" either of these without re-running the experiments.

## Commands

**Script analysis** — `Get-PSTaskScriptProfile`, `Get-PSTaskEngine`

**Plan** — `New-PSTaskPlan`, `New-PSTaskTriggerSpec`, `Test-PSTaskPlan`,
`ConvertTo-PSTaskArgument`, `ConvertTo-PSTaskQuotedValue`, `Export-PSTaskPlan`,
`Import-PSTaskPlan`

**Task Scheduler** — `Get-PSTaskInventory`, `Register-PSTaskPlan`, `New-PSTaskLogWrapper`,
`ConvertFrom-PSTaskDefinition`, `ConvertFrom-PSTaskAction`, `ConvertTo-PSTaskCimTrigger`,
`ConvertFrom-PSTaskCimTrigger`, `ConvertFrom-PSTaskDuration`, `ConvertFrom-PSTaskResultCode`,
`ConvertFrom-PSTaskTriggerSummary`

## Round-trip safety

`ConvertFrom-PSTaskDefinition` sets `IsFullyRecognized = $false` and preserves the original
`Execute`/`Arguments` in `RawAction` when a task was built some other way — inline `-Command`
code, a non-PowerShell action, or multiple actions. The UI must offer a raw-arguments box in
that case. Silently rewriting somebody's working task into our preferred shape is how you
break production.

## Tests

```powershell
Invoke-Pester -Path .\Tests\PSTaskBuilder.Tests.ps1
```

86 tests, offline apart from one that launches the engine to prove wrapper forwarding. Nothing
in the suite registers a real scheduled task.

## Requirements

Windows PowerShell 5.1 or PowerShell 7+. The `ScheduledTasks` module (in-box) is needed only
for `Get-PSTaskInventory`, `Register-PSTaskPlan` and `ConvertFrom-PSTaskDefinition`; the
derivation and argument-building commands run anywhere. Registering a task generally requires
elevation.

## Next

The WinForms front end: task list with `Get-PSTaskInventory`, the derived parameter form,
live command preview, inline preflight, and an editor that opens any row via
`ConvertFrom-PSTaskDefinition`.
