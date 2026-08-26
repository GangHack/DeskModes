# Contributing

Thanks for looking. This is a small, opinionated tool, and the fastest way to get
a change in is to know the two files that answer most questions before you ask
them.

## Read this first

**[AGENTS.md](AGENTS.md)** — how things are done here and what people trip over.
It is short, and every rule in it cost someone an evening: comments are Russian
while the interface is English, display switching goes through the CCD API only,
a refresh rate is the driver's exact fraction, `.GetNewClosure()` is banned in
event handlers. Read it before the first edit, whether you are a person or an
agent.

**[docs/notes.ru.md](docs/notes.ru.md)** — the engineering diary, in Russian: a
day-by-day account of what Windows actually does, with measurements. When a
decision in the code looks arbitrary, this is usually where the evening that
produced it is written down. Section «Тупики, в которые не надо возвращаться»
lists the dead ends, so you do not have to find them again.

## One command decides whether you are done

```powershell
.\tools\check.ps1
```

Four gates, non-zero exit on any failure: every script parses, every `.ps1` is
UTF-8 with BOM and CRLF, PSScriptAnalyzer is clean, and the test suite passes.
Nothing else counts as verification — in particular, "the tests passed" is not
enough, because two scripts in this repository are dot-sourced by nothing and a
typo in them survives until somebody runs them by hand.

PSScriptAnalyzer is used *if you have it* and is never installed by the tool:

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
```

CI runs the same command with `-RequireAnalyzer`, so a missing analyzer is a
failure there and a warning here.

## Pull requests

- **One change per pull request.** A diff that can be read is a diff that can be
  reviewed.
- **A test for anything that can be tested.** Add a `Test-Case` block to the
  matching file in `tests/cases/`, and name it as a sentence about behaviour —
  the name is what a failure prints. See [AGENTS.md](AGENTS.md) for how the
  orchestrator tests shadow functions instead of adding a seam to the code.
- **Comments say *why*, and name the real breakage.** Comment density here is a
  style choice; a comment that restates the line below it is worse than none.
- **Do not add a dependency.** Not a module, not a NuGet package, not Pester.
  "Nothing is installed on your system, the folder can just be deleted" is a
  promise to the user, and it is why there is no build step.
- Commit subjects in this repository are Russian and say what changed in meaning.
  A pull request description in English is fine and welcome.

## If it involves your hardware

Most of the value of this project is behaviour on real displays, and it has been
run on very few desks. If you hit a refusal, a mode that will not apply, or a
monitor that will not come back, that is interesting even without a fix:

1. Run `.\Set-Display.ps1 status` and paste the first line — it names the
   version, the Windows build and the PowerShell version.
2. Attach the relevant part of `last-run.log`. Failures are logged with the
   reason, and the `done:` line carries the timings.
3. Say what the display is and how it is plugged in. The short Monitor ID differs
   between a monitor's DisplayPort and HDMI inputs, and that alone explains a
   surprising number of reports.

`.\tests\live.ps1 -ReadOnly` is a safe read-only smoke check. The full
`.\tests\live.ps1` switches through every mode on your real desk and puts it
back — useful, and it will blink your screens.
