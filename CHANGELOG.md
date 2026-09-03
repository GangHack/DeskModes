# Changelog

What changed, and why you would care. Versions follow
[semantic versioning](https://semver.org/): the middle number moves when
something new appears, the last one when something is fixed.

The version is printed by `.\Set-Display.ps1 status` and by **About ScreenDeck**
in the tray menu — that line is the right thing to paste into a bug report.

## Unreleased

### The Settings window is an application

- **A pane on the left, a page on the right.** Your desk, Modes, Rules and Behavior are pages
  now instead of four cards stacked into one column 640 points wide and up to 1311 tall. Nothing
  is folded away to make room, and the next section that comes along has somewhere to stand.
- **The window can be resized**, and it comes back the size you left it, in the place you left
  it, on the page you left it on. That is kept in `ui-state.json` next to the program - the
  machine's state, like `window-state.json`, and safe to delete. A rectangle that is no longer on
  any screen is refused: a window put back onto a monitor that has gone cannot be reached at all.
- **Your desk has a Displays table** under the cards: what each display reports about itself, and
  the **Monitor ID** it is called by in `settings.json` and in the log - which is the name you
  need when you open either by hand.
- **The commands stand in the page's heading** - *Add a combination*, *Add a rule* - rather than
  under the list. With a dozen modes, adding one meant scrolling to the bottom first.
- **An About page**, at the bottom of the pane where Windows keeps its own: the version line to
  paste into a bug report, the log, the folder everything lives in, the project page and a
  **Report a problem** button. **About ScreenDeck** in the tray menu opens the window there
  instead of showing a notification you cannot copy from.
- **A Support card** with a **Donate** button. There is no address behind it yet, and until there
  is, the button says so instead of opening a page that would not be there.

### The monitor's picture preset follows the mode

- **Remember the monitor's current preset.** A mode already carried brightness and contrast; now it
  can carry the thing the buttons on the monitor's bezel change - Reader, FPS, sRGB, whatever that
  monitor calls them. Set the monitor the way you want it for this mode, press **Remember** in the
  mode's editor, and the switch puts it back there every time.
- **No names and no lists**, deliberately. The numbers behind those names are the manufacturer's,
  and on this desk one monitor shows two different numbers as "Gamer 1" - they look nothing alike.
  So ScreenDeck remembers the number the monitor is holding when you press the button, along with
  the register it answered on, and writes exactly that back.
- The setting is one line per display in `settings.json` - `"picture": { "combo:Work": {
  "ULTRAGEAR": "0x15:45" } }` - and `.\Set-Display.ps1 brightness` now prints the register and
  number each monitor is holding, so it can be written by hand as well.
- The preset goes out **before** brightness and contrast: on some presets a monitor locks those two
  in its own menu, and a level written first would land in a monitor about to forget it. The log
  says which of the three was taken, refused or never answered, separately.
- A monitor that is asleep or has DDC/CI switched off in its menu says so instead of having a
  preset guessed for it.

### Windows' display timeout, where the desk is

- **Displays go to sleep after** is a row on the **Your desk** page: the same setting Windows keeps
  under Power, next to the question it belongs with. It is read when the window opens and written
  on **Save**, and only if you changed it - like **Start with Windows**, it is the system's state
  and not something `settings.json` carries.
- A value you set in Windows itself keeps its place in the list rather than being rounded to the
  nearest ready answer, and if Windows will not say what the timeout is, the row says so instead
  of offering to change something it could not read.

### The diary is a page of the same window

- **Statistics...** in the tray opens the Settings window on its **Diary** page instead of a
  window of its own. The same six figures, the same histogram and the same four lists - and
  **Open as a page** still writes `stats.html` for whatever period is on screen.
- **A row is two floors now**: the name and the time on top, the bar and the share underneath.
  In the old 880-point window all four shared one line, and the name was the one that gave way -
  "chrome on LG ULTRA..." was already cut off there. Nothing is trimmed any more.
- The six figures are **three by two** rather than six across, so "09:40-23:15" has room to be
  itself; and what the diary does not record is said once, on the **Behavior** page, instead of
  twice.

### A mode's editor holds all of a mode

- **Contrast has a card**, right under Brightness and working exactly like it: leave it alone,
  one level for the whole mode, or one per display. **Ask the monitors** reports both in one
  walk of the bus — fewer monitors answer for contrast, and now you can see which.
- **The playback device is picked from a list.** Open the dropdown and it offers what Windows
  has; what gets stored is still a *piece* of the name, so shortening "Speakers (Realtek High
  Definition Audio)" to "Realtek" by hand keeps working when a driver update renames the rest.
  The list is fetched when you first open it, never when the window is built.
- **Commands got their two boxes** — *Before switching* and *After switching*, with the promise
  written above them: the command is started and not waited for.
- **A mode's row says what is set on it.** `brightness 80  -  contrast 65  -  audio  -  command`,
  so a setting hidden behind an Edit button is no longer invisible until you have opened every
  mode in turn.
- All four are now **edited** rather than merely carried: emptying a box clears the setting.
  Until now a device or a command could be added to `settings.json` by hand and never taken
  away from any window, and an entry left behind by a mode that no longer exists gets its own
  removable row, the way a stranded shortcut always did.

### Rows that say only what they have to

- **The display cards are the picture.** There was a second drawing under the row saying the same
  thing twice — the same displays, the same order, the same taskbar. Each card's screen is the
  display it stands for now, and the taskbar display is the one outlined. One control instead of
  two, and 132 points shorter.
- **A mode's row says nothing about what kind of mode it is.** "Only LG ULTRAFINE" had a second
  line under it reading "Display"; a combination's said "Combination" before listing anything.
  Both repeated what the row already showed — the title in one case, the **Remove** button in the
  other. A display's row is one line high now unless the mode actually has something set on it,
  and a combination's caption keeps the 87 points the word was taking:
  `LG ULTRAFINE + LG ULTRAGEAR  -  brightness per display` where it read
  `Combination  -  LG ULTRAFINE + LG ULTRAGEAR  -  bri…`.
- **The mode editor folds too.** What a mode *is* stays in sight — its name, its displays, the
  taskbar and the shortcut. What it does to the hardware — brightness, contrast, the playback
  device and the commands — sits behind **Brightness, sound and commands**, which halves the
  editor: 615 points instead of 1199. It **opens by itself** for a mode that has any of them set,
  including one inherited from a name just typed, because a setting nobody can see is a setting
  an empty field then erases.

### The display cards are the size of the displays

- **A card's screen is drawn to the size of the panel**, taken from the monitor's own EDID,
  instead of to its resolution. Drawing by pixels said the opposite of what is on the desk: a
  24-inch 4K got 128 points of width and the 27-inch 1440p beside it 85, so the smaller monitor
  was shown half again as big as the larger one.
- The difference is **damped** — the width follows the square root of the ratio of the diagonals
  — because the row is for telling which panel is which, not for measuring them: 24 next to 27
  comes out at 94 %, and 32 next to 24 at 115 %. The shape is still the resolution's, so a 21:9
  stays a long one, and a monitor whose EDID says nothing about its size (projectors and network
  displays write nothing there) is drawn like its neighbours rather than as a dot. The size in
  inches is on the card's hover text next to the resolution.
- The screens no longer step down the card as they will on the desk. That offset was the height
  of the picture, and it made the row look broken for something a person cannot change here
  anyway: Windows centres displays of different heights, and it does so on its own.

### Rules are a list you can see

- **A Rules card** between Modes and Behavior: what each rule watches for, where it takes the
  desk, where it puts it back, and a switch that turns one off without deleting it. A rule that
  is off is dimmed, so the list explains why the desk is not moving.
- **Add a rule** and **Edit** open a small window with four questions — when, what to watch,
  where to go and where to come back to. It refuses a rule with no mode, a program rule with no
  program, an idle rule of less than a minute, and one that goes back to the mode it switches to
  (which would flicker the desk every fifteen seconds).
- **The program is picked from a list.** The box offers what has a window open right now and what
  the diary has seen in the last month — because a rule for a game is usually written while the
  game is not running. The names are offered the way a rule stores them, without `.exe`, and
  typing one in by hand works exactly as before. The list is gathered when you first open it,
  never when the window is built.
- Renaming a combination carries the rules that point at it, in the window and at once; deleting
  one drops the rules that needed it and clears the way back of the rest. That used to happen
  in a rename map at Save time and is now the same path every other mode-keyed setting takes.
- An edited rule **keeps its place** in the list, because that order is the order the tray checks
  them in and the first match wins.

### Rebuilding the desk is three controls, not three keys in a file

- **Rebuild after waking from sleep** and **Rebuild when a display is unplugged** are toggles in
  **Behavior** now. Both default to on, so until now the only way to say "stop doing that" was
  to find `reapply` in `settings.json`.
- **When a display is plugged in, switch to** is a dropdown of every mode, empty by default.
  It follows a combination through a rename while the window is open, and clears itself if you
  delete the combination it pointed at. A mode that is not on the desk right now keeps its
  place in the list rather than being quietly dropped — a monitor being asleep is not a reason
  to cancel a decision you made.
- Any other key you put in `reapply` by hand travels through a Save untouched.

### Fixed

- **Renaming a combination no longer drops what the rename was not told about.** Everything
  keyed to a mode now *moves* to the new key instead of being cleared and rewritten from the
  edit — a setting the edit did not mention kept its value everywhere else in the window, and
  a rename was the one place that meant "throw it away".

### The diary has a window

- **Statistics…** opens a window of its own instead of a browser tab: the same numbers, in
  the system theme and accent colour, all on one screen — six figures at the top, the
  hour-of-the-day histogram, and top lists for displays, modes, apps and app-on-display.
  Nothing scrolls; that is what the window is for.
- **The period is chosen where the diary is read**: **Today**, **7 days**, **30 days** or
  **All**. "All" means every day the diary still holds, however far back that goes.
- **Modes are named, not keyed.** "Work" and "Only XG27AQDMGR" rather than `combo:Work` and
  `solo:XG27AQDMGR` — in the window, on the page and in the console report alike.
- The page has not gone anywhere. **Open as a page** at the bottom of the window writes
  `stats.html` for the period on screen and opens it in the browser: a file to keep or send,
  which a window is not.

### Fixed

- The Settings window no longer opens with a scrollbar it does not need. It had grown about
  twenty points taller than the work area of a 1440p screen, so a window whose content fits
  was scrolled all the same; it is a hundred points shorter now, and the desk picture lost a
  caption that only repeated the section above it.
- **A window that grows no longer grows off the bottom of the screen.** Open **Add a
  combination** low on the display and unfold **Brightness, sound and commands**: the editor
  went from 578 points to 1201, all of it downwards, and **Save** ended up 615 points below
  the edge with no way to reach it — the window has no border to drag. Every window that
  sizes itself to its content is now kept inside the work area of the monitor it stands on,
  and one taller than that monitor is pinned to the top so the title and the first question
  stay reachable. The height limit is read off that same monitor too, instead of off the
  primary one — on a desk of displays of different heights those are different numbers.

## 1.0.0 — 2026-09-01

First public release. Everything below is what the tool does on day one, not a
list of changes against something earlier.

### Switching

- Modes: one per connected display, one per combination you define, and **all**.
  Global shortcuts are registered by the tray process itself, so they work
  whether or not Explorer picked up a Start-menu shortcut.
- A switch is **one** `SetDisplayConfig` call — set, positions, primary,
  resolutions and refresh rates at once — instead of three transitions. Each
  transition freezes input and blinks the screens, so this is the difference
  between a switch you notice and one you do not.
- Pressing the shortcut for the mode you are already in costs nothing: the
  topology is left alone, and only the layout and the modes are checked.
- Refresh rate is asked for as the driver's exact fraction (144 Hz is
  `143999/1000` here). Whole hertz are rounded, and Windows rejects the whole
  request over it.
- Displays are arranged left to right in the order you list them, with the
  taskbar on the one you name.
- A refusal is reported as a refusal: a display that would not turn off, a
  layout that would not lie down, or a display that never attached all land in
  the summary and in the exit code.

### While it runs

- Puts back a refresh rate Windows silently dropped, and rebuilds the desk after
  sleep or a hotplug — without ever overwriting the mode you chose, without
  mistaking a display waking from its own sleep for a hand on a cable, and never
  while a game is on the screen: that work waits until you are out of it.
- The log names displays, not "a display", and writes the whole desk on every
  change: who is gone from the bus, who is merely switched off, who is showing
  what. A display the driver removed is still named, from what was seen before.
- Leaves a full-screen game alone — changing the mode under a full-screen D3D
  device makes the picture blink and the window minimise.
- Rules: "while this program runs, be in that mode", and back again afterwards.
- Brightness and contrast over DDC/CI, per mode or per display.
- Commands before and after a switch.
- Window positions remembered per set of displays and put back.
- A shutdown timer, and a diary of what you did where, with an HTML report.

### Interface

- A tray icon with a menu that shows the real state of every display, themed
  after the system.
- A Settings window (WPF) for combinations, order, shortcuts, brightness, rules
  and commands, with a preview of the desk. The first time the tray starts it opens
  by itself, and a balloon says the menu is on the right click — a folder of scripts
  gives no other hint that anything happened.
- Clears the Mark-of-the-Web from its own scripts when it finds it, so Explorer stops
  asking about `Displays.cmd` and your own console will run `Set-Display.ps1`
  instead of refusing it as unsigned. Anything else in the folder keeps its mark:
  there it is what SmartScreen and Protected View go by.
- A command line — `Set-Display.ps1` — with exit codes a `.cmd` wrapper can act
  on: 0 done, 1 failed, 2 another switch was already running.

### How it is built

- Windows PowerShell 5.1, no build step, no dependencies, nothing installed on
  your system. Deleting the folder uninstalls it.
- One `Add-Type` for all the embedded C#, cached as `native-*.dll` next to the
  scripts and rebuilt automatically when the source changes.
- 341 test cases and one command that runs every gate: `.\tools\check.ps1`.
