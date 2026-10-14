<p align="center">
  <img src="Codevator/Assets.xcassets/AppIcon.appiconset/icon-512@2x.png" alt="Codevator 应用图标" width="144" />
</p>

<h1 align="center">Codevator</h1>

<p align="center">在一个 Mac 应用里管理项目、worktree 和编程对话。</p>

<p align="center"><a href="README.md">English</a></p>

Codevator 让不同的编程任务各有自己的位置。左侧放本机 Git 项目和 worktree；选中一个 worktree，就可以在右侧打开 Codex、Claude Code 或普通终端。临时切到别的项目时，已经打开的标签会继续运行。

<p align="center">
  <img src="docs/screenshots/codevator-ocean.png" alt="Codevator 中的项目、worktree 和 Codex 对话" width="960" />
</p>

## 可以用它做什么

- **在项目之间切换，不用重新找工作现场。** 侧边栏列出项目及其 worktree。你可以把 worktree 理解为同一 Git 项目的另一个工作文件夹：在别的分支上工作时，不会打乱主目录。
- **为每项任务开独立标签。** 在选中的 worktree 中启动 Codex、Claude Code 或普通终端。同一个 worktree 也能同时打开多个标签，稍后再切回来。
- **看清哪些对话还需要关注。** 在 Codex 和 Claude Code 标签中，绿色提示表示发出的提问正在等待回复；橙色提示表示回复已经完成、但你还没查看。两种提示可以同时出现在同一个 worktree 或项目旁。允许通知后，后台回复完成时还可以收到 macOS 提醒。
- **直接从侧边栏创建 worktree。** 可以选择已有的本地分支，也可以创建新分支。应用会推荐文件夹名称，创建前仍可自行修改。

## 开始使用

需要 macOS 14 或更新版本，以及 Git。只用普通终端时，不需要安装 AI 工具；如果要使用 Codex 或 Claude Code，请先在 Mac 上安装对应的命令行工具，并通过工具本身登录。

1. 从[发布页面](https://github.com/LaughingVzr/Codevator/releases)下载磁盘映像，打开后把 Codevator 拖入「应用程序」。应用目前没有签名，也未经过 Apple 公证，首次打开时 macOS 可能要求你确认。
2. 点击侧边栏的 **+**，或按 **⌘O**，选择本机已有的 Git 项目。
3. 选中一个 worktree，点击 **Codex**、**Claude** 或 **终端** 打开标签。也可以先开空白标签，之后再选要运行的工具。

要再建一个 worktree，右键点击侧边栏里的项目，选择 **创建 worktree**。窗口默认使用已有本地分支；需要新分支时，再打开 **创建新分支**。

Codevator 会在本机查找 `codex` 和 `claude`。如果工具安装在其他位置，可以到 **Codevator → 设置 → 编程工具** 填写路径。普通终端会使用 Mac 上的 shell。

这份 README 介绍的是当前源码。下载版发布之后新增的功能，可能要等下一次发布才能用上。发布包面向 Apple 芯片和 Intel Mac 构建；目前尚未在 Intel 实机上完成测试。

## 使用前了解一下

- 切换项目或标签不会停止会话。关闭正在运行的标签，或有会话运行时退出应用，Codevator 会先询问你。
- 再次打开应用时，项目和选中的 worktree 仍在；正在运行的会话和终端历史暂时不会恢复。
- 只有非主 worktree、没有运行会话，也没有尚未提交到 Git 的改动或新文件时，才能在应用中移除。从侧边栏移除项目不会删除磁盘上的文件；确认后，它会停止该项目仍在运行的会话。
- Codex 和 Claude Code 仍由各自的工具处理登录和命令授权；Codevator 不会替你批准命令。

<details>
<summary>从源码构建与测试</summary>

安装 Xcode 后，打开 `Codevator.xcodeproj`，选择 **Codevator** 和 **My Mac**，点击 **Run**。也可以使用 Makefile：

```sh
make build
make test
```

运行 `make test-ui` 可以执行 macOS 界面测试。如果 Xcode 不在 `/Applications/Xcode.app`，可通过 `XCODEBUILD` 指定 `xcodebuild` 的路径。

</details>

## 开源协议

Codevator 采用 [MIT 协议](LICENSE)。你可以修改并用于商业项目；复制或分发本项目的大部分内容时，需保留版权与协议声明。
