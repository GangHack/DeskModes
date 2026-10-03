# Launch copy

Prepared drafts for the owner to review and post. Nothing here has been sent.
Use one audience at a time and reply to its questions before widening the launch.

## r/software Weekly Discovery Thread

First option checked on October 4:
[Weekly Discovery Thread - October 02, 2026](https://www.reddit.com/r/software/comments/1wvquoc/weekly_discovery_thread_october_02_2026/).
It welcomes relevant side projects and transparent self-promotion, but prohibits link
spam and AI-generated content dumps. Review and personalize this short draft before posting;
use the current weekly thread if this one is no longer active.

```text
I develop DeskModes, a free, open-source Windows tool for switching between work screens, a gaming monitor and a TV. You can save display modes, assign hotkeys and add rules that select a mode while any chosen game or program is running, then return when the last one closes.

It's portable and has no installer or telemetry. I've tested the core workflow on my three-display desktop; other hardware still needs feedback.

Download and screenshots: https://github.com/GentleMec/DeskModes

If you use several displays, what part of switching between setups would you most like to improve?
```

Start with this comment or the SideProject post below. Wait for replies before adding
another announcement. Keep the donation link on the project page.

## Replies to existing discussions

Search for recent questions about Windows display presets, saved layouts or hotkeys.
Answer the actual question, disclose that you develop DeskModes and link it only when
the current app fits. Automatic rules are useful when the question involves games or
programs selecting a display setup.

Older examples are research context:
[layout hotkeys](https://www.reddit.com/r/software/comments/w423fs/) and
[switching displays with hotkeys](https://www.reddit.com/r/windows/comments/1h6qkci/).
Their age makes them poor first launch destinations. DeskModes does not promise
cross-PC KVM switching, monitor input-source switching or cloned-display profiles.
Do not revive old threads with a generic promotion message. No replies have been sent.

## r/SideProject

Title:

```text
DeskModes - A free Windows tool for display setups, hotkeys and automatic rules
```

Body:

```text
I built DeskModes to make it easier to move between work screens, a gaming monitor and a TV without rebuilding the desktop each time.

Save named display modes and choose them from the tray or with a hotkey. It remembers layouts, refresh rates and window positions. Optional rules can select a mode while any of your chosen games or programs is running, then return after the last one closes. There are also brightness, picture preset, HDR and audio options where the hardware supports them.

It's free, open source and portable. No installer, administrator rights, app account or telemetry.

I've tested the core workflow on my three-display desktop. Laptops, docks, multiple GPUs and identical panels are still experimental.

Download and screenshots: https://github.com/GentleMec/DeskModes

I'd love feedback on the first setup: is it clear how to create a mode and a rule? What would make the app more useful at your desk? Suggestions and bug reports both have forms on GitHub.
```

Attach `docs/images/settings-modes.png`. Caption: "Named display modes and their hotkeys.
Current interface with an example desk." Follow any extra rules shown in the submission form.

## r/software

Title:

```text
DeskModes: free, open-source Windows display modes with hotkeys and automatic rules
```

Body:

```text
DeskModes is a portable Windows tool I made for people who use different displays for work, gaming or watching on a TV.

Save a display set, assign a hotkey and switch from the tray. It restores the set's layout, exact refresh rates and saved window positions. A rule can watch several games or programs, hold their display mode while any is running and return after the last one closes. Brightness, picture presets, HDR and playback-device settings are optional.

The first public release is available now. It runs with the Windows PowerShell 5.1 included in Windows. Extract the release ZIP into a writable folder and start Displays.cmd. No installer, administrator rights or telemetry; MIT licensed and fully usable without payment. The scripts and locally compiled native cache are unsigned.

The core workflow has been tested on my three-display desktop. Fresh Windows installations and laptops, docks, multiple GPUs and identical panels still need validation. Monitor controls and wake behavior depend on the hardware.

Download, screenshots and setup guide: https://github.com/GentleMec/DeskModes

If you try it, please tell me whether switching away and back restores your layout, and which part of setup could be clearer. Bug reports and improvement ideas are welcome through the GitHub forms.
```

Use Release flair for the first public program release if offered. Read the live rules
and account restrictions first; the open-source rule is separate from the Wednesday
exception for other software. If AutoModerator removes the post, use the moderator
route described by the community rather than resubmitting.

## Moderator inquiry

Destination: [r/Windows11 moderators](https://www.reddit.com/message/compose?to=%2Fr%2FWindows11).
Subject: `May I share a free open-source display-workflow tool?`

```text
Hi! I develop DeskModes, a free MIT-licensed Windows tool for named display setups, hotkeys and automatic rules. I would like to share a short practical demo of switching between work screens and a gaming monitor, with a GitHub link and a request for setup feedback.

I saw that Windows compatibility alone does not make a post relevant here. Would this workflow fit your community, and is there a preferred flair or thread? I can leave donation links out of the post.

Project: https://github.com/GentleMec/DeskModes
Thanks!
```

Draft only. Wait for a reply before preparing a post for that community.

## Show HN: owner-written submission

The [moderator guidance](https://news.ycombinator.com/item?id=22336638) asks authors
to write HN text themselves without an LLM. Do not paste these drafts into HN or ask
an LLM to rewrite your HN text. Open https://news.ycombinator.com/submit and write your
own title and introduction using these factual notes:

- Title starts with Show HN; project URL: https://github.com/GentleMec/DeskModes.
- Personal reason: different Windows display setups for work, gaming and TV.
- Capabilities: named sets, hotkeys, saved geometry/refresh rates/window positions,
  multi-program rules and optional monitor/audio controls.
- Implementation: Windows PowerShell 5.1, Windows display APIs, WPF settings and tray menu.
- Download and use require no app account; submitting feedback requires GitHub sign-in.
- Three-display desktop tested; fresh Windows launch and other configurations have limits.
- Explain what you learned and what feedback you need, in your own words.

Read [Show HN rules](https://news.ycombinator.com/showhn.html). Be present for discussion;
do not frame it as a fundraiser, solicit votes or submit every small version update.

## Invitation to a willing tester

```text
I've released DeskModes, a free Windows tool for display modes, hotkeys and rules. If you use multiple monitors and have a few minutes, would you like to try it?

Download and setup: https://github.com/GentleMec/DeskModes

Start from a working Windows layout, create one mode, switch to it and back, then tell me whether the layout and window positions came back correctly. Please include your Windows version, monitor models and connection types, and the first thing that was confusing. Laptops, docks, multiple GPUs and identical panels are still experimental.

Ideas: https://github.com/GentleMec/DeskModes/issues/new?template=feature_request.yml
Bugs: https://github.com/GentleMec/DeskModes/issues/new?template=bug_report.yml

Trying it is completely optional. Thanks!
```

## Short post for an existing personal account

```text
DeskModes is out: a free, portable Windows tool for display modes, hotkeys and automatic rules. Save Work, Game or TV setups, then switch from the tray or a shortcut. Optional brightness, HDR and audio settings too.

Download + screenshots: https://github.com/GentleMec/DeskModes

What would you like it to make easier? Ideas and bug reports are welcome on GitHub.
```

Use where the owner's account and community rules fit. No workplace identity or private
work details are needed for the launch.

## Replies ready for GitHub and community comments

**A useful idea:**

```text
Thanks! Could you describe the workflow you'd like to make easier and what the app should do differently? You can put it in the suggestion form so it stays in one place: https://github.com/GentleMec/DeskModes/issues/new?template=feature_request.yml
```

**A report missing details:**

```text
Thanks for reporting this. Which DeskModes version are you using, what did you do just before it happened, and what did you expect? If the app opens, Settings → About → Copy diagnostics can help. Logs are optional; please remove private paths and hook commands before sharing them.
```

**A compatibility question:**

```text
The core workflow has been tested on my three-display desktop. I haven't verified that setup yet. Laptops, docks, multiple GPUs and identical panels are currently experimental. If you try it, please start from a working Windows layout and share the monitor models, connections and result.
```

**Does it cost anything?**

```text
DeskModes is free and open source under the MIT license. Donations are optional and the app remains fully usable without them: https://ko-fi.com/gentlemec
```

**Privacy:**

```text
The app makes no network requests. The optional activity diary is off by default and stored locally. Diagnostics are copied locally; nothing is submitted automatically. Feedback is posted only when you choose to share it on GitHub.
```

For a fix or workaround, add the actual verified version, issue and result before replying.
Do not promise dates or claim compatibility from one partial report.
