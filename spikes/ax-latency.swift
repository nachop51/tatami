// Phase 0 spike: how fast is the Accessibility API, and can a Desk switch fit in 100 ms?
// Build: swiftc -O -swift-version 5 spikes/ax-latency.swift -o .build/ax-latency
// Run:   .build/ax-latency          (reads + 1px nudge, harmless)
//        .build/ax-latency --park   (moves every window off-screen and back, serial then parallel)
import AppKit
import ApplicationServices

guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
    print("NOT TRUSTED: grant Accessibility to the app that launched this, then rerun")
    exit(2)
}

func ms(_ f: () -> Void) -> Double {
    let t = DispatchTime.now().uptimeNanoseconds
    f()
    return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
}

func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}

func getPos(_ w: AXUIElement) -> CGPoint? {
    guard let v = attr(w, kAXPositionAttribute) else { return nil }
    var p = CGPoint.zero
    AXValueGetValue(v as! AXValue, .cgPoint, &p)
    return p
}

func getSize(_ w: AXUIElement) -> CGSize? {
    guard let v = attr(w, kAXSizeAttribute) else { return nil }
    var s = CGSize.zero
    AXValueGetValue(v as! AXValue, .cgSize, &s)
    return s
}

@discardableResult func setPos(_ w: AXUIElement, _ p: CGPoint) -> AXError {
    var p = p
    return AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
}

@discardableResult func setSize(_ w: AXUIElement, _ s: CGSize) -> AXError {
    var s = s
    return AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!)
}

func stats(_ xs: [Double]) -> String {
    guard !xs.isEmpty else { return "n=0" }
    let s = xs.sorted()
    func q(_ p: Double) -> Double { s[min(s.count - 1, Int(Double(s.count) * p))] }
    return String(format: "n=%d min=%.2f med=%.2f p95=%.2f max=%.2f ms", s.count, s[0], q(0.5), q(0.95), s[s.count - 1])
}

struct Win { let app: String; let pid: pid_t; let el: AXUIElement; let pos: CGPoint; let size: CGSize }

var wins: [Win] = []
var enumerate: [Double] = []
for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
    let el = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(el, 1.0)
    var list: [AXUIElement] = []
    enumerate.append(ms { list = (attr(el, kAXWindowsAttribute) as? [AXUIElement]) ?? [] })
    for w in list {
        guard (attr(w, kAXSubroleAttribute) as? String) == (kAXStandardWindowSubrole as String),
              (attr(w, kAXMinimizedAttribute) as? Bool) != true,
              let p = getPos(w), let s = getSize(w) else { continue }
        wins.append(Win(app: app.localizedName ?? "?", pid: app.processIdentifier, el: w, pos: p, size: s))
    }
}

let byApp = Dictionary(grouping: wins, by: \.pid)
print("windows: \(wins.count) across \(byApp.count) apps")
for (_, ws) in byApp { print("  \(ws[0].app): \(ws.count)") }
print("list windows per app:  \(stats(enumerate))")

if !CommandLine.arguments.contains("--park") {
    var gp: [Double] = [], gs: [Double] = [], sp: [Double] = [], ss: [Double] = []
    for _ in 0..<5 {
        for w in wins {
            gp.append(ms { _ = getPos(w.el) })
            gs.append(ms { _ = getSize(w.el) })
            sp.append(ms { setPos(w.el, CGPoint(x: w.pos.x + 1, y: w.pos.y)) })
            sp.append(ms { setPos(w.el, w.pos) })
            ss.append(ms { setSize(w.el, CGSize(width: w.size.width - 1, height: w.size.height)) })
            ss.append(ms { setSize(w.el, w.size) })
        }
    }
    print("get position:          \(stats(gp))")
    print("get size:              \(stats(gs))")
    print("set position (1px):    \(stats(sp))")
    print("set size (1px):        \(stats(ss))")
    exit(0)
}

// --park: simulate a Desk switch. Hide = move every window to the bottom-right corner; show = move back.
let corner: CGPoint = {
    let u = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
    return CGPoint(x: u.maxX - 1, y: u.height - 1)
}()
func restore() { for w in wins { setPos(w.el, w.pos) } }
signal(SIGINT) { _ in restore(); exit(1) }

let groups = Array(byApp.values)
var serialHide: [Double] = [], serialShow: [Double] = [], parHide: [Double] = [], parShow: [Double] = []
for _ in 0..<5 {
    serialHide.append(ms { for w in wins { setPos(w.el, corner) } })
    serialShow.append(ms { for w in wins { setPos(w.el, w.pos) } })
    parHide.append(ms { DispatchQueue.concurrentPerform(iterations: groups.count) { i in for w in groups[i] { setPos(w.el, corner) } } })
    parShow.append(ms { DispatchQueue.concurrentPerform(iterations: groups.count) { i in for w in groups[i] { setPos(w.el, w.pos) } } })
}
restore()
var drift = 0
for w in wins { if let p = getPos(w.el), p != w.pos { drift += 1 } }
print("serial   hide all: \(stats(serialHide))")
print("serial   show all: \(stats(serialShow))")
print("parallel hide all: \(stats(parHide))")
print("parallel show all: \(stats(parShow))")
print("windows not back at original position: \(drift)")
