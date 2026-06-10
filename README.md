# win-run-toolbox

一个很小的 Windows 工具箱入口：把当前目录加入当前用户 `PATH`，让 `Win + R`、终端和脚本都可以直接运行这里的 `.cmd`、`.bat`、`.exe`。

只需要下载这两个文件即可使用：

```text
pathhereadd.cmd
pathhereremove.cmd
```

## 用法

进入你准备作为工具箱的目录：

```cmd
cd /d C:\my_handy_tools
pathhereadd
```

之后新开的终端，或重新调起的 `Win + R`，就可以直接运行这个目录里的命令。

移除当前目录：

```cmd
cd /d C:\my_handy_tools
pathhereremove
```

也可以传入指定目录：

```cmd
pathhereadd C:\my_handy_tools
pathhereremove C:\my_handy_tools
```

## 建议

不要把很多目录都加入 `PATH`。更低心智负担的做法是：只把一个稳定的工具箱目录加入 `PATH`，以后把自定义命令、便携工具、包装脚本都放进这个目录。

例如：

```text
git1.cmd       使用 SSH Key 1 调 Git
porttask.cmd   根据端口查进程
taskport.cmd   根据进程查端口
tcpview.exe    Sysinternals 连接查看工具
```

`PATH` 只负责指向入口；工具箱目录才是自定义命令的单一事实源。

## 脚本做了什么

- 读取当前用户 `PATH`
- 添加或移除当前目录/指定目录
- 写入前把旧值备份到 `pathhere.backup.log`
- 使用 PowerShell 读写 `HKCU\Environment` 中的用户 `Path`
- 保留已有 `Path` 注册表值名称和类型

两个 `.cmd` 都是单文件脚本：文件开头是很薄的 batch wrapper，后半段是 PowerShell 主逻辑。

## 边界

已经打开的终端通常不会自动刷新环境变量；如果命令找不到，请重新打开终端或重新调起 `Win + R`。

本仓库不分发 Sysinternals 等第三方二进制工具。需要这些工具时，请从 Microsoft 官方页面下载。

维护脚本时，建议让 `.cmd` 文件本体保持 ASCII-only。中文说明可以放在 README 里；脚本输出保留英文，能减少 `cmd.exe`、Windows PowerShell 5.1 和 UTF-8 批处理文件之间的编码噪声。
