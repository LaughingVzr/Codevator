## Purpose

在每个 worktree 中提供独立的交互式 CLI 编程环境，让用户直接使用本机 Codex 或 Claude 的原有终端交互，并在项目导航中保留进程与输出，同时明确会话状态和退出边界。

## ADDED Requirements

### Requirement: Resolve installed CLI tools
应用 SHALL 提供 Codex 和 Claude 入口，从用户登录环境的 PATH 查找可执行文件并允许覆盖绝对可执行路径；MUST 不自行安装 CLI、处理账户登录或保存凭据。

#### Scenario: Missing executable
- **WHEN** 所选工具找不到或配置路径不可执行
- **THEN** 显示缺失或路径错误，提供路径设置和重新检测入口，不创建运行会话

### Requirement: Start an isolated terminal session
应用 SHALL 仅在用户主动启动时创建交互式终端，工作目录 MUST 为所选有效 worktree；首版每个 worktree 同时最多一个 CLI 会话，工具选择 MUST 不替换正在运行的会话。

#### Scenario: Start Codex or Claude
- **WHEN** 用户在有效 worktree 中选择可用 CLI 并启动
- **THEN** 在该目录启动所选 CLI，显示对应工具及运行状态，输入只发送到该会话

#### Scenario: Start while already running
- **WHEN** worktree 已有运行会话且用户重复启动或选择另一工具
- **THEN** 聚焦已有会话，切换工具需要先停止原会话，不创建重复进程

### Requirement: Preserve native terminal interaction
终端 SHALL 支持 CLI 的 ANSI 输出、交互输入、方向键、Ctrl-C、中文输入、文本选择复制、粘贴、滚动和窗口尺寸变化；CLI 的授权与审批 MUST 通过其原生终端流程完成，应用 MUST 不自动确认。

#### Scenario: Interactive input and resize
- **WHEN** 用户输入中文、使用方向键或调整终端尺寸
- **THEN** CLI 收到正确输入和终端尺寸，输出保持可读且无原始控制序列文本

#### Scenario: CLI approval prompt
- **WHEN** CLI 请求用户确认工具执行
- **THEN** 在终端呈现原有提示并等待用户输入，不由应用自动批准

### Requirement: Preserve sessions across navigation
应用 SHALL 在切换项目或 worktree 时保留运行进程、终端缓冲区和会话状态，且后台会话 MUST 继续接收输出；不同 worktree 的输入与输出 MUST 不混合。

#### Scenario: Switch away and back
- **WHEN** worktree A 的 CLI 运行时用户转到 B 再回到 A
- **THEN** A 的进程未重启、内容及后台新增输出可见，B 会话保持独立

### Requirement: Session lifecycle and shutdown
应用 SHALL 显示未启动、启动中、运行中、已退出和失败状态；退出 MUST 显示可获得的退出码及保留本次输出，停止 MUST 清理所属进程与终端资源，重新启动 MUST 创建新会话。退出应用时存在运行会话 MUST 提示确认停止；取消 MUST 保持运行。

#### Scenario: Stop or restart
- **WHEN** 用户停止会话并再次启动
- **THEN** 原会话所属进程及资源释放，新会话在原 worktree 中启动，不复用失效进程

#### Scenario: Unexpected exit
- **WHEN** CLI 启动失败或运行期间退出
- **THEN** 显示失败原因或退出状态，保留已收到的输出，并允许用户重新启动

#### Scenario: Quit application
- **WHEN** 用户确认退出含运行会话的应用
- **THEN** 停止全部所属会话后退出，下次启动仅恢复工作空间配置，不恢复进程或终端历史
