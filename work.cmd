@echo off
rem Switch to the combination named "work" in Settings. Which displays that is
rem lives in settings.json -> combos, and the taskbar goes to whichever display
rem its "primary" names -- nothing is hardcoded here.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-Display.ps1" work
