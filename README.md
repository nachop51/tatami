# tatami

Quick and simple tiling window manager for macOS, with a Hyprland feel: windows tile
automatically (Dwindle or Accordion) and are grouped into Desks, without macOS Spaces.
Draws its own borders. Swift, no dependencies, System Integrity Protection stays on.

A personal tool, built for one setup and shared as is. It calls a few private (undocumented) macOS
APIs for focus without raising, window ids and corner radii, all in `Sources/tatami/Private.swift`;
a macOS update can break them. Developed on macOS 27.

## Run

```
swift build
.build/debug/tatami start     # needs Accessibility permission
.build/debug/tatami stop
```

To install it, `./install.sh` puts a release build in `~/.local/bin/tatami` and adds a LaunchAgent
(`dev.tatami`) that starts it at login. Run it again after every change.

macOS ties the Accessibility permission to the exact binary, so an ad-hoc signed build has to be granted
again after every rebuild. To grant it once, create a self-signed code signing certificate named
`tatami-dev` (Keychain Access > Certificate Assistant > Create a Certificate, type Code Signing):
`install.sh` signs with it when it exists, and the grant then follows the certificate.

`tatami defaults` prints the built-in config (gaps, borders, every bind). Put what differs in
`~/.config/tatami/config` and apply it with `tatami reload`:

```
gap.inner = 16
pin 1,3,5 = monitor 1
pin 2,4   = monitor 2
layout 5  = accordion
bind alt+enter = exec open -a Ghostty
rule "System Settings" = float
```

Letters and digits in a bind follow your keyboard layout; punctuation (`comma`, `semicolon`…) and
named keys (`enter`, `left`…) are physical US key positions.

## Test

```
swift test                 # the pure layout core
swift run tatami-e2e       # a real tatami, real windows, synthetic mouse; see the file header
swift run tatami-e2e follow dialogs   # only some scenarios; --list names them
```

Design, decisions and vocabulary: [docs/DESIGN.md](docs/DESIGN.md), [CONTEXT.md](CONTEXT.md).

## License

[MIT](LICENSE)
