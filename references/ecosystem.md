# 生态：模型、能力与集成

本篇覆盖日常集成会用到的部分：模型 provider 配置、自己写 LLM 适配器、能力 seam 三角色的落地、
dsh 自己的 **skill 子系统**、subagent、沙箱、Python SDK、MCP。

## 模型配置

变更在**下一次请求时生效，不需要重启服务器**。

### 界面路径

- **DeepSeek**：设置 → 模型 → DeepSeek 卡片 → 填 API 密钥保存。
  密钥**只写**，保存在 `$DSH_HOME/.credentials.yaml`，settings 只保留凭据引用。
- **第三方提供商**：添加模型提供商 → 选 dsh 自带目录（列表显示 provider id，
  如 `anthropic`、`openai`、Kimi 对应 `moonshotai`、GLM 对应 `zai`）→ 填密钥。
  **OAuth 登录的提供商（如 Codex）暂不支持。**
- **自定义模型 API**：适用于中转站、公司网关、自建服务器。填 Provider ID（小写）、基础 URL、
  **API 协议**、凭据和至少一个模型。

**API 协议**只提供三种，在 profile 的 `cordis.patch.yml` 中分别存为
`openai-completions`、`openai-responses`、`anthropic-messages`。
**一个提供商只用一种协议**；网关同时提供两种就建两个提供商。

> **Provider ID 是永久的** —— 请求、已保存会话、模型默认值和凭据引用都会用它。
> 要重命名就新增一个再删旧的。显示名称、基础 URL、协议、凭据和模型可改。

**探测模型**（模型目录 → 获取可用模型）只是便利手段而非保证：
探测读的是常见网关公开的列表格式，不是每个端点都这么答。
失败或列表为空时**手动添加模型 ID 即可，效果完全一样**。

### 配置文件路径

```text
$DSH_HOME/profiles/<profile>/cordis.patch.yml    # 用 dsh web 启动时 <profile> 就是 web
$DSH_HOME/cordis.patch.yml                        # home 级，各 profile 共享
```

推理等级、请求兼容性开关、请求头、超时和重试策略都在这里（界面只有一部分）。
**适器会在下一次请求时重新读取，无需重启。** 浏览器与服务器同机时，
设置页顶部有"打开配置文件"。

### `dsh-llm-pi-ai` 配置要点

```yaml
- id: llm-pi-ai
  config:
    providers:
      my-gateway:
        apiKeyEnv: GATEWAY_API_KEY
        api: openai-completions
        baseURL: https://gateway.example/v1
        compat:
          supportsDeveloperRole: false
          maxTokensField: max_tokens
        reasoning: high                 # 会话未选等级时采用的默认等级
        defaultInput: [text, image]     # 路由级模态回退（默认 [text]）
        models:
          - id: legacy-chat
          - id: vision-preview
            input: [text, image]
          - id: deepseek-v4-pro
            compat:
              thinkingFormat: deepseek  # 让 off 发送 thinking: {type: disabled}
            reasoningEfforts:
              off:                      # 留空 = 什么都不发送
              high: high
              max: max                  # 值是在协议上以 reasoning_effort 发送的写法
```

关键规则：

- **`input` 的语义**：显式非空选择优先；省略或为空 → 先继承已安装目录的输入类型，
  再回退到路由的 `defaultInput`（默认 `[text]`）。**它是回退值而不是覆盖值。**
  内置提供商没有显式 `models` 列表时，写在 `modelOverrides` 下（以模型 id 为键）。
- **推理等级**：手动录入的模型**不声明任何等级**，所以菜单里不会出现该项。
  要出现就用 `reasoningEfforts` 声明。**只有 `off` 可以留空**（对多数端点，不思考就是不传该参数）；
  给 `off` 一个值则会把该值作为 `reasoning_effort` 发送。
  对"不明确关闭就会思考"的模型（如 OpenAI 兼容网关后面的 DeepSeek V4）需要
  `compat.thinkingFormat: deepseek`。
- **`compat` 是断言而不是检查**：写下一个网关其实不需要的开关，只是发出一个不同的请求。
  凡是写下的开关**都要给值** —— 冒号后留空会被拒绝而不是忽略
  （空值会抹掉 catalog 已知的信息却没给替代）。每个开关归属于声明它的那些协议。
- `DeepSeek` 自身路由不需要上面任何 compat 配置：其模型已提供 `off`、`low`、`high`、`max`，
  用 `llm-deepseek.reasoningEffort` 设默认值。
- DeepSeek 把省略的 `inputModalities` 视为纯文本，并**拒绝空列表**；
  取消图片还会移除该模型的 `imagePixelBudget` 和 `imageMaxBytes`。

### 常见排错

| 报错 / 症状 | 处理 |
|---|---|
| `MISSING_CREDENTIAL` | 通过模型页存密钥，或提供被引用的环境变量 |
| `UNKNOWN_MODEL` | 选择已配置的模型，或向自定义提供商添加缺失模型 |
| 获取可用模型返回 401 | 检查密钥（发现会调 OpenAI 兼容的 `GET /models`）；不提供该端点的服务手动输入 |
| 探测提示既无 `data` 数组也无 `models` 对象 | 端点列表格式不在读取范围内，手动输入 |
| 密钥与地址都对，网关仍拒绝每个请求 | 先在路由上设 `compat.supportsDeveloperRole: false` + `compat.maxTokensField: max_tokens` |
| 只有推理模型失败 | pi-ai 把系统提示词以 `developer` 角色发出，网关拒绝 → `compat.supportsDeveloperRole: false` |
| 手动模型没有推理等级菜单 | 该模型没声明等级，加 `reasoningEfforts` |
| `off` 无法让 DeepSeek 停止思考 | 留空的 `off` 不发送推理字段；设 `compat.thinkingFormat: deepseek` |
| 图片在发送前被拒绝 | 该模型未声明图片模态 → 加 `input: [text, image]` |
| 提供商拒绝了带图片的请求 | 声明了端点实际没有的能力。从授予它的列表移除 `image`，**然后开新会话**（附加图片会留在会话日志里，会话不离开它就会重复该请求） |

## 自己写 LLM 适配器

参考实现：`packages/llm/llm-deepseek`（直接 HTTP，SSE 由 `eventsource-parser` 分帧）、
`packages/llm/llm-pi-ai`（封装 LLM 库）。
**先读 `packages/llm/llm/src/types.ts` 的 `StreamChunk` 文档** —— 两个适配器都验证过的协议约定在那里。

```ts
class MyAdapter extends LlmAdapter {
  async * stream(options: GenerateOptions): AsyncIterable<StreamChunk> { /* … */ }
}

export const name = 'llm-myprovider'
export const inject = ['llm']
export const Config = Schema.object({ apiKey: Schema.string(), /* … */ })

export function apply(ctx: Context, config: Config) {
  ctx.llm.registerAdapter(['my-provider'], new MyAdapter(/* … */))
}
```

注册基于副作用，可安全支持 HMR。**每个提供方路由仅对应一个适配器，重复注册会抛异常；
多路由注册要么全部成功，要么全部失败。** `options.provider` 选适配器，`options.model` 是提供方模型 ID，
因此动态模型目录适配器无需重新配置生命周期即可提供新模型。

**密钥用 Cordis 原生方式管理**：Schemastery Config 带环境变量回退，
通过 `cordis.yml` 的 `!!js process.env.MY_KEY` 注入。**切勿在代码中读取自行约定的密钥文件。**

### 协议义务（两个实现共同验证的约定）

- 在 `finish` **之前**发出 `usage`；`finish` 之后**不再发出任何内容**。
  稳健做法：缓冲 finish/usage 直到提供方的流结束标记，再统一 flush
  （可处理提供方在末尾发送仅含 usage 的分片的情况）。
- 工具调用的 `arguments` **全程为原始 JSON 字符串**；流式片段以 `argumentsDelta` 发送。
  如果你的提供方返回已解析对象，请在 `block-end` 时**重新 stringify**。
- 按**首次出现的流顺序**分配块 `index`；同一块的每次 delta 复用该 index。
- **错误有且仅有两条合法路径**：从 `stream()` **抛出**（传输与协议故障 —— 用带稳定 code 的 `LlmError`），
  或以 `finish {kind: 'error' | 'aborted'}` 结束流（提供方带内故障）。
  消费方两者都处理；按故障类别选路径并加以文档化。
- 遵守 `options.signal`（传给 fetch 或你的 SDK）。
- 提供方无法支持的 `GenerateOptions` 字段 → 抛 `LlmError(..., 'UNSUPPORTED_OPTION')`，**不要静默丢弃**。
- 后续调用需要响应 ID / 签名 / 原生元数据时，把其**最小无损 JSON 投影**作为 `finish.replayState` 发出，
  重建历史时验证该状态。**状态缺失时，切勿仅根据提供方/模型名称推断原生回放。**
- 提供方特有的思考模式开关仍放在适配器的 Config 中。
- 模型元数据用一处提供方无关的能力 seam：实现 `resolveModel()`，
  返回提供方/模型身份以及可选的 `context` 和 `reasoning` 字段；
  仅当存在配置指定的默认值时才声明 `defaultEffort`；遵守解析模型时传入的可选 `AbortSignal`。

**实现结构**：让 wire format 类型、请求序列化、传输解析、分片转换和适配器类**各自承担独立职责**。
`llm-deepseek` 是参考布局。**推理强度是由适配器映射到提供方请求的有序不透明 ID** ——
保留适配器给出的权威可选列表（包括适配器在支持时定义的 `off`），
**不得暴露最终协议值的具体拼写，也不得自动调整不支持的值。**

## 能力 seam：三角色落地

概念见 [architecture.md](architecture.md#能力-seam)。当一项能力足够通用、需要支持可替换提供方时
（例如 Bash 执行），把它拆成三个角色。

以 Bash 为例：

- **Service Definition**（`dsh-shell`）：定义 Cordis 服务以及 Bash 请求和结果类型
- **Service Provider**（`dsh-bash-local`）：在本地机器上执行命令
- **Consumer**（`dsh-tool-bash`）：把该能力公开为模型可调用的工具

```text
┌─────────────┐     ┌──────────────────┐     ┌──────────────┐
│  dsh-shell   │────▶│  dsh-bash-local  │     │ dsh-tool-bash│
│(definition) │     │    (provider)     │     │(consumer/tool)│
└─────────────┘     └──────────────────┘     └──────────────┘
       ▲                                            │
       └────────────────────────────────────────────┘
                    inject: ['shell']
```

### 三步实现

**① Service Definition**

```ts
// packages/my-cap/my-cap/src/index.ts
import { Service, type Context } from '@deepseek-ai/cordis'

declare module '@deepseek-ai/cordis' {
  interface Context {
    myCap: MyCapService
  }
}

export abstract class MyCapService extends Service {
  constructor(ctx: Context) {
    super(ctx, 'myCap')
  }

  /** Execute the capability. */
  abstract execute(request: MyCapRequest): Promise<MyCapResult>
}

export interface MyCapRequest { input: string }
export interface MyCapResult { output: string }
```

**② Service Provider**

```ts
// packages/my-cap/my-cap-local/src/index.ts
import type { Context } from '@deepseek-ai/cordis'
import { MyCapService, type MyCapRequest, type MyCapResult } from '@deepseek-ai/dsh-my-cap'

class MyCapLocal extends MyCapService {
  async execute(request: MyCapRequest): Promise<MyCapResult> {
    return { output: request.input.toUpperCase() }
  }
}

export const name = 'my-cap-local'
export function apply(ctx: Context) {
  ctx.plugin(MyCapLocal)
}
```

**③ Consumer（工具）**

```ts
// packages/my-cap/tool-my-cap/src/index.ts
import type { Context } from '@deepseek-ai/cordis'
import { defineTool } from '@deepseek-ai/dsh-tools'

export const name = 'tool-my-cap'
export const inject = ['tools', 'myCap']

export function apply(ctx: Context) {
  ctx.tools.register(defineTool({
    name: 'my_cap',
    description: 'Execute my capability.',
    parameters: { input: { type: 'string', required: true } },
    output: {
      schema: { type: 'string' },
      render: (_args, value) => [{ type: 'text', text: value }],
    },
    async execute(args) {
      const result = await ctx.myCap.execute({ input: args.input })
      return result.output
    },
  }))
}
```

**在 `cordis.yml` 中组合**：

```yaml
- name: '@deepseek-ai/dsh-my-cap-local'
- name: '@deepseek-ai/dsh-tool-my-cap'
```

### 设计要点

- **不要预防性拆分**：只有角色需要独立演进时才用不同包。**简单的工具插件无需拆分。**
- **Service Definition 拥有 Request/Result 类型**；Provider 和 Consumer 只依赖 Definition 包。
- **依赖解耦**：Provider 依赖 Definition，Consumer 依赖 Definition，
  **Provider 与 Consumer 互不依赖**。
- **显式优于隐式**：实现应通过显式的 `resolve(request): Spec` 步骤处理默认值，
  而不是在 `run()` 中隐藏 `?? default`。
- 替换提供方时，只需在 `cordis.yml` 换一行；Definition 与工具都不变。

## dsh 自己的 skill 子系统

dsh 内置了 skill 机制（`packages/skill/*`），和你在 WorkBuddy 里用的 skill 概念类似但**是 dsh 自己的实现**。

- Service Definition：`dsh-skill`（`ctx.skills`）
- 本地 Provider：`dsh-skill-filesystem`
- 可选随包 Provider：`dsh-skill-badge`、`dsh-skill-office`、`dsh-sandbox-windows-acl`
- Consumer：`dsh-tool-skill`（拥有初始目录与替换目录，以及面向模型的 `skill` 工具）

**skill 是可选的指令，不是会话事件**，因此其词汇定义在 `/reference/subsystems/skills` 而不是 core 页面。

### 本地发现优先级

随附的本地 provider 按 rank 顺序扫描（**rank 数字小的赢**）：

| Rank | Source | Root |
|---|---|---|
| 100 | `project-dsh` | `<projectRoot>/.dsh/skills` |
| 200 | `project-agents` | `<projectRoot>/.agents/skills` |
| 300 | `custom` | `Config.customSkillDirs` |
| 400 | `user-dsh` | `<dshHome>/skills` |
| 500 | `user-agents` | `<agentsHome>/skills` |
| 600 | `bundled` | 配置了 `Config.bundledSkillDir` 时使用 |

- 项目根目录 = 包含 `.git` 的**最近祖先目录**；找不到时用当前 cwd。
  `ctx.fs` 可用时通过文件系统服务探测 `.git`，使远程/沙箱工作区不会回退到宿主文件系统边界。
- 用户 DSH 根目录会**跳过其 `.system` 子目录**。
- 本地 provider **不合成内置系统 skill**；部署方通过已配置的 bundled 根目录或专用 provider 提供随包 skill。
- Chokidar 监视现有根目录中直属 bundle / 平铺条目的增删，以及直属 skill 条目的变更；
  **bundle 下的资源文件变更不属于目录变更**。项目作用域 watcher 使用按配置设限的 LRU。

### SKILL.md 格式

- **skill 名称必须是 kebab-case**：`^[a-z0-9]+(?:-[a-z0-9]+)*$`
- 本地 provider 接受两种形态：
  - **目录包** `<name>/SKILL.md`
  - **扁平 Markdown 文件** `<name>.md`
- **嵌套递归的 `**/SKILL.md` 发现不受支持。**
- Frontmatter 键（kebab-case，名称完全匹配）：`disable-model-invocation`、`user-invocable`。
  **省略的字段默认 `true`。** 本地 provider 会把它们规范化为正向布尔：
  - 仅模型可调用 → `{ modelInvocable: true, userInvocable: false }`
  - 仅用户可调用 → `{ modelInvocable: false, userInvocable: true }`
  - 两者都 `false` → 只能由受信的 `ctx.skills.get()` 调用方获取（**不在任何目录里出现**）
- **模型会话目录只使用模型可调用 skill 的 `name` 和 `description`**，
  **从不使用正文或绝对文件路径**。
- 注册表是**宿主 + 按 scope 分层**的（与工具注册表同形，基于 `dsh-scope`）：
  注册落入调用方上下文 scope 对应的层（宿主行与 repository 插件落入全局层，
  agent preset 常驻组合挂载的插件落入该 preset 的层）；**provider 名称在每层内唯一，而非进程级唯一**。
- 读取时把全局层与观察 scope 的链合并：**最近层的条目直接赢得重名 skill**；
  单层内依次按 rank → provider 顺序 → 本地顺序裁决重名；摘要按名称排序。
- 显式的不完整观测会提供可用候选项但**不会使结果变得可缓存**；**格式错误的候选项快速失败**。
- provider 和运行时变更发出**不带过滤条件的** `skills/change` 失效事件（不携带 diff），
  消费方需用自身查找选项重新获取 `snapshot()`。
- 运行时注册用 `ctx.skills.register()`；返回的 disposer 移除该贡献并使发现缓存失效。

## Subagent

`ctx.subagents` 是提供方注册表，实现可换：

- `dsh-subagent-spawn-in-process` / `dsh-subagent-fork-in-process`
- `dsh-subagent-acp` / `dsh-subagent-codex` / `dsh-subagent-claude-code` / `dsh-subagent-dsh-sdk`

`dsh-tool-subagent` 把**一个已配置的提供方**暴露给模型；`dsh-tool-subagent-control` 传递后续消息；
`dsh-tool-ralph` 要求一条全新的结构化输出路由。
服务还负责**可选的、基于 Activation 的延续编排**。

> **实验性 Agent Teams**：`ctx.agentTeams` 上公开发布、**显式启用**的协作 seam，
> 在可继续 subagent 之上提供**持久 roster、任务板和 mailbox**
> （`dsh-experimental-agent-team` + `dsh-experimental-tool-agent-team`）。

## 沙箱

- `ctx.sandbox` 是进程沙箱 seam；消费方**交出即将执行 spawn 的确切 argv**，
  后端按每次调用的策略包装该 argv，并报告强制执行情况。
- 与配套子进程提供方共享执行环境的后端（`sandbox-local`、`sandbox-ssh`）才有效 ——
  因为**文件系统与进程提供方共享同一个执行世界**，
  把它们指向远程沙箱也就把 Bash、PTY、LSP 一并搬了过去。
- `ctx.sandboxPolicy` 统一保存部署默认模式和工作区根目录，
  只有沙箱执行器和提供方读取该服务（工具层使用它同时导出的纯 `sandbox/mode` 折叠区）。
  **bash 与 fs 两类强制执行组件都读同一服务，因此不会限制到不同根目录。**
- Linux 上是 `landlock` / `sandbox-exec` 之类机制，通过 `dsh-bash-sandbox` 使用；
  能力级别的拒绝用 `tools/pre-execute`。
- **`LocalWorkspace` 之类"本地"执行不是安全边界。**

## Python SDK

Python SDK 遵循与 Node 相同的应用架构：

- 运行时 wheel 把普通 `dsh` CLI 打包为 `deepseek-harness-sdk-runtime-<platform>-<arch>`。
- 客户端默认以**显式 Harness home** 启动 `dsh --profile sdk`；
  极简示例选择随附的 `sdk-minimal` profile。
- Python 暴露 **profile 选择与有序 patch 文件**，而**不是完整 Cordis 树**；
  持久外部插件通过 `dsh plugin` 安装。
- 文档：`/guide/python-sdk`。

## MCP

**每个服务器一个插件**：发现工具 → `ctx.tools.register()`。

用提示词配置（创造模式，Web profile）：

> 将 `<endpoint>` 处的 MCP 服务器配置到当前 profile，命名为 `demo`。
> 立即启用它的工具，然后调用它的 ping 工具并告诉我结果。

agent 会写一个**纯配置组合包**，在 patch 中插入 `@deepseek-ai/dsh-mcp-client`，
再通过 `plugin_manager install_bundle` 安装。**启用 HMR 时，工具会出现在同一个运行中的会话里。**
同时检查管理结果（`application: applied`）和成功的工具调用。

- 返回 `restart-required` 的已保存条目**尚未激活**；失败条目需要修复配置。
- **修改配置前先读取组合包 patch。** 用 Plugin Manager 停用条目或移除组合包。
- 参考：`packages/mcp/mcp-client/README.zh.md`、`/guide/mcp-memory`。

## 扩展插件形态（更多模式）

`/reference/cookbook/extension-cookbook` 给出代码片段：
工具插件、**钩子插件（权限门禁）**、**UI 插件**（组合持久 `session/event` 与瞬态
`agent/assistant-stream` frame，通过 `agent.followup()` / `agent.steer()` 驱动输入）、
**外部协议驱动**（把协议对端接入 `ctx.agents`；`packages/acp/acp` 是仅面向自动化的完整示例）。

> 注意：该手册里的代码片段**省略了 import 和辅助实现，无法直接复制运行**。
