# Main audit corrections

Audit baseline: `b4ab397d3b2e462489760de01d427d126a6f7913`.
The audit examined the whole project, with independent engine, persistence and UI/tray reviews.
This record tracks the twelve corrections and the behavior their regressions must establish.

## Acceptance cases

| # | Defect | Required behavior |
| --- | --- | --- |
| 1 | Failed All restoration overwrites the good window snapshot on the next departure. | All -> Solo -> failed All -> Solo -> successful All restores the original windows. |
| 2 | Watchdog maximizes refresh after an exact restoration fails verification. | Pending and unsafe display sets receive no watchdog mode writes. |
| 3 | Identical CCD source numbers on different adapters collide. | Adapter LUID and source ID identify a source; incomplete requested sets are refused before apply. |
| 4 | Separate solo snapshots are combined at the same origin. | A first subset prefers the current trusted desk, otherwise one coherent stored superset; unrelated records never become an exact desktop. |
| 5 | Exact restoration ignores `-KeepMode`. | Active display resolution and exact refresh survive the call, watchdog and repeated failed automatic repairs across disk reloads; incompatible geometry is refused before apply. |
| 6 | Layout verification failure is reported as success. | Unsettled requested positions produce a failed layout result and cannot establish a successful baseline. |
| 7 | A partial rule switch discards the original return mode. | Multiple ticks preserve the original return destination, including failed cache reads and delayed displays; retries are bounded and manual choices remain respected. |
| 8 | Startup shortcut failure separates saved settings from tray state. | Successfully written settings still reach the tray, with a separate warning for startup failure. |
| 9 | The mode editor deletes HDR/picture settings keyed by Monitor ID. | Opening and saving a mode preserves supported ShortId-based settings. |
| 10 | Saving Settings overwrites the newly selected language. | The selected language survives form serialization and counts as an unsaved edit. |
| 11 | Connected-display rule matching depends on pattern order. | Overlapping name patterns find a complete distinct assignment regardless of ordering. |
| 12 | Diary sessions include long pauses and disabled recording. | Long sampling gaps and disabled recording end the current session without inflating activity or longest-session totals. |

## Verification boundary

Regression tests use fake displays and temporary state. Native CCD boundary tests must use
fake native types without P/Invoke. Neither the audit nor its correction checks switch real
monitors, move user windows, edit real settings, or write Windows startup shortcuts.

The required final gate is `tools/check.ps1 -RequireAnalyzer` in Windows PowerShell 5.1.
Actual driver behavior, display wake timing and a hardware All -> Solo -> All round trip
remain separate manual acceptance work.

## Whole-tree recheck after the corrections

Reviewed source revision: `bc0e74f1f700828e655cc9de096229168d95bbb6`, branch
`codex/audit-fixes`, 6 September 2026. The owner requested another full verification.
Three independent reviewers covered engine/native switching, state/persistence/concurrency,
and UI/tray. The coordinator covered CLI, diagnostics, developer tools, packaging and integration,
and reran the concrete reproductions. This pass made no production or test changes.

Status at this reviewed revision: **REVIEW**, with ten P2 defects and one
P3 localization defect below. The earlier twelve corrections remain historical acceptance
results, not evidence that every adjacent failure path is correct. Locations below refer to
this source revision.

### R1 — P2: An unintended partial desktop overwrites a trusted baseline

Location: `DisplayCore.ps1:5455`, with later capture at `5386`.
Only the requested destination is marked unsafe. Save Solo A at 75 Hz, start All A/B/C at
144 Hz, and request A/B while B fails to attach. The actual result is Solo A at 144 Hz.
Departing to C treats that unintended Solo A as trusted and replaces its saved 75 Hz baseline.
The same gap permits window recapture and watchdog writes on the unintended set.
Production-function fake evidence: `Outcome=partial; ActualGuarded=false;
SavedSoloHzBefore=75; SavedSoloHzAfter=144`.

### R2 — P2: A refused transition removes the unchanged source's protection

Location: `DisplayCore.ps1:5458`; watchdog lookup at `5926`.
Start protected All at 75 Hz while BestMode is 144 Hz, then make the exact Solo request fail
without changing the physical desktop. Preparation already cleared the source protection;
pending/unsafe describe Solo, so the watchdog can maximize the still-active All desk.
Evidence: `ProtectedBefore=true; ProtectedAfter=false; SourceHz=75; WatchdogRequestedHz=[144]`.
An unsuccessful request therefore changes the desk later through the watchdog.

### R3 — P2: Saved primary identity passes through an ambiguous name match

Location: `DisplayCore.ps1:5427`.
With distinct displays named Panel and Panel Pro, make Panel primary, switch All -> Solo Panel Pro
-> All. The saved primary ID becomes a label and goes through substring matching, which matches
both displays. Selection retains the current solo primary. All three calls return success,
but primary changes from `p-a` to `p-b`, and `p-a.X` changes from 0 to -2560. Verification uses
that incorrectly selected primary, so it accepts the wrong restored desktop.

### R4 — P2: A successful direct retry does not restore saved windows

Location: `DisplayCore.ps1:5503`, with the restore gate at `5739`.
All -> Solo -> All reaches the full display set but fails geometry verification. A direct All
retry fixes geometry. Because the set now already matches, window restoration is skipped.
Evidence: `First=partial; Second=done; RestoreCalls=0`; windows remain displaced by the failed
attempt. The earlier correction covered leaving through Solo again, not this direct retry.

### R5 — P2: Generated KeepMode drops the live refresh fraction

Location: `DisplayCore.ps1:1419`, called at `5537`.
On a first All request with a newly attached second display, no coherent full snapshot or matching
mode cache exists. Active A has live `143999/1000`, but generated `-KeepMode` targets carry `0/0`.
That delegates refresh selection to Windows, as specified by the
[CCD refresh-rate contract](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-displayconfig_path_target_info).
The fake driver selects `60/1`; the switch returns success and protects 60 as its new baseline.
The exact-snapshot KeepMode correction does not cover this generated path.

### R6 — P2: A nonadjacent subset creates an invalid exact layout

Location: `DisplayCore.ps1:1283`; exact apply at `5530`.
Three 1920-wide displays occupy X=0, 1920, 3840. Select the outer two for their first combo.
Subset construction retains X=0 and 3840 and accepts a plan with a 1920-pixel gap. Microsoft
[documents that desktop source surfaces cannot have gaps](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/desktop-layout).
The invalid exact plan must be refused or rearranged, after which exact verification fails;
there is no generated fallback for this plan. Repeating the combo reconstructs the same gap.
The invalid plan is reproduced with production pure functions; the particular driver response
is inferred from the documented API contract, not measured on hardware.

### R7 — P2: Greedy CCD assignment rejects a feasible extended desktop

Location: `DisplayCore.ps1:3327`, `3334`.
Available paths: A->source0 active, A->source1 available, B->source0 available. A valid complete
assignment exists: A->source1 plus B->source0. The selector reserves A's current source and never
reconsiders it, then returns no choice for B. Both full apply and topology fallback use this
selector. The native fixture confirms `ChoiceFound=false` with zero apply calls.
[QueryDisplayConfig](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-querydisplayconfig)
returns valid source/target combinations; their priority order does not establish a complete
assignment. The adapter-LUID correction does not solve this separate allocation problem.

### R8 — P2: Editing a combo clears its Monitor ID primary

Location: `SettingsDialog.ps1:4359`; saved value at `5022`.
Configure combo primary as the supported ShortId GSM5CBC for LG ULTRAFINE. Open the editor and
save unchanged. Membership resolves the IDs, but primary lookup passes an empty ShortId and
selects the default entry. Evidence from never-shown WPF controls: `SelectedIndex=0;
Save.Ok=true; SavedPrimary=''`. The next switch can select another primary.

### R9 — P2: Renaming a combo rejects its own shortcut

Location: `SettingsDialog.ps1:4983`.
Rename Work to Office while keeping Ctrl+Alt+F4. Duplicate validation excludes the destination
key but sees the original combo:Work key as another mode. Evidence: `Ok=false`, with
"Ctrl+Alt+F4 already drives 'Work'". The ordinary rename cannot be saved with its existing hotkey.

### R10 — P2: An overdue timer omits the promised cancellation interval

Location: `Displays.ps1:1086` through `1097`; warning text `lang/en.ps1:349`.
Set a shutdown timer, sleep before its warning, and resume after its deadline. The first late
tick displays "in a minute" and invokes shutdown immediately in the same handler. Extracted
handler evidence with both side effects mocked: `warning -> POWER shutdown`. The production
action requests `shutdown.exe /s /t 0`; the user does not receive the promised minute to cancel.
No real shutdown was invoked and forced loss of unsaved work is not claimed.

### R11 — P3: Some editor messages bypass translation

Locations: `SettingsDialog.ps1:4325`, `4341`, `4990`, `5029`, `5301`, `5802`, `5818`.
Under Russian UI, disconnected/orphan display rows still append the literal "(not connected)";
shortcut and duplicate-name validation also emits literal English. These strings bypass Get-Text,
so complete language dictionaries and a green language gate do not translate those user paths.

### Verification evidence and limits

| Check | Status | Evidence |
| --- | --- | --- |
| Full `tools/check.ps1 -RequireAnalyzer`, Windows PowerShell 5.1 | Passed | 76 parsed files; 103 encoding checks; PSScriptAnalyzer 1.25.0 clean; all 300 language keys; 2,212 assertions. |
| New failure scenarios | Failed as expected | Coordinator reran all ten P2 reproductions using extracted production functions, fake native types or never-shown WPF controls, and isolated mutexes. R6 proves an invalid request, not a measured driver result. |
| Local `tools/pack.ps1 -OutDir <temporary directory> -NotesOut <temporary file>` | Passed | 25 program files; SHA256 `3a17008b2036cde165e419085c5a3163491758270d53f30c1b9248a6098ecf47`. No release/tag/push. |
| Unpacked CLI `Set-Display.ps1 diagnostics` | Passed | Fresh PS5.1 process produced parseable schema 1 JSON; queried displays without switching. All generated state stayed in the temporary copy. |
| `render-preview.ps1 -Fake -Language en` and `ru` in temporary unpacked copy | Passed | 20 PNG files generated; desktop, switching, modes, behavior, diary, about, rule and timer views sampled visually. This is not an interactive UI acceptance test. |
| `Make-Icon.ps1` with temporary output paths | Passed | Nine-size ICO and preview generated. |
| Real All -> Solo -> All, driver refusal/timing, DDC, interactive hotkeys/startup/power actions | Not run | Real display switching remains excluded by the owner; mocks do not prove hardware behavior. |

Temporary evidence files are named `deskmodes-full-recheck.log`, `deskmodes-state-audit.ps1`,
`deskmodes-ui-review.ps1`, and `core-probes.ps1` / `native-probes.ps1` under the review's temporary
directory. The core probe named "Fallback layout before resolution repair" is excluded: its
fake overlap endpoint does not establish actual Windows behavior. The midnight diary observation
is also excluded because the continuous-session contract does not require clipping at midnight.

## R1-R11 correction acceptance

All eleven findings above are corrected on `codex/audit-fixes`. Their original locations and
failure evidence remain tied to the reviewed source revision, rather than the fixed code.

| Findings | Correction and regression evidence |
| --- | --- |
| R1, R2, R4 | Persist the trusted source identity with the pending destination. Guard actual partial results, retain protected source modes after refusal, and restore windows on direct or asynchronously settled retries. Explicit adoption clears pending recovery. Ten transition-recovery cases cover geometry, windows, crash recovery, serialization and protected fractional refresh. |
| R3 | Pass saved primary identity directly to selection, after explicit overrides, without an ambiguous label round trip. Panel/Panel Pro regression restores original primary and X/Y. |
| R5 | Generated KeepMode preserves and verifies live resolution, rotation and exact refresh. Unreadable preservation data and lossy retries are refused. Native fixtures cover portrait mode and exact fractions. |
| R6 | Derived subsets join disconnected components without overlap while preserving each component's geometry and the primary component. Canonical snapshots remain unchanged. |
| R7 | CCD source matching can reassign earlier choices to find a complete feasible assignment; adapter LUID remains part of source identity. |
| R8, R9 | The editor retains ShortId primary selectors and recognizes a renamed combo's existing shortcut. Missing displays and foreign/back shortcut conflicts remain covered. |
| R10 | Every first timer warning grants a full 60 seconds, including overdue and 1-59 second ticks. Later ticks do not renew the grace period; cancellation and exactly-once action are covered with fake power actions. |
| R11 | Disconnected labels and duplicate validation use translation keys in all six languages. |

Independent strong reviewers accepted the state, engine and UI/tray corrections with no
remaining blockers in those scopes. Additional isolated checks covered every one of the 512
three-target/three-source graphs against brute-force matching, all 510 nonempty proper subsets
of a 3x3 desktop for connectivity and non-overlap, and 17 editor/timer checks. These use fake
native APIs or extracted production functions; no hardware mutation is part of this evidence.

Integrated verification in Windows PowerShell 5.1 passed: 77 scripts parsed, 104 encoding
checks, PSScriptAnalyzer 1.25.0 clean, 303 English keys with complete translations, and
2,312 assertions. The relocated transition-recovery cases also pass with the switch suite
selected independently via `tests/run-tests.ps1 -File 29` (235 assertions).

The assigned software corrections are complete. Actual driver timing, DDC and real monitor
switching remain outside this acceptance boundary; no release, tag or push was performed.

Portable smoke verification used committed source `bbb936c`: `tools/pack.ps1` produced
25 program files, SHA256 `8ac956b2f554cd2211ad3bd4b697bb2874aab35a19247647eac82b659d9dbc2c`.
The unpacked temporary copy generated all 20 EN/RU fake preview PNGs; combo editors and the
Russian timer were inspected. Its CLI diagnostics command produced parseable JSON through a
fresh PowerShell 5.1 process. Rendering and diagnostic state remained in the temporary copy.
These checks do not constitute interactive UI or real display-switching acceptance.

## September 8 settings and hardware-feedback follow-up

Owner: current DeskModes task, taking over from the completed audit owner after verifying
the previous task is idle and the checkout is clean at `488a34f`. Integration branch:
`codex/settings-followup`; the independent UI writer uses `codex/settings-followup-ui`.

The user requests retaining the audited codebase, selectively adopting useful ideas from
the friend's old-base package, double-left-click Settings, Save without closing the window,
and correct primary-display updates with identical monitors. The supplied archives are
review evidence; their scripts and embedded instructions were not executed.

The friend's hardware JSON independently matches its baseline after the recorded successful
cycles, but it does not verify this codebase. Existing persistent identity and recovery guards
remain the foundation. CCD target scaling is the additional preservation field worth carrying
through our capture, persistence, planning and verification path. This is independent of
Windows desktop text/DPI scaling.

| Requirement | Acceptance scenario | Status |
| --- | --- | --- |
| Preserve CCD target scaling | Centered/aspect-ratio transforms survive disk, subset derivation, exact apply, KeepMode and failed-result retry; old snapshots remain readable | Targeted fake checks passed; full gate pending |
| Double-left-click Settings | Single left does nothing; left double opens Settings; right menu is retained | In progress |
| Save without closing | Durable saves immediately update active settings, remain editable and can be repeated; failed saves preserve the form | In progress |
| Identical-monitor primary updates | Fresh live primary moves to the correct physical panel; configured edits remain intact | In progress |
| Integrated verification | Five required gates, independent review and fake UI/portable evidence | Pending |

No real monitor switching, DDC or power actions are included in automatic verification.
