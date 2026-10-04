# deepseek-harness-skill

> 让 AI 编程助手真正会写 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 插件的 Agent Skill。

**这不是给 DeepSeek Harness 用的插件，而是教 AI 怎么写 DeepSeek Harness 插件的知识包。**

---

## 快速开始

```sh
# 1) 装进你的 Agent 工具（WorkBuddy / Claude Code等智能体工具，根据正在使用的智能体安装，下面是示例）
git clone https://github.com/shuaishenlxq/deepseek-harness-skill.git \
  ~/.workbuddy/skills/deepseek-harness-skill

# 2) 把 dsh 装成全局命令（需先有一份源码 checkout，见「使用教程」）
bash ~/.workbuddy/skills/deepseek-harness-skill/scripts/install_global_dsh.sh \
  ~/evn/deepseek-harness
```

3）重启工具 / 新开会话，然后直接问：**「用 deepseek-harness-skill 帮我写个 dsh 插件」**。

详细步骤见 [安装](#安装) 与 [使用教程](#使用教程)。

---

## 为什么需要它

DeepSeek Harness（命令名 `dsh`）是 DeepSeek AI 开源的 agent harness，2026 年 8 月才开源，  
目前仍处于**开发者预览**阶段（`0.2.x-rc` / `alpha`）。它有三个特点：

| 特点                                                      | 后果                                       |
| ------------------------------------------------------- | ---------------------------------------- |
| **一切皆插件** —— 模型适配器、工具注册表、会话日志、agent loop 本身都是 Cordis 插件 | 扩展点极多，API 面很宽                            |
| **迭代快，明确会有破坏性变更**                                       | 上个月的写法这周可能就过时                            |
| **足够新**                                                 | 通用大模型的训练数据里基本没有它，直接问 AI 大概率得到**编造的 API** |

这个 skill 把官方文档（186 页，中英双语）里真正会用到的部分结构化成了可加载的参考资料，  
并配了几个脚本用于**核对事实**和**生成可运行骨架** —— 而不是靠模型记忆硬编。

### 有 / 没有这个 skill 的区别

|      | 没有                                 | 有                                                             |
| ---- | ---------------------------------- | ------------------------------------------------------------- |
| 插件形态 | 编一个 `export default function(ctx)` | 函数 / 对象 / `Service` 子类三种形态，按场景选                               |
| 工具定义 | 猜 `parameters` 怎么写                 | `defineTool` DSL、参数校验边界、`output.render` 与 `output.schema` 的分工 |
| 配置   | 导出一个普通对象当 `Config`                 | 知道必须用 Schemastery（Standard Schema 接口）                         |
| 插件加载 | `cd` 进仓库再跑，工作区永远是仓库                | 知道 `--patch` overlay 路径必须绝对、且不能被 `cd` 影响                      |
| 分发   | 直接扔 GitHub 上                       | 知道 git 安装拉的是**源码不是产物**，需要 `prepare` + `allowBuilds`           |
| 排错   | 到处试                                | 知道去 `llms.txt` 拉原文、`--dump-config` 看组合后的配置树                   |

---

## 目录结构

```
deepseek-harness-skill/
├── SKILL.md                      # 主入口（Agent 首先读到的就是它）
├── README.md                     # 你正在看的
├── references/                   # 5 篇深度参考，按需加载，不用一次读完
│   ├── cordis-core.md            # Context / Fiber / Service / 五种事件分发模式
│   ├── plugin-development.md     # Config、bundle/profile manifest、层序、打包分发
│   ├── tools-and-ui.md           # defineTool 契约、UI 卡片、执行流水线、PTC mode
│   ├── architecture.md           # 事件域、turn/step 流程、"新行为该挂在哪"映射表
│   └── ecosystem.md              # 模型 provider 配置、LLM 适配器、skill 子系统、沙箱
└── scripts/
    ├── fetch_docs.sh             # 抓官方文档全站 Markdown 到本地，供离线检索
    ├── dsh_info.sh               # 查 npm 版本 / 仓库 HEAD / 本地 checkout 状态
    ├── new_plugin.sh             # 生成最小插件骨架（含可直接用的 overlay）
    └── install_global_dsh.sh     # 把源码 checkout 的 dsh 装成全局命令
```

---

## 安装

### 前置条件

| 项                           | 要求                                                    | 说明                                                               |
| --------------------------- | ----------------------------------------------------- | ---------------------------------------------------------------- |
| Agent 工具                    | WorkBuddy / Claude Code / 其它支持 **Agent Skills** 约定的工具 | 即读取 `SKILL.md` + YAML frontmatter 的机制                            |
| `git`                       | 任意版本                                                  | 用「方式二」可不需要                                                       |
| `bash` + `curl` + `python3` | —                                                     | 仅 `scripts/` 下的脚本需要；不跑脚本可以不装                                     |
| dsh 源码 checkout             | **可选，但强烈建议**                                          | 见下方「[使用教程 → 前置](#前置准备一个-dsh-源码-checkout)」。没有它照样能读文档和写代码，只是跑不起来插件 |

> **本仓库只包含 skill 本体，不含 DeepSeek Harness。** 用之前请先准备好一份 dsh 源码检出
> （见 [使用教程 → 前置](#前置准备一个-dsh-源码-checkout)）。没有 checkout 也能读文档、写插件代码，
> 只是跑不起来插件本身。

下面命令里的 `shuaishenlxq` 换成你自己的 GitHub 用户名（fork 或转发给别人时）。

> **如果你想把这个 skill 发布成自己的仓库**：把本目录的**内容**作为仓库根
> （`SKILL.md` 与 `README.md` 同级），仓库名取 `deepseek-harness-skill`，
> 这样上面所有 `git clone` 命令都能直接照抄。
> 复制到新目录后想重新推成仓库，先 `rm -rf .git` 再 `git init -b main`，
> 并且**确认当前目录不在某个上层 git 仓库里** —— `git rev-parse --show-toplevel`
> 输出的必须是你自己这个目录，否则后续 `git add` 会加进那个上层仓库。

### 方式一：git clone（推荐）

**用户级** —— 装一次，所有项目都能用：

```sh
# WorkBuddy
git clone https://github.com/shuaishenlxq/deepseek-harness-skill.git \
  ~/.workbuddy/skills/deepseek-harness-skill

# Claude Code
git clone https://github.com/shuaishenlxq/deepseek-harness-skill.git \
  ~/.claude/skills/deepseek-harness-skill
```

两个工具读取的是同一套 `SKILL.md` + frontmatter 约定，**不需要装两份**。  
想一份维护、两处生效，用软链：

```sh
git clone https://github.com/shuaishenlxq/deepseek-harness-skill.git \
  ~/.workbuddy/skills/deepseek-harness-skill
ln -s ~/.workbuddy/skills/deepseek-harness-skill ~/.claude/skills/deepseek-harness-skill
```

**项目级** —— 只对某个项目生效，适合随项目一起分发给同事：

```sh
cd <your-project>
git clone https://github.com/shuaishenlxq/deepseek-harness-skill.git \
  .workbuddy/skills/deepseek-harness-skill
# 或 .claude/skills/deepseek-harness-skill
```

### 方式二：手动下载（没有 git，或想锁定某个版本）

从 GitHub 页面的 **Code → Download ZIP** 下载后解压到目标目录。  
**注意 GitHub 的 ZIP 会多套一层 `<仓库名>-main/`**，必须把里面的内容提上来 ——  
目标目录要**直接**包含 `SKILL.md`：

```sh
# ✅ 对
~/.workbuddy/skills/deepseek-harness-skill/SKILL.md

# ❌ 错：多套了一层，工具扫不到
~/.workbuddy/skills/deepseek-harness-skill/deepseek-harness-skill-main/SKILL.md
```

### 方式三：从本地已有目录安装（软链 / 复制）

已经在别处 clone 过，或者就是想放在项目仓库里一起管：

```sh
# 软链（改动同步，只维护一份）
ln -s /path/to/your/deepseek-harness-skill \
  ~/.workbuddy/skills/deepseek-harness-skill

# 或直接复制（macOS 上 -R 与 -a 都会保留脚本的执行位）
cp -R /path/to/your/deepseek-harness-skill \
  ~/.workbuddy/skills/deepseek-harness-skill
```

> 如果你是用 Finder 拖拽或某种不保留权限的方式拷的，脚本可能丢掉执行位 ——  
> 补一句 `chmod +x <目标目录>/scripts/*.sh` 即可（用 `bash scripts/xxx.sh` 调用则完全不受影响）。

### 验证装好了

**1. 检查结构** —— 下面三条都应该能列出来：

```sh
ls ~/.workbuddy/skills/deepseek-harness-skill/SKILL.md \
   ~/.workbuddy/skills/deepseek-harness-skill/references \
   ~/.workbuddy/skills/deepseek-harness-skill/scripts
```

**2. 跑一下脚本**（这一步需要联网）：

```sh
bash ~/.workbuddy/skills/deepseek-harness-skill/scripts/dsh_info.sh --npm
```

**3. 重启你的 Agent 工具**（或新开一个会话）—— 大多数工具是在启动时扫描 skills 目录的，  
装完不重启不会生效。

**4. 问一句话，验证它真的被加载了**：

> 用 deepseek-harness-skill 帮我看下 dsh 的插件怎么写。

如果回答里出现 `defineTool`、`inject`、`cordis.yml` 这些具体名词（而不是泛泛而谈），  
就说明加载成功了。

### 升级

```sh
cd ~/.workbuddy/skills/deepseek-harness-skill
git pull

# 顺手把官方文档缓存也刷新一下（上游是开发者预览，API 变化快）
bash scripts/fetch_docs.sh --update
```

### 卸载

```sh
# 删掉 skill 本体
rm -rf ~/.workbuddy/skills/deepseek-harness-skill
# 软链方式的话，删链接即可，源目录不受影响

# 如果之前用教程第 ① 步装过全局 dsh 命令，一并删掉
rm -f ~/.local/bin/dsh
```

> 文档缓存（`~/.cache/dsh-docs`）和 dsh 自己的数据（`~/.dsh`）不在卸载范围内，  
> 想彻底清干净手动删。**`~/.dsh` 里有你的 API 凭据和会话记录，删之前想清楚。**

### 装不上？按这个表排查

| 现象                               | 原因          | 处理                                                                                 |
| -------------------------------- | ----------- | ---------------------------------------------------------------------------------- |
| Agent 完全不提这个 skill               | 目录层级多套了一层   | 确认 `SKILL.md` **直接**在目标目录下                                                         |
| 同上                               | 工具没重启       | 重启客户端或新开会话                                                                         |
| 同上                               | 装错了目录       | 用户级必须是 `~/.workbuddy/skills/` 或 `~/.claude/skills/`，项目级是 `<项目>/.workbuddy/skills/` |
| 脚本报 `Permission denied`          | 拷贝时丢了执行位    | `chmod +x scripts/*.sh`                                                            |
| 脚本报 `command not found: python3` | 缺 python3   | 装一个，或只手动读 `references/`（脚本非必需）                                                     |
| 软链不生效                            | 某些工具不跟随符号链接 | 改用「方式一」直接 clone                                                                    |

---

## 使用教程

### 前置：准备一个 dsh 源码 checkout

开发 dsh 插件需要从源码跑（`--patch` overlay、热重载、类型定义都要它）：

```sh
git clone https://github.com/deepseek-ai/deepseek-harness.git ~/evn/deepseek-harness
cd ~/evn/deepseek-harness
pnpm install
pnpm run build        # 必须先构建，pnpm dsh 直接用构建产物
pnpm run typecheck    # 新克隆后跑一次；成功退出 = 环境搭好了
```

要求：**Node 22.19+ 或 24+**、**pnpm 11.7.0**（经 Corepack，`corepack enable` 即可）、Git 2.26+。

### ① 把 `dsh` 装成全局命令

```sh
bash scripts/install_global_dsh.sh ~/evn/deepseek-harness
dsh --version
```

脚本会探测 checkout 路径、校验 Node 版本范围、检查 PATH 与命令遮蔽，  
并写一个 wrapper 到 `~/.local/bin/dsh`。

> **这里有个必须知道的坑**：wrapper **故意不 `cd`**。  
> dsh 把**你调用时所在的目录**当作默认工作区根 —— 如果 wrapper 里 `cd` 进了 harness 仓库  
> （或者你用了 `pnpm -C <repo> dsh`、`alias dsh='cd <repo> && pnpm dsh'`），  
> 那不管你人在哪个项目里，dsh 打开的工作区都会是 harness 仓库本身。

> wrapper 跑的是**构建产物**。改了 `packages/**` 源码后要 `pnpm run build` 才生效；  
> 边改边用请走仓库里的 `pnpm run dev:web`。

### ② 生成并跑起第一个插件

```sh
bash scripts/new_plugin.sh ~/scratch/hello-plugin hello-plugin
```

生成四个文件：

```
hello-plugin/
├── package.json        # 含 dsh.bundle manifest，可直接作为组合包安装
├── cordis.patch.yml    # bundle 层（按包名引用插件）
├── dev.overlay.yml     # 本地开发用 overlay（按绝对路径引用插件）
└── index.js            # 插件入口
```

启动（脚本已经把绝对路径写进 overlay 了）：

```sh
cd ~/evn/deepseek-harness
pnpm dsh web --patch ~/scratch/hello-plugin/dev.overlay.yml
```

打开 `http://127.0.0.1:3080`，**终端会打印 `[hello-plugin] plugin loaded!`**。

> **⚠️ flag 顺序有坑**：启动器只解析**自己认识**的 flag，遇到第一个不认识的 flag 就把  
> **后面所有参数**原样交给 app。所以要`--patch` 必须写在 `--no-open` / `--port` 这类  
> **app 专属 flag 之前**，否则会被当成 web app 的参数并报 `unknown option '--patch'`：
>
> ```sh
> dsh web --patch <overlay> --no-open --port 3199   # ✅ 对
> dsh web --no-open --port 3199 --patch <overlay>   # ❌ unknown option '--patch'
> dsh --patch <overlay> web                          # ❌ --profile <name> is required
> ```
>
> 想确认 overlay 到底有没有生效，不用启动服务：
>
> ```sh
> dsh --profile web --patch <overlay> --dump-config | grep -A2 'dev.overlay'
> # == /path/to/dev.overlay.yml
> # - id: hello-plugin
> #   name: file:///path/to/hello-plugin/index.js     ← 启动器把路径规范化成 file:// URL
> ```


想用 TypeScript 版加 `--ts`：

```sh
bash scripts/new_plugin.sh ~/scratch/hello-plugin hello-plugin --ts
```

### ③ 加一个模型可调用的工具

编辑 `hello-plugin/index.js`（`--ts` 则是 `src/index.ts`）：


```js
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

重启后（或开热重载）在 Web UI 里输入：

> Use the greet tool to greet Ada.

模型会调用 `greet` 并收到 `Hello, Ada!`。

要理解这里面每个字段为什么这么写（参数校验边界、为什么 `execute` 只能返回规范 JSON 值、  
`render` 和 UI 卡片为什么必须分开、怎么加后台任务和权限钩子），  
读 `references/tools-and-ui.md`。

### ④ 打包安装进 profile

本地 overlay 只是开发态。要真正安装：

```sh
dsh plugin --profile demo add ~/scratch/hello-plugin
dsh --profile demo --dump-config    # 应该能看到 "# == dsh-hello-plugin" 这一层
dsh --profile demo
```

配置层按顺序叠加，**后应用者按行胜出，且 patch 会整段替换目标行的 `config`（不是深合并）**：

1. `dsh.profile.bundles` 列出的各 bundle patch
2. profile 自己的 `cordis.patch.yml`
3. home 级 `$DSH_HOME/cordis.patch.yml`
4. 每个 `--patch <path>` overlay

推论：你的 patch 想覆盖前面某层某行时，**必须重述该行需要的每一个键**。

### ⑤ 查文档 / 排错

```sh
bash scripts/fetch_docs.sh --update                        # 抓全站文档到 ~/.cache/dsh-docs
bash scripts/fetch_docs.sh --grep 'defineTool'             # 在文档里搜关键词
bash scripts/fetch_docs.sh --page reference/subsystems/tools.md   # 打印某页原文
bash scripts/dsh_info.sh                                   # npm 版本 / 仓库 HEAD / 本地状态
```

`dsh --profile web --dump-config` 可以在**不启动**的情况下打印组合后的完整配置树 ——  
排查"我的插件到底有没有被加载、被哪一层覆盖了"最有效。

---

## 脚本速查

| 脚本              | 作用                                                                               | 常用法                                                                    |
| --------------- | -------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| `fetch_docs.sh` | 从 `llms.txt` 抓官方文档全站 Markdown 到 `~/.cache/dsh-docs`（186 页，中英各 93），供离线检索          | `--update` / `--grep <pat>` / `--page <path>` / `--list` / `--lang en` |
| `dsh_info.sh`   | 报告 `@deepseek-ai/dsh` npm 各 dist-tag 与近期发布、相关包版本、仓库 HEAD 与最后 push、本地 checkout 状态 | `--npm` / `--repo`；本地 checkout 用 `DSH_REPO_PATH=...`                   |


| `new_plugin.sh` | 生成最小插件骨架：bundle manifest + bundle patch + 开发 overlay + 插件源码 | `<dir> [name] [--ts]`，已存在 `package.json` 时拒绝覆盖 |
| `install_global_dsh.sh` | 把源码 checkout 的 dsh 装成全局命令（默认 `~/.local/bin/dsh`） | `[repo] [--bin-dir D] [--name N] [--force]` |

**通用前置**：脚本只依赖 `bash` 和系统自带工具（`curl`、`python3`、`grep`、`sed`）。
`fetch_docs.sh` 与 `dsh_info.sh` 需要联网。Windows 请用 Git Bash 或 WSL 执行。

---

## 这个 skill 里最值钱的几条

都是官方文档里写了、但第一遍读绝对会漏的东西：

1. **`--patch` overlay 里的插件路径必须是绝对路径**，且 patch 只贡献配置，不改变 loader 解析模块路径用的 profile 目录。
2. **启动器 flag 必须写在 app flag 之前** —— `dsh web --patch X --no-open` 可以，`dsh web --no-open --patch X` 会报 `unknown option '--patch'`。启动器遇到第一个自己不认识的 flag 就把后面全部透传给 app。
3. **`Config` 不能导出普通对象** —— 必须用 Schemastery，否则不满足 Cordis 要求的 Standard Schema 接口。
4. **`waterfall` 监听器必须调 `next()`**，不调就是**有意短路**整条流水线（用于实现拦截/网关）。这是特性不是 bug。
5. **从 GitHub 安装插件拿到的是源码不是产物** —— 作者要提供自包含的 `prepare` 脚本，用户还得在 `pnpm-workspace.yaml` 里 `allowBuilds` 显式授权（等于允许该包代码在你的机器上执行，不在任何沙箱内），或者改为发 npm 包 / tarball。装插件时会执行安装脚本这件事，很多人根本没意识到。
6. **别在工具实现里内建部署策略** —— 用 `tools/pre-execute`（允许/拒绝/询问）、`ctx.tools.guard()`（单调最终拒绝）、`tools/execute`（超时/重试/指标）、`tools/post-execute`（改内容）、`tools/result`（只观察）这些扩展点。
7. **`ctx` 上做的一切注册都会随插件卸载自动撤销** —— 但多个异步 disposer 是**并发**执行的，有顺序依赖的清理必须放进**同一个** `ctx.effect()` 里串行等待。
8. **运行时不变式：模型可见即已记录。** 想让模型看到新输入，必须落会话事件，不能只改内存。
9. **别预防性拆分能力** —— 只有 Service Definition / Provider / Consumer 三个角色需要独立演进时才拆包；简单工具插件一个包就够。

---

## 它是怎么被触发的

Agent 启动时只会看到每个 skill 的 `name` 和 `description`，**不会**读 body。
当你的提问命中 description 描述的场景（dsh 插件开发、Cordis context/service/events、
`defineTool`、LLM 适配器、profile/bundle、打包安装等），Agent 才会加载 `SKILL.md`，
再按需去读 `references/` 里对应的那一篇。

所以它**不是常驻上下文**，不会白白占用 token；只在真正要做 dsh 相关的事时才展开。
同理，`references/` 分了 5 篇而不是写成一个大文件，就是为了按需加载。

---

## 版本基线与新鲜度

| | |
|---|---|
| 构建基线 | `@deepseek-ai/dsh@0.2.0-rc.2`（2026-09-29 发布） |
| 脚本实测版本 | `0.2.1-alpha.1`（2026-10-03），checkout 于 `5badb150` |
| 文档来源 | `https://deepseek-harness.github.io/deepseek-harness/llms.txt` |
| 端到端实测范围 | 教程 ①②③⑤ + 全部 4 个脚本；④ 来自官方文档未逐条实跑（会往 `~/.dsh` 里新建 profile） |

DeepSeek Harness 明确标注**开发者预览，会有破坏兼容性变更**。所以这个 skill 的立场是
**"不知道就联网查"** 而不是"凭记忆答"：

```sh
bash scripts/dsh_info.sh              # 先看目标环境到底是什么版本
bash scripts/fetch_docs.sh --update   # 再把最新文档拉到本地
```

> 如果你发现 skill 里的 API 和实际不符，八成是上游改了 —— 先跑上面两条命令确认，
> 然后按 `references/` 对应的那篇更新。欢迎提 PR。

---

## 免责与许可

- 本项目是**非官方**的社区作品，与 DeepSeek AI 无隶属关系。
- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 本身以 **MIT** 许可开源；
  本 skill 内的代码片段与文档转述均来自该项目及其官方文档。
- 本仓库以 **Apache-2.0** 许可发布，详见 [LICENSE](LICENSE)。
