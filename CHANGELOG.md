# Changelog

What changed, and why you would care. Versions follow
[semantic versioning](https://semver.org/): the middle number moves when
something new appears, the last one when something is fixed.

The version is printed by `.\Set-Display.ps1 status` and by **About ScreenDeck**
in the tray menu — that line is the right thing to paste into a bug report.

## Unreleased

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

### The Settings window is one screen again

- **The display cards are the picture.** There was a second drawing under the row saying the same
  thing twice — the same displays, the same order, the same taskbar. Each card's screen is now
  drawn at your desk's own scale and offset, by the function the switcher itself uses: a 4K panel
  looks bigger than the 1440p one beside it, a shorter display sits lower exactly as it will, and
  the taskbar display is the one outlined. One control instead of two, and 132 points shorter.
- **Additional settings** folds away the four with a right default — the refresh-rate watchdog and
  the three "when Windows rearranges the desk behind my back" answers. They are still saved
  whether the fold is open or shut.
- Together these fit the window back onto a 1440p screen without a scrollbar, Rules card and all.
  Measured against a 1352-point limit: 1176 on a fresh desk, 1262 with a couple of combinations,
  and 1311 for a desk with two combinations, two rules and something set on every mode.
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

### Rules are a list you can see

- **A Rules card** between Modes and Behavior: what each rule watches for, where it takes the
  desk, where it puts it back, and a switch that turns one off without deleting it. A rule that
  is off is dimmed, so the list explains why the desk is not moving.
- **Add a rule** and **Edit** open a small window with four questions — when, what to watch,
  where to go and where to come back to. It refuses a rule with no mode, a program rule with no
  program, an idle rule of less than a minute, and one that goes back to the mode it switches to
  (which would flicker the desk every fifteen seconds).
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
