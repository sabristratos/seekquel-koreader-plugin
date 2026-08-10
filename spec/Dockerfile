# A real Lua 5.1 (the dialect LuaJIT implements, so the plugin runs under the same
# semantics KOReader gives it) with real sockets, real TLS and a real SQLite.
#
# What this image cannot provide is KOReader itself. The framework modules are stubbed
# by spec/stubs.lua, so this harness proves the plugin's own logic, its payloads and its
# SQL, not the assumptions it makes about KOReader's API.
FROM debian:bookworm-slim

RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      lua5.1 lua-socket lua-sec lua-md5 lua-dkjson sqlite3 ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /plugin
ENTRYPOINT ["lua5.1"]
