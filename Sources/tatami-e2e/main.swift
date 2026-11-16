// End-to-end regression tests: a real tatami, real windows, real (synthetic) mouse input.
//
//   swift build && swift run tatami-e2e              everything
//   swift build && swift run tatami-e2e --no-mouse   skip hovering and dragging
//
// macOS has one window server and one cursor per login session, so this cannot run headless: the test
// windows are real and the mouse tests move the real cursor. --no-mouse also turns focus-follows-mouse
// off in the test tatami, so you can keep using the mouse while it runs (it still takes keyboard focus).
//
// Starts a helper app with test windows and an isolated tatami that manages only that app
// (own port, config and state), then checks what actually happens on screen. Takes about 30 s,
// moves the cursor, and puts the test windows on the leftmost Monitor. Your own tatami must be stopped.
// Needs Accessibility permission for whatever launches it.
import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow") func _AXUIElementGetWindow(_ e: AXUIElement, _ id: inout CGWindowID) -> AXError

// MARK: - Helper app (this binary with --app): opens and closes windows on request

if CommandLine.arguments.contains("--app") {
    setvbuf(stdout, nil, _IONBF, 0)
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
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

guard AXIsProcessTrusted() else { print("not trusted for Accessibility"); exit(2) }
guard CFMessagePortCreateRemote(nil, "dev.tatami.cli" as CFString) == nil else {
    print("your tatami is running: `tatami stop` first (it would fight over the test windows)")
    exit(2)
}

let binary = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("tatami")
let home = FileManager.default.temporaryDirectory.appendingPathComponent("tatami-e2e-\(getpid())")
try! FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
// Gaps are measured between borders: windows sit a border further from the edge and two borders further apart.
let border = 4.0, outer = 10.0 + border, inner = 10.0 + 2 * border
let mouseTests = !CommandLine.arguments.contains("--no-mouse")
try! "gap.inner = 10\ngap.outer = 10\nborder.width = \(Int(border))\nlayout 6 = accordion\nfocus.follows_mouse = \(mouseTests)\n".write(to: home.appendingPathComponent("config"), atomically: true, encoding: .utf8)

// Monitors in Accessibility coordinates. The tests run on whichever one the first window lands on.
let primaryHeight = NSScreen.screens[0].frame.height
let monitors: [CGRect] = NSScreen.screens.map { s in
    let v = s.visibleFrame
    return CGRect(x: v.minX, y: primaryHeight - v.maxY, width: v.width, height: v.height)
}
var area = monitors[0]
let parkX = NSScreen.screens.map(\.frame.maxX).max()! - 3
let cursorAtStart = CGEvent(source: nil)!.location

// Helper app.
let helper = Process()
let toHelper = Pipe(), fromHelper = Pipe()
helper.executableURL = Bundle.main.executableURL
helper.arguments = ["--app"]
helper.standardInput = toHelper
helper.standardOutput = fromHelper
try! helper.run()

func ask(_ command: String) -> String {
    toHelper.fileHandleForWriting.write(Data((command + "\n").utf8))
    var line = ""
    while !line.hasSuffix("\n") {
        let data = fromHelper.fileHandleForReading.availableData
        if data.isEmpty { break }
        line += String(data: data, encoding: .utf8) ?? ""
    }
    return line.trimmingCharacters(in: .whitespacesAndNewlines)
}
func open(_ minimum: String = "") -> CGWindowID {
    let id = CGWindowID(ask("open \(minimum)").split(separator: " ").last!)!
    usleep(900_000)  // tatami rescans up to 0.3 s after the window appears, then places it
    return id
}

// Isolated tatami.
var env = ProcessInfo.processInfo.environment
env["TATAMI_PORT"] = "dev.tatami.e2e.\(getpid())"
env["TATAMI_HOME"] = home.path
env["TATAMI_ONLY_PID"] = String(helper.processIdentifier)
env["TATAMI_DEBUG"] = "1"
let daemon = Process()
daemon.executableURL = binary
daemon.arguments = ["run"]
daemon.environment = env
let logURL = home.appendingPathComponent("log")
FileManager.default.createFile(atPath: logURL.path, contents: nil)
daemon.standardError = try! FileHandle(forWritingTo: logURL)
try! daemon.run()

func cleanup() {
    if daemon.isRunning { daemon.terminate() }
    if helper.isRunning { helper.terminate() }
    CGWarpMouseCursorPosition(cursorAtStart)
}
signal(SIGINT) { _ in cleanup(); exit(1) }

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

for _ in 0..<50 where CFMessagePortCreateRemote(nil, env["TATAMI_PORT"]! as CFString) == nil { usleep(100_000) }
guard CFMessagePortCreateRemote(nil, env["TATAMI_PORT"]! as CFString) != nil else {
    print("tatami did not start:\n" + ((try? String(contentsOf: logURL, encoding: .utf8)) ?? ""))
    cleanup(); exit(1)
}

// MARK: Observing

let helperElement = AXUIElementCreateApplication(helper.processIdentifier)
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
    for w in (attribute(helperElement, kAXWindowsAttribute) as? [AXUIElement]) ?? [] where windowID(w) == id {
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
func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 3) -> Bool { abs(a - b) <= tolerance }
func show(_ r: CGRect) -> String { "(\(Int(r.minX)), \(Int(r.minY)), \(Int(r.width))x\(Int(r.height)))" }

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

// MARK: Mouse

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

// MARK: - Scenarios

print("tatami e2e")

// tatami starts focused on the Monitor the cursor is on: that is where the tests run.
area = monitors.first { $0.contains(cursorAtStart) } ?? area
print("  on Monitor \(show(area))\(mouseTests ? "" : ", mouse tests skipped")")

print("tiling")
usleep(1_000_000)  // let tatami finish its first-start scan: windows found by it join the Desk of the Monitor they are on
let a = open()
check("the window opens on the Monitor the cursor is on", "\(show(frame(a))) not on \(show(area))") {
    area.contains(CGPoint(x: frame(a).midX, y: frame(a).midY))
}
area = monitors.first { $0.contains(CGPoint(x: frame(a).midX, y: frame(a).midY)) } ?? area
check("one window fills the Monitor inside the outer gap", show(frame(a))) {
    let f = frame(a)
    return near(f.minX, area.minX + outer) && near(f.minY, area.minY + outer)
        && near(f.width, area.width - 2 * outer) && near(f.height, area.height - 2 * outer)
}
let b = open()
checkPair("second window takes its half", a, b)
check("on the right", "a \(show(frame(a))) b \(show(frame(b)))") { frame(b).minX > frame(a).minX }
check("new window has focus", "focused \(focused())") { focused() == b }

print("keyboard focus")
tatami("focus", "left")
check("focus left moves to the left window", "focused \(focused())") { focused() == a }
check("cursor warped into it") { frame(a).contains(CGEvent(source: nil)!.location) }

print("focus from outside")
_ = ask("select \(b)")
check("a window activated from outside gets the cursor", "cursor \(CGEvent(source: nil)!.location) window \(show(frame(b)))") {
    frame(b).contains(CGEvent(source: nil)!.location)
}
tatami("focus", "left")
check("back on the left window", "focused \(focused())") { focused() == a }

var before = (frame(a), frame(b))
if mouseTests {
// Synthetic mouse input lands on whatever is on top: make sure that is the test windows.
_ = ask("front")
print("focus follows mouse")
hover(CGPoint(x: frame(b).midX, y: frame(b).midY))
check("hovering the right window focuses it (same app, no raise)", "focused \(focused())") { focused() == b }

print("mouse resize")
before = (frame(a), frame(b))
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

print("mouse swap")
before = (frame(a), frame(b))
drag(from: CGPoint(x: before.0.midX, y: before.0.minY + 14), to: CGPoint(x: before.1.midX, y: before.1.midY))
check("dropping the left window on the right one swaps them", "a \(show(frame(a))) b \(show(frame(b)))") {
    near(frame(a).minX, before.1.minX) && near(frame(b).minX, before.0.minX) && near(frame(a).width, before.1.width)
}
drag(from: CGPoint(x: frame(a).midX, y: frame(a).minY + 14), to: CGPoint(x: frame(a).midX + 60, y: frame(a).minY + 60))
check("a window dropped on itself snaps back", "a \(show(frame(a)))") { near(frame(a).minX, before.1.minX) && near(frame(a).minY, before.1.minY) }

}

print("accordion")
tatami("layout", "toggle")
check("layout toggle stacks both windows nearly full-size, one peeking 32 px", "a \(show(frame(a))) b \(show(frame(b)))") {
    near(frame(a).width, area.width - 2 * outer - 32) && near(frame(b).width, frame(a).width)
        && near(abs(frame(a).minX - frame(b).minX), 32) && near(min(frame(a).minX, frame(b).minX), area.minX + outer)
}
tatami("layout", "toggle")
checkPair("toggling back restores the tiling", a, b)
tatami("desk", "6")
check("a Desk with `layout N = accordion` starts as Accordion", tatami("state")) {
    tatami("state").split(separator: "\n").contains { $0.hasPrefix("desk 6 ") && $0.contains("accordion") }
}
tatami("desk", "last")

print("desks")
before = (frame(a), frame(b))
tatami("desk", "9")
check("switching Desk parks both windows", "a \(show(frame(a))) b \(show(frame(b)))") { frame(a).minX >= parkX && frame(b).minX >= parkX }
tatami("desk", "last")
check("switching back returns them exactly", "a \(show(frame(a))) b \(show(frame(b)))") { near(frame(a).minX, before.0.minX) && near(frame(b).minX, before.1.minX) && near(frame(a).width, before.0.width) }
let homeDesk = tatami("state").split(separator: "\n").first { $0.contains("focused") }?.split(separator: " ").dropFirst().first.map(String.init) ?? "1"
tatami("send", "8")
check("send moves the focused window and follows it", tatami("state")) {
    tatami("state").split(separator: "\n").contains { $0.hasPrefix("desk 8 ") && $0.contains("active focused") }
}
check("the other window is parked", "a \(show(frame(a))) b \(show(frame(b)))") { (frame(a).minX >= parkX) != (frame(b).minX >= parkX) }
tatami("send", homeDesk)
check("and back: both windows on the first Desk again", tatami("state")) {
    frame(a).minX < parkX && frame(b).minX < parkX && !tatami("state").contains("desk 8 ")
}

print("minimum size")
let big = open("1100 300")
check("a window with a wide minimum keeps it", show(frame(big))) { frame(big).width >= 1100 }
check("and no tiled window overlaps another", "a \(show(frame(a))) b \(show(frame(b))) big \(show(frame(big)))") {
    let f = [frame(a), frame(b), frame(big)].map { $0.insetBy(dx: 2, dy: 2) }
    return !f[0].intersects(f[1]) && !f[0].intersects(f[2]) && !f[1].intersects(f[2])
}

print("floating")
check("the new window is focused", "focused \(focused())") { focused() == big }
tatami("float", "toggle")
check("float toggle centres the window on the Monitor", show(frame(big))) {
    near(frame(big).midX, area.midX, 6) && near(frame(big).midY, area.midY, 6)
}
check("the other two fill the Monitor again", "a \(show(frame(a))) b \(show(frame(b)))") {
    near(min(frame(a).minX, frame(b).minX), area.minX + outer) && near(max(frame(a).maxX, frame(b).maxX), area.maxX - outer)
}
tatami("focus", "left")
check("keyboard focus leaves the Floating Window", "focused \(focused())") { focused() != big }
tatami("focus", "right")
check("and comes back to it", "focused \(focused())") { focused() == big }

print("closing")
_ = ask("close \(big)")
check("after closing, focus stays on the Desk", "focused \(focused())") { [a, b].contains(focused()) }
_ = ask("close \(b)")
check("the last window fills the Monitor again", show(frame(a))) { near(frame(a).width, area.width - 2 * outer) }

print("stop")
let c = open()
tatami("desk", "7")
check("windows parked before stop") { frame(a).minX >= parkX && frame(c).minX >= parkX }
tatami("stop")
check("tatami exits") { !daemon.isRunning }
check("every window is back on-screen", "a \(show(frame(a))) c \(show(frame(c)))") { frame(a).minX < parkX && frame(c).minX < parkX }

cleanup()
let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
if failures > 0, !log.isEmpty { print("--- tatami log\n" + log) }
try? FileManager.default.removeItem(at: home)
print(failures == 0 ? "PASS" : "FAILED: \(failures)")
exit(failures == 0 ? 0 : 1)
