# DeskModes reference

For the first run, updating and recovery, start with the [README](https://github.com/GangHack/DeskModes#readme).

[![check](https://github.com/GangHack/DeskModes/actions/workflows/check.yml/badge.svg)](https://github.com/GangHack/DeskModes/actions/workflows/check.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/GangHack/DeskModes/blob/main/LICENSE)

Turn the displays on your desk on and off in named sets, with one hotkey.

`Ctrl+Alt+F1` — only the 4K panel. `Ctrl+Alt+F3` — both work displays. `Ctrl+Alt+F5` —
everything. The displays you did not ask for go to standby; the ones you did come up in
their remembered Windows configuration, with their positions, orientation and taskbar
placement preserved. Explicit per-mode choices can override the primary display.

No installer, no service, no dependencies — a folder of PowerShell scripts talking to the
Windows display API. Disable startup and exit the tray before deleting the folder.

![The Settings window, on the page where the desk is arranged](https://raw.githubusercontent.com/GangHack/DeskModes/main/docs/images/settings.png)

## What it actually does

Every one of these exists because the naive version broke on a real desk:

- **Switches sets, not just the primary display.** Any subset of your monitors can be a
  mode, bound to a hotkey, in the tray menu, or callable from the command line.
- **Any combination you can name.** "Movie night" is the 4K panel plus the TV with the
  taskbar moved to the TV — one display can be part of any number of combinations, each
  with its own menu entry, hotkey and taskbar placement.
- **Keeps the arrangement.** Before changing sets, DeskModes records the physical displays,
  their X/Y positions, orientation, resolution, exact refresh rates and primary. Returning
  to that set restores its snapshot; repeating All preserves the live desktop. Explicit
  arrow editing can instead request a vertically centred left-to-right row.
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
- **Speaks your language.** English, Russian, Ukrainian, Spanish, French and German,
  following Windows unless you say otherwise (Settings -> Behavior -> Language). The log
  stays English whatever the windows say - it is the thing you attach to a bug report.
- **Remembers the last set across a reboot.** Windows brings up whatever it feels like
  after a restart, not what you had chosen.
- **Rebuilds the desk when the world changes.** Woke up from sleep, monitor unplugged,
  monitor switched on by its own button — Windows rearranges the desk on every one of
  those. The set you chose comes back by itself.
- **Follows with audio, optionally.** A mode can carry a default playback device — handy
  when the gaming monitor has the speakers. Pick it from the list in the mode's editor, or
  type part of a name so the setting survives a driver renaming the rest.
- **Carries brightness with the mode.** Over DDC/CI — the same channel inside the cable
  that the buttons on the monitor's own bezel use. The evening mode dims the 4K panel to
  25%, the work mode puts it back to 80%, and you stop reaching for the bezel.
- **Carries the monitor's picture preset too.** The Reader/FPS/sRGB the bezel buttons switch
  between: set the monitor the way you want it, press **Remember** in the mode's editor, and the
  switch puts it back there. No list of names to pick from, because the numbers behind those names
  are the manufacturer's - one monitor here shows two different ones as "Gamer 1".
- **Runs your own command around a switch.** One line per mode: close an app, change the
  power plan, turn off the lights in the room. What it does is your business.
- **Switches by itself on a rule.** A process started, nobody has touched the computer for
  twenty minutes, or the connected displays are exactly these — go to this mode, and come back
  when it is over. The last one is the laptop and its dock: two monitors at home, one at the
  office, none on the train. Built in Settings, and switched off there without being deleted.
- **Carries HDR with the mode.** On for the game, off for the spreadsheet beside it, per display,
  and a display that cannot do HDR is left as it is.
- **Puts the previous set back when nothing came up.** If none of a mode's displays attaches, the
  displays that were on come back on by themselves, and the switch says so. A desk that went dark
  is the one thing a shortcut cannot fix.
- **Goes back.** The tray menu has *Back to Work*, named after wherever you were; the command line
  takes `back`; and a shortcut for it lives on the Behavior page — for the moment the picture is
  wrong and you are pressing keys blind.
- **Says which display is which.** A badge on every display for a moment, from the tray or from
  the Settings window: its name, its Monitor ID and what it is showing.
- **Turns the computer off on a timer.** From the tray menu — a ready length, or your own
  picked on a slider — with the countdown on the icon and a warning a minute before,
  movable and cancellable at any point.
- **Keeps a diary, if you ask it to.** How long in which app, on which display, in which
  mode — with a report you can actually look at. Off by default, window titles never
  recorded, one local file you can delete.
- **Tells the truth in the log.** Every switch writes what it asked for and what actually
  happened, in English, with timings. Refused to turn a display off? Layout would not
  apply? It says so, in the log and in the notification.

## What it looks like

Everything is set up in one window: a pane on the left, a page on the right, **Save** and
**Cancel** underneath. It follows the system theme — dark, light and your accent colour — and
it can be resized; where it stood and which page you left it on come back with it.

**Your desk** separates the Windows layout from explicit switching choices. The live diagram
uses Windows coordinates and display dimensions, including portrait orientation and Y offsets;
its star identifies the current primary and refreshes when Windows reports a display change,
including a primary change between identical panels. This refresh preserves unfinished edits.
The switching row lets you deliberately change order or choose a different taskbar display
for subsequent switches. Save records those choices without changing the live desktop itself.
**Use Windows layout** reads the current arrangement, adopts it as the complete desktop
snapshot and clears row/primary overrides. **Which is which** shows each display's concise
name on its physical screen. Identical panels keep distinct titles and exact internal bindings.
Double-left-click the tray icon to open Settings, or right-click for its switching menu.
Save applies settings and keeps the window open for further edits. Saving a different language
automatically reopens Settings on the same page with the translated interface.
Reopening Settings activates the existing window, preserving unfinished edits.

A display you have switched off at its own button is still there, marked `not connected`. Some
monitors leave the DisplayPort bus when they go dark, and Windows then stops mentioning them
altogether — which used to mean the one display you wanted to set a rule or a combination up
for was the one missing from every list. Every monitor seen in the last three months keeps its
card, its row in the table, its tick in a combination and its own mode to point a rule at. Its
mode is greyed where you switch from, because it cannot be switched to until it is back.

The same page carries **Displays go to sleep after** - Windows' own timeout, read when the
window opens and written back on Save, so setting up a desk does not mean a detour through the
Control Panel.

**Modes** is everything you can switch to. Each one is a row, and **Edit** opens the one place
that mode is configured:

![The Modes page](https://raw.githubusercontent.com/GangHack/DeskModes/main/docs/images/settings-modes.png)

The mode editor holds everything one mode owns. What the mode IS stays in sight — its name,
its displays, where the taskbar goes and the keys that reach it; what it does to the hardware
— brightness, contrast, the playback device and the commands — is folded under one line, and
unfolds by itself for a mode that already has any of them set:

![The mode editor](https://raw.githubusercontent.com/GangHack/DeskModes/main/docs/images/settings-editor.png)

And the shutdown timer, from the tray menu, when a ready length is not the one you want:

![Picking a time for the shutdown timer](https://raw.githubusercontent.com/GangHack/DeskModes/main/docs/images/settings-timer.png)

**Diary** is the same window's page too: where the time went, by display, by mode and by
application, for today, a week, a month or everything the diary holds.

![The Diary page](https://raw.githubusercontent.com/GangHack/DeskModes/main/docs/images/settings-diary.png)

**About** sits at the bottom of the pane, where Windows keeps its own: the version to paste
into a bug report, the log, the folder everything lives in, and the project page.

![The About page](https://raw.githubusercontent.com/GangHack/DeskModes/main/docs/images/settings-about.png)

## Requirements

Windows 10 or 11, and Windows PowerShell 5.1 — which ships with Windows. Nothing to
install, no admin rights, no change to your execution policy (the launchers pass
`-ExecutionPolicy Bypass` for themselves).

PowerShell 7 is not it. The `.cmd` files call `powershell.exe` by name, so the ordinary
way in works whatever your terminal opens with; running a script by hand from a `pwsh`
prompt is refused with a line telling you so, because the Windows API layer here is
compiled against .NET Framework and would fail further down with nothing readable to
show for it.

## Quickstart

Download the ZIP from [Releases](https://github.com/GangHack/DeskModes/releases) and
unpack it anywhere you like — your user folder is fine, no admin rights are needed. Or take
the whole repository, which also gets you the tests and the engineering notes:

```bash
git clone https://github.com/GangHack/DeskModes.git
```

Then:

1. Run `Displays.cmd`. An icon appears in the notification area, and the Settings window
   opens by itself the first time.
2. **Right-click** the icon for the menu — displays, modes, **Settings…**
3. Arrange the display cards as they stand on your desk and star the one that keeps the
   taskbar. Add a **combination** for every set of displays you switch between. Every mode
   is a row under **Modes** with an **Edit** button: that one window holds its displays, its
   taskbar, its shortcut (click the box, press the keys; the cross removes a binding), the
   brightness and contrast of its monitors, its playback device and its commands.
4. Turn on **Start with Windows** if you want it back after a reboot.

The Settings window follows the system theme — dark, light and your accent color — and
everything above is edited visually; `settings.json` is written for you.

There is no configuration to write by hand for the common case — `settings.json` is created
for you on first run.

## The tray menu

Click the icon with either button. The menu follows the system theme, dark or light, with
your accent color:

- **DISPLAYS** — every display this desk has, at what mode, and who is primary. Names read
  at full strength, the mode and remarks a step quieter. The dot is green at the maximum
  refresh rate, amber `(below N Hz)` when Windows dropped it, grey when the display is off,
  hollow when it is not connected — a display switched off at its own button is still listed,
  because that is when you want to set something up for it.
  Under the list, **Which is which...** puts a badge on every display for a moment.
- **SWITCH TO** — your modes: one per display, your combinations, all. The one
  matching the current desk is ticked; modes whose displays are unplugged are greyed with
  `(not connected)`. Under them, **Back to <mode>** — named after the mode you left — once you
  have left one.
- **Shut down in…** and **Sleep in…** — 15 minutes, 30, an hour, two, each with the time on
  the clock it lands on (`1 h    at 02:26`), or **Pick a time…** for anything else. That one
  opens a small popup by the cursor: a slider over uneven steps (five minutes near, hours far
  out), one-tap chips, the mouse wheel and the arrow keys for five minutes at a time, and a
  field that still takes `20`, `90m` or `1h30` if typing is faster. Whatever you are on, it
  says when it will happen. While a timer is armed, the icon's tooltip counts down, the menu
  entry shows what is coming and when, and its submenu grows **Add 15 minutes**, **Take 15
  minutes off** and **Cancel the timer** — an armed timer is moved more often than cancelled.
  A minute before, a notification says so — that minute is the whole difference between a
  handy timer and lost work. A late first warning, including after resume, starts a full new
  minute; subsequent ticks do not extend it. The countdown lives in memory only: a computer
  that switches itself off a day after you asked would be worse than no timer.
- **Statistics…** — the diary in a window of its own, in your theme and accent colour:
  **Today**, **7 days**, **30 days** or **All**, and everything on one screen without a
  scrollbar. **Open as a page** at the bottom writes the same report to `stats.html` and
  opens it in the browser — a file you can keep or send. Greyed out with `(diary is off)`
  until you turn the diary on in Settings.
- **Settings…**, **Open log**, **Open folder**, **Exit**.

## Combinations

Every mode is one of three things: **one display** (there is a mode per display, for free),
**all of them**, or **a combination** — the sets you name yourself. That is the only concept
you configure, and it is the only one you can delete.

Create one in the Settings window with **Add a combination**: it opens with the displays that
are on already ticked and the current taskbar display chosen, so on the usual day the name is
all there is to type. Otherwise pick a name, tick the
displays, optionally choose which of them keeps the taskbar while the combination is on,
press a shortcut, and set the brightness of its monitors — all in the same window, which is
also what **Edit** opens later. One display can be in as many combinations as you like —
"Movie night" and "Work" can both include the 4K panel, each with the taskbar somewhere
different.

The same **Edit** sits on every other mode too. A display's mode and "all displays" have no
name or membership to argue about — the desk decides those — so their editor holds the
shortcut, the brightness, the contrast, the playback device and the commands, and nothing
else. Only combinations have **Remove**.

Each combination shows up in the tray menu under its own name, takes a hotkey like any other
mode, resolves from the command line (`.\Set-Display.ps1 "Movie night"`), and is a valid
target for `rules`, `hooks`, `brightness` and `audio`. The mode key is `combo:<name>`.

Renaming a combination carries everything tied to it — hotkey, brightness, contrast,
playback device and commands; removing it removes them.
A combination whose displays are all unplugged stays in the menu, greyed out — you made it,
so only you remove it.

Nothing is ever guessed. Plug in three monitors on a fresh install and you get exactly three
modes plus "all"; no set is invented for you. An early version decided ASUS meant gaming and
LG meant work, which was true of exactly one desk: LG makes gaming panels, ASUS makes office
ones, and Dell fell through the cracks entirely. Which displays belong together is a
decision, not a property of the hardware.

## settings.json

Written by the Settings window, and safe to edit by hand. See
[`settings.example.json`](https://github.com/GangHack/DeskModes/blob/main/settings.example.json).

| Key | What it is |
| --- | --- |
| `hotkeys` | mode key → keys, e.g. `"combo:Work": "Ctrl+Alt+F3"`. One entry is not a mode: `"back"` is the shortcut that returns to the mode you left |
| `layout` | display names for an explicitly configured left-to-right row |
| `layoutOverride` | apply that row instead of saved Windows coordinates; set by arrow editing, cleared by Use Windows layout |
| `primary` | which display gets the taskbar when `primaryOverride` is enabled and it is among those switched on |
| `primaryOverride` | use the explicitly selected taskbar display; absent legacy values do not override a captured desktop |
| `combos` | combination name → `{ "displays": [...], "primary": "..." }`; a bare array works too |
| `maximizeRefresh` | restore the highest refresh rate when no protected desktop snapshot applies; an exact saved mode takes precedence |
| `notifications` | show a balloon after switching |
| `restoreWindows` | remember and restore window positions per display set |
| `restoreLastMode` | replace the active screens with the last chosen mode when the application starts. Off by default |
| `reapply` | rebuild the desk when the world changes: `onResume`, `onUnplug`, `onPlug`. Edited in Settings |
| `rules` | switch by itself when something happens. Edited in Settings. See [Rules](#rules) |
| `hooks` | mode key → `{ "before": "...", "after": "..." }`; a bare string means *after*. Edited in the mode editor |
| `brightness`, `contrast` | mode key → a number for every display of the mode, or `{ display → number }`. Edited in the mode editor |
| `hdr` | mode key → `true`/`false` for every display of the mode, or `{ display → true/false }`. A display not mentioned is left as it is. Edited in the mode editor |
| `stats` | keep the diary. Off by default |
| `language` | `"auto"` to follow Windows, or a code with a file under `lang\` (`"en"`, `"ru"`, `"uk"`, `"es"`, `"fr"`, `"de"`). Edited in Settings |
| `audio` | mode key → part of a playback device name. Edited in the mode editor |

Identical monitor models receive a connection fingerprint in their selected label, such as
`Panel {0123456789abcdef}`. Use that full label to select one instance. It is matched exactly,
including when the other panel is disconnected. A changed port can produce a new connection;
select it again in Settings. Old ambiguous numbered keys are retained for manual reassignment.
Plain model patterns intentionally match every matching panel.
Imported `id:<full device path>` selectors remain exact and case-insensitive in groups, primary,
layout, rules and per-monitor settings. An unavailable path never matches another panel by model.
Saving an existing group or rule retains its imported exact selectors.

On startup, imported solo captions containing model, ShortId and a connection token (for example
`UID256`) migrate only when all components identify one panel with a stable fingerprinted mode.
Shortcuts and other mode references migrate together. Ambiguities, missing physical targets,
non-fingerprinted destinations and conflicting bindings remain available for explicit reselection;
they are never reassigned to a model-only key. Existing group names and membership are preserved.

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

Settings are replaced only after a complete new file is written. The previous complete save
is kept as `settings.json.bak`; an unreadable primary is retained as `settings.json.bad` and
recovered from the backup when possible. Defaults are used only when neither copy can be read.

## When the world changes by itself

Three things rearrange your desk without asking: waking from sleep, a monitor going away,
and a monitor coming back. Windows decides what the desk looks like in all three cases, and
its decision is not the one you made.

All three sit in **Settings → Behavior**: two toggles and a dropdown of every mode. The same
three keys by hand:

```json
"reapply": { "onResume": true, "onUnplug": true, "onPlug": "" }
```

- **`onResume`** — after the computer wakes up, the mode you chose last comes back. Five
  seconds after the wake-up event, because straight after it the monitors are still coming
  up and Windows answers questions about half a desk.
- **`onUnplug`** — a display went away (cable out, or switched off with its own button), so
  the last chosen mode is applied to what is left: the arrangement and the taskbar are put
  back on the remaining screens. Nothing new is ever switched on by this.
- **`onPlug`** — a display appeared. Empty by default, so nothing happens: after a monitor
  comes back, Windows puts up whatever arrangement it remembers, and the desk is whatever it
  decided. Name a mode here (`"all"`, `"combo:Work"`) and the desk is assembled by the
  switcher instead.

  It fires **only when the display that appeared belongs to that mode**. Switching off the
  monitor somebody just switched on by hand is a war with a human, and without this it would
  be exactly what `"combo:Work"` did to a display the combination does not include. With
  `"all"` every connected display belongs to it, so the desk is always assembled.

  And it stays quiet for ten seconds after **any** display went away — including the one
  that then comes back. When a monitor drops off the bus, Windows lights up whatever is left,
  and those screens arrive as a plug of their own a second or two later; a monitor in deep
  sleep does the same by itself, leaving the bus and returning within a second. Neither is a
  hand on a cable, and both used to walk the desk over to a mode the display you were working
  on is not part of. A real hand is slower than that: switching a monitor off and on by its
  own button takes longer than ten seconds, and if it did not, the next press works.

  A cable swapped in one go is still a plug — there the new display is the news.

Only **connected** displays are compared, never the ones that are on. The switcher turns
displays on and off constantly; reacting to its own work would be an endless loop.

None of this happens while a game is on the screen. Rearranging displays under a full-screen
app drops its Direct3D device — the picture blinks, the window falls out — so the rebuild
waits, and runs within fifteen seconds of your leaving the game. It is postponed, not
dropped: a display that went away leaves the arrangement in pieces, and those pieces are what
you would come back to otherwise. Switch modes yourself in the meantime and the postponed
rebuild is forgotten — you have just said what you want.

None of this ever overwrites the mode **you** chose. When explicitly enabled, `restoreLastMode`
brings back your last choice at application startup, not the last thing the switcher did on its
own — otherwise a monitor that fell asleep at the wrong moment would quietly become your new
default, and every event afterwards would confirm it.

## Rules

"This happened - become that." A rule watches for a condition and puts the desk into a
mode while it holds.

**Settings → Rules** lists them: what each one watches for, where it takes the desk, and a
switch to turn it off without deleting it. **Add a rule** and **Edit** open a small window
with four questions — when, what to watch, where to go, where to come back to. Renaming a
combination carries the rules that point at it; deleting one takes them with it. The same
list by hand:

```json
"rules": [
    { "when": "process", "process": "cs2", "mode": "solo:LG ULTRAGEAR" },
    { "when": "idle", "minutes": 30, "mode": "combo:Movie night", "back": "combo:Work" },
    { "when": "displays", "displays": ["U2720Q", "ULTRAGEAR"], "mode": "combo:Home", "back": "solo:LAPTOP" }
]
```

| Field | What it is |
| --- | --- |
| `when` | `process` — that process is running; `idle` — nobody has touched the computer for `minutes`; `displays` — the connected displays are exactly the ones in `displays` |
| `process` | process name, with or without `.exe`, as Task Manager shows it |
| `minutes` | for `idle` only. Zero means the rule never fires |
| `displays` | for `displays` only: names or Monitor IDs, matched the way `layout` matches them. Exactly this set — a rule for the one monitor at the office does not fire at home, where that monitor is there too. Connected is enough; a display that is off at its own button counts |
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

## Brightness

A monitor's brightness lives in its own firmware, not in Windows, and is reached over
DDC/CI — the service channel inside the HDMI/DisplayPort cable that the buttons on the
bezel use. So a mode can carry it.

**In the Settings window** it lives inside the mode itself: press **Edit** on any mode and
scroll to **Brightness**. There is no brightness card of its own — a mode is set up in one
place. Say what should happen to it —

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
the list at the top of Brightness, which is your decision — and switching to per-display seeds every slider with
the number you were looking at.

**Contrast** is a card of its own right below, with the same three choices and the same
sliders. Fewer monitors answer for contrast than for brightness, which is what **Ask the
monitors** is for — one walk of the bus reports both.

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

**Settings → Edit** on any mode has two boxes, **Before switching** and **After switching**.
What they run is your business:

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
**Statistics…** in the menu opens that as a window: time at the computer, per display, per
mode, per app, which app on which display, an hour-of-the-day histogram, your usual day
from first to last, longest single session, switches, days in a row. The period is a row of
pills — **Today**, **7 days**, **30 days**, **All** — and the whole thing is one screen: no
scrolling, and nothing hidden a fold below. **Open as a page** writes the same report to
`stats.html` and opens it in the browser, for when you want it as a file rather than a look.

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
.\Set-Display.ps1 hdr           which displays can do HDR, and whether it is on
.\Set-Display.ps1 stats         the diary, as a report in the console
.\Set-Display.ps1 all           every connected display
.\Set-Display.ps1 back          the mode you left last, whoever switched away from it
.\Set-Display.ps1 "Movie night" a combination, by its name
.\Set-Display.ps1 work          the same, when the name is one word
.\Set-Display.ps1 ULTRAGEAR     one display, by part of its name
```

`-PrimaryMatch <name>` overrides the taskbar display for this call. `-KeepMode` retains
the resolution and exact refresh rate of displays that are already active; a sleeping
display uses its saved mode when one is available. During exact restoration, a live mode
that conflicts with the saved arrangement or orientation is refused before applying it.
The verified result is also protected from the watchdog and automatic reapply.
`-DryRun` prints what would happen without touching anything.
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
22:35:14  done: LG ULTRAFINE 3840x2160 @ 60 Hz, LG ULTRAGEAR 2560x1440 @ 144 Hz (2.5 s: state 0.2, apply 0.9, settle 0.3, modes 1.1)
```

That is a healthy switch: the desk was rebuilt once (`full config applied`), and the checks
after it found nothing left to fix. The `done:` line breaks the total down by phase, so a
slow switch tells you whose second it was: `state` and `layout` are the tool's own work,
while `apply`, `settle` and `modes` are mostly waiting for Windows and the displays
themselves. Whatever runs after the desk is up — window positions, audio, DDC brightness —
is timed on a separate `after:` line. Lines to notice if it feels rough: `rates left to
Windows` means the exact refresh rate was not known yet and will be learned by the next
switch; `topology set` instead of `full config applied` means the single call was refused
and the old three-step path ran; a `mode:` line means one display needed its rate corrected
afterwards, which is a second rebuild.

Four things worth knowing:

- **After editing the scripts, restart the tray.** It runs the code as it was when it
  launched, so a fix looks like it did nothing until you restart or reboot.
- **A display that dropped its DisplayPort link needs the cable replugged.** The power
  button is not enough, and no software can fix it — the log will say the display did not
  come up.
- **Downloaded scripts carry a mark.** Windows tags everything that came from the internet,
  which is why Explorer asks about `Displays.cmd` and why your own console refuses to run
  `.\Set-Display.ps1`. The tray clears the mark from its own `.ps1` and `.cmd` files the
  first time it starts and writes `removed Mark-of-the-Web` in the log. Every other kind of
  file it leaves marked on purpose: on a downloaded installer or document that same flag is
  what SmartScreen and Office Protected View go by, and the tool has no business disarming
  something that merely sits in the same folder. To do it by hand instead:
  `Get-ChildItem -Recurse -File | Where-Object Extension -in '.ps1','.cmd' | Unblock-File`.
- **If nothing happens at all when you run `Displays.cmd`,** your execution policy is
  probably set by group policy — a work laptop, usually. The `-ExecutionPolicy Bypass` the
  launchers pass is ignored in that case, and the hidden PowerShell dies before it can even
  write a log. `Get-ExecutionPolicy -List` says whether `MachinePolicy` or `UserPolicy` is
  the one deciding; if it is, this needs whoever administers the machine.

## Why PowerShell, and why that is safe

Because the job is a dozen Windows API calls and a window, and Windows PowerShell 5.1 is on every
Windows 10 and 11 machine already. There is nothing to install, nothing runs as a service, and the
program is text you can read before you run it — every line of it is in this repository, and the
folder you unpack is the folder that runs. The Windows API layer is compiled from the C# at the
top of `DisplayCore.ps1` on the first start, into a `native-*.dll` next to the scripts, and that
file is rebuilt whenever the source changes; it is the only binary here, and it is made on your
machine from the source you can see.

What that costs you: a first start takes about a second longer while that assembly compiles, the
`.cmd` launchers open through `powershell.exe` rather than as an `.exe` of their own, and
SmartScreen has never heard of the ZIP you downloaded. What it does not cost you: a background
service or an installer. Disable Start with Windows, exit the tray, then delete the folder.

## How it works

Everything goes through the Connected Display Configuration API (`QueryDisplayConfig` /
`SetDisplayConfig`), not the legacy `ChangeDisplaySettingsEx` path. The difference is not
academic: on the machine this was built for, the legacy call returns `-1` for every monitor
and the layout simply cannot be written, while CCD does both the primary move and the
enable correctly.

A switch is **one** call: which displays are on, where they sit, which one is primary, and
at what resolution and refresh rate — all in a single `SetDisplayConfig`. That matters for
how a switch feels rather than for how long it takes. Every rebuild of the desktop freezes
the compositor and the mouse for a moment, and doing three of them in a row (set the
displays, then move them, then fix the refresh rate) means the cursor stalls and jumps
forward, screens blink twice over, and every open window gets told the display changed
three times.

Exact restoration uses `desktop-layouts.json`, keyed by the physical display set, with
source coordinates, rotation, standard CCD target scaling and the driver's refresh fraction. It supplies that geometry
in one CCD request and verifies the returned desktop. A refusal is reported instead of
retrying with omitted Hz or replacing the saved orientation with a best-mode guess. The
watchdog respects the restored modes and leaves unverified destinations alone. A failed
restore also cannot overwrite the last good window positions on the next departure, and a
direct retry restores those windows even if the display set has already settled. An unresolved
switch pauses the watchdog; a verified refusal preserves the unchanged source protection.
The snapshot is separate from the legacy best-mode
cache in `display-modes.json`.

Scaling preserves whether the image is centered, stretched or fitted with its aspect ratio.
It is not the Windows text-size percentage. Older snapshots without this field leave scaling
unspecified until a fresh complete desktop is captured. Vendor-private custom transforms and
an unresolved scaling preference are refused before switching because their exact appearance
cannot be reconstructed from this state alone. The supported standard transforms are defined
by [Microsoft's DISPLAYCONFIG_SCALING contract](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ne-wingdi-displayconfig_scaling).

A first subset uses one complete source desktop, preferring the current trusted Windows
arrangement. Nonadjacent components are joined without gaps or overlap, keeping the primary
component in place and leaving the saved full desktop untouched. Separate solo snapshots cannot
establish where those displays belong together.
Repeating All manually preserves the live desk, including a mode retained with `-KeepMode`.

Generated `-KeepMode` plans retain and verify active resolution, rotation, known target scaling and exact refresh;
missing preservation data or a refused exact mode cannot fall back to unspecified rates.

For other sets with no complete known geometry, the fallback repair steps remain. After applying
the set, the tool checks
the arrangement and each mode, and fixes whatever did not take (a display that refuses a
rate, for instance). When everything landed, those checks find nothing to do and cost
nothing. Doing it in one call also removes the ordering problem the three steps had: the
primary display cannot be turned off, so a stuck primary made every mode fail.

P/Invoke types are compiled once and cached next to the scripts. Actual switching includes
driver work and panel wake-up time; historical measurements on the development desk ranged
from 1.3 to 6.9 seconds. Repeating an already active mode took 0.3–0.5 seconds.

## Tests

```powershell
.\tools\check.ps1                    everything below, and four gates more
.\tests\run-tests.ps1               just the tests, about two seconds
.\tests\run-tests.ps1 -Only combos  only tests whose name contains the string
.\tests\run-tests.ps1 -File 14      only that file of cases
```

`tools\check.ps1` is the one command that answers "did I break anything": every script
parses, every `.ps1` is UTF-8 with BOM and CRLF, PSScriptAnalyzer is clean if you have it,
translation keys are consistent, and the tests pass. Non-zero exit on any failure. The parse gate is there because two
scripts here are dot-sourced by nothing, so a typo in them would otherwise survive until
somebody ran them by hand.

Pure functions only: hotkey parsing, mode keys, display-name matching, combinations, the
hotkey-key migration, the primary-display ladder, every spelling `settings.json` accepts and
its round-trip through disk, command-line name resolution, layout retry and the switch
verdict, "are all the displays already in their best mode", the Settings window's save path
including how mode keys follow a rename or a removal (the window is built but never shown),
window-layout keys, the remembered mode, the startup-restore decision, rule decisions, the
rebuild-the-desk decision, brightness plans and the sliders that write them (rows really
built, not just the model), hook launching, duration parsing, the timer window (typing moves
its slider and the slider rewrites its field), the desk drawn into its cards, the diary window (each
period picks its own days, and the bars stay inside their tracks), and the whole
diary — sums, report, streaks and the page it produces. **No test touches your displays, your
`settings.json`, your log or your diary** — those are redirected to temporary files. Non-zero
exit on failure.

The switch itself is covered too, and without touching a monitor: `Switch-DisplayMode`
reaches hardware and disk only through named functions, and a test declares its own
stand-ins for them. So it can check *what* was called and *in what order*: that the desk
was built in one transition and not three, that a refusal is reported as a refusal, that
the before-command never runs for a switch that cannot happen.

`tests\live.ps1` is the opposite of all that: it drives your real desk, by hand only. It
switches through every mode, checks the set, the taskbar, the positions and the refresh
rates after each one, then puts the desk back. `-ReadOnly` runs only the command-line
smoke checks and leaves your displays alone.

No Pester on purpose: PowerShell 5.1 ships an ancient 3.4, and installing a newer one would
break the "nothing is installed on your system" promise.

## Files

| File | What it is |
| --- | --- |
| `DisplayCore.ps1` | all the logic, definitions only — one source of truth for tray and CLI |
| `Displays.ps1` | the app: tray icon, menu, hotkeys, rules, timers |
| `SettingsDialog.ps1` | the windows (WPF, themed after the system): Settings, the mode editor, the rule editor, the timer popup and the diary, separate so they can be built in isolation |
| `WindowLayout.ps1` | window-position snapshots per display set |
| `Activity.ps1` | the diary and its report |
| `Diagnostics.ps1` | a support snapshot with an explicit field allowlist |
| `lang\*.ps1` | the interface, one file per language (`en`, `ru`, `uk`, `es`, `fr`, `de`). Drop another `code.ps1` beside them and it appears in the Language list - no code to change |
| `Set-Display.ps1` | the command line |
| `tests\run-tests.ps1` | the test runner: `framework.ps1`, `fakes.ps1`, and one file per group in `cases\` |
| `tests\live.ps1` | the same questions asked of your real desk, by hand (`-ReadOnly` changes nothing) |
| `tools\check.ps1` | every gate in one command - run this before calling a change done |
| `Make-Icon.ps1` | regenerates `app.ico` |
| `render-preview.ps1` | renders the Settings window, a mode editor, the timer popup, the diary and a rule editor to PNGs without showing them, for checking the UI (`-Fake` invents a desk and a diary, `-EditorMode` picks whose editor) |
| `Displays.cmd`, `all.cmd`, `work.cmd`, `game.cmd`, `status.cmd`, `diagnostics.cmd` | one-line wrappers so the tray and the common modes are double-clickable |
| `settings.example.json` | a `settings.json` with every key filled in, to copy from |
| `last-run.log` | the log; rotates past 1 MB |
| `settings.json`, `window-state.json`, `last-mode.json`, `desktop-layouts.json`, `display-modes.json`, `known-displays.json`, `activity.json`, `stats.html`, `native-*.dll` | created as needed, safe to delete |

The release ZIP holds the program only — the scripts, the launchers and the README. The
tests, the gates, the screenshots and the engineering notes live in the repository,
because that is where they are of any use.

The engineering notes are worth a look if you are here for the display API rather than the
tool — they are a day-by-day account of what Windows actually does, with measurements:
[`docs/notes.md`](https://github.com/GangHack/DeskModes/blob/main/docs/notes.md).

## Also here

- [CHANGELOG.md](https://github.com/GangHack/DeskModes/blob/main/CHANGELOG.md) — what changed in each version, and why you would care.
- [CONTRIBUTING.md](https://github.com/GangHack/DeskModes/blob/main/CONTRIBUTING.md) — how to make a change stick, and the one command that
  decides whether it is done.
- [SECURITY.md](https://github.com/GangHack/DeskModes/blob/main/SECURITY.md) — what the tool touches, what it does not, and how to report a
  hole privately.

## License

MIT — see [LICENSE](https://github.com/GangHack/DeskModes/blob/main/LICENSE).
