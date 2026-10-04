# 架构与扩展点

**改动 `packages/` 下任何内容之前先读这篇。** 本篇假定你已了解 Cordis
（不了解先读 [cordis-core.md](cordis-core.md) 或文档站的 Cordis 教程）。

官方完整版：`docs/architecture.zh.md`（文档站 `/reference/`）。
下面这版是给 agent 用的浓缩版 + 定位指南。

## 一切皆插件

dsh 的产品每一部分都是插件：模型适配器、工具注册表、会话日志、**agent loop 本身**。
每个都可以从配置替换。**不存在需要打补丁的特权内核** —— 扩展 dsh 的方式是把插件挂到其他插件旁边，
而各项注册都是副作用，会在其插件卸载时撤销。

## Profile 与组合包

运行中的 `dsh` 是一棵**插件树**，由启动时按序叠加的各层组合而成。

- **profile** 是存放在 Harness home 中的具名组装：列出自己叠放的 bundle、存放自己安装的树外插件、
  保存用户自己的 `cordis.patch.yml`。`web`、`headless`、`sdk`、`sdk-minimal`、`acp` 作为模板随发行版交付。
- **组合包（bundle）** 是 Cordis 配置项及其挂载代码的**分发格式**，
  因此它插入的内容始终可被其上各层 patch。

`dsh-base` 是 `web`、`headless`、`sdk`、`acp` profile 的**共享第一层**：
模型适配器、工具、持久化、沙箱与审批策略、设置、凭据、遥测。
`dsh-web-app` 加浏览器应用，`dsh-headless` 加不带服务器的一次性运行器，
`dsh-sdk-app` 加 SDK JSON-RPC 服务器，`dsh-acp-app` 加仅用于自动化的 ACP 服务器。

层序与 patch 语义见 [plugin-development.md](plugin-development.md#加载顺序层优先级)。

查看你机器实际启动的配置树：

```sh
dsh --profile web --dump-config       # 打印出的任何条目都可以由你自己的 patch 替换
dsh --profile web --dump-default-config
dsh --profile web --dump-config-schema  # 打印 entry 与 patch 的 JSON Schema（检查不受信插件前先读安全说明）
```

## 应用启动

受支持的 Node 应用都通过**具名 `dsh` profile** 启动。`dsh --profile <name>` 或 `dsh <name>` 选择。
`plugin` 是管理命令，所以同名 profile 必须用 `--profile plugin` 选择。
TypeScript SDK 解析其同版本 `dsh` 依赖并选择 `sdk`。
自定义插件组合继续由 profile 与有序 patch 文件表达，**而不是另一个可执行文件或内联应用树**。

`scripts/verify-application-entrypoints.ts` 把每个包 bin、可执行源码、根 demo 与根脚本
`start:web` / `dev:web` 归入显式类别，**并拒绝任何绕过 `dsh` 的 Node 应用路径**。

Python SDK 遵循同一应用架构：其运行时 wheel 把普通 `dsh` CLI 打包为
`deepseek-harness-sdk-runtime-<platform>-<arch>`，客户端默认以显式 Harness home 启动 `dsh --profile sdk`。

**桌面应用**：Electron 在签名资源中携带精确匹配的 dsh 生产运行时，拥有保留的
`$DSH_HOME/profiles/desktop`。默认端口 **19387**，profile 配置可覆盖。
CLI 与 Desktop 共享产品数据，但可执行包、启用选择与锁文件保持独立；
**公开 CLI 不能管理 Desktop profile。**

## 核心包与 `ctx` 键

| 包 | 职责 | `ctx` 键 |
|---|---|---|
| `core/session` | 仅追加的 `SessionEvent` 日志和内存存储 | `ctx.sessions` |
| `core/system-prompt` | 提示词片段与工具 schema 的组装 | `ctx.systemPrompt` |
| `core/tools` | 作用域化的工具注册表和带把关的执行流水线 | `ctx.tools` |
| `core/agent` | `Agent` 接口、活跃 agent 注册表和 `agent/*` 事件 | `ctx.agents` |
| `core/agent-loop` | 实现该接口的默认驱动器 | `ctx.agentLoop` |
| `core/scope` | 按 agent 划分作用域的注册原语 | 库，无 ctx 键 |
| `llm/llm` | 消息与流式词汇表，以及适配器 seam | `ctx.llm` |
| `webhook/webhook` | 已认证 delivery 的分派和 Workspace Session 创建 | `ctx.webhookRuntime` |

其他常打交道的服务（完整表见文档站 `/reference/capability-seams`）：

| `ctx` 键 | 角色 | 说明 |
|---|---|---|
| `ctx.fs` | seam | 文件系统提供方（local / sandbox / ssh） |
| `ctx.shell` | seam | Bash 执行器 seam（bash-local / bash-sandbox / pwsh-local） |
| `ctx.subprocess` | seam | 子进程 seam，Bash/PTY/LSP/进程外 subagent 都走它 spawn |
| `ctx.terminals` | seam | 持久 PTY 会话注册表 |
| `ctx.jobs` | seam | 后台任务注册表 |
| `ctx.subagents` | seam | subagent 提供方与延续服务 |
| `ctx.skills` | seam | skill 提供方注册表（见 [ecosystem.md](ecosystem.md)） |
| `ctx.web` | seam | web 搜索/抓取提供方 |
| `ctx.sandbox` | seam | 进程沙箱 seam |
| `ctx.approval` | seam | 一次性权限决策（`approval/request` waterfall；**没有回答方时以 `unavailable` 关闭失败**） |
| `ctx.permissionPresets` | core | 用户预设表（`workspace-write` / `danger-full-access`），把沙箱模式与审批策略组合起来 |
| `ctx.commands` | core | 面向人的命令注册表（**无需模型轮次即可分派**） |
| `ctx.systemPrompt` | core | 提示词片段 + 工具 schema 收集（每步） |
| `ctx.sessionProjections` | core | 事件折叠为类型化状态，供 host 消费方读取 |
| `ctx.sessionPersistence` | seam | 会话持久化（JSONL 后端） |
| `ctx.compaction` | seam | 上下文压缩 |
| `ctx.planMode` | core | Plan 协作状态、`/plan` 入口、`exit_plan_mode` 出口 |
| `ctx.goals` | core | 同会话目标状态 |
| `ctx.schedule` | core | 定时消息（cron） |
| `ctx.workflowEngine` | seam | 工作流脚本引擎 |
| `ctx.agentTeams` | core | **实验性** Agent Teams（持久 roster、任务板、mailbox） |

**服务名、公开方法和源码位置由仓库自动生成到各服务的子系统页面**
（`/reference/subsystems/*`，含 `cordis-surface` 区块）。
**开发插件时以这些生成区块和服务的 TypeScript 接口为准，不要维护另一份静态清单。**

## 三个事件域

**事件就是扩展点，而选对事件域是大多数改动的第一个决定。**

- **会话事件（`session/event`）**：追加到日志并广播的**持久事实**。
  当某个事实必须在重新加载后仍然存在时用它。
  持久类型包括 `turn/*`、`step/*`、`system/message`、`user/message`、`assistant/message`、
  `assistant/attempt`、`tool/call`、`tool/result`、`compaction/*`。
- **Agent 事件（`agent/*`）**：携带活跃 `Agent` —— inbox、步骤、状态、请求、验证、续跑。
  要**观察或拦截进行中的工作**时用它。
- **能力事件（`fs/*`、`tools/*`、`telemetry/*`）**：**无需导入循环**即可向某个 seam 附加策略和适配器。

命名遵循 `namespace/action`：例如 `agent/pre-step`、`agent/request`、`agent/request-error`、
`tools/result`、`session/event`。

> **注意区分**：`turn/*`、`step/*`、`tool/call`、`tool/result`、`compaction/*` 是**持久化的会话事件类型**，
> **不是同名 Cordis 事件**。需要观察它们时，监听 `session/event` 并检查 `event.type`。

AgentLoop 在启动已排队工作前，等待**串行** `agent/created` 初始化。
初始化失败会回滚创建；teardown 顺序由 agent-loop 定义。

## 轮次流程（turn / step）

- 一个**步骤（step）** = 一次模型请求 + 它调用的工具。
- 一个**轮次（turn）** 包含零个或多个步骤：在领取首条输入之前打开，在不再欠下任何工作时关闭。

```text
turn/start
  claim next-step input plus one queued message
  assemble prompt sections + tool schemas; project runtime context
  -> agent/pre-step                   reject | enter(messages, startsRequestSeries?)
     reject, or a first enter rewritten empty -> close the turn with no step
     step/start
     agent/request -> prepareCall (cancellation commits neither system nor users)
     reconcile system/message using the prepared call capability
     append entered messages as user/message; log request/header and request/context as needed
     derive and freeze model history from the log
     stream the bound prepared call -> llm/stream -> agent/assistant-stream start
       agent/assistant-stream chunk*
       assistant/message | assistant/attempt -> agent/assistant-stream end
     tool/call* -> tools/pre-execute -> tools/execute -> tools/post-execute -> tool/result*
     step/end
     tools owe another request, or next-step input arrived -> claim -> next step
  -> agent/turn-stopping
turn/end
```

**分发模式**（写监听器前必须知道）：

- `agent/pre-step`、`agent/request`、`llm/stream` 和三个 `tools/*` 事件是 **waterfall**，
  其监听器**必须调用 `next()`** 才能委托下游。
- `agent/turn-stopping` 是 **serial** 事件，**没有 `next()`**。
- `agent/assistant-stream` 发布进程本地 start、瞬态 chunk 与 end frame
  （**live event**，不是持久事实）。

关键语义：

- **`agent/pre-step` 决定接纳的输入。** 监听器可以改写或拒绝已领取消息；
  首次领取被拒绝或为空时，关闭**不含步骤**的持久轮次。
- enter 决策可设置 `startsRequestSeries`；包装监听器通过 `{ ...decision, messages }` 保留该声明。
- **在任一异步阶段取消，都不会提交系统提示词与已接纳用户消息。**
- 提示词准入依据**已准备调用的能力**，而非先前的 `request/context`。
- 重试**不重复**组装或 `agent/pre-step`。
- **提示词仅通过 `system/message` 历史传递**：空渲染文本会清除所有生效的系统节点，
  模型不再看到旧提示词。

**输入通过同一个 inbox 到达驱动器**；注入的上下文等待一条唤醒消息。
AgentLoop 的持久 `inbox` 投影使待处理输入在没有活跃 Agent 时仍可读取。

## 会话日志

会话日志是**模型所见上下文的来源**；`deriveMessages()` 从中投影出模型历史。

- 每个 `assistant/message` 都嵌入产生其组装内容的**精确紧凑带时间 stream**。
- `assistant/attempt` 保留已到达 settlement 的失败、重试、取消与 stream error attempt，
  **且不添加模型历史**。
- fork、恢复、transcript、遥测与持久化都从这些**持久 settlement** 派生；
  实时 UI 增量则来自 `agent/assistant-stream`。
- 如果进程在 settlement 前硬中断，**不会留下持久 attempt stream**。

> **运行时不变量：模型可见即已记录。**
> 运行时会检查模型请求是否可以**从日志重建**。新增模型可见输入**需要会话事件**。
> 修改现有消息内容的插件注册**纯消息投影**（`dsh-session-projection` 的 `ctx.sessionProjections`），
> 独立读取器显式传入相同的处理器。

**投影 seam**：`ctx.sessionProjections` 的已注册单元**增量折叠已提交事件**，
host 消费方通过 `stateOf()` 读取单个类型化状态，载体通过 `snapshot()` 批量取得裁剪后的客户端视图。
host 读取方要么在激活时要求该服务，要么在注册表或必需 key 缺席时**明确失败**。
贡献方可以保留 `ctx.inject(['sessionProjections'], ...)` 注册，
**但不能为缺失的 host 值静默提供默认值**。

**JSONL 持久化**：v0 用 `session.jsonl[.zstd]`，v1 及之后用 `session.vN.jsonl[.zstd]`；
**已提交 generation 路径绝不重命名、替换或删除**。每个相邻迁移包只负责一个 `vN -> vN+1` 步骤。

## 能力 seam

一个 **seam** 是一项可替换能力，含三种角色：

- **Service Definition** —— 声明接口（拥有 Request/Result 类型）
- **Service Provider** —— 实现它
- **Consumer** —— 使用它（通常是面向模型的工具）

一个包可以合并承担多个角色，但**单一角色本身不是 seam**；添加一项能力意味着把三者一并设计。

seam 正是"替换一个提供方就能改变整个产品"的原因：文件系统与进程提供方共享同一个执行世界，
把它们指向远程沙箱，也就把 **Bash、PTY 和 LSP 一并搬了过去**，无需提供方专用 fork。

详见 `/reference/capability-seams` 与 [ecosystem.md](ecosystem.md)。

## 新行为的归属位置（最重要的一张表）

新行为只挂到**已有文档记录的扩展点**上：

| 目标 | 机制 |
|---|---|
| 添加模型提供方 | 在 `ctx.llm` 上注册其适配器 |
| 添加面向模型的能力 | 在 `ctx.tools` 上注册；schema 自动加入提示词组装 |
| 让某个会话拥有不同能力集合 | 组装 agent preset；其中的服务行需要 `isolate` realm |
| 添加 shell 执行 | 注册 `ctx.shell` 后端；本地后端通过 `ctx.subprocess` spawn 进程 |
| 添加持久化终端执行 | 注册 `ctx.terminals` 后端和 `dsh-tool-terminal` |
| 添加用户命令 | 在 `ctx.commands` 上注册（无需模型轮次） |
| 管理后台任务 | 在 `ctx.jobs` 上注册；`job_*` 工具读取或停止任务 |
| 从外部 webhook 启动 Session | 在 `ctx.webhookRuntime` 上注册可信规则，并挂载提供方适配器 |
| 添加文件系统访问或策略 | 注册 `ctx.fs` 提供方，或监听 `fs/*` 事件 |
| 限制所启动的进程 | 使用 `ctx.sandbox` 后端；消费方在启动进程前包装 argv |
| 拦截请求、工具或轮次 | 用相应的 `agent/*` 或 `tools/*` 事件；`agent/turn-stopping` 会停止轮次 |
| 添加模型可见上下文 | 调用 `agent.inject()`；它会落到下一次获准的请求中 |
| 添加 UI 或编辑器集成 | 驱动 `ctx.agents` 并从 `session/event` 渲染 |
| 添加 Web Client Chat 节点 | 注册 `ConversationNodeDefinition` + keyed renderer |
| 添加持久会话状态 | 扩展 `SessionEventMap`；从日志渲染和回放 |
| 生成会话标题 | 注册唯一的 `ctx.sessionTitle` 提供方 |
| 管理同会话目标 | 使用 `ctx.goals`；通过 `agent/*` 续跑 |
| 在轮次边界 fork 会话 | `ctx.agents.create({ sessionId, seed, meta: { parentSession, seedLength } })` —— 只有经 agent-loop 发布的会话才会持久化 |
| 在新后端存储会话 | 基于共享的句柄脚手架实现 `SessionPersistence`（`create` / `open` / `stat` / `list` / `export`） |
| 将注册项限定到单个 agent | 使用该 agent 的 `agent.ctx` |

`system-prompt/assemble` 是一个**专家协作式的整体装配变换**：其返回的装配结果**具有权威性**，
因此监听器作者有责任保留活跃的 PTC mode 和结构化输出协议的贡献。
需要在展示、查找和执行之间保持对齐的工具过滤，优先用 `ctx.tools.restrict()`。

### 产品功能 → 插件机制（节选）

| 产品功能 | 插件机制 |
|---|---|
| 钩子系统（用户级 + 项目级） | `agent/created`、`agent/pre-step`、`agent/request`、`tools/pre-execute`、`tools/post-execute`、`agent/turn-stopping` 上的监听器；waterfall 返回类型化决策；`dsh-hooks-claude-code` / `dsh-hooks-codex` 把钩子配置文件映射到这些扩展点 |
| `/loop` | 在 `turn/end` 会话事件上 `followup()` 下一次迭代；或强制继续 |
| 动态工作流 | `ctx.workflowEngine` + PTC 工作流引擎 + `workflow` 工具 |
| 排队消息 + steering | 核心 `Agent.followup()` / `Agent.steer()` |
| 上下文压缩 | `ctx.compaction` seam + `dsh-compaction-basic`；自动压力检查在串行 `agent/pre-step`，溢出恢复在 `agent/request-error` |
| 系统提示词可配置性 | `ctx.systemPrompt.section()`，支持排序与作用域局部覆盖 |
| AGENTS.md（根目录） | 一个读取该文件的 section 提供方 |
| AGENTS.md（子目录，按需触发） | 从 watcher / 工具结果监听器调用 `agent.inject()` |
| 内置工具 | `ctx.tools.register()`；`dsh-tool-*` 系列（bash、fs、web、subagent、todo）是已交付示例 |
| ToolSearch / 渐进式披露 | 可见集变化时替换一个作用域化的 `ctx.tools.restrict()` 注册 |
| 工具截止时间 / 重试 / 指标 | 用 `tools/execute` 包裹核心分发 |
| Plan mode | `@deepseek-ai/dsh-plan-mode`：落日志的 `plan/mode` 状态、`plan:policy` 引导段、`/plan [message]`、`/plan off`、经用户评审的 `exit_plan_mode` |
| subagent 委派 | `ctx.subagents` 提供方注册表（spawn-in-process / fork-in-process / acp / codex / claude-code / dsh-sdk）+ `dsh-tool-subagent` |
| MCP | 每个服务器一个插件：发现工具 → `ctx.tools.register()` |
| skill（技能） | section + 工具注册；调用时通过 `inject()` 注入 skill 内容 |
| 记忆 | section 提供方 + 工具 |
| 定时任务（cron） | 插件注册面向模型的调度工具；定时器触发 → 空闲时 `followup(…, {source: {kind: 'plugin', plugin: 'schedule'}})` / 忙碌时 `inject()` 通知 |
| UI | 监听 `agent/assistant-stream` 的实时 chunk + `session/event` 的持久 settlement / 边界 / 工具活动；输入 → `followup()` |
| 遥测 / 可回放 trace | `session/event` → JSONL；回放 = `sessions.create(id, { seed })` |
| 模型适配器 | 通过 `registerAdapter` 注册 `LlmAdapter` 子类 |
| 插件热重载 | 每个注册都是一个 `ctx.effect` → 随仓库提供的 HMR 直接生效 |

## 仓库结构与构建

```text
deepseek-harness/
├── packages/                  # 全部是 @deepseek-ai/dsh-* 包，按 group 分区
│   ├── core/ llm/ shell/ subprocess/ fs/ terminal/ web/ job/ ...
│   ├── skill/ subagent/ preset/ plan/ goal/ schedule/ compaction/ ...
│   ├── bundle/                # base / web-app / headless / sdk-app / sdk-minimal / acp-app
│   ├── boot/                  # app-boot、plugin-manager、config-editor、hmr、cmdline
│   ├── client/ host/ api/     # Web Client、HTTP 服务器、Remote 网关
│   └── experimental/          # 实验包（不稳定，勿在生产依赖）
├── apps/cli/                  # dsh CLI 启动器（唯一受支持的 Node 应用入口）
├── apps/desktop/              # Electron 桌面应用
├── apps/web/                  # Web 前端
├── vendor/                    # cordis / cosmokit / schemastery 的 vendor 源码
├── benchmarks/ scripts/ tests/
└── docs/                      # 文档源（含 .zh.md 双语配对）
```

构建按生成依赖排序：

```sh
tsc -b tsconfig.host.json
tsdown --env.DSH_BUILD_FACE host
pnpm --filter @deepseek-ai/dsh-desktop run bundle
tsc -b tsconfig.client.json
tsdown --env.DSH_BUILD_FACE client
pnpm run build:web
```

- **Host / Client 是两个隔离的 TS aggregate**（`tsconfig.host.json` / `tsconfig.client.json`）。
  两侧在**相同键**下用**不同服务**对 Cordis `Context` 做声明合并；
  单一 `ts.Program` 同时看到两份合并会报冲突。
- 由此三条纪律：`tsconfig.base.json` **永不**加 `include` / `files`；
  构造全仓 `ts.Program` 的脚本显式以 host 或 client 为种子，**根 solution 永不作为种子**；
  新包只登记进一个 aggregate。

## 验证边界（别骗自己）

- `pnpm run typecheck` 成功退出 = 搭建完成。
- 静态分析和测试通过 `tsconfig.base.json` 的 `paths` 把 workspace import 解析到 `src`，
  **必须在干净树上通过**。
- 消费构建产物 `lib/` 的门禁需要先 `pnpm run build`（新 worktree 在构建前没有打包的 JS 和声明文件）。
- `pnpm run hygiene` 含 `publint` 和 `verify-node-next-types`。
- 环境变量：真实 DeepSeek 适配器从环境变量或仓库根被 gitignore 的 `.env` 读取
  `DEEPSEEK_API_KEY`、可选 `DEEPSEEK_BASE_URL`。
- **import / 构造通过 ≠ 服务能起来 ≠ 真实 provider 能用 ≠ 容器/沙箱能跑。**

## 相关文档

- `docs/architecture.zh.md` — 完整版架构文档
- `docs/development.zh.md` — 搭建、项目布局、日常命令
- `docs/testing.zh.md` — 测试策略（交付变更必须遵守）
- `AGENTS.md` — 面向 agent 的仓库约定
- 文档站 `/reference/`（架构、能力 seam、Agent 生命周期、Tool 执行、API Gateway）
  与 `/reference/subsystems/*`（每个子系统的生成式参考）
