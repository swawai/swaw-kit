# win-run-toolbox

一个有用的 Windows 工具箱入口

克隆本项目到你本机，双击其中的

```text
pathhereadd.cmd
```

这时脚本会检查这个工具箱目录，是否已经在当前用户的 `PATH`，不存在就追加进去。

之后，打开新终端，或者重新调起 `Win + R`，就可以直接调用本仓库里精心准备的 `.cmd`、`.bat`、`.exe`等命令工具。

要撤销，只需双击同目录中的:

```text
pathhereremove.cmd
```

它会执行 `pathhereadd.cmd` 的反向操作。


## 会不会改坏 PATH？

脚本在追加/移除其中目标项时，做了几层保护：

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

1. 修改环境变量后，已经打开的终端通常不会自动刷新。新开的终端、新启动的程序，才会读取新的用户环境变量。

2. 不建议把很多目录都加入 `PATH`。最好只加一个稳定的工具箱目录，用作自己的命令空间；目录多了，反而容易出现命令名冲突。


## 仓库中部分快捷命令使用示例

```bat
porttask.cmd 80*
taskport.cmd chrome
portrule.cmd 8080
copy vps1.cmd vps2.cmd
copy git1.cmd git2.cmd
```

复制 `vps1.cmd` / `git1.cmd` 后，按需修改其中的主机或授权信息。

## 微软 sysinternals

含有许多高级命令，可以自行下载，按需加入：

https://learn.microsoft.com/en-us/sysinternals/
