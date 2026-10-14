import XCTest
import AppKit
import ApplicationServices

final class TerminalEditingUITests: XCTestCase {
    func testWorktreeShowsPendingAndUnreadBadgesTogether() throws {
        continueAfterFailure = false
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CodevatorStatusUI-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixture = repository.appendingPathComponent(".build/ui-fixtures/Project-A").path
        guard FileManager.default.fileExists(atPath: fixture + "/.git"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("Requires a disposable Git fixture and Python 3")
        }
        let fakeCLI = folder.appendingPathComponent("codex")
        let script = """
        #!/usr/bin/python3
        import json, os, sys, time
        argument = next((value[7:] for value in sys.argv[1:] if value.startswith("notify=")), None)
        marker = json.loads(argument)[-1] if argument else None
        finish = os.path.join(os.path.dirname(__file__), "complete-now")
        print("READY", flush=True)
        for line in sys.stdin:
            if line.strip() == "/permission":
                print("Choose permission level", flush=True)
            elif line.strip() == "1":
                print("Permission selection requested: Full Access", flush=True)
                print("Ask Codex to do anything", flush=True)
            elif line.strip() == "complete":
                deadline = time.time() + 20
                while not os.path.exists(finish) and time.time() < deadline:
                    time.sleep(0.05)
                if os.path.exists(finish):
                    with open(marker, "a") as file:
                        file.write("x")
                    print("DONE", flush=True)
            else:
                print("WAITING", flush=True)
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)
        let common = fixture + "/.git"
        let config = folder.appendingPathComponent("workspace.json")
        let data: [String: Any] = ["schemaVersion": 1, "projects": [["id": common, "name": "UI Test", "directory": fixture, "expanded": true]], "selection": common + "\n" + fixture, "cliPaths": ["codex": fakeCLI.path]]
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
        addTeardownBlock { app.terminate() }
        focus(app)
        let createCodex = app.buttons["新建 Codex 标签"]
        XCTAssertTrue(createCodex.waitForExistence(timeout: 20))
        createCodex.click()
        let terminal = app.textViews["Codex 终端"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 20))
        let ready = NSPredicate { _, _ in (terminal.value as? String)?.contains("READY") == true }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: terminal)], timeout: 10), .completed)
        let pending = app.descendants(matching: .any).matching(identifier: "worktreePending-\(fixture)").firstMatch
        XCTAssertFalse(pending.exists)
        terminal.click()
        app.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(pending.exists)
        clipboard.clearContents()
        clipboard.setString("/permission", forType: .string)
        app.typeKey("v", modifierFlags: .command)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(pending.exists)
        clipboard.clearContents()
        clipboard.setString("1", forType: .string)
        app.typeKey("v", modifierFlags: .command)
        app.typeKey(.return, modifierFlags: [])
        let permissionResult = NSPredicate { _, _ in (terminal.value as? String)?.contains("Permission selection requested: Full Access") == true }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: permissionResult, object: terminal)], timeout: 10), .completed)
        XCTAssertFalse(pending.exists)
        clipboard.clearContents()
        clipboard.setString("pending", forType: .string)
        app.typeKey("v", modifierFlags: .command)
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(pending.waitForExistence(timeout: 10))
        createCodex.click()
        XCTAssertTrue(app.buttons["Codex 2 标签"].waitForExistence(timeout: 20))
        XCTAssertTrue(terminal.waitForExistence(timeout: 20))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: terminal)], timeout: 10), .completed)
        terminal.click()
        clipboard.clearContents()
        clipboard.setString("complete", forType: .string)
        app.typeKey("v", modifierFlags: .command)
        app.typeKey(.return, modifierFlags: [])
        app.buttons["Codex 1 标签"].click()
        try Data().write(to: folder.appendingPathComponent("complete-now"))

        let completed = app.descendants(matching: .any).matching(identifier: "worktreeCompleted-\(fixture)").firstMatch
        XCTAssertTrue(completed.waitForExistence(timeout: 12))
        XCTAssertTrue(pending.exists)
        app.buttons["停止"].click()
        app.buttons["Codex 2 标签"].click()
        app.buttons["停止"].click()
    }

    func testTerminalFontSizeSettingsAndKeyboardShortcuts() throws {
        continueAfterFailure = false
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CodevatorFontUI-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let app = XCUIApplication()
        app.launchEnvironment["CODEVATOR_UI_TEST_CONFIG"] = folder.appendingPathComponent("workspace.json").path
        app.launch()
        addTeardownBlock { app.terminate() }
        focus(app)
        try openSettingsMenu()
        let settings = app.windows.matching(NSPredicate(format: "title != 'Codevator'")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        let terminalSection = settings.staticTexts["终端"]
        XCTAssertTrue(terminalSection.waitForExistence(timeout: 5))
        terminalSection.click()
        let size = settings.staticTexts["terminalFontSize"]
        XCTAssertTrue(size.waitForExistence(timeout: 5))
        let originalText = try XCTUnwrap(size.value as? String)
        let original = try XCTUnwrap(Int(originalText.replacingOccurrences(of: " pt", with: "")))
        app.typeKey("+", modifierFlags: .command)
        XCTAssertEqual(size.value as? String, "\(min(original + 1, 28)) pt")
        app.typeKey("-", modifierFlags: .command)
        XCTAssertEqual(size.value as? String, "\(original) pt")
        settings.buttons["放大终端文字"].click()
        XCTAssertEqual(size.value as? String, "\(min(original + 1, 28)) pt")
        settings.buttons["缩小终端文字"].click()
        XCTAssertEqual(size.value as? String, "\(original) pt")
    }

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
        app.buttons["终端"].click()
        XCTAssertTrue(app.textViews["终端"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["终端 标签"].exists)
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
        if provider == "Codex" {
            key("a", modifiers: .control, app: app)
            key("k", modifiers: .control, app: app)
            clipboard.clearContents()
            clipboard.setString("/permission", forType: .string)
            key("v", modifiers: .command, app: app)
            key(.return, modifiers: [], app: app)
            let permissionMenu = NSPredicate { _, _ in
                (terminal.value as? String)?.contains("Update Model Permissions") == true
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: permissionMenu, object: terminal)], timeout: 10), .completed,
                           "Codex did not show the permission menu: \(terminal.value ?? "")")
            key(.return, modifiers: [], app: app)
            let readyAgain = NSPredicate { _, _ in
                (terminal.value as? String)?.contains("Ask Codex to do anything") == true
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: readyAgain, object: terminal)], timeout: 10), .completed,
                           "Codex did not return from the permission menu: \(terminal.value ?? "")")
            let pending = app.descendants(matching: .any).matching(identifier: "worktreePending-\(fixture)").firstMatch
            XCTAssertFalse(pending.exists, "Permission selection must not count as an AI turn")
        }
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

    private func openSettingsMenu() throws {
        let pid = try XCTUnwrap(NSWorkspace.shared.frontmostApplication?.processIdentifier)
        let application = AXUIElementCreateApplication(pid)
        func value(of element: AXUIElement, attribute: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
            return value
        }
        func children(of element: AXUIElement) -> [AXUIElement] {
            value(of: element, attribute: kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        func title(of element: AXUIElement) -> String? {
            value(of: element, attribute: kAXTitleAttribute) as? String
        }
        let menuBar = try XCTUnwrap(value(of: application, attribute: kAXMenuBarAttribute)) as! AXUIElement
        let appMenu = try XCTUnwrap(children(of: menuBar).first { title(of: $0) == "Codevator" })
        XCTAssertEqual(AXUIElementPerformAction(appMenu, kAXPressAction as CFString), .success)
        let settings = try XCTUnwrap(children(of: appMenu).flatMap { children(of: $0) }.first { title(of: $0) == "设置…" })
        XCTAssertEqual(AXUIElementPerformAction(settings, kAXPressAction as CFString), .success)
    }
}
