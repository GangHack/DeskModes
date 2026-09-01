# ScreenDeck — engineering notes

This is an **engineering diary**, not documentation. The description of the project, its
installation and its settings are in the [README](../README.md); what is here is what has no
business being in a README: what Windows actually does with monitors, which measurements
showed that, which diagnoses turned out to be wrong, and why. It was written as things
happened, in the first person, with dates. In places it describes the author's particular desk
(three monitors, two graphics cards) — that is deliberate: without the specific figures these
conclusions would be worth exactly nothing.

If you came for the Windows display API rather than for a utility, the most useful parts here
are the ones about writing the layout the old way versus CCD, about the primary monitor that
got stuck, and about which monitor identifiers are actually stable.

A switcher for the active monitors: an icon in the notification area, global shortcuts, run at
startup.

Inside there is nothing but PowerShell and the Windows API. Nothing is installed on the
system: the folder can simply be deleted, and two shortcuts (Start menu and startup) will be
left behind.

## How it is put together

### The icon

`app.ico` is used both in the tray and on the shortcuts — in the Start menu and in startup.

`System.Drawing` cannot save a real multi-size `.ico` (PNG inside, the Vista+ format), so
`Make-Icon.ps1` assembles the header and the directory by hand. Every size is drawn separately
rather than scaled from one: at 16-20 px the second monitor turned to mush, so only one screen
is left there. In the tray the size is asked of the system
(`SystemInformation.SmallIconSize`) — at 150% scale that is no longer 16 px.

**The icon's tile is opaque**, and that is deliberate: a white glyph with no backing disappears
on a light taskbar, and a dark one on a dark taskbar.

The Start-menu shortcut keeps **its own copy** of the path to the icon. Move the tool's folder
and the icon will vanish and turn into a blank sheet — the path in the shortcut stays the old
one.

### Nothing is hard-coded

The modes are built out of the current state on every request: every connected monitor gets a
solo mode of its own by itself, plus "all connected". Nothing else is guessed at: which
monitors work together is a person's decision rather than a property of the hardware, and named
sets (combos) are only created by hand, in the Settings window.

A solo mode's key is the **monitor's name** (`solo:LG ULTRAGEAR`). Neither the output number
nor either of the Monitor IDs can be cached, and that has been verified twice:

- the **full** Monitor ID changes when a cable is moved to another port (on the ULTRAFINE
  `GSM5CBB\…\0005` → `\0002`), and the `\.\DISPLAYx` numbers get rearranged too;
- the **short** Monitor ID changes when moving to another **input on the same monitor**. A
  monitor on DisplayPort and on HDMI has different EDIDs, and the product code in them
  differs. After the cables were moved around, the ULTRAGEAR became `GSM5BB4` → `GSM5BB3` and
  the ULTRAFINE `GSM5CBB` → `GSM5CBC` — and the `Ctrl+Alt+F1/F2` bindings started pointing at
  nothing, and the modes "did not work". The short ID is stable not for a monitor but for a
  "monitor + input" pair.

A name does not depend on the input, so the key is built from it. Two identical models would
give one key between them — in that case the short ID is appended to the name. Old bindings
move to the new keys by themselves (`Update-HotkeyKeys` at startup, with a `settings: moved …`
entry in the log); a binding for a monitor that is not in the system stays where it is and is
visible in the Settings window.
### The order, and the safeguards

One transition for everything: `Set-CcdFullConfig` sets the **set** of monitors that are on,
their **positions**, who is **primary**, and also the **resolution and refresh rate** of each —
in a single `SetDisplayConfig`.

It was not always so, and the previous shape cost real discomfort. There were three steps:
`Set-CcdTopology` switched the set on, `Set-CcdLayout` arranged the monitors in a second call,
and `Set-BestModeFor` brought the refresh rate up in a third. Each of the three is a separate
rebuild of the desk, and every rebuild freezes the compositor and input: the cursor stalled and
then "shot" forward, the screens blinked twice, and every window got `WM_DISPLAYCHANGE` three
times. In the log of 20 August 2026 such a switch cost 6.3 s; the same one in a single
transition took 4.1 s, and with one freeze instead of three.

The three steps have not gone anywhere, mind — they became the **repair**. After the single
transition the whole desk is still checked: the set, the layout, every monitor's mode. It landed
at once — all three checks see "already correct" and do nothing; it did not — whoever's part
failed fixes it. A failure of the transition itself does not lose the switch either:
`Set-CcdFullConfig` returns `$false`, and the old road of three steps takes over.

Atomicity matters here in its own right. The order of the steps used to matter, because the
primary monitor cannot be put out: the role would not leave the ASUS, so it would not go out, so
not one mode came out right. A single transition removes the question of order altogether — the
system is asked about the final state, and how it gets there is its own business. It also does
away with the intermediate state in which more screens hung on the desk than were asked for.

Two details without which the single transition does not work.

**The refresh rate takes an exact fraction only.** CCD accepts a refresh rate not in whole hertz
but as a rational number, and it accepts only one that exists: 144 Hz on this machine is
`143999/1000`, 60 Hz is `59997/1000`, and the ASUS's 240 Hz is `239970/1000`. A request for
"144/1" the system rejects entirely — `validate -> 1610`, verified on 20 August — and the
resolution and the layout would be lost along with the refresh rate. There is nowhere to get the
fraction from for a monitor that is out: `EnumDisplaySettings` enumerates modes only for an
active output, and out of EDID the system hands back the native resolution alone. So after every
switch what the monitor **really showed** is remembered in `display-modes.json` (device path ->
`w`, `h`, `hz`, `num`, `den`), and the next switch asks for exactly that. A fraction is only good
for its own mode: we remember 144 Hz and 240 is asked for — so there is no fraction for 240, the
system chooses the rate, and the repair step brings it up and teaches the cache for next time.
The file is the machine's state, like `last-mode.json`, and it does not reach git.

**Without the monitors' order we do not take this road.** Setting the whole desk means naming
coordinates for every screen, and there is no "do not know" among them — it would turn out that
the monitors are arranged by our judgement (alphabetically) where nobody asked us to. An empty
`layout` in the settings means the old road, which moves only the primary monitor and leaves the
rest standing; in the log that shows as the line
`ccd: no display order in the settings`. One screen is the exception: there is nothing to arrange
it against, its place is the coordinate origin, and a solo mode is what gets pressed most often —
so that one goes in a single call with no order at all (2026-09-01, see the review at the end).

**The primary is moved on both roads**, and until 2026-09-01 it was not: `Set-CcdLayout` sat behind
`if ($order.Count -gt 0)` in `Switch-DisplayMode`, so a desk with no `layout` never had its taskbar
placed — the sentence above described a road nobody was driving.

Every step first looks at whether it needs doing at all: the set of active monitors is compared
with the requested one, and the desired positions with the current ones. They match — the step
is skipped with the line `switch: topology already correct` or `layout: already correct`. That is
what it exists for: pressing the same mode again stopped being a full rebuild of the desk with a
blink.

A refusal is checked by the fact rather than by the return code: after the transition the
application verifies that exactly what was requested came on, and any spare screens reach the
summary as the line `Still on:`. It waits **on a condition rather than on a timer** — it polls
the state until it becomes the requested one, and writes `warn:` when the deadline runs out.
There are two deadlines: how long to wait for the monitors to wake up (the ASUS out of standby
takes seconds), and how much longer to wait for the spare ones to go out after everything we need
is already on the desk. With one shared deadline a refusal to go out would cost the whole fifteen
seconds of waiting on a path that had failed anyway.

If Windows rejects the configuration, **nothing** changes — `SetDisplayConfig` is called with
`SDC_VALIDATE` first. There is no way to be left without a picture.

**One switch at a time** (the mutex `Local\ScreenDeckSwitch`). Without it, two quick presses
started two processes that cut across each other — one was switching a monitor on while the other
was changing its mode. In the log that looked like random refusals. Now the second press is
dropped with a `skip:` entry.

The refresh-rate watchdog takes the mutex too, so a `skip:` in the log means not only "pressed
two combinations in a row" but also "pressed at exactly the moment the watchdog was dealing with
a layout change". That is by design: wait a couple of seconds and press again.

### The menu and the state cache

The menu has to open instantly. When a state query cost 1.5 s and sat right inside the `Opening`
handler, **a right-click on the icon did not work at all**: Windows managed to decide the menu
had never shown and closed it. The left click worked only because we invoke the menu's showing
ourselves, and that tolerates a delay.

A query costs ~90 ms now and could live right inside the handler, but the cache has been kept: it
complicates nothing, and the story above shows what blocking work in `Opening` leads to.

So the state is kept in a cache: it is warmed at startup, refreshed after every switch and on the
system's `DisplaySettingsChanged` event — that is, also when a monitor was switched on or
reconnected past the application.

### The refresh rate

It is set explicitly: on power-on Windows returns a monitor to the mode out of the registry, and
that is often below the native one — 4K dropped to 30 Hz, 2K/144 to 120, and the ASUS came up at
59 Hz instead of 240. The maximum is the **highest refresh rate at the native resolution**, and
the resolution comes from EDID rather than from the driver.

**Why not ask the driver.** For the ULTRAGEAR it reported `Maximum Resolution 3840x2160`: over
HDMI the monitor accepts 4K and squeezes it into its own 1440p itself. Because of that the rule
"the largest area, then the refresh rate" aimed at `3840x2160@60` — which could not be applied
(`mode: … failed` in the log), and had it succeeded it would have dropped 144 Hz to 60.

The native resolution is EDID's first detailed timing (the preferred timing). The system hands it
back itself: `DisplayConfigGetDeviceInfo` with `GET_TARGET_PREFERRED_MODE`, and **for a monitor
that is switched off as well**. There used to be a walk of the registry here
(`HKLM\SYSTEM\CurrentControlSet\Enum\DISPLAY\…\Device Parameters\EDID`) with picking the right
record out of those left over from earlier connections and parsing byte 54 by hand — 36 lines
that are replaced entirely by one call.

One subtlety: the preferred mode's `vSyncFreq` is the *preferred* refresh rate rather than the
maximum (on the ASUS it is 59.95 Hz with 240 available). Only the resolution is taken from there;
the refresh rate is still chosen by walking the modes.

Four non-obvious points this used to break on:

1. **A command that does not report its errors is worse than no command at all.** The request
   "set 60 Hz" went out, looked successful in the log, and the monitor stayed at 30 Hz. So the
   mode is set through `ChangeDisplaySettingsEx` — it returns a code, a miss is visible at once,
   and a second attempt is made with a check of the actual mode.
2. **The mode is set as the last step**, after the primary monitor has been assigned and the rest
   have been put out. Both of those reset the refresh rate to the one written in the registry,
   that is, an earlier setting was simply overwritten. Anything external resets it too:
   `DisplaySwitch /extend`, for instance, dropped 4K from 60 to 29 Hz before our eyes.
3. **A monitor has to be waited for with retries rather than a fixed pause.** At first there was
   a 900 ms wait after the switch-off, then the output map was read — and it still answered "not
   attached". Setting the mode and the summary stood behind an "if attached" check and were
   **silently skipped entirely**: the log held an empty `done:` and not one `mode:` line, and the
   refresh rate stayed unreset. Now every monitor is waited for separately (`Get-CcdOutput`, up
   to 8 s), and when it never turns up a `warn:` is written.
4. **`CDS_UPDATEREGISTRY` does not work on every monitor.** On the ASUS ROG STRIX writing the
   mode to the registry answered `failed` for **any** refresh rate — even for the one already
   set. The same mode with `flags = 0` (apply, do not remember) lands instantly. Because of that
   the monitor stayed at 59 Hz instead of 240. Both LGs worked fine with the write.

   **Measured 11 August 2026: it has passed.** The same call with `CDS_UPDATEREGISTRY` at
   2560x1440@240 returned **code 0**, the mode landed and was remembered. That is, all five
   `not saved to registry` entries in the log are one evening, 5 August, as written below — an
   episode rather than a property of the monitor. The workaround (a retry without the registry
   write) stays: it costs nothing on success, and the episode may recur.

   So on a refusal `Set-DisplayMode` repeats the call without the registry write and logs
   `ok (not saved to registry)`. The refresh rate matters more than saving it: the mode is set
   afresh on every switch anyway. Codes `-2`/`-5` (the mode is impossible) are not retried.

   There was one more quiet defect in the same place: `Set-BestModeFor` returned from the function
   on any error, so the second attempt promised in the comment **never happened at all**.

### Speed

The state is read through CCD — one `QueryDisplayConfig` call. That is ~90 ms for everything
(including the walk over the modes to pick the best one). The previous way — start an external
utility, let it dump a CSV into a temporary file and parse that — cost **1100 ms**, and those had
to be paid on every switch, on every menu open and on every firing of the watchdog.

The state cache in the tray was created for that second's sake, and invalidation on a system event
along with it. The cache has stayed, but now it saves milliseconds rather than seconds.

### How long a switch takes (measurements of 11 August 2026)

| What | Before | After |
| --- | --- | --- |
| One monitor | 2.8 s | **1.3 s** |
| Both LGs | 4.0 s | **1.6 s** |
| All three, ASUS out of standby | 14.9 s | **6.9 s** |
| Pressing the same mode again | 2.4 s, the screens blinked | **0.3–0.5 s**, no blinking |
| `status` from the command line | 0.63 s | **0.47 s** |
| Tray startup until the shortcuts work | — | **0.5 s** |

Every switch's duration is now written into the log: `done: … (1.6 s)`. That is not for
decoration — without figures for the past weeks the question "has it got slower?" is unanswerable.

Since 2026-08-24 the overall figure has a per-phase breakdown: `done: … (6.1 s: state 0.3, apply
1.0, settle 0.1, layout 3.2, modes 1.5)`. It answers the question "whose second is this": `state`
and `layout` are our own work, while `apply`, `settle` and `modes` are mostly waiting on the
system and on the monitors themselves. The tail after the desk is assembled — the windows, the
audio, the brightness over DDC — is written as a separate `after: …` line: the brightness is
brought up for seconds with the picture already there, and without that line its time would look
like a hole between entries.

Where this came from:

- **Do nothing when there is nothing to do.** Before the desks are rebuilt, the set of active
  monitors is compared with the requested one and the desired positions with the current ones.
  They match — `switch: topology already correct`, `layout: already correct`, and no switch
  happens at all. Hence the 0.3 s on a repeat press instead of a full cycle with a blink.
- **Wait on a condition, not on a timer.** Three fixed pauses (1200, 700 and 600 ms) have been
  replaced by polling: the moment the system reports the state we want we move on, and when the
  deadline runs out we write `warn:`. A pause is at once too long in the ordinary case and too
  short in the bad one.
- **Do not recompute what has already been computed.** Right after a topology change, walking a
  monitor's modes (`EnumDisplaySettings` over the whole list) costs **1.6 s** instead of 60 ms at
  rest — the driver hands them back slowly. For a monitor that was on the desk before the switch
  too, the best mode is already known from the state on the way in, and there is no point
  recomputing it: it is a property of the panel, not of the layout. In "all three" mode that is
  2.4 s less.
- **One compilation instead of four.** All the Windows types are built by a single `Add-Type` and
  put into `native-<hash>.dll` next to the scripts. Edit the C# and the hash changes and the
  assembly rebuilds itself; forgetting is impossible by construction. 320 ms → 50 ms on every
  run. The cache broke — `core: dll cache failed` is written, and the types are compiled into
  memory as before.

**What is left, and why.** In "all three" mode about five seconds is the ASUS physically
resynchronising its panel from 59 to 240 Hz. It becomes addressable 0.75 s after the command, so
this is not about waiting: that is the time of the mode change itself, and no software shortens
it.

### Writing the layout: the old path is broken, CCD works (verified 7 August 2026)

This took two days and three wrong diagnoses, so what is here is only what has been confirmed by
a live check on this machine.
**The fact.** Every attempt to write the layout the old way answers with a refusal:

| Method | Result |
| --- | --- |
| `ChangeDisplaySettingsEx`, changing the position with `CDS_UPDATEREGISTRY` | `-1` on **all three** monitors |
| `SetDisplayConfig` through CCD, shifting the positions | **works** |
| `SetDisplayConfig` through CCD, switching monitors on | **works** |

**The consequence that made nothing at all work.** The ASUS was primary. The primary role cannot
be moved the old way, and Windows does not let the primary monitor be switched off — so neither it
nor its neighbours went out, and any mode other than "everything on" failed. And every command
answered with success.

**The solution.** The primary is moved through CCD, and so are switching on and putting out: these
days that is a single `Set-CcdFullConfig` for everything at once — the set of screens, the
positions, the primary role and the modes — while `Set-CcdTopology` with `Set-CcdLayout` remained
the repair and the fallback road. "Primary" in Windows is not a flag but a position: the monitor
whose top-left corner lies at (0,0) becomes it. So it is moved by shifting the whole layout.

This used to say "the old path has been kept as a fallback". That is wrong: there is no legacy
fallback path for the layout and the primary in the code, and there is no point creating one — on
this machine it is dead, and `SetDisplayConfig` is called with `SDC_VALIDATE` first, so there is no
way to be left without a picture even without a second path. The legacy call stayed in exactly one
place — `Set-DisplayMode`, the mode change — and there it works.

**What used to be written here wrongly** (corrected 7 August, after verification):

- "The modern API answers with success and does nothing" — the test was invalid.
  Per the documentation, `SDC_TOPOLOGY_*` **must** be given `NULL` instead of an array of paths and
  cannot express "switch on these monitors"; it reproduces the saved layout for the current set.
  What is needed is `SDC_USE_SUPPLIED_DISPLAY_CONFIG`, and with that everything works.
- "`DisplaySwitch.exe /internal` does not work either" — `/internal` means "the built-in screen
  only". This is a desktop computer; there is no built-in screen. The test tested nothing.
- "The monitors will not switch off" — they do. Putting them out worked all along.
- "The refresh rate is not remembered in principle" — `not saved to registry` occurs in the log
  **five times**, all on 5 August between 16:32 and 18:12, all about the ASUS. That was an episode
  rather than a property of the machine.

**A trap when testing.** A matrix of flags that writes **the same** values as are already set
returns 0 for every variant — the system always accepts a "write" like that. Testing has to be done
by really changing a value. The mirror trap turned out to be more dangerous: the testing code was
reading **the wrong monitor** (see below), and the whole wrong diagnosis was built on its readings.

There is no need to reinstall the NVIDIA driver or clean out
`GraphicsDrivers\Configuration`: that is treating a disease that does not exist.

### A broken instrument: the output map was reading the wrong monitor

The function `Get-OutputMap` is no longer in the code — the output names come from CCD. The lesson
stands.

The project's most expensive mistake, because conclusions about Windows were built on its readings.

An adapter `\.\DISPLAYx` can have **several** child monitors: the ones that are off are dumped
onto one output, and records left over from earlier connections stay there too. The code held a
hard-coded index:

```powershell
EnumDisplayDevices($adapter.DeviceName, 0, [ref]$monitor, 0)   # always child #0
```

Whichever came first was read, not the one on the desk. The map collapsed into a single record
pointing at a **detached** output, and everything that rested on it lied. In the log it looked like
this:

```
19:28:29  warn: ROG STRIX XG27AQDMGR did not attach within 8 s
19:28:29  done:
```

— at a moment when the ASUS was on and was the primary.

First the function was fixed — walk every child and count only the one with its own
`DISPLAY_DEVICE_ACTIVE` flag as live. Then it was removed altogether: activity is asked of CCD
(`Wait-ForTopology`), where the flag sits on the monitor's own path and there is nothing to confuse
it with a neighbour's. Exactly one call is left from the old API — `Get-PrimaryOutput` — and even
that reads only adapters, which have no child monitors at all.

**The rule that should have been drawn earlier:** before explaining the system's behaviour by a
defect in it, check that your instrument is looking at the same device you are talking about.

### A monitor that is switched off loses its name in the old enumeration

Another reason for moving to CCD, and it is not about speed. Enumeration through `EnumDisplay*`
hands this back when the monitors are out:

| Output | Monitor name | Short ID | Active |
| --- | --- | --- | --- |
| `\.\DISPLAY1` | ROG STRIX XG27AQDMGR | AUSAA1D | yes |
| `\.\DISPLAY2` | *(empty)* | *(empty)* | no |

The two LGs that were off collapsed into one nameless row. There is nothing to switch them on by
name with, and addressing a monitor by its output number is no good either: the numbers get
shuffled.

In the same state CCD enumerates all three monitors with their names, with a `targetAvailable`
flag and with the native resolution. So the set of monitors that are on is given by
`Set-CcdTopology` — whole and in one call.

### Where the monitors stand

Windows lines the screens up in whatever order it pleases, and after every switch the order can
come out different. The cursor then goes right onto a monitor that physically stands on the left.
So the layout is given explicitly, in `settings.json`:

```json
"layout":  [ "LG ULTRAFINE", "XG27AQDMGR", "LG ULTRAGEAR" ],
"primary": "ULTRAGEAR"
```

`layout` is the names left to right, as the monitors stand on the desk. They can be written in
parts: `UltraGear` will find `LG ULTRAGEAR`. A monitor that is not in the list goes to the end.

`primary` is where the taskbar will be, if that monitor is on. The preference is soft: it is not in
the mode — then the rightmost one by `layout` is taken. Without this setting the primary stayed
whoever it had been before, and the taskbar moved from one switch to the next.

Vertically the screens are aligned **centred** rather than at the top: 2160 and 1440 points — with
a top alignment a strip is left at the bottom of the tall one that the cursor cannot cross to the
neighbouring screen from.

The layout is worked out in `Get-LayoutPositions` — a pure function, with not a single call to the
system, which is why it is covered by tests. Two callers ask it, and the answer has to be one and
the same: `Set-CcdFullConfig`, which sets the whole desk (there the sizes are the **target** ones —
a monitor may still be out), and `Set-CcdLayout`, which adjusts a desk that already stands (there
the sizes are the current ones). Let those two calculations diverge and the repair pass would move
the monitors after the main transition — that is, it would bring back that very extra rebuild of
the desk.

The layout and the primary role are one and the same action in Windows: the monitor whose top-left
corner lies at (0,0) becomes primary, so the whole layout is shifted to bring the monitor we want
to the coordinate origin.

The layout is applied with a check (`SDC_VALIDATE`), and right after a topology change the check can
refuse: on 17 August 2026 it returned 87 (`ERROR_INVALID_PARAMETER`) on a configuration snapshot the
system itself had handed back a moment earlier — the transition had not settled yet. There was one
attempt then, and until the next shortcut the monitors stood the way Windows had arranged them:
muddled up, with a green report of success. Now there are up to three attempts, each with a fresh
`QueryDisplayConfig` and a 0.3 s pause — in the log they show as
`ccd: layout validate -> 87 (attempt 1/3)`. If the third does not work either, the switch does not
pretend to have succeeded: `positions not arranged` is added to the summary, the tray shows a yellow
"Switched with problems", and `Set-Display.ps1` returns a non-zero code.

This used to say that the same call is made once more before the switch-off, without the order: the
primary monitor cannot be put out, so the role has to be carried away from it in advance. That
description fell behind the code — the system moves the primary role inside the atomic transition
itself, and `Set-CcdLayout` in `Switch-DisplayMode` is called exactly once and usually only confirms
that the positions are already correct: `Set-CcdFullConfig` set them together with the set of
screens.

### The refresh-rate watchdog

`Restore-BestModes` is called on the system's `DisplaySettingsChanged` event: if a connected monitor
has ended up below its best mode, the mode is set again.
That is how the ASUS holds 240 Hz, even though the system cannot remember them. The bounce is damped
(one layout change raises the event several times), and during a switch the watchdog keeps quiet —
the modes are being set there anyway. In the log those are the `watch:` lines.

#### The watchdog and games

The watchdog was wrong twice in the same direction — it took an application's deliberate choice for
a failure of the system. Both prohibitions were added on 6 August after Counter-Strike would not
start because of them: the game set its own mode, the watchdog put the old one back, the game set it
again. The screens blinked, the full-screen mode minimised, and a "Refresh rate restored" balloon
finished the window off. In the log it looked like this:

```
19:12:59  watch: LG ULTRAGEAR dropped to 1440x1080 @ 144 Hz, restoring 2560x1440 @ 144 Hz
19:13:28  watch: LG ULTRAGEAR dropped to 1440x1080 @ 144 Hz, restoring 2560x1440 @ 144 Hz
19:13:46  watch: LG ULTRAGEAR dropped to 1440x1080 @ 144 Hz, restoring 2560x1440 @ 144 Hz
```

**The watchdog does not touch the resolution at all.** What the system drops is the refresh rate
specifically (240→144 and 60→29 in the log), whereas applications change the resolution and do so
deliberately: 1440x1080 is the classic stretched 4:3 in CS. If the current resolution does not equal
the native one, the monitor is skipped with the line
`watch: … leaving the resolution alone, an app set it` (written once per state, so as not to clog
the log).

**While a full-screen application is on the screen, the watchdog keeps quiet.** Changing the mode
under a running D3D is not allowed — the device is lost. `Test-FullscreenApp` asks twice:

| Check | What it catches |
| --- | --- |
| `SHQueryUserNotificationState` (shell32) | states 2, 3, 4, 7 — the same source Windows uses to decide whether to show balloons |
| the active window covers `rcMonitor` entirely | a borderless full screen, which the first check does not see |

A maximised window does not reach this point: it covers `rcWork` but not the taskbar. The desktop
and the shell (`Progman`, `WorkerW`, `Shell_TrayWnd`) are excluded by window class.

There are two checks specifically, and the second stands **after** the state is gathered rather than
only on the way in: the `DisplaySettingsChanged` event arrives before the game manages to open its
window, and on the way in the full screen may not be there yet. Gathering the state takes about a
second — and that is enough.

What was postponed is remembered in `$script:RestorePending`, and the tray picks it up on a timer
every 15 seconds: leaving a borderless full screen comes with no `DisplaySettingsChanged` event, and
waiting for one is pointless. The line in the log is `watch: postponed`.

## When a switch "does not work"

**Open log** in the menu, or `last-run.log`. The application runs without a window, and without the
log an error is not visible at all.

Entries from before 5 August 2026 are in Russian — that is simply old history.

Useful lines besides the ones listed below: `core:` — compiling or loading the Windows types and
rotating the log, `windows:` — window-position snapshots, `auto:` — the automatic game mode,
`audio:` — changing the output device, `layout:` — the monitors' layout.

- **`warn: refused to turn off: …`** — the switch-off command went out and the monitor stayed on the
  desk. See the section above about writing the layout. This check did not appear straight away:
  the `done:` line used to list **only** the monitors that were supposed to stay on, and a refusal
  looked like a complete success in the log.
- **`skip: … the previous switch has not finished yet`** — two combinations were pressed in a row.
  That is by design; wait a couple of seconds.
- **`ERROR: no display … came up`** — the safeguard would not put the rest out. The cause is almost
  always physical, see below.
- **Nothing in the log** — the application is not running. Check the icon, run `Displays.cmd`.
- **`That display is not connected right now`** — the shortcut is assigned to a monitor that is not
  in the system right now. Normal, not a breakage.

### The physical layer is the most frequent cause

DisplayPort has two quirks that look like software failures:

**A monitor drops its link.** Having lost the signal, a DP monitor stops being visible to Windows
altogether — indistinguishable from a pulled cable. **Verified on the ULTRAGEAR: neither
`SetDisplayConfig`, nor `ChangeDisplaySettingsEx`, nor `DisplaySwitch /extend`, nor even the
monitor's own power button helps. Only unplugging and replugging the cable helps.** There is no
software cure for this at all.

That it takes a replug specifically rather than a power cycle points at the physics of the connector:
a worn latch or bad contact on the Hot Plug Detect line. Which means the cable is due for
replacement.

Prevention in the monitor's menu: **General → `Automatic Standby` → Off** (on some models Deep Sleep
Mode) and **`DisplayPort Version` → 1.4**. On the ULTRAGEAR that was already set on 2026-08-04.

Push the cable in until it clicks, at both ends, and without tension: a short cable behind a monitor
works as a lever and pulls itself out. For 4K buy **VESA Certified** only.
### Dead ends not to go back to

- **"This is a Windows 11 24H2 bug"** — an hour of debugging wasted. The symptom "the monitor stopped
  switching on" was produced by a cable working loose.
- **"The DP link degraded, which is why 4K holds 30 Hz"** — also wrong. The UltraFine is connected
  over HDMI 2.1, and 60 Hz was set by hand with no trouble. The real cause was the mode-change
  command silently not applying the refresh rate; see the section on the refresh rate above.
- **Switching a display on through `ChangeDisplaySettingsEx`** (`CDS_UPDATEREGISTRY | CDS_NORESET`)
  — returns `-4` bad flags. On modern Windows it is `SetDisplayConfig` (the CCD API) that attaches
  displays. For a *mode change* the same call works perfectly well.
- **"The refresh-rate fix does not work"** — the fix was right but was never running: see point 3 in
  the section on the refresh rate. Before editing the logic, check in the log that it even reached
  execution. An empty `done:` is the sign that the whole tail of the function was skipped.
- **`Set-StrictMode`** — tried on 2026-08-24 and rejected deliberately, so as not to try again. Both
  `2.0` and `Latest` break the settings parsing: it is built entirely on "the key may not be in the
  file" (`if ($null -ne $raw.stats)`), and strict mode counts a reference to a missing property as
  an error. To turn it on, every such read would have to be rewritten as
  `$raw.PSObject.Properties['stats']` — dozens of places, twice as long and worse to read, with the
  same behaviour: a file edited by hand parses correctly as it is, and there are tests for that. A
  good practice, but not one that suits this code.

### Argument order: name them, do not count them

A positional call of one's own functions reads fine as long as the arguments are of different kinds.
But `Get-DisplayModes` takes `(State, Settings)` while `Update-HotkeyKeys` takes `(Settings, State)`,
and in a place like that a positional call will get muddled sooner or later. So in the working
scripts, calls with two or more "nameless" arguments of the same kind are written with the parameter
names (`-State ... -Settings ...`); short helpers like `Format-DisplayStamp $now 'HH:mm'` and the
assertions in the tests need no names.

### About the interface

An error while building a window the system shows as a nameless window with no detail. So the
Settings window lives in a file of its own and is split into `New-SettingsWindow` (building) and
`Show-SettingsDialog` (showing and saving) — the building can be called from a console and the real
exception seen:

    . .\DisplayCore.ps1; . .\SettingsDialog.ps1
    New-SettingsWindow -Modes @(Get-DialogModes -State @(Get-DisplayState) -Settings (Get-DisplaySettings)) `
                       -Settings (Get-DisplaySettings) -State @(Get-DisplayState)

That is exactly how the crash on an invalid `Anchor = 'West'` in the old WinForms window was found.
The call from the menu is wrapped in a try/catch and writes the exception into the log along with the
line number.

**Read and write the settings only through `Get-ActiveSettings` / `Set-ActiveSettings`.** Event
handlers are created with `.GetNewClosure()` inside other blocks, and a `$script:Settings` reference
inside them resolves **not** to the script's variable: the Settings window got `$null` and died on
`.Contains()`, and the menu silently showed no key combinations. A function runs in script scope no
matter who called it.

The rule is broader than the settings, and it has been verified by experience:

| What is inside the handler | Is `$script:X` visible? |
| --- | --- |
| an ordinary block `{ … }` | yes |
| a block with `.GetNewClosure()` | **no**, nothing comes back |
| a call to a function from any block | yes |

Hence two techniques: keep the logic in functions, and put simple values (the application's name for
an error window's caption, say) into a local variable **before** creating the closure — locals are
exactly what it does capture.

The window is tested with no person involved: a timer closes an already-shown form with the button we
want. The cases run: an ordinary call, `$Settings = $null`, settings with no `hotkeys`, closing
through Save (bindings for missing monitors are preserved), clearing a shortcut to `(none)`, and a
duplicate of one combination on two modes.

**The window edits only what is in it — the rest has to travel straight through.** The save branch
starts with `Get-DefaultSettings`, that is, with a blank sheet. While the fields were carried over
into it by a list, the very first **Save erased `layout` and `primary`**: the monitors stood any old
way again and the taskbar moved around. Now every field is carried over **except** the ones that have
a form element of their own — otherwise each new setting with no window (`audio`, `hooks`) would
bring this bug back.

There is a test for this: it calls the real save branch `Read-SettingsFromUi` and checks that the
fields with no form element of their own arrived untouched.

**WinForms timers do not tick under a modal `MessageBox`.** A test that closes dialogs with a timer
of its own hangs solid on a `MessageBox` — which is what happened; the test hung for two minutes.
Windows like that have to be closed from a **separate process**. And do not trust its report without
verifying: my closer, built on `FindWindow('#32770')`, reported "there was no window" where there
definitely was one. It is more reliable to judge by the fact: if the call has not returned, the window
is shown.

## The mode comes back after the computer is turned on
After power-on Windows brings up **its own** set of screens rather than the one that was chosen
before shutdown: it keeps its own idea of the layout to itself and reports nothing to us. In the log
that is visible across all the days at once — almost every `tray: started` is followed, seconds or
minutes later, by a switch made by hand:

```
2026-08-09 20:33:57  tray: started
2026-08-09 20:34:00  --- start mode=solo:XG27AQDMGR      <- three seconds later, by hand
2026-08-10 10:59:12  tray: started
2026-08-10 11:00:54  --- start mode=solo:LG ULTRAGEAR
2026-08-11 08:28:17  tray: started
2026-08-11 08:34:51  --- start mode=combo:Work
```

So we remember the choice ourselves. Every switch that made it to the end writes the mode key into
`last-mode.json`, and the tray puts it back at startup — a second and a half after the shortcuts
started working (any earlier is not allowed: until the message loop is running the menu does not open
and no balloons show).

What is remembered is the **choice, not the result**: even if one monitor never came up, the person
asked for this mode specifically.

**The restore does not compare sets of screens and does not bail out early** — it always calls the
same `Switch-DisplayMode` a shortcut does. That skips whatever is already done itself (the topology,
the layout, the modes — three separate checks), so on a correct desk the call costs 0.2–0.3 s and
blinks nothing. What it does cure is the case where the screens are the same but the layout drifted
after boot and the taskbar moved to another monitor.

Four reasons not to touch the screens, each writing its own line into the log:

| The line in the log | Why |
| --- | --- |
| `same session as the last switch, leaving the displays alone` | the tray was merely restarted. The set could have been changed by the person themselves through Win+P or Windows settings — that is their decision |
| `'Only LG ULTRAGEAR' is not available right now` | the monitor is not there. The rest must not be put out for its sake: a black desk would be left |
| `a mode was already chosen by hand, not restoring` | a shortcut was pressed before the timer fired. Their choice is newer than ours |
| (silence) | nothing was remembered — a first run |

**How "the computer was turned on" is told from "the tray was restarted".** By a fingerprint of two
values, both read in milliseconds:

* `HKLM\SYSTEM\CurrentControlSet\Control\Windows\ShutdownTime` — the time of the last shutdown. It
  changes on every power-off and reboot, **fast startup included** (`HiberbootEnabled=1` on this
  machine), where the uptime counter may carry on from the previous session and the "moment of boot"
  alone will not do;
* the moment of boot, that is, now minus the uptime (`Stopwatch::GetTimestamp`) to the nearest minute
  — this covers the case where there was no shutdown at all: a crash, a Reset, a loss of power.

It is enough for either of the two to have changed. It is worked out once per process: within one
power-on the answer does not change, while the uptime counter drifts slightly after a long sleep.
`Win32_OperatingSystem.LastBootUpTime` would give the same thing but costs 300 ms — a noticeable
fraction of a second at tray startup.

It is turned off with the "Restore the last mode after turning the computer on" checkbox or with
`"restoreLastMode": false` in `settings.json`.

## Window positions

Changing the set of active monitors moves windows around — that is Windows, and it never puts them
back. **Now the application does.** On by default, with the "Remember window positions per display
layout" checkbox in the settings.

How it works: before the desks are rebuilt, the positions of every ordinary window are taken, and
afterwards they are restored. The snapshot is tied to the **set of active monitors** rather than to
the mode's name: until the ASUS is plugged in, "both LGs" and "all" are one and the same set of
screens, and they have to share a snapshot, or the windows would come back only every other time.

What lands in the snapshot: visible windows with a title. Service windows (`WS_EX_TOOLWINDOW`), child
windows and Store apps' windows hidden by DWM do not. `GetWindowPlacement` is taken rather than
`GetWindowRect`: it carries both the normal-state frame and the "minimised/maximised" flag, so a
maximised window comes back maximised rather than as an ordinary full-screen-sized window.

On the restore, not only is the window checked to be alive but so is **its process**: Windows reuses
window numbers, and without that check the snapshot would one day move a stranger's window that had
taken over a freed number. Closed windows are simply skipped, and the log shows an honest count:

```
windows: saved 8 for a 3-display layout
windows: restored 6 of 7 (1 gone)
```

The snapshot is only taken when the set of screens **really changes**: on a repeat press of the same
shortcut the windows did not move anywhere, and there is no reason to pay for walking them.

It is kept in `window-state.json`. Window numbers live only within one logon to Windows, so at
application startup entries with dead processes are swept out. The file is shared between the tray
and the command line — a snapshot taken by one serves the other.

Different scales on the monitors (96 / 144 / 96 dpi here) do not bother the snapshot: the process
declares itself per-monitor DPI aware, so the coordinates are in one system both when taking and when
restoring.

## Audio following the mode

Off as well while the dictionary is empty, and edited by hand as well:

```json
"audio": { "combo:Work": "ULTRAFINE", "solo:XG27AQDMGR": "ROG" }
```

The value is any recognisable piece of an output device's name. What there is will be shown by

    .\Set-Display.ps1 audio

No external programs are needed: the list comes from `IMMDeviceEnumerator`, and the assignment from
the undocumented `IPolicyConfig`. There is no public API in Windows at all for "make this device the
default one", and every audio switcher uses this one.

The roles assigned are **eConsole and eMultimedia**. `eCommunications` is deliberately left alone: the
device for talking is usually a headset, and there is no reason for it to travel after the monitors.

The device was not found — a `warn:` goes into the log with a list of what there is: without it, it is
unclear what to write into the settings.

## HDR survives a switch

There is no need to check it or restore it — verified 11 August 2026. All three monitors report HDR
support; HDR was turned on by hand and `all → work → all` was run through — and it stayed on at every
step. There is no code for this in the application; if the behaviour changes after a driver update,
the request type numbers and the structure layout will have to be taken from the CCD headers afresh —
they are not kept anywhere in this repository.

## The topology (as of 2026-08-11)

| Monitor | Resolution | Scale | What it is connected to |
| --- | --- | --- | --- |
| LG ULTRAGEAR | 2560×1440@144 | 100% | RTX 4080 SUPER |
| LG ULTRAFINE | 3840×2160@60 | 150% | RTX 4080 SUPER |
| ASUS ROG STRIX XG27AQDMGR | 2560×1440@240 | 100% | RTX 4080 SUPER |

The ASUS **is connected** (in the table of 4 August it was listed as absent). So `F3` (both LGs) and
`F5` (all) now mean different things, and the caveat in the section on global shortcuts no longer
applies.

The scales differ, and that matters for more than the eyes: the window-position snapshot works in
desktop pixels, so the process is declared per-monitor DPI aware — otherwise the coordinates would be
virtualised and the snapshot would lie.

The card has 3× DP 1.4a + 1× HDMI 2.1 and **no USB-C**. That is why the ULTRAFINE could not stay on a
USB-C→motherboard cable: there the video goes over DP Alt Mode from the processor's integrated
graphics, `AMD Radeon Graphics` showed up in the list, frames were copied between GPUs over PCIe and
the cursor stuttered on that screen.

If a USB-C monitor ever needs connecting to the card, what is needed is a directional
**DisplayPort → USB-C** cable ("DP source to USB-C monitor", e.g. Club3D CAC-1557). Only video goes
over it: the monitor's USB hub will drop off, and a separate USB cable into the monitor's upstream port
is needed for that.

## Monitor combos (2026-08-18)

A combo is the only way to say "these two and that one over there": `combos` in settings.json, a name
→ an arbitrary set of name patterns plus an optional `primary` of its own. That is exactly why it is a
set rather than a flagged monitor: "the ULTRAFINE plus the ASUS, with the taskbar on the ULTRAFINE"
cannot be expressed by a flag on a monitor. The mode key is `combo:<name>`, and the title is the name
as entered. One monitor can belong to any number of combos.

Choosing the primary monitor grew to six rungs in the process and was lifted out of
`Switch-DisplayMode` as the pure function `Select-PrimaryDisplay`: `-PrimaryMatch` from the command
line is hard (a typo has to be an error rather than a silent substitution), a combo's primary and the
primary out of the settings are soft (the monitor may not be on the desk, and the combo has to work
without it), and after that come the current primary, the rightmost by layout, and the first one that
comes to hand. The whole ladder is nailed down by tests; inside the switcher it was untestable.

`Get-DisplayModes` gained a second parameter — the settings — and still does NOT read the disk itself:
the tray menu calls it on every open, and a disk read here would cost exactly the delay the state
cache was created to avoid. Every caller passes the settings they already hold.

## The Settings window — WPF (2026-08-18)

The old window was bare WinForms: a white form, system frames, the look of Windows XP. WinForms has no
templates — "modern" there means drawing every button by hand in Paint handlers. In WPF rounded
corners, toggles, cards and a dark theme are
markup. So the window was rewritten from scratch: a XAML string with palette tokens, parsing through
XamlReader, and not one new dependency (PresentationFramework is part of .NET Framework 4.8, which is
installed anyway).

What is in the window: the "desk" cards (the monitors' order via arrows — that is layout; the star —
that is primary; a disconnected monitor stays as a dimmed card and is not lost on Save), the combos
with an editor (members' checkboxes, choosing the taskbar's monitor), the shortcuts with captions
describing each mode's membership, and behaviour toggles. Save validates the input BEFORE closing —
the old window used to close on a duplicate shortcut and throw every edit away.

Two lessons from the very first showing (from a preview, before a single run): a person took the flat
textual Edit/Remove on a combo for captions and could not find how to delete it — action buttons have
to look like buttons (the BtnSmall style, with a border); and people want to assign a shortcut in the
same place they create a combo rather than going to a neighbouring card for it — so a Shortcut field
appeared in the editor (the truth about the bindings is still single and lives in the main window's
fields: the editor gets the current text and hands back a new one, and a conflict with somebody else's
shortcut is caught right in the editor).

A third lesson from the same place: "the shortcuts cannot be removed". A binding could be cleared —
with Backspace — but the only thing that said so was a tiny line above the list. Now every shortcut
has a cross, an empty field with focus says "press the keys" itself, and the cards' captions explain
the difference out loud: the combos are the modes you create, while Keyboard shortcuts is a list of
ALL the modes, and a row cannot be deleted from there by construction (a mode follows from a monitor
or a combo). The phrasing "the shortcut cannot be removed" is a reliable sign that the interface did
not show the action, not that the person failed to work it out.

The WPF assemblies load lazily, on the first window open: they cost hundreds of milliseconds, and
"tray: started in N ms" is a measurement of when the shortcuts are ready, and it must not pay for a
window nobody has opened yet.

The theme is the system's, out of the registry; there is still no official Win32 API for this:

  * whether the apps theme is dark: `HKCU\...\Themes\Personalize\AppsUseLightTheme` (0 — dark; the key
    is absent on older builds — light);
  * the accent: `HKCU\...\Explorer\Accent\AccentPalette` — 32 bytes, 8 RGBA colours from light to
    dark, the base one being the fourth (index 3). For a dark theme light2 (index 1) is taken — the
    accent itself can be almost black and is unreadable on a dark background; that is exactly what
    Windows does too. The fallback path is `HKCU\...\DWM\AccentColor` (an ABGR number there), and the
    last resort is the out-of-the-box blue;
  * the text colour on the accent is worked out from its brightness: on a yellow accent white letters
    are unreadable.

A dark title bar is `DwmSetWindowAttribute(20)` (attribute 19 on builds before 20H1), after the HWND
appears, that is, in SourceInitialized. A refusal from any of the DWM calls is silently ignored — the
window simply keeps a light title bar.

A caveat about DPI: the process is declared per-monitor aware v2 (for the window snapshots' sake),
while WPF without a manifest cannot do per-monitor properly — moving the Settings window between
monitors of different scale may show slight softness. The window is static and is opened rarely; if it
ever gets in the way, look towards Switch.System.Windows.DoNotScaleForDpiChanges.

## Event handlers: .GetNewClosure() is banned (2026-08-19)

The tests caught a real breakage: a click on the cross died with "The term
'ConvertFrom-HotkeyString' is not recognized". The handler had been created with `.GetNewClosure()`,
and such a block gets a scope of its own, out of which neither `$script:` (there was already a comment
about this in the project, on Get-ActiveSettings) nor function names resolve — at least when the
closure is created in a dot-sourced file and is called by WPF through a delegate. A separate reproducer
showed that in a simple script every variant works, which means the property depends on the layout of
the scopes and cannot be relied on.

Save, Add, Edit and Remove all went the same way, that is, **every** button in the window: the tests
touched only one path, and the whole lot was broken. So there are no closures in the handlers in
SettingsDialog.ps1 at all any more. The window's state arrives through `$script:ActiveUi` (the window
is modal, there cannot be a second one; the editor uses `$script:ActiveEditor`), and a row's state
through the element's `.Tag`, while inside a block the element is available as `$this`. A flat block
keeps the file's scope, and functions with `$script:` inside it work.

At the same time the mode editor's parsing was lifted out into `Read-ModeFromUi` — as
`Read-SettingsFromUi` is for the main window: all four refusals (an empty name, a taken name, not one
monitor, somebody else's shortcut) are now checked without showing the window.

## One kind of set instead of two (2026-08-19)

For a while a named set of monitors could be described two ways: as a "group" (a name written on every
monitor) and as a combo. Three questions in a row about one and the same thing — "so is Work displays
a combo?" — and then a precise formulation from the person: *"in fact work displays IS a combo; if I
wanted to delete it, I could not"*. A verdict not on the labels but on the model itself.

A group was the same combo, only weaker:

  * a monitor had **one** group, so overlapping sets ("4K + the TV" and "4K + the gaming one") could
    not be expressed with it;
  * it had no monitor of its own for the taskbar;
  * they were created differently (writing a name into two fields versus "assemble a set"), and above
    all they were **deleted differently**: a combo by the button on its own row, and a group by
    erasing text in another card. The "Work displays" row in the shortcut list had no delete button at
    all.

The weaker one was thrown out, along with guessing a set from the manufacturer code out of EDID: which
monitors work together is a person's decision rather than a property of the hardware.

The lesson in general form: if a user asks three times how A differs from B, the answer is not to
explain harder but to stop having two concepts where one is enough.

## The tray menu (2026-08-18)

The stock ToolStrip renderers draw either Windows 7 (System) or Office 2007 with gradients
(Professional). Our own `ModernMenuRenderer` (C#, in the shared cacheable source of the native types):
a flat background matching the theme, a rounded highlight on the row, and the current mode's check mark
drawn with a pen in the accent colour — with a pen specifically rather than a Segoe MDL2 glyph: when a
font is missing GDI+ silently substitutes another one, and instead of a check mark a little square would
come out. The rows' meaning is passed through Tag: `header` — dim it, `info` — ordinary text with
Enabled=false (otherwise the information lines went grey, like disabled ones).

Rounding the corners of the menu's own window is `DwmSetWindowAttribute(33)`, which exists only in
Windows 11 and is called in Opened (before that the menu has no HWND). The monitor status dots are
16×16 bitmaps, drawn one per kind and living until the process ends: green — on and at its maximum,
amber — the refresh rate is below the maximum, grey — off, an outline — not connected.

The renderer is recreated on every menu open, so a change of Windows theme is picked up without
restarting the tray. The font is Segoe UI Variable Text with a check that the family exists (on Windows
10 it does not, and GDI+ would silently substitute Microsoft Sans Serif).

## Tested without a single run (2026-08-18)

By request — do not touch the screens — the application was never launched: the tests build the windows
WITHOUT showing them (the timer test with a real ShowDialog was deleted — once the saving moved into
`Read-SettingsFromUi` it stopped being needed, and the tests no longer flash a window), and the
appearance was checked by an off-screen render of the window's content into a PNG through
RenderTargetBitmap — both themes and the combo editor. 89 tests, 302 assertions, green. A live run —
switching, registering shortcuts, DWM attributes on real windows — is still to come.

## Why CONNECTED DISPLAYS was grey (2026-08-19)

The complaint: "Connected Displays could be made a little more readable, they are so grey." The colour
they were given was the right one — WinForms was to blame, and in two places at once.

`ToolStripRenderer.OnRenderItemText` ends with
`textColor = item.Enabled ? textColor : SystemColors.GrayText`, that is, for any DISABLED item it
throws our colour away and takes the system's dark grey. The monitor rows are disabled deliberately —
they cannot be clicked — and so the section was drawn in `#6D6D6D` on a `#2C2C2C` background:
**a contrast of 2.7:1**, half the minimum for text (WCAG AA is 4.5:1). No edit to the palette cured
this: our colour simply never reached the drawing. The only cure is drawing the text ourselves —
`TextRenderer.DrawText` instead of `base`.

The second place is `OnRenderItemImage`: for a disabled item the image goes through
`ControlPaint.DrawImageDisabled`. A pixel dump of an off-screen render showed `#828282`, `#7D7D7D`,
`#8B8B8B` in the icon strip — three identical grey smudges instead of the green, amber and grey dots.
That is, the status colour code had not worked from the start, and it was almost impossible to notice
by eye: the dots are small, and "grey on grey" looks as intended. Now the image is drawn by our own
`DrawImage`, and the dump gives `#3FB950`, `#D29922`, `#8A8A8A`.

At the same time, since the text is being drawn by hand anyway: a monitor's row goes **in two tones** —
the name at full brightness (`#F2F2F2`, 12.5:1), the mode and the notes dimmed (`#ADADAD`, 6.2:1) —
and the key combination on menu items became quieter than the mode's name, as in the Windows 11 menus
(`ToolStripMenuItem` draws it in a separate `DrawItemText` call, distinguishable by
`ShortcutKeyDisplayString`). The dimmed tone itself was strengthened in both themes: it used to be
4.3:1 (dark) and 3.3:1 (light).

Both bugs are nailed down by tests that look at the PIXELS rather than at the presence of code: we draw
with the real `ModernMenuRenderer` into a `Bitmap` through the public `DrawItemText` / `DrawItemImage`
(no window needed) and measure the brightness and the "greenness". A mutation check was done: remove
`OnRenderItemImage` and the test turns red with `saw 0`; hand the text to `base` and it turns red with
`saw 109`, exactly the brightness of the system `GrayText` that started all of this.

The lesson: if a colour "was not applied" in somebody else's framework, do not fiddle with the palette
— check whether the base implementation overrides it for that state. And measure pixels: both bugs were
invisible in the code and obvious in the dump.

## Brightness over DDC/CI (2026-08-21)

An external monitor's brightness lives in its firmware rather than in Windows. The WMI class
`WmiMonitorBrightnessMethods` only answers on laptops' built-in screens — on this machine it does not
exist at all. There is one real path: DDC/CI, the service channel
inside an HDMI/DisplayPort cable, the same one the buttons on the bezel work over. Through
`dxva2.dll`: `GetPhysicalMonitorsFromHMONITOR` from an `HMONITOR`, then `GetMonitorBrightness` /
`SetMonitorBrightness` and the same pair for contrast.

Three things that had to be learned in practice.

**It can only be tied to our own state by the output name.** The description
`GetPhysicalMonitorsFromHMONITOR` hands back is "Generic PnP Monitor" on all three monitors at once.
The useful name (`\.\DISPLAY1`) sits in `MONITORINFOEX.szDevice` and matches the `Output` field of our
state.

**The bus is unreliable by nature.** The very first query of the UltraGear went perfectly: brightness
100 out of 0..100, contrast 70, and even switching the input (VCP `0x60`) answered with the values
`0x0F/0x10/0x11/0x12`. Half an hour later the same call to the same monitor started returning
`0xC0262589` — `ERROR_GRAPHICS_DDCCI_INVALID_MESSAGE_COMMAND`, "the monitor answered with the wrong
thing". Six attempts in a row with pauses — the same refusal. A check with the original probe (code
that had worked before) gave the same error, so it was not the code. The only thing standing between
"it worked" and "it did not" was a capabilities-string request
(`CapabilitiesRequestAndCapabilitiesReply`): that is a long conversation over I2C, and some monitors
stop answering after one until a link cycle. The conclusion: in the working code we never ask for the
capabilities string, and every call is repeated three times with a 60 ms pause — one failure on this
bus is normal, not an answer.

**A sleeping monitor does not answer.** So the levels are set at the very end of a switch and only on
the monitors that are on in that mode. And that is why `.\Set-Display.ps1 brightness` shows only the
ones that are on — lying about "not supported" for a sleeping one is not allowed.

The cost: one DDC question is tens of milliseconds, sometimes over a hundred. So the `brightness` and
`contrast` dictionaries are empty by default, and with them empty not one request goes out.

## The diary (2026-08-21)

A sample is three system calls: `GetForegroundWindow`, `MonitorFromWindow` + `GetMonitorInfoW` (for the
output name) and `QueryFullProcessImageNameW` (for the process name). Plus `GetLastInputInfo` — how
long the person has not touched the keyboard.

Window titles are deliberately not read: they hold the document's name, the page address and the
subject of an email, whereas the process name is enough for "how much time in what". What is not in the
file cannot leak out of it.

The file accumulates SUMS per day rather than events. `{"chrome": 3600}` instead of a stream of "at
14:03:10 it was chrome": the file stays in kilobytes forever, and it cannot be used to reconstruct what
somebody was doing on Thursday at three in the afternoon. A live check: four samples gave 236 bytes for
the day.

Two subtleties with the time. First: the length of a stretch is taken by the clock (the difference from
the previous sample) rather than by the timer's step — the tray timer can be late if the system is busy
or the computer slept. But the gap cannot be trusted whole either, so it is capped at three steps: a
minute of sleep must not be credited to an application that happened to be on screen. Second: the first
sample after a break is exactly one timer step. There used to be 30 seconds "by default" here, and
every return to the computer gifted the application half a minute that never happened.

`GetLastInputInfo` and `GetTickCount` are 32-bit and wrap round after 49 days. The subtraction is done
in unsigned arithmetic and survives the wrap; a cast to `int` before the subtraction does not.

## Rules: "when this happens, become that" (2026-08-21)

Its predecessor was an automatic game mode that could do exactly one rule: one process, one mode, one
return. A second condition ("nobody has worked at the computer for twenty minutes") it could not
express, let alone a second process. Now this is `rules`, a list, and a condition is not only "a process
is running".

All the logic is in `Get-RuleDecision`, a pure function over facts, and it is under tests. The reason is
simple: the watching lives in a timer that ticks every fifteen seconds for weeks, and debugging it from
the log instead of from tests is exactly the way the desk has already been broken in this project. Three
refusals that matter more than the switches themselves: do not take the desk if we are already in the
mode we want (there would be nothing to give back afterwards); do not leave if there is nowhere to go
back to (the current set matched no mode and `back` is not set); and let the desk go if it was switched
by hand.

## The world changes by itself: sleep and reconnection (2026-08-21)

`restoreLastMode` covered only the tray's startup. Three cases were left: waking from sleep, a monitor
going away, a monitor appearing.

It is the **connected** monitors that get compared, not the ones that are on. The ones that are on we
change ourselves on every switch, and reacting to those is an endless circle: the
`DisplaySettingsChanged` event arrives on our own work too.

"A monitor appeared" does nothing by default. Putting out a monitor a person has just switched on with
the button is a fight with a person; the mode for this case is named explicitly (`reapply.onPlug`).

The wake event (`SystemEvents.PowerModeChanged`) arrives NOT on the application's thread, so a WinForms
timer must not be started from there. A timestamp is set, and the existing 15-second timer picks it up:
a reaction within fifteen seconds, but without somebody else's thread. Five seconds of delay — because
right after waking the monitors are still coming up, and a state query answers about a half-assembled
desk.

## The desk preview (2026-08-21)

The cards in the Settings window said what order the monitors stand in, but they did not show what comes
out of that: screens of different heights (1440 and 2160) line up centred, and strips are left at the
edges that the cursor will not cross. That only came to light after Save, on the live desk.

The picture is worked out by `Get-LayoutPositions` — the very function the switcher works with, with the
same coordinates. Not "a similar picture" but exactly what will be applied: if the picture lies, then
the switch lies too, and it is one and the same bug that is on show.

## The speed limit is set by the panel, not by Windows (2026-08-25)

Measurements of nine switches on the single transition. The numbers come from the `done:` line, which is
what it is written for.

| Switch | Total | apply + settle | layout | modes |
| --- | --- | --- | --- | --- |
| → all three (ASUS asleep) | 5.1 s | 0.7 | 1.0 | 3.3 |
| → all three (ASUS asleep) | 5.2 s | 0.6 | 0.9 | 3.6 |
| → all three (ASUS asleep) | 5.1 s | 0.7 | — | 4.2 |
| → both LGs, modes already correct | 0.4 s | 0.2 | — | — |
| → one monitor, modes already correct | 0.4 s | 0.2 | — | — |
| → one LG being woken | 1.2–1.6 s | 0.4 | — | 0.8–1.1 |

**Windows answers in half a second.** Accepting the whole topology (`apply`) takes 0.2–0.7 s, and
confirming that the screens are on the desk (`settle`) 0.1 s. That is not the bottleneck and never was.

**Only waking the ASUS out of standby is expensive: 3.3–4.2 s.** It reports "active" almost at once and
then spends seconds renegotiating the link, and while it is doing that the driver answers any question
slowly. Proof by contradiction — the same calls without it cost 0.4 s.

**Separately, about the temptation to optimise the layout check.** In the first two measurements the
`layout` phase cost ~1 s and ended with a verdict of "already correct" — which looked like a pure loss,
all the more so because in that case `Invoke-CcdLayoutAttempt` returns before a single
`SetDisplayConfig` and only reads. We checked with instrumentation, splitting the reading into a
configuration snapshot and a request for the monitors' names — and the **hypothesis was refuted**: in
the third measurement `layout` fitted into hundredths, while `modes` grew from 3.3 to 4.2. The total did
not change.

The second did not disappear, it moved: this is one physical wait, and the phases merely slice it up
differently — whoever asks the driver first pays. The sum `layout + modes` holds (4.3 / 4.5 / 4.2) with
a constant total (5.1 / 5.2 / 5.1).

Hence a conclusion worth remembering: **removing the layout check is pointless** — the wait will surface
in another phase. And it would cost dearly: in the case of the single transition that check is the only
confirmation that the desk is arranged correctly, and "success" by return code has already turned out to
be false twice in this project. The instrumentation was removed after the measurement: the `layout`
phase in `done:` serves as the radar.

## Smart App Control and the assembly cache (2026-08-24)

The Windows API types are compiled once and put next to the scripts in `native-<hash>.dll`: startup
costs ~50 ms instead of ~250 ms. On a machine with **Smart App Control** on, this cache sometimes does
not work — the assembly is not signed by a trusted publisher, and the code integrity policy will not let
it through:

```
core: dll cache failed - ... An Application Control policy has blocked this file.
      (Exception from HRESULT: 0x800711C7)
```

Events 3033 and 3077 appear in `Microsoft-Windows-CodeIntegrity/Operational` at the same time, and SAC
itself is visible in the registry: `HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy`,
`VerifiedAndReputablePolicyState = 1`.

**The refusal is not permanent, and that is the main thing.** One and the same file — with the same
content and the same name, because the hash is computed from the source — was blocked on four runs in a
row, and having been deleted and rebuilt it loaded in 50 ms without a single event. Which means the
decision is made by the file's reputation, not by its content alone.

Hence the behaviour of `Initialize-NativeTypes`, and it is right under either of the two hypotheses (a
one-off refusal or a permanent one):

- the rejected file is **deleted**. Keeping it is not allowed: it guarantees the same refusal on the
  next start and two more entries in the CodeIntegrity log;
- the cache is **not switched off forever** in the process. The next start will rebuild the assembly and
  get a fresh chance; in the worst case that is a compilation into memory, that is, +150 ms, and only on
  the run where the refusal happened;
- the refusal is recognised by `HResult = 0x800711C7` (`Test-BlockedByPolicy`), **not by the text**: the
  message arrives in the system's language, and a check by words would silently stop working on a
  Russian Windows. The refusal cannot be produced live on demand, so the recogniser is pinned down by
  tests, including the case of a nested exception.

Turning Smart App Control off for these milliseconds is not worth it — and remember that it cannot be
turned back on without reinstalling Windows.

## The shutdown timer (2026-08-21)

The countdown lives only in the tray's memory and dies with it. Writing it to disk is not allowed: a
computer that turns itself off a day after being asked to is scarier than any usefulness.

The one-minute warning is a required part, not a convenience: between "set a timer and forgot" and "lost
unsaved work" stands exactly that.

Sleep is the only state with no console command for it: `shutdown.exe` can do a shutdown (`/s`), a
reboot (`/r`) and a hibernation (`/h`), and "sleep" is not in it. It goes through
`SetSuspendState(false, true, false)` from `powrprof.dll`, where the first parameter being `false` is
what means "sleep, not hibernate".

### Your own time: a window instead of an input line (2026-08-25)

The presets (15, 30, an hour, two) covered the popular cases, and everything else was asked for with a
one-line `InputBox` from `Microsoft.VisualBasic`. It knows neither the theme nor what time this will
happen at, and it demands that the answer be typed blind — "45" is easy to type, but it does not answer
"and what time will that be?".

Now **Pick a time…** opens a window of its own (`New-TimerWindow` / `Show-TimerDialog` in
`SettingsDialog.ps1`): a slider, pills, the wheel and arrows in five-minute steps, with the input field
still there. The `Microsoft.VisualBasic` assembly left `Displays.ps1` along with `InputBox`.

Three decisions worth remembering:

- **The slider's steps are uneven** (`Get-TimerSteps`): five minutes at a time near the bottom, an hour
  at a time further out. An even step makes the small end unmanageable and the large end endless. The
  slider travels by STEP NUMBER rather than by minutes.
- **The field and the slider read each other through the same functions**: the slider writes with
  `Format-DurationShort`, the field parses with `ConvertFrom-DurationText`. What is shown is what reads
  back — pinned down by a test across every step. A separate `Syncing` flag keeps them from moving each
  other around in circles.
- **The clock time is visible everywhere**: in the window, and next to every preset in the menu
  (`Get-TimerTargetText`). "In 340 min" says nothing, "at 06:20 tomorrow" says everything.

The placement by the cursor and the closing on focus loss are attached in `Show-TimerDialog` rather than
in `New-TimerWindow`: the same window is used by the tests and by `render-preview.ps1`, and they do not
need a window that moves itself to the cursor and closes on a stray click.

`Get-PopupPlacement` is a pure function, and the very first test for it caught a real bug: locals `$x`/`$y`
next to the parameters `$X`/`$Y`. PowerShell variables have no case — it was one and the same pair.

A timer that is set can now be moved (`Add-PowerTime`): "another fifteen minutes" is what people come
back to it for more often than to cancel it. Taking time off does not let the deadline come closer than a
minute: the one-minute warning is part of the bargain.

## Brightness sliders in the Settings window (2026-08-21)

Brightness was only editable by hand in `settings.json`, and it was the one new setting with no element
of its own. Now the window has a **Brightness** card: choosing the mode, choosing the form of entry, and
sliders.

The main decision here is that **the window does not turn one form of entry into the other on its own**.
In the file the brightness sits either as a number ("the same for every monitor in the mode", which is
how it is usually written) or as a dictionary ("one each"). The temptation was to expand the number into
a dictionary on opening and always write a dictionary — that makes the code simpler. It is not allowed
for two reasons: the expansion goes over the monitors that are connected NOW, so the brightness of one
that was pulled out would be lost silently; and the entry `"all": 80` means "everybody there is",
including a monitor that turns up tomorrow, while a dictionary no longer means that. So the form is an
item in the "Then…" list, that is, a person's decision, and the move from "one number" to "one each"
fills the sliders with that very number the person was looking at.

Two more small things from the same family. An unticked checkbox on a monitor means "we do not touch the
brightness" rather than "zero" — which is why the row says `off` and not `0`, and on Save such a monitor
simply disappears from the dictionary; when they all disappear, the mode's key is not written at all
rather than left as an empty dictionary. And modes that have a brightness set while the mode itself is not
here right now (the monitor was taken away) still reach the list: otherwise the setting can neither be
seen nor cleared — shortcut bindings to missing monitors live by the same rule.

Querying the monitors is done with an "Ask the monitors" button rather than on opening the window: one DDC
question costs tens of milliseconds per monitor, and on a stuck bus up to a second with the retries, and
there is no reason to pay that for every opening of the settings.

A slider template of our own had to be written: the system `Slider` knows neither a dark theme nor an
accent and stayed light in a dark window. The filled part is the track's `DecreaseRepeatButton`, WPF's
standard way of showing what has been covered.

And a lesson about tests. The "one each" rows were built by code that called
`[System.Windows.GridLength]::Parse` — a method that does not exist. Every test was green: they edited the
model and read it back, and nobody built the rows in the process. What caught it was a snapshot of the
window (`render-preview.ps1`), after which two tests appeared that do build the rows and look at the
checkbox, the slider and the caption. Testing the model is not enough — what a person will see has to be
assembled at least once.

## Everything about a mode in one window (2026-08-21)

A mode's settings were smeared across three cards: the membership in "Combinations", the shortcut in
"Keyboard shortcuts", and the brightness in "Brightness" with a dropdown of its
own listing the modes. Three places, three ways to get to one and the same mode, and every question of
"so where do I turn X on for Work?" had its own answer. Now there is one card: **Modes**, a row per mode,
an **Edit** button and one window behind it.

What is in that window: for a combo — the name, the monitors' checkboxes, the taskbar, the shortcut, the
brightness; for a monitor mode and for "all" — the shortcut and the brightness, with the rest hidden
(`ComboPart` collapses), because their membership is set by the desk rather than by a person. Only what a
person created themselves can be deleted — **Remove** is on a combo and on an orphan row, and a monitor
mode does not have it by construction.

The shortcut in the list became a caption instead of an input field. A field was faster by one edit, but
it was exactly what kept the settings apart: if the shortcut is edited in the list then so should
everything else be, and "everything else" does not fit in a row. The other side is honest: to change a
shortcut you now have to open Edit.

Three things that had to be decided along the way.

**The truth about the bindings moved from the elements into the data.** There used to be `$Ui.Boxes` — a
"mode key → TextBox" dictionary — and the list was rebuilt on every edit, carrying what had been typed
into a stash. It became `$Ui.Hotkeys`, a dictionary of strings, with the list only showing it. The stash
disappeared along with the fields, but a new question appeared: the order. It used to come out by itself
because the fields were built in the modes' order; now `Get-MapInModeOrder` sets it, otherwise
`settings.json` would get reshuffled by the order in which a person happened to open the editors, and
editing one shortcut would rewrite half the file.

**The editor edits a copy of the brightness model** (`Copy-LevelModel`). The model is an object, and a
slider in the editor would change it in place: "moved it about and changed my mind" would already have
changed the setting, and Cancel would be lying. Rolling the sliders back would be harder and still untrue.

**Orphans now come from brightness too.** A "the setting is there, the mode is not" row used to be created
only by a shortcut; such a mode's brightness was visible in the card's dropdown. The dropdown is gone — so
the brightness reaches the orphan rows too, or the setting can neither be seen nor cleared. An empty
brightness model does not hold a row: it is created by a single visit to the editor and means nothing.

Two traps caught by something other than the eye.

`Get-LevelRowNames` began with `param($Names, $Map)` and `$names = @()` — and that is one and the same
variable: names in PowerShell are case-insensitive, the accumulator wiped the parameter out, and the
function returned only the "orphans" out of the map. A test for the row of a monitor with no brightness set
failed immediately. The parameter was renamed to `$Displays` for exactly this reason.

`render-preview.ps1` was capturing precisely half the editor: it looked for the scrolling by walking the
element tree, and there is no tree before `Show()`. Now the `ScrollViewer` is found by the name from the
markup, and the image is taken whole. The script also gained `-EditorMode` along the way: any mode's editor
can be rendered, not just the first combo's.

## The orchestrator is tested by shadowing functions (2026-08-26)

All 254 checks that existed before this day were of pure functions. `Switch-DisplayMode` — 290 lines, the
most complicated and the most fragile part of the project — was not covered at all: to test it you had to
switch real monitors and look with your eyes.

The first thought was wrong: "create a seam". Pass an object with methods into the switch, or a table of
functions, or a "we are in a test" flag. Any of those would have meant **an extra call on the very path
where milliseconds were measured**, and a layer of indirection in code that is hard enough to read as it
is. The price of tests must not fall on the product.

It turned out there is nothing to pay at all. I checked the body of `Switch-DisplayMode` line by line:
**not one direct reference to `[NativeCcd]::`**. It reaches hardware exactly through named functions —
`Get-DisplayState`, `Set-CcdFullConfig`, `Set-CcdTopology`, `Set-CcdLayout`, `Wait-ForTopology`,
`Set-BestModeFor`, `Get-CurrentMode` — and disk through `Save-LastMode`, `Save-AppliedModes`,
`Save-WindowLayout` and `Invoke-ModeHook`. That did not come about on purpose: each of those functions was
created because it was being debugged separately.

And PowerShell looks functions up **along the chain of call scopes** rather than by the scope of
declaration. Which means:

    Test-Case 'anything' {
        function Set-CcdFullConfig { param($Targets, $PrimaryPath, $Order) ... }
        Switch-DisplayMode -ModeKey 'all' -Quiet    # will call THIS one
    }

A declaration inside a block overrides the real function for everything that block calls, and **dies with
the block**. There is nothing to restore, the isolation between cases is free, and the production code does
not change by a single line.

The fakes put their calls into a list, and a test checks **what was called and in what order** rather than
only how it all ended. That turned out to be the main thing: a `done: ok` at the end does not tell "the
desk was assembled in one transition" from "assembled in three", whereas the list of calls does.

Eighteen fakes covering every case sit in a single script block, and every case starts with
`. $script:SwFakes`. Dot-sourcing a **script block** executes it in the scope of whoever called it — that
is, inside the `Test-Case` block. Declare them as an ordinary function and the functions would be created
in its scope and die with it, never living to see the switch called.

### What was found along the way

Half the cases were testing something other than what their names said the first time round, and that too
is a property of the method: a fake that lies about the hardware lies convincingly.

- **A fictional monitor with no `BestMode`** brings the whole set of targets down: `Get-SwitchTargets`
  finds no sizes, hands back an empty array, and the one-call transition is not even attempted.
  The test "exactly one `Set-CcdFullConfig`" would have passed, because there were zero calls.
- **A `Get-CcdOutput` that hands back nothing** is a monitor that did not attach. `Set-WantedModes`
  honestly wrote "did not attach" into the log and put it into `Failed`, the verdict became "not ok", and
  three cases failed for an entirely correct reason.
- **The cache of verified modes has to be shadowed.** The file in the temporary folder is left behind by
  other groups of cases, and without shadowing it the set of targets would depend on the order of the run.

And one thing that had not been said anywhere before: **with `-KeepMode` there is no "leave it as it is"
for a sleeping monitor**. It has no current mode, `BestMode` is not taken under `-KeepMode`, and the set
goes to the old road of three steps whole. That is not a breakage but the only honest answer — mixing
specified sizes with unspecified ones in one request means guessing what the system will do with the
remainder. There is now a case named after exactly this.

### A mutex belongs to a thread, not to an object

The case "a second quick press goes down the skip branch" I first wrote like this: take
`Local\ScreenDeckSwitch` right in the test and call the switch. It is green — and it tests nothing. A
Win32 mutex is **reentrant for its own thread**: `WaitOne(0)` from the same thread goes straight through,
and the switch calmly takes it a second time and works as usual. I worked it out from `$r.Message` turning
out to be the summary of a successful switch instead of "A switch is already in progress.".

A separate thread holds it now — `[powershell]::Create()` — and the synchronisation is on named events
with a bounded wait: the test has no right to hang, whatever the outcome of the grab. The "I have it"
signal is only sent on a successful grab: if a live tray has taken the mutex, the wait will expire and the
failure will be readable.

That is also the main pitfall of the whole group, written down in `AGENTS.md`: if the tray is switching the
desk at the moment of the run, these cases will go to "skip". The probability is low, but on an
inexplicable red it is the first thing to check.

### How it was verified that the tests reach the orchestrator at all

A test that tests itself is the worst possible thing, and taking anyone's word for it here is not on. So
`sameTopology` in `DisplayCore.ps1` was temporarily replaced with `$false`, and the run was supposed to
turn red in exactly one place. And so it did: the case "the set is already correct — the topology is not
rebuilt" failed, and printed the whole difference —

    expected [hook:before,layout,lastMode,applied,hook:after]
    got      [hook:before,windows:save,full:...,settle,layout,best:...,lastMode,applied,windows:restore,hook:after]

that is, the test really does go through the orchestrator and see every one of its steps. After which the
file was restored byte for byte.

## The first live run, and what it cost (2026-08-26)

`tests/live.ps1` has been written and run against the real desk. Six modes, and after each one the
membership, the primary monitor, the layout's X/Y and the refresh rates, then the restore. Green all
through on the second attempt; on the first it found what runs like this exist for.

**The refresh-rate watchdog takes the same mutex as a switch.** `Restore-BestModes` starts with
`Local\ScreenDeckSwitch` and holds it while it gathers state: a full `Get-DisplayState`, `Get-CurrentMode`
for every monitor and **two** visits to `Test-FullscreenApp` — by its own comment in the code, about a
second. And what starts it is `DisplaySettingsChanged`, that is, **our own** switch. The busy window opens
right after every successful step.

A script that fires modes off with no pause lands in that window every time. And so it did:

    12:55:37  done: LG ULTRAGEAR 2560x1440 @ 144 Hz (0.5 s: ...)
    12:55:38  skip: mode=solo:LG ULTRAFINE - the previous switch has not finished yet
    12:55:38  skip: mode=solo:XG27AQDMGR   - the previous switch has not finished yet
    12:55:38  skip: mode=combo:Work        - the previous switch has not finished yet
    12:55:38  skip: mode=combo:work+game   - the previous switch has not finished yet
    12:55:38  skip: mode=all               - the previous switch has not finished yet
    12:55:38  skip: mode=combo:Work        - the previous switch has not finished yet

The first step went through, and all the rest — the restore included — got a skip, and the desk was left in
pieces. The diagnosis read out of the log in a minute precisely because **there is not one foreign
`--- start` between those lines**: which means what was holding it was not a second switcher but something
that takes the mutex without being a switch. There is exactly one such place in the code.

The right answer is **not to shut the tray down**. A running tray is the machine's normal state, and that
is what has to be tested; a person who presses a shortcut in the same second simply presses again. So
`Invoke-LiveSwitch` retries up to five times with a 1.5 s pause and prints how many were needed. On the run
two were needed — three times out of six.

**Skipped has to be checked separately from a failure.** The first version did
`[void](Switch-DisplayMode ...)` and went on to compare the membership against a desk nobody had changed.
The switching code would have looked red while the order of calls in the test was to blame — the worst kind
of false evidence.

### Along the way: `DISPLAY1/2/3` moved during the run itself

Before the run `combo:Work` lived on `\.\DISPLAY1` (ULTRAGEAR) and `\.\DISPLAY2` (ULTRAFINE). Afterwards
the same set and the same primary, but `DISPLAY2` (ULTRAFINE) and `DISPLAY3` (ULTRAGEAR): the third monitor
was woken and put out again, and Windows reassigned the names. A live demonstration of the rule written
down both in `AGENTS.md` and above in these notes: **an output name is not a monitor's identity**; the
identity is the device path.

### The speed did not change

Real switches have to be compared with real ones: the median over all the `done:` lines is deceptive,
because 155 of the log's 178 lines are repeat presses ("the topology is already correct", fractions of a
second). By the presence of an `apply` phase:

| Monitors on | Before (median / worst) | This run |
| --- | --- | --- |
| 1 | 1.2 / 1.6 | 0.5, 0.8, 1.2, 2.2 |
| 2 | 0.7 / 2.2 | 1.1, 1.9, 3.1, 3.4 |
| 3 | 5.2 | 5.4 |

The most expensive and most telling case — three monitors — has not changed: 5.2 against 5.4. The
two-monitor figures are higher, but there are only five historical ones, while these ran back to back, each
straight after the previous one and alongside the watchdog. The breakdown shows where the seconds are:
`modes` and `apply`, that is, waiting on the hardware. And it is verifiable: over that whole day
`DisplayCore.ps1` changed by exactly the version block at the top of the file — not a line on the switch
path.

## The watchdog saw a full screen where there was none (2026-08-26)

Yegor noticed it on the live desk: every monitor was off, he switched one on with the button — for a second
the ASUS and the ULTRAFINE lit up, then the ASUS went out and the ULTRAGEAR came on. Verified against the
log: **that was not us**. Only `Switch-DisplayMode` changes the topology, and it writes `--- start` before
any work; over the whole window after the event there is not one such line. And on a monitor *appearing* we
deliberately keep quiet — `reapply.onPlug` is empty, and the code next to it says why. So the flicker was
Windows restoring its own remembered layout while the screens came back one by one.

There is a weakness here, but a different one: **the desk's final state was decided by Windows rather than
by us, and it coincided with `combo:Work` by its memory rather than by our decision.** Had they diverged,
nothing would have corrected it. There is no solution yet; the option "on a monitor appearing, do not change
the set but reapply the layout, the primary and the refresh rates" looks right, but it needs a branch of its
own in `Get-ReapplyDecision` and cases of its own.

And in the same log a second, independent thing turned up:

    14:04:12  watch: postponed - a full-screen app is running, it sets the mode itself

There was no game. No game, no video — Yegor confirmed it. And this is not a one-off oddity: over the log's
history there are **a hundred and fifty** such entries, and three of them are from this one day, including
two during the live run, when I was sitting right there and knew for certain there was no full screen.

### Why the check lies

`Test-FullscreenApp` asks twice. Branch A is `SHQueryUserNotificationState`, the shell's own answer; at rest
it answers honestly, `QUNS_ACCEPTS_NOTIFICATIONS`. Branch B is "does the active window cover its monitor
entirely", and that one hangs by a thread. A measurement over every open window:

| Window | Class | Margin before it fires |
| --- | --- | --- |
| `TextInputHost` | `Windows.UI.Core.CoreWindow` | **0 px — it passes already** |
| `NVIDIA Overlay` | `CEF-OSC-WIDGET` | 1 px |
| `chrome` | `Chrome_WidgetWin_1` | 40 px |
| `msedgewebview2` | `Chrome_WidgetWin_1` | 48 px |
| `claude` | `Chrome_WidgetWin_1` | 64 px |

`TextInputHost` is the system input window (the touch keyboard, emoji, IME candidates), exactly the size of
the monitor: `0,0..2560,1440` against `0,0..2560,1440`. Let it become active at the moment of the check and
the watchdog will decide a game is running.

The comment in the code explained the safeguard like this: "a maximised window covers the work area but not
the taskbar". That is true, but it rests on the taskbar and **on nothing else**: an ordinary maximised
window's frame goes 8 px past the monitor, that is, three conditions out of four are always met, and the only
thing that saves us is the bottom running into the taskbar. On Yegor's desk the taskbar is shown on every
monitor, so it saves us everywhere for now — but the margin, as the table shows, is a matter of pixels.

### What that costs

The tray's timer rechecks every 15 s and clears the flag itself, so a one-off firing is a delay in restoring
the refresh rate rather than a loss. What is dangerous is the **persistent** case: let such a window stay
active and the watchdog is silently switched off, and on this machine the refresh rate does not hold in the
registry — 240 Hz simply will not come back, and there will be no error about it.

### It found itself, in this very file

The rule "a window that is not on the desk does not exist" was **already** in the project — and with a
comment about exactly this phenomenon, in `NativeWindows.Enumerate()`, where window positions are taken:

> DWM "hides" Store apps' windows without closing them: they stay visible by
> `IsWindowVisible`, but they are not on the desk.

The window walk filters out the invisible, the child, the tool-window, the nameless and the **cloaked**
ones. `Test-FullscreenApp` did not know about it — it was known in one place out of two. The measurement
over every open window confirmed it: for `TextInputHost`, `IsWindowVisible` = **yes**,
`DwmGetWindowAttribute` (`DWMWA_CLOAKED`) = **yes**. That is, precisely the flag already in use next door.

So the fix is not a new heuristic but moving our own rule to where it had been forgotten: before the
geometry we ask `Get-GhostWindowReason`, and an invisible window, one cloaked by DWM, a minimised one or a
tool window never reaches the rectangle comparison. The geometry is untouched.

What that catches on this desk:

| Window | Covers the monitor | Now rejected as |
| --- | --- | --- |
| `TextInputHost` | yes | cloaked by DWM |
| `NVIDIA Overlay` | no, 1 px short of it | tool window |
| `SystemSettings`, `ApplicationFrameHost` | no | cloaked by DWM |
| `ChatGPT`, `steamwebhelper` | no | minimised |

An empty title was **not** taken as a tell, even though the window walk accounts for it: a borderless game
may well have no title, and filtering it out would be worse than a false positive.

The decision is lifted out into the pure `Get-GhostWindowReason` and covered by cases. There is no other way
to test it: in `Test-FullscreenApp` itself every input comes from Windows, and `[NativeForeground]` is a type
rather than a function, so there is nothing to shadow it with in a test. Verified rather than taken on trust:
with the `Cloaked` check removed, exactly the case about it fails.

### Verified on the real desk

The tray was restarted (the old `native-*.dll` deleted itself in the process — which means the new C# was
loaded), and `tests\live.ps1` was run once more: the same six modes and the restore, seven rebuilds of the
desk.

| | before the fix | after |
| --- | --- | --- |
| false `watch: postponed` per run | **2** | **0** |
| `TextInputHost` covers the monitor entirely | yes | yes |
| the same one is cloaked by DWM | yes | yes |

The second half of the table is what matters: the condition the check lied on has not gone anywhere — what
went was the firing. Otherwise "it went quiet" would mean nothing.

And the watchdog did not switch off in the process but started working: the run again showed the line "took 2
attempts — the tray watchdog held the mutex", that is, `Restore-BestModes` still runs and gathers state. The
only difference is that it no longer gives up on the first step.

### And the log line has been taught to name itself anyway

One defect was fixed, and measured. Whether `postponed` keeps appearing where there is no full screen the log
will show, so the reason is now written into the line:

    watch: postponed - full screen: the shell says 2 (QUNS_BUSY)
    watch: postponed - full screen: Chrome_WidgetWin_1 covers its monitor: window ..., monitor ...

For the shell's answer, the value and its name ("2" in a bug report says nothing, `QUNS_BUSY` says
everything); for the geometric branch, the window class and both rectangles. The `watch: postponed` prefix is
kept deliberately: the whole past history of the log is grepped by it.

Editing the C# changes the source's SHA, so a new `native-*.dll` was built, and the previous one will go on
the next run — the tray keeps it open, and that is exactly the behaviour described above.

## We assemble the desk after a monitor is switched on, not Windows (2026-08-26)

The open question from the entry above is closed. It ran like this: when the monitors come back, Windows
brings up **its own** remembered layout, and it is the one that decides the desk's final state. On Yegor's
desk it coincided with `combo:Work` — but by its memory rather than by our decision. Had they diverged,
nothing would have corrected it.

The setting for this already existed: `reapply.onPlug` — the key of the mode to go to when a monitor has
appeared. Empty by default, and the README says honestly why:

> switching off the monitor somebody just switched on by hand is a war with a human

That is not an excuse but a real price. Yegor has `Ctrl+Alt+F4` bound to `solo:XG27AQDMGR`, that is, he
switches the ASUS on deliberately; with `onPlug: "combo:Work"` an ASUS switched on with the button would go
out a second later, because `combo:Work` does not have it. The same war, only now by configuration.

### What changed

The named mode is applied **only if the monitor that appeared belongs to it**. In which case:

- everything was off and the ULTRAGEAR or the ULTRAFINE was switched on → they are in `combo:Work` → we
  assemble the desk;
- the ASUS was switched on with the button → `combo:Work` does not have it → we leave the desk alone, no war;
- `onPlug: "all"` → the members are everything connected, so the check changes nothing and the desk is
  always assembled.

Verified on the real desk and the real settings, with the same code `Invoke-PlugCheck` works the membership
out with:

    onPlug = 'combo:Work', its monitors: LG ULTRAFINE, LG ULTRAGEAR
      LG ULTRAGEAR appears (a member of Work)  -> assemble 'combo:Work'
      LG ULTRAFINE appears (a member of Work)  -> assemble 'combo:Work'
      XG27AQDMGR appears (NOT in Work)         -> leave the desk alone

### Where this lives, and why exactly there

`Get-ReapplyDecision` stays **pure**: it does not know the state of the desk and must not. The mode's
membership is worked out by the caller — `Invoke-PlugCheck`, which holds both the state cache and the
settings — and passed as the `PlugModeMembers` parameter.

The difference between `$null` and an empty list is a semantic one here, and there is a case for each:

- `$null` — "the membership was not stated", and the mode is applied as before. Otherwise the very first
  caller that does not work the membership out would quietly switch the setting off altogether;
- `@()` — "we were told: nobody", and then there is nothing to assemble.

Verified by shadowing: with the membership check removed, exactly two cases fail — the one about the ASUS and
the one about an empty membership.

## The desk ran away from the person, and there was nothing to come back with (2026-08-28)

Two days later the setting from the previous entry turned into exactly what it had been guarding against —
only from the other side.

The complaint: "the monitor was on, it switched itself off for some reason, and both work ones came on."
Twice in one day.

### What the log showed

    21:01:52  startup: restoring 'Only XG27AQDMGR'   — the desk was assembled, the ASUS alone
    21:06:43  reapply: 'Only XG27AQDMGR' is not available right now
    21:06:43  reapply: 'Only XG27AQDMGR' is not available right now
    21:06:45  reapply: a display was plugged in -> 'Work'
    21:06:46  ccd: full config applied - 2 display(s) on
    21:07:33  --- start mode=solo:XG27AQDMGR
    21:07:33  ERROR: That display is not connected right now.

The first line is already a reaction: the ASUS left the bus by itself before it. The application cannot put a
monitor out at all — DDC/CI is only touched for brightness and contrast, and this person's brightness
dictionaries are empty, so `Set-MonitorLevels` returns before reaching the bus. The refresh-rate watchdog last
changed a mode on 11 August.

And then ours fired. While the person sat on the ASUS, both LGs were asleep, and a sleeping DisplayPort
monitor drops HPD — to Windows it is **not connected**. When the ASUS's link died, Windows lit what was left,
the LGs came back into the connected list, and that arrived as a separate event two seconds later. `onPlug`
saw "a monitor appeared", the membership check let it through honestly — the ULTRAGEAR does belong to
`combo:Work` — and the desk went off to a mode with no ASUS in it.

The membership check from the entry above does not save us from this and could not: the question is not whose
monitor appeared but **who switched it on**.

### The real price: an overwritten choice

The second half was worse. `Switch-DisplayMode` called `Save-LastMode` on every switch that made it through,
with a comment saying "the person asked for this mode specifically". On an automatic reapply no person asked
for anything — the application asked itself. What was left on disk was:

    {"key":"combo:Work","when":"2026-08-28T21:06:46"}

`21:06:46` is not a choice, it is onPlug. The choice was `solo:XG27AQDMGR` at 21:01:52. From that second on,
`onUnplug` assembled Work on any disappearance, `restoreLastMode` would have brought Work up after a reboot,
and every waking of the neighbouring screen affirmed the trap all over again. There was nothing to get out
with.

### Three fixes

1. **An automatic switch does not overwrite the choice.** `Switch-DisplayMode` gained `-Automatic`;
   `Invoke-Mode` passes it along with its own `-Auto`, which means every automatic path (rules, startup,
   reapply) is closed off by one line and there is no need to list them one by one. `Save-AppliedModes`
   stays: that is a fact about the monitors rather than a person's choice.
2. **A quarantine on `onPlug`.** An appearance within ten seconds of **somebody else's** disappearance counts
   as an echo. A monitor of one's own that came back after its own disappearance did not count as an echo —
   that is exactly what the setting was created for. A disappearance together with an appearance in one event
   is untouched too: there a cable was moved over, and the new monitor IS the news (the `cable swapped` case
   was written earlier and stayed green; changing its order would have meant fixing the wrong defect).

   The exception for one's "own" monitor lived three days and was removed on 31 August: a return a second
   after its own disappearance turned out to be the monitor's deep sleep rather than a hand on a button. See
   the entry "An audit after two complaints" below.
3. **The log names the monitors.** The lines `plug: XG27AQDMGR went away` and `plug: LG ULTRAGEAR came up` are
   written before any decision. This whole evening's investigation went on inferring the names indirectly —
   from which branch had fired: it was visible WHAT had been decided and not visible about whom.

The clock is held by the tray (`$script:LastVanishAt`, `$script:LastVanishIds`), and a pure function makes the
decision: the time and the list arrive as parameters, or it could not be tested. The quarantine is
deliberately not written to disk — a disappearance remembered since yesterday would forbid a real plug-in.

### What turned out not to be ours, and how that was established

The ASUS dropping off the bus is not ours. It recurred at a time when the application was doing nothing: at
21:13 all four checks said "already correct", not one call to the hardware, and the monitors switched anyway —
that was Windows.

But the indirect arguments here are thin, and it is right that they were not enough. The direct argument turned
up in a Windows log we did not know about:

    Microsoft-Windows-Kernel-PnP/Device Management, event 1010
    "Device DISPLAY\AUSAA1D\5&2b9c6f03&0&UID4353 has been surprise removed
     as it is reported as missing on the bus"

That is "the monitor went out by itself", said in words and with an exact time. Counted over the log's whole
history:

- the ASUS has been leaving the bus **since 18 May**, 141 times: 53 in May, 44 in June, 35 in July, 9 in
  August;
- the ULTRAGEAR by the hundred, since January (it is on HDMI, where this happens more often);
- the drop-off arrives **2 seconds earlier** than the tray notices it — that is, it is the cause and not the
  effect.

So "the monitor switches itself off" is not news and was never ours. What became news on 26 August was
something else: an ordinary event that had been happening unnoticed for months began to **drag the desk
away** — `onPlug` turned it into a switch, and the overwritten last mode made that state permanent. The
defect was real; its symptom ("the ASUS goes out"), though, had existed long before the code that exposed it.

So that this is never inferred indirectly again, two things were added:

- `desk:` — the whole desk in one line on every configuration change, with three different states (`gone` —
  not on the bus, `off` — switched off by us, `on` — showing) and the idle time alongside;
- `tools/trace-displays.ps1` — our log and `Kernel-PnP` 1010 in one timeline by time. Exactly the splice
  that was missing and that an evening went on.

A separate subtlety: a monitor taken off the bus vanishes from the enumeration **entirely**, and asking for
its name at the moment it goes is too late. So the tray remembers the paths it has seen
(`$script:KnownLabels`), and `Get-DisplayLabelById` takes the name from there — otherwise the line
`plug: ... went away` would say "a display" in exactly the case it was created for.

Candidate number one on the hardware side is DisplayPort Deep Sleep in the monitor's own menu; the
application already mentions it in the "Nothing came up" balloon.

## An audit after two complaints (2026-08-31)

There were two complaints: "I was playing, and the game jumped from screen to screen when I alt-tabbed" and
"I unplugged the UltraFine's cable and the Asus went out too". Neither turned out to be ours, but the audit
they prompted found two real defects. Useful as a specimen: not once here did the symptom and the cause
coincide.

### Both complaints are not ours

**The game.** Across the whole 17:24–18:07 session there is not one `--- start` in the log, only a dozen and
a half `watch: postponed — full screen`. The watchdog backed off honestly and the application never touched
the desk. The jumps are visible in `desk:`: 240 to 59 Hz and back without a single call of ours — that is the
game setting its own mode and Windows taking it away. There was some involvement of ours that evening after
all, but earlier and of a different kind: at 17:23:29 the desk was switched to `work+game` **with the game
already running**, and games that pick a monitor by index lose "their" screen after a topology change.

**The UltraFine and the Asus.** The log's last line is `tray: stopped` at 18:07:05, and nothing after it. The
cable experiment took place with the **tray shut down**, that is, it was Windows itself that put the Asus out:
it has a configuration database of its own for every set of connected monitors, and for the pair {UltraGear,
Asus} it remembered something of its own. The same mechanism from the other side is visible at 15:20:40 the
same day — the UltraGear's link flapped, and Windows lit the Asus at 144 Hz that nobody had asked it for.

### Defect one: a monitor's sleep looked like a hand on the button

30 August, twice in one evening:

    19:58:47  plug: LG ULTRAGEAR went away
    19:58:47  reapply: 'Only LG ULTRAGEAR' is not available right now
    19:58:48  plug: LG ULTRAGEAR came up
    19:58:48  reapply: a display was plugged in -> 'Work'
    19:58:48  ccd: full config applied - 2 display(s) on

The person was sitting in `work+game` with a full-screen Chrome on the Asus. The ULTRAGEAR, which the mode
had put out, left the bus by itself (deep sleep) and came back **a second later** — and `onPlug` assembled
`combo:Work`, which has no Asus in it. At 23:47 the same thing, to the second. This is the
"unplug one and another switches off", only there was no hand on a cable at all.

The quarantine of 28 August let this case through deliberately: a monitor of one's own that came back after
its own disappearance counted as "switched off with the button and switched back on". They can only be told
apart by time, and the log shows there is nothing to tell apart:

| what | gap between the disappearance and the return |
| --- | --- |
| its own flap (the monitor's sleep), 08-30 19:58 and 23:47 | **1 s** and **1 s** |
| a real switch-on, 08-29 20:22 | **17,335 s** |
| a real switch-on, 08-31 12:33 | **35,256 s** |

Between a second and five hours there is nothing to pick a threshold from, so no separate threshold appeared:
the exception was simply removed, and any appearance — one's own and somebody else's — now falls under the
quarantine (`QuietSeconds`, the same 10 s). The "switched off with the button" case is not lost: a hand does
not fit inside ten seconds, and if it did, the next press will fire. The cost of being wrong is asymmetric,
and it is cheaper not to assemble the desk on a button press than to put a monitor out in the middle of a
game.

### Defect two: rebuilding the desk did not look at the full screen

The refresh-rate watchdog has backed off before a full-screen application from the start (the entry of
26 August), while the "the world changed by itself" path did not. That is exactly why the rebuild of
30 August went through to the end over a full-screen Chrome: nobody asked `Test-FullscreenApp` on that path.

Now it does ask — in `Invoke-ReapplyMode`, that is, for both roads at once: for `onPlug`/`onUnplug` and for
the restore after sleep. What is postponed is **remembered rather than forgotten**: a monitor that went away
leaves the layout drifted, and a person coming out of a game expects an assembled desk rather than the one
Windows left them. It is picked up from the existing 15-second timer — leaving a borderless full screen comes
with no `DisplaySettingsChanged` event, there is nothing to wait for, and we have to ask ourselves. No timer
of its own was created for this, and no new setting either.

Three things that are not obvious in this construction and are therefore pinned down by tests:

- **one** intention is postponed, the latest one: events arrive under one game without limit, and by the time
  it ends the earlier ones are no longer true;
- a switch by hand **cancels** what was postponed — it was waiting for the game to end, and in the meantime
  the person said what they wanted, and laying a half-hour-old decision over their choice would be the same
  war `Reset-RuleOwnership` next door exists to avoid;
- an unreachable mode is not postponed forever: the intention is cleared before the availability check, or it
  would survive every game and every tick of the timer.

The worst a false positive from `Test-FullscreenApp` now costs (and it does lie, see the entry of
26 August) is a fifteen-second delay to the rebuild. The former price of a false **negative** was a monitor
put out under a game.

### What of this concerns a new person

Almost nothing, and that was worth checking separately. `onPlug` is empty by default, so the first defect
only befalls whoever turned the setting on by hand — the second defect, though, is shared: `onUnplug` is on
out of the box. The fixes added not one new setting: both roads simply became more careful on their own
rather than by request.

## A review before the release, and what it turned up (2026-09-01)

A read of the whole thing before making it public — every file, top to bottom, with the numbers measured
rather than guessed. Five things came out of it, and the first is the kind only a reading finds: it had no
symptom anybody would have reported, because what it broke was a promise nobody had tried to check.

### The taskbar was never placed on a desk with no `layout`

`Switch-DisplayMode` called `Set-CcdLayout` from inside `if ($order.Count -gt 0)`. Read on its own that
looks right — with no order there is nothing to arrange. But "primary" in Windows is not a flag, it is the
place (0, 0), and that call is the only thing in the whole application that moves anybody there.
`Set-CcdFullConfig` refuses without an order, `Set-CcdTopology` knows nothing about a primary, and so on an
empty `layout` the taskbar simply stayed where Windows had put it: the `primary` setting did nothing, a
combo's own primary did nothing, and `-PrimaryMatch` from the command line did nothing at all — except
throw on a typo.

Whose desks: every one whose owner has never pressed Save in the Settings window. The first run writes
`settings.json` with the shortcuts alone, and `layout` is filled in from the desk cards only on a save — so
that is the state a fresh install is in.

Three things say the guard was a slip and not a decision. The branch inside `Invoke-CcdLayoutAttempt` that
exists for exactly this case ("There is no order — nothing to arrange, but the primary monitor still has to
end up at (0,0)") was unreachable: the only production caller was behind that `if`, and the tests always
shadow the function, so that code had never run anywhere at all. README said the old road "moves only the
primary and leaves the rest where they are". And so did this file, six hundred lines above.

Proved before it was touched, by running the real `Switch-DisplayMode` over shadowed CCD calls:

```
A. layout SET           : full > settle > layout     <- the primary is applied
B. layout EMPTY         : topology > settle          <- Set-CcdLayout is never called
C. empty + -PrimaryMatch: topology > settle          <- silently a no-op
D. solo, layout EMPTY   : topology > settle          <- one screen, and still the long road
```

The call is unconditional now. It costs nothing when there is nothing to do: the attempt compares the
positions it would set against the ones standing and returns `Changed = false` without asking Windows for
anything — the same "already correct" every other step of a switch prints.

Case D was worth its own line. One screen has no order to be arranged against: its place is the origin
whatever the settings say. `Set-CcdFullConfig` now takes the one-call road for a single display with no
`layout` at all — so a solo mode, the mode pressed more often than any other, stopped costing three
transitions on every desk that has never seen the Settings window.

### A rule that fired into a busy mutex lost its turn

`Invoke-RulesCheck` claimed ownership of the desk before calling `Invoke-Mode`, and never looked at what
came back. A busy `Local\ScreenDeckSwitch` answers `Skipped`, and that is an ordinary answer here rather
than a breakage: a rule fires on the very events the refresh-rate watchdog wakes on, and that one holds the
mutex for about a second. The reapply path was taught this on 30 August (`$script:LastSwitchWent`); the
rules were not.

What it cost, in order of nastiness. Going back was the worst: ownership was let go BEFORE the switch, so a
refused way back left the person on the game display for good — the condition has ended, and nothing comes
down that road again. Firing was milder: the next tick saw the mode unchanged and let go with "the displays
were changed by hand", about a person who had touched nothing, and the rule fired again fifteen seconds
later. Unless the desk matched no known mode at all — then the release branch does not fire either (it only
fires on a mode that *differs*), and the claim the rule never earned held until the game was closed.

Only a busy mutex is retried. "That display is not connected" will not come right by being asked again, and
a retry loop there would be a balloon every fifteen seconds — so `Invoke-Mode` now reports the two apart,
through `$script:LastSwitchSkipped` beside the field that was already there.

### The one write to disk that could take the tray down

Every write in this project says so in the log and carries on — `Save-LastMode`, `Save-ModeCache`,
`Write-DisplayLog`, the window snapshots, the diary. `Save-DisplaySettings` did not: no `try`, and no
`-ErrorAction Stop` either, so under a caller with `Continue` it would have written "settings: saved" after
a write that never happened. Under `Stop` — which is what both entry points set — it threw.

And it is called at the TOP LEVEL of the tray's startup, twice: after the hotkey migration, and on the
first run. That is before the message loop, with the console hidden. A folder without write rights (a
shared `Tools\`, a read-only share, an editor holding the file open) therefore killed the application
silently and left nothing in the log — on the very first meeting with it. Verified against a read-only
file: `UnauthorizedAccessException`, and not a line written anywhere.

It answers `$true`/`$false` now. The tray starts either way and the log says why; the Settings window is
the one caller with something to do about a "no", and it says so in a message box instead of reporting a
save that did not happen.

### Three smaller ones

**`work.cmd` and `game.cmd` ship in the archive** and name combos a new person does not have. The mode did
not resolve, `Set-Display.ps1` died with a red wall of PowerShell internals, and the window closed on the
instant — the file looked broken rather than unconfigured. The CLI catches its own refusals now and prints
the sentence it always had ("Unknown mode 'work'. Run: .\Set-Display.ps1 modes"), and the wrappers end in
`|| pause`: silent on success, readable on a refusal.

**"asking..." in the brightness probe was never painted.** WPF draws when the handler gives the thread
back, and `Get-MonitorLevels` holds it for tenths of a second — up to a second on a bus that has to be
asked three times. A person saw a frozen window and no reason for it. One dispatcher pump at `Render`
priority, and the word arrives before the wait instead of with the answer.

**`PROPVARIANT` was eight bytes short.** The declaration carried two fields — the type at 0 and the pointer
at 8 — which the marshaller lays out as 16 bytes, while the real thing is 24 on x64.
`IPropertyStore::GetValue` writes a whole one into that buffer on every audio-device listing. Nothing
visible ever came of it, which is exactly what makes it worth naming; the size is stated outright now. The
string it hands back was leaking as well, and is released with `PropVariantClear`.

### What the reading did NOT find, and the numbers behind that

Idle cost, which is what a tray icon has to answer for. The 15-second timer does nothing at all when there
are no rules and nothing is postponed; the 10-second diary timer returns on a single dictionary lookup
while `stats` is off; `Test-FullscreenApp` is only asked when something is waiting on it. Nothing polls the
hardware on a schedule.

Measured here, warm: `Get-CcdTargets` 13-15 ms, `Get-DisplayState` 28-30 ms, `Get-CcdPathChoice` 2 ms over
58 paths — the suspicion that its per-path name queries were expensive was simply wrong, they cost 0.03 ms
each — `Test-FullscreenApp` about 20 ms on the first call, `IdleSeconds` under a millisecond, and
`Get-DisplayModes` with `Get-ActiveModeKey` about 4 ms.

Handles are closed where they are opened: the physical monitors in a `finally`, and the hotkey window, the
tray icon, the timers, both mutexes and the two `SystemEvents` subscriptions on the way out — the switch
mutex even on the path where the switch is skipped.

### The session stamp had a seam in it

`Get-SystemSessionId` rounded the moment of boot down to the minute and the answer was compared as a
string. The moment comes off the uptime counter, which two processes read at two different moments, so a
boot that landed near a minute boundary gave them two different strings — and a tray restarted in that
session took itself for a fresh boot and laid the remembered mode over a desk somebody had just arranged
by hand. Measured against `LastBootUpTime`: the counter agrees to within two seconds, so the drift was
never the problem, the boundary was. The stamp is whole seconds now and the slack lives in the comparison
(`Test-SameSession`, two minutes) — far below the shortest gap between two real power-ons.

### The nameless line, and the tool that named it

On 31 August at 20:10 the log wrote `plug: a display went away` with no name, though the map of names seen
earlier exists for precisely that. Reading the code got nowhere: `Update-StateCache` fills the map from the
same walk that fills the set of connected monitors, so anything that can be reported as gone was in the map
a moment earlier. The invariant holds — in the code as it stands today.

`tools\trace-displays.ps1` settled it in one run, which is the first time that tool has earned its keep on
something other than the evening it was written for:

```
2026-08-31 20:10:23  WINDOWS  AUSAA1D surprise removed - missing on the bus
2026-08-31 20:10:24  deck     desk: LG ULTRAFINE on 3840x2160@60, LG ULTRAGEAR off (idle 91 s)
2026-08-31 20:10:25  deck     plug: a display went away
```

`AUSAA1D` is the ASUS. And the desk line above it is the FIRST of that run — which is the whole answer. The
tray had started at 20:03; the version on disk at that moment was 196ac4b, where the map was filled not in
`Update-StateCache` but in `Write-DeskSnapshot`. That one runs only on a configuration change, and it reads
the cache AFTER the refresh — so on the first event of a run the map was still empty, and the monitor that
caused the event was already out of the state. Every later disappearance was named (21:31 and 23:52 both say
`XG27AQDMGR went away`), because by then the desk snapshot had seen it come back.

So the defect was real, it was in this file's own subject matter, and it had been fixed before the review
even started: the declaration and the fill now sit beside the cache they index, and the comment there names
this exact symptom. What the review adds is only the last word. `Get-DisplayLabelById` has a third road —
the device path IS the identifier, and the monitor's own id sits inside it (`DISPLAY#GSM5BB3#...`). With the
map filled from the right place that road is not needed, and it is kept deliberately all the same: this
function's whole job is that the log never says "somebody", and three lines of arithmetic are a cheap price
for never having to run this investigation twice.

## A second sweep, and the answer that had no shape (2026-09-01)

The reading above found five things and shipped them. A second pass over the same code — this time going
after the *seams between* the parts rather than the parts — found twenty, and one of them was the reason
four of the others existed. Written down here because the four looked like four separate bugs right up to
the moment they turned out to be one.

### The answer a switch gives had no vocabulary

`Switch-DisplayMode` returned a `[pscustomobject]` built by hand at each of its three exits: `Skipped` on
a busy mutex, `Ok` plus `Message` at the end, `Ok = $true` on a dry run. A refusal did not return at all —
it threw, because the message is written for a person and belongs in a balloon. Four shapes, no name for
the question a caller actually has.

Two callers in the tray have that question, and each answered it out of a different piece:

```
Invoke-RulesCheck    switch branch   if ($script:LastSwitchSkipped) { Reset-RuleOwnership }
                     return branch   if (-not $script:LastSwitchSkipped) { Reset-RuleOwnership }
Invoke-ReapplyMode                   $switched = -not $result.Skipped   →  if (-not $switched) { re-arm }
```

Read each on its own and each is defensible. Together they are two opposite retry policies, and both are
wrong at one end:

* The rule's way back let the desk go on **any** failure that was not a busy mutex. A throw — Windows
  refusing the configuration, once — and the claim was dropped while the desk stood in the rule's mode.
  The condition has ended by then, so nothing comes back down that road ever again: the person stays on
  the game display until they switch by hand. Permanent, from one transient refusal.
* The reapply did the mirror image. `-not $result.Skipped` counts a switch where no monitor woke as
  "went", so the intent went in the bin with the desk still drifted — and counts a throw as "did not go",
  so the intent was re-armed and the 15-second timer asked again, and again: an error balloon every
  fifteen seconds, each one a whole switch attempt on the tray's single STA thread, until the next
  hotplug happened to change the answer.
* And a rule that failed hard kept its claim, so the next tick compared the unchanged desk against the
  mode it had never reached and released with `the displays were changed by hand` — about a person who
  had touched nothing. Then the rule fired again, failed again, and the pair repeated for as long as the
  condition lasted.

Four symptoms, in three files, and no fix to any one of them is safe on its own: releasing the claim
sooner fixes the rule and arms the balloon storm, keeping it longer fixes the storm and strands the desk.

**None of the four has ever happened on this desk, and that is the point of writing them down.** The log
holds 26 `skip: mode` lines, so the busy mutex is an everyday event — but not one `rule:` line in the
whole file, because no rule has ever been configured here, and not one `did not come up`, because these
three monitors always attach. The two paths where the two policies diverge have never been walked. Found
by reading, fixed by reading, and covered now by tests that walk all four on purpose — which is the only
way this class of thing gets found at all.

So the fix is the shape. `New-SwitchResult` builds every answer, `New-SwitchFailure` turns a caught throw
into the same one, and both callers now read two named fields:

* **`Ok`** — the desk **is** in the requested mode now. Nothing else means that. A switch that came to
  nothing ran to the end, has a summary, has a duration in the log, and is not a success.
* **`Retry`** — asking again in a moment can change this answer. True for a busy mutex (the refresh-rate
  watchdog holds `Local\ScreenDeckSwitch` for about a second after every switch, ours included) and for a
  display that has not attached yet. False for Windows turning the configuration down and for a mode that
  is no longer in the settings.

`Outcome` is the same answer as a word — `done`, `partial`, `busy`, `dryrun`, `refused` — and the rules
need it, because their question is a third one: *did the desk move?* A `partial` switch moved it; a
display that stayed dark does not undo the ones that lit. So `partial` claims the desk, `busy` claims
nothing and asks again next tick, and `refused` keeps the claim (to stop the rule firing every fifteen
seconds) while `-Taken $false` keeps the state honest — `Get-RuleDecision` now sits out the condition in
silence rather than blaming a person, and when the condition ends it lets go without moving a screen.

The retry that was missing is bounded: `$script:AutoRetryLimit`, four ticks, about a minute. Long enough
for a mutex or a display still waking; short enough that "keep asking" and "a warning balloon until
bedtime" stay different things. Waiting out a full-screen game does not spend an attempt — a game that
lasted three hours must not have used up the retries a waking display needs afterwards.

The tray's two loose booleans are one field now, `$script:LastSwitch`, and the AST test in
`34-reapply-fullscreen` asserts that the real `Invoke-Mode` publishes it from its `finally` — the line
every fake in two files stands on, and until now covered by none of a thousand assertions. Delete it and
the suite used to stay green.

### A BOM in `work.cmd`, and the two launch paths that disagree about it

`work.cmd`, `game.cmd` and `all.cmd` had a UTF-8 BOM. `.editorconfig` says `charset = utf-8-bom` for
`[*]` and had nothing to say about `.cmd`, so every editor put one there — and gate 2 of
`tools/check.ps1` never looked, because its file filter was `ps1|psd1|md|json`.

The measurement is worth writing down in full, because the first way of taking it says there is no
problem. A two-line batch, `set FIRST=RAN` and an `echo` of it, in both encodings:

```
cmd /c file.cmd          with a BOM  FIRST=[RAN]     without  FIRST=[RAN]
ShellExecute(file.cmd)   with a BOM  FIRST=[]        without  FIRST=[RAN]
```

`cmd /c` tolerates the BOM. **ShellExecute — a double click, and a shortcut pinned to the file — does
not**: the three bytes are glued to the first command, which fails as unrecognised (`ERRORLEVEL` 9009 on
the next line, measured), and then the rest of the file runs on. So a BOM costs exactly the first line,
and only when launched the way a person launches these.

Which puts the real cost lower than "the file does nothing" and higher than nothing at all. The first
line here is `@echo off`. The switch still happens; what is lost is the quiet: the window shows
`'∩╗┐@echo' is not recognized`, then echoes the whole `powershell -NoProfile ...` line, and on success
closes the instant it is done. `@echo off` and `|| pause` exist together so that the ONLY thing a person
ever reads out of these files is a refusal. A BOM turns that into a flash of an error message on every
successful switch — a file that works and looks broken, which is worse than one that plainly does not.

Both halves are fixed: the BOM stripped, `[*.cmd]` written into `.editorconfig`, and gate 2 now covers
`.cmd` with the requirement *inverted* — `.ps1` must have the BOM, `.cmd` must not, and the two sit in
one directory where one careless "normalise on save" reaches both.

### Nothing to anchor is not "already correct"

The unconditional `Set-CcdLayout` from the review above brought a case with it that the old `if` had kept
out of reach. With no `layout` in the settings the call has one job — put the primary display at (0, 0) —
and it took its anchor from `$screens[0]` when the display it was asked for was not among the active ones.

That shifts the **whole desk** by a stranger's offset: every window moves, the taskbar lands on a display
nobody named, and the line above it in the log reports the taskbar as having gone to the display that
never came up. Before the call became unconditional this branch was reached only when an order existed
and the fallback was unreachable; afterwards it is reached on every desk whose owner has never opened the
Settings window, and a display refusing to wake is precisely when it fires.

There is nobody to anchor, so nothing moves. The layout result carries a `Note` for exactly this — "not
`Changed`, and not because everything was already right" — and the caller prints it instead of `layout:
already correct`. The absent display is reported in its own right, one line up.

### The session stamp read its own past as somebody else's

`Get-SystemSessionId` writes `<shutdownTime>/<epochSeconds>`. Before the review above it wrote
`<shutdownTime>/<yyyy-MM-dd HH:mm>`, and `last-mode.json` outlives an upgrade — this machine's own file
still said so while the fix was being written:

```
{"key":"solo:LG ULTRAGEAR","session":"134326946768424535/2026-09-01 10:25","when":"2026-09-01T15:19:03"}
```

`Test-SameSession` split that, failed to parse `2026-09-01 10:25` as a number, and answered "another
session" — so the first start after the upgrade would lay the remembered mode over a desk the person had
arranged themselves. Once, on every installation in existence, with nothing in the log anybody would
connect to the upgrade. The test file made it worse than a slip: `and anything else is not` asserted the
wrong answer in so many words, so the suite was holding the defect in place.

The shutdown half decides it now. That one is read out of the registry by both sides and changes at every
power-off, so a match means the power-on we are living in — bar a crash or a Reset, which leave it
untouched. That "bar" is why the answer is yes rather than no: guessing wrong this way costs one skipped
restore and a keypress, guessing wrong the other way moves somebody's desk. It happens exactly once —
the next switch writes the stamp in today's shape.

### The promise about window titles was true in one file and false in another

README, `Activity.ps1` and the Settings window all say, in those words, that window titles are never
read. `Save-WindowLayout` wrote `title` and `path` — the window's caption and the full path to its
executable — into `window-state.json` for every window on the desk, on every switch. `Restore-WindowLayout`
reads `hwnd`, `pid`, `showCmd`, `n`, `mn`, `mx`. Nothing anywhere read the other two, ever.

So "Delete `activity.json` to forget everything", which the Settings window offers, forgot nothing of the
sort: the titles were sitting in the file next to it. A promise is kept where the reading would happen,
not where the writing does, so `Title` and `Path` are gone from `WinInfo` and from `Enumerate` — along
with `PathOf`, which was an `OpenProcess` per window on the switch path. What is never gathered cannot be
written down by the next person to touch the snapshot. An existing store is swept on the next tray start:
stopping the writing is only half of it, because a snapshot is rewritten only when its own desk is left,
and the layouts a person visits rarely would have kept their titles for as long as the file lived.

### The rest, and the one thing worth generalising

A claim on the desk was a rule's **index**, and the rules list is edited by hand and from the Settings
window while a rule is holding it: delete a rule above the holder and the claim quietly moves to whoever
slides into that slot. `Get-RuleSignature` — what it watches, what for, where it goes, where it comes back
— is the identity now, and the index is only where to look first. Deleting the *last* rule while it held
the desk did nothing at all, because `Invoke-RulesCheck` returned early on an empty list, jumping over the
answer `Get-RuleDecision` has had for that case from the start.

Two `WaitOne(0)` calls stood outside their `try`. `AbandonedMutexException` is thrown *while granting
ownership*: the wait fails and the mutex is ours, so out there it was leaked, and in a tray that lives for
weeks every later switch would have answered "a switch is already in progress" for good. Self-healing on
restart, which is why nobody had seen it.

Three `Set-Content` calls had no `-ErrorAction Stop`, so their non-terminating refusal skipped the `catch`
and the next line reported success — the diary would have declared its unsaved day clean and thrown it
away. They were masked by both entry points setting `$ErrorActionPreference = 'Stop'`, which is exactly
the mask `Write-DisplayLog` has carried a comment about since August: core must not depend on its caller's
preference, and neither must anything core dot-sources. `[void](Save-DisplaySettings)` on the first-run
path was the same disease with a worse ending: a first run is told by the ABSENCE of `settings.json`, so
in a folder we may not write to, the log said "assigned the default shortcuts" and every start afterwards
was a first run again — welcome balloon, Settings window, for good.

The generalisation, and the only line of this section worth carrying forward: **every one of these is a
caller and a callee disagreeing about what an answer means.** `-ErrorAction Stop` is a callee that returns
failure by a channel the caller is not listening on. `WaitOne` is a callee that returns success by
throwing. `Skipped` versus `Ok` is one answer that two callers read as two. `$screens[0]` is a callee
inventing an answer rather than admitting it has none. They are not five kinds of bug; they are one, and
the place to look for the next one is wherever a return value is read in pieces.

## The archive was rehearsed, and PowerShell 7 was found in the way (2026-09-01)

The first CI run went green with the analyzer actually installed — 1.25.0, clean, 1099 assertions — so
the third gate, which is skipped here for want of the module, finally had a verdict rather than a
warning. That left the release itself untested, so it was built by hand the way the tag will build it:
`pack.ps1 -ExpectVersion 1.0.0`, 17 files, 189 KB, one `ScreenDeck` folder inside, the CHANGELOG section
pulled out whole. Unpacked into a folder of its own, `.ps1` still carried the BOM and `.cmd` still did
not, and `Set-Display.ps1 status` printed the desk.

Then the same command in the terminal that happened to be open, which was **pwsh 7**:

```
Add-Type: DisplayCore.ps1:2145
(292,20): error CS0246: The type or namespace name 'List<>' could not be found
```

`using System.Collections.Generic;` is at the top of the embedded block and always was. The difference
is the compiler underneath: on .NET Framework `Add-Type` references mscorlib whatever else is asked for,
on .NET Core it references what `-ReferencedAssemblies` names and nothing more — here
`System.Windows.Forms` and `System.Drawing`, which do not bring `System.Runtime` with them. The generic
collections are simply not in scope, and the error names a type nobody wrote.

What let it happen is that `#Requires -Version 5.1` is a **minimum**. Seven satisfies it and walks on.
Every `.cmd` here calls `powershell` by name, so the ordinary way in was never affected — which is
exactly why it went unnoticed: nobody on this desk types the script name into a shell they did not
choose for it. Whoever unpacks the ZIP and tries it in Windows Terminal, where the default profile is
increasingly pwsh, gets a C# compiler error as their first impression of the tool.

Making it *work* on 7 is a different project: WinForms, WPF and every P/Invoke here would have to be
measured again, and the measurements are the whole value of this code. So it is a refusal, and it sits
at the top of `DisplayCore.ps1` rather than in the two entry points — that file is what the tray, the
command line, `render-preview.ps1` and the test runner all dot-source, and it is what fails. One copy,
and no new entry point can forget it. The test does not spawn a shell; it reads the source and asserts
the guard still stands **before** the `Add-Type` it protects, because below it the refusal would arrive
after the error it exists to replace.
## The scrollbar was fifteen points wide, and the diary moved out of the browser (2026-09-01)

Two complaints, and only the second one sounded like a feature: *there is a scrollbar in the settings
though everything fits*, and *show the statistics somewhere other than the browser, with a period I can
choose*.

The first was arithmetic. `render-preview.ps1` writes at 192 dpi, so its numbers halve into WPF points:
the Settings window measured **1375** points of content. This desk's primary is the 1440p panel at 100%,
work area 1392 pixels, and a window carries a title bar of about 31 on top of its content. 1375 + 31 =
1406 against 1392: fourteen points over, `SizeToContent` stops at the screen's edge, and the viewer that
had nothing to scroll grew a bar and took another seventeen points of width for it. A window that *fits*
was scrolled because it missed by half a line of text.

So the height was spent down rather than the bar hidden — hiding it would have clipped the last row
instead:

| what | points |
| --- | --- |
| the caption under the desk picture ("How Windows will arrange the displays.") | 24 |
| the desk canvas, 132 → 112, and its padding 12 → 10 | 24 |
| the six behaviour rows, gaps 12 → 10 | 20 |
| "Restore the last mode", reworded so it stops wrapping to a second line | 16 |
| the six mode rows, margins 4 → 2 | 24 |

1277 now — about 80 points of room, which is two more modes before this comes back. The caption was the
only *thing* removed, and it was the right one: it stood under a picture of three named rectangles and
said that the picture was of three rectangles.

The second complaint was the interesting one. `Activity.ps1` had carried a note since August saying the
report gets no window of its own — "a WPF window with charts is a day of work and another thousand lines,
whereas a page in the browser reads better". Half of that stayed true. What broke it is the period: the
page is a **static file with no script in it**, deliberately, so choosing "today" in it means writing the
file again and reloading the tab. Four periods that way are four round trips through the browser to answer
a question you asked from the tray icon. In a window, four pills.

So both exist, and each does what it is for. The window is the everyday look: 880 by 750 points, six
figures, the hour histogram, four top-five lists, one screen, no scrolling on any desk with 780 points of
height. The page is the artefact: **Open as a page** writes `stats.html` for whatever period is on screen
— a file to keep or to send, which a window will never be. Both are built from the same
`Get-ActivityReport`, so they cannot disagree.

Three small things fell out of the work:

- **"All" is nought days, not a big number.** `Get-ActivityReport` builds a `yyyy-MM-dd` boundary and
  compares dates as strings; the empty string is below every date there can be, so `-Days 0` reads the
  whole pot without anybody having to guess how far back "far enough" is.
- **The diary keeps mode keys; nobody should have to read them.** `combo:Work` is what a switch is
  recorded as and it must stay that way — but `Get-ModeTitleFromKey` already turns a key into the name
  the mode has everywhere else in the app, and now all three places the diary is shown (window, page,
  console) go through one `ConvertTo-ModeTitleRows`. It cost eight lines and removed the last place where
  the tool spoke to a person in its own storage format.
- **An empty report hands back no hours at all** — `Get-ActivityReport` returns early before it fills the
  twenty-four. The page never showed it because nobody opens a report of nothing; the window would have
  drawn a blank rectangle under "Time of day" and looked broken. It draws the twenty-four ticks itself in
  that case: a flat row says "nothing happened", empty space says "this is not finished".

The window is the fourth in `SettingsDialog.ps1` and follows the same three rules as the other three: it
is built separately from being shown (`New-StatsWindow` / `Show-ActivityStats`), not one handler holds a
closure (the period lives on the pill's `.Tag`, the window in `$script:ActiveStatsUi`), and
`render-preview.ps1` renders it to a PNG without showing it — which is how its layout was measured at
every step above, on a desk that does not exist.
