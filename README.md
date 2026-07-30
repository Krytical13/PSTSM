# PSTSM

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

Build, validate, register and edit Windows scheduled tasks that run PowerShell scripts —
with the launch boilerplate derived from the script instead of retyped every time.

**Status: v0.2.0 — engine and UI both working.**

## Why

Nothing maintained does this. The Task Scheduler console knows nothing about PowerShell, so
every task means retyping `-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "..."`,
guessing at a logon type, and finding out at 3am which guess was wrong. This derives what can
be derived, defaults the rest sensibly, and names the specific ways a task fails unattended.

## Run it

**Double-click `PSTSM.cmd`.** No UAC prompt.

That's the entry point because Windows opens a `.ps1` in an editor rather than running it. It
hands off to `Start-PSTSM.ps1`, which sorts out the STA apartment WinForms requires — `pwsh`
starts MTA, where a form either throws or deadlocks on its first dialog.

### Elevation belongs to the task, not to opening the tool

PSTSM opens unelevated and stays that way until something actually needs otherwise. Most work
never does, and demanding a prompt up front would lock out exactly the people managing their own
scheduled work.

Only a short list of registrations needs an administrator token:

| | Needs admin? |
|---|---|
| Register / edit / delete a task that runs as **you** at normal privilege | no |
| Browse, edit, health sweep, run logs — the whole read-only surface | no |
| **Run with highest privileges** | **yes** |
| Run as **SYSTEM / LOCAL SERVICE / NETWORK SERVICE** | **yes** |
| Run for a **group** | **yes** |
| An **at-startup** trigger | **yes** |
| `Install-ADServiceAccount`, granting the batch-logon right | **yes** |

Windows *refuses* those outright rather than quietly downgrading them, so when a plan asks for one
the **Save** button takes a shield and elevates for that single registration — one consent prompt,
no restart, and everything you typed is still there afterwards. Decline the prompt and nothing
happens at all; the window is exactly as you left it.

That mechanism is Microsoft's [Administrator Broker Model](https://learn.microsoft.com/windows/win32/secauthz/developing-applications-that-require-administrator-privilege):
a short-lived elevated helper does the one privileged thing and exits. It works that way because
Windows cannot raise the privileges of a process that is already running — elevation happens at
process creation and nowhere else, so "elevate on save" has to mean "start something elevated that
saves". What crosses the boundary is a plan file that carries no secret, and a reply file; both
live in a private temp directory that is deleted afterwards. A stored-password task is the one case
needing a credential, and the helper prompts for it itself, so the password only ever exists inside
the elevated process that consumes it.

If you would rather elevate once and not be asked again — installing a gMSA, granting batch-logon
rights, working through a run of privileged tasks — **Restart as admin** sits in the footer, and
`PSTSM.cmd -Elevated` does it from the start.

<details>
<summary>Why Task Scheduler looks like it does this differently</summary>

Open `taskschd.msc`, tick **Run with highest privileges**, save, and it asks for a username and
password — which looks like elevation happening at the point of the action. It isn't, twice over.

`mmc.exe` ships with `requestedExecutionLevel level="highestAvailable"`, so when an administrator
opens Task Scheduler **Windows elevates it at launch** — silently, with no prompt, because it is a
signed Windows binary. It is already elevated before you tick anything.

The dialog at save time is asking for the *task's* run-as account password, so the service can
store it as an LSA secret and log the task on later. It is triggered by "Run whether user is logged
on or not" without "Do not store password", not by the privileges checkbox. Microsoft keeps the two
strictly separate: *"the user must supply the correct credentials when a task is registered **and**
the application must be running in a process with the correct privileges."* Two conditions, both
required — credentials never substitute for privilege.

PSTSM doesn't take MMC's route because silently elevating an administrator on launch is the very
thing that makes a tool unusable for everyone else, and it grants far more privilege than one
registration needs.

</details>

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

Editing an existing task opens the same form via `ConvertFrom-PSTSMDefinition`, so a task
created here reopens exactly as it was saved.

## Scripted use

```powershell
Import-Module .\PSTSM.psd1

# Everything below the script path is derived and overridable.
$plan = New-PSTSMPlan -ScriptPath 'D:\Scripts\Send-NightlyReport.ps1' `
                       -Parameters ([ordered]@{ SmtpServer = 'mail.contoso.com'; DaysOut = 14 }) `
                       -TaskPath   'Custom' `
                       -Trigger    (New-PSTSMTriggerSpec -Type Daily -At '07:00' -RandomDelay '00:05:00')

$plan.ArgumentString          # exactly what gets registered
Test-PSTSMPlan -Plan $plan   # preflight before anything is written
Register-PSTSMPlan -Plan $plan
```

Browse and edit what already exists:

```powershell
Get-PSTSMInventory -PowerShellOnly |
    Format-Table TaskName, State, LastResultText, ScriptName, TriggerSummary

$plan = ConvertFrom-PSTSMDefinition -TaskName 'Send-NightlyReport' -TaskPath '\Custom\'
$plan.Triggers = @(New-PSTSMTriggerSpec -Type Daily -At '06:00')
Register-PSTSMPlan -Plan $plan
```

Config-as-code:

```powershell
Export-PSTSMPlan -Plan $plan -Path .\Plans\NightlyReport.task.json
Import-PSTSMPlan -Path .\Plans\NightlyReport.task.json | Register-PSTSMPlan
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

`Get-PSTSMScriptProfile` also returns UI hints (`IsPathLike` → Browse button, `IsCredential` →
refuse rather than put a secret on a command line) and the behavioural signals the preflight
consumes.

### Defaults, and why some are shown but not filled in

Parameter defaults come in three kinds, and they are treated differently on purpose:

| Kind | Example | In the form |
|---|---|---|
| **Literal** | `= 14`, `= 'Normal'` | pre-filled as a real value |
| **Resolved** | `= (Join-Path $env:ProgramData 'Acme\Logs')` | shown greyed, as a hint |
| **Unresolved** | `= (Get-Date).AddDays(-7)` | source text shown as a hint |

**Nothing is ever executed to work this out.** This tool gets pointed at scripts you did not
write, so opening one must never be a way to run it — a default could as easily be
`(Get-Content C:\secrets\key.txt)`. `Resolve-PSTSMDefaultValue` walks the AST and computes a
value only for a provably side-effect-free shape: literals, `$PSScriptRoot`, `$env:*`,
`Join-Path`, `+` concatenation, and interpolated strings made only of those. Everything else
stays unresolved and is displayed as text.

A **Resolved** default is deliberately *not* put on the command line either. The script computes
the same thing at run time, and passing it would freeze anything time-dependent and put a value
on the command line the operator never chose. Leaving the box empty means "let the script decide"
— the hint just makes that visible rather than looking like the form knows nothing.

### Settings files

Scripts built for unattended use often keep their real configuration next door:

```powershell
[string]$ConfigPath = (Join-Path $PSScriptRoot 'settings.psd1')
```

That file is a hard dependency of the task that Task Scheduler will never mention, and it fails
the same ways the script does. When a parameter's *name* looks like configuration and its default
*resolves* to a real path, the preflight checks it: exists, parses, and is somewhere the task
account can actually read (a config in your user profile or on a UNC share gets the same warning
the script would). `.psd1` is read with `Import-PowerShellDataFile`, which refuses dynamic
expressions rather than evaluating them; `.json` with `ConvertFrom-Json`. Top-level keys are
listed so you can confirm it is the file you meant — nothing is interpreted, because the tool
cannot know what any of those keys mean.

## Preflight (`Test-PSTSMPlan`)

Every check answers one question: *this works in my console — will it still work when Task
Scheduler runs it?* `Error` blocks registration, `Warning` is a real risk to acknowledge.

- `S4U_NETWORK` / `S4U_DPAPI` — see below. The most common "works by hand, fails on the
  schedule", raised only when the script actually does the thing that breaks.
- `MODULE_USERSCOPE` — module installed only under your profile; SYSTEM/gMSA will not see it.
- `INTERACTIVE` / `GUI` — `Read-Host`, `Get-Credential`, WinForms: nobody is there to answer.
- `EXIT_CODE` — no `exit`/`throw`, so Last Run Result reads `0x0` even when the script failed.
- `ENCODING` — UTF-8 without BOM under Windows PowerShell 5.1 silently mangles non-ASCII.
- `ENGINE_VERSION` / `ENGINE_EDITION`, `ELEVATION`, `PARAM_MANDATORY`, `PARAM_UNKNOWN`,
  `PARAM_CREDENTIAL`, `WORKDIR`, `SCRIPT_IN_PROFILE`, `SCRIPT_ON_UNC`, `NO_TRIGGERS`,
  `BATCH_RIGHT`, `PASSWORD_ROTATION`, `TASK_EXISTS`.

## What S4U actually costs you

"Run whether user is logged on or not" + "Do not store password" is an **S4U** logon: Task
Scheduler uses Kerberos S4U2Self to mint a token for the account without its password. Microsoft
summarises the consequence as *"no password is stored by the system and there is no access to
either the network or encrypted files"* — which is blunter than what happens in practice, and
worth stating precisely because it drives two of the checks:

| | Under S4U |
|---|---|
| Sockets, DNS, outbound HTTPS to a public endpoint | **Works** — connectivity is not gated by the token |
| A REST call authenticated by a bearer/OAuth token | **Works** — app-layer auth, not Windows auth |
| `\\server\share`, LDAP/`Get-AD*`, WinRM, SQL Integrated Security, `-UseDefaultCredentials` | **Fails** |
| Identity presented to those services | **ANONYMOUS** |
| DPAPI user-scope secrets (`ConvertTo-SecureString` on a stored blob, `Import-Clixml` credentials) | **Fails to decrypt** |

Two things people get wrong:

- **It is not "no internet".** Connectivity is fine; *authentication as that user* is what is
  missing.
- **It does not fall back to the machine account.** `DOMAIN\COMPUTER$` is what **SYSTEM** and
  **NETWORK SERVICE** present on the network, and that is a real identity that can authenticate.
  S4U has none. That is precisely why SYSTEM is a genuine alternative rather than a sideways
  move — and why a gMSA is usually the right answer when the script needs to be *itself* on the
  network.

The DPAPI case is the non-obvious one: the master key is unlocked from the account's password,
so a secret that decrypts perfectly when you run the script by hand fails on the schedule. The
check matches the unambiguous primitives only (keyless `ConvertTo-`/`ConvertFrom-SecureString`,
`ProtectedData`); a helper of your own that wraps them will not be spotted.

### Running as a gMSA

Pick the **gMSA** logon type. There is no gMSA value in `TASK_LOGON_TYPE`, so it registers as
`Password` with **no password supplied** — Task Scheduler retrieves the managed one. It is
modelled as its own logon type precisely so the "a password is required" rule and the
password-rotation warning do not apply to it, and so a registered task whose account ends in
`$` round-trips back as a gMSA rather than a `Password` principal nobody can save.

The preflight checks what actually blocks it: that the account exists (gMSA names are unique
per **forest**, not per domain), that `Test-ADServiceAccount` says *this* host can retrieve the
password, and that the account has **Log on as a batch job** — which a gMSA almost never has by
default. If `Test-ADServiceAccount` returns false, the usual cause is that the host was added to
`PrincipalsAllowedToRetrieveManagedPassword` but has not rebooted, so its Kerberos ticket does
not yet carry the new membership.

### Choosing the account

**Browse…** next to the Account field opens a picker covering existing gMSAs, user/service
accounts, and the built-in principals, filterable by type and name. Every entry carries the
logon type it needs, and selecting one sets both — because account and logon type are a single
decision, and a gMSA left on `S4U` produces a task that cannot register. On a machine with no
reachable DC the picker still lists the built-ins, so it is never a dead end.

The list also tells you what each choice costs: a user account whose password expires is
labelled as such, a disabled account is shown in red and cannot be selected, and a gMSA this
host cannot yet read is called out.

### Creating a gMSA

A side utility, reachable from the picker. gMSA setup is three steps in two places and the
process explains itself nowhere, so the dialog says what it is doing and why:

1. Create the account, naming who may read its password — **a group**, not individual
   computers, or every new host means editing the gMSA.
2. Each host caches it (`Install-ADServiceAccount`).
3. Each host grants it **Log on as a batch job**, or registration fails with `0x80070534`.

A checkbox does 2 and 3 for the local machine. If the host can't read the password yet, that is
reported as a **next step, not a failure** — the usual cause is a group membership that needs a
reboot to land in the machine's Kerberos ticket, and the task can be built in the meantime.

Everything runs on your own Windows credentials. The tool holds none, so it simply succeeds or
fails on your rights.

**It deliberately won't run `Add-KdsRootKey`.** That key is a single forest-wide secret the DCs
use to *compute* gMSA passwords; you need it only if nobody has ever made a gMSA in the forest,
and if one exists you never think about it again. Creating it is one Enterprise Admin command —
but it becomes usable only after ~10 hours of replication, so a button that appears to succeed
and then does nothing all day is worse than no button. The prerequisite check explains it and
shows the command.

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

`Logging.Mode = 'Transcript'` (default) generates `<ScriptDir>\.pstsm\<TaskName>.wrapper.ps1`
and points the action at it. The wrapper starts a transcript, forwards the arguments
unchanged, converts a terminating error into `exit 1`, propagates `$LASTEXITCODE`, and prunes
logs past `RetentionDays`. It is regenerated on every save and carries a do-not-edit header —
it is build output, not source. `ConvertFrom-PSTSMDefinition` sees through it, so editing a
task shows your script, not the shim. Set `Mode = 'None'` to point the action straight at the
script.

If your scripts live in a repo, add `.pstsm/` to its `.gitignore` — the wrappers are
generated per machine and per task, and there is no reason to track them.

## Verified behaviour

These were established by experiment, not assumption, and all of them are load-bearing.
Do not "tidy" any of them without re-running the experiment.

1. **Argument quoting.** Five candidate encoders were run against 11 hostile values (trailing
   backslash, embedded quotes, UNC, `&`, `;`, `$`, backtick, parens) on both Windows PowerShell
   5.1 and PowerShell 7. Only the `CommandLineToArgvW` rule — doubling backslash runs before a
   quote and at end-of-argument — is correct in every case. That is what
   `ConvertTo-PSTSMQuotedValue` implements.

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

**Script analysis** — `Get-PSTSMScriptProfile`, `Get-PSTSMEngine`

**Plan** — `New-PSTSMPlan`, `New-PSTSMTriggerSpec`, `Test-PSTSMPlan`,
`ConvertTo-PSTSMArgument`, `ConvertTo-PSTSMQuotedValue`, `Export-PSTSMPlan`,
`Import-PSTSMPlan`

**Task Scheduler** — `Get-PSTSMInventory`, `Register-PSTSMPlan`, `New-PSTSMLogWrapper`,
`ConvertFrom-PSTSMDefinition`, `ConvertFrom-PSTSMAction`, `ConvertTo-PSTSMCimTrigger`,
`ConvertFrom-PSTSMCimTrigger`, `ConvertFrom-PSTSMDuration`, `ConvertFrom-PSTSMResultCode`,
`ConvertFrom-PSTSMTriggerSummary`

**UI** — `Show-PSTSM`, `Show-PSTSMEditor`, `Show-PSTSMTriggerDialog`

The engine never references the UI, so it stays usable from a console, a build agent, or a
scheduled task of its own.

`Show-PSTSMEditor` is deliberately one long function rather than a set of smaller ones. Its
event handlers are plain scriptblocks that read the defining function's locals — the only
pattern that keeps module affinity on 5.1 (see #4 above) — and that only works while that
function's frame is on the stack, which it is for the whole life of a modal `ShowDialog`.
Splitting the handlers into separate functions would break them at runtime, not at parse time.

## Round-trip safety

`ConvertFrom-PSTSMDefinition` sets `IsFullyRecognized = $false` and preserves the original
`Execute`/`Arguments` in `RawAction` when a task was built some other way — inline `-Command`
code, a non-PowerShell action, or multiple actions. The UI must offer a raw-arguments box in
that case. Silently rewriting somebody's working task into our preferred shape is how you
break production.

## Tests

```powershell
Invoke-Pester -Path .\Tests\PSTSM.Tests.ps1      # engine, 86 tests
Invoke-Pester -Path .\Tests\PSTSM.UI.Tests.ps1   # UI, 23 tests
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
needed only for `Get-PSTSMInventory`, `Register-PSTSMPlan` and `ConvertFrom-PSTSMDefinition`;
the derivation and argument-building commands run anywhere. Registering a task generally
requires elevation.

Set `PSTSM_NODIALOG=1` in any automated run. Without it, an exception inside a WinForms
handler reaches the global handler and pops a modal message box on the desktop of whoever is at
the machine.

## Licence

**GPL-3.0-or-later.** Copyright © 2026 Krytical13. Full text in [LICENSE](LICENSE).

In plain terms:

| | |
|---|---|
| Use it at work, on any number of machines | ✅ yes, internal use has no obligations |
| Use it on billable client work | ✅ yes |
| Fork it, change it, publish your version | ✅ yes — under GPL-3.0 too |
| Sell it, or sell support for it | ✅ yes — the GPL does not forbid charging money |
| Ship it inside a **closed-source** product | ❌ no — derivatives must ship their source |

That last row is the whole point. The intent is that anyone can use and improve this freely,
and nobody can take it closed-source and resell it as their own.

The **name** is handled separately — see [TRADEMARK.md](TRADEMARK.md). Short version: fork
freely, but give a substantially changed version its own name.

## Contributing

Issues and pull requests are welcome. By contributing you agree your contribution is licensed
under GPL-3.0-or-later, the same as the rest of the project.

Two things worth reading first:

- The **Verified behaviour** section above. Several things that look like over-engineering are
  load-bearing and were established by experiment; the comments say which and why.
- Run both suites under **`powershell.exe`** as well as `pwsh`. Windows PowerShell 5.1 is where
  the binder bugs surface, and the UI form tests skip themselves under MTA.

## Health sweep and run logs

**Health** scans every task and lists the ones that are quietly broken — script deleted, module
uninstalled, settings file gone, S4U against a script that needs the network, plus what Task
Scheduler recorded: a failed last run, missed runs, triggers that have never fired, disabled but
still scheduled. Double-click a finding to open that task.

Signal-to-noise is the point. An empty next-run time is *not* a fault when the trigger is
at-logon, on-idle, at-startup or on-event — those have no predictable next run by nature.
Flagging them fired on nearly every vendor task, so the check is limited to time-based triggers.
On a stock machine that is the difference between 28 findings and 12.

**Last run** turns `Last Run Result: 0x1` into what actually happened: the per-run transcript for
a task PSTSM built, or the Task Scheduler operational event log for anything else.

Note that Windows ships that operational log **disabled**, so on most machines it holds nothing
for *any* task. When there's no history the window says so and gives you the command:

```
wevtutil set-log "Microsoft-Windows-TaskScheduler/Operational" /enabled:true
```

It only records from that point on — which is why PSTSM's own Transcript logging is the source
worth relying on.

## Next

- Multi-machine apply: push an exported plan to a list of servers over WinRM.
- Event triggers (`MSFT_TaskEventTrigger`) in the trigger dialog; they round-trip today but
  cannot yet be created from the UI.
- A history pane reading the Task Scheduler operational log for the selected task.
