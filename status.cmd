@echo off
rem Show what Windows sees right now (read-only).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-Display.ps1" status
pause
