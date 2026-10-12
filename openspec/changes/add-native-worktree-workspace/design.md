## Context

仓库目前只有 OpenSpec 配置，尚无应用工程。动机见 proposal.md，行为契约见三个 capability 的 spec.md。首版规划 macOS 14+，Apple Silicon / Intel，单工作空间窗口；Git 和 CLI 均由用户安装。应用需要访问仓库、启动用户 CLI 及其子进程，因此采用非沙盒桌面应用基线，分发与公证另行规划。

## Goals / Non-Goals

**Goals:**
- 将项目配置、Git 状态和运行会话分层，避免导航视图销毁导致进程丢失。
- 复用成熟终端模拟器，保持 CLI 原生交互；Git 操作和终端输出不阻塞主线程。
- 明确仓库身份、目录身份与进程生命周期，支持真实 Git 集成测试和可替换的 CLI 测试进程。

**Non-Goals:**
- 不解析 AI 消息协议，不依赖 Codex 或 Claude 私有输出格式。
- 不提供任意自定义 shell 命令编辑器，不持久化终端内容，不恢复 CLI 内部会话。
- 不通过嵌入 Terminal.app / iTerm2 窗口实现界面，也不引入浏览器壳。

## Decisions

### 1. SwiftUI shell + AppKit terminal

以 Xcode macOS app 工程承载 SwiftUI，使用 NavigationSplitView 构建项目树和详情区，终端经 NSViewRepresentable 承载。采用 Swift Package Manager 引入 SwiftTerm 并锁定经过验证的发布版本。SwiftTerm 官方说明提供 AppKit 前端和本地进程支持，是本设计选择的依据：[SwiftTerm 官方仓库](https://github.com/migueldeicaza/SwiftTerm)。

不自行编写 ANSI 解析器，避免终端兼容性成本；不采用 xterm.js + WKWebView，减少原生应用的 Web 桥接层。当前实现锁定 SwiftTerm 1.20.0，已验证 PTY 输入、尺寸、生命周期及真实 Codex / kscc 的初始终端输出。完整窗口体验验收和 Ghostty 运行对照尚未完成；这是当前实现选择，不是性能最优结论。使用与锁定版本对应的文档，不直接追随 main 分支。

### 2. Separate durable state from live sessions

工作空间模型保存 ProjectID、展示名、canonical Git common directory、可用 Git 操作目录和展开状态。通过 Git 返回的 common directory 规范化路径，识别同仓库的不同 worktree。WorktreeID 由 ProjectID 与规范化 worktree 路径组成，主目录、分支、detached、locked 等为可刷新状态；目录重建不复用已经失效的会话。

SessionManager 长期拥有终端实例与进程句柄，按 WorktreeID 索引，生命周期独立于详情视图。首版每个 worktree 一个会话，工具切换必须先停止；重新启动创建新终端并清空本次缓冲区。后台终端仍接收输出，配置有限滚动缓冲区以控制内存。SwiftUI 只挂载选中会话视图，不在 selection 变化时启动或结束进程。

替代方案是在每个详情视图内部管理进程，这会受视图重建影响，因此不采用。多标签多会话可以之后扩展，不纳入首版。

### 3. Git is authoritative

GitService 在后台执行参数数组形式的 Git 子进程，禁止拼接用户输入为 shell 命令。查询使用机器可解析的 worktree porcelain 输出及 NUL 分隔路径；状态检查包含未跟踪文件，目录和分支参数显式校验。解析支持空格、Unicode 路径、detached、locked 和失效节点。

创建支持已有本地分支以及新分支/本地起点，拒绝已存在目标路径；失败后重读状态并提示残留，不擅自回滚删除。移除只使用正常 Git worktree remove，不使用 force，不删分支。预检不能替代 Git 最终检查；确认后再次检查会话和目录状态，并在同一仓库操作队列中执行。Git 超时或不可用有明确错误与取消/重试行为。

不用文件夹扫描推断 worktree，不用直接删除目录代替 Git，避免 Git 元数据不一致。同仓库写操作串行；刷新请求带版本标记，过期响应不能覆盖新状态。应用重新激活及手动操作触发刷新，不在首版引入持续文件系统监听。

### 4. Launch installed CLIs in a PTY

Provider 描述包含稳定工具 ID、显示名、默认可执行名称（codex / claude）和可选绝对路径。两者使用默认交互入口，不设置私有参数，不自动放宽权限。先检测覆盖路径，再从用户登录环境 PATH 解析。登录环境探测有超时、捕获输出与缓存，失败时提示手动指定路径；CLI 所需 node 等依赖沿用该环境，不能只找到脚本路径而丢失 PATH。

PTY 会话从所选目录启动可执行文件，设置正确工作目录与终端环境，双向传输字节，尺寸变化传递给 PTY。优先使用锁定版本 SwiftTerm 的本地进程能力，SessionManager 封装其启动、退出和清理；若该版本接口不足，在同一适配层补充 PTY/进程组管理，不改变终端架构。中文输入、复制粘贴、Ctrl-C 和 CLI TUI 审批都在原终端流程中处理。

不通过已安装终端 App 打开外部窗口，因为无法提供右侧内嵌及统一会话生命周期。不用 stdout/stderr 文本框代替 PTY，因为它无法完整承载交互式 CLI。

### 5. Explicit shutdown and failure boundaries

状态机为 idle → starting → running → exited / failed；stop 在 starting 或 running 中标记停止进行中，阻止重复动作。Ctrl-C 属于终端输入，与停止整个会话区分。停止先向会话所属进程组发送终止信号，有限等待后升级终止并回收 PTY 与进程资源，不按名称杀掉其他 CLI。已退出输出在本次应用运行内保留；新启动重置终端。

退出应用或移除含运行会话的项目，统一由会话协调器确认并停止会话。删除 worktree 必须先显式停止对应会话。外部删除目录使节点不可用，已有会话不会被自动改到其他目录；用户仍能停止它。首版不管理 CLI 主动脱离会话进程组的后台服务。

### 6. Local configuration only

产品现名为 Codevator；为兼容原设置，仍在 Application Support/CodeElevator 保存带 schemaVersion 的 JSON，包含项目、展开与选择状态、CLI 路径覆盖。使用原子写入，不序列化终端、进程对象或环境变量；损坏文件保留并提示用户重置或重新导入。启动后重新读取 Git，而不是把缓存的 worktree 当事实。相比数据库，JSON 足以处理首版小规模配置，并降低迁移复杂度。

## Risks / Trade-offs

- [CLI TUI 或中文输入存在兼容问题] → 先做真实 Codex / Claude 嵌入验证，覆盖审批、窗口缩放、中文组合输入；记录工具和依赖版本。
- [GUI 启动环境与用户 shell 不一致] → 有界登录环境检测加可执行路径覆盖，显示具体启动错误而不隐式安装工具。
- [停止会话遗漏子进程] → 测试进程组归属及子进程回收，生命周期逻辑封装于适配层；脱离进程组的服务列为限制。
- [后台终端数量造成内存增长] → 有界滚动缓冲区，释放被移除会话；验证多个并行 worktree 会话及大输出。
- [Git 检查和实际操作之间存在竞态] → 再检查、仓库写操作串行、依赖 Git 最终拒绝，不使用强制删除。
- [首版非沙盒限制分发方式] → 以本地构建验证为交付标准，后续独立设计签名、公证及分发。

## Migration Plan

这是新应用，没有旧数据迁移。先建立可运行工程及终端适配验证，再完成项目注册、Git 生命周期、会话及持久化，最后执行集成和人工验收。配置从 schemaVersion 1 开始；未来不识别版本时保留原文件并报告错误。回退应用版本不修改仓库内容；卸载或重置配置不会自动清理用户 worktree。
