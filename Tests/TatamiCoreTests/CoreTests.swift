import XCTest
@testable import TatamiCore

final class CoreTests: XCTestCase {
    let a = Monitor(id: "A", frame: Rect(0, 0, 1000, 600))
    let b = Monitor(id: "B", frame: Rect(1000, 0, 1000, 600))
    let full = Rect(0, 0, 1000, 600)

    func world(_ monitors: [Monitor]? = nil, pins: [Int: Int] = [:]) -> World {
        World(monitors: monitors ?? [a], config: Config(gapInner: 0, gapOuter: 0, accordionPeek: 50), pins: pins)
    }

    /// 1 on the left half, 2 top right, 3 bottom right; 3 focused.
    func three() -> World {
        var w = world()
        w.open(1); w.open(2); w.open(3)
        return w
    }

    // MARK: Dwindle

    func testDwindleSplitsFocusedWindowAlongLongerSide() {
        var w = world()
        w.open(1)
        XCTAssertEqual(w.layout.frames, [1: full])
        w.open(2)
        XCTAssertEqual(w.layout.frames, [1: Rect(0, 0, 500, 600), 2: Rect(500, 0, 500, 600)])
        XCTAssertEqual(w.focusedWindow, 2)
        w.open(3)  // 2 is taller than wide, so 3 takes its bottom half
        XCTAssertEqual(w.layout.frames, [1: Rect(0, 0, 500, 600), 2: Rect(500, 0, 500, 300), 3: Rect(500, 300, 500, 300)])
        XCTAssertEqual(w.layout.focused, 3)
    }

    func testGaps() {
        var w = World(monitors: [a], config: Config(gapInner: 16, gapOuter: 8))
        w.open(1)
        XCTAssertEqual(w.layout.frames, [1: Rect(8, 8, 984, 584)])
        w.open(2)
        XCTAssertEqual(w.layout.frames, [1: Rect(8, 8, 484, 584), 2: Rect(508, 8, 484, 584)])
    }

    func testCloseFocusesMostRecentWindowOnSameDesk() {
        var w = three()
        w.focus(window: 1)
        w.focus(window: 3)
        w.close(3)
        XCTAssertEqual(w.focusedWindow, 1)
        XCTAssertEqual(w.layout.frames, [1: Rect(0, 0, 500, 600), 2: Rect(500, 0, 500, 600)])
        w.close(1); w.close(2)
        XCTAssertNil(w.focusedWindow)
        XCTAssertEqual(w.focusedDesk, 1)
    }

    func testSplitToggle() {
        var w = world()
        w.open(1); w.open(2)
        w.apply(.splitToggle)
        XCTAssertEqual(w.layout.frames, [1: Rect(0, 0, 1000, 300), 2: Rect(0, 300, 1000, 300)])
    }

    // MARK: Focus and move

    func testFocusDirection() {
        var w = three()
        w.apply(.focus(.left))
        XCTAssertEqual(w.focusedWindow, 1)
        w.apply(.focus(.right))  // 2 and 3 both touch 1; the more recently focused wins
        XCTAssertEqual(w.focusedWindow, 3)
        w.apply(.focus(.up))
        XCTAssertEqual(w.focusedWindow, 2)
        w.apply(.focus(.up))  // edge, no Monitor above
        XCTAssertEqual(w.focusedWindow, 2)
    }

    func testFocusCrossesToNeighbouringMonitor() {
        var w = world([a, b])
        w.open(1)
        w.apply(.focus(.right))
        XCTAssertEqual(w.focusedMonitor, "B")
        XCTAssertNil(w.focusedWindow)
        w.open(2)  // new Windows open on the focused Monitor's Active Desk
        XCTAssertEqual(w.layout.frames, [1: full, 2: Rect(1000, 0, 1000, 600)])
        w.apply(.focus(.left))
        XCTAssertEqual(w.focusedWindow, 1)
    }

    func testMoveSwapsWithNeighbour() {
        var w = three()
        w.apply(.move(.left))
        XCTAssertEqual(w.layout.frames, [3: Rect(0, 0, 500, 600), 2: Rect(500, 0, 500, 300), 1: Rect(500, 300, 500, 300)])
        XCTAssertEqual(w.focusedWindow, 3)
    }

    func testMoveCrossesToNeighbouringMonitor() {
        var w = world([a, b])
        w.open(1); w.open(2)
        w.apply(.move(.right))
        XCTAssertEqual(w.layout.frames, [1: full, 2: Rect(1000, 0, 1000, 600)])
        XCTAssertEqual(w.focusedMonitor, "B")
        XCTAssertEqual(w.focusedWindow, 2)
    }

    func testFollow() {
        var w = world()
        w.open(1)
        w.apply(.desk(2))
        w.open(2)
        w.focus(window: 1)
        XCTAssertEqual(w.focusedDesk, 1)
        XCTAssertEqual(w.layout.hidden, [2])
    }

    // MARK: Desks

    func testDeskSwitchHidesWindowsAndEmptyDeskDisappears() {
        var w = world()
        w.open(1)
        w.apply(.desk(2))
        XCTAssertEqual(w.layout.hidden, [1])
        XCTAssertEqual(w.layout.frames, [:])
        XCTAssertNil(w.focusedWindow)
        XCTAssertEqual(w.deskNumbers, [1, 2])
        w.apply(.desk(1))
        XCTAssertEqual(w.deskNumbers, [1])
        XCTAssertEqual(w.focusedWindow, 1)
        w.apply(.desk(1))  // current Desk: no-op, must not disturb back-and-forth
        w.apply(.deskLast)
        XCTAssertEqual(w.focusedDesk, 2)
        w.apply(.deskLast)
        XCTAssertEqual(w.focusedDesk, 1)
    }

    func testDeskOnAnotherMonitorJumpsThere() {
        var w = world([a, b])
        XCTAssertEqual([w.activeDesk(on: "A"), w.activeDesk(on: "B")], [1, 2])
        w.apply(.desk(2))
        XCTAssertEqual(w.focusedMonitor, "B")
        XCTAssertEqual(w.activeDesk(on: "A"), 1)
        w.apply(.desk(3))  // new Desk lives on the Monitor where it was first opened
        XCTAssertEqual(w.activeDesk(on: "B"), 3)
        XCTAssertEqual(w.deskNumbers, [1, 3])
        w.focus(monitor: "A")
        XCTAssertEqual(w.focusedDesk, 1)
        w.apply(.desk(3))
        XCTAssertEqual(w.focusedMonitor, "B")
    }

    func testSendMovesWindowAndSwitches() {
        var w = world()
        w.open(1); w.open(2)
        w.apply(.send(4))
        XCTAssertEqual(w.focusedDesk, 4)
        XCTAssertEqual(w.focusedWindow, 2)
        XCTAssertEqual(w.layout.frames, [2: full])
        XCTAssertEqual(w.layout.hidden, [1])
    }

    func testClosingWindowOnHiddenDeskNeverJumpsDesk() {
        var w = world()
        w.open(1)
        w.apply(.desk(2))
        w.open(2)
        w.close(1)
        XCTAssertEqual(w.focusedDesk, 2)
        XCTAssertEqual(w.deskNumbers, [2])
    }

    func testRuleOpensWindowOnItsDeskWithoutSwitching() {
        var w = world()
        w.open(7, desk: 3)
        XCTAssertEqual(w.focusedDesk, 1)
        XCTAssertEqual(w.layout.hidden, [7])
        XCTAssertEqual(w.desk(of: 7), 3)
    }

    // MARK: Accordion, Floating, Fullscreen

    func testAccordion() {
        var w = three()
        w.apply(.layoutToggle)
        XCTAssertEqual(w.layout.frames, [1: Rect(0, 0, 900, 600), 2: Rect(50, 0, 900, 600), 3: Rect(100, 0, 900, 600)])
        XCTAssertEqual(w.layout.front, [3])
        w.apply(.focus(.left))
        XCTAssertEqual(w.layout.front, [2])
        w.apply(.focus(.left)); w.apply(.focus(.left))
        XCTAssertEqual(w.focusedWindow, 1)
        w.apply(.move(.right))
        XCTAssertEqual(w.layout.frames[1], Rect(50, 0, 900, 600))
        w.apply(.layoutToggle)  // back to Dwindle, nothing lost
        XCTAssertEqual(w.layout.frames.count, 3)
        XCTAssertEqual(w.layout.front, [])
    }

    func testFloatToggle() {
        var w = world()
        w.open(1); w.open(2)
        w.apply(.floatToggle)
        XCTAssertEqual(w.layout.frames, [1: full])
        XCTAssertEqual(w.layout.floating, [2])
        XCTAssertEqual(w.focusedWindow, 2)
        w.apply(.floatToggle)
        XCTAssertEqual(w.layout.frames[2], Rect(500, 0, 500, 600))
        XCTAssertEqual(w.layout.floating, [])
        w.open(9, floating: true)  // auto-floated dialog: belongs to the Desk, hides with it
        w.apply(.desk(2))
        XCTAssertEqual(w.layout.hidden, [1, 2, 9])
    }

    func testFullscreen() {
        var w = World(monitors: [a])
        w.open(1); w.open(2)
        w.apply(.fullscreenToggle)
        XCTAssertEqual(w.layout.frames[2], full)  // fills the Monitor, no gaps
        XCTAssertEqual(w.layout.fullscreen, [2])
        w.apply(.fullscreenToggle)
        XCTAssertEqual(w.layout.fullscreen, [])
        w.apply(.fullscreenToggle)
        w.apply(.focus(.left))  // focusing another Window ends Fullscreen
        XCTAssertEqual(w.layout.fullscreen, [])
    }

    // MARK: Monitors and Pins

    func testMonitorsAreNumberedByPosition() {
        let w = world([b, a])
        XCTAssertEqual(w.monitors.map(\.id), ["A", "B"])
        XCTAssertEqual(w.focusedMonitor, "A")
    }

    func testDesksMigrateOnDisconnectAndReturnOnReconnect() {
        var w = world([a, b])
        w.open(1)
        w.focus(monitor: "B")
        w.open(2)
        w.setMonitors([a])
        XCTAssertEqual(w.focusedMonitor, "A")
        XCTAssertEqual(w.layout.hidden, [2])
        w.apply(.desk(2))  // reachable on the remaining Monitor
        XCTAssertEqual(w.layout.frames, [2: full])
        w.setMonitors([a, b])
        XCTAssertEqual(w.activeDesk(on: "B"), 2)
        XCTAssertEqual(w.layout.frames[2], Rect(1000, 0, 1000, 600))
        XCTAssertEqual(w.activeDesk(on: "A"), 1)
    }

    func testPin() {
        var w = world([a, b], pins: [5: 2])
        w.apply(.desk(5))
        XCTAssertEqual(w.focusedMonitor, "B")
        XCTAssertEqual(w.activeDesk(on: "B"), 5)

        var single = world(pins: [5: 2])  // Pin to a missing Monitor falls back to the nearest
        single.apply(.desk(5))
        XCTAssertEqual(single.activeDesk(on: "A"), 5)
    }

    // MARK: Commands

    func testCommandParsing() {
        XCTAssertEqual(Command("focus left"), .focus(.left))
        XCTAssertEqual(Command("  move   down "), .move(.down))
        XCTAssertEqual(Command("desk 10"), .desk(10))
        XCTAssertEqual(Command("desk last"), .deskLast)
        XCTAssertEqual(Command("send 3"), .send(3))
        XCTAssertEqual(Command("split toggle"), .splitToggle)
        XCTAssertEqual(Command("layout toggle"), .layoutToggle)
        XCTAssertEqual(Command("float toggle"), .floatToggle)
        XCTAssertEqual(Command("fullscreen toggle"), .fullscreenToggle)
        XCTAssertEqual(Command("exec open -a Ghostty"), .exec("open -a Ghostty"))
        XCTAssertEqual(Command("reload"), .reload)
        for bad in ["", "desk 0", "desk 11", "focus", "focus north", "exec", "reload now", "dance"] {
            XCTAssertNil(Command(bad), bad)
        }
    }

    // MARK: Minimum size, mouse, native fullscreen

    func testMinimumSizeGrowsTileAndShrinksSibling() {
        var w = world()
        w.open(1); w.open(2)
        w.setMinimumSize(2, width: 700, height: 100)
        XCTAssertEqual(w.layout.frames, [1: Rect(0, 0, 300, 600), 2: Rect(300, 0, 700, 600)])
    }

    func testWindowThatCannotFitFloats() {
        var w = world()
        w.open(1); w.open(2)
        w.setMinimumSize(1, width: 600, height: 100)
        w.setMinimumSize(2, width: 600, height: 100)  // 1200 > 1000
        XCTAssertEqual(w.layout.floating, [2])
        XCTAssertEqual(w.layout.frames, [1: full])
        XCTAssertEqual(w.focusedWindow, 2)
    }

    func testMouseResizeUpdatesSplitRatio() {
        var w = three()
        w.resized(3, from: Rect(500, 300, 500, 300), to: Rect(400, 200, 600, 400))  // dragged its top-left corner
        XCTAssertEqual(w.layout.frames, [1: Rect(0, 0, 400, 600), 2: Rect(400, 0, 600, 200), 3: Rect(400, 200, 600, 400)])
    }

    func testMouseResizeIgnoresWindowSmallerThanItsTile() {
        var w = three()
        // A terminal that rounds to whole cells sits 10 px short of its tile; only its left edge was dragged.
        w.resized(3, from: Rect(500, 300, 490, 290), to: Rect(400, 300, 590, 290))
        XCTAssertEqual(w.layout.frames, [1: Rect(0, 0, 400, 600), 2: Rect(400, 0, 600, 300), 3: Rect(400, 300, 600, 300)])
    }

    func testKeyboardFocusReachesFloatingWindows() {
        var w = world()
        w.open(1); w.open(2)
        w.open(9, floating: true)
        w.observed(9, at: Rect(300, 150, 400, 300))  // centred, over both tiles
        XCTAssertEqual(w.focusedWindow, 9)
        w.apply(.focus(.right))
        XCTAssertEqual(w.focusedWindow, 2)
        w.apply(.focus(.left))  // the Floating Window's centre is closer than Window 1's
        XCTAssertEqual(w.focusedWindow, 9)
        w.apply(.focus(.left))
        XCTAssertEqual(w.focusedWindow, 1)
        w.apply(.focus(.right))
        XCTAssertEqual(w.focusedWindow, 9)
    }

    func testMouseDropSwaps() {
        var w = three()
        w.dropped(3, atX: 100, y: 100)
        XCTAssertEqual(w.layout.frames[3], Rect(0, 0, 500, 600))
        XCTAssertEqual(w.layout.frames[1], Rect(500, 300, 500, 300))
    }

    func testMouseDropOnAnotherMonitor() {
        var w = world([a, b])
        w.open(1); w.open(2)
        w.dropped(2, atX: 1500, y: 300)  // empty Desk there: joins it
        XCTAssertEqual(w.layout.frames, [1: full, 2: Rect(1000, 0, 1000, 600)])
        XCTAssertEqual(w.focusedMonitor, "B")
        w.dropped(2, atX: 100, y: 100)  // onto 1: they trade Desks
        XCTAssertEqual(w.layout.frames, [2: full, 1: Rect(1000, 0, 1000, 600)])
        XCTAssertEqual(w.focusedWindow, 2)
    }

    func testNativeFullscreenKeepsTile() {
        var w = world()
        w.open(1); w.open(2)
        w.setNativeFullscreen(2, true)
        XCTAssertEqual(w.layout.frames, [1: Rect(0, 0, 500, 600)])
        w.setNativeFullscreen(2, false)
        XCTAssertEqual(w.layout.frames[2], Rect(500, 0, 500, 600))
    }

    // MARK: Saving and restoring

    func testRestoreBringsBackTheSameArrangement() throws {
        var w = world([a, b])
        w.open(1); w.open(2); w.open(3)  // Desk 1 on A
        w.resized(3, from: Rect(500, 300, 500, 300), to: Rect(400, 200, 600, 400))
        w.open(9, floating: true)
        w.apply(.desk(4)); w.open(5); w.open(6)
        w.apply(.layoutToggle)
        w.apply(.desk(2)); w.open(7)  // Desk 2 on B
        w.apply(.desk(4))
        let before = w.layout
        let saved = try JSONDecoder().decode(World.Snapshot.self, from: JSONEncoder().encode(w.snapshot))

        // After a reboot the same Windows come back with new ids, in another order.
        var r = World(monitors: [a, b], config: w.config, restoring: saved)
        XCTAssertEqual(r.layout.frames, [:])
        XCTAssertTrue(r.hasPlaceholders)
        for (old, new) in [(7, 107), (3, 103), (6, 106), (1, 101), (9, 109), (5, 105), (2, 102)] as [(WindowID, WindowID)] {
            XCTAssertTrue(r.adopt(old, as: new))
        }
        XCTAssertFalse(r.hasPlaceholders)
        let after = r.layout
        XCTAssertEqual(after.frames, Dictionary(uniqueKeysWithValues: before.frames.map { ($0.key + 100, $0.value) }))
        XCTAssertEqual(after.hidden, Set(before.hidden.map { $0 + 100 }))
        XCTAssertEqual(after.floating, Set(before.floating.map { $0 + 100 }))
        XCTAssertEqual(after.focused, before.focused.map { $0 + 100 })
        XCTAssertEqual(r.focusedDesk, 4)
        XCTAssertEqual(r.layoutKind(ofDesk: 4), .accordion)
        r.apply(.deskLast)
        XCTAssertEqual(r.focusedDesk, 2)
    }

    func testPlaceholdersTakeNoRoomAndExpire() {
        var w = world()
        w.open(1); w.open(2); w.open(3)
        var r = World(monitors: [a], config: w.config, restoring: w.snapshot)
        XCTAssertTrue(r.adopt(1, as: 11))
        XCTAssertEqual(r.layout.frames, [11: full])  // alone for now
        XCTAssertTrue(r.adopt(3, as: 13))
        XCTAssertEqual(r.layout.frames, [11: Rect(0, 0, 500, 600), 13: Rect(500, 0, 500, 600)])
        XCTAssertFalse(r.adopt(8, as: 18))  // not part of the saved arrangement
        r.open(20)  // a new Window meanwhile is fine
        XCTAssertEqual(r.layout.frames.count, 3)
        r.dropPlaceholders()  // 2 never came back
        XCTAssertFalse(r.hasPlaceholders)
        XCTAssertEqual(r.layout.frames.count, 3)
        r.close(13); r.close(20)
        XCTAssertEqual(r.layout.frames, [11: full])
    }

    func testDeskOfAwaitedWindowsSurvivesBeingEmpty() {
        var w = world()
        w.apply(.desk(3)); w.open(1)
        w.apply(.desk(1))
        var r = World(monitors: [a], config: w.config, restoring: w.snapshot)
        XCTAssertEqual(r.deskNumbers, [1, 3])  // Desk 3 has no Window yet but one is awaited
        XCTAssertTrue(r.adopt(1, as: 50))
        XCTAssertEqual(r.layout.hidden, [50])
        XCTAssertEqual(r.focusedDesk, 1)
    }

    // MARK: Config file

    func testConfigFile() throws {
        let c = try ConfigFile(parsing: """
        # comment
        gap.inner = 16
        gap.outer = 8

        border.width    = 8
        border.active   = #ff2d78
        focus.follows_mouse = false
        pin 2 = monitor 2
        pin 1, 3,5 = monitor 1
        bind alt+shift+h = move left
        bind alt+enter   = exec open -a Ghostty
        rule Ghostty = desk 1
        rule "System Settings" = float
        """)
        XCTAssertEqual(c.layout.gapInner, 16)
        XCTAssertEqual(c.borderWidth, 8)
        XCTAssertEqual(c.borderActive, 0xff2d78ff)
        XCTAssertFalse(c.focusFollowsMouse)
        XCTAssertEqual(c.pins, [2: 2, 1: 1, 3: 1, 5: 1])
        XCTAssertEqual(c.binds.map(\.keys), ["alt+shift+h", "alt+enter"])
        XCTAssertEqual(c.binds[1].command, .exec("open -a Ghostty"))
        XCTAssertEqual(c.binds[1].line, 11)
        XCTAssertEqual(c.rules, [.init(app: "Ghostty", action: .desk(1)), .init(app: "System Settings", action: .float)])
    }

    func testConfigFileReportsLineOfError() {
        for (text, line) in [("gap.inner = 4\nbind alt+x = dance", 2), ("nonsense", 1), ("\n\ngap.inner = wide", 3),
                             ("pin 11 = monitor 1", 1), ("pin 1,x = monitor 1", 1), ("rule X = send 2", 1), ("colour = red", 1)] {
            XCTAssertThrowsError(try ConfigFile(parsing: text), text) {
                XCTAssertEqual(($0 as? ConfigFile.ParseError)?.line, line, text)
            }
        }
    }

    func testUserConfigOverridesBuiltin() throws {
        let c = try ConfigFile.user("""
        gap.inner = 20
        bind shift+alt+h = desk 9
        unbind alt+comma
        bind cmd+k = layout toggle
        layout 5, 7 = accordion
        """)
        XCTAssertEqual(c.layout.gapInner, 20)
        XCTAssertEqual(c.layout.gapOuter, 8)  // untouched default
        XCTAssertEqual(c.binds.filter { $0.keys.split(separator: "+").contains("h") }.map(\.command), [.focus(.left), .desk(9)])
        XCTAssertFalse(c.binds.contains { $0.keys == "alt+comma" })
        XCTAssertTrue(c.binds.contains { $0.keys == "cmd+k" && $0.command == .layoutToggle })
        XCTAssertEqual(c.binds.count, ConfigFile.builtin.binds.count)  // one replaced, one removed, one added
        XCTAssertEqual(c.layouts, [5: .accordion, 7: .accordion])
        XCTAssertThrowsError(try ConfigFile.user("unbind alt+z"))
        XCTAssertThrowsError(try ConfigFile.user("layout 5 = stack"))
    }

    func testDefaultLayoutPerDesk() {
        var w = World(monitors: [a], layouts: [3: .accordion])
        w.apply(.desk(3))
        XCTAssertEqual(w.layoutKind(ofDesk: 3), .accordion)
        w.apply(.desk(1))  // Desk 3 was empty: it disappears, and comes back as Accordion
        w.apply(.desk(3))
        XCTAssertEqual(w.layoutKind(ofDesk: 3), .accordion)
        w.setLayouts([1: .accordion])
        w.apply(.desk(1))
        XCTAssertEqual(w.layoutKind(ofDesk: 1), .accordion)
    }

    func testBuiltinConfig() {
        XCTAssertEqual(ConfigFile.builtin.binds.count, 33)
        XCTAssertTrue(ConfigFile.builtin.binds.contains { $0.keys == "alt+0" && $0.command == .desk(10) })
    }
}
