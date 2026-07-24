@echo off & chcp 65001 >nul <nul & setlocal DisableDelayedExpansion
call "%~dp0_lib\editor_kit\entry-bootstrap.cmd" "%~1" "GIT_ID_ENTRY_FILE"
if errorlevel 1 exit /b %ERRORLEVEL%
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Commit author identity (required)
:: 提交时的署名信息(必填)
:::::::::::::::::::::::::::::::::::::::::::::::::::
set "GIT_ID_NAME=user1"
set "GIT_ID_EMAIL=user1@example.com"


:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Remote access method (choose one of three modes; required)
:: 远端访问方式(模式三选一，必填)
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: https.github mode:
:: https.github 模式:
set "GIT_ID_ACCESS=https.github:host=github.com;account=user1"

:: https.gitlab mode:
:: https.gitlab 模式:
:: set "GIT_ID_ACCESS=https.gitlab:host=gitlab.example.com;account=alice"

:: ssh mode (platform-independent; configures sshCommand):
:: ssh 模式(不用区分平台，实际上就是配置 sshCommand):
:: set "GIT_ID_ACCESS=ssh:ssh -o IdentitiesOnly=yes -i '%USERPROFILE%/.ssh/id_ed25519'"




:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Optional configuration
:: 可选配置.
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: cmd / powershell / pwsh / gitbash
set "GIT_ID_DEFAULT_TERMINAL=cmd"
:: Commit signing (authoritative): leave both empty to disable, or set both to enable. Format: openpgp / ssh / x509
:: 提交签名（权威配置）：两项都留空即禁用；两项都填写才启用。格式：openpgp / ssh / x509
set "GIT_ID_SIGNING_KEY="
set "GIT_ID_GPG_FORMAT="
:: Optional: force help language: zh-CN / en. Auto-detect when unset:
:: 可选：指定 help 语言: zh-CN / en。留空则自动检测:
set "GIT_ID_HELP_LANG="


:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Do not edit anything below.
:: 下面的不要做任何修改.
:::::::::::::::::::::::::::::::::::::::::::::::::::
set "GIT_ID_KIT=%~dp0_lib\git_identity_kit\kit.cmd"
if exist "%GIT_ID_KIT%" goto :GitIdentityKitFound
echo [ERROR] Git identity kit not found:
echo   "%GIT_ID_KIT%"
echo.
echo Missing _lib\git_identity_kit\kit.cmd next to this entry file.
exit /b 1
:GitIdentityKitFound
set "GIT_ID_ENTRY_COMMAND=%~n0"
set "GIT_ID_ENTRY_FILE=%~f0"
:: Tail-call the kit so cmd.exe does not parse and expand the forwarded arguments a second time.
"%GIT_ID_KIT%" %*
