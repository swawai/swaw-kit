@echo off & chcp 65001 >nul <nul & setlocal DisableDelayedExpansion & set "SSH_ACCESS_PROTOCOL=1"
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Public key path. The optional private key path is derived by removing the final .pub:
:: 公钥路径；可选私钥的路径固定由移除末尾 .pub 推导:
:::::::::::::::::::::::::::::::::::::::::::::::::::
set "SSH_ACCESS_PUBLIC_KEY_PATH=%USERPROFILE%\.ssh\id_%~n0.pub"



:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Optional configuration
:: 可选配置.
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: OpenSSH key type passed to ssh-keygen -t:
:: 传给 ssh-keygen -t 的 OpenSSH 密钥类型:
set "SSH_ACCESS_KEY_TYPE=ed25519"

:: Public key comment. Do not store a passphrase in this file:
:: 公钥注释；不要在此文件中保存私钥口令:
set "SSH_ACCESS_KEY_COMMENT=%~n0@%COMPUTERNAME%"

:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Do not edit below.
:: 下面的内容不要修改。
:::::::::::::::::::::::::::::::::::::::::::::::::::
set "SSH_ACCESS_ORIGIN_USER_NAME="
set "SSH_ACCESS_ORIGIN_USER_SID="
set "SSH_ACCESS_KIT=%~dp0_lib\ssh_access\kit.cmd"

if exist "%SSH_ACCESS_KIT%" goto :SshAccessKitFound
echo [ERROR] SSH access kit not found:
echo   "%SSH_ACCESS_KIT%"
echo.
echo Missing _lib\ssh_access\kit.cmd next to this entry file.
exit /b 1

:SshAccessKitFound
set "SSH_ACCESS_ENTRY_COMMAND=%~n0"
set "SSH_ACCESS_ENTRY_FILE=%~f0"

:: Tail-call the kit so cmd.exe does not parse forwarded arguments twice.
"%SSH_ACCESS_KIT%" %*
