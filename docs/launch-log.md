# Launch log

Checked on 2026-10-03. This records evidence and actions still needed, not a claim of
universal hardware support. Start with [the launch plan](https://github.com/GentleMec/DeskModes/blob/main/docs/public-launch.md).

## Current evidence

| Item | Result | Evidence and limit |
| --- | --- | --- |
| Public release | Verified | [1.0.1](https://github.com/GentleMec/DeskModes/releases/tag/v1.0.1), ZIP and checksum are public. Downloaded ZIP hash matches the attached hash and GitHub asset digest. |
| Released startup commands | Verified on this PC | Fresh isolated extraction: status and diagnostics exit 0 under Windows PowerShell 5.1. Diagnostics contains schema, version, windows, powershell and displays. No real switch was invoked. |
| Source quality | Verified for functional source | Commit `4ee38111360bd44bd68181019901fe1873723deb`: [Windows CI success](https://github.com/GentleMec/DeskModes/actions/runs/37074182210), including required analyzer. Local check on October 3 passed 2,849 assertions; local analyzer unavailable. |
| GitHub presentation | Prepared and published | Short README, Modes/desk screenshots, release download link, useful About description and repository website. Release description shortened with full changelog linked separately. |
| Bug and idea forms | Published; browser check pending | Both YAML forms are on main; bug/enhancement labels exist; Issues enabled. [API smoke issue #1](https://github.com/GentleMec/DeskModes/issues/1) was created and closed. That does not prove browser validation. |
| Private security route | Enabled | Repository API returns private vulnerability reporting enabled. |
| Maintainer notifications | Action required | Repository subscription API returned 404 for the authenticated owner. Enable Watch → Custom → Issues and test another account's report. Email/browser delivery is unverified. |
| Donation links | Published on GitHub | README and FUNDING.yml point to https://ko-fi.com/gentlemec. Source About uses the same URL. The 1.0.1 ZIP predates this source change and has no Support button. |
| Next app release | Candidate prepared | Clean source `36ee7e439d1defc28602eef9f2806e87a9514c5c`, version 1.0.2, undated changelog. All 25 archived files match source; no machine state or development files. Isolated status/diagnostics and offline Support-click verification passed. The release guard refuses the undated build before writing an archive. |
| Ko-fi account | Owner reports providers connected | PayPal and Stripe are reported connected. English copy is ready. Page editing and public checkout remain unverified; browser tool cannot verify saved permissions. |
| Outreach material | Prepared | Platform drafts, tester invitation, FAQ replies, direct destinations, posting rules and image captions are linked from the plan. No messages or community posts have been sent. |
| Content formatting | Verified | GitHub Markdown API rendered the plan, posts, content checklist, journal and release notes; tables and code blocks are retained. About screenshot rendered from current WPF source and visually inspected. |
| Demo | Script ready; recording pending | A 20–25 second physical-desk recording is optional for the first screenshot post. No real-hardware video was fabricated or recorded. |

Published ZIP SHA256:

```text
d90f79b308d26b6ba205372180fe740926702c98ad6e2b562f0c0382a13bbcbe
```

Release asset download count was 1 before this session's verification download. Treat
maintainer downloads as part of the count, not new users. Refresh the baseline immediately
before outreach using [release assets](https://github.com/GentleMec/DeskModes/releases/tag/v1.0.1)
and the private [traffic view](https://github.com/GentleMec/DeskModes/graphs/traffic).

An ignored local `DeskModes-1.0.1.zip` in the checkout predates publication and is a
historical candidate. Use the public attached ZIP and verified hash above for the launch.

## 1.0.2 candidate verification

Candidate ZIP SHA256:

```text
ca39bf94179eef1357fd219b4acd4435e420fe6b7f2607ab75e961b58a0b7b12
```

The ZIP, matching hash and candidate notes are saved under
`../DeskModes-launch/prepared-1.0.2-36ee7e4`. A maintainer preservation draft is planned
on GitHub under **DeskModes 1.0.2 candidate (36ee7e4)**; its own body records upload and
CI confirmation. The candidate is not a public release.

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
| Suggestion form | [Open while signed in](https://github.com/GentleMec/DeskModes/issues/new?template=feature_request.yml); empty required fields should block submission. Submit a clearly marked test with no private data and close it. | Pending |
| Bug form | [Open while signed in](https://github.com/GentleMec/DeskModes/issues/new?template=bug_report.yml); symptom, steps and version required; logs optional. | Pending |
| Notifications | Repository Watch → Custom → Issues; [notification settings](https://github.com/settings/notifications) for delivery preference. Have another account create a harmless issue and check arrival. | Pending |
| Ko-fi page | Paste [page copy](https://github.com/GentleMec/DeskModes/blob/main/docs/kofi-page.md), add GitHub links and thank-you text; review currency, suggested tip and fees. Open signed out and inspect checkout. | Pending |
| Receipt | Check any outstanding PayPal/Stripe account requirements and confirm receipt after a genuine supporter payment. | Pending; no agent payment attempted |
| First outreach | Choose one community, recheck its rules, review and post the matching draft. Add its URL below. | Pending; owner action |

For future app releases, keep the existing tag workflow. Bump the source version and
move applicable Unreleased notes to that version; run the required gates, build an isolated
candidate, verify affected behavior and exact-commit CI, then date and tag that commit.
Do not reuse v1.0.1 or overwrite its assets to add the new Support button.

## Publication and feedback journal

No community publication is recorded yet. Duplicate the following block for each actual post:

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
