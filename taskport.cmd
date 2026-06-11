@echo off
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0\taskport.ps1" -name "%~1"
pause


