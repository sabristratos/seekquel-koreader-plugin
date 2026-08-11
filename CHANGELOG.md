# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## [1.4.0] - 2026-08-11

### Added

- **Rate a book from the reader.** Under Seekquel, tap Rate this book. No rating removes
  one you have already given.
- **The status you set in KOReader travels.** Marking a book Finished or On hold from
  KOReader's own status screen, or from the file browser, now reaches Seekquel as Read or
  Did not finish, instead of leaving the book sitting as Reading forever. It only sends a
  change you make on the device, so the status you set in the app is never overwritten.
  There is a switch for it in Settings.
- Syncing when Wi-Fi is about to go off, so the last few pages are not left behind on a
  device that turns its radio off by itself.

### Fixed

- **Pointing a file at a different book sends that book everything.** Correcting a link
  used to leave the new book without the reading history and highlights already sent to
  the old one, because the add-on believed it had sent them. It now starts fresh.

## [1.3.1] - 2026-08-11

### Fixed

- **Putting an Android reader to sleep now syncs.** On a Boox or any other Android
  device, KOReader tells add-ons something different when the screen goes off than a Kobo
  or a Kindle does, and the add-on was only listening for the Kobo and Kindle version. So
  a passage you highlighted and then slept on stayed on the device until you closed the
  book or tapped Sync now. Both are handled now, and sleeping syncs on every device.

## [1.3.0] - 2026-08-10

### Added

- **The add-on updates itself.** When Seekquel is serving a newer version, the menu offers
  it; one tap downloads and replaces the add-on, and KOReader asks you to restart. No
  cable and no computer. KOReader has no way to install or update an add-on of its own, so
  before this every update meant copying files across by hand.
  - The download is checked file by file before anything is replaced, so a download cut
    short on a poor connection leaves the copy you are running exactly as it was.
  - Your current copy is kept until the new one is in place, and put back if anything goes
    wrong part way.
  - It only ever downloads from the server address this device is already set to, and it
    only happens when you ask for it.
  - A device that will not let the add-on write to its own folder says so and tells you to
    copy the files across instead, rather than failing quietly.

## [1.2.0] - 2026-08-10

### Changed

- **Opening a book no longer stalls the reader.** Every message the add-on sends holds
  the screen until it answers, and opening a book for the first time sent five of them
  back to back, one of which uploads the cover. Only the quick ones happen at the open
  now; the description and the cover follow a minute later, and only if Wi-Fi is already
  on. Messages also give up sooner, and a sync that is already taking too long stops and
  leaves the rest for the next one instead of adding another wait.
- **Only new and edited highlights are sent.** Every sync used to re-send every highlight
  in the book, which on a heavily marked book was the longest wait of the lot and the one
  that came round most often. Editing a note still sends it again.
- **Reading time is counted in your own time zone**, the one on your Seekquel account,
  rather than whatever the clock on the reader says. A late evening was landing on the
  wrong day for anyone whose reader disagreed, which moved streaks and daily goals.
- **Nothing is lost after a long spell offline.** The add-on used to offer only the last
  seven days of reading time once a book had synced, so a longer trip away simply lost
  the days in between. It now offers everything since it last got through.
- **The pairing code lasts as long as Seekquel says it does.** The add-on gave up after
  five minutes on a code good for fifteen and told you it had expired. There is also a
  Cancel button now, so changing your mind does not mean waiting it out.
- Disconnecting a device forgets what it had already sent, so connecting to a different
  account sends that account the descriptions, covers and reading history it has not seen.
- Searching with a letter or two typed says so instead of doing nothing.

[1.4.0]: https://github.com/sabristratos/seekquel-koreader-plugin/releases/tag/v1.4.0

[1.3.1]: https://github.com/sabristratos/seekquel-koreader-plugin/releases/tag/v1.3.1

[1.3.0]: https://github.com/sabristratos/seekquel-koreader-plugin/releases/tag/v1.3.0

[1.2.0]: https://github.com/sabristratos/seekquel-koreader-plugin/releases/tag/v1.2.0

## [1.1.0] - 2026-08-10

### Added

- **Send highlights automatically** as its own switch. Turn it off and your passages stay
  on the device until you tap Sync now. Your place in the book and your reading time keep
  syncing, so nothing about your streak or your daily goal changes.
- **Sync status** in the menu: when the last sync was and whether all of it went through,
  which book the open file is linked to, and how many highlights are sitting on it.
- The switches can now be set from Seekquel as well as here. The app records what you
  asked for and this device applies it the next time it connects, so you no longer have
  to find the reader to change what it sends. Changing a switch here still wins.
- Diagnostics. The add-on notes what it is doing before each message it sends and clears
  it afterwards, so if the reader freezes or is closed part way through, the next start
  knows what it stopped on and tells Seekquel. Sync status shows the same thing. Calls
  that take more than five seconds are recorded too, since the reader waits on every one
  of them. No highlight text is ever included.

### Changed

- A file Seekquel cannot place is now left for you to link, rather than being saved as
  your own book straight away. Before, a file whose title carried its series and volume
  number ("Carl's Doomsday Scenario: Dungeon Crawler Carl Book 2") could end up as a
  second copy of a book already in your library, and it appeared on your profile as newly
  started. Nothing is recorded for a file until you say which book it is.
- More of those files now find their book on their own: a title that repeats its series
  and position after a colon is matched when the catalogue agrees on both.

[1.1.0]: https://github.com/sabristratos/seekquel-koreader-plugin/releases/tag/v1.1.0

## [1.0.0] - 2026-08-10

First public release.

### Added

- Pair a device by approving an eight-character code in the Seekquel app, so no key is
  ever typed on an e-ink keyboard.
- Send your place in a book, using the same document checksum KOReader's built-in
  progress sync uses.
- Send reading time per day, read from KOReader's own statistics database and grouped in
  local time, so a sync after a week offline still lands each session on the day it
  happened.
- Send highlights and notes, keeping the book's words and your own comment apart.
- Send everything the book file itself carries, once per file: description, ISBN,
  language, subject tags, length, table of contents and cover. It fills in your own copy
  of a book the catalogue does not have, never a catalogue book, and never over the top
  of something you set yourself.
- Mark a book finished when you reach the end.
- Link a file to a catalogue book from the device, or save it as your own private book
  when the catalogue does not have it.
- Set a reading status from the menu.
- Per-device switches for reading time, highlights, finishing at the end, syncing while
  reading, and whether syncing may turn on Wi-Fi. All of them are reported to the account
  so you can see what each device sends.
- Point the plugin at a self-hosted Seekquel with a server address setting.

[1.0.0]: https://github.com/sabristratos/seekquel-koreader-plugin/releases/tag/v1.0.0
