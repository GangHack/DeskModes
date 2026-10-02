# Launch content checklist

Use a real interface image for the first post. A short real-desktop demo can follow.

## Screenshots ready to attach

| Asset | Purpose | Caption |
| --- | --- | --- |
| [Modes](https://raw.githubusercontent.com/GentleMec/DeskModes/main/docs/images/settings-modes.png) | First post and GitHub hero | Named display modes and hotkeys. Current interface with an example desk. |
| [Rules](https://raw.githubusercontent.com/GentleMec/DeskModes/main/docs/images/settings-rules.png) | Automation follow-up or second image | Rules select a mode for running programs, idle time or connected displays. Example configuration. |
| [Rule editor](https://raw.githubusercontent.com/GentleMec/DeskModes/main/docs/images/settings-rule.png) | Explain multi-program rules | Choose programs and the display mode a rule should use. Example configuration. |
| [Your desk](https://raw.githubusercontent.com/GentleMec/DeskModes/main/docs/images/settings.png) | Layout questions | Live Windows geometry and switching configuration have separate controls. Example desk. |
| [About](https://raw.githubusercontent.com/GentleMec/DeskModes/main/docs/images/settings-about.png) | Help and diagnostics instructions | Help and diagnostic controls in current source. The optional Support card is below this view; the 1.0.1 download has no Support button. |

Files are also in `docs/images/`. They are rendered from the real WPF interface with
invented monitors. They show the interface, not successful switching or support for
those models. No personal desktop, logs or settings are shown. Use one main image and
at most one extra image per first post.

## Real demo: 20–25 seconds

Owner recording is still needed. A camera showing the physical screens makes the
switch visible; a recording of one Windows screen cannot establish which panels are lit.
Start with two known working modes and a recovery mode already configured. Close
personal documents and notifications. Use ordinary sample windows.

| Time | Shot | On-screen caption |
| --- | --- | --- |
| 0–3 s | Work screens visible, sample windows arranged | Your work setup. |
| 3–6 s | Show Modes and the chosen shortcut briefly | Save a display mode. Give it a hotkey. |
| 6–11 s | Press the actual Game shortcut; keep screens in frame | Switch to your gaming setup. |
| 11–16 s | Use Back; show work layout and window positions | Back to your previous desk. |
| 16–21 s | Show Rules and a multi-program rule without implying it ran | Automate it with rules. |
| 21–25 s | End on Modes or the real desk | Free and open source. github.com/GentleMec/DeskModes |

Let transitions finish. Use the actual configured shortcuts; screenshot bindings are
examples. Do not edit a failed switch into an apparently successful result. If recovery
is needed, keep the report and resolve it before presenting the clip as successful.

Optional voiceover:

```text
DeskModes saves your Windows display setups. Use a hotkey to move from work screens to a gaming monitor, then go back to your previous desk. You can also automate modes with rules and add brightness or audio settings. It's free and open source.
```

Suggested file: `deskmodes-work-game-back.mp4`, 1080p, H.264, no music required. Keep
original footage with the exported clip. Time captions to the actual recording.

## Optional second demo: rules

Show a rule watching two harmless programs. Start one, then the other. Close the first
and show the mode stays; close the last and show the return. Record actual behavior
before using the caption "Returns after the last program closes." Automated tests alone
do not accept this native scenario.

## Before attaching content

- Check labels and shortcuts at normal viewing size.
- Include a download link and one concrete feedback question.
- Qualify optional monitor controls by hardware support.
- Do not claim all panels wake, every dock works or Windows warnings are bypassed.
- Record post URL, date, content and feedback in [the launch log](https://github.com/GentleMec/DeskModes/blob/main/docs/launch-log.md).
