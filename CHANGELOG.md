# Changelog

User-visible changes. The version shown by DeskModes is defined in DisplayCore.ps1.
A release is dated only when its tag is ready to publish.

## 1.0.0 — not released yet

First public release candidate. Requires Windows 10/11 and Windows PowerShell 5.1.
Download the complete folder; the scripts and locally compiled API cache are unsigned.
The release ZIP's SHA256 verifies the downloaded bytes against the published archive.

### Display modes

- Preserve an already active All displays desktop; capture and restore physical monitor X/Y,
  primary, orientation (including flipped portrait), resolution and exact refresh rates.
  A refused restoration cannot silently replace the saved desktop with a damaged result.

- Named combinations, a mode for each display and an all-displays mode, available through
  tray menu, global hotkeys and CLI. Configure everything in the Settings window.
- Display membership, arrangement, primary display and exact driver refresh fractions applied
  in one CCD request where possible, with checks and repair when Windows refuses part of it.
- Back to the previous mode and recovery of the previous display set if no requested screen attaches.
- Window positions per display set, refresh-rate restoration and handling of wake/hotplug events.
  Automatic repairs wait while a full-screen application is active and retries are bounded.
- Identical monitor models use persistent connection labels, so enumeration order and an absent
  twin cannot redirect a shortcut or select both panels in a saved single-panel combination.
  Moving an identical panel to a different port may require selecting it again.

### Optional mode settings

- Brightness, contrast and remembered picture preset over DDC/CI; HDR per display; playback device.
- Commands around a switch and rules for a running process, idle time or the connected display set.
- Sleep/shutdown timers and a local activity diary, off by default, with an HTML report.

### Interface and support

- Left-click the tray icon to open Settings; right-click retains the switching menu.
- Your desk shows live Windows geometry and primary separately from explicit row editing.
  Identical displays have concise distinct titles without changing their saved identities.

- Resizable WPF Settings and system-themed tray menu. First-run Settings, Use Windows layout,
  display-identification badges, keyboard shortcuts and per-mode editors.
- English, Russian, Ukrainian, Spanish, French and German. Logs and command-line output stay English.
- Settings saved through complete file replacement with a previous-good backup and recovery.
- Startup status verifies the shortcut target; enable it again after moving the portable folder.
- Copy diagnostics from About or run diagnostics.cmd: a version/display snapshot without settings,
  hook commands, full device paths or diary data. Nothing is sent automatically.

### Release verification

- Syntax, BOM/CRLF, PSScriptAnalyzer, translation consistency and isolated behavior tests.
- Packaging refuses failed Git status checks and unversioned pending release notes.
- External hardware validation remains necessary; see docs/release-readiness.md in the repository.

Detailed development notes are retained in docs/development-history.md in the repository.
