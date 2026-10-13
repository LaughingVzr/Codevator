import XCTest
import AppKit

final class TerminalEditingUITests: XCTestCase {
    func testMultipleTabsAndBlankTabSelection() throws {
        continueAfterFailure = false
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CodevatorTabsUI-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixture = repository.appendingPathComponent(".build/ui-fixtures/Project-A").path
        guard FileManager.default.fileExists(atPath: fixture + "/.git") else { throw XCTSkip("Requires disposable Git fixture") }
        let config = folder.appendingPathComponent("workspace.json")
        let common = fixture + "/.git"
        let data: [String: Any] = ["schemaVersion": 1, "projects": [["id": common, "name": "UI Test", "directory": fixture, "expanded": true]], "selection": common + "\n" + fixture, "cliPaths": ["codex": "/bin/cat", "claude": "/bin/cat"]]
        try JSONSerialization.data(withJSONObject: data).write(to: config)
        let app = XCUIApplication()
        app.launchEnvironment["CODEVATOR_UI_TEST_CONFIG"] = config.path
        app.launch()
        addTeardownBlock { app.terminate() }
        focus(app)
        let codex = app.buttons["新建 Codex 标签"]
        XCTAssertTrue(codex.waitForExistence(timeout: 20))
        codex.click()
        XCTAssertTrue(app.textViews["Codex 终端"].waitForExistence(timeout: 20))
        app.buttons["新建 Claude 标签"].click()
        XCTAssertTrue(app.textViews["Claude 终端"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.buttons.matching(identifier: "Codex 标签").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "Claude 标签").count, 1)
        app.buttons["停止"].click()
        app.buttons["关闭 Claude 标签"].click()
        XCTAssertTrue(app.textViews["Codex 终端"].waitForExistence(timeout: 10))
        app.buttons["新建空白标签"].click()
        XCTAssertTrue(app.buttons["新标签 标签"].waitForExistence(timeout: 10))
        app.buttons["Claude"].click()
        XCTAssertTrue(app.textViews["Claude 终端"].waitForExistence(timeout: 20))
        app.buttons["停止"].click()
        app.buttons["Codex 标签"].click()
        app.buttons["停止"].click()
    }

    func testRealCodexUnicodeCopyAndPaste() throws {
        try verifyEditing(provider: "Codex", executable: "/opt/homebrew/bin/codex", readyText: "Ask Codex")
    }

    func testRealClaudeUnicodeCopyAndPaste() throws {
        try verifyEditing(provider: "Claude", executable: "/opt/homebrew/bin/claude", readyText: "for shortcuts")
    }

    private func verifyEditing(provider: String, executable: String, readyText: String) throws {
        continueAfterFailure = false
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CodevatorUI-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixture = repository.appendingPathComponent(".build/ui-fixtures/Project-A").path
        guard FileManager.default.fileExists(atPath: fixture + "/.git"), FileManager.default.isExecutableFile(atPath: executable) else {
            throw XCTSkip("Requires the local disposable Git fixture and installed CLI")
        }
        let config = folder.appendingPathComponent("workspace.json")
        let common = fixture + "/.git"
        let providerKey = provider == "Codex" ? "codex" : "claude"
        let data: [String: Any] = ["schemaVersion": 1, "projects": [["id": common, "name": "UI Test", "directory": fixture, "expanded": true]], "selection": common + "\n" + fixture, "cliPaths": [providerKey: executable]]
        try JSONSerialization.data(withJSONObject: data).write(to: config)
        let clipboard = NSPasteboard.general
        let original = (clipboard.pasteboardItems ?? []).map { item in
            let clone = NSPasteboardItem()
            for type in item.types { if let bytes = item.data(forType: type) { clone.setData(bytes, forType: type) } }
            return clone
        }
        addTeardownBlock { clipboard.clearContents(); if !original.isEmpty { clipboard.writeObjects(original) } }

        let app = XCUIApplication()
        app.launchEnvironment["CODEVATOR_UI_TEST_CONFIG"] = config.path
        app.launch()
        focus(app)
        var stopped = false
        addTeardownBlock {
            if !stopped, app.buttons["停止"].exists { app.buttons["停止"].click() }
            app.terminate()
        }
        let start = app.buttons["新建 \(provider) 标签"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        start.click()
        let terminal = app.textViews[provider + " 终端"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 30))
        let ready = NSPredicate { _, _ in
            let visible = terminal.value as? String ?? ""
            if provider == "Claude", visible.contains("Yes, I trust this folder") {
                self.key(.return, modifiers: [], app: app)
            }
            return visible.contains(readyText)
        }
        let readyWait = XCTNSPredicateExpectation(predicate: ready, object: terminal)
        if XCTWaiter.wait(for: [readyWait], timeout: 30) != .completed {
            let detail = XCTAttachment(string: terminal.value as? String ?? "No terminal value")
            detail.name = "Isolated CLI startup output"
            detail.lifetime = .keepAlways
            add(detail)
            XCTFail("The isolated CLI did not reach its input prompt")
        }
        terminal.click()
        clipboard.clearContents()
        clipboard.setString("中文复制测试", forType: .string)
        key("v", modifiers: .command, app: app)
        let textShown = NSPredicate { _, _ in (terminal.value as? String)?.contains("中文复制测试") == true }
        expectation(for: textShown, evaluatedWith: terminal)
        waitForExpectations(timeout: 10)

        // Known test text only; never copy the entire CLI buffer.
        let lines = try XCTUnwrap(terminal.value as? String).components(separatedBy: "\n")
        let row = try XCTUnwrap(lines.firstIndex(where: { $0.contains("中文复制测试") }))
        let range = try XCTUnwrap(lines[row].range(of: "中文复制测试"))
        let leadingColumns = lines[row][..<range.lowerBound].count
        let cellWidth = ("M" as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]).width
        let y = (CGFloat(row) + 0.5) * terminal.frame.height / CGFloat(lines.count)
        let origin = terminal.coordinate(withNormalizedOffset: .zero)
        let startText = origin.withOffset(CGVector(dx: CGFloat(leadingColumns) * cellWidth, dy: y))
        let endText = origin.withOffset(CGVector(dx: CGFloat(leadingColumns + 12) * cellWidth, dy: y))
        XCTAssertTrue(terminal.frame.contains(startText.screenPoint) && terminal.frame.contains(endText.screenPoint))
        focus(app)
        XCUIElement.perform(withKeyModifiers: .shift) { startText.click(forDuration: 0.1, thenDragTo: endText) }
        key("c", modifiers: .command, app: app)
        let copied = clipboard.string(forType: .string) ?? ""
        let trace = (try? String(contentsOfFile: config.path + ".editing-trace", encoding: .utf8)) ?? "No editing trace"
        XCTAssertTrue(copied.trimmingCharacters(in: .whitespacesAndNewlines) == "中文复制测试", "Known selection was not copied; character count: \(copied.count); frame=\(terminal.frame), row=\(row)/\(lines.count), start=\(startText.screenPoint), end=\(endText.screenPoint); \(trace)")
        key("a", modifiers: .control, app: app)
        key("k", modifiers: .control, app: app)
        let cleared = NSPredicate { _, _ in !(terminal.value as? String ?? "").contains("中文复制测试") }
        expectation(for: cleared, evaluatedWith: terminal)
        waitForExpectations(timeout: 10)
        key("v", modifiers: .command, app: app)
        let pasted = NSPredicate { _, _ in
            let value = terminal.value as? String ?? ""
            return value.contains("中文复制测试")
        }
        expectation(for: pasted, evaluatedWith: terminal)
        waitForExpectations(timeout: 10)
        app.buttons["停止"].click()
        stopped = true
    }

    private func key(_ key: XCUIKeyboardKey, modifiers: XCUIElement.KeyModifierFlags, app: XCUIApplication) {
        focus(app)
        app.typeKey(key, modifierFlags: modifiers)
    }

    private func key(_ key: String, modifiers: XCUIElement.KeyModifierFlags, app: XCUIApplication) {
        focus(app)
        app.typeKey(key, modifierFlags: modifiers)
    }

    private func focus(_ app: XCUIApplication) {
        app.activate()
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "dev.codeelevator.CodeElevator", "The test app must own keyboard focus before synthesizing input")
    }
}
