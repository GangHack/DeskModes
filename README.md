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
- **Any combination you can name.** "Movie night" is the 4K panel plus the TV with the
  taskbar moved to the TV — one display can be part of any number of combinations, each
  with its own menu entry, hotkey and taskbar placement.
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
- **Rebuilds the desk when the world changes.** Woke up from sleep, monitor unplugged,
  monitor switched on by its own button — Windows rearranges the desk on every one of
  those. The set you chose comes back by itself.
- **Follows with audio, optionally.** A mode can carry a default playback device — handy
  when the gaming monitor has the speakers.
- **Carries brightness with the mode.** Over DDC/CI — the same channel inside the cable
  that the buttons on the monitor's own bezel use. The evening mode dims the 4K panel to
  25%, the work mode puts it back to 80%, and you stop reaching for the bezel.
- **Runs your own command around a switch.** One line per mode: close an app, change the
  power plan, turn off the lights in the room. What it does is your business.
- **Switches by itself on a rule.** A process started, or nobody has touched the computer
  for twenty minutes — go to this mode, and come back when it is over.
- **Turns the computer off on a timer.** From the tray menu, with the countdown on the
  icon and a warning a minute before, cancellable at any point.
- **Keeps a diary, if you ask it to.** How long in which app, on which display, in which
  mode — with a report you can actually look at. Off by default, window titles never
  recorded, one local file you can delete.
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
3. Arrange the display cards as they stand on your desk and star the one that keeps the
   taskbar. Add a **combination** for every set of displays you switch between, and bind
   hotkeys to the modes you want (click a box, press the keys; the cross next to it removes
   a binding).
4. Turn on **Start with Windows** if you want it back after a reboot.

The Settings window follows the system theme — dark, light and your accent color — and
everything above is edited visually; `settings.json` is written for you.

There is no configuration to write by hand for the common case — `settings.json` is created
for you on first run.

## The tray menu

Click the icon with either button. The menu follows the system theme, dark or light, with
your accent color:

- **CONNECTED DISPLAYS** — what is plugged in, at what mode, and who is primary. Names read
  at full strength, the mode and remarks a step quieter. The dot is green at the maximum
  refresh rate, amber `(below N Hz)` when Windows dropped it, grey when the display is off.
- **SWITCH TO** — your modes: one per display, your combinations, all. The one
  matching the current desk is ticked; modes whose displays are unplugged are greyed with
  `(not connected)`.
- **Shut down in…** and **Sleep in…** — 15 minutes, 30, an hour, two, or a time you type
  (`20`, `90m`, `1h30`). While a timer is armed, the icon's tooltip counts down, the menu
  entry shows what is coming and when, and there is a **Cancel the timer** entry at the top
  of its submenu. A minute before, a notification says so — that minute is the whole
  difference between a handy timer and lost work. The countdown lives in memory only: a
  computer that switches itself off a day after you asked would be worse than no timer.
- **Statistics…** — the diary as a page in your browser, in your theme and accent colour.
  Greyed out with `(diary is off)` until you turn the diary on in Settings.
- **Settings…**, **Open log**, **Open folder**, **Exit**.

## Combinations

Every mode is one of three things: **one display** (there is a mode per display, for free),
**all of them**, or **a combination** — the sets you name yourself. That is the only concept
you configure, and it is the only one you can delete.

Create one in the Settings window: pick a name, tick the displays, optionally choose which
of them keeps the taskbar while the combination is on, and press a shortcut right there in
the editor. One display can be in as many combinations as you like — "Movie night" and
"Work" can both include the 4K panel, each with the taskbar somewhere different.

Each combination shows up in the tray menu under its own name, takes a hotkey like any other
mode, resolves from the command line (`.\Set-Display.ps1 "Movie night"`), and is a valid
target for `autoGame` and `audio`. The mode key is `combo:<name>`.

Renaming a combination moves its hotkey and audio binding along; removing it removes them.
A combination whose displays are all unplugged stays in the menu, greyed out — you made it,
so only you remove it.

Nothing is ever guessed. Plug in three monitors on a fresh install and you get exactly three
modes plus "all"; no set is invented for you. An early version decided ASUS meant gaming and
LG meant work, which was true of exactly one desk: LG makes gaming panels, ASUS makes office
ones, and Dell fell through the cracks entirely. Which displays belong together is a
decision, not a property of the hardware.

### Coming from display groups

Earlier versions had a second concept: a **group**, a name written on each display, which
produced a mode once two displays shared it. It said less than a combination (one group per
display, no taskbar choice of its own) and it was removed in favour of the one that says
more.

Nothing to do about it — `roles` in an existing `settings.json` is turned into combinations
the first time the new version reads it: `work` on two displays becomes a combination named
`Work` with those two, and its hotkey, audio entry and `autoGame` target follow it from
`role:work` to `combo:Work`. The tray rewrites the file once and logs what moved. `work.cmd`
and `game.cmd` keep working, because a combination also resolves by name.

## settings.json

Written by the Settings window, and safe to edit by hand. See
[`settings.example.json`](settings.example.json).

| Key | What it is |
| --- | --- |
| `hotkeys` | mode key → keys, e.g. `"combo:Work": "Ctrl+Alt+F3"` |
| `layout` | display names left to right, as they physically stand on your desk |
| `primary` | which display gets the taskbar, when it is among those switched on |
| `combos` | combination name → `{ "displays": [...], "primary": "..." }`; a bare array works too |
| `roles` | legacy display groups; turned into combinations on first read, then left empty |
| `maximizeRefresh` | restore each display to its highest refresh rate |
| `notifications` | show a balloon after switching |
| `restoreWindows` | remember and restore window positions per display set |
| `restoreLastMode` | re-apply the last chosen mode after the computer starts |
| `reapply` | rebuild the desk when the world changes: `onResume`, `onUnplug`, `onPlug` |
| `rules` | switch by itself when something happens. See [Rules](#rules) |
| `hooks` | mode key → `{ "before": "...", "after": "..." }`; a bare string means *after* |
| `brightness`, `contrast` | mode key → a number for every display of the mode, or `{ display → number }` |
| `stats` | keep the diary. Off by default |
| `autoGame` | legacy single rule; turned into the first entry of `rules` on first read |
| `audio` | mode key → part of a playback device name |

Names are matched by substring, in either direction: `UltraGear` finds `LG ULTRAGEAR`, and
`ROG STRIX XG27AQDMGR` finds the `XG27AQDMGR` Windows reports. Matching is
case-insensitive.

Mode keys are `solo:<display name>`, `combo:<name>`, and `all`. They are keyed by **name**
on purpose: a monitor's EDID product code changes when you move it to a different input, so
anything derived from it — including what other tools use as a stable id — silently stops
matching after you swap a cable.

Bindings for displays that are not currently connected are kept, and shown in the Settings
window as their own row: the combination is registered globally whether the monitor is
there or not, so you need a way to see and clear it.

If the file is ever unreadable, defaults are used and a copy is kept as `settings.json.bad`
rather than being overwritten.

## When the world changes by itself

Three things rearrange your desk without asking: waking from sleep, a monitor going away,
and a monitor coming back. Windows decides what the desk looks like in all three cases, and
its decision is not the one you made.

```json
"reapply": { "onResume": true, "onUnplug": true, "onPlug": "" }
```

- **`onResume`** — after the computer wakes up, the mode you chose last comes back. Five
  seconds after the wake-up event, because straight after it the monitors are still coming
  up and Windows answers questions about half a desk.
- **`onUnplug`** — a display went away (cable out, or switched off with its own button), so
  the last chosen mode is applied to what is left: the arrangement and the taskbar are put
  back on the remaining screens. Nothing new is ever switched on by this.
- **`onPlug`** — a display appeared. Empty by default, and that is deliberate: switching off
  the monitor somebody just switched on by hand is a war with a human. Name a mode here
  (`"all"`, `"combo:Movie night"`) and it will be applied when a display shows up.

Only **connected** displays are compared, never the ones that are on. The switcher turns
displays on and off constantly; reacting to its own work would be an endless loop.

## Rules

`autoGame` could express one thing: this process started, go to that mode, come back when
it exits. Rules say the same and more.

```json
"rules": [
    { "when": "process", "process": "cs2", "mode": "solo:LG ULTRAGEAR" },
    { "when": "idle", "minutes": 30, "mode": "combo:Movie night", "back": "combo:Work" }
]
```

| Field | What it is |
| --- | --- |
| `when` | `process` — that process is running; `idle` — nobody has touched the computer for `minutes` |
| `process` | process name, with or without `.exe`, as Task Manager shows it |
| `minutes` | for `idle` only. Zero means the rule never fires |
| `mode` | mode key to go to |
| `back` | where to return when the condition ends. Empty — back to wherever the desk was |
| `enabled` | `false` switches a rule off without deleting it |

Checked every fifteen seconds. Rules are tried in order and **the first match wins**; while
a rule holds the desk, the others stay quiet. Three things it will not do:

- **Take over when you are already there.** No switch, and nothing to give back later.
- **Go somewhere with no way back.** If the current set of displays matches no known mode
  and the rule names no `back`, it stays put and says so in the log.
- **Argue with you.** Switch the desk by hand while a rule holds it and the rule lets go —
  by hotkey, from the menu or from the command line, it makes no difference.

Your old `autoGame` keeps working: it becomes the first rule the first time the new version
reads the file, and it keeps its seniority over rules you write later.

## Brightness

A monitor's brightness lives in its own firmware, not in Windows, and is reached over
DDC/CI — the service channel inside the HDMI/DisplayPort cable that the buttons on the
bezel use. So a mode can carry it.

**In the Settings window**, the **Brightness** card does it with sliders: pick a mode, then
say what should happen to it —

- **leave the brightness alone** — the mode does not touch it (the default for everything);
- **one level for every display of this mode** — a single slider;
- **a level for each display** — a slider per display, with a tick that turns each one on
  or off. Unticked means *not set*, not zero: that display keeps whatever it had.

**Ask the monitors** asks over DDC/CI right there and reports who answered and at what
level. It is a button rather than something the window does when it opens, because one
question costs tens of milliseconds per monitor — and up to a second on a wedged bus.

By hand it is the same setting, and both shapes are valid:

```json
"brightness": { "combo:Work": 80, "combo:Movie night": { "ULTRAFINE": 25 } },
"contrast":   { "combo:Work": 70 }
```

A number goes to every display of that mode; an object gives each its own, matched by part
of the name like everywhere else. Values outside 0..100 are clamped rather than obeyed — a
typo should not black out a monitor.

The window never turns one shape into the other behind your back. A hand-written
`"all": 80` is still `80` after a Save: expanding it into a per-display object would use the
displays that happen to be plugged in *now*, quietly dropping the one that is unplugged and
changing what the setting means for a monitor you buy tomorrow. Switching shapes is the
"Then…" list, which is your decision — and switching to per-display seeds every slider with
the number you were looking at.

Contrast has no sliders: it is the same idea and stays in `settings.json`.

Only displays that are **on** in that mode are set: a sleeping monitor does not answer.
Run `.\Set-Display.ps1 brightness` to see which of yours answer at all and what they
currently sit at.

Three things worth knowing about that channel.

It is **slow**: tens of milliseconds per question, and a confirmed level costs about 150 ms
per display. That happens after the desk is already up, so it does not delay the picture —
but it is why nothing is asked at all unless you configured a level.

It is **unreliable by nature**: the same call to the same monitor sometimes comes back as
rubbish (`0xC0262589`, "invalid message command"), so every call is tried three times before
being believed. If a monitor answers nothing, look for DDC/CI in its own on-screen menu;
some monitors also need their link cycled — a switch to standby and back — after something
else has wedged the bus.

And **a write is not a promise**. Setting a level needs no reply, so Windows reports success
whether or not the monitor listened — on the machine this was built for, one monitor
accepted every brightness while refusing to report any. So every level is read back and
compared, and the log says which of them the monitor actually took:

```
levels: XG27AQDMGR - brightness 95, contrast 55
levels: LG ULTRAGEAR did not take brightness 95 - DDC/CI may be off in its own menu
```

## Commands around a switch

One line per mode, and what it does is your business:

```json
"hooks": {
    "combo:Movie night": { "after": "taskkill /im slack.exe" },
    "combo:Work": "C:\\tools\\morning.ps1"
}
```

`before` runs just before the desk is rebuilt, `after` when it is done and the switch
succeeded. A bare string means `after`, which is the one you want nine times out of ten.
A path ending in `.ps1` is run through PowerShell with the execution policy bypassed;
anything else goes to `cmd /c`, so `.exe`, `.bat` and built-ins like `start` all work.

The command is **launched, not waited for**. A switch is something you do with a hotkey and
measure in tenths of a second; a hung program of somebody else's has no right to hold it,
and a hung `before` would mean a black screen.

## The diary

Off by default. Turn on **Keep a diary** in Settings and the tray starts counting, every ten
seconds, which app is in front, which display it is on and which mode the desk is in.
**Statistics…** in the menu turns that into a page: time at the computer, per display, per
mode, per app, which app on which display, an hour-of-the-day histogram, your usual day
from first to last, longest single session, switches, days in a row.

Three decisions matter more than the code:

- **Window titles are never read.** A window title holds the document you have open, the
  page you are on, the subject of the letter you are writing. For "how long in what", the
  process name is enough. What is not in the file cannot leak out of it.
- **Sums are kept, not events.** The file holds "chrome — 3600 seconds" for a day, not a
  stream of "at 14:03:10 it was chrome". It stays a few kilobytes forever, and it cannot
  tell anybody what you were doing at three o'clock on Thursday.
- **Nothing leaves the machine.** `activity.json` sits next to the scripts, is listed in
  `.gitignore`, and deleting it forgets everything. Days older than a year are dropped by
  themselves.

Time is only counted while somebody is actually there: ninety seconds without a keypress or
a mouse move and counting stops until you come back. `.\Set-Display.ps1 stats` prints the
same report in the console.

## Command line

```powershell
.\Set-Display.ps1 status        what Windows reports right now (read-only)
.\Set-Display.ps1 modes         mode keys and their bound hotkeys
.\Set-Display.ps1 audio         playback devices, to fill in the audio setting
.\Set-Display.ps1 brightness    which displays answer over DDC/CI, and at what level
.\Set-Display.ps1 stats         the diary, as a report in the console
.\Set-Display.ps1 all           every connected display
.\Set-Display.ps1 "Movie night" a combination, by its name
.\Set-Display.ps1 work          the same, when the name is one word
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
22:35:11  --- start mode=combo:Work primaryMatch='' keepMode=False dryRun=False
22:35:11  switch: on = LG ULTRAFINE, LG ULTRAGEAR
22:35:12  ccd: full config applied - 2 display(s) on (with refresh rates)
22:35:12  layout: already correct
22:35:14  done: LG ULTRAFINE 3840x2160 @ 60 Hz, LG ULTRAGEAR 2560x1440 @ 144 Hz (2.5 s)
```

That is a healthy switch: the desk was rebuilt once (`full config applied`), and the checks
after it found nothing left to fix. Lines to notice if it feels rough: `rates left to
Windows` means the exact refresh rate was not known yet and will be learned by the next
switch; `topology set` instead of `full config applied` means the single call was refused
and the old three-step path ran; a `mode:` line means one display needed its rate corrected
afterwards, which is a second rebuild.

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

A switch is **one** call: which displays are on, where they sit, which one is primary, and
at what resolution and refresh rate — all in a single `SetDisplayConfig`. That matters for
how a switch feels rather than for how long it takes. Every rebuild of the desktop freezes
the compositor and the mouse for a moment, and this used to do three of them in a row (set
the displays, then move them, then fix the refresh rate) — the cursor would stall and jump
forward, screens blinked twice over, and every open window got told the display changed
three times.

Two details make the single call possible. The refresh rate has to be passed as the exact
fraction the driver uses — 144 Hz is `143999/1000` here, and asking for `144/1` gets the
whole request rejected — so each display's real mode is remembered in `display-modes.json`
after every switch, which is also where the rate for a *sleeping* display comes from. And
because a single call has to name coordinates for every display, this road is only taken
when `layout` in the settings says what the order is; without it the old three-step path
runs, which moves only the primary and leaves the rest where they are.

The three steps are still there as repair: after the single call the tool checks the set,
the arrangement and each mode, and fixes whatever did not take (a display that refuses a
rate, for instance). When everything landed, those checks find nothing to do and cost
nothing. It used to be that order mattered a lot, because the primary display cannot be
turned off; a stuck primary made every mode fail while every command reported success.

P/Invoke types are compiled once and cached next to the scripts, which is why a switch
costs tenths of a second rather than seconds.

## Tests

```powershell
.\tests\run-tests.ps1               all of them, about two seconds
.\tests\run-tests.ps1 -Only combos  only tests whose name contains the string
```

Pure functions only: hotkey parsing, mode keys, display-name matching, combinations, the
legacy-group migration, the primary-display ladder, settings round-trips, command-line name
resolution, layout retry and the switch verdict, the Settings window's save path (the window
is built but never shown), window-layout keys, the remembered mode, the startup-restore
decision, rule decisions, the rebuild-the-desk decision, brightness plans and the sliders
that write them (rows really built, not just the model), hook launching,
duration parsing, the desk preview, and the whole diary — sums, report, streaks and the page
it produces. **No test touches your displays, your `settings.json`, your log or your diary**
— those are redirected to temporary files. Non-zero exit on failure.

No Pester on purpose: PowerShell 5.1 ships an ancient 3.4, and installing a newer one would
break the "nothing is installed on your system" promise.

## Files

| File | What it is |
| --- | --- |
| `DisplayCore.ps1` | all the logic, definitions only — one source of truth for tray and CLI |
| `Displays.ps1` | the app: tray icon, menu, hotkeys, rules, timers |
| `SettingsDialog.ps1` | the Settings window (WPF, themed after the system), separate so it can be built in isolation |
| `WindowLayout.ps1` | window-position snapshots per display set |
| `Activity.ps1` | the diary and its report |
| `Set-Display.ps1` | the command line |
| `tests\run-tests.ps1` | the test runner |
| `Make-Icon.ps1` | regenerates `app.ico` |
| `render-preview.ps1` | renders the Settings window to a PNG without showing it, for checking the UI (`-Fake` invents a desk) |
| `last-run.log` | the log; rotates past 1 MB |
| `settings.json`, `window-state.json`, `last-mode.json`, `activity.json`, `stats.html`, `native-*.dll` | created as needed, safe to delete |

Code comments and the engineering notes are in Russian; the interface, the log and this
README are in English. The notes are worth a look if you are here for the display API
rather than the tool — they are a day-by-day account of what Windows actually does, with
measurements: [`docs/notes.ru.md`](docs/notes.ru.md).

## License

MIT — see [LICENSE](LICENSE).
