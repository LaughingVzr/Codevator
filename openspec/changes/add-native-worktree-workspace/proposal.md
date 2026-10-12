## Why

在多个 Git 项目和 worktree 间编程时，需要反复切换目录、终端和 AI CLI，容易混淆会话所属的工作目录。建立 Mac 原生工作空间，将项目树、worktree 生命周期和独立 CLI 会话集中管理。

## What Changes

- 新建 macOS 原生应用，左侧展示项目及其 worktree，右侧展示当前 worktree 的交互式终端。
- 支持添加已有本地 Git 项目、移除项目记录、刷新 worktree 和恢复项目列表及选择状态。
- 支持基于已有本地分支或新分支创建 worktree，以及带检查和确认的删除操作。
- 支持启动本机已安装的 Codex、Claude CLI；每个 worktree 可拥有独立会话，切换选择时保留运行中的进程和终端内容。
- 展示 CLI 缺失、运行、退出和失败状态，提供停止与重新启动入口。
- 首版不包含统一聊天消息解析、内置编辑器、云端同步、CLI 安装登录、远程仓库克隆或跨应用重启的进程恢复。

## Capabilities

### New Capabilities
- `project-workspace`: 原生分栏界面、项目注册、导航及本地状态恢复。
- `worktree-management`: Git worktree 发现、创建、删除及错误反馈。
- `cli-terminal-sessions`: 按 worktree 隔离的 Codex / Claude 交互式终端与进程生命周期。

### Modified Capabilities

无，当前仓库尚无已有规格。

## Impact

- 从空仓库建立 Swift / SwiftUI macOS 应用，使用 AppKit 承载终端视图。
- 引入 Git 子进程服务、PTY 会话服务和本地配置存储；终端依赖的具体版本在实施时验证并锁定。
- 依赖用户本机 Git 和所选 CLI，不接入托管模型 API，不保存 CLI 凭据。
- 首版以 macOS 14+、Apple Silicon 和 Intel 为规划基线，采用非 App Store 分发；签名、公证和发布不在本变更范围。
