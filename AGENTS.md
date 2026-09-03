# AGENTS.md

House rules for ScreenDeck. The README tells a user what the tool does; this file
tells whoever edits it how things are done here and what people trip over.

Read it before the first edit. Every rule below cost someone an evening.

## What this is

A Windows-only display switcher written in Windows PowerShell 5.1. No build step, no
package manager, no dependencies, nothing installed on the system: the folder is the
program, and deleting it uninstalls it. That is a promise to the user, not an accident
— see [What not to do](#what-not-to-do).

Two entry points, one engine:

```
Displays.ps1     (tray icon)  ─┐
Set-Display.ps1  (CLI)        ─┴─►  DisplayCore.ps1 + WindowLayout.ps1 + Activity.ps1
Displays.ps1 also dot-sources       SettingsDialog.ps1
```

`DisplayCore.ps1` holds definitions only and does nothing on load beyond compiling its
types. It must keep working when `WindowLayout.ps1` was not dot-sourced, so it calls
into that file through a presence check rather than blind (`DisplayCore.ps1:4146`):

```powershell
$doWindows = ((Test-Path Function:\Save-WindowLayout) -and ...)
```

New cross-file calls out of `DisplayCore.ps1` follow the same shape.

## Check before you call it done

```powershell
.\tools\check.ps1
```

Four gates, non-zero exit on any failure: every `.ps1` parses, every `.ps1` is UTF-8
with BOM and CRLF, PSScriptAnalyzer is clean (skipped with a warning when the module
is absent), and the test suite passes. `-Only <substring>` is passed through to the
tests; `-RequireAnalyzer` turns a missing analyzer into a failure, which is what CI
uses.

Nothing else counts as verification. In particular, "the tests passed" is not enough:
`render-preview.ps1` and `Make-Icon.ps1` are dot-sourced by nothing, so a typo in them
survives until somebody runs them by hand. That is what gate one is for.

## Cutting a release

Three things by hand, the rest by machine:

1. Bump `$script:Version` in `DisplayCore.ps1`.
2. Date the version's heading in `CHANGELOG.md` — `## 1.1.0 — 2026-09-14`. The heading
   is what `tools/pack.ps1 -NotesOut` reads for the release page, so a version with no
   section there fails the build rather than shipping empty notes.
3. Tag `vX.Y.Z` and push the tag.

`.github/workflows/release.yml` takes it from there: gates first, then `tools/pack.ps1`,
then a GitHub Release with the ZIP and its `.sha256` attached. The tag is checked against
`$script:Version` (`-ExpectVersion`), so a tag without a bump fails instead of shipping an
archive that disagrees with its own About box.

The archive holds the program only — no `tests/`, `tools/`, `docs/` or this file. That is
why README links its screenshots and everything under `docs/` absolutely: relative paths
would be broken pictures for whoever reads it from the unpacked folder. The list
of what stays behind is in `tools/pack.ps1`, and it is an *excluding* list on purpose: a
new file of the program ships by itself, a new file for us has to be named there.

## Where things live

| File | Lines | Go here for |
| --- | --- | --- |
| `DisplayCore.ps1` | 5222 | the engine: state, switching, modes, brightness, rules, hooks. Embedded C# 810-2042, the compiled-assembly cache 2044-2153, `Switch-DisplayMode` at 3990 |
| `SettingsDialog.ps1` | 4616 | all WPF: the Settings window, the mode editor, the rule editor, the timer popup and the diary window. Building a window is separated from showing it so tests can build one and never show it |
| `Displays.ps1` | 1508 | the app: tray icon, menu, hotkey registration, watchdogs, timers |
| `Activity.ps1` | 583 | the diary, the report both the window and the page are built from, and that page |
| `Set-Display.ps1` | 218 | the command line: argument parsing and printing, no logic |
| `WindowLayout.ps1` | 228 | window-position snapshots per display set |
| `render-preview.ps1` | 269 | dev tool: renders all five windows to PNG without showing them |
| `Make-Icon.ps1` | 150 | dev tool: regenerates `app.ico` |
| `tools/check.ps1` | 234 | the four gates, and the only answer to "am I done" |
| `tools/probe-picture.ps1` | 269 | dev tool: reads and writes ONE monitor register per run, so that an eye at the desk can say what changed. The only way to learn a picture preset's number; the program itself never asks for capabilities |
| `tools/trace-displays.ps1` | 132 | dev tool: our log and Windows' `Kernel-PnP` 1010 in one timeline. The Windows side is the only place a display leaving the bus by itself is written down |
| `tools/pack.ps1` | 211 | the release archive: what the user downloads, built from `git ls-files` |
| `tests/` | — | the runner (107), the framework (79), the fakes (131), 39 files of cases (6393) and `live.ps1` (252) |
| `docs/notes.md` | 2214 | the engineering diary: what Windows actually does, measured, day by day |

Line counts are signposts, not contracts — they drift. `docs/notes.md` is the place
to look when a decision here looks arbitrary; it usually records the evening that
produced it.

## Rules you cannot infer from the code

- **Everything here is English** — the code, the comments, the interface, the log, the
  documentation and the commit subjects. Russian is for talking to the author, and it does
  not go into the repository. Entries in `last-run.log` from before 2026-08-05 are Russian;
  that is history, not a precedent.
- **Every date and percentage goes through `InvariantCulture`.** `-f` and `ToString()`
  without a culture take the current one — including its *calendar*. On a Thai locale
  `yyyy` is a Buddhist year and the log stops being ISO. `Format-DisplayStamp` exists
  for exactly this.
- **No trace of any predecessor.** No third-party tool's name in the code, the docs or
  any identifier, and no "this used to be…" archaeology in comments. A comment explains
  the code as it stands.
- **Every `.ps1` is UTF-8 with BOM, CRLF.** Without the BOM, PowerShell 5.1 reads the file
  as Windows-1251, and every non-ASCII character in it turns to mush. `.gitattributes` fixes
  line endings at commit time; `tools/check.ps1` catches both on the spot.
- **A comment says *why*, and names the real breakage.** Comment density here is a
  style choice, not decoration — keep it. A comment that restates the line below it is
  worse than none.
- **Commit subjects say what changed in meaning** — not which files were touched.
- **Name your arguments** when a call passes two or more of the same kind.
  `Get-DisplayModes` takes `(State, Settings)` and `Update-HotkeyKeys` takes
  `(Settings, State)`; positionally, those get swapped sooner or later.
- **Settings are read and written only through `Get-ActiveSettings` /
  `Set-ActiveSettings`** — never `$script:Settings` from inside an event handler.
- **The version lives in one place** — `$script:Version` in `DisplayCore.ps1`, formatted
  by `Get-VersionLine` for both `Set-Display.ps1 status` and the tray's About item. Bump
  it with a `CHANGELOG.md` entry, never on its own.
- **Every script run directly starts with `#Requires -Version 5.1`.** It is a comment, so
  it goes on line one and the comment-based help below it still resolves.

## Traps

Most of these are written up in `docs/notes.md`, section "Dead ends not to go back to"
(`docs/notes.md:521`). Do not rediscover them.

- **CCD only.** Turning a display on goes through `QueryDisplayConfig` /
  `SetDisplayConfig`. The legacy `ChangeDisplaySettingsEx` returns `-4` (bad flags) on
  this hardware for that job. Do not "fix" anything by falling back to it. For a *mode
  change* the legacy call works fine, and that is where it is still used.
- **A monitor's picture preset has no standard.** Brightness is one code with one meaning
  everywhere; the preset is not. MCCS names `0xDC`, both LGs on this desk answer only on LG's own
  `0x15`, and the ASUS only on `0xDC`. Worse, the NAMES lie: measured 2026-09-03, the UltraGear
  shows both 6 and 45 as "Gamer 1" and they look different. So there is no table of models and no
  learning of names anywhere here — `Remember` reads the number the monitor is holding at that
  moment, stores it with the register that answered (`"0x15:45"`), and writes it back on a switch.
  `tools/probe-picture.ps1` is how a number is found by hand; **never ask for the capabilities
  string** from the program — on 2026-08-21 that left the UltraGear deaf to DDC until its cable
  was cycled.
- **A refresh rate is the driver's exact fraction.** 144 Hz is `143999/1000`, 60 Hz is
  `59997/1000`. Asking for `144/1` makes the system reject the whole request. That is
  what `display-modes.json` caches, and why that file exists.
- **One `SetDisplayConfig` per switch, not three.** Each transition freezes input and
  blinks the screens. `Set-CcdFullConfig` sets the whole desk — set, positions, primary,
  resolutions and rates — in one call; the three-step path below it is the fallback for
  when that call is refused. It needs the display order out of the settings and refuses
  without it — except for a single display, whose place is the origin whatever anybody wrote.
- **`Set-CcdLayout` is the only thing that moves the primary display,** and it is called on
  every switch — not only when `layout` says what the order is. "Primary" in Windows is a
  place (0, 0) rather than a flag: `Set-CcdTopology` cannot move it and `Set-CcdFullConfig`
  refuses the whole job without an order, so an `if` around this call takes the taskbar away
  from every desk whose owner has never opened the Settings window. That `if` was there until
  2026-09-01; see the review at the end of `docs/notes.md`. With no order the call moves
  nobody and only anchors the primary, and when that one is at (0, 0) already it applies
  nothing and costs a single query.
- **`.GetNewClosure()` is banned in WPF and WinForms handlers.** Inside a closure,
  `$script:X` resolves to nothing: the Settings window got `$null` and died on
  `.Contains()`, and the menu silently showed no shortcuts. Put logic in functions
  (a function runs in script scope no matter who called it) and copy plain values into
  locals *before* creating the closure.
- **The embedded C# is one block and one `Add-Type`.** Four separate `Add-Type` calls
  cost a third of a second on every start. Editing the block changes its SHA, so a new
  `native-*.dll` is compiled and the stale ones are cleaned up on the next run — you
  cannot forget to rebuild.
- **Windows PowerShell 5.1 only, and `#Requires` cannot say so** — it takes a minimum, so PowerShell 7
  passes it and then dies on `Add-Type` with `CS0246: List<> could not be found`: on .NET Core only
  what `-ReferencedAssemblies` names is referenced, and `System.Runtime` is not in that list. The
  refusal is at the top of `DisplayCore.ps1` — the file every caller dot-sources and the file that
  fails — and it must stay above the `Add-Type` it stands in front of.
- **Smart App Control can refuse the unsigned `native-*.dll`.** The refusal is by
  reputation, not by content, and it arrives as HRESULT `0x800711C7`. The code deletes
  the file and the next start rebuilds it. Match on the number, never on the message
  text — that text is localised.
- **`DisplayCore.ps1` deliberately does not set `$ErrorActionPreference`,** and has to
  survive a caller that set it to `Stop`. Both entry points do. See the comments at
  `DisplayCore.ps1:51` and `:297`: that is why `Add-Content` carries an explicit
  `-ErrorAction Stop`, and why settings parsing sits under one `try`.
- **`DISPLAY1` / `DISPLAY2` / `DISPLAY3` are not a monitor's identity.** Windows hands
  those names out by position, and they move between monitors across a reboot or a
  hotplug. Identity is the device path (`Id`) or the short Monitor ID.
- **`Set-StrictMode` was tried on 2026-08-24 and rejected.** Both `2.0` and `Latest`
  break settings parsing, which is built on "the key may be missing". Do not try again.
- **`Local\ScreenDeckSwitch` is taken by two things, not one.** `Switch-DisplayMode` holds
  it for a whole switch, and the refresh-rate watchdog `Restore-BestModes` holds it for
  about a second while it collects state — and what starts the watchdog is
  `DisplaySettingsChanged`, i.e. *our own* switch. So a running tray makes the mutex busy
  for roughly a second after every switch. Anything that switches back to back must expect
  a `Skipped` result and retry (`tests/live.ps1` does); anything that reads a red result
  should check this first, because the failure surfaces far from its cause.
- **Read a switch's answer through `Ok` / `Retry` / `Outcome`, never by assembling it out of
  the pieces.** `New-SwitchResult` builds every answer `Switch-DisplayMode` can give, and
  `New-SwitchFailure` turns a caught refusal into the same shape. `Ok` is "the desk is in
  that mode now"; `Retry` is "asking again in a moment can change this" — true for a busy
  mutex and for a display still waking, false for Windows refusing outright. Before that
  existed, the tray's two automatic callers each read `Skipped` and `Ok` apart from each
  other and derived opposite policies: a rule that stranded a person on the game display
  for good on one side, an error balloon every fifteen seconds on the other. And it is
  bounded: `$script:AutoRetryLimit` in `Displays.ps1` is how many times any automatic path
  asks again — four ticks of the 15-second timer, about a minute.
- **A `.cmd` file must NOT have a UTF-8 BOM,** and the two launch paths disagree about it, which
  is why it went unnoticed. `cmd /c work.cmd` tolerates the BOM; **ShellExecute — what a double
  click and a pinned shortcut do — does not.** There the three bytes are glued to the first
  command, it fails as unrecognised (`ERRORLEVEL` 9009, measured 2026-09-01), and the rest of
  the file runs on. So the first line is the whole cost: here it is `@echo off`, so the switch
  still happens, with an error message and every command echoed into a window that closes the
  instant it is done. An editor set to "UTF-8" puts the BOM back on save, which is why both
  `.editorconfig` and gate 2 of `tools/check.ps1` say so — `.ps1` needs the BOM, `.cmd`
  must not have one, and the two live in one directory.
- **A rule's claim on the desk is its identity, not its index.** `Get-RuleSignature` is what
  `Get-RuleDecision` finds the holder by; the index is only where to look first. The list is
  edited by hand and from the Settings window while a rule is holding the desk, and deleting
  a rule above the holder renumbers everything below it.

## Tests

```powershell
.\tests\run-tests.ps1                all of them, about two seconds
.\tests\run-tests.ps1 -Only combos   only tests whose name contains the string
.\tests\run-tests.ps1 -File 12       only that file of cases
```

No Pester — see [What not to do](#what-not-to-do). The runner is a few dozen lines:
`Test-Case`, `Assert-Equal`, `Assert-True`, `Assert-Null`, two counters and a non-zero
exit.

Layout:

- `tests/run-tests.ps1` — entry point. Redirects the log, dot-sources the code under
  test, walks `cases/`, prints the total.
- `tests/framework.ps1` — `Test-Case` and the assertions.
- `tests/fakes.ps1` — `New-FakeMonitor`, `New-FakeScreen`, `New-TestSettings` and kin, plus
  `Get-TrayFunctionSource` / `Get-TrayVariableSource`: `Displays.ps1` cannot be dot-sourced by
  a test — it brings the whole application up — so the functions under test are cut out of it
  by parsing the file, and the caller dot-sources what comes back. Four files of cases do this;
  the parse itself is cached (`Get-TrayAst`).
- `tests/cases/NN-name.tests.ps1` — one file per group; the numeric prefix fixes the
  order of the output.

**No test touches the real displays, `settings.json`, the log or the diary.** That is
held up by two things, and a new test must not break either:

- `$env:SCREENDECK_LOG_FILE` is set to a temp file *before* `DisplayCore.ps1` is dot-sourced.
  It has to be before: log rotation and type compilation write to it during load, and
  reassigning `$script:LogFile` afterwards is too late.
- `$script:SettingsFile`, `$script:WindowStateFile`, `$script:LastModeFile`,
  `$script:ModeCacheFile` and `$script:ActivityFile` all point into one temp directory,
  which is removed at the end.

To add a case, drop a `Test-Case` block into the matching file under `tests/cases/`.
Name it as a sentence about behaviour, not about the function — the name is what a
failure prints.

**The orchestrator tests work by shadowing functions.** `Switch-DisplayMode` reaches
hardware only through named functions (`Get-DisplayState`, `Set-CcdFullConfig`,
`Set-CcdTopology`, `Set-CcdLayout`, `Set-DisplayMode`, `Set-BestModeFor`,
`Wait-ForTopology`) and disk only through `Save-LastMode`, `Save-AppliedModes`,
`Save-WindowLayout` and `Invoke-ModeHook`. PowerShell resolves functions dynamically up
the call scopes, so declaring `function Set-CcdFullConfig { … }` *inside* a `Test-Case`
block overrides the real one for everything that block calls, and dies with the block.
The fakes record their calls into a list, and the test asserts what was called and in
what order. Production code carries no seam for this and must not grow one.

`tests/live.ps1` is the opposite: it drives the real desk, by hand only, never in CI.
It exists because P/Invoke signatures, driver behaviour and real timings are the whole
value of this project, and no fake reproduces them.

## What not to do

- **Do not add a dependency.** Not a module, not a NuGet package, not Pester.
  PowerShell 5.1 ships Pester 3.4, and installing a newer one breaks "nothing is
  installed on your system, the folder can just be deleted". PSScriptAnalyzer is used
  *if present* and is never installed by the tool.
- **Do not write an installer or a Windows service.** Startup is a shortcut; that is
  deliberate and sufficient.
- **Do not add a seam, a wrapper or a layer of indirection to the switch path** for the
  sake of testing. Milliseconds were measured on that path, and the `done:` line in the
  log keeps measuring them on every switch, forever. Shadow functions in the test
  instead.
- **Do not write anything here in a language other than English** — not a comment, not a
  log line, not a commit subject. The one-language rule is the whole rule; there is no
  half of the repository it does not apply to.
- **Do not let anything here learn where it lives.** There is not one absolute path in
  this repository — every one of them resolves through `$PSScriptRoot` or `%~dp0`, which
  is why the folder can be moved or renamed at no cost. Keep it that way. What a move
  does break is outside the repository: the startup shortcut stores an absolute path
  (`Set-RunAtStartup`, `DisplayCore.ps1:5186`) and so does any shortcut pinned to
  `Displays.cmd`. `Test-RunAtStartup` only checks that the `.lnk` exists, so a stale one
  reads as enabled and silently starts nothing — re-run `Set-RunAtStartup $true` from the
  new location.
- **Do not commit generated files.** `native-*.dll`, `settings.json`, `last-mode.json`,
  `display-modes.json`, `window-state.json`, `ui-state.json`, `activity.json`, `stats.html` and
  `last-run.log` belong to the machine, not to the code, and are all in `.gitignore`. So do
  `ScreenDeck-*.zip`, its `.sha256` and `release-notes.md` — `tools/pack.ps1` builds all
  three out of what is already committed. The screenshots under `docs/images/` are the
  exception that is *not* generated-and-ignored: they are committed, because README needs
  them and GitHub cannot run a renderer.
