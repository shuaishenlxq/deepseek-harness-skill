# 工具开发与 UI 展示

面向模型的工具必须满足哪些约定，以官方 `/reference/cookbook/adding-a-tool` 为准。
生产级三包示例是 `packages/shell/tool-bash`。

## 最小形态

```ts
import { readFile } from 'node:fs/promises'
import type { Context } from '@deepseek-ai/cordis'
import { defineTool } from '@deepseek-ai/dsh-tools'

export const name = 'my-tool'
export const inject = ['tools']

export function apply(ctx: Context) {
  ctx.tools.register(defineTool({
    name: 'read_file',
    description: 'Read a file from disk.',          // 模型看到的就是这句
    parameters: {
      path: { type: 'string', required: true, description: 'Absolute path' },
      limit: { type: 'number' },                     // 默认可选
    },
    output: {
      schema: { type: 'string' },
      render: (_args, value) => [{ type: 'text', text: value }],
    },
    async execute(args, exec) {
      // args 已由 schema 推导出类型：{ path: string; limit?: number }
      // exec 携带不可变身份 + token；signal 是操作字段
      return readFile(args.path, { encoding: 'utf8', signal: exec.signal })
    },
  }))
}
```

**注册基于副作用**：dispose 插件 fiber 即注销该工具。
**schema 会自动流入系统提示词的组装过程。**

`ctx.tools.register()` 也直接接受**原始 JSON Schema** `ToolDefinition`（MCP 来源的工具就是这样到达的），
但直接注册的原始 JSON Schema 工具**自行负责输入校验**。`defineTool` 是第一方工具用的类型化辅助函数。

## `execute()` 的契约（逐条很重要）

- **参数已为你校验。** `defineTool` 在 `execute` 运行前，按统一的 `ParameterSchemaSpec` 校验模型生成的
  `arguments`（类型、必填键、字面量约束、恰好匹配一个分支的联合、嵌套值），因此 `execute` 内的
  `args` 匹配 `InferArgs`。**你仍需手动检查 schema DSL 表达不了的约束** ——
  非空字符串、正数、跨字段规则。显式对象节点必须声明 `additionalProperties: true | false`；
  隐式参数根对象保持开放。
- **注册借用你的只读定义。** 类型化的同进程贡献不是序列化边界：注册后**不要修改其 schema 或替换回调**。
  `schemas()` 只物化显式的模型可见投影。要热替换工具，请 dispose 其所属副作用并注册替代品。
  回调闭包内的可变状态仍是普通的插件状态。
- **执行身份受保护。** 注册表在一次递归遍历中把 `arguments` 物化为**分离的无损 JSON**，
  在策略开始前冻结该值，并分配不透明的 `exec.token`。`callId`、`name`、`arguments`、`agent`、`token`、
  必填且由调用方持有的 `signal`，以及可选的外层传输 `parent` token 在**整个分发过程中保持不可变**。
  `parent` 仅用于身份标识，不暴露活跃的外层执行。**把 `args` 视为只读输入。**
  只有 around-dispatch 包装器会收到可变视图；它可以替换并恢复必填的 `exec.signal` 以施加截止时间，
  但**不能移除该信号**。
- **声明并返回一个规范 JSON 值。** `output.schema` 用 `ValueSchemaSpec`，**根可以是对象、数组、标量或 null**。
  `execute` 只返回推导出的值；注册表把它快照为无损 JSON、完成校验和冻结后，再传给 `output.render(args, value)`。
  **工具主体不要返回内容块**，也不要迫使调用方从自然语言里解析 id 和字段。
- **抛异常或返回无效值 → `isError`。** 注册表捕获异常，并在观察者运行前收敛 schema/渲染器/元数据投影器/
  无损 JSON 失败。**基础设施故障请抛异常**；成功的领域结果即使表示不理想的状态也应写入规范值
  （例如进程以非零状态退出 → 由 Native 渲染器解释该状态）。
- **遵守 `exec.signal`。** 信号触发时取消进行中的工作。
- **`presentationMeta` 投影可回放的卡片数据（可选）。** `output.presentationMeta(args, value)` 从同一个规范值
  派生可回放 JSON；核心把它持久化在 `tool/result` 上并传给 `presentResult`，因此需要结果期事实的卡片
  （如 `write` / `edit` 的已应用 hunk）无需持久化规范值就能在回放中重现。嵌套 Code 分发没有卡片，
  会跳过该投影器。
- **用 `exec.agent` 发送异步通知。** `agent.inject({ content, source: { kind: 'plugin', plugin: '<name>' } })`
  追加**持久化上下文**，下一次模型请求会看到它 —— **这不是唤醒**（空闲的 agent 保持空闲）。
  请防范已 dispose 的 agent（try/catch）。

## 长时间运行的工作

通过 producer 配置控制 `run_in_background`，然后用 `ctx.jobs.start({ kind, label, owner: exec.agent, run })`
注册任务：

- 注册表在进入 producer 主体前，把**已预先中止**的调用判为失败。
- 运行时在 `run()` 启动工作前校验 owner 和任务控制器是否可用，随后提供 id、会话围栏、
  通用控制工具、通知和 owner cleanup。
- 成功的后台分支返回**类型化的规范句柄**，如 `{ kind: 'background', jobId }`；
  Native 渲染器可以保留 `started background job bash-1` 这类给人读的自然语言，
  但 **PTC mode 绝不能通过解析这段文本取得 id**。
- spec 提供同步的 `cancel`、在资源清理后 settle 且**不 reject** 的 `done`，
  以及被注册表泵入 job 输出环的拉取式 `output` 源（或经 starter 收到的 `JobHandle` 推送）。
- **`ctx.jobs.start()` 发布 id 后，应使用任务自有的取消信号，而不是 `exec.signal`** ——
  之后取消外层调用只会停止等待本次调用，**不会终止已经发布的工作**；该生命周期归
  `job_kill`、owner dispose 和服务 teardown 所有。前台工作仍与 `exec.signal` 耦合。

完整约定见 `dsh-tool-bash` 与后台任务运行时 Agent Note。

## 执行策略与观测：不要内建部署策略

**尽量不要把部署策略内建到工具中。** 用这些扩展点：

| 扩展点 | 用途 |
|---|---|
| `tools/pre-execute`（waterfall） | 可扩展的**允许 / 拒绝 / 询问**策略（权限门禁、钩子、沙箱） |
| `ctx.tools.guard()` | 设置**最终的单调拒绝**，后续监听器无法撤销 |
| `tools/execute`（waterfall） | 围绕分发加**截止时间、重试、指标收集**（around dispatch） |
| `tools/post-execute`（waterfall） | 替换展示内容或返回值、阻止结果、附加模型可见上下文 |
| `tools/result`（同步通知） | **观测不可变的归一化结果而不改变它** |
| `output.projectContent` | 由定义自身控制，在执行后策略**之前**安装已准备内容 |
| `output.finalizeContent` | **最后一道仅限内容的不变式** |

注意：**替换内容不会阻止程序化访问 `value`**；保密策略会屏蔽或替换该值。
沙箱实现也可以在工具的执行器实现中运行。

`dsh-tools` README 的 "extension points" 小节定义每个扩展点的输入、顺序、返回值和失败行为。

### 权限门禁示例（钩子插件）

```ts
import type { Context } from '@deepseek-ai/cordis'
import type { PreToolDecision, ToolExecution } from '@deepseek-ai/dsh-tools'

declare function isAllowed(exec: ToolExecution): Promise<boolean>

export const name = 'permission-gate'

export function apply(ctx: Context) {
  ctx.on('tools/pre-execute', async (exec, next): Promise<PreToolDecision> => {
    if (!(await isAllowed(exec))) {
      return { kind: 'deny', reason: 'Denied by policy.' }
    }
    return next()                         // 委托给下游监听器
  })
}
```

这是**可重排的策略层**。当不变式需要单调的最终拒绝时用 `ctx.tools.guard()`；
需要包裹分发生命周期时用 `tools/execute`（仅 `exec.signal` 可替换）；
显式结果变换用 `tools/post-execute`；对不可变最终结果的受限观察用 `tools/result`。

## 工具执行流水线（完整顺序）

```text
模型消息里出现 tool-call block
  → Session 事件 tool/call          （执行前就落日志）
  → UI pending 卡片 presentCall(args)
  → tools/pre-execute  waterfall    （钩子、权限、沙箱）
      ├ allow → 已注册的单调守卫（deny 或 abstain；身份受保护）
      │           ├ allow → tools/execute waterfall（超时、重试、指标）
      │           │           → 已注册工具的 execute() 主体
      │           │           → fs/write-intent | fs/edit-intent（仅 tool-fs 变更）
      │           │           → 工具自有的 session 事件
      │           │               （todo/write、fs/observed、hook/invoked、
      │           │                hook/result、tool/ptc-dispatch）
      │           └ deny  → 跳过工具主体
      └ deny  → 跳过工具主体
      └ ask   → ctx.approval 一次性询问
                   ├ allowed-once → 单调守卫
                   └ rejected / cancelled / unavailable → 拒绝
  → ToolDefinition.projectContent   （执行期准备的文本与图片）
  → tools/post-execute waterfall    （accept、block、replace、add context）
  → 注册表外层归一化                （pipeline/result 快照抛错 → isError）
  → ToolDefinition.finalizeContent  （最后一道仅限内容的不变式）
  → tools/result  同步通知          （冻结的权威结果）
  → 活跃批次 additionalContexts FIFO（在已记录的 tool result 之后注入 user/message）
  → Session 事件 tool/result         （单一模型面向的结果）
  → 批次 settle → UI 完成卡片 presentResult(args, result)
```

要点：

- **文件系统的"先读后编辑"检查位于 `tool-fs` 之下，通过 `fs/*` 事件实现。**
- `ctx.approval` 在**单调守卫之前**处理询问；不得重新排序的所有者策略仍作为已注册的守卫。
- 注册表会对候选结果做**无损快照**；快照失败则先规范化失败，之后由快照时已固定的
  `finalizeContent` 回调强制执行其同步且仅限内容的不变式。
- **PTC mode** 会把保留的 `run_code` 传输及其序列化子调用都送入同一条流水线；
  子调用携带父级 token、记录 `tool/ptc-dispatch`、把拒绝呈现为具有约束力的驳回，
  并**省略 `additionalContexts`** 以保持调用与结果相邻。

## PTC mode：自动触达你的工具

在 PTC mode 中，**每个可见的已注册工具都可通过 `await tools.<name>(args)` 调用**，无需额外集成。
生成的 `ToolArgsMap` / `ToolOutputMap` 会根据同一组 schema 分别推导精确的参数类型与规范返回类型，
调用则重新进入正常的执行流水线。

- 成功调用解析为**策略处理后的最终规范 JSON 值**，而不是渲染后的 Native 内容。
- 失败调用以真正的 `ToolCallError` reject；程序只能检查其 `name`、`toolName` 和给人读的 `message`，
  **无法取得内部错误代码或失败联合**。

**因此把 `output.schema` 设计为实用的程序化 API**：直接返回句柄与字段；
当标量、数组或 null 确实就是结果时，允许采用相应的根类型；把面向人类的解释放进 `output.render`。
中间值只存在于执行期间，不会被持久化、不按提示词上限截断、也不设字节上限。

## 工具在 UI 中怎么渲染

`output.render` 返回**模型可见内容**；**UI 卡片是另一项独立关注点**，通过纯展示投影以及可选的
`presentCall` / `presentResult` 声明。没有 UI 展示方法的工具会回退到通用卡片
（标题 = 工具名，原始 args 作为输入）。

两个方法都返回一个 **带 `card` 标签的渲染意图**：

### `presentCall(args)` → `ToolCallView`（PENDING 卡片）

- `{ card: 'generic', title, kind?, rawInput?, content?, locations? }` —— 默认。
  设置 `kind` 获取图标（`read` / `search` / …）；设置 `locations: [{ path, line? }]`
  标注工具涉及的文件，使有能力的编辑器跟随/跳转。
- `{ card: 'terminal', title, description?, cwd? }` —— 调用本身就是 shell 命令。
  `title` 是命令，`description` 渲染在终端卡片上方。（tool-bash）
- `{ card: 'diff', title, diffs, locations? }` —— 调用创建或修改文件。
  `diffs: [{ path, oldText, newText }]`（新文件时 `oldText: null`）渲染为内联 diff 卡片。
  （tool-fs 的 `write` / `edit`）

### `presentResult(args, { content, isError, meta? })` → 完成卡片

- `generic` —— 可选标题和内容。
- `terminal` —— 原始输出和可选退出元数据；各 UI 按自身能力渲染或回退。
- `diff` —— 已应用的 hunk，通常由 `output.presentationMeta` 派生并通过持久化的 `result.meta` 携带，
  使回放能重现它们。**变更类工具保留 diff 结果**，因为完成视图会替换 pending 卡片。
- `read` —— 从持久化 `result.meta` 重建的已完成文件窗口：文件 `path`、从 1 开始的 `offset`、
  返回的 `lines`（每行保留其文件行号）、`totalLines`，以及可选的 `lang` 高亮提示；
  不具备 `read` 能力的 UI 回退到原始结果内容。**没有 `read` 调用视图** ——
  读取调用的 pending 状态保持 generic 卡片，因为内容只在 `execute` 之后才存在。（tool-fs 的 `read`）
- `search` —— 从持久化 `result.meta` 重建的发现型结果：按文件分组的匹配（`shape: 'matches'`，grep）
  或扁平路径列表（`shape: 'paths'`，glob），外加 `truncated` / `total`，
  使 UI 永不把被截断的结果当作完整结果呈现。该视图不携带结果文本；也没有 `search` 调用视图。（`grep` / `glob`）
- `web` —— 已完成的 web 检索，以 `kind: 'search' | 'fetch'` 区分，由 `result.meta` 派生；
  不携带正文副本，不具备 `web` 能力的 UI 回退到原始结果内容。（`web_search` / `web_fetch`）

### 硬性规则（违反会出问题）

- **纯函数。** 这些方法在**实时流式输出和会话日志回放时都会运行**，因此必须是 `args`（加 result）的
  纯函数 —— **不做 I/O、不读会话状态、不用时钟/随机数**。diff 从 args 派生（`write` 用 `oldText: null`，
  因为调用时的展示器没有文件先前内容）；会话上下文由 **UI 适配器**而非工具提供。
  如果你发现自己想在 `presentCall` 内获取文件旧内容或工作目录，**停下** ——
  那属于持久结果元数据或适配器，不属于展示器。
- **UI 格式不进入模型结果。** 围栏 ` ```console ` 块、diff、相对化路径均不应**仅为服务 UI** 而进入
  规范值或 Native 内容。`output.render` 负责模型可见的自然语言；
  `presentationMeta` 和卡片展示器负责可回放的 UI 状态。
- **`defineTool` 对展示路径做软校验。** 格式错误或旧版日志中的参数会让包装器返回 `undefined`
  （通用回退）而非抛异常 —— **展示绝不能导致回放崩溃**。

**中性词汇定义在 `dsh-tools` 中；工具绝不导入 UI 或传输类型。**
消费方把每个 `card` 映射到自己的视图。参考实现：`dsh-tool-fs`（generic/diff）、
`dsh-tool-bash`（terminal）。

### 内置 Web Client 的展示路径

**内置 Web Client 不消费 `presentCall` 或 `presentResult`。** Session `page` 与 `follow` 运输原始
`tool/call` 和 `tool/result` 事件（包括持久化的 `result.meta`）。Client 插件在 keyed slot
`tool.call.toolview` 中注册自己的 wire 工具名称，并从 `ToolCallBlock` 的参数、内容、错误、metadata、
现有 PTC dispatch `parentCallId` 与 Session 路径事实派生组件 props。
插件在本地校验这些 wire 值，并让格式错误或不受支持的输入回退到 generic 行。

需要模型可见内容无法无损保存的有界结构化结果事实时，用 `output.presentationMeta(args, value)`。
**不要**在 metadata 中保存 React props 或预选卡片，**不要**把 Host 工具实现导入浏览器 bundle，
**不要**建立另一套 Client presenter registry。**只定义 Host 展示方法不会增加专用 Web 卡片。**

## 事件参考：`tools/result` 长什么样

```ts
export function apply(ctx: Context) {
  ctx.on('tools/result', (exec, result) => {
    console.log(`[tool] ${exec.name}(${JSON.stringify(exec.arguments)})`)
    const text = result.content
      .map(block => block.type === 'text' ? block.text : '')
      .join('')
    console.log(`[tool result] ${text.slice(0, 100)}`)
  })
}
```

## 验证

遵循仓库测试策略（`docs/testing.zh.md`）和所属包的测试文档。
**已交付且面向模型或 UI 的变更必须提供其中规定的组装覆盖。**

## 相关文档

- `/develop/basic/tool` — 第一个工具教程
- `/reference/cookbook/adding-a-tool` — 工具定义的真源（嵌套 schema、规范值、后台工作、
  策略钩子、PTC mode、UI 卡片）
- `/reference/tool-execution-pipeline` — 上面的流水线图
- `/reference/tool-catalog` — 生成的 Tool Schema 目录
- `/reference/cookbook/extension-cookbook` — 钩子插件、UI 插件、外部协议驱动的参考模式
