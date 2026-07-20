@echo off & chcp 65001 >nul <nul & setlocal DisableDelayedExpansion
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Copy this file as, for example, git2.cmd, then customize the Git identity settings below.
:: 复制本文件为(例如): git2.cmd，然后自定义下面的 Git 身份配置.
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Remote access identity (choose one): ssh:command / https.github:host/user / https.gitlab:host/user. Before using HTTPS, run `git1 .https login`.
:: 远端访问身份（三选一）：ssh:command / https.github:host/user / https.gitlab:host/user。HTTPS 模式使用前需执行如 `git1 .https login`。
set "GIT_ID_ACCESS=ssh:ssh -o IdentitiesOnly=yes -i '%USERPROFILE%/.ssh/id_ed25519'"
:: set "GIT_ID_ACCESS=https.github:github.com/swawai"
:: set "GIT_ID_ACCESS=https.gitlab:gitlab.example.com/alice"

:: 提交信息.
set "GIT_ID_NAME=user1"
set "GIT_ID_EMAIL=user1@example.com"





:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Optional configuration
:: 可选配置.
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: cmd / powershell / pwsh / gitbash
set "GIT_ID_DEFAULT_TERMINAL=cmd"
:: Commit signing (authoritative): leave both empty to disable, or set both to enable. Format: openpgp / ssh / x509.
:: 提交签名（权威配置）：两项都留空即禁用；两项都填写才启用。格式：openpgp / ssh / x509。
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
