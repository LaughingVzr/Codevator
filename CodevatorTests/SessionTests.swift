import XCTest
import AppKit
import SwiftTerm
@testable import Codevator

@MainActor
final class SessionTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SessionTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func tree(_ name: String) throws -> Worktree {
        let path = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return Worktree(projectID: "test", path: GitService.canonical(path.path), branch: name)
    }
    func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 4) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        return condition()
    }
    func text(_ session: TerminalSession) -> String {
        // Buffer export includes NUL continuation cells for double-width glyphs.
        String(decoding: session.terminal.getTerminal().getBufferAsData(), as: UTF8.self).replacingOccurrences(of: "\0", with: "")
    }
    func testPTYDirectoryANSIUnicodeInputResizeAndExit() async throws {
        let tree = try tree("目录 with space")
        let session = TerminalSession(tree: tree, provider: .codex)
        defer { if session.active { Task { await session.stop() } } }
        session.terminal.resize(cols: 240, rows: 40)
        session.launch(executable: "/bin/sh", environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "LC_CTYPE": "UTF-8"], args: ["-c", "pwd; printf '\\033[31mCOLOR_OK\\033[0m\\n'; read line; printf 'INPUT:%s\\n' \"$line\"; stty size; exit 7"])
        let ready = await waitFor { self.text(session).contains("COLOR_OK") }; XCTAssertTrue(ready)
        XCTAssertTrue(text(session).contains(tree.path), text(session)); XCTAssertFalse(text(session).contains("\u{1b}[31m"))
        session.terminal.resize(cols: 100, rows: 30)
        session.terminal.insertText("中文测试\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        let exited = await waitFor { !session.active }; XCTAssertTrue(exited)
        let delivered = await waitFor { self.text(session).contains("INPUT:中文测试") && self.text(session).contains("30 100") }
        XCTAssertTrue(delivered, text(session)); XCTAssertEqual(session.state, String(format: tr("已退出（%d）"), 7))
        await session.stop()
    }
    func testIndependentBackgroundSessionsAndBoundedBuffer() async throws {
        let a = TerminalSession(tree: try tree("a"), provider: .codex)
        let b = TerminalSession(tree: try tree("b"), provider: .claude)
        a.launch(executable: "/bin/sh", environment: ["PATH": "/usr/bin:/bin"], args: ["-c", "echo A_ONLY; sleep .1; echo A_BACKGROUND; read x; echo A_INPUT:$x"])
        b.launch(executable: "/bin/sh", environment: ["PATH": "/usr/bin:/bin"], args: ["-c", "echo B_ONLY; read x; echo B_INPUT:$x"])
        let apid = a.terminal.process.shellPid, bpid = b.terminal.process.shellPid
        let visible = await waitFor { self.text(a).contains("A_BACKGROUND") && self.text(b).contains("B_ONLY") }; XCTAssertTrue(visible)
        XCTAssertNotEqual(apid, bpid)
        XCTAssertFalse(text(a).contains("B_ONLY")); XCTAssertFalse(text(b).contains("A_ONLY"))
        a.terminal.process.send(data: Array("hello\n".utf8)[...])
        let input = await waitFor { self.text(a).contains("A_INPUT:hello") }; XCTAssertTrue(input)
        XCTAssertTrue(b.active); XCTAssertEqual(b.terminal.process.shellPid, bpid)
        a.terminal.feed(text: String(repeating: "large output\r\n", count: 10000))
        XCTAssertLessThan(a.terminal.getTerminal().getBufferAsData().count, 200000)
        await a.stop(); await b.stop()
    }
    func testStopReapsProcessGroupWithoutKillingExternalProcess() async throws {
        let tree = try tree("children")
        let external = Process(); external.executableURL = URL(fileURLWithPath: "/bin/sleep"); external.arguments = ["30"]
        try external.run(); defer { if external.isRunning { external.terminate(); external.waitUntilExit() } }
        let session = TerminalSession(tree: tree, provider: .codex)
        session.launch(executable: "/bin/sh", environment: ["PATH": "/usr/bin:/bin"], args: ["-c", "sleep 30 & child=$!; echo $child > child.pid; wait"])
        let file = URL(fileURLWithPath: tree.path).appendingPathComponent("child.pid")
        let ready = await waitFor { FileManager.default.fileExists(atPath: file.path) }; XCTAssertTrue(ready)
        let child = try XCTUnwrap(Int32(String(contentsOf: file).trimmingCharacters(in: .whitespacesAndNewlines)))
        let parent = session.terminal.process.shellPid
        XCTAssertEqual(session.processGroup, parent)
        await session.stop()
        XCTAssertFalse(session.active); XCTAssertFalse(session.terminal.process.running)
        let parentGone = await waitFor { kill(parent, 0) == -1 }; XCTAssertTrue(parentGone)
        let childGone = await waitFor { kill(child, 0) == -1 }; XCTAssertTrue(childGone)
        XCTAssertTrue(external.isRunning)
    }
    func testManagerDeduplicationRestartAndFailure() async throws {
        let tree = try tree("managed"), manager = SessionManager()
        let tab = manager.createTab(for: tree.id)
        await manager.start(tree, tabID: tab.id, provider: .codex, override: "/bin/cat")
        let first = try XCTUnwrap(manager.sessions[tab.id])
        let pid = first.terminal.process.shellPid
        await manager.start(tree, tabID: tab.id, provider: .claude, override: "/bin/cat")
        XCTAssertTrue(manager.sessions[tab.id] === first); XCTAssertEqual(manager.sessions[tab.id]?.provider, .codex)
        await manager.stop(tab.id)
        await manager.start(tree, tabID: tab.id, provider: .claude, override: "/bin/cat")
        let second = try XCTUnwrap(manager.sessions[tab.id]); XCTAssertFalse(first === second)
        XCTAssertNotEqual(pid, second.terminal.process.shellPid)
        await manager.remove(tree.id); XCTAssertNil(manager.sessions[tab.id])
        let failed = manager.createTab(for: tree.id)
        await manager.start(tree, tabID: failed.id, provider: .codex, override: root.appendingPathComponent("missing").path)
        XCTAssertTrue(manager.sessions[failed.id]?.state.hasPrefix(tr("失败：")) == true)
        XCTAssertFalse(manager.sessions[failed.id]?.active == true)
        await manager.remove(tree.id)
    }
    func testPlainTerminalStartsInWorktreeWithoutAIIndicators() async throws {
        let tree = try tree("plain-terminal"), manager = SessionManager()
        let tab = manager.createTab(for: tree.id, provider: .terminal)
        var completions = 0
        manager.onTurnCompleted = { _, _ in completions += 1 }
        // A configured AI path must not affect the plain shell.
        await manager.start(tree, tabID: tab.id, provider: .terminal, override: "/not/a/real/cli")
        let session = try XCTUnwrap(manager.sessions[tab.id])
        XCTAssertTrue(session.active, session.state)
        XCTAssertEqual(session.provider, .terminal)
        let cwdFile = URL(fileURLWithPath: tree.path).appendingPathComponent("shell-cwd.txt")
        session.terminal.process.send(data: Array("pwd > shell-cwd.txt; printf 'SHELL_READY\\n'\n".utf8)[...])
        let ready = await waitFor({ FileManager.default.fileExists(atPath: cwdFile.path) && self.text(session).contains("SHELL_READY") }, timeout: 12)
        XCTAssertTrue(ready, text(session))
        let actualDirectory = try String(contentsOf: cwdFile).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(URL(fileURLWithPath: actualDirectory).resolvingSymlinksInPath().path,
                       URL(fileURLWithPath: tree.path).resolvingSymlinksInPath().path)
        XCTAssertFalse(session.awaitingResponse)
        XCTAssertEqual(manager.pendingCount(in: tree.id), 0)
        XCTAssertEqual(manager.unreadCount(in: tree.id), 0)
        XCTAssertEqual(completions, 0)
        await manager.stop(tab.id)
        XCTAssertFalse(session.active)
    }
    func testMultipleTabsInOneWorktreeStayIndependent() async throws {
        let tree = try tree("shared"), manager = SessionManager()
        let codex = manager.createTab(for: tree.id, provider: .codex)
        await manager.start(tree, tabID: codex.id, provider: .codex, override: "/bin/cat")
        let first = try XCTUnwrap(manager.sessions[codex.id])
        let firstPID = first.terminal.process.shellPid
        let claude = manager.createTab(for: tree.id, provider: .claude)
        await manager.start(tree, tabID: claude.id, provider: .claude, override: "/bin/cat")
        let second = try XCTUnwrap(manager.sessions[claude.id])
        let anotherCodex = manager.createTab(for: tree.id, provider: .codex)
        await manager.start(tree, tabID: anotherCodex.id, provider: .codex, override: "/bin/cat")
        let third = try XCTUnwrap(manager.sessions[anotherCodex.id])
        XCTAssertEqual(manager.tabs(for: tree.id).count, 3)
        XCTAssertNotEqual(third.terminal.process.shellPid, firstPID)
        XCTAssertEqual(manager.selectedTab(for: tree.id)?.id, anotherCodex.id)
        XCTAssertNotEqual(firstPID, second.terminal.process.shellPid)
        manager.select(codex.id, in: tree.id)
        XCTAssertEqual(manager.selectedTab(for: tree.id)?.id, codex.id)
        XCTAssertEqual(first.terminal.process.shellPid, firstPID)
        XCTAssertTrue(first.active && second.active)
        await manager.close(codex.id)
        XCTAssertFalse(first.active)
        XCTAssertTrue(second.active)
        XCTAssertEqual(manager.selectedTab(for: tree.id)?.id, claude.id)
        await manager.remove(tree.id)
        XCTAssertFalse(second.active)
        XCTAssertFalse(third.active)
        XCTAssertTrue(manager.tabs(for: tree.id).isEmpty)
    }
    func testTerminalFontSizeUpdatesOpenTabsAndPersistsForNewTabs() async throws {
        let suite = "CodevatorFontTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = SessionManager(defaults: defaults)
        let tree = try tree("font-size")
        let firstTab = manager.createTab(for: tree.id)
        await manager.start(tree, tabID: firstTab.id, provider: .codex, override: "/bin/cat")
        let first = try XCTUnwrap(manager.sessions[firstTab.id])
        let pid = first.terminal.process.shellPid
        first.terminal.feed(text: "Visible before zoom")

        manager.setFontSize(17)
        XCTAssertEqual(first.terminal.font.pointSize, 17)
        XCTAssertEqual(first.terminal.process.shellPid, pid)
        XCTAssertTrue(text(first).contains("Visible before zoom"))

        let secondTab = manager.createTab(for: tree.id)
        await manager.start(tree, tabID: secondTab.id, provider: .claude, override: "/bin/cat")
        let second = try XCTUnwrap(manager.sessions[secondTab.id])
        XCTAssertEqual(second.terminal.font.pointSize, 17)
        XCTAssertEqual(SessionManager(defaults: defaults).fontSize, 17)

        manager.adjustFontSize(by: -1)
        XCTAssertEqual(first.terminal.font.pointSize, 16)
        XCTAssertEqual(second.terminal.font.pointSize, 16)
        manager.setFontSize(100)
        XCTAssertEqual(manager.fontSize, TerminalFontSize.range.upperBound)
        manager.resetFontSize()
        XCTAssertEqual(manager.fontSize, TerminalFontSize.defaultValue)
        await manager.stopAll()
    }
    func testBlankTabCanChooseProviderLater() async throws {
        let tree = try tree("blank"), manager = SessionManager()
        let blank = manager.createTab(for: tree.id)
        XCTAssertNil(blank.provider)
        XCTAssertNil(manager.sessions[blank.id])
        await manager.start(tree, tabID: blank.id, provider: .claude, override: "/bin/cat")
        XCTAssertEqual(manager.selectedTab(for: tree.id)?.provider, .claude)
        XCTAssertTrue(manager.sessions[blank.id]?.active == true)
        await manager.remove(tree.id)
    }
    func testCompletionHooksAndUnreadCounts() async throws {
        let firstTree = try tree("notifications"), secondTree = try tree("other-notifications")
        let manager = SessionManager()
        let firstTab = manager.createTab(for: firstTree.id, provider: .codex)
        let secondTab = manager.createTab(for: firstTree.id, provider: .claude)
        let otherTab = manager.createTab(for: secondTree.id, provider: .codex)
        manager.markUnread(firstTab.id)
        manager.markUnread(secondTab.id)
        manager.markUnread(otherTab.id)
        XCTAssertEqual(manager.unreadCount(in: firstTree.id), 2)
        XCTAssertEqual(manager.unreadCount(forProject: firstTree.projectID), 3)
        manager.markRead(secondTab.id)
        XCTAssertEqual(manager.unreadCount(in: firstTree.id), 1)
        await manager.close(firstTab.id)
        XCTAssertEqual(manager.unreadCount(forProject: firstTree.projectID), 1)

        let codex = TerminalSession(tree: firstTree, provider: .codex)
        let args = codex.completionArguments(for: "/opt/homebrew/bin/codex")
        XCTAssertEqual(args.first, "-c")
        let payload = try XCTUnwrap(args.last?.replacingOccurrences(of: "notify=", with: ""))
        let command = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String])
        let marker = try XCTUnwrap(command.last)
        XCTAssertEqual(command.first, "/bin/sh")
        var completed = 0
        codex.onTurnCompleted = { completed += 1 }
        func invokeHook(_ event: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: try XCTUnwrap(command.first))
            process.arguments = Array(command.dropFirst()) + [event]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        try invokeHook(#"{"type":"approval-requested","input-messages":["Review code"]}"#)
        try invokeHook(#"{"type":"agent-turn-complete","input-messages":["Generate a concise, single-line task title for this task"],"last-assistant-message":"{\"title\":\"Review code\"}"#)
        codex.checkCompletions()
        XCTAssertEqual(completed, 0)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: marker)).count, 0)
        try invokeHook(#"{"type":"agent-turn-complete","input-messages":["Review code"],"last-assistant-message":"Done"}"#)
        codex.checkCompletions()
        XCTAssertEqual(completed, 0)
        codex.launch(executable: "/bin/cat", environment: ["PATH": "/usr/bin:/bin"])
        codex.terminal.insertText("Review code\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(codex.awaitingResponse)
        try invokeHook(#"{"type":"agent-turn-complete","input-messages":["Review code"],"last-assistant-message":"Done"}"#)
        codex.checkCompletions()
        XCTAssertEqual(completed, 1)
        await codex.stop()

        let claude = TerminalSession(tree: firstTree, provider: .claude)
        let claudeArgs = claude.completionArguments(for: "/opt/homebrew/bin/claude")
        XCTAssertEqual(claudeArgs.first, "--settings")
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(claudeArgs.last).utf8)) as? [String: Any])
        XCTAssertNotNil(settings["hooks"])
        claude.fail("测试结束")
    }

    func testAICompletionPlaysSoundAndBackgroundNotificationOnce() throws {
        let tree = try tree("sound")
        let workspace = Workspace(store: ConfigurationStore(file: root.appendingPathComponent("sound-workspace.json")))
        var soundCount = 0
        var notificationCount = 0
        workspace.playCompletionSound = { soundCount += 1 }
        workspace.postCompletionNotification = { _, _, _ in notificationCount += 1 }

        let codexTab = workspace.sessions.createTab(for: tree.id, provider: .codex)
        workspace.sessions.onTurnCompleted?(codexTab.id, TerminalSession(tree: tree, provider: .codex))
        XCTAssertEqual(soundCount, 1)
        XCTAssertEqual(notificationCount, 1)

        let terminalTab = workspace.sessions.createTab(for: tree.id, provider: .terminal)
        workspace.sessions.onTurnCompleted?(terminalTab.id, TerminalSession(tree: tree, provider: .terminal))
        workspace.sessions.onTurnCompleted?("closed-tab", TerminalSession(tree: tree, provider: .codex))
        XCTAssertEqual(soundCount, 1)
        XCTAssertEqual(notificationCount, 1)
    }
    func testAIActivityTracksSubmittedTurnsNotPermissionReturnsOrOpenProcesses() async throws {
        let tree = try tree("turn-activity")
        let manager = SessionManager()
        let tab = manager.createTab(for: tree.id, provider: .codex)
        let session = TerminalSession(tree: tree, provider: .codex)
        let arguments = session.completionArguments(for: "/opt/homebrew/bin/codex")
        let payload = try XCTUnwrap(arguments.last?.replacingOccurrences(of: "notify=", with: ""))
        let command = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String])
        let marker = try XCTUnwrap(command.last)
        manager.sessions[tab.id] = session
        var completions = 0
        session.onTurnCompleted = { completions += 1 }
        session.launch(executable: "/bin/cat", environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(session.state, tr("已就绪"))
        session.terminal.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(manager.pendingCount(in: tree.id), 0)
        session.terminal.insertText("/permissions\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(manager.pendingCount(in: tree.id), 0)
        session.terminal.insertText("1\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(manager.pendingCount(in: tree.id), 0)
        XCTAssertEqual(session.state, tr("已就绪"))
        session.terminal.insertText("/perm\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        session.terminal.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(manager.pendingCount(in: tree.id), 0)
        // Codex may send the selected label and an extra Return while closing
        // the permission menu. Neither is an agent request.
        session.terminal.insertText("Full Access\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(manager.pendingCount(in: tree.id), 0)
        session.terminal.insertText("/permission\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        let permissionResult = Array("Permission selection requested: Full Access".utf8)
        session.terminal.dataReceived(slice: permissionResult[..<15])
        session.terminal.dataReceived(slice: permissionResult[15...])
        XCTAssertEqual(manager.pendingCount(in: tree.id), 0)
        try Data("x".utf8).write(to: URL(fileURLWithPath: marker))
        session.checkCompletions()
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(session.state, tr("已就绪"))

        // If input tracking missed the slash command, the Codex result line
        // still corrects a false pending state without posting a notification.
        session.terminal.insertText("Full Access\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(manager.pendingCount(in: tree.id), 1)
        let styledPermissionResult = Array("Permission \u{1B}[36mselection\u{1B}[0m requested: Full Access".utf8)
        session.terminal.dataReceived(slice: styledPermissionResult[..<18])
        session.terminal.dataReceived(slice: styledPermissionResult[18...])
        XCTAssertEqual(manager.pendingCount(in: tree.id), 0)
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(session.state, tr("已就绪"))

        session.terminal.insertText("Full Access", replacementRange: NSRange(location: NSNotFound, length: 0))
        session.terminal.dataReceived(slice: permissionResult[...])
        session.terminal.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(manager.pendingCount(in: tree.id), 0)

        session.terminal.insertText("Review this change\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(manager.pendingCount(in: tree.id), 1)
        XCTAssertEqual(session.state, tr("回复中"))
        try Data("xx".utf8).write(to: URL(fileURLWithPath: marker))
        session.checkCompletions()
        XCTAssertEqual(manager.pendingCount(in: tree.id), 0)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(session.state, tr("已完成"))
        XCTAssertTrue(session.active)
        session.terminal.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(manager.pendingCount(in: tree.id), 0)
        // A locally tracked draft can be stale after Ctrl+A/Ctrl+K editing.
        // The actual Codex menu must still clear the false running state.
        session.terminal.insertText("stale", replacementRange: NSRange(location: NSNotFound, length: 0))
        session.terminal.insertText("/permission\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(manager.pendingCount(in: tree.id), 1)
        let menu = Array("\u{1B}[2JUpdate Model Permissions".utf8)
        session.terminal.dataReceived(slice: menu[...])
        XCTAssertEqual(manager.pendingCount(in: tree.id), 0)
        session.terminal.insertText("1\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        let unchangedPrompt = Array("\u{1B}[2JAsk Codex to do anything".utf8)
        session.terminal.dataReceived(slice: unchangedPrompt[...])
        XCTAssertEqual(manager.pendingCount(in: tree.id), 0)
        session.terminal.insertText("A new actual question\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(manager.pendingCount(in: tree.id), 1)
        await session.stop()
    }
    func testCompletionMarkerNotifiesWithoutPolling() async throws {
        let session = TerminalSession(tree: try tree("completion-event"), provider: .codex)
        let arguments = session.completionArguments(for: "/opt/homebrew/bin/codex")
        let payload = try XCTUnwrap(arguments.last?.replacingOccurrences(of: "notify=", with: ""))
        let command = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String])
        let marker = try XCTUnwrap(command.last)
        var completions = 0
        session.onTurnCompleted = { completions += 1 }
        session.launch(executable: "/bin/cat", environment: ["PATH": "/usr/bin:/bin"])
        session.monitorCompletions()
        session.terminal.insertText("Check this change\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(session.awaitingResponse)
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: marker))
        file.seekToEndOfFile()
        file.write(Data("x".utf8))
        try file.close()
        let notified = await waitFor { completions == 1 && !session.awaitingResponse }
        XCTAssertTrue(notified, "Appending a completion marker should notify the session")
        XCTAssertEqual(session.state, tr("已完成"))
        await session.stop()
    }
    func testRapidSessionStopReapsChildren() async throws {
        for index in 0..<8 {
            let session = TerminalSession(tree: try tree("rapid-stop-\(index)"), provider: .terminal)
            session.launch(executable: "/bin/sh", environment: ["PATH": "/usr/bin:/bin"], args: ["-c", "sleep 30"])
            let pid = session.terminal.process.shellPid
            XCTAssertGreaterThan(pid, 0)
            await session.stop()
            var status: Int32 = 0
            XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1, "Stopped child should already be reaped")
            XCTAssertEqual(errno, ECHILD)
        }
    }
    func testPendingAndUnreadIndicatorsCoexistAcrossWorktrees() async throws {
        let firstTree = try tree("pending-and-completed")
        let secondPath = try tree("another-project").path
        let secondTree = Worktree(projectID: "another-project", path: secondPath, branch: "main")
        let manager = SessionManager()

        func trackedSession(for tree: Worktree) throws -> (TerminalSession, String) {
            let session = TerminalSession(tree: tree, provider: .codex)
            let arguments = session.completionArguments(for: "/opt/homebrew/bin/codex")
            let payload = try XCTUnwrap(arguments.last?.replacingOccurrences(of: "notify=", with: ""))
            let command = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String])
            let marker = try XCTUnwrap(command.last)
            session.launch(executable: "/bin/cat", environment: ["PATH": "/usr/bin:/bin"])
            return (session, marker)
        }

        let waitingTab = manager.createTab(for: firstTree.id)
        let completedTab = manager.createTab(for: firstTree.id)
        let otherTab = manager.createTab(for: secondTree.id)
        let (waiting, _) = try trackedSession(for: firstTree)
        let (completed, marker) = try trackedSession(for: firstTree)
        let (other, _) = try trackedSession(for: secondTree)
        manager.sessions[waitingTab.id] = waiting
        manager.sessions[completedTab.id] = completed
        manager.sessions[otherTab.id] = other
        defer { Task { await manager.stopAll() } }

        XCTAssertEqual(manager.pendingCount(in: firstTree.id), 0)
        waiting.terminal.insertText("first prompt\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        completed.terminal.insertText("second prompt\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        other.terminal.insertText("other prompt\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(manager.pendingCount(in: firstTree.id), 2)
        XCTAssertEqual(manager.pendingCount(forProject: firstTree.projectID), 2)
        XCTAssertEqual(manager.pendingCount(forProject: secondTree.projectID), 1)

        try Data("x".utf8).write(to: URL(fileURLWithPath: marker))
        completed.checkCompletions()
        manager.markUnread(completedTab.id)
        XCTAssertEqual(manager.pendingCount(in: firstTree.id), 1)
        XCTAssertEqual(manager.unreadCount(in: firstTree.id), 1)
        XCTAssertEqual(manager.pendingCount(forProject: firstTree.projectID), 1)
        XCTAssertEqual(manager.unreadCount(forProject: firstTree.projectID), 1)
        XCTAssertEqual(manager.pendingCount(forProject: secondTree.projectID), 1)
        await manager.close(waitingTab.id)
        XCTAssertEqual(manager.pendingCount(in: firstTree.id), 0)
        XCTAssertEqual(manager.unreadCount(in: firstTree.id), 1)
        await manager.stopAll()
    }
    func testInstalledCodexAndClaudeStartupWithoutApproval() async throws {
        let executables: [(CLIProvider, String)] = [(.codex, "/opt/homebrew/bin/codex"), (.claude, "/opt/homebrew/bin/claude")]
        let resolver = CLIResolver()
        for (provider, executable) in executables {
            guard FileManager.default.isExecutableFile(atPath: executable) else { throw XCTSkip("本机 CLI 未安装：\(executable)") }
            let directory = try tree("smoke-" + provider.rawValue)
            let session = TerminalSession(tree: directory, provider: provider)
            let (path, environment) = try await resolver.resolve(provider, override: executable)
            session.launch(executable: path, environment: environment)
            let rendered = await waitFor({ !self.text(session).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, timeout: 15)
            if provider == .claude, !rendered, session.active {
                await session.stop()
                throw XCTSkip("Claude Code 进程已启动，但 15 秒内没有终端输出，暂时无法验收其交互界面")
            }
            XCTAssertTrue(rendered, provider.title + " 应产生终端界面；状态：" + session.state)
            XCTAssertTrue(session.active, provider.title + " 应保持交互进程")
            // Do not accept trust/authorization prompts or send a model request.
            session.terminal.resize(cols: 110, rows: 35)
            await session.stop()
            XCTAssertFalse(session.active)
        }
    }
    func testArrowKeyAndControlCInIsolatedTerminalView() async throws {
        let session = TerminalSession(tree: try tree("keys"), provider: .codex)
        session.launch(executable: "/bin/sh", environment: ["PATH": "/usr/bin:/bin"], args: ["-c", "stty -icanon -echo; echo READY; dd bs=1 count=3 2>/dev/null | od -An -tx1; echo WAITING; sleep 30"])
        let ready = await waitFor { self.text(session).contains("READY") }; XCTAssertTrue(ready)
        // A unit-test event on a newly constructed view, not OS input injection.
        let arrow = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: 126))
        session.terminal.keyDown(with: arrow)
        let received = await waitFor { self.text(session).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").contains("1b 5b 41") }; XCTAssertTrue(received, text(session))
        let waiting = await waitFor { self.text(session).contains("WAITING") }; XCTAssertTrue(waiting)
        let interrupt = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{3}", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        session.terminal.keyDown(with: interrupt)
        let exited = await waitFor { !session.active }; XCTAssertTrue(exited)
        await session.stop()
    }
    func testCommandArrowsSendLineNavigationToEveryCLI() async throws {
        for provider in [CLIProvider.terminal, .codex, .claude] {
            let session = TerminalSession(tree: try tree("command-arrows-" + provider.rawValue), provider: provider)
            session.launch(executable: "/bin/sh", environment: ["PATH": "/usr/bin:/bin"], args: ["-c", "stty -icanon -echo; echo READY; dd bs=1 count=2 2>/dev/null | od -An -tx1; echo DONE"])
            let ready = await waitFor { self.text(session).contains("READY") }
            XCTAssertTrue(ready, provider.title)
            for (keyCode, character) in [(UInt16(123), "\u{F702}"), (UInt16(124), "\u{F703}")] {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil,
                    characters: character, charactersIgnoringModifiers: character,
                    isARepeat: false, keyCode: keyCode))
                XCTAssertTrue(session.terminal.performKeyEquivalent(with: event), provider.title)
            }
            let received = await waitFor { self.text(session).contains("DONE") }
            XCTAssertTrue(received, provider.title + ": " + text(session))
            XCTAssertTrue(text(session).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").contains("01 05"),
                          provider.title + ": " + text(session))
            await session.stop()
        }
    }
    func testMarkedTextCommitsOnlyAfterInputMethodConfirmation() async throws {
        let session = TerminalSession(tree: try tree("ime"), provider: .codex)
        session.launch(executable: "/bin/cat", environment: ["PATH": "/usr/bin:/bin", "LC_CTYPE": "UTF-8"])
        session.terminal.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(session.terminal.hasMarkedText())
        XCTAssertFalse(text(session).contains("zhongwen"))
        session.terminal.insertText("中文\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(session.terminal.hasMarkedText())
        let received = await waitFor { self.text(session).contains("中文") }; XCTAssertTrue(received)
        await session.stop()
    }
    func testUncommittedTextDoesNotRemainOverCodexPromptAfterWindowSwitch() async throws {
        let session = TerminalSession(tree: try tree("ime-window"), provider: .codex)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(session.terminal)
        session.launch(executable: "/bin/cat", environment: ["PATH": "/usr/bin:/bin"])
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        session.terminal.setMarkedText("旧输入", selectedRange: NSRange(location: 3, length: 0),
                                       replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(session.terminal.hasMarkedText())
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertFalse(session.terminal.hasMarkedText())
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(text(session).contains("旧输入"))

        session.terminal.setMarkedText("旧输入", selectedRange: NSRange(location: 3, length: 0),
                                       replacementRange: NSRange(location: NSNotFound, length: 0))
        session.terminal.send(source: session.terminal, data: ArraySlice<UInt8>([13]))
        XCTAssertFalse(session.terminal.hasMarkedText())
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(text(session).contains("旧输入"))
        session.terminal.setMarkedText("旧输入", selectedRange: NSRange(location: 3, length: 0),
                                       replacementRange: NSRange(location: NSNotFound, length: 0))
        session.terminal.send(source: session.terminal, data: ArraySlice("\u{1B}[13u".utf8))
        XCTAssertFalse(session.terminal.hasMarkedText())
        session.terminal.setMarkedText("旧输入", selectedRange: NSRange(location: 3, length: 0),
                                       replacementRange: NSRange(location: NSNotFound, length: 0))
        session.terminal.removeFromSuperview()
        XCTAssertFalse(session.terminal.hasMarkedText())
        await session.stop()
    }
    func testTerminalCopyPreservesUnicode() throws {
        let pasteboard = NSPasteboard.general
        let original = (pasteboard.pasteboardItems ?? []).map { item in
            let clone = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { clone.setData(data, forType: type) } }
            return clone
        }
        defer { pasteboard.clearContents(); if !original.isEmpty { pasteboard.writeObjects(original) } }
        let session = TerminalSession(tree: try tree("copy"), provider: .codex)
        session.terminal.feed(text: "clipboard 中文 text")
        session.terminal.selectAll(nil)
        session.terminal.copy(self)
        let copied = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(copied.contains("clipboard 中文 text"))
        session.terminal.selection.selectNone()
        session.terminal.copy(self)
        XCTAssertEqual(pasteboard.string(forType: .string), copied)
    }

    func testCommandCopyKeepsSelectionDuringKeyDispatch() throws {
        let pasteboard = NSPasteboard.general
        let original = (pasteboard.pasteboardItems ?? []).map { item in
            let clone = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { clone.setData(data, forType: type) } }
            return clone
        }
        defer { pasteboard.clearContents(); if !original.isEmpty { pasteboard.writeObjects(original) } }
        let session = TerminalSession(tree: try tree("command-copy"), provider: .codex)
        session.terminal.feed(text: "快捷键复制 中文")
        for (character, keyCode) in [("a", UInt16(0)), ("c", UInt16(8))] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode))
            XCTAssertTrue(session.terminal.performKeyEquivalent(with: event))
        }
        XCTAssertTrue(pasteboard.string(forType: .string)?.contains("快捷键复制 中文") == true)
    }

    func testCodexUnsentInputCanBeCopiedWhileMouseTrackingIsEnabled() throws {
        let pasteboard = NSPasteboard.general
        let original = (pasteboard.pasteboardItems ?? []).map { item in
            let clone = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { clone.setData(data, forType: type) } }
            return clone
        }
        defer { pasteboard.clearContents(); if !original.isEmpty { pasteboard.writeObjects(original) } }
        let view = TerminalSession(tree: try tree("tracked-copy"), provider: .codex).terminal
        view.frame = CGRect(x: 0, y: 0, width: 640, height: 240)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        // Codex renders its editable prompt in the alternate terminal buffer.
        // Mouse reporting can be enabled there even though the text is still
        // an unsent draft, so a normal drag must remain a local selection.
        view.feed(text: "\u{1B}[?1049h\u{1B}[?1002hCOPYABLE TEXT")
        XCTAssertNotEqual(view.getTerminal().mouseMode, .off)

        func mouse(_ type: NSEvent.EventType, x: CGFloat, number: Int) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type,
                                             location: CGPoint(x: x, y: view.bounds.height - 10),
                                             modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: number, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try mouse(.leftMouseDown, x: 5, number: 1))
        view.mouseDragged(with: try mouse(.leftMouseDragged, x: 105, number: 2))
        view.mouseUp(with: try mouse(.leftMouseUp, x: 105, number: 3))
        XCTAssertEqual(view.getSelection(), "COPYABLE TEXT")
        view.copy(self)
        XCTAssertEqual(pasteboard.string(forType: .string), "COPYABLE TEXT")
    }
}
