@echo off & setlocal DisableDelayedExpansion
echo [ERROR] Interactive credential prompts are disabled for this Git identity.>&2
echo Use its configured access, or run the matching entry's ".https login" first.>&2
exit /b 1
