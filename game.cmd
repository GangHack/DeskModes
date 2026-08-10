@echo off
rem Game: Asus ROG only, both LG monitors go to standby.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-Display.ps1" game
