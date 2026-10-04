# 插件开发与分发

本篇覆盖：插件的配置（Config）、服务隔离、把插件打包成**组合包（bundle）**、
以 **profile** 安装与启动、加载层序、以及从 GitHub 安装时的构建授权坑。

插件的基本形态、`inject`、生命周期、事件见 [cordis-core.md](cordis-core.md)。

## 配置：Config + Schemastery

让插件接受用户在 `cordis.yml` 中传入的配置 —— 导出一个 `Config` **类型**和**同名**的
Schemastery schema，默认值直接写在 schema 里：

```ts
import type { Context } from '@deepseek-ai/cordis'
import Schema from '@deepseek-ai/schemastery'

export const name = 'my-plugin'

export interface Config {
  greeting: string
  maxRetries: number
  verbose?: boolean
}

export const Config: Schema<Config> = Schema.object({
  greeting: Schema.string().default('Hello'),
  maxRetries: Schema.number().default(3),
  verbose: Schema.boolean().default(false),
})

export function apply(ctx: Context, config: Config) {
  console.log(config.greeting)   // 用户值或 schema 默认值
}
```

`cordis.yml` 中注入：

```yaml
- insert:
    - id: hello
      name: './src/my-plugin.ts'
      config:
        greeting: 'Hi there'
        maxRetries: 5
```

加载时 Cordis 用导出的 schema **校验配置并填充默认值**。

> **不要导出普通对象当 `Config`** —— 它不满足 Cordis 要求的 Standard Schema 接口。
> 必须用 `Schema.object(...)`（`@deepseek-ai/schemastery`）。

需要严格校验时：

```ts
export interface Config {
  apiKey: string
  timeout: number
  mode: 'fast' | 'accurate'
}

export const Config = Schema.object({
  apiKey: Schema.string().required(),
  timeout: Schema.number().default(30000),
  mode: Schema.union(['fast', 'accurate']).default('fast'),
})
```

配置不合法 → **插件加载失败并给出明确错误信息**（这是期望行为）。

### 两条设计原则

1. **无硬编码可调参数。** Harness 的约定：**凡是不同部署可能需要取不同值的参数，都必须定义为配置字段。**
   检验标准 —— 能否在 `cordis.yml` 中改变这个值，而不修改代码？
   ```ts
   // ✗ 错：硬编码超时
   const TIMEOUT = 30000
   // ✓ 对：可配置，默认 30000
   export interface Config { timeoutMs: number }
   ```
2. **配置错误要响亮。** 在 schema 中表达自身完备的约束，让无效配置在**加载时**失败。
   对服务或已注册资源的引用需要依赖注入，不要从配置里悄悄兜默认值。

### 配合 HMR

修改 `cordis.yml` 中某个插件的 `config` 会触发插件热替换（卸载旧实例 → 加载新实例）。
因为注册都属于 effect 并会自动清理，替换后不会保留旧实例的注册。

## 服务隔离

`cordis.yml` 支持服务隔离 —— 同一服务可以有多个实例，不同插件组看到不同实例：

```yaml
- id: group-a
  name: '@deepseek-ai/cordis-plugin-group'
  group: true
  isolate:
    shell: true
  config:
    - name: '@deepseek-ai/dsh-bash-local'
      config:
        timeoutMs: 5000
    - name: './src/plugin-a.ts'

- id: group-b
  name: '@deepseek-ai/cordis-plugin-group'
  group: true
  isolate:
    shell: true
  config:
    - name: '@deepseek-ai/dsh-bash-local'
      config:
        timeoutMs: 60000
    - name: './src/plugin-b.ts'
```

`plugin-a` 和 `plugin-b` 各自看到自己组内的 Bash 实例，互不影响。
（`dsh` 的 agent preset 就是靠 `isolate` realm 让不同会话拥有不同能力集合。）

## 两个概念，两种 manifest

安装机制建立在两个概念之上，二者都由 `package.json` 描述，但在 **`dsh` 键下携带不同类型的 manifest**：

- **组合包（bundle）**：附带一个配置层的 npm 包。manifest 声明 `dsh.bundle`，
  回答"**这个包贡献什么？**" —— 一个插入或覆盖插件行的 patch 文件。
- **profile**：位于 `$DSH_HOME/profiles/<name>`、描述一份可启动组合的目录。
  manifest 声明 `dsh.profile`，回答"**这套配置由哪些组合包按什么顺序组成？**"。

bundle 是你编写并分发的东西；profile 是用户用 `dsh --profile <name>` 启动的东西。
**没有东西同时是两者。**

### bundle manifest

```text
hello-plugin/
├── package.json       # declares dsh.bundle
├── cordis.patch.yml   # the layer applied when a profile lists this bundle
└── index.js           # plugin modules the patch rows reference
```

```json
{
  "name": "dsh-hello-plugin",
  "version": "0.1.0",
  "type": "module",
  "main": "index.js",
  "files": ["index.js", "cordis.patch.yml"],
  "dsh": { "bundle": { "patch": "./cordis.patch.yml" } }
}
```

```js
// index.js
export const name = 'hello-plugin'
export function apply() {
  console.log('[hello-plugin] plugin loaded!')
}
```

```yaml
# cordis.patch.yml —— 与 --patch overlay 同格式，但插件行按【包名】引用，
# 这样 Node 的模块解析才能找到已安装的代码
- insert:
    - id: hello
      name: dsh-hello-plugin
```

`patch` 也接受**有序文件列表**，如 `["./base.patch.yml", "./web.patch.yml"]`：
launcher 按该顺序把它们作为**同一层**应用，每个文件中的相对插件路径**相对于该文件**解析。

没有 `dsh.bundle` 声明的包仍可安装，但只作为普通依赖 —— `dsh plugin` 会打印警告且**不激活任何层**。
如果一个库是供插件包 import 而不是供用户启用，就用这种包格式。

### profile manifest

profile 目录含两个文件：

- `package.json` — profile 的**树外**插件依赖（由 pnpm 管理），加上 `dsh.profile` 及其有序 `bundles` 列表。
- `cordis.patch.yml` — 用户自己的 patch 层，在**每个 bundle 层之后**应用。

profile manifest **从不需要手写**：`dsh --profile <name> --from-default-profile <template>`
可从随附模板创建，`dsh plugin` 会创建一个以 base 为基础的 profile 并维护其中已安装的 bundle 列表。

```sh
dsh plugin --profile demo add ./hello-plugin
```

首次使用会初始化 profile（`@deepseek-ai/dsh-base` 作为第一个组合包），pnpm 链接该 checkout，
`dsh` 因该包声明了 `dsh.bundle` 而把它追加进 `dsh.profile.bundles`：

```json
{
  "name": "dsh-profile-demo",
  "private": true,
  "dependencies": { "dsh-hello-plugin": "link:/path/to/hello-plugin" },
  "dsh": { "profile": { "bundles": ["@deepseek-ai/dsh-base", "dsh-hello-plugin"] } }
}
```

先**不启动**只验证该层，再启动：

```sh
dsh --profile demo --dump-config   # 会显示 "# == dsh-hello-plugin" 这一层
dsh --profile demo
dsh plugin --profile demo remove dsh-hello-plugin   # 同时移除依赖和对应的层
```

### 依赖声明约定

- 通过 link 安装的 checkout **保留自己的 `node_modules`**。
- 需要与宿主**共享实例**的 dsh 包，同时声明在 `peerDependencies` 与 `devDependencies` 中
  （peer 用运行中的副本，dev 副本供类型检查和独立测试）。
- 需要**独立版本**的第三方依赖，以及**无状态**的 dsh 工具包，放 `dependencies`。
- linked import 遵循 Node 的祖先顺序，检查每个目录当前的 peer 声明；更近的物理包先于更高的 peer 声明。

## 加载顺序（层优先级）

生效配置在**空根**之上按以下顺序逐层组合：

1. `dsh.profile.bundles` 所列各 bundle 的 patch，按列表顺序 —— 先是 `@deepseek-ai/dsh-base`，
   然后是每个已安装 bundle，按加入顺序。
2. profile 自己的 `cordis.patch.yml`。
3. home 级 `$DSH_HOME/cordis.patch.yml` —— 各 profile 共享的机器本地偏好。
4. 每个 `--patch <path>` overlay，按 argv 顺序。

应用参数**不是另一层 patch**；表层 bundle 可以通过 plugin 的 commander 程序与
`@deepseek-ai/dsh-cmdline` 的 `parseCmdline` 解析它们。

**规则**：后应用的层按行胜出，**patch 会替换目标行的整个 `config` 值，而不是深度合并各键**。
两个推论：

- 你的 patch 可以按 `id` 覆盖前面各层的行，但**必须重述该行需要的每一个键**，不能只写改动的那个。
- 用户可以在自己 profile 的 `cordis.patch.yml` 中覆盖你的行，无需改你的包 ——
  所以优先给出用户大概率会保留的默认值，其余交给 schema 承担。

内置 bundle 名始终从 **dsh 安装目录本身**解析；pnpm 只管理树外包，
所以你的 bundle 可以放心依赖 `@deepseek-ai/dsh-base` 存在且与安装一致。

随附 bundle：`@deepseek-ai/dsh-base`（共享第一层：模型适配器、工具、持久化、沙箱与审批策略、
设置、凭据、遥测）、`dsh-web-app`、`dsh-headless`、`dsh-sdk-app`、`dsh-acp-app`、
`dsh-sdk-minimal`（**刻意保留的例外**：一个 bundle 拥有完整的显式 SDK 配置树，不应用 `dsh-base`）。

## 从 GitHub 安装：构建脚本这道坎

发布到注册表不是必须的，用户可以直接从 git 托管安装：

```sh
dsh plugin --profile demo add github:you/hello-plugin
```

但 git 安装拉取的是**源码，不是构建产物** —— 没有任何环节运行你的 `build` 脚本，
所以 TypeScript 包到手时没有 `lib/` 输出，加载会失败。**两边各做一件事**：

- **作者**：提供 `prepare` 脚本（pnpm 在 git 安装后运行它），从源码构建出发布入口。
  必须**自包含** —— 不能假设旁边有一份 monorepo checkout。专用 tsdown 配置可直接转译 `src/`，
  不用项目引用、不做类型检查。
- **用户**：为构建授权。pnpm ≥10 在得到显式允许前拒绝运行 git 依赖的 `prepare` 脚本，
  所以第一次 `add` 会失败；把 pnpm 打印的确切包键复制进该 profile 的 `pnpm-workspace.yaml`：

  ```yaml
  allowBuilds:
    dsh-hello-plugin: true
  ```

  然后重新执行 `add`。

> **安全提示**：这项授权等于**允许该包的代码在安装时于你的机器上执行**，且不在 agent 运行的
> 任何沙箱之内。只对源码可信的包授权，并**锁定 commit**（`github:you/hello-plugin#<sha>`），
> 让后续推送无法悄悄改变实际运行的内容。

不想让用户做这项授权，就改为**分发构建产物**（两者都不需要任何构建权限）：

- **发布到 npm**，在 `pnpm publish` 时构建好 `lib/`；`dsh plugin add your-package` 装的是预构建代码。
- **交付 tarball**：`pnpm pack` 打包；用户 `dsh plugin add ./hello-plugin-0.1.0.tgz`。

## 让表层 bundle 持有自己的命令行

定义了可运行应用的 bundle 挂载一个普通提供方插件：

```yaml
- id: hello-startup
  name: 'dsh-hello-plugin/startup'
```

该插件导出 `inject = ['cmdlineArgs']`，用 `@deepseek-ai/dsh-cmdline` 的 `parseCmdline`
配合自己的 commander program，再在 program 的 action 中把应用自有服务提供出去。
启动器把自身 flag 之后的**同一份不可变参数**交给每个插件，因此添加应用专属 flag 无需修改启动器，
多个插件也可以解析同一份快照。Loader 行不需要启动器标记或特殊类型。

## 在 monorepo 里新增 `@deepseek-ai/dsh-*` 包

仅当你要**给 harness 本身**贡献包时才需要。逐文件清单：

```text
packages/<group>/<pkg>/
  package.json     # 从 packages/core/tools 复制，改 name/description/deps
  tsconfig.json    # extends ../../../tsconfig.base.json，rootDir src，
                   # outDir lib/types，references: ../../../vendor/cosmokit、
                   # ../../../vendor/cordis（用 Config 再加 schemastery）、
                   # 每个 dsh 依赖加 ../../<group>/<dep>
  src/index.ts     # 服务 default export，或插件（name/inject/apply/Config）
  locale/en.json   # 可选展示元信息：meta.title / meta.description
  locale/zh.json
  README.md        # 服务 API、事件、扩展点、设计说明 + Model Experience 区块
                   # + "Known Limitations and Deferred Work" 区块
```

**package.json 不变式**（由 `pnpm run constraints` 强制）：

- `private: true`，`version` 与根 `package.json` 一致，`type: module`
- `main: "lib/index.js"`，`types: "lib/types/index.d.ts"`
- `exports["."].types: "./lib/types/index.d.ts"`，`exports["."].default: "./lib/index.js"`
- `@deepseek-ai/cordis` **同时**出现在 `peerDependencies` 和 `devDependencies`（相同范围）
- `@deepseek-ai/schemastery` 放 `dependencies`（它是运行时校验器）
- `files` 精确包含 `lib/index.js`、`lib/types/**/*.d.ts` 及门禁认可的包专用运行时产物
- **不要**发布 `src`、声明映射、JS map 或陈旧的根声明文件

包内相对导入在源码中用显式 `.ts` 后缀（`export * from './types.ts'`），
编译器在输出的 JS 里重写为 `.js`。

**根配置注册**：

| 文件 | 变更 |
|---|---|
| `tsconfig.base.json` | 已有分组无需编辑；**新分组**需为 `@deepseek-ai/dsh-*` 通配符加 `./packages/<group>/*/src` 候选路径 |
| `tsconfig.host.json` 或 `tsconfig.client.json` | 在 `references` 中加 `{ "path": "./packages/<group>/<pkg>" }` —— 普通包**恰好属于一个 aggregate**，绝不两个都加 |

`packages/client/*` 改为 extends `tsconfig.base.client.json`，并需在 package.json 声明
`dsh.client`、导出 `./client`、调用共享 tsdown preset（`packages/client/tsdown.client.ts`）。

以下由 glob 或 manifest 发现机制自动覆盖，**无需手动编辑**：根 `package.json` workspaces、
`scripts/publint-all.ts`、`tsdown.config.ts`、`.oxlintrc.json`、`scripts/check-workspace-constraints.ts`。

### 角色命名的纪律

名称必须描述**当前稳定职责**；不要用首个实现、可能的未来扩展或 Cordis 基类命名。
接口包用能力名；实现包加上能区分机制/协议/环境/厂商的限定词；
只有"同主机执行属于约定"时才用 `local`。

| 词 | 适用条件 | 不适用条件 |
|---|---|---|
| `Controller` | 接受命令或用户意图，改变一项既有领域/展示状态 | 执行任意工作、拥有一组 provider、只做值→展示转换 |
| `Store` | 拥有一组数据，主要提供其 CRUD / snapshot / subscription | 校验状态机、裁决权限、分派工作、拥有 provider 优先级 |
| `Directory` | 暴露供发现或选择的条目及其元数据 | producer 注册任意实现，或调用方通过它执行工作 |
| `Presenter` | 把领域值或工具参数**纯转换**为渲染意图 | 执行 I/O、订阅、修改状态、拥有生命周期 |
| `Registry` | 拥有一组动态具名注册 + 查询/重复项/优先级/生命周期/释放 | 主要约定是分派、执行、取消、策略或编排 |
| `Runtime` | 运行实时工作，跨调用拥有分派/取消/provider 协调/操作生命周期 | 只存储记录、返回目录、解析一个值、保存配置 |
| `Resolver` | 根据输入计算或定位一个答案，**但不拥有该答案的生命周期** | 拥有可变集合或长时间运行执行 |
| `Binder` | 把已声明接口绑定到调用方 context/生命周期并返回值 | 把值作为集合持有、控制领域状态、只转换数据 |
| `Engine` | 实现领域算法或有状态执行模型 | 只选择 provider 或跨协议边界转发请求 |
| `Policy` | 决定允许/选择/限制/观察什么 | 执行该决定所允许的机制 |
| `Executor` | 在一项能力中运行一个明确请求或已解析 spec | 拥有广泛应用生命周期或 provider 目录 |
| `Gateway` | 适配进程、网络、RPC 或 API 边界 | 只注册同进程服务或存储元数据 |
| `Provider` | 提供一项能力定义的一个实现 | 表示能力定义、provider registry 或消费方 runtime |
| `Backend` | 在已定义接口后实现可替换的底层持久化/传输/执行 | 表示面向用户的服务或已返回的实时资源引用 |
| `Handle` | 引用一个实时资源，并控制或观察该资源 | 创建并管理完整资源池 |
| `Service` | 拥有一项无法用以上更精确角色诚实描述的内聚领域服务 | 只因为类继承 Cordis `Service` 而用这个名字 |

`ctx` key 单复数也要一致：engine/runtime/policy/controller/resolver/store 用**单数**，
registry 或拥有多个具名成员的服务用**复数**。

**产品拼写统一用 `Typert`**，不得写 `TypeRT` / `typeRT`。
`SDK` 只用于受支持的 Python 与 TypeScript SDK 的 JSON-RPC 客户端/服务器协议 ——
**DeepSeek Harness 本身是 agent harness，不是 SDK 项目。**

### 插件展示元信息（可选）

`locale/en.json` 定义标题与描述（`en.json` 是发现入口），其他语言用同名字段：

```json
{ "meta": { "title": "Workspace Tools", "description": "Tools for your workspace." } }
```

同时合并进 `package.json`（保留已有 exports 与发布文件）：

```json
{
  "exports": { "./package.json": "./package.json", "./locale/*.json": "./locale/*.json" },
  "files": ["locale/*.json"]
}
```

回退链：标题 = locale `meta.title` → `package.json.name` → 完整 Cordis 插件名；
描述 = locale `meta.description` → `package.json.description` → 不显示。
要显示图片，在导出清单顶层设 `"icon": "./icon.svg"` 并加入 `files`
（≤256 KiB 的 SVG / PNG / JPEG / WebP，必须自包含；SVG 作为图片渲染，不作为内联 HTML）。

## 验证

```sh
pnpm install
pnpm run doc-sync
pnpm run constraints && pnpm run typecheck && pnpm run lint
pnpm run build && pnpm run hygiene
pnpm run verify-package-meta      # 检查 locale 字段、资源 exports 与发布文件覆盖
```

**No hardcoded tunables** 和 **配置错误要响亮** 是仓库级约定，新插件应遵守。

## 相关文档

- `docs/development.zh.md` — 搭建、TypeScript 项目布局（Host/Client aggregate）、日常命令、Profile 运行
- `apps/cli/README.zh.md` — CLI 入口模式、应用参数、profile、可选覆盖层
- `apps/cli/reference/README.zh.md` — 确切的层优先级、flag、关闭行为、源码执行
- 文档站 `/develop/basic/config|publish`、`/reference/cookbook/adding-a-package`
