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

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
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
  return key === "main" && Array.isArray(chat.lists) && chat.lists.indexOf("main") >= 0 ? String(chat.order) : "0"
}

function pinnedIn(chat, listKey) {
  var key = listKey || "main"
  if (isObject(chat) && isObject(chat.positions)) return isObject(chat.positions[key]) && chat.positions[key].pinned === true
  return key === "main" && isObject(chat) && chat.pinned === true
}

function sortChats(chats, listKey) {
  var key = listKey || "main"
  var list = Array.isArray(chats) ? chats.filter(function (c) { return isObject(c) && typeof c.id === "number" }) : []
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
  return sortChats((Array.isArray(chats) ? chats : []).filter(function (c) { return compareOrder(orderIn(c, key), "0") > 0 }), key)
}

// The tabs above the chat list: folders in Telegram's order with "All" where Telegram puts
// the main list, and the archive last.
function listTabs(folders, mainPosition) {
  var list = Array.isArray(folders) ? folders.filter(function (f) { return isObject(f) && typeof f.id === "number" && f.id > 0 }) : []
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

function filterChats(chats, query) {
  var q = String(query || "").trim().toLowerCase()
  if (!q) return chats
  return chats.filter(function (c) { return String(c.title || "").toLowerCase().indexOf(q) >= 0 })
}

function unreadTotal(chats) {
  var n = 0
  for (var i = 0; i < chats.length; i++) if (!chats[i].muted) n += Math.max(0, chats[i].unread | 0)
  return n
}

// ---------------------------------------------------------------- messages

function mergeMessages(existing, incoming) {
  var byId = {}
  var all = (existing || []).concat(incoming || [])
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
function autoDownload(kind, size) {
  if (kind === "sticker" || kind === "voice") return true
  if (kind === "photo" || kind === "gif" || kind === "videoNote") return (Number(size) || 0) <= AUTO_DOWNLOAD_MAX
  return false
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
