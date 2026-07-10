# repo1.cmd / GH Wrapper Trial Plan

## 结论

下一步可以试做一个 `repo1.cmd` 形态的 repo 工作台。它不取代 `git1.cmd`，而是以一个本地 repo 目录为核心绑定，并在这个 repo 维度绑定 GitHub CLI 上下文：一个脚本对应一个 `REPO_DIR`、一个 `GH_CONFIG_DIR`、一个默认 `GH_REPO`。

核心心智：

```text
git1.cmd  = Git 身份入口，负责 user.name / user.email / SSH key / signing
repo1.cmd = 本地 repo 工作台，负责 REPO_DIR / GH_REPO / GH_CONFIG_DIR / gh 透传
```

## 资源即目录 / 资源即命令

`repo1.cmd` 的产品心智不是“把 gh 命令变短”，而是把一个本地项目目录变成稳定命令入口。

```text
repo1 = 绑定到 REPO_DIR 的项目资源
```

这个入口把原本分散在脑子里、终端当前目录里、gh 全局状态里的上下文固定下来：

```text
REPO_DIR       本地项目目录
GH_REPO        线上 GitHub 仓库
GH_CONFIG_DIR  这个项目对应的 gh 登录/配置上下文
```

这样设计的主要收益是降低项目切换和账号切换的摩擦。人和 Agent 都不需要先探索“项目在哪、当前 gh 操作哪个 repo、当前账号是谁”，而是从固定入口开始：

```cmd
repo1 .info
repo1 .doctor
repo1 repo view
repo1 pr list
```

这延续了工具箱里“一资源一入口”的模式：`wsl01.cmd` 绑定一个 WSL 实例，`vps1.cmd` 绑定一台远程机器，`repo1.cmd` 绑定一个本地项目目录。命令名就是资源边界；点号命令是资源管理面；非点号命令保留底层工具的原生语义。

## 已对齐的设计点

1. `git1.cmd` 继续保持纯 Git 身份边界。
   - 它不扩展成 repo 管理器。
   - 它负责 Git commit identity 和 Git SSH 传输。
   - 这避免把“我是谁”和“我在哪个 repo 工作”混成一个复杂概念。

2. `repo1.cmd` 的主路径是 gh wrapper。
   - 自定义命令全部用点号开头，例如 `.help`、`.info`、`.doctor`。
   - 非点号命令默认交给 `gh`。
   - 第一版尽量不重新包装 `gh` 的语义。

3. `REPO_DIR` 是 repo 脚本的核心绑定。
   - 用户心智是“这个命令管理这个本地仓库目录”。
   - `GH_REPO` 和 `GH_CONFIG_DIR` 都依附于这个 repo 工作台。
   - 第一版的 gh 透传可以在 `REPO_DIR` 下执行，让 gh 也能读取本地 Git remote/context。

4. `GH_CONFIG_DIR` 是账号/配置隔离的核心。
   - 每个 repo 脚本可以设置自己的 `GH_CONFIG_DIR`。
   - `repo1.cmd` 和 `repo2.cmd` 可以分别登录不同 GitHub 账号。
   - 不推荐每次运行时调用 `gh auth switch`，因为它会改变 active account 状态。

5. `GH_REPO` 绑定默认 GitHub 仓库。
   - 格式是 `[HOST/]OWNER/REPO`，例如 `owner/repo` 或 `github.example.com/owner/repo`。
   - wrapper 通过环境变量注入，避免修改本地 `.git/config`。
   - 第一版不主动执行 `gh repo set-default`。

6. token 不由我们自造文件格式保存。
   - 普通用户走 `repo1 auth login`，即原生 `gh auth login` 透传。
   - classic PAT 用户后续可以加 `.auth.token`，实际调用 `gh auth login --with-token`。
   - fine-grained PAT 更适合通过 `GH_TOKEN` 环境变量临时提供。
   - 不建议把 token 明文写进 `repo1.cmd`。

7. `REPO_ENV_FILE` 暂不作为主路径。
   - 既然 `GH_CONFIG_DIR` 已经能隔离登录配置，第一版先不增加 `.env` 或 local env 文件复杂度。
   - 后续只有在真实遇到 per-repo 私密环境变量需求时再加。

8. gh 缺失时不自动下载。
   - 普通 `repo1` 命令如果需要 gh，发现缺失就给清晰提示。
   - 下载便携 gh 这种联网/供应链动作必须显式触发，例如未来的 `.gh.install`。

9. 不把 issue / PR / run 数据同步成本地状态。
   - 第一版把 gh 视为在线查询工具。
   - `repo1 pr list`、`repo1 issue list` 这类命令直接走 gh 当前行为。
   - wrapper 不在 `data\` 下维护自己的 issue/PR 缓存。

## 第一版建议配置

`repo1.cmd` 顶部只保留非敏感配置：

```cmd
set "REPO_NAME=repo1"
set "REPO_DIR=D:\code\repo1"
set "GH_REPO=owner/repo"
set "GH_CONFIG_DIR=%~dp0data\gh\repo1"
```

可选项：

```cmd
set "GH_HOST=github.com"
```

`REPO_DIR` 是主配置。第一版建议所有非点号 gh 透传都在 `REPO_DIR` 下执行；`GH_REPO` 仍然显式注入，避免完全依赖 gh 从 Git remote 推断仓库。

## 命令模型草案

点号命令由 wrapper 自己处理：

```cmd
repo1 .help
repo1 .info
repo1 .auth.token
repo1 .doctor
```

非点号命令透传给 `gh`：

```cmd
repo1 auth status
repo1 auth login
repo1 repo view
repo1 pr list
repo1 issue list
repo1 run list
repo1 workflow list
repo1 release list
repo1 api repos/{owner}/{repo}
```

第一版明确不支持 `repo1 view` 这种隐式别名。查看仓库使用原生 gh 形态：`repo1 repo view`。需要短命令时后续再增加点号快捷命令，例如 `repo1 .view`。

## 第一版不做

1. 不包装大量 gh 子命令。
2. 不自动下载 gh。
3. 不自动运行 `gh auth switch`。
4. 不自动运行 `gh repo set-default`。
5. 不实现完整 `.env` parser。
6. 不把 token 写进 `repo1.cmd`。
7. 不在第一版混入 Git commit/push wrapper。
8. 不实现 wrapper 自己的 issue/PR 本地缓存。

## 试做步骤

1. 新增 `repo1.cmd` 模板。
   - 暴露 `REPO_DIR`、`GH_REPO`、`GH_CONFIG_DIR`。
   - 检查 `_lib\repo_gh_kit\kit.cmd` 是否存在。
   - 设置入口命令名和入口文件路径。

2. 新增 `_lib\repo_gh_kit\kit.cmd`。
   - 处理点号命令。
   - 准备 `GH_CONFIG_DIR` 和 `GH_REPO` 环境变量。
   - 将非点号 gh 透传的工作目录切到 `REPO_DIR`。
   - 检查 `gh` 是否存在。
   - 非点号命令直接执行 `gh %*`。

3. 新增最小点号命令。
   - `.help` 显示 wrapper 帮助。
   - `.info` 显示入口文件、`REPO_DIR`、`GH_REPO`、`GH_CONFIG_DIR`、gh 路径。
   - `.doctor` 检查 gh 是否存在、`REPO_DIR` 是否存在、`GH_REPO` 是否配置、`GH_CONFIG_DIR` 是否可创建、auth status 是否可运行。
   - `.auth.token` 作为可选增强，交互式读取 token，再 pipe 给 `gh auth login --with-token`。

4. 增加 smoke test。
   - fake `gh.cmd` 捕获参数和环境变量。
   - 验证 `repo1 pr list` 透传为 `gh pr list`。
   - 验证 `GH_REPO` 和 `GH_CONFIG_DIR` 被注入。
   - 验证 gh 透传在 `REPO_DIR` 下执行。
   - 验证点号命令不会透传给 gh。
   - 验证 gh 缺失时错误清晰。

## 验证方式

建议第一版完成后至少跑：

```cmd
PowerShell -NoProfile -ExecutionPolicy Bypass -File "_lib\repo_gh_kit\test\smoke.ps1"
repo1 .info
repo1 .doctor
repo1 auth status
repo1 repo view
```

如果本机还没有安装 gh，`repo1 .doctor` 应该清楚提示缺失，而不是自动下载。

## 后续扩展判断

只有在真实使用中高频出现时，再考虑加这些糖：

```cmd
repo1 .view   -> gh repo view
repo1 .web    -> gh repo view --web
repo1 .prs    -> gh pr list
repo1 .runs   -> gh run list
```

这遵守 AHA > DRY：先让重复自然出现，再抽象稳定的快捷入口。
