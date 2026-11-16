import AppKit
import ApplicationServices
import TatamiCore

enum Placement: Equatable { case frame(Rect), parked, free }

enum WindowEvent {
    case opened(WindowID, AppWorker, at: Rect, floating: Bool, initial: Bool)
    case closed(WindowID)
    case focused(WindowID)
    /// A Tiled Window is not where tatami put it (mouse drag, or the app moved itself).
    case changed(WindowID)
    /// The Window refused to shrink; 0 for a dimension it accepted.
    case minimum(WindowID, width: Double, height: Double)
    case nativeFullscreen(WindowID, Bool)
    /// Where the Window really is now (for its border).
    case frame(WindowID, Rect)
}

/// Where hidden Desks park their Windows: the bottom-right corner of all Monitors.
var parkCorner = CGPoint.zero
/// Monitor frames, for centring a Window that stops being tiled.
var monitorRects: [Rect] = []

/// All Accessibility traffic for one app, on its own serial queue, so a hung app only stalls itself.
final class AppWorker {
    let app: NSRunningApplication
    private let emit: (WindowEvent) -> Void  // always called on the main queue
    private let queue: DispatchQueue
    private let element: AXUIElement
    private var observer: AXObserver?

    // Touched only on `queue`.
    private var windows: [WindowID: AXUIElement] = [:]
    private var wanted: [WindowID: Placement] = [:]  // what the daemon last asked for
    private var placed: [WindowID: Placement] = [:]  // what was applied successfully
    private var retryScheduled = false
    private var retries: [WindowID: Int] = [:]  // clamped-resize retries for the current target
    private var sizes: [WindowID: CGSize] = [:]  // last size set, to skip the slow resize call on a Desk switch
    private var saved: [WindowID: CGPoint] = [:]  // position before parking
    private var native: Set<WindowID> = []  // in macOS native fullscreen
    private var hungUntil: UInt64 = 0
    private var scanned = false

    init(app: NSRunningApplication, emit: @escaping (WindowEvent) -> Void) {
        self.app = app
        self.emit = emit
        queue = DispatchQueue(label: "tatami.app.\(app.processIdentifier)")
        element = AXUIElementCreateApplication(app.processIdentifier)
        queue.async { self.start(attempt: 0) }
    }

    /// Call before dropping the worker: the observer holds an unretained pointer to it.
    func invalidate() {
        queue.sync {
            if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
            observer = nil
        }
    }

    func place(_ id: WindowID, _ target: Placement) {
        queue.async { [self] in
            if wanted[id] != target { retries[id] = nil }
            wanted[id] = target
            apply(id)
        }
    }

    private func apply(_ id: WindowID) {
        guard let w = windows[id], let target = wanted[id], placed[id] != target, !native.contains(id) else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= hungUntil else { return retryLater() }
        var err = AXError.success
        switch target {
        case .frame(let r):
            // Position, size, position: the size can be clamped by the old position, and can shift the origin.
            let p = CGPoint(x: r.x, y: r.y), s = CGSize(width: r.w, height: r.h)
            err = setPosition(w, p)
            if err == .success, sizes[id] != s {
                err = setSize(w, s)
                if err == .success {
                    sizes[id] = s
                    setPosition(w, p)
                    // A window just moved to another Monitor has its resize clamped to the old one until the app
                    // catches up: try again shortly, twice at most (some windows really are smaller than asked).
                    if let got = size(w), got.width < s.width - 1 || got.height < s.height - 1, retries[id, default: 0] < 2 {
                        retries[id, default: 0] += 1
                        queue.asyncAfter(deadline: .now() + 0.15) { [self] in
                            guard wanted[id] == target else { return }
                            placed[id] = nil; sizes[id] = nil
                            apply(id)
                        }
                    }
                    // Apps resize late or animate: a size is a minimum only once it has stopped changing
                    // (same for 150 ms, waiting 1 s at most) and is still too big.
                    func tooBig(_ z: CGSize?) -> Bool { z.map { $0.width > s.width + 1 || $0.height > s.height + 1 } ?? false }
                    var last = size(w), still = 0
                    for _ in 0..<20 where tooBig(last) && still < 3 {
                        usleep(50_000)
                        let next = size(w)
                        still = next == last ? still + 1 : 0
                        last = next
                    }
                    if let got = last, tooBig(got) {
                        send(.minimum(id, width: got.width > s.width + 1 ? got.width : 0,
                                      height: got.height > s.height + 1 ? got.height : 0))
                    }
                }
            }
        case .parked:
            guard let p = position(w) else { return }
            saved[id] = p
            err = setPosition(w, parkCorner)
        case .free:
            if placed[id] == .parked {
                err = setPosition(w, saved[id] ?? CGPoint(x: 40, y: 40))
            } else if case .frame(let tile)? = placed[id],
                      let m = monitorRects.first(where: { $0.contains(tile.x + tile.w / 2, tile.y + tile.h / 2) }) {
                // Was tiled, now floats: a tile-shaped Floating Window is no use, so centre it at a comfortable size.
                // Position first: where the tile was, the Monitor's edge would clamp the new size.
                var s = CGSize(width: m.w * 0.6, height: m.h * 0.7)
                setPosition(w, CGPoint(x: m.x + (m.w - s.width) / 2, y: m.y + (m.h - s.height) / 2))
                setSize(w, s)
                s = size(w) ?? s
                err = setPosition(w, CGPoint(x: m.x + (m.w - s.width) / 2, y: m.y + (m.h - s.height) / 2))
                sizes[id] = nil
            }
        }
        if err == .success {
            placed[id] = target
            if target != .parked, let r = frame(w) { send(.frame(id, r)) }
        } else if err == .cannotComplete {
            // Timed out: skip the app for a while instead of paying the timeout per call, then try again.
            hungUntil = now + 2_000_000_000
            log("\(app.localizedName ?? "?") is not answering, retrying in 2 s")
            retryLater()
        } else {
            log("\(app.localizedName ?? "?"): could not place window \(id) (AXError \(err.rawValue))")
        }
    }

    private func retryLater() {
        guard !retryScheduled else { return }
        retryScheduled = true
        queue.asyncAfter(deadline: .now() + 2.1) { [self] in
            retryScheduled = false
            wanted.keys.forEach(apply)
        }
    }

    /// Forget what was applied, so the next `place` sets the frame again (after a mouse drag).
    func forgetPlacement(_ id: WindowID) {
        queue.async { [self] in placed[id] = nil; sizes[id] = nil }
    }

    func frame(of id: WindowID, reply: @escaping (Rect?) -> Void) {
        queue.async { [self] in
            let r = windows[id].flatMap(frame)
            DispatchQueue.main.async { reply(r) }
        }
    }

    /// `raise` false is focus-follows-mouse. `previous` is the Window that had focus.
    func focus(_ id: WindowID, raise: Bool, previous: (pid: pid_t, window: WindowID)?) {
        queue.async { [self] in
            guard let w = windows[id] else { return }
            if raise { AXUIElementPerformAction(w, kAXRaiseAction as CFString) }
            focusWindow(pid: app.processIdentifier, window: id, previous: previous, raise: raise)
        }
    }

    /// Move the cursor to the Window's centre, unless it is already inside.
    func warp(_ id: WindowID) {
        queue.async { [self] in
            guard let w = windows[id], let r = frame(w), let cursor = CGEvent(source: nil)?.location,
                  !r.contains(cursor.x, cursor.y) else { return }
            CGWarpMouseCursorPosition(CGPoint(x: r.x + r.w / 2, y: r.y + r.h / 2))
        }
    }

    /// Bring parked Windows back on-screen (tatami is quitting).
    func restore(in group: DispatchGroup) {
        queue.async(group: group) { [self] in
            for (id, p) in placed where p == .parked {
                if let w = windows[id] { setPosition(w, saved[id] ?? CGPoint(x: 40, y: 40)) }
            }
        }
    }

    /// The parking corner moved (Monitors changed).
    func repark() {
        queue.async { [self] in
            for (id, p) in placed where p == .parked {
                if let w = windows[id] { setPosition(w, parkCorner) }
            }
        }
    }

    // MARK: On `queue`

    private func start(attempt: Int) {
        var created: AXObserver?
        guard AXObserverCreate(app.processIdentifier, observerCallback, &created) == .success, let created else { return }
        let me = Unmanaged.passUnretained(self).toOpaque()
        let err = AXObserverAddNotification(created, element, kAXWindowCreatedNotification as CFString, me)
        guard err == .success || err == .notificationAlreadyRegistered else {
            // A freshly launched app may not answer yet.
            if attempt < 5, !app.isTerminated { queue.asyncAfter(deadline: .now() + 1) { self.start(attempt: attempt + 1) } }
            return
        }
        for n in [kAXFocusedWindowChangedNotification, kAXApplicationActivatedNotification,
                  kAXApplicationHiddenNotification, kAXApplicationShownNotification] {
            AXObserverAddNotification(created, element, n as CFString, me)
        }
        observer = created
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        scan()
        reportFocus()
    }

    fileprivate func notified(_ name: String, _ el: AXUIElement) {
        queue.async { [self] in
            switch name {
            case kAXWindowCreatedNotification, kAXWindowDeminiaturizedNotification, kAXApplicationShownNotification:
                scan()
                // Some apps announce a window before it is listed, has its subrole, or is on screen.
                for delay in [0.3, 1.0] { queue.asyncAfter(deadline: .now() + delay) { self.scan() } }
            case kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification:
                if let id = id(of: el) { forget(id) }
            case kAXApplicationHiddenNotification:
                // Hide: the Windows leave the tiling. The daemon remembers their Desks for when they return.
                windows.keys.forEach(forget)
            case kAXWindowMovedNotification, kAXWindowResizedNotification:
                if let id = id(of: el) { moved(id) }
            default:
                reportFocus()
            }
        }
    }

    private func id(of el: AXUIElement) -> WindowID? { windows.first { CFEqual($0.value, el) }?.key }

    private func forget(_ id: WindowID) {
        windows[id] = nil; wanted[id] = nil; placed[id] = nil; sizes[id] = nil; saved[id] = nil; native.remove(id)
        send(.closed(id))
    }

    private func moved(_ id: WindowID) {
        guard let w = windows[id] else { return }
        let fullscreen = attribute(w, "AXFullScreen") as? Bool == true
        if fullscreen != native.contains(id) {
            if fullscreen { native.insert(id) } else { native.remove(id) }
            placed[id] = nil; sizes[id] = nil
            send(.nativeFullscreen(id, fullscreen))
        }
        guard !fullscreen, let got = frame(w) else { return }
        send(.frame(id, got))
        guard case .frame(let want)? = placed[id] else { return }
        let off = [got.x - want.x, got.y - want.y, got.w - want.w, got.h - want.h].contains { abs($0) > 2 }
        if off { send(.changed(id)) }
    }

    private func scan() {
        guard let observer, !app.isHidden, let list = attribute(element, kAXWindowsAttribute) as? [AXUIElement] else { return }
        // Apps keep invisible helper windows around: a real one is in the window server's on-screen list.
        let visible = Set((CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[CFString: Any]] ?? [])
            .filter { $0[kCGWindowLayer] as? Int == 0 }.compactMap { $0[kCGWindowNumber] as? WindowID })
        let me = Unmanaged.passUnretained(self).toOpaque()
        for w in list {
            var id: CGWindowID = 0
            guard _AXUIElementGetWindow(w, &id) == .success, windows[id] == nil, visible.contains(id),
                  let subrole = attribute(w, kAXSubroleAttribute) as? String,
                  [kAXStandardWindowSubrole, kAXDialogSubrole, kAXSystemDialogSubrole, kAXFloatingWindowSubrole].contains(subrole)
            else { continue }
            for n in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                      kAXWindowMovedNotification, kAXWindowResizedNotification] {
                AXObserverAddNotification(observer, w, n as CFString, me)
            }
            // Minimized Windows are ignored until restored.
            guard attribute(w, kAXMinimizedAttribute) as? Bool != true, let r = frame(w) else { continue }
            windows[id] = w
            if r.x >= parkCorner.x - 2 {
                // Left parked by a tatami that crashed: its original position is gone. (macOS clamps y, so x decides.)
                placed[id] = .parked
            }
            // Dialogs, panels and windows that cannot be resized float.
            var resizable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(w, kAXSizeAttribute as CFString, &resizable)
            send(.opened(id, self, at: r, floating: subrole != kAXStandardWindowSubrole || !resizable.boolValue, initial: !scanned))
            if attribute(w, "AXFullScreen") as? Bool == true {
                native.insert(id)
                send(.nativeFullscreen(id, true))
            }
        }
        scanned = true
    }

    private func reportFocus() {
        guard app.isActive, let w = attribute(element, kAXFocusedWindowAttribute) else { return }
        var id: CGWindowID = 0
        if _AXUIElementGetWindow(w as! AXUIElement, &id) == .success, windows[id] != nil { send(.focused(id)) }
    }

    private func send(_ event: WindowEvent) { DispatchQueue.main.async { self.emit(event) } }

    private func frame(_ w: AXUIElement) -> Rect? {
        guard let p = position(w), let s = size(w) else { return nil }
        return Rect(p.x, p.y, s.width, s.height)
    }
}

private let observerCallback: AXObserverCallback = { _, element, notification, me in
    Unmanaged<AppWorker>.fromOpaque(me!).takeUnretainedValue().notified(notification as String, element)
}

private func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}

private func position(_ w: AXUIElement) -> CGPoint? {
    guard let v = attribute(w, kAXPositionAttribute) else { return nil }
    var p = CGPoint.zero
    AXValueGetValue(v as! AXValue, .cgPoint, &p)
    return p
}

private func size(_ w: AXUIElement) -> CGSize? {
    guard let v = attribute(w, kAXSizeAttribute) else { return nil }
    var s = CGSize.zero
    AXValueGetValue(v as! AXValue, .cgSize, &s)
    return s
}

@discardableResult private func setPosition(_ w: AXUIElement, _ p: CGPoint) -> AXError {
    var p = p
    return AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
}

@discardableResult private func setSize(_ w: AXUIElement, _ s: CGSize) -> AXError {
    var s = s
    return AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!)
}
