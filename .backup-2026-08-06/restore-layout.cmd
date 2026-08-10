@echo off
rem Restore the layout captured by save-layout.cmd.
if not exist "%~dp0profiles\all-three.cfg" (
  echo No snapshot yet. Turn on all three monitors, arrange them, run save-layout.cmd.
  pause
  exit /b 1
)
"%~dp0MultiMonitorTool.exe" /LoadConfig "%~dp0profiles\all-three.cfg"
