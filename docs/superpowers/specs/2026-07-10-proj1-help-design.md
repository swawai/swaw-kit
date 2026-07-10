# proj1 中文帮助设计

## 背景

`proj1.cmd` 是一个绑定单个本地项目目录的入口。当前入口协议已经声明 `PROJECT_DIR`、默认 shell、默认 IDE、可选 Git 身份、可选 GitHub 仓库以及可选 `PROJECT_DATA_ROOT`。

本阶段先实现中文帮助。帮助不仅说明当前入口如何使用，也冻结 Project Kit 的目标命令面，作为后续功能开发的用户侧契约。

## 目标

- `proj1 --help` 等帮助入口能够稳定输出 UTF-8 中文。
- 帮助模板使用实际入口名，复制为 `proj2.cmd` 后无需修改帮助实现。
- 当前只有中文模板；显式请求英文时明确提示尚未提供并返回非零。
- 帮助列出 Project Kit 的完整目标命令面，并明确说明除帮助外的命令仍待实现。
- 查看帮助不校验 `PROJECT_DIR`、不创建数据目录、不修改环境。

## 非目标

- 本阶段不实现项目终端、IDE、诊断、环境模块或命令透传。
- 本阶段不提供英文帮助模板。
- 本阶段不抽象通用的跨 kit 国际化框架。
- 本阶段不迁移 `xvenv.cmd` 的环境管理实现。

## 方案

采用三个职责单一的文件：

```text
_lib/project_kit/kit.cmd
_lib/project_kit/help.ps1
_lib/project_kit/help/zh-CN.txt
```

- `kit.cmd` 是 Project Kit 的批处理入口，只识别帮助命令并调用渲染器。其他命令明确返回“尚未实现”，避免误报成功。
- `help.ps1` 负责语言参数解析、UTF-8 输出、模板读取和 `{{COMMAND}}` 替换。
- `help/zh-CN.txt` 是帮助内容的单一事实源，不在 CMD 或 PowerShell 中重复维护文案。

暂不增加 `kit.ps1` 总调度器。等出现第二类实际管理命令时，再依据真实调度需求引入，避免为空架构付维护成本。

## 帮助入口

以下命令显示中文帮助并返回 `0`：

```text
proj1 --help
proj1 -h
proj1 /?
proj1 .help
proj1 .help zh
proj1 .help zh-CN
```

语言优先级为：显式参数、`PROJECT_HELP_LANG`、默认 `zh-CN`。

- `zh`、`zh-CN` 以及其他 `zh-*` 形式统一映射为 `zh-CN`。
- `en`、`en-*` 显示“英文帮助尚未提供”并返回 `1`。
- 其他非空语言显示“不支持的帮助语言”并返回 `1`。
- 不进行系统语言自动探测；首版默认中文，行为更直接、可预测。

## 目标命令面

帮助按以下分组展示后续需要实现的契约。

### 项目管理

```text
proj1                       在 PROJECT_DIR 打开默认 shell
proj1 .info                 显示入口、项目目录、数据目录和关键配置
proj1 .doctor               检查目录、工具、环境和 GitHub 状态
proj1 .dir                  用资源管理器打开 PROJECT_DIR
proj1 .code                 用默认 IDE 打开 PROJECT_DIR
proj1 .shell                打开默认项目 shell
```

### 环境管理

```text
proj1 .env status
proj1 .env ensure
proj1 .env modules
proj1 .env module gh install
proj1 .env module gh use
```

### 项目命令

```text
proj1 git ...
proj1 gh ...
proj1 bun ...
proj1 python ...
proj1 <其他命令> ...
```

点号命令由 Project Kit 管理；非点号命令最终将在 `PROJECT_DIR` 和项目级环境中原样执行。Project Kit 不修改系统 PATH、全局 Git 配置或全局 GitHub CLI 配置。

## 错误行为

- 帮助渲染器、中文模板或 PowerShell 不可用时，输出包含具体路径或依赖名的错误并返回非零。
- 非帮助命令统一提示“当前尚未实现”，返回非零，并引导执行 `proj1 --help`。
- 帮助路径不得因为 `PROJECT_DIR` 不存在而失败。

## 验证

新增一个聚焦帮助契约的 PowerShell 冒烟测试，覆盖：

- 六种中文帮助调用均返回 `0`。
- 输出包含中文标题、实际命令名和完整目标命令分组。
- 输出不残留 `{{COMMAND}}` 模板占位符。
- `.help en` 与 `--help en` 返回 `1` 并提示英文尚未提供。
- 未知语言返回 `1` 并提示不支持。
- 将 `PROJECT_DIR` 临时设为不存在的路径时，帮助仍可显示。
- 查看帮助前后不会创建默认数据目录。

实现遵循测试先行：先写并运行失败的帮助契约测试，再添加最小实现使其通过。
