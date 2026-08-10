@echo off
rem Start the tray switcher without leaving a console window behind.
start "" /min powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Displays.ps1"
