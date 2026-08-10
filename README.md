# Seekquel for KOReader

Sends your reading to [Seekquel](https://seekquel.app): where you are in each book, how
long you read, the books you finish, and your highlights.

Works anywhere KOReader does, including Kindle, Kobo, PocketBook, Cervantes, reMarkable,
Android, Linux and macOS.

KOReader already ships a progress-sync client, and it covers your position and nothing
else. This is the rest.

## Install

1. Download `seekquel.koplugin` from the [latest release](https://github.com/sabristratos/seekquel-koreader-plugin/releases/latest).
2. Unzip it and copy the `seekquel.koplugin` folder into `koreader/plugins/` on your device.
3. Restart KOReader.
4. Open **Tools > Seekquel > Connect this device**. It shows an eight-character code.
5. On your phone or computer, open Seekquel and go to **Settings > Integrations > KOReader**,
   then enter that code.

Nothing is typed on the e-ink keyboard. The device shows the code, and you approve it
somewhere with a real keyboard.

You need a Seekquel account. The plugin is useless without one.

## What it sends

| What | When |
| --- | --- |
| Where you are in a book | Every 60 pages and when you close it |
| How long you read | Per day, from KOReader's own statistics |
| Books you finish | When you reach the end, if you leave that switch on |
| Highlights and notes | With the passage and your own comment kept apart |
| Reading status | When you set it from the menu |
| The book's own details | Once per file, the first time you open it |

That last row is everything the file itself carries: the description, the ISBN, the
language, the publisher's subject tags, how long the book is, the table of contents, and
the cover. A sideloaded book that Seekquel has never heard of arrives with its jacket and
its chapters rather than as a bare title.

Those details only ever fill in **your own copy of a book Seekquel does not have**. They
never touch a book in the shared catalogue, and they never overwrite something you have
already set yourself. A file's metadata is one person's copy of one book, frequently
retyped by whoever made the file, and the catalogue is everybody's.

## Linking a book

The first time you open a book, Seekquel asks which catalogue book the file is. Search by
title, pick from the list, and it remembers. The answer is stored against the file, so it
holds even if you move the book to another device.

A book the catalogue does not have becomes your own private book. Sideloaded PDFs and
mangled filenames never end up in the shared catalogue.

Until a file is linked, no reading time or highlights are sent for it. Minutes filed
against the wrong book are worse than minutes nobody recorded.

## Settings

Everything is under **Tools > Seekquel > Settings**.

- Send reading time, send highlights, and mark finished at the end are all on by default.
- **Sync while reading** off means it only syncs when you close a book.
- **Turn on Wi-Fi to sync** is off by default. With it off, syncing waits for a connection
  you made yourself, and your radio stays off.

The switches live on the device. Seekquel shows you what each device is set to send, but
it does not change them from the web.

## How it works

Some of this is worth knowing before you file a bug.

**Nothing blocks a page turn.** Every network call is fire and forget behind a debounce,
every failure is a log line, and a device out of range simply syncs later. You should
never learn that this plugin exists by waiting for it.

**Nothing is guessed at.** A file is linked to a catalogue book once, by you. Until then
no reading time or highlights are sent for it, and the server refuses them anyway.

**A book is identified by KOReader's own partial checksum**, the same one the built-in
progress sync uses, so one book is one document however it was connected. The checksum is
of your file, so the same book from a different source has a different one. That is a
property of the scheme, not a bug, and it is why linking is asked of you once per file.

**Reading time comes from KOReader's statistics plugin**, not from a timer of our own.
That plugin already records a row per page turn with its duration, which is a far better
record of a sitting than anything we could ask you to start and stop. Days are grouped in
local time, because the day you believe you read on is the day your lamp was on, not the
UTC date. A sync after a week offline still files each session on the day it happened.

**Whole minutes only.** A day that adds up to less than a minute is carried over rather
than rounded away, so forty seconds a night still counts eventually.

**Highlights are never deleted.** A highlight you remove on the device stays in Seekquel.
Losing a note because one device stopped reporting it is much worse than keeping one you
no longer want, and a book moved between devices routinely arrives with an empty
annotation list. Delete them in Seekquel if you want them gone.

**Your comment on a passage is stored apart from the passage.** The book's words and your
words are two different things.

**The cover faces the same check as any other automatically found cover.** Plenty of EPUBs
carry a thumbnail-sized jacket, and a mushy cover on a shelf is worse than none. If yours
is refused, that is why.

## Status

This has been run against real KOReader in an emulator, end to end, but **not yet on a
physical e-reader**. Treat the first install as a test, and please report anything that
misbehaves.

## Privacy

The device key is stored in plain text in `koreader/settings/seekquel.lua`. There is
nowhere else to put it. KOReader runs unprivileged on a filesystem you mount over USB, and
a keystore here would be theatre. The key can only sync, and you can revoke it from
Settings > Integrations at any time.

The plugin talks to your Seekquel server and to nothing else. It has no analytics.

## Self-hosting

**Tools > Seekquel > Server address** points the plugin somewhere else. Give it the full
base address including `/koreader`, for example `https://api.example.com/koreader`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports from real devices are the most useful
thing right now.

## Licence

[AGPL-3.0](LICENSE), the same licence as KOReader, which this runs inside.
