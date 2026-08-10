# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[semantic versioning](https://semver.org/spec/v2.0.0.html).

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
