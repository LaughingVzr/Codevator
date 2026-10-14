import Foundation

struct WorkspaceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = tr(message) }
}

struct CommandResult {
    let output: Data
    let error: String
    let status: Int32
    var text: String { String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum CommandRunner {
    // File-backed output avoids pipe deadlocks, including large stderr responses.
    static func run(_ executable: String, _ arguments: [String], directory: String? = nil,
                    environment: [String: String]? = nil, timeout: TimeInterval = 20) async throws -> CommandResult {
        let task = Task.detached { try execute(executable, arguments, directory: directory, environment: environment, timeout: timeout) }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    private static func execute(_ executable: String, _ arguments: [String], directory: String?, environment: [String: String]?, timeout: TimeInterval) throws -> CommandResult {
            let fm = FileManager.default
            let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: folder) }
            let out = folder.appendingPathComponent("stdout"), err = folder.appendingPathComponent("stderr")
            fm.createFile(atPath: out.path, contents: nil); fm.createFile(atPath: err.path, contents: nil)
            let oh = try FileHandle(forWritingTo: out), eh = try FileHandle(forWritingTo: err)
            defer { try? oh.close(); try? eh.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments; process.environment = environment
            if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
            process.standardOutput = oh; process.standardError = eh
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if Task.isCancelled || Date() > deadline {
                    process.terminate()
                    for _ in 0..<20 where process.isRunning { Thread.sleep(forTimeInterval: 0.01) }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    process.waitUntilExit()
                    throw WorkspaceError(String(format: tr("命令已取消或超时：%@"), executable))
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            process.waitUntilExit()
            return CommandResult(output: try Data(contentsOf: out), error: String(decoding: try Data(contentsOf: err), as: UTF8.self), status: process.terminationStatus)
    }
}

struct Project: Identifiable, Codable, Equatable {
    var id: String // canonical common Git directory
    var name: String
    var directory: String
    var expanded = true
}

struct Worktree: Identifiable, Equatable {
    var projectID: String
    var path: String
    var branch: String?
    var locked = false
    var unavailable = false
    var isMain = false
    var id: String { projectID + "\n" + path }
    func displayName(projectName: String) -> String {
        if isMain { return "main" }
        let directory = URL(fileURLWithPath: path)
        let name = directory.lastPathComponent
        // Some tools place every checkout in a same-named repository directory.
        // In that layout, the enclosing directory distinguishes the worktrees.
        return name == projectName ? directory.deletingLastPathComponent().lastPathComponent : name
    }
    var label: String { branch ?? "detached HEAD" }
}

enum WorktreeLocation {
    private static let adjectives = [
        "amber", "brisk", "calm", "clear", "distant", "early", "gentle", "golden",
        "hollow", "lively", "lunar", "mellow", "open", "quiet", "silver", "steady",
        "sunny", "swift", "tidal", "vivid", "warm", "wild", "young", "zenith"
    ]
    private static let nouns = [
        "anchor", "arcade", "bridge", "canvas", "cedar", "cloud", "delta", "ember",
        "forest", "garden", "harbor", "island", "meadow", "mirror", "orbit", "river",
        "signal", "spark", "summit", "valley", "voyage", "willow", "window", "zephyr"
    ]
    static func suggestedRoot(project: Project, trees: [Worktree]) -> String {
        if let nested = trees.first(where: { !$0.isMain && URL(fileURLWithPath: $0.path).lastPathComponent == project.name }) {
            return URL(fileURLWithPath: nested.path).deletingLastPathComponent().deletingLastPathComponent().path
        }
        return URL(fileURLWithPath: project.directory).deletingLastPathComponent()
            .appendingPathComponent("worktrees").appendingPathComponent(project.name).path
    }
    static func availableName(base: String, root: String, reservedNames: Set<String> = []) -> String {
        func isTaken(_ name: String) -> Bool {
            reservedNames.contains(name) || FileManager.default.fileExists(atPath: URL(fileURLWithPath: root).appendingPathComponent(name).path)
        }
        var candidate = base
        var suffix = 2
        while isTaken(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }
    static func automaticName(branch: String, root: String, reservedNames: Set<String> = []) -> String {
        let base = branch.isEmpty ? "new-worktree" : branch.replacingOccurrences(of: "/", with: "-")
        return availableName(base: base, root: root, reservedNames: reservedNames)
    }
    static func randomName(root: String, reservedNames: Set<String> = [], excluding: Set<String> = []) -> String {
        let forbidden = reservedNames.union(excluding)
        for _ in 0..<32 {
            let name = "\(adjectives.randomElement()!)-\(nouns.randomElement()!)"
            if !forbidden.contains(name) && !FileManager.default.fileExists(atPath: URL(fileURLWithPath: root).appendingPathComponent(name).path) {
                return name
            }
        }
        return availableName(base: "worktree-\(UUID().uuidString.prefix(6).lowercased())", root: root, reservedNames: forbidden)
    }
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name == name.trimmingCharacters(in: .whitespacesAndNewlines) &&
        name != "." && name != ".." && !name.contains("/") && !name.contains(":") && !name.contains("\0")
    }
    static func path(root: String, name: String, projectName: String) -> String {
        URL(fileURLWithPath: root).appendingPathComponent(name).appendingPathComponent(projectName).path
    }
}

struct WorkspaceConfiguration: Codable, Equatable {
    var schemaVersion = 1
    var projects: [Project] = []
    var selection: String?
    var cliPaths: [String: String] = [:]
}

struct ConfigurationStore {
    var file: URL
    init(file: URL? = nil) {
        var testFile: URL?
        #if DEBUG
        testFile = ProcessInfo.processInfo.environment["CODEVATOR_UI_TEST_CONFIG"].map { URL(fileURLWithPath: $0) }
        #endif
        self.file = file ?? testFile ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodeElevator/workspace.json")
    }
    func load() throws -> WorkspaceConfiguration {
        guard FileManager.default.fileExists(atPath: file.path) else { return .init() }
        let config = try JSONDecoder().decode(WorkspaceConfiguration.self, from: Data(contentsOf: file))
        guard config.schemaVersion == 1 else { throw WorkspaceError(String(format: tr("不支持的配置版本，原文件已保留：%@"), file.path)) }
        return config
    }
    func save(_ config: WorkspaceConfiguration) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: file, options: .atomic)
    }
}

actor GitService {
    func command(_ directory: String, _ args: [String]) async throws -> CommandResult {
        let r = try await CommandRunner.run("/usr/bin/git", ["-C", directory] + args)
        guard r.status == 0 else { throw WorkspaceError(r.error.isEmpty ? r.text : r.error.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return r
    }
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
    func register(_ path: String) async throws -> Project {
        guard try await command(path, ["rev-parse", "--is-bare-repository"]).text == "false" else {
            throw WorkspaceError("首版不支持 bare 仓库")
        }
        let root = try await command(path, ["rev-parse", "--show-toplevel"]).text
        let common = try await command(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"]).text
        return Project(id: Self.canonical(common), name: URL(fileURLWithPath: root).lastPathComponent, directory: Self.canonical(root))
    }
    func worktrees(_ project: Project) async throws -> [Worktree] {
        let r = try await command(project.directory, ["worktree", "list", "--porcelain", "-z"])
        return Self.parse(r.output, projectID: project.id)
    }
    static func parse(_ data: Data, projectID: String) -> [Worktree] {
        var list: [Worktree] = [], current: Worktree?
        for item in data.split(separator: 0, omittingEmptySubsequences: false) {
            let field = String(decoding: item, as: UTF8.self)
            if field.hasPrefix("worktree ") {
                if let current { list.append(current) }
                let path = canonical(String(field.dropFirst(9)))
                current = Worktree(projectID: projectID, path: path, unavailable: !FileManager.default.fileExists(atPath: path), isMain: list.isEmpty)
            } else if field.hasPrefix("branch refs/heads/") {
                current?.branch = String(field.dropFirst(18))
            } else if field == "locked" || field.hasPrefix("locked ") { current?.locked = true }
            else if field == "prunable" || field.hasPrefix("prunable ") { current?.unavailable = true }
        }
        if let current { list.append(current) }
        return list
    }
    func branches(_ project: Project) async throws -> [String] {
        try await command(project.directory, ["for-each-ref", "--format=%(refname:short)", "refs/heads/"]).text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }
    // Actor methods can re-enter at awaits: explicit leases serialize full mutations.
    private var busy: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private func acquire(_ id: String) async {
        if busy.insert(id).inserted { return }
        await withCheckedContinuation { waiters[id, default: []].append($0) }
    }
    private func release(_ id: String) {
        if var queue = waiters[id], !queue.isEmpty {
            let next = queue.removeFirst(); waiters[id] = queue; next.resume()
        } else { busy.remove(id) }
    }
    func create(_ project: Project, path: String, branch: String, newBranch: Bool, start: String) async throws -> [Worktree] {
        await acquire(project.id); defer { release(project.id) }
        guard path.hasPrefix("/"), !FileManager.default.fileExists(atPath: path) else { throw WorkspaceError("目标必须是尚不存在的绝对路径") }
        _ = try await command(project.directory, ["check-ref-format", "--branch", branch])
        var args = ["worktree", "add"]
        if newBranch {
            guard !start.hasPrefix("-") else { throw WorkspaceError("无效的起点") }
            _ = try await command(project.directory, ["rev-parse", "--verify", "--end-of-options", start + "^{commit}"])
            args += ["-b", branch, "--", path, start]
        } else {
            guard try await branches(project).contains(branch) else { throw WorkspaceError("请选择已有本地分支") }
            args += ["--", path, branch]
        }
        do { _ = try await command(project.directory, args) }
        catch {
            let original = error.localizedDescription
            let remaining = (try? await worktrees(project)) ?? []
            let branchExists = (try? await branches(project))?.contains(branch) == true
            throw WorkspaceError(String(format: tr("%@\n状态已重新读取；目标目录%@，分支%@，共 %ld 个 worktree。请检查残留内容。"), original,
                                        tr(FileManager.default.fileExists(atPath: path) ? "存在" : "不存在"), tr(branchExists ? "存在" : "不存在"), remaining.count))
        }
        return try await worktrees(project)
    }
    func validateRemoval(_ project: Project, _ tree: Worktree) async throws {
        guard let actual = try await worktrees(project).first(where: { $0.id == tree.id }) else { throw WorkspaceError("worktree 已不存在，请刷新") }
        guard !actual.isMain, !actual.locked, !actual.unavailable else { throw WorkspaceError("无法移除主工作目录、锁定或不可用的 worktree") }
        guard try await command(tree.path, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]).output.isEmpty else { throw WorkspaceError("目录含未提交或未跟踪内容，请先处理改动") }
    }
    func remove(_ project: Project, _ tree: Worktree) async throws -> [Worktree] {
        await acquire(project.id); defer { release(project.id) }
        try await validateRemoval(project, tree)
        _ = try await command(project.directory, ["worktree", "remove", "--", tree.path])
        return try await worktrees(project)
    }
}

enum CLIProvider: String, CaseIterable, Identifiable {
    case codex, claude, terminal
    static let aiCases: [CLIProvider] = [.codex, .claude]
    var id: String { rawValue }
    var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .terminal: return tr("终端")
        }
    }
}

actor CLIResolver {
    private var cached: [String: String]?
    func environment() async throws -> [String: String] {
        if let cached { return cached }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let result = try await CommandRunner.run(shell, ["-lc", "/usr/bin/printf '\\0CODE_ELEVATOR_ENV\\0'; /usr/bin/env -0"], timeout: 8)
        guard result.status == 0 else { throw WorkspaceError("登录环境检测失败，请设置 CLI 绝对路径") }
        let marker = Data("\0CODE_ELEVATOR_ENV\0".utf8)
        guard let range = result.output.range(of: marker) else { throw WorkspaceError("无法读取登录环境") }
        var env: [String: String] = [:]
        for entry in result.output[range.upperBound...].split(separator: 0) {
            let pair = String(decoding: entry, as: UTF8.self).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 { env[String(pair[0])] = String(pair[1]) }
        }
        env["TERM"] = "xterm-256color"; cached = env; return env
    }
    func invalidate() { cached = nil }
    func resolveShell() async throws -> (String, [String: String]) {
        var env = (try? await environment()) ?? ProcessInfo.processInfo.environment
        let candidates = [env["SHELL"], ProcessInfo.processInfo.environment["SHELL"], "/bin/zsh", "/bin/bash"].compactMap { $0 }
        guard let shell = candidates.first(where: { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw WorkspaceError("找不到可用的登录 Shell")
        }
        env["SHELL"] = shell
        env["TERM"] = "xterm-256color"
        return (shell, env)
    }
    func resolve(_ provider: CLIProvider, override: String?) async throws -> (String, [String: String]) {
        guard provider != .terminal else { return try await resolveShell() }
        let env: [String: String]
        do { env = try await environment() }
        catch {
            guard let override, !override.isEmpty else { throw error }
            var fallback = ProcessInfo.processInfo.environment
            fallback["PATH"] = URL(fileURLWithPath: override).deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            fallback["TERM"] = "xterm-256color"; env = fallback
        }
        let paths: [String]
        if let override, !override.isEmpty {
            guard override.hasPrefix("/") else { throw WorkspaceError("CLI 路径必须为绝对路径") }
            paths = [override]
        } else { paths = (env["PATH"] ?? "").split(separator: ":").map { String($0) + "/" + provider.rawValue } }
        guard let executable = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) && !((try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) }) else { throw WorkspaceError(String(format: tr("找不到可执行的 %@，请安装后重新检测或设置绝对路径"), provider.title)) }
        return (executable, env)
    }
}
