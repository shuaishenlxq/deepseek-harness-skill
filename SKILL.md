---
name: deepseek-harness-skill
description: Build, extend, and debug DeepSeek Harness (dsh) — DeepSeek AI's open-source agent harness where everything is a plugin, powered by the Cordis framework. Consult this skill for dsh plugin development, Cordis context/services/events, defineTool tool authoring, LLM adapters, profiles and bundles, model/provider configuration, and packaging or installing plugins.
metadata:
  version: "0.1.0"
  agent_created: true
---

# DeepSeek Harness (dsh)

DeepSeek Harness（命令名 `dsh`）是 DeepSeek AI 开源的 **agent harness**，架构原则是
**一切皆插件（Everything is a Plugin）**，底层由 [Cordis](https://github.com/cordiverse/cordis)
插件框架驱动（harness 内置的是 vendor 版本 `@deepseek-ai/cordis`）。

它在产品层面就是一个可执行的 agent（能读写工作区文件、跑命令、委派 subagent、维护计划），
在架构层面则是**插件树**：模型适配器、工具注册表、会话日志、甚至 agent loop 本身都是插件，
所以每一部分都能通过配置替换。**不存在需要打补丁的特权内核** —— 扩展 dsh 的方式是把插件挂到
其他插件旁边；所有注册都是可逆副作用，随插件卸载自动撤销。

> **当前状态：开发者预览（developer preview），正在快速迭代，会有破坏兼容性变更。**
> 本技能基线为 npm `@deepseek-ai/dsh@0.2.0-rc.2`（2026-09-29 发布）。写代码前先用
> `scripts/dsh_info.sh` 核对实际安装版本，API 行为以**目标环境里实际装的那份**为准。

## 关键事实

| 项目 | 值 |
|---|---|
| 仓库 | `https://github.com/deepseek-ai/deepseek-harness`（默认分支 `master`） |
| 文档站 | `https://deepseek-harness.github.io/deepseek-harness/` |
| npm 包 | `@deepseek-ai/dsh`（CLI：profile 启动、插件管理、配置检查） |
| 许可证 | MIT |
| Harness home | `$DSH_HOME`，默认 `~/.dsh` |
| 语言 | TypeScript（ESM，`type: module`）；Node **22.19+ / 24+**（CI 覆盖 22.19、24、26） |
| 包管理 | pnpm（仓库固定 `pnpm@11.7.0`，经 Corepack） |
| Web UI | `http://127.0.0.1:3080` |

## 安装与运行

```sh
# 用 npm 跑（最省事）
npx @deepseek-ai/dsh web            # 默认 http://127.0.0.1:3080，本机自动开浏览器
npx @deepseek-ai/dsh web --no-open  # 只起服务

# 从源码跑（开发插件必须走这条）
git clone https://github.com/deepseek-ai/deepseek-harness.git
cd deepseek-harness
pnpm install
pnpm run build                      # 必须先构建，pnpm dsh 直接用构建产物
pnpm dsh web
```

源码开发另有：`pnpm run dev:web`（构建 + 起服务 + 源码变更时重建 client bundle）、
`pnpm run typecheck`（新克隆后跑一次，成功即表示环境搭好了）、
`pnpm dsh --profile headless "summarize this workspace"`（一次性 headless 任务，需 `DEEPSEEK_API_KEY`）。

Windows 上原生或 WSL 2 均可，但**检出目录、依赖、工具链必须在同一个操作系统环境里**。

## 核心概念（10 秒版）

- **插件**：一个导出 `apply` 函数的 TypeScript 模块。框架加载时调用 `apply(ctx)`，你通过 `ctx` 注册能力。
- **上下文 `ctx`**：服务的容器。一个服务占据稳定的 `ctx.<key>`（`ctx.tools`、`ctx.llm`、`ctx.sessions`、`ctx.agents`…），
  其他插件按 key 查找，而不是 import 具体实现。
- **`inject`**：声明所需服务。**不必手动编排加载顺序** —— 依赖就绪前插件不会被加载；依赖消失时会自动卸载，恢复后再重载。
- **`ctx.effect()` / `ctx.on()`**：注册即副作用，插件卸载时自动撤销。有顺序依赖的清理放进**同一个** effect。
- **事件**：类型化事件，五种分发模式 —— `emit`（广播）、`waterfall`（环绕中间件，必须调 `next()`）、
  `parallel`、`serial`、`bail`（短路）。事件是 dsh 的主要扩展点。
- **Config**：导出一个 `Config` 接口 + 同名 Schemastery schema，默认值写在 schema 里，由 `cordis.yml` 注入。
- **Profile 与组合包（bundle）**：profile 是"一套可启动的组合"（`$DSH_HOME/profiles/<name>`），
  bundle 是"附带一个配置层的 npm 包"。两者都靠 `package.json` 的 `dsh` 字段声明，**没有东西同时是两者**。
- **能力 seam**：可替换能力分三角色 —— Service Definition（接口）/ Service Provider（实现）/ Consumer（通常是对模型暴露的工具）。

## 最小插件

```ts
import type { Context } from '@deepseek-ai/cordis'

export const name = 'hello-plugin'

export function apply(ctx: Context) {
  console.log('[hello-plugin] plugin loaded!')
}
```

函数形式覆盖大多数场景。另外两种形态：对象形式（`export default { name, inject, apply }`）、
类形式（`export default class X extends Service`，用于**对外提供服务**）。

注册到 web 覆盖层 `cordis.yml`（**插件路径必须是绝对路径**）：

```yaml
- insert:
    - id: hello
      name: '/absolute/path/to/deepseek-harness/scratch-plugin/src/my-plugin.ts'
```

```sh
pnpm dsh web --patch ./scratch-plugin/cordis.yml   # 启动时终端打印 [hello-plugin] plugin loaded!
```

## 最小工具

```ts
import type { Context } from '@deepseek-ai/cordis'
import { defineTool } from '@deepseek-ai/dsh-tools'

export const name = 'greet-tool'
export const inject = ['tools']

export function apply(ctx: Context) {
  ctx.tools.register(defineTool({
    name: 'greet',
    description: 'Greet someone by name.',
    parameters: {
      name: { type: 'string', required: true, description: 'The name to greet' },
    },
    output: {
      schema: { type: 'string' },
      render: (_args, value) => [{ type: 'text', text: value }],
    },
    async execute(args) {
      return `Hello, ${args.name}!`
    },
  }))
}
```

`defineTool` 会从 `parameters` 推导并**校验** `args`（所以 `execute` 里不要重复做类型检查，
但要手动检查 schema 表达不了的约束：非空字符串、正数、跨字段规则）。`execute` 只返回
`output.schema` 声明的**规范 JSON 值**，不要把内容块塞进返回值 —— `output.render` 负责转成模型可见内容。

工具开发的完整约定（参数校验、执行身份、`output.schema`/`render`/`presentationMeta`、
UI 卡片、后台任务、PTC mode、策略钩子）见 [references/tools-and-ui.md](references/tools-and-ui.md)。

## CLI 速查

```sh
dsh <name>                                   # 启动 $DSH_HOME/profiles/<name>
dsh --profile <name>                         # 同上，显式写法
dsh --profile <name> --from-default-profile <template>   # 基于模板新建 profile
dsh web                                      # 启动 web profile
dsh plugin --profile <name> <pnpm args...>   # 在 profile 目录内转发给 pnpm，管理插件
dsh --profile demo --dump-config             # 不启动，打印各层 patch 组合后的配置树
dsh --profile demo                           # 启动
dsh --help                                   # 启动器自身帮助
```

> **⚠️ flag 顺序陷阱**：启动器只解析**自己认识**的 flag，遇到第一个不认识的 flag 就把
> **其后所有参数**原样交给 app（`dsh web --help` 打印的是 web app 自己的选项）。
> 因此 `--patch` / `--dump-config` 这类**启动器 flag 必须写在 app 专属 flag 之前**：
>
> ```sh
> dsh web --patch ./x/cordis.yml --no-open --port 3199   # ✅
> dsh web --no-open --port 3199 --patch ./x/cordis.yml   # ❌ unknown option '--patch'
> dsh --patch ./x/cordis.yml web                          # ❌ --profile <name> is required
> ```
>
> 不启动就验证 overlay 是否生效：`dsh --profile web --patch ./x/cordis.yml --dump-config`，
> 输出里能看到 `# == ./x/cordis.yml` 这一层，且插件路径被规范化成 `file:///...`。

随附 profile：`web`、`headless`、`sdk`、`sdk-minimal`、`acp`。
`desktop` 保留给 Electron，CLI 会拒绝针对它的启动与配置 dump。

**配置层顺序**（后应用者按行胜出，patch 会**整段替换**目标行的 `config`，不是深合并）：

1. `dsh.profile.bundles` 列出的各 bundle patch，按列表顺序
2. profile 自己的 `cordis.patch.yml`
3. home 级 `$DSH_HOME/cordis.patch.yml`
4. 每个 `--patch <path>` overlay，按 argv 顺序

推论：你的 patch 想覆盖前面某层某行时，**必须重述该行需要的每一个键**，不能只写改动的那个。

## 开发工作流

1. **准备** — 源码 checkout 完成 `pnpm install` + `pnpm run build` + `pnpm run typecheck`。
2. **写插件** — `.ts` 导出 `apply`（+ 可选 `name` / `inject` / `Config`）。
3. **本地验证** — 用 `--patch` overlay 挂载，`pnpm dsh web --patch ./x/cordis.yml`，看日志和 Web UI。
4. **收口配置** — 凡是"不同部署可能取不同值"的参数都做成 Config 字段，不许硬编码。
5. **打包分发** — `package.json` 声明 `dsh.bundle.patch` 指向 `cordis.patch.yml`，
   用户 `dsh plugin --profile <name> add <pkg>` 安装进 profile。
6. **验证** — 按仓库测试策略补齐组装覆盖；`pnpm run constraints && pnpm run typecheck && pnpm run lint`。

## 仓库结构

```text
deepseek-harness/
├── packages/                  # 全部是 @deepseek-ai/dsh-* 包，按 group 分区
│   ├── core/                  # session / tools / agent / agent-loop / system-prompt / scope
│   ├── llm/                   # llm（seam）、llm-deepseek、llm-pi-ai
│   ├── shell/ subprocess/ fs/ # 执行与文件能力（definition / provider / tool 三件套）
│   ├── skill/ subagent/       # 技能与子智能体
│   ├── bundle/                # base / web-app / headless / sdk-app / sdk-minimal / acp-app
│   ├── boot/                  # app-boot、plugin-manager、config-editor、hmr、cmdline
│   ├── client/ host/ api/     # Web Client、HTTP 服务器、Remote 网关
│   └── experimental/          # 实验包（不稳定）
├── apps/cli/                  # dsh CLI 启动器（唯一受支持的 Node 应用入口）
├── apps/desktop/              # Electron 桌面应用
├── vendor/                    # cordis / cosmokit / schemastery 的 vendor 源码
├── docs/                      # 文档源（含 .zh.md 双语配对）
└── tsconfig.{base,host,client}.json
```

**Host / Client 是两个隔离的 TS aggregate**：普通包只登记进一个（`tsconfig.host.json` 或
`tsconfig.client.json`），两侧对同一个 `Context` 接口做**不同的声明合并**，因此不能塞进同一个
`ts.Program`。`packages/client/*` 走 `tsconfig.base.client.json`。

## 新手最容易踩的坑

- **插件路径要绝对路径**（`--patch` overlay 里）。patch 只贡献配置，不改变 loader 解析模块路径用的 profile 目录。
- **不要导出普通对象当 `Config`** —— 它不满足 Cordis 要求的 Standard Schema 接口，必须用 `@deepseek-ai/schemastery` 的 `Schema.object(...)`。
- **`waterfall` 监听器必须调 `next()`**，不调就是有意短路整条流水线（用于拦截/网关）。
- **从 GitHub 装包拿到的是源码不是产物**：作者要提供自包含的 `prepare` 脚本，用户要显式给 pnpm 授权
  （`pnpm-workspace.yaml` 里 `allowBuilds:`）。不想让用户授权就发 npm 包或 tarball。
- **别在工具里内建部署策略**：用 `tools/pre-execute` / `ctx.tools.guard()` / `tools/execute` /
  `tools/post-execute` / `tools/result` 这些扩展点。
- **别预防性拆分能力**：只有三个角色需要独立演进时才拆成不同包；简单工具插件一个包就够。

## 资源

### 官方文档

- [文档站](https://deepseek-harness.github.io/deepseek-harness/)：指南 / 开发 / 参考三块。
- **`llms.txt`**：`https://deepseek-harness.github.io/deepseek-harness/llms.txt` 列出全站页面及精确 `.md` 地址
  （规则：页面 URL 去尾斜杠 + `.md`；根路径用 `/index.md`）。这是判断"文档里到底怎么写的"的**唯一权威入口**，
  不确定就先抓它，不要凭记忆答。

### GitHub 资源

- [主仓库](https://github.com/deepseek-ai/deepseek-harness)：源码、测试、Agent Note（`.agents/notes/`）。
- [Discussions](https://github.com/deepseek-ai/deepseek-harness/discussions)：反馈与设计讨论。
- 插件仓库加 [`dsh-plugin`](https://github.com/topics/dsh-plugin) 话题便于被发现。

### 本技能的本地参考

按需读取，不要一次全读：

- [Cordis 内核](references/cordis-core.md)：五大概念、`Context`/`Fiber`/`Service` API、
  五种事件分发模式与 waterfall 语义、生命周期状态机、声明合并、HMR。
- [插件开发与分发](references/plugin-development.md)：三种插件形态、`inject`、`effect`、Config 与
  Schemastery、配置设计原则、bundle/profile manifest、加载层序、服务隔离、git 安装与打包。
- [工具与 UI](references/tools-and-ui.md)：`defineTool` DSL、`execute()` 契约、
  规范值/渲染器/`presentationMeta`、UI 卡片类型、工具执行流水线、策略钩子、后台任务、PTC mode。
- [架构与扩展点](references/architecture.md)：一切皆插件、profile/bundle 组装、核心服务表、
  三个事件域、轮次（turn/step）流程、会话日志不变量、**「新行为该挂在哪」映射表**。
- [生态与配置](references/ecosystem.md)：模型 provider 配置（含 pi-ai `compat` 坑）、LLM 适配器实现、
  能力 seam 三角色、dsh 自己的 skill 子系统与本地发现优先级、subagent、沙箱、Python SDK、MCP。

### 脚本

- `scripts/fetch_docs.sh`：把官方文档全站 markdown 拉到本地缓存（默认 `~/.cache/dsh-docs`），
  之后可离线 `--grep` / `--page` 检索。**改插件前先跑一次，比猜 API 可靠。**
- `scripts/dsh_info.sh`：报告 npm 最新/已安装 `@deepseek-ai/dsh` 版本、相关包版本、仓库 HEAD 与最后 push 时间。
- `scripts/new_plugin.sh`：生成最小插件骨架 —— `package.json`（带可发布的 bundle manifest）、
  `cordis.patch.yml`（bundle 层）、`dev.overlay.yml`（可直接用的 `--patch` overlay）和插件源码
  （默认 JS，`--ts` 生成 TypeScript 变体）。
- `scripts/install_global_dsh.sh`：把源码 checkout 的 `dsh` 装成全局命令（默认写到 `~/.local/bin/dsh`），
  自动探测 checkout 路径、校验 node 引擎范围、检查 PATH 与遮蔽。

> **装全局 `dsh` 时千万别 `cd` 进仓库**（也不要用 `pnpm -C <repo> dsh`）：
> dsh 把**调用时所在目录**当作默认 workspace 根，`cd` 会让它一直指向 harness 仓库本身。
> 正确做法是一个 `exec node <repo>/apps/cli/lib/bin.js "$@"` 的 wrapper —— 不动 cwd。
> 注意 wrapper 跑的是**构建产物**：改过 `packages/**` 源码后必须 `pnpm run build` 才生效。

路径相对于本技能目录（`~/.workbuddy/skills/deepseek-harness-skill/`）：

```bash
bash scripts/fetch_docs.sh --update                       # 刷新全站文档缓存
bash scripts/fetch_docs.sh --grep 'defineTool'            # 在文档里搜关键词
bash scripts/fetch_docs.sh --page reference/subsystems/tools.md   # 打印某页原文
bash scripts/dsh_info.sh                                  # 版本与仓库状态
bash scripts/new_plugin.sh ./my-plugin hello-plugin       # 生成插件骨架
bash scripts/install_global_dsh.sh ~/evn/deepseek-harness # 装全局 dsh 命令
```

## 交付前检查

- 用 `scripts/dsh_info.sh` 确认目标环境的 `dsh` 版本，并对照实际源码/文档，**不要按训练记忆写 API**。
- 检查插件是否声明了正确的 `inject`，是否把所有注册都做成了可清理的副作用（`ctx.effect` / `ctx.on`）。
- 检查所有"可调参数"是否都进了 `Config` 且带默认值；schema 是否能让非法配置在加载时就响亮失败。
- 检查工具：`parameters` 能否表达约束、`execute` 是否只返回规范 JSON 值、是否遵守 `exec.signal`、
  `output.render` 与 UI 展示投影是否分离。
- 区分验证边界：import/构造通过 ≠ 服务能起来 ≠ 真实 provider（DeepSeek / 网关）能用 ≠ 容器/沙箱能跑。
  无网络的 smoke test 不能证明外部依赖可用。
