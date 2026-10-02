# Public launch plan

Goal: help Windows users with several displays understand the value, try one mode,
and report whether it works on their desk. This is an outreach plan, not a compatibility promise.

## GitHub front page

The README leads with one use case, a release link and the current Modes screenshot.
Detailed setup and recovery live in docs/getting-started.md; technical options stay in
docs/reference.md. The screenshots are rendered from the real UI with invented monitors,
not evidence of validation on those monitor models.

Suggested repository About description:

> Switch between Work, Game and TV display setups with one hotkey. Portable Windows app that remembers layouts, refresh rates and window positions.

Use https://github.com/GentleMec/DeskModes/releases/latest as the About website.
Keep the existing focused topics: windows, powershell, multi-monitor, monitor-switcher,
display-profiles, hotkeys and ddc-ci. Keep the public issue channel enabled.

## Feedback acceptance

- The released app opens the repository Issues page from Settings → About.
- README links directly to the Bug report and Feature request forms.
- Bug reports require the symptom, reproduction steps and version. Diagnostics,
  logs and hardware details are optional so startup failures can still be reported.
- Confirm the bug and enhancement labels exist, and the templates are on main.
- Create one clearly marked test issue with no real diagnostics, then close it.
  This checks issue creation and closure, not browser form validation.
- In a signed-in browser, open each README feedback link. Verify the correct form
  renders, empty required fields block submission, and a report without logs is allowed.
- In GitHub, select Watch → Custom → Issues for the maintainer account. Check
  notification delivery with a report from another account; self-authored issues
  do not establish notification delivery.
- Review new issues daily during the first week. Ask for only the missing details,
  add a workaround when known, and link a fix to its release.

A successful API smoke check does not prove the browser form or email notifications.
Record those owner checks before describing the entire feedback path as verified.

## Enable voluntary support

The support page is https://ko-fi.com/gentlemec. The owner reports PayPal and Stripe
connected on 2026-10-03. Registration, identity checks, payment setup and transactions
are owner actions. Page editing and checkout have not been verified by the agent.

The English page title, description, feedback links and thank-you message are ready in
[docs/kofi-page.md](https://github.com/GentleMec/DeskModes/blob/main/docs/kofi-page.md).

GitHub FUNDING.yml and the README link to this page. The About button uses the same URL
in the source. The released 1.0.1 ZIP has no support link; the app change is recorded under
Unreleased and will reach downloaded copies through the normal next-release workflow.

Remaining owner checks:

1. Paste the prepared English copy into Ko-fi and add the GitHub links.
2. Review page currency, suggested tip amount and Standard/Contributor fees.
3. Confirm the public page offers both payment methods and check for any outstanding
   payment-provider requirements. Confirm receipt after a genuine supporter payment.

Official setup:
https://help.ko-fi.com/hc/en-us/articles/115003980093-How-do-I-get-paid

DeskModes remains free; support is optional and grants no promise of priority fixes.


## First two weeks

| Window | Action | Observable result |
| --- | --- | --- |
| Days 1–2 | Publish the concise README and current screenshots; finish the feedback and notification checks; set up the support page. | A visitor can find the ZIP, understand one use case and report a problem. |
| Days 2–3 | Record a 15–25 second demonstration: Work → Game → Back. Show the hotkey, resulting screens and restored arrangement. Hide personal desktop content. | One short real-hardware clip, with captions and a GitHub link. |
| Days 3–5 | Share with 5–10 willing users who have different Windows display setups. Ask them to create one mode, switch away and back, then describe the result. | Setup reports with monitor models, connection types and Windows version. |
| Days 5–7 | Publish one focused post in a relevant community after reading its current promotion rules. Adapt the clip and use case to that audience. | Useful questions and reproducible reports rather than unexplained download counts. |
| Week 2 | Fix the most common setup obstacle, update the guide, and publish a patch if needed. Share one follow-up with the result. | A shorter first-run path and evidence from desks beyond the author's. |

Potential audiences to assess: Windows multi-monitor users, gaming/workstation
communities and open-source desktop-tool communities. Check current rules and any
self-promotion restrictions immediately before posting. This document does not authorize
sending messages or posting announcements; the owner chooses the accounts and channels.

## Draft announcement

> I built DeskModes because I kept switching between a work setup and a gaming monitor.
> It lets you save named display sets and switch with a hotkey, restoring their layouts,
> refresh rates and window positions. It is a free, portable Windows tool with no telemetry.
>
> The first public release is available now. It has been tested on my three-display desktop;
> laptops, docks and other setups still need feedback. If you try it, I would like to know
> whether Work → Game → Back restores your desk correctly.
>
> Download and screenshots: https://github.com/GentleMec/DeskModes
> Report a problem: https://github.com/GentleMec/DeskModes/issues/new?template=bug_report.yml

## What to measure

Use GitHub release asset downloads, the repository's available traffic view, reported
successful setups, reproducible bugs and repeated questions. Downloads are not active users.
Traffic data may include the maintainer's own checks. Keep a baseline before the first post.

A useful first target is five independent successful setup reports and a clear view of the
three most common obstacles. Stars and voluntary contributions are secondary signals.
Pause wider outreach if reports show inaccessible desktops, failed recovery or lost settings;
document the workaround and verify a fix before the next round. Add no application telemetry
just to measure the launch.

## Verification record — 2026-10-02

Public repository, released 1.0.1 ZIP/checksum and successful release/check workflows confirmed.
The existing bug and enhancement labels are present. API smoke issue #1 was created
with the bug label and closed as completed. About description and release link updated.
Local tools/check.ps1 passed with 2,850 assertions; the local analyzer was unavailable.
Signed-in browser form validation and notification delivery remain owner checks because
the browser tool could not verify its saved access permissions. The public chooser
redirects signed-out visitors to GitHub sign-in. At that snapshot, the support page URL was pending.
