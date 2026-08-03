# Swaw Kit Proj 开发设计纲要

> 文档性质：后续设计与开发的架构纲要，不承担使用手册、版本日志或临时任务清单职责。
>
> 事实基线：2026-08-02 的 `_lib/proj`、`.swaw/proj`、测试和历史任务 `019fa67e-aaa4-7d32-9489-c6d03f5dbfc2`。
>
> 规范词：必须 = 不可破坏的契约；应 = 默认选择，偏离需说明理由；可以 = 尚未冻结或按需实现。
>
> 架构口令：统一协议，分散实现；按功能领域纵切，不按技术层堆叠。

## 1. 产品定义与最终形态

Swaw Kit Proj 是“一个项目生命的本地控制面”：

- 一个命名入口绑定一个目标项目、ActionRoot、DataRoot 和隔离开发环境。
- 用户可从任意目录调用入口；入口文件不要求位于目标项目内。
- CLI 与 GUI 消费同一项目上下文和文件系统命令树。
- 项目环境只影响当前进程树，不修改 User/Machine PATH 或机器级身份。
- 可变状态集中在受控数据根，可验证、可恢复、可整体删除重建。

目标体验：

```text
<entry> .help                    查看真实命令树
<entry> .dev.setup               显式建立受管开发环境
<entry> .cargo build             使用受管 Rust/MSVC 工具链
<entry> proj.build.launcher      执行项目自己的 Action
<entry>                          打开 GUI 项目控制面
```

目标程序由以下部分组成：

- 极薄原生入口：保真 argv、入口路径、CLI/GUI 启动边界和退出码。
- Rust `proj-core`：入口上下文、命令树、Guard、执行、状态和安全协议。
- Tauri GUI Host：窗口、WebView、IPC 和 View 装载，是 Core 的适配器。
- PowerShell：当前 V0 Core；长期保留适合 Windows 的安装、修复和构建脚本。
- Project Action：`.swaw` 内贴近项目、可进 Git、按功能领域组织的能力。

Proj 不做全局包管理器、通用 CI 平台、隐式安装/升级，也不让 Core 理解每个项目的 build/deploy 业务。V0 平台严格限定为 Windows x64。

## 2. 架构取向：协议集中，能力去中心化

去中心化的是能力、代码和状态的所有权，不是让协议与事实源各自为政。Core 负责统一道路规则，不经营道路两旁的每一家店。

### 2.1 可执行约束

- 每项能力必须归属一个明确领域；声明、校验、状态、副作用、错误、Help、View 和测试由该领域共同拥有。
- 新增普通能力应主要修改一个领域目录及必要的 composition root；若每次都要修改中央路由、Core 名单和多个无关模块，说明边界错误。
- Core 只拥有跨领域稳定机制，不拥有工具名单、IDE 名单、项目 build 语义或按 caller/mode/type 分支的业务策略。
- 文件系统命令树与本地 manifest 用于发现；不得再维护中央 command/plugin catalog。
- composition root 可以集中装配，但只负责连接、顺序、依赖和冲突校验，不判断领域内部行为。
- 领域之间只依赖窄而稳定的公开 facade，不导入其他领域的 `_lib`、私有状态格式或安装细节。
- Single Source of Truth 在每个领域内成立；GUI、Help、索引和 API 都是权威事实的投影。
- 只有稳定语义出现第二个真实消费者后才提炼共享原语；不提前建设第三方插件 ABI、复杂 DI 或通用 mode 分发器。

这里采用的是轻量 DDD：重点是领域边界、语言和所有权，不要求简单功能机械套用 Entity、Repository、Service 等战术模式。

### 2.2 领域地图

| 领域 | 拥有的事实与行为 | 不应拥有 |
|---|---|---|
| Bootstrap / Launcher | 原生 argv、入口文件、CLI/GUI 启动边界 | 命令发现、DataRoot、工具安装 |
| Entry Context | EntryIdentity、入口绑定、ProjectRoot/ActionRoot/DataRoot | build/deploy 业务 |
| Command Runtime | 地址、发现、Help/View、Guard、进程执行协议 | 具体命令前提和业务参数 |
| Managed Dev Environment | 声明快照、安装、generation、激活、恢复 | Project Action 和 GUI 状态 |
| GUI Host | 展示领域投影、采集输入、调用 Core 用例 | 第二套路由、直接写领域状态 |
| Project Action | 项目本地 build/test/deploy 纵切能力 | Core 安装策略和全局工具管理 |

目标 Rust 代码按 `entry/`、`command/`、`execution/`、`dev_env/`、`view/` 等领域组织；避免长期形成全局 `controllers/services/models/utils` 技术层目录。

### 2.3 当前去中心化程度

- 文件系统 Action 树已经无需中央路由表。
- `.swaw/proj/build/launcher` 已把 Guard、Help、策略和运行入口放在同一纵切片附近。
- `.dev/setup/_modules/<name>` 已让各工具拥有自身声明与安装策略。
- 当前 setup composition 仍按工具名装配，Action 也直接引用 MSVC 私有 runtime；这是自举阶段例外，不应扩散为公共模式。
- Rust 迁移时应按领域重组；不为目录整洁机械搬动仍在工作的 PowerShell 文件。

开发环境的目标是：每个内部工具领域只暴露 manifest 与公开 facade，自己加载私有实现；composition root 装配已启用领域并提交统一事务。它仍是内部模块协议，不承诺第三方 drop-in 插件兼容性。

## 3. 冻结契约

### 3.1 项目上下文与事实源

| 锚点 | 含义 | 当前权威来源 |
|---|---|---|
| `EntryFile` | 用户调用的真实入口文件 | 入口自身 |
| `ProjHome` | 控制端根 | 根据 `_lib/proj` 位置派生 |
| `ProjectRoot` | 被控制的业务项目根 | `SWAWKIT_PROJ_DIR` |
| `ActionRoot` | 项目命令树，可不存在 | `SWAWKIT_PROJ_ACTION_ROOT` |
| `DataRoot` | 当前入口的可变状态根 | `ProjHome/data/proj.<entryName>` |

各类事实只有一个权威所有者：

- V0 项目意图：入口中的 `SWAWKIT_PROJ_*` 声明。
- 命令地址：`_lib/proj` 与 `ActionRoot` 的真实目录。
- 入口绑定：`DataRoot/_entry.json` 与当前入口文件身份。
- 已应用开发声明：`DataRoot/dev_env/_state.json`。
- 生成环境：同 generation 的 `env.cmd` 与 `env.ps1`。
- 安装事实：模块 metadata、inventory 和本地 selection。

声明是意图，生成状态是结果；生成状态不得反向成为配置。未来结构化配置必须一次性完成读取、写入、GUI 编辑、Core 消费和旧 CMD 声明删除，不允许双事实源。

`SWAWKIT_PROJ_ID` 已删除。入口身份、项目位置和未来可能的业务项目 UUID 是三个不同概念，不得再次混合。

### 3.2 文件系统命令协议

统一调用形式为 `<entry> <single-address> [opaque-tail-arguments...]`。Core 只解析第一个 token 为地址，其余参数属于目标领域。

| 地址类型 | 来源 | 示例 |
|---|---|---|
| 空地址 | Kernel 根 | `_lib/proj/run.*` |
| 点号地址 | Kernel | `.dev.setup` |
| 非点号地址 | Project Action | `proj.build.launcher` |

地址规则：

- Kernel 点号命令只在根层使用真实 `.<name>` 目录；未知点号命令不回退为 Action。
- 普通段匹配 `^[a-z][a-z0-9-]*$`，拒绝 Windows 设备名和非规范大小写。
- 任意层 `_*` 为私有资源，不进入发现。
- 命令根、入口、Help、View 和路径段都拒绝 reparse point 越界。

每个可执行节点必须且只能包含一个 `run.exe/run.ts/run.py/run.ps1/run.cmd`。这是支持集合而非优先级；多个入口或 runtime 缺失都明确失败，不 fallback。

V0 adapter 边界：

- `run.exe` 保真原生 argv；`run.ts` 经 `.bun` bridge 使用受管 Bun。
- `run.py` 当前依赖 ambient Python，尚未具备受管可移植语义。
- `run.ps1` 使用独立 Windows PowerShell 和版本化参数 payload。
- `run.cmd` 只支持无动态参数或一个独立 Help selector，等待原生入口解除限制。

节点可就近提供 `_help/zh-CN.txt` 和 `index.html`。Help 只有在目标主动提供且尾部只有一个 `.help/.h/-h/--help` 时才由 Core 拦截；否则参数原样传递，`--` 只是普通参数。

固定执行管线：

```text
_global/run.* → <command>/_guard/run.* → <command>/run.*
```

- `_global` 只校验已激活环境的项目归属和 published generation。
- `_guard` 只声明前提并放行/拒绝，不接收动态参数或注入环境，并应保持 bootstrap-safe、只读。
- 真正需要受管工具的 `run.*` 加载环境并复核声明与工具来源。

Core 向子进程提供 `SWAWKIT_PROJ_*`、`SWAWKIT_COMMAND_*` 和 `SWAWKIT_INVOCATION_DIR`，流式连接 stdio 并原样返回退出码。Project Action 默认 cwd 为 ProjectRoot；直接工具命令可以明确选择 InvocationDirectory。

### 3.3 入口身份与 DataRoot

Windows V0 中：

- 入口逻辑名是 EntryFile 主文件名。
- 入口连续性凭据是 `(volumeId, fileId)`。
- DataRoot 是 `ProjHome/data/proj.<entryName>`。

文件身份只证明本机连续性，不是秘密、认证或业务项目身份。

必须保持的状态机：

1. 名称与文件身份都匹配：静默使用。
2. 新名称且无身份匹配：创建新 DataRoot 与 `_entry.json`。
3. 同名 DataRoot 的身份不匹配：显式 claim。
4. 其他唯一 DataRoot 匹配当前身份：claim 后同卷原子改名。
5. 多匹配、目标冲突、无法判断的损坏或跨卷非原子迁移：拒绝并要求人工处理。

Claim 必须显示完整上下文、要求用户限时精确复述新入口名，并在确认前后重新加锁和重算。重定向 stdin 时立即失败。

首次合法入口解析可以创建 `DataRoot/_entry.json`；Help/Info/Status 本身不得创建 dev_env、安装工具、联网或修改全局状态。入口迁移后，包含旧绝对路径的派生环境必须失效或重发。

### 3.4 受管开发环境

| 模块 | 当前实现 | 语义 |
|---|---|---|
| Bun | 已实现 | 精确版本或 latest；可选项目 SHA-256 |
| PowerShell | 已实现 | 精确版本或 latest；隔离安装 |
| MSVC | 已实现 | Channel + Microsoft manifest 制品校验 |
| Rust | 已实现 | 隔离 rustup；stable x64-msvc |
| uv / Python / Go | 仅声明 | 启用时在任何下载或写入前 fail-fast |

生命周期不变量：

- 下载、安装、更新和清理只能由显式命令触发；普通启动与 Status 保持纯本地。
- moving selector 首次 setup 解析并锁定精确结果；重复 setup 不隐式追逐上游版本。
- setup 依次完成声明校验、锁、下载校验、staging、payload 验证、backup/replace、环境生成和最后发布 `_state.json`。
- `env.cmd`、`env.ps1`、`_state.json` 必须属于同一 generation；半发布状态不是 ready。
- managed-only 命令必须证明最终可执行文件位于对应 `SWAWKIT_DEV_<MODULE>_HOME`。
- PATH 注入只影响当前子进程树；不修改 User/Machine PATH。
- 强杀、断电、缓存损坏或文件锁后，下次 setup 必须恢复有效备份或干净重装，不得永久卡死。
- 最终安装属于 DataRoot；只有经过验证、内容稳定的下载制品可共享于 `ProjHome/data/proj_cache`。

Rust toolchain 声明是权威；仓库 `rust-toolchain.toml`、ambient `RUSTUP_TOOLCHAIN` 或 `+nightly` 不得改变实际编译器。

### 3.5 安全与恢复底线

- 所有删除、移动、覆盖必须先证明目标位于明确 ControlledRoot。
- 命令、DataRoot、安装目录、缓存和归档展开都拒绝 reparse/junction 与路径穿越。
- 下载先落临时文件并验证可获得的 digest；不能把未 pin 制品描述为强可复现。
- 写入使用窄锁、staging、验证、原子发布和可恢复备份。
- 错误必须说明失败事实、仍保留的有效状态和下一步操作。
- Action 是受信任项目代码，不是安全沙箱；第三方不受信任代码属于另一套威胁模型。

## 4. GUI 与 `index.html` 协议

### 4.1 技术选择

推荐以 Tauri 2 实现 GUI Host。Tauri 负责窗口、系统 WebView、IPC、capability 和资源协议；业务状态与命令语义全部留在共享 Rust `proj-core`。

不建立本地 HTTP Server，也不把每个 `run.*` 动态发布为 HTTP 路由。文件系统负责自动发现，Core 只公开少量稳定用例：

```text
catalog(entry) -> CommandTree
start_run(entry, address, argv, channel) -> RunId
cancel_run(run_id)
```

这样新增 Action 不需要修改 Rust router，同时避免端口、认证、CORS/CSRF、防火墙和服务生命周期复杂度。未来若出现浏览器或远程客户端，再把 HTTP 作为独立 Adapter 立项。

Tauri IPC 分工：

| 场景 | 机制 |
|---|---|
| command catalog、状态、启动/取消 | `#[tauri::command]` + `invoke()` |
| started/stdout/stderr/exited/error | Channel |
| catalog-changed 等低频广播 | Event |
| 节点 `index.html` 与相对静态资源 | 受控 custom URI protocol |

前端不得直接获得 Tauri FS、Shell、HTTP 或任意进程权限；所有行为经过 Proj 的领域用例。

### 4.2 View 协议

`index.html` 是所属命令领域的 GUI 投影，不是第二个应用、路由表或后台服务。

Catalog 至少投影 `address`、`summary`、`children`、`runnable`、`hasView` 和 `availability`。选择节点后，Host 使用类似 `swaw-view://<opaque-view-id>/index.html` 的地址加载 View：

- opaque ID 由 Rust 状态映射到已经 canonicalize 的命令目录，URL 不接受任意磁盘路径。
- 协议处理器限制资源位于该 View 根内，拒绝 traversal、reparse 和未知 MIME。
- View 不硬编码平台 Origin，不加载远程脚本，并使用严格 CSP。
- V0 将 ActionRoot View 视为与 `run.*` 同等级的受信任项目代码，但仍只暴露窄 Host API。
- Bundled Host Shell 可以运行所选 catalog 节点；领域 View 默认只能 `run_self(argv)` 或调用明确授权的自身子树。
- Tauri 自定义 commands 必须通过 AppManifest、permissions 和 capabilities 明确收口，不能依赖默认全窗口可用行为。

第三方或不受信任 View 暂不支持；未来需要独立 WebView/进程、签名或声明式 UI，不把 iframe 当作天然安全边界。

### 4.3 第一个 GUI 纵切

第一个可交付版本只做：

1. Tauri GUI EXE 接收当前 Entry 上下文并启动。
2. Rust catalog 扫描同一文件系统协议，显示 Kernel 与 Project Action 树。
3. 选择 `.info`，通过 View 协议加载现有 `index.html`。
4. 从 Host Shell 启动一个命令，Channel 实时显示 stdout/stderr/退出码。
5. 支持取消运行，并保持 argv、cwd、Guard 和退出码语义。
6. 验证 traversal、多个 `run.*`、View 越权、输出顺序和取消后的子进程收敛。

迁移期允许 `start_run` 暂时调用当前 EntryFile，让 PowerShell Core 继续负责身份、Guard 和执行；Rust catalog 必须用共享 fixture 与当前发现行为对齐。该 legacy execution adapter 的删除条件是 Rust Execution 领域通过等价测试，禁止长期双 Core。

## 5. 当前事实与主要缺口

| 子系统 | 当前事实 | 主要缺口 |
|---|---|---|
| `swawkit.cmd` | CMD → Windows PowerShell 的入口和 argv relay | 不是编译器，也尚未启动 GUI |
| Command Core | PowerShell 路由、Help、Guard、身份、环境协议已实现 | 迁移为共享 Rust `proj-core` |
| Rust 构建 | 有通用 `.cargo/.rustc` bridge | 当前环境发布损坏时会 fail-closed |
| C 构建 | `proj.build.launcher` 可构建固定 `launcher.c` | 不是通用 C 项目构建器 |
| C++ 构建 | 受管 cl/link、SDK 和 C++ 标准库已安装 | 没有一等 C++ Action 和真实编译验收 |
| Launcher | 构建/发布管线存在，C 程序仍是 Hello World | 实现真正的极薄启动边界 |
| GUI | 无参数命令明确未实现；`.info/index.html` 是静态示例 | Tauri EXE、Catalog、View 与执行纵切 |
| Dev Env | Bun/Pwsh/MSVC/Rust 代码主链已实现 | update/clean 与当前发布状态修复 |
| 其他声明 | IDE/GH/Git/Repo 等尚无消费者 | 有真实用例和测试前不宣称能力 |
| 测试 | 协议、安装、安全和恢复 fixture 较完整 | 缺少真实 C++/Rust 端到端编译与 GUI 测试 |

当前工作区的 MSVC 14.44、Windows SDK 10.0.26100 和 Rust/Cargo 1.97.1 制品存在，但 `dev_env/_state.json` 缺失，`.dev.status` 报 environment incomplete；`.cargo`、`.rustc` 目前因此退出 1。重跑 `.dev.setup` 发布完整 generation 后才能声称当前构建链可用。

最准确的能力表述是：受管 MSVC/Rust 工具链已具备，Rust 有通用命令桥，C 有 launcher 参考纵切，C++ 尚只有工具链而无产品化 Action。

## 6. 优先路线图

### P0：恢复构建基线并冻结 GUI ADR

- 运行 `.dev.setup` 修复完整 generation，确认 `.dev.status`、`.cargo --version` 和 `.rustc --version`。
- 增加真实 C、C++、Rust hello 构建探针，证明受管工具链端到端可用。
- 验证 Tauri Windows 前置条件，包括 WebView2 运行时和当前受管 MSVC/Rust 兼容性。
- 冻结 Tauri workspace、GUI binary 位置、View 信任模型、custom protocol 和 legacy adapter 删除条件。

退出条件：不是“工具文件存在”，而是三个语言探针都从当前 Entry 成功编译并验证来源。

### P1：交付 Tauri GUI 最小纵切

- 建立按领域组织的 Rust workspace：共享 `proj-core` 与薄 `proj-gui-tauri`。
- 前端采用 Vanilla TypeScript/HTML/CSS 起步，不引入重量 UI 框架。
- 实现 catalog、Finder 式导航和 `.info` View。
- 实现 `start_run/cancel_run`、Channel 输出和运行状态。
- 无参数 Entry 启动 GUI；有地址时继续保持 CLI 行为。
- 收紧 CSP、AppManifest、capability 和 View 资源边界。

退出条件：用户能打开 GUI、浏览真实命令树、查看 `.info` 并运行/取消一个真实命令；GUI 不维护第二份 catalog。

### P2：迁移 Rust Core 并删除过渡层

- 按 Entry Context、Command Runtime、Execution、Dev Environment 的领域顺序迁移。
- CLI 与 GUI 链接同一个 `proj-core`，共享 fixture 和错误模型。
- 原生入口通过完整 argv、stdio、cwd、Ctrl+C、Explorer 双击和缺失 Core 测试。
- 删除 legacy execution adapter、CMD argv relay 与 PowerShell 路由 Core；PowerShell provider/Action 按职责保留。

退出条件：只有一个正式 Core 和一个配置事实源，不存在长期双运行时。

### P3：按真实需求扩展

- 显式 `.dev.update[.<module>]`、clean/retention 和 `.doctor`。
- uv/Python/Go 完整纵切。
- IDE、Git/GH 和项目上下文能力。
- 结构化配置的单向迁移及旧 CMD 声明删除。

## 7. 开发规范与验证门槛

### 7.1 开发规范

- 先回答“行为属于哪个领域”“Core 是否真的需要知道”；仅为统一管理而放入 Core 通常是重新中心化。
- 决策优先级：正确性与核心价值 > 可维护性与低心智负担 > 必要体验 > 性能扩展 > 非核心功能。
- 修改身份、路径、安装和恢复代码前先理解其安全理由，遵守 Chesterton's Fence。
- 调用者知道意图时使用明确函数；避免通用函数内部猜 caller/mode/type。
- AHA 优先于 DRY；稳定重复出现前允许少量局部重复。
- 不增加没有明确删除条件的兼容层、fallback 或“新旧都支持”模式。
- V0 PowerShell 兼容 Windows PowerShell 5.1，启用 StrictMode，显式处理 UTF-8。
- 单文件超过 400 行应在新增职责前评估拆分；超过 700 行必须拆分。
- 未实现功能必须显示为 unavailable/pending，不能凭声明或占位目录进入成功标准。
- 协议、Help、View schema 或行为改变时，同一提交更新相邻测试。

### 7.2 验证门槛

影响协议的改动至少覆盖：

- Command：任意 cwd、命名空间隔离、唯一 `run.*`、Help opt-in、Guard 顺序、argv 和退出码。
- Entry：直接、复制、改名、替换、claim 超时、并发变化和 DataRoot 冲突。
- Dev Env：首次安装、幂等 setup、generation、缓存损坏、partial/backup 和 managed-only 来源。
- GUI：Catalog 等价、View 越界、IPC 授权、输出顺序、取消和子进程回收。
- 全局边界：不修改 User/Machine PATH、全局 Git/GH 身份或机器级配置。

可离线协议/故障注入测试与真实 GitHub/Microsoft/Rust 源探针必须分层，避免网络抖动成为所有提交的单点判断。

## 8. 尚待 ADR 冻结的决策

1. 结构化项目配置的准确路径、schema 与 entry bootstrap。
2. 原生入口、GUI EXE 和共享 Core 的安装、定位、升级与签名。
3. Rust workspace/crate 边界，以及 CLI/GUI 二进制关系。
4. `index.html` 是静态 fragment 还是允许受控脚本，以及 Host API 的版本协议。
5. legacy PowerShell execution adapter 的准确边界与删除验收。
6. `run.py` 的 ambient/managed 归属。
7. update、clean 和旧版本 retention 的产品语义。
8. 业务项目 UUID 是否需要，以及与 EntryIdentity 的关系。
9. 跨平台的入口身份、adapter 和受管工具协议。

ADR 必须写清默认主路径、触发条件、迁移方式和旧路径删除条件；未决问题保持当前主路径，不靠局部代码抢先定案。

## 9. 产品级完成定义

Proj 达到目标形态时必须同时满足：

- Fresh clone 可显式建立隔离开发环境，并通过真实 C/C++/Rust 构建探针。
- 一个 Entry 从任意目录稳定控制同一项目，且可与 ProjectRoot 分离。
- CLI 与 GUI 共享 `proj-core`、命令树、状态、Help/View 和配置事实源。
- 新增领域能力无需修改中央路由或复制 Core 安全/状态机制。
- GUI 使用窄 IPC 和受控 View 协议，不依赖本地 HTTP Server。
- managed-only 工具来源可证明，环境不会跨项目或 generation 串用。
- 所有可变状态可验证、可恢复、可整体删除重建。
- 新主路径落地后，旧 CMD/PowerShell 路由 Core 和兼容配置已经删除。
