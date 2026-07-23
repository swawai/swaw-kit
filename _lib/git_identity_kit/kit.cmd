@echo off
chcp 65001 >nul <nul
setlocal DisableDelayedExpansion

if not defined GIT_ID_ENTRY_COMMAND set "GIT_ID_ENTRY_COMMAND=git_identity"

if "%~1"=="" goto :LaunchDefaultTerminal
if "%~1"=="-h" goto :ShowHelp
if /i "%~1"=="--help" goto :ShowHelp
if "%~1"=="/?" goto :ShowHelp

if /i "%~1"==".help" goto :ShowHelp
if /i "%~1"==".info" goto :WhoAmI
if /i "%~1"==".sync" goto :Sync
if /i "%~1"==".https" goto :HttpsCommand
if /i "%~1"==".origin" goto :OriginProtocol
if /i "%~1"==".code" goto :LaunchCode
if /i "%~1"==".cursor" goto :LaunchCursor
if /i "%~1"==".gitbash" goto :LaunchGitBash
if /i "%~1"==".cmd" goto :LaunchCmd
if /i "%~1"==".powershell" goto :LaunchPowerShell
if /i "%~1"==".pwsh" goto :LaunchPwsh

:ValidateGitArguments
if "%~1"=="" goto :RunGit
set "GIT_ID_GIT_ARGUMENT=%~1"
if "%GIT_ID_GIT_ARGUMENT%"=="-c" goto :UnsupportedGitOverride
if "%GIT_ID_GIT_ARGUMENT:~0,2%"=="-c" goto :UnsupportedGitOverride
if "%GIT_ID_GIT_ARGUMENT%"=="-C" goto :UnsupportedGitOverride
if "%GIT_ID_GIT_ARGUMENT:~0,2%"=="-C" goto :UnsupportedGitOverride
if /i "%GIT_ID_GIT_ARGUMENT%"=="--git-dir" goto :UnsupportedGitOverride
if /i "%GIT_ID_GIT_ARGUMENT:~0,10%"=="--git-dir=" goto :UnsupportedGitOverride
if /i "%GIT_ID_GIT_ARGUMENT%"=="--work-tree" goto :UnsupportedGitOverride
if /i "%GIT_ID_GIT_ARGUMENT:~0,12%"=="--work-tree=" goto :UnsupportedGitOverride
if /i "%GIT_ID_GIT_ARGUMENT%"=="--bare" goto :UnsupportedGitOverride
if /i "%GIT_ID_GIT_ARGUMENT%"=="--config-env" goto :UnsupportedGitOverride
if /i "%GIT_ID_GIT_ARGUMENT:~0,13%"=="--config-env=" goto :UnsupportedGitOverride
if /i "%GIT_ID_GIT_ARGUMENT%"=="--exec-path" goto :UnsupportedGitOverride
if /i "%GIT_ID_GIT_ARGUMENT:~0,12%"=="--exec-path=" goto :UnsupportedGitOverride
if /i "%GIT_ID_GIT_ARGUMENT%"=="--namespace" goto :UnsupportedGitOverride
if /i "%GIT_ID_GIT_ARGUMENT%"=="--super-prefix" goto :UnsupportedGitOverride
if /i "%GIT_ID_GIT_ARGUMENT%"=="--list-cmds" goto :UnsupportedGitOverride
if /i "%GIT_ID_GIT_ARGUMENT%"=="--attr-source" goto :UnsupportedGitOverride
if "%GIT_ID_GIT_ARGUMENT%"=="--" goto :RunGit
if "%GIT_ID_GIT_ARGUMENT%"=="-p" goto :ConsumeGitGlobalArgument
if /i "%GIT_ID_GIT_ARGUMENT%"=="--paginate" goto :ConsumeGitGlobalArgument
if "%GIT_ID_GIT_ARGUMENT%"=="-P" goto :ConsumeGitGlobalArgument
if /i "%GIT_ID_GIT_ARGUMENT%"=="--no-pager" goto :ConsumeGitGlobalArgument
if /i "%GIT_ID_GIT_ARGUMENT%"=="--no-replace-objects" goto :ConsumeGitGlobalArgument
if /i "%GIT_ID_GIT_ARGUMENT%"=="--literal-pathspecs" goto :ConsumeGitGlobalArgument
if /i "%GIT_ID_GIT_ARGUMENT%"=="--glob-pathspecs" goto :ConsumeGitGlobalArgument
if /i "%GIT_ID_GIT_ARGUMENT%"=="--noglob-pathspecs" goto :ConsumeGitGlobalArgument
if /i "%GIT_ID_GIT_ARGUMENT%"=="--icase-pathspecs" goto :ConsumeGitGlobalArgument
if /i "%GIT_ID_GIT_ARGUMENT%"=="--no-optional-locks" goto :ConsumeGitGlobalArgument
if /i "%GIT_ID_GIT_ARGUMENT%"=="--no-lazy-fetch" goto :ConsumeGitGlobalArgument
if /i "%GIT_ID_GIT_ARGUMENT%"=="--no-advice" goto :ConsumeGitGlobalArgument
if "%GIT_ID_GIT_ARGUMENT%"=="-v" goto :ConsumeGitGlobalArgument
if /i "%GIT_ID_GIT_ARGUMENT%"=="--version" goto :ConsumeGitGlobalArgument
if "%GIT_ID_GIT_ARGUMENT%"=="-h" goto :ConsumeGitGlobalArgument
if /i "%GIT_ID_GIT_ARGUMENT%"=="--help" goto :ConsumeGitGlobalArgument
if /i "%GIT_ID_GIT_ARGUMENT%"=="--html-path" goto :ConsumeGitGlobalArgument
if /i "%GIT_ID_GIT_ARGUMENT%"=="--man-path" goto :ConsumeGitGlobalArgument
if /i "%GIT_ID_GIT_ARGUMENT%"=="--info-path" goto :ConsumeGitGlobalArgument
if "%GIT_ID_GIT_ARGUMENT:~0,1%"=="-" goto :UnsupportedGitOverride
if /i "%GIT_ID_GIT_ARGUMENT%"=="clone" goto :StartValidateCloneArguments
goto :RunGit

:ConsumeGitGlobalArgument
shift
goto :ValidateGitArguments

:StartValidateCloneArguments
shift
:ValidateCloneArguments
if "%~1"=="" goto :RunGit
set "GIT_ID_GIT_ARGUMENT=%~1"
if "%GIT_ID_GIT_ARGUMENT%"=="--" goto :RunGit
if "%GIT_ID_GIT_ARGUMENT%"=="-c" goto :UnsupportedGitOverride
if "%GIT_ID_GIT_ARGUMENT:~0,2%"=="-c" goto :UnsupportedGitOverride
if /i "%GIT_ID_GIT_ARGUMENT%"=="--config" goto :UnsupportedGitOverride
shift
goto :ValidateCloneArguments

:RunGit
set "GIT_ID_GIT_ARGUMENT="
call :PrepareIdentity
if errorlevel 1 exit /b %ERRORLEVEL%

git %*
exit /b %ERRORLEVEL%

:UnsupportedGitOverride
echo [ERROR] Git repository and config override options are not supported by this identity entry.
echo Change directory first; only known value-free Git global options are accepted before the subcommand, and clone -c/--config is disabled.
exit /b 1

:LaunchDefaultTerminal
if not defined GIT_ID_DEFAULT_TERMINAL goto :LaunchCmd
if /i "%GIT_ID_DEFAULT_TERMINAL%"=="cmd" goto :LaunchCmd
if /i "%GIT_ID_DEFAULT_TERMINAL%"=="powershell" goto :LaunchPowerShell
if /i "%GIT_ID_DEFAULT_TERMINAL%"=="pwsh" goto :LaunchPwsh
if /i "%GIT_ID_DEFAULT_TERMINAL%"=="gitbash" goto :LaunchGitBash
echo [ERROR] Invalid GIT_ID_DEFAULT_TERMINAL: %GIT_ID_DEFAULT_TERMINAL%
echo Use cmd, powershell, pwsh, or gitbash.
exit /b 1

:ShowHelp
if not "%~3"=="" goto :InvalidHelpCommand
if "%~2"=="" goto :RunHelp
if /i "%~2"=="zh" goto :RunHelp
if /i "%~2"=="zh-CN" goto :RunHelp
if /i "%~2"=="en" goto :RunHelp
goto :InvalidHelpCommand

:RunHelp
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0help.ps1" -CommandName "%GIT_ID_ENTRY_COMMAND%" -Language "%~2"
exit /b %ERRORLEVEL%

:InvalidHelpCommand
echo [ERROR] Use "%GIT_ID_ENTRY_COMMAND% .help", ".help zh", or ".help en".
exit /b 1

:WhoAmI
call :PrepareIdentity
if errorlevel 1 exit /b %ERRORLEVEL%

if not "%~2"=="" goto :WhoAmIUnknownOption

PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0info.ps1"
exit /b %ERRORLEVEL%

:WhoAmIUnknownOption
echo [ERROR] Unrecognized .info option: %~2
echo Run "%GIT_ID_ENTRY_COMMAND% --help" for examples.
exit /b 1

:Sync
set "GIT_ID_SYNC_MODE=write"
if "%~2"=="" goto :SyncPrepare
if /i "%~2"=="--dry-run" set "GIT_ID_SYNC_MODE=dry-run" & goto :SyncPrepare
if /i "%~2"=="--clear" set "GIT_ID_SYNC_MODE=clear" & goto :RunSync
echo [ERROR] Unrecognized .sync option: %~2
echo Run "%GIT_ID_ENTRY_COMMAND% --help" for examples.
exit /b 1

:SyncPrepare
call :PrepareIdentity
if errorlevel 1 exit /b %ERRORLEVEL%

:RunSync
if not "%~3"=="" (
    echo [ERROR] Too many .sync arguments.
    echo Run "%GIT_ID_ENTRY_COMMAND% --help" for examples.
    exit /b 1
)
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync.ps1" -Mode "%GIT_ID_SYNC_MODE%" -EntryCommand "%GIT_ID_ENTRY_COMMAND%" -EntryFile "%GIT_ID_ENTRY_FILE%"
exit /b %ERRORLEVEL%

:HttpsCommand
if /i not "%~2"=="login" goto :InvalidHttpsCommand
if not "%~3"=="" goto :InvalidHttpsCommand
call :PrepareIdentity
if errorlevel 1 exit /b %ERRORLEVEL%
if not defined GIT_ID_HTTPS_PROVIDER goto :MissingHttpsAccess
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0https-auth.ps1" -Provider "%GIT_ID_HTTPS_PROVIDER%" -AccountHost "%GIT_ID_HTTPS_HOST%" -ExpectedAccount "%GIT_ID_HTTPS_ACCOUNT%" -Namespace "%GIT_ID_CREDENTIAL_NAMESPACE%"
exit /b %ERRORLEVEL%

:MissingHttpsAccess
echo [ERROR] "%GIT_ID_ENTRY_COMMAND% .https login" requires HTTPS access.
echo Set GIT_ID_ACCESS to https.github:host=HOST;account=ACCOUNT or https.gitlab:host=HOST;account=ACCOUNT.
exit /b 1

:InvalidHttpsCommand
echo [ERROR] Use "%GIT_ID_ENTRY_COMMAND% .https login".
exit /b 1

:OriginProtocol
if not "%~3"=="" goto :InvalidOriginProtocolCommand
if /i "%~2"=="ssh" goto :RunOriginProtocol
if /i "%~2"=="https" goto :RunOriginProtocol
goto :InvalidOriginProtocolCommand

:RunOriginProtocol
call :PrepareIdentity
if errorlevel 1 exit /b %ERRORLEVEL%
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0remote-protocol.ps1" -Protocol "%~2"
exit /b %ERRORLEVEL%

:InvalidOriginProtocolCommand
echo [ERROR] Use "%GIT_ID_ENTRY_COMMAND% .origin ssh" or "%GIT_ID_ENTRY_COMMAND% .origin https".
exit /b 1

:LaunchCode
call :PrepareIdentity
if errorlevel 1 exit /b %ERRORLEVEL%
if /i "%WIN_RUN_EDITOR_BOOTSTRAP%"=="code" goto :LaunchCodeWithBootstrap
set "WIN_RUN_EDITOR_BOOTSTRAP="
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0editor-launch.ps1" -Tool "code" -DropFirst %*
exit /b %ERRORLEVEL%

:LaunchCodeWithBootstrap
set "WIN_RUN_EDITOR_BOOTSTRAP="
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0editor-launch.ps1" -Tool "code" -DropFirst -ReuseBootstrapWindow %*
exit /b %ERRORLEVEL%

:LaunchCursor
call :PrepareIdentity
if errorlevel 1 exit /b %ERRORLEVEL%
if /i "%WIN_RUN_EDITOR_BOOTSTRAP%"=="cursor" goto :LaunchCursorWithBootstrap
set "WIN_RUN_EDITOR_BOOTSTRAP="
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0editor-launch.ps1" -Tool "cursor" -DropFirst %*
exit /b %ERRORLEVEL%

:LaunchCursorWithBootstrap
set "WIN_RUN_EDITOR_BOOTSTRAP="
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0editor-launch.ps1" -Tool "cursor" -DropFirst -ReuseBootstrapWindow %*
exit /b %ERRORLEVEL%

:LaunchGitBash
call :PrepareIdentity
if errorlevel 1 exit /b %ERRORLEVEL%
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1" -Tool "gitbash" -DropFirst %*
exit /b %ERRORLEVEL%

:LaunchCmd
call :PrepareIdentity
if errorlevel 1 exit /b %ERRORLEVEL%
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1" -Tool "cmd" -DropFirst %*
exit /b %ERRORLEVEL%

:LaunchPowerShell
call :PrepareIdentity
if errorlevel 1 exit /b %ERRORLEVEL%
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1" -Tool "powershell" -DropFirst %*
exit /b %ERRORLEVEL%

:LaunchPwsh
call :PrepareIdentity
if errorlevel 1 exit /b %ERRORLEVEL%
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1" -Tool "pwsh" -DropFirst %*
exit /b %ERRORLEVEL%

:PrepareIdentity
if not defined GIT_ID_NAME goto :MissingIdentity
if not defined GIT_ID_EMAIL goto :MissingIdentity

set "GIT_DIR="
set "GIT_EXEC_PATH="
set "GIT_WORK_TREE="
set "GIT_COMMON_DIR="
set "GIT_INDEX_FILE="
set "GIT_OBJECT_DIRECTORY="
set "GIT_ALTERNATE_OBJECT_DIRECTORIES="
set "GIT_CEILING_DIRECTORIES="
set "GIT_DISCOVERY_ACROSS_FILESYSTEM="
set "GIT_NAMESPACE="
set "GIT_CONFIG="
set "GIT_CONFIG_SYSTEM="
set "GIT_CONFIG_GLOBAL="
set "GIT_CONFIG_NOSYSTEM="
set "GIT_CONFIG_PARAMETERS="
set "GIT_CONFIG_COUNT=0"
set "GIT_SSL_CERT="
set "GIT_SSL_KEY="
set "GIT_SSL_CERT_PASSWORD_PROTECTED="

set "GIT_AUTHOR_NAME=%GIT_ID_NAME%"
set "GIT_AUTHOR_EMAIL=%GIT_ID_EMAIL%"
set "GIT_COMMITTER_NAME=%GIT_ID_NAME%"
set "GIT_COMMITTER_EMAIL=%GIT_ID_EMAIL%"

call :PrepareAccess
if errorlevel 1 exit /b %ERRORLEVEL%
call :PrepareSigning
if errorlevel 1 exit /b %ERRORLEVEL%

set "GIT_CONFIG_PARAMETERS='credential.helper'=''"
set "GIT_CONFIG_COUNT=0"
set "GIT_ID_CREDENTIAL_NAMESPACE="
call :AssertAuthorizationBoundary
if errorlevel 1 exit /b %ERRORLEVEL%
if defined GIT_ID_HTTPS_PROVIDER call :PrepareCredentialNamespace
if errorlevel 1 exit /b %ERRORLEVEL%

if defined GIT_ID_HTTPS_PROVIDER set "GIT_ID_HTTPS_CREDENTIAL_HELPER_QUOTED=%GIT_ID_HTTPS_CREDENTIAL_HELPER:'='\''%"
if defined GIT_ID_HTTPS_PROVIDER set "GIT_CONFIG_PARAMETERS=%GIT_CONFIG_PARAMETERS% 'credential.helper'='%GIT_ID_HTTPS_CREDENTIAL_HELPER_QUOTED%'"
set "GIT_ID_CONFIG_KEY=transfer.credentialsInUrl" & set "GIT_ID_CONFIG_VALUE=die" & call :AddGitConfig
set "GIT_ID_CONFIG_KEY=user.name" & set "GIT_ID_CONFIG_VALUE=%GIT_ID_NAME%" & call :AddGitConfig
set "GIT_ID_CONFIG_KEY=user.email" & set "GIT_ID_CONFIG_VALUE=%GIT_ID_EMAIL%" & call :AddGitConfig
if /i "%GIT_ID_SIGNING_ENABLED%"=="true" set "GIT_ID_CONFIG_KEY=user.signingkey" & if /i "%GIT_ID_SIGNING_ENABLED%"=="true" set "GIT_ID_CONFIG_VALUE=%GIT_ID_SIGNING_KEY%" & if /i "%GIT_ID_SIGNING_ENABLED%"=="true" call :AddGitConfig
if /i "%GIT_ID_SIGNING_ENABLED%"=="true" set "GIT_ID_CONFIG_KEY=gpg.format" & if /i "%GIT_ID_SIGNING_ENABLED%"=="true" set "GIT_ID_CONFIG_VALUE=%GIT_ID_GPG_FORMAT%" & if /i "%GIT_ID_SIGNING_ENABLED%"=="true" call :AddGitConfig
set "GIT_ID_CONFIG_KEY=commit.gpgSign" & set "GIT_ID_CONFIG_VALUE=%GIT_ID_SIGNING_ENABLED%" & call :AddGitConfig
set "GIT_ID_CONFIG_KEY=tag.gpgSign" & set "GIT_ID_CONFIG_VALUE=false" & call :AddGitConfig

set "GCM_NAMESPACE="
set "GCM_INTERACTIVE="
set "GCM_CREDENTIAL_STORE="
set "GCM_PROVIDER="
set "GCM_GITHUB_AUTHMODES="
set "GCM_GITLAB_AUTHMODES="
set "GCM_TRACE="
set "GCM_TRACE_SECRETS=false"
set "GIT_TRACE_REDACT=1"
set "GIT_TERMINAL_PROMPT=0"

if defined GIT_ID_HTTPS_PROVIDER set "GCM_NAMESPACE=%GIT_ID_CREDENTIAL_NAMESPACE%"
if defined GIT_ID_HTTPS_PROVIDER set "GCM_INTERACTIVE=false"
if defined GIT_ID_HTTPS_PROVIDER set "GCM_CREDENTIAL_STORE=wincredman"
if defined GIT_ID_HTTPS_PROVIDER set "GIT_ID_CONFIG_KEY=credential.namespace" & if defined GIT_ID_HTTPS_PROVIDER set "GIT_ID_CONFIG_VALUE=%GIT_ID_CREDENTIAL_NAMESPACE%" & if defined GIT_ID_HTTPS_PROVIDER call :AddGitConfig
if defined GIT_ID_HTTPS_PROVIDER set "GIT_ID_CONFIG_KEY=credential.credentialStore" & if defined GIT_ID_HTTPS_PROVIDER set "GIT_ID_CONFIG_VALUE=wincredman" & if defined GIT_ID_HTTPS_PROVIDER call :AddGitConfig
if defined GIT_ID_HTTPS_PROVIDER set "GIT_ID_CONFIG_KEY=credential.interactive" & if defined GIT_ID_HTTPS_PROVIDER set "GIT_ID_CONFIG_VALUE=false" & if defined GIT_ID_HTTPS_PROVIDER call :AddGitConfig
if defined GIT_ID_HTTPS_PROVIDER set "GIT_ID_CONFIG_KEY=credential.https://%GIT_ID_HTTPS_HOST%.provider" & if defined GIT_ID_HTTPS_PROVIDER set "GIT_ID_CONFIG_VALUE=%GIT_ID_HTTPS_PROVIDER%" & if defined GIT_ID_HTTPS_PROVIDER call :AddGitConfig
if defined GIT_ID_HTTPS_PROVIDER set "GIT_ID_CONFIG_KEY=credential.https://%GIT_ID_HTTPS_HOST%.username" & if defined GIT_ID_HTTPS_PROVIDER set "GIT_ID_CONFIG_VALUE=%GIT_ID_HTTPS_CREDENTIAL_USER%" & if defined GIT_ID_HTTPS_PROVIDER call :AddGitConfig
set "GIT_ID_CONFIG_KEY="
set "GIT_ID_CONFIG_VALUE="
set "GIT_ID_HTTPS_CREDENTIAL_HELPER_QUOTED="
exit /b 0

:PrepareAccess
set "GIT_ID_TRANSPORT="
set "GIT_ID_HTTPS_PROVIDER="
set "GIT_ID_HTTPS_HOST="
set "GIT_ID_HTTPS_ACCOUNT="
set "GIT_ID_HTTPS_CREDENTIAL_USER="
set "GIT_ID_HTTPS_CREDENTIAL_GUARD="
set "GIT_ID_HTTPS_CREDENTIAL_HELPER="
set "GIT_ID_ACCESS_TAG="
set "GIT_ID_ACCESS_TARGET="
set "GIT_ID_HTTPS_HOST_FIELD="
set "GIT_ID_HTTPS_ACCOUNT_FIELD="
set "GIT_ID_ACCESS_EXTRA="
set "GIT_SSH="
set "GIT_SSH_COMMAND="
set "GIT_SSH_VARIANT=ssh"
set "GIT_ASKPASS="
set "SSH_ASKPASS="
if not defined GIT_ID_ACCESS goto :MissingAccess

for /f "tokens=1,* delims=:" %%A in ("%GIT_ID_ACCESS%") do (
    set "GIT_ID_ACCESS_TAG=%%A"
    set "GIT_ID_ACCESS_TARGET=%%B"
)
if /i "%GIT_ID_ACCESS_TAG%"=="ssh" goto :PrepareSshAccess
if /i "%GIT_ID_ACCESS_TAG%"=="https.github" goto :PrepareGithubAccess
if /i "%GIT_ID_ACCESS_TAG%"=="https.gitlab" goto :PrepareGitlabAccess
goto :InvalidAccess

:PrepareGithubAccess
set "GIT_ID_HTTPS_PROVIDER=github"
goto :PrepareHttpsAccess

:PrepareGitlabAccess
set "GIT_ID_HTTPS_PROVIDER=gitlab"
goto :PrepareHttpsAccess

:PrepareHttpsAccess
set "GIT_ID_TRANSPORT=https"
if not "%GIT_ID_ACCESS%"=="%GIT_ID_ACCESS: =%" goto :InvalidAccess

for /f "tokens=1,2,* delims=;" %%A in ("%GIT_ID_ACCESS_TARGET%") do (
    set "GIT_ID_HTTPS_HOST_FIELD=%%A"
    set "GIT_ID_HTTPS_ACCOUNT_FIELD=%%B"
    set "GIT_ID_ACCESS_EXTRA=%%C"
)
if not defined GIT_ID_HTTPS_HOST_FIELD goto :InvalidAccess
if not defined GIT_ID_HTTPS_ACCOUNT_FIELD goto :InvalidAccess
if defined GIT_ID_ACCESS_EXTRA goto :InvalidAccess
if /i not "%GIT_ID_HTTPS_HOST_FIELD:~0,5%"=="host=" goto :InvalidAccess
if /i not "%GIT_ID_HTTPS_ACCOUNT_FIELD:~0,8%"=="account=" goto :InvalidAccess
set "GIT_ID_HTTPS_HOST=%GIT_ID_HTTPS_HOST_FIELD:~5%"
set "GIT_ID_HTTPS_ACCOUNT=%GIT_ID_HTTPS_ACCOUNT_FIELD:~8%"
if not defined GIT_ID_HTTPS_HOST goto :InvalidAccess
if not defined GIT_ID_HTTPS_ACCOUNT goto :InvalidAccess
if /i not "%GIT_ID_ACCESS_TARGET%"=="host=%GIT_ID_HTTPS_HOST%;account=%GIT_ID_HTTPS_ACCOUNT%" goto :InvalidAccess
if not "%GIT_ID_HTTPS_HOST%"=="%GIT_ID_HTTPS_HOST:/=%" goto :InvalidAccess
if not "%GIT_ID_HTTPS_HOST%"=="%GIT_ID_HTTPS_HOST:\=%" goto :InvalidAccess
if not "%GIT_ID_HTTPS_ACCOUNT%"=="%GIT_ID_HTTPS_ACCOUNT:/=%" goto :InvalidAccess
if not "%GIT_ID_HTTPS_ACCOUNT%"=="%GIT_ID_HTTPS_ACCOUNT:\=%" goto :InvalidAccess
if /i "%GIT_ID_HTTPS_PROVIDER%"=="github" set "GIT_ID_HTTPS_CREDENTIAL_USER=%GIT_ID_HTTPS_ACCOUNT%"
if /i "%GIT_ID_HTTPS_PROVIDER%"=="gitlab" set "GIT_ID_HTTPS_CREDENTIAL_USER=oauth2"
set "GIT_ID_HTTPS_CREDENTIAL_GUARD=%~dp0https-credential-guard.cmd"
if not exist "%GIT_ID_HTTPS_CREDENTIAL_GUARD%" goto :MissingCredentialGuard
set "GIT_ID_HTTPS_CREDENTIAL_HELPER=%GIT_ID_HTTPS_CREDENTIAL_GUARD:\=/%"
set GIT_ID_HTTPS_CREDENTIAL_HELPER=!"%GIT_ID_HTTPS_CREDENTIAL_HELPER%"
set "GIT_ID_ACCESS=https.%GIT_ID_HTTPS_PROVIDER%:host=%GIT_ID_HTTPS_HOST%;account=%GIT_ID_HTTPS_ACCOUNT%"
set "GIT_SSH_COMMAND="%~dp0deny-ssh.cmd""
set "GIT_ASKPASS="%~dp0deny-credential-prompt.cmd""
exit /b 0

:PrepareSshAccess
if not defined GIT_ID_ACCESS_TARGET goto :InvalidAccess
set "GIT_ID_TRANSPORT=ssh"
set "GIT_SSH_COMMAND=%GIT_ID_ACCESS_TARGET%"
set "GIT_ASKPASS="%~dp0deny-credential-prompt.cmd""
exit /b 0

:PrepareSigning
set "GIT_ID_SIGNING_ENABLED=false"
if defined GIT_ID_SIGNING_KEY goto :SigningKeyConfigured
if defined GIT_ID_GPG_FORMAT goto :IncompleteSigningConfiguration
exit /b 0

:SigningKeyConfigured
if not defined GIT_ID_GPG_FORMAT goto :IncompleteSigningConfiguration
if /i "%GIT_ID_GPG_FORMAT%"=="openpgp" goto :UseOpenPgpSigning
if /i "%GIT_ID_GPG_FORMAT%"=="ssh" goto :UseSshSigning
if /i "%GIT_ID_GPG_FORMAT%"=="x509" goto :UseX509Signing
echo [ERROR] Invalid GIT_ID_GPG_FORMAT in "%GIT_ID_ENTRY_COMMAND%.cmd".
echo Use openpgp, ssh, or x509.
exit /b 1

:UseOpenPgpSigning
set "GIT_ID_GPG_FORMAT=openpgp"
goto :EnableSigning

:UseSshSigning
set "GIT_ID_GPG_FORMAT=ssh"
goto :EnableSigning

:UseX509Signing
set "GIT_ID_GPG_FORMAT=x509"
goto :EnableSigning

:EnableSigning
set "GIT_ID_SIGNING_ENABLED=true"
exit /b 0

:IncompleteSigningConfiguration
echo [ERROR] Incomplete commit signing configuration in "%GIT_ID_ENTRY_COMMAND%.cmd".
echo Set both GIT_ID_SIGNING_KEY and GIT_ID_GPG_FORMAT, or leave both empty to disable signing.
exit /b 1

:MissingAccess
echo [ERROR] Git access is not configured in "%GIT_ID_ENTRY_COMMAND%.cmd".
echo Set GIT_ID_ACCESS to ssh:command, https.github:host=HOST;account=ACCOUNT, or https.gitlab:host=HOST;account=ACCOUNT.
exit /b 1

:InvalidAccess
echo [ERROR] Invalid GIT_ID_ACCESS in "%GIT_ID_ENTRY_COMMAND%.cmd".
echo Expected: ssh:command, https.github:host=HOST;account=ACCOUNT, or https.gitlab:host=HOST;account=ACCOUNT
echo Example: https.github:host=github.com;account=alice
exit /b 1

:MissingCredentialGuard
echo [ERROR] HTTPS credential guard is missing: %GIT_ID_HTTPS_CREDENTIAL_GUARD%
exit /b 1

:AddGitConfig
set "GIT_CONFIG_KEY_%GIT_CONFIG_COUNT%=%GIT_ID_CONFIG_KEY%"
set "GIT_CONFIG_VALUE_%GIT_CONFIG_COUNT%=%GIT_ID_CONFIG_VALUE%"
set /a GIT_CONFIG_COUNT+=1
exit /b 0

:PrepareCredentialNamespace
if not "%GIT_ID_ENTRY_COMMAND%"=="%GIT_ID_ENTRY_COMMAND:@=%" goto :InvalidCredentialNamespace
if not "%GIT_ID_HTTPS_PROVIDER%"=="%GIT_ID_HTTPS_PROVIDER:@=%" goto :InvalidCredentialNamespace
if not "%GIT_ID_HTTPS_HOST%"=="%GIT_ID_HTTPS_HOST:@=%" goto :InvalidCredentialNamespace
if not "%GIT_ID_HTTPS_ACCOUNT%"=="%GIT_ID_HTTPS_ACCOUNT:@=%" goto :InvalidCredentialNamespace
set "GIT_ID_CREDENTIAL_NAMESPACE=swaw-kit-git.v2@%GIT_ID_ENTRY_COMMAND%@%GIT_ID_HTTPS_PROVIDER%@%GIT_ID_HTTPS_HOST%@%GIT_ID_HTTPS_ACCOUNT%"
exit /b 0

:InvalidCredentialNamespace
echo [ERROR] Git identity entry, HTTPS host, and account must not contain "@".
exit /b 1

:AssertAuthorizationBoundary
call git config --list >nul 2>nul
if errorlevel 1 goto :AuthorizationConfigInspectionFailed
call git config --get-regexp "^(http|credential)\." 2>nul | %SystemRoot%\System32\findstr.exe /i /r /c:"^http\.extraheader ." /c:"^http\..*\.extraheader ." /c:"^http\.cookiefile ." /c:"^http\..*\.cookiefile ." /c:"^http\.sslcert ." /c:"^http\..*\.sslcert ." /c:"^http\.sslkey ." /c:"^http\..*\.sslkey ." /c:"^http\.delegation ." /c:"^http\..*\.delegation ." /c:"^credential\..*\.helper ." >nul
if errorlevel 2 goto :AuthorizationConfigInspectionFailed
if errorlevel 1 exit /b 0
echo [ERROR] Git config contains hidden HTTPS authorization that can bypass this identity.
echo Remove HTTP credential headers, cookies, client certificates, and URL-scoped credential helpers before using this entry.
exit /b 1

:AuthorizationConfigInspectionFailed
echo [ERROR] Git configuration could not be inspected for HTTPS authorization bypasses.
exit /b 1

:MissingIdentity
echo [ERROR] Git identity is not configured in "%GIT_ID_ENTRY_COMMAND%.cmd".
echo.
echo Set these lines near the top of the entry file:
echo   set "GIT_ID_NAME=Your Name"
echo   set "GIT_ID_EMAIL=you@example.com"
echo.
echo Run "%GIT_ID_ENTRY_COMMAND% --help" for examples.
exit /b 1
