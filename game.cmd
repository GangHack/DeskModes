@echo off
rem Switch to the displays you gave the "game" group in Settings. A group of one
rem works too: the name resolves to that display's own mode.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-Display.ps1" game
