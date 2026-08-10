#!/usr/bin/env bash
#
# Brings up a virtual screen the size of an e-reader, puts KOReader on it, and serves
# that screen over noVNC so it can be driven from a browser.
set -eu

WIDTH="${SCREEN_WIDTH:-758}"
HEIGHT="${SCREEN_HEIGHT:-1024}"
DISPLAY_NUM=":0"

export DISPLAY="$DISPLAY_NUM"
export HOME=/root

echo "Starting a ${WIDTH}x${HEIGHT} display..."
Xvfb "$DISPLAY_NUM" -screen 0 "${WIDTH}x${HEIGHT}x24" -nolisten tcp &
sleep 2

x11vnc -display "$DISPLAY_NUM" -forever -shared -nopw -quiet -rfbport 5900 &
sleep 1

websockify --web=/usr/share/novnc 6080 localhost:5900 &
sleep 1

# The plugin is mounted rather than baked in, so an edit on the host is one restart away
# from running here.
KOREADER_DIR=/opt/koreader/lib/koreader

if [ -d /plugin/seekquel.koplugin ]; then
  rm -rf "$KOREADER_DIR/plugins/seekquel.koplugin"
  cp -r /plugin/seekquel.koplugin "$KOREADER_DIR/plugins/seekquel.koplugin"
  echo "Plugin installed: $(ls "$KOREADER_DIR/plugins/seekquel.koplugin" | tr '\n' ' ')"
fi

echo "noVNC on http://localhost:6080/vnc.html"

cd "$KOREADER_DIR"
exec ./koreader.sh "${BOOK_PATH:-/books}"
