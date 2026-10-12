import AppKit
import SwiftUI
import SwiftTerm
import Combine

final class AccessibleTerminalView: LocalProcessTerminalView {
    private var editingMonitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let editingMonitor { NSEvent.removeMonitor(editingMonitor); self.editingMonitor = nil }
        guard window != nil else { return }
        editingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" { self?.traceEditing("monitor", event: event) }
            guard let self, let window = self.window, window.isKeyWindow, window.firstResponder === self else { return event }
            return self.handleEditingShortcut(event) ? nil : event
        }
    }

    deinit { if let editingMonitor { NSEvent.removeMonitor(editingMonitor) } }

    override func copy(_ sender: Any) {
        traceEditing("copy")
        super.copy(sender)
    }

    override func mouseDown(with event: NSEvent) {
        let extendingSelection = selection.active && event.modifierFlags.contains(.shift)
        withTextSelectionOverride(event) { super.mouseDown(with: event) }
        // SwiftTerm seeds a drag at its first movement. Preserve the actual
        // press position so fast drags do not omit the first character.
        if event.clickCount == 1, !extendingSelection, event.modifierFlags.contains(.shift) || !allowMouseReporting || getTerminal().mouseMode == .off {
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
        if event.modifierFlags.contains(.shift) { allowMouseReporting = false }
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
    let terminal: LocalProcessTerminalView
    @Published var state = "启动中"
    @Published var active = true
    @Published var stopping = false
    private(set) var processGroup: pid_t = 0
    var hasManagedProcesses: Bool { active || stopping || (processGroup > 0 && kill(-processGroup, 0) == 0) }

    init(tree: Worktree, provider: CLIProvider) {
        treeID = tree.id; path = tree.path; self.provider = provider
        terminal = AccessibleTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600), font: .monospacedSystemFont(ofSize: 13, weight: .regular), options: TerminalOptions(scrollback: 5000))
        terminal.setAccessibilityElement(true)
        terminal.setAccessibilityRole(.textArea)
        terminal.setAccessibilityLabel(provider.title + " 终端")
        let editingMenu = NSMenu(title: "终端")
        for (title, action) in [("复制", #selector(TerminalView.copy(_:))), ("粘贴", #selector(TerminalView.paste(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = terminal
            editingMenu.addItem(item)
        }
        terminal.menu = editingMenu
        terminal.appearance = NSAppearance(named: .darkAqua)
        terminal.nativeForegroundColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        terminal.nativeBackgroundColor = NSColor(calibratedWhite: 0.07, alpha: 1)
        super.init(); terminal.processDelegate = self
    }
    func launch(executable: String, environment: [String: String], args: [String] = []) {
        guard active, !stopping else { return }
        terminal.startProcess(executable: executable, args: args, environment: environment.map { "\($0.key)=\($0.value)" }, currentDirectory: path)
        let pid = terminal.process.shellPid
        guard terminal.process.running, pid > 0 else { active = false; state = "失败：无法创建 PTY 进程"; return }
        // forkpty establishes a new session/group in the child. getpgid queried
        // immediately in the parent races that setup, so retain the known group ID.
        processGroup = pid
        state = "运行中"
    }
    func fail(_ message: String) { active = false; state = "失败：" + message }
    func stop() async {
        guard !stopping else { return }
        stopping = true; state = "正在停止"
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
        processGroup = 0; active = false; stopping = false; state = "已停止"
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        active = false
        if !stopping {
            if let status = exitCode {
                let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                state = "已退出（\(code)）"
            } else { state = "失败：进程退出状态不可用" }
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

@MainActor
final class SessionManager: ObservableObject {
    @Published var sessions: [String: TerminalSession] = [:]
    let resolver = CLIResolver()
    private var observations: [String: AnyCancellable] = [:]
    private var starting: Set<String> = []
    var isClosing = false
    func start(_ tree: Worktree, provider: CLIProvider, override: String?) async {
        guard !isClosing else { return }
        if sessions[tree.id]?.active == true || sessions[tree.id]?.stopping == true || !starting.insert(tree.id).inserted { return }
        defer { starting.remove(tree.id) }
        if let previous = sessions[tree.id] { await previous.stop() }
        guard !isClosing else { return }
        let session = TerminalSession(tree: tree, provider: provider)
        sessions[tree.id] = session
        observations[tree.id] = session.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
        do {
            guard !tree.unavailable, FileManager.default.fileExists(atPath: tree.path) else { throw WorkspaceError("工作目录不可用，请刷新") }
            let (executable, env) = try await resolver.resolve(provider, override: override)
            guard sessions[tree.id] === session, session.active else { return }
            session.launch(executable: executable, environment: env)
        } catch { if session.active { session.fail(error.localizedDescription) } }
    }
    func stop(_ id: String) async { await sessions[id]?.stop(); objectWillChange.send() }
    func remove(_ id: String) async { await stop(id); sessions.removeValue(forKey: id); observations.removeValue(forKey: id) }
    func stopAll() async { for session in sessions.values { await session.stop() }; objectWillChange.send() }
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
        return container
    }
    func updateNSView(_ nsView: TerminalContainerView, context: Context) { attach(to: nsView) }
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
