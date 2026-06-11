@echo off
cd /d "%~dp0"
cacls.exe "%SystemDrive%\System Volume Information" >nul 2>nul
if %errorlevel%==0 goto Admin
if exist "%temp%\getadmin.vbs" del /f /q "%temp%\getadmin.vbs"
echo Set RequestUAC = CreateObject^("Shell.Application"^)>"%temp%\getadmin.vbs"
echo RequestUAC.ShellExecute "%~s0","","","runas",1 >>"%temp%\getadmin.vbs"
echo WScript.Quit >>"%temp%\getadmin.vbs"
"%temp%\getadmin.vbs" /f
if exist "%temp%\getadmin.vbs" del /f /q "%temp%\getadmin.vbs"
exit
:Admin
chcp 65001 > nul
setlocal EnableDelayedExpansion
:: 设置规则前缀
set RULE_PREFIX=ES_FW_

:menu
cls
echo ====================================
echo    Windows防火墙端口管理工具.
echo    (Elastic Stack 服务专用)
echo ====================================
echo 规则前缀: %RULE_PREFIX%
echo ------------------------------------
echo 1. 添加入站规则 (允许端口)
echo 2. 查看现有规则.
echo 3. 删除现有规则.
echo 4. 退出程序.
echo ====================================
set /p choice=请选择操作 (1-4): 

if "%choice%"=="1" goto add_inbound
if "%choice%"=="2" goto list_rules
if "%choice%"=="3" goto delete_rule
if "%choice%"=="4" goto exit
goto menu

:add_inbound
echo.
echo 添加入站规则.
echo ------------------------------------
set /p rule_desc=请输入规则描述 (如: Elasticsearch-HTTP): 
set rule_name=%RULE_PREFIX%%rule_desc%
echo 最终规则名称将为: %rule_name%
echo.
set /p port=请输入端口号: 
echo 请选择协议类型:
echo 1. TCP
echo 2. UDP
set /p protocol_choice=请选择 (1/2)(默认TCP):
if "%protocol_choice%"=="2" (
    set protocol=UDP
) else (
    set protocol=TCP
)
netsh advfirewall firewall add rule name="%rule_name%" dir=in action=allow protocol=%protocol% localport=%port% enable=yes
echo.
echo 入站规则已添加.
pause
goto menu

:list_rules
echo.
echo 当前已配置的规则:
echo ------------------------------------
netsh advfirewall firewall show rule name=all | findstr /b /i "Rule Name" | findstr /i "%RULE_PREFIX%"
echo.
pause
goto menu

:delete_rule
echo.
echo 当前配置的规则列表:
echo ------------------------------------
:: 创建临时文件存储规则
set "tempfile=%temp%\fwrules.txt"
netsh advfirewall firewall show rule name=all | findstr /b /i "Rule Name" | findstr /i "%RULE_PREFIX%" > "%tempfile%"

:: 读取规则并去除多余空格.
set count=0
for /f "tokens=*" %%a in ('type "%tempfile%"') do (
    set "line=%%a"
    set "line=!line:Rule Name=!"
    set "line=!line::=!"
    set "line=!line: =!"
    set /a count+=1
    set "rule_!count!=!line!"
    echo !count!. !line!
)
del "%tempfile%"

if %count%==0 (
    echo 没有找到以 %RULE_PREFIX% 开头的规则.
    pause
    goto menu
)

echo.
set /p del_choice=请输入要删除的规则编号 (0返回):
if "%del_choice%"=="0" goto menu
if %del_choice% gtr %count% goto delete_rule

call set "selected_rule=%%rule_%del_choice%%%"

echo.
echo 即将删除规则: !selected_rule!
set /p confirm=确认删除？(Y/N): 
if /i "%confirm%"=="Y" (
    netsh advfirewall firewall delete rule name="!selected_rule!"
    if !errorlevel! equ 0 (
        echo 规则已成功删除.
    ) else (
        echo 删除失败，请检查规则名称或权限.
    )
) else (
    echo 已取消删除操作.
)
pause
goto menu

:exit
echo 感谢使用，再见.
endlocal
exit /b 0