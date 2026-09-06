@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-Display.ps1" diagnostics
pause
