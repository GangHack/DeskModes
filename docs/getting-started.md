# DeskModes setup and recovery

For a quick overview and download, see the [README](https://github.com/GentleMec/DeskModes#readme).

## Quickstart

1. Extract the release ZIP into a folder you can write to, such as a folder under your
   user account. Keep the whole `DeskModes` folder together; do not run from inside the ZIP.
   A source checkout works too: `git clone https://github.com/GentleMec/DeskModes.git`.
2. Double-click **Displays.cmd**. The tray icon appears and a short **First steps** tour opens,
   followed by Settings. The interface language is in the head of the tour — it follows Windows
   until you change it there or in Behavior. The tour can be skipped from any screen and reopens
   from the tray menu or from **Settings → About → First steps**.
   Double-left-click the tray icon to reopen Settings;
   right-click it for the switching menu. If the icon is not visible, open the `^` arrow on the
   taskbar and drag it out — Windows hides new tray icons there.
   If Windows shows a warning, review the source and publisher before choosing to run it.
3. On **Your desk**, use **Use Windows layout** if the current arrangement is correct,
   or arrange the cards and choose the taskbar display. In **Modes**, add a combination,
   select its displays and set a hotkey. Press **Save**; the window stays open for further edits.
4. Switch using the tray menu or your hotkey. Enable **Start with Windows** in Behavior
   if you want the tray to return after sign-in.

DeskModes leaves the screens Windows activated at startup in place by default. The optional
**Restore the last mode at startup** setting replaces that set with your last manually chosen
mode when the application starts. Resume, hotplug and process rules are separate Behavior settings.

The interface follows Windows or your language choice: English, Russian, Ukrainian,
Spanish, French and German. Choose it on the first screen of **First steps**, or in
**Settings → Behavior → Language** and save.
Settings reopens automatically on the same page in the selected language. No JSON editing is required.
The `.cmd` launchers choose Windows PowerShell 5.1 even if your terminal uses PowerShell 7.

Display status describes the Windows desktop: a resolution and refresh rate mean the display
is active, **not in use** means Windows sees it but does not use it in the current desktop,
and **not detected** means Windows does not currently report it as available. A sleeping or
powered-off panel can remain active in Windows; check its power and input if it stays dark.

Manually selecting a mode, including repeating All, also checks the selected active panels'
power register (DDC/CI 0xD6). A panel that reports standby/off receives a power-on request,
which is read back with a bounded wait before optional brightness or picture settings.
Panels already on, unsupported registers and unknown values receive no power write.
Automatic rules, startup/resume reapplication and dry runs do not send this wake command.
A panel that has left the connection, has DDC/CI disabled or no longer answers still needs
its physical power button or connection restored. Windows desktop status is not proof of an image.

## What comes with a mode

- The selected displays and their saved Windows positions, orientation, resolution, refresh rate
  and primary display. Repeating All displays preserves the current desktop.
- Window positions per display set and optional explicit arrangement overrides.
- Optional brightness, contrast, remembered picture preset, HDR and playback device.
- Optional commands before/after switching and rules for processes, idle time or connected displays.
- **Back to the previous mode**, plus recovery of the previous display set if none of the
  requested screens attaches. Assign a Back hotkey in Behavior before experimenting.

The tray also offers sleep/shutdown timers and an optional local activity diary. The diary
is off by default. The application makes no network requests; diagnostics are shared only
when you copy and send them yourself.

## Requirements and current limits

- Windows 10 or 11 and **Windows PowerShell 5.1**. No administrator rights are needed.
  PowerShell 7 is refused. Managed devices may enforce a policy that prevents scripts running.
- Keep the folder writable: settings, backups and the locally compiled API cache live beside
  the scripts. The program does not install a service or change your global execution policy.
- Desktop snapshots remember the arrangement observed before a switch. Start with a correct
  Windows layout: the program cannot reconstruct positions lost before a snapshot existed.
  Explicit row editing remains available when you want an automatically centred row.
- DDC/CI, picture presets, HDR and wake-up time depend on the display, cable, dock and driver.
  The controls are optional. No monitor-capabilities-string probing is performed.
- Identical models use a connection fingerprint to distinguish instances. A different port
  may require selecting that connection again. Plain name patterns can intentionally match
  several displays; use the full label when you mean one identical panel.
- Real hardware validation covers the author's three-display desktop and manual UltraFine wake.
  Laptops, docks, multiple GPUs and identical panels remain experimental. Fresh Windows 10/11
  launch and the full accessibility matrix have not been validated; automated checks do not
  establish those results. See the [validation matrix](https://github.com/GentleMec/DeskModes/blob/main/docs/release-readiness.md).

Switch duration includes Windows reconfiguration and the panel waking up. Historical results
on the development desk were 1.3–6.9 seconds for actual switches and 0.3–0.5 seconds when
repeating the already active mode. These are measurements of that desk, not a speed guarantee.

## If something goes wrong

If the picture is usable, select **Back to the previous mode** or another available mode.
The automatic recovery restores the previous display set when none of the requested screens
attaches; it cannot repair a cable or a monitor that has physically left the bus.

For a bug report, open **Settings → About → Copy diagnostics**, or run **diagnostics.cmd**.
This creates a JSON snapshot of versions and display modes. It excludes settings, commands,
full device paths, process names and the diary. The Settings button uses the snapshot from
when the window opened; the command reads a fresh one. Review it before posting.

Attach the relevant switch from `last-run.log` if needed. Logs can contain your hook commands
and local paths; redact private information before posting them publicly.

If Displays.cmd appears to do nothing, run this in a terminal to see the error:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Displays.ps1
```

A company execution policy can override Bypass. Use `Get-ExecutionPolicy -List` to inspect it;
a policy managed by your organisation needs its administrator. More troubleshooting is in the
[reference](https://github.com/GentleMec/DeskModes/blob/main/docs/reference.md#when-something-goes-wrong).

## Update, move, roll back or remove

Before updating, choose **Exit** from the tray and make a copy of the entire folder.
Extract the new release over the existing folder. Release archives contain no personal JSON,
so your settings and diary remain. Start Displays.cmd and check your modes.

After moving the folder, open Behavior and enable **Start with Windows** again. The toggle
checks the shortcut's target; saving it enabled rebuilds the shortcut for the new location.
Pinned shortcuts must be recreated separately.

To roll back, exit the tray and restore the previous folder backup, including its settings.
To remove DeskModes, disable **Start with Windows**, save, exit the tray and delete the folder.
Remove any shortcuts you pinned yourself. Current Windows display/power choices are not undone.

Settings are written as a complete replacement. `settings.json.bak` holds the previous good
save; `settings.json.bad` preserves an unreadable file. A readable backup is recovered
automatically. Keep an external folder backup before an upgrade as well.

## For contributors

Read [AGENTS.md](https://github.com/GentleMec/DeskModes/blob/main/AGENTS.md), then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\check.ps1
```

The gates cover syntax, encoding, static analysis, translation keys and tests. Static analysis
is optional locally and required in CI. Tests use fake displays and temporary settings. The
[engineering diary](https://github.com/GentleMec/DeskModes/blob/main/docs/notes.md) explains the
hardware decisions and measured tradeoffs. [MIT license](https://github.com/GentleMec/DeskModes/blob/main/LICENSE).
