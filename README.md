# Codevator

macOS 原生的多 Git 项目、worktree 与 CLI 编程会话管理工具。左侧管理项目及工作目录，右侧通过 SwiftTerm 嵌入本机 Codex / Claude 交互式终端。

目前是开发版本。自动化验证与仍待完成的窗口验收见 [docs/implementation-status.md](docs/implementation-status.md)。

## 构建与运行

需要 macOS 14+、完整 Xcode（含命令行工具及 MetalToolchain）、Git。依赖已通过 SPM 固定在工程和 Package.resolved 中，首轮构建需要联网。

用 Xcode 打开 `Codevator.xcodeproj`，选择 **Codevator → My Mac → Run**。也可在仓库目录运行：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project Codevator.xcodeproj -scheme Codevator \
  -derivedDataPath .build/DerivedData -skipPackagePluginValidation build
open .build/DerivedData/Build/Products/Debug/Codevator.app
```

若提示缺少 Metal 编译器，执行 `xcodebuild -downloadComponent MetalToolchain`。需先由用户接受 Xcode 许可及完成首次启动准备。本工程不改变全局 xcode-select 配置。

测试与通用 Release 构建：

```sh
xcodebuild -project Codevator.xcodeproj -scheme Codevator \
  -derivedDataPath .build/DerivedData -skipPackagePluginValidation test
xcodebuild -project Codevator.xcodeproj -scheme Codevator \
  -derivedDataPath .build/DerivedData -skipPackagePluginValidation \
  -configuration Release ONLY_ACTIVE_ARCH=NO build
```

同一个 derivedDataPath 的构建、测试需顺序执行。Release 输出支持 arm64 与 x86_64；Intel 实机运行尚未验证。当前禁用分发签名和沙盒，签名、公证及发布另行规划。

## 使用

1. 点击左上方 **+** 或按 ⌘O，选择已有本地 Git 项目。关联 worktree 属于同一个项目；bare 仓库暂不支持。
2. 在左侧项目名称上右键，选择 **创建 worktree…**。选择已有本地分支，或输入新分支名与本地起点，并指定尚不存在的绝对目录路径。
3. 选中 worktree，在右侧选择 Codex 或 Claude，再点击 **启动**。CLI 必须已安装，账户登录由 CLI 自身处理。
4. 在 **Codevator → Settings…** 中可指定 CLI 绝对路径并重新检测。此环境验证 Claude 使用 `/opt/homebrew/bin/kscc`，请将它填入 Claude 路径；普通安装可留空自动检测 `claude`。
5. 切换项目和 worktree 保留原进程及终端内容。每个 worktree 同时一个会话；切换工具前先停止。
6. CLI 开启鼠标模式时，可按住 Shift 选择终端文字；终端右键菜单提供复制和粘贴。
7. 删除 worktree 使用右键菜单，仅允许删除非主、未锁定、干净且无运行会话的目录，分支保留。移除项目记录不会删除磁盘内容。

Git 错误提供刷新/重试。若目录被外部移除，关联会话仍可查看和停止，但不能在失效目录重新启动。退出应用时提示停止运行会话，取消会保留会话。

## 状态与边界

- 项目列表、展开状态、选择与 CLI 路径保存于 `~/Library/Application Support/CodeElevator/workspace.json`，schemaVersion 为 1。改名后继续沿用旧配置目录以兼容已有设置。
- 配置损坏时保留原文件，暂停保存；“备份并重置配置”会将原文件改名备份。
- 重启应用恢复工作空间配置，不自动恢复 CLI 进程或终端历史，不保存 CLI 凭据。
- 终端提供有限的 5000 行滚动缓冲区，交互及审批沿用 CLI 原生流程，不自动确认权限。
- 应用停止所属 PTY 进程组；CLI 主动脱离进程组的后台服务不在首版生命周期管理范围内。

## 依赖与工程

终端使用 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) **1.20.0**（MIT），锁定提交 `5d14406844143538cd8f8851d2d8a67c1fe443e5`。我们采用它的 AppKit 视图与 PTY 接入能力，不需要安装终端 App。源码接口评估与实际启动测试不代表已证明其性能优于 Ghostty；完整对照及窗口体验验收仍待完成。

`Codevator/Core.swift` 提供 Git、配置与 CLI 环境服务；`Sessions.swift` 管理终端和进程；`Workspace.swift` 协调状态与确认；`App.swift` 为 SwiftUI 界面。测试使用临时 Git 仓库和测试进程，不修改用户仓库。真实 CLI 启动 smoke test 会在临时目录启动本机 Codex 与 kscc，仅观察初始输出，不接受信任提示或发送模型请求；未安装对应工具时报告 skipped。

工程文件已生成，无需安装生成器。调整文件布局后如需重新生成，可安装 Ruby `xcodeproj` gem 并运行 `Scripts/generate-project.rb`；此脚本会覆盖工程和共享 scheme，手工设置需同步到脚本。

## 原生 UI 自动化

`Codevator-UI` 是独立的 XCTest UI scheme，使用 Debug 专用的临时配置文件，避免修改正常工作区配置。测试需要本机 Codex、kscc 以及 `.build/ui-fixtures/Project-A` 隔离仓库；只输入、选择和粘贴测试文本，不提交模型请求，并恢复测试前的剪贴板。首次运行可能需要允许 Xcode 的 UI 自动化。

```sh
xcodebuild test -project Codevator.xcodeproj -scheme Codevator-UI \
  -derivedDataPath .build/DerivedData -skipPackagePluginValidation \
  -disableAutomaticPackageResolution -destination platform=macOS,arch=arm64
```

运行结果和仍待验收项见 `docs/implementation-status.md`。
