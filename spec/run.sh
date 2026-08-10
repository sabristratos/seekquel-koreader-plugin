#!/usr/bin/env bash
#
# Runs the plugin against a Seekquel you are already running.
#
#   SEEKQUEL_TOKEN=<a personal access token> spec/run.sh
#
# The token is the reader's phone: pairing needs somebody signed in to approve the code,
# and that is the one thing a device genuinely cannot do for itself.
set -euo pipefail

cd "$(dirname "$0")/.."

: "${SEEKQUEL_TOKEN:?set SEEKQUEL_TOKEN to a personal access token for the account under test}"

# With HARNESS_WAIT_FOR_APPROVAL the harness writes its pairing code to
# spec/.pairing-code and waits for somebody to type it into the real app rather than
# approving itself. That is the one step of the journey a test cannot honestly fake.
WAIT="${HARNESS_WAIT_FOR_APPROVAL:-}"

HOST="${SEEKQUEL_HOST:-http://host.docker.internal:8000}"
DIGEST="${HARNESS_DIGEST:-0f0e0d0c0b0a09080706050403020100}"
IMAGE="seekquel-koplugin-harness"

# Git Bash hands Docker an MSYS path it cannot mount, so ask for the Windows one where
# that shell exists and fall back to the ordinary path everywhere else.
MOUNT="$(pwd -W 2>/dev/null || pwd)"

echo "Building the harness image..."
docker build -q -t "$IMAGE" -f spec/Dockerfile spec >/dev/null

# No absolute container path appears on this command line: Git Bash rewrites anything
# that looks like one into a Windows path, and the container then writes its settings
# and its statistics database somewhere the plugin will never look. The container picks
# its own directory instead.
echo "Running against $HOST"
docker run --rm \
  --add-host host.docker.internal:host-gateway \
  -v "$MOUNT":/plugin \
  -e SEEKQUEL_URL="$HOST/koreader" \
  -e SEEKQUEL_API="$HOST" \
  -e SEEKQUEL_TOKEN="$SEEKQUEL_TOKEN" \
  -e HARNESS_DIGEST="$DIGEST" \
  -e HARNESS_WAIT_FOR_APPROVAL="$WAIT" \
  --entrypoint sh \
  "$IMAGE" -c 'set -e
    HARNESS_SETTINGS_DIR="$(mktemp -d)"
    export HARNESS_SETTINGS_DIR
    sed "s/:digest/\x27$HARNESS_DIGEST\x27/" /plugin/spec/fixture.sql \
      | sqlite3 "$HARNESS_SETTINGS_DIR/statistics.sqlite3"
    exec lua5.1 /plugin/spec/run.lua
  '
