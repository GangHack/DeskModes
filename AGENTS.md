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
into that file through a presence check rather than blind (`DisplayCore.ps1:3780`):

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
| `DisplayCore.ps1` | 4626 | the engine: state, switching, modes, brightness, rules, hooks. Embedded C# 723-1841, the compiled-assembly cache 1843-1953, `Switch-DisplayMode` at 3634 |
| `SettingsDialog.ps1` | 3033 | all WPF: the Settings window, the mode editor, the timer popup. Building a window is separated from showing it so tests can build one and never show it |
| `Displays.ps1` | 1115 | the app: tray icon, menu, hotkey registration, watchdogs, timers |
| `Activity.ps1` | 549 | the diary and its HTML report |
| `Set-Display.ps1` | 207 | the command line: argument parsing and printing, no logic |
| `WindowLayout.ps1` | 188 | window-position snapshots per display set |
| `render-preview.ps1` | 201 | dev tool: renders windows to PNG without showing them |
| `Make-Icon.ps1` | 150 | dev tool: regenerates `app.ico` |
| `tools/check.ps1` | 221 | the four gates, and the only answer to "am I done" |
| `tools/trace-displays.ps1` | 103 | dev tool: our log and Windows' `Kernel-PnP` 1010 in one timeline. The Windows side is the only place a display leaving the bus by itself is written down |
| `tools/pack.ps1` | 165 | the release archive: what the user downloads, built from `git ls-files` |
| `tests/` | — | the runner (108), the framework (80), the fakes (58), 30 files of cases (3642) and `live.ps1` (223) |
| `docs/notes.ru.md` | 1353 | the engineering diary, in Russian: what Windows actually does, measured, day by day |

Line counts are signposts, not contracts — they drift. `docs/notes.ru.md` is the place
to look when a decision here looks arbitrary; it usually records the evening that
produced it.

## Rules you cannot infer from the code

- **Two languages, on purpose.** Comments and `docs/notes.ru.md` are Russian. The
  interface, the log, the README and this file are English. Do not translate either
  direction.
- **Every date and percentage goes through `InvariantCulture`.** `-f` and `ToString()`
  without a culture take the current one — including its *calendar*. On a Thai locale
  `yyyy` is a Buddhist year and the log stops being ISO. `Format-DisplayStamp` exists
  for exactly this.
- **No trace of any predecessor.** No third-party tool's name in the code, the docs or
  any identifier, and no "this used to be…" archaeology in comments. A comment explains
  the code as it stands.
- **Every `.ps1` is UTF-8 with BOM, CRLF.** Without the BOM, PowerShell 5.1 reads the
  file as Windows-1251 and the Russian comments turn to mush. `.gitattributes` fixes
  line endings at commit time; `tools/check.ps1` catches both on the spot.
- **A comment says *why*, and names the real breakage.** Comment density here is a
  style choice, not decoration — keep it. A comment that restates the line below it is
  worse than none.
- **Commit subjects are Russian, and say what changed in meaning** — not which files
  were touched.
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

Most of these are written up in `docs/notes.ru.md`, section
«Тупики, в которые не надо возвращаться» (`docs/notes.ru.md:501`). Do not rediscover
them.

- **CCD only.** Turning a display on goes through `QueryDisplayConfig` /
  `SetDisplayConfig`. The legacy `ChangeDisplaySettingsEx` returns `-4` (bad flags) on
  this hardware for that job. Do not "fix" anything by falling back to it. For a *mode
  change* the legacy call works fine, and that is where it is still used.
- **A refresh rate is the driver's exact fraction.** 144 Hz is `143999/1000`, 60 Hz is
  `59997/1000`. Asking for `144/1` makes the system reject the whole request. That is
  what `display-modes.json` caches, and why that file exists.
- **One `SetDisplayConfig` per switch, not three.** Each transition freezes input and
  blinks the screens. `Set-CcdFullConfig` sets the whole desk — set, positions, primary,
  resolutions and rates — in one call; the three-step path below it is the fallback for
  when that call is refused.
- **`.GetNewClosure()` is banned in WPF and WinForms handlers.** Inside a closure,
  `$script:X` resolves to nothing: the Settings window got `$null` and died on
  `.Contains()`, and the menu silently showed no shortcuts. Put logic in functions
  (a function runs in script scope no matter who called it) and copy plain values into
  locals *before* creating the closure.
- **The embedded C# is one block and one `Add-Type`.** Four separate `Add-Type` calls
  cost a third of a second on every start. Editing the block changes its SHA, so a new
  `native-*.dll` is compiled and the stale ones are cleaned up on the next run — you
  cannot forget to rebuild.
- **Smart App Control can refuse the unsigned `native-*.dll`.** The refusal is by
  reputation, not by content, and it arrives as HRESULT `0x800711C7`. The code deletes
  the file and the next start rebuilds it. Match on the number, never on the message
  text — that text is localised.
- **`DisplayCore.ps1` deliberately does not set `$ErrorActionPreference`,** and has to
  survive a caller that set it to `Stop`. Both entry points do. See the comments at
  `DisplayCore.ps1:55` and `:305`: that is why `Add-Content` carries an explicit
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
- `tests/fakes.ps1` — `New-FakeMonitor`, `New-FakeScreen`, `New-TestSettings` and kin.
- `tests/cases/NN-name.tests.ps1` — one file per group; the numeric prefix fixes the
  order of the output.

**No test touches the real displays, `settings.json`, the log or the diary.** That is
held up by two things, and a new test must not break either:

- `$env:MMT_LOG_FILE` is set to a temp file *before* `DisplayCore.ps1` is dot-sourced.
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
- **Do not translate the comments to English**, and do not translate the interface or
  the log to Russian.
- **Do not rename the folder.** The repository lives in `MultiMonitorTool` while the
  product is ScreenDeck. That is a leftover, and it stays: renaming breaks paths, the
  startup shortcut and the `.cmd` wrappers. It is a job for one person, done alone and
  last.
- **Do not commit generated files.** `native-*.dll`, `settings.json`, `last-mode.json`,
  `display-modes.json`, `window-state.json`, `activity.json`, `stats.html` and
  `last-run.log` belong to the machine, not to the code, and are all in `.gitignore`. So do
  `ScreenDeck-*.zip`, its `.sha256` and `release-notes.md` — `tools/pack.ps1` builds all
  three out of what is already committed. The screenshots under `docs/images/` are the
  exception that is *not* generated-and-ignored: they are committed, because README needs
  them and GitHub cannot run a renderer.
