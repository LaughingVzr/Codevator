import XCTest
@testable import Codevator

final class CoreTests: XCTestCase {
    var root: URL!
    var repository: String { root.appendingPathComponent("项目 with space").path }
    let git = GitService()
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CodevatorTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("项目 with space"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func setupRepository() async throws -> Project {
        _ = try await git.command(repository, ["init", "-b", "main"])
        _ = try await git.command(repository, ["config", "user.name", "Test"])
        _ = try await git.command(repository, ["config", "user.email", "test@example.invalid"])
        try Data("initial".utf8).write(to: URL(fileURLWithPath: repository).appendingPathComponent("tracked"))
        _ = try await git.command(repository, ["add", "."])
        _ = try await git.command(repository, ["commit", "-m", "initial"])
        return try await git.register(repository)
    }
    func expectError(_ action: () async throws -> Void) async {
        do { try await action(); XCTFail("Expected rejection") } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }
    func testRunnerLargeOutputAndTimeout() async throws {
        let result = try await CommandRunner.run("/bin/sh", ["-c", "i=0; while [ $i -lt 6000 ]; do echo output; echo error >&2; i=$((i+1)); done"])
        XCTAssertEqual(result.status, 0); XCTAssertGreaterThan(result.output.count, 40000); XCTAssertGreaterThan(result.error.count, 30000)
        await expectError { _ = try await CommandRunner.run("/bin/sleep", ["3"], timeout: 0.05) }
    }
    func testRepositoryIdentityAndInvalidInputs() async throws {
        let project = try await setupRepository()
        let path = root.appendingPathComponent("linked 中文").path
        let list = try await git.create(project, path: path, branch: "feature", newBranch: true, start: "HEAD")
        XCTAssertEqual(list.count, 2); XCTAssertEqual(list.first?.branch, "main"); XCTAssertTrue(list.first?.isMain == true)
        let linked = try await git.register(path)
        XCTAssertEqual(linked.id, project.id)
        let sub = URL(fileURLWithPath: path).appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let nested = try await git.register(sub.path); XCTAssertEqual(nested.id, project.id)
        await expectError { _ = try await self.git.register(self.root.path) }
        let bare = root.appendingPathComponent("bare").path
        _ = try await CommandRunner.run("/usr/bin/git", ["init", "--bare", bare])
        await expectError { _ = try await self.git.register(bare) }
    }
    func testCreationFailuresAndExistingBranch() async throws {
        let project = try await setupRepository()
        let path = root.appendingPathComponent("feature").path
        _ = try await git.command(repository, ["branch", "existing"])
        let trees = try await git.create(project, path: path, branch: "existing", newBranch: false, start: "HEAD")
        XCTAssertEqual(trees.last?.branch, "existing")
        await expectError { _ = try await self.git.create(project, path: self.root.appendingPathComponent("occupied").path, branch: "existing", newBranch: false, start: "HEAD") }
        await expectError { _ = try await self.git.create(project, path: self.repository, branch: "other", newBranch: true, start: "HEAD") }
        await expectError { _ = try await self.git.create(project, path: self.root.appendingPathComponent("bad").path, branch: "bad name", newBranch: true, start: "HEAD") }
        await expectError { _ = try await self.git.create(project, path: self.root.appendingPathComponent("bad-start").path, branch: "valid", newBranch: true, start: "does-not-exist") }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: repository).appendingPathComponent("tracked")), Data("initial".utf8))
    }
    func testWorktreeDisplayNamesFollowCheckoutLayout() {
        let projectID = "/projects/repo/.git"
        let main = Worktree(projectID: projectID, path: "/projects/repo", branch: "dev", isMain: true)
        let nested = Worktree(projectID: projectID, path: "/worktrees/repo/light-glen/repo", branch: "feature")
        let flat = Worktree(projectID: projectID, path: "/worktrees/repo-feature", branch: "feature")
        XCTAssertEqual(main.displayName(projectName: "repo"), "main")
        XCTAssertEqual(nested.displayName(projectName: "repo"), "light-glen")
        XCTAssertEqual(flat.displayName(projectName: "repo"), "repo-feature")
    }
    func testAutomaticWorktreeLocationAndNameCollision() throws {
        let project = Project(id: "/projects/repo/.git", name: "repo", directory: root.appendingPathComponent("repo").path)
        let defaultRoot = root.appendingPathComponent("worktrees/repo").path
        XCTAssertEqual(WorktreeLocation.suggestedRoot(project: project, trees: []), defaultRoot)
        let linked = Worktree(projectID: project.id, path: root.appendingPathComponent("other/light-glen/repo").path)
        let linkedRoot = root.appendingPathComponent("other").path
        XCTAssertEqual(WorktreeLocation.suggestedRoot(project: project, trees: [linked]), linkedRoot)
        XCTAssertEqual(WorktreeLocation.automaticName(branch: "feature/search", root: linkedRoot), "feature-search")
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: linkedRoot).appendingPathComponent("feature-search"), withIntermediateDirectories: true)
        XCTAssertEqual(WorktreeLocation.automaticName(branch: "feature/search", root: linkedRoot), "feature-search-2")
        XCTAssertEqual(WorktreeLocation.path(root: linkedRoot, name: "feature-search-2", projectName: "repo"), root.appendingPathComponent("other/feature-search-2/repo").path)
        let generated = WorktreeLocation.randomName(root: linkedRoot, reservedNames: ["main"])
        let words = generated.split(separator: "-")
        XCTAssertEqual(words.count, 2)
        XCTAssertTrue(words.allSatisfy { $0.allSatisfy(\.isLetter) })
        XCTAssertNotEqual(generated, WorktreeLocation.randomName(root: linkedRoot, excluding: [generated]))
        XCTAssertEqual(WorktreeLocation.availableName(base: generated, root: linkedRoot, reservedNames: [generated]), generated + "-2")
        XCTAssertTrue(WorktreeLocation.validName("中文-worktree"))
        XCTAssertFalse(WorktreeLocation.validName("../outside"))
        XCTAssertFalse(WorktreeLocation.validName(" name "))
    }
    func testRemovalProtectionAndBranchPreservation() async throws {
        let project = try await setupRepository()
        let list = try await git.create(project, path: root.appendingPathComponent("feature").path, branch: "feature", newBranch: true, start: "HEAD")
        let tree = try XCTUnwrap(list.last)
        await expectError { _ = try await self.git.remove(project, list[0]) }
        let untracked = URL(fileURLWithPath: tree.path).appendingPathComponent("untracked")
        try Data("save me".utf8).write(to: untracked)
        await expectError { _ = try await self.git.remove(project, tree) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: untracked.path))
        try FileManager.default.removeItem(at: untracked)
        let tracked = URL(fileURLWithPath: tree.path).appendingPathComponent("tracked")
        try Data("changed".utf8).write(to: tracked)
        await expectError { _ = try await self.git.remove(project, tree) }
        _ = try await git.command(tree.path, ["checkout", "--", "tracked"])
        _ = try await git.command(repository, ["worktree", "lock", tree.path])
        await expectError { _ = try await self.git.remove(project, tree) }
        _ = try await git.command(repository, ["worktree", "unlock", tree.path])
        let remaining = try await git.remove(project, tree); XCTAssertEqual(remaining.count, 1)
        let branches = try await git.branches(project); XCTAssertTrue(branches.contains("feature"))
    }
    func testDetachedLockedAndMissingWorktree() async throws {
        let project = try await setupRepository()
        let path = root.appendingPathComponent("detached").path
        _ = try await git.command(repository, ["worktree", "add", "--detach", path, "HEAD"])
        _ = try await git.command(repository, ["worktree", "lock", path])
        let discovered = try await git.worktrees(project)
        let tree = try XCTUnwrap(discovered.last)
        XCTAssertNil(tree.branch); XCTAssertTrue(tree.locked)
        try FileManager.default.removeItem(atPath: path)
        let refreshed = try await git.worktrees(project)
        let missing = try XCTUnwrap(refreshed.last); XCTAssertTrue(missing.unavailable)
        await expectError { _ = try await self.git.remove(project, missing) }
    }
    func testConcurrentCreation() async throws {
        let project = try await setupRepository()
        async let a = git.create(project, path: root.appendingPathComponent("a").path, branch: "a", newBranch: true, start: "HEAD")
        async let b = git.create(project, path: root.appendingPathComponent("b").path, branch: "b", newBranch: true, start: "HEAD")
        _ = try await (a, b)
        let list = try await git.worktrees(project); XCTAssertEqual(list.count, 3)
    }
    func testConfigurationRoundTripAndCorruptionPreservation() throws {
        let file = root.appendingPathComponent("config/workspace.json"), store = ConfigurationStore(file: file)
        let config = WorkspaceConfiguration(projects: [Project(id: "git", name: "中文", directory: repository, expanded: false)], selection: "git\n/path", cliPaths: ["codex": "/custom/codex"])
        try store.save(config); XCTAssertEqual(try store.load(), config)
        let invalid = Data("invalid".utf8); try invalid.write(to: file)
        XCTAssertThrowsError(try store.load()); XCTAssertEqual(try Data(contentsOf: file), invalid)
        var future = config; future.schemaVersion = 99
        try JSONEncoder().encode(future).write(to: file)
        XCTAssertThrowsError(try store.load()); XCTAssertEqual(try JSONDecoder().decode(WorkspaceConfiguration.self, from: Data(contentsOf: file)).schemaVersion, 99)
    }
    func testCLIPathValidation() async throws {
        let resolver = CLIResolver()
        let (path, env) = try await resolver.resolve(.codex, override: "/bin/sh")
        XCTAssertEqual(path, "/bin/sh"); XCTAssertEqual(env["TERM"], "xterm-256color"); XCTAssertFalse(env["PATH", default: ""].isEmpty)
        await expectError { _ = try await resolver.resolve(.codex, override: "relative/path") }
        await expectError { _ = try await resolver.resolve(.claude, override: self.root.appendingPathComponent("missing").path) }
        let file = root.appendingPathComponent("nonexec"); try Data().write(to: file)
        await expectError { _ = try await resolver.resolve(.codex, override: file.path) }
    }
    @MainActor func testWorkspaceRegistrationRestorationAndRefresh() async throws {
        let project = try await setupRepository()
        let store = ConfigurationStore(file: root.appendingPathComponent("workspace.json"))
        let workspace = Workspace(store: store)
        await workspace.add(repository)
        XCTAssertEqual(workspace.configuration.projects.count, 1)
        let path = root.appendingPathComponent("linked").path
        _ = try await git.create(project, path: path, branch: "linked", newBranch: true, start: "HEAD")
        await workspace.add(path)
        XCTAssertEqual(workspace.configuration.projects.count, 1)
        XCTAssertEqual(workspace.trees[project.id]?.count, 2)
        let restored = Workspace(store: store); await restored.load()
        XCTAssertEqual(restored.selection, workspace.selection); XCTAssertTrue(restored.sessions.sessions.isEmpty)
        _ = try await git.command(repository, ["worktree", "remove", path])
        await restored.refreshAll(); XCTAssertEqual(restored.trees[project.id]?.count, 1)
        try FileManager.default.removeItem(atPath: repository)
        await restored.refreshAll(); XCTAssertNotNil(restored.projectErrors[project.id])
        XCTAssertTrue(restored.selectedTree?.unavailable == true)
    }
    @MainActor func testWorktreeDeletionCancellationAndRunningSessionProtection() async throws {
        let project = try await setupRepository()
        var accept = false, displayedPath = ""
        let workspace = Workspace(store: ConfigurationStore(file: root.appendingPathComponent("config.json")), confirmation: { _, message, _ in displayedPath = message; return accept })
        await workspace.add(repository)
        let path = root.appendingPathComponent("feature").path
        let created = await workspace.create(project, path: path, branch: "feature", newBranch: true, start: "HEAD")
        XCTAssertTrue(created)
        let tree = try XCTUnwrap(workspace.selectedTree)
        workspace.configuration.cliPaths["codex"] = "/bin/cat"
        await workspace.openSession(tree, provider: .codex)
        let tabID = try XCTUnwrap(workspace.sessions.selectedTab(for: tree.id)?.id)
        await workspace.removeTree(tree, project: project)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path)); XCTAssertTrue(displayedPath.isEmpty)
        await workspace.sessions.stop(tabID)
        await workspace.removeTree(tree, project: project)
        XCTAssertTrue(displayedPath.contains(path)); XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        accept = true
        await workspace.removeTree(tree, project: project)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path)); XCTAssertNil(workspace.selection)
        let branches = try await git.branches(project); XCTAssertTrue(branches.contains("feature"))
    }
    @MainActor func testProjectRemovalStopsSessionsOnlyAfterConfirmation() async throws {
        let project = try await setupRepository()
        var accept = false
        let workspace = Workspace(store: ConfigurationStore(file: root.appendingPathComponent("config.json")), confirmation: { _, _, _ in accept })
        await workspace.add(repository)
        let tree = try XCTUnwrap(workspace.selectedTree)
        let tabID = await workspace.sessions.start(tree, provider: .codex, override: "/bin/cat")
        await workspace.removeProject(project)
        XCTAssertEqual(workspace.configuration.projects.count, 1); XCTAssertTrue(workspace.sessions.sessions[tabID]?.active == true)
        accept = true; await workspace.removeProject(project)
        XCTAssertTrue(workspace.configuration.projects.isEmpty); XCTAssertTrue(workspace.sessions.sessions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository))
    }
    @MainActor func testQuitConfirmationAndMissingDirectorySession() async throws {
        let project = try await setupRepository()
        var accept = false, message = ""
        let workspace = Workspace(store: ConfigurationStore(file: root.appendingPathComponent("config.json")), confirmation: { _, text, _ in message = text; return accept })
        await workspace.add(repository)
        workspace.configuration.cliPaths["codex"] = "/bin/cat"
        let path = root.appendingPathComponent("feature").path
        _ = await workspace.create(project, path: path, branch: "feature", newBranch: true, start: "HEAD")
        let tree = try XCTUnwrap(workspace.selectedTree)
        await workspace.openSession(tree, provider: .codex)
        let tabID = try XCTUnwrap(workspace.sessions.selectedTab(for: tree.id)?.id)
        let session = try XCTUnwrap(workspace.sessions.sessions[tabID])
        let firstPid = session.terminal.process.shellPid
        workspace.selection = workspace.trees[project.id]?.first?.id
        workspace.selection = tree.id
        XCTAssertEqual(workspace.sessions.sessions[tabID]?.terminal.process.shellPid, firstPid)
        let cancelled = await workspace.prepareToExit()
        XCTAssertFalse(cancelled); XCTAssertTrue(session.active); XCTAssertFalse(workspace.sessions.isClosing)
        XCTAssertTrue(message.contains(path))
        _ = try await git.command(repository, ["worktree", "remove", path])
        await workspace.refreshAll()
        XCTAssertTrue(workspace.selectedTree?.unavailable == true)
        await workspace.openSession(tree, provider: .claude)
        XCTAssertNotNil(workspace.error); XCTAssertTrue(session.active)
        accept = true; let confirmed = await workspace.prepareToExit()
        XCTAssertTrue(confirmed); XCTAssertFalse(session.active); XCTAssertTrue(workspace.sessions.isClosing)
    }
    func testRunnerCancellation() async throws {
        let start = Date()
        let task = Task { try await CommandRunner.run("/bin/sleep", ["10"]) }
        try await Task.sleep(nanoseconds: 50_000_000); task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must reject") } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    @MainActor func testTabSelectionAndWorktreeIsolation() async throws {
        let project = try await setupRepository()
        let workspace = Workspace(store: ConfigurationStore(file: root.appendingPathComponent("config.json")))
        await workspace.add(repository)
        let main = try XCTUnwrap(workspace.selectedTree)
        _ = await workspace.create(project, path: root.appendingPathComponent("other").path, branch: "other", newBranch: true, start: "HEAD")
        let other = try XCTUnwrap(workspace.selectedTree)
        workspace.configuration.cliPaths = ["codex": "/bin/cat", "claude": "/bin/cat"]
        let blank = workspace.sessions.createTab(for: main.id)
        XCTAssertNil(workspace.sessions.selectedTab(for: other.id))
        await workspace.startSession(main, tabID: blank.id, provider: .claude)
        XCTAssertEqual(workspace.sessions.sessions[blank.id]?.provider, .claude)
        let second = workspace.sessions.createTab(for: main.id)
        XCTAssertEqual(workspace.sessions.selectedTab(for: main.id)?.id, second.id)
        workspace.selection = main.id
        workspace.sessions.markUnread(blank.id)
        workspace.selectTab(blank.id, in: main.id)
        XCTAssertEqual(workspace.sessions.selectedTab(for: main.id)?.provider, .claude)
        XCTAssertEqual(workspace.sessions.unreadCount(in: main.id), 0)
        XCTAssertNil(workspace.sessions.selectedTab(for: other.id))
        await workspace.sessions.stopAll()
    }
}
