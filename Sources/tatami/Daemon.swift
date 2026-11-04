import AppKit
import ApplicationServices
import Carbon.HIToolbox
import TatamiCore

// Test isolation (used by tatami-e2e): TATAMI_PORT renames the CLI port, TATAMI_HOME holds config and state,
// TATAMI_ONLY_PID limits tatami to the listed apps (comma separated).
private let environment = ProcessInfo.processInfo.environment
let portName = (environment["TATAMI_PORT"] ?? "dev.tatami.cli") as CFString
private var daemon: Daemon!

final class Daemon {
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let testHome = environment["TATAMI_HOME"].map { URL(fileURLWithPath: $0) }
    private static let configURL = testHome?.appendingPathComponent("config") ?? home.appendingPathComponent(".config/tatami/config")
    private static let stateURL = testHome?.appendingPathComponent("state.json")
        ?? home.appendingPathComponent("Library/Application Support/tatami/state.json")
    private static let onlyPIDs = environment["TATAMI_ONLY_PID"].map { Set($0.split(separator: ",").compactMap { pid_t($0) }) }

    private var file: ConfigFile
    private var world: World
    private var workers: [pid_t: AppWorker] = [:]
    private var owner: [WindowID: AppWorker] = [:]
    private var osFocus: WindowID?  // what macOS last told us, or what we last asked for
    private var rejoin: [WindowID: Int] = [:]  // Desk of Windows that left (Hide, minimize), for when they return
    private var awaited: [SavedWindow]  // Windows of the saved arrangement that have not shown up yet
    private var titles: [WindowID: String] = [:]
    private var lastSaved = Data()
    private var saveScheduled = false
    private var keep: [Any] = []
    private var quits: [pid_t: NSKeyValueObservation] = [:]
    private var shown = Layout()  // what the last reconcile asked for
    private var dragged: Set<WindowID> = []  // Tiled Windows the mouse moved or resized, settled on mouse-up
    private var dragStart: [WindowID: Rect] = [:]  // where each Window was when the mouse went down on it
    private var quietUntil = Date.distantPast  // after a close, macOS picks its own next window: not a Follow
    private var lastHover = Date.distantPast
    private var lastMouseMove = Date.distantPast
    /// When a hover asked macOS to focus each Window, until macOS confirms it.
    private var hovered: [WindowID: Date] = [:]
    /// When each dialog or panel opened: its app focusing it right then is part of opening, not focus from outside.
    private var born: [WindowID: Date] = [:]
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
        let saved = try? JSONDecoder().decode(SavedState.self, from: Data(contentsOf: Daemon.stateURL))
        world = World(monitors: Daemon.monitors(), config: Daemon.gaps(file), pins: file.pins, layouts: file.layouts,
                      restoring: saved?.world)
        awaited = saved?.windows ?? []
        // The state file used to be just Window id -> Desk: still honour one, so an upgrade keeps the Desks.
        if saved == nil, let old = try? JSONDecoder().decode([String: Int].self, from: Data(contentsOf: Daemon.stateURL)) {
            for (id, desk) in old { if let id = WindowID(id) { rejoin[id] = desk } }
        }
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
        // Letters follow the keyboard layout, so switching layouts moves the hotkeys.
        keep.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [unowned self] _ in registerHotkeys() })

        let ws = NSWorkspace.shared.notificationCenter
        keep.append(ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [unowned self] n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { add(a) }
        })
        keep.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [unowned self] n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { add(a, withWindow: true) }
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
        // Whatever macOS has focused right now must not pull a hidden Desk of the saved arrangement into view.
        quietUntil = Date() + 3
        // Until a Window reports focus, the focused Monitor is the one the cursor is on.
        if let p = CGEvent(source: nil)?.location, let m = world.monitors.first(where: { $0.frame.contains(p.x, p.y) }) {
            world.focus(monitor: m.id)
        }
        let owners = Set((CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[CFString: Any]] ?? [])
            .filter { $0[kCGWindowLayer] as? Int == 0 }.compactMap { $0[kCGWindowOwnerPID] as? pid_t })
        for app in NSWorkspace.shared.runningApplications { add(app, withWindow: owners.contains(app.processIdentifier)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [unowned self] in settled = true; reconcile() }
        // Windows of the saved arrangement get this long to come back (apps reopening after login).
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [unowned self] in
            awaited = []
            world.dropPlaceholders()
            reconcile()
        }
        keep.append(NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [unowned self] _ in hover() } as Any)
        // A global monitor only sees events meant for other apps. With nothing focused (an empty Desk) tatami itself is
        // the active app and gets the mouse events: without this, focus follows mouse was dead until a click.
        keep.append(NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [unowned self] e in hover(); return e } as Any)
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
        writeState()
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

    /// Regular apps are always watched. Menu bar ("accessory") apps number in the dozens and rarely have a
    /// window, so one is watched only from the moment it shows one: when it becomes active, or at start if it
    /// already owns a window (`withWindow`). Their Windows float.
    private func add(_ app: NSRunningApplication, withWindow: Bool = false) {
        let pid = app.processIdentifier
        guard workers[pid] == nil, pid != getpid(), Daemon.onlyPIDs?.contains(pid) != false,
              app.activationPolicy == .regular || (app.activationPolicy == .accessory && withWindow) else { return }
        workers[pid] = AppWorker(app: app) { [unowned self] in handle($0) }
        // NSWorkspace only announces regular apps quitting: watch the app itself so no window outlives it.
        quits[pid] = app.observe(\.isTerminated) { [unowned self] app, _ in
            DispatchQueue.main.async { if app.isTerminated { self.remove(app) } }
        }
    }

    private func remove(_ app: NSRunningApplication) {
        quits[app.processIdentifier] = nil
        guard let worker = workers.removeValue(forKey: app.processIdentifier) else { return }
        worker.invalidate()
        for (id, w) in owner where w === worker {
            owner[id] = nil
            actual[id] = nil
            if osFocus == id { osFocus = nil }
            quietUntil = Date() + 0.5  // an app quitting never jumps Desk either
            world.close(id)
        }
        reconcile()
    }

    private func handle(_ event: WindowEvent) {
        if case .frame = event {} else { debug("event \(event) mouse=\(NSEvent.pressedMouseButtons)") }
        var warp = false
        switch event {
        case .opened(let id, let worker, let frame, let title, let floating, let initial):
            guard workers[worker.app.processIdentifier] === worker else { return }
            owner[id] = worker
            actual[id] = frame
            titles[id] = title
            world.observed(id, at: frame)
            // Part of the arrangement saved last time? Then it goes back to exactly where it was.
            if let saved = claim(app: Daemon.key(worker.app), title: title, id: id),
               world.adopt(saved.id, as: id, floating: floating || saved.floating) { break }
            let rule = file.rules.first { $0.app == worker.app.localizedName || $0.app == worker.app.bundleIdentifier }?.action
            var desk = rejoin.removeValue(forKey: id)
            if desk == nil, case .desk(let n)? = rule { desk = n }
            // At first start each open Window joins the Active Desk of its Monitor.
            if desk == nil, initial { desk = world.activeDesk(on: monitor(at: frame)) }
            // A dialog or panel gets focus from its app, or not at all: tatami follows, never decides. Forcing it took
            // focus from a password field for its Caps Lock indicator, which then closed and reopened in a loop.
            if floating { born[id] = Date() }
            world.open(id, floating: floating || rule == .float, desk: desk, focus: !initial && !floating)
        case .closed(let id):
            // Also reached by Hide and minimize: remember the Desk so the Window rejoins it.
            rejoin[id] = world.desk(of: id)
            titles[id] = nil
            owner[id] = nil
            actual[id] = nil
            dragged.remove(id)
            hovered[id] = nil
            born[id] = nil
            if osFocus == id { osFocus = nil }
            quietUntil = Date() + 0.5
            world.close(id)
        case .focused(let id):
            // macOS confirms a hover focus late, and across apps out of order: by then the mouse may be on another
            // Window. That is no focus from outside, and following it would undo the newer hover.
            // ponytail: 1 s window; number the requests if a real switch back within it ever gets lost.
            if id == osFocus { hovered[id] = nil } else if Date().timeIntervalSince(hovered[id] ?? .distantPast) < 1 {
                return debug("late confirmation of the hover on \(id) ignored")
            }
            // Focus tatami did not ask for (app switcher, launcher shortcut, Dock): the cursor follows it,
            // like after a tatami focus command. After a click the cursor is already inside, so nothing moves.
            // Never while the mouse is in use: an app answering a hover by focusing another of its windows
            // would pull the cursor out of the user's hand.
            warp = settled && id != osFocus && Date().timeIntervalSince(born[id] ?? .distantPast) > 1
            if warp, Date().timeIntervalSince(lastMouseMove) < 0.7 {
                warp = false
                log("focus went to window \(id) of \(owner[id]?.app.localizedName ?? "?") while the mouse was on \(osFocus.map(String.init) ?? "nothing"); cursor left alone")
            }
            // The app of the Window that had focus quit (the workspace may only say so later): macOS choosing again.
            let quit = osFocus.flatMap { owner[$0]?.app.isTerminated } ?? false
            settled = true
            osFocus = id
            // Closing a Window never jumps Desk: right after a close, a Window on a hidden Desk getting focus
            // is macOS choosing, not the user. Skip it and let reconcile put focus back where tatami wants it.
            if !(shown.hidden.contains(id) && (Date() < quietUntil || quit)) { world.focus(window: id) }
        case .changed(let id):
            if NSEvent.pressedMouseButtons & 1 != 0 { dragged.insert(id) }
        case .minimum(let id, let width, let height):
            world.setMinimumSize(id, width: width, height: height)
        case .fixed(let id):
            world.float(id)
        case .nativeFullscreen(let id, let on):
            world.setNativeFullscreen(id, on)
        case .title(let id, let title):
            titles[id] = title
            return scheduleSave()
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
        lastMouseMove = Date()
        guard file.focusFollowsMouse, NSEvent.pressedMouseButtons == 0, let p = CGEvent(source: nil)?.location else { return }
        // Cheap way out: still over the focused Tiled Window, and nothing can be above it (no Floating Window, and
        // not an Accordion, where the focused Window may sit behind another).
        if shown.floating.isEmpty, world.layoutKind(ofDesk: world.focusedDesk) != .accordion,
           let f = shown.focused, shown.frames[f]?.contains(p.x, p.y) == true { return }
        guard Date().timeIntervalSince(lastHover) > 0.03 else { return }
        lastHover = Date()

        // A window tatami does not manage counts as nothing being there.
        let stack = windowsFrontToBack()
        if var id = stack.first(where: { $0.bounds.contains(p) })?.id, owner[id] != nil {
            // In an Accordion the Windows behind peek out from under the one on top. Hovering such an edge must not
            // take focus from the Window you see: only a click brings another one forward. So the mouse anywhere
            // on an Accordion counts as being on whichever of its Windows is on top.
            if shown.frames[id] != nil, let desk = world.desk(of: id), world.layoutKind(ofDesk: desk) == .accordion {
                let stacked = Set(world.windows(onDesk: desk)).intersection(shown.frames.keys)
                id = stack.first { stacked.contains($0.id) }?.id ?? id
            }
            guard let worker = owner[id], id != world.focusedWindow, !shown.hidden.contains(id) else { return }
            let previous = osFocus.flatMap { old in owner[old].map { (pid: $0.app.processIdentifier, window: old) } }
            debug("hover focuses \(id), was \(String(describing: osFocus))")
            osFocus = id
            hovered[id] = Date()
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

    /// Windows on screen, front to back: normal ones and those above them up to the Dock (panels, system prompts).
    /// A prompt is not a window tatami manages, but the mouse over it is not on the Window underneath either.
    private func windowsFrontToBack() -> [(id: WindowID, bounds: CGRect)] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
        return list.compactMap { w in
            guard let layer = w[kCGWindowLayer] as? Int, (0..<Int(CGWindowLevelForKey(.dockWindow))).contains(layer),
                  w[kCGWindowAlpha] as? Double ?? 1 > 0, let id = w[kCGWindowNumber] as? WindowID, let bounds = w[kCGWindowBounds],
                  let r = CGRect(dictionaryRepresentation: bounds as! CFDictionary) else { return nil }
            return (id, r)
        }
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
                // Its raise may bury a Floating Window: put that right at once, not at the next check.
                owner[f]?.focus(f, raise: true, previous: previous) { [unowned self] in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { self.restack() }
                }
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
        scheduleSave()
        scheduleRestack()
    }

    // MARK: Accordion stacking

    private var restacking: DispatchWorkItem?
    private var lastRestack: (raised: [WindowID], order: [WindowID], at: Date) = ([], [], .distantPast)

    /// Checked a moment after every change, once the raise that came with it has landed.
    private func scheduleRestack() {
        restacking?.cancel()
        let work = DispatchWorkItem { [unowned self] in restack() }
        restacking = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Two things macOS does not keep true by itself. Floating Windows stay above Tiled ones. And
    /// in an Accordion every Window shows an edge only if, going outwards from the front one on either side, each
    /// Window sits above the next. macOS brings one window forward at a time (a click, a focus), which can bury
    /// the ones in between: bring those forward again, from the far ones to the front one.
    private func restack() {
        guard NSEvent.pressedMouseButtons == 0 else { return scheduleRestack() }  // not in the middle of a drag
        let depth = Dictionary(windowsFrontToBack().enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var raise: [WindowID] = [], order: [WindowID] = []
        for m in world.monitors {
            guard let desk = world.activeDesk(on: m.id) else { continue }
            let members = world.windows(onDesk: desk).filter { depth[$0] != nil }
            order += members.sorted { depth[$0]! < depth[$1]! }
            let tiled = members.filter { shown.frames[$0] != nil }
            guard !tiled.contains(where: shown.fullscreen.contains) else { continue }
            var up: [WindowID] = []
            let stack = tiled.sorted { (shown.frames[$0]!.x, shown.frames[$0]!.y) < (shown.frames[$1]!.x, shown.frames[$1]!.y) }
            if world.layoutKind(ofDesk: desk) == .accordion, let f = stack.firstIndex(where: shown.front.contains) {
                var buried: [WindowID] = []
                // Each side from its far end towards the front: whatever is not below its nearer neighbours comes forward.
                for side in [Array(stack[..<f]), Array(stack[(f + 1)...].reversed())] where !side.isEmpty {
                    var inOrder = 1
                    while inOrder < side.count, depth[side[inOrder]]! < depth[side[inOrder - 1]]! { inOrder += 1 }
                    buried += side.dropFirst(inOrder)
                }
                let frontOnTop = stack.allSatisfy { $0 == stack[f] || depth[stack[f]]! < depth[$0]! }
                if !buried.isEmpty || !frontOnTop { up = buried + [stack[f]] }
            }
            // Floating Windows are drawn over Tiled ones: one that a Tiled Window covers comes forward again
            // (from the back, so they keep their own order).
            let covered = members.filter(shown.floating.contains).sorted { depth[$0]! > depth[$1]! }.filter { f in
                guard let r = actual[f] else { return false }
                return tiled.contains { t in
                    let o = shown.frames[t]!
                    return (depth[t]! < depth[f]! || up.contains(t)) && o.x < r.maxX && r.x < o.maxX && o.y < r.maxY && r.y < o.maxY
                }
            }
            raise += up + covered
        }
        guard !raise.isEmpty else { return }
        // Each window is only asked to come forward: no app becomes the front one, the keyboard stays where it is,
        // nothing blinks. Some apps ignore that (System Settings): their window then stays behind like any macOS
        // window, until it is focused. Forcing it forward means making its app the front one, which took the
        // keyboard away and blinked. Same windows in the same order as before the last try: it changed nothing.
        if raise == lastRestack.raised, order == lastRestack.order, Date().timeIntervalSince(lastRestack.at) < 2 { return }
        lastRestack = (raise, order, Date())
        debug("restack raises \(raise)")
        raiseInTurn(raise[...], all: raise)
    }

    private func raiseInTurn(_ ids: ArraySlice<WindowID>, all: [WindowID]) {
        guard let id = ids.first else {
            // Within one app, the window brought forward last also became its key window: the keyboard goes back
            // to the focused Window, without raising it.
            if let f = shown.focused, let from = all.last(where: { $0 != f && owner[$0] === owner[f] }) {
                owner[f]?.focus(f, raise: false, previous: owner[from].map { (pid: $0.app.processIdentifier, window: from) })
            }
            updateBorders()
            return scheduleRestack()  // did it work?
        }
        guard let worker = owner[id] else { return raiseInTurn(ids.dropFirst(), all: all) }
        worker.raise(id) { [unowned self] in raiseInTurn(ids.dropFirst(), all: all) }
    }

    // MARK: State

    private struct SavedWindow: Codable {
        var id: WindowID
        var app: String  // bundle id, or name
        var title: String
        var floating: Bool
    }

    private struct SavedState: Codable {
        var world: World.Snapshot
        var windows: [SavedWindow]
    }

    private static func key(_ app: NSRunningApplication) -> String { app.bundleIdentifier ?? app.localizedName ?? "" }

    /// The saved Window this one is: same id while the Mac stayed on; after a reboot ids are new,
    /// so same app and title, else the app's next unclaimed Window.
    private func claim(app: String, title: String, id: WindowID) -> SavedWindow? {
        let i = awaited.firstIndex { $0.app == app && $0.id == id }
            ?? awaited.firstIndex { $0.app == app && $0.title == title }
            ?? awaited.firstIndex { $0.app == app }
        return i.map { awaited.remove(at: $0) }
    }

    /// Saves a second from now at most, so a burst of changes is one write.
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [unowned self] in
            saveScheduled = false
            writeState()
        }
    }

    private func writeState() {
        // While Windows of the saved arrangement are still awaited, the file on disk knows more than we do.
        guard !world.hasPlaceholders else { return }
        let floating = world.layout.floating
        let windows = owner.keys.sorted().compactMap { id in
            owner[id].map { SavedWindow(id: id, app: Daemon.key($0.app), title: titles[id] ?? "", floating: floating.contains(id)) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(SavedState(world: world.snapshot, windows: windows)), data != lastSaved else { return }
        lastSaved = data
        do {
            try FileManager.default.createDirectory(at: Daemon.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: Daemon.stateURL, options: .atomic)
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
