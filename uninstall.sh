#!/bin/zsh
set -euo pipefail

LABEL="io.github.nano-mac-throttle"
DOMAIN="gui/$(id -u)"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    echo "==> Stopping agent"
    launchctl bootout "$DOMAIN/$LABEL" || true
fi

if [[ -f "$PLIST_DST" ]]; then
    echo "==> Removing $PLIST_DST"
    rm -f "$PLIST_DST"
fi

echo "==> Done."
