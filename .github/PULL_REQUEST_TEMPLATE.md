# What this changes

<!-- What the tool does differently now, in a sentence or two. Not which files
     were touched — that is what the diff is for. -->

## How it was checked

<!-- `.\tools\check.ps1` is the answer to "am I done". If the change touches the
     switch path, DDC or hotplug behaviour, say what happened on a real desk —
     `.\tests\live.ps1` exists for that, and no fake reproduces a driver. -->

- [ ] `.\tools\check.ps1` passes
- [ ] Tried on real hardware, if it touches displays (say which monitors, and how connected)

## House rules

The full set is in [AGENTS.md](https://github.com/GangHack/DeskModes/blob/main/AGENTS.md); these are the ones people trip over:

- [ ] Code, comments, logs and documentation in English; interface translations in `lang/`
- [ ] Every `.ps1` is UTF-8 **with BOM** and CRLF, and starts with `#Requires -Version 5.1` if it is run directly
- [ ] No new dependency — no module, no package, no Pester
- [ ] Settings read and written through `Get-ActiveSettings` / `Set-ActiveSettings`, never `$script:Settings` inside a handler
- [ ] No `.GetNewClosure()` in a WPF or WinForms handler — logic goes in a function
- [ ] Dates and percentages formatted through `InvariantCulture`
- [ ] A `CHANGELOG.md` entry, if a person would notice the change
- [ ] Comments say *why*, and name the real breakage
