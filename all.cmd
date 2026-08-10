@echo off
rem Enable every connected monitor.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-Display.ps1" all
