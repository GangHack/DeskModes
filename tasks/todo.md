# Current desktop apply and clear settings

Owner: GPT-5.6 Luna. Parent performs independent read-only review before completion.

- [x] Implement guarded apply-current-desktop behavior and fake-hardware regressions.
- [x] Add Save and apply action, localized explanations/current mode override hint, and honest result handling.
- [x] Sort live Displays rows and refresh all live views after successful apply.
- [x] Render localized previews and run tools/check.ps1; record exact results.
- [x] Parent review of hardware boundary; address findings and repeat necessary verification.
- [x] Replace the duplicate desk Apply button with a localized footer Save/apply action and keyboard-accessible options menu.
- [x] Preserve desk apply intent only for direct edits, including stable identity refreshes and edit/undo baselines.

No commit, publication, live hardware test, settings mutation or tray restart is part of implementation verification.

Verification recorded during implementation:

- `tests/run-tests.ps1 -File 29`: 271 assertions passed, including exact active-set CCD, pending/unsafe recovery, changed-desktop recovery instructions and readiness-signalled mutex coverage.
- `tests/run-tests.ps1 -File 10`: 374 assertions passed, including footer dispatch/menu wiring, Save-only and retry/success states, stable identity refreshes, edit/undo baselines, save-first failure wording, persistence wording, mode precedence hint and live row ordering.
- `tools/check.ps1`: all parse, encoding, language and test gates passed; 2,593 assertions passed. PSScriptAnalyzer was unavailable and skipped with the documented warning.
- `render-preview.ps1 -Fake -Language en`, `-Language uk` and `-Language ru`: all ten preview images written successfully; English, Ukrainian and Russian desk previews inspected for clipping and layout.

Parent final verification: inspected the hardware boundary and localized footer previews, resolved the persisted-unverified recovery wording, updated the language-rebuild test fixture for desk action state, and reran tools/check.ps1 on the final shared snapshot: exit 0, 2,593 assertions passed. PSScriptAnalyzer was unavailable and skipped. No live hardware switching was performed.
