## Purpose

为注册的本地 Git 项目提供可验证的 worktree 发现和生命周期管理，使用户能创建隔离工作目录并安全移除不再使用的目录，同时保护主工作目录、未提交内容和运行会话。

## ADDED Requirements

### Requirement: Discover and refresh worktrees
应用 SHALL 从 Git 获取真实 worktree 列表，显示路径、分支或 detached 标识、主工作目录标识以及锁定或不可用状态，并支持手动刷新及重新激活应用时刷新。

#### Scenario: External worktree change
- **WHEN** 外部命令新增或移除 worktree 后用户刷新
- **THEN** 左侧与 Git 结果一致；消失目录的关联会话显示目录不可用且不能重新启动，运行会话不被转移到其他目录

### Requirement: Create worktree
应用 SHALL 支持选择目标路径并从未被其他 worktree 使用的已有本地分支创建 worktree，或从有效本地起点创建新分支及 worktree；MUST 不覆盖已有目录内容且 MUST 不隐式 fetch。

#### Scenario: Create from existing branch
- **WHEN** 用户提交可用本地分支及不存在的目标目录
- **THEN** 创建成功后刷新列表并选中新 worktree，不自动启动 CLI

#### Scenario: Create a new branch
- **WHEN** 用户提交有效的新分支名、本地起点和目标路径
- **THEN** 新分支及关联 worktree 创建成功并出现在列表中

#### Scenario: Creation rejected
- **WHEN** 分支被占用、名称无效、路径已存在、起点无效或 Git 执行失败
- **THEN** 显示失败原因，不展示虚假的成功节点；重新读取 Git 状态并明确报告可能残留的分支或目录，不自动删除用户文件

### Requirement: Protect worktree removal
应用 SHALL 只允许移除非主、未锁定、目录可访问且没有已跟踪或未跟踪改动的 worktree；存在关联运行会话时 MUST 要求先停止；MUST 在显示完整路径的确认后使用 Git 正常移除，MUST 不提供强制删除且 MUST 保留分支。

#### Scenario: Remove clean worktree
- **WHEN** 用户确认移除无运行会话的干净关联 worktree
- **THEN** 成功移除该 worktree 后刷新列表，清除对应选择和会话记录，保留 Git 分支

#### Scenario: Unsafe removal
- **WHEN** 目标为主工作目录、已锁定、不可访问、有未提交或未跟踪内容，或含运行会话
- **THEN** 阻止删除并说明处理方式，不修改目录

#### Scenario: State changes before removal
- **WHEN** 检查通过后 Git 拒绝移除或用户取消确认
- **THEN** 保留节点及目录，显示 Git 错误或保持原状态，不改用强制移除

### Requirement: Nonblocking Git operations
应用 SHALL 在 Git 操作期间保持界面可交互，同一仓库 MUST 串行执行创建和删除，操作失败 MUST 提供错误与重试入口；Git 不可用时 MUST 不伪造仓库状态。

#### Scenario: Concurrent requests
- **WHEN** 某仓库创建操作未完成时用户再次请求修改该仓库
- **THEN** 后续修改被禁用或排队，其他项目仍可导航，完成后重新刷新真实状态
