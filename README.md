# win-run-toolbox

Windows 开发/运维常见痛点工具箱。目标是一键：

管理指定 SSH 主机（如设置免密登录）  
管理指定 WSL 实例（如设置后台保活、备份还原、端口映射）  
管理多套 Git 身份（一个命令入口一套身份，清晰可见）  
查询端口占用进程  
查询进程占用端口  
查询/管理自定义防火墙规则  
...  
以及，一键将仓库目录加入用户 PATH


## 示例

```cmd
porttask.cmd 80*     # 查询 80* 端口占用程序
taskport.cmd chrome  # 查询 chrome 进程占用端口
tcpview.exe          # GUI 程序, 总览系统 TCP/UDP 端口/进程 (微软 sysinternals 组件)
portrule.cmd         # 交互式管理防火墙入站规则
psping qq.com:80     # TCP ping 80 端口 (微软 sysinternals 组件)
vps2.cmd  --help     # 管理指定 SSH 主机，copy vps1.cmd   vps2.cmd   后修改其中主机信息）
wsl02.cmd --help     # 管理指定 WSL 实例，copy wsl01.cmd  wsl02.cmd  后修改其中实例信息）
git2.cmd  --help     # 应用指定 Git 身份，copy git1.cmd  git2.cmd   后修改其中账号信息）
```

>命令脚本名，如带点号，如 vps.2.cmd，在 Win+R 中执行 vps.2 可能会报错。






## 加入 PATH

克隆仓库后，双击：

    pathhereadd.cmd

它会将当前工具箱目录，幂等加入当前用户的 `PATH`。

撤销：

    pathhereremove.cmd

它会把该目录从当前用户 `PATH` 中安全移除。


## 会不会改坏 PATH？

脚本会这样操作：

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

> `PATH` 本身用分号分隔目录项，所以切勿吧仓库克隆到路径带`;`号的位置。


## 边界和风险

1. 修改环境变量后，已经打开的终端不会自动刷新。

2. 目录都加入 `PATH`，可能带来命令名冲突。如：系统本来有`cmd`命令，你追加的目录中若同名命令，系统的会被你覆盖。


## Docs
WSL 实例管理：https://swaw.com/zh/p/swaw-kit-wsl-release/  
SSH 主机管理：https://swaw.com/zh/p/ssh-remote-kit-windows/  
Git 多身份管理：https://swaw.com/zh/p/swaw-kit-git/

## 微软 sysinternals

含有许多强大工具，可以自行下载，按需加入：

https://learn.microsoft.com/en-us/sysinternals/
