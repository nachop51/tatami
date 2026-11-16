import AppKit
import TatamiCore

/// One click-through overlay per bordered Window, kept directly below it, drawing a ring just outside its frame.
final class Borders {
    private var overlays: [WindowID: (window: NSWindow, ring: CAShapeLayer)] = [:]
    private var radii: [WindowID: CGFloat] = [:]

    /// `frames` are the Windows to border, in Accessibility coordinates. Everything else loses its border.
    func update(frames: [WindowID: Rect], focused: WindowID?, width: CGFloat, active: UInt32, inactive: UInt32) {
        let wanted = width > 0 ? frames : [:]
        for id in overlays.keys where wanted[id] == nil {
            overlays.removeValue(forKey: id)?.window.orderOut(nil)
            radii[id] = nil
        }
        let primaryHeight = NSScreen.screens[0].frame.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)  // no animations
        for (id, r) in wanted {
            let overlay = overlays[id] ?? make(id)
            let frame = CGRect(x: r.x - width, y: primaryHeight - r.maxY - width, width: r.w + 2 * width, height: r.h + 2 * width)
            if overlay.window.frame != frame { overlay.window.setFrame(frame, display: false) }
            if radii[id] == nil { radii[id] = cornerRadius(of: id) ?? 0 }
            let radius = min(radii[id]! + width / 2, min(frame.width, frame.height) / 2 - width / 2)
            overlay.ring.path = CGPath(roundedRect: CGRect(origin: .zero, size: frame.size).insetBy(dx: width / 2, dy: width / 2),
                                       cornerWidth: max(radius, 0), cornerHeight: max(radius, 0), transform: nil)
            overlay.ring.lineWidth = width
            overlay.ring.strokeColor = colour(id == focused ? active : inactive)
            overlay.window.order(.below, relativeTo: Int(id))
        }
        CATransaction.commit()
    }

    private func make(_ id: WindowID) -> (window: NSWindow, ring: CAShapeLayer) {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.collectionBehavior = [.stationary, .ignoresCycle]
        let view = NSView()
        view.wantsLayer = true
        let ring = CAShapeLayer()
        ring.fillColor = nil
        view.layer!.addSublayer(ring)
        window.contentView = view
        overlays[id] = (window, ring)
        return (window, ring)
    }

    private func colour(_ rgba: UInt32) -> CGColor {
        CGColor(red: CGFloat(rgba >> 24 & 0xff) / 255, green: CGFloat(rgba >> 16 & 0xff) / 255,
                blue: CGFloat(rgba >> 8 & 0xff) / 255, alpha: CGFloat(rgba & 0xff) / 255)
    }
}
