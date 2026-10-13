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
        XCTAssertEqual(kill(parent, 0), -1)
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
        try Data("x".utf8).write(to: URL(fileURLWithPath: marker))
        codex.checkCompletions()
        codex.checkCompletions()
        XCTAssertEqual(completed, 1)
        codex.fail("测试结束")

        let claude = TerminalSession(tree: firstTree, provider: .claude)
        let claudeArgs = claude.completionArguments(for: "/opt/homebrew/bin/claude")
        XCTAssertEqual(claudeArgs.first, "--settings")
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(claudeArgs.last).utf8)) as? [String: Any])
        XCTAssertNotNil(settings["hooks"])
        claude.fail("测试结束")
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
}
