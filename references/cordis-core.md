# Cordis 内核（dsh 的插件框架）

Cordis 是 DeepSeek Harness 底层**以 vendor 方式引入**的插件框架（包名 `@deepseek-ai/cordis`）。
dsh 的产品每一部分都是插件 —— 模型适配器、工具注册表、会话日志、agent loop 本身 ——
所以每个都能从配置替换。读 [architecture.md](architecture.md) 之前先读本篇。

vendor 源码在仓库 `vendor/cordis/`，同步流程见 `vendor/README.md`。完整 API 参考：
文档站 `/reference/cordis-api/context|events|fiber|registry|service|inherited`，以及子系统页面里
生成的 `cordis-surface` 区块。

## 五个核心概念

1. **插件是实现 Service 的对象。** 可以是带可选 `inject` 和 `apply(ctx)` 的函数，也可以是
   `Service` 子类；生命周期由 Cordis 挂载到当前上下文。
2. **上下文（Context）是服务的容器。** 一个服务占据稳定的 `ctx.<key>`
   （`ctx.tools`、`ctx.llm`、`ctx.sessions`…）；其他插件按 key 查找服务，**不 import 具体实现**。
3. **用 `inject` 声明服务依赖。** 声明后插件会等这些服务就绪才启动；
   **加载顺序通过服务依赖表达，而不是手动编排启动序列**。
4. **类型化事件用于通信。** 服务用 TypeScript 声明合并注册事件名，然后按
   `emit` / `waterfall` / `parallel` / `serial` / `bail` 分发。
5. **注册是可逆的副作用。** 提示词片段、工具 schema、适配器、提供方、监听器都通过
   `ctx.effect()` 或 `ctx.on()` 安装，reload / teardown 时按预期撤销。

## 插件形态与 `apply`

```ts
import type { Context } from '@deepseek-ai/cordis'

export const name = 'my-plugin'
export const inject = ['tools']            // 可选：声明依赖服务

export function apply(ctx: Context) {
  // 走到这里时，inject 声明的服务已经全部就绪
}
```

对象形式：

```ts
export default {
  name: 'my-plugin',
  inject: ['tools'],
  apply(ctx: Context) { /* ... */ },
}
```

类形式（**当插件要向其他插件提供服务时**才需要）：

```ts
import { Service, type Context } from '@deepseek-ai/cordis'

export default class MetricsService extends Service {
  static inject = ['llm']                  // 服务本身也可以依赖别的服务

  constructor(ctx: Context) {
    super(ctx, 'metrics')                  // 注册为 ctx.metrics
  }

  record(event: string, value: number) { /* ... */ }
}
```

## Fiber 状态机（插件生命周期）

每个被加载的插件都拥有一个 **Fiber** 作用域：

```text
PENDING → LOADING → ACTIVE
                 ↘ FAILED
ACTIVE → UNLOADING → DISPOSED
```

| 状态 | 含义 |
|---|---|
| PENDING | 已声明，但所需依赖未就绪 |
| LOADING | 依赖就绪，正在执行 `apply` |
| ACTIVE | 插件运行中 |
| FAILED | `apply` 抛出异常 |
| UNLOADING | 正在卸载并释放资源 |
| DISPOSED | 已完全卸载 |

**依赖驱动的加载**：如果某项必需服务在运行期间消失（例如提供方被替换），
依赖它的插件会被自动 dispose，服务恢复后再自动重新加载 —— 这防止插件调用已不存在的服务。

**嵌套上下文**：`ctx.plugin(childPlugin)` 创建子 Fiber，继承父上下文但有独立生命周期，
随父插件一起卸载。

**手动释放**：

```ts
const fiber = ctx.plugin(myPlugin)
await fiber.dispose()
```

`dispose` 保证：① 该插件拥有的所有注册被移除；② 子插件递归卸载；
③ 返回的 Promise 在所有异步清理完成后兑现。

## 自动清理与 `ctx.effect`

**通过 `ctx` 做的任何注册，在插件卸载时都会自动撤销。** 你不需要手写
`removeListener` / `clearInterval`。以下都会被自动追踪：

- `ctx.on(event, handler)` — 事件监听
- `ctx.tools.register(tool)` — 工具注册
- `ctx.llm.registerAdapter(names, adapter)` — LLM 适配器注册
- `ctx.effect(() => cleanup)` — 自定义资源

```ts
export function apply(ctx: Context) {
  ctx.on('some-event', handler)            // 卸载时自动移除

  ctx.effect(() => {
    const connection = createConnection()
    return () => connection.close()        // 返回的 disposer 在卸载时执行
  })
}
```

**顺序陷阱**：卸载时处置器按**注册顺序的逆序**开始调用，但**多个异步处置器会并发执行，
不保证逐个完成**。存在顺序依赖的清理步骤必须放进**同一个** `ctx.effect()` 返回的处置器中，
由该处置器负责串行等待。

## 事件系统

### 注册与分发

```ts
ctx.on('event-name', (payload) => { /* 处理 */ })
ctx.once('event-name', (payload) => { /* 只处理一次 */ })
ctx.emit('event-name', payload)
```

`ctx.on()` / `ctx.once()` 接受 `EventOptions`：

```ts
interface EventOptions {
  /** 在其他同事件监听器之前插入。 */
  prepend?: boolean
  /** 绕过 context filter 检查，始终收到该事件。 */
  global?: boolean
}
```

### 五种分发模式

**分发模式是事件公开约定的一部分**，每个事件只能通过对应方法分发：

| 模式 | 是否 await | 分发顺序 | 有返回值 | 提前终止 |
|---|---|---|---|---|
| `emit` | 否 | 按注册顺序观察 | 否 | — |
| `waterfall` | 否 | 按注册顺序观察 | 是 | 不调 `next()` 即短路 |
| `parallel` | 是 | 所有监听器并行 | 否 | — |
| `serial` | 是 | 按注册顺序观察 | 是 | 首个非 `null`/`false`/`undefined` 的返回值终止后续 |
| `bail` | 否 | 按注册顺序观察 | 是 | 首个非 `null`/`false`/`undefined` 的返回值终止 |

`DispatchMode = 'emit' | 'parallel' | 'serial' | 'bail' | 'waterfall'`

新增 harness 事件用 `@mode` 标签记录模式，生成的目录会把声明与分发调用点做交叉校验。

### waterfall 语义（最容易写错的一个）

`ctx.waterfall` 是**环绕中间件**。监听器接收 `(...args, next)`：
调用 `next()` 会执行下游监听器，下游返回值经 `next()` 返回当前包装层，可包装后再往外返回；
**不调用 `next()` 直接返回即短路整条流水线**。

```ts
// 分发（第三个参数是最终回调）
const output = await ctx.waterfall('my-plugin/transform', input, async () => input)

// 监听：next() 是强制的
ctx.on('my-plugin/transform', async (_input, next) => {
  const downstream = await next()
  return downstream.trim()
})
```

- 协作式监听器通常**修改一个共享的请求/决策对象再委托**。
- 仅当必须在普通注册之前运行时才用 `prepend: true`。
- 对**单决策事件**，短路是设计意图：拥有决策权的策略监听器可以直接返回不调 `next()`；
  只做标注或观察的监听器**必须**委托。
- 需要实现拦截/网关逻辑时，故意不调 `next()` 就是正确写法。

### 类型安全的事件

用 TypeScript 声明合并给事件名加类型：

```ts
import '@deepseek-ai/cordis'

declare module '@deepseek-ai/cordis' {
  interface Events {
    'my-plugin/ready': (payload: { id: string }) => void
    'my-plugin/check': (input: string) => boolean | undefined
    'my-plugin/transform': (input: string, next: () => Promise<string>) => Promise<string>
  }
}
```

之后 `ctx.on(...)` / `ctx.emit(...)` 就能正确推导。**声明合并不会生成任何运行时接线** ——
插件仍必须实际发事件或提供服务。

## Context API 速查

服务存储与混入：

| API | 说明 |
|---|---|
| `ctx.get(name, strict?)` | 按名取服务。用于**可选依赖**（`inject` 用于必需依赖） |
| `ctx.set(name, value)` | 写入服务槽 |
| `ctx.provide(name, value)` | 提供服务，并注册可用性谓词 |
| `ctx.accessor(name, options)` | 自定义访问器 |
| `ctx.mixin(name, mixins)` | 混入 |

上下文与注册：

| API | 说明 |
|---|---|
| `ctx.extend(meta?)` | 派生扩展上下文 |
| `ctx.isolate(name, label?)` | 隔离某个服务（**服务隔离**，见 plugin-development.md） |
| `ctx.intercept(name, config)` | 拦截某服务的配置 |
| `ctx.inject(deps, callback)` | 在依赖就绪后执行回调，注册随该注册自动清理 |
| `ctx.plugin(plugin)` | 挂载子插件，返回其 Fiber |
| `ctx.effect(fn, label?)` | 注册带清理逻辑的副作用 |
| `ctx.emit/bail/serial/waterfall/parallel(name, ...args)` | 分发事件 |
| `ctx.on/once(name, listener, options?)` | 监听事件 |
| `ctx.root` | 根上下文 |
| `ctx.logger` | 日志 |
| `ctx.registry` / `ctx.reflect` / `ctx.events` | 注册表 / 反射 / 事件服务 |
| `ctx.baseUrl` | 基础 URL |

**必需依赖 vs 可选依赖**：

```ts
// 必需：服务缺席时插件根本不加载
export const inject = ['tools']

// 可选：不 inject，在使用点用 ctx.get() 查询
export function apply(ctx: Context) {
  const metrics = ctx.get('metrics')
  metrics?.record('plugin_loaded', 1)
}
```

## 服务（Service）

服务是**挂载在 `ctx` 上的命名能力**，是插件向其他插件公开能力的方式。

```ts
import { Service, type Context } from '@deepseek-ai/cordis'

declare module '@deepseek-ai/cordis' {
  interface Context {
    metrics: MetricsService          // 声明合并，让 ctx.metrics 有正确类型
  }
}

export default class MetricsService extends Service {
  constructor(ctx: Context) {
    super(ctx, 'metrics')            // 服务会立即注册，并随所属 fiber 自动移除
  }

  record(event: string, value: number) { /* ... */ }
}
```

消费方：

```ts
export const inject = ['metrics']

export function apply(ctx: Context) {
  ctx.metrics.record('tool_call', 1)
}
```

`Service` 基类的关键静态成员（符号键）：`Service.init`（构造后运行的实例方法）、
`Service.check`（传给 `ctx.provide()` 的可用性谓词）、`Service.config`（拦截配置类型参数）、
`Service.invoke`（使服务可调用，如 `ctx.logger()`）、`Service.extend`、`Service.tracker`、
`Service.resolveConfig`。

## Loader 配置

`@deepseek-ai/cordis-plugin-include` 把 `!!js` 解析为**表达式节点**：

- Loader 在声明的注入激活后，**基于该插件上下文**（`ctx.serviceName`）插值条目的 `config`。
- 每次挂载决策时，基于 loader 上下文插值其 `disabled` 字段。
- Include 会**保留嵌套行表达式**，直到目标行激活；其余条目元数据保持字面值。
- 由环境选择插件时用 overlay。

```yaml
- id: my-app
  name: '@example/my-app'
  inject: [myAppStartup]
  config:
    port: !!js ctx.myAppStartup.port ?? 8080
```

## HMR（热模块替换）

通过 `cordis.yml` 加载 `@deepseek-ai/dsh-hmr` 后，修改插件源文件会触发：

1. 卸载旧插件（清理所有注册）
2. 重新加载新代码
3. 执行新的 `apply`

**因为注册会被自动清理，热替换不会保留旧实例的注册。** 配置变更同样触发热替换：
修改 `cordis.yml` 中某个插件的 `config` 后，框架卸载旧实例并加载新实例。

在 dsh 里是否启用 HMR 由 YAML 决定：`dsh-base` 启用仅监视配置的 `dsh-hmr`；
Headless、SDK、ACP 禁用它；`sdk-minimal` 不包含它。Profile patch 可以覆盖这些默认值。

## 实践规则

- 把行为封装为插件：工具流水线事件属于 `ctx.tools`，模型流式输出属于 `ctx.llm`，
  实时 agent 协调属于 `ctx.agents`。
- **拦截和策略优先用事件；直接能力调用优先用服务方法。**
- 每个注册都应有对应的 disposer：要么从 `ctx.effect()` 返回一个，
  要么使用 Cordis 提供的辅助方法自动处理。
- teardown 有顺序要求时，把相关工作放进同一个 effect。

## 相关源码位置

- `vendor/cordis/src/context.ts`、`events.ts`、`fiber.ts`、`service.ts`、`registry.ts`
- `vendor/cordis/bin.js` — 教程用的单文件启动器（创建根 Context、挂载 Loader、
  从当前目录加载 `./cordis.yml`）
- 文档站 `/reference/cordis-api/*` — `Context` / `Events` / `Fiber` / `Plugin Registry` /
  `Service` / `继承接口面`（含继承 API 与源码位置）
