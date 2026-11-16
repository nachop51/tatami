// Every private (undocumented) macOS call tatami makes lives in this file.
import ApplicationServices
import Carbon.HIToolbox

/// Accessibility has no public way to get a window's id, and the saved Window→Desk mapping
/// needs an id that survives a tatami restart.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: inout CGWindowID) -> AXError

@_silgen_name("GetProcessForPID")
private func GetProcessForPID(_ pid: pid_t, _ psn: inout ProcessSerialNumber) -> OSStatus

@_silgen_name("_SLPSSetFrontProcessWithOptions")
private func _SLPSSetFrontProcessWithOptions(_ psn: inout ProcessSerialNumber, _ window: UInt32, _ mode: UInt32) -> CGError

@_silgen_name("SLPSPostEventRecordTo")
private func SLPSPostEventRecordTo(_ psn: inout ProcessSerialNumber, _ bytes: UnsafeMutablePointer<UInt8>) -> CGError

@_silgen_name("SLSMainConnectionID") private func SLSMainConnectionID() -> Int32
@_silgen_name("SLSWindowQueryWindows") private func SLSWindowQueryWindows(_ cid: Int32, _ windows: CFArray, _ count: UInt32) -> CFTypeRef
@_silgen_name("SLSWindowQueryResultCopyWindows") private func SLSWindowQueryResultCopyWindows(_ query: CFTypeRef) -> CFTypeRef
@_silgen_name("SLSWindowIteratorAdvance") private func SLSWindowIteratorAdvance(_ iterator: CFTypeRef) -> Bool
@_silgen_name("SLSWindowIteratorGetCornerRadii") private func SLSWindowIteratorGetCornerRadii(_ iterator: CFTypeRef) -> Unmanaged<CFArray>?

/// A window's corner radius, so its border can hug it. No public API reports it.
func cornerRadius(of window: UInt32) -> CGFloat? {
    let iterator = SLSWindowQueryResultCopyWindows(SLSWindowQueryWindows(SLSMainConnectionID(), [window] as CFArray, 1))
    guard SLSWindowIteratorAdvance(iterator),
          let radii = SLSWindowIteratorGetCornerRadii(iterator)?.takeUnretainedValue() as? [CGFloat] else { return nil }
    return radii.max()
}

/// Give a window keyboard focus. The public API can only focus by raising, cannot pick one window of an app
/// reliably, and its app activation is a request macOS may ignore. With `raise` false the stacking order stays.
/// Event record layout as used by yabai; `previous` is the window that had focus.
func focusWindow(pid: pid_t, window: UInt32, previous: (pid: pid_t, window: UInt32)?, raise: Bool) {
    var psn = ProcessSerialNumber()
    guard GetProcessForPID(pid, &psn) == noErr else { return }
    func record(_ fill: (inout [UInt8]) -> Void, window: UInt32) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        withUnsafeBytes(of: window) { for (i, b) in $0.enumerated() { bytes[0x3c + i] = b } }
        fill(&bytes)
        return bytes
    }
    if let previous, previous.pid == pid {
        // Within one app the window server will not move key status by itself.
        var lose = record({ $0[0x08] = 0x0d; $0[0x8a] = 0x02 }, window: previous.window)
        _ = SLPSPostEventRecordTo(&psn, &lose)
        usleep(10_000)
        var gain = record({ $0[0x08] = 0x0d; $0[0x8a] = 0x01 }, window: window)
        _ = SLPSPostEventRecordTo(&psn, &gain)
    }
    _ = _SLPSSetFrontProcessWithOptions(&psn, window, raise ? 0x200 /* user generated: this window forward */ : 0x400 /* none */)
    for phase: UInt8 in [0x01, 0x02] {
        var key = record({ $0[0x08] = phase; $0[0x3a] = 0x10; for i in 0x20..<0x30 { $0[i] = 0xff } }, window: window)
        _ = SLPSPostEventRecordTo(&psn, &key)
    }
}
