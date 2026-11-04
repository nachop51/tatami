# tatami — design

Status: planning agreed 2026-11-16. Phases 0–4 done: core in `Sources/TatamiCore` (`swift test`), shell in `Sources/tatami` (`swift build`, then `.build/debug/tatami start`). Phase 5 (dogfood) in progress since 2026-11-13.
Terms in **bold** are defined in [CONTEXT.md](../CONTEXT.md).

## Goal

A tiling window manager for macOS with the Hyprland experience, replacing
AeroSpace and JankyBorders. Brand new project: not a fork, not a port.

Success is measured against the three AeroSpace problems that motivated it:

| Problem | Criterion |
|---|---|
| Lag and freezes | Desk switch and focus moves feel instant. One unresponsive app never stalls tatami. |
| Focus glitches | tatami's focus model is the single source of truth. Closing a Window never jumps Desk. |
| Bad tiling | Dialogs, popups and fixed-size windows float automatically. No overlaps or gaps when an app refuses a size. |

## Constraints

- System Integrity Protection stays enabled.
- Private (undocumented) macOS APIs allowed only where the spike proves the
  public API falls short, isolated in one module.
- No animations.
- Swift, no third-party dependencies.
- Personal tool: no code signing for distribution, no installer.
- Any number of Monitors, 1 to N.

## Behaviour decisions

### Desks and Monitors
- Monitors are numbered by position: left to right, then top to bottom.
- Desks are created on demand, numbered 1–10. An empty Desk disappears when left.
- A Desk lives on the Monitor where it was first opened, unless a **Pin** says
  otherwise. A Pin to a missing Monitor falls back to the nearest existing one.
- When a Monitor disconnects, its Desks migrate to a remaining Monitor and
  return when it reconnects.
- `desk N` for a Desk on another Monitor shows it there; focus and cursor jump
  to it. `desk N` for the current Desk is a no-op. `desk last` is back-and-forth.
- **Send** moves the focused Window to a Desk and switches to it.

### Layouts
- Each Desk has one **Layout**: **Dwindle** (default) or **Accordion**, toggled per Desk.
- Dwindle: new Window splits the focused Window along its longer side, takes
  the right/bottom half, and gets focus. `split toggle` flips a split.
- Mouse drag-resize of a Tiled Window updates the split ratio. Mouse drag-move
  swaps it with the Window under the drop point.
- `focus <dir>` / `move <dir>` at a Monitor edge cross to the neighbouring
  Monitor's Active Desk.
- **Fullscreen** toggle fills the Monitor inside the Desk. A Window in macOS
  native fullscreen is unmanaged until it exits, then returns to its tile.

### Floating
- Floating Windows are part of v1: auto-floated (dialogs, popups, windows that
  cannot be resized), by Rule, or by `float toggle`.
- They belong to their Desk and hide with it. Auto-floated dialogs stay where
  the app put them.
- A Window whose minimum size exceeds its tile gets a bigger tile (sibling
  shrinks); if it cannot fit at all it floats.
- Picture-in-picture and similar system overlays are never managed.
- Not in v1: "sticky" Windows visible on every Desk.

### Focus
- Focus follows mouse, without raising. Clicking raises.
- Moving the cursor to a Monitor with an empty Desk focuses that Monitor.
- Every keyboard focus change warps the cursor to the target Window's centre,
  unless the cursor is already inside it.
- After a Window closes, focus goes to the most recently focused Window on the
  same Desk. On an empty Desk nothing is focused.
- **Follow**: activating a Window on a hidden Desk (Cmd+Tab, Dock) switches to that Desk.

### Windows appearing and disappearing
- New Windows open on the focused Monitor's Active Desk unless a Rule applies.
- **Hide** is the native macOS app hide: Windows leave the tiling and rejoin
  their Desk when shown.
- At first start, each open Window joins the Active Desk of its Monitor.
  Minimized Windows are ignored until restored.
- On quit, all Windows return on-screen. The Window→Desk mapping is saved and
  restored on next launch, including after a crash.

### Borders (replaces JankyBorders)
- Drawn by tatami on Tiled and Floating Windows; none in Fullscreen.
- Config: width, active colour, inactive colour.

### Config and CLI
- File: `~/.config/tatami/config`. Ghostty-style: one `key = value` per line, `#` comments.
- Reload is on demand only: `tatami reload`. No file watcher. A broken file
  keeps the running config and reports line and error.
- With no file, built-in defaults apply.
- One command vocabulary for CLI and binds. Binds can run shell commands via `exec`.
- Bind keys: letters and digits follow the keyboard layout (`alt+z` is the key labelled Z on AZERTY
  or Dvorak); punctuation and named keys are physical US positions. (Added 2026-11-19.)
- No binding modes. A menu bar item shows each Monitor's Active Desk, left to right (`1 | 4`, focused one bold), with Reload and Stop in its menu. (Added 2026-11-16; the plan first said no menu bar item.)
- Launched by hand with `tatami start`; `tatami stop` restores every Window. `./install.sh` puts a release build in `~/.local/bin` and starts it at login through a LaunchAgent (`dev.tatami`, no KeepAlive); it signs the build with a self-signed certificate named `tatami-dev` when the keychain has one, so the Accessibility grant follows the certificate and survives rebuilds (checked: two different builds started without a new grant); ad-hoc signed, every build needs the grant again.

Sketch:

```
gap.inner = 16
gap.outer = 8

border.width    = 8
border.active   = #ff2d78
border.inactive = #414550

focus.follows_mouse = true

pin 2 = monitor 2
pin 1,3,5 = monitor 1

bind alt+h       = focus left
bind alt+shift+h = move left
bind alt+1       = desk 1
bind alt+cmd+1   = send 1
bind alt+tab     = desk last
bind alt+enter   = exec open -a Ghostty

rule Ghostty = desk 1
rule "System Settings" = float
```

Rules match app name or bundle id, have two actions (`desk N`, `float`), and
apply once when a Window opens.

## Architecture

1. **Pure core** — state + command → desired layout. No macOS calls; unit tested.
2. **Reconciler** — diffs desired against observed frames, applies, verifies,
   retries. A refused size feeds back into the layout.
3. **Per-app Accessibility workers with timeouts** — one hung app cannot block
   the others; a Desk switch runs apps in parallel.
4. **Focus manager** — tatami decides focus; OS focus events are inputs.
5. **Window classifier** — role, subrole and resizability decide tile or float;
   Rules override.
6. **Borders** — click-through overlay windows positioned from the layout.

Hidden Desks park their Windows off-screen (same technique as AeroSpace),
since macOS Spaces cannot be controlled with SIP enabled.

## Phases

| Phase | Content | Estimate |
|---|---|---|
| 0. Spike | Accessibility latency per call; timeout on a hung app; event source (AX observers vs private SkyLight); border ordering and corner radius | 3–4 days |
| 1. Core | Dwindle, Accordion, Desks, Monitors, commands, tests | 1.5 weeks |
| 2. Shell | AX workers, reconciler, parking, hotkeys, config + reload, CLI, state restore | 2.5 weeks |
| 3. Focus and classification | Focus manager, mouse focus, warp, Follow, auto-float, min-size feedback, Rules, Hide, Fullscreen, mouse resize/swap | 2 weeks |
| 4. Borders | Overlay borders | 1 week |
| 5. Dogfood | Daily use in place of AeroSpace | 1–2 months |

First usable build at the end of phase 2 (about 4.5 weeks). Feature complete
at about 8 weeks.

### Spike gate

If a Desk switch with about 10 windows cannot get under roughly 100 ms because
of the Accessibility API itself, stop and rethink the switch mechanism before
phase 1.

## Spike results (2026-11-16, macOS 27.3, SIP on)

Code in `spikes/`.

| Question | Result |
|---|---|
| Border ordering | Public `NSWindow.order(_:relativeTo:)` places an overlay directly below or above another app's window. No private API needed. |
| Corner radius | Private `SLSWindowIteratorGetCornerRadii` returns per-corner radii (16 for System Settings). |
| SkyLight events | Private notifications work: create about 20 ms after the window is shown, move about 8 ms, resize about 12 ms. Close arrives about 270 ms after `close()`. |
| Close lag | Cause: AppKit's window close animation. SkyLight reports hide/close/destroy only when the fade ends (about 270 ms; about 20 ms with `animationBehavior = .none`, which tatami cannot set on other apps). The public AX `kAXUIElementDestroyedNotification` on the window element arrives about 2 ms after `close()`. Use AX for close, SkyLight for the rest. |
| Private symbols | All 34 SkyLight functions checked are present. |
| Accessibility latency | 8 windows across 8 apps (Electron, native, browser). Median per call: get position 0.17 ms, get size 0.06 ms, set position 0.6 ms (p95 11, max 23), set size 10.7 ms (p95 81, max 399). Listing an app's windows: 15–45 ms. |
| Desk switch (park) | Move all 8 windows to a corner, 5 runs: serial median 24 ms, max 40 ms; move back: median 41 ms, max 52 ms. Parallel per app is no faster (31 / 39 ms median). All windows returned to their exact position. **Gate passed**: hide 8 + show 8 worst case is about 92 ms, and a real switch only sets positions. |
| Hung-app timeout | `AXUIElementSetMessagingTimeout` bounds calls exactly (0.05 s → 51 ms, 0.1 s → 104 ms, 0.25 s → 253 ms), returning `kAXErrorCannotComplete`. It is per element: set on the app element it does not cover that app's window elements, which fell back to a 1.5 s default. Set on the system-wide element it becomes the process default for every element. Calls to another app from a second thread stayed at 0.3 ms median, 0.5 ms max while a call to the stopped app was blocked. The app answers normally after `SIGCONT`. |

## Phase 1 choices (confirmed 2026-11-16)

Made while writing the core, where the decisions above were silent:

- Command names: `layout toggle`, `fullscreen toggle` (next to `split toggle`, `float toggle`).
- `focus <dir>` picks the nearest Tiled Window in that direction; ties go to the most recently focused.
- `move <dir>` swaps with that neighbour. A Floating Window ignores `move`.
- `focus <dir>` reaches Floating Windows too: one lying in that direction wins over the tiled neighbour if its centre is closer; from a Floating Window every Window is judged by centre. (Changed 2026-11-16 after dogfooding: Floating Windows were unreachable by keyboard.)
- Fullscreen ends when another Window on the Desk gets focus or a Window opens there.
- Accordion runs along the Monitor's longer side; `accordionPeek` defaults to 32. Default gaps 8 / 8.
- A Rule's `desk N` opens the Window there without switching Desk.
- A Desk migrated from a disconnected Monitor arrives hidden; the focused Monitor falls back to where it went.
- A Pin to a missing Monitor uses the nearest Monitor number.
- Not in the core yet (phase 3): mouse resize and swap, minimum-size feedback, Hide, native fullscreen.

## Phase 2 notes (2026-11-16)

- Events come from public AX observers (window created, destroyed, minimized, focus changed) plus
  `NSWorkspace` launch and terminate. SkyLight notifications are not used yet: nothing so far needs them.
- One private call: `_AXUIElementGetWindow`, to get a window id that survives a restart (state restore).
- CLI talks to the running tatami over a `CFMessagePort`; hotkeys use Carbon `RegisterEventHotKey`.
- Built-in binds with no config file: `alt+hjkl` focus, `alt+shift+hjkl` move, `alt+1…0` desk,
  `alt+cmd+1…0` send (was `alt+ctrl+1…0` until 2026-11-19), `alt+tab` desk last, `alt+f` fullscreen, `alt+t` float, `alt+e` split, `alt+comma` layout.
- State file: `~/Library/Application Support/tatami/state.json`.
- Live test, 8 windows on 2 Monitors: tiling, Desk switch (park and return), reload, bad command, stop
  from a hidden Desk, and restart after `kill -9` all behave. CLI round trip 11–13 ms.
- Seen in the test, due in phase 3: windows with a large minimum size (Spotify, App Store) overlap their
  neighbours; an empty Desk leaves macOS focus on a parked Window; only standard windows are managed,
  dialogs are ignored rather than floated.
- Not exercised: hotkeys by real key press, Monitor disconnect on real hardware, a hung app against the full shell.

## Phase 3 notes (2026-11-16)

- Classifier: standard resizable windows tile; dialogs, panels and windows that cannot be resized float;
  anything else, and any window not in the window server's on-screen list, is not managed.
- Minimum size: a refused resize (still too big 100 ms later) is recorded as the Window's minimum and its
  tile grows. A Window the Desk cannot fit floats, centred at 60 % × 70 % of the Monitor. Which Window
  floats depends on which one reports last.
- Focus follows mouse uses private `_SLPSSetFrontProcessWithOptions` and `SLPSPostEventRecordTo`
  (in `Private.swift`): the public API can only focus by raising. Verified on macOS 27.3: focus moves,
  stacking order does not.
- Keyboard focus raises and warps the cursor. An empty Desk makes tatami itself the active app, so keys go nowhere.
- Follow guard: for 0.5 s after a Window closes, focus landing on a Window of a hidden Desk is treated as
  macOS's choice and undone, so closing never jumps Desk.
- Hide and minimize: the Window leaves its Desk and rejoins the same Desk when shown.
- Mouse: on mouse-up, a resized Tiled Window moves its splits (measured against where it was when the mouse went down, since an app may sit smaller or bigger than its tile); a moved one swaps with the Tiled Window
  under the cursor, or joins another Monitor's Active Desk when dropped on none (choice, not in the decisions above).
- Startup does not take focus: Windows found at start join without focus until macOS reports the focused one.
- A timed-out app (0.5 s) is skipped for 2 s, then its pending placements are retried.
- Focus that tatami did not ask for (app switcher, launcher shortcut, Dock) also warps the cursor into the Window. Not while the mouse is in use (moved within 0.7 s): an app that answers a hover by focusing another of its windows would otherwise pull the cursor away. When that happens it is logged with the app's name.
- `tatami state` prints Desks, Tiled and Floating Windows and learnt minimums.
- Live test, 8 windows on 2 Monitors: startup keeps focus; minimum sizes give a clean tiling with 2–3 of
  6 big-minimum windows floating on one Monitor; focus follows mouse without raise; keyboard focus and warp;
  empty Desk; Hide and unhide; Send.
- Not exercised live: mouse resize and swap, native fullscreen, focus without raise between two windows
  of one app, the Follow guard, dialogs. Windows on other macOS Spaces are not discovered.

## Phase 4 notes (2026-11-16)

- Borders: one click-through overlay window per Tiled or Floating Window on an Active Desk, ordered
  directly below it with public `NSWindow.order(_:relativeTo:)`, drawing a ring just outside its frame.
  None for Fullscreen, native fullscreen or parked Windows. Corner radius from private
  `SLSWindowIteratorGetCornerRadii` (in `Private.swift`).
- Borders follow the frames the workers report (after each placement and on every AX move or resize
  notification), so a dragged Floating Window's border trails it slightly.
- `tatami start` now returns once tatami is up in the background, logging to `~/Library/Logs/tatami.log`.
  `tatami run` stays in the foreground. Closing the terminal no longer stops it.
- Fixed: Monitor frames were read before `NSApplication` existed, so the menu bar on the secondary
  Monitor was missed and windows there were pushed 22 px down into their neighbours.
- Live test: every window has its overlay directly below it, 4 px outside its frame; a Desk switch
  removes and restores them; none remain after stop. Colours and corner fit were not checked by eye
  (no screen capture permission).

## Config changes after dogfooding (2026-11-16)

- The built-in defaults (gaps, border, every bind) always apply; `~/.config/tatami/config` only holds
  what differs. A `bind` replaces the default on the same keys, `unbind <keys>` removes one,
  `tatami defaults` prints the built-in config.
- `layout <desks> = dwindle | accordion` sets the Layout a Desk starts with (and gets back when it
  reappears after being empty). `pin` and `layout` take comma lists: `pin 1,3,5 = monitor 1`.
- Gaps are measured between borders: the layout adds the border width, so `gap.inner = 8` with a
  4 px border leaves 8 px of desktop visible between two borders (before, the borders filled the gap).
- At start the focused Monitor is the one under the cursor.

## Saved arrangement (2026-11-16)

- `state.json` holds the whole arrangement: every Desk's split tree with ratios, Layout, Floating Windows,
  focus order, each Monitor's Active Desk, the last Desk, and for every Window its id, app and title.
  Written within a second of a change and on stop.
- At start the Desks come back with a placeholder per Window. A placeholder takes no room; a Window that
  shows up claims its own: by id while the Mac stayed on, and after a reboot (new ids) by app and title,
  else the app's next unclaimed one. It then sits exactly where it was.
- Windows get 120 s to come back (apps reopening after login); after that the remaining placeholders are
  dropped and a late Window opens like any new one. Nothing is saved while placeholders are pending, so an
  early stop cannot lose the saved arrangement.
- Not restored: Fullscreen, learnt minimum sizes (relearnt), Floating Window positions (apps restore their own).
- Checked: unit tests remap ids as a reboot would; e2e stops and restarts tatami and compares frames; on the
  real desktop a stop/start left `tatami state` and every window frame identical. A real reboot was not tried.

## Dogfood fixes (2026-11-19)

- Hotkeys follow the keyboard layout. At registration `UCKeyTranslate` maps key codes 0–64 (below the
  keypad) on the current ASCII-capable layout to letters and digits; anything missing (AZERTY's shifted
  digits) falls back to the physical US position. Punctuation stays physical: on many layouts it needs
  shift and the bind would never fire. Switching layouts re-registers every bind.
- Hung apps: a timed-out app now skips focus, warp and frame reads for 2 s too, not only placements.
  Parking back on stop and re-parking after a Monitor change still try, so no Window is left off-screen.
  Dropping the worker of a quit app no longer waits on its queue, which froze hotkeys behind a hung app.
- Checked: build and unit tests; the layout map on US QWERTY equals the old table. Not tried: another
  layout by real key press, a hung app against the full shell.

## Testing

- `swift test`: the pure core, 37 unit tests, no macOS involved.
- `swift build && swift run tatami-e2e`: end-to-end regression tests (`Sources/tatami-e2e`). A helper app opens
  test windows; an isolated tatami (own port, config and state through `TATAMI_PORT`, `TATAMI_HOME`,
  `TATAMI_ONLY_PID`) manages only that app; synthetic mouse events do the hovering and dragging; every
  check reads the real window frames or the app's real key window. 21 scenarios, 105 checks, about 3.5 minutes;
  each scenario starts its own helper apps and tatami, so `swift run tatami-e2e dialogs follow` runs just those
  (`--list` names them): tiling and gaps, keyboard focus and warp, focus follows mouse, mouse resize and swap,
  Accordion (real `alt+comma` key press, hovering and clicking the edges), three-Window stack, Floating Windows above Tiled ones, a system prompt, a window with a maximum size, hovering from an empty Monitor, Desk switch and Send, minimum size, float toggle, closing, menu bar
  app, two apps, a panel shown without focus, dialogs, Follow and its guard, an app quitting, stop and restart.
  Your own tatami must be stopped, and the mouse left alone while it runs: a moved mouse fails checks.
  `--no-mouse` skips hovering and dragging and turns focus-follows-mouse off in the test tatami, so the
  mouse can be used meanwhile (it still takes keyboard focus). It cannot run headless: macOS has one
  window server and one cursor per login session; only a macOS VM would give that.
- `TATAMI_DEBUG=1 tatami run` logs every event, command and focus decision.
- Found by the e2e tests and fixed (2026-11-16): cursor warp skipped when macOS focus was already right;
  focusing a second window of the same app did not take (focus now goes through the private SkyLight call
  for raise too, not app activation); a window still animating its resize was recorded as having a huge
  minimum size and floated for no reason; a new window moved to another Monitor kept a clamped size;
  a Window floated out of its tile kept the tile's size; hovering an unmanaged window blocked focusing
  an empty Monitor.
- Found in use and fixed (2026-11-16): keyboard focus did not raise a window of another app (the raise ran before its app was frontmost), visible in Accordion. The e2e suite now runs a second helper app to cover focus across apps and an app quitting.
- Found in use and fixed (2026-11-16): the cursor was pulled to a window's centre while sweeping the mouse across apps. macOS confirms a focus change late, and across apps out of order; a confirmation of an earlier hover was taken for focus from outside, so tatami warped the cursor there and re-focused. A confirmation for a Window the mouse has already left, within 1 s of that hover, is now ignored. The e2e helper apps confirm too fast to reproduce it: checked on the real desktop with `TATAMI_DEBUG=1` (18 mistaken events in a 10 s sweep before, 0 after).
- Found in use and fixed (2026-11-16): with Caps Lock on, a System Settings password prompt lost focus several times a second. Its Caps Lock indicator is a small panel; tatami gave it focus like any new Window, the password field lost focus, the indicator closed, focus went back, and it opened again. tatami no longer gives focus to a new dialog or panel (anything auto-floated): the app does that, and tatami follows. New Tiled Windows still get focus. Covered by e2e (a panel shown without focus).
- Found by new e2e scenarios and fixed (2026-11-16): closing a Window could jump Desk. When a window closes, its app picks the next key window, and macOS can report that focus before the close; the Follow guard only armed on hearing the close, so tatami followed to the other Desk. The worker now checks its Windows for closed ones before it reports a focus change, so the close always comes first. The same for an app that quits: macOS activates another app, whose window may be on a hidden Desk; that focus is not followed either.
- Found in use and fixed (2026-11-16): in an Accordion, hovering the peeking edge of a Window behind gave it the keyboard while it stayed behind, and the Window on top only got focus back once the mouse had left the other one's whole frame (the hover shortcut "still inside the focused Window" does not hold when Windows overlap). Now the mouse anywhere on an Accordion counts as being on whichever of its Windows is on top on screen; only a click brings another one forward.
- Found by e2e and fixed (2026-11-16): with focus on an empty Monitor, focus follows mouse was dead until a click. tatami is then the active app, and its global mouse monitor does not see events meant for its own app; a local monitor now covers that.
- Found in use and fixed (2026-11-16), all about what sits above what. macOS brings one window forward at a time and keeps no order for tatami, so 150 ms after every change tatami compares the real order on screen with the one it needs and brings forward what is buried, far windows first:
  - Accordion: going outwards from the front Window, each Window must sit above the next, or its edge does not show. With three Windows, clicking the first and then the last buried the middle one.
  - Floating Windows stay above the Tiled ones of their Desk: a dialog used to end up behind the stack.
- Found in use and fixed (2026-11-16): the mouse over a system prompt (not managed, and above normal windows) counted as being on the Window underneath, which took the keyboard from the prompt. Hover now looks at every window up to the Dock's level.
- Found in use and fixed (2026-11-16): a window that resizes but has a maximum size (System Settings) left its tile half empty. A Window that stays more than 100 px short of its tile becomes a Floating Window. The threshold keeps terminals tiled, which snap to whole character cells.
- Changed after use (2026-11-16): keyboard focus in an Accordion. Its Windows all cover the Monitor, so there is no geometry to go by: with a centred Floating Window, `focus right` went back and forth between it and one Tiled Window and never reached the rest of the stack. Now the two axes are told apart: along the stack is the Tiled Windows only, across it the Floating ones (the one used last, then the others, then back to the Tiled Window); from a Floating Window, along the stack goes to the front Tiled Window. Dwindle keeps judging by position.
- Changed after use (2026-11-16): a buried window is only asked to come forward (no app becomes the front one, the keyboard stays put, nothing blinks). The first version made each window's app the front one in turn and handed the keyboard back: that blinked, and with System Settings it kept taking the keyboard. Some apps ignore the plain request (System Settings); their window then stays behind like any macOS window until it is focused (`focus up/down` in an Accordion). A check runs right after tatami's own raise.
- A built-in Rule floats System Settings (`rule com.apple.systempreferences = float`), which never gets wider than about 740 px.
- Found in use and fixed (2026-11-19): on a Desk switch the browser (Zen) slid in from the parking corner over 200 ms instead of just being there. tatami sent one move; the app animated it, because it was in "enhanced user interface" mode (`AXEnhancedUserInterface`, switched on by some assistive tool or extension), in which apps animate every move they are asked to make. tatami switches the mode off around its own moves and back on after. Measured with the window server's own bounds: 20 steps over 200 ms before, one step after, mode still on afterwards. Zen answers "not implemented" to the switch and obeys anyway.
- Found in use and fixed (2026-11-19): after replugging the Monitors, windows stayed wherever macOS had left them. While displays reconnect or wake, apps refuse to be moved for a moment (`AXError -25202`, seen with cmux, Finder and Telegram); tatami logged it and did not try again. A refused placement is now retried after 2 s, three times at most. Not reproducible in e2e.
- Menu bar ("accessory") apps: their windows are managed as Floating Windows (border, focus, hide with the Desk).
  Such an app is watched only once it shows a window (when it becomes active, or at start if it owns one).
  macOS does not announce these apps quitting, so every watched app's own termination is observed; before that
  a dead app's window stayed in its Desk and took keyboard focus.
- Not covered by e2e: native fullscreen, Hide, Monitor disconnect, hung apps, Rules, borders by eye,
  multi-Monitor moves.

## Open risks

- Set size has a long tail (p95 81 ms, one 399 ms outlier; app not identified).
  Desk switches avoid it by only moving; the reconciler must not block other
  apps on a slow resize.
- Hung apps: handled. The timeout (0.5 s) is set on the system-wide element; after
  a timeout the worker skips that app's calls for 2 s (parking it back on quit is
  still attempted). Dropping a worker never waits on its queue.

## Working agreements

- Git repository from the start. Commits only on explicit instruction, with no
  AI attribution.
- AeroSpace stays closed while tatami runs.
