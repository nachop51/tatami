// Phase 0 spike: do private SkyLight window notifications still work on this macOS with SIP on,
// and how soon after the real operation do they arrive?
// Build: swiftc -O -swift-version 5 -F /System/Library/PrivateFrameworks -framework SkyLight spikes/sls-events.swift -o .build/sls-events
// The listener spawns itself with --child; the child opens, moves, resizes and closes a window.
import AppKit

setvbuf(stdout, nil, _IONBF, 0)
func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }
let t0 = Double(ProcessInfo.processInfo.environment["T0"] ?? "") ?? now()
func log(_ s: String) { print(String(format: "%8.1f ms  %@", now() - t0, s)) }

if CommandLine.arguments.contains("--child") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    var win: NSWindow!
    var step = 0
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
        step += 1
        switch step {
        case 1:
            win = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 400, height: 300), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            log("OP create"); win.orderFrontRegardless(); log("OP create returned wid=\(win.windowNumber)")
        case 2: log("OP move"); win.setFrameOrigin(CGPoint(x: 260, y: 260))
        case 3: log("OP resize"); win.setContentSize(CGSize(width: 500, height: 350))
        case 4:
            // CLOSE=noanim disables the window's close animation; CLOSE=orderout hides instead of closing.
            let mode = ProcessInfo.processInfo.environment["CLOSE"] ?? "default"
            if mode == "noanim" { win.animationBehavior = .none }
            log("OP close (\(mode))")
            if mode == "orderout" { win.orderOut(nil) } else { win.close() }
        case 5: exit(0)
        default: break
        }
    }
    app.run()
}

typealias NotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void
@_silgen_name("SLSMainConnectionID") func SLSMainConnectionID() -> Int32
@_silgen_name("SLSRegisterNotifyProc") func SLSRegisterNotifyProc(_ proc: NotifyProc, _ event: UInt32, _ ctx: UnsafeMutableRawPointer?) -> Int32
@_silgen_name("SLSRequestNotificationsForWindows") func SLSRequestNotificationsForWindows(_ cid: Int32, _ wins: UnsafePointer<UInt32>, _ count: Int32) -> Int32

let names: [UInt32: String] = [723: "update", 804: "close", 806: "move", 807: "resize", 808: "reorder", 811: "level",
                               815: "unhide", 816: "hide", 1325: "create", 1326: "destroy", 1508: "front-change"]
let cid = SLSMainConnectionID()
var watched: [UInt32] = []

let handler: NotifyProc = { event, data, len, _ in
    var wid: UInt32 = 0
    if let data {
        // create/destroy carry { uint64 space; uint32 wid }, the rest carry { uint32 wid }.
        wid = len >= 12 ? data.load(fromByteOffset: 8, as: UInt32.self) : (len >= 4 ? data.load(as: UInt32.self) : 0)
    }
    log("EV \(names[event] ?? String(event)) wid=\(wid) len=\(len)")
    if event == 1325 {
        watched.append(wid)
        let r = SLSRequestNotificationsForWindows(cid, watched, Int32(watched.count))
        log("   requested per-window notifications -> \(r)")
    }
}
for e in names.keys { _ = SLSRegisterNotifyProc(handler, e, nil) }

// Comparison: does the public AX destroyed notification beat the SkyLight close event?
var axObserver: AXObserver?
func watchAX(_ pid: pid_t) {
    guard AXIsProcessTrusted() else { log("AX not trusted, skipping AX comparison"); return }
    let appEl = AXUIElementCreateApplication(pid)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &v) == .success,
          let w = (v as? [AXUIElement])?.first else { log("AX: no window"); return }
    AXObserverCreate(pid, { _, _, name, _ in log("AX \(name)") }, &axObserver)
    AXObserverAddNotification(axObserver!, w, kAXUIElementDestroyedNotification as CFString, nil)
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver!), .defaultMode)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let child = Process()
child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
child.arguments = ["--child"]
child.environment = ProcessInfo.processInfo.environment.merging(["T0": String(t0)]) { $1 }
try! child.run()
Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in watchAX(child.processIdentifier) }
Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { _ in exit(0) }
app.run()
