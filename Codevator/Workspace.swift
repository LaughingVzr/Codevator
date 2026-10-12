import AppKit
import SwiftUI

@MainActor
final class Workspace: ObservableObject {
    @Published var configuration = WorkspaceConfiguration()
    @Published var trees: [String: [Worktree]] = [:]
    @Published var projectErrors: [String: String] = [:]
    @Published var busy: Set<String> = []
    @Published var error: String?
    @Published var configurationBlocked = false
    var selectedProviders: [String: CLIProvider] = [:]
    let git = GitService()
    let sessions = SessionManager()
    let store: ConfigurationStore
    private let confirmation: ((String, String, String) -> Bool)?
    private var refreshVersions: [String: Int] = [:]
    init(store: ConfigurationStore = .init(), confirmation: ((String, String, String) -> Bool)? = nil) { self.store = store; self.confirmation = confirmation }
    var selection: String? {
        get { configuration.selection }
        set { guard configuration.selection != newValue else { return }; configuration.selection = newValue; save() }
    }
    func displayTrees(_ projectID: String) -> [Worktree] {
        let current = trees[projectID] ?? []
        let known = Set(current.map(\.id))
        let retained = sessions.sessions.values.filter { $0.treeID.hasPrefix(projectID + "\n") && !known.contains($0.treeID) }
            .map { Worktree(projectID: projectID, path: $0.path, unavailable: true) }
        return current + retained.sorted { $0.path < $1.path }
    }
    var selectedTree: Worktree? { configuration.projects.flatMap { displayTrees($0.id) }.first { $0.id == selection } }
    func load() async {
        do { configuration = try store.load() }
        catch { configurationBlocked = true; self.error = "配置读取失败，原文件保留：\(error.localizedDescription)\n\(store.file.path)" }
        await refreshAll()
    }
    func save() {
        guard !configurationBlocked else { return }
        do { try store.save(configuration) } catch { self.error = error.localizedDescription }
    }
    func resetConfiguration() {
        guard sessions.running.isEmpty else { error = "请先停止所有运行会话，再重置配置"; return }
        do {
            if FileManager.default.fileExists(atPath: store.file.path) {
                try FileManager.default.moveItem(at: store.file, to: store.file.appendingPathExtension("backup-" + UUID().uuidString))
            }
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
        panel.message = "选择已有 Git 项目"
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
    func providerSelection(_ tree: Worktree) -> Binding<CLIProvider> {
        Binding(get: {
            if let session = self.sessions.sessions[tree.id], session.active { return session.provider }
            return self.selectedProviders[tree.id] ?? self.sessions.sessions[tree.id]?.provider ?? .codex
        }, set: { value in
            let current = self.selectedProviders[tree.id] ?? self.sessions.sessions[tree.id]?.provider ?? .codex
            guard current != value else { return }
            self.selectedProviders[tree.id] = value
            DispatchQueue.main.async { self.objectWillChange.send() }
        })
    }
    func startSession(_ tree: Worktree, provider: CLIProvider? = nil) async {
        let chosen = provider ?? selectedProviders[tree.id] ?? sessions.sessions[tree.id]?.provider ?? .codex
        do {
            guard !tree.unavailable, !busy.contains(tree.projectID) else { throw WorkspaceError("工作目录不可用或正在修改") }
            let actual = try await git.register(tree.path)
            guard actual.id == tree.projectID, !busy.contains(tree.projectID),
                  configuration.projects.contains(where: { $0.id == tree.projectID }) else {
                throw WorkspaceError("工作目录身份已改变，请刷新项目")
            }
            await sessions.start(tree, provider: chosen, override: configuration.cliPaths[chosen.rawValue])
        } catch { self.error = error.localizedDescription }
    }
    func confirm(_ title: String, _ message: String, button: String) -> Bool {
        if let confirmation { return confirmation(title, message, button) }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: button); alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
    func prepareToExit() async -> Bool {
        sessions.isClosing = true
        let running = sessions.running
        guard !running.isEmpty else { return true }
        let names = running.map { "\($0.provider.title)：\($0.path)" }.joined(separator: "\n")
        guard confirm("停止会话并退出？", names, button: "停止并退出") else {
            sessions.isClosing = false; return false
        }
        await sessions.stopAll()
        return true
    }
    func removeTree(_ tree: Worktree, project: Project) async {
        guard !busy.contains(project.id) else { return }
        guard sessions.sessions[tree.id]?.hasManagedProcesses != true else { error = "请先停止此 worktree 的运行会话"; return }
        do {
            try await git.validateRemoval(project, tree)
            guard confirm("移除 worktree？", tree.path + "\n分支将保留。", button: "移除") else { return }
            busy.insert(project.id); defer { busy.remove(project.id) }
            guard sessions.sessions[tree.id]?.hasManagedProcesses != true else { throw WorkspaceError("请先停止运行会话") }
            _ = try await git.remove(project, tree)
            await sessions.remove(tree.id)
            if selection == tree.id { selection = nil }
            await refresh(project)
        } catch { self.error = error.localizedDescription; await refresh(project) }
    }
    func removeProject(_ project: Project) async {
        guard busy.insert(project.id).inserted else { return }
        defer { busy.remove(project.id) }
        let associated = sessions.sessions.values.filter { $0.treeID.hasPrefix(project.id + "\n") }
        let running = associated.filter { $0.hasManagedProcesses }
        let message = running.isEmpty ? "只移除项目记录，磁盘文件和分支将保留。" : "以下会话将停止：\n" + running.map { "\($0.provider.title)：\($0.path)" }.joined(separator: "\n")
        guard confirm("移除项目 \(project.name)？", message, button: "移除") else { return }
        for session in associated { await sessions.remove(session.treeID) }
        configuration.projects.removeAll { $0.id == project.id }; trees.removeValue(forKey: project.id)
        if selection?.hasPrefix(project.id + "\n") == true { selection = nil }; save()
    }
}
