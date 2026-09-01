@echo off
rem Enable every connected monitor.
rem
rem || pause: on success the window closes at once, as it should; on a refusal it stays
rem long enough to be read. Without it the reason flashed past and the file looked broken.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-Display.ps1" all || pause
