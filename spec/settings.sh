#!/usr/bin/env bash
#
# The settings store's own logic. No server, no token, no pairing. Run it while editing.
#
#   spec/settings.sh
#
# spec/run.sh is the integration harness and needs a running Seekquel and somebody to
# approve a pairing code, which is why this exists separately.
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
  "$IMAGE" -c 'exec lua5.1 /plugin/spec/settings_spec.lua'
