@echo off
rem Double-click launcher. Runs the GUI, which then asks for administrator rights itself.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0NoTestModeWM.ps1"
