@echo off & chcp 65001 >nul <nul & setlocal DisableDelayedExpansion
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: GitHub identity (required)
:: GitHub 身份（必填）.
:::::::::::::::::::::::::::::::::::::::::::::::::::
set "GH_HOST=github.com"
set "GH_ID_ACCOUNT=user1"




:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Optional configuration
:: 可选配置
:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Optional: force help language: zh-CN / en. Auto-detect when unset:
:: 可选：指定帮助语言 zh-CN / en。留空则自动检测:
set "GH_ID_HELP_LANG="
:: Profile storage (required; normally keep the default):
:: 账号配置目录（必需；通常保持默认值）:
set "GH_CONFIG_DIR=%~dp0data\github-cli\profiles\%~n0"
:: more Optional:
:: 更多选项:
set "GH_ID_GIT_PROTOCOL=https"
set "GH_ID_DEFAULT_TERMINAL=cmd"




:::::::::::::::::::::::::::::::::::::::::::::::::::
:: Do not edit anything below.
:: 下面的内容不要修改.
:::::::::::::::::::::::::::::::::::::::::::::::::::
set "GH_ID_KIT_PROTOCOL=2"
set "GH_ID_KIT=%~dp0_lib\github_cli_kit\kit.cmd"

if exist "%GH_ID_KIT%" goto :GithubCliKitFound
echo [ERROR] GitHub CLI kit not found:
echo   "%GH_ID_KIT%"
echo.
echo Missing _lib\github_cli_kit\kit.cmd next to this entry file.
exit /b 1

:GithubCliKitFound
set "GH_ID_ENTRY_COMMAND=%~n0"
set "GH_ID_ENTRY_FILE=%~f0"
:: Tail-call the kit so cmd.exe does not parse forwarded arguments twice here.
"%GH_ID_KIT%" %*
