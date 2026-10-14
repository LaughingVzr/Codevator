import SwiftUI
import AppKit
import UserNotifications

func tr(_ key: String) -> String { NSLocalizedString(key, comment: "") }

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: tr("跟随系统")
        case .light: tr("浅色")
        case .dark: tr("深色")
        }
    }
    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }
    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    @MainActor static func apply(_ rawValue: String) {
        let appearance = AppAppearance(rawValue: rawValue) ?? .system
        NSApp.appearance = appearance.appKitAppearance
        for window in NSApp.windows {
            style(window, appearance: appearance)
        }
    }

    @MainActor static func style(_ window: NSWindow, appearance: AppAppearance) {
        guard window.title.hasPrefix("Codevator") else { return }
        window.titlebarAppearsTransparent = true
        window.isOpaque = true
        let dark = NSColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1)
        let light = NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1)
        switch appearance {
        case .dark:
            window.backgroundColor = dark
        case .light:
            window.backgroundColor = light
        case .system:
            window.backgroundColor = NSColor(name: NSColor.Name("CodevatorWindowBackground")) { currentAppearance in
                currentAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            }
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, chinese = "zh-Hans", english = "en"
    static let runningRawValue = UserDefaults.standard.string(forKey: "language") ?? system.rawValue
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: tr("跟随系统")
        case .chinese: tr("简体中文")
        case .english: "English"
        }
    }
    var locale: Locale? {
        switch self {
        case .system: nil
        case .chinese: Locale(identifier: "zh-Hans")
        case .english: Locale(identifier: "en")
        }
    }
    static func apply(_ rawValue: String) {
        let language = AppLanguage(rawValue: rawValue) ?? .system
        if language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
    }
}

private enum AppSurface {
    static let darkSidebar = Color(red: 0.09, green: 0.10, blue: 0.12)
    static let darkContent = Color(red: 0.12, green: 0.13, blue: 0.15)
    static let lightContent = Color(red: 0.97, green: 0.975, blue: 0.985)

    static func sidebar(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkSidebar : Color(nsColor: .windowBackgroundColor)
    }

    static func content(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkContent : lightContent
    }
}

@main
struct CodevatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var workspace = Workspace()
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("language") private var language = AppLanguage.system.rawValue
    var body: some Scene {
        Window("Codevator", id: "workspace") {
            WorkspaceView(workspace: workspace)
                .frame(minWidth: 850, minHeight: 560)
                .task { delegate.workspace = workspace; await workspace.load() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    workspace.markVisibleTabRead()
                    Task { await workspace.refreshAll() }
                }
        }
        .commands {
            CommandGroup(after: .newItem) { Button("添加 Git 项目…") { workspace.chooseProject() }.keyboardShortcut("o") }
            CommandMenu("终端") {
                Button("放大终端文字") { workspace.sessions.adjustFontSize(by: 1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("缩小终端文字") { workspace.sessions.adjustFontSize(by: -1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("还原终端文字大小") { workspace.sessions.resetFontSize() }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
        Settings {
            AppSettingsView(workspace: workspace, appearance: $appearance, language: $language)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var workspace: Workspace?
    var relaunchAfterTermination = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        AppAppearance.apply(UserDefaults.standard.string(forKey: "appearance") ?? AppAppearance.system.rawValue)
        NotificationCenter.default.addObserver(self, selector: #selector(styleKeyWindow(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        }
        #if DEBUG
        guard ProcessInfo.processInfo.environment["CODEVATOR_UI_TEST_CONFIG"] != nil else { return }
        DispatchQueue.main.async {
            guard let screen = NSScreen.screens.first,
                  let window = NSApplication.shared.windows.first(where: { $0.title == "Codevator" }) else { return }
            window.collectionBehavior.insert(.moveToActiveSpace)
            let visible = screen.visibleFrame
            let width = min(window.frame.width, visible.width - 40)
            let height = min(window.frame.height, visible.height - 40)
            window.setFrame(NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2,
                                   width: width, height: height), display: true)
            window.makeKeyAndOrderFront(nil)
        }
        #endif
    }
    @objc private func styleKeyWindow(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let appearance = AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "system") ?? .system
        AppAppearance.style(window, appearance: appearance)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace else { return .terminateNow }
        guard !workspace.sessions.running.isEmpty else { workspace.sessions.isClosing = true; return .terminateNow }
        Task { sender.reply(toApplicationShouldTerminate: await workspace.prepareToExit()) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        guard relaunchAfterTermination else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open -a \"$1\"", "codevator-relaunch", Bundle.main.bundleURL.path]
        try? process.run()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

struct WorkspaceView: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.colorScheme) private var colorScheme
    @State private var createProject: Project?
    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { workspace.selection }, set: { workspace.selection = $0 })) {
                ForEach(workspace.configuration.projects) { project in
                    DisclosureGroup(isExpanded: workspace.expanded(project)) {
                        if let failure = workspace.projectErrors[project.id] {
                            Text(failure).font(.caption).foregroundStyle(.red)
                            Button("重试") { Task { await workspace.refresh(project) } }
                        }
                        ForEach(workspace.displayTrees(project.id)) { tree in
                            treeItem(tree, project: project)
                        }
                    } label: {
                        projectRow(project)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contextMenu {
                                Button("创建 worktree…") { createProject = project }.disabled(workspace.busy.contains(project.id))
                                Button("刷新") { Task { await workspace.refresh(project) } }
                                Button("移除项目记录…", role: .destructive) { Task { await workspace.removeProject(project) } }.disabled(workspace.busy.contains(project.id))
                            }
                    }
                }
            }
            .navigationTitle("项目")
            .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 400)
            .toolbar { Button(action: workspace.chooseProject) { Label("添加项目", systemImage: "plus") }; Button { Task { await workspace.refreshAll() } } label: { Label("刷新", systemImage: "arrow.clockwise") } }
            .scrollContentBackground(.hidden)
            .background(AppSurface.sidebar(for: colorScheme))
        } detail: {
            Group {
                if let tree = workspace.selectedTree {
                    WorktreeDetail(tree: tree, workspace: workspace, manager: workspace.sessions)
                } else {
                    WorkspaceEmptyState(hasProjects: !workspace.configuration.projects.isEmpty) {
                        workspace.chooseProject()
                    }
                }
            }
            .background(AppSurface.content(for: colorScheme))
        }
        .toolbarBackground(AppSurface.content(for: colorScheme), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .sheet(item: $createProject) { CreateWorktreeView(project: $0, workspace: workspace) }
        .alert("操作未完成", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button("确定") { workspace.error = nil }
        } message: { Text(workspace.error ?? "") }
        .overlay(alignment: .bottom) {
            if workspace.configurationBlocked {
                HStack { Text("配置损坏或版本不支持，保存已暂停"); Button("备份并重置配置") { Task { await workspace.resetConfiguration() } } }
                    .padding().background(.regularMaterial)
            }
        }
    }

    private func treeRow(_ tree: Worktree, project: Project) -> some View {
        HStack(spacing: 8) {
            Image(systemName: tree.isMain ? "house" : "arrow.triangle.branch")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(tree.displayName(projectName: project.name))
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(tree.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    if tree.locked || tree.unavailable {
                        Text(tree.locked ? "已锁定" : "不可用")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 4)
            if workspace.sessions.pendingCount(in: tree.id) > 0 {
                PendingBadge(count: workspace.sessions.pendingCount(in: tree.id))
                    .accessibilityIdentifier("worktreePending-\(tree.path)")
            }
            if workspace.sessions.unreadCount(in: tree.id) > 0 {
                CompletionBadge(count: workspace.sessions.unreadCount(in: tree.id))
                    .accessibilityIdentifier("worktreeCompleted-\(tree.path)")
            }
        }
    }

    private func treeItem(_ tree: Worktree, project: Project) -> some View {
        treeRow(tree, project: project)
            .help(tree.path)
            .tag(tree.id)
            .contextMenu {
                Button("在 Finder 显示") { NSWorkspace.shared.selectFile(tree.path, inFileViewerRootedAtPath: "") }
                Button("移除 worktree…", role: .destructive) { Task { await workspace.removeTree(tree, project: project) } }
                    .disabled(tree.isMain || tree.locked || tree.unavailable || workspace.busy.contains(project.id))
            }
    }

    private func projectRow(_ project: Project) -> some View {
        HStack {
            Text(project.name).fontWeight(.medium)
            if workspace.busy.contains(project.id) { ProgressView().controlSize(.small) }
            Spacer(minLength: 4)
            if workspace.sessions.pendingCount(forProject: project.id) > 0 {
                PendingBadge(count: workspace.sessions.pendingCount(forProject: project.id))
                    .accessibilityIdentifier("projectPending-\(project.id)")
            }
            if workspace.sessions.unreadCount(forProject: project.id) > 0 {
                CompletionBadge(count: workspace.sessions.unreadCount(forProject: project.id))
                    .accessibilityIdentifier("projectCompleted-\(project.id)")
            }
        }
    }
}

private struct WorkspaceEmptyState: View {
    let hasProjects: Bool
    let addProject: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 68, height: 68)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
            Text(hasProjects ? LocalizedStringKey("选择一个 worktree") : LocalizedStringKey("添加你的第一个项目"))
                .font(.title3.weight(.semibold))
            Text(hasProjects ? LocalizedStringKey("从左侧选择 worktree，开始编程会话。") : LocalizedStringKey("添加 Git 项目后，就能管理 worktree 和编程会话。"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !hasProjects {
                Button("添加 Git 项目…", action: addProject)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WorktreeDetail: View {
    let tree: Worktree
    @ObservedObject var workspace: Workspace
    @ObservedObject var manager: SessionManager
    private var selectedTab: SessionManager.Tab? { manager.selectedTab(for: tree.id) }
    private var unavailable: Bool { tree.unavailable || workspace.busy.contains(tree.projectID) }
    private func tabTitle(_ tab: SessionManager.Tab) -> String {
        guard let provider = tab.provider else { return tr("新标签") }
        let sameTool = manager.tabs(for: tree.id).filter { $0.provider == provider }
        guard sameTool.count > 1, let position = sameTool.firstIndex(where: { $0.id == tab.id }) else { return provider.title }
        return provider.title + " \(position + 1)"
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text((workspace.configuration.projects.first(where: { $0.id == tree.projectID })?.name ?? tr("项目")) + " · " + tree.label).font(.headline)
                    Text(tree.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                ForEach(CLIProvider.allCases) { provider in
                    Button { Task { await workspace.openSession(tree, provider: provider) } } label: {
                        Label { Text(provider.title) } icon: { CLIProviderIcon(provider: provider) }
                    }
                    .accessibilityLabel("新建 \(provider.title) 标签")
                    .help("在新标签中启动 \(provider.title)")
                    .disabled(unavailable)
                }
            }.padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            HStack(spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(manager.tabs(for: tree.id)) { tab in
                            HStack(spacing: 2) {
                                Button {
                                    workspace.selectTab(tab.id, in: tree.id)
                                } label: {
                                    HStack(spacing: 6) {
                                        if let provider = tab.provider { CLIProviderIcon(provider: provider) }
                                        else { Image(systemName: "terminal").foregroundStyle(.secondary) }
                                        Text(tabTitle(tab))
                                        if manager.unreadCompletions.contains(tab.id) {
                                            Circle().fill(.orange).frame(width: 6, height: 6)
                                        }
                                        if manager.sessions[tab.id]?.awaitingResponse == true {
                                            Circle().fill(.green).frame(width: 5, height: 5)
                                        }
                                    }.padding(.horizontal, 8).padding(.vertical, 6)
                                }
                                .accessibilityLabel("\(tabTitle(tab)) 标签")
                                Button { Task { await workspace.closeTab(tab.id) } } label: {
                                    Image(systemName: "xmark").font(.caption2).padding(5)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("关闭 \(tabTitle(tab)) 标签")
                            }
                            .buttonStyle(.plain)
                            .background(manager.selectedTabIDs[tree.id] == tab.id ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        }
                        Button { _ = manager.createTab(for: tree.id) } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("新建空白标签")
                        .help("先创建标签，再选择工具")
                        .padding(.leading, 2)
                    }.padding(.horizontal, 8).padding(.vertical, 4)
                }
            }.background(.bar)
            Divider()
            if tree.unavailable { Text("此工作目录不可用，请刷新项目。已有会话可以停止。").foregroundStyle(.orange).padding(8) }
            if let tab = selectedTab {
                if let session = manager.sessions[tab.id] {
                    VStack(spacing: 0) {
                        HStack {
                            Text(session.state).textSelection(.enabled)
                            Spacer()
                            if session.active || session.stopping {
                                Button("停止") { Task { await manager.stop(tab.id) } }.disabled(session.stopping)
                            } else {
                                Button("重新启动") { Task { await workspace.startSession(tree, tabID: tab.id, provider: session.provider) } }
                                    .disabled(unavailable)
                            }
                        }.font(.caption).padding(8).background(.bar)
                        TerminalHost(session: session).id(ObjectIdentifier(session))
                    }
                } else {
                    ContentUnavailableView {
                        Label("选择工具", systemImage: "terminal")
                    } description: {
                        Text("在此标签中启动 Codex、Claude 或终端。")
                    } actions: {
                        HStack {
                            ForEach(CLIProvider.allCases) { provider in
                                Button { Task { await workspace.startSession(tree, tabID: tab.id, provider: provider) } } label: {
                                    Label { Text(provider.title) } icon: { CLIProviderIcon(provider: provider) }
                                }.disabled(unavailable)
                            }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView("启动编程会话", systemImage: "terminal", description: Text("点击上方工具名称直接打开新标签，或点击 + 先创建空白标签。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct PendingBadge: View {
    let count: Int
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(.green).frame(width: 6, height: 6)
            Text(String(count))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Color.green.opacity(0.13), in: Capsule())
        .accessibilityLabel("\(count) 个会话正在等待回复")
        .help("\(count) 个会话正在等待回复")
    }
}

private struct CompletionBadge: View {
    let count: Int
    var body: some View {
        Text(String(count))
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.orange, in: Capsule())
            .accessibilityLabel("\(count) 个已完成的会话待查看")
            .help("\(count) 个已完成的会话待查看")
    }
}

struct CLIProviderIcon: View {
    let provider: CLIProvider
    private var symbol: String {
        switch provider {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claude: "asterisk"
        case .terminal: "terminal"
        }
    }
    private var tint: Color {
        switch provider {
        case .codex: .teal
        case .claude: Color(red: 0.85, green: 0.42, blue: 0.27)
        case .terminal: .secondary
        }
    }
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }
}

struct CreateWorktreeView: View {
    let project: Project
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var root = ""
    @State private var branch = ""
    @State private var start = "HEAD"
    @State private var newBranch = false
    @State private var customNameEnabled = false
    @State private var customName = ""
    @State private var generatedName = ""
    @State private var branches: [String] = []
    @State private var creationError: String?
    private var reservedNames: Set<String> {
        Set(workspace.displayTrees(project.id).map { $0.displayName(projectName: project.name) })
    }
    private var name: String {
        if customNameEnabled { return customName }
        if newBranch { return WorktreeLocation.automaticName(branch: branch, root: root, reservedNames: reservedNames) }
        return WorktreeLocation.availableName(base: generatedName.isEmpty ? "worktree" : generatedName, root: root, reservedNames: reservedNames)
    }
    private var targetPath: String { WorktreeLocation.path(root: root, name: name, projectName: project.name) }
    private var nameTaken: Bool {
        reservedNames.contains(name) || FileManager.default.fileExists(atPath: URL(fileURLWithPath: root).appendingPathComponent(name).path)
    }
    private var canCreate: Bool {
        root.hasPrefix("/") && !branch.isEmpty && WorktreeLocation.validName(name) && !nameTaken &&
        !workspace.busy.contains(project.id)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("创建 worktree · \(project.name)").font(.title2)
            Toggle("创建新分支", isOn: $newBranch)
                .onChange(of: newBranch) { _ in branch = "" }
            if newBranch { TextField("新分支名", text: $branch); TextField("本地起点", text: $start) }
            else { Picker("已有本地分支", selection: $branch) { Text("选择分支").tag(""); ForEach(branches, id: \.self) { Text($0).tag($0) } } }
            Toggle("自定义 worktree 名称", isOn: $customNameEnabled)
            if customNameEnabled {
                TextField("worktree 名称", text: $customName)
                if !customName.isEmpty && !WorktreeLocation.validName(customName) {
                    Text("名称只能是单个目录名，不能包含 / 或 :。")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                HStack {
                    Text("自动名称：\(name)").font(.subheadline).foregroundStyle(.secondary)
                    if !newBranch {
                        Button("换一个") {
                            generatedName = WorktreeLocation.randomName(root: root, reservedNames: reservedNames, excluding: [generatedName])
                        }
                        .controlSize(.small)
                    }
                }
            }
            HStack {
                TextField("worktree 根目录的绝对路径", text: $root)
                Button("选择目录…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url { root = url.path }
                }
            }
            Text("目标路径：\(targetPath)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if customNameEnabled && nameTaken {
                Text("此名称对应的目录已存在，请换一个名称。")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("创建完成后不会自动启动 CLI。").font(.caption).foregroundStyle(.secondary)
            if let creationError { Text(creationError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer(); Button("取消") { dismiss() }.disabled(workspace.busy.contains(project.id))
                Button("创建") { Task {
                    creationError = nil
                    if await workspace.create(project, path: targetPath, branch: branch, newBranch: newBranch, start: start) { dismiss() }
                    else { creationError = workspace.error; workspace.error = nil }
                } }
                    .disabled(!canCreate)
            }
        }.padding(24).frame(width: 500)
        .task {
            root = WorktreeLocation.suggestedRoot(project: project, trees: workspace.displayTrees(project.id))
            generatedName = WorktreeLocation.randomName(root: root, reservedNames: reservedNames)
            do { branches = try await workspace.git.branches(project) } catch { creationError = error.localizedDescription }
        }
    }
}

private enum SettingsSection: Hashable {
    case appearance, language, terminal, notifications, tools
}

struct AppSettingsView: View {
    @ObservedObject var workspace: Workspace
    @Binding var appearance: String
    @Binding var language: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var section: SettingsSection? = .appearance
    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Label("外观", systemImage: "paintbrush.pointed")
                    .tag(SettingsSection.appearance)
                Label("语言", systemImage: "character.bubble")
                    .tag(SettingsSection.language)
                Label("终端", systemImage: "textformat.size")
                    .tag(SettingsSection.terminal)
                Label("通知", systemImage: "bell.badge")
                    .tag(SettingsSection.notifications)
                Label("编程工具", systemImage: "terminal")
                    .tag(SettingsSection.tools)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
            .scrollContentBackground(.hidden)
            .background(AppSurface.sidebar(for: colorScheme))
        } detail: {
            Group {
                switch section {
                case .appearance:
                    AppearanceSettings(appearance: $appearance)
                case .language:
                    LanguageSettings(language: $language)
                case .terminal:
                    TerminalSettings(sessions: workspace.sessions)
                case .notifications:
                    NotificationSettings()
                case .tools:
                    CLISettings(workspace: workspace)
                case nil:
                    ContentUnavailableView("选择设置项", systemImage: "gearshape")
                }
            }
            .background(AppSurface.content(for: colorScheme))
        }
        .frame(minWidth: 700, minHeight: 400)
        .toolbarBackground(AppSurface.content(for: colorScheme), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
    }
}

private struct TerminalSettings: View {
    @ObservedObject var sessions: SessionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("终端文字大小").font(.title2.weight(.semibold))
            Text("调整所有终端的文字大小。已打开的标签会立即更新。")
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Button { sessions.adjustFontSize(by: -1) } label: {
                    Image(systemName: "minus")
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("缩小终端文字")
                .disabled(sessions.fontSize == TerminalFontSize.range.lowerBound)

                Text("\(sessions.fontSize) pt")
                    .font(.system(.title3, design: .monospaced))
                    .frame(minWidth: 70)
                    .accessibilityIdentifier("terminalFontSize")

                Button { sessions.adjustFontSize(by: 1) } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("放大终端文字")
                .disabled(sessions.fontSize == TerminalFontSize.range.upperBound)

                Button("还原默认大小") { sessions.resetFontSize() }
                    .padding(.leading, 8)
                    .disabled(sessions.fontSize == TerminalFontSize.defaultValue)
            }
            Text("也可以使用 ⌘+、⌘− 和 ⌘0 调整。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct NotificationSettings: View {
    @State private var status: UNAuthorizationStatus?
    @State private var soundEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("通知").font(.title2.weight(.semibold))
            Text("Codex 或 Claude 完成回复后，在你查看其他窗口时提醒你。")
                .foregroundStyle(.secondary)
            if let status {
                switch status {
                case .authorized, .provisional:
                    Label("通知已允许", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(soundEnabled ? "通知声音已开启。" : "通知声音已关闭，可在 macOS 系统设置中开启。")
                        .foregroundStyle(.secondary)
                case .notDetermined:
                    Text("尚未允许通知。启动编程工具时会请求权限。")
                        .foregroundStyle(.secondary)
                    Button("允许通知") {
                        Task {
                            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                            await refresh()
                        }
                    }
                default:
                    Text("系统通知已关闭。请在 macOS 系统设置 → 通知 → Codevator 中开启通知和声音。")
                        .foregroundStyle(.secondary)
                }
                if status != .notDetermined {
                    Button("打开系统通知设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        status = settings.authorizationStatus
        soundEnabled = settings.soundSetting == .enabled
    }
}

private struct LanguageSettings: View {
    @Binding var language: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("语言").font(.title2.weight(.semibold))
            Text("选择菜单和界面的显示语言。")
                .foregroundStyle(.secondary)
            Picker("应用语言", selection: $language) {
                ForEach(AppLanguage.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
            .onChange(of: language) { _, newValue in
                AppLanguage.apply(newValue)
            }
            if language != AppLanguage.runningRawValue {
                Text("重新启动 Codevator 后，菜单和界面将使用所选语言。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("重新启动 Codevator") {
                    (NSApp.delegate as? AppDelegate)?.relaunchAfterTermination = true
                    NSApp.terminate(nil)
                }
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct AppearanceSettings: View {
    @Binding var appearance: String
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("外观").font(.title2.weight(.semibold))
                Text("选择 Codevator 的显示方式。")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                ForEach(AppAppearance.allCases) { option in
                    Button {
                        AppAppearance.apply(option.rawValue)
                        appearance = option.rawValue
                    } label: {
                        VStack(spacing: 14) {
                            Image(systemName: option.symbol)
                                .font(.system(size: 28, weight: .medium))
                                .frame(height: 38)
                            HStack(spacing: 6) {
                                Text(option.title).fontWeight(.medium)
                                if appearance == option.rawValue {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 100)
                        .background(appearance == option.rawValue ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(appearance == option.rawValue ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.title)
                    .accessibilityAddTraits(appearance == option.rawValue ? .isSelected : [])
                }
            }
            Text("跟随系统时，Codevator 会随 macOS 的外观设置自动切换。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct CLISettings: View {
    @ObservedObject var workspace: Workspace
    @State private var result = ""
    var body: some View {
        Form {
            ForEach(CLIProvider.aiCases) { provider in
                TextField(provider.title + tr(" 绝对路径（留空自动检测）"), text: Binding(get: { workspace.configuration.cliPaths[provider.rawValue] ?? "" }, set: { workspace.configuration.cliPaths[provider.rawValue] = $0; workspace.save() }))
            }
            Button("重新检测 CLI") {
                Task {
                    await workspace.sessions.resolver.invalidate()
                    var lines: [String] = []
                    for provider in CLIProvider.aiCases {
                        do { let (path, _) = try await workspace.sessions.resolver.resolve(provider, override: workspace.configuration.cliPaths[provider.rawValue]); lines.append(provider.title + "：" + path) }
                        catch { lines.append(provider.title + "：" + error.localizedDescription) }
                    }
                    result = lines.joined(separator: "\n")
                }
            }
            Text(result).font(.caption).textSelection(.enabled)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
