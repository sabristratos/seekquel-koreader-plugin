#!/usr/bin/env bash
#
# Where the reader is, told apart from where they are looking. No server, no token, no
# pairing. Run it while editing.
#
#   spec/position.sh
#
# The rule this covers is decidable on the device alone, so it does not belong in
# spec/run.lua, which needs a running Seekquel and somebody to approve a pairing code.
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE="seekquel-koplugin-harness"

# Git Bash hands Docker an MSYS path it cannot mount, so ask for the Windows one where
# that shell exists and fall back to the ordinary path everywhere else.
MOUNT="$(pwd -W 2>/dev/null || pwd)"

docker build -q -t "$IMAGE" -f spec/Dockerfile spec >/dev/null

# The script path is passed inside `sh -c` rather than as an argument, because Git Bash
# rewrites a bare leading-slash argument into a Windows path and the container then
# cannot find it. An argument that does not begin with `/` is left alone.
docker run --rm \
  -v "$MOUNT":/plugin \
  --entrypoint sh \
  "$IMAGE" -c 'exec lua5.1 /plugin/spec/position_spec.lua'
