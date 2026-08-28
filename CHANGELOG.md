# Changelog

What changed, and why you would care. Versions follow
[semantic versioning](https://semver.org/): the middle number moves when
something new appears, the last one when something is fixed.

The version is printed by `.\Set-Display.ps1 status` and by **About ScreenDeck**
in the tray menu — that line is the right thing to paste into a bug report.

## 1.0.0 — not released yet

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
  sleep or a hotplug.
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
- 297 test cases and one command that runs every gate: `.\tools\check.ps1`.
