# Contributing

Issues and pull requests are welcome. By contributing you agree your contribution is licensed
under GPL-3.0-or-later, the same as the rest of the project.

## Running the tests

```powershell
.\Tools\Invoke-PSTSMTest.ps1
```

That is the whole answer, and it exists because doing it by hand needs three pieces of knowledge
that are annoying to acquire:

- **Pester 5 is required**, and Windows ships Pester 3.4. Worse, `Install-Module -Scope
  CurrentUser` from `pwsh` installs into `Documents\PowerShell\`, which Windows PowerShell cannot
  see — so "I installed Pester 5" and "5.1 can find Pester 5" are different facts. The runner
  searches both roots and imports by full path.
- **Both hosts matter.** Windows PowerShell 5.1 is where the parameter-binder differences
  surface; `pwsh` is where most people run. Green on one proves little.
- **The UI suite needs STA.** Without it, the form tests skip themselves and the suite still
  reports success — testing almost nothing while looking fine.

CI runs exactly this on every push, on `windows-latest`, on both hosts.

## What the tests are for

Volume is not the point. Most of these exist because something was found to be broken in a way a
green suite had failed to notice, so a few conventions are worth knowing:

- **Test against real objects, not only mocks.** More than once a check has been added, passed
  its mocked tests, and been incapable of ever firing. If you are asserting on behaviour that
  touches Windows, exercise Windows.
- **Prove a negative test can fail.** If a test is meant to catch a regression, break the code
  and confirm it goes red. Two launcher tests once asserted against a copy of the logic and
  passed with the file deleted.
- **Nothing may write to Task Scheduler.** Some tests read live task state deliberately — that
  is how several real bugs were found — but nothing registers, edits or deletes a task, so the
  suite is safe to run on a working machine. Keep it that way.
- **Never steal focus.** UI seams use `Show-PSTSMUIForTest`, which realises a window off-screen
  without activating it. A suite that yanks the desktop once per dialog is one nobody runs twice.

## Things that look wrong and are not

Several parts of this codebase look like over-engineering until you know what they are working
around. They are documented where they live; before "simplifying" one, read the comment.

- Argument quoting follows the `CommandLineToArgvW` rules, and the reader is its exact inverse.
- The generated log wrapper has no `param()` block and uses automatic `$args`.
- `Show-PSTSMEditor` is deliberately one long function.
- Elevation happens at save, in a separate process, not at launch.
- Arrays are refused by the renderer, because `-File` genuinely cannot deliver one.

## Style

Match the surrounding code: PascalCase for functions, comment-based help on anything exported,
UTF-8 **with BOM** for any file containing non-ASCII (Windows PowerShell 5.1 reads a BOM-less
UTF-8 script as ANSI). `Invoke-ScriptAnalyzer` should be clean; CI enforces it.
