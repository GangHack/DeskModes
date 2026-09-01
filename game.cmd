@echo off
rem Switch to the combination named "game" in Settings. A combination of one
rem works too: the name resolves to that display's own mode.
rem
rem There is no such combination until you create one, and then this says so and waits to be
rem read (|| pause) instead of closing the window on the answer.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-Display.ps1" game || pause
