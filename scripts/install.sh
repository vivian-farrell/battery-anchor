#!/bin/bash
# Installs the Battery Anchor daemon, CLI and menu bar app. Run with sudo after scripts/build-app.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $EUID -ne 0 ]]; then
    echo "install.sh must run as root (try: sudo $0)" >&2
    exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
    echo "warning: Battery Anchor targets Apple Silicon Macs; charge control may not work on this machine" >&2
fi

LABEL=dev.batteryanchor.daemon
BIN="$(swift build -c release --show-bin-path 2>/dev/null || echo .build/release)"
DAEMON=/Library/PrivilegedHelperTools/$LABEL
PLIST=/Library/LaunchDaemons/$LABEL.plist
SUPPORT="/Library/Application Support/BatteryAnchor"
LOG=/Library/Logs/BatteryAnchor.log
APP_SRC="build/Battery Anchor.app"
APP_DEST="/Applications/Battery Anchor.app"

# Other charge limiters write the same SMC keys and will fight Battery Anchor.
CONFLICTS="$(pgrep -fl 'AlDente|aldente-pro.helper|co.palokaj.battery|batt/batt' || true)"
if [[ -n "$CONFLICTS" ]]; then
    echo "warning: other charge-control tools are running and will override Battery Anchor:" >&2
    echo "$CONFLICTS" | sed 's/^/    /' >&2
    echo "  Quit/uninstall them (e.g. 'battery uninstall', AlDente → Settings → Uninstall helper)." >&2
    echo >&2
fi

for f in "$BIN/battery-anchord" "$BIN/battery-anchor" "$APP_SRC"; do
    [[ -e "$f" ]] || { echo "missing $f — run 'make' first" >&2; exit 1; }
done

echo "Stopping any existing daemon"
launchctl bootout system/$LABEL 2>/dev/null || true
# bootout can return before the job is gone, which makes the next bootstrap fail.
for _ in {1..20}; do
    launchctl print system/$LABEL >/dev/null 2>&1 || break
    sleep 0.5
done

echo "Installing daemon → $DAEMON"
install -d -m 755 -o root -g wheel /Library/PrivilegedHelperTools
install -m 755 -o root -g wheel "$BIN/battery-anchord" "$DAEMON"

echo "Installing CLI → /usr/local/bin/battery-anchor"
install -d -m 755 /usr/local/bin
install -m 755 -o root -g wheel "$BIN/battery-anchor" /usr/local/bin/battery-anchor

# Status is root-only; settings are admin-writable.
install -d -m 755 -o root -g wheel "$SUPPORT"
install -d -m 775 -o root -g admin "$SUPPORT/settings"

# The daemon writes and rotates $LOG itself (1 MB cap). launchd's stderr capture, which only
# catches crash output, goes to the root-only support directory.
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DAEMON</string>
        <string>--log-file</string>
        <string>$LOG</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardErrorPath</key><string>$SUPPORT/daemon-stderr.log</string>
</dict>
</plist>
PLIST
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

# Enable first: bootstrap refuses a service that was previously disabled.
launchctl enable system/$LABEL
for attempt in 1 2 3 4 5; do
    if launchctl bootstrap system "$PLIST"; then
        break
    fi
    if [[ $attempt == 5 ]]; then
        echo "error: couldn't start the daemon, so the charge limit is NOT active." >&2
        echo "  Retry with: sudo launchctl bootstrap system $PLIST" >&2
        exit 1
    fi
    sleep 1
done

echo "Installing app → $APP_DEST"
pkill -x BatteryAnchor 2>/dev/null || true
rm -rf "$APP_DEST"
cp -R "$APP_SRC" "$APP_DEST"
if [[ -n "${SUDO_USER:-}" ]]; then
    chown -R "$SUDO_USER":staff "$APP_DEST"
fi

echo
echo "Done. The daemon is running (log: $LOG)."
echo "Open the menu bar app with:  open \"$APP_DEST\""
echo "Or use the CLI:              battery-anchor on 80"
