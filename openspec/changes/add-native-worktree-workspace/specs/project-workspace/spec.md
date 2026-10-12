## Purpose

提供 Mac 原生的多项目导航工作空间，使用户能在一个窗口中明确选择项目及工作目录，并在应用重新启动后恢复项目组织和有效的选择，减少跨项目编程时的上下文混淆。

## ADDED Requirements

### Requirement: Native workspace navigation
应用 SHALL 在 macOS 14 及以上提供可调整宽度的原生分栏窗口，左侧按项目分组展示 worktree，右侧展示当前 worktree 的会话区域及项目名、分支或 detached 标识和完整路径。

#### Scenario: Select a worktree
- **WHEN** 用户选择某项目下的 worktree
- **THEN** 右侧显示该 worktree 的会话区域和目录信息，选择其他节点不会将原会话改到新目录

#### Scenario: Empty workspace
- **WHEN** 尚未添加项目或未选择 worktree
- **THEN** 显示添加项目或选择 worktree 的明确入口，且不自动启动 CLI

### Requirement: Register local Git projects
应用 SHALL 允许选择已有非 bare Git 仓库目录或其子目录，归一化到仓库身份，同一仓库的不同 worktree MUST 不重复注册；无效目录 MUST 显示可操作错误。

#### Scenario: Add an existing repository
- **WHEN** 用户选择有效仓库目录
- **THEN** 左侧新增项目并展示其主工作目录和已存在的关联 worktree

#### Scenario: Duplicate or invalid directory
- **WHEN** 用户选择已注册仓库的关联 worktree、非 Git 目录或 bare 仓库
- **THEN** 对重复仓库定位到已有项目，对不支持的目录显示原因，不新增项目

### Requirement: Persist workspace configuration
应用 SHALL 保存项目记录、展开状态、最后选择以及 CLI 可执行路径配置；重新启动 MUST 验证路径，MUST 不自动启动原会话，也 MUST 不保存终端对话或 CLI 凭据。

#### Scenario: Restore valid selection
- **WHEN** 应用重新启动且最后选择目录仍有效
- **THEN** 恢复项目树和该目录选择，终端处于未启动状态

#### Scenario: Repository becomes unavailable
- **WHEN** 已记录仓库无法访问或配置文件损坏
- **THEN** 显示可恢复错误而不崩溃，不将无法验证的目录作为 CLI 启动目录，不静默覆盖损坏配置

### Requirement: Remove project registration
应用 SHALL 支持移除项目记录且 MUST 不删除仓库、worktree 目录或分支；存在运行会话时 MUST 在用户明确确认停止这些会话后才移除记录。

#### Scenario: Remove with running sessions
- **WHEN** 用户移除含运行会话的项目
- **THEN** 列出将停止的会话，取消保留全部状态，确认后停止会话并移除项目记录而保留磁盘文件
