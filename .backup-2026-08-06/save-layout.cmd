@echo off
rem Snapshot the current layout: which monitors are on, which is primary,
rem resolutions and positions. Run this once all three monitors are plugged in
rem and arranged the way you want; restore-layout.cmd brings that exact
rem picture back, positions included.
if not exist "%~dp0profiles" mkdir "%~dp0profiles"
"%~dp0MultiMonitorTool.exe" /SaveConfig "%~dp0profiles\all-three.cfg"
echo Saved: %~dp0profiles\all-three.cfg
pause
