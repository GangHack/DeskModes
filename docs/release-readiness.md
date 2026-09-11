# Release readiness

Status on 11 September 2026: **local candidate preparation, not a published release**.
The application reports 1.0.1. Its CHANGELOG heading intentionally has no release date;
`pack.ps1 -ExpectVersion 1.0.1` refuses publication until a dated section is committed.

## Remaining acceptance for the current candidate

The integrated candidate includes imported physical-selector compatibility, opt-in startup
restoration, per-monitor WPF DPI handling, tray placement/dismissal and saved taskbar labels.
Earlier hardware evidence applies only to its recorded source, not automatically to this candidate.

Before tagging:

- Repeat All -> solo/subset -> All on the author's desk and the external three-monitor setup.
  Compare physical primary, X/Y, rotation, resolution, refresh and restored window reachability.
  Include an unavailable panel and confirm recovery leaves a usable desktop.
- Start with a different visible panel than the last chosen mode. Defaults must preserve the
  current desktop. Existing explicit restoreLastMode=true remains an intentional opt-in.
- Move Settings between the 4K/2K screens, switch the active desk, and test narrow RU/UK windows.
  Check tray scrolling, Exit, outside-click/Escape dismissal and the timer submenu on the real tray.
- Test the exact ZIP on a clean Windows installation and overlay it on a backed-up installation.
  Record Windows warnings, first launch, imported bindings, settings preservation and rollback.
- Record the latest GitHub Actions result for the exact candidate commit. The old remote run
  from September 6 is not acceptance for these changes.
- Before the first public release, consolidate the still-unreleased 1.0.0 feature notes into the
  chosen first-release section. The packer exports only the current version's section; publishing
  1.0.1 as written would describe only the follow-up fixes rather than the complete first release.
- The GitHub repository is currently private. Decide public distribution and verify README,
  screenshot, download and issue links as an unauthenticated visitor before announcing it.

The first release date and tag remain unset until applicable hardware acceptance is recorded.
Untested laptop, dock and multi-GPU configurations must remain explicitly experimental.

## What the automated checks establish

`powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\check.ps1 -RequireAnalyzer`

The local Windows PowerShell 5.1 run passes syntax, BOM/CRLF, PSScriptAnalyzer 1.25.0,
translation keys and the regression suite. Every supported interface language covers
the complete English key set. Tests redirect machine files and shadow hardware calls; no physical
display switching is part of this result. The analyzer is a development tool, not a
runtime dependency.

New regressions cover stable identical-display keys across enumeration and disappearance,
exact combination membership, refusal of ambiguous primary/CLI choices, unambiguous old
mode-reference migration with and without hotkeys, damaged-settings recovery, locked-file
save failure, stale startup shortcut targets, packaging failure and diagnostic privacy.
A missing friendly monitor name must not leak its device path through the diagnostic model field.

Desktop restoration regressions cover exact positions, flipped rotation, rational refresh rates,
same-set preservation, first subset derivation, failed restores and repeated-failure rollback.
The current Windows arrangement is shown separately from explicit switching customization.
English and Russian offscreen previews verify the portrait geometry, primary marker and full
duplicate-panel captions. These tests do not establish a successful real driver round-trip.

English screenshots are refreshed in `docs/images/`. Nine offscreen WPF windows were
rendered for English, Russian, German and French. Desk and About pages were inspected for
readability at the renderer's dimensions. This does not validate keyboard navigation,
actual tray interactions, small-screen scrolling, every DPI or dark/high-contrast themes.

## Hardware and first-run matrix

Pending means no result has been recorded for this candidate. It is not a passing claim.
Record the Windows build, GPU and driver, monitor models, cable/dock, scale and source
commit with each result. Keep serial numbers, private commands and full paths out of
public reports.

| Scenario | Procedure and pass condition | Candidate status |
| --- | --- | --- |
| Fresh Windows 10 | Download ZIP in a browser; extract to a writable folder; start Displays.cmd. Record actual warnings, first compilation time and first Settings window. | Pending |
| Fresh Windows 11 | Same procedure, recording Smart App Control state without changing it for the test. A refused run must have actionable troubleshooting. | Pending |
| One monitor | Start, configure, repeat its mode, open/close Settings and exit. No phantom monitors or failure loop. | Pending |
| Two different monitors | Alternate solo, combination and all; verify membership, primary, positions and refresh rates. | Pending |
| Exact three-display restoration | Two identical landscape panels plus portrait-flipped third panel at asymmetric Y. Repeat All; cycle subset/solo to All; restart in subset. Compare physical primary, every X/Y, rotation, resolution and rational Hz. | Earlier test archive reproduced destructive layout and rotation changes; fixed candidate needs hardware retest |
| Two identical panels | Save distinct hotkeys and a one-panel combination. Reconnect in a different enumeration order; remove either panel. The remaining one keeps its key and never substitutes for the absent selection. | Pending |
| Laptop and external display | Repeat with lid open/closed, sleep/wake and reconnect. Record the configured Windows lid action; use a visible recovery path. | Pending |
| Dock / multiple GPUs | Record exact adapters, dock, ports and driver; test unplug/replug and wake. | Pending; experimental |
| Optional display controls | Opt into brightness/contrast/picture/HDR only where supported. Verify restoration and bounded failure; never query the capabilities string. | Pending |
| Rules and Back | Test process/idle/plug trigger, return, unavailable target, bounded retry and manual override. | Pending |
| Small screen and accessibility | 100/150/200% scale, short working area, long translations, keyboard and screen reader, light/dark/high contrast. All actions must remain reachable. | Pending |
| Portable update | Back up the folder, exit, overlay the new program files and restart. Settings, hooks, rules and diary remain intact. | Pending on real installation |
| Move, rollback, removal | Move folder, recreate startup target, restore the saved folder, disable startup, exit and remove. No orphaned enabled startup indicator. | Logic covered; end-to-end pending |
| Read-only location | Start from a folder with no write access. Record the actionable error; do not solve by running elevated. | Pending |

Use the existing hardware checklist in a source checkout:

```powershell
.\tests\live.ps1 -ReadOnly
# The following switches real displays and must be watched at the desk:
.\tests\live.ps1
```

A source checkout contains this script; the user ZIP intentionally does not contain tests.
The read-only path still loads the engine and may create its cache/log beside the program.
Run it in an isolated candidate folder when protecting an existing installation.

## Evidence to attach to each run

```text
Date and source commit:
ZIP SHA256 and download location:
Windows build / PowerShell:
GPU / driver / monitor models / cable or dock / DPI:
Scenario and prior Windows configuration:
Expected result:
Observed result, duration and repetition count:
Diagnostic snapshot and redacted relevant log:
Recovery performed and final desk state:
Pass / fail / not tested:
```

For diagnostics use `diagnostics.cmd` or Settings -> About -> Copy diagnostics. The UI
copies the snapshot captured when Settings opened; the CLI reads a fresh state. Neither
sends anything. Logs are separate and can include paths and hook commands.

## Candidate and release procedure

1. Run all five gates, with the required analyzer. Commit the exact changes and verify
   that GitHub Actions succeeds for that commit as well.
2. Build a local candidate with `tools/pack.ps1 -OutDir <candidate-folder> -NotesOut <notes-file>`.
   The folder is a candidate even though the archive name includes 1.0.1. Check archive
   membership, SHA256, notes, script syntax and CLI startup from an isolated extraction.
3. Complete the applicable hardware rows. Fix failures and repeat affected scenarios plus
   the full automated check. State any deliberately untested configurations as experimental.
4. Set the actual date in CHANGELOG, commit, check and tag `v1.0.1` on that commit.
   The release workflow separately checks and packages without installing dependencies in
   the publishing job. It refuses mismatched version or nonempty Unreleased content.
5. Download the attached ZIP and hash from the release page and repeat first-run checks.
   Verify the README, images and issue links as a visitor before announcing availability.

## Scope of the first release

Ship the reliable named-set workflow, recovery, documentation and diagnostic path first.
Keep optional rules, hardware controls and diary discoverable in their existing pages;
there is no need for a new installer, service, mandatory analytics or account system.
Automatic updates and broad hardware claims are separate work. A short list of tested setups is more useful than an unsupported compatibility promise.
