# Startup preservation implementation

## Task 1: Default to the current desktop

Owner: Sol. Dependencies: none. Scope: engine/defaults, Settings fallback, example settings and focused tests.

- [x] Set the default to false and preserve explicit stored values.
- [x] Make the checkbox reflect default/missing/explicit settings correctly.
- [x] Add the regression matrix from the plan and explicitly enable restore in opt-in tests.

Verification: run the relevant existing settings, startup and Settings-window cases; demonstrate the new default regression fails before the fix and passes after it.

## Task 2: Explain the startup choice

Owner: Sol. Dependencies: Task 1. Scope: localization, README, changelog, engineering notes and release exclusions if needed.

- [x] Explain startup restoration and its effect on current screens in relevant UI translations and documentation.
- [x] Record the behavior change without changing release version or date.
- [x] Keep planning artifacts out of shipped program files; preserve unrelated edits.

Verification: inspect text against runtime behavior, run language gate, and inspect localized layout when sizing is affected.

## Task 3: Verify and apply the user's preference

Owner: Sol; independent review by planning owner. Dependencies: Tasks 1 and 2.

- [x] Run all five gates using `tools/check.ps1` in Windows PowerShell 5.1.
- [x] Save only the user's startup restoration preference as false through supported settings functions and confirm other values are preserved.
- [x] Review the final diff and report tests, runtime preference and outstanding hardware confirmation separately.

Verification: full check output, persisted-settings comparison and independent diff review. Do not switch real displays, restart the tray, reboot, commit or publish.
