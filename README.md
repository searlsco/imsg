# imsg - archive your iMessages

🚨🧘 **VIBE CODING ALERT: no humans were harmed in the writing of this code.** 🧘🚨

A CLI tool to export iMessages to static web archives that can be viewed locally.

<img width="1147" height="716" alt="Image" src="https://github.com/user-attachments/assets/f3001ff9-4368-4196-9492-6b7ed0f368b5" />

## Install

```
brew install searlsco/tap/imsg
```

## Features

- **Export your Messages** to a static HTML website you can open as a file without running a server
- **Display attached files and media** like images, video, and audio. Clicking a file reveals it in Finder
- **Search transcripts** and jump to any point in a conversation
- **Filter threads** to find the one you're looking for
- **Merge contacts into combined threads, like Messages does** by cross-referencing your Contacts database or an address book export

You can export a single conversation or an archive of all of them. Long threads are loaded in gradually as you scroll and search, improving the archive's responsiveness.

## Why to use this

Whether you're backing up your own Messages or archiving a loved one's texts, exporting a backup of your message database as a portable web archive means you'll be able to continue to revisit it for years and decades to come. Because Apple's own Messages and Contacts apps' data is predominantly stored in proprietary formats, it may become difficult or impossible to recover very old backups with the current versions of those applications.

Also Apple's search sucks and this search is fast, simple, and mostly works.

## What you'll need

This tool was designed around the macOS Messages app and is not suitable for extracting Messages from other Apple platforms. It can be used in either of these two situations:

* You are logged into the account you want to archive. In this case, `imsg` will read your actual messages and contacts from `~/Library`
* You have backups from someone else's account. In this case, supply `-m path/to/their/Messages` directory and `-a path/to/their/address-book.abbu` export

If you have a Messages database but no contacts database directory or address book export, all threads will be exported using only contact identifiers (phone numbers, email addresses). This means the export will lack human display names and conversations with the same person across different numbers/addresses will not be merged.

## Usage

### Exporting all your messages

Export your messages and open them in a browser:

```
imsg export
```

Export a specific database of messages with a custom address book:

```
imsg export -m dads/Messages -a dads-contacts.abbu
```

### Exporting a single conversation

To export a single conversation, you can identify it by running:

```
imsg list
```

Which will produce a table like:

```
+----------+-----------+---------------------+---------------------+---------------+
| Name     | ID        | First Message at    | Last Message at     | Message Count |
+----------+-----------+---------------------+---------------------+---------------+
| Jane Doe | ab:pk:137 | 2023-06-12 08:39:40 | 2025-04-11 13:13:40 |         41073 |
+----------+-----------+---------------------+---------------------+---------------+
| Name     | ID        | First Message at    | Last Message at     | Message Count |
+----------+-----------+---------------------+---------------------+---------------+
```

The ID format depends on whether the handle matches a contact, a group chat, or an individual email/phone.

Once you have the ID you wish to export:

```
imsg export ab:pk:137
```

You'll see an archive created at `./exports/jane_doe/` and your browser will open to its generated `index.html` page.

If you're exporting a conversation between yourself and someone else from _their_ backup (as was the case when restoring chats with [our late father](https://justin.searls.co/links/2024-12-18-my-dads-obituary/)), you can add `--flip-perspective` along with their Messages & Contacts exports. You can also set the display name to their name.

Here's what that might look like:

```
./bin/imsg export ab:pk:137 -m Messages -a address-book.abbu/ --flip-perspective --display-name "Fred Searls"
```

## Options

There are a lot of other options.

The `export` command:

```
Usage: imsg export [options] [CHAT_IDS...]
  -m, --messages DIR               macOS Messages database directory. Default: ~/Library/Messages
  -a, --address-book PATH          Contacts database or export (.abbu or .abcddb). Default: reads from ~/Library/Contacts
      --no-address-book            Do not cross-reference Contacts; list threads by email or phone
      --[no-]backup                Read via a SQLite backup copy for integrity. Default: on
      --limit N                    Limit number of conversations. Default: all
      --from-date ISO8601          Only include messages on/after this timestamp (e.g., 2022-01-01T00:00:00)
      --to-date ISO8601            Only include messages on/before this date (e.g., 2024-12-15)
  -o, --outdir DIR                 Output directory
      --page-size N                Messages per page (default: 1000)
      --skip-attachments           Do not copy or render attachments
      --[no-]open-after-export     Open export in browser after completion (default: on for interactive TTY only)
      --display-name NAME          Override display name (single chat export only)
      --name NAME                  Deprecated: use --display-name NAME
      --flip-perspective           Invert sender/recipient roles in the viewer (me<->them)
      --sort FIELD                 Sort processing/limit order by: last_message_at|name|message_count
      --asc                        Sort processing/limit in ascending order
      --desc                       Sort processing/limit in descending order
```

The `list` command:

```
Usage: imsg list [options]
  -m, --messages DIR               macOS Messages database directory. Default: ~/Library/Messages
  -a, --address-book PATH          Contacts database or export (.abbu or .abcddb). Default: reads from ~/Library/Contacts
      --no-address-book            Do not cross-reference Contacts; list threads by email or phone
      --[no-]backup                Read via a SQLite backup copy for integrity. Default: on
      --limit N                    Limit number of conversations. Default: all
      --from-date ISO8601          Only include messages on/after this timestamp (e.g., 2022-01-01T00:00:00)
      --to-date ISO8601            Only include messages on/before this date (e.g., 2024-12-15)
      --sort FIELD                 Sort by: last_message_at|name|message_count
      --asc                        Sort ascending
      --desc                       Sort descending
      --count                      Print only the number of rows and exit
```

## Keyboard Shortcuts

The exported web app also supports a number of keyboard shortcuts:

- Filter conversation list:
  - macOS: `Ctrl` + `F`
  - Linux/Windows: `Alt` + `F`
- Search within a conversation:
  - macOS: `Ctrl` + `S`
  - Linux/Windows: `Alt` + `S`
- Switch focus between areas:
  - macOS: `Ctrl+1` focuses the chat list; `Ctrl+2` focuses the viewer
  - Linux/Windows: `Alt+1` focuses the chat list; `Alt+2` focuses the viewer
- Arrow Keys (sidebar filter):
  - `ArrowDown` selects and opens the first visible conversation
  - `ArrowUp` selects and opens the last visible conversation
- Arrow Keys (conversation list):
  - `ArrowDown`/`ArrowUp` moves selection and opens the selected conversation
  - `ArrowRight` moves focus to the viewer
- Arrow Keys (conversation view):
  - `ArrowLeft` returns focus to the chat list
- Search Results overlay (inside a thread after typing in search):
  - `ArrowDown`/`ArrowUp` moves through results
  - `Enter` jumps to the selected result and highlights it
  - `Escape` clears the search field and closes results
