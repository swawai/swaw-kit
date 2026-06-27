# win-run-toolbox

个人常用的 Windows 工具集合

克隆仓库，双击其中的：

```text
pathhereadd.cmd
```

它会将自身所在目录，幂等加入当前用户的 `PATH`。

之后，打开的新终端、新 `Win + R`，可直接执行仓库中的 `.cmd`、`.exe`等命令工具。

要撤销，只需双击仓库中的:

```text
pathhereremove.cmd
```

它会执行反向操作（把所在目录从用户的 `PATH`中安全的移除）。


## 会不会改坏 PATH？

脚本在追加/移除时，会这样操作：

```text
1. 只修改当前用户 PATH，不碰系统 PATH
2. 添加前检查是否已存在，避免重复加入
3. 写入前备份原始用户 PATH
4. 只改要追加/删除的目录项；其他仍按原样保留（例如 `%USERPROFILE%\bin` 这种，不会被展开成固定路径）
5. 支持空格、中文、&、%、!、括号等路径字符
6. 删除时把 `PATH` 按分号拆成一个个目录项，再做完整项匹配；所以删除如 `C:\Tools` 时，不会误伤 `C:\ToolsExtra`。
7. 如果同一个目录重复出现，删除脚本会把所有匹配项都清掉。
8. 脚本同目录的 `pathhere.backup.log`，里面有每次操作前备份的原始用户 `PATH`，可做最后保障。
```

> `PATH` 本身用分号分隔目录项，所以工具箱目录名不要包含分号。


## 边界和风险

1. 修改环境变量后，已经打开的终端通常不会自动刷新。

2. 不要随意把目录都加入 `PATH`，它是重要的系统环境；目录多了，容易命令名冲突。如系统本来有`cmd`命令，你追加的目录中若有此命令，会被你覆盖。


## 仓库中部分快捷命令使用示例

```bat
porttask.cmd 80*           # 查询80* 端口占用程序
taskport.cmd chrome        # 查询chrome进程占用端口
tcpview.exe                # GUI 程序, 查看系统 TCP 端口/进程 (微软sysinternals组件)
portrule.cmd               # 交互式管理防火墙入站规则
psping qq.com:80           # TCP ping                (微软sysinternals组件)
copy vps1.cmd vps2.cmd     # 为ssh远程主机创建专用命令 (复制后修改其中的ssh 主机信息，执行 vps2 --help)
copy git1.cmd git2.cmd     # 为git身份设置专用包装脚本 (复制后修改其中的git 账户信息，然后用git2 替代git 命令来使用)
copy wsl01.cmd wsl02.cmd   # 为WSL实例创建专用命令     (复制后修改其中的WSL实例绑定信息，执行 wsl02 --help)

```

>对于带点号的脚本命令，如 vps.2.cmd，在 Win+R 中输入 vps.2，貌似会找不到。




## 微软 sysinternals

含有许多强大工具，可以自行下载，按需加入：

https://learn.microsoft.com/en-us/sysinternals/
