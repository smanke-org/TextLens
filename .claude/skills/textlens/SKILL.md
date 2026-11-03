---
name: textlens
description: Drive TextLens, the text recognition app on this Mac, from the shell with the `textlens` command: read the text and QR or bar codes in picture and PDF files, translate text on the Mac, make QR code pictures, search, pin and delete captures in its history, list or stop watched screen areas, and start captures. Use when the user wants text pulled out of an image or PDF, a QR code read or made, text translated offline, asks about their TextLens history, or names TextLens.
---

# TextLens

`textlens` runs commands in the TextLens app. Changes show in its History window at once.
If the app is closed, the command opens it in the background. If `textlens` isn't on PATH, use
`/Applications/TextLens.app/Contents/MacOS/TextLens` the same way.

## Rules

- Always add `--json` and read the JSON. Exit 0 is ok; otherwise read `error.code` and
  `error.message`, and do what the message says.
- `text read` and `codes read` only read the file: they copy nothing and save nothing. Use
  `history add` only when the user wants the text kept in TextLens's history.
- Find ids with `textlens history list --search ...`. An id is 8 characters; any unique start works.
- `history delete` only reports what it would delete. Show the user that report and ask before
  you run it again with `--yes`: it can't be undone and removes it on every synced Mac.
- `capture start` puts up an area picker on the person's screen. Only run it when they asked for
  a capture; every mode but `again` waits for them to drag over an area.
- `needs_download`: macOS hasn't downloaded that language pair. Only the person can, in TextLens.
- Paths may be relative in the shell; over MCP they must be absolute.
- To try something without real data, run a Debug build with `APP_STORE=/tmp/textlens-test` in front.

## Main commands

| Command | Does |
| --- | --- |
| `textlens status --json` | Version, history count, watches, live translation, Screen Recording allowed |
| `textlens text read <file> [--line-breaks false] --json` | The text in a picture or PDF |
| `textlens codes read <file> --json` | The QR and bar codes in a picture or PDF |
| `textlens text translate --text T [--to fr] [--from de] --json` | Translate on this Mac |
| `textlens qr make --text T --to <file-or-folder> --json` | Save a QR code PNG |
| `textlens history list [--search T] [--kind text] [--pinned] [--limit N] --json` | Find captures |
| `textlens history show <id> --json` | One capture's full text and translation |

Everything else: `textlens help`, and `textlens help <command>` for its options.
