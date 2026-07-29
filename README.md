# PSTaskBuilder

Build, validate, register and edit Windows scheduled tasks that run PowerShell scripts —
with the launch boilerplate derived from the script instead of retyped every time.

**Status: v0.2.0 — engine and UI both working.**

## Why

Nothing maintained does this. The Task Scheduler console knows nothing about PowerShell, so
every task means retyping `-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "..."`,
guessing at a logon type, and finding out at 3am which guess was wrong. This derives what can
be derived, defaults the rest sensibly, and names the specific ways a task fails unattended.

## Run it

```
.\Start-PSTaskBuilder.ps1
```

That opens the task list. The launcher handles the STA relaunch that `pwsh` needs — WinForms
requires an STA apartment and `pwsh` starts MTA, where a form either throws or deadlocks on its
first dialog.

**Main window** — every scheduled task, defaulting to the PowerShell ones and hiding the
built-in `\Microsoft\` tree (both are toggles). Unlike the built-in console it shows the actual
script each task runs, the engine, a readable schedule, and a *decoded* Last Run Result, so a
broken task is visible without opening anything. New / Edit / Run now / Enable / Disable /
Delete / Export.

**Editor** — pick a `.ps1` and the form fills itself in. The parameter section is generated
from the script's own `param()` block: switches become checkboxes, `ValidateSet` becomes a
combo, path-like parameters get a Browse button, mandatory ones are marked and enforced.
Declared defaults are pre-filled so the form and the preview always agree. The right pane shows
the exact command that will be registered and the live preflight; saving is blocked while any
`Error` check stands.

Editing an existing task opens the same form via `ConvertFrom-PSTaskDefinition`, so a task
created here reopens exactly as it was saved.

## Scripted use

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

These were established by experiment, not assumption, and all of them are load-bearing.
Do not "tidy" any of them without re-running the experiment.

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

3. **`@($list)` throws on Windows PowerShell 5.1** when `$list` is a
   `[System.Collections.Generic.List[object]]` — "Argument types do not match", regardless of
   element type. Plain arrays are fine on both runtimes. Everything here returns `.ToArray()`
   instead, and a lint test fails the build if `@(` ever wraps a List variable again.

4. **Event handlers are plain scriptblocks and must stay that way.** `.GetNewClosure()` severs
   module session-state affinity on 5.1: module functions become "not recognized" and
   `$script:` variables read empty. A lint test enforces this.

5. **A handler cannot assign to a caller's variable.** `$result = $x` inside a Click handler
   creates `$result` in the *handler's* scope, so the caller still sees `$null`. State crosses
   that boundary through a mutated hashtable. This shipped as a real bug — the trigger dialog
   returned nothing — and is now covered by a test that drives the real handler.

6. **`PerformClick()` is a no-op on a form that was never shown**, because it goes through
   `CanSelect` and `Visible` reads the *effective* value. Test seams that click a button must
   `Show()` the form first, or they silently prove nothing.

7. **No fixed pixel sizes.** Buttons are `AutoSize` with the requested width as a *minimum*,
   label columns are `AutoSize`, and list/grid row heights come from `Font.Height`. A hardcoded
   `Width = 104` clips its caption on any machine above 100% scaling — which is most laptops.
   The forms also run `AutoScaleMode = 'None'` on purpose: with `'Font'`, assigning `Form.Font`
   silently resizes the form (measured: a 1180×780 design became 1377×900), which happens
   *after* any `ClientSize` you set and invalidates it. The window size is applied explicitly
   and clamped to the screen's working area, because a high-DPI laptop can have as little as
   1512×901 of logical room and the action bar otherwise lands below the bottom edge.

   Tests cover this by re-laying out each window at a 150%-sized font and asserting that no
   button or label is smaller than its `PreferredSize`.

## Commands

**Script analysis** — `Get-PSTaskScriptProfile`, `Get-PSTaskEngine`

**Plan** — `New-PSTaskPlan`, `New-PSTaskTriggerSpec`, `Test-PSTaskPlan`,
`ConvertTo-PSTaskArgument`, `ConvertTo-PSTaskQuotedValue`, `Export-PSTaskPlan`,
`Import-PSTaskPlan`

**Task Scheduler** — `Get-PSTaskInventory`, `Register-PSTaskPlan`, `New-PSTaskLogWrapper`,
`ConvertFrom-PSTaskDefinition`, `ConvertFrom-PSTaskAction`, `ConvertTo-PSTaskCimTrigger`,
`ConvertFrom-PSTaskCimTrigger`, `ConvertFrom-PSTaskDuration`, `ConvertFrom-PSTaskResultCode`,
`ConvertFrom-PSTaskTriggerSummary`

**UI** — `Show-PSTaskBuilder`, `Show-PSTaskEditor`, `Show-PSTaskTriggerDialog`

The engine never references the UI, so it stays usable from a console, a build agent, or a
scheduled task of its own.

`Show-PSTaskEditor` is deliberately one long function rather than a set of smaller ones. Its
event handlers are plain scriptblocks that read the defining function's locals — the only
pattern that keeps module affinity on 5.1 (see #4 above) — and that only works while that
function's frame is on the stack, which it is for the whole life of a modal `ShowDialog`.
Splitting the handlers into separate functions would break them at runtime, not at parse time.

## Round-trip safety

`ConvertFrom-PSTaskDefinition` sets `IsFullyRecognized = $false` and preserves the original
`Execute`/`Arguments` in `RawAction` when a task was built some other way — inline `-Command`
code, a non-PowerShell action, or multiple actions. The UI must offer a raw-arguments box in
that case. Silently rewriting somebody's working task into our preferred shape is how you
break production.

## Tests

```powershell
Invoke-Pester -Path .\Tests\PSTaskBuilder.Tests.ps1      # engine, 86 tests
Invoke-Pester -Path .\Tests\PSTaskBuilder.UI.Tests.ps1   # UI, 23 tests
```

Nothing in either suite registers a real scheduled task. The engine suite is offline apart from
one test that launches PowerShell to prove wrapper argument forwarding. The UI suite lints for
the 5.1 hazards above, builds every window headlessly and asserts control bounds, then shows
and pumps them with a thread-exception trap — `DrawToBitmap` renders chrome only and misses
show-time failures.

**Run both under `powershell.exe` as well as `pwsh`.** 5.1 is where the binder bugs surface,
and the UI form tests skip themselves under MTA:

```powershell
powershell.exe -STA -File <runner>   # or: pwsh -STA
```

A green MTA run means much less than it looks like; the suite prints which apartment it used.

## Requirements

Windows PowerShell 5.1 or PowerShell 7+, on Windows. The `ScheduledTasks` module (in-box) is
needed only for `Get-PSTaskInventory`, `Register-PSTaskPlan` and `ConvertFrom-PSTaskDefinition`;
the derivation and argument-building commands run anywhere. Registering a task generally
requires elevation.

Set `PSTASKBUILDER_NODIALOG=1` in any automated run. Without it, an exception inside a WinForms
handler reaches the global handler and pops a modal message box on the desktop of whoever is at
the machine.

## Next

- Multi-machine apply: push an exported plan to a list of servers over WinRM.
- Event triggers (`MSFT_TaskEventTrigger`) in the trigger dialog; they round-trip today but
  cannot yet be created from the UI.
- A history pane reading the Task Scheduler operational log for the selected task.
