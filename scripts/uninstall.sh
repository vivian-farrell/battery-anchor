#!/bin/bash
# Removes Battery Anchor and restores normal charging. Run with sudo.
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "uninstall.sh must run as root (try: sudo $0)" >&2
    exit 1
fi

LABEL=dev.batteryanchor.daemon
DAEMON=/Library/PrivilegedHelperTools/$LABEL
REPO_DAEMON="$(cd "$(dirname "$0")/.." && pwd)/.build/release/battery-anchord"
APP="/Applications/Battery Anchor.app"
failed=0

# Remove the login item while the app still exists; it's registered in the user's session.
if [[ -n "${SUDO_USER:-}" && -x "$APP/Contents/MacOS/BatteryAnchor" ]]; then
    uid="$(id -u "$SUDO_USER")"
    if ! launchctl asuser "$uid" sudo -u "$SUDO_USER" "$APP/Contents/MacOS/BatteryAnchor" --unregister-login-item; then
        echo "warning: couldn't remove the login item; remove it in System Settings → General → Login Items" >&2
    fi
fi
pkill -x BatteryAnchor 2>/dev/null

echo "Stopping daemon"
launchctl bootout system/$LABEL 2>/dev/null
# Wait for the daemon to finish restoring charging before anything is deleted.
for _ in {1..20}; do
    launchctl print system/$LABEL >/dev/null 2>&1 || break
    sleep 0.5
done
if launchctl print system/$LABEL >/dev/null 2>&1; then
    echo "error: the daemon is still loaded" >&2
    failed=1
fi

# Restore explicitly, with whichever copy of the daemon exists.
RESTORE=""
for candidate in "$DAEMON" "$REPO_DAEMON"; do
    if [[ -x "$candidate" ]]; then
        RESTORE="$candidate"
        break
    fi
done
if [[ -z "$RESTORE" ]]; then
    echo "error: no battery-anchord binary found to restore charging with. Run 'make' in the project, then uninstall again." >&2
    failed=1
elif ! "$RESTORE" --restore; then
    echo "error: couldn't restore normal charging" >&2
    failed=1
fi

rm -f "/Library/LaunchDaemons/$LABEL.plist" /usr/local/bin/battery-anchor
rm -rf "/Library/Application Support/BatteryAnchor" "$APP"
if [[ $failed -eq 0 ]]; then
    rm -f "$DAEMON"
    echo "Battery Anchor removed; normal charging restored. Logs left at /Library/Logs/BatteryAnchor.log*."
else
    echo "Battery Anchor removed, except $DAEMON (kept so you can retry: sudo $DAEMON --restore)." >&2
    echo "Charging may still be limited — see the errors above." >&2
    exit 1
fi
