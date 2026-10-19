import AppKit
import SwiftUI
import SwiftTerm
import Combine

final class AccessibleTerminalView: LocalProcessTerminalView {
    private var editingMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []
    var prefersLocalTextSelection = false
    var onSubmittedInput: ((String) -> Void)?
    var onInterruptedInput: (() -> Void)?
    var onPermissionSelectionCompleted: (() -> Void)?
    var onPermissionMenuOpened: (() -> Void)?
    var onScreenUpdated: (() -> Void)?
    private var draftInput = ""
    private var recentOutput = ""
    var refreshWholeSurfaceAfterOutput = false
    private var wholeSurfaceRefreshScheduled = false
    private var lastOutputTime: UInt64 = 0

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        if onPermissionSelectionCompleted != nil {
            recentOutput = String((recentOutput + String(decoding: slice, as: UTF8.self)).suffix(512))
            let readableOutput = recentOutput.replacingOccurrences(
                of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression
            )
            if readableOutput.contains("Permission selection requested:") {
                recentOutput = ""
                draftInput = ""
                onPermissionSelectionCompleted?()
            } else if readableOutput.contains("Update Model Permissions") {
                // Codex can redraw a command entered after shell-style line
                // edits, so the locally tracked draft is not always reliable.
                recentOutput = ""
                draftInput = ""
                onPermissionMenuOpened?()
            }
        }
        onScreenUpdated?()
        guard refreshWholeSurfaceAfterOutput else { return }
        lastOutputTime = DispatchTime.now().uptimeNanoseconds
        scheduleWholeSurfaceRefresh()
    }

    private func scheduleWholeSurfaceRefresh() {
        guard !wholeSurfaceRefreshScheduled else { return }
        wholeSurfaceRefreshScheduled = true
        // SwiftTerm queues its own display update after receiving bytes. Keep
        // repainting during a stream and once more after the last queued update,
        // so a late partial draw cannot overwrite the final full repaint.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) { [weak self] in
            guard let self else { return }
            self.wholeSurfaceRefreshScheduled = false
            self.setNeedsDisplay(self.bounds)
            let elapsed = DispatchTime.now().uptimeNanoseconds - self.lastOutputTime
            if elapsed < 100_000_000 {
                self.scheduleWholeSurfaceRefresh()
            }
        }
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        super.send(source: source, data: data)
        let encoded = String(decoding: data, as: UTF8.self)
        // SwiftTerm sends Return as CR in normal mode and as a Kitty key
        // sequence when a CLI enables enhanced keyboard reporting.
        if data.contains(10) || data.contains(13) ||
            encoded == "\u{1B}[13u" || encoded == "\u{1B}[13;1u" {
            discardUncommittedText()
            onSubmittedInput?(draftInput)
            draftInput = ""
        } else if data.contains(3) || encoded == "\u{1B}" || encoded == "\u{1B}[27u" {
            discardUncommittedText()
            draftInput = ""
            onInterruptedInput?()
        } else if data.count == 1 && data.first == 0x15 {
            // Ctrl+U removes the input back to the start of the line.
            draftInput = ""
        } else if data.contains(8) || data.contains(127) {
            if !draftInput.isEmpty { draftInput.removeLast() }
        }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let text = string as? String { draftInput += text }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func paste(_ sender: Any) {
        if let text = NSPasteboard.general.string(forType: .string) { draftInput += text }
        super.paste(sender)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let editingMonitor { NSEvent.removeMonitor(editingMonitor); self.editingMonitor = nil }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        guard let window else { discardUncommittedText(); return }
        // SwiftTerm's IME preview is a separate, non-editable subview. Clear it
        // when focus or hosting changes so it cannot cover Codex's next prompt.
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in self?.discardUncommittedText() })
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.setNeedsDisplay(self.bounds)
        })
        setNeedsDisplay(bounds)
        editingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" { self?.traceEditing("monitor", event: event) }
            guard let self, let window = self.window, window.isKeyWindow, window.firstResponder === self else { return event }
            return self.handleEditingShortcut(event) ? nil : event
        }
    }

    private func discardUncommittedText() {
        guard hasMarkedText() else { return }
        inputContext?.discardMarkedText()
        unmarkText()
        setNeedsDisplay(bounds)
    }

    deinit {
        if let editingMonitor { NSEvent.removeMonitor(editingMonitor) }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
    }

    override func copy(_ sender: Any) {
        traceEditing("copy")
        // SwiftTerm clears the shared clipboard even when no text is selected.
        // Keep the previous clipboard contents if the selection disappeared
        // before a menu command or shortcut reaches the terminal.
        guard let selected = getSelection(), !selected.isEmpty else { return }
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        clipboard.setString(selected, forType: .string)
    }

    override func mouseDown(with event: NSEvent) {
        // SwiftTerm can leave another control as first responder after a click
        // in the terminal, which routes Command-C away from the selection.
        window?.makeFirstResponder(self)
        let extendingSelection = selection.active && event.modifierFlags.contains(.shift)
        withTextSelectionOverride(event) { super.mouseDown(with: event) }
        // SwiftTerm seeds a drag at its first movement. Preserve the actual
        // press position so fast drags do not omit the first character.
        let selectsLocally = prefersLocalTextSelection || event.modifierFlags.contains(.shift) ||
            !allowMouseReporting || getTerminal().mouseMode == .off
        if event.clickCount == 1, !extendingSelection, selectsLocally {
            let terminal = getTerminal()
            let index = characterIndex(for: event.locationInWindow)
            selection.setSoftStart(bufferPosition: Position(col: max(0, index % terminal.cols), row: max(0, index / terminal.cols) + terminal.buffer.yDisp))
            selection.startSelection()
        }
        traceEditing("mouseDown", event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        withTextSelectionOverride(event) { super.mouseDragged(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        withTextSelectionOverride(event) { super.mouseUp(with: event) }
        traceEditing("mouseUp", event: event)
    }

    private func withTextSelectionOverride(_ event: NSEvent, action: () -> Void) {
        let reporting = allowMouseReporting
        if prefersLocalTextSelection || event.modifierFlags.contains(.shift) { allowMouseReporting = false }
        defer { allowMouseReporting = reporting }
        action()
    }

    private func traceEditing(_ action: String, event: NSEvent? = nil) {
        #if DEBUG
        guard let config = ProcessInfo.processInfo.environment["CODEVATOR_UI_TEST_CONFIG"] else { return }
        let path = config + ".editing-trace"
        let responder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let message = "\(action): active=\(selection.active), chars=\(getSelection()?.count ?? 0), keyWindow=\(window?.isKeyWindow ?? false), responder=\(responder), modifiers=\(event?.modifierFlags.rawValue ?? 0)\n"
        let data = Data(message.utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data); try? handle.close()
        } else { _ = FileManager.default.createFile(atPath: path, contents: data) }
        #endif
    }

    override func accessibilityValue() -> Any? {
        let terminal = getTerminal()
        return (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true).replacingOccurrences(of: "\0", with: " ") }.joined(separator: "\n")
    }

    override func accessibilitySelectedText() -> String? { getSelection() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleEditingShortcut(event) || super.performKeyEquivalent(with: event)
    }

    private func handleEditingShortcut(_ event: NSEvent) -> Bool {
        // Handle native editing shortcuts before SwiftTerm clears its selection
        // or forwards enhanced keyboard events to the CLI.
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command {
            if event.keyCode == 123 || event.keyCode == 124 {
                // Match macOS line navigation in shell and AI prompt editors.
                // Their terminal equivalents are Ctrl+A and Ctrl+E.
                traceEditing("lineNavigation", event: event)
                selection.selectNone()
                send(source: self, data: ArraySlice<UInt8>([event.keyCode == 123 ? 0x01 : 0x05]))
                return true
            }
            if event.keyCode == 51 {
                // Command-Delete is the Mac shortcut for deleting to the
                // beginning of the current input line.
                selection.selectNone()
                send(source: self, data: ArraySlice<UInt8>([0x15]))
                return true
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": copy(self); return true
            case "v": paste(self); return true
            case "a": selectAll(self); return true
            default: break
            }
        }
        return false
    }

    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self) ?? false
    }
}

@MainActor
final class TerminalSession: NSObject, ObservableObject, @preconcurrency LocalProcessTerminalViewDelegate {
    let treeID: String
    let path: String
    let provider: CLIProvider
    let terminal: AccessibleTerminalView
    @Published var state = tr("启动中")
    @Published var active = true
    @Published var stopping = false
    @Published private(set) var awaitingResponse = false
    private(set) var processGroup: pid_t = 0
    private let completionFile = FileManager.default.temporaryDirectory.appendingPathComponent("codevator-complete-" + UUID().uuidString)
    private var completionTimer: Timer?
    private var completionLength: UInt64 = 0
    private var completionTrackingEnabled = false
    private var selectingCodexPermission = false
    private var codexPermissionMenuWasVisible = false
    var onTurnCompleted: (() -> Void)?
    var hasManagedProcesses: Bool { active || stopping || (processGroup > 0 && kill(-processGroup, 0) == 0) }

    init(tree: Worktree, provider: CLIProvider, fontSize: Int = TerminalFontSize.defaultValue) {
        treeID = tree.id; path = tree.path; self.provider = provider
        terminal = AccessibleTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600), font: .monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular), options: TerminalOptions(scrollback: 5000))
        terminal.refreshWholeSurfaceAfterOutput = provider == .codex
        // Codex and Claude may enable mouse tracking after entering their TUI.
        // Keep left-button text selection local so copying remains predictable.
        terminal.prefersLocalTextSelection = provider != .terminal
        terminal.setAccessibilityElement(true)
        terminal.setAccessibilityRole(.textArea)
        terminal.setAccessibilityLabel(provider == .terminal ? provider.title : provider.title + tr(" 终端"))
        let editingMenu = NSMenu(title: tr("终端"))
        for (title, action) in [(tr("复制"), #selector(TerminalView.copy(_:))), (tr("粘贴"), #selector(TerminalView.paste(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = terminal
            editingMenu.addItem(item)
        }
        terminal.menu = editingMenu
        terminal.appearance = NSAppearance(named: .darkAqua)
        terminal.nativeForegroundColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        terminal.nativeBackgroundColor = NSColor(calibratedWhite: 0.07, alpha: 1)
        super.init(); terminal.processDelegate = self
        terminal.onSubmittedInput = { [weak self] input in self?.markSubmittedInput(input) }
        terminal.onInterruptedInput = { [weak self] in self?.markInterruptedInput() }
        if provider == .codex {
            terminal.onPermissionSelectionCompleted = { [weak self] in self?.finishCodexPermissionSelection() }
            terminal.onPermissionMenuOpened = { [weak self] in self?.beginCodexPermissionSelection() }
            terminal.onScreenUpdated = { [weak self] in self?.checkCodexPermissionMenu() }
        }
    }
    private func markSubmittedInput(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == .codex {
            let command = text.lowercased()
            if command == "/permission" || command == "/permissions" ||
                (command.count >= 5 && "/permissions".hasPrefix(command)) {
                selectingCodexPermission = true
                codexPermissionMenuWasVisible = false
                return
            }
            if selectingCodexPermission {
                return
            }
        }
        guard !text.isEmpty else { return }
        guard completionTrackingEnabled, active, !stopping, terminal.process.running else { return }
        awaitingResponse = true
        state = tr("回复中")
    }
    private func finishCodexPermissionSelection() {
        selectingCodexPermission = false
        codexPermissionMenuWasVisible = false
        // The permission menu is local CLI interaction, not an agent turn. A
        // menu key can be mistaken for a submitted prompt when Codex redraws
        // its input area; the result line is authoritative for this flow.
        awaitingResponse = false
        state = tr("已就绪")
    }
    private func beginCodexPermissionSelection() {
        selectingCodexPermission = true
        codexPermissionMenuWasVisible = true
        awaitingResponse = false
        state = tr("已就绪")
    }
    private func checkCodexPermissionMenu() {
        guard selectingCodexPermission,
              let screen = terminal.accessibilityValue() as? String else { return }
        let menu = screen.range(of: "Update Model Permissions", options: .backwards)
        let prompt = screen.range(of: "Ask Codex to do anything", options: .backwards)
        if let menu, prompt == nil || prompt!.lowerBound < menu.lowerBound {
            codexPermissionMenuWasVisible = true
        } else if codexPermissionMenuWasVisible && prompt != nil {
            // Choosing the already active permission returns to the prompt
            // without printing a selection-result line.
            finishCodexPermissionSelection()
        }
    }
    private func markInterruptedInput() {
        selectingCodexPermission = false
        codexPermissionMenuWasVisible = false
        guard awaitingResponse else { return }
        awaitingResponse = false
        state = tr("已就绪")
    }
    func setFontSize(_ size: Int) {
        guard Int(terminal.font.pointSize) != size else { return }
        terminal.font = .monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
    }
    func launch(executable: String, environment: [String: String], args: [String] = []) {
        guard active, !stopping else { return }
        terminal.startProcess(executable: executable, args: args, environment: environment.map { "\($0.key)=\($0.value)" }, currentDirectory: path)
        let pid = terminal.process.shellPid
        guard terminal.process.running, pid > 0 else { active = false; state = tr("失败：无法创建 PTY 进程"); return }
        // forkpty establishes a new session/group in the child. getpgid queried
        // immediately in the parent races that setup, so retain the known group ID.
        processGroup = pid
        state = provider == .terminal ? tr("运行中") : tr("已就绪")
    }
    func completionArguments(for executable: String) -> [String] {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        guard (provider == .codex && name == "codex") ||
              (provider == .claude && name == "claude") else { return [] }
        guard FileManager.default.createFile(atPath: completionFile.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return [] }
        if provider == .codex {
            // Codex appends its event JSON as the final argument. The hook only
            // writes a fixed marker; prompts and responses never leave the CLI.
            let script = """
            umask 077
            case "$1" in
              *'"type":"agent-turn-complete"'*) ;;
              *) exit 0 ;;
            esac
            case "$1" in
              *'"input-messages":["Generate a concise, single-line task title'*) exit 0 ;;
            esac
            printf x >> "$0"
            """
            let argv = ["/bin/sh", "-c", script, completionFile.path]
            guard let data = try? JSONSerialization.data(withJSONObject: argv, options: [.withoutEscapingSlashes]),
                  let value = String(data: data, encoding: .utf8) else { return [] }
            completionTrackingEnabled = true
            return ["-c", "notify=" + value]
        }
        let quotedPath = "'" + completionFile.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let settings: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "umask 077; printf x >> " + quotedPath]]]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: settings),
              let value = String(data: data, encoding: .utf8) else { return [] }
        completionTrackingEnabled = true
        return ["--settings", value]
    }
    func monitorCompletions() {
        completionTimer?.invalidate()
        completionLength = 0
        completionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkCompletions() }
        }
    }
    func checkCompletions() {
        guard active, !stopping,
              let size = (try? FileManager.default.attributesOfItem(atPath: completionFile.path)[.size]) as? NSNumber else { return }
        let length = size.uint64Value
        guard length > completionLength else { return }
        completionLength = length
        guard awaitingResponse else { return }
        awaitingResponse = false
        state = tr("已完成")
        onTurnCompleted?()
    }
    private func stopCompletionMonitor() {
        completionTimer?.invalidate(); completionTimer = nil
        try? FileManager.default.removeItem(at: completionFile)
    }
    func fail(_ message: String) { stopCompletionMonitor(); awaitingResponse = false; active = false; state = tr("失败：") + message }
    func stop() async {
        if stopping {
            while stopping { try? await Task.sleep(nanoseconds: 20_000_000) }
            return
        }
        stopping = true; state = tr("正在停止")
        let pid = terminal.process.shellPid
        let group = processGroup
        if group > 0 {
            for _ in 0..<10 where terminal.process.running && getpgid(pid) != group {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            kill(-group, SIGTERM)
        }
        else if pid > 0, terminal.process.running { kill(pid, SIGTERM) }
        // Keep the process monitor alive until the child has been reaped.
        for _ in 0..<50 {
            if !terminal.process.running && (group == 0 || kill(-group, 0) != 0) { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if group > 0, kill(-group, 0) == 0 { kill(-group, SIGKILL) }
        else if pid > 0, terminal.process.running { kill(pid, SIGKILL) }
        for _ in 0..<50 where terminal.process.running { try? await Task.sleep(nanoseconds: 20_000_000) }
        if terminal.process.running { terminal.terminate() }
        stopCompletionMonitor()
        processGroup = 0; awaitingResponse = false; active = false; stopping = false; state = tr("已停止")
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        checkCompletions()
        stopCompletionMonitor()
        awaitingResponse = false
        active = false
        if !stopping {
            if let status = exitCode {
                let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                state = String(format: tr("已退出（%d）"), code)
            } else { state = tr("失败：进程退出状态不可用") }
            // Reap any children left in the session group promptly, rather than
            // retaining a stale group ID until a much later restart.
            let group = processGroup
            if group > 0 { kill(-group, SIGTERM) }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, !self.stopping, self.processGroup == group else { return }
                if group > 0, kill(-group, 0) == 0 { kill(-group, SIGKILL) }
                self.processGroup = 0
            }
        }
    }
}

enum TerminalFontSize {
    static let key = "terminalFontSize"
    static let defaultValue = 13
    static let range = 10...28
    static func clamped(_ value: Int) -> Int { min(max(value, range.lowerBound), range.upperBound) }
}

@MainActor
final class SessionManager: ObservableObject {
    struct Tab: Identifiable, Equatable {
        let id: String
        let treeID: String
        var provider: CLIProvider?
        init(treeID: String, provider: CLIProvider? = nil) {
            id = UUID().uuidString; self.treeID = treeID; self.provider = provider
        }
    }
    @Published private(set) var tabsByTree: [String: [Tab]] = [:]
    @Published private(set) var selectedTabIDs: [String: String] = [:]
    @Published var sessions: [String: TerminalSession] = [:]
    @Published private(set) var unreadCompletions: Set<String> = []
    @Published private(set) var fontSize: Int
    var onTurnCompleted: ((String, TerminalSession) -> Void)?
    let resolver = CLIResolver()
    private let defaults: UserDefaults
    private var observations: [String: AnyCancellable] = [:]
    private var starting: Set<String> = []
    private var closing: Set<String> = []
    var isClosing = false
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        fontSize = defaults.object(forKey: TerminalFontSize.key) == nil
            ? TerminalFontSize.defaultValue
            : TerminalFontSize.clamped(defaults.integer(forKey: TerminalFontSize.key))
    }
    func setFontSize(_ value: Int) {
        let size = TerminalFontSize.clamped(value)
        guard fontSize != size else { return }
        fontSize = size
        defaults.set(size, forKey: TerminalFontSize.key)
        for session in sessions.values { session.setFontSize(size) }
    }
    func adjustFontSize(by delta: Int) { setFontSize(fontSize + delta) }
    func resetFontSize() { setFontSize(TerminalFontSize.defaultValue) }
    func tabs(for treeID: String) -> [Tab] { tabsByTree[treeID] ?? [] }
    func openTerminalCount(in treeID: String) -> Int {
        tabs(for: treeID).filter { $0.provider != nil }.count
    }
    func selectedTab(for treeID: String) -> Tab? {
        tabs(for: treeID).first { $0.id == selectedTabIDs[treeID] }
    }
    @discardableResult func createTab(for treeID: String, provider: CLIProvider? = nil) -> Tab {
        let tab = Tab(treeID: treeID, provider: provider)
        tabsByTree[treeID, default: []].append(tab)
        selectedTabIDs[treeID] = tab.id
        return tab
    }
    func select(_ tabID: String, in treeID: String) {
        guard tabs(for: treeID).contains(where: { $0.id == tabID }) else { return }
        selectedTabIDs[treeID] = tabID
    }
    func start(_ tree: Worktree, tabID: String, provider: CLIProvider, override: String?) async {
        guard !isClosing, !closing.contains(tabID),
              tabs(for: tree.id).contains(where: { $0.id == tabID }) else { return }
        if sessions[tabID]?.active == true || sessions[tabID]?.stopping == true || !starting.insert(tabID).inserted { return }
        defer { starting.remove(tabID) }
        if let previous = sessions[tabID] { await previous.stop() }
        guard !isClosing, !closing.contains(tabID),
              let index = tabsByTree[tree.id]?.firstIndex(where: { $0.id == tabID }) else { return }
        tabsByTree[tree.id]?[index].provider = provider
        let session = TerminalSession(tree: tree, provider: provider, fontSize: fontSize)
        session.onTurnCompleted = { [weak self, weak session] in
            guard let self, let session, self.sessions[tabID] === session else { return }
            self.onTurnCompleted?(tabID, session)
        }
        sessions[tabID] = session
        observations[tabID] = session.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
        do {
            guard !tree.unavailable, FileManager.default.fileExists(atPath: tree.path) else { throw WorkspaceError(tr("工作目录不可用，请刷新")) }
            let (executable, env) = try await resolver.resolve(provider, override: override)
            guard !isClosing, !closing.contains(tabID), sessions[tabID] === session, session.active else { return }
            let arguments = provider == .terminal ? ["-l"] : session.completionArguments(for: executable)
            session.launch(executable: executable, environment: env, args: arguments)
            if provider != .terminal, !arguments.isEmpty, session.active { session.monitorCompletions() }
        } catch { if session.active { session.fail(error.localizedDescription) } }
    }
    @discardableResult func start(_ tree: Worktree, provider: CLIProvider, override: String?) async -> String {
        let tab = selectedTab(for: tree.id) ?? createTab(for: tree.id)
        await start(tree, tabID: tab.id, provider: provider, override: override)
        return tab.id
    }
    func stop(_ tabID: String) async { await sessions[tabID]?.stop(); objectWillChange.send() }
    func markUnread(_ tabID: String) { unreadCompletions.insert(tabID) }
    func markRead(_ tabID: String) { unreadCompletions.remove(tabID) }
    func unreadCount(in treeID: String) -> Int { tabs(for: treeID).filter { unreadCompletions.contains($0.id) }.count }
    func unreadCount(forProject projectID: String) -> Int {
        tabsByTree.keys.filter { $0.hasPrefix(projectID + "\n") }.reduce(0) { $0 + unreadCount(in: $1) }
    }
    func pendingCount(in treeID: String) -> Int {
        tabs(for: treeID).reduce(0) { count, tab in
            count + (sessions[tab.id]?.awaitingResponse == true ? 1 : 0)
        }
    }
    func pendingCount(forProject projectID: String) -> Int {
        tabsByTree.keys.filter { $0.hasPrefix(projectID + "\n") }.reduce(0) { $0 + pendingCount(in: $1) }
    }
    func close(_ tabID: String) async {
        guard let treeID = tabsByTree.first(where: { $0.value.contains(where: { $0.id == tabID }) })?.key,
              closing.insert(tabID).inserted else { return }
        await stop(tabID)
        unreadCompletions.remove(tabID)
        sessions.removeValue(forKey: tabID); observations.removeValue(forKey: tabID)
        let old = tabs(for: treeID)
        guard let index = old.firstIndex(where: { $0.id == tabID }) else { closing.remove(tabID); return }
        var remaining = old; remaining.remove(at: index)
        if remaining.isEmpty { tabsByTree.removeValue(forKey: treeID); selectedTabIDs.removeValue(forKey: treeID) }
        else {
            tabsByTree[treeID] = remaining
            if selectedTabIDs[treeID] == tabID { selectedTabIDs[treeID] = remaining[min(index, remaining.count - 1)].id }
        }
        closing.remove(tabID)
    }
    func remove(_ treeID: String) async {
        for tab in tabs(for: treeID) { await close(tab.id) }
    }
    func stopAll() async { for session in sessions.values { await session.stop() }; objectWillChange.send() }
    func running(in treeID: String) -> [TerminalSession] { running.filter { $0.treeID == treeID } }
    var running: [TerminalSession] { sessions.values.filter { $0.hasManagedProcesses } }
}

final class TerminalContainerView: NSView {
    weak var terminal: LocalProcessTerminalView?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusTerminal()
    }
    func focusTerminal() {
        guard let terminal, let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window, self.terminal === terminal else { return }
            window.makeFirstResponder(terminal)
        }
    }
}

struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        attach(to: container)
        applyAppearance()
        return container
    }
    func updateNSView(_ nsView: TerminalContainerView, context: Context) {
        attach(to: nsView)
        applyAppearance()
    }
    private func applyAppearance() {
        guard session.terminal.appearance?.name != .darkAqua else { return }
        session.terminal.appearance = NSAppearance(named: .darkAqua)
        session.terminal.nativeForegroundColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        session.terminal.nativeBackgroundColor = NSColor(calibratedWhite: 0.07, alpha: 1)
        session.terminal.needsDisplay = true
    }
    private func attach(to container: TerminalContainerView) {
        guard session.terminal.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        session.terminal.removeFromSuperview()
        session.terminal.frame = container.bounds
        session.terminal.autoresizingMask = [.width, .height]
        container.terminal = session.terminal
        container.addSubview(session.terminal)
        container.focusTerminal()
    }
}
