# DeskModes 1.0.1

Save your Windows display setups and switch between Work, Game or TV with a hotkey.
DeskModes remembers layouts, refresh rates and window positions. Optional rules can
hold a mode while any selected program is running and return after the last one closes.
Brightness, picture presets, HDR and playback-device settings are available where supported.

**Start:** download **DeskModes-1.0.1.zip** below, extract the whole archive into a writable
folder and double-click **Displays.cmd**. Follow First steps and create a mode.
Windows 10/11 with Windows PowerShell 5.1; no installer, administrator rights or app account.
Free and open source, with no telemetry. The scripts and locally compiled native cache are unsigned.

The attached `.sha256` file checks the ZIP's bytes. In the download folder:

```powershell
Get-FileHash .\DeskModes-1.0.1.zip -Algorithm SHA256
Get-Content .\DeskModes-1.0.1.zip.sha256
```

Compare the two hashes before extracting.

**Validation:** automated checks and Windows CI passed; exact mode round trips were tested
on the author's three-display desktop, with manual UltraFine power-on and an isolated
portable overlay. Fresh Windows 10/11 launch, whole-computer suspend/resume and the full
native UI/accessibility matrix remain unverified. Laptop, dock, multiple-GPU and identical-panel
setups are experimental. Monitor controls and wake depend on the hardware and connection.

[Screenshots and setup](https://github.com/GentleMec/DeskModes) ·
[Report a bug](https://github.com/GentleMec/DeskModes/issues/new?template=bug_report.yml) ·
[Suggest an improvement](https://github.com/GentleMec/DeskModes/issues/new?template=feature_request.yml)

[Full version changelog](https://github.com/GentleMec/DeskModes/blob/v1.0.1/CHANGELOG.md) ·
[Recorded validation](https://github.com/GentleMec/DeskModes/blob/main/docs/release-readiness.md)

If the app helps you, [buy me a coffee](https://ko-fi.com/gentlemec). Support is optional.
