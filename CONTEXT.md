# tatami

A tiling window manager for macOS that gives a Hyprland-like experience: windows tile automatically and are grouped into Desks, without using macOS Spaces.

## Language

**Desk**:
A numbered group of Windows shown together on one Monitor. Each Window belongs to exactly one Desk.
_Avoid_: Workspace, Space, desktop

**Monitor**:
A connected display. Shows exactly one active Desk at a time. Any number of Monitors may be connected.
_Avoid_: Screen, display

**Active Desk**:
The Desk a Monitor is currently showing.

**Focused Monitor**:
The Monitor that holds the focused Window, or that the cursor last entered if its Desk is empty. New Windows open on its Active Desk.

**Window**:
A single application window. The unit that is tiled, focused, and assigned to a Desk; one app may have Windows on several Desks.

**Tiled Window**:
A Window whose position and size are decided by the Desk's layout.
_Avoid_: Tile, managed window

**Floating Window**:
A Window that keeps its own position and size, drawn over Tiled Windows. Still belongs to a Desk and hides with it.
_Avoid_: Float, popup

**Hide**:
The macOS app hide (Cmd+H semantics). A hidden app's Windows leave the tiling and rejoin their Desk when the app is shown again.
_Avoid_: Minimize, scratchpad

**Layout**:
How a Desk arranges its Tiled Windows. Each Desk has exactly one: Dwindle or Accordion.

**Dwindle**:
The Layout where each new Window splits the focused Window along its longer side, taking the right or bottom half.
_Avoid_: BSP, tiles

**Accordion**:
The Layout where a Desk's Tiled Windows are stacked nearly full-size with their edges peeking out, one in front at a time.
_Avoid_: Stack, tabbed, monocle

**Fullscreen**:
A Window temporarily filling its Monitor while staying on its Desk. Distinct from macOS native fullscreen, during which tatami does not manage the Window.

**Pin**:
A config statement tying a Desk to a Monitor. Unpinned Desks live on the Monitor where they were first opened.

**Send**:
Moving the focused Window to another Desk and switching to that Desk along with it.

**Rule**:
A config statement that decides how a newly opened Window is treated, such as which Desk it opens on or whether it floats.

**Follow**:
Switching to the Desk that holds a Window when that Window is activated from outside (Cmd+Tab, Dock click).
