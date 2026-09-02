#!/usr/bin/env bash
#
# What the plugin reads out of KOReader's own statistics database, against a real SQLite
# holding a real KOReader schema. No server, no token, no pairing. Run it while editing.
#
#   spec/stats.sh
#
# The distinction it exists to hold: a database that could not be read and a database
# with nothing in it are different answers, and reading time stops silently when they
# are not.
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE="seekquel-koplugin-harness"

# Git Bash hands Docker an MSYS path it cannot mount, so ask for the Windows one where
# that shell exists and fall back to the ordinary path everywhere else.
MOUNT="$(pwd -W 2>/dev/null || pwd)"

DIGEST="${HARNESS_DIGEST:-0f0e0d0c0b0a09080706050403020100}"

docker build -q -t "$IMAGE" -f spec/Dockerfile spec >/dev/null

docker run --rm \
  -v "$MOUNT":/plugin \
  -e HARNESS_DIGEST="$DIGEST" \
  --entrypoint sh \
  "$IMAGE" -c '
    HARNESS_SETTINGS_DIR="$(mktemp -d)"
    export HARNESS_SETTINGS_DIR
    sed "s/:digest/\x27$HARNESS_DIGEST\x27/" /plugin/spec/fixture.sql \
      | sqlite3 "$HARNESS_SETTINGS_DIR/statistics.sqlite3"
    exec lua5.1 /plugin/spec/stats_spec.lua
  '
