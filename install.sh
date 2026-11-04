#!/bin/sh
# Installs tatami: release build in ~/.local/bin, started at login by a LaunchAgent.
# Run it again after every change.
#
# Accessibility: with a code signing certificate named "tatami-dev" in your keychain, the binary is signed with
# it and macOS ties the grant to that certificate, so it survives rebuilds. Without one the build is ad-hoc
# signed and every new build has to be granted again (remove the old entry, add the binary again).
set -eu
cd "$(dirname "$0")"

label=dev.tatami
identity=tatami-dev
domain="gui/$(id -u)"
bin="$HOME/.local/bin/tatami"
plist="$HOME/Library/LaunchAgents/$label.plist"
log="$HOME/Library/Logs/tatami.log"

swift build -c release --product tatami

# Stop whichever tatami is running (any build answers on the same port) and wait for it to put windows back.
.build/release/tatami stop 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x tatami >/dev/null || break; sleep 0.5; done
launchctl bootout "$domain/$label" 2>/dev/null || true

mkdir -p "$(dirname "$bin")" "$(dirname "$plist")"
rm -f "$bin"  # a fresh file: overwriting a signed binary in place gets the new one killed
cp .build/release/tatami "$bin"
if security find-identity -p codesigning | grep -q "\"$identity\""; then
    codesign --force --sign "$identity" --identifier "$label" "$bin"
fi

# No KeepAlive: `tatami stop` must stay stopped, and a missing grant must not loop.
cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key><array><string>$bin</string><string>run</string></array>
    <key>RunAtLoad</key><true/>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardOutPath</key><string>$log</string>
    <key>StandardErrorPath</key><string>$log</string>
</dict>
</plist>
EOF
launchctl bootstrap "$domain" "$plist"

for _ in 1 2 3 4 5 6 7 8 9 10; do
    if "$bin" state >/dev/null 2>&1; then echo "tatami installed and running: $bin"; exit 0; fi
    sleep 0.5
done
echo "Installed, but tatami is not running (see $log)."
echo "Most likely: allow $bin in System Settings > Privacy & Security > Accessibility, then:"
echo "    launchctl kickstart $domain/$label"
exit 1
