@echo off
rem — call the PS script in the same folder, passing the wildcard pattern —
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0porttask.ps1" -Pattern "%~1"
pause
