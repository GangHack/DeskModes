# Contributing

Thanks for looking. This is a small, opinionated tool, and the fastest way to get
a change in is to know the two files that answer most questions before you ask
them.

## Read this first

**[AGENTS.md](AGENTS.md)** — how things are done here and what people trip over.
It is short, and every rule in it cost someone an evening: everything here is written in
English, display switching goes through the CCD API only,
a refresh rate is the driver's exact fraction, `.GetNewClosure()` is banned in
event handlers. Read it before the first edit, whether you are a person or an
agent.

**[docs/notes.md](docs/notes.md)** — the engineering diary: a day-by-day account
of what Windows actually does, with measurements. When a decision in the code
looks arbitrary, this is usually where the evening that produced it is written
down. The section "Dead ends not to go back to" lists them, so you do not have
to find them again.

## One command decides whether you are done

```powershell
.\tools\check.ps1
```

Four gates, non-zero exit on any failure: every script parses, every `.ps1` is
UTF-8 with BOM and CRLF, PSScriptAnalyzer is clean, and the test suite passes.
Nothing else counts as verification — in particular, "the tests passed" is not
enough, because two scripts in this repository are dot-sourced by nothing and a
typo in them survives until somebody runs them by hand.

### If that command will not run at all

A stock Windows refuses it with *"running scripts is disabled on this system"* —
and not just it: `tests\run-tests.ps1`, `tools\pack.ps1`, `render-preview.ps1`
and `Make-Icon.ps1` are all `.ps1` and all equally blocked. That is the execution
policy, not the tool, and it is a different thing from the Mark-of-the-Web
(*"not digitally signed"*) that `Displays.ps1` clears for itself.

The `.cmd` launchers a user gets pass `-ExecutionPolicy Bypass`, which is why
nobody has to change a setting to switch monitors. That promise is to the user,
not to the workbench: here you are running scripts all day, so set it once.

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

No admin rights needed, and `RemoteSigned` still holds *downloaded* scripts to a
signature — which is what keeps the zone mark worth clearing at all. If you would
rather change nothing on your machine, `Set-ExecutionPolicy -Scope Process Bypass`
lasts for that one window and dies with it.

`Get-ExecutionPolicy -List` names the scope that is deciding. If that scope is
`MachinePolicy` or `UserPolicy`, group policy holds it — a work laptop, usually —
and no command of yours will override it; that one needs whoever administers the
machine.

PSScriptAnalyzer is used *if you have it* and is never installed by the tool:

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
```

CI runs the same command with `-RequireAnalyzer`, so a missing analyzer is a
failure there and a warning here. Leave that switch to CI: typed locally without
the module installed, it turns the warning into a red gate and nothing else.

## Pull requests

- **One change per pull request.** A diff that can be read is a diff that can be
  reviewed.
- **A test for anything that can be tested.** Add a `Test-Case` block to the
  matching file in `tests/cases/`, and name it as a sentence about behaviour —
  the name is what a failure prints. See [AGENTS.md](AGENTS.md) for how the
  orchestrator tests shadow functions instead of adding a seam to the code.
- **Comments say *why*, and name the real breakage.** Comment density here is a
  style choice; a comment that restates the line below it is worse than none.
- **Do not add a dependency.** Not a module, not a NuGet package, not Pester.
  "Nothing is installed on your system, the folder can just be deleted" is a
  promise to the user, and it is why there is no build step.
- Commit subjects in this repository are Russian and say what changed in meaning.
  A pull request description in English is fine and welcome.

## Screenshots for the README

The windows are rendered, not photographed. `render-preview.ps1 -Fake` builds them
off-screen at 192 dpi against an invented three-display desk, so what lands in the
README does not depend on which monitors happen to be plugged in that day:

```powershell
.\render-preview.ps1 -Fake -Out docs\images\settings.png -EditorMode "combo:Movie night"
```

`-EditorMode` names the mode whose editor is photographed, and "Movie night" is the
combination with ONE display on the invented desk. That is not a preference: with two
displays the editor unfolded is 1460 points tall, taller than a 1440p work area, and a
window taller than the screen comes out of the renderer with its last two boxes cut off.
On a real desk that window scrolls.

That writes eight files in one go: the Settings window on each of its six pages
(`settings.png` for the first, then `-modes`, `-rules`, `-behavior`, `-diary`, `-about`)
and the two editors (`-editor`, `-rule`), plus the timer popup (`-timer`).

**Only six of them are committed** — the five README shows plus the Modes page:
`settings.png`, `settings-modes.png`, `settings-diary.png`, `settings-editor.png`,
`settings-about.png` and `settings-timer.png`. The rest are for looking at while a window is being worked on;
delete them before committing. The rendered files go under `docs/images/`, never the
ignored `preview-*.png` names.

The theme comes from the system, so switch Windows to the theme you want *before*
rendering; the script has no switch for it.

**In the README they are linked absolutely**, as
`https://raw.githubusercontent.com/GangHack/ScreenDeck/main/docs/images/…`, and that is
not a style choice. `README.md` ships inside the release ZIP and `docs/` does not, so a
relative `docs/images/desk.png` is four broken pictures for everyone who reads the README
from the unpacked folder instead of on GitHub. The same goes for the links to
`CONTRIBUTING.md` and `docs/notes.md`. Only files that `tools/pack.ps1` actually
ships — `CHANGELOG.md`, `SECURITY.md`, `LICENSE`, `settings.example.json` — may be
linked relatively.

The tray menu is the one picture that cannot be rendered — it is a WinForms
`ContextMenuStrip` and only exists on a real screen. Capture it by hand
(Win+Shift+S) at 100 % scaling, in the same theme as the rest.

## If it involves your hardware

Most of the value of this project is behaviour on real displays, and it has been
run on very few desks. If you hit a refusal, a mode that will not apply, or a
monitor that will not come back, that is interesting even without a fix:

1. Run `.\Set-Display.ps1 status` and paste the first line — it names the
   version, the Windows build and the PowerShell version.
2. Attach the relevant part of `last-run.log`. Failures are logged with the
   reason, and the `done:` line carries the timings.
3. Say what the display is and how it is plugged in. The short Monitor ID differs
   between a monitor's DisplayPort and HDMI inputs, and that alone explains a
   surprising number of reports.

`.\tests\live.ps1 -ReadOnly` is a safe read-only smoke check. The full
`.\tests\live.ps1` switches through every mode on your real desk and puts it
back — useful, and it will blink your screens.
