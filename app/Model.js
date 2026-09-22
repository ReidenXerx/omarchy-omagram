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

// How a list view's rows, one per id, become another sorted list of ids by editing them in place:
// ordered edits { op: "insert", at, ids } / { op: "remove", at, count } / { op: "set", at, id }
// (a row taking another id where one left, as a sent message takes its server id). A list view
// given a new array instead throws away every row and loses its place. null when either list is
// not sorted by id: then rebuild.
function listEdits(oldIds, newIds) {
  var a = toList(oldIds)
  var b = toList(newIds)
  for (var s = 1; s < a.length; s++) if (!(a[s - 1] < a[s])) return null
  for (var t = 1; t < b.length; t++) if (!(b[t - 1] < b[t])) return null
  var ops = []
  var push = function (op, at, id) {
    var last = ops[ops.length - 1]
    if (op === "remove" && last && last.op === "remove" && last.at === at) last.count++
    else if (op === "insert" && last && last.op === "insert" && last.at + last.ids.length === at) last.ids.push(id)
    else ops.push(op === "remove" ? { op: op, at: at, count: 1 } : { op: op, at: at, ids: [id] })
  }
  var i = 0, j = 0, at = 0
  while (i < a.length || j < b.length) {
    if (i < a.length && j < b.length && a[i] === b[j]) {
      i++
      j++
      at++
    } else if (j >= b.length || (i < a.length && a[i] < b[j])) {
      push("remove", at)
      i++
    } else {
      push("insert", at, b[j])
      j++
      at++
    }
  }
  var out = []
  for (var k = 0; k < ops.length; k++) {
    var e = ops[k]
    var next = ops[k + 1]
    if (next && e.op === "remove" && e.count === 1 && next.op === "insert" && next.at === e.at && next.ids.length === 1) {
      out.push({ op: "set", at: e.at, id: next.ids[0] })
      k++
    } else if (next && e.op === "insert" && e.ids.length === 1 && next.op === "remove" && next.count === 1 && next.at === e.at + 1) {
      out.push({ op: "set", at: e.at, id: e.ids[0] })
      k++
    } else {
      out.push(e)
    }
  }
  return out
}

// Brings a ListModel of { mid } rows from oldIds to the ids of `messages`: in place when it can,
// rebuilt when the lists are not sorted or too different to edit (another chat). The ids now shown.
function syncRows(rows, oldIds, messages) {
  var ids = toList(messages).map(function (m) { return m.id })
  var edits = listEdits(oldIds, ids)
  if (edits === null || edits.length > 64) {
    rows.clear()
    if (ids.length) rows.append(ids.map(function (id) { return { mid: id } }))
  } else {
    edits.forEach(function (e) {
      if (e.op === "set") rows.setProperty(e.at, "mid", e.id)
      else if (e.op === "remove") rows.remove(e.at, e.count)
      else rows.insert(e.at, e.ids.map(function (id) { return { mid: id } }))
    })
  }
  return ids
}

// The message a row shows: the one at its index when the ids agree, otherwise found by id (rows and
// messages are a step apart while they change); null when it is not in the list.
function rowMessage(messages, index, id) {
  var list = toList(messages)
  var at = list[index]
  return at && at.id === id ? at : (findMessage(list, id) || null)
}

// A message with every field a row reads, for a row that has none to show for a moment.
var NO_MESSAGE = { id: 0, chatId: 0, date: 0, editDate: 0, outgoing: false, pinned: false, sender: null, senderName: "",
                   sending: null, replyTo: null, forward: null, albumId: "", reactions: [], views: 0, markup: null,
                   topicId: 0, sendAt: 0, content: { kind: "text", text: "", entities: [] } }

// What stands where the message box would be when you cannot write: "join" for a group or channel you
// are not in, "left" for a basic group you left (only someone in it can add you back), "channel" for a
// channel only its admins post in, "banned" when you were removed; "" when you can write (or it is not
// known yet). A channel's discussion group may take comments from people who have not joined it.
function composerBlock(chat) {
  if (!isObject(chat) || (chat.kind !== "group" && chat.kind !== "channel")) return ""
  if (chat.myStatus === "left") return !chat.supergroup ? "left" : (chat.joinToWrite === false ? "" : "join")
  if (chat.myStatus === "banned") return "banned"
  if (chat.kind === "channel" && (chat.myStatus === "member" || chat.myStatus === "restricted")) return "channel"
  return ""
}

// How fast voice and video messages, videos and music play: 1×, 1.5× or 2×, in turn.
var SPEEDS = [1, 1.5, 2]

function playbackRate(value) {
  return SPEEDS.indexOf(Number(value)) >= 0 ? Number(value) : 1
}

// The frame of a round video's moving picture that goes with its sound: `elapsedMs` since it started playing at
// `rate`, at `fps` frames a second, never past the last of `frames`.
function noteFrame(elapsedMs, rate, fps, frames) {
  var count = Math.floor(Number(frames) || 0)
  var perSecond = Number(fps) || 0
  if (count < 1 || perSecond <= 0) return 0
  var speed = Number(rate) > 0 ? Number(rate) : 1
  var frame = Math.floor(Math.max(0, Number(elapsedMs) || 0) / 1000 * speed * perSecond)
  return Math.min(count - 1, frame)
}

function nextSpeed(rate) {
  return SPEEDS[(SPEEDS.indexOf(playbackRate(rate)) + 1) % SPEEDS.length]
}

function speedLabel(rate) {
  return playbackRate(rate) + "×"
}

// Under a channel post: its comments, or the way to leave the first; under a message in a
// discussion group: its replies, once there are any.
function repliesText(replies, channel) {
  if (!isObject(replies)) return ""
  var n = Math.max(0, Number(replies.count) | 0)
  if (channel) return n ? n + (n === 1 ? " comment" : " comments") : "Leave a comment"
  return n ? n + (n === 1 ? " reply" : " replies") : ""
}

// Telegram looks public chats up by name from four characters (five with an @ in front).
function publicQuery(query) {
  var q = String(query || "").trim()
  var n = Array.from(q).length
  return n > 4 || (n === 4 && q[0] !== "@")
}

// Under a public chat found by search: its username and its size.
function publicChatDetail(chat) {
  if (!isObject(chat)) return ""
  var size = chat.kind === "private" ? (chat.bot ? "bot" : "") : memberCountText(chat.memberCount, chat.kind === "channel")
  return [chat.username ? "@" + chat.username : "", size].filter(function (s) { return s !== "" }).join("  ·  ")
}

// What a join came to, as the service reports it (chat.join, chat.joinLink).
function joinText(state, channel) {
  if (state === "joined") return channel ? "You joined the channel" : "You joined the group"
  if (state === "requested") return "Your request to join is sent: an admin will let you in"
  if (state === "guardBot") return "A bot guards this chat: join it from another Telegram app"
  if (state === "declined") return "The chat's bot turned down your request to join"
  return "Could not join"
}

// ---------------------------------------------------------------- files waiting to be sent

var PHOTO_EXTENSIONS = [".jpg", ".jpeg", ".png", ".webp"]
var VIDEO_EXTENSIONS = [".mp4", ".mov", ".m4v"]
var AUDIO_EXTENSIONS = [".mp3", ".m4a", ".flac", ".ogg", ".opus"]

// How a file waiting to be sent goes out when sent as media, by its name, as the service decides:
// "photo", "video", "audio" or "file".
function attachmentKind(path) {
  var name = String(path || "").toLowerCase()
  var endsIn = function (list) { return list.some(function (e) { return name.slice(-e.length) === e }) }
  return endsIn(PHOTO_EXTENSIONS) ? "photo" : (endsIn(VIDEO_EXTENSIONS) ? "video" : (endsIn(AUDIO_EXTENSIONS) ? "audio" : "file"))
}

// ---------------------------------------------------------------- suggestions while typing

// What is typed at the cursor that a suggestion can complete: @someone, or a bot /command that starts
// the message. { kind: "mention" | "command" | "", query, start, end }; a suggestion replaces the text
// from start to end.
function suggestToken(text, cursor) {
  var s = String(text || "")
  var at = Math.max(0, Math.min(Number(cursor) || 0, s.length))
  var before = s.slice(0, at)
  var rest = s.slice(at)
  var command = /^\/([A-Za-z0-9_]{0,32})$/.exec(before)
  if (command && !/^\S/.test(rest)) return { kind: "command", query: command[1], start: 0, end: at }
  var mention = /(^|[\s([{])@([^\s@]{0,32})$/.exec(before)
  if (mention && !/^\S/.test(rest)) return { kind: "mention", query: mention[2], start: at - mention[2].length - 1, end: at }
  var emoji = emojiToken(before, rest)
  if (emoji) return { kind: "emoji", query: emoji, start: at - emoji.length - 1, end: at }
  return { kind: "", query: "", start: at, end: at }
}

// ":hea" just before the cursor, at the start or after a space or bracket, and not run into a word after it:
// an emoji asked for by name. Times (12:30) and links (http://) are not.
function emojiToken(before, rest) {
  function space(ch) { return ch === " " || ch === String.fromCharCode(9) || ch === String.fromCharCode(10) }
  var colon = before.lastIndexOf(":")
  if (colon < 0) return ""
  var name = before.slice(colon + 1)
  var prev = colon === 0 ? "" : before.charAt(colon - 1)
  if (name.length < 2 || name.length > 32 || name.split("").some(space)) return ""
  if (prev !== "" && !space(prev) && "([{".indexOf(prev) < 0) return ""
  if (rest !== "" && !space(rest.charAt(0))) return ""
  return name
}

// A person put into a message: their @username, or a link to them that Telegram reads as a mention
// by name.
function mentionText(person) {
  if (!isObject(person)) return ""
  if (person.username) return "@" + person.username + " "
  var name = String(person.name || "").replace(/[\[\]()\n]/g, "").trim() || "someone"
  return "[" + name + "](tg://user?id=" + Number(person.userId) + ") "
}

// A bot command as typed; in a group it names its bot, so the right one answers.
function commandText(command, inGroup) {
  if (!isObject(command)) return ""
  return "/" + command.command + (inGroup && command.bot ? "@" + command.bot : "") + " "
}

function matchCommands(commands, query) {
  var q = String(query || "").toLowerCase()
  return toList(commands).filter(function (c) {
    return isObject(c) && typeof c.command === "string" && c.command.toLowerCase().indexOf(q) === 0
  }).sort(function (a, b) { return a.command < b.command ? -1 : (a.command > b.command ? 1 : 0) }).slice(0, 50)
}

// Telegram Markdown markers put around the text selected in the message box, or taken off again
// when they are already there: { text, start, end, wrapped } with the selection after the change.
function markdownToggle(text, start, end, before, after) {
  var s = String(text || "")
  var b = Math.min(s.length, Math.max(0, Math.max(start, end)))
  var a = Math.min(b, Math.max(0, Math.min(start, end)))
  if (a >= before.length && s.slice(a - before.length, a) === before && s.slice(b, b + after.length) === after)
    return { text: s.slice(0, a - before.length) + s.slice(a, b) + s.slice(b + after.length),
             start: a - before.length, end: b - before.length, wrapped: false }
  return { text: s.slice(0, a) + before + s.slice(a, b) + after + s.slice(b), start: a + before.length, end: b + before.length, wrapped: true }
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

// What marks a chat read up to its newest message, as "Mark as read" in the chat list does; nothing when nothing in
// it is unread. Answering a chat from the quick view uses it, since answering means you have read it.
function readRequests(chat) {
  if (!isObject(chat) || typeof chat.id !== "number" || chat.id === 0) return []
  var out = []
  var last = isObject(chat.lastMessage) ? chat.lastMessage.id : 0
  if (chat.unread > 0 && typeof last === "number" && last > 0) out.push({ cmd: "chat.read", args: { chatId: chat.id, messageIds: [last] } })
  if (chat.mentions > 0) out.push({ cmd: "chat.readMentions", args: { chatId: chat.id } })
  if (chat.markedUnread === true) out.push({ cmd: "chat.markUnread", args: { chatId: chat.id, unread: false } })
  return out
}

// A Qt colour as "#rrggbb" for Rich Text, or "" when it is not one.
function hexOf(color) {
  if (!color || typeof color.r !== "number" || typeof color.g !== "number" || typeof color.b !== "number") return ""
  var parts = [color.r, color.g, color.b]
  if (!parts.every(function (v) { return isFinite(v) })) return ""
  return "#" + parts.map(function (v) {
    var n = Math.max(0, Math.min(255, Math.round(v * 255)))
    return (n < 16 ? "0" : "") + n.toString(16)
  }).join("")
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
var DOWNLOADS_DEFAULT = { photos: true, gifs: true, videos: 0, files: 0 }

// Whether a message's media downloads as soon as it is on screen: stickers and voice messages always
// (they are small, and needed to play), photos, GIFs and round video messages up to 10 MB unless you
// said no, videos and files up to the size you chose in Settings.
function autoDownload(kind, size, rules) {
  var r = isObject(rules) ? rules : DOWNLOADS_DEFAULT
  var bytes = Number(size) || 0
  if (kind === "sticker" || kind === "voice") return bytes <= AUTO_DOWNLOAD_MAX
  if (kind === "photo") return r.photos !== false && bytes <= AUTO_DOWNLOAD_MAX
  if (kind === "gif" || kind === "videoNote") return r.gifs !== false && bytes <= AUTO_DOWNLOAD_MAX
  var limit = (kind === "video" ? Number(r.videos) : (kind === "file" || kind === "audio" ? Number(r.files) : 0)) || 0
  return limit > 0 && bytes > 0 && bytes <= limit * 1024 * 1024
}

function downloadText(rules, key) {
  var r = isObject(rules) ? rules : DOWNLOADS_DEFAULT
  if (key === "photos" || key === "gifs") return r[key] === false ? "No" : "Yes, up to 10 MB"
  var mb = Number(r[key]) || 0
  return mb > 0 ? "Up to " + mb + " MB" : "No"
}

// Enter on a download row: photos and GIFs yes or no; videos and files never, up to 10 MB, up to 50 MB.
function nextDownloadRule(rules, key) {
  var r = isObject(rules) ? rules : DOWNLOADS_DEFAULT
  var next = { photos: r.photos !== false, gifs: r.gifs !== false, videos: Number(r.videos) || 0, files: Number(r.files) || 0 }
  if (key === "photos" || key === "gifs") next[key] = !next[key]
  else if (key === "videos" || key === "files") next[key] = next[key] === 0 ? 10 : (next[key] === 10 ? 50 : 0)
  return next
}

function scopeText(view) {
  if (view === null) return "Telegram did not say"
  if (!isObject(view)) return "Loading…"
  return view.muted ? "Muted" : "Notify"
}

// Message text in notifications, over the three types of chat.
function previewsText(scopes) {
  var views = ["private", "groups", "channels"].map(function (key) { return isObject(scopes) ? scopes[key] : null })
                                                 .filter(function (view) { return isObject(view) })
  if (!views.length) return "Loading…"
  var shown = views.filter(function (view) { return view.preview === true }).length
  return shown === views.length ? "Shown" : (shown === 0 ? "Hidden" : "Shown for some")
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

function richText(text, entities, revealed, codeBackground, emojiImages, linkColor) {
  var s = String(text || "")
  // Rich Text takes a link's colour from the palette (Qt's blue), not from Text.linkColor, so it is written on the link.
  var linkStyle = /^#[0-9a-fA-F]{6}$/.test(String(linkColor || "")) ? ' style="color:' + linkColor + '; text-decoration:none"' : ""
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
      out += '<a href="omagram:spoiler"' + linkStyle + '>' + piece.replace(/[^\s]/g, "▒") + "</a>"
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
      if (href) { html = '<a href="' + escapeHtml(href) + '"' + linkStyle + '>' + html + "</a>"; break }
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
  if (p && p.canGetThread) out.push({ id: "thread", label: isObject(chat) && chat.kind === "channel" ? "Comments" : "Replies" })
  if (message.canSeeReactions && toList(message.reactions).length) out.push({ id: "reactions", label: "Who reacted" })
  if (p && p.canGetViewers) out.push({ id: "viewers", label: "Who has seen it" })
  if (c.text && (!p || p.canSave !== false)) out.push({ id: "copy", label: "Copy text" })
  // Telegram translates on its servers, which never see a secret chat's messages.
  if (c.text && !(isObject(chat) && chat.kind === "secret"))
    out.push(translated ? { id: "untranslate", label: "Hide the translation" } : { id: "translate", label: "Translate" })
  if (p && p.canGetLink) out.push({ id: "link", label: "Copy link" })
  if (p && p.canEdit) out.push({ id: "edit", label: c.kind === "text" ? "Edit" : "Edit caption" })
  if (p && p.canForward) out.push({ id: "forward", label: "Forward" })
  if (p && p.canPin) out.push(message.pinned ? { id: "unpin", label: "Unpin" } : { id: "pin", label: "Pin" })
  if (c.kind === "sticker" && isObject(c.media) && isObject(c.media.file)) {
    out.push({ id: "favoriteSticker", label: "Add to favorite stickers" })
    if (c.media.setId) out.push({ id: "stickerSet", label: "Its sticker set" })
  }
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
  if (chat.autoDelete > 0)
    out.push({ label: "Messages disappear", value: "after " + autoDeleteText(chat.autoDelete) + (chat.kind === "secret" ? " once seen" : "") })
  if (details.keyHash) out.push({ label: "Encryption key: the other device shows the same", value: String(details.keyHash) })
  return out
}

function infoActions(chat, meId) {
  if (!isObject(chat)) return []
  var out = [{ id: "mute", label: chat.muted ? "Unmute" : "Mute" }, { id: "search", label: "Search" }]
  if (chat.canSetAutoDelete) out.push({ id: "autoDelete", label: "Auto-delete messages" })
  if (chat.kind === "private" && !chat.bot && chat.userId && chat.userId !== meId)
    out.push({ id: "secret", label: "Start a secret chat" }, { id: "hearSound", label: "Hear their sound" },
             { id: "otherSound", label: "Give them another sound" })
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
    // A chat set to silent sending sends without sound already: the one-off is a message with sound.
    out.push(chat.silent ? { id: "loud", label: "Send with sound" } : { id: "silent", label: "Send without sound" })
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
  if (id === "loud") return { silent: false }
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

// ---------------------------------------------------------------- stories

// The chats with active stories in the main list, as Telegram orders them: by order, then chat id,
// both descending.
function storyChats(active) {
  return toList(active).filter(function (a) {
    return isObject(a) && a.list === "main" && compareOrder(String(a.order), "0") > 0 && toList(a.stories).length > 0
  }).sort(function (a, b) { return compareOrder(String(b.order), String(a.order)) || b.chatId - a.chatId })
}

function findStories(chats, chatId) {
  return toList(chats).filter(function (a) { return isObject(a) && a.chatId === chatId })[0] || null
}

function storiesUnread(active) {
  return isObject(active) && toList(active.stories).some(function (s) { return s.id > (active.maxReadId || 0) })
}

// Where a chat's stories start: at its first unread one, or at the first.
function firstStoryId(active) {
  var list = isObject(active) ? toList(active.stories) : []
  for (var i = 0; i < list.length; i++) if (list[i].id > (active.maxReadId || 0)) return list[i].id
  return list.length ? list[0].id : 0
}

// The story after (delta 1) or before (-1) one, across chats: { chatId, storyId }, or null past
// either end. Forward into a chat starts at its first unread story; back, at its last.
function storyStep(chats, chatId, storyId, delta) {
  var list = toList(chats)
  for (var c = 0; c < list.length; c++) {
    if (list[c].chatId !== chatId) continue
    var stories = toList(list[c].stories)
    var at = -1
    for (var i = 0; i < stories.length; i++) if (stories[i].id === storyId) at = i
    var next = at + delta
    if (next >= 0 && next < stories.length) return { chatId: chatId, storyId: stories[next].id }
    var other = list[c + (delta > 0 ? 1 : -1)]
    var theirs = other ? toList(other.stories) : []
    if (!theirs.length) return null
    return { chatId: other.chatId, storyId: delta > 0 ? firstStoryId(other) : theirs[theirs.length - 1].id }
  }
  return null
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
function historyKey(chatId, topicId, thread) {
  if (!(topicId > 0)) return String(chatId)
  return chatId + ":" + (thread ? "t" : "") + topicId
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

// The selected messages themselves, in the order they are shown.
function selectedMessages(messages, selection) {
  if (!isList(messages) || !isObject(selection)) return []
  return messages.filter(function (m) { return isObject(m) && selection[m.id] === true })
}

// Reacting to several messages at once is one toggle over the whole group: the reaction comes
// off only when every message already carries yours. A half-reacted selection finishes the job
// instead of undoing it, which is what you meant by selecting them together.
function reactionAdds(messages, emoji) {
  if (!isList(messages) || !messages.length) return true
  return !messages.every(function (m) { return reactionChosen(m, emoji) })
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

// ---------------------------------------------------------------- your profile

// What is wrong with a field of your profile as typed, or "" when it can go to Telegram.
function profileProblem(field, text) {
  var t = String(text === undefined || text === null ? "" : text)
  for (var i = 0; i < t.length; i++) if (t.charCodeAt(i) < 32) return "One line only"
  var trimmed = t.trim()
  if (field === "firstName") return trimmed === "" ? "A first name is needed" : (trimmed.length > 64 ? "At most 64 characters" : "")
  if (field === "lastName") return trimmed.length > 64 ? "At most 64 characters" : ""
  if (field === "bio") return trimmed.length > 140 ? "At most 140 characters" : ""
  if (field === "folderName") return trimmed === "" ? "A folder needs a name" : (trimmed.length > 12 ? "At most 12 characters" : "")
  if (field === "username") {
    var name = trimmed.replace(/^@/, "")
    if (name === "") return ""
    if (!/^[A-Za-z]/.test(name)) return "A username starts with a letter"
    if (!/^[A-Za-z0-9_]+$/.test(name)) return "Letters, digits and underscores only"
    if (name.length < 5 || name.length > 32) return "5 to 32 characters"
  }
  return ""
}

// Telegram turning a change of your profile down, in words; "" when nothing was wrong after all.
function profileError(error) {
  var e = String(error || "")
  if (/NOT_MODIFIED/.test(e)) return ""
  if (/USERNAME_OCCUPIED|USERNAME_PURCHASE_AVAILABLE/.test(e)) return "That username is taken"
  if (/USERNAME_INVALID|username is invalid/i.test(e)) return "Telegram does not accept that username"
  if (/FIRSTNAME_INVALID|LASTNAME_INVALID/.test(e)) return "Telegram does not accept that name"
  if (/ABOUT_TOO_LONG/.test(e)) return "That bio is too long"
  if (/PHOTO_CROP_SIZE_SMALL|PHOTO_INVALID_DIMENSIONS/.test(e)) return "That picture is too small: pick one at least 160 pixels on each side"
  if (/FLOOD_WAIT/.test(e)) return "Telegram asks you to wait before changing that again"
  return e || "Telegram did not take the change"
}

// What a row of your profile shows under its name.
function profileValue(profile, field) {
  if (!isObject(profile)) return "Loading…"
  if (field === "firstName") return profile.firstName || ""
  if (field === "lastName") return profile.lastName || "None"
  if (field === "username") return profile.username ? "@" + profile.username : "None: people find you by your name or number"
  if (field === "bio") return profile.bio || "None"
  if (field === "phone") return profile.phone ? "+" + profile.phone : ""
  if (field === "photo") return profile.photo || profile.photoId ? "" : "None"
  return ""
}

// You, the way Avatar draws a chat: your photo, or your initials.
function profileChat(profile) {
  if (!isObject(profile)) return null
  return { id: 0, kind: "private", userId: 0, photo: profile.photo || null,
           title: [profile.firstName, profile.lastName].filter(function (part) { return !!part }).join(" ") }
}

// ---------------------------------------------------------------- a sound for each person

var SOUND_STYLES = [["pop", "Pop", "soft and round"], ["drop", "Drop", "a drop of water"], ["knock", "Knock", "a knuckle on wood"]]

function soundStyleText(style) {
  for (var i = 0; i < SOUND_STYLES.length; i++) if (SOUND_STYLES[i][0] === style) return SOUND_STYLES[i][1] + ", " + SOUND_STYLES[i][2]
  return "Off"
}

// Round and round: each instrument, then off.
function nextSoundStyle(style) {
  var keys = SOUND_STYLES.map(function (s) { return s[0] }).concat(["off"])
  var at = keys.indexOf(style)
  return keys[(at < 0 ? 0 : at + 1) % keys.length]
}

// ---------------------------------------------------------------- readable colours

// A colour's relative luminance (as WCAG counts it), from r, g and b between 0 and 1.
function colorLuminance(c) {
  function channel(v) { return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
}

// How far apart two colours read: 1 for the same, 21 for black on white. Text wants 4.5.
function colorContrast(a, b) {
  var la = colorLuminance(a)
  var lb = colorLuminance(b)
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
}

function mixColors(a, b, t) {
  return { r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t }
}

// `color` itself when it reads at `minimum` on `ground`; otherwise moved toward `toward` (the text colour) just
// far enough, and past it toward white or black, whichever the ground is further from.
function readableColor(color, ground, toward, minimum) {
  var c = { r: color.r, g: color.g, b: color.b }
  if (colorContrast(c, ground) >= minimum) return c
  for (var t = 0.1; t <= 1.0001; t += 0.1) {
    var toText = mixColors(c, toward, t)
    if (colorContrast(toText, ground) >= minimum) return toText
  }
  var pole = colorLuminance(ground) > 0.18 ? { r: 0, g: 0, b: 0 } : { r: 1, g: 1, b: 1 }
  for (var s = 0.1; s <= 1.0001; s += 0.1) {
    var toPole = mixColors(toward, pole, s)
    if (colorContrast(toPole, ground) >= minimum) return toPole
  }
  return pole
}

// Of the text colours a theme offers, the one that stands out most on `ground`.
function bestTextColor(ground, candidates) {
  var list = toList(candidates)
  var best = list[0]
  for (var i = 1; i < list.length; i++) if (colorContrast(list[i], ground) > colorContrast(best, ground)) best = list[i]
  return best
}

// Text on a filled shape (a count on a badge, a primary button): the first of `inks` that reads at `minimum`,
// or else whichever of them, white and black reads best.
function inkOnFill(fill, inks, minimum) {
  var preferred = toList(inks)
  for (var i = 0; i < preferred.length; i++) if (colorContrast(preferred[i], fill) >= minimum) return preferred[i]
  return bestTextColor(fill, preferred.concat([{ r: 1, g: 1, b: 1 }, { r: 0, g: 0, b: 0 }]))
}

// ---------------------------------------------------------------- proxies

var PROXY_TYPE_NAMES = { socks5: "SOCKS5", http: "HTTP", mtproto: "MTProto" }

// "proxy.example.com:1080", "1.2.3.4:443" or "[2001:db8::1]:443" as { server, port }; null when it is not that.
function parseProxyAddress(text) {
  var t = String(text || "").trim()
  var colon = t.lastIndexOf(":")
  if (colon <= 0) return null
  var server = t.slice(0, colon)
  var port = t.slice(colon + 1)
  if (server.charAt(0) === "[" && server.charAt(server.length - 1) === "]") server = server.slice(1, -1)
  if (!/^[-A-Za-z0-9.:]{1,253}$/.test(server) || !/^[0-9]{1,5}$/.test(port)) return null
  var n = Number(port)
  return n >= 1 && n <= 65535 ? { server: server, port: n } : null
}

// t.me/proxy?…, t.me/socks?… (telegram.me and telegram.dog too), tg://proxy?… and tg://socks?…
function isProxyLink(text) {
  return /^((https?:[/][/])?(www[.])?(t[.]me|telegram[.]me|telegram[.]dog)[/]|tg:[/][/])(proxy|socks)[?]/i.test(String(text || "").trim())
}

function proxyLinkUrl(text) {
  var t = String(text || "").trim()
  return /^(https?|tg):/i.test(t) ? t : "https://" + t
}

// What adding a proxy asks, one field at a time.
function proxySteps(kind) {
  var address = { key: "address", label: "The server and its port", placeholder: "proxy.example.com:1080" }
  if (kind === "mtproto") return [address, { key: "secret", label: "The secret", secret: true, placeholder: "as the proxy's owner gave it" }]
  if (kind === "socks5" || kind === "http")
    return [address, { key: "username", label: "Username (you can leave this empty)" },
            { key: "password", label: "Password (you can leave this empty)", secret: true }]
  if (kind === "link") return [{ key: "link", label: "The proxy link", placeholder: "https://t.me/proxy?server=…" }]
  return []
}

function proxyStepProblem(step, text) {
  var t = String(text === undefined || text === null ? "" : text)
  if (!isObject(step)) return ""
  if (step.key === "address") return parseProxyAddress(t) ? "" : "Type the server and its port, like proxy.example.com:1080"
  if (step.key === "secret") return /^[-A-Za-z0-9_=]{16,512}$/.test(t.trim()) ? "" : "The secret is the long code the proxy's owner gave"
  if (step.key === "username" || step.key === "password") return t.length > 255 ? "At most 255 characters" : ""
  if (step.key === "link") return isProxyLink(t) ? "" : "A proxy link starts with t.me/proxy or t.me/socks"
  return ""
}

// A proxy's line: "SOCKS5 · 123 ms · in use". `ping` is { seconds }, { error: true }, or nothing yet.
function proxyText(proxy, ping, connection) {
  if (!isObject(proxy)) return ""
  var parts = [PROXY_TYPE_NAMES[proxy.type] || "Proxy"]
  if (isObject(ping)) parts.push(ping.error ? "not answering" : Math.round(Number(ping.seconds) * 1000) + " ms")
  if (proxy.enabled) parts.push(["network", "proxy", "connecting"].indexOf(connection) >= 0 ? "connecting…" : "in use")
  return parts.join(" · ")
}

function connectionText(state) {
  return ({ network: "Waiting for the network…", proxy: "Connecting to the proxy…", connecting: "Connecting…",
            updating: "Updating…", ready: "Connected" })[state] || ""
}

// ---------------------------------------------------------------- a link's preview while typing, disappearing messages

// The first thing in typed text that may be a link, so Telegram is asked for a preview only when it changes; "" when none.
function composerLink(text) {
  var flat = String(text || "").split(String.fromCharCode(10)).join(" ").split(String.fromCharCode(9)).join(" ")
  var m = /(https?:[/][/]|www[.]|t[.]me[/])[^ ()<>]+|[a-z0-9][a-z0-9-]*([.][a-z0-9-]+)*[.][a-z]{2,24}([/:?#][^ ()<>]*)?/i.exec(flat)
  return m && m[0].length <= 2048 ? m[0] : ""
}

var AUTO_DELETE_TIMES = [0, 86400, 604800, 2678400]           // off, a day, a week, a month (31 days, as Telegram counts it)
var SECRET_CHAT_TIMERS = [0, 5, 30, 60, 3600, 86400, 604800]   // after a message is seen

// "1 day", "2 weeks", "1 month", "30 seconds"; "Off" when messages stay.
function autoDeleteText(seconds) {
  var s = Math.max(0, Math.floor(Number(seconds) || 0))
  if (!s) return "Off"
  if (s === 2678400) return "1 month"
  var units = [[31536000, "year"], [604800, "week"], [86400, "day"], [3600, "hour"], [60, "minute"], [1, "second"]]
  for (var i = 0; i < units.length; i++) {
    if (s % units[i][0]) continue
    var n = s / units[i][0]
    return n + " " + units[i][1] + (n === 1 ? "" : "s")
  }
}

// The default for new chats, round and round: off, a day, a week, a month.
function nextAutoDelete(seconds) {
  var s = Number(seconds) || 0
  for (var i = 0; i < AUTO_DELETE_TIMES.length; i++) if (AUTO_DELETE_TIMES[i] > s) return AUTO_DELETE_TIMES[i]
  return 0
}

// What a chat's messages can be set to disappear after, with the current choice ticked.
function autoDeleteMenu(chat) {
  if (!isObject(chat)) return []
  var current = Number(chat.autoDelete) || 0
  var secret = chat.kind === "secret"
  var times = (secret ? SECRET_CHAT_TIMERS : AUTO_DELETE_TIMES).slice()
  if (times.indexOf(current) < 0) times.push(current)   // set to something else in another app
  return times.map(function (t) {
    return { id: "autoDelete:" + t, label: (t ? "After " + autoDeleteText(t) + (secret ? " once seen" : "") : "Keep messages") + (t === current ? "   ✓" : "") }
  })
}

// Seconds from an auto-delete menu item, or -1 when it is not one.
function autoDeleteSeconds(id) {
  var m = /^autoDelete:(0|[1-9][0-9]{0,8})$/.exec(String(id))
  return m ? Number(m[1]) : -1
}

// ---------------------------------------------------------------- going to a date

// A month typed as at least its first three letters: "sep", "sept" and "september" are 8; -1 when it is none.
function monthOf(word) {
  for (var i = 0; i < MONTHS_LONG.length; i++) if (word.length >= 3 && MONTHS_LONG[i].toLowerCase().indexOf(word) === 0) return i
  return -1
}

// A day without a year given is this year's, or last year's when this year's is still ahead.
function dayOf(date, month, year, now) {
  var y = year !== undefined ? Number(year) : now.getFullYear()
  var d = new Date(y, month, date)
  if (d.getMonth() !== month || d.getDate() !== date) return null
  if (year === undefined && d.getTime() > now.getTime()) d = new Date(y - 1, month, date)
  return d
}

// The start of a day you typed, local time, in seconds: "today", "yesterday", "2026-09-01", "01.09.2026",
// "1.9", "1 Sep" or "Sep 1". null when it is not a day, or it is still to come.
function parseDay(text, nowMs) {
  var s = String(text === undefined || text === null ? "" : text).trim().toLowerCase()
  var now = new Date(nowMs)
  var day = null
  var m = null
  if (s === "today") day = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  else if (s === "yesterday") day = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1)
  else if ((m = /^([0-9]{4})-([0-9]{1,2})-([0-9]{1,2})$/.exec(s)) !== null) day = dayOf(Number(m[3]), Number(m[2]) - 1, m[1], now)
  else if ((m = /^([0-9]{1,2})[.]([0-9]{1,2})(?:[.]([0-9]{4}))?$/.exec(s)) !== null) day = dayOf(Number(m[1]), Number(m[2]) - 1, m[3], now)
  else if ((m = /^([0-9]{1,2}) ([a-z]+)$/.exec(s)) !== null && monthOf(m[2]) >= 0) day = dayOf(Number(m[1]), monthOf(m[2]), undefined, now)
  else if ((m = /^([a-z]+) ([0-9]{1,2})$/.exec(s)) !== null && monthOf(m[1]) >= 0) day = dayOf(Number(m[2]), monthOf(m[1]), undefined, now)
  if (!day || isNaN(day.getTime()) || day.getTime() > nowMs) return null
  return Math.floor(day.getTime() / 1000)
}

// ---------------------------------------------------------------- more to send: dice, contact cards, locations

var DICE = [["🎲", "Dice"], ["🎯", "Darts"], ["🏀", "Basketball"], ["⚽", "Football"], ["🎳", "Bowling"], ["🎰", "Slot machine"]]

// What the message box's + button offers. Polls only where Telegram takes them: not in secret chats, and
// in a private chat only with a bot or in Saved Messages.
function moreMenu(chat, meId) {
  if (!isObject(chat)) return []
  var out = []
  var botOrSaved = chat.kind === "private" && (chat.bot === true || (!!meId && chat.userId === meId))
  if (chat.kind !== "secret" && (chat.kind !== "private" || botOrSaved)) out.push({ id: "poll", label: "A poll or a quiz" })
  return out.concat([{ id: "dice", label: "Dice, darts or a slot machine" }, { id: "contact", label: "A contact card" },
                     { id: "location", label: "A location" }])
}

// What stops a poll from going out, or "". Its options are the answers typed, empty rows left out, and
// `correct` counts among them.
function pollProblem(poll) {
  if (!isObject(poll)) return "No poll"
  var question = String(poll.question || "").trim()
  if (question === "") return "A poll needs a question"
  if (question.length > 255) return "The question is at most 255 characters"
  var answers = toList(poll.options).map(function (o) { return String(o === undefined || o === null ? "" : o).trim() })
                                    .filter(function (o) { return o !== "" })
  if (answers.length < 2) return "A poll needs at least two answers"
  if (answers.length > 12) return "At most 12 answers"
  if (answers.some(function (o) { return o.length > 100 })) return "An answer is at most 100 characters"
  var seen = {}
  for (var i = 0; i < answers.length; i++) {
    var key = answers[i].toLowerCase()
    if (seen[key]) return "Two answers are the same"
    seen[key] = true
  }
  if (poll.quiz) {
    if (!(poll.correct >= 0 && poll.correct < answers.length)) return "Mark the right answer"
    if (String(poll.explanation || "").length > 200) return "The explanation is at most 200 characters"
  }
  return ""
}

function diceMenu() {
  return DICE.map(function (d) { return { id: "dice:" + d[0], label: d[0] + "   " + d[1] } })
}

// Coordinates from what you typed or pasted: "50.45, 30.52", a geo: link, or a Google Maps or OpenStreetMap link.
function parseLocation(text) {
  var s = String(text === undefined || text === null ? "" : text).trim()
  var number = "(-?[0-9]{1,3}(?:[.][0-9]+)?)"
  var patterns = [new RegExp("@" + number + "," + number), new RegExp("[?&](?:q|query|ll|center)=" + number + "(?:,|%2C)" + number, "i"),
                  new RegExp("mlat=" + number + "&mlon=" + number), new RegExp("#map=[0-9]{1,2}/" + number + "/" + number),
                  new RegExp("^geo:" + number + "," + number, "i"), new RegExp("^" + number + "[ ]*[, ][ ]*" + number + "$")]
  for (var i = 0; i < patterns.length; i++) {
    var m = patterns[i].exec(s)
    if (!m) continue
    var latitude = Number(m[1])
    var longitude = Number(m[2])
    if (Math.abs(latitude) <= 90 && Math.abs(longitude) <= 180) return { latitude: latitude, longitude: longitude }
  }
  return null
}

function locationText(place) {
  return isObject(place) ? Number(place.latitude).toFixed(5) + ", " + Number(place.longitude).toFixed(5) : ""
}

// ---------------------------------------------------------------- chat folders

var FOLDER_KINDS = [["includeContacts", "Contacts"], ["includeNonContacts", "Other people"], ["includeGroups", "Groups"],
                    ["includeChannels", "Channels"], ["includeBots", "Bots"]]
var FOLDER_LEAVES = [["excludeMuted", "muted"], ["excludeRead", "read"], ["excludeArchived", "archived"]]

// Under a folder in Settings: the kinds of chats it takes, the chats always in it, and what it leaves out.
function folderSummary(folder) {
  if (!isObject(folder)) return ""
  var parts = []
  var kinds = FOLDER_KINDS.filter(function (k) { return folder[k[0]] === true }).map(function (k) { return k[1] })
  if (kinds.length) parts.push(kinds.join(", "))
  var always = toList(folder.pinned).concat(toList(folder.included)).filter(function (id, i, all) { return all.indexOf(id) === i }).length
  if (always) parts.push(always + (always === 1 ? " chat always in it" : " chats always in it"))
  var never = toList(folder.excluded).length
  if (never) parts.push(never + (never === 1 ? " chat left out" : " chats left out"))
  var leaves = FOLDER_LEAVES.filter(function (k) { return folder[k[0]] === true }).map(function (k) { return k[1] })
  if (leaves.length) parts.push("without " + leaves.join(", ") + " chats")
  return parts.length ? parts.join(" · ") : "Empty"
}

function newFolder() {
  return { id: 0, name: "", icon: "", colorId: -1, shareable: false, includeContacts: false, includeNonContacts: false,
           includeGroups: false, includeChannels: false, includeBots: false, excludeMuted: false, excludeRead: false,
           excludeArchived: false, pinned: [], included: [], excluded: [] }
}

// What stops a folder from being saved, or "".
function folderProblem(folder) {
  if (!isObject(folder)) return "No folder"
  var name = String(folder.name || "").trim()
  if (name === "") return "A folder needs a name"
  if (name.length > 12) return "A folder's name is at most 12 characters"
  var takes = FOLDER_KINDS.some(function (k) { return folder[k[0]] === true })
  if (!takes && !toList(folder.included).length && !toList(folder.pinned).length) return "Choose chats for it: a kind of chat, or a chat always in it"
  return ""
}

// The folders' ids with one of them moved a step earlier (-1) or later (1).
function movedFolders(ids, id, delta) {
  var list = toList(ids).slice()
  var at = list.indexOf(id)
  var to = at + delta
  if (at < 0 || to < 0 || to >= list.length) return list
  list.splice(at, 1)
  list.splice(to, 0, id)
  return list
}

// ---------------------------------------------------------------- privacy and security

var PRIVACY_CHOICES = ["everybody", "contacts", "nobody"]

// Who may see or do something, with the people and chats you made exceptions for.
function privacyText(view) {
  if (view === null) return "Telegram did not say"
  if (!isObject(view)) return "Loading…"
  var text = ({ everybody: "Everybody", contacts: "My contacts", nobody: "Nobody" })[view.base] || "Nobody"
  var except = []
  if (view.allowed > 0) except.push(view.allowed + " more allowed")
  if (view.restricted > 0) except.push(view.restricted + " kept out")
  return except.length ? text + " · " + except.join(", ") : text
}

// Enter on a privacy row: the next choice. Finding you by your number is for everybody or contacts only.
function nextPrivacy(settingId, base) {
  var choices = settingId === "findByPhone" ? ["everybody", "contacts"] : PRIVACY_CHOICES
  return choices[(choices.indexOf(base) + 1) % choices.length]
}

var ACCOUNT_TTL_DAYS = [30, 90, 180, 365, 548, 730]

function ttlText(days) {
  var d = Number(days) || 0
  if (d <= 0) return "Loading…"
  if (d >= 700) return "2 years"
  if (d >= 540) return "18 months"
  if (d >= 360) return "1 year"
  if (d >= 170) return "6 months"
  if (d >= 85) return "3 months"
  return "1 month"
}

function nextTtl(days) {
  var d = Number(days) || 0
  for (var i = 0; i < ACCOUNT_TTL_DAYS.length; i++) if (ACCOUNT_TTL_DAYS[i] > d + 5) return ACCOUNT_TTL_DAYS[i]
  return ACCOUNT_TTL_DAYS[0]
}

function passwordText(state) {
  if (!isObject(state)) return "Loading…"
  if (state.emailCodePattern) return "Waiting for the code sent to " + state.emailCodePattern
  if (!state.hasPassword) return "Off: the code Telegram sends is all it takes to sign in"
  return "On" + (state.hint ? " · hint: " + state.hint : "") + (state.hasRecoveryEmail ? " · recovery email set" : "")
}

function blockedText(blocked) {
  if (!isObject(blocked)) return "Loading…"
  var n = Math.max(0, Number(blocked.total) | 0)
  return n === 0 ? "Nobody" : n + (n === 1 ? " person or chat" : " people and chats")
}

// Changing two-step verification, one field at a time: turning it on, changing the password,
// turning it off, or typing the code Telegram emailed.
function passwordSteps(kind) {
  var current = { key: "oldPassword", label: "Your current password", secret: true }
  var fresh = [{ key: "newPassword", label: "A new password", secret: true },
               { key: "repeat", label: "The new password again", secret: true },
               { key: "hint", label: "A hint for it (you can leave this empty)", placeholder: "not the password itself" }]
  if (kind === "on") return fresh.concat([{ key: "email", label: "A recovery email (you can leave this empty)", placeholder: "for when you forget the password" }])
  if (kind === "change") return [current].concat(fresh)
  if (kind === "off") return [current]
  if (kind === "code") return [{ key: "code", label: "The code Telegram emailed you", placeholder: "from the email" }]
  return []
}

function passwordStepProblem(step, text, values) {
  var t = String(text === undefined || text === null ? "" : text)
  if (!isObject(step)) return ""
  if (step.key === "oldPassword" || step.key === "newPassword") return t === "" ? "Type the password" : (t.length > 256 ? "At most 256 characters" : "")
  if (step.key === "repeat") return t !== (isObject(values) ? values.newPassword : undefined) ? "That is not the same password" : ""
  if (step.key === "hint") {
    if (t.trim() !== "" && isObject(values) && t.trim() === values.newPassword) return "A hint cannot be the password itself"
    return t.length > 64 ? "At most 64 characters" : ""
  }
  if (step.key === "email") return t.trim() === "" || /^[^@ ]+@[^@ ]+[.][^@ ]+$/.test(t.trim()) ? "" : "That does not look like an email address"
  if (step.key === "code") return t.trim() === "" ? "Type the code" : ""
  return ""
}

function passwordError(error) {
  var e = String(error || "")
  if (/PASSWORD_HASH_INVALID|wrong password/i.test(e)) return "That password is not right"
  if (/EMAIL_INVALID/.test(e)) return "Telegram does not accept that email address"
  if (/CODE_INVALID|EMAIL_HASH_EXPIRED|CODE_EXPIRED/.test(e)) return "That code is not right, or it has expired"
  if (/FLOOD_WAIT|too many/i.test(e)) return "Too many tries: Telegram asks you to wait"
  return e || "Telegram did not take the change"
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

