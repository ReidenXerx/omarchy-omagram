# Omagram

**An unofficial Telegram client for [Omarchy](https://omarchy.org).** Omagram is not made,
endorsed or supported by Telegram. It is built on TDLib, Telegram's own client library, and
you sign in with an API id of your own.

A keyboard-driven window in your Omarchy theme, a bar badge with a quick panel, a quick-reply
overlay on a key, and desktop notifications you can answer without leaving what you are doing.

![service](https://img.shields.io/badge/omarchy-service-blue) ![bar widget](https://img.shields.io/badge/omarchy-bar--widget-blue) ![overlay](https://img.shields.io/badge/omarchy-overlay-blue)

> **Before you use it:** Telegram places accounts that sign in from unofficial clients
> "under observation" and may limit accounts that misuse the API. Omagram uses the API as an
> ordinary client does, but the risk is yours to take.

## What it does

- **Chats** — your chat list with folders as tabs, pinned, muted and archived chats, unread
  counts (or mark a chat unread), and drafts that follow you to your other devices. Pin (`p`),
  archive (`a`) and mute (`m`) from the keyboard, or right-click a chat. Start a chat with a
  contact or anyone's @username, or create a group or a channel (`Ctrl+Shift+N`, or the pencil).
  Your chat with yourself is Saved Messages, and a forum group opens on its topics.
- **Chat info** — a panel (`Ctrl+I`) with a person's bio, username and phone, or a group's
  description and invite link; its members; and everything shared in it: photos and videos,
  files, links, voice messages, music and GIFs. Leave a group, or clear or delete a chat, from it.
- **Messages** — send, reply, edit, forward, pin, react and delete (for you or for everyone),
  or select several and act on them at once. Read ticks, "typing…", last seen and the pinned
  message above the chat, with read state kept in sync with your other devices. Right-click a
  message (or press `m`) for everything Telegram allows on it.
- **Rich messages** — formatting, links, mentions and hashtags, spoilers, link previews, polls
  you can vote in, places, contacts, albums, service messages ("Ann joined the group"), and
  bots' buttons and keyboards. Web links open in your browser; Telegram links open in Omagram.
- **Media** — photos (with a full-size viewer), videos, GIFs, files, round video notes and
  voice messages with a waveform. Send photos and files with `Ctrl+O`, by dropping them on the
  chat or by pasting a copied image, and record voice messages (`Ctrl+R`) and round video
  messages (`Ctrl+Shift+R`). A file's menu opens it with its app or saves it to Downloads.
- **Emoji** — Omarchy's emoji picker, from the message box (`Ctrl+;`).
- **Account** — Settings shows how much Omagram keeps on this computer (and clears the cache),
  every device signed in to your account (sign any of them out), and signs you out here.
- **Stickers** — static, animated (TGS) and video (WebM) stickers, and a sticker picker with
  your recent stickers and installed sets.
- **Search** — chats in every list, and messages in all chats or in the open one.
- **Notifications** — one per chat, replaced as messages arrive and withdrawn when you read
  them anywhere. **Open** opens the chat; **Reply** opens the quick-reply overlay on it.
  Telegram's own mute settings and Omarchy's Do Not Disturb apply.
- **In the bar** — a message icon with a dot while unmuted chats have unread messages. Left
  click opens a panel of recent chats where you can reply inline; right click opens the window.
- **Quick reply** — an overlay to find a chat by typing, read its latest messages and answer.

Not supported yet: secret chats, calls and stories.

## Requirements

Omarchy with Hyprland 0.56 or newer, and these packages (most are already on a stock install):

```bash
sudo pacman -S --needed qt6-multimedia qt6-multimedia-ffmpeg qt6-lottie libsecret python-gobject qrencode
```

TDLib is not packaged for Arch, so Omagram builds the exact version it was tested with (1.8.67)
into your home directory. That needs, once:

```bash
sudo pacman -S --needed git cmake gperf clang openssl zlib
```

## Install

```bash
omarchy plugin add https://github.com/ReidenXerx/omagram.git --enable
~/.config/omarchy/plugins/reidenxerx.omagram/bin/omagram-build-tdlib
```

The build takes about ten minutes and roughly 2 GB of memory per parallel job (it picks the
job count from your memory). Nothing is installed system-wide and nothing needs root:
the library ends up in `~/.local/share/omagram/lib/`. `omagram-build-tdlib --check` tells you
whether a usable library is installed.

Optionally add Omagram to the Omarchy menu (Trigger → Omagram):

```bash
~/.config/omarchy/plugins/reidenxerx.omagram/bin/omagram-menu-install
```

## Sign in

1. Create your own API id at [my.telegram.org](https://my.telegram.org) → *API development
   tools*. Telegram requires every client to use its own id; Omagram does not ship one.
2. Open Omagram — from the menu, by right-clicking the bar icon, or with
   `/usr/bin/python3 ~/.config/omarchy/plugins/reidenxerx.omagram/bin/omagram`.
3. Enter the API id and hash, then your phone number, the code Telegram sends you, and your
   two-step verification password if you have one. Or choose **Use a QR code instead** and scan
   it with Telegram on your phone (Settings → Devices → Link Desktop Device); drawing the code
   needs `qrencode`.

The API id and hash go straight into your keyring; they are never written to a file.

## Keys

These are the defaults. **Every one of them can be changed in Settings** — the gear in the chat
list, or `Ctrl+,`: choose an action, press Enter and then the new keys (A adds a key, Backspace
removes one, R resets it). Settings shows when two actions would fight over the same keys, and its
own keys never change, so a bad choice can always be undone. Your choices are kept in
`~/.config/omagram/settings.json`.

**Window**

| key | action |
|---|---|
| `Ctrl+K` / `Ctrl+F` | search chats and messages |
| `Ctrl+Shift+F` | search in the open chat |
| `Alt+↑` / `Alt+↓` | previous / next chat |
| `Ctrl+PgUp` / `Ctrl+PgDn`, `Ctrl+[` / `Ctrl+]` | previous / next folder tab |
| `Ctrl+1` / `Ctrl+2` / `Ctrl+3` | chat list / messages / composer |
| `Ctrl+;` or `Ctrl+.` | emoji |
| `Ctrl+M` | jump to the next message that mentions you |
| `Ctrl+Shift+M` | mute or unmute the open chat |
| `Ctrl+Shift+P` | go to the pinned message |
| `Ctrl+I` | the chat's info (`Tab` switches its tabs, `Enter` opens, `Esc` closes) |
| `Ctrl+Shift+N` | start a chat, a group or a channel (`Enter` opens or adds, `Ctrl+Enter` goes on) |
| `Alt+←` | from a forum's topic back to its topics |
| `Ctrl+,` | settings |

**Chat list**

| key | action |
|---|---|
| `↑` `↓` or `j` `k`, `g` / `G` | move, first / last |
| `Enter`, `l` or `→` | open the chat (or the message found) |
| `/` | search |
| `[` / `]` | previous / next tab |
| `p` | pin or unpin |
| `a` | archive or unarchive |
| `m` | mute or unmute |
| `Menu` or `Shift+F10` | the chat's menu (so does a right click) |
| `Tab` | go to the open chat |

**Messages**

| key | action |
|---|---|
| `↑` `↓` or `j` `k` | select a message |
| `Enter` or `o` | download or open its media |
| `Space` | play or pause |
| `r` / `e` / `y` | reply / edit yours / copy |
| `f` / `p` / `s` | forward / pin or unpin / save its file to Downloads |
| `Shift+Y` | copy a link to the message |
| `x` | select or unselect (so does Ctrl+click); `f`, `y` and `d` then act on everything selected |
| `m`, `Menu` or `Shift+F10` | the message's menu (so does a right click) |
| `d` or `Delete` | delete (press again to confirm) |
| `Esc` or `i` | clear the selection, or back to the composer |

**Composer**

| key | action |
|---|---|
| `Enter` / `Shift+Enter` | send / new line |
| `↑` in an empty composer | edit your last message |
| `Esc` | cancel a reply or edit |
| `Ctrl+O` / `Ctrl+Shift+O` | attach photos / send files uncompressed |
| `Ctrl+V` with an image copied | send the image (it asks first) |
| `Ctrl+S` | stickers (arrows or `hjkl`, `Tab` switches sets, `Enter` sends) |
| `Ctrl+R` | record a voice message (`Enter` sends, `Esc` cancels) |
| `Ctrl+Shift+R` | record a round video message (`Enter` starts, then sends) |

**Menus and questions** — in a menu `↑` `↓` or `j` `k` choose, `Enter` picks, `Esc` closes, and
`1`–`8` pick a quick reaction. When the bar above the message box asks something (deleting,
joining a group, opening a file that could run a program), `Enter` answers yes and `Esc` no. In
the forward dialog, type to find a chat, `↑` `↓` or `Ctrl+N` `Ctrl+P` choose and `Enter` forwards.

**From anywhere** — pick keys for quick reply, the bar panel and opening Omagram in Settings →
*Shortcuts that work anywhere*. Omagram registers them with Hyprland while it runs, never writes
them into your Hyprland config, leaves combinations you already use alone (Settings shows them as
taken), and only ever removes bindings it made. Or bind the commands yourself:

```bash
omarchy-shell shell toggle reidenxerx.omagram '{}'   # quick reply: find a chat and answer
omarchy-shell reidenxerx.omagram.panel toggle        # the bar panel
```

In the quick-reply overlay: type to search, `↑` `↓` or `Ctrl+J` `Ctrl+K` to choose, `Enter`
to reply and `Enter` again to send, `Ctrl+O` to open the chat in the window, `Esc` to go back.

## How it is put together

- **`bin/omagramd`** — the service. It holds the Telegram session through TDLib and serves
  the window, the bar and the overlay over a Unix socket. Omarchy's shell keeps it running;
  the window starts it too if needed, and only one instance ever runs.
- **`bin/omagram`** — opens or focuses the window, a separate Quickshell process with its own
  Hyprland class `omagram`, so it tiles and takes window rules like any application.
  `omagram --chat <id>` opens it at a chat.
- **`shell/`** — the parts that live inside Omarchy's shell: the service entry, the bar widget
  and its panel, and the quick-reply overlay.

## Privacy and security

- **Your data stays on your machine**, in `~/.local/share/omagram` (TDLib's database, encrypted
  with a key kept in your keyring, downloaded files, and in `sent/` the voice and video messages you
  send, so your own messages play from them) and `~/.cache/omagram` (the
  TDLib build and unpacked animated stickers). Omagram sends nothing anywhere except to Telegram.
- **Secrets are never in files, command lines or logs.** The API id, hash and database key
  move through `secret-tool` on stdin and stdout. TDLib's own log is off, because at higher
  verbosity it records message text.
- **Only you can talk to the service.** Its socket is `0600` in your runtime directory, and it
  checks every connection's user id.
- **Telegram content is shown as text.** Names and previews are rendered as plain text, message
  formatting is escaped before it is drawn, and notification bodies are escaped, because
  Omarchy's notifications render markup and links. Links lead only to web and mail addresses
  (opened in your browser) or inside Omagram; joining a group, starting a bot and opening a file
  that could run a program (a script, an executable, a `.desktop` file, a web page) ask first.
- **Bounded and checked.** Every request is validated field by field; network strings, lists
  and animated stickers are size-capped; files you send must be regular, readable files of at
  most 2 GB outside Omagram's own database; helpers run by absolute path as argument lists,
  never through a shell.
- **The library is only loaded if it is safe to.** `libtdjson.so` is used only if it is a
  regular file you own that nobody else can write, in directories you own.

`bin/plugin_safety.py` is a shared safety library vendored unchanged into each of these plugins.

```bash
python3 tests/state_test.py     # TDLib objects → what the UI sees, hostile values
python3 tests/daemon_test.py    # the service on a sandboxed socket with a fake TDLib
python3 tests/notify_test.py    # notifications with a fake bus
python3 tests/media_test.py     # preparing voice and video messages
python3 tests/settings_test.py  # settings and global shortcuts, with Hyprland faked
node tests/model-test.js        # the window's list, message and menu logic
node tests/keymap-test.js       # shortcuts: parsing, matching, clashes
```

## Remove

```bash
bin/omagram-menu-install remove                 # if you added the menu entries
omarchy plugin remove reidenxerx.omagram
rm -rf ~/.local/share/omagram ~/.cache/omagram  # the session, downloads and the TDLib build
secret-tool clear service omagram               # the API id, hash and database key
```

Removing the data does not end the session on Telegram's side: to do that, terminate it from
Settings → Devices in another Telegram app.

## License

MIT. TDLib is © Aliaksei Levin and Arseny Smirnov, under the Boost Software License 1.0;
Omagram downloads and builds it on your machine and does not redistribute it. Omagram is an
independent project and is not affiliated with Telegram.
