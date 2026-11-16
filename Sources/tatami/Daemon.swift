import AppKit
import ApplicationServices
import TatamiCore

// Test isolation (used by tatami-e2e): TATAMI_PORT renames the CLI port, TATAMI_HOME holds config and state,
// TATAMI_ONLY_PID limits tatami to one app.
private let environment = ProcessInfo.processInfo.environment
let portName = (environment["TATAMI_PORT"] ?? "dev.tatami.cli") as CFString
private var daemon: Daemon!

final class Daemon {
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let testHome = environment["TATAMI_HOME"].map { URL(fileURLWithPath: $0) }
    private static let configURL = testHome?.appendingPathComponent("config") ?? home.appendingPathComponent(".config/tatami/config")
    private static let stateURL = testHome?.appendingPathComponent("state.json")
        ?? home.appendingPathComponent("Library/Application Support/tatami/state.json")
    private static let onlyPID = environment["TATAMI_ONLY_PID"].flatMap { pid_t($0) }

    private var file: ConfigFile
    private var world: World
    private var workers: [pid_t: AppWorker] = [:]
    private var owner: [WindowID: AppWorker] = [:]
    private var osFocus: WindowID?  // what macOS last told us, or what we last asked for
    private var restored: [String: Int]  // Window→Desk mapping from the previous run
    private var savedState: [String: Int] = [:]
    private var keep: [Any] = []
    private var shown = Layout()  // what the last reconcile asked for
    private var dragged: Set<WindowID> = []  // Tiled Windows the mouse moved or resized, settled on mouse-up
    private var dragStart: [WindowID: Rect] = [:]  // where each Window was when the mouse went down on it
    private var quietUntil = Date.distantPast  // after a close, macOS picks its own next window: not a Follow
    private var lastHover = Date.distantPast
    private let borders = Borders()
    private lazy var statusBar = StatusBar { [unowned self] line in
        let result = execute(line)
        if !result.hasPrefix("ok") { log(result) }
    }
    private var actual: [WindowID: Rect] = [:]  // where shown Windows really are, as the workers report it
    private var settled = false  // false until macOS reports the focused Window at start (or 2 s pass)

    init() throws {
        // Before reading any screen: without NSApplication, NSScreen misses the menu bar on secondary displays.
        _ = NSApplication.shared
        file = try Daemon.loadConfig()
        world = World(monitors: Daemon.monitors(), config: Daemon.gaps(file), pins: file.pins, layouts: file.layouts)
        restored = (try? JSONDecoder().decode([String: Int].self, from: Data(contentsOf: Daemon.stateURL))) ?? [:]
    }

    func run() -> Never {
        daemon = self
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        log("started, pid \(ProcessInfo.processInfo.processIdentifier)")

        // Per element by default (spike): the system-wide element makes it the default for all of them.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        parkCorner = Daemon.corner()
        monitorRects = world.monitors.map(\.frame)
        registerHotkeys()

        let ws = NSWorkspace.shared.notificationCenter
        keep.append(ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [unowned self] n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { add(a) }
        })
        keep.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [unowned self] n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { remove(a) }
        })
        keep.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [unowned self] _ in
            world.setMonitors(Daemon.monitors())
            parkCorner = Daemon.corner()
            monitorRects = world.monitors.map(\.frame)
            workers.values.forEach { $0.repark() }
            reconcile()
        })
        // Until a Window reports focus, the focused Monitor is the one the cursor is on.
        if let p = CGEvent(source: nil)?.location, let m = world.monitors.first(where: { $0.frame.contains(p.x, p.y) }) {
            world.focus(monitor: m.id)
        }
        NSWorkspace.shared.runningApplications.forEach(add)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [unowned self] in settled = true; reconcile() }
        keep.append(NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [unowned self] _ in hover() } as Any)
        keep.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [unowned self] _ in
            // Let the last move/resize notification of the drag arrive first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.settleDrags() }
        } as Any)

        let port = CFMessagePortCreateLocal(nil, portName, { _, _, data, _ in
            let text = data.flatMap { String(data: $0 as Data, encoding: .utf8) } ?? ""
            return Unmanaged.passRetained(Data(daemon.execute(text).utf8) as CFData)
        }, nil, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMessagePortCreateRunLoopSource(nil, port, 0), .commonModes)

        signal(SIGHUP, SIG_IGN)  // runs in the background: closing the terminal must not stop it
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [unowned self] in
                log("stopping: got signal \(sig)")
                stop()
            }
            source.resume()
            keep.append(source)
        }
        app.run()
        exit(0)
    }

    // MARK: Commands

    /// Runs one line from the CLI or a bind. Returns "ok" or an error message.
    func execute(_ text: String) -> String {
        if text == "stop" {
            log("stopping: tatami stop")
            DispatchQueue.main.async { self.stop() }  // after the reply is sent
            return "ok"
        }
        if text == "state" { return "ok\n" + world.summary }
        guard let command = Command(text) else { return "unknown command: \(text)" }
        return perform(command)
    }

    private func perform(_ command: Command) -> String {
        debug("command \(command)")
        switch command {
        case .reload:
            do {
                file = try Daemon.loadConfig()
            } catch {
                return "\(error)"  // the running config stays
            }
            world.config = Daemon.gaps(file)
            world.setLayouts(file.layouts)
            world.setPins(file.pins)
            registerHotkeys()
        case .exec(let line):
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", line]
            do { try p.run() } catch { return "exec failed: \(error.localizedDescription)" }
        default:
            world.apply(command)
        }
        reconcile(warp: true)
        return "ok"
    }

    /// Every Window returns on-screen, then tatami exits.
    private func stop() -> Never {
        let group = DispatchGroup()
        workers.values.forEach { $0.restore(in: group) }
        _ = group.wait(timeout: .now() + 2)
        exit(0)
    }

    private func registerHotkeys() {
        let binds = file.binds
        let refused = Hotkeys.register(binds.map(\.keys)) { [unowned self] i in
            let result = perform(binds[i].command)
            if result != "ok" { log(result) }
        }
        for keys in refused { log("could not register hotkey \(keys)") }
    }

    // MARK: Events

    private func add(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular, workers[app.processIdentifier] == nil,
              Daemon.onlyPID == nil || Daemon.onlyPID == app.processIdentifier else { return }
        workers[app.processIdentifier] = AppWorker(app: app) { [unowned self] in handle($0) }
    }

    private func remove(_ app: NSRunningApplication) {
        guard let worker = workers.removeValue(forKey: app.processIdentifier) else { return }
        worker.invalidate()
        for (id, w) in owner where w === worker {
            owner[id] = nil
            world.close(id)
        }
        reconcile()
    }

    private func handle(_ event: WindowEvent) {
        if case .frame = event {} else { debug("event \(event) mouse=\(NSEvent.pressedMouseButtons)") }
        var warp = false
        switch event {
        case .opened(let id, let worker, let frame, let floating, let initial):
            guard workers[worker.app.processIdentifier] === worker else { return }
            let rule = file.rules.first { $0.app == worker.app.localizedName || $0.app == worker.app.bundleIdentifier }?.action
            var desk = restored.removeValue(forKey: String(id))
            if desk == nil, case .desk(let n)? = rule { desk = n }
            // At first start each open Window joins the Active Desk of its Monitor.
            if desk == nil, initial { desk = world.activeDesk(on: monitor(at: frame)) }
            owner[id] = worker
            actual[id] = frame
            world.observed(id, at: frame)
            world.open(id, floating: floating || rule == .float, desk: desk, focus: !initial)
        case .closed(let id):
            // Also reached by Hide and minimize: remember the Desk so the Window rejoins it.
            restored[String(id)] = world.desk(of: id)
            owner[id] = nil
            actual[id] = nil
            dragged.remove(id)
            if osFocus == id { osFocus = nil }
            quietUntil = Date() + 0.5
            world.close(id)
        case .focused(let id):
            // Focus tatami did not ask for (app switcher, launcher shortcut, Dock): the cursor follows it,
            // like after a tatami focus command. After a click the cursor is already inside, so nothing moves.
            warp = settled && id != osFocus
            settled = true
            osFocus = id
            // Closing a Window never jumps Desk: right after a close, a Window on a hidden Desk getting focus
            // is macOS choosing, not the user. Skip it and let reconcile put focus back where tatami wants it.
            if !(shown.hidden.contains(id) && Date() < quietUntil) { world.focus(window: id) }
        case .changed(let id):
            if NSEvent.pressedMouseButtons & 1 != 0 { dragged.insert(id) }
        case .minimum(let id, let width, let height):
            world.setMinimumSize(id, width: width, height: height)
        case .nativeFullscreen(let id, let on):
            world.setNativeFullscreen(id, on)
        case .frame(let id, let frame):
            if NSEvent.pressedMouseButtons & 1 != 0, dragStart[id] == nil { dragStart[id] = actual[id] }
            actual[id] = frame
            world.observed(id, at: frame)
            return updateBorders()
        }
        reconcile(warp: warp)
    }

    /// Borders on Tiled and Floating Windows of Active Desks; none in Fullscreen.
    private func updateBorders() {
        var frames: [WindowID: Rect] = [:]
        for id in Set(shown.frames.keys).union(shown.floating).subtracting(shown.fullscreen) { frames[id] = actual[id] }
        borders.update(frames: frames, focused: shown.focused, width: file.borderWidth,
                       active: file.borderActive, inactive: file.borderInactive)
    }

    // MARK: Mouse

    /// Focus follows mouse, without raising.
    private func hover() {
        guard file.focusFollowsMouse, NSEvent.pressedMouseButtons == 0, let p = CGEvent(source: nil)?.location else { return }
        // Cheap way out: still over the focused Tiled Window, and nothing can be floating above it.
        if shown.floating.isEmpty, let f = shown.focused, shown.frames[f]?.contains(p.x, p.y) == true { return }
        guard Date().timeIntervalSince(lastHover) > 0.03 else { return }
        lastHover = Date()

        // A window tatami does not manage counts as nothing being there.
        if let id = windowUnder(p), let worker = owner[id] {
            guard id != world.focusedWindow, !shown.hidden.contains(id) else { return }
            let previous = osFocus.flatMap { old in owner[old].map { (pid: $0.app.processIdentifier, window: old) } }
            debug("hover focuses \(id), was \(String(describing: osFocus))")
            osFocus = id
            world.focus(window: id)
            worker.focus(id, raise: false, previous: previous)
            reconcile()
        } else if let m = world.monitors.first(where: { $0.frame.contains(p.x, p.y) })?.id, m != world.focusedMonitor,
                  let desk = world.activeDesk(on: m), world.windows(onDesk: desk).isEmpty {
            // Moving the cursor to a Monitor with an empty Desk focuses that Monitor.
            world.focus(monitor: m)
            reconcile()
        }
    }

    /// The topmost normal window at a point, front to back.
    private func windowUnder(_ p: CGPoint) -> WindowID? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
        for w in list where w[kCGWindowLayer] as? Int == 0 {
            if let bounds = w[kCGWindowBounds], let r = CGRect(dictionaryRepresentation: bounds as! CFDictionary), r.contains(p) {
                return w[kCGWindowNumber] as? WindowID
            }
        }
        return nil
    }

    /// Mouse-up after dragging Tiled Windows: a resize moves the splits, a move swaps with the Window at the cursor.
    private func settleDrags() {
        let starts = dragStart
        dragStart = [:]
        for id in dragged {
            guard let worker = owner[id], let before = starts[id] ?? shown.frames[id] else { continue }
            worker.frame(of: id) { [unowned self] got in
                guard let got, let cursor = CGEvent(source: nil)?.location else { return }
                debug("drag settled \(id): \(before) -> \(got), cursor \(cursor)")
                if abs(got.w - before.w) > 2 || abs(got.h - before.h) > 2 {
                    world.resized(id, from: before, to: got)
                } else {
                    world.dropped(id, atX: cursor.x, y: cursor.y)
                }
                worker.forgetPlacement(id)  // also snaps it back if nothing changed
                reconcile()
            }
        }
        dragged = []
    }

    private func monitor(at r: Rect) -> MonitorID {
        let x = r.x + r.w / 2, y = r.y + r.h / 2
        return world.monitors.first { $0.frame.x <= x && x < $0.frame.maxX && $0.frame.y <= y && y < $0.frame.maxY }?.id
            ?? world.focusedMonitor
    }

    // MARK: Reconciler

    /// Tell every worker where its Windows belong; each one skips what is already in place.
    private func reconcile(warp: Bool = false) {
        let layout = world.layout
        shown = layout
        for (id, frame) in layout.frames {
            owner[id]?.place(id, .frame(frame))
            actual[id] = frame  // optimistic; the worker corrects it if the app disagrees
        }
        for id in layout.floating { owner[id]?.place(id, .free) }
        for id in layout.hidden {
            owner[id]?.place(id, .parked)
            actual[id] = nil
        }
        updateBorders()
        statusBar.show(desks: world.monitors.compactMap { world.activeDesk(on: $0.id) }, focused: world.focusedDesk)
        if settled, layout.focused != osFocus {
            let previous = osFocus.flatMap { old in owner[old].map { (pid: $0.app.processIdentifier, window: old) } }
            debug("reconcile focuses \(String(describing: layout.focused)), macOS had \(String(describing: osFocus))")
            osFocus = layout.focused
            if let f = layout.focused {
                owner[f]?.focus(f, raise: true, previous: previous)
            } else {
                // Nothing focused: take the keyboard away from whatever Window macOS still has it on.
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        // Every keyboard command leaves the cursor in the focused Window, whether or not focus had to move.
        if warp, let f = layout.focused { owner[f]?.warp(f) }
        if warp, layout.focused == nil, let m = world.monitors.first(where: { $0.id == world.focusedMonitor })?.frame,
           let cursor = CGEvent(source: nil)?.location, !m.contains(cursor.x, cursor.y) {
            CGWarpMouseCursorPosition(CGPoint(x: m.x + m.w / 2, y: m.y + m.h / 2))
        }
        saveState()
    }

    private func saveState() {
        var state: [String: Int] = [:]
        for id in owner.keys { state[String(id)] = world.desk(of: id) }
        guard state != savedState else { return }
        savedState = state
        do {
            try FileManager.default.createDirectory(at: Daemon.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: Daemon.stateURL, options: .atomic)
        } catch {
            log("could not save state: \(error.localizedDescription)")
        }
    }

    // MARK: Environment

    /// Gaps are what you see between borders, so the layout leaves room for the borders too.
    private static func gaps(_ file: ConfigFile) -> Config {
        var c = file.layout
        c.gapInner += 2 * file.borderWidth
        c.gapOuter += file.borderWidth
        return c
    }

    static func loadConfig() throws -> ConfigFile {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return .builtin }
        let file = try ConfigFile.user(String(contentsOf: configURL, encoding: .utf8))
        for bind in file.binds where Hotkeys.parse(bind.keys) == nil {
            throw ConfigFile.ParseError(line: bind.line, message: "unknown key combination `\(bind.keys)`")
        }
        return file
    }

    /// Monitors in Accessibility coordinates (origin top-left of the primary display), minus menu bar and Dock.
    private static func monitors() -> [Monitor] {
        let primaryHeight = NSScreen.screens[0].frame.height
        return NSScreen.screens.map { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
            let uuid = CGDisplayCreateUUIDFromDisplayID(number).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
            let v = screen.visibleFrame
            return Monitor(id: uuid ?? String(number), frame: Rect(v.minX, primaryHeight - v.maxY, v.width, v.height))
        }
    }

    private static func corner() -> CGPoint {
        let all = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        return CGPoint(x: all.maxX - 1, y: NSScreen.screens[0].frame.height - all.minY - 1)
    }
}

/// With TATAMI_DEBUG set, every event, command and focus decision goes to the log.
let debugging = ProcessInfo.processInfo.environment["TATAMI_DEBUG"] != nil
func debug(_ message: @autoclosure () -> String) { if debugging { log(message()) } }

func log(_ message: String) {
    // Timestamps in the log file, not in front of CLI errors on a terminal.
    let time = isatty(2) == 0 ? ISO8601DateFormatter().string(from: Date()) + " " : ""
    FileHandle.standardError.write(Data("\(time)tatami: \(message)\n".utf8))
}
