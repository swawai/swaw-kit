# win-run-toolbox

一个有用的 Windows 工具箱入口

克隆本项目到你本机，双击其中的：

```text
pathhereadd.cmd
```

这时脚本会检查这个工具箱目录，是否已经在当前用户的 `PATH`，不存在就追加进去。

之后，打开新终端，或者重新调起 `Win + R`，就可以直接调用本仓库里精心准备的 `.cmd`、`.bat`、`.exe`等命令工具。

要撤销，只需双击同目录中的:

```text
pathhereremove.cmd
```

它会执行 `pathhereadd.cmd` 的反向操作（把所在目录从用户的 `PATH`中安全的移除）。


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
copy wsl01.cmd wsl.dev.cmd
```

复制 `vps1.cmd` / `git1.cmd` / `wsl01.cmd` 后，按需修改其中的主机或授权信息。
WSL 入口文件名建议使用 `wsl01.cmd` 这类不含额外点号的形式，便于 Win+R 按 `PATHEXT` 解析为 `.cmd`。

`wsl01.cmd` 会优先透传原生 WSL 运行参数，并自动绑定入口配置中的实例：

```bat
wsl01.cmd status
wsl01.cmd doctor
wsl01.cmd uname -a
wsl01.cmd --cd /tmp -- pwd
wsl01.cmd ctl config dir
wsl01.cmd ctl install dir
wsl01.cmd ctl install --dry-run
wsl01.cmd ctl backup list
wsl01.cmd ctl restore D:\x.tar --dry-run
wsl01.cmd ctl ssh status
wsl01.cmd ctl port status
wsl01.cmd ctl port expose 8080 80
wsl01.cmd ctl port expose 8080 80 --uac
wsl01.cmd vm status
wsl01.cmd vm settings
wsl01.cmd vm welcome
wsl01.cmd vm shutdown
wsl01.cmd code ~
```

WSL 入口文件使用 `WSL_KIT_PROTOCOL` 声明与 `_lib\wsl_instance_kit` 的协议版本；当前模板使用 `1`。
`ctl` 是此入口绑定实例的管理命名空间；`vm` 是当前 Windows 用户下 WSL 底层虚拟机/用户级设置的管理命名空间，会影响该用户下的所有 WSL 实例。
`doctor` 会检查 `wsl.exe`、入口协议和关键配置、安装源/fallback 元数据、实例注册和运行状态、存储目录、Windows 虚拟化/WSL 功能、网络模式、GitHub WSL 发行版索引、fallback URL，并对 fallback 镜像做 15 秒下载测速；本地诊断会先输出，联网检查放在最后执行。`ctl doctor` 也可用，但不在 help 中展示。
`ctl backup` 和 `ctl export` 的导出格式由入口文件中的 `WSL_export_format` 固定控制，默认是 `tar`。
`ctl backup list` 会列出当前实例备份目录中的 `.tar` / `.tar.gz` / `.tar.xz` / `.tgz` / `.vhd` / `.vhdx` 归档；`ctl restore <archive>` 会把归档还原到当前入口绑定的实例名和安装目录，实例已存在时需要追加 `--yes`，可先用 `--dry-run` 预览原生 `wsl.exe` 命令。
`ctl install dir` 可打开当前实例安装目录；`ctl backup dir` 可打开当前实例备份目录；`ctl downloads dir` 可打开 fallback 镜像缓存目录；`status` 会显示当前实例备份、备份根目录和下载缓存占用。
在线发行版安装默认仍优先使用原生 `wsl --install`；如果失败，会提示显式尝试 `ctl install --fallback`，fallback 会使用 `_lib\wsl_instance_kit\DistributionInfo.json`。
fallback 下载的发行版镜像会复用 `data\wsl.downloads`，下载时先写入临时目录，校验成功后再移入镜像库。
fallback 安装成功后会为使用的源镜像写入同名 `.sha256` 文件；后续复用缓存前会校验该 hash，并在 DistributionInfo 提供 SHA256 时同步校验上游 hash，不匹配会清理后重新下载。
`ctl systemd enable` / `ctl systemd disable` 负责写入实例内 `/etc/wsl.conf`；修改后通常需要 `vm shutdown` 让 WSL 重启后生效。
`vm status` 会显示当前 Windows 用户下的 WSL VM 概览、实例列表、网络模式和 WSL Settings 可用性。
`vm settings` 会打开 WSL Settings 可视化配置程序，用于处理 WSL VM 网络等当前 Windows 用户级配置；`vm welcome` 会打开 WSL 欢迎/功能介绍页面。
`ctl ssh enable <port>` 只支持 systemd 托管启用，需要 systemd 已实际运行，并显式传入端口，例如 `ctl ssh enable 2222`；执行前会检查 Windows/WSL 侧端口占用。
SSH 自动安装 `openssh-server` 目前支持 apt-get、dnf、yum、microdnf 系发行版；服务启停仍统一走 systemd。
`ctl port status` / `ctl port doctor` 会显示当前 WSL 网络模式、运行状态、WSL IP、已管理的端口映射和防火墙规则。
`ctl port expose <listen-port> [connect-port]` 会根据网络模式自动选择策略：NAT 使用 `netsh interface portproxy` 加 Windows Firewall；mirrored 使用 Hyper-V Firewall 且不做端口重映射；none / virtioproxy / bridged 只给出诊断提示。
`ctl port remove <listen-port>` 会删除对应的托管 portproxy / firewall 规则；`ctl port sync` 用于 NAT 下 WSL IP 变化后刷新已管理映射。
端口修改需要管理员权限；非管理员终端默认直接失败，可加 `--uac` 弹出 UAC 提权窗口，或加 `--dry-run` 预览将执行的命令。
测试脚本分两层：`_lib\wsl_instance_kit\test\smoke.ps1` 默认不改环境；`_lib\wsl_instance_kit\test\live.ps1 -Yes` 会真实安装、shutdown、SSH 连接、backup/export、通过 `ctl restore` 从导出包恢复并删除 `wslkit-live-*` 测试实例。

参考资料：

```text
WSL 实用指南 https://swaw.com/zh/p/wsl-guide/
WSL 配置详解 https://learn.microsoft.com/zh-cn/windows/wsl/wsl-config#main-wsl-settings
```


## 微软 sysinternals

含有许多高级命令，可以自行下载，按需加入：

https://learn.microsoft.com/en-us/sysinternals/
