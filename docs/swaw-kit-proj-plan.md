# SWAW Kit Proj 架构与实施计划

## 1. 结论

Proj 的长期设计心智是：**协议集中、领域自治、能力可组合**。

- Core 只集中维护跨领域必须一致的协议：Entry 身份、Profile、Catalog、Command Identity、DataRoot、只读执行就绪断言、进程生命周期、Journal、Host/Web 边界和受限 System handler。
- Module 领域拥有自己的源码、入口、帮助、声明、状态、数据、构建与发布生命周期。修改一个原生领域，不要求把它重新静态链接进共享 Core。
- 模块之间通过稳定命令地址、Provider contract 与 Export 协作，不通过 Core 内部函数互相耦合。
- 普通执行只消费已经存在的能力，不安装工具、不编译、不修复发布状态。构建原生模块必须显式执行 `.module/instantiate`。

当前命令模型只有两种身份：`System` 与 `Module`。旧的 `Control / Kernel / Action` 分类、双点地址、点分隔层级和 `module/` CLI 前缀都不是兼容入口，也不再属于现行协议。

## 2. 总体运行链

```text
Entry Launcher
  -> Rust Core CLI / Entry Host
  -> Catalog v19
  -> CommandId { space, namespace?, path }
  -> Readiness / Journal / Adapter
  -> CLI 同步执行器 / Host RuntimeService
  -> Core handler、Runtime Component 或 Module run.*
```

Entry 是直接位于 `SWAWKIT_HOME` 根目录的薄原生 Launcher。Launcher 以自身文件名选择 `data/proj.<entry>/`；唯一例外是大小写不敏感的 manager `swawkit.exe`，其 DataRoot 固定为 `data/proj.swawkit/`。每个已初始化 Entry 都以 DataRoot 根部严格的 `entry.id`（64 位小写十六进制加换行）持有稳定身份，并从 `runtime/current` 选择 `runtime/releases/<release-id>/` 中的不可变 Core Release Set。Launcher 原样传递 argv，但不再以 Launcher FileId 或 `_entry.json` claim 绑定实例；替换同路径 Launcher 不会改变 `entry.id`。旧 `_entry.json` 只作为“需要显式迁移”的证据，不再是身份事实，迁移也不会擅自删除它。

普通 Entry 的实例生命周期只由 manager `swawkit.exe` 管理：`.entry/instances` 检查实例，`.entry/instances/create <entry-name>` 创建实例，`.entry/instances/migrate <entry-name>` 只显式迁移同名旧 DataRoot。Entry name 是 1..48 字节的规范 lower-kebab ASCII：以小写字母开头，以小写字母或数字结尾，中间只允许小写字母、数字和不连续的连字符；`swawkit` 保留给 manager，Windows DOS 设备名也明确拒绝。Core 领域服务同时为 CLI 与 Host/Web 提供同一套 inspect/create/migrate 规则，非 manager Entry 即使绕过界面也会被领域边界拒绝。

fresh create 先固定读取 manager 根 Launcher，再要求 manager `runtime/current` 仍等于当前 Host 的 running Release；只有两者属于同一代时，才在 `data/` 下准备并验证完整 DataRoot，其中包含新的 `entry.id`、该 running Runtime Release 副本以及记录目标 Entry name、Launcher 长度和 SHA-256 的 `launcher.json` 摘要回执。回执用于拒绝跨名称复制误认领，不是第二份实例身份。DataRoot 原子提交后才发布根 `<entry-name>.exe`。因此中断最多留下“DataRoot 已就绪、Launcher 待补齐”的可重试状态，不会留下可启动却没有身份的 Launcher；若 manager 在重试前升级，未激活实例的 Runtime、回执和 Launcher 会一起前滚到新的 running generation，而 stale Host 必须先重启。同名旧实例迁移采用另一条明确顺序：验证精确的 `swawkit.proj-entry.v0` 证据，先准备 Runtime、替换 Launcher 并发布 `launcher.json`，最后以 `entry.id` 作为迁移提交点。系统不自动迁移，也不在这个切片提供 rename、delete、repair 或桌面 shortcut；这些能力不能通过猜测路径或兼容 fallback 偷渡进主流程。

只有 manager `swawkit.exe` 可以在 fresh manager DataRoot 尚未建立，或 selector/Runtime 缺失时调用 `_lib/proj/bootstrap.ps1` 完成冷 Bootstrap。普通 Entry 缺少任一必备状态都会 fail closed；它不会自行构建 Runtime，也不会隐式认领现有目录。已有 manager DataRoot 缺少 `entry.id` 时同样 fail closed，只有确认是旧 manager DataRoot 后才能显式执行 `bootstrap.ps1 -MigrateLegacyManagerDataRoot` 补建；畸形 `entry.id` 始终拒绝。

冷 Bootstrap 只构建和原子发布四个必备产品制品：`swawkit-proj.exe`、`swawkit-proj-host.exe`、`swawkit-proj-module.exe` 与 `swawkit-proj-dev.exe`。其中 Module manager 直接以 `system/module/` 为独立 Cargo 根，只依赖一个很小的共享协议 crate，不静态依赖 Core。Bootstrap 不扫描、编译或链接领域 Native Command，因此增加或修改 `.context` 等原生领域不会扩大产品 Runtime 的 Rust 编译集合。

物理源码按可用阶段和状态所有权分层，而不是按“都和构建有关”合并成一个 `.boot` 大域：

| 平面 | 物理入口 | 所有权 |
| --- | --- | --- |
| Stage-0 | 根 `bootstrap.ps1`、`build.ps1` 与私有 `_bootstrap/` | Core 不存在时准备锁定工具链，构建或恢复必备 Runtime |
| Framework Command Runtime | `data/proj_cache/bootstrap/command-runtimes/` | 为框架 `run.ts` / `run.ps1` adapter 固定 Bun 与 Pwsh；不承载用户项目版本 |
| Runtime publication | 每个 Entry 的 `data/proj.<entry>/runtime/`、私有 `_runtime/` 与 System `.runtime` | 校验四制品 Release Set、原子切换该 Entry selector、管理已发布 Runtime 与 Host |
| Domain publication | System `.module` | 在 Core 已建立 Catalog、Entry 与 DataRoot 后发布单个 Native owner |
| Development | System `.dev`，独立 Cargo 产品位于 `system/dev/` | 当前 Entry/Profile 的用户与项目开发环境 Export |

私有 `_toolchain/` 只保留 Stage-0 使用的原生 PowerShell 原语和有限工具配方（当前包括 Bun/Pwsh 归档原语以及 Bootstrap 必需的 MSVC/Rust 模块）；它不是命令空间，不拥有 Runtime selector。Stage-0 用这些配方发布一个独立、内容寻址的 Framework Command Runtime，供 Core 的脚本 adapter 使用。丰富的 Entry 开发环境下载、安装、状态与发布全部属于独立 `system/dev` Rust 产品。两者可以暂时保留相似实现，但不能通过反向依赖重新耦合。真正的冷启动必须位于 Catalog 之外、Core 之前：把它命名成 `.boot` System 命令会要求 Core 先存在，形成自举环。若未来需要健康 Runtime 内的自修复，应建模为 `.runtime/repair`；若需要统一的冷恢复 CLI，应由 Launcher 顶层 verb 或独立 Bootstrap 程序提供，而不是伪装成 Catalog 命令。

`bootstrap.json` 是 Stage-0 builder 与 Framework Command Runtime 的版本事实源。Stage-0 每次准备工具链时，都把构建所需变量、PATH 前缀以及 Cargo、Rustc、MSVC compiler/linker 的路径、长度和摘要原子发布为 `data/proj_cache/bootstrap/environment.json`；同时把固定版本和摘要的 Bun/Pwsh 发布到 `command-runtimes/releases/<id>/manifest.json`，再由产品 Runtime Release 记录该 `commandRuntimeId`。`.module/instantiate` 只验证并消费 builder 投影，不读取 `.dev/setup` 的 Entry/Profile publication；投影缺失或与 `bootstrap.json` 不一致时显式执行物理 `_bootstrap/setup.ps1` 修复。这样产品构建、框架脚本解释器和用户业务开发环境可以分别选版、升级和失效。

私有 PowerShell `_toolchain/` 与产品 `swawkit-proj-dev.exe` 不是同一个所有权概念：前者用于 Core 不存在时的 Stage-0 工具链和 Framework Command Runtime，后者就是 `.dev/setup` 与 `.dev/status` 的领域执行产品。Dev 以标准 Cargo 根 `system/dev/` 独立编译，只依赖共享协议 crate；Core 不读取或注入 Dev 发布的 `environment.json`，也不静态链接 Dev 的安装仓库或算法。只有 `.dev/bun`、`.dev/pwsh`、`.dev/rust/cargo` 等显式目标环境命令才验证 Provider State 并导入这份 Export。Runtime cleanup 已回归 Core 内部控制逻辑，不再借 Dev 启动第二个进程。

这里有三个不能混为一谈的发布平面：Framework Command Runtime v1 位于共享 Bootstrap DataRoot；每个 Entry 的产品 Runtime Release Set v4 严格包含上述四件、固定一个 `commandRuntimeId`，并只使用自身 `data/proj.<entry>/runtime/current`；领域 Native Command Release v3 位于各 owner DataRoot，由 `.module/instantiate` 单独发布并拥有自己的 selector。Module manager 与 Dev manager 属于产品 Runtime，因为 fresh install 必须先有管理器；`.context` 属于领域 Native Release，不能再加入产品 Runtime，否则会出现两个 selector 争夺同一事实源。

每个 Core/Host 进程启动时都从自身 EXE 严格反推 `data/proj.<entry>/runtime/releases/<release-id>/`，再校验 Launcher 传入的 Entry basename、`entry.id` 与磁盘事实一致；旧 `_lib/proj/_bin` 布局会被拒绝。进程只读取小型 Manifest，校验 v4 身份、四制品记录、`commandRuntimeId`、精确目录成员与长度；它不追随可能已经切换的 `runtime/current`，也不在每次 CLI 启动时哈希四个 EXE 或整个工具环境。真正准备启动某个兄弟产品或脚本 adapter 时，才流式校验被使用的单个 EXE。这样同时保留旧进程安全存活、内容寻址边界和低启动成本。

Host 的持久发现与控制协议已经硬切到 `swawkit.host-runtime/v2`、`swawkit.host-status/v2` 与 `swawkit.runtime-status/v2`。Instance key 是规范 DataRoot 路径与 `entry.id` 的 SHA-256；Host 单实例租约再加入运行 `release-id`，所以它表达的是一个明确 Runtime generation，而不是某个可替换 Launcher 文件。Host Runtime 文档位于 `runtime/hosts/<running-release-id>.json`，并以 `entryId + instanceKeySha256 + releaseId + bootId + pid + loopback URL` 绑定健康端点；health response 同时回显 boot、entry、instance 与 release，任何不一致都 fail closed。Runtime Status v2 汇总 selector、Release 数量与这一代 Host 状态，不按 PID 猜测实例。

Runtime v3 → v4 与 per-Entry Runtime layout 都是硬切升级：四个 EXE 的精确集合保持不变，v4 新增 `commandRuntimeId`，并把脚本 adapter 的 Bun/Pwsh 版本从隐式 `.dev` 状态提升为 Runtime 的发布依赖。新 Launcher、Core 与 Runtime publisher 不读取或创建旧 `_lib/proj/_bin`；该目录只可留在显式的旧部署壳层回退中，不属于产品运行主路径，也不是兼容 selector。

Launcher 构建与部署同样分离。`project/proj/build/launcher` 只发布命令自身的 `export/swawkit.exe`，物理 `_lib/proj/build.ps1` 只生成 `data/proj_cache/bootstrap/build/launcher/release/swawkit.exe` 候选；两者都不替换根 Launcher。当前没有 `project/proj/publish/launcher`、Launcher template 或 `Favorites` 自动发布路径；根 `swawkit.exe` 及其改名副本只能由源码包或显式部署提供。

## 3. Command Identity 与 CLI

内部身份是结构化值，不从字符串前缀反推来源：

```text
System: { space: system, path: [context, add] }
Module: { space: module, namespace: project, path: [proj, build, app] }
```

规范 CLI 地址：

```text
swawkit .help
swawkit .entry/language
swawkit .dev/setup
swawkit .module/instantiate .context

swawkit .context/list --json
swawkit .context/add my-context project/proj/build/app
swawkit project/proj/build/app
swawkit user-custom/something
```

规则：

1. System 使用一个前导点，目录层级使用 `/`。
2. Module 直接从显式 namespace 开始，CLI 不输入 `module/`。
3. namespace 和路径段只接受可移植的小写短横线语法；`system`、`module` 是保留 namespace。
4. 不接受 `..entry`、`.dev.setup`、`system/help`、`module/project/build`、`.h` 等旧地址或别名。
5. `::context/<id>` 是动态 Subject 的显示与寻址身份，不是 CLI 命令地址。

## 4. 物理目录与挂载

| 身份 | 物理根 | namespace | 示例地址 |
| --- | --- | --- | --- |
| System | `_lib/proj/system/` | 无 | `.context`、`.dev/setup` |
| 官方 Module | `_lib/proj/modules/` | `swaw` | `swaw/example` |
| 当前项目 Module | `<targetProjectRoot>/.swaw/` | `project` | `project/proj/build/app` |
| 外部 Module | Profile `moduleMounts[]` | 显式声明 | `user-custom/something` |

某种 Module 来源没有任何命令时，其挂载根可以不存在；Catalog 与命令环境只发布实际存在的挂载，不用靠空目录占位。显式声明但已经失效的外部挂载仍应 fail closed，不能被当作自然空集合忽略。

Catalog 扫描这些显式根并生成 `swawkit.command-catalog/v19`。除显式挂载根外，只有拥有规范 `swawkit.module.json` 且目录名满足 lower-kebab-case CommandId 语法的目录才形成命令；没有 Manifest 的目录整棵剪枝。下划线不承担额外发现语义，普通 `src/` 等实现目录只是自然地不具备 Manifest。目录、CLI 地址与 namespace 的映射只有这一处事实源；Web、CLI、Journal、DataRoot 和 Subject 协议都消费同一个结构化身份。

Profile 中的外部挂载形如：

```json
{
  "moduleMounts": [
    { "namespace": "user-custom", "root": "D:\\modules\\user-custom" }
  ]
}
```

挂载必须显式，不能靠扫描任意父目录或环境变量猜测。Core 在每次命令执行时发布规范 `SWAWKIT_PROJ_SYSTEM_ROOT` 与 `SWAWKIT_PROJ_MODULE_ROOTS` JSON；`SWAWKIT_PROJ_PROJECT_MODULE_ROOT` 只是 `project` 挂载的便捷投影。

## 5. 目录命令协议

`swawkit.module.json` 是命令身份凭证，也是能力声明的单一事实源。只有 schema 的最小 Manifest 表示不可运行的结构命令；Manifest 存在但内容无效时，Catalog 保留该命令的本地诊断并继续检查其显式子模块。普通 `_module.json` 属于其他协议，不被读取，也不会触发递归。

一个可执行命令目录必须且只能拥有一个执行来源：一个真实的本地 `run.*` 文件，或一个 `swawkit.module.json.execution` 声明。两者互斥。

| 入口 | 所属 | 语义 |
| --- | --- | --- |
| `run.exe` | Module | 随源码或发行包直接提供的原生可执行入口 |
| `run.ts` | Module | 随领域源码提供，由当前 Runtime 固定的 Framework Bun 执行 |
| `run.py` | Module | 预留给受管 Python；工具链所有权完整前只诊断、不可执行 |
| `run.ps1` / `run.cmd` | 按 Catalog 约束 | `run.ps1` 由当前 Runtime 固定的 Framework Pwsh 执行；`run.cmd` 由系统 `cmd.exe` 执行 |
| `execution.core` | System | 调用受限、白名单化的进程内 Core handler；不得声明 `requires` |
| `execution.runtime` | System | 按逻辑 product ID 调用同一 Runtime Release Set 中的独立必备制品 |
| `execution.native` | System 或 Module | 目录拥有独立原生项目和内容寻址发布生命周期 |
| `execution.delegate` | System 或 Module | 显式委派到同一命令空间的 `execution.native` 真祖先 owner；Module 还必须同 namespace |

`swawkit.module.json`、`_help/`、`_view/` 与标准 `src/` 就近属于该命令。相关逻辑靠近所属领域，Catalog 只汇总协议事实，不搬走领域实现。

System 是框架自带的稳定命名空间，不等于 Core。Entry Profile、`entry.id`/DataRoot 身份校验、Host 生命周期等需要进程内状态所有权或特权协调的行为才进入 Core；必须随产品存在、但不需要 Core 内状态的 `.module` 与 `.dev` 成为独立 Runtime Component。普通业务领域不得仅因“官方内置”而进入产品 Runtime 边界。

`.module/instantiate` 与 `.module/status` 由 `product: "module"` 的独立 `swawkit-proj-module.exe` 提供。它随四制品 Runtime Release Set 一起升级、回滚和校验，源码、依赖和测试则直接位于标准 Cargo 根 `system/module/`。Core 只根据 Catalog 中的 product ID 路由到同一已选择 Release 中的兄弟制品，不内置 `.module` 的构建与发布实现。

`.dev/setup` 与 `.dev/status` 同理由 `product: "dev"` 的独立 `swawkit-proj-dev.exe` 提供，源码、依赖和测试直接位于 `system/dev/`。setup 成功后先发布有版本的 `environment.json`/`env.ps1` Export，再原子发布绑定同一 `inputRevision + publicationToken` 的 Provider State。Core 只传递当前 Profile 的 Dev 配置声明和 input revision，不消费产出的 PATH 或工具路径；`.dev/*` 薄命令在自身进程内显式验证并导入目标环境。`.check` 与 `.dev/status` 承担显式诊断，普通领域 `run.ts`/`run.ps1` 完全不依赖目标 Dev publication。

Core recovery/control 命令可能在 DataRoot 建立前直接 dispatch，因此不消费模块 Export，Manifest v11 明确禁止 `execution.core` 与 `requires` 组合。需要依赖 Export 的 System 命令应使用受统一依赖断言保护的普通 `run.*`、`execution.runtime` 或 `execution.native`，不能在 control dispatch 中另加一条时序不同的特殊门禁。

## 6. 原生 Module 的独立构建与发布

原生 owner 自身就是独立 Rust 项目：

```text
_lib/proj/system/context/
├─ Cargo.toml
├─ Cargo.lock
├─ src/main.rs
├─ src/lib.rs
├─ src/...
├─ swawkit.module.json                 # execution.native
└─ add|remove|show|.../swawkit.module.json  # execution.delegate -> .context
```

它不是 `_app` Cargo workspace 成员。`Cargo.toml` 显式生成名为 `run.exe` 的 bin。领域 schema、存储、操作和测试留在领域目录；Core 不通过 Registry 把源码重新静态组合回产品 Runtime 制品。

显式实例化：

```text
swawkit .module/instantiate .context
```

正常冷 Bootstrap 或产品 build 已准备 Native builder 投影。只有投影被删除、损坏或 `bootstrap.json` 改版后，才显式执行物理 `_lib/proj/_bootstrap/setup.ps1`；这不是 Catalog 命令，也不创建 `.boot` 特殊地址。

`.module/instantiate` 的职责是：

1. 从显式 System 根或 Module 挂载根读取 Manifest v11，将 delegate 目标归一到 native owner，并生成与 Core 相同的规范执行契约。
2. 读取与 `bootstrap.json` 精确匹配的 Bootstrap builder projection，验证变量集合、受控目录以及 Cargo、Rustc、MSVC compiler/linker 的长度与摘要；不消费 `.dev/setup`。
3. 直接启动投影声明并验证过的真实 `cargo.exe`，只把投影环境注入该构建子进程，不回退系统 PATH 或 rustup proxy。
4. 对 owner 受控树中的源码、`Cargo.toml`、`Cargo.lock`、全部 Manifest、帮助与资源做确定性快照，并把规范化执行契约作为一个合成构建输入；只排除明确生成的 `target/` 和由另一 selector 管理的嵌套 native owner，不读取或要求 Git。
5. 在 owner DataRoot 的 `_native/work/cargo-target/` 执行 `cargo build --locked --release`。
6. 在有界输出和超时约束下调用候选 `run.exe --swawkit-describe`，要求它报告的 owner 与命令集合和规范执行契约完全一致；执行前后候选字节也必须保持一致。
7. 将 `buildInputRevision`、`executionContractRevision`、命令集合以及 EXE 长度与哈希写入不可变 Native Command Release v3，以该文档的 SHA-256 作为 Release ID。
8. 发布不可变 Release bundle，最后原子切换唯一 selector；任一步失败都保持旧 selector 不变。

发布结构：

```text
DataRoot/modules/<space-or-namespace>/<owner-path>/_native/
├─ locks/instantiate.lock
├─ work/cargo-target/
└─ export/command/
   ├─ current
   └─ releases/<sha256>/
      ├─ run.exe
      └─ swawkit.release.json
```

构建或自描述对账失败不会影响旧 selector；同一 Release bundle 重复实例化是幂等操作。普通调用只验证 selector、Release Manifest、EXE 完整性、被调用端口以及当前 Catalog 的执行契约，不扫描或哈希领域源码。Manifest 中会影响运行语义的 owner、delegate、`requires`、`provides` 或命令集合发生变化时，执行契约不匹配会 fail closed；单纯修改 `src/`、`Cargo.toml` 或资源不会让已发布 EXE 突然不可运行。

Core、Module manager 与 Dev manager 复用共享协议 crate 中唯一的 Manifest v11、Command identity、Dev environment Export 等协议类型；执行声明、依赖、Export、Facet 与 Subject kind 不再各自猜测。命令目录段和 `swawkit.module.json` 文件名也按同一规范大小写发现，因此 manager 能发布的领域必然也是 Catalog 能发现的领域。

源码新鲜度属于显式管理操作：`.module/status <address>` 只读计算当前 `buildInputRevision`，报告 `unpublished | current | outdated`；`.module/instantiate` 才构建并发布新版本。这样每次 CLI 执行的成本与源码树规模无关，也避免把 Git 变成运行时依赖。当前 Rust builder 的摘要边界是 owner 受控树；若 Cargo build script 或 path dependency 擅自读取 owner 外部文件，manager 不把它冒充为可证明的 hermetic 输入，领域应先把依赖发布或收回 owner 边界。`run.ts`、`run.py` 等当前仍是直接源码入口；若未来需要与 EXE 一样的冻结发布语义，应由相应语言的独立 builder/manager 明确实例化为包或不可变脚本 bundle，而不是让 Core 猜测跨语言构建输入。

委派关系由叶子命令自己的 `swawkit.module.json.execution` 显式给出，不放置零字节 marker，也不向上猜测“最近的可运行祖先”。v11 要求 owner 与叶子位于同一 Command space、是叶子的真祖先，并且声明 `execution.native`；Module 身份还必须同 namespace。中间 native owner 始终形成领域边界，不能被后代穿越。Core 仍以叶子命令身份创建 DataRoot、环境与 Journal，然后一次性启动 owner 的当前 `run.exe`；环境同时带有逻辑命令与 native owner 身份。这样既保留 `.context/add` 的独立命令语义，也避免九个子命令耦合发布九份 EXE。

```json
{
  "schema": "swawkit.command-module/v11",
  "execution": {
    "type": "delegate",
    "owner": {
      "type": "command",
      "space": "system",
      "address": ".context"
    }
  }
}
```

## 7. DataRoot、Export 与依赖

Entry DataRoot 先由 Launcher 文件名确定：`<entry>.exe -> data/proj.<entry>/`，manager 始终规范为 `data/proj.swawkit/`。DataRoot 内的 `entry.id` 是稳定实例身份，`runtime/current` 与 `runtime/releases/` 是该实例独享的产品 Runtime selector 和不可变 Release Store；命令数据再按结构化 Command identity 投影到 `modules/`。文件名负责寻址，`entry.id` 负责防止错误实例接管，二者不能互相替代。

DataRoot 与结构化身份同构：

```text
System .dev/setup              -> DataRoot/modules/system/dev/setup/
System .context                -> DataRoot/modules/system/context/
Module project/proj/build/app  -> DataRoot/modules/project/proj/build/app/
```

这里要区分两种 Export：

1. **能力 Export**：命令地址及其 `run.*` 是模块天然对外能力。用户或顶层 orchestrator 通过 `swawkit <address>` 获得完整命令语义；领域 `run.*` 之间不递归启动 Entry，而是直接消费声明的 Export/artifact。
2. **产物 Export**：模块把稳定文件、目录或可执行物发布到自身 DataRoot 的 `export/`，候选和中间文件留在 `work/`。Provider State、领域产物 Manifest、长度与哈希共同形成可验证边界。

Manifest v11 使用具名 Export，而不是把一个 Provider 等同于一个模糊的产物：

```json
{
  "schema": "swawkit.command-module/v11",
  "requires": [{
    "provider": ".dev/setup",
    "export": "environment",
    "contract": "swawkit.proj.dev-setup/v3"
  }],
  "provides": [{
    "id": "runtime-release",
    "contract": "swawkit.proj-build-app/v6"
  }]
}
```

`provider + export` 是被依赖能力的逻辑身份，`contract` 是其精确数据或 IO 协议身份。Provider State v2 在一次原子发布中列出实际 Ready 的 `{id, contract}` 集合；Manifest 声明、Provider State 和消费要求三者必须精确相交。框架当前不在声明中增加泛化 `kind`：文件、目录、Release Set 与 EXE 的内容完整性继续由各自领域 Manifest 验证，避免用一个过早的万能 Artifact schema 抹平真实差异。

`.check <command-address> --json` 只读报告命令入口及其输入依赖能否立即执行，不评价目标自身声明的 `provides`，不猜测领域私有文件格式，也不执行安装、编译、修复或领域代码。普通 CLI 与 Web 执行会在 Journal 和目标进程之前复用同一递归依赖断言；任一依赖缺失、契约不匹配或传递依赖未就绪时直接失败。显式 `.check && run` 适合人和 CI 提前取得诊断，但执行边界仍必须重新读取状态，不能把协议正确性寄托在调用者记忆或存在竞态的旧检查结果上。

`requires` 只表达已发布能力能否消费，不是命令调用路由。`run.*` 应直接消费声明的 Export/artifact，不在领域进程内递归启动另一个 Entry；Launcher 检测到 command protocol 时拒绝 nested Entry，这是执行环境、Job 与 Journal 的隔离边界。多个命令的串联属于未来 Playbook 或更上层 orchestrator，不由叶子命令暗中编排。

`::artifact/<id>` 可以作为未来统一文件产物身份，并用 `path`、`run` 等 Facet 暴露能力；`.path`、`.run` 不应拼入 Subject 规范地址。当前具名 Export 已解决模块间依赖身份，但尚没有第二种真实文件 Subject，因此不建立全局 artifact registry。

Manifest、解析结果与 Playbook 必须分层：`swawkit.module.json` 是作者维护的声明，Provider State 与不可变 Release Manifest 是运行时发布事实；未来若需要可复现的跨模块解析，应生成独立 lock 文档。Playbook 是按顺序调用命令和引用 Export 的程序，不应把解析结果回写进模块 Manifest，也不应把 Web Facet 配置误当成执行 DSL。首个 Playbook 应从真实链路（例如 build → publish）提炼，而不是现在预建通用语法。

## 8. Subject、Facet 与 Web

统一对象模型包含：

- `SubjectRef`：静态 Command 或动态 Instance 的结构化身份。
- `Facet`：Subject 可浏览、投影或执行的能力。
- `SubjectCollection`：某个 collection Facet 的解析结果。

当前关键协议是 Catalog v19、SubjectCollection v3、Context v2、CommandCheck v1、CommandRunEvent v2、CommandRunJournal 查询文档 v2 与 Web live CommandRun v2；未改变字段的持久 Journal State 与不含事件的 CommandRunHistory 保持 v1。Command SubjectRef 使用 `space + namespace? + address`；动态对象使用 `{ type: instance, kind, id }`，例如 `::context/test`。

Web 路由与身份一致：

```text
/commands/system/entry/language
/commands/system/context
/commands/module/project/proj/build/app
```

Finder 先分 System 与 Module，再按 Module namespace 分组。Web 不自建命令别名，不从物理路径猜能力；它只消费 Catalog、SubjectKind 模板与 Facet resolver。

`.context` 是首个完整垂直样例：它拥有 System 身份，但执行实现仍是独立 Cargo owner；Context v2 存储、原子更新、Markdown 与 SubjectCollection 投影全部由领域自身提供，`new/add/remove/note/prompt/show/render/list/delete` 是 delegate 端口。领域记录位于 `DataRoot/modules/system/context/state/contexts/`，框架的原生实例位于 `_native/`，二者互不混用。地址空间与执行技术正交：System 不等于 Core，Native 也不等于 Module。

## 9. 环境、执行与 Journal

环境变量是一次执行的边界，不是长期状态。Core 清除继承的 `SWAWKIT_HOME` 与全部 `SWAWKIT_PROJ_*`，再从当前 Entry、Profile、CommandId 与挂载表生成新环境。关键字段包括：

```text
SWAWKIT_PROJ_CORE_COMMAND_PROTOCOL=2
SWAWKIT_PROJ_CORE_COMMAND_SPACE
SWAWKIT_PROJ_CORE_COMMAND_NAMESPACE
SWAWKIT_PROJ_CORE_COMMAND_ADDRESS
SWAWKIT_PROJ_CORE_COMMAND_DATA_ROOT
SWAWKIT_PROJ_CORE_COMMAND_RUNTIME_ID
SWAWKIT_PROJ_SYSTEM_ROOT
SWAWKIT_PROJ_PROJECT_MODULE_ROOT
SWAWKIT_PROJ_MODULE_ROOTS
```

Command environment v2 表示一次真实的 command invocation；不再包含 `phase` 或 Guard scope。`COMMAND_RUNTIME_ID` 只描述当前产品 Runtime 固定的框架脚本解释器，不是 `.dev/setup` 的 target environment。Core 可以把 Profile 中的 Dev 选版声明传给 Dev Runtime Component，但不会把 Dev Export 的变量或 PATH 注入普通命令。需要 Python 3.9 等目标项目工具的脚本，应显式调用 `.dev/python`、`.dev/uv` 等领域入口；脚本自身使用的解释器版本属于 Framework Command Runtime。

CLI 与 Host RuntimeService 复用同一 Catalog、Profile、cwd、只读依赖断言、Adapter、DataRoot、进程物化和 Journal 规则。Web command 与 Facet query 直接调用 Host 内的 RuntimeService；RuntimeService 在 Journal 建立后直接执行 Core handler 或启动领域进程，不再递归启动 Entry Launcher 与第二个 Core。动态领域前提由目标命令自己验证，框架不执行通用的有副作用 Guard。Windows Job Object 管理整棵命令进程树；取消和 Host 退出都会回收后代。

每次运行在所属命令 DataRoot 的 `_runs/<run-id>/` 保存 `events.jsonl` 与 `_state.json`。CLI、Web 实时窗口和历史查询消费同一事件身份。异常退出由 owner lease 与下一次读取安全收敛为明确失败，不能凭 PID 或半写文件猜测成功。

## 10. 当前实施状态

已经完成：

1. `CommandSpace::{System, Module}`、显式 namespace 与唯一规范 CLI 地址。
2. `_lib/proj/system`、官方 `swaw`、项目 `project` 和 Profile 外部挂载扫描；System/Module 身份与执行 adapter 正交。
3. Catalog v19、Web 路由/分组、结构化 Subject CommandRef 与共享 DataRoot 映射。
4. Manifest v11 的 `execution` 统一 Core、Runtime、Native 与 Delegate；`.module` 与 `.dev` 都是独立 Cargo 项目和必备 Runtime Component，不静态链接 Core。
5. `.module/instantiate` 与 `.module/status` 管理 Native Command Release v3：显式构建、候选自描述、构建输入状态、不可变内容寻址发布和原子 selector；instantiate 消费独立 Bootstrap builder projection，普通执行不扫描源码。
6. `.context` 以 System identity + Native execution 完整领域下沉；Core 中旧 Context 业务实现已移除。
7. `.dev/setup` 和 Context 领域数据均采用一次性显式迁移；运行时代码不保留旧地址根的双写或 fallback。
8. 项目 `.swaw/proj/...` 命令迁到 `project/proj/...` 地址和 DataRoot。
9. Manifest v11 具名 Export、Provider State v2 发布集合、CommandCheck v1 与执行前递归依赖断言。
10. Runtime Release v4 固定 Framework Command Runtime v1；每个 Entry 独享 `data/proj.<entry>/runtime/current` 与 `runtime/releases/`，Core 的 Bun/Pwsh adapter 与目标 `.dev` 环境完全解耦，`.dev/*` 只在被显式调用时导入目标环境。
11. Launcher protocol v5 传递并复验 `entry.id`，且只允许 `cli` 与 `internal-host` 两个 composition root；FileId、DataRoot claim、共享 `_bin` 与旧 worker launch 主路径已删除，只有 manager `swawkit.exe` 可以冷 Bootstrap。
12. Rust、Web、Context、TypeScript 与关键 Launcher/CLI/进程树/Journal 黑盒回归。
13. Host RuntimeService 直接执行 Core handler 与领域进程；Host Runtime/Status v2 以 `entryId + instanceKeySha256 + releaseId + bootId` 绑定 generation，Run 与无 Journal query 共用容量和 shutdown 生命周期，可取消的领域进程统一由 Job Object 监督。Launch v5 仅保留 `cli` 与 `internal-host` 两个 composition root，旧 Entry worker launch protocol 已硬删除。
14. manager-only Entry lifecycle 已统一到 `EntryManager`：inventory/inspect、可重试 create 与同名显式 legacy migration 共用同一领域规则；`launcher.json` 绑定目标名称与 Launcher 摘要，`entry.id` 是唯一身份事实和迁移的最终提交点。manager 自身的冷迁移仍由 Bootstrap 完成。

后续按真实收益推进，而不是为“纯模块化”迁移一切：

1. 审计仍在 System 的业务，只有能形成独立 bounded context 且不需要进程内状态所有权的能力才下沉 Module。
2. 为受管 Python 建立完整版本、来源、安装元数据和哈希所有权后，再启用 `run.py`。
3. 出现真实高频跨模块低层调用后，再设计版本化 EXE/DLL/包 Export 注入；用户与顶层 orchestrator 仍走 `swawkit <address>`，领域 `run.*` 只直接消费声明的 Export/artifact。
4. 出现第二种真实文件 Subject 后，再定义 artifact SubjectKind；不预建万能资产层。
5. 出现第二个 System Native 领域时，优先复用现有结构化 identity、DataRoot 和 Release 协议，不为具体地址增加 Core 特判。

## 11. 架构护栏

评审新功能时依次问：

1. 这是跨领域必须统一的协议，还是某个领域自己的行为？
2. 修改这个领域，是否被迫修改并重新发布共享 Core？如果是，边界是否放错？
3. 调用方需要完整命令语义，还是经过测量确认的低层高频能力？
4. 状态的唯一事实源和原子授予点在哪里？
5. 失败是否保持旧版本可用，且没有无删除条件的兼容 fallback？
6. 目录、CLI、DataRoot、Subject 和 Web 是否都指向同一个结构化身份？

最终目标不是让所有东西都成为进程，而是让复杂度落在正确所有者处：**Core 为一致性付费，Module 为领域变化付费；两者通过明确协议组合。**
