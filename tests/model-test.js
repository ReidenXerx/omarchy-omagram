#!/usr/bin/env node
// node tests/model-test.js — app/Model.js without a compositor.
"use strict"
const fs = require("fs")
const path = require("path")
const vm = require("vm")
const assert = require("assert")

const source = fs.readFileSync(path.join(__dirname, "..", "app", "Model.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
const box = {}
vm.runInNewContext(source + "\nthis.M = { CHATS_MAX, MESSAGES_MAX, compareOrder, orderIn, pinnedIn, sortChats, upsertChat, upsertKnown, chatsIn, listTabs, findChat, indexOfChat, filterChats, unreadTotal, mergeMessages, replaceMessage, removeMessages, patchMessage, findMessage, oldestId, lastOwnEditable, incomingIds, contentLabel, previewOf, sameRun, sameDay, listTime, dayLabel, clock, initials, validApiId, validApiHash, cleanPhone, validCode }", box)
const M = box.M
const plain = v => JSON.parse(JSON.stringify(v))
const eq = (a, b, msg) => assert.deepStrictEqual(plain(a), plain(b), msg)

let passed = 0
const failures = []
function test(name, fn) {
  try { fn(); passed++ } catch (e) { failures.push(name + "\n    " + e.message) }
}

const chat = (id, order, extra) => Object.assign({ id, title: "Chat " + id, order: String(order), lists: ["main"], unread: 0 }, extra || {})
const msg = (id, extra) => Object.assign({ id, chatId: 1, date: 1789000000 + id, outgoing: false,
  sender: { type: "user", id: 7 }, content: { kind: "text", text: "m" + id, entities: [] } }, extra || {})

test("int64 orders compare exactly, beyond double precision", () => {
  assert.strictEqual(M.compareOrder("9223372036854775806", "9223372036854775807"), -1)
  assert.strictEqual(M.compareOrder("100", "99"), 1)
  assert.strictEqual(M.compareOrder("007", "7"), 0)
  assert.strictEqual(M.compareOrder("junk", "0"), 0)
  eq(M.sortChats([chat(1, "9223372036854775806"), chat(2, "9223372036854775807"), chat(3, "5")]).map(c => c.id), [2, 1, 3])
})

test("chats per list: order and pin in each list, tabs in Telegram's order", () => {
  const c1 = { id: 1, positions: { main: { order: "50", pinned: false }, "folder:3": { order: "9", pinned: true } } }
  const c2 = { id: 2, positions: { archive: { order: "70", pinned: false } } }
  const c3 = { id: 3, positions: { main: { order: "60", pinned: true } } }
  const all = [c1, c2, c3]
  eq(M.chatsIn(all, "main").map(c => c.id), [3, 1])
  eq(M.chatsIn(all, "archive").map(c => c.id), [2])
  eq(M.chatsIn(all, "folder:3").map(c => c.id), [1])
  assert.strictEqual(M.pinnedIn(c1, "folder:3"), true)
  assert.strictEqual(M.pinnedIn(c1, "main"), false)
  assert.strictEqual(M.orderIn(c2, "main"), "0")
  assert.strictEqual(M.orderIn(chat(9, 12), "main"), "12")   // views without positions
  const known = M.upsertKnown(all, { id: 1, positions: { archive: { order: "80" } } })
  eq(known.map(c => c.id), [2, 3, 1])
  eq(M.chatsIn(known, "archive").map(c => c.id), [1, 2])
  eq(M.chatsIn(known, "main").map(c => c.id), [3])
  eq(M.listTabs([{ id: 3, name: "Work" }, { id: 5, name: "" }, { id: 0 }], 1).map(t => t.key + "=" + t.title),
     ["folder:3=Work", "main=All", "folder:5=Folder", "archive=Archive"])
  eq(M.listTabs(null, 9).map(t => t.key), ["main", "archive"])
})

test("upsert replaces, reorders and drops chats that left the list", () => {
  let chats = M.sortChats([chat(1, 10), chat(2, 20)])
  chats = M.upsertChat(chats, chat(1, 30, { title: "Renamed" }))
  eq(chats.map(c => [c.id, c.title]), [[1, "Renamed"], [2, "Chat 2"]])
  chats = M.upsertChat(chats, chat(2, 0))
  eq(chats.map(c => c.id), [1])
  chats = M.upsertChat(chats, chat(1, 30, { lists: ["archive"] }))
  eq(chats, [])
  eq(M.upsertChat([chat(1, 1)], "junk"), [chat(1, 1)])
})

test("filter, find and unread total", () => {
  const chats = [chat(1, 3, { title: "Mom", unread: 2 }), chat(2, 2, { title: "Work group", unread: 10, muted: true }), chat(3, 1, { title: "momentum", unread: 1 })]
  eq(M.filterChats(chats, " MOM ").map(c => c.id), [1, 3])
  assert.strictEqual(M.filterChats(chats, "").length, 3)
  assert.strictEqual(M.unreadTotal(chats), 3)
  assert.strictEqual(M.findChat(chats, 2).title, "Work group")
  assert.strictEqual(M.indexOfChat(chats, 9), -1)
})

test("history merges without duplicates, newest wins, capped", () => {
  const merged = M.mergeMessages([msg(3), msg(1)], [msg(2), msg(3, { content: { kind: "text", text: "edited" } }), "junk", { id: -1 }])
  eq(merged.map(m => m.id), [1, 2, 3])
  assert.strictEqual(merged[2].content.text, "edited")
  const many = M.mergeMessages([], Array.from({ length: M.MESSAGES_MAX + 10 }, (_, i) => msg(i + 1)))
  assert.strictEqual(many.length, M.MESSAGES_MAX)
  assert.strictEqual(many[0].id, 11)
})

test("send succeeded, deletes, patches", () => {
  let list = [msg(1), msg(2, { outgoing: true, sending: "pending" })]
  list = M.replaceMessage(list, 2, msg(50, { outgoing: true }))
  eq(list.map(m => m.id), [1, 50])
  list = M.patchMessage(list, 50, { editDate: 5 })
  assert.strictEqual(list[1].editDate, 5)
  assert.strictEqual(list[0].editDate, undefined)
  eq(M.removeMessages(list, [1, 99]).map(m => m.id), [50])
  assert.strictEqual(M.oldestId(list), 1)
  assert.strictEqual(M.oldestId([]), 0)
})

test("last own editable and incoming ids", () => {
  const list = [msg(1, { outgoing: true }), msg(2), msg(3, { outgoing: true, content: { kind: "photo", text: "" } }),
                msg(4, { outgoing: true, sending: "pending" }), msg(5)]
  assert.strictEqual(M.lastOwnEditable(list).id, 1)
  assert.strictEqual(M.lastOwnEditable([msg(1)]), null)
  eq(M.incomingIds(list, 5), [2, 5])
  eq(M.incomingIds(list, 1), [5])
})

test("previews and labels", () => {
  assert.strictEqual(M.previewOf(msg(1, { content: { kind: "text", text: "  two\n\nlines  " } })), "two lines")
  assert.strictEqual(M.previewOf(msg(1, { content: { kind: "photo", text: "sunset" } })), "Photo, sunset")
  assert.strictEqual(M.previewOf(msg(1, { content: { kind: "sticker", emoji: "😂", text: "" } })), "😂 Sticker")
  assert.strictEqual(M.previewOf(msg(1, { content: { kind: "file", fileName: "a.pdf", text: "" } })), "a.pdf")
  assert.strictEqual(M.previewOf(msg(1, { content: { kind: "text", text: "x".repeat(500) } })).length, 120)
  assert.strictEqual(M.previewOf(null), "")
  assert.strictEqual(M.contentLabel({ kind: "whatever" }), "Message")
})

test("runs group a sender's messages within five minutes", () => {
  const a = msg(1, { date: 1000 })
  assert.strictEqual(M.sameRun(a, msg(2, { date: 1200 })), true)
  assert.strictEqual(M.sameRun(a, msg(2, { date: 1400 })), false)
  assert.strictEqual(M.sameRun(a, msg(2, { date: 1100, sender: { type: "user", id: 8 } })), false)
  assert.strictEqual(M.sameRun(a, msg(2, { date: 1100, outgoing: true })), false)
})

test("times read like a messenger", () => {
  const now = new Date(2026, 8, 12, 15, 0).getTime()
  const at = (y, mo, d, h, mi) => new Date(y, mo, d, h, mi).getTime() / 1000
  assert.strictEqual(M.listTime(at(2026, 8, 12, 9, 5), now), "09:05")
  assert.strictEqual(M.listTime(at(2026, 8, 10, 23, 0), now), "Thu")
  assert.strictEqual(M.listTime(at(2026, 6, 1, 8, 0), now), "1 Jul")
  assert.strictEqual(M.listTime(at(2025, 11, 31, 8, 0), now), "31 Dec 2025")
  assert.strictEqual(M.listTime(0, now), "")
  assert.strictEqual(M.dayLabel(at(2026, 8, 12, 1, 0), now), "Today")
  assert.strictEqual(M.dayLabel(at(2026, 8, 11, 23, 59), now), "Yesterday")
  assert.strictEqual(M.dayLabel(at(2026, 8, 8, 12, 0), now), "Tuesday")
  assert.strictEqual(M.dayLabel(at(2026, 0, 3, 12, 0), now), "3 January")
  assert.strictEqual(M.sameDay(at(2026, 8, 12, 0, 0), at(2026, 8, 12, 23, 59)), true)
})

test("initials and input checks", () => {
  assert.strictEqual(M.initials("anna lee smith"), "AL")
  assert.strictEqual(M.initials("🦊 Fox"), "🦊F")
  assert.strictEqual(M.initials("   "), "?")
  assert.strictEqual(M.validApiId("123456"), true)
  assert.strictEqual(M.validApiId("0123"), false)
  assert.strictEqual(M.validApiHash("0123456789abcdef0123456789abcdef"), true)
  assert.strictEqual(M.validApiHash("0123456789ABCDEF0123456789ABCDEF"), false)
  assert.strictEqual(M.cleanPhone("+380 (67) 123-45-67"), "+380671234567")
  assert.strictEqual(M.cleanPhone("call me"), "")
  assert.strictEqual(M.validCode("12345"), true)
  assert.strictEqual(M.validCode("12a45"), false)
})

test("media URLs never let a file name change the target", () => {
  const box2 = {}
  vm.runInNewContext(source + "\nthis.M = { fileUrl, miniUrl, formatSize, formatDuration, fitSize, autoDownload, progress, AUTO_DOWNLOAD_MAX }", box2)
  const X = box2.M
  assert.strictEqual(X.fileUrl("/home/u/.local/share/omagram/files/photos/a b#1.jpg"),
                     "file:///home/u/.local/share/omagram/files/photos/a%20b%231.jpg")
  for (const bad of ["relative/a.jpg", "", null, 5, "/a\0b"]) assert.strictEqual(X.fileUrl(bad), "", String(bad))
  assert.strictEqual(X.miniUrl({ data: "AAAA/+==" }), "data:image/jpeg;base64,AAAA/+==")
  assert.strictEqual(X.miniUrl({ data: "not base64!" }), "")
  assert.strictEqual(X.miniUrl(null), "")
})

test("sizes, durations, fitting, auto-download, progress", () => {
  const box2 = {}
  vm.runInNewContext(source + "\nthis.M = { formatSize, formatDuration, fitSize, autoDownload, progress, AUTO_DOWNLOAD_MAX }", box2)
  const X = box2.M
  assert.strictEqual(X.formatSize(512), "512 B")
  assert.strictEqual(X.formatSize(1536), "1.5 KB")
  assert.strictEqual(X.formatSize(5 * 1048576), "5.0 MB")
  assert.strictEqual(X.formatSize(50 * 1048576), "50 MB")
  assert.strictEqual(X.formatSize(-3), "0 B")
  assert.strictEqual(X.formatDuration(7), "0:07")
  assert.strictEqual(X.formatDuration(125), "2:05")
  assert.strictEqual(X.formatDuration(3725), "1:02:05")
  eq(X.fitSize(1280, 720, 360, 360), { width: 360, height: 203 })
  eq(X.fitSize(512, 512, 180, 180), { width: 180, height: 180 })
  eq(X.fitSize(100, 50, 360, 360), { width: 100, height: 50 })
  eq(X.fitSize(0, 0, 360, 360), { width: 360, height: 270 })
  assert.strictEqual(X.autoDownload("sticker", 999999999), true)
  assert.strictEqual(X.autoDownload("photo", X.AUTO_DOWNLOAD_MAX), true)
  assert.strictEqual(X.autoDownload("photo", X.AUTO_DOWNLOAD_MAX + 1), false)
  assert.strictEqual(X.autoDownload("video", 10), false)
  assert.strictEqual(X.autoDownload("file", 10), false)
  assert.strictEqual(X.progress({ size: 200, downloaded: 50 }), 0.25)
  assert.strictEqual(X.progress({ size: 0, downloaded: 50 }), 0)
  assert.strictEqual(X.progress({ size: 10, downloaded: 99 }), 1)
})

for (const f of failures) console.log("FAIL " + f)
console.log(passed + " passed, " + failures.length + " failed")
process.exit(failures.length ? 1 : 0)
