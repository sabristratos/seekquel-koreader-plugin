#!/usr/bin/env bash
#
# Runs the self-update checks against a real KOReader build.
#
#   spec/updater.sh
#
# This one deliberately does not use spec/Dockerfile. The updater's whole job is to
# unpack an archive with KOReader's own libarchive binding, hash the result with
# KOReader's own SHA-256 and swap a directory on disk, and the stub harness can fake all
# three from the plugin's own assumptions. So it runs inside the emulator image, where
# those libraries are the ones the reader's device actually has. It needs no server.
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE="koreader-emulator"

# Git Bash hands Docker an MSYS path it cannot mount, so ask for the Windows one where
# that shell exists and fall back to the ordinary path everywhere else.
MOUNT="$(pwd -W 2>/dev/null || pwd)"

echo "Building the KOReader image..."
docker build -q -t "$IMAGE" emulator >/dev/null

echo "Running the self-update checks..."
MSYS_NO_PATHCONV=1 docker run --rm \
    --entrypoint sh \
    -v "$MOUNT":/plugin \
    "$IMAGE" \
    -c 'cd /opt/koreader/lib/koreader && ./luajit -e "require(\"setupkoenv\"); dofile(\"/plugin/spec/updater.lua\")"'
