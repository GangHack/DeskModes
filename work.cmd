@echo off
rem Switch to the displays you gave the "work" group in Settings.
rem Which displays those are lives in settings.json -> roles, and the taskbar
rem goes to whichever display "primary" names -- nothing is hardcoded here.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-Display.ps1" work
