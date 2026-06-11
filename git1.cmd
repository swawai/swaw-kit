@echo off

setlocal


set "GIT_SSH_COMMAND=ssh -o IdentitiesOnly=yes -i C:/Users/pc/.ssh/id_ed25519"


git %*


set "EXITCODE=%ERRORLEVEL%"


endlocal & exit /b %EXITCODE%
