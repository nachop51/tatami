public struct Monitor: Equatable, Sendable {
    public let id: MonitorID
    public var frame: Rect
    public init(id: MonitorID, frame: Rect) { self.id = id; self.frame = frame }
}

public struct Config: Equatable, Sendable {
    public var gapInner: Double
    public var gapOuter: Double
    /// How much of each Accordion Window peeks out from behind the next.
    public var accordionPeek: Double
    public init(gapInner: Double = 8, gapOuter: Double = 8, accordionPeek: Double = 32) {
        self.gapInner = gapInner; self.gapOuter = gapOuter; self.accordionPeek = accordionPeek
    }
}

public enum LayoutKind: String, Sendable, Codable { case dwindle, accordion }

struct Desk {
    var monitor: MonitorID  // where it shows now
    var home: MonitorID  // where it was first opened; it returns here when that Monitor reconnects
    var layout = LayoutKind.dwindle
    var tree: Node?  // Tiled Windows
    var floating: [WindowID] = []
    var history: [WindowID] = []  // every Window of the Desk, most recently focused first
    var fullscreen: WindowID?

    var isEmpty: Bool { history.isEmpty }
    /// The tree of the Windows that are really there (no placeholders): what gets laid out.
    var live: Node? { tree?.keeping { $0 & ghostBit == 0 } }
    var frontTiled: WindowID? { tree.flatMap { t in history.first(where: t.contains) } }
}

/// What the shell must make true on screen.
public struct Layout: Equatable, Sendable {
    /// Frames of Tiled Windows on Active Desks, and of Fullscreen Windows.
    public var frames: [WindowID: Rect] = [:]
    /// Floating Windows on Active Desks: shown, frame left alone.
    public var floating: Set<WindowID> = []
    /// Windows on Desks that are not active: parked off-screen.
    public var hidden: Set<WindowID> = []
    /// Fullscreen Windows: no border.
    public var fullscreen: Set<WindowID> = []
    /// Windows that must sit above their Desk's other Tiled Windows (Accordion front, Fullscreen).
    public var front: Set<WindowID> = []
    public var focused: WindowID?
    public init() {}
}

/// The whole tatami state. Pure: events and commands in, `layout` out.
public struct World {
    public var config: Config
    public private(set) var pins: [Int: Int]  // Desk number -> Monitor number (1-based, by position)
    public private(set) var layouts: [Int: LayoutKind]  // the Layout a Desk starts with; Dwindle if absent
    public private(set) var monitors: [Monitor] = []  // left to right, then top to bottom
    public private(set) var focusedMonitor: MonitorID = ""
    var desks: [Int: Desk] = [:]
    var active: [MonitorID: Int] = [:]  // may keep entries for disconnected Monitors, used when they return
    var lastDesk: Int?
    var mins: [WindowID: Node.Size] = [:]  // minimum sizes learnt from refused resizes
    var floatFrames: [WindowID: Rect] = [:]  // where Floating Windows are, as the shell reports it
    var native: Set<WindowID> = []  // in macOS native fullscreen: unmanaged, tile kept
    var ghostFloats: [WindowID: Int] = [:]  // placeholders for Floating Windows of a restored arrangement -> Desk
    var ghostFront: [Int: WindowID] = [:]  // the placeholder that was each Desk's focused Window

    /// `restoring` brings back a saved arrangement: its Desks return with a placeholder for every Window,
    /// which `adopt` fills in as the Windows show up.
    public init(monitors: [Monitor], config: Config = Config(), pins: [Int: Int] = [:], layouts: [Int: LayoutKind] = [:],
                restoring saved: Snapshot? = nil) {
        self.config = config
        self.pins = pins
        self.layouts = layouts
        if let saved {
            for (n, d) in saved.desks where Command.deskNumbers.contains(n) {
                var desk = Desk(monitor: d.monitor, home: d.home, layout: d.layout)
                desk.tree = d.tree?.mapping { $0 | ghostBit }
                desks[n] = desk
                for f in d.floating { ghostFloats[f | ghostBit] = n }
                if let front = d.front { ghostFront[n] = front | ghostBit }
            }
            active = saved.active
            focusedMonitor = saved.focusedMonitor
            lastDesk = saved.lastDesk
        }
        setMonitors(monitors)
    }

    // MARK: Queries

    public var focusedDesk: Int { active[focusedMonitor]! }
    public var focusedWindow: WindowID? { desks[focusedDesk]!.history.first }
    public var deskNumbers: [Int] { desks.keys.sorted() }
    public func activeDesk(on monitor: MonitorID) -> Int? { has(monitor) ? active[monitor] : nil }
    public func desk(of w: WindowID) -> Int? { desks.first { $0.value.history.contains(w) }?.key }
    public func windows(onDesk n: Int) -> [WindowID] { desks[n]?.history ?? [] }
    public func layoutKind(ofDesk n: Int) -> LayoutKind? { desks[n]?.layout }

    // MARK: Saving and restoring

    /// Everything needed to arrange the same Windows the same way again.
    public struct Snapshot: Codable, Equatable {
        struct DeskState: Codable, Equatable {
            var layout: LayoutKind
            var home: MonitorID
            var monitor: MonitorID
            var tree: Node?
            var floating: [WindowID]
            var front: WindowID?
        }
        var desks: [Int: DeskState]
        var active: [MonitorID: Int]
        var focusedMonitor: MonitorID
        var lastDesk: Int?
    }

    public var snapshot: Snapshot {
        Snapshot(desks: desks.mapValues {
                     .init(layout: $0.layout, home: $0.home, monitor: $0.monitor, tree: $0.live, floating: $0.floating, front: $0.history.first)
                 },
                 active: active, focusedMonitor: focusedMonitor, lastDesk: lastDesk)
    }

    /// True while Windows of the restored arrangement are still awaited.
    public var hasPlaceholders: Bool { !ghostFloats.isEmpty || desks.values.contains { $0.tree != $0.live } }

    /// A Window of the restored arrangement showed up as `w` (its id may differ from the `saved` one):
    /// it takes its old place. False if no place was waiting for it.
    @discardableResult public mutating func adopt(_ saved: WindowID, as w: WindowID, floating: Bool = false) -> Bool {
        let g = saved | ghostBit
        guard desk(of: w) == nil else { return false }
        let n: Int
        if let floatDesk = ghostFloats.removeValue(forKey: g), desks[floatDesk] != nil {
            n = floatDesk
            desks[n]!.floating.append(w)
        } else if let tiledDesk = desks.first(where: { $0.value.tree?.contains(g) == true })?.key {
            n = tiledDesk
            if floating {
                desks[n]!.tree = desks[n]!.tree!.removing(g)
                desks[n]!.floating.append(w)
            } else {
                desks[n]!.tree = desks[n]!.tree!.swapping(g, w)
            }
        } else {
            return false
        }
        if ghostFront[n] == g {
            ghostFront[n] = nil
            desks[n]!.history.insert(w, at: 0)
        } else {
            desks[n]!.history.append(w)
        }
        return true
    }

    /// Stop waiting: Windows that did not come back lose their place.
    public mutating func dropPlaceholders() {
        for n in desks.keys { desks[n]!.tree = desks[n]!.live }
        ghostFloats = [:]
        ghostFront = [:]
        collect()
    }

    /// One line per Desk, for `tatami state`.
    public var summary: String {
        deskNumbers.map { n in
            let d = desks[n]!
            let m = monitors.firstIndex { $0.id == d.monitor }.map { $0 + 1 } ?? 0
            let flags = (active[d.monitor] == n ? "active " : "") + (n == focusedDesk ? "focused " : "")
            let mins = d.history.compactMap { w in mins[w].map { "\(w)≥\(Int($0.w))x\(Int($0.h))" } }
            return "desk \(n) monitor \(m) \(flags)\(d.layout) tiled \(d.live?.leaves ?? []) floating \(d.floating)"
                + (mins.isEmpty ? "" : " min \(mins.joined(separator: " "))")
        }.joined(separator: "\n")
    }

    public var layout: Layout {
        var out = Layout()
        out.focused = focusedWindow
        for (n, d) in desks {
            guard active[d.monitor] == n else { out.hidden.formUnion(d.history); continue }
            let m = frame(d.monitor)
            out.floating.formUnion(d.floating)
            if let tree = d.live {
                switch d.layout {
                case .dwindle:
                    for (w, r) in tiles(d) { out.frames[w] = r.inset(config.gapInner / 2) }
                case .accordion:
                    let area = m.inset(config.gapOuter), leaves = tree.leaves
                    let wide = area.w >= area.h
                    let length = wide ? area.w : area.h
                    let peek = leaves.count > 1 ? min(config.accordionPeek, length / 2 / Double(leaves.count - 1)) : 0
                    let size = length - peek * Double(leaves.count - 1)
                    for (i, w) in leaves.enumerated() {
                        let o = peek * Double(i)
                        out.frames[w] = wide ? Rect(area.x + o, area.y, size, area.h) : Rect(area.x, area.y + o, area.w, size)
                    }
                    if let f = d.frontTiled { out.front.insert(f) }
                }
            }
            if let f = d.fullscreen {
                out.frames[f] = m
                out.floating.remove(f)
                out.fullscreen.insert(f)
                out.front.insert(f)
            }
        }
        for w in native {
            out.frames[w] = nil
            for set in [\Layout.floating, \.hidden, \.fullscreen, \.front] { out[keyPath: set].remove(w) }
        }
        return out
    }

    // MARK: Events from the shell

    /// A Window opened. `desk` comes from a Rule (or the first-start scan); nil means the focused Monitor's Active Desk.
    /// `focus` false (first-start scan) leaves the Desk's focus where it is.
    public mutating func open(_ w: WindowID, floating: Bool = false, desk: Int? = nil, focus: Bool = true) {
        let n = desk ?? focusedDesk
        guard self.desk(of: w) == nil, Command.deskNumbers.contains(n) else { return }
        ensure(n)
        insert(w, into: n, floating: floating)
        if !focus, desks[n]!.history.count > 1 { desks[n]!.history.append(desks[n]!.history.removeFirst()) }
    }

    public mutating func close(_ w: WindowID) {
        guard let n = desk(of: w) else { return }
        detach(w, from: n)
        mins[w] = nil
        floatFrames[w] = nil
        native.remove(w)
        collect()
    }

    /// The Window refused a smaller size. Its tile grows; if the Desk cannot fit it at all, it floats.
    public mutating func setMinimumSize(_ w: WindowID, width: Double, height: Double) {
        guard let n = desk(of: w), let tree = desks[n]!.live, tree.contains(w) else { return }
        mins[w] = (max(mins[w]?.w ?? 0, width), max(mins[w]?.h ?? 0, height))
        let need = tree.minSize(minimum), area = tileArea(desks[n]!)
        if need.w > area.w + 0.5 || need.h > area.h + 0.5 {
            let history = desks[n]!.history
            detach(w, from: n)
            insert(w, into: n, floating: true)
            desks[n]!.history = history
            mins[w] = nil
        }
    }

    /// The Window will not grow to its tile: it floats, rather than leave part of the tile empty.
    public mutating func float(_ w: WindowID) {
        guard let n = desk(of: w), desks[n]!.live?.contains(w) == true else { return }
        let history = desks[n]!.history
        detach(w, from: n)
        insert(w, into: n, floating: true)
        desks[n]!.history = history
        mins[w] = nil
    }

    /// The Window entered or left macOS native fullscreen. Meanwhile tatami leaves it alone and keeps its tile.
    public mutating func setNativeFullscreen(_ w: WindowID, _ on: Bool) {
        if on { native.insert(w) } else { native.remove(w) }
    }

    /// Where a Window really is. Only Floating Windows need it: the core cannot know their frames otherwise.
    public mutating func observed(_ w: WindowID, at frame: Rect) { floatFrames[w] = frame }

    /// The mouse resized a Tiled Window from `before` to `after`: the splits follow the edges that moved.
    /// Measured against where the Window was, not its tile: an app may sit smaller or bigger than its tile.
    public mutating func resized(_ w: WindowID, from before: Rect, to after: Rect) {
        guard let n = desk(of: w), let d = desks[n], d.layout == .dwindle, let tree = d.live, let old = tiles(d)[w] else { return }
        let new = Rect(old.x + after.x - before.x, old.y + after.y - before.y,
                       old.w + after.w - before.w, old.h + after.h - before.h)
        desks[n]!.tree = tree.resizing(w, from: old, to: new, in: tileArea(d), min: minimum)
    }

    /// The mouse dropped a Tiled Window at a point: it swaps with the Tiled Window there,
    /// or joins the Active Desk of another Monitor if it landed on none.
    public mutating func dropped(_ w: WindowID, atX x: Double, y: Double) {
        guard let n = desk(of: w), desks[n]!.tree?.contains(w) == true,
              let m = monitors.first(where: { $0.frame.contains(x, y) }), let k = active[m.id], let d = desks[k] else { return }
        if d.layout == .dwindle, let t = tiles(d).first(where: { $0.key != w && $0.value.contains(x, y) })?.key {
            desks[n]!.tree = desks[n]!.tree!.swapping(w, t)
            guard k != n else { return }
            desks[k]!.tree = desks[k]!.tree!.swapping(w, t)
            desks[n]!.history = desks[n]!.history.map { $0 == w ? t : $0 }
            desks[k]!.history = desks[k]!.history.map { $0 == t ? w : $0 }
            desks[n]!.fullscreen = nil
        } else if k != n {
            transfer(w, from: n, to: k)
        } else {
            return
        }
        touch(w, on: k)
        show(k)
    }

    /// The Window got focus from the mouse or from outside (Cmd+Tab, Dock). On a hidden Desk this is Follow.
    public mutating func focus(window w: WindowID) {
        guard let n = desk(of: w) else { return }
        touch(w, on: n)
        show(n)
    }

    /// The cursor entered a Monitor whose Active Desk is empty.
    public mutating func focus(monitor m: MonitorID) {
        if let n = activeDesk(on: m) { show(n) }
    }

    /// New defaults also apply to the Desks that exist now.
    public mutating func setLayouts(_ layouts: [Int: LayoutKind]) {
        self.layouts = layouts
        for (n, kind) in layouts { desks[n]?.layout = kind }
    }

    public mutating func setPins(_ pins: [Int: Int]) {
        self.pins = pins
        setMonitors(monitors)
    }

    public mutating func setMonitors(_ new: [Monitor]) {
        precondition(!new.isEmpty, "tatami needs at least one Monitor")
        let old = monitors
        let focusedBefore = active[focusedMonitor]
        monitors = new.sorted { ($0.frame.x, $0.frame.y) < ($1.frame.x, $1.frame.y) }
        for n in desks.keys { desks[n]!.monitor = place(desks[n]!, number: n, old: old) }
        for m in monitors where active[m.id].flatMap({ desks[$0]?.monitor }) != m.id {
            active[m.id] = deskNumbers.first { desks[$0]!.monitor == m.id } ?? freshDesk(on: m.id)
        }
        if !has(focusedMonitor) { focusedMonitor = focusedBefore.flatMap { desks[$0]?.monitor } ?? monitors[0].id }
        collect()
    }

    // MARK: Commands

    public mutating func apply(_ command: Command) {
        let n = focusedDesk
        switch command {
        case .focus(let dir):
            if let w = focusedWindow, let t = neighbour(of: w, dir, on: n) {
                touch(t, on: n)
            } else if let m = neighbourMonitor(dir) {
                show(active[m]!)
            }
        case .move(let dir):
            guard let w = focusedWindow, let tree = desks[n]!.tree, tree.contains(w) else { return }
            if let t = neighbour(of: w, dir, on: n), tree.contains(t) {
                desks[n]!.tree = tree.swapping(w, t)
            } else if let m = neighbourMonitor(dir) {
                transfer(w, from: n, to: active[m]!)
                show(active[m]!)
            }
        case .desk(let target):
            if Command.deskNumbers.contains(target) { show(target) }
        case .deskLast:
            if let l = lastDesk { show(l) }
        case .send(let target):
            guard let w = focusedWindow, target != n, Command.deskNumbers.contains(target) else { return }
            ensure(target)
            transfer(w, from: n, to: target)
            show(target)
        case .splitToggle:
            if let w = focusedWindow { desks[n]!.tree = desks[n]!.tree?.togglingSplit(of: w) }
        case .layoutToggle:
            desks[n]!.layout = desks[n]!.layout == .dwindle ? .accordion : .dwindle
        case .floatToggle:
            guard let w = focusedWindow else { return }
            let wasFloating = desks[n]!.floating.contains(w)
            detach(w, from: n)
            insert(w, into: n, floating: !wasFloating)
        case .fullscreenToggle:
            guard let w = focusedWindow else { return }
            desks[n]!.fullscreen = desks[n]!.fullscreen == w ? nil : w
        case .exec, .reload:
            break  // the shell's job
        }
    }

    // MARK: Internals

    private func minimum(_ w: WindowID) -> Node.Size {
        mins[w].map { ($0.w + config.gapInner, $0.h + config.gapInner) } ?? (0, 0)
    }

    private func tileArea(_ d: Desk) -> Rect { frame(d.monitor).inset(config.gapOuter - config.gapInner / 2) }

    /// Dwindle tiles of a Desk before the inner gap is cut out of each: they touch, which is what navigation wants.
    private func tiles(_ d: Desk) -> [WindowID: Rect] { d.live?.frames(in: tileArea(d), min: minimum) ?? [:] }

    private func has(_ m: MonitorID) -> Bool { monitors.contains { $0.id == m } }
    private func frame(_ m: MonitorID) -> Rect { monitors.first { $0.id == m }!.frame }

    /// The Monitor a Pin points at; a Pin to a missing Monitor falls back to the nearest number.
    private func pinned(_ n: Int) -> MonitorID? {
        pins[n].map { monitors[min(max($0, 1), monitors.count) - 1].id }
    }

    private func place(_ d: Desk, number n: Int, old: [Monitor]) -> MonitorID {
        if let p = pinned(n) { return p }
        if has(d.home) { return d.home }
        if has(d.monitor) { return d.monitor }
        guard let gone = old.first(where: { $0.id == d.monitor })?.frame else { return monitors[0].id }
        func distance(_ r: Rect) -> Double {
            let dx = r.x + r.w / 2 - gone.x - gone.w / 2, dy = r.y + r.h / 2 - gone.y - gone.h / 2
            return dx * dx + dy * dy
        }
        return monitors.min { distance($0.frame) < distance($1.frame) }!.id
    }

    private mutating func freshDesk(on m: MonitorID) -> Int {
        let free = Command.deskNumbers.first { desks[$0] == nil && (pinned($0) ?? m) == m }
        // ponytail: with all 10 Desks in use elsewhere, take the highest hidden one. Breaks past 10 Monitors.
        let n = free ?? deskNumbers.last { active[desks[$0]!.monitor] != $0 }!
        desks[n, default: Desk(monitor: m, home: m, layout: layouts[n] ?? .dwindle)].monitor = m
        return n
    }

    private mutating func ensure(_ n: Int) {
        guard desks[n] == nil else { return }
        let m = pinned(n) ?? focusedMonitor
        desks[n] = Desk(monitor: m, home: m, layout: layouts[n] ?? .dwindle)
    }

    /// An empty Desk disappears when left.
    private mutating func collect() {
        desks = desks.filter { n, d in
            !d.isEmpty || active[d.monitor] == n || d.tree != nil || ghostFloats.values.contains(n)  // placeholders pending
        }
    }

    /// Make Desk `n` the Active Desk of its Monitor and focus that Monitor.
    private mutating func show(_ n: Int) {
        let from = focusedDesk
        ensure(n)
        let m = desks[n]!.monitor
        active[m] = n
        focusedMonitor = m
        if n != from { lastDesk = from }
        collect()
    }

    private mutating func touch(_ w: WindowID, on n: Int) {
        desks[n]!.history.removeAll { $0 == w }
        desks[n]!.history.insert(w, at: 0)
        if desks[n]!.fullscreen != w { desks[n]!.fullscreen = nil }
    }

    /// Adds `w` to Desk `n` as its most recently focused Window. Tiled: splits the Desk's front Tiled Window
    /// along its longer side and takes the right/bottom half.
    private mutating func insert(_ w: WindowID, into n: Int, floating: Bool) {
        var d = desks[n]!
        if floating {
            d.floating.append(w)
        } else if let tree = d.tree, let target = d.frontTiled {
            let r = tiles(d)[target]!
            d.tree = tree.inserting(w, at: target, r.w >= r.h ? .sideBySide : .stacked)
        } else if let tree = d.tree {
            // Only placeholders so far: keep them, they may still be claimed.
            d.tree = tree.inserting(w, at: tree.leaves[0], .sideBySide)
        } else {
            d.tree = .leaf(w)
        }
        d.history.insert(w, at: 0)
        d.fullscreen = nil
        desks[n] = d
    }

    private mutating func detach(_ w: WindowID, from n: Int) {
        desks[n]!.tree = desks[n]!.tree?.removing(w)
        desks[n]!.floating.removeAll { $0 == w }
        desks[n]!.history.removeAll { $0 == w }
        if desks[n]!.fullscreen == w { desks[n]!.fullscreen = nil }
    }

    private mutating func transfer(_ w: WindowID, from a: Int, to b: Int) {
        let floating = desks[a]!.floating.contains(w)
        detach(w, from: a)
        insert(w, into: b, floating: floating)
    }

    /// The Tiled Window next to `w` on Desk `n`, or nil at the Desk's edge.
    /// The Window `focus <dir>` goes to from `w` on Desk `n`, or nil at the Desk's edge.
    /// Tiled Windows go to the Tiled Window next to them; a Floating Window in that direction wins if its
    /// centre is closer. From a Floating Window everything is judged by centres.
    ///
    /// An Accordion has no geometry to go by (its Windows all cover the Monitor), so its two axes are told apart:
    /// along the stack is the Tiled Windows, across it the Floating ones.
    private func neighbour(of w: WindowID, _ dir: Direction, on n: Int) -> WindowID? {
        let d = desks[n]!
        if d.layout == .accordion {
            let area = frame(d.monitor)
            let along: [Direction] = area.w >= area.h ? [.left, .right] : [.up, .down]
            let step = [.left, .up].contains(dir) ? -1 : 1
            if let leaves = d.live?.leaves, let i = leaves.firstIndex(of: w) {
                if along.contains(dir) { return leaves.indices.contains(i + step) ? leaves[i + step] : nil }
                return d.history.first(where: d.floating.contains)  // the Floating Window used last
            }
            // From a Floating Window: along the stack goes back to the front Tiled Window; across it, to the next
            // Floating Window, and past the last one to the Tiled Window again.
            guard !along.contains(dir), let i = d.floating.firstIndex(of: w), d.floating.indices.contains(i + step) else { return d.frontTiled }
            return d.floating[i + step]
        }
        var frames = tiles(d)
        for f in d.floating { frames[f] = floatFrames[f] }

        var tiled: WindowID?
        if let tree = d.live, tree.contains(w) {
            tiled = nearest(from: frames[w]!, dir, d.history.filter { $0 != w && tree.contains($0) }.map { ($0, frames[$0]!) })
        }
        // A Floating Window whose frame is not known yet cannot be judged: fall back to the front Tiled Window.
        guard let from = frames[w] else { return d.frontTiled }

        /// How far `r`'s centre lies in `dir` from ours, sideways drift counted double; nil if it is not that way.
        func distance(_ r: Rect) -> Double? {
            let dx = r.x + r.w / 2 - from.x - from.w / 2, dy = r.y + r.h / 2 - from.y - from.h / 2
            let (along, across): (Double, Double)
            switch dir {
            case .left: (along, across) = (-dx, dy)
            case .right: (along, across) = (dx, dy)
            case .up: (along, across) = (-dy, dx)
            case .down: (along, across) = (dy, dx)
            }
            return along > 1 ? along + 2 * abs(across) : nil
        }
        // From a Tiled Window only Floating Windows compete with the tiled neighbour; from a Floating one, all do.
        let rivals = d.tree?.contains(w) == true ? d.floating : d.history
        var best = tiled.map { (id: $0, score: distance(frames[$0]!) ?? .infinity) }
        for other in rivals where other != w && other != tiled {
            guard let r = frames[other], let score = distance(r) else { continue }
            if best == nil || score < best!.score { best = (other, score) }
        }
        // From a Floating Window with nothing that way (it sits centred over the Tiled Windows): the front Tiled
        // Window, so the keyboard can always leave a Floating Window.
        return best?.id ?? (d.floating.contains(w) ? d.frontTiled : nil)
    }

    private func neighbourMonitor(_ dir: Direction) -> MonitorID? {
        nearest(from: frame(focusedMonitor), dir, monitors.filter { $0.id != focusedMonitor }.map { ($0.id, $0.frame) })
    }
}
