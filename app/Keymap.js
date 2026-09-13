.pragma library

// Every keyboard shortcut in Omagram, and matching key presses against them.
//
// Keys are written the way Qt writes key sequences -- "Ctrl+Shift+R", "PgDown", "Return", "J",
// "/" -- so the same strings drive Shortcut elements and the key handlers that call matches().
// Settings keep only the actions whose keys differ from the defaults. Key codes are Qt's, which
// are stable, so this file needs no Qt object and is tested with node.

var SHIFT = 0x02000000
var CTRL = 0x04000000
var ALT = 0x08000000
var META = 0x10000000
var SEQUENCE_MAX = 40
var KEYS_MAX = 6

// Where an action applies. Within the window, "window" shortcuts work anywhere and win over
// every other key handler, so they clash with keys in every other scope of the window; the rest
// only clash within their own scope. The bar panel and the quick-reply overlay live in
// Omarchy's shell, never in the same window as the rest.
var SECTIONS = [
  { id: "window", title: "Anywhere in Omagram", scope: "window", app: "window" },
  { id: "list", title: "Chat list", scope: "list", app: "window" },
  { id: "messages", title: "Messages", scope: "messages", app: "window" },
  { id: "composer", title: "Message box", scope: "composer", app: "window" },
  { id: "suggest", title: "Suggestions while typing", scope: "suggest", app: "window" },
  { id: "voice", title: "Recording a voice message", scope: "voice", app: "window" },
  { id: "videoNote", title: "Recording a video message", scope: "videoNote", app: "window" },
  { id: "stickers", title: "Stickers", scope: "stickers", app: "window" },
  { id: "photo", title: "Photo viewer", scope: "photo", app: "window" },
  { id: "story", title: "Stories", scope: "story", app: "window" },
  { id: "menu", title: "Menus", scope: "menu", app: "window" },
  { id: "picker", title: "Choosing a chat to forward to", scope: "picker", app: "window" },
  { id: "prompt", title: "Questions above the message box", scope: "prompt", app: "window" },
  { id: "info", title: "Chat info", scope: "info", app: "window" },
  { id: "newChat", title: "Starting a chat", scope: "newChat", app: "window" },
  { id: "poll", title: "Making a poll", scope: "poll", app: "window" },
  { id: "topics", title: "A forum's topics", scope: "topics", app: "window" },
  { id: "panel", title: "Bar panel", scope: "panel", app: "shell" },
  { id: "quick", title: "Quick reply: finding a chat", scope: "quick", app: "shell" },
  { id: "quickMessage", title: "Quick reply: writing", scope: "quickMessage", app: "shell" }
]

var ACTIONS = [
  { id: "window.search", label: "Search chats and messages", keys: ["Ctrl+K", "Ctrl+F"] },
  { id: "window.searchInChat", label: "Search in the open chat", keys: ["Ctrl+Shift+F"] },
  { id: "window.previousChat", label: "Open the chat above", keys: ["Alt+Up"] },
  { id: "window.nextChat", label: "Open the chat below", keys: ["Alt+Down"] },
  { id: "window.previousTab", label: "Previous folder tab", keys: ["Ctrl+PgUp", "Ctrl+["] },
  { id: "window.nextTab", label: "Next folder tab", keys: ["Ctrl+PgDown", "Ctrl+]"] },
  { id: "window.focusList", label: "Go to the chat list", keys: ["Ctrl+1"] },
  { id: "window.focusMessages", label: "Go to the messages", keys: ["Ctrl+2"] },
  { id: "window.focusComposer", label: "Go to the message box", keys: ["Ctrl+3"] },
  { id: "window.attach", label: "Attach photos or files", keys: ["Ctrl+O"] },
  { id: "window.attachFiles", label: "Send files uncompressed", keys: ["Ctrl+Shift+O"] },
  { id: "window.stickers", label: "Stickers", keys: ["Ctrl+S"] },
  { id: "window.more", label: "A poll, dice, a contact card or a location", keys: ["Ctrl+Shift+A"] },
  { id: "window.voice", label: "Record a voice message", keys: ["Ctrl+R"] },
  { id: "window.videoNote", label: "Record a video message", keys: ["Ctrl+Shift+R"] },
  { id: "window.settings", label: "Settings", keys: ["Ctrl+,"] },
  { id: "window.emoji", label: "Emoji", keys: ["Ctrl+;", "Ctrl+."] },
  { id: "window.nextMention", label: "Jump to the next mention of you", keys: ["Ctrl+M"] },
  { id: "window.mute", label: "Mute or unmute the open chat", keys: ["Ctrl+Shift+M"] },
  { id: "window.pinnedMessage", label: "Go to the pinned message", keys: ["Ctrl+Shift+P"] },
  { id: "window.chatInfo", label: "Show or hide the chat's info", keys: ["Ctrl+I"] },
  { id: "window.newChat", label: "Start a chat, a group or a channel", keys: ["Ctrl+Shift+N"] },
  { id: "window.topicList", label: "Back to a forum's topics, or from comments to their post", keys: ["Alt+Left"] },
  { id: "window.stories", label: "Watch stories", keys: ["Ctrl+Shift+S"] },

  { id: "list.down", label: "Next chat", keys: ["Down", "J"] },
  { id: "list.up", label: "Previous chat", keys: ["Up", "K"] },
  { id: "list.pageDown", label: "Ten chats down", keys: ["PgDown"] },
  { id: "list.pageUp", label: "Ten chats up", keys: ["PgUp"] },
  { id: "list.first", label: "First chat", keys: ["Home", "G"] },
  { id: "list.last", label: "Last chat", keys: ["End", "Shift+G"] },
  { id: "list.open", label: "Open the chat or message", keys: ["Return", "Enter", "L", "Right"] },
  { id: "list.search", label: "Search", keys: ["/"] },
  { id: "list.previousTab", label: "Previous tab", keys: ["["] },
  { id: "list.nextTab", label: "Next tab", keys: ["]"] },
  { id: "list.pin", label: "Pin or unpin", keys: ["P"] },
  { id: "list.archive", label: "Archive or unarchive", keys: ["A"] },
  { id: "list.toChat", label: "Go to the open chat", keys: ["Tab"] },
  { id: "list.clearSearch", label: "Clear the search", keys: ["Esc"] },
  { id: "list.mute", label: "Mute or unmute", keys: ["M"] },
  { id: "list.menu", label: "The chat's menu", keys: ["Menu", "Shift+F10"] },

  { id: "messages.down", label: "Next message", keys: ["Down", "J"] },
  { id: "messages.up", label: "Previous message", keys: ["Up", "K"] },
  { id: "messages.last", label: "Last message", keys: ["End"] },
  { id: "messages.open", label: "Download or open media", keys: ["Return", "Enter", "O"] },
  { id: "messages.play", label: "Play or pause", keys: ["Space"] },
  { id: "messages.reply", label: "Reply", keys: ["R"] },
  { id: "messages.edit", label: "Edit your message", keys: ["E"] },
  { id: "messages.copy", label: "Copy the text", keys: ["Y"] },
  { id: "messages.delete", label: "Delete (press twice)", keys: ["D", "Del"] },
  { id: "messages.toComposer", label: "Back to the message box (clears a selection first)", keys: ["Esc", "I"] },
  { id: "messages.toList", label: "Go to the chat list", keys: ["Tab"] },
  { id: "messages.menu", label: "The message's menu", keys: ["M", "Menu", "Shift+F10"] },
  { id: "messages.forward", label: "Forward", keys: ["F"] },
  { id: "messages.select", label: "Select or unselect", keys: ["X"] },
  { id: "messages.pin", label: "Pin or unpin", keys: ["P"] },
  { id: "messages.save", label: "Save the file to Downloads", keys: ["S"] },
  { id: "messages.link", label: "Copy a link to the message", keys: ["Shift+Y"] },
  { id: "messages.thread", label: "The post's comments, or the replies to the message", keys: ["C"] },
  { id: "messages.speed", label: "Voice and video messages at 1×, 1.5× or 2×", keys: ["."] },

  { id: "composer.send", label: "Send", keys: ["Return", "Enter"] },
  { id: "composer.newLine", label: "New line", keys: ["Shift+Return", "Shift+Enter"] },
  { id: "composer.sendSilent", label: "Send without sound", keys: ["Ctrl+Shift+Return", "Ctrl+Shift+Enter"] },
  { id: "composer.later", label: "Send later, quietly or when online", keys: ["Ctrl+Alt+Return", "Ctrl+Alt+Enter"] },
  { id: "composer.bold", label: "Bold: **text**", keys: ["Ctrl+B"] },
  { id: "composer.italic", label: "Italic: __text__", keys: ["Ctrl+Shift+I"] },
  { id: "composer.strikethrough", label: "Strikethrough: ~~text~~", keys: ["Ctrl+Shift+X"] },
  { id: "composer.code", label: "Code: `text`", keys: ["Ctrl+E"] },
  { id: "composer.spoiler", label: "Spoiler: ||text||", keys: ["Ctrl+Shift+H"] },
  { id: "composer.link", label: "Link: [text](address)", keys: ["Ctrl+L"] },
  { id: "composer.cancel", label: "Cancel a reply or edit", keys: ["Esc"] },
  { id: "composer.editLast", label: "Edit your last message (empty box)", keys: ["Up"] },
  { id: "composer.toMessages", label: "Go to the messages", keys: ["Tab"] },

  { id: "suggest.next", label: "Next suggestion", keys: ["Down"] },
  { id: "suggest.previous", label: "Previous suggestion", keys: ["Up"] },
  { id: "suggest.pick", label: "Put the suggestion in", keys: ["Tab"] },
  { id: "suggest.send", label: "Put it in (a bot command is sent at once)", keys: ["Return", "Enter"] },
  { id: "suggest.close", label: "Close the suggestions", keys: ["Esc"] },

  { id: "voice.send", label: "Send the voice message", keys: ["Return", "Enter"] },
  { id: "voice.cancel", label: "Cancel the voice message", keys: ["Esc"] },

  { id: "videoNote.record", label: "Start recording, then send", keys: ["Return", "Enter", "Space"] },
  { id: "videoNote.cancel", label: "Cancel", keys: ["Esc"] },

  { id: "stickers.left", label: "Move left", keys: ["Left", "H"] },
  { id: "stickers.right", label: "Move right", keys: ["Right", "L"] },
  { id: "stickers.up", label: "Move up", keys: ["Up", "K"] },
  { id: "stickers.down", label: "Move down", keys: ["Down", "J"] },
  { id: "stickers.nextSet", label: "Next sticker set", keys: ["Tab"] },
  { id: "stickers.previousSet", label: "Previous sticker set", keys: ["Shift+Tab"] },
  { id: "stickers.send", label: "Send the sticker", keys: ["Return", "Enter"] },
  { id: "stickers.close", label: "Close", keys: ["Esc"] },
  { id: "stickers.favorite", label: "Add the sticker to your favorites, or take it out of them", keys: ["F"] },
  { id: "stickers.install", label: "Add the sticker set to yours, or remove it", keys: ["A"] },

  { id: "photo.previous", label: "Previous photo", keys: ["Left", "H"] },
  { id: "photo.next", label: "Next photo", keys: ["Right", "L"] },
  { id: "photo.close", label: "Close", keys: ["Esc", "Q"] },

  { id: "story.previous", label: "Previous story", keys: ["Left", "H"] },
  { id: "story.next", label: "Next story", keys: ["Right", "L"] },
  { id: "story.pause", label: "Pause or play", keys: ["Space"] },
  { id: "story.close", label: "Close", keys: ["Esc", "Q"] },

  { id: "menu.down", label: "Next item", keys: ["Down", "J"] },
  { id: "menu.up", label: "Previous item", keys: ["Up", "K"] },
  { id: "menu.pick", label: "Choose the item", keys: ["Return", "Enter"] },
  { id: "menu.close", label: "Close", keys: ["Esc"] },

  { id: "picker.down", label: "Next chat", keys: ["Down", "Ctrl+N"] },
  { id: "picker.up", label: "Previous chat", keys: ["Up", "Ctrl+P"] },
  { id: "picker.pick", label: "Forward there", keys: ["Return", "Enter"] },
  { id: "picker.close", label: "Cancel", keys: ["Esc"] },

  { id: "prompt.accept", label: "Yes", keys: ["Return", "Enter"] },
  { id: "prompt.cancel", label: "No", keys: ["Esc"] },

  { id: "info.down", label: "Next", keys: ["Down", "J"] },
  { id: "info.up", label: "Previous", keys: ["Up", "K"] },
  { id: "info.open", label: "Open the member or the message", keys: ["Return", "Enter"] },
  { id: "info.nextTab", label: "Next tab", keys: ["Tab", "]"] },
  { id: "info.previousTab", label: "Previous tab", keys: ["Shift+Tab", "["] },
  { id: "info.close", label: "Close", keys: ["Esc"] },

  { id: "newChat.down", label: "Next", keys: ["Down", "Ctrl+N"] },
  { id: "newChat.up", label: "Previous", keys: ["Up", "Ctrl+P"] },
  { id: "newChat.pick", label: "Open the chat, or add or remove the person", keys: ["Return", "Enter"] },
  { id: "newChat.next", label: "Next step, or create", keys: ["Ctrl+Return", "Ctrl+Enter"] },
  { id: "newChat.back", label: "Back, or close", keys: ["Esc"] },

  { id: "poll.send", label: "Send the poll", keys: ["Ctrl+Return", "Ctrl+Enter"] },
  { id: "poll.next", label: "The next field", keys: ["Tab"] },
  { id: "poll.previous", label: "The field before", keys: ["Shift+Tab"] },
  { id: "poll.right", label: "Make the answer you are in the right one (a quiz)", keys: ["Alt+R"] },
  { id: "poll.close", label: "Cancel", keys: ["Esc"] },

  { id: "topics.down", label: "Next topic", keys: ["Down", "J"] },
  { id: "topics.up", label: "Previous topic", keys: ["Up", "K"] },
  { id: "topics.open", label: "Open the topic", keys: ["Return", "Enter", "L", "Right"] },

  { id: "panel.reply", label: "Reply to the chat", keys: ["R"] },
  { id: "panel.openInWindow", label: "Open it in the window", keys: ["O"] },

  { id: "quick.down", label: "Next chat", keys: ["Down", "Ctrl+J", "Ctrl+N"] },
  { id: "quick.up", label: "Previous chat", keys: ["Up", "Ctrl+K", "Ctrl+P"] },
  { id: "quick.pageDown", label: "Eight chats down", keys: ["PgDown"] },
  { id: "quick.pageUp", label: "Eight chats up", keys: ["PgUp"] },
  { id: "quick.reply", label: "Reply to the chat", keys: ["Return", "Enter"] },
  { id: "quick.openInWindow", label: "Open it in the window", keys: ["Ctrl+O"] },
  { id: "quick.close", label: "Clear the search, then close", keys: ["Esc"] },

  { id: "quickMessage.send", label: "Send", keys: ["Return", "Enter"] },
  { id: "quickMessage.back", label: "Back to finding a chat", keys: ["Esc"] },
  { id: "quickMessage.openInWindow", label: "Open it in the window", keys: ["Ctrl+O"] }
]

var MODIFIER_KEYS = [0x01000020, 0x01000021, 0x01000022, 0x01000023, 0x01001103, 0x01000024, 0x01000025]

var NAMED_CODES = {
  "16777216": "Esc", "16777217": "Tab", "16777218": "Tab", "16777219": "Backspace", "16777220": "Return",
  "16777221": "Enter", "16777222": "Ins", "16777223": "Del", "16777232": "Home", "16777233": "End",
  "16777234": "Left", "16777235": "Up", "16777236": "Right", "16777237": "Down", "16777238": "PgUp",
  "16777239": "PgDown", "16777301": "Menu", "32": "Space"
}

var ALIASES = {
  esc: "Esc", escape: "Esc", tab: "Tab", backspace: "Backspace", return: "Return", enter: "Enter",
  ins: "Ins", insert: "Ins", del: "Del", delete: "Del", home: "Home", end: "End", left: "Left", up: "Up",
  right: "Right", down: "Down", pgup: "PgUp", pageup: "PgUp", pgdown: "PgDown", pagedown: "PgDown",
  space: "Space", menu: "Menu"
}

var MODIFIER_NAMES = { ctrl: CTRL, control: CTRL, alt: ALT, shift: SHIFT, meta: META, super: META, win: META }

var ORDER = [[CTRL, "Ctrl"], [ALT, "Alt"], [SHIFT, "Shift"], [META, "Meta"]]

function actionById(id) {
  for (var i = 0; i < ACTIONS.length; i++) if (ACTIONS[i].id === id) return ACTIONS[i]
  return null
}

function sectionOf(id) {
  var name = String(id).split(".")[0]
  for (var i = 0; i < SECTIONS.length; i++) if (SECTIONS[i].id === name) return SECTIONS[i]
  return null
}

function join(mods, name) {
  var parts = []
  for (var i = 0; i < ORDER.length; i++) if (mods & ORDER[i][0]) parts.push(ORDER[i][1])
  parts.push(name)
  return parts.join("+")
}

// Shift is part of what a punctuation key types ("?" is Shift+/), so it only counts for letters
// and named keys.
function shiftCounts(name) {
  return name.length > 1 || /^[A-Z]$/.test(name)
}

function keyName(key) {
  if (NAMED_CODES.hasOwnProperty(String(key))) return NAMED_CODES[String(key)]
  if (key >= 0x01000030 && key <= 0x01000052) return "F" + (key - 0x01000030 + 1)
  if (key >= 0x21 && key <= 0x7e) return String.fromCharCode(key).toUpperCase()
  return ""
}

// The sequence a key press stands for ("Ctrl+Shift+R"), or "" for a lone modifier or a key
// with no name.
function fromEvent(key, modifiers) {
  if (MODIFIER_KEYS.indexOf(key) >= 0) return ""
  var name = keyName(key)
  if (!name) return ""
  var mods = modifiers & (SHIFT | CTRL | ALT | META)
  if (key === 0x01000002) mods |= SHIFT   // Backtab is how Qt reports Shift+Tab
  if (!shiftCounts(name)) mods &= ~SHIFT
  return join(mods, name)
}

// A sequence as settings or people write it ("ctrl + shift + r", "Page Down") in the one form
// used everywhere ("Ctrl+Shift+R", "PgDown"); "" if it is not a single key with modifiers.
function normalize(sequence) {
  if (typeof sequence !== "string") return ""
  var s = sequence.trim()
  if (!s || s.length > SEQUENCE_MAX) return ""
  var keyToken = ""
  var body = s
  if (s === "+") return "+"
  if (/\+\s*\+$/.test(s)) {   // "Ctrl++": the key is "+"
    keyToken = "+"
    body = s.replace(/\+\s*\+$/, "")
  } else {
    var at = s.lastIndexOf("+")
    keyToken = at < 0 ? s : s.slice(at + 1)
    body = at < 0 ? "" : s.slice(0, at)
  }
  var mods = 0
  if (body.trim() !== "") {
    var tokens = body.split("+")
    for (var i = 0; i < tokens.length; i++) {
      var t = tokens[i].trim().toLowerCase()
      if (!MODIFIER_NAMES.hasOwnProperty(t)) return ""
      mods |= MODIFIER_NAMES[t]
    }
  }
  var k = keyToken.trim()
  var lower = k.toLowerCase().replace(/\s+/g, "")
  var name = ""
  if (ALIASES.hasOwnProperty(lower)) name = ALIASES[lower]
  else if (lower === "backtab") { name = "Tab"; mods |= SHIFT }
  else if (/^f([1-9]|[12][0-9]|3[0-5])$/.test(lower)) name = "F" + lower.slice(1)
  else if (k.length === 1 && k.charCodeAt(0) >= 0x21 && k.charCodeAt(0) <= 0x7e) name = k.toUpperCase()
  if (!name) return ""
  if (!shiftCounts(name)) mods &= ~SHIFT
  return join(mods, name)
}

function uniqueNormalized(list) {
  var out = []
  for (var i = 0; i < list.length && out.length < KEYS_MAX; i++) {
    var n = normalize(list[i])
    if (n && out.indexOf(n) < 0) out.push(n)
  }
  return out
}

function defaultsFor(id) {
  var action = actionById(id)
  return action ? uniqueNormalized(action.keys) : []
}

// The keys for an action: the settings' choice if there is one (an empty list switches it
// off), otherwise the defaults.
function keysFor(overrides, id) {
  var own = overrides && Object.prototype.hasOwnProperty.call(overrides, id) ? overrides[id] : null
  return Array.isArray(own) || own instanceof Array ? uniqueNormalized(own) : defaultsFor(id)   // also a QML sequence
}

function matches(overrides, id, event) {
  if (!event) return false
  var sequence = fromEvent(event.key, event.modifiers)
  return sequence !== "" && keysFor(overrides, id).indexOf(sequence) >= 0
}

// Whether a sequence types a character: a letter, digit or symbol with no Ctrl, Alt or Meta.
function types(sequence) {
  return /^(Shift\+)?[\x21-\x7e]$/.test(sequence) || /^(Shift\+)?Space$/.test(sequence)
}

// For keys pressed in a text field: a key that types a character is text, never a shortcut,
// so "L" to open a chat cannot swallow an "l" typed into a search.
function matchesInText(overrides, id, event) {
  if (!event) return false
  var sequence = fromEvent(event.key, event.modifiers)
  return sequence !== "" && !types(sequence) && keysFor(overrides, id).indexOf(sequence) >= 0
}

// A key typed in a panel's key catcher arrives as text ("r").
function matchesText(overrides, id, text) {
  var sequence = normalize(String(text || ""))
  return sequence !== "" && keysFor(overrides, id).indexOf(sequence) >= 0
}

// Only what differs from the defaults is stored.
function withKeys(overrides, id, keys) {
  var next = {}
  for (var k in overrides || {}) if (k !== id) next[k] = overrides[k]
  var chosen = uniqueNormalized(keys || [])
  if (chosen.join("|") !== defaultsFor(id).join("|")) next[id] = chosen
  return next
}

// Actions that would fight over the same keys: [{ sequence, ids }].
function conflicts(overrides) {
  var owners = {}
  for (var i = 0; i < ACTIONS.length; i++) {
    var id = ACTIONS[i].id
    var keys = keysFor(overrides, id)
    for (var j = 0; j < keys.length; j++) {
      if (!owners[keys[j]]) owners[keys[j]] = []
      owners[keys[j]].push(id)
    }
  }
  var out = []
  for (var sequence in owners) {
    var ids = owners[sequence]
    var clashing = []
    for (var a = 0; a < ids.length; a++) {
      for (var b = a + 1; b < ids.length; b++) {
        var sa = sectionOf(ids[a])
        var sb = sectionOf(ids[b])
        // While a voice message records, its keys deliberately take over Enter and Esc.
        var voice = sa.scope === "voice" || sb.scope === "voice"
        if (sa.scope === sb.scope || (sa.app === sb.app && !voice && (sa.scope === "window" || sb.scope === "window"))) {
          if (clashing.indexOf(ids[a]) < 0) clashing.push(ids[a])
          if (clashing.indexOf(ids[b]) < 0) clashing.push(ids[b])
        }
      }
    }
    if (clashing.length) out.push({ sequence: sequence, ids: clashing })
  }
  out.sort(function (x, y) { return x.sequence < y.sequence ? -1 : (x.sequence > y.sequence ? 1 : 0) })
  return out
}

function conflictsFor(overrides, id) {
  var found = conflicts(overrides)
  var out = []
  for (var i = 0; i < found.length; i++) if (found[i].ids.indexOf(id) >= 0) out.push(found[i])
  return out
}

var HYPRLAND_KEYS = {
  Space: "SPACE", Return: "RETURN", Enter: "RETURN", Tab: "TAB", Esc: "ESCAPE", Backspace: "BACKSPACE", Del: "DELETE",
  Home: "HOME", End: "END", Up: "UP", Down: "DOWN", Left: "LEFT", Right: "RIGHT", PgUp: "PAGE_UP", PgDown: "PAGE_DOWN",
  ",": "COMMA", ".": "PERIOD", "/": "SLASH", ";": "SEMICOLON", "'": "APOSTROPHE", "-": "MINUS", "=": "EQUAL",
  "[": "BRACKETLEFT", "]": "BRACKETRIGHT", "\\": "BACKSLASH", "`": "GRAVE"
}

// A Qt sequence ("Meta+Alt+M") as Hyprland writes a combination ("SUPER + ALT + M"), or "" when
// Hyprland cannot bind it or it has no Super, Ctrl or Alt (a global shortcut must not eat typing).
function toHyprland(sequence) {
  var n = normalize(sequence)
  if (!n || n === "+" || /\+\+$/.test(n)) return ""
  var parts = n.split("+")
  var key = parts.pop()
  var mods = []
  if (parts.indexOf("Meta") >= 0) mods.push("SUPER")
  if (parts.indexOf("Ctrl") >= 0) mods.push("CTRL")
  if (parts.indexOf("Alt") >= 0) mods.push("ALT")
  if (!mods.length) return ""
  if (parts.indexOf("Shift") >= 0) mods.push("SHIFT")
  var name = HYPRLAND_KEYS.hasOwnProperty(key) ? HYPRLAND_KEYS[key]
           : (/^([A-Z0-9]|F([1-9]|1[0-9]|2[0-4]))$/.test(key) ? key : "")
  return name ? mods.concat([name]).join(" + ") : ""
}

var GLYPHS = { Up: "↑", Down: "↓", Left: "←", Right: "→", Return: "Enter", Enter: "Keypad Enter", PgUp: "Page Up", PgDown: "Page Down" }

// "Ctrl + ↑" for showing a sequence.
function label(sequence) {
  var n = normalize(sequence)
  if (!n) return ""
  if (n === "+") return "+"
  var parts = /\+\+$/.test(n) ? n.slice(0, -2).split("+").concat(["+"]) : n.split("+")
  return parts.map(function (p) { return GLYPHS.hasOwnProperty(p) ? GLYPHS[p] : p }).join(" + ")
}
