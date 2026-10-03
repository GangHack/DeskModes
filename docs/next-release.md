# Next release: 1.0.2 candidate

The public download remains 1.0.1. Current source prepares 1.0.2 with the existing
Support DeskModes button enabled in About and project/help/feedback links updated
to GentleMec. There is no display-engine, rules, settings or diagnostics change.

## Prepared candidate

The clean candidate built from source `36ee7e439d1defc28602eef9f2806e87a9514c5c` contains
25 program files. Its checksum and release notes are beside the ZIP in the local delivery
folder `../DeskModes-launch/prepared-1.0.2-36ee7e4`. Its validation record is in the launch log.

The archive is also saved in the maintainer-only
[DeskModes 1.0.2 candidate (36ee7e4) draft](https://github.com/GentleMec/DeskModes/releases/tag/untagged-5e2a2933156f305e801c),
with its hash, notes, validation summary and Support preview. All uploaded digests matched
the local files. Sign in with maintainer access to open the draft.
Keep that preservation draft unpublished; the final v1.0.2 still goes through the tag workflow.
The draft's candidate tag name does not replace the final version tag.

## Before publication

1. Ko-fi profile text is saved. Finish outstanding owner verification and verify checkout;
   [profile copy and remaining checks](https://github.com/GentleMec/DeskModes/blob/main/docs/kofi-page.md).
2. Verify both GitHub feedback forms and owner notification delivery as listed in
   [the launch log](https://github.com/GentleMec/DeskModes/blob/main/docs/launch-log.md).
3. Verify the isolated candidate shows version 1.0.2 and its Support button points
   to https://ko-fi.com/gentlemec. Gate/test evidence and candidate checks belong in the log.
4. Remove the candidate-only introductory paragraph from the 1.0.2 changelog section
   and date its heading with the actual publication day. Keep Unreleased empty.
5. Commit the final dated source, run all required gates and wait for successful CI
   on that exact commit. Use `tools/check.ps1 -RequireAnalyzer` where the analyzer is available;
   CI requires it. Rebuild the clean archive with `tools/pack.ps1 -ExpectVersion 1.0.2`.
6. Publish through the existing annotated-tag workflow:

```powershell
git tag -a v1.0.2 -m "Release 1.0.2"
git push origin v1.0.2
```

7. Confirm the release workflow succeeds, download its attached ZIP and checksum,
   compare hashes, extract into a separate writable folder and confirm startup/version.
   Only then announce 1.0.2 or claim downloaded copies include Support.

The release date and tag are deliberately absent from the candidate. Do not overwrite
v1.0.1 or replace its assets. No user installation is replaced by candidate preparation.

## Owner review

Exit the existing tray before deliberately trying another tray instance; keep a backup
of the working folder and settings. Review the candidate in its separate folder before
overlaying a working installation. Run ordinary read-only commands first:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Set-Display.ps1 status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Set-Display.ps1 diagnostics
```

Real panel wake, rules and display transitions are governed by the existing
[validation matrix](https://github.com/GentleMec/DeskModes/blob/main/docs/release-readiness.md).
The link-only patch does not establish new hardware compatibility.
