# ScreenDeck

Turn the displays on your desk on and off in named sets, with one hotkey.

`Ctrl+Alt+F1` — only the 4K panel. `Ctrl+Alt+F3` — both work displays. `Ctrl+Alt+F5` —
everything. The displays you did not ask for go to standby; the ones you did come up in
their best mode, arranged in the physical order you gave them, with the taskbar on the
display you chose.

No installer, no service, no dependencies — a folder of PowerShell scripts talking to the
Windows display API. Delete the folder and it is gone.

## What it actually does

Every one of these exists because the naive version broke on a real desk:

- **Switches sets, not just the primary display.** Any subset of your monitors can be a
  mode, bound to a hotkey, in the tray menu, or callable from the command line.
- **Keeps the arrangement.** Windows re-orders displays whenever a monitor comes back, so
  the cursor leaves the left screen to the right. You state the physical order once; every
  switch rebuilds it, vertically centred so the cursor can cross between panels of
  different heights.
- **Keeps the taskbar put.** "Primary" in Windows is not a flag, it is whoever sits at
  (0, 0) — so the whole layout is shifted to put your chosen display there.
- **Restores refresh rates.** Windows silently drops a display to a lower rate after a
  topology change, and on some hardware it cannot remember the right one at all. A
  watchdog puts it back.
- **Stays out of the way of games.** The watchdog never touches resolution and goes quiet
  while a full-screen app owns a screen. It used to fight Counter-Strike over stretched
  1440×1080 three times a minute.
- **Remembers window positions per set.** Come back to a layout and your windows come back
  with it.
- **Remembers the last set across a reboot.** Windows brings up whatever it feels like
  after a restart, not what you had chosen.
- **Follows with audio, optionally.** A mode can carry a default playback device — handy
  when the gaming monitor has the speakers.
- **Tells the truth in the log.** Every switch writes what it asked for and what actually
  happened, in English, with timings. Refused to turn a display off? Layout would not
  apply? It says so, in the log and in the notification.

## Requirements

Windows 10 or 11, and Windows PowerShell 5.1 — which ships with Windows. Nothing to
install, no admin rights, no change to your execution policy (the launchers pass
`-ExecutionPolicy Bypass` for themselves).

## Quickstart

```bash
git clone https://github.com/<you>/screendeck.git
```

Or download the ZIP and unblock it — Windows marks downloaded scripts, and PowerShell will
refuse to run them until you do:

```powershell
Get-ChildItem *.ps1 | Unblock-File
```

Then:

1. Run `Displays.cmd`. An icon appears in the notification area.
2. Click the icon → **Settings…**
3. Give your displays **group names** (say `work` to two of them), and bind hotkeys to the
   modes you want.
4. Tick **Start with Windows** if you want it back after a reboot.

There is no configuration to write by hand for the common case — `settings.json` is created
for you on first run.

## The tray menu

Click the icon with either button:

- **CONNECTED DISPLAYS** — what is plugged in, at what mode, and who is primary. A display
  running below its maximum is marked `(below N Hz)`.
- **SWITCH TO** — your modes. The one matching the current desk is ticked; modes whose
  displays are unplugged are greyed with `(not connected)`.
- **Settings…**, **Open log**, **Open folder**, **Exit**.

## Display groups

A group is how you say "these two belong together". Give two displays the same group name
and you get a mode that switches both on. The name is yours — `work`, `game`, `coding`,
anything; the mode is keyed `role:<name>` and titled `Name displays`.

A group of one gets no menu entry — the display already has its own mode — but the name
still resolves on the command line, so `Set-Display.ps1 game` works with a single gaming
monitor.

Nothing is guessed from the model name. An earlier version decided ASUS meant gaming and LG
meant work, which was true of exactly one desk: LG makes gaming panels, ASUS makes office
ones, and Dell fell through the cracks entirely. Which display is "work" is a decision, not
a property of the hardware.

## settings.json

Written by the Settings window, and safe to edit by hand. See
[`settings.example.json`](settings.example.json).

| Key | What it is |
| --- | --- |
| `hotkeys` | mode key → combination, e.g. `"role:work": "Ctrl+Alt+F3"` |
| `layout` | display names left to right, as they physically stand on your desk |
| `primary` | which display gets the taskbar, when it is among those switched on |
| `roles` | display name → group name |
| `maximizeRefresh` | restore each display to its highest refresh rate |
| `notifications` | show a balloon after switching |
| `restoreWindows` | remember and restore window positions per display set |
| `restoreLastMode` | re-apply the last chosen mode after the computer starts |
| `autoGame` | switch modes automatically when a given process starts. Off by default |
| `audio` | mode key → part of a playback device name |

Names are matched by substring, in either direction: `UltraGear` finds `LG ULTRAGEAR`, and
`ROG STRIX XG27AQDMGR` finds the `XG27AQDMGR` Windows reports. Matching is
case-insensitive.

Mode keys are `solo:<display name>`, `role:<group>`, and `all`. They are keyed by **name**
on purpose: a monitor's EDID product code changes when you move it to a different input, so
anything derived from it — including what other tools use as a stable id — silently stops
matching after you swap a cable.

Bindings for displays that are not currently connected are kept, and shown in the Settings
window as their own row: the combination is registered globally whether the monitor is
there or not, so you need a way to see and clear it.

If the file is ever unreadable, defaults are used and a copy is kept as `settings.json.bad`
rather than being overwritten.

## Command line

```powershell
.\Set-Display.ps1 status        what Windows reports right now (read-only)
.\Set-Display.ps1 modes         mode keys and their bound hotkeys
.\Set-Display.ps1 audio         playback devices, to fill in the audio setting
.\Set-Display.ps1 all           every connected display
.\Set-Display.ps1 work          a group, by name
.\Set-Display.ps1 ULTRAGEAR     one display, by part of its name
```

`-PrimaryMatch <name>` overrides the taskbar display for this call, `-KeepMode` leaves
refresh rates alone, and `-DryRun` prints what would happen without touching anything.
Exit codes: `0` switched, `1` failed, `2` skipped because another switch was in flight.

`status` prints `Current` and `Best` side by side — if they differ, that display is not at
its maximum. `all.cmd`, `work.cmd`, `game.cmd` and `status.cmd` are one-line wrappers.

## When something goes wrong

Read `last-run.log`. It is English, it is chronological, and every switch is one block:
what was requested, what the topology call did, whether the layout applied, what mode each
display ended at, and how long the whole thing took.

```
19:06:32  --- start mode=role:work primaryMatch='' keepMode=False dryRun=False
19:06:32  switch: on = LG ULTRAGEAR, LG ULTRAFINE
19:06:32  switch: topology already correct
19:06:32  layout: already correct
19:06:32  done: LG ULTRAGEAR 2560x1440 @ 144 Hz, LG ULTRAFINE 3840x2160 @ 60 Hz (0.2 s)
```

Two things worth knowing:

- **After editing the scripts, restart the tray.** It runs the code as it was when it
  launched, so a fix looks like it did nothing until you restart or reboot.
- **A display that dropped its DisplayPort link needs the cable replugged.** The power
  button is not enough, and no software can fix it — the log will say the display did not
  come up.

## Why not something else

| | |
| --- | --- |
| **Win+P** | Duplicate/extend/one-screen only. It cannot express "these two of my three". |
| **Windows Settings** | Several clicks per display, and it forgets the arrangement. |
| **DisplayFusion** | Excellent and paid, a whole window-management suite. This is one job. |
| **MonitorSwitcher** | Saves profiles keyed to the monitor's EDID, which changes when the monitor moves to another input. |
| **NirSoft MultiMonitorTool** | Where this project started. It writes the layout through the legacy display API, which on some machines reports success and does nothing; and a disabled monitor has no name in its dump, so it cannot be switched back on by name. |

## How it works

Everything goes through the Connected Display Configuration API (`QueryDisplayConfig` /
`SetDisplayConfig`), not the legacy `ChangeDisplaySettingsEx` path. The difference is not
academic: on the machine this was built for, the legacy call returns `-1` for every monitor
and the layout simply cannot be written, while CCD does both the primary move and the
enable correctly.

A switch is one atomic topology call — the requested set on, everything else off — then the
layout and primary in a second call, then per-display modes. It used to be three steps
where order mattered, because the primary display cannot be turned off; a stuck primary
made every mode fail while every command reported success.

P/Invoke types are compiled once and cached next to the scripts, which is why a switch
costs tenths of a second rather than seconds.

## Tests

```powershell
.\tests\run-tests.ps1               all of them, about two seconds
.\tests\run-tests.ps1 -Only roles   only tests whose name contains the string
```

Pure functions only: hotkey parsing, mode keys, display groups, settings round-trips,
command-line name resolution, layout retry and the switch verdict, window-layout keys, the
remembered mode, and the startup-restore decision. **No test touches your displays, your
`settings.json`, or your log** — those are redirected to temporary files. Non-zero exit on
failure.

No Pester on purpose: PowerShell 5.1 ships an ancient 3.4, and installing a newer one would
break the "nothing is installed on your system" promise.

## Files

| File | What it is |
| --- | --- |
| `DisplayCore.ps1` | all the logic, definitions only — one source of truth for tray and CLI |
| `Displays.ps1` | the app: tray icon, menu, hotkeys, auto-game mode |
| `SettingsDialog.ps1` | the Settings window, separate so the form can be built in isolation |
| `WindowLayout.ps1` | window-position snapshots per display set |
| `Set-Display.ps1` | the command line |
| `tests\run-tests.ps1` | the test runner |
| `Make-Icon.ps1` | regenerates `app.ico` |
| `last-run.log` | the log; rotates past 1 MB |
| `settings.json`, `window-state.json`, `last-mode.json`, `native-*.dll` | created as needed, safe to delete |

Code comments and the engineering notes are in Russian; the interface, the log and this
README are in English. The notes are worth a look if you are here for the display API
rather than the tool — they are a day-by-day account of what Windows actually does, with
measurements: [`docs/notes.ru.md`](docs/notes.ru.md).

## License

MIT — see [LICENSE](LICENSE).
