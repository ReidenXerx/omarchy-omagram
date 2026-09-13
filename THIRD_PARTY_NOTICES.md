# Third-party notices

Omagram's code is MIT (see `LICENSE`). It talks to Telegram through TDLib, which is not part of this
repository: it is built on your computer when Omagram is set up, from https://github.com/tdlib/td
(Boost Software License 1.0, Copyright Aliaksei Levin and Arseny Smirnov).

## Emoji, symbols and kaomoji

`app/emoji/` is taken unchanged from the Omarchy emoji picker plugin by the same author
(https://github.com/ReidenXerx/omarchy-emoji-picker, MIT): `EmojiModel.js`, and its data files, which
that plugin's `tools/build-data.py` generates from:

- Unicode emoji data: `emoji-test.txt`, Unicode Emoji 16.0 (https://www.unicode.org/Public/emoji/16.0/),
  for the emoji, their grouping, order and skin tones.
- Unicode CLDR annotations for English, Ukrainian and Russian (https://github.com/unicode-org/cldr-json,
  revision `1aaabe99aa65`), for the names and keywords of emoji and symbols.

  Both under the Unicode License V3, `LICENSES/Unicode-3.0.txt`. Copyright © 1991-2026 Unicode, Inc.

- emoticon-data (https://github.com/w33ble/emoticon-data, revision `92b6211ec2a9`) for the kaomoji, whose
  tags were grouped and given Ukrainian and Russian search words; the kaomoji themselves are unchanged.
  MIT, `LICENSES/emoticon-data-MIT.txt`. Copyright (c) 2014 Joe Fleming.
