@echo off
rem Work: both LG monitors, Asus goes to standby.
rem Primary is pinned to the ULTRAGEAR so a hotkey always lands the taskbar in the
rem same place. Both LGs now hang off the RTX 4080, so either one is fine here --
rem swap ULTRAGEAR for ULTRAFINE below, or drop -PrimaryMatch entirely to keep
rem whichever monitor happens to be primary already.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-Display.ps1" work -PrimaryMatch ULTRAGEAR
