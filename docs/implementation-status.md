# 实施与验收状态

变更 `add-native-worktree-workspace`，2026-10-12。实现可构建并已安装到 `/Applications/CodeElevator.app`；OpenSpec 18/20 项完成，尚未归档。Computer Use 访问和锁屏阻塞均已解除，测试由代理执行。

## 构建与自动测试

- 本机 macOS 27.0.1、Apple Silicon、Xcode 27.0；部署基线 macOS 14。
- SwiftTerm 固定 1.20.0，依赖锁定文件位于 Xcode workspace 的 `xcshareddata/swiftpm/Package.resolved`。
- 最新 Debug 测试报告：23 passed、0 failed、0 skipped（14 CoreTests、9 SessionTests）。报告为 `.build/DerivedData/Logs/Test/Test-CodeElevator-2026.10.12_20-40-18-+0800.xcresult`。
- 最新 Release 构建成功，`lipo -info` 确认 x86_64 和 arm64。Intel 及 macOS 14 尚无实机结果。

测试命令：

```sh
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test -project CodeElevator.xcodeproj -scheme CodeElevator -derivedDataPath .build/DerivedData -skipPackagePluginValidation -disableAutomaticPackageResolution -destination platform=macOS,arch=arm64 -quiet
```

覆盖真实 Git 注册与去重、bare 拒绝、创建/删除与保护、分支保留、修改串行、命令超时取消、配置恢复、独立 PTY、后台输出、缓冲区上限、中文提交、尺寸与键盘、退出和重启、进程组回收、项目移除与应用退出协调。新增测试覆盖工具选择模型、IME marked-text 提交边界以及中文选择复制；复制测试恢复原剪贴板。

## 原生窗口验证

通过 Computer Use 操作已安装的 Release 应用，使用 `.build/ui-fixtures/` 中的独立测试仓库，没有使用用户业务仓库。

- 空工作区、原生目录选择、两个项目登记、项目折叠/展开、侧栏宽度 260→340、选中分支与屏幕上完整目录一致。
- 新分支 worktree 创建、自动选中；已存在目录报错在表单内显示，改为新目录后重试成功。
- worktree 右键菜单、删除确认完整路径、取消后节点仍在；运行中的会话阻止删除；正常移除后节点消失并由 Git 确认分支保留。
- Codex 0.162.1 与 kscc 1.3.7 同时运行在不同项目/worktree；两者通过中文粘贴提交均回复“测试通过”，切换返回保留会话与后台结果。
- Codex Ctrl-C 清空输入；kscc Ctrl-C 显示退出提示，`/exit` 后显示退出码 0 和重新启动入口；停止按钮能够清理会话。
- 原生窗口缩放及侧栏调整后 CLI 重新排版；退出应用时显示会话清单，取消保留会话，确认后停止退出；重启恢复项目选择但不自动启动 CLI。
- Codex/kscc 的测试目录信任提示可显示和操作，仅接受代理创建的测试目录。未批准模型执行工具。
- 已清理应用中的测试项目登记，测试目录与分支留在被忽略的 `.build/` 中；应用空工作区，无运行测试会话。

修复了终端文字对比度、空状态标题布局、终端初始聚焦和可访问性、项目菜单覆盖 worktree 菜单、创建表单错误被父层提示遮住等问题。

工具选择由工作区模型持有，并有回归测试。原弹出菜单在连续选择并启动时存在时序问题，现改为原生分段 Picker。最新 Release 已构建并更新到 `/Applications/CodeElevator.app`；通过 Computer Use 在单次调用中连续点击 Claude→启动、Codex→重新启动，分别正确启动 kscc 和 Codex，新会话不保留旧缓冲区。

## 尚缺端到端证据

OpenSpec 1.3 和 5.2 保留未完成。此次新增真实 CLI 验收证据：

- Codex 为只读 `pwd` 发起明确权限请求，终端显示原生三选项审批及请求原因，等待期间没有自动批准；按 Esc 后显示取消及无输出。
- kscc 对仅打印标记的 Python 命令显示原生审批，按 Esc 后显示 Interrupted，没有打印测试标记。两个 CLI 的常规 `pwd` 由自身策略直接执行，不能把这种情况当作审批提示。
- 仅对已确认父进程为本次 CodeElevator 的 kscc PID 21556 注入 SIGKILL，窗口显示退出码 137 和重新启动入口；逐一检查该进程及其已识别子进程均不再存在。没有按名称结束其他 CLI。
- XCTest 原生 UI 测试已验证真实 Codex 与 kscc：粘贴已知中文字符串、Shift 拖选、Cmd-C 复制、Ctrl-A/Ctrl-K 清空、Cmd-V 回显。断言完整字符串一致，没有提交给模型；临时配置和原剪贴板在测试后恢复。通过报告 `.build/DerivedData/Logs/Test/Test-CodeElevator-UI-2026.10.12_20-47-42-+0800.xcresult`（2 tests、0 failures）。
- 修复原生复制快捷键被 CLI 键盘路径吞掉、SwiftTerm 在首次拖动才设起点导致漏字的问题；保留 Shift 扩展已有选区。增加 Debug 隔离 UI 测试配置及主屏测试窗口定位，Release 忽略测试配置。
- 用户已明确授权当前剪贴板本地回显、临时输入源切换与恢复、XCTest UI 自动化；没有仍待回复的授权请求。

剩余明确边界：

1. 系统 IME 的稳定端到端验收尚未完成。此前 Computer Use 在 Codex 观察到带下划线拼音组合文本，并用 Space 提交中文，但候选窗口未捕获；此次 XCTest 和 kscc 的 Computer Use 按键路径仅产生英文，不能宣称两种真实 CLI 的系统拼音输入均通过。失败的 IME 探针未纳入常规测试套件，诊断报告保留于 `.build/DerivedData/Logs/Test/`。
2. 每次临时输入源切换均执行恢复，最后恢复标识为 `com.apple.keylayout.ABC`，原始快照文件已移除。XCTest 的输入源上下文与前台应用切换关系仍需排查，未修改输入法列表或用户的键盘快捷键。
3. 复制粘贴的较早失败报告仍保留，不以单次成功掩盖失败；最终通过的两种真实 CLI 测试使用 macOS 鼠标 API，并修复实际拖选起点。

测试登记与运行会话已清理，无需用户手动测试。OpenSpec 1.3、5.2 因系统 IME 未稳定验收保持未完成，其余真实 CLI 对话、审批、Ctrl-C、缩放、异常退出和应用退出已有证据。最新双架构 Release 已安装到 `/Applications/CodeElevator.app`。

普通 Claude `/Users/liuweizheng/.local/bin/claude --version` 退出 137，未修改其安装；按用户指定使用 `/opt/homebrew/bin/kscc` 并在应用 Claude 路径设置中保存。Codex 路径 `/opt/homebrew/bin/codex`。

## 终端选型边界

SwiftTerm 提供 AppKit、本地 forkpty、cwd、PID 与尺寸接口，当前已完成真实 CLI 对话验证。Ghostty 嵌入接口源码调研不等于运行对照；尚未执行 Ghostty 样例或性能比较，不宣称 SwiftTerm 性能最优。构建与使用说明见 README.md。

## 项目改名

项目、源码目录、Xcode 工程、scheme 与应用名称改为 Codevator；主应用 bundle identifier `dev.codeelevator.CodeElevator` 和原配置目录保持兼容。早期报告中的 CodeElevator 为当时名称。

Codevator 改名回归：23 tests、0 failures，报告 `.build/CodevatorDerivedData/Logs/Test/Test-Codevator-2026.10.12_21-41-43-+0800.xcresult`。GitHub 仓库：https://github.com/LaughingVzr/Codevator （记录当时为私有）。
