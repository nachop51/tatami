// Phase 0 spike: does AXUIElementSetMessagingTimeout bound calls to a hung app,
// and do calls to other apps stay fast meanwhile?
// Build: swiftc -O -swift-version 5 spikes/ax-hang.swift -o .build/ax-hang
// Run:   .build/ax-hang      (spawns itself as a helper app, SIGSTOPs it, measures, kills it)
import AppKit
import ApplicationServices

if CommandLine.arguments.contains("--helper") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 300),
                     styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
    w.title = "tatami-hang-helper"
    w.orderFrontRegardless()
    app.run()
    exit(0)
}

guard AXIsProcessTrusted() else {
    print("NOT TRUSTED: grant Accessibility to the app that launched this, then rerun")
    exit(2)
}

func ms(_ f: () -> Void) -> Double {
    let t = DispatchTime.now().uptimeNanoseconds
    f()
    return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
}

func attr(_ e: AXUIElement, _ a: String) -> (AXError, CFTypeRef?) {
    var v: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(e, a as CFString, &v)
    return (err, v)
}

func setPos(_ w: AXUIElement, _ p: CGPoint) -> AXError {
    var p = p
    return AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
}

let helper = Process()
helper.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
helper.arguments = ["--helper"]
try! helper.run()
let pid = helper.processIdentifier
func cleanup() { kill(pid, SIGCONT); kill(pid, SIGKILL) }
signal(SIGINT) { _ in cleanup(); exit(1) }
defer { cleanup() }

let appEl = AXUIElementCreateApplication(pid)
var win: AXUIElement?
for _ in 0..<50 {
    if let w = (attr(appEl, kAXWindowsAttribute).1 as? [AXUIElement])?.first { win = w; break }
    usleep(100_000)
}
guard let win else { print("helper window never appeared"); cleanup(); exit(1) }

// Some other responsive app's window, to check for collateral slowness.
var other: AXUIElement?
var otherName = "?"
for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
    let el = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(el, 1.0)
    if let w = (attr(el, kAXWindowsAttribute).1 as? [AXUIElement])?.first {
        other = w; otherName = app.localizedName ?? "?"; break
    }
}

func probe(_ label: String) {
    var e = AXError.success
    let t1 = ms { e = attr(win, kAXPositionAttribute).0 }
    print(String(format: "  %@ get position: %.1f ms err=%d", label, t1, e.rawValue))
    let t2 = ms { e = setPos(win, CGPoint(x: 210, y: 210)) }
    print(String(format: "  %@ set position: %.1f ms err=%d", label, t2, e.rawValue))
    let t3 = ms { e = attr(appEl, kAXWindowsAttribute).0 }
    print(String(format: "  %@ list windows: %.1f ms err=%d", label, t3, e.rawValue))
}

print("helper pid \(pid), other app: \(otherName)")
print("responsive:")
probe("helper")

kill(pid, SIGSTOP)
usleep(200_000)
print("stopped (kAXErrorCannotComplete = -25204):")
for timeout: Float in [0.05, 0.1, 0.25, 1.0] {
    AXUIElementSetMessagingTimeout(appEl, timeout)
    print(" timeout \(timeout) s set on app element:")
    probe("helper")
}

// The timeout is per element: the app-element setting above does not reach the window element.
AXUIElementSetMessagingTimeout(win, 0.1)
print(" timeout 0.1 s set on window element itself:")
probe("helper")
AXUIElementSetMessagingTimeout(win, 0)  // 0 = back to the global default
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.1)
print(" timeout 0.1 s set on system-wide element (process-global default), fresh elements:")
let appEl2 = AXUIElementCreateApplication(pid)
var e2 = AXError.success
let tl = ms { e2 = attr(appEl2, kAXWindowsAttribute).0 }
print(String(format: "  fresh app element list windows: %.1f ms err=%d", tl, e2.rawValue))
let tw = ms { e2 = attr(win, kAXPositionAttribute).0 }
print(String(format: "  window element get position: %.1f ms err=%d", tw, e2.rawValue))

AXUIElementSetMessagingTimeout(win, 1.0)
if let other {
    // While one thread is blocked on the hung app for 1 s, hammer another app from a second thread.
    var during: [Double] = []
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { _ = attr(win, kAXPositionAttribute); done.signal() }
    usleep(50_000)
    while done.wait(timeout: .now()) == .timedOut {
        during.append(ms { _ = attr(other, kAXPositionAttribute) })
        usleep(10_000)
    }
    let s = during.sorted()
    print(String(format: "other app (%@) get position while hung call blocked: n=%d med=%.2f max=%.2f ms",
                 otherName, s.count, s[s.count / 2], s.last ?? 0))
}

kill(pid, SIGCONT)
usleep(300_000)
print("resumed:")
probe("helper")
