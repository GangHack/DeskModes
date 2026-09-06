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
