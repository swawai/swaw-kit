@echo off & setlocal DisableDelayedExpansion
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0https-credential-guard.ps1" -Operation "%~1"
exit /b %ERRORLEVEL%
