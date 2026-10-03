# Launch log

Checked on 2026-10-04. This records evidence and actions still needed, not a claim of
universal hardware support. Start with [the launch plan](https://github.com/GentleMec/DeskModes/blob/main/docs/public-launch.md).

## Current evidence

| Item | Result | Evidence and limit |
| --- | --- | --- |
| Public release | Verified | [1.0.2](https://github.com/GentleMec/DeskModes/releases/tag/v1.0.2), normal public release from f07232136200a4650ef4b355a399f31e6a878edf. [Tag workflow succeeded](https://github.com/GentleMec/DeskModes/actions/runs/37158627145). Downloaded ZIP hash matches attached checksum and GitHub digest. All 25 files match the clean local build. |
| Released startup commands | Verified on this PC | Fresh isolated extraction: status and diagnostics exit 0 under Windows PowerShell 5.1. Diagnostics contains schema, version, windows, powershell and displays. No real switch was invoked. |
| Source quality | Verified | Release commit f07232136200a4650ef4b355a399f31e6a878edf: [Windows CI success](https://github.com/GentleMec/DeskModes/actions/runs/37158437316), including required analyzer. Local tools/check.ps1 passed 2,849 assertions on October 4; local analyzer unavailable. Tag workflow ran all gates again successfully. |
| GitHub presentation | Prepared and published | Short README, Modes/desk screenshots, release download link, useful About description and repository website. Release description shortened with full changelog linked separately. |
| Bug and idea forms | Verified in a signed-in browser | Required fields block empty submissions. A suggestion with optional fields empty created [#3](https://github.com/GentleMec/DeskModes/issues/3) with enhancement; a bug without logs created [#4](https://github.com/GentleMec/DeskModes/issues/4) with bug. Both harmless tests were closed. |
| Private security route | Enabled | Repository API returns private vulnerability reporting enabled. |
| Maintainer notifications | Subscription saved; delivery pending | Watch → Custom → Issues was saved and confirmed checked after reload on October 4. A report from another account and actual notification delivery remain unverified. |
| Donation links | Published in app and on GitHub | README, FUNDING.yml and the 1.0.2 About Support button point to https://ko-fi.com/gentlemec. Payment acceptance remains a separate owner check. |
| App release | 1.0.2 published | Support and canonical-link patch; no display-engine, rules, settings or diagnostics change. Isolated downloaded status/diagnostics exit 0 and report DeskModes 1.0.2. No real display switch was invoked. |
| Ko-fi profile | Text verified; cover ready locally | Display name, English About, Website and Software category confirmed. New dark cover and its generation brief are in the local delivery folder. Automated upload requires the extension file-URL option; manual upload is available. Thank-you field was empty after reload and is not saved. |
| Ko-fi payments | Owner checks remain | Payment Settings shows both providers connected and outstanding verification requirements. Signed-out checkout and receipt unverified. Private account follow-up is kept outside this public log. |
| Outreach material | Prepared | Platform drafts, tester invitation, FAQ replies, direct destinations, posting rules and image captions are linked from the plan. No messages or community posts have been sent. |
| Content formatting | Earlier rendering verified; current Markdown inspected | GitHub Markdown API rendered the earlier plan, posts, content checklist, journal and release notes; tables and code blocks are retained. About screenshot rendered from current WPF source and visually inspected. |
| October 3 profile follow-up checks | Historical failure resolved October 4 | Tall-menu fixture assumed 1,200 pixels would fit 40 rows; at 150% DPI the menu needs 1,204. Larger fake screen now uses the natural menu height. Original regression failed 1 of 5; fixed check passes 5 of 5 and full tools/check.ps1 passes 2,849 assertions. No production menu change. |
| Demo | Script ready; recording pending | A 20–25 second physical-desk recording is optional for the first screenshot post. No real-hardware video was fabricated or recorded. |

Published ZIP SHA256:

```text
cdcc7ea4807f1ed3d4e47eff067547802882c67eb52781cb20787e876943ac7e
```

The 1.0.1 asset count was 1 before its earlier verification download. Treat
maintainer downloads as part of the count, not new users. Refresh the baseline immediately
before outreach using [release assets](https://github.com/GentleMec/DeskModes/releases/tag/v1.0.2)
and the private [traffic view](https://github.com/GentleMec/DeskModes/graphs/traffic).

An ignored local `DeskModes-1.0.1.zip` in the checkout predates publication and is a
historical candidate. Use the public attached ZIP and verified hash above for the launch.

## Historical 1.0.2 candidate verification

Candidate ZIP SHA256:

```text
ca39bf94179eef1357fd219b4acd4435e420fe6b7f2607ab75e961b58a0b7b12
```

The ZIP, matching hash and candidate notes are saved under
`../DeskModes-launch/prepared-1.0.2-36ee7e4`. The same files are saved in the
[maintainer-only preservation draft](https://github.com/GentleMec/DeskModes/releases/tag/untagged-5e2a2933156f305e801c),
including validation.txt and the UI preview. All five uploaded asset digests matched
the local files. The draft's own body records hosted CI confirmation. At that candidate stage no v1.0.2 tag
was pushed. The final dated release above supersedes it; the preservation draft stays unpublished.

Local tools/check.ps1 passed 2,849 assertions after the version bump; local analyzer
was unavailable. Extracted status and diagnostics report DeskModes 1.0.2. The About
window shows the same version, Support is visible/enabled, and raising its click event
passes https://ko-fi.com/gentlemec to a locally captured Open-UiTarget call. This verifies
the packaged action's target, not browser navigation or payment checkout.

The [Support preview](https://raw.githubusercontent.com/GentleMec/DeskModes/main/docs/images/settings-support.png)
was rendered offscreen from the candidate and visually inspected. No real display
switch or user installation update was performed. The original hardware limits apply.

## Owner checks: record the actual result

| Check | How | Result |
| --- | --- | --- |
| Suggestion form | Browser submission and required-field validation; optional workaround left empty. | Passed; #3 closed |
| Bug form | Browser submission and required-field validation; diagnostics and logs left empty. | Passed; #4 closed |
| Notifications | Watch → Custom → Issues is saved. Have another account create a harmless issue and check arrival. | Subscription verified; delivery pending |
| Ko-fi page | [Profile text](https://github.com/GentleMec/DeskModes/blob/main/docs/kofi-page.md) is saved; finish cover upload, reload-check thank-you and inspect signed-out checkout. | Text verified; remaining checks pending |
| Receipt | Check any outstanding PayPal/Stripe account requirements and confirm receipt after a genuine supporter payment. | Pending; no agent payment attempted |
| First outreach | Choose one community, recheck its rules, review and post the matching draft. Add its URL below. | Pending; owner action |

For future app releases, keep the existing tag workflow. Bump the source version and
move applicable Unreleased notes to that version; run the required gates, build an isolated
candidate, verify affected behavior and exact-commit CI, then date and tag that commit.
Do not reuse v1.0.1 or overwrite its assets to add the new Support button.

## Publication and feedback journal

No community publication is recorded yet.

The owner confirmed on 2026-10-03 that the task is to prepare the posting plan. No community
post or moderator message was sent. First options: the current r/software Weekly Discovery Thread or r/SideProject.
The October 4 weekly thread welcomes relevant side projects with transparent authorship.
Wait for feedback before another announcement; no community post has been sent.

Duplicate the following block for each actual post:

```text
Date/time and account:
Community/thread URL:
Rules checked at:
Post URL and title:
Screenshot/clip and release used:
Downloads/traffic baseline (including maintainer checks):
Useful feedback and linked GitHub issues:
Replies sent and outstanding questions:
Next action and date:
```

Keep contact details, private chats and payment records outside this public journal.
After 48 hours, count useful setup reports and repeated questions. After one week,
choose the three most common obstacles; stop wider outreach if recovery or settings safety
fails, document a workaround and verify a fix. Target five independent successful setups;
stars and donations are secondary. Do not add app telemetry for this launch.
