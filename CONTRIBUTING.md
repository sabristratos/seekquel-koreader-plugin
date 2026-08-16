# Contributing

Bug reports from real e-readers are the most valuable thing anyone can send right now.
The plugin has been exercised against real KOReader in an emulator but not yet on
physical hardware, so device-specific breakage is likely and is very much worth reporting.

## Reporting a bug

Open an issue and include:

- Your device and KOReader version, from **Help > About**.
- What you expected and what happened instead.
- The relevant lines from KOReader's log. On most devices that is `crash.log` next to the
  KOReader binary. Lines from this plugin are prefixed `Seekquel:`.

Redact your device key if it appears anywhere. It looks like `ABCD-EFGH-JKLM-NPQR`.

## Layout

```
seekquel.koplugin/     the plugin itself, seven files, no build step
  _meta.lua            name and description KOReader reads
  main.lua             the widget, the menu, the reader events
  seekquel_api.lua     every HTTP call
  seekquel_settings.lua what the device remembers between launches
  seekquel_stats.lua   reads KOReader's statistics database
  seekquel_annotations.lua turns annotations into highlights
  seekquel_metadata.lua  reads the book file's own details and cover
spec/                  a Lua harness that runs the plugin against a live server
emulator/              real KOReader on a virtual screen, in a browser
```

There is nothing to compile. Copy the folder onto a device and restart KOReader.

## Style

- Four spaces, no tabs. LF endings.
- No comments. Names carry the meaning, and anything that genuinely needs explaining
  belongs in the README where a user will find it.
- Every user-facing string goes through `_()` so it can be translated.
- Every network call is fire and forget. Nothing may block a page turn.
- Every failure is a log line and a return, never an error dialog the reader did not ask for.

Run `luacheck .` before opening a pull request. CI runs it too.

## Testing

Four harnesses, and they prove different things.

### The position spec

```bash
spec/position.sh
```

The other one you can run while editing: no server, no token, nobody approving a pairing
code. It covers telling where the reader *is* apart from where they are *looking*, which
is decidable on the device alone and is the rule that is easiest to get subtly wrong.
Consulting an index at the back of a book used to be reported as reading it, so a reader
7% in was recorded at 94%.

### The settings spec

```bash
spec/settings.sh
```

The one you can run while editing: no server, no token, nobody approving a pairing code.
It covers the settings store's own logic, which is where the rules that are easy to get
subtly wrong live: a high-water mark that must not move backwards, and a diagnostic that
has to survive being reported without being re-reported forever. Run it and the position
spec before the two below; they take a second between them, and each has already caught a
bug the reasoning missed.

### The Lua harness

```bash
SEEKQUEL_TOKEN=<a personal access token> spec/run.sh
```

Boots the plugin in Docker under Lua 5.1, which is the dialect LuaJIT implements and so
the same semantics KOReader gives it, with real sockets, real TLS and a real SQLite
holding a KOReader-shaped statistics database. It walks the whole reader journey against
a running Seekquel: pair, approve, open a book, link it, read, highlight, finish.

Set `HARNESS_WAIT_FOR_APPROVAL=1` to have it wait for a person to type the pairing code
into the real app instead of approving itself.

**What it cannot prove:** KOReader itself is stubbed in `spec/stubs.lua`, and the stubs
are written from the same assumptions the plugin makes. If the plugin calls a method
KOReader does not have, the stub agrees with the mistake and the harness passes.

That is not hypothetical. Two defects shipped exactly that way, and only the emulator
found them:

- The plugin called a `fastDigest` method that does not exist in KOReader. Every sync
  silently did nothing. The real answer is `doc_settings:readSetting("partial_md5_checksum")`.
- **KOReader's JSON library decodes `null` to a function**, not to `nil`, so every
  `field ~= nil` check read a null as present and indexing it crashed the reader. The
  harness used a different JSON library that decodes null to nil, so it agreed with the
  bug. `seekquel_api.lua` now strips those sentinels at the boundary, and the stub
  reproduces KOReader's behaviour so the harness can see it.

The lesson generalises: before calling a KOReader method, go and read it in the KOReader
source. Do not infer it from another plugin's docs or from what seems reasonable.

### The emulator

```bash
docker build -t koreader-emulator emulator
docker run -d --name koreader -p 127.0.0.1:6080:6080 \
  --add-host host.docker.internal:host-gateway \
  -e BOOK_PATH=/books/yourbook.epub \
  -v "$PWD":/plugin \
  -v "$PWD/emulator/books":/books \
  -v "$PWD/emulator/state":/root/.config/koreader \
  koreader-emulator
```

Then open http://localhost:6080/vnc.html. That is a real KOReader desktop build, loading
the plugin through the real plugin loader, drawn to a virtual screen you can click.

Put any EPUB in `emulator/books` first. Nothing is committed there.

`emulator/state` keeps the pairing and the statistics database across restarts, so you can
rebuild and carry on rather than pairing again.

This is the only layer that catches a wrong assumption about KOReader's own API. When you
change anything that touches the framework, run it here.

## Pull requests

Small and focused. Explain what a reader would notice, not only what changed in the code.

By contributing you agree your work is licensed under AGPL-3.0, the same as the rest of
the project.
