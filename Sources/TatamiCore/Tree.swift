public typealias WindowID = UInt32
public typealias MonitorID = String

/// Top-left origin, y grows downward (the Accessibility coordinate space).
public struct Rect: Equatable, Sendable {
    public var x, y, w, h: Double
    public init(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }
    public var maxX: Double { x + w }
    public var maxY: Double { y + h }
    func inset(_ d: Double) -> Rect { Rect(x + d, y + d, w - 2 * d, h - 2 * d) }
    public func contains(_ px: Double, _ py: Double) -> Bool { x <= px && px < maxX && y <= py && py < maxY }
}

public enum Direction: String, Sendable { case left, right, up, down }

enum Axis: String, Codable { case sideBySide, stacked }

/// The split tree of a Desk's Tiled Windows. In-order leaves double as the Accordion order.
/// Set on the ids of placeholders: Windows of a restored arrangement that have not shown up yet.
/// They keep their place in the tree but take no room on screen.
let ghostBit: WindowID = 0x8000_0000

indirect enum Node: Equatable, Codable {
    case leaf(WindowID)
    case split(Axis, ratio: Double, Node, Node)

    var leaves: [WindowID] {
        switch self {
        case .leaf(let w): return [w]
        case .split(_, _, let a, let b): return a.leaves + b.leaves
        }
    }

    func contains(_ w: WindowID) -> Bool { leaves.contains(w) }

    typealias Size = (w: Double, h: Double)

    /// The smallest area the subtree can take, given each Window's minimum size.
    func minSize(_ m: (WindowID) -> Size) -> Size {
        switch self {
        case .leaf(let w): return m(w)
        case .split(let axis, _, let a, let b):
            let x = a.minSize(m), y = b.minSize(m)
            return axis == .sideBySide ? (x.w + y.w, max(x.h, y.h)) : (max(x.w, y.w), x.h + y.h)
        }
    }

    /// The two halves of a split of `r`: by ratio, then pushed so each side gets at least its minimum.
    private static func halves(_ axis: Axis, _ ratio: Double, _ a: Node, _ b: Node, in r: Rect, _ m: (WindowID) -> Size) -> (Rect, Rect) {
        let ma = a.minSize(m), mb = b.minSize(m)
        if axis == .sideBySide {
            let w = max(min(max(r.w * ratio, ma.w), r.w - mb.w), 0)
            return (Rect(r.x, r.y, w, r.h), Rect(r.x + w, r.y, r.w - w, r.h))
        }
        let h = max(min(max(r.h * ratio, ma.h), r.h - mb.h), 0)
        return (Rect(r.x, r.y, r.w, h), Rect(r.x, r.y + h, r.w, r.h - h))
    }

    func frames(in r: Rect, min m: (WindowID) -> Size = { _ in (0, 0) }) -> [WindowID: Rect] {
        switch self {
        case .leaf(let w): return [w: r]
        case .split(let axis, let ratio, let a, let b):
            let (ra, rb) = Node.halves(axis, ratio, a, b, in: r, m)
            return a.frames(in: ra, min: m).merging(b.frames(in: rb, min: m)) { x, _ in x }
        }
    }

    /// `w` was dragged from `old` to `new`: every split whose boundary is an edge that moved follows it.
    func resizing(_ w: WindowID, from old: Rect, to new: Rect, in r: Rect, min m: (WindowID) -> Size) -> Node {
        guard case .split(let axis, var ratio, let a, let b) = self else { return self }
        let (ra, rb) = Node.halves(axis, ratio, a, b, in: r, m)
        let first = a.contains(w)
        // The boundary is the first half's far edge and the second half's near edge.
        let (was, now, origin, length) = axis == .sideBySide
            ? (first ? old.maxX : old.x, first ? new.maxX : new.x, r.x, r.w)
            : (first ? old.maxY : old.y, first ? new.maxY : new.y, r.y, r.h)
        let boundary = axis == .sideBySide ? ra.maxX : ra.maxY
        if abs(was - boundary) < 1, abs(now - was) > 1, length > 0 {
            ratio = min(max((now - origin) / length, 0.1), 0.9)
        }
        return .split(axis, ratio: ratio,
                      first ? a.resizing(w, from: old, to: new, in: ra, min: m) : a,
                      first ? b : b.resizing(w, from: old, to: new, in: rb, min: m))
    }

    /// Rebuild the tree leaf by leaf; a leaf mapped to nil is removed and its sibling takes the parent's place.
    private func rewrite(_ f: (WindowID) -> Node?) -> Node? {
        switch self {
        case .leaf(let w): return f(w)
        case .split(let axis, let ratio, let a, let b):
            switch (a.rewrite(f), b.rewrite(f)) {
            case let (x?, y?): return .split(axis, ratio: ratio, x, y)
            case let (x?, nil): return x
            case let (nil, y): return y
            }
        }
    }

    /// The tree without the leaves that fail `keep`.
    func keeping(_ keep: (WindowID) -> Bool) -> Node? { rewrite { keep($0) ? .leaf($0) : nil } }

    func mapping(_ f: (WindowID) -> WindowID) -> Node { rewrite { .leaf(f($0)) }! }

    func inserting(_ new: WindowID, at target: WindowID, _ axis: Axis) -> Node {
        rewrite { $0 == target ? .split(axis, ratio: 0.5, .leaf(target), .leaf(new)) : .leaf($0) }!
    }

    func removing(_ w: WindowID) -> Node? { rewrite { $0 == w ? nil : .leaf($0) } }

    func swapping(_ a: WindowID, _ b: WindowID) -> Node {
        rewrite { .leaf($0 == a ? b : $0 == b ? a : $0) }!
    }

    /// Flip the split that directly holds `w`.
    func togglingSplit(of w: WindowID) -> Node {
        guard case .split(let axis, let ratio, let a, let b) = self else { return self }
        if a == .leaf(w) || b == .leaf(w) {
            return .split(axis == .sideBySide ? .stacked : .sideBySide, ratio: ratio, a, b)
        }
        return .split(axis, ratio: ratio, a.togglingSplit(of: w), b.togglingSplit(of: w))
    }
}

/// The closest candidate lying in `dir` from `from` that overlaps it on the other axis.
/// Ties go to the earliest candidate, so pass them most-recently-focused first.
func nearest<K>(from: Rect, _ dir: Direction, _ candidates: [(K, Rect)]) -> K? {
    var best: (key: K, gap: Double)?
    for (k, r) in candidates {
        let gap: Double, overlap: Double
        switch dir {
        case .left: gap = from.x - r.maxX
        case .right: gap = r.x - from.maxX
        case .up: gap = from.y - r.maxY
        case .down: gap = r.y - from.maxY
        }
        switch dir {
        case .left, .right: overlap = min(from.maxY, r.maxY) - max(from.y, r.y)
        case .up, .down: overlap = min(from.maxX, r.maxX) - max(from.x, r.x)
        }
        if gap > -0.5, overlap > 0.5, best == nil || gap < best!.gap - 0.5 { best = (k, gap) }
    }
    return best?.key
}
