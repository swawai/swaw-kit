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
  -> Rust Core（CLI / Host / Worker）
  -> Catalog v17
  -> CommandId { space, namespace?, path }
  -> Readiness / Journal / Adapter
  -> Core handler、Runtime Component 或 Module run.*
```

Entry 是薄原生 Launcher。它负责确定自身身份、读取 `_lib/proj/_bin/current`、选择不可变 Core Release Set，并原样传递 argv。若共享 Core 尚不存在，Launcher 才调用 `_lib/proj/bootstrap.ps1`。

冷 Bootstrap 只构建和原子发布四个必备产品制品：`swawkit-proj.exe`、`swawkit-proj-host.exe`、`swawkit-proj-module.exe` 与 `swawkit-proj-toolchain.exe`。其中 Module manager 是位于 `system/module/_app/` 的独立 Cargo 项目，只依赖一个很小的共享协议 crate，不静态依赖 Core。Bootstrap 不扫描、编译或链接领域 Module，因此增加或修改 `swaw/context` 等原生领域不会扩大产品 Runtime 的 Rust 编译集合。

这里有两个不能混为一谈的发布平面：产品 Runtime Release Set v2 严格包含上述四件并共用 `_bin/current`；领域 Native Command Release v2 位于各 owner DataRoot，由 `.module/instantiate` 单独发布并拥有自己的 selector。Module manager 属于前者，因为 fresh install 必须先有管理器才能实例化任何领域；`swaw/context` 属于后者，不能再加入产品 Runtime，否则会出现两个 selector 争夺同一事实源。

每个 Core/Host 进程启动时都以自身 EXE 所在 Release 目录为准，只读取小型 Manifest，校验 v2 身份、四制品记录、精确目录成员与长度；它不追随可能已经切换的 `_bin/current`，也不在每次 CLI 启动时哈希四个 EXE。真正准备启动某个兄弟产品时，才流式校验该单个 Host、Module 或 Toolchain 制品的长度与 SHA-256。这样同时保留旧进程安全存活、内容寻址边界和低启动成本。

Runtime v1 → v2 是一次硬切升级：旧 Launcher 只知道三制品 Core 是否存在，无法从旧二进制推导第四个 Module 产品。因此升级桥必须显式执行新版 `bootstrap.ps1`，或先用旧 Runtime 完成新版 `project/proj/build/app → publish/app`，再原子切换 selector；不在新 Core 中保留 v1 fallback。

## 3. Command Identity 与 CLI

内部身份是结构化值，不从字符串前缀反推来源：

```text
System: { space: system, path: [entry, language] }
Module: { space: module, namespace: swaw, path: [context, add] }
```

规范 CLI 地址：

```text
swawkit .help
swawkit .entry/language
swawkit .dev/setup
swawkit .module/instantiate swaw/context

swawkit swaw/context
swawkit swaw/context/add my-context project/proj/build/app
swawkit project/proj/build/app
swawkit user-custom/something
```

规则：

1. System 使用一个前导点，目录层级使用 `/`。
2. Module 直接从显式 namespace 开始，CLI 不输入 `module/`。
3. namespace 和路径段只接受可移植的小写短横线语法；`system`、`module` 是保留 namespace。
4. 不接受 `..entry`、`.dev.setup`、`system/help`、`module/swaw/context`、`.h` 等旧地址或别名。
5. `::context/<id>` 是动态 Subject 的显示与寻址身份，不是 CLI 命令地址。

## 4. 物理目录与挂载

| 身份 | 物理根 | namespace | 示例地址 |
| --- | --- | --- | --- |
| System | `_lib/proj/system/` | 无 | `.dev/setup` |
| 官方 Module | `_lib/proj/modules/` | `swaw` | `swaw/context` |
| 当前项目 Module | `<targetProjectRoot>/.swaw/` | `project` | `project/proj/build/app` |
| 外部 Module | Profile `moduleMounts[]` | 显式声明 | `user-custom/something` |

Catalog 扫描这些显式根并生成 `swawkit.command-catalog/v17`。除显式挂载根外，只有拥有规范 `swawkit.module.json` 且目录名满足 lower-kebab-case CommandId 语法的目录才形成命令；没有 Manifest 的目录整棵剪枝。下划线不承担额外发现语义，`_lib`、`_src` 等目录只是自然地不具备 Manifest、也不满足公开地址语法。目录、CLI 地址与 namespace 的映射只有这一处事实源；Web、CLI、Journal、DataRoot 和 Subject 协议都消费同一个结构化身份。

Profile 中的外部挂载形如：

```json
{
  "moduleMounts": [
    { "namespace": "user-custom", "root": "D:\\modules\\user-custom" }
  ]
}
```

挂载必须显式，不能靠扫描任意父目录或环境变量猜测。Core 在每次命令执行时发布 `SWAWKIT_PROJ_MODULE_ROOTS` JSON；`SWAWKIT_PROJ_PROJECT_MODULE_ROOT` 只是 `project` 挂载的便捷投影。

## 5. 目录命令协议

`swawkit.module.json` 是命令身份凭证，也是能力声明的单一事实源。只有 schema 的最小 Manifest 表示不可运行的结构命令；Manifest 存在但内容无效时，Catalog 保留该命令的本地诊断并继续检查其显式子模块。普通 `_module.json` 属于其他协议，不被读取，也不会触发递归。

一个可执行命令目录必须且只能拥有一个执行来源：一个真实的本地 `run.*` 文件，或一个 `swawkit.module.json.execution` 声明。两者互斥。

| 入口 | 所属 | 语义 |
| --- | --- | --- |
| `run.exe` | Module | 随源码或发行包直接提供的原生可执行入口 |
| `run.ts` | Module | 随领域源码提供，由当前 Entry 的受管 Bun 执行 |
| `run.py` | Module | 预留给受管 Python；工具链所有权完整前只诊断、不可执行 |
| `run.ps1` / `run.cmd` | 按 Catalog 约束 | 脚本入口；PowerShell 必须满足受管或明确 system 模式 |
| `execution.core` | System | 调用受限、白名单化的进程内 Core handler；不得声明 `requires` |
| `execution.toolchain` | System | 调用同一 Release Set 的低频 Toolchain handler |
| `execution.runtime` | System | 按逻辑 product ID 调用同一 Runtime Release Set 中的独立必备制品 |
| `execution.native` | Module | 目录拥有独立原生项目和内容寻址发布生命周期 |
| `execution.delegate` | Module | 显式委派到同 namespace 的 `execution.native` 真祖先 owner |

`swawkit.module.json`、`_help/`、`_view/` 与私有 `_lib/`、`_src/` 就近属于该命令。相关逻辑靠近所属领域，Catalog 只汇总协议事实，不搬走领域实现。

System 是框架自带的稳定命名空间，不等于 Core。Entry Profile、DataRoot claim、Host 生命周期等需要进程内状态所有权或特权协调的行为才进入 Core；开发工具链操作可以进入 Toolchain；必须先于任意领域实例化而可用、但不需要 Core 内状态的控制面可以成为独立 Runtime Component。普通业务领域不得仅因“官方内置”而进入这三个产品边界。

`.module/instantiate` 与 `.module/status` 由 `product: "module"` 的独立 `swawkit-proj-module.exe` 提供。它随四制品 Runtime Release Set 一起升级、回滚和校验，但源码、依赖和测试位于 `system/module/_app/`。Core 只根据 Catalog 中的 product ID 路由到同一已选择 Release 中的兄弟制品，不内置 `.module` 的构建与发布实现。

Core recovery/control 命令可能在 DataRoot 建立前直接 dispatch，因此不消费模块 Export，Manifest v9 明确禁止 `execution.core` 与 `requires` 组合。需要依赖 Export 的 System 命令应使用受统一依赖断言保护的普通 `run.*`、`execution.toolchain` 或 `execution.runtime`，不能在 control dispatch 中另加一条时序不同的特殊门禁。

## 6. 原生 Module 的独立构建与发布

原生 owner 自身就是独立 Rust 项目：

```text
_lib/proj/modules/context/
├─ Cargo.toml
├─ Cargo.lock
├─ _src/main.rs
├─ _lib/src/...
├─ swawkit.module.json                 # execution.native
└─ add|remove|show|.../swawkit.module.json  # execution.delegate -> swaw/context
```

它不是 `_app` Cargo workspace 成员。`Cargo.toml` 显式生成名为 `run.exe` 的 bin。领域 schema、存储、操作和测试留在领域目录；Core 不通过 Registry 把源码重新静态组合回产品 Runtime 制品。

显式实例化：

```text
swawkit .dev/setup
swawkit .module/instantiate swaw/context
```

`.module/instantiate` 的职责是：

1. 从显式 Module 挂载根读取 Manifest v9，将 delegate 目标归一到 native owner，并生成与 Core 相同的规范执行契约。
2. 使用 `.dev/setup` 已验证并发布的 Rust/MSVC 环境。
3. 从已验证 `rustc` 同目录选择真实 `cargo.exe`，不回退系统 PATH 或 rustup proxy。
4. 对 owner 受控树中的源码、`Cargo.toml`、`Cargo.lock`、全部 Manifest、帮助与资源做确定性快照，并把规范化执行契约作为一个合成构建输入；只排除明确生成的 `target/` 和由另一 selector 管理的嵌套 native owner，不读取或要求 Git。
5. 在 owner DataRoot 的 `_native/work/cargo-target/` 执行 `cargo build --locked --release`。
6. 在有界输出和超时约束下调用候选 `run.exe --swawkit-describe`，要求它报告的 owner 与命令集合和规范执行契约完全一致；执行前后候选字节也必须保持一致。
7. 将 `buildInputRevision`、`executionContractRevision`、命令集合以及 EXE 长度与哈希写入不可变 Native Command Release v2，以该文档的 SHA-256 作为 Release ID。
8. 发布不可变 Release bundle，最后原子切换唯一 selector；任一步失败都保持旧 selector 不变。

发布结构：

```text
DataRoot/modules/<namespace>/<owner-path>/_native/
├─ locks/instantiate.lock
├─ work/cargo-target/
└─ export/command/
   ├─ current
   └─ releases/<sha256>/
      ├─ run.exe
      └─ swawkit.release.json
```

构建或自描述对账失败不会影响旧 selector；同一 Release bundle 重复实例化是幂等操作。普通调用只验证 selector、Release Manifest、EXE 完整性、被调用端口以及当前 Catalog 的执行契约，不扫描或哈希领域源码。Manifest 中会影响运行语义的 owner、delegate、`requires`、`provides` 或命令集合发生变化时，执行契约不匹配会 fail closed；单纯修改 `_src`、`Cargo.toml` 或资源不会让已发布 EXE 突然不可运行。

Core 与 Module manager 复用共享协议 crate 中唯一的 Manifest v9 typed parser/validator；执行声明、依赖、Export、Facet 与 Subject kind 不再各自猜测。命令目录段和 `swawkit.module.json` 文件名也按同一规范大小写发现，因此 manager 能发布的领域必然也是 Catalog 能发现的领域。

源码新鲜度属于显式管理操作：`.module/status <address>` 只读计算当前 `buildInputRevision`，报告 `unpublished | current | outdated`；`.module/instantiate` 才构建并发布新版本。这样每次 CLI 执行的成本与源码树规模无关，也避免把 Git 变成运行时依赖。当前 Rust builder 的摘要边界是 owner 受控树；若 Cargo build script 或 path dependency 擅自读取 owner 外部文件，manager 不把它冒充为可证明的 hermetic 输入，领域应先把依赖发布或收回 owner 边界。`run.ts`、`run.py` 等当前仍是直接源码入口；若未来需要与 EXE 一样的冻结发布语义，应由相应语言的独立 builder/manager 明确实例化为包或不可变脚本 bundle，而不是让 Core 猜测跨语言构建输入。

委派关系由叶子命令自己的 `swawkit.module.json.execution` 显式给出，不放置零字节 marker，也不向上猜测“最近的可运行祖先”。v9 要求 owner 与叶子位于同一 Module namespace、是叶子的真祖先，并且声明 `execution.native`。中间目录是否可运行、是否也声明委派，都不会改变解析结果。Core 仍以叶子命令身份创建 DataRoot、环境与 Journal，然后一次性启动 owner 的当前 `run.exe`；环境同时带有逻辑命令与 native owner 身份。这样既保留 `swaw/context/add` 的独立命令语义，也避免九个子命令耦合发布九份 EXE。

```json
{
  "schema": "swawkit.command-module/v9",
  "execution": {
    "type": "delegate",
    "owner": {
      "type": "command",
      "space": "module",
      "namespace": "swaw",
      "address": "swaw/context"
    }
  }
}
```

## 7. DataRoot、Export 与依赖

DataRoot 与结构化身份同构：

```text
System .dev/setup              -> DataRoot/modules/system/dev/setup/
Module swaw/context            -> DataRoot/modules/swaw/context/
Module project/proj/build/app  -> DataRoot/modules/project/proj/build/app/
```

这里要区分两种 Export：

1. **能力 Export**：命令地址及其 `run.*` 是模块天然对外能力。用户或顶层 orchestrator 通过 `swawkit <address>` 获得完整命令语义；领域 `run.*` 之间不递归启动 Entry，而是直接消费声明的 Export/artifact。
2. **产物 Export**：模块把稳定文件、目录或可执行物发布到自身 DataRoot 的 `export/`，候选和中间文件留在 `work/`。Provider State、领域产物 Manifest、长度与哈希共同形成可验证边界。

Manifest v9 使用具名 Export，而不是把一个 Provider 等同于一个模糊的产物：

```json
{
  "schema": "swawkit.command-module/v9",
  "requires": [{
    "provider": ".dev/setup",
    "export": "environment",
    "contract": "swawkit.proj.dev-setup/v2"
  }],
  "provides": [{
    "id": "runtime-release",
    "contract": "swawkit.proj-build-app/v4"
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

当前关键协议是 Catalog v17、SubjectCollection v3、Context v2、CommandCheck v1、CommandRunEvent v2、CommandRunJournal 查询文档 v2 与 Web live CommandRun v2；未改变字段的持久 Journal State 与不含事件的 CommandRunHistory 保持 v1。Command SubjectRef 使用 `space + namespace? + address`；动态对象使用 `{ type: instance, kind, id }`，例如 `::context/test`。

Web 路由与身份一致：

```text
/commands/system/entry/language
/commands/module/swaw/context
/commands/module/project/proj/build/app
```

Finder 先分 System 与 Module，再按 Module namespace 分组。Web 不自建命令别名，不从物理路径猜能力；它只消费 Catalog、SubjectKind 模板与 Facet resolver。

`swaw/context` 是首个完整垂直样例：一个独立 Cargo owner 提供 Context v2 存储、原子更新、Markdown 与 SubjectCollection 投影；`new/add/remove/note/prompt/show/render/list/delete` 是 delegate 端口。领域记录位于 `DataRoot/modules/swaw/context/state/contexts/`，框架的原生实例位于 `_native/`，二者互不混用。

## 9. 环境、执行与 Journal

环境变量是一次执行的边界，不是长期状态。Core 清除继承的 `SWAWKIT_HOME` 与全部 `SWAWKIT_PROJ_*`，再从当前 Entry、Profile、CommandId 与挂载表生成新环境。关键字段包括：

```text
SWAWKIT_PROJ_CORE_COMMAND_PROTOCOL=2
SWAWKIT_PROJ_CORE_COMMAND_SPACE
SWAWKIT_PROJ_CORE_COMMAND_NAMESPACE
SWAWKIT_PROJ_CORE_COMMAND_ADDRESS
SWAWKIT_PROJ_CORE_COMMAND_DATA_ROOT
SWAWKIT_PROJ_PROJECT_MODULE_ROOT
SWAWKIT_PROJ_MODULE_ROOTS
```

Command environment v2 表示一次真实的 command invocation；不再包含 `phase` 或 Guard scope。动态前提属于命令自身，Core 不再用同一环境协议启动另一轮通用 Guard。

CLI 与 Web Worker 进入同一执行链，使用同一 Catalog、Profile、cwd、只读依赖断言、Adapter、DataRoot 和 Journal。动态领域前提由目标命令自己验证，框架不执行通用的有副作用 Guard。Windows Job Object 管理整棵命令进程树；取消和 Host 退出都会回收后代。

每次运行在所属命令 DataRoot 的 `_runs/<run-id>/` 保存 `events.jsonl` 与 `_state.json`。CLI、Web 实时窗口和历史查询消费同一事件身份。异常退出由 owner lease 与下一次读取安全收敛为明确失败，不能凭 PID 或半写文件猜测成功。

## 10. 当前实施状态

已经完成：

1. `CommandSpace::{System, Module}`、显式 namespace 与唯一规范 CLI 地址。
2. `_lib/proj/system`、官方 `swaw`、项目 `project` 和 Profile 外部挂载扫描。
3. Catalog v17、Web 路由/分组、结构化 Subject CommandRef 与新 DataRoot 映射。
4. Manifest v9 的 `execution` 统一 Core、Toolchain、Runtime、Native 与 Delegate；`.module` 是独立 Cargo 项目和第四个必备 Runtime Component，不静态链接 Core。
5. `.module/instantiate` 与 `.module/status` 管理 Native Command Release v2：显式构建、候选自描述、构建输入状态、不可变内容寻址发布和原子 selector；普通执行不扫描源码。
6. `swaw/context` 完整领域下沉；Core 中旧 Context 业务实现已移除。
7. `.dev/setup` 和旧 Context DataRoot 的一次性状态迁移；迁移只处理已知旧布局，不形成长期双写或 fallback。
8. 项目 `.swaw/proj/...` 命令迁到 `project/proj/...` 地址和 DataRoot。
9. Manifest v9 具名 Export、Provider State v2 发布集合、CommandCheck v1 与执行前递归依赖断言。
10. Rust、Web、Context、TypeScript 与关键 Launcher/CLI/进程树/Journal 黑盒回归。

后续按真实收益推进，而不是为“纯模块化”迁移一切：

1. 审计仍在 System 的业务，只有能形成独立 bounded context 且不需要进程内状态所有权的能力才下沉 Module。
2. 为受管 Python 建立完整版本、来源、安装元数据和哈希所有权后，再启用 `run.py`。
3. 出现真实高频跨模块低层调用后，再设计版本化 EXE/DLL/包 Export 注入；用户与顶层 orchestrator 仍走 `swawkit <address>`，领域 `run.*` 只直接消费声明的 Export/artifact。
4. 出现第二种真实文件 Subject 后，再定义 artifact SubjectKind；不预建万能资产层。
5. 若确认 `.context` 是稳定且必不可少的框架命名，再把 `swaw/context` 一次性硬切到 System 地址 `.context`；地址升格与执行/发布机制正交，Context 仍保持自己的 Cargo 项目和 DataRoot Command Release，不能并入产品 Runtime Release Set。

## 11. 架构护栏

评审新功能时依次问：

1. 这是跨领域必须统一的协议，还是某个领域自己的行为？
2. 修改这个领域，是否被迫修改并重新发布共享 Core？如果是，边界是否放错？
3. 调用方需要完整命令语义，还是经过测量确认的低层高频能力？
4. 状态的唯一事实源和原子授予点在哪里？
5. 失败是否保持旧版本可用，且没有无删除条件的兼容 fallback？
6. 目录、CLI、DataRoot、Subject 和 Web 是否都指向同一个结构化身份？

最终目标不是让所有东西都成为进程，而是让复杂度落在正确所有者处：**Core 为一致性付费，Module 为领域变化付费；两者通过明确协议组合。**
