@echo off
rem Switch to the combination named "work" in Settings. Which displays that is
rem lives in settings.json -> combos, and the taskbar goes to whichever display
rem its "primary" names -- nothing is hardcoded here.
rem
rem There is no such combination until you create one, and then this says so and waits to be
rem read (|| pause) instead of closing the window on the answer.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-Display.ps1" work || pause
