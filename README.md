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

### Updating

You only do the copying above once. After that, when Seekquel is serving a newer version
the Seekquel menu offers **Update the add-on**; tap it, and KOReader will ask you to
restart. KOReader itself has no way to install or update an add-on, which is why this is
built in rather than something the reader does for you.

It never updates on its own, and it only ever downloads from the server address this
device is set to. The download is checked before anything is replaced, so a connection
that drops part way leaves the copy you are running untouched. If your device will not let
the add-on write to its own folder, it says so and you copy the files across as above.

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

A file Seekquel cannot place is left for you to answer rather than saved as a book on your
behalf. Pick the catalogue book it is, or choose **Not in the catalogue** and it becomes
your own private book. Sideloaded PDFs and mangled filenames never end up in the shared
catalogue either way.

That is deliberate and it replaced the opposite. A file used to be saved as your own book
the moment nothing matched it, which for a filename carrying a series and a volume number
meant a second copy of a book already in your library, shown on your profile as newly
started. A guess should not speak for you.

Until a file is linked, no reading time or highlights are sent for it. Minutes filed
against the wrong book are worse than minutes nobody recorded. Nothing is lost while it
waits: your place is held, and everything catches up once you answer.

Point a file at a different book later and that book gets everything: the reading history
and the highlights are offered again from scratch, rather than being counted as already
sent to the book you corrected away from.

Once a file is linked you can set its status and rate it from **Tools > Seekquel**,
without opening the app.

## Settings

Everything is under **Tools > Seekquel > Settings**.

- Send reading time, send highlights, and mark finished at the end are all on by default.
- **Send status changes from this device** mirrors the status you set in KOReader's own
  screens: Finished becomes Read, On hold becomes Did not finish. It only sends a change
  you make on the device, so a status you set in the app is never overwritten. Setting it
  from the file browser while the book is closed reaches Seekquel the next time you open
  and sync that book.
- **Sync while reading** off means it only syncs when you close a book.
- **Send highlights automatically** off means your passages stay on the device until you
  tap **Sync now**. Your place in the book and your reading time keep syncing either way.
- **Sync on a timer** is every fifteen minutes by default, and can be set to five, thirty,
  sixty, or off. It is the floor under the page count: read slowly, or read a few pages
  and put the book down without closing it, and this is what brings the sitting across. A
  tick with nothing new to send does nothing at all, so it costs you no pauses. It follows
  **Sync while reading**, so turning that off stops the timer too. Like the switches, it
  can be set from Seekquel instead of from here.
- **Turn on Wi-Fi to sync** is off by default. With it off, syncing waits for a connection
  you made yourself, and your radio stays off.

**Sync status** tells you when the last sync was and whether all of it went through, which
book the open file is linked to, and how many highlights are sitting on it. If a sync
stopped part way through, it says which step it stopped on.

That last part is worth knowing about, because it is how a freeze gets reported at all. The
add-on writes down what it is about to do before each message it sends and clears it once
the message is answered. If your reader dies in between, the note survives, and the next
time it connects it tells Seekquel what it stopped on. Nothing about what you highlighted
is included, only the name of the step.

You can set all of these here or in Seekquel, under Settings, Integrations, KOReader.
The app records what you asked for and this device applies it the next time it connects,
so a device that is off or out of range simply picks it up later. Changing a switch here
always wins, because it takes effect immediately and works with no connection at all.

## How it works

Some of this is worth knowing before you file a bug.

**Time spent reading is KOReader's own count, and it does not run while you are away.**
The add-on reads the numbers KOReader's statistics already keep, so it inherits their
rules: a single page can never be worth more than **two minutes**, however long the book
sits open on it, and time while the device is asleep is not counted at all. So falling
asleep mid-page, or leaving the reader open on the sofa, costs you two minutes at most.
That ceiling is yours to change, under KOReader's own **Settings > Statistics**.

**Looking something up is not reading, and your place knows the difference.** Jumping to an
index at the back, an endnote, a glossary, an appendix or a chapter in the contents moves
where you are looking, not how far you have read, so none of it is sent. Your place only
follows you once you have read a few pages from where you landed, which is what makes
skipping ahead work and a look at the index cost nothing. The same count decides what a
day is credited with: skip an introduction and your place moves without those pages being
added to your reading.

**A page turn is never waited on, but a sync is not free either.** Turning pages only ever
schedules a sync, and never waits for one, so reading is unaffected. The sync itself does
block: each message waits up to twelve seconds for an answer (thirty for a cover or a long
backlog), and a sync sends a few, so on a poor connection the screen can sit still for a
while once one starts. A sync that has already taken twenty seconds stops there and leaves
the rest for the next one, so a bad connection costs you a delay rather than a longer wait.
Describing a book to Seekquel is the slowest part and no longer happens as you open it: the
description follows twenty seconds later, and only if Wi-Fi is already on. Syncs happen
when you close a book, when the device sleeps, when you pick it back up, when it finds a
network, every twenty pages if **Sync while reading** is on, and on the timer. If yours
freezes, **Sync status** will say what it stopped on, and that is reported so it can be
fixed.

**A server that will not answer is left alone for two minutes**, so one unreachable server
costs you one pause rather than one per message. Waking the device or finding a network
ends that wait early, because both are reasons to think the answer has changed. **Sync
now**, pairing and updating always try immediately.

**Nothing is guessed at.** A file is linked to a catalogue book once, by you. Until then
no reading time or highlights are sent for it, and the server refuses them anyway.

**A book is identified by KOReader's own partial checksum**, the same one the built-in
progress sync uses, so one book is one document however it was connected. The checksum is
of your file, so the same book from a different source has a different one. That is a
property of the scheme, not a bug, and it is why linking is asked of you once per file.

**Reading time comes from KOReader's statistics plugin**, not from a timer of our own.
That plugin already records a row per page turn with its duration, which is a far better
record of a sitting than anything we could ask you to start and stop. Days are grouped by
the time zone on your Seekquel account, because the day you believe you read on is the day
your lamp was on, and the clock on an e-reader is often not set to where you live. However
long you have been offline, every session still files on the day it happened.

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

Run end to end against real KOReader in an emulator, and **in testing on real e-readers
since August 2026**. Treat it as early: freezes during syncing have been reported and are
being chased. Please report anything that misbehaves, and include what **Sync status**
says.

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
