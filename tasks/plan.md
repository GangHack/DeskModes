# Preserve the desktop at startup

## Objective and evidence

DeskModes should leave the current display set in place at startup by default. The user starts on different monitors and does not want a fixed startup monitor. On September 10 at 10:54:26 the log records startup restoration of `solo:LG ULTRAFINE`, selected the previous evening. The user reports that ASUS was showing the desktop and the LG was switched off at its button; the restoration disabled ASUS. Windows reported a successful configuration, which does not establish that a panel was showing a picture.

## Decisions

- Reuse `restoreLastMode`; do not introduce a new setting or startup heuristic. Its default becomes false. Missing settings and a missing key use that default. Explicit persisted true and false remain respected.
- Align the Settings checkbox fallback with the engine default. Explain that the option applies at application startup, can replace the currently active screens, and is off by default. Update English, Russian and Ukrainian UI text; inspect other translations for conflicting claims and update as needed.
- Preserve the existing opt-in startup path and its same-session, manual-choice and unavailable-mode guards. Do not turn those tests into vacuous passes by letting them run with restoration disabled.
- For this user's existing local settings, explicitly save `restoreLastMode = false` through the supported settings load/save functions, preserving every other value. This is a local preference change authorized by this request, not a migration imposed on all existing users. Do this after automated verification, outside tests. Confirm the persisted diff is limited to that preference (serialization formatting may differ). Do not restart the tray or switch displays to activate it: the preference will be read on the next launch.
- Sleep, hotplug and process rules remain separate explicitly configured behaviors. Do not promise that disabling startup restoration disables all automatic switching. No changes to CCD, DDC, display power detection, timers or hardware switching are needed.
- Preserve last-mode history and desktop snapshots. Do not adopt Windows' boot state as a new manual selection or rewrite saved layouts.
- Keep the existing unrelated working-tree edits intact. There is one implementation writer. No commit, release, installation or real display test is required by this request.

## Ordered work

See `tasks/todo.md` for acceptance and completion tracking.

1. Change the default, loading/UI fallback and example configuration with meaningful regression tests.
2. Clarify user-facing text and documentation, record the incident rationale and keep planning files out of release archives if they are tracked.
3. Run the project gates in Windows PowerShell 5.1, apply the local preference and report verification. The planning owner reviews the resulting diff independently.

## Required regression coverage

- No settings file, a settings object missing the key, and fresh defaults all disable startup restoration.
- Explicit true and false survive loading and save/load round trips.
- With defaults, active ASUS plus an inactive but enumerated LG and a previous-session LG selection causes no startup mode invocation. This is deliberately stronger than checking that the target is disconnected.
- Repeat the safe-start scenario with LG as the active screen so the behavior is not tied to ASUS. Include a current multi-monitor set.
- Retain meaningful opt-in tests: a previous-session mode restores; same-session restart and a manual choice prevent restoration; unavailable/deleted modes skip; a matching desk still takes the silent layout-check path.
- The Settings checkbox is unchecked for defaults and for a missing key, checked for explicit true, and preserves a chosen value through UI reading.

## Verification and limits

Use the existing test runner and `tools/check.ps1` in Windows PowerShell 5.1. The complete five-gate command is required; report analyzer availability honestly. Tests must use temporary settings/log/state and fakes, never real display mutations. Inspect localized layout if changed hints affect sizing. No reboot or hardware switching is part of automated verification; the next ordinary boot provides the final physical confirmation.

## Initial working-tree context

Existing uncommitted edits are present in `Displays.ps1`, `SettingsDialog.ps1`, `CHANGELOG.md`, `docs/notes.md`, and test cases 09 and 10. They concern tray placement and Settings behavior. Preserve them exactly outside the minimal intersections needed here. Local `settings.json` currently has startup restore enabled, one process rule and separate resume/hotplug preferences; preserve those other preferences.
