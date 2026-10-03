# Changelog

User-visible changes. The version shown by DeskModes is defined in DisplayCore.ps1.
A release is dated only when its tag is ready to publish.

## Unreleased

## 1.0.2 — 2026-10-04

### Added

- Enable the optional Support DeskModes button in About, linking to the author's Ko-fi page.
  GitHub and the README now link to the same voluntary support page.

### Changed

- Update project, help and feedback links to the renamed GentleMec/DeskModes repository.

No display-switching, rules, settings or diagnostic behavior changed from 1.0.1.
The existing hardware validation limits still apply. Start with Displays.cmd and use
the GitHub Bug report or Suggest an improvement forms for feedback.

## 1.0.1 — 2026-10-02

First public release. Requires Windows 10/11 and Windows PowerShell 5.1.
Extract the complete ZIP into a writable folder and start Displays.cmd.
The scripts and locally compiled API cache are unsigned. The ZIP's SHA256 verifies
the downloaded bytes against the published archive.

Validation covers 2,850 automated assertions, Windows CI with the required analyzer,
exact mode round trips on the author's three-display desktop, manual UltraFine power-on
and an isolated portable overlay. Timed display power-off is accepted by the owner.
Fresh Windows 10/11 launch, whole-computer suspend/resume and the full native UI/accessibility
matrix remain unverified. Laptop, dock, multiple-GPU and identical-panel setups are experimental.
See the [validation matrix](https://github.com/GentleMec/DeskModes/blob/main/docs/release-readiness.md)
for the recorded scope. The scripts and native cache remain unsigned.

### Latest improvements

- Wake selected panels that report standby/off over DDC/CI when a mode is chosen manually,
  including repeated All. Read back power-on; leave automatic rules and unsupported panels alone.

- Describe display availability without claiming physical power state: unused displays say
  **not in use**, and displays Windows cannot see say **not detected**. Settings explains that
  a Windows desktop status does not confirm whether the panel is awake.
- Let one rule watch several games or programs. It keeps the chosen mode while any of them
  is running and returns after the last one closes. Add programs in the rule editor; existing
  single-program rules keep working. The rules list now shows the default return mode too.
- Stop the tray menu drawing a mode's shortcut on top of its name. A mode whose display is
  unplugged is disabled on purpose and still bound to a key, and both halves of its row were
  being painted into the same place.
- Replace the footer's split Save button with one **Save** that only ever writes settings.json,
  on every page. Applying a desk arrangement to the screens is a real change to somebody's
  displays, so it has an explicit button of its own under the cards it applies, dead until there
  is something to apply — and Enter can never reach it.
- Add **Forget** beside a display Windows cannot see, for a monitor that was tried once and then
  sold or lent. It used to sit in every list for ninety days, because "not connected" is also
  what a monitor that is merely switched off looks like. Plugging it back in returns it.

- Keep background rules from turning off every active display while all displays in their destination
  are still inactive. The rule waits until one destination display is visibly active instead.
- Open a short four-screen introduction on the first run, ahead of the Settings window: what a
  mode is, that the program lives in the tray and how its menu opens, the shortcuts this run just
  assigned listed by name, and what happens when a display does not come up. It can be skipped
  from any screen and reopens from the tray menu and from Settings → About.
- Offer the interface language in the head of that introduction, so it can be chosen before
  anything else is read. It follows Windows until it is changed, here or later in Behavior, and
  the tour reopens on the same screen in the language picked.
- Group the tour and a link to the full reference into a Help section at the top of the About
  page, above the version and the diagnostics.
- Call a user-made set of displays a **mode** everywhere it is read, instead of alternating
  between "mode" and "combination" between the page, the button and the editor's own heading.
- Fold the configured desk away on **Your desk** until it means something, and say under its
  heading which of the two states the page is in: switching keeps the Windows layout drawn above
  it, or it uses this order and this taskbar display. Opening or closing it changes no setting.
- Name the mode the desk is in in the tray icon's tooltip, which used to carry the program's
  name and nothing else.
- Stop a mode's row cutting a word in half: three settings are named in full and the rest are
  counted, with the whole list in the row's tooltip. The displays in that row are shortened the
  way their titles already were, so two identical panels no longer fill it with a connection
  fingerprint.
- Answer a plain Save inside the window — settings written, displays untouched — rather than
  only in a notification behind it.
- Open Behavior from **Statistics (diary is off)**, where the switch that fills it lives, instead
  of explaining the emptiness in a notification and leaving the person to find the switch.
- Restore exact portrait display layouts with their CCD source dimensions instead of reusing the
  rotated desktop bounds, which Windows rejects when returning from a single-display mode.
- Keep separate window snapshots for different resolutions of the same display set and move an
  inaccessible title bar into the current working area before restoring the saved window state.

- Paint the tray menu on the first click after startup by clearing WinForms' empty-menu
  cancellation after its rows have been built.

- Highlight a configured taskbar display only when its primary override is enabled; inactive
  legacy choices no longer look like a request to move the taskbar.

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
- Save writes settings while keeping the window open for further edits. Applying the configured
  arrangement to active displays uses the separate button on Your desk. Language changes
  automatically reopen the window on the same page with the selected translation.
- Your desk shows live Windows geometry and primary separately from explicit row editing.
  Identical displays have concise distinct titles without changing their saved identities.

- Resizable WPF Settings and system-themed tray menu. First steps tour, Use Windows layout,
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
