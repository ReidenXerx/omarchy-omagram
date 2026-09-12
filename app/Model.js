.pragma library

// Pure display logic for Omagram's window: no QML, no I/O (node tests/model-test.js).

var CHATS_MAX = 500
var MESSAGES_MAX = 3000
var PREVIEW_MAX = 120
var RUN_GAP_SECONDS = 300

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
var MONTHS_LONG = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                   "October", "November", "December"]
var WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var WEEKDAYS_LONG = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

var KIND_LABELS = {
  photo: "Photo", sticker: "Sticker", gif: "GIF", voice: "Voice message", videoNote: "Video message",
  video: "Video", file: "File", audio: "Audio", contact: "Contact", location: "Location", poll: "Poll",
  service: "Service message", unsupported: "Unsupported message"
}

// A list that reaches QML through a model's modelData is a QML sequence: an instance of Array, with
// its methods, for which Array.isArray is false -- and which concat does not spread.
function isList(value) {
  return Array.isArray(value) || value instanceof Array
}

// A list as a JS array, for what needs one (concat); [] for anything else.
function toList(value) {
  return Array.isArray(value) ? value : (value instanceof Array ? Array.prototype.slice.call(value) : [])
}

function isObject(value) {
  return value !== null && typeof value === "object" && !isList(value)
}

// ---------------------------------------------------------------- chats

// Chat order is an int64 sent as a decimal string and compared as text: a JavaScript
// number would round it and shuffle chats that differ only in the low bits.
function compareOrder(a, b) {
  a = /^[0-9]{1,20}$/.test(String(a)) ? String(a).replace(/^0+(?=.)/, "") : "0"
  b = /^[0-9]{1,20}$/.test(String(b)) ? String(b).replace(/^0+(?=.)/, "") : "0"
  if (a.length !== b.length) return a.length < b.length ? -1 : 1
  return a < b ? -1 : (a > b ? 1 : 0)
}

// A chat's order in one list, as text; "0" when it is not in that list.
function orderIn(chat, listKey) {
  var key = listKey || "main"
  if (!isObject(chat)) return "0"
  if (isObject(chat.positions)) return isObject(chat.positions[key]) ? String(chat.positions[key].order) : "0"
  return key === "main" && isList(chat.lists) && chat.lists.indexOf("main") >= 0 ? String(chat.order) : "0"
}

function pinnedIn(chat, listKey) {
  var key = listKey || "main"
  if (isObject(chat) && isObject(chat.positions)) return isObject(chat.positions[key]) && chat.positions[key].pinned === true
  return key === "main" && isObject(chat) && chat.pinned === true
}

function sortChats(chats, listKey) {
  var key = listKey || "main"
  var list = toList(chats).filter(function (c) { return isObject(c) && typeof c.id === "number" })
  return list.sort(function (x, y) { return compareOrder(orderIn(y, key), orderIn(x, key)) || (x.id - y.id) }).slice(0, CHATS_MAX)
}

// Insert or replace one chat; a chat that has left the list (order 0, archived) drops out.
function upsertChat(chats, chat, listKey) {
  if (!isObject(chat) || typeof chat.id !== "number") return chats
  var key = listKey || "main"
  var out = chats.filter(function (c) { return c.id !== chat.id })
  if (compareOrder(orderIn(chat, key), "0") > 0) out.push(chat)
  return sortChats(out, key)
}

// Every known chat, whatever list it is in; the window picks a tab's chats with chatsIn().
function upsertKnown(chats, chat) {
  if (!isObject(chat) || typeof chat.id !== "number") return chats
  var out = chats.filter(function (c) { return c.id !== chat.id })
  out.push(chat)
  return out.length > CHATS_MAX ? out.slice(out.length - CHATS_MAX) : out
}

function chatsIn(chats, listKey) {
  var key = listKey || "main"
  return sortChats(toList(chats).filter(function (c) { return compareOrder(orderIn(c, key), "0") > 0 }), key)
}

// The tabs above the chat list: folders in Telegram's order with "All" where Telegram puts
// the main list, and the archive last.
function listTabs(folders, mainPosition) {
  var list = toList(folders).filter(function (f) { return isObject(f) && typeof f.id === "number" && f.id > 0 })
  var at = Math.max(0, Math.min(list.length, mainPosition | 0))
  var tabs = []
  for (var i = 0; i <= list.length; i++) {
    if (i === at) tabs.push({ key: "main", title: "All" })
    if (i < list.length) tabs.push({ key: "folder:" + list[i].id, title: String(list[i].name || "Folder") })
  }
  tabs.push({ key: "archive", title: "Archive" })
  return tabs
}

function findChat(chats, id) {
  for (var i = 0; i < chats.length; i++) if (chats[i].id === id) return chats[i]
  return null
}

function indexOfChat(chats, id) {
  for (var i = 0; i < chats.length; i++) if (chats[i].id === id) return i
  return -1
}

function filterChats(chats, query, meId) {
  var q = String(query || "").trim().toLowerCase()
  if (!q) return chats
  return chats.filter(function (c) { return chatTitle(c, meId).toLowerCase().indexOf(q) >= 0 })
}

function unreadTotal(chats) {
  var n = 0
  for (var i = 0; i < chats.length; i++) if (!chats[i].muted) n += Math.max(0, chats[i].unread | 0)
  return n
}

// ---------------------------------------------------------------- messages

function mergeMessages(existing, incoming) {
  var byId = {}
  var all = toList(existing).concat(toList(incoming))
  for (var i = 0; i < all.length; i++) {
    var m = all[i]
    if (isObject(m) && typeof m.id === "number" && m.id > 0) byId[m.id] = m   // later wins
  }
  var out = Object.keys(byId).map(function (k) { return byId[k] })
  out.sort(function (a, b) { return a.id - b.id })
  return out.length > MESSAGES_MAX ? out.slice(out.length - MESSAGES_MAX) : out
}

function replaceMessage(existing, oldId, message) {
  return mergeMessages((existing || []).filter(function (m) { return m.id !== oldId }), [message])
}

function removeMessages(existing, ids) {
  var gone = {}
  for (var i = 0; i < (ids || []).length; i++) gone[ids[i]] = true
  return (existing || []).filter(function (m) { return !gone[m.id] })
}

function patchMessage(existing, id, patch) {
  return (existing || []).map(function (m) {
    if (m.id !== id) return m
    var copy = {}
    for (var k in m) copy[k] = m[k]
    for (var p in patch) copy[p] = patch[p]
    return copy
  })
}

function findMessage(messages, id) {
  for (var i = messages.length - 1; i >= 0; i--) if (messages[i].id === id) return messages[i]
  return null
}

function oldestId(messages) {
  return messages && messages.length ? messages[0].id : 0
}

function lastOwnEditable(messages) {
  for (var i = messages.length - 1; i >= 0; i--) {
    var m = messages[i]
    if (m.outgoing && !m.sending && isObject(m.content) && m.content.kind === "text") return m
  }
  return null
}

function incomingIds(messages, count) {
  var ids = []
  for (var i = messages.length - 1; i >= 0 && ids.length < count; i--) if (!messages[i].outgoing) ids.push(messages[i].id)
  return ids.reverse()
}

function contentLabel(content) {
  if (!isObject(content)) return ""
  if (content.kind === "text" || content.kind === "emoji") return ""
  if (content.kind === "sticker") return ((content.emoji || "") + " Sticker").trim()
  if (content.kind === "file" && content.fileName) return content.fileName
  return KIND_LABELS[content.kind] || "Message"
}

// One line for a reply quote or a notification: text if there is any, the kind otherwise.
function previewOf(message) {
  if (!isObject(message) || !isObject(message.content)) return ""
  var text = String(message.content.text || "").replace(/\s+/g, " ").trim()
  var label = contentLabel(message.content)
  var line = label && text ? label + ", " + text : (text || label)
  return line.length > PREVIEW_MAX ? line.slice(0, PREVIEW_MAX - 1) + "…" : line
}

function sameSender(a, b) {
  return isObject(a) && isObject(b) && isObject(a.sender) && isObject(b.sender)
    && a.sender.type === b.sender.type && a.sender.id === b.sender.id
}

// Consecutive messages from one sender within five minutes on one day read as one run.
function sameRun(previous, message) {
  return sameSender(previous, message) && message.outgoing === previous.outgoing
    && message.date - previous.date <= RUN_GAP_SECONDS && sameDay(previous.date, message.date)
}

// ---------------------------------------------------------------- time

function pad(n) {
  return (n < 10 ? "0" : "") + n
}

function sameDay(aSeconds, bSeconds) {
  var a = new Date(aSeconds * 1000)
  var b = new Date(bSeconds * 1000)
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate()
}

function daysBetween(earlierSeconds, nowMs) {
  var a = new Date(earlierSeconds * 1000)
  var b = new Date(nowMs)
  var startA = new Date(a.getFullYear(), a.getMonth(), a.getDate()).getTime()
  var startB = new Date(b.getFullYear(), b.getMonth(), b.getDate()).getTime()
  return Math.round((startB - startA) / 86400000)
}

function clock(seconds) {
  var d = new Date(seconds * 1000)
  return pad(d.getHours()) + ":" + pad(d.getMinutes())
}

// The time column of the chat list: 14:05 today, a weekday this week, a date before that.
function listTime(seconds, nowMs) {
  if (!(seconds > 0)) return ""
  var days = daysBetween(seconds, nowMs)
  var d = new Date(seconds * 1000)
  if (days <= 0) return clock(seconds)
  if (days < 7) return WEEKDAYS[d.getDay()]
  var date = d.getDate() + " " + MONTHS[d.getMonth()]
  return d.getFullYear() === new Date(nowMs).getFullYear() ? date : date + " " + d.getFullYear()
}

// The separator above the first message of each day.
function dayLabel(seconds, nowMs) {
  var days = daysBetween(seconds, nowMs)
  var d = new Date(seconds * 1000)
  if (days <= 0) return "Today"
  if (days === 1) return "Yesterday"
  if (days < 7) return WEEKDAYS_LONG[d.getDay()]
  var date = d.getDate() + " " + MONTHS_LONG[d.getMonth()]
  return d.getFullYear() === new Date(nowMs).getFullYear() ? date : date + " " + d.getFullYear()
}

// ---------------------------------------------------------------- media

var AUTO_DOWNLOAD_MAX = 10 * 1024 * 1024

// A file:// URL for a downloaded file, each path segment encoded so a "#" or a space in a
// file name cannot change what the URL points at.
function fileUrl(path) {
  if (typeof path !== "string" || path.charAt(0) !== "/" || path.indexOf("\0") >= 0) return ""
  return "file://" + path.split("/").map(encodeURIComponent).join("/")
}

function miniUrl(mini) {
  return isObject(mini) && typeof mini.data === "string" && /^[A-Za-z0-9+\/]+={0,2}$/.test(mini.data)
    ? "data:image/jpeg;base64," + mini.data : ""
}

function formatSize(bytes) {
  var n = Math.max(0, Math.floor(Number(bytes) || 0))
  if (n < 1024) return n + " B"
  if (n < 1048576) return (n / 1024).toFixed(n < 10240 ? 1 : 0) + " KB"
  if (n < 1073741824) return (n / 1048576).toFixed(n < 10485760 ? 1 : 0) + " MB"
  return (n / 1073741824).toFixed(1) + " GB"
}

function formatDuration(seconds) {
  var s = Math.max(0, Math.floor(Number(seconds) || 0))
  var h = Math.floor(s / 3600)
  var m = Math.floor(s % 3600 / 60)
  return (h ? h + ":" + pad(m) : String(m)) + ":" + pad(s % 60)
}

// Fit media into a box without distorting it; an unknown size gets the box width at 4:3.
function fitSize(width, height, maxWidth, maxHeight) {
  var w = Number(width) || 0
  var h = Number(height) || 0
  if (w <= 0 || h <= 0) return { width: Math.round(maxWidth), height: Math.round(maxWidth * 3 / 4) }
  var scale = Math.min(1, maxWidth / w, maxHeight / h)
  return { width: Math.max(1, Math.round(w * scale)), height: Math.max(1, Math.round(h * scale)) }
}

// What downloads by itself when a message comes into view: stickers and voice messages
// always; photos, GIFs and video messages up to 10 MB. Videos, files and audio wait for you.
// Only small media downloads by itself: anyone who can message you picks what lands on disk,
// and a "voice message" or sticker can claim to be any size.
function autoDownload(kind, size) {
  if (kind !== "sticker" && kind !== "voice" && kind !== "photo" && kind !== "gif" && kind !== "videoNote") return false
  return (Number(size) || 0) <= AUTO_DOWNLOAD_MAX
}

function progress(file) {
  if (!isObject(file) || !(file.size > 0)) return 0
  return Math.max(0, Math.min(1, (Number(file.downloaded) || 0) / file.size))
}

// ---------------------------------------------------------------- faces and input

function initials(title) {
  var words = String(title || "").trim().split(/\s+/).filter(function (w) { return w.length > 0 })
  var letters = words.slice(0, 2).map(function (w) { return Array.from(w)[0] || "" }).join("")
  return letters.toUpperCase() || "?"
}

function validApiId(value) {
  return /^[1-9][0-9]{0,9}$/.test(String(value || "").trim())
}

function validApiHash(value) {
  return /^[0-9a-f]{32}$/.test(String(value || "").trim())
}

function cleanPhone(value) {
  var digits = String(value || "").replace(/[\s()-]/g, "")
  return /^\+?[0-9]{5,20}$/.test(digits) ? digits : ""
}

function validCode(value) {
  return /^[0-9]{3,10}$/.test(String(value || "").trim())
}

// ---------------------------------------------------------------- rich text

function escapeHtml(value) {
  return String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")
}

// A web or mail link a message may lead to, or "" when it must not be followed from here.
// "example.com/page" is written without a scheme in messages, as Telegram shows it.
function safeUrl(url) {
  var u = String(url || "").trim()
  if (!u || u.length > 2048 || /[\s\x00-\x1f"<>\\`]/.test(u)) return ""
  if (/^(https?:\/\/|mailto:|tg:\/\/)/i.test(u)) return u
  if (/^[A-Za-z0-9.-]+\.[A-Za-z]{2,}([\/:?#].*)?$/.test(u)) return "https://" + u
  return ""
}

function linkFor(entity, piece) {
  switch (entity.type) {
  case "url": return safeUrl(piece)
  case "textUrl": return safeUrl(entity.url)
  case "email": return /^[^\s@]+@[^\s@]+$/.test(piece) ? "mailto:" + piece : ""
  case "mention": return "omagram:mention:" + encodeURIComponent(piece.replace(/^@/, ""))
  case "mentionName": return typeof entity.userId === "number" && entity.userId > 0 ? "omagram:user:" + entity.userId : ""
  case "hashtag": case "cashtag": return "omagram:search:" + encodeURIComponent(piece)
  case "botCommand": return "omagram:command:" + encodeURIComponent(piece)
  }
  return ""
}

// A message's text and formatting as the Rich Text a Text element shows. Everything that
// comes from Telegram is escaped; links lead only to checked web or mail addresses or to
// omagram: actions the window handles; a spoiler stays hidden until `revealed`.
var EMOJI_PX = 20

// What a sticker can be drawn from as a still image: a WebP sticker itself, or the still thumbnail
// of an animated one; null when there is neither.
function stillStickerFile(sticker) {
  if (!isObject(sticker)) return null
  if (sticker.format === "webp" && isObject(sticker.file)) return sticker.file
  var thumb = sticker.thumb
  return isObject(thumb) && isObject(thumb.file) && ["webp", "png", "jpeg"].indexOf(thumb.format) >= 0 ? thumb.file : null
}

// The custom emoji a message uses, by id, for asking the service for their stickers.
function customEmojiIds(entities) {
  var out = []
  var list = toList(entities)
  for (var i = 0; i < list.length && out.length < 50; i++) {
    var id = isObject(list[i]) && list[i].type === "customEmoji" ? String(list[i].customEmojiId || "") : ""
    if (/^-?[0-9]{1,19}$/.test(id) && out.indexOf(id) < 0) out.push(id)
  }
  return out
}

function richText(text, entities, revealed, codeBackground, emojiImages) {
  var s = String(text || "")
  var list = toList(entities).filter(function (e) {
    return isObject(e) && typeof e.type === "string" && typeof e.offset === "number" && typeof e.length === "number"
        && e.offset >= 0 && e.length > 0 && e.offset + e.length <= s.length
  })
  var cuts = [0, s.length]
  list.forEach(function (e) { cuts.push(e.offset, e.offset + e.length) })
  cuts = cuts.filter(function (c, i, all) { return all.indexOf(c) === i }).sort(function (a, b) { return a - b })
  var out = ""
  for (var i = 0; i + 1 < cuts.length; i++) {
    var start = cuts[i], end = cuts[i + 1]
    var piece = s.slice(start, end)
    var on = list.filter(function (e) { return e.offset <= start && e.offset + e.length >= end })
    var types = on.map(function (e) { return e.type })
    if (types.indexOf("spoiler") >= 0 && !revealed) {
      out += '<a href="omagram:spoiler">' + piece.replace(/[^\s]/g, "▒") + "</a>"
      continue
    }
    // A custom emoji is its sticker once that is on this computer (a local file, never a remote
    // image), and the emoji it stands in for until then.
    var custom = on.filter(function (e) { return e.type === "customEmoji" })[0]
    var image = custom && isObject(emojiImages) ? String(emojiImages[custom.customEmojiId] || "") : ""
    var html = image.indexOf("file:///") === 0
      ? '<img src="' + escapeHtml(image) + '" width="' + EMOJI_PX + '" height="' + EMOJI_PX + '">'
      : escapeHtml(piece)
    if (types.indexOf("code") >= 0 || types.indexOf("pre") >= 0 || types.indexOf("preCode") >= 0)
      html = '<code style="background-color:' + escapeHtml(codeBackground || "transparent") + '">' + html + "</code>"
    if (types.indexOf("bold") >= 0) html = "<b>" + html + "</b>"
    if (types.indexOf("italic") >= 0 || types.indexOf("blockQuote") >= 0) html = "<i>" + html + "</i>"
    if (types.indexOf("underline") >= 0) html = "<u>" + html + "</u>"
    if (types.indexOf("strikethrough") >= 0) html = "<s>" + html + "</s>"
    for (var k = 0; k < on.length; k++) {
      var whole = s.slice(on[k].offset, on[k].offset + on[k].length)
      var href = linkFor(on[k], whole)
      if (href) { html = '<a href="' + escapeHtml(href) + '">' + html + "</a>"; break }
    }
    out += html
  }
  return '<span style="white-space: pre-wrap">' + out + "</span>"
}

// ---------------------------------------------------------------- people and chats

function statusText(status, nowMs) {
  if (!isObject(status)) return ""
  if (status.state === "online") return "online"
  if (status.state === "offline" && status.wasOnline > 0) {
    var minutes = Math.floor((nowMs / 1000 - status.wasOnline) / 60)
    if (minutes < 1) return "last seen just now"
    if (minutes < 60) return "last seen " + minutes + (minutes === 1 ? " minute ago" : " minutes ago")
    if (sameDay(status.wasOnline, nowMs / 1000)) return "last seen today at " + clock(status.wasOnline)
    if (daysBetween(status.wasOnline, nowMs) === 1) return "last seen yesterday at " + clock(status.wasOnline)
    return "last seen " + dayLabel(status.wasOnline, nowMs)
  }
  return ({ recently: "last seen recently", lastWeek: "last seen within a week", lastMonth: "last seen within a month" })[status.state] || ""
}

var ACTION_WORDS = {
  typing: "typing", recordingVoice: "recording a voice message", recordingVideo: "recording a video",
  recordingVideoNote: "recording a video message", uploadingPhoto: "sending a photo", uploadingVideo: "sending a video",
  uploadingFile: "sending a file", uploadingVoice: "sending a voice message", uploadingVideoNote: "sending a video message",
  choosingSticker: "choosing a sticker", choosingLocation: "choosing a location", choosingContact: "choosing a contact",
  playingGame: "playing a game", watchingAnimations: "watching an animation"
}
var ACTION_MS = 6000   // Telegram repeats an action every few seconds while it lasts

function withAction(actions, event, nowMs) {
  var next = {}
  for (var k in actions || {}) next[k] = actions[k]
  if (!isObject(event) || !event.chatId) return next
  var chat = {}
  for (var s in next[event.chatId] || {}) chat[s] = next[event.chatId][s]
  if (event.action === "cancel" || !ACTION_WORDS[event.action]) delete chat[event.senderId]
  else chat[event.senderId] = { senderName: event.senderName || "", action: event.action, until: nowMs + ACTION_MS }
  next[event.chatId] = chat
  return next
}

function activeActions(actions, chatId, nowMs) {
  var chat = isObject(actions) ? actions[chatId] : null
  var out = []
  for (var id in chat || {}) if (chat[id].until > nowMs) out.push(chat[id])
  return out
}

// "typing…" in a private chat; "Ann is typing…", "Ann and Bob are typing…" in a group.
function actionText(list, privateChat) {
  var active = toList(list).filter(function (a) { return isObject(a) && ACTION_WORDS[a.action] })
  if (!active.length) return ""
  var word = ACTION_WORDS[active[0].action]
  var same = active.every(function (a) { return a.action === active[0].action })
  if (privateChat) return word + "…"
  if (active.length === 1) return (active[0].senderName || "Someone") + " is " + word + "…"
  if (active.length === 2) return (active[0].senderName || "Someone") + " and " + (active[1].senderName || "someone") + " are " + (same ? word : "busy") + "…"
  return active.length + " people are " + (same ? word : "busy") + "…"
}

// ---------------------------------------------------------------- messages

// "", "sending", "failed", "sent" or "read", for your own messages.
function receipt(message, chat) {
  if (!isObject(message) || !message.outgoing) return ""
  if (message.sending === "pending") return "sending"
  if (message.sending === "failed") return "failed"
  return isObject(chat) && message.id <= (chat.lastReadOutbox || 0) ? "read" : "sent"
}

function updatePoll(messages, poll) {
  if (!isList(messages) || !isObject(poll)) return messages
  var changed = false
  var out = messages.map(function (m) {
    if (isObject(m) && isObject(m.content) && isObject(m.content.poll) && m.content.poll.id === poll.id) {
      changed = true
      var content = {}
      for (var k in m.content) content[k] = m.content[k]
      content.poll = poll
      content.text = poll.question
      var copy = {}
      for (var j in m) copy[j] = m[j]
      copy.content = content
      return copy
    }
    return m
  })
  return changed ? out : messages
}

// The messages of an album that starts at `index`; [] when this message does not start one.
function albumStart(messages, index) {
  var m = messages[index]
  if (!isObject(m) || !m.albumId) return []
  if (index > 0 && isObject(messages[index - 1]) && messages[index - 1].albumId === m.albumId) return []
  var out = []
  for (var i = index; i < messages.length && isObject(messages[i]) && messages[i].albumId === m.albumId; i++) out.push(messages[i])
  return out
}

function inAlbumAfterFirst(messages, index) {
  var m = messages[index]
  return index > 0 && isObject(m) && !!m.albumId && isObject(messages[index - 1]) && messages[index - 1].albumId === m.albumId
}

// The bot keyboard for the message box: the newest message that sets or removes one decides.
function latestKeyboard(messages) {
  if (!isList(messages)) return null
  for (var i = messages.length - 1; i >= 0; i--) {
    var markup = isObject(messages[i]) ? messages[i].markup : null
    if (!isObject(markup)) continue
    if (markup.type === "keyboard") return { messageId: messages[i].id, rows: markup.rows || [], oneTime: !!markup.oneTime, placeholder: markup.placeholder || "" }
    if (markup.type === "remove") return null
  }
  return null
}

// ---------------------------------------------------------------- menus, selection, files

var MUTE_FOREVER = 2147483647
var FILE_KINDS = ["photo", "video", "gif", "voice", "videoNote", "audio", "file"]
var CAPTION_KINDS = ["photo", "video", "gif", "voice", "audio", "file"]
// Files that could run code when opened with their app: opening one asks first, as Telegram does.
var RISKY_EXTENSIONS = ["appimage", "apk", "bash", "bat", "bin", "cmd", "com", "csh", "deb", "desktop", "el", "elf", "exe",
                        "fish", "hta", "htm", "html", "jar", "js", "ko", "ksh", "lnk", "mjs", "msi", "php", "pkg", "pl", "ps1",
                        "py", "pyc", "pyw", "rb", "rpm", "run", "scr", "service", "sh", "so", "svg", "url", "vbs", "xhtml", "zsh"]

// "Saved Messages" for your chat with yourself, as every Telegram app calls it.
function chatTitle(chat, meId) {
  if (!isObject(chat)) return ""
  if (chat.kind === "private" && meId && chat.userId === meId) return "Saved Messages"
  return String(chat.title || "") || "Deleted account"
}

// What a message's menu offers. `properties` is what Telegram allows for the message, null until
// it has answered: until then only what needs no permission is there.
function messageMenu(message, properties, translated, chat) {
  if (!isObject(message) || !isObject(message.content)) return []
  var p = isObject(properties) ? properties : null
  var c = message.content
  if (message.sendAt) {   // a scheduled message
    var later = [{ id: "sendNow", label: "Send now" }, { id: "reschedule", label: "Change when it is sent" }]
    if (c.kind === "text") later.push({ id: "edit", label: "Edit" })
    if (c.text) later.push({ id: "copy", label: "Copy text" })
    later.push({ id: "deleteAll", label: "Delete", danger: true })
    return later
  }
  var out = []
  if (!p || p.canReply) out.push({ id: "reply", label: "Reply" })
  if (c.text && (!p || p.canSave !== false)) out.push({ id: "copy", label: "Copy text" })
  // Telegram translates on its servers, which never see a secret chat's messages.
  if (c.text && !(isObject(chat) && chat.kind === "secret"))
    out.push(translated ? { id: "untranslate", label: "Hide the translation" } : { id: "translate", label: "Translate" })
  if (p && p.canGetLink) out.push({ id: "link", label: "Copy link" })
  if (p && p.canEdit) out.push({ id: "edit", label: c.kind === "text" ? "Edit" : "Edit caption" })
  if (p && p.canForward) out.push({ id: "forward", label: "Forward" })
  if (p && p.canPin) out.push(message.pinned ? { id: "unpin", label: "Unpin" } : { id: "pin", label: "Pin" })
  out.push({ id: "select", label: "Select" })
  if (isObject(c.media) && isObject(c.media.file) && FILE_KINDS.indexOf(c.kind) >= 0 && (!p || p.canSave !== false)) {
    out.push({ id: "open", label: "Open with its app" })
    out.push({ id: "save", label: "Save to Downloads" })
  }
  if (isObject(c.poll) && c.poll.voted && !c.poll.closed && !c.poll.quiz) out.push({ id: "retract", label: "Retract vote" })
  if (p && p.canDeleteForAll) out.push({ id: "deleteAll", label: "Delete for everyone", danger: true })
  if (p && p.canDeleteForMe) out.push({ id: "deleteMe", label: "Delete for me", danger: true })
  return out
}

function muteMenu(chat) {
  if (!isObject(chat)) return []
  if (chat.muted) return [{ id: "unmute", label: "Unmute" }]
  return [{ id: "mute:3600", label: "Mute for 1 hour" }, { id: "mute:28800", label: "Mute for 8 hours" },
          { id: "mute:172800", label: "Mute for 2 days" }, { id: "mute:forever", label: "Mute forever" }]
}

// Seconds to mute for, from a mute menu item: 0 unmutes, -1 is not a mute item.
function muteSeconds(id) {
  if (id === "unmute") return 0
  if (id === "mute:forever") return MUTE_FOREVER
  var m = /^mute:([1-9][0-9]{0,8})$/.exec(String(id))
  return m ? Number(m[1]) : -1
}

function chatMenu(chat, listKey, searchMode) {
  if (!isObject(chat)) return []
  var out = [{ id: "open", label: "Open" }, { id: "info", label: "Info" }]
  if (chat.unread > 0 || chat.mentions > 0 || chat.markedUnread) out.push({ id: "read", label: "Mark as read" })
  else out.push({ id: "unread", label: "Mark as unread" })
  if (!searchMode) out.push(pinnedIn(chat, listKey) ? { id: "unpin", label: "Unpin" } : { id: "pin", label: "Pin" })
  out.push(chat.muted ? { id: "unmute", label: "Unmute" } : { id: "mute", label: "Mute" })
  out.push(chat.archived ? { id: "unarchive", label: "Move out of the archive" } : { id: "archive", label: "Archive" })
  return out.concat(leaveActions(chat))
}

// Leaving a group or channel; clearing or deleting a chat with a person (your copy only).
function leaveActions(chat) {
  if (!isObject(chat)) return []
  if (chat.kind === "private" || chat.kind === "secret")
    return [{ id: "clear", label: "Clear history", danger: true }, { id: "delete", label: "Delete chat", danger: true }]
  if ((chat.kind === "group" || chat.kind === "channel") && chat.myStatus !== "left" && chat.myStatus !== "banned")
    return [{ id: "leave", label: chat.kind === "channel" ? "Leave channel" : "Leave group", danger: true }]
  return []
}

// ---------------------------------------------------------------- a chat's info

function memberCountText(count, channel) {
  var n = Math.max(0, Number(count) | 0)
  if (!n) return channel ? "Channel" : "Group"
  return n + (channel ? (n === 1 ? " subscriber" : " subscribers") : (n === 1 ? " member" : " members"))
}

// Under the name: a person's last seen, a group's size.
function infoSubtitle(chat, details, statuses, nowMs) {
  if (!isObject(chat)) return ""
  if (chat.kind === "private" || chat.kind === "secret") {
    if (chat.bot) return "bot"
    return statusText(isObject(statuses) && statuses[chat.userId] ? statuses[chat.userId] : chat.status, nowMs)
  }
  var count = isObject(details) && details.memberCount > 0 ? details.memberCount : chat.memberCount
  return memberCountText(count, chat.kind === "channel")
}

// What a chat's info shows: username, phone, bio or description, invite link.
function infoDetails(chat, details) {
  if (!isObject(chat) || !isObject(details)) return []
  var out = []
  var username = String(details.username || chat.username || "")
  if (username) out.push({ label: "Username", value: "@" + username, copy: "https://t.me/" + username })
  var phone = String(details.phone || "").replace(/^\+/, "")
  if (phone) out.push({ label: "Phone", value: "+" + phone, copy: "+" + phone })
  if (isObject(details.bio) && details.bio.text)
    out.push({ label: "Bio", value: String(details.bio.text), entities: toList(details.bio.entities) })
  if (details.botDescription) out.push({ label: "About", value: String(details.botDescription) })
  if (details.description) out.push({ label: chat.kind === "channel" ? "About the channel" : "About the group", value: String(details.description) })
  if (details.inviteLink) out.push({ label: "Invite link", value: String(details.inviteLink), copy: String(details.inviteLink) })
  if (details.commonGroups > 0) out.push({ label: "Groups in common", value: String(details.commonGroups) })
  if (details.keyHash) out.push({ label: "Encryption key: the other device shows the same", value: String(details.keyHash) })
  return out
}

function infoActions(chat, meId) {
  if (!isObject(chat)) return []
  var out = [{ id: "mute", label: chat.muted ? "Unmute" : "Mute" }, { id: "search", label: "Search" }]
  if (chat.kind === "private" && !chat.bot && chat.userId && chat.userId !== meId) out.push({ id: "secret", label: "Start a secret chat" })
  if (chat.kind === "secret" && isObject(chat.secret) && chat.secret.state !== "closed")
    out.push({ id: "endSecret", label: "End the secret chat", danger: true })
  return out.concat(leaveActions(chat))
}

function secretStateText(chat) {
  if (!isObject(chat) || !isObject(chat.secret)) return ""
  if (chat.secret.state === "ready") return "end-to-end encrypted"
  if (chat.secret.state === "closed") return "the secret chat has ended"
  return chat.secret.outbound ? "waiting for the other side to accept" : "setting up the secret chat"
}

// ---------------------------------------------------------------- sending later, quietly

// The times offered: in an hour, this evening at 21:00 (tomorrow's once that is near or past),
// and tomorrow at 9:00. In seconds.
function schedulePresets(nowMs) {
  var now = new Date(nowMs)
  var evening = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 21, 0, 0)
  if (evening.getTime() <= nowMs + 10 * 60 * 1000) evening.setDate(evening.getDate() + 1)
  var morning = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1, 9, 0, 0)
  return { hour: Math.floor(nowMs / 1000) + 3600, evening: Math.floor(evening.getTime() / 1000), morning: Math.floor(morning.getTime() / 1000) }
}

// "today", "tomorrow", "Wednesday", "3 October" (with its year when that is another), "when online".
function scheduleDay(sendAt, nowMs) {
  if (sendAt === -1) return "when online"
  if (!(sendAt > 0)) return ""
  var days = daysBetween(Math.floor(nowMs / 1000), sendAt * 1000)
  var d = new Date(sendAt * 1000)
  if (days <= 0) return "today"
  if (days === 1) return "tomorrow"
  if (days < 7) return WEEKDAYS_LONG[d.getDay()]
  return d.getDate() + " " + MONTHS_LONG[d.getMonth()] + (d.getFullYear() !== new Date(nowMs).getFullYear() ? " " + d.getFullYear() : "")
}

// "today at 21:00", "tomorrow at 09:00", "Wednesday at 09:00", "3 October at 09:00", "when online".
function scheduleText(sendAt, nowMs) {
  return sendAt > 0 ? scheduleDay(sendAt, nowMs) + " at " + clock(sendAt) : scheduleDay(sendAt, nowMs)
}

// Whether a message starts a day in the list: the day it was sent, or for a scheduled message the
// day it will be (TDLib gives those no date), those waiting for the other person to be online together.
function startsDay(previous, message) {
  if (!isObject(previous)) return true
  if (previous.sendAt === -1 || message.sendAt === -1) return previous.sendAt !== message.sendAt
  return !sameDay(previous.sendAt > 0 ? previous.sendAt : previous.date, message.sendAt > 0 ? message.sendAt : message.date)
}

// The heading over a day's messages: "Today", "Yesterday", ...; over scheduled ones "Will be sent tomorrow".
function dayHeading(message, nowMs) {
  if (!(message.sendAt > 0) && message.sendAt !== -1) return dayLabel(message.date, nowMs)
  var day = scheduleDay(message.sendAt, nowMs)
  return "Will be sent " + (["today", "tomorrow", "when online"].indexOf(day) >= 0 ? day : "on " + day)
}

// The other ways to send what is typed: quietly, later, or once the other person is online.
function sendMenu(chat, meId, nowMs, hasText) {
  if (!isObject(chat)) return []
  var out = []
  if (hasText) {
    out.push({ id: "silent", label: "Send without sound" })
    if (chat.kind !== "secret") {   // a secret chat cannot schedule
      var p = schedulePresets(nowMs)
      out.push({ id: "at:" + p.hour, label: "Send in an hour" },
               { id: "at:" + p.evening, label: "Send " + scheduleText(p.evening, nowMs) },
               { id: "at:" + p.morning, label: "Send " + scheduleText(p.morning, nowMs) })
      if (chat.kind === "private" && !chat.bot && chat.userId !== meId) out.push({ id: "online", label: "Send when they are online" })
    }
  }
  if (chat.hasScheduled) out.push({ id: "scheduled", label: "Scheduled messages" })
  return out
}

function rescheduleMenu(chat, meId, nowMs) {
  if (!isObject(chat)) return []
  var p = schedulePresets(nowMs)
  var capital = function (s) { return s.charAt(0).toUpperCase() + s.slice(1) }
  var out = [{ id: "now", label: "Send now" }, { id: "at:" + p.hour, label: "In an hour" },
             { id: "at:" + p.evening, label: capital(scheduleText(p.evening, nowMs)) },
             { id: "at:" + p.morning, label: capital(scheduleText(p.morning, nowMs)) }]
  if (chat.kind === "private" && !chat.bot && chat.userId !== meId) out.push({ id: "online", label: "When they are online" })
  return out
}

// What a send or reschedule menu item asks for: { silent } or { sendAt }; null for anything else.
function sendChoice(id) {
  if (id === "silent") return { silent: true }
  if (id === "online") return { sendAt: -1 }
  if (id === "now") return { sendAt: 0 }
  var m = /^at:([1-9][0-9]{0,10})$/.exec(String(id))
  return m ? { sendAt: Number(m[1]) } : null
}

// Scheduled messages in the order they go out: by the time set, those waiting for the other person
// to be online last.
function scheduledOrder(messages) {
  var at = function (m) { return m.sendAt > 0 ? m.sendAt : Infinity }
  return toList(messages).filter(isObject).sort(function (a, b) { return at(a) - at(b) || a.id - b.id })
}

var INFO_TABS = [
  { key: "photos", label: "Photos and videos" }, { key: "files", label: "Files" }, { key: "links", label: "Links" },
  { key: "voice", label: "Voice" }, { key: "music", label: "Music" }, { key: "gifs", label: "GIFs" }
]

// A chat info's tabs: members where they can be listed, then each kind of shared media there is
// -- all of them until the counts are known.
function infoTabs(chat, details, counts) {
  if (!isObject(chat)) return []
  var out = []
  if ((chat.kind === "group" || chat.kind === "channel") && isObject(details) && details.canGetMembers)
    out.push({ key: "members", label: chat.kind === "channel" ? "Subscribers" : "Members", count: Math.max(0, details.memberCount | 0) })
  INFO_TABS.forEach(function (tab) {
    var count = isObject(counts) ? counts[tab.key] : undefined
    if (count === undefined || count > 0) out.push({ key: tab.key, label: tab.label, count: count === undefined ? -1 : count })
  })
  return out
}

// The first link a message leads to, if it is one that may be followed.
function firstLink(content) {
  if (!isObject(content)) return ""
  var text = String(content.text || "")
  var entities = toList(content.entities)
  for (var i = 0; i < entities.length; i++) {
    var e = entities[i]
    if (!isObject(e)) continue
    var url = e.type === "textUrl" ? safeUrl(e.url) : (e.type === "url" ? safeUrl(text.substr(e.offset, e.length)) : "")
    if (url) return url
  }
  return isObject(content.linkPreview) ? safeUrl(content.linkPreview.url) : ""
}

// A shared file, link, voice or music message as a row: a title, and a line under it.
function sharedRow(message, kind, nowMs) {
  if (!isObject(message) || !isObject(message.content)) return { title: "", detail: "" }
  var c = message.content
  var media = isObject(c.media) ? c.media : {}
  var who = message.outgoing ? "You" : String(message.senderName || "")
  var when = listTime(message.date, nowMs)
  var line = function (first) { return [first, who, when].filter(function (part) { return !!part }).join(" · ") }
  if (kind === "files") return { title: String(media.fileName || c.fileName || "File"), detail: line(formatSize(isObject(media.file) ? media.file.size : 0)) }
  if (kind === "music")
    return { title: media.title ? (media.performer ? media.performer + " — " : "") + media.title : String(media.fileName || "Audio"),
             detail: line(formatDuration(media.duration)) }
  if (kind === "voice") return { title: (c.kind === "videoNote" ? "Video message, " : "Voice message, ") + formatDuration(media.duration), detail: line("") }
  if (kind === "links") return { title: firstLink(c) || previewOf(message), detail: line(previewOf(message)) }
  return { title: previewOf(message), detail: line("") }
}

function memberDetail(member, nowMs) {
  if (!isObject(member)) return ""
  var role = ({ owner: "owner", admin: "admin", restricted: "restricted", banned: "removed", left: "left" })[member.status] || ""
  return [role, member.bot ? "bot" : statusText(member.userStatus, nowMs)].filter(function (part) { return !!part }).join(" · ")
}

// ---------------------------------------------------------------- forum topics

// Where the window keeps a history: a chat's id, or "chat:topic" for a topic of a forum.
function historyKey(chatId, topicId) {
  return topicId > 0 ? chatId + ":" + topicId : String(chatId)
}

function isHistoryOf(key, chatId) {
  var s = String(key)
  return s === String(chatId) || s.indexOf(chatId + ":") === 0
}

// Topics as their list shows them: pinned first, then Telegram's order (an int64, as text).
function mergeTopics(existing, incoming) {
  var byId = {}
  var all = toList(existing).concat(toList(incoming))
  all.forEach(function (topic) {
    if (isObject(topic) && typeof topic.id === "number" && topic.id > 0) byId[topic.id] = topic   // later wins
  })
  return Object.keys(byId).map(function (k) { return byId[k] }).sort(function (a, b) {
    if (!!a.pinned !== !!b.pinned) return a.pinned ? -1 : 1
    return compareOrder(b.order, a.order) || (a.id - b.id)
  }).slice(0, 500)
}

var TOPIC_COLORS = ["#6FB9F0", "#FFD67E", "#CB86DB", "#8EEE98", "#FF93B2", "#FB6F5F"]

// A topic icon's colour: Telegram's RGB number, or the first of its palette when there is none.
function topicColor(color) {
  var n = Number(color) >>> 0 & 0xFFFFFF
  if (!n) return TOPIC_COLORS[0]
  var hex = n.toString(16)
  return "#" + "000000".slice(hex.length) + hex
}

function topicLetter(topic) {
  if (!isObject(topic) || topic.general) return "#"
  return (Array.from(String(topic.name || "").trim())[0] || "#").toUpperCase()
}

// ---------------------------------------------------------------- starting a chat

function sortContacts(contacts) {
  return toList(contacts).filter(isObject)
    .sort(function (a, b) { return String(a.name || "").localeCompare(String(b.name || "")) })
}

// A username typed to find someone, "@name" or "name": 4 to 32 letters, digits and underscores,
// starting with a letter.
function usernameQuery(query) {
  var m = /^@?([A-Za-z][A-Za-z0-9_]{3,31})$/.exec(String(query || "").trim())
  return m ? m[1] : ""
}

// The rows of the new chat dialog: starting a group or a channel, finding a @username, and the
// contacts matching what is typed (with whether each is chosen for a new group).
function newChatRows(mode, contacts, query, selected) {
  var q = String(query || "").trim().toLowerCase().replace(/^@/, "")
  var found = toList(contacts).filter(function (c) {
    return isObject(c) && (!q || String(c.name || "").toLowerCase().indexOf(q) >= 0 || String(c.username || "").toLowerCase().indexOf(q) >= 0)
  })
  var out = []
  if (mode === "people") {
    if (!q) out.push({ kind: "action", id: "group", label: "New group" }, { kind: "action", id: "channel", label: "New channel" })
    var username = usernameQuery(query)
    if (username && !found.some(function (c) { return String(c.username || "").toLowerCase() === username.toLowerCase() }))
      out.push({ kind: "username", username: username, label: "Find @" + username })
  }
  found.forEach(function (c) {
    out.push({ kind: "contact", contact: c, selected: mode === "members" && isObject(selected) && selected[c.userId] === true })
  })
  return out
}

function contactDetail(contact, nowMs) {
  if (!isObject(contact)) return ""
  return [contact.username ? "@" + contact.username : "", contact.bot ? "bot" : statusText(contact.status, nowMs)]
    .filter(function (part) { return !!part }).join(" · ")
}

// The messages one bubble stands for: every message of an album, or just the one.
function albumIds(messages, message) {
  if (!isObject(message)) return []
  if (!message.albumId || !isList(messages)) return [message.id]
  var ids = messages.filter(function (m) { return isObject(m) && m.albumId === message.albumId }).map(function (m) { return m.id })
  return ids.length ? ids : [message.id]
}

// Selects the messages, or unselects them when all of them already are.
function toggleSelection(selection, ids) {
  var next = {}
  for (var k in selection || {}) next[k] = selection[k]
  var list = toList(ids)
  var all = list.length > 0 && list.every(function (id) { return next[id] === true })
  list.forEach(function (id) { if (all) delete next[id]; else next[id] = true })
  return next
}

// Selected messages that are still loaded, oldest first.
function selectedIds(messages, selection) {
  if (!isList(messages) || !isObject(selection)) return []
  return messages.filter(function (m) { return isObject(m) && selection[m.id] === true }).map(function (m) { return m.id })
}

// Selected messages as text for the clipboard, the way Telegram copies them.
function selectionText(messages, selection) {
  if (!isList(messages) || !isObject(selection)) return ""
  return messages.filter(function (m) { return isObject(m) && selection[m.id] === true }).map(function (m) {
    var body = isObject(m.content) && m.content.text ? String(m.content.text) : previewOf(m)
    return (m.outgoing ? "You" : (m.senderName || "Unknown")) + ", [" + clock(m.date) + "]\n" + body
  }).join("\n\n")
}

function reactionChosen(message, emoji) {
  return isObject(message) && isList(message.reactions)
    && message.reactions.some(function (r) { return isObject(r) && r.emoji === emoji && r.chosen === true })
}

// Whether opening a file with its app could run code: no extension, or one that runs.
function riskyFile(name) {
  var m = /\.([A-Za-z0-9]{1,12})$/.exec(String(name || "").trim())
  return !m || RISKY_EXTENSIONS.indexOf(m[1].toLowerCase()) >= 0
}

// The name a message's file is saved under in Downloads.
function saveName(message) {
  var c = isObject(message) && isObject(message.content) ? message.content : {}
  var media = isObject(c.media) ? c.media : {}
  var given = String(media.fileName || c.fileName || "")
  if (given) return given
  var d = new Date((isObject(message) && message.date > 0 ? message.date : 0) * 1000)
  var stamp = d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()) + "_"
            + pad(d.getHours()) + "-" + pad(d.getMinutes()) + "-" + pad(d.getSeconds())
  var base = { photo: "photo", video: "video", gif: "animation", voice: "voice", videoNote: "video-message", audio: "audio" }[c.kind] || "file"
  var ext = { photo: ".jpg", video: ".mp4", gif: ".mp4", voice: ".ogg", videoNote: ".mp4" }[c.kind] || ""
  return base + "_" + stamp + ext
}

// "just now", "5 minutes ago", "3 hours ago", "yesterday", then a date.
function agoText(seconds, nowMs) {
  if (!(seconds > 0)) return ""
  var minutes = Math.floor((nowMs / 1000 - seconds) / 60)
  if (minutes < 1) return "just now"
  if (minutes < 60) return minutes + (minutes === 1 ? " minute ago" : " minutes ago")
  if (sameDay(seconds, nowMs / 1000)) {
    var hours = Math.floor(minutes / 60)
    return hours + (hours === 1 ? " hour ago" : " hours ago")
  }
  if (daysBetween(seconds, nowMs) === 1) return "yesterday"
  return listTime(seconds, nowMs)
}

// A signed-in device: "Telegram Desktop 5.1", then "PC · Windows 11 · Kyiv · active 5 minutes ago".
function sessionTitle(session) {
  if (!isObject(session)) return ""
  return (String(session.app || "") || "Unknown app") + (session.appVersion ? " " + session.appVersion : "")
}

function sessionDetail(session, nowMs) {
  if (!isObject(session)) return ""
  var system = [session.platform, session.system].filter(function (part) { return !!part }).join(" ")
  var parts = [session.device, system, session.location].filter(function (part) { return !!part })
  parts.push(session.current ? "this device" : "active " + agoText(session.lastActive, nowMs))
  return parts.join(" · ")
}

function storageText(stats) {
  if (!isObject(stats)) return "Counting…"
  var files = Math.max(0, stats.fileCount | 0)
  return formatSize(stats.filesSize) + " of downloads in " + files + (files === 1 ? " file" : " files")
    + " · database " + formatSize(stats.databaseSize)
    + (stats.stickerCacheSize > 0 ? " · stickers " + formatSize(stats.stickerCacheSize) : "")
}

// Chats to forward to: Saved Messages first, then the main list and the archive.
function forwardTargets(chats, query, meId) {
  var every = chatsIn(chats, "main").concat(chatsIn(chats, "archive"))
  var own = function (c) { return c.kind === "private" && !!meId && c.userId === meId }
  return filterChats(every.filter(own).concat(every.filter(function (c) { return !own(c) })), query, meId).slice(0, 100)
}

