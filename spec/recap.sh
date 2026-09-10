#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE="seekquel-koplugin-harness"
MOUNT="$(pwd -W 2>/dev/null || pwd)"

docker build -q -t "$IMAGE" -f spec/Dockerfile spec >/dev/null
docker run --rm -v "$MOUNT":/plugin --entrypoint sh "$IMAGE" -c 'exec lua5.1 /plugin/spec/recap_spec.lua'
