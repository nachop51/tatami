// End-to-end regression tests: a real tatami, real windows, real (synthetic) mouse input.
//
//   swift build && swift run tatami-e2e                  every scenario (about 2 minutes)
//   swift build && swift run tatami-e2e dialogs follow   only those
//   swift run tatami-e2e --list                          their names
//   swift run tatami-e2e --no-mouse                      skip hovering and dragging
//
// macOS has one window server and one cursor per login session, so this cannot run headless: the test
// windows are real and the mouse scenarios move the real cursor. --no-mouse also turns focus-follows-mouse
// off in the test tatami, so you can keep using the mouse while it runs (it still takes keyboard focus).
//
// Every scenario starts its own helper apps and its own isolated tatami that manages only those apps
// (own port, config and state), then checks what actually happens on screen, on the Monitor the cursor
// is on. Your own tatami must be stopped. Needs Accessibility permission for whatever launches it.
import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow") func _AXUIElementGetWindow(_ e: AXUIElement, _ id: inout CGWindowID) -> AXError

// MARK: - Helper app (this binary with --app): opens and closes windows on request

if CommandLine.arguments.contains("--app") {
    setvbuf(stdout, nil, _IONBF, 0)
    let app = NSApplication.shared
    app.setActivationPolicy(CommandLine.arguments.contains("--accessory") ? .accessory : .regular)
    var windows: [Int: NSWindow] = [:]
    DispatchQueue.global().async {
        // Commands on stdin: "open [minWidth minHeight]", "close <window number>".
        while let line = readLine() {
            let words = line.split(separator: " ").map(String.init)
            DispatchQueue.main.async {
                switch words.first {
                case "open":
                    let w = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 500, height: 400),
                                     styleMask: [.titled, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false)
                    w.isReleasedWhenClosed = false
                    w.title = "tatami e2e"
                    if words.count == 3, let mw = Double(words[1]), let mh = Double(words[2]) { w.minSize = NSSize(width: mw, height: mh) }
                    // A background app's new window opens behind everything: the tests need it in front.
                    app.activate(ignoringOtherApps: true)
                    w.makeKeyAndOrderFront(nil)
                    w.orderFrontRegardless()
                    windows[w.windowNumber] = w
                    print("opened \(w.windowNumber)")
                case "panel":
                    // A small window the app shows without making it key, like the Caps Lock indicator of a password field.
                    let p = NSPanel(contentRect: NSRect(x: 60, y: 60, width: 84, height: 77),
                                    styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
                    p.isReleasedWhenClosed = false
                    p.orderFrontRegardless()
                    windows[p.windowNumber] = p
                    print("opened \(p.windowNumber)")
                case "capped":
                    // A window that resizes, but never beyond a maximum: System Settings is one.
                    let w = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 500, height: 400),
                                     styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
                    w.isReleasedWhenClosed = false
                    w.title = "tatami e2e capped"
                    w.contentMaxSize = NSSize(width: 600, height: 420)
                    app.activate(ignoringOtherApps: true)
                    w.makeKeyAndOrderFront(nil)
                    windows[w.windowNumber] = w
                    print("opened \(w.windowNumber)")
                case "alert":
                    // A system-style prompt: above normal windows ("alert x y", AppKit coordinates).
                    let x = words.count == 3 ? Double(words[1]) ?? 340 : 340, y = words.count == 3 ? Double(words[2]) ?? 340 : 340
                    let p = NSPanel(contentRect: NSRect(x: x, y: y, width: 360, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
                    p.isReleasedWhenClosed = false
                    p.level = .modalPanel
                    p.hidesOnDeactivate = false
                    p.orderFrontRegardless()
                    windows[p.windowNumber] = p
                    print("opened \(p.windowNumber)")
                case "dialog":
                    // A dialog the app opens and makes key, as an Open or Save panel would be ("dialog x y", AppKit coordinates).
                    let x = words.count == 3 ? Double(words[1]) ?? 340 : 340, y = words.count == 3 ? Double(words[2]) ?? 340 : 340
                    let p = NSPanel(contentRect: NSRect(x: x, y: y, width: 360, height: 200),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
                    p.isReleasedWhenClosed = false
                    p.hidesOnDeactivate = false
                    app.activate(ignoringOtherApps: true)
                    p.makeKeyAndOrderFront(nil)
                    windows[p.windowNumber] = p
                    print("opened \(p.windowNumber)")
                case "closeto":
                    // Close one window and make another key at once: macOS choosing the next key window after a close.
                    if words.count == 3, let n = Int(words[1]), let m = Int(words[2]) {
                        windows.removeValue(forKey: n)?.close()
                        windows[m]?.makeKeyAndOrderFront(nil)
                    }
                    print("closed")
                case "select":
                    // The app switches window by itself, as a launcher shortcut or the app switcher would.
                    if let n = words.last.flatMap(Int.init) { windows[n]?.makeKeyAndOrderFront(nil) }
                    print("selected")
                case "front":
                    windows.values.forEach { $0.orderFrontRegardless() }
                    print("front")
                case "key":
                    // Ground truth for focus: what the app itself considers its key window.
                    print("key \(app.isActive ? app.keyWindow?.windowNumber ?? 0 : 0)")
                case "close":
                    if let n = words.last.flatMap(Int.init) { windows.removeValue(forKey: n)?.close() }
                    print("closed")
                default: break
                }
            }
        }
        exit(0)
    }
    app.run()
}

// MARK: - Driver

setvbuf(stdout, nil, _IONBF, 0)
_ = NSApplication.shared  // without it NSScreen misses the menu bar on secondary displays

let binary = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("tatami")
// Gaps are measured between borders: windows sit a border further from the edge and two borders further apart.
let border = 4.0, outer = 10.0 + border, inner = 10.0 + 2 * border
let mouseTests = !CommandLine.arguments.contains("--no-mouse")

// Monitors in Accessibility coordinates. Every scenario runs on the one the cursor was on at the start.
let primaryHeight = NSScreen.screens[0].frame.height
let monitors: [CGRect] = NSScreen.screens.map { s in
    let v = s.visibleFrame
    return CGRect(x: v.minX, y: primaryHeight - v.maxY, width: v.width, height: v.height)
}
let parkX = NSScreen.screens.map(\.frame.maxX).max()! - 3
let cursorAtStart = CGEvent(source: nil)!.location
let area = monitors.first { $0.contains(cursorAtStart) } ?? monitors[0]

// MARK: Session: what one scenario runs against

typealias Helper = (process: Process, input: Pipe, output: Pipe)
func launchHelper(_ extra: [String] = []) -> Helper {
    let p = Process(), input = Pipe(), output = Pipe()
    p.executableURL = Bundle.main.executableURL
    p.arguments = ["--app"] + extra
    p.standardInput = input
    p.standardOutput = output
    try! p.run()
    return (p, input, output)
}

// Helper apps: the main one, a second so that some checks span two apps, and a menu bar app.
var helper: Helper!, other: Helper!, menuBarApp: Helper!
var helperElements: [AXUIElement] = []
var home: URL!, logURL: URL!
var env = ProcessInfo.processInfo.environment
var daemon: Process!
var sessions = 0

func startTatami() -> Process {
    let p = Process()
    p.executableURL = binary
    p.arguments = ["run"]
    p.environment = env
    let log = try! FileHandle(forWritingTo: logURL)
    log.seekToEndOfFile()
    p.standardError = log
    try! p.run()
    for _ in 0..<50 where CFMessagePortCreateRemote(nil, env["TATAMI_PORT"]! as CFString) == nil { usleep(100_000) }
    return p
}

/// Fresh helper apps and a fresh isolated tatami (own port, config and state) that manages only those apps,
/// so every scenario starts from nothing and can run alone.
func begin() {
    sessions += 1
    home = FileManager.default.temporaryDirectory.appendingPathComponent("tatami-e2e-\(getpid())-\(sessions)")
    try! FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try! "gap.inner = 10\ngap.outer = 10\nborder.width = \(Int(border))\nlayout 6 = accordion\nfocus.follows_mouse = \(mouseTests)\n"
        .write(to: home.appendingPathComponent("config"), atomically: true, encoding: .utf8)
    helper = launchHelper()
    other = launchHelper()
    menuBarApp = launchHelper(["--accessory"])
    helperElements = [helper, other, menuBarApp].map { AXUIElementCreateApplication($0.process.processIdentifier) }
    env["TATAMI_PORT"] = "dev.tatami.e2e.\(getpid()).\(sessions)"
    env["TATAMI_HOME"] = home.path
    env["TATAMI_ONLY_PID"] = [helper, other, menuBarApp].map { "\($0.process.processIdentifier)" }.joined(separator: ",")
    env["TATAMI_DEBUG"] = "1"
    logURL = home.appendingPathComponent("log")
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    // tatami starts focused on the Monitor the cursor is on: that is where the scenario runs.
    CGWarpMouseCursorPosition(CGPoint(x: area.midX, y: area.midY))
    daemon = startTatami()
    guard CFMessagePortCreateRemote(nil, env["TATAMI_PORT"]! as CFString) != nil else {
        print("tatami did not start:\n" + ((try? String(contentsOf: logURL, encoding: .utf8)) ?? ""))
        end(); exit(1)
    }
    usleep(1_000_000)  // let tatami finish its first-start scan
}

func end() {
    if daemon?.isRunning == true { daemon.terminate(); daemon.waitUntilExit() }  // also frees its hotkeys for the next one
    for h in [helper, other, menuBarApp] where h?.process.isRunning == true { h!.process.terminate() }
    if let home { try? FileManager.default.removeItem(at: home) }
    CGWarpMouseCursorPosition(cursorAtStart)
}
signal(SIGINT) { _ in end(); exit(1) }

func ask(_ command: String, _ app: Helper? = nil) -> String {
    let app = app ?? helper!
    app.input.fileHandleForWriting.write(Data((command + "\n").utf8))
    var line = ""
    while !line.hasSuffix("\n") {
        let data = app.output.fileHandleForReading.availableData
        if data.isEmpty { break }
        line += String(data: data, encoding: .utf8) ?? ""
    }
    return line.trimmingCharacters(in: .whitespacesAndNewlines)
}
/// Opens a window in a helper app and returns its id. `command` may be "open 1100 300" (minimum size), "panel", "dialog".
func open(_ command: String = "open", in app: Helper? = nil) -> CGWindowID {
    let id = CGWindowID(ask(command, app).split(separator: " ").last!)!
    usleep(900_000)  // tatami rescans up to 0.3 s after the window appears, then places it
    return id
}

@discardableResult func tatami(_ args: String...) -> String {
    let p = Process(), out = Pipe()
    p.executableURL = binary
    p.arguments = args
    p.environment = env
    p.standardOutput = out
    p.standardError = out
    try! p.run()
    p.waitUntilExit()
    usleep(350_000)
    return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

// MARK: Observing

func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func windowID(_ e: AXUIElement) -> CGWindowID {
    var id: CGWindowID = 0
    _ = _AXUIElementGetWindow(e, &id)
    return id
}
func frame(_ id: CGWindowID) -> CGRect {
    for w in helperElements.flatMap({ (attribute($0, kAXWindowsAttribute) as? [AXUIElement]) ?? [] }) where windowID(w) == id {
        var p = CGPoint.zero, s = CGSize.zero
        if let pv = attribute(w, kAXPositionAttribute), let sv = attribute(w, kAXSizeAttribute) {
            AXValueGetValue(pv as! AXValue, .cgPoint, &p)
            AXValueGetValue(sv as! AXValue, .cgSize, &s)
            return CGRect(origin: p, size: s)
        }
    }
    return .null
}
/// The helper's key window while it is the active app, else 0.
func focused() -> CGWindowID { CGWindowID(ask("key").split(separator: " ").last ?? "0") ?? 0 }
func cursor() -> CGPoint { CGEvent(source: nil)!.location }
func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 3) -> Bool { abs(a - b) <= tolerance }
func show(_ r: CGRect) -> String { "(\(Int(r.minX)), \(Int(r.minY)), \(Int(r.width))x\(Int(r.height)))" }
/// The line of `tatami state` for one Desk ("" when the Desk does not exist).
func deskLine(_ n: String) -> String { tatami("state").components(separatedBy: "\n").first { $0.hasPrefix("desk \(n) ") } ?? "" }
/// The number of the focused Desk.
func focusedDesk() -> String {
    tatami("state").split(separator: "\n").first { $0.contains("focused") }?.split(separator: " ").dropFirst().first.map(String.init) ?? "1"
}
func isFloating(_ id: CGWindowID) -> Bool {
    tatami("state").components(separatedBy: "\n").contains { $0.contains("floating") && $0.components(separatedBy: "floating").last!.contains(String(id)) }
}
/// Front to back position among all on-screen windows.
func depth(_ id: CGWindowID) -> Int {
    let all = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[CFString: Any]] ?? []).compactMap { $0[kCGWindowNumber] as? CGWindowID }
    return all.firstIndex(of: id) ?? .max
}

var failures = 0
/// Passes as soon as `condition` holds, fails if it still does not after 3 s.
func check(_ name: String, _ detail: @autoclosure () -> String = "", _ condition: () -> Bool) {
    for _ in 0..<30 {
        if condition() { print("  ok    \(name)"); return }
        usleep(100_000)
    }
    failures += 1
    print("  FAIL  \(name)  \(detail())")
}

/// Two windows side by side, in either order, filling the Monitor with the configured gaps.
func checkPair(_ name: String, _ one: CGWindowID, _ other: CGWindowID) {
    check(name, "\(show(frame(one))) and \(show(frame(other))) area \(show(area))") {
        let both = [frame(one), frame(other)].sorted { $0.minX < $1.minX }
        let l = both[0], r = both[1]
        return near(l.minX, area.minX + outer) && near(r.maxX, area.maxX - outer) && near(r.minX - l.maxX, inner)
            && near(l.minY, area.minY + outer) && near(l.height, area.height - 2 * outer) && near(r.height, l.height)
    }
}

// MARK: Mouse and keys

func mouse(_ type: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)!.post(tap: .cghidEventTap)
}
func hover(_ p: CGPoint) {
    for dx in [-6.0, -3, 0] { mouse(.mouseMoved, CGPoint(x: p.x + dx, y: p.y)); usleep(60_000) }
    usleep(300_000)
}
func drag(from a: CGPoint, to b: CGPoint) {
    mouse(.mouseMoved, a); usleep(200_000)
    mouse(.leftMouseDown, a); usleep(200_000)
    for i in 1...20 {
        let t = Double(i) / 20
        mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        usleep(20_000)
    }
    usleep(200_000)
    mouse(.leftMouseUp, b)
    usleep(600_000)
}
func press(_ key: CGKeyCode, _ flags: CGEventFlags) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)!
        event.flags = flags
        event.post(tap: .cghidEventTap)
        usleep(60_000)
    }
    usleep(400_000)
}

// MARK: - Scenarios

// Each one starts with nothing open and opens what it needs, so any of them runs alone.
var scenarios: [(name: String, needsMouse: Bool, run: () -> Void)] = []
func scenario(_ name: String, needsMouse: Bool = false, _ run: @escaping () -> Void) { scenarios.append((name, needsMouse, run)) }

scenario("tiling") {
    let a = open()
    check("the window opens on the Monitor the cursor is on", "\(show(frame(a))) not on \(show(area))") {
        area.contains(CGPoint(x: frame(a).midX, y: frame(a).midY))
    }
    check("one window fills the Monitor inside the outer gap", show(frame(a))) {
        let f = frame(a)
        return near(f.minX, area.minX + outer) && near(f.minY, area.minY + outer)
            && near(f.width, area.width - 2 * outer) && near(f.height, area.height - 2 * outer)
    }
    let b = open()
    checkPair("second window takes its half", a, b)
    check("on the right", "a \(show(frame(a))) b \(show(frame(b)))") { frame(b).minX > frame(a).minX }
    check("new window has focus", "focused \(focused())") { focused() == b }
}

scenario("focus") {
    let a = open(), b = open()
    tatami("focus", "left")
    check("focus left moves to the left window", "focused \(focused())") { focused() == a }
    check("cursor warped into it") { frame(a).contains(cursor()) }
    _ = ask("select \(b)")  // from outside: the app switches window by itself
    check("a window activated from outside gets the cursor", "cursor \(cursor()) window \(show(frame(b)))") { frame(b).contains(cursor()) }
    tatami("focus", "left")
    check("back on the left window", "focused \(focused())") { focused() == a }
}

scenario("hover", needsMouse: true) {
    let a = open(), b = open()
    tatami("focus", "left")
    _ = ask("front")  // synthetic mouse input lands on whatever is on top: make sure that is the test windows
    hover(CGPoint(x: frame(b).midX, y: frame(b).midY))
    check("hovering the right window focuses it (same app, no raise)", "focused \(focused())") { focused() == b }
    // Focus from outside while the mouse moves.
    let held = CGPoint(x: frame(a).midX + 50, y: frame(a).midY + 50)
    hover(held)
    mouse(.mouseMoved, CGPoint(x: held.x + 1, y: held.y))
    _ = ask("select \(b)")
    usleep(900_000)
    check("focus from outside while the mouse moves leaves the cursor alone", "cursor \(cursor()), left at \(held)") {
        abs(cursor().x - held.x) < 3 && abs(cursor().y - held.y) < 3
    }
}

scenario("drag", needsMouse: true) {
    let a = open(), b = open()
    _ = ask("front")
    var before = (frame(a), frame(b))
    drag(from: CGPoint(x: before.0.maxX - 1, y: before.0.midY), to: CGPoint(x: before.0.maxX + 149, y: before.0.midY))
    check("dragging the left window's right edge moves the split", "left \(show(frame(a))) right \(show(frame(b))), was \(show(before.0)) \(show(before.1))") {
        near(frame(a).width, before.0.width + 150, 8) && near(frame(b).minX - frame(a).maxX, inner) && near(frame(b).maxX, before.1.maxX)
    }
    before = (frame(a), frame(b))
    drag(from: CGPoint(x: before.1.minX + 1, y: before.1.midY), to: CGPoint(x: before.1.minX - 149, y: before.1.midY))
    check("dragging the right window's left edge moves it back", "left \(show(frame(a))) right \(show(frame(b))), was \(show(before.0)) \(show(before.1))") {
        near(frame(b).width, before.1.width + 150, 8) && near(frame(b).minX - frame(a).maxX, inner) && near(frame(a).minX, before.0.minX)
    }
    before = (frame(a), frame(b))
    drag(from: CGPoint(x: before.0.maxX - 1, y: before.0.midY), to: CGPoint(x: before.0.maxX - 1, y: before.0.midY + 80))
    check("a click on the edge without resizing changes nothing", "left \(show(frame(a))) right \(show(frame(b)))") {
        near(frame(a).width, before.0.width) && near(frame(b).width, before.1.width)
    }
    before = (frame(a), frame(b))
    drag(from: CGPoint(x: before.0.midX, y: before.0.minY + 14), to: CGPoint(x: before.1.midX, y: before.1.midY))
    check("dropping the left window on the right one swaps them", "a \(show(frame(a))) b \(show(frame(b)))") {
        near(frame(a).minX, before.1.minX) && near(frame(b).minX, before.0.minX) && near(frame(a).width, before.1.width)
    }
    drag(from: CGPoint(x: frame(a).midX, y: frame(a).minY + 14), to: CGPoint(x: frame(a).midX + 60, y: frame(a).minY + 60))
    check("a window dropped on itself snaps back", "a \(show(frame(a)))") { near(frame(a).minX, before.1.minX) && near(frame(a).minY, before.1.minY) }
}

scenario("accordion") {
    let a = open(), b = open()
    press(43 /* comma */, .maskAlternate)
    check("the alt+comma hotkey stacks both windows nearly full-size, one peeking 32 px", "a \(show(frame(a))) b \(show(frame(b)))") {
        near(frame(a).width, area.width - 2 * outer - 32) && near(frame(b).width, frame(a).width)
            && near(abs(frame(a).minX - frame(b).minX), 32) && near(min(frame(a).minX, frame(b).minX), area.minX + outer)
    }
    let (first, second) = frame(a).minX < frame(b).minX ? (a, b) : (b, a)
    tatami("focus", "left")
    check("focus left brings the first window to the front", "focused \(focused()) depths \(depth(first)) \(depth(second))") {
        focused() == first && depth(first) < depth(second)
    }
    tatami("focus", "right")
    check("focus right brings the second one to the front", "focused \(focused()) depths \(depth(first)) \(depth(second))") {
        focused() == second && depth(second) < depth(first)
    }
    tatami("move", "left")
    check("move left reorders the stack", "a \(show(frame(a))) b \(show(frame(b)))") {
        frame(second).minX < frame(first).minX && focused() == second
    }
    press(43, .maskAlternate)
    checkPair("alt+comma again restores the tiling", a, b)
    tatami("desk", "6")
    check("a Desk with `layout N = accordion` starts as Accordion", tatami("state")) { deskLine("6").contains("accordion") }
}

// Found in use: with three Windows, clicking the first and then the last buried the middle one: macOS brings
// only the clicked window forward. Going outwards from the front one, each Window must sit above the next,
// or its edge does not show.
scenario("accordion-stack", needsMouse: true) {
    let a = open(), x = open(in: other), b = open()
    tatami("layout", "toggle")
    let order = [a, x, b].sorted { frame($0).minX < frame($1).minX }
    let (first, middle, last) = (order[0], order[1], order[2])
    func depths() -> String { "depths first \(depth(first)) middle \(depth(middle)) last \(depth(last))" }
    func key(_ id: CGWindowID) -> Bool { ask("key", id == x ? other : nil) == "key \(id)" }
    func click(_ p: CGPoint) {
        mouse(.mouseMoved, p); usleep(150_000)
        mouse(.leftMouseDown, p); usleep(80_000); mouse(.leftMouseUp, p)
        usleep(900_000)
    }
    // Only the first window reaches the left edge of the stack, only the last one the right edge.
    let edgeOfFirst = CGPoint(x: frame(first).minX + 10, y: frame(first).midY)
    let edgeOfLast = CGPoint(x: frame(last).maxX - 10, y: frame(last).midY)
    check("three windows stack with their edges 32 px apart", order.map { show(frame($0)) }.joined(separator: " ")) {
        near(frame(middle).minX - frame(first).minX, 32) && near(frame(last).minX - frame(middle).minX, 32)
    }
    click(edgeOfLast)
    check("with the last one in front, the middle one is above the first", depths()) {
        depth(last) < depth(middle) && depth(middle) < depth(first)
    }
    click(edgeOfFirst)
    check("clicking the first one keeps the middle one above the last", depths()) {
        depth(first) < depth(middle) && depth(middle) < depth(last)
    }
    check("and the first one has the keyboard", "") { key(first) }
    click(edgeOfLast)
    check("clicking the last one again puts the middle one above the first", depths()) {
        depth(last) < depth(middle) && depth(middle) < depth(first)
    }
    check("and the last one has the keyboard", "") { key(last) }
    let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    print("  (order repaired \(log.components(separatedBy: "restack raises").count - 1) times, \(log.components(separatedBy: "by activating").count - 1) of them by activating apps)")
    click(CGPoint(x: frame(middle).minX + 10, y: frame(middle).midY))  // the middle one's edge, showing next to the first one's
    check("the middle one's edge can be clicked: it comes forward", depths()) {
        key(middle) && depth(middle) < depth(first) && depth(middle) < depth(last)
    }
}

/// "x y" for the helper's dialog and alert commands: a 360 x 200 window in the middle of the test Monitor.
func middleOfArea() -> String { "\(Int(area.midX - 180)) \(Int(primaryHeight - (area.midY + 100)))" }

// Found in use: a dialog (a Floating Window) ended up behind the Accordion's windows and could not be reached.
scenario("float-above") {
    let a = open(), b = open()
    tatami("layout", "toggle")
    let dialog = open("dialog " + middleOfArea())
    usleep(600_000)
    check("the dialog is a Floating Window, in front", "depths dialog \(depth(dialog)) a \(depth(a)) b \(depth(b))") {
        isFloating(dialog) && depth(dialog) < depth(a) && depth(dialog) < depth(b)
    }
    for (name, w) in [("one", a), ("the other", b)] {
        _ = ask("select \(w)")  // a Tiled Window comes forward, as when it is clicked
        usleep(1_200_000)
        check("\(name) Tiled Window takes the keyboard", "focused \(focused())") { focused() == w }
        check("and the Floating Window is above both Tiled ones again", "depths dialog \(depth(dialog)) a \(depth(a)) b \(depth(b))") {
            depth(dialog) < depth(a) && depth(dialog) < depth(b)
        }
    }
}

// Found in use: a system prompt (not a window tatami manages, and above normal windows) could not keep focus:
// the mouse over it counted as being on the Window underneath.
scenario("prompt", needsMouse: true) {
    let a = open(), b = open()
    check("the second window has the keyboard", "focused \(focused())") { focused() == b }
    let outsider = launchHelper()  // not one of the apps this tatami manages
    defer { outsider.process.terminate() }
    usleep(500_000)
    // Over the first window, which does not have the keyboard.
    let alert = CGWindowID(ask("alert \(Int(frame(a).midX - 180)) \(Int(primaryHeight - (frame(a).midY + 100)))", outsider).split(separator: " ").last!)!
    usleep(800_000)
    check("the prompt is above the first window", "depths prompt \(depth(alert)) a \(depth(a))") { depth(alert) < depth(a) }
    _ = ask("front")
    hover(CGPoint(x: frame(b).midX, y: frame(b).midY))
    hover(CGPoint(x: frame(a).midX + 20, y: frame(a).midY + 10))
    hover(CGPoint(x: frame(a).midX - 20, y: frame(a).midY - 10))
    usleep(600_000)
    check("the mouse over the prompt does not focus the Window underneath", "focused \(focused()), underneath \(a)") { focused() == b }
    hover(CGPoint(x: frame(a).midX, y: frame(a).minY + 40))  // on the first window itself, beside the prompt
    check("the mouse on that Window itself does", "focused \(focused())") { focused() == a }
}

// Found in use: System Settings never gets wider than about 740 px. Tiled, it left most of its tile empty,
// and in an Accordion the windows behind showed through.
scenario("capped") {
    let a = open()
    let capped = open("capped")
    usleep(1_500_000)
    check("a window that will not grow to its tile becomes a Floating Window", tatami("state")) { isFloating(capped) }
    check("and the Tiled Window has the Monitor to itself", show(frame(a))) { near(frame(a).width, area.width - 2 * outer) }
    check("it kept a size it accepts", show(frame(capped))) { frame(capped).width <= 601 && frame(capped).minX < parkX }
}

// Found in use: hovering the edge of a Window behind gave it the keyboard while it stayed behind, and the Window
// in front only got focus back once the mouse had left the other one's whole frame.
scenario("accordion-hover", needsMouse: true) {
    let a = open(), b = open()
    tatami("layout", "toggle")
    _ = ask("front")
    _ = ask("select \(b)")
    check("the second window is in front and focused", "focused \(focused()) depths \(depth(a)) \(depth(b))") { focused() == b && depth(b) < depth(a) }
    let edgeOfA = CGPoint(x: (frame(a).minX + frame(b).minX) / 2, y: frame(a).midY)  // the strip of a that peeks out
    hover(CGPoint(x: frame(b).midX, y: frame(b).midY))
    hover(edgeOfA)
    usleep(500_000)
    check("hovering the edge of the window behind does not take focus", "focused \(focused()), front \(b)") { focused() == b }
    check("nor bring it forward", "depths \(depth(a)) \(depth(b))") { depth(b) < depth(a) }
    mouse(.leftMouseDown, edgeOfA); usleep(80_000); mouse(.leftMouseUp, edgeOfA)
    check("a click on that edge brings the window forward and focuses it", "focused \(focused()) depths \(depth(a)) \(depth(b))") {
        focused() == a && depth(a) < depth(b)
    }
    hover(CGPoint(x: frame(b).maxX - 10, y: frame(b).midY))  // now b peeks out, on the other side
    usleep(500_000)
    check("and now the other one's edge does not take focus either", "focused \(focused())") { focused() == a }
}

// Found by accident in a test: with focus on an empty Monitor, tatami itself is the active app.
scenario("hover-from-empty", needsMouse: true) {
    guard monitors.count > 1 else { return print("  (skipped: needs two Monitors)") }
    let a = open()
    _ = ask("front")
    tatami("focus", "right")
    if focused() == a { tatami("focus", "left") }
    check("focus moved to the empty Monitor", "focused \(focused())") { focused() == 0 }
    hover(CGPoint(x: frame(a).midX, y: frame(a).midY))
    check("hovering a Window from an empty Monitor focuses it", "focused \(focused())") { focused() == a }
}

scenario("desks") {
    let a = open(), b = open()
    let before = (frame(a), frame(b)), homeDesk = focusedDesk()
    tatami("desk", "9")
    check("switching Desk parks both windows", "a \(show(frame(a))) b \(show(frame(b)))") { frame(a).minX >= parkX && frame(b).minX >= parkX }
    tatami("desk", "last")
    check("switching back returns them exactly", "a \(show(frame(a))) b \(show(frame(b)))") {
        near(frame(a).minX, before.0.minX) && near(frame(b).minX, before.1.minX) && near(frame(a).width, before.0.width)
    }
    tatami("send", "8")
    check("send moves the focused window and follows it", tatami("state")) { deskLine("8").contains("active focused") }
    check("the other window is parked", "a \(show(frame(a))) b \(show(frame(b)))") { (frame(a).minX >= parkX) != (frame(b).minX >= parkX) }
    tatami("send", homeDesk)
    check("and back: both windows on the first Desk again", tatami("state")) {
        frame(a).minX < parkX && frame(b).minX < parkX && deskLine("8").isEmpty
    }
}

scenario("minimum") {
    let a = open(), b = open(), big = open("open 1100 300")
    check("a window with a wide minimum keeps it", show(frame(big))) { frame(big).width >= 1100 }
    check("and no tiled window overlaps another", "a \(show(frame(a))) b \(show(frame(b))) big \(show(frame(big)))") {
        let f = [frame(a), frame(b), frame(big)].map { $0.insetBy(dx: 2, dy: 2) }
        return !f[0].intersects(f[1]) && !f[0].intersects(f[2]) && !f[1].intersects(f[2])
    }
}

scenario("floating") {
    let a = open(), b = open(), c = open()
    check("the new window is focused", "focused \(focused())") { focused() == c }
    tatami("float", "toggle")
    check("float toggle centres the window on the Monitor", show(frame(c))) {
        near(frame(c).midX, area.midX, 6) && near(frame(c).midY, area.midY, 6)
    }
    check("the other two fill the Monitor again", "a \(show(frame(a))) b \(show(frame(b)))") {
        near(min(frame(a).minX, frame(b).minX), area.minX + outer) && near(max(frame(a).maxX, frame(b).maxX), area.maxX - outer)
    }
    tatami("focus", "left")
    check("keyboard focus leaves the Floating Window", "focused \(focused())") { focused() != c }
    tatami("focus", "right")
    check("and comes back to it", "focused \(focused())") { focused() == c }
    _ = ask("close \(c)")
    check("after closing, focus stays on the Desk", "focused \(focused())") { [a, b].contains(focused()) }
    _ = ask("close \(b)")
    check("the last window fills the Monitor again", show(frame(a))) { near(frame(a).width, area.width - 2 * outer) }
}

scenario("menubar") {
    let a = open()
    let width = frame(a).width
    let settings = open(in: menuBarApp)
    usleep(600_000)
    check("a menu bar app's window is managed as a Floating Window", tatami("state")) { isFloating(settings) }
    check("and the tiling is left alone", show(frame(a))) { near(frame(a).width, width) }
    tatami("desk", "9")
    check("it hides with its Desk", show(frame(settings))) { frame(settings).minX >= parkX }
    tatami("desk", "last")
    check("and comes back", show(frame(settings))) { frame(settings).minX < parkX }
    menuBarApp.process.terminate()
    check("when it quits, its window is gone from the Desk", tatami("state")) { !tatami("state").contains(String(settings)) }
}

scenario("two-apps") {
    let a = open(), x = open(in: other)
    checkPair("a window of a second app tiles next to the first", a, x)
    if mouseTests {
        func guardLines() -> [String] {
            ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").components(separatedBy: "\n").filter { $0.contains("cursor left alone") }
        }
        let guardLinesBefore = guardLines().count
        _ = ask("front"); _ = ask("front", other)
        // Sweep back and forth across both windows faster than macOS confirms each focus change.
        let ends = [CGPoint(x: frame(a).midX, y: frame(a).midY), CGPoint(x: frame(x).midX, y: frame(x).midY)]
        for i in 0..<9 {
            mouse(.mouseMoved, ends[i % 2]); usleep(45_000)
            mouse(.mouseMoved, CGPoint(x: ends[i % 2].x + 3, y: ends[i % 2].y)); usleep(45_000)
        }
        let rest = CGPoint(x: ends[0].x + 40, y: ends[0].y + 40)  // off-centre, so a warp to a centre shows
        mouse(.mouseMoved, rest)
        usleep(1_200_000)
        check("after a fast sweep the cursor stays where the mouse left it", "cursor \(cursor()), left at \(rest)") {
            abs(cursor().x - rest.x) < 2 && abs(cursor().y - rest.y) < 2
        }
        check("and focus is on the window under it", "focused \(focused())") { focused() == a }
        // macOS confirms each hover focus late. A confirmation that arrives after tatami moved on is not a focus
        // change from outside, and must never count as a reason to move the cursor.
        let echoes = Array(guardLines().dropFirst(guardLinesBefore))
        check("no late confirmation of a hover is taken for focus from outside", echoes.joined(separator: "\n")) { echoes.isEmpty }
        hover(CGPoint(x: frame(x).midX, y: frame(x).midY))
    }
    tatami("layout", "toggle")
    let (lower, upper) = frame(a).minX < frame(x).minX ? (a, x) : (x, a)
    tatami("focus", "left")
    check("Accordion: focus left raises the other app's window", "depths \(depth(lower)) \(depth(upper))") { depth(lower) < depth(upper) }
    tatami("focus", "right")
    check("Accordion: focus right raises it back", "depths \(depth(lower)) \(depth(upper))") { depth(upper) < depth(lower) }
    tatami("focus", "left")
    check("and again the other way", "depths \(depth(lower)) \(depth(upper))") { depth(lower) < depth(upper) }
    tatami("layout", "toggle")
    let a2 = open()
    if mouseTests {
        // Coming from another app onto a window that is not its app's key window.
        _ = ask("front"); _ = ask("front", other)
        hover(CGPoint(x: frame(a).midX, y: frame(a).midY))
        check("hover: first app's window A is key", "focused \(focused())") { focused() == a }
        hover(CGPoint(x: frame(x).midX, y: frame(x).midY))
        check("hover: the other app takes focus", ask("key", other)) { ask("key", other) == "key \(x)" }
        let target = CGPoint(x: frame(a2).midX + 30, y: frame(a2).midY + 30)
        hover(target)
        usleep(800_000)
        check("hover back onto the first app's other window focuses that one, not A", "focused \(focused())") { focused() == a2 }
        check("and the cursor is not pulled anywhere", "cursor \(cursor()), left at \(target)") {
            abs(cursor().x - target.x) < 2 && abs(cursor().y - target.y) < 2
        }
    }
    other.process.terminate()
    check("when that app quits, the remaining windows fill the Monitor", "\(show(frame(a))) \(show(frame(a2)))") {
        let f = [frame(a), frame(a2)]
        return near(f[0].union(f[1]).width, area.width - 2 * outer) && near(f[0].union(f[1]).height, area.height - 2 * outer)
            && !f[0].insetBy(dx: 2, dy: 2).intersects(f[1].insetBy(dx: 2, dy: 2))
    }
}

// Found in use: the Caps Lock indicator of a password prompt was given focus, which took it from the password
// field, which closed the indicator, which gave focus back, several times a second.
scenario("panel") {
    let a = open()
    check("the window has focus", "focused \(focused())") { focused() == a }
    let panel = open("panel")
    usleep(600_000)
    check("a panel its app shows without focusing it is a Floating Window", tatami("state")) { isFloating(panel) }
    check("but tatami does not give it focus", "focused \(focused()), was \(a), panel \(panel)") { focused() == a }
    _ = ask("close \(panel)")
    usleep(600_000)
    check("and closing it leaves focus where it was", "focused \(focused()), was \(a)") { focused() == a }
}

scenario("dialogs") {
    let a = open(), b = open()
    tatami("focus", "left")
    let before = (frame(a), frame(b))
    let dialog = open("dialog")  // the app makes it key itself, as an Open or Save panel would be
    usleep(600_000)
    check("a dialog is a Floating Window", tatami("state")) { isFloating(dialog) }
    check("it keeps the size its app gave it", show(frame(dialog))) { near(frame(dialog).width, 360) && frame(dialog).minX < parkX }
    check("the tiling is left alone", "\(show(frame(a))) \(show(frame(b)))") {
        near(frame(a).minX, before.0.minX) && near(frame(a).width, before.0.width) && near(frame(b).minX, before.1.minX) && near(frame(b).width, before.1.width)
    }
    check("it has the focus its app gave it", "focused \(focused()), dialog \(dialog)") { focused() == dialog }
    tatami("desk", "9")
    check("it hides with its Desk", show(frame(dialog))) { frame(dialog).minX >= parkX }
    tatami("desk", "last")
    check("and comes back with it", show(frame(dialog))) { frame(dialog).minX < parkX }
    _ = ask("close \(dialog)")
    check("closing it returns focus to the Window that had it", "focused \(focused()), was \(a)") { focused() == a }
    check("and it is gone from the Desk", tatami("state")) { !tatami("state").contains(String(dialog)) }
}

scenario("follow") {
    let a = open(), b = open()
    let homeDesk = focusedDesk()
    tatami("send", "8")  // b has focus: it goes to Desk 8, and tatami with it
    tatami("desk", homeDesk)
    check("a Window sent to another Desk is hidden after switching back", "a \(show(frame(a))) b \(show(frame(b)))") {
        frame(b).minX >= parkX && frame(a).minX < parkX
    }
    _ = ask("select \(b)")  // as the app switcher or the Dock would
    check("activating a Window on a hidden Desk switches to that Desk", tatami("state")) {
        deskLine("8").contains("active focused") && frame(b).minX < parkX && frame(a).minX >= parkX
    }
    let extra = open()
    check("a new Window opens on that Desk", tatami("state")) { deskLine("8").contains(String(extra)) }
    _ = ask("closeto \(extra) \(a)")  // macOS picks a window on the hidden Desk as the next key window
    usleep(1_200_000)
    check("closing a Window never jumps Desk", tatami("state")) { deskLine("8").contains("active focused") && frame(a).minX >= parkX }
    check("focus goes to the Window left on the Desk", "focused \(focused()), expected \(b)") { focused() == b }
}

// The same for an app that quits: macOS then activates another app, whose window may be on a hidden Desk.
scenario("quit") {
    let a = open()
    tatami("desk", "8")
    let x = open(in: other)
    check("the other app's window opens on the new Desk, the first one stays hidden", tatami("state")) {
        deskLine("8").contains(String(x)) && frame(a).minX >= parkX
    }
    other.process.terminate()
    usleep(1_500_000)
    let activated = ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").contains("event focused(\(a))")
    print("  (macOS \(activated ? "gave" : "did not give") focus to the window on the hidden Desk)")
    check("an app quitting never jumps Desk", tatami("state")) { deskLine("8").contains("active focused") && frame(a).minX >= parkX }
}

scenario("restart") {
    let a = open(), b = open(), c = open()
    tatami("split", "toggle")
    tatami("float", "toggle")  // c floats; a and b stay tiled
    tatami("focus", "left")
    let arranged = [a, b, c].map(frame)
    let stateBefore = tatami("state")
    tatami("desk", "7")
    check("windows parked before stop") { frame(a).minX >= parkX && frame(c).minX >= parkX }
    usleep(1_300_000)  // state is saved within a second of a change
    tatami("stop")
    check("tatami exits") { !daemon.isRunning }
    check("every window is back on-screen", "a \(show(frame(a))) c \(show(frame(c)))") { frame(a).minX < parkX && frame(c).minX < parkX }
    daemon = startTatami()
    check("after a restart the same Desk is active and the windows are hidden again", tatami("state")) {
        frame(a).minX >= parkX && frame(b).minX >= parkX && frame(c).minX >= parkX
    }
    tatami("desk", "last")
    check("their Desk comes back exactly as arranged", "\([a, b, c].map { show(frame($0)) }) was \(arranged.map(show))") {
        zip([a, b, c].map(frame), arranged).allSatisfy { near($0.minX, $1.minX) && near($0.minY, $1.minY) && near($0.width, $1.width) && near($0.height, $1.height) }
    }
    check("tiled and floating as before", "\(tatami("state"))\nwas\n\(stateBefore)") { isFloating(c) }
    tatami("stop")
    check("tatami exits again") { !daemon.isRunning }
}

// MARK: - Run

let names = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
if CommandLine.arguments.contains("--list") { scenarios.forEach { print($0.name) }; exit(0) }
if let unknown = names.first(where: { name in !scenarios.contains { $0.name == name } }) {
    print("no scenario \"\(unknown)\"; there are: \(scenarios.map(\.name).joined(separator: " "))")
    exit(64)
}
guard AXIsProcessTrusted() else { print("not trusted for Accessibility"); exit(2) }
guard CFMessagePortCreateRemote(nil, "dev.tatami.cli" as CFString) == nil else {
    print("your tatami is running: `tatami stop` first (it would fight over the test windows)")
    exit(2)
}

print("tatami e2e on Monitor \(show(area))\(mouseTests ? "" : ", mouse scenarios skipped")")
for s in scenarios where names.isEmpty || names.contains(s.name) {
    if s.needsMouse, !mouseTests { print("\(s.name)  (skipped: needs the mouse)"); continue }
    print(s.name)
    let failedBefore = failures
    begin()
    s.run()
    let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    end()
    if failures > failedBefore, !log.isEmpty { print("--- tatami log of \(s.name)\n" + log) }
}
print(failures == 0 ? "PASS" : "FAILED: \(failures)")
exit(failures == 0 ? 0 : 1)
