// Phase 0 spike: can a border overlay be ordered directly below/above another app's window
// with public API, and can we read that window's corner radius?
// Build: swiftc -O -swift-version 5 -F /System/Library/PrivateFrameworks -framework SkyLight spikes/border-order.swift -o .build/border-order
import AppKit

@_silgen_name("SLSMainConnectionID") func SLSMainConnectionID() -> Int32
@_silgen_name("SLSWindowQueryWindows") func SLSWindowQueryWindows(_ cid: Int32, _ wins: CFArray, _ count: UInt32) -> CFTypeRef
@_silgen_name("SLSWindowQueryResultCopyWindows") func SLSWindowQueryResultCopyWindows(_ query: CFTypeRef) -> CFTypeRef
@_silgen_name("SLSWindowIteratorAdvance") func SLSWindowIteratorAdvance(_ it: CFTypeRef) -> Bool
@_silgen_name("SLSWindowIteratorGetCornerRadii") func SLSWindowIteratorGetCornerRadii(_ it: CFTypeRef) -> Unmanaged<CFArray>?

func onScreen() -> [[String: Any]] {
    (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
}
func wid(_ w: [String: Any]) -> Int { w[kCGWindowNumber as String] as? Int ?? 0 }

let me = ProcessInfo.processInfo.processIdentifier
guard let target = onScreen().first(where: {
    ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowOwnerPID as String] as? pid_t) != me
        && (CGRect(dictionaryRepresentation: $0[kCGWindowBounds as String] as! CFDictionary)?.width ?? 0) > 300
}) else { print("no target window"); exit(1) }
let tid = wid(target)
let tb = CGRect(dictionaryRepresentation: target[kCGWindowBounds as String] as! CFDictionary)!
print("target: wid=\(tid) owner=\(target[kCGWindowOwnerName as String] ?? "?") bounds=\(tb)")

// Corner radius via private iterator.
let query = SLSWindowQueryWindows(SLSMainConnectionID(), [tid] as CFArray, 1)
let it = SLSWindowQueryResultCopyWindows(query)
if SLSWindowIteratorAdvance(it) {
    print("corner radii:", SLSWindowIteratorGetCornerRadii(it)?.takeUnretainedValue() as Any)
} else { print("corner radii: iterator empty") }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let primaryH = NSScreen.screens[0].frame.height
let width: CGFloat = 8
let frame = CGRect(x: tb.minX - width, y: primaryH - tb.maxY - width, width: tb.width + 2 * width, height: tb.height + 2 * width)
let win = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
win.isOpaque = false
win.backgroundColor = .clear
win.hasShadow = false
win.ignoresMouseEvents = true
win.collectionBehavior = [.stationary, .ignoresCycle]
let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
view.wantsLayer = true
let shape = CAShapeLayer()
shape.path = CGPath(roundedRect: view.bounds.insetBy(dx: width / 2, dy: width / 2), cornerWidth: 16, cornerHeight: 16, transform: nil)
shape.fillColor = nil
shape.strokeColor = NSColor(red: 1, green: 0.176, blue: 0.47, alpha: 1).cgColor
shape.lineWidth = width
view.layer!.addSublayer(shape)
win.contentView = view

func report(_ label: String) {
    let ids = onScreen().filter { ($0[kCGWindowLayer as String] as? Int) == 0 }.map(wid)
    let mine = ids.firstIndex(of: win.windowNumber), theirs = ids.firstIndex(of: tid)
    print("\(label): overlay z-index=\(mine.map(String.init) ?? "absent") target z-index=\(theirs.map(String.init) ?? "absent") (0 = frontmost)")
}

var step = 0
Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
    step += 1
    switch step {
    case 1: win.order(.below, relativeTo: tid)
    case 2: report("order below"); win.order(.above, relativeTo: tid)
    case 3: report("order above"); win.order(.below, relativeTo: tid)
    case 4: report("order below again"); exit(0)
    default: break
    }
}
app.run()
