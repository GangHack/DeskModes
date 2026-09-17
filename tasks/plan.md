# Make current desktop changes explicit

## Objective
Make DeskModes distinguish current Windows state, saved defaults for future switches, and per-mode overrides. Let the user save and immediately apply desk choices without enabling an inactive display. Implementation owner: GPT-5.6 Luna; parent reviews the hardware-affecting boundary independently.

## User flow
- Keep Save as save-only. Add a distinct localized Save and apply to current desktop action near the configured desk controls or footer, with a short explanation that only currently active displays are affected.
- Applying first validates and saves. On save failure do not touch Windows. On apply failure state clearly that settings were saved but the desktop was not applied; allow retry without pretending success.
- A successful apply refreshes the live canvas, Displays table and tray from fresh Windows state. Save-only must not falsify their primary markers.
- Explain that the configured taskbar is the general default for future mode switches; an explicit taskbar in a mode wins during normal mode switching. Surface a concise localized warning naming the current mode when it overrides the general choice.
- The explicit apply-now action applies the desk choices to the active desktop (including a manually selected primary), regardless of the current mode's primary; leave the mode's stored preferences unchanged. Explain this in the relevant hint if needed.
- If the selected primary is inactive or disconnected, refuse apply-now with an actionable message. Never silently select a different display or enable the selected inactive one. Saving for future use remains possible.
- Sort Displays rows by actual active Windows X then Y, with stable identity tie-break; inactive remembered displays follow in configured order, then stable label/identity order. If geometry is missing, use a deterministic fallback. This is a live-state table, not a preview of unsaved order.

## Safety and architecture
- Read AGENTS.md. Preserve all existing uncommitted fixes. One writer in this checkout; parent is read-only during implementation. Do not commit, publish, restart the running tray, change live settings or run real monitor switching tests.
- Reuse existing CCD, exact snapshots, settings accessors and New-SwitchResult outcome semantics. No dependencies, test-only production seams, or fallback to legacy display enable APIs.
- Apply-now must capture and recheck the active physical device set under Local\DeskModesSwitch. Preserve that exact set: All and a cached named mode are not valid substitutes. Preserve resolution, exact refresh fraction and rotation. Preserve physical coordinates unless the user explicitly requested the configured layout order. Respect snapshot pending/verification rules and honest failure outcomes.
- Avoid triggering unrelated mode hooks, HDR/brightness/picture changes, last-mode history or automatic topology restore merely to move the taskbar. If safely sharing the existing switch path requires a narrowly scoped production option, keep it explicit and tested. Do not persist a temporary mode or replace live settings with fake settings.
- Avoid application startup/discovery/hotplug/rule changes. No real hardware mutations during verification.
- UTF-8 BOM + CRLF for all ps1; English code/comments/docs; all user-facing text in lang/. Translate changed UI in every existing language. Keep buttons responsive with MinWidth.

## Acceptance evidence
1. Regression tests with mocked hardware: active LG UltraFine + LG UltraGear and inactive ASUS; apply selects UltraFine, only the original two active physical IDs reach CCD, modes/rotation preserved; inactive primary refused; mutex busy/save failure/apply failure distinct; ordinary Save does not call hardware; no unrelated hook/history effects.
2. UI tests: action wiring, unsaved edits survive a failed apply, success refreshes live primary/table/tray; per-mode precedence hint; active rows left-to-right with deterministic inactive placement.
3. Render English and Ukrainian/Russian settings previews with fakes; inspect action labels, hint and table layout.
4. Run powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/check.ps1, inspect all gates. Parent independently reviews current-desktop hardware path and acceptance evidence. If a correction is made, rerun applicable tests and full gates.

## Work order
See tasks/todo.md. Finish implementation and verification in the same delegated task; update the checklist and report limitations honestly.