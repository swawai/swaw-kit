@echo off
echo [ERROR] This Git identity is configured for HTTPS access; SSH access is disabled.>&2
echo Use a matching HTTPS origin or an SSH identity entry.>&2
exit /b 1
