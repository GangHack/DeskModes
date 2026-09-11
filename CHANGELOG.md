# Changelog

User-visible changes. The version shown by DeskModes is defined in DisplayCore.ps1.
A release is dated only when its tag is ready to publish.

## 1.0.1 — not released yet

- Dismiss the tray menu on an outside click or Escape even when Windows did not activate it.
- Label the configured taskbar as a choice for future switches, including when its display is off.

- Leave the display set Windows activated at startup in place by default. Restoring the last
  chosen mode remains available as an explicit Behavior setting.
- Keep the tray menu inside the current monitor's working area, with scrolling when its rows
  exceed the available height, so bottom commands no longer hide behind the taskbar.
- Let WPF windows follow each monitor's Windows scale when moving between displays or switching
  the active desk, instead of retaining the previous scale under Windows PowerShell 5.1.
- Preserve the physical meaning of imported `id:` display selectors in groups, primary choices,
  layout, rules and per-monitor settings. Exact paths never fall back to a shared model name.
- Migrate imported solo captions containing model, ShortId and connection token to the matching
  physical mode, retaining shortcuts and other mode references. Ambiguities and existing bindings
  are preserved for explicit resolution rather than silently overwritten.
- Identify this compatibility fix as 1.0.1 in the application, diagnostics and portable archive.

## 1.0.0 — not released yet

First public release candidate. Requires Windows 10/11 and Windows PowerShell 5.1.
Download the complete folder; the scripts and locally compiled API cache are unsigned.
The release ZIP's SHA256 verifies the downloaded bytes against the published archive.

### Display modes

- Preserve an already active All displays desktop; capture and restore physical monitor X/Y,
  primary, orientation (including flipped portrait), resolution, standard CCD target scaling
  and exact refresh rates.
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

- Double-left-click the tray icon to open Settings; right-click retains the switching menu.
- Save applies settings while keeping the window open for further edits. Language changes
  automatically reopen the window on the same page with the selected translation.
- Your desk shows live Windows geometry and primary separately from explicit row editing.
  Identical displays have concise distinct titles without changing their saved identities.

- Resizable WPF Settings and system-themed tray menu. First-run Settings, Use Windows layout,
  display-identification badges, keyboard shortcuts and per-mode editors.
- English, Russian, Ukrainian, Spanish, French and German. Logs and command-line output stay English.
- Settings saved through complete file replacement with a previous-good backup and recovery.
- Startup status verifies the shortcut target; enable it again after moving the portable folder.
- Copy diagnostics from About or run diagnostics.cmd: a version/display snapshot without settings,
  hook commands, full device paths or diary data. Nothing is sent automatically.

### Audit corrections

- Keep the last good window positions after a failed desktop restoration, and leave pending
  or unsafe display sets untouched by the refresh watchdog.
- Distinguish CCD sources across video adapters and refuse incomplete display requests.
  Derive a new subset from one coherent desktop snapshot, never unrelated solo coordinates.
- Honor `-KeepMode` during exact restoration and protect its applied modes from the watchdog.
  Report failed layout verification instead of accepting the wrong arrangement as success.
- Preserve a rule's original return mode after a partial switch, and match overlapping
  connected-display patterns independently of their order.
- Save the selected interface language and preserve Monitor-ID-based HDR and picture settings
  when a mode editor is saved. A startup shortcut failure no longer strands committed settings
  outside the running tray.
- End diary sessions across long sampling gaps and disabled recording instead of counting
  the intervening hours as continuous work.

- Protect the actual partial desktop and the unchanged source after a failed switch; direct
  restoration retries bring saved windows back, including when the driver settles asynchronously.
- Restore primary by physical identity, connect nonadjacent subsets without gaps, and find
  complete CCD source assignments when an active source must move to another display.
- Preserve and verify live resolution, rotation and exact refresh on generated `-KeepMode` plans.
- Keep Monitor-ID primary settings and existing shortcuts when editing or renaming combinations.
  Translate disconnected labels and duplicate validation in every supported language.
- Give a full cancellation minute after the first power-timer warning, including after resume.

### Release verification

- Syntax, BOM/CRLF, PSScriptAnalyzer, translation consistency and isolated behavior tests.
- Packaging refuses failed Git status checks and unversioned pending release notes.
- External hardware validation remains necessary; see docs/release-readiness.md in the repository.

Detailed development notes are retained in docs/development-history.md in the repository.
