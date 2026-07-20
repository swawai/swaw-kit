# proj1.cmd 项目工作台计划

## 定位

`proj1.cmd` 是绑定一个本地项目目录的便携工作台。

```text
PROJECT_DIR  = 用户项目目录
```

它延续“一资源一入口”模式：

```text
wsl01.cmd = 一个 WSL 实例
vps1.cmd  = 一台远程机器
proj1.cmd = 一个本地项目目录
```



## 命名


```text
_lib\project_kit
```

## proj1.cmd 模板协议

模板顶部只放声明式配置：

```cmd
@echo off & chcp 65001 >nul & setlocal

set "PROJECT_DIR=D:\code\proj1"

:: 可选
:: set "GH_REPO=owner/repo"

set "GIT_ID_NAME=user1"
set "GIT_ID_EMAIL=user1@example.com"
set "GIT_SSH_COMMAND=ssh -i '%USERPROFILE%/.ssh/id_ed25519' -o IdentitiesOnly=yes"
set "GIT_SSH_VARIANT=ssh"


set "PROJECT_DEFAULT_SHELL=pwsh"
set "PROJECT_DEFAULT_IDE=code"
:: set "PROJECT_HELP_LANG=zh-CN"
set "PROJECT_HOME_root=%~dp0data\"
```



纳入 D:\2026.3\xvenv 环境管理，





## --help 文案草案

```text
Project Kit: 项目目录绑定的便携工作台

基本用法:
  proj1                       在 PROJECT_DIR 中打开默认项目终端
  proj1 --help                显示帮助
  proj1 .info                 显示项目目录、状态目录、模块和关键环境变量
  proj1 .doctor               检查项目目录、状态目录、模块和 gh 登录状态
  proj1 .dir                  用资源管理器打开 PROJECT_DIR
  proj1 .code                 用配置的编辑器打开 PROJECT_DIR
  proj1 .shell                在 PROJECT_DIR 中打开配置的 shell

环境管理:
  proj1 .env status           显示项目环境状态
  proj1 .env ensure           创建 PROJECT_HOME 并生成环境文件
  proj1 .env modules          列出配置的模块
  proj1 .env module gh install 安装此项目的便携 gh
  proj1 .env module gh use    启用已安装的 gh 模块

项目命令:
  proj1 gh auth login         使用此项目的 GH_CONFIG_DIR 登录 gh
  proj1 gh pr list            列出 GH_REPO 的 PR
  proj1 gh repo view          查看 GH_REPO
  proj1 git status            在 PROJECT_DIR 中运行 git status
  proj1 bun install           在 PROJECT_DIR 中运行 bun install
  proj1 python --version      使用项目环境中的 python

规则:
  点号命令是 Project Kit 管理命令
  非点号命令会在 PROJECT_DIR 和项目环境中原样执行
  Project Kit 不修改系统 PATH 或全局工具配置
```

其中 .env 功能主要从 此项目迁移：D:\2026.3\xvenv\xvenv.cmd




1. 不把 gh token 写进 `proj1.cmd`。
2. 不修改系统 PATH、注册表、全局 Git config、全局 gh config。

`gh` 模块：

```text
安装便携 gh.exe
启用后加入 PATH
设置 GH_CONFIG_DIR  # 默认为 %PROJECT_HOME_root%/ 下
可选注入 GH_REPO
```


## 成功标准

```text
proj1 一看就知道绑定哪个目录
proj1 .doctor 能解释项目资源状态
proj1 gh pr list 不串到别的 GitHub 配置
proj1 git/bun/python 能在同一套项目环境中运行
系统环境保持不变
```
