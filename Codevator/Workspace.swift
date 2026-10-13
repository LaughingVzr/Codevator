import AppKit
import SwiftUI
import Combine
import UserNotifications

@MainActor
final class Workspace: ObservableObject {
    @Published var configuration = WorkspaceConfiguration()
    @Published var trees: [String: [Worktree]] = [:]
    @Published var projectErrors: [String: String] = [:]
    @Published var busy: Set<String> = []
    @Published var error: String?
    @Published var configurationBlocked = false
    let git = GitService()
    let sessions = SessionManager()
    let store: ConfigurationStore
    private let confirmation: ((String, String, String) -> Bool)?
    private var refreshVersions: [String: Int] = [:]
    private var sessionObservation: AnyCancellable?
    init(store: ConfigurationStore = .init(), confirmation: ((String, String, String) -> Bool)? = nil) {
        self.store = store; self.confirmation = confirmation
        sessions.onTurnCompleted = { [weak self] tabID, session in self?.turnCompleted(tabID: tabID, session: session) }
        sessionObservation = sessions.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
    }
    var selection: String? {
        get { configuration.selection }
        set {
            guard configuration.selection != newValue else { return }
            configuration.selection = newValue; save(); markVisibleTabRead()
        }
    }
    func selectTab(_ tabID: String, in treeID: String) {
        sessions.select(tabID, in: treeID)
        if selection == treeID { sessions.markRead(tabID); updateDockBadge() }
    }
    func markVisibleTabRead() {
        guard NSApp.isActive, let treeID = selection, let tabID = sessions.selectedTabIDs[treeID] else { return }
        sessions.markRead(tabID); updateDockBadge()
    }
    private func updateDockBadge() {
        let count = sessions.unreadCompletions.count
        NSApp.dockTile.badgeLabel = count == 0 ? nil : String(count)
        NSApp.dockTile.display()
    }
    private func turnCompleted(tabID: String, session: TerminalSession) {
        guard sessions.tabs(for: session.treeID).contains(where: { $0.id == tabID }) else { return }
        let visible = NSApp.isActive && NSApp.keyWindow?.title == "Codevator" &&
            selection == session.treeID && sessions.selectedTabIDs[session.treeID] == tabID
        guard !visible else { return }
        sessions.markUnread(tabID); updateDockBadge()
        let project = configuration.projects.first(where: { $0.id == session.treeID.components(separatedBy: "\n").first })
        let projectName = project?.name ?? tr("项目")
        let worktreeName = project.flatMap { project in
            displayTrees(project.id).first(where: { $0.id == session.treeID })?.displayName(projectName: project.name)
        } ?? URL(fileURLWithPath: session.path).lastPathComponent
        CompletionNotifier.post(title: String(format: tr("%@ 回复已完成"), session.provider.title), body: "\(projectName) · \(worktreeName)", tabID: tabID)
    }
    func displayTrees(_ projectID: String) -> [Worktree] {
        let current = trees[projectID] ?? []
        let known = Set(current.map(\.id))
        let retained = sessions.sessions.values.filter { $0.treeID.hasPrefix(projectID + "\n") && !known.contains($0.treeID) }
            .map { Worktree(projectID: projectID, path: $0.path, unavailable: true) }
        return current + Dictionary(grouping: retained, by: \.id).values.compactMap(\.first).sorted { $0.path < $1.path }
    }
    var selectedTree: Worktree? { configuration.projects.flatMap { displayTrees($0.id) }.first { $0.id == selection } }
    func load() async {
        do { configuration = try store.load() }
        catch { configurationBlocked = true; self.error = String(format: tr("配置读取失败，原文件已保留：%@\n%@"), error.localizedDescription, store.file.path) }
        await refreshAll()
    }
    func save() {
        guard !configurationBlocked else { return }
        do { try store.save(configuration) } catch { self.error = error.localizedDescription }
    }
    func resetConfiguration() async {
        guard sessions.running.isEmpty else { error = tr("请先停止所有运行会话，再重置配置"); return }
        do {
            if FileManager.default.fileExists(atPath: store.file.path) {
                try FileManager.default.moveItem(at: store.file, to: store.file.appendingPathExtension("backup-" + UUID().uuidString))
            }
            for treeID in sessions.tabsByTree.keys { await sessions.remove(treeID) }
            updateDockBadge()
            configuration = .init(); configurationBlocked = false; save()
        } catch { self.error = error.localizedDescription }
    }
    func refreshAll() async { for project in configuration.projects { await refresh(project) } }
    func refresh(_ project: Project) async {
        let version = (refreshVersions[project.id] ?? 0) + 1; refreshVersions[project.id] = version
        do {
            let discovered = try await git.worktrees(project)
            guard refreshVersions[project.id] == version, configuration.projects.contains(where: { $0.id == project.id }) else { return }
            trees[project.id] = discovered; projectErrors.removeValue(forKey: project.id)
        } catch {
            guard refreshVersions[project.id] == version else { return }
            projectErrors[project.id] = error.localizedDescription
            trees[project.id] = (trees[project.id] ?? []).map { var t = $0; t.unavailable = true; return t }
        }
    }
    func add(_ path: String) async {
        do {
            let project = try await git.register(path)
            if !configuration.projects.contains(where: { $0.id == project.id }) { configuration.projects.append(project) }
            await refresh(project)
            selection = trees[project.id]?.first?.id; save()
        } catch { self.error = error.localizedDescription }
    }
    func chooseProject() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = tr("选择已有 Git 项目")
        if panel.runModal() == .OK, let url = panel.url { Task { await add(url.path) } }
    }
    func expanded(_ project: Project) -> Binding<Bool> {
        Binding(get: { self.configuration.projects.first(where: { $0.id == project.id })?.expanded ?? true }, set: { value in
            if let i = self.configuration.projects.firstIndex(where: { $0.id == project.id }), self.configuration.projects[i].expanded != value { self.configuration.projects[i].expanded = value; self.save() }
        })
    }
    func create(_ project: Project, path: String, branch: String, newBranch: Bool, start: String) async -> Bool {
        guard busy.insert(project.id).inserted else { return false }; defer { busy.remove(project.id) }
        do {
            _ = try await git.create(project, path: path, branch: branch, newBranch: newBranch, start: start)
            await refresh(project)
            selection = trees[project.id]?.first(where: { $0.path == GitService.canonical(path) })?.id
            return true
        } catch { await refresh(project); self.error = error.localizedDescription; return false }
    }
    func startSession(_ tree: Worktree, tabID: String, provider: CLIProvider) async {
        do {
            guard !tree.unavailable, !busy.contains(tree.projectID) else { throw WorkspaceError(tr("工作目录不可用或正在修改")) }
            let actual = try await git.register(tree.path)
            guard actual.id == tree.projectID, !busy.contains(tree.projectID),
                  configuration.projects.contains(where: { $0.id == tree.projectID }) else {
                throw WorkspaceError(tr("工作目录身份已改变，请刷新项目"))
            }
            guard sessions.tabs(for: tree.id).contains(where: { $0.id == tabID }) else { return }
            sessions.markRead(tabID); updateDockBadge()
            await sessions.start(tree, tabID: tabID, provider: provider, override: configuration.cliPaths[provider.rawValue])
        } catch { self.error = error.localizedDescription }
    }
    func openSession(_ tree: Worktree, provider: CLIProvider) async {
        guard !tree.unavailable, !busy.contains(tree.projectID) else { return }
        let tab = sessions.createTab(for: tree.id, provider: provider)
        await startSession(tree, tabID: tab.id, provider: provider)
        if sessions.sessions[tab.id] == nil { await sessions.close(tab.id) }
    }
    func closeTab(_ tabID: String) async {
        if let session = sessions.sessions[tabID], session.hasManagedProcesses,
           !confirm(tr("关闭运行中的标签？"), String(format: tr("%@：%@\n此会话及其子进程将停止。"), session.provider.title, session.path), button: tr("关闭并停止")) { return }
        await sessions.close(tabID)
        updateDockBadge()
    }
    func confirm(_ title: String, _ message: String, button: String) -> Bool {
        if let confirmation { return confirmation(title, message, button) }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: button); alert.addButton(withTitle: tr("取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }
    func prepareToExit() async -> Bool {
        sessions.isClosing = true
        let running = sessions.running
        guard !running.isEmpty else { return true }
        let names = running.map { "\($0.provider.title)：\($0.path)" }.joined(separator: "\n")
        guard confirm(tr("停止会话并退出？"), names, button: tr("停止并退出")) else {
            sessions.isClosing = false; return false
        }
        await sessions.stopAll()
        return true
    }
    func removeTree(_ tree: Worktree, project: Project) async {
        guard !busy.contains(project.id) else { return }
        guard sessions.running(in: tree.id).isEmpty else { error = tr("请先停止此 worktree 的运行会话"); return }
        do {
            try await git.validateRemoval(project, tree)
            guard confirm(tr("移除 worktree？"), tree.path + tr("\n分支将保留。"), button: tr("移除")) else { return }
            busy.insert(project.id); defer { busy.remove(project.id) }
            guard sessions.running(in: tree.id).isEmpty else { throw WorkspaceError(tr("请先停止运行会话")) }
            _ = try await git.remove(project, tree)
            await sessions.remove(tree.id)
            updateDockBadge()
            if selection == tree.id { selection = nil }
            await refresh(project)
        } catch { self.error = error.localizedDescription; await refresh(project) }
    }
    func removeProject(_ project: Project) async {
        guard busy.insert(project.id).inserted else { return }
        defer { busy.remove(project.id) }
        let associated = sessions.sessions.values.filter { $0.treeID.hasPrefix(project.id + "\n") }
        let running = associated.filter { $0.hasManagedProcesses }
        let message = running.isEmpty ? tr("只移除项目记录，磁盘文件和分支将保留。") : tr("以下会话将停止：\n") + running.map { "\($0.provider.title)：\($0.path)" }.joined(separator: "\n")
        guard confirm(String(format: tr("移除项目 %@？"), project.name), message, button: tr("移除")) else { return }
        for treeID in sessions.tabsByTree.keys.filter({ $0.hasPrefix(project.id + "\n") }) { await sessions.remove(treeID) }
        updateDockBadge()
        configuration.projects.removeAll { $0.id == project.id }; trees.removeValue(forKey: project.id)
        if selection?.hasPrefix(project.id + "\n") == true { selection = nil }; save()
    }
}

private enum CompletionNotifier {
    static func post(title: String, body: String, tabID: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            let authorized: Bool
            switch settings.authorizationStatus {
            case .authorized, .provisional: authorized = true
            case .notDetermined: authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            default: authorized = false
            }
            guard authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body; content.sound = .default
            let request = UNNotificationRequest(identifier: "codevator-" + tabID + "-" + UUID().uuidString, content: content, trigger: nil)
            try? await center.add(request)
        }
    }
}
