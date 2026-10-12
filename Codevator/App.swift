import SwiftUI
import AppKit

@main
struct CodevatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var workspace = Workspace()
    var body: some Scene {
        Window("Codevator", id: "workspace") {
            WorkspaceView(workspace: workspace)
                .frame(minWidth: 850, minHeight: 560)
                .task { delegate.workspace = workspace; await workspace.load() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await workspace.refreshAll() } }
        }
        .commands {
            CommandGroup(after: .newItem) { Button("添加 Git 项目…") { workspace.chooseProject() }.keyboardShortcut("o") }
        }
        Settings { CLISettings(workspace: workspace) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var workspace: Workspace?
    func applicationDidFinishLaunching(_ notification: Notification) {
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
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
            window.makeKeyAndOrderFront(nil)
        }
        #endif
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace else { return .terminateNow }
        guard !workspace.sessions.running.isEmpty else { workspace.sessions.isClosing = true; return .terminateNow }
        Task { sender.reply(toApplicationShouldTerminate: await workspace.prepareToExit()) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct WorkspaceView: View {
    @ObservedObject var workspace: Workspace
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
                            VStack(alignment: .leading, spacing: 3) {
                                Label(tree.label, systemImage: tree.isMain ? "house" : "arrow.triangle.branch")
                                Text(URL(fileURLWithPath: tree.path).lastPathComponent).font(.caption).foregroundStyle(.secondary)
                                if tree.locked || tree.unavailable { Text(tree.locked ? "已锁定" : "不可用").font(.caption).foregroundStyle(.orange) }
                            }
                            .tag(tree.id)
                            .contextMenu {
                                Button("在 Finder 显示") { NSWorkspace.shared.selectFile(tree.path, inFileViewerRootedAtPath: "") }
                                Button("移除 worktree…", role: .destructive) { Task { await workspace.removeTree(tree, project: project) } }
                                    .disabled(tree.isMain || tree.locked || tree.unavailable || workspace.busy.contains(project.id))
                            }
                        }
                    } label: {
                        HStack { Text(project.name).fontWeight(.medium); if workspace.busy.contains(project.id) { ProgressView().controlSize(.small) } }
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
        } detail: {
            if let tree = workspace.selectedTree {
                WorktreeDetail(tree: tree, workspace: workspace, manager: workspace.sessions)
            } else {
                ContentUnavailableView {
                    Label("Codevator", systemImage: "terminal")
                } description: { Text(workspace.configuration.projects.isEmpty ? "添加一个 Git 项目，开始管理 worktree 与编程会话。" : "在左侧选择一个 worktree。") }
                actions: { Button("添加 Git 项目…", action: workspace.chooseProject) }
            }
        }
        .sheet(item: $createProject) { CreateWorktreeView(project: $0, workspace: workspace) }
        .alert("操作未完成", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button("确定") { workspace.error = nil }
        } message: { Text(workspace.error ?? "") }
        .overlay(alignment: .bottom) {
            if workspace.configurationBlocked {
                HStack { Text("配置损坏或版本不支持，保存已暂停"); Button("备份并重置配置") { workspace.resetConfiguration() } }
                    .padding().background(.regularMaterial)
            }
        }
    }
}

struct WorktreeDetail: View {
    let tree: Worktree
    @ObservedObject var workspace: Workspace
    @ObservedObject var manager: SessionManager
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text((workspace.configuration.projects.first(where: { $0.id == tree.projectID })?.name ?? "项目") + " · " + tree.label).font(.headline)
                    Text(tree.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Picker("工具", selection: workspace.providerSelection(tree)) { ForEach(CLIProvider.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 180)
                    .disabled(manager.sessions[tree.id]?.active == true)
                if let session = manager.sessions[tree.id], session.active || session.stopping {
                    Button("停止") { Task { await manager.stop(tree.id) } }.disabled(session.stopping)
                } else {
                    Button(manager.sessions[tree.id] == nil ? "启动" : "重新启动") {
                        Task { await workspace.startSession(tree) }
                    }.disabled(tree.unavailable || workspace.busy.contains(tree.projectID))
                }
            }.padding()
            Divider()
            if tree.unavailable { Text("此工作目录不可用，请刷新项目。已有会话可以停止。").foregroundStyle(.orange).padding(8) }
            if let session = manager.sessions[tree.id] { SessionView(session: session) }
            else {
                ContentUnavailableView("启动编程会话", systemImage: "terminal", description: Text("选择 Codex 或 Claude 并启动。会话将运行在上方 worktree 目录中。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct SessionView: View {
    @ObservedObject var session: TerminalSession
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(session.provider.title); Text(session.state).textSelection(.enabled); Spacer() }
                .font(.caption).padding(8).background(.bar)
            TerminalHost(session: session).id(ObjectIdentifier(session))
        }
    }
}

struct CreateWorktreeView: View {
    let project: Project
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var branch = ""
    @State private var start = "HEAD"
    @State private var newBranch = true
    @State private var branches: [String] = []
    @State private var creationError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("创建 worktree · \(project.name)").font(.title2)
            Toggle("创建新分支", isOn: $newBranch)
            if newBranch { TextField("新分支名", text: $branch); TextField("本地起点", text: $start) }
            else { Picker("已有本地分支", selection: $branch) { Text("选择分支").tag(""); ForEach(branches, id: \.self) { Text($0).tag($0) } } }
            TextField("新目录的绝对路径", text: $path)
            Button("选择父目录…") {
                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                if panel.runModal() == .OK, let url = panel.url { path = url.appendingPathComponent(branch.isEmpty ? "new-worktree" : branch.replacingOccurrences(of: "/", with: "-")).path }
            }
            Text("目标目录须不存在。创建完成后不会自动启动 CLI。").font(.caption).foregroundStyle(.secondary)
            if let creationError { Text(creationError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer(); Button("取消") { dismiss() }.disabled(workspace.busy.contains(project.id))
                Button("创建") { Task {
                    creationError = nil
                    if await workspace.create(project, path: path, branch: branch, newBranch: newBranch, start: start) { dismiss() }
                    else { creationError = workspace.error; workspace.error = nil }
                } }
                    .disabled(path.isEmpty || branch.isEmpty || workspace.busy.contains(project.id))
            }
        }.padding(24).frame(width: 500)
        .task { do { branches = try await workspace.git.branches(project) } catch { creationError = error.localizedDescription } }
    }
}

struct CLISettings: View {
    @ObservedObject var workspace: Workspace
    @State private var result = ""
    var body: some View {
        Form {
            ForEach(CLIProvider.allCases) { provider in
                TextField(provider.title + " 绝对路径（留空自动检测）", text: Binding(get: { workspace.configuration.cliPaths[provider.rawValue] ?? "" }, set: { workspace.configuration.cliPaths[provider.rawValue] = $0; workspace.save() }))
            }
            Button("重新检测 CLI") {
                Task {
                    await workspace.sessions.resolver.invalidate()
                    var lines: [String] = []
                    for provider in CLIProvider.allCases {
                        do { let (path, _) = try await workspace.sessions.resolver.resolve(provider, override: workspace.configuration.cliPaths[provider.rawValue]); lines.append(provider.title + "：" + path) }
                        catch { lines.append(provider.title + "：" + error.localizedDescription) }
                    }
                    result = lines.joined(separator: "\n")
                }
            }
            Text(result).font(.caption).textSelection(.enabled)
        }.padding(24).frame(width: 600)
    }
}
