# Release readiness

Status on 1 October 2026: **automated candidate checks and all configured native mode round trips passed; sleep and interactive acceptance remain open**.
The application reports 1.0.1. Its CHANGELOG heading intentionally has no release date;
`pack.ps1 -ExpectVersion 1.0.1` refuses publication until a dated section is committed.
The first-release feature notes are consolidated under 1.0.1, including the current
separate Save and apply-to-displays behavior.

## Continue from another computer

The verified candidate source is on GitHub at `3f8a52f939eeb7d13e7aeea5891e826b270af807`.
Its [Windows CI run](https://github.com/GangHack/DeskModes/actions/runs/35370648757)
completed successfully, including the required analyzer and full regression suite.
The repository is private; sign in with an account that has access.

The [candidate draft](https://github.com/GangHack/DeskModes/releases/tag/untagged-a77f5d749e045ddaa30f)
contains the exact tested ZIP, its SHA256 file, release notes and validation evidence.
It is a draft, not a published release. The server-reported ZIP digest matches the local one:

```text
24e196bf66e1d1f244f9fa24e13536a9a6f0979d086fbe76a5c120a506dc05f0
```

On macOS, clone the repository or use the GitHub web editor to continue documentation and
release preparation. Windows CI can run the automated checks; the application itself requires
Windows PowerShell 5.1 and cannot run natively on macOS. No source or candidate archive is
available only on the author's Windows computer. Personal settings and machine caches are
excluded from the uploaded assets.

Before publishing, finish the applicable interactive checks below on Windows, then date the
1.0.1 CHANGELOG heading, commit it, wait for green Windows CI, and push `v1.0.1` at that commit.
The existing release workflow builds the final assets. Do not publish the preservation draft
as the final release: its notes and source deliberately remain an undated candidate.

## October 1 candidate verification

The source above passed all five local gates with PSScriptAnalyzer 1.25.0 and 2,840
assertions: 78 scripts parsed, 108 text files passed encoding checks, all six languages
covered 368 English strings, and all 360 requested keys existed. The analyzer was loaded
from a temporary development folder without a system installation. Its existing GitHub
Actions run was independently confirmed successful on October 1.

The candidate was rebuilt from the clean source. Its 25 program files excluded personal
settings, logs, caches, diary data and development files. The ZIP SHA256 matched the
preserved draft digest above. Freshly extracted `status` and `modes` commands exited 0
under Windows PowerShell 5.1 on Windows build 26200.

An isolated copy of the installation's eight machine-state files was overlaid with the
candidate's program files. All eight files retained their exact hashes after the overlay.
The extracted candidate then passed all eight checks in `tests/live.ps1 -ReadOnly`,
including an unchanged active display set after `all -DryRun`. Settings, diary and the
last chosen mode retained their hashes after those CLI checks. The real installation
was not replaced; tray restart, Windows download warnings and clean-Windows startup
remain pending.

A temporary observer also recorded Windows display power changing from on to dim to
off on the two-LG desktop. Wallpaper Engine's audio session became inactive, and no
nonzero audio peak was sampled while both Windows display-power states were off during
the remaining two minutes of capture. The reported intermittent music was not reproduced.
The owner subsequently disabled Wallpaper Engine audio. This is an external workaround,
not a DeskModes fix or acceptance of sleep/wake on the ASUS desktop; that scenario remains
open. The observer stopped, and no DeskModes behavior or user settings were changed.

The owner reported that All woke the ASUS and UltraGear, while UltraFine remained dark
although the application showed it as on. The captured All attempts at 15:55:10 and
15:56:27 completed without a logged refusal; Windows reported all three desktop paths
active, including UltraFine at 3840x2160 / 59997/1000 Hz. A subsequent read-only query
confirmed that desktop state, and a single-register DDC read of UltraFine's power-mode
register 0xD6 returned 1. These later readings do not establish that the panel displayed
an image during the reported failure. The application currently derives its on/off
status from Windows desktop-path activity, not physical panel illumination.

Three-monitor visual All acceptance is therefore unresolved. Record the panel's OSD
message and recovery action, reproduce from display sleep, and confirm visible output
on every requested panel before accepting the candidate. No display configuration,
monitor setting or switch behavior was changed during this investigation.

The owner subsequently confirmed that pressing UltraFine's physical power button restored
its image. This establishes the recovery action, not the cause of the dark panel. The current
source now labels inactive desktop paths as **not in use** and unavailable displays as
**not detected**, with a Settings explanation that desktop activity is not panel power.
This wording change does not establish an automatic wake fix or accept the All scenario.
The preserved draft ZIP predates this wording change and must be rebuilt for the next candidate.

Repository visibility and the preserved draft were rechecked on October 1: the repository
remains private and the candidate remains a draft. Distribution audience is still an owner
decision; neither verification nor candidate preparation changes repository visibility.

## October 1 wake checks

The status-wording source `3888705a596abfac789b329c254f760177493c0d` passed all 2,840
local assertions and the parse, encoding and language gates. Its
[Windows CI run](https://github.com/GangHack/DeskModes/actions/runs/36875615025) also passed,
including the required analyzer. A separate local candidate was rebuilt from that clean
source with 25 program files and SHA256
`d007594900a612499ee98df7824914039d785152870b8fd30e6d800b7419fc55`.
The older preserved draft above remains unchanged.

With another panel displaying an image, the owner turned UltraFine off using its physical
power button. Windows still reported its target as available but inactive; ordinary DDC
physical-monitor enumeration had no handle for it. A restricted-process All attempt returned
Win32 access error 5 before any display change, so that attempt is not hardware-failure evidence.
Repeating All in the normal user session succeeded and restored all three display paths:
UltraGear at 2560x1440 / 144 Hz, ASUS at 2560x1440 / 240 Hz, and UltraFine at 3840x2160 / 60 Hz.
The owner confirmed that UltraFine remained physically dark.

Once its desktop path was active, UltraFine answered a single-register DDC read with
`0xD6 = 5`. One explicit developer-tool write of `0xD6 = 1` returned success. The immediate
read did not answer while the panel was transitioning; a later fresh read returned 1.
The owner confirmed that the image appeared without pressing its power button, and Windows
kept the three display modes. No capabilities string was requested. This proves that this
UltraFine can be powered on through DDC after desktop activation. DeskModes switching at the time of that test
did not send that power command, and this result does not establish behavior on other panels
or the cause of the earlier automatic-sleep incident.

A separate Windows display-power off/on request ran for ten seconds without changing the
configured power plan or display timeout. After it, active membership, primary, coordinates,
rotation, resolutions and exact refresh fractions matched the preceding desktop; settings.json
retained its hash. The owner subsequently reported that the screens did not visibly go dark.
The commands returning successfully therefore do not constitute a sleep/wake pass.
This short explicit power cycle does not replace acceptance of the fifteen-minute idle timeout.

## October 1 final candidate round trips

The documented candidate source `f8fcc050a8eeb2491186cc3cc5001f13edd55483` passed its
[Windows CI run](https://github.com/GangHack/DeskModes/actions/runs/36882100726), including
the required analyzer. Its code is unchanged from the status-wording source above, whose
full local suite passed 2,840 assertions. The rebuilt ZIP contains 25 program files and has SHA256
`2e346e2bf0075d2e6975e9e78f203ea38eab794bd1486f56cba1d4db15c7f107`.
A fresh isolated extraction with copies of the existing machine-state files passed all eight
read-only CLI checks. The preserved GitHub draft remains the older candidate.

A normal-user-session hardware run started in Solo ASUS and exercised repeated All,
all three solo modes, both configured combinations (Work and work+game), and an All
return after each. Every requested active physical identity, single primary at the origin,
source/target dimensions, rotation and rational refresh rate matched expectations.
Every All return matched the captured three-display snapshot, including UltraFine's
asymmetric Y position. The final Solo ASUS matched its original exact snapshot, and
settings.json retained its hash. No optional hardware controls or personal hooks were enabled.

The owner confirmed visible images on every requested panel throughout this switching run,
including UltraFine, and the final Solo ASUS. This accepts ordinary switching on the current
three-panel desk with the panels powered on. It does not establish automatic panel power-on,
the idle sleep/wake scenario, identical panels, portrait rotation or another computer. The current
tray process has not been restarted with the new wording; real ZIP/tray startup remains open.

## Manual DDC wake candidate

Explicit mode selection now checks the selected active physical panels' power register after
Windows desktop verification, including repeated All. It writes 0xD6=1 only after a successful
read reports 2 through 5, and reads back within twelve confirmation passes. Already-on panels,
unknown values and unsupported/non-answering registers receive no power write. A fresh CCD
identity-to-output mapping avoids using a stale DISPLAY number after hotplug. The same switch
mutex covers this work. Automatic rules, startup/resume reapplication, dry runs and failed desktop
verification do not invoke wake. The operation precedes optional brightness/picture settings.
A known-off panel that fails confirmation is logged as a warning; desktop success still reports
Windows configuration, and does not claim optical output or universal monitor power support.

The regression cases failed on the previous code, then passed after implementation. All 2,850
local assertions and parse, encoding and language gates passed; required analyzer acceptance is
performed by Windows CI. Controlled physical-button wake with the integrated code remains pending.
The running tray still holds the previous source until it is restarted; CLI runs use the new code.

The [Microsoft DDC/CI API documentation](https://learn.microsoft.com/en-us/windows/win32/api/lowlevelmonitorconfigurationapi/nf-lowlevelmonitorconfigurationapi-setvcpfeature)
requires hardware validation because firmware support varies. The
[power-register reference](https://www.ddcutil.com/vcpinfo_output/) identifies the standard power
values; this desk's UltraFine additionally reports value 5 after button-off, as measured above.
No capabilities request or monitor-off command is added.

## Remaining acceptance for the current candidate

The integrated candidate includes imported physical-selector compatibility, opt-in startup
restoration, per-monitor WPF DPI handling, tray placement/dismissal, first-run language selection,
separate Save and apply-to-displays actions, and rules that watch several programs.
Earlier hardware evidence applies only to its recorded source, not automatically to this candidate.

Before tagging:

- The current three-monitor desk passed exact and visually confirmed mode round trips above.
  Finish idle sleep/wake acceptance and repeat All -> solo/subset -> All on the external setup.
  Compare physical primary, X/Y, rotation, resolution, refresh and restored window reachability.
  Include an unavailable panel and confirm recovery leaves a usable desktop.
- Start with a different visible panel than the last chosen mode. Defaults must preserve the
  current desktop. Existing explicit restoreLastMode=true remains an intentional opt-in.
- Move Settings between the 4K/2K screens, switch the active desk, and test narrow RU/UK windows.
  Check tray scrolling, Exit, outside-click/Escape dismissal and the timer submenu on the real tray.
- Edit the configured desk and press Save or Enter: settings must be saved without switching
  displays. Use the separate apply button and verify only the currently active displays change.
- Start two programs named by one rule, then close them one at a time. The mode must remain
  active until the last program closes; verify the configured return and manual override too.
- Test the exact ZIP on a clean Windows installation and overlay it on a backed-up installation.
  Record Windows warnings, first launch, imported bindings, settings preservation and rollback.
- Recheck GitHub Actions for the final dated release commit. The current candidate's run is
  green, as linked above.
- Decide the distribution audience: the repository is confirmed private. Verify README,
  screenshot, download and issue links as an unauthenticated visitor before announcing
  a public release. Changing repository visibility requires the owner's explicit decision.

The first release date and tag remain unset until applicable hardware acceptance is recorded.
Untested laptop, dock and multi-GPU configurations must remain explicitly experimental.

## What the automated checks establish

`powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\check.ps1 -RequireAnalyzer`

On September 18, the application source at `e7272e109c24e5184b419b9c0ee52e733461e6b8`
passed the full local command above: 78 scripts parsed, 107 text files passed encoding checks,
PSScriptAnalyzer 1.25.0 was clean, and 2,840 assertions passed. The analyzer ran from a temporary
development folder without a system installation. All five translations cover all 368 English
strings; all 360 statically requested keys exist. Release preparation changes only documentation.
Tests redirect machine files and shadow hardware calls; no physical
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

Earlier English screenshots are in `docs/images/`. Nine offscreen WPF windows were
rendered for English, Russian, German and French. Desk and About pages were inspected for
readability at the renderer's dimensions. This does not validate keyboard navigation,
actual tray interactions, small-screen scrolling, every DPI or dark/high-contrast themes.
On September 18, the current renderer also produced 14 English preview images successfully;
the desk page and first welcome screen were inspected. This is offscreen rendering evidence,
not a clean-Windows launch or an interactive hardware result.

## Hardware and first-run matrix

Pending means no result has been recorded for this candidate. It is not a passing claim.
Record the Windows build, GPU and driver, monitor models, cable/dock, scale and source
commit with each result. Keep serial numbers, private commands and full paths out of
public reports.

| Scenario | Procedure and pass condition | Candidate status |
| --- | --- | --- |
| Fresh Windows 10 | Download ZIP in a browser; extract to a writable folder; start Displays.cmd. Record actual warnings, first compilation time and first Settings window. | Pending |
| Fresh Windows 11 | Same procedure, recording Smart App Control state without changing it for the test. A refused run must have actionable troubleshooting. | Pending |
| Author's three-monitor desk | Solo -> All -> solo -> All -> original solo, using exact desktop comparisons and the extracted candidate. | All configured mode round trips and owner visual confirmation passed October 1; button-off UltraFine and idle sleep/wake remain open |
| One monitor | Start, configure, repeat its mode, open/close Settings and exit. No phantom monitors or failure loop. | Pending |
| Two different monitors | Alternate solo, combination and all; verify membership, primary, positions and refresh rates. | Pending |
| Exact three-display restoration | Two identical landscape panels plus portrait-flipped third panel at asymmetric Y. Repeat All; cycle subset/solo to All; restart in subset. Compare physical primary, every X/Y, rotation, resolution and rational Hz. | Three distinct landscape panels passed October 1; identical/portrait setup pending |
| Two identical panels | Save distinct hotkeys and a one-panel combination. Reconnect in a different enumeration order; remove either panel. The remaining one keeps its key and never substitutes for the absent selection. | Pending |
| Laptop and external display | Repeat with lid open/closed, sleep/wake and reconnect. Record the configured Windows lid action; use a visible recovery path. | Pending |
| Dock / multiple GPUs | Record exact adapters, dock, ports and driver; test unplug/replug and wake. | Pending; experimental |
| Optional display controls | Opt into brightness/contrast/picture/HDR only where supported. Verify restoration and bounded failure; never query the capabilities string. | Pending |
| Rules and Back | Test process/idle/plug trigger, return, unavailable target, bounded retry and manual override. | Pending |
| Small screen and accessibility | 100/150/200% scale, short working area, long translations, keyboard and screen reader, light/dark/high contrast. All actions must remain reachable. | Pending |
| Portable update | Back up the folder, exit, overlay the new program files and restart. Settings, hooks, rules and diary remain intact. | Isolated overlay and read-only CLI passed October 1; real tray restart pending |
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

### September 18 hardware evidence

The exact draft ZIP was extracted into a separate writable folder. `tests/live.ps1 -ReadOnly`
passed all eight CLI checks. Three repetitions of the active single-display mode also preserved
the exact desktop. The subsequent real switching run passed Solo -> All -> solo -> All ->
original solo. Exact comparisons covered active physical identities, primary, X/Y, rotation,
source and target dimensions, scaling and rational refresh rates. The final window restoration
reported 11 of 11 windows restored.

The active three-display configuration reported LG UltraGear at 2560x1440 / 144 Hz,
ASUS XG27AQDMGR at 2560x1440 / 240 Hz and LG UltraFine at 3840x2160 / 60 Hz.
The host reported Windows build 26200 and Windows PowerShell 5.1.26100.9444.
Reported GPU inventory: NVIDIA GeForce RTX 4080 SUPER (driver 32.0.16.1692) and
AMD Radeon(TM) Graphics (driver 32.0.21043.5001). Cable/port routing and per-monitor DPI
were not recorded; this does not establish coverage of multiple-GPU configurations.
The test used default settings plus the existing layout order and copied desktop/mode caches.
It did not execute personal hooks or optional DDC/HDR/audio changes. Existing user settings
were not replaced. The original single LG UltraGear desktop was restored at the end.

An initial run in the restricted execution environment received CCD validation error 5
(access denied) without applying a topology change. That run is not a hardware pass.
The successful round trip ran in the ordinary user session with a fresh isolated copy of
the original caches. No person observed the screens; visual output, first-run warnings,
interactive Save/apply behavior, sleep/wake and external hardware remain unverified.

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
