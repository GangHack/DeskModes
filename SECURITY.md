# Security

## Reporting a vulnerability

Use GitHub's **Report a vulnerability** button under this repository's *Security*
tab. That opens a private advisory only the maintainer can see. Please do not
open a public issue for something exploitable.

Expect a first reply within a week. If a fix is needed, the advisory is published
together with it.

## What is supported

The latest release. There are no maintained older branches — this is a single
folder of scripts, and updating means replacing it.

## What this tool actually is

Worth knowing before you look for a hole, because it narrows the surface a lot:

- **It makes no network connections.** Nothing is downloaded, nothing is sent, no
  telemetry, no update check.
- **Nothing is installed.** No service, no scheduled task, no registry keys of its
  own, no elevation. Startup, if you turn it on, is a shortcut in your own
  Startup folder. Deleting the folder uninstalls it.
- **It runs as you**, with your privileges, and changes only display
  configuration, and — when you ask for it — the default playback device and
  monitor brightness over DDC/CI.

## Where it does trust its input

Three places, all local and all by design. If you find a way to reach them from
outside the machine, that is a vulnerability and worth reporting:

- **`settings.json`** is read from the tool's own folder and is expected to be
  yours. It is parsed defensively — damaged JSON and nonsense values fall back to
  defaults rather than stopping the tool — but it is not a security boundary.
- **Commands before and after a switch, and rules**, run programs you name in the
  settings. That is the whole point of the feature: `hooks` launch whatever you
  put there, through `cmd` or `powershell` depending on the extension. Anyone who
  can write to your `settings.json` can already run code as you.
- **`native-*.dll`** is compiled on your machine from C# embedded in
  `DisplayCore.ps1`, cached next to the scripts, and named after a hash of that
  source. It is unsigned, so Smart App Control may refuse to load it; the tool
  then deletes it and compiles in memory instead. It is never downloaded.

## What is not a vulnerability

- The scripts are unsigned, and running them needs an execution policy that
  allows it. That is what the `.cmd` wrappers pass `-ExecutionPolicy Bypass` for,
  and it applies to the copy of the tool you already have on disk.
- `hooks` running a program you configured yourself.
- Anything requiring an attacker who can already write into the tool's folder or
  run code as your user.
