#!/bin/zsh
set -euo pipefail

SRC_DIR="${0:A:h}"
BIN="$SRC_DIR/nano-mac-throttle"
PLIST_SRC="$SRC_DIR/io.github.nano-mac-throttle.plist.template"
PLIST_DST="$HOME/Library/LaunchAgents/io.github.nano-mac-throttle.plist"
LABEL="io.github.nano-mac-throttle"
DOMAIN="gui/$(id -u)"

echo "==> Building binary"
"$SRC_DIR/build.sh"

echo "==> Installing LaunchAgent plist"
mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__NANO_MAC_THROTTLE_BIN__|$BIN|g" "$PLIST_SRC" > "$PLIST_DST"

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    echo "==> Unloading previous agent"
    launchctl bootout "$DOMAIN/$LABEL" || true
fi

echo "==> Loading agent"
launchctl bootstrap "$DOMAIN" "$PLIST_DST"
launchctl enable "$DOMAIN/$LABEL"
launchctl kickstart -k "$DOMAIN/$LABEL"

for old_label in io.github.nano-mac-load io.github.nanomacthrottle io.github.nanomempressure; do
    if launchctl print "$DOMAIN/$old_label" >/dev/null 2>&1; then
        echo "==> Note: $old_label is still running; uninstall it to avoid duplicate notifications."
    fi
done

echo "==> Triggering a test notification"
"$BIN" --test

echo "==> Status:"
"$BIN" --status

echo
echo "Done. Commands:"
echo "  $BIN --status          # print thermal and memory status"
echo "  $BIN --cpu             # print top CPU users"
echo "  $BIN --memory          # print top memory users"
echo "  $BIN --test            # fire a test notification"
echo "  $BIN --show-icon-test  # show the menu bar icon for 15 seconds"
