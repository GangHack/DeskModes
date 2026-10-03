# Release verification and next patch

[DeskModes 1.0.2](https://github.com/GentleMec/DeskModes/releases/tag/v1.0.2) was published
on October 4, 2026 from f07232136200a4650ef4b355a399f31e6a878edf. It enables the existing
Support DeskModes button and updates project/help/feedback links. Display switching,
rules, settings and diagnostics are unchanged.

The exact source CI and tag workflow passed. The downloaded ZIP matches its attached
SHA256 and GitHub digest, all 25 files match the clean local archive, and isolated status/
diagnostics report 1.0.2 with exit 0. Evidence is in [the launch log](https://github.com/GentleMec/DeskModes/blob/main/docs/launch-log.md).
The older preservation draft remains unpublished.

## Remaining owner checks

Finish Ko-fi account verification, install the prepared dark cover and save/reload-check
the thank-you message. Confirm checkout and receipt of a genuine supporter payment.
Both GitHub forms and Watch → Custom → Issues passed browser checks; notification
arrival from another account remains unverified. These checks do not establish new
hardware compatibility.

## Future release procedure

1. Fix a reproducible issue or implement a reviewed improvement. Update the single
   source version and changelog together; keep Unreleased empty for the release tag.
2. Run tools/check.ps1 and verify affected behavior. Require the analyzer in CI and
   wait for green CI on the exact committed source.
3. Date the changelog heading with the publication day. Build a clean archive with
   tools/pack.ps1 -ExpectVersion and verify it in an isolated writable folder.
4. Create an annotated version tag and push it through the existing release workflow.
   Keep previous tags and their assets intact.
5. Confirm tag workflow success, download ZIP/checksum, compare files and hashes,
   and verify startup/version before announcing the new version.

For owner installation review, exit the existing tray before starting another instance.
Keep a backup of the working folder and settings. Start with read-only status/diagnostics
commands from the separate extraction; use the [validation matrix](https://github.com/GentleMec/DeskModes/blob/main/docs/release-readiness.md)
for real panel wake, rules and display transitions.
