<p align="center">
  <img src="Codevator/Assets.xcassets/AppIcon.appiconset/icon-512@2x.png" alt="Codevator 应用图标" width="144" />
</p>

<h1 align="center">Codevator</h1>

<p align="center">在 Mac 上，把项目、工作目录和编程对话放在一起。</p>

<p align="center"><a href="README.md">English</a></p>

Codevator 帮你在不同的编程任务间切换，又不必担心找不到刚才的工作。左侧是项目和 worktree，右侧可以为每个任务打开独立的 Codex 或 Claude Code 标签。切换项目、工作目录或标签时，对话仍会继续运行。

> Codevator 仍在持续开发中。目前可以自行构建体验，尚未提供打包好的安装版本。

## 可以用它做什么

- **集中管理项目。** 把本机 Git 项目加入侧边栏，直接查看它们的 worktree。你可以把 worktree 理解成同一项目的另一个工作文件夹：在新分支上工作时，不必打乱主文件夹。
- **在对应的目录里开始对话。** 选中 worktree 后，打开 Codex 或 Claude Code。每个标签都是独立会话，也可以同时开多个标签。
- **不错过后台回复。** 对话完成后，标签、worktree 和项目旁会出现提示；也可以收到 macOS 通知。
- **按习惯调整外观。** 界面可选浅色、深色或跟随系统，终端始终保持暗色。应用支持简体中文和英文。

Codevator 使用你 Mac 上已安装的编程工具，不随应用附带 Codex 或 Claude Code。登录仍在各工具中完成。

## 开始使用

需要 macOS 14 或更新版本、Git 和 Xcode。如果要使用编程对话，还需要自行安装 Codex 或 Claude Code。

1. 克隆本仓库，用 Xcode 打开 `Codevator.xcodeproj`。
2. 选择 **Codevator** 和 **My Mac**，点击 **Run**。
3. 在应用侧边栏点击 **+**（或按 **⌘O**），选择本机已有的 Git 项目。
4. 选中一个 worktree，点击 **Codex** 或 **Claude** 开始新标签。也可以先开空白标签，再选择工具。

要创建新的 worktree，右键点击侧边栏中的项目。你可以基于已有分支创建，也可以新建分支；应用会推荐一个名称，你仍能自己修改。

在 **Codevator → 设置** 中可以切换外观和语言，也可以填写编程工具的自定义路径。路径留空时，应用会在本机查找 `codex` 或 `claude`。切换语言后需要重新启动应用。

## 使用前了解一下

- 切换项目或标签不会停止正在运行的对话。关闭运行中的标签或退出应用时，会先询问是否停止进程。
- 应用会记住项目和选中的 worktree，但退出后暂时不会恢复正在运行的对话或终端历史。
- 只有没有未提交改动、也没有运行会话的非主 worktree 才能在应用中删除。把项目从侧边栏移除不会删除磁盘文件。
- 登录和执行命令时的授权仍由 Codex、Claude Code 自己处理；Codevator 不会替你自动批准。

内置终端使用 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)，该依赖采用 MIT 协议。早期的实现和测试记录见[开发记录](docs/implementation-status.md)。

<details>
<summary>通过终端构建与测试</summary>

```sh
xcodebuild -project Codevator.xcodeproj -scheme Codevator \
  -derivedDataPath .build/CodevatorDerivedData \
  -skipPackagePluginValidation -disableAutomaticPackageResolution build

xcodebuild -project Codevator.xcodeproj -scheme Codevator \
  -derivedDataPath .build/CodevatorDerivedData \
  -skipPackagePluginValidation -disableAutomaticPackageResolution \
  -only-testing:CodevatorTests test
```

</details>

## 开源协议

Codevator 采用 [MIT 协议](LICENSE)。你可以修改并用于商业项目；复制或分发本项目的大部分内容时，需保留版权与协议声明。
