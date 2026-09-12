#!/usr/bin/env node
// node tests/model-test.js — app/Model.js without a compositor.
"use strict"
const fs = require("fs")
const path = require("path")
const vm = require("vm")
const assert = require("assert")

const source = fs.readFileSync(path.join(__dirname, "..", "app", "Model.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
const box = {}
vm.runInNewContext(source + "\nthis.M = { CHATS_MAX, MESSAGES_MAX, compareOrder, orderIn, pinnedIn, sortChats, upsertChat, upsertKnown, chatsIn, listTabs, findChat, indexOfChat, filterChats, unreadTotal, mergeMessages, replaceMessage, removeMessages, patchMessage, findMessage, oldestId, lastOwnEditable, incomingIds, contentLabel, previewOf, sameRun, sameDay, listTime, dayLabel, clock, initials, validApiId, validApiHash, cleanPhone, validCode, safeUrl, richText, statusText, withAction, activeActions, actionText, receipt, updatePoll, albumStart, inAlbumAfterFirst, latestKeyboard, MUTE_FOREVER, chatTitle, messageMenu, muteMenu, muteSeconds, chatMenu, albumIds, toggleSelection, selectedIds, selectionText, reactionChosen, riskyFile, saveName, forwardTargets }", box)
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
  assert.strictEqual(X.autoDownload("sticker", 400000), true)
  assert.strictEqual(X.autoDownload("sticker", 999999999), false)
  assert.strictEqual(X.autoDownload("voice", X.AUTO_DOWNLOAD_MAX + 1), false)
  assert.strictEqual(X.autoDownload("photo", X.AUTO_DOWNLOAD_MAX), true)
  assert.strictEqual(X.autoDownload("photo", X.AUTO_DOWNLOAD_MAX + 1), false)
  assert.strictEqual(X.autoDownload("video", 10), false)
  assert.strictEqual(X.autoDownload("file", 10), false)
  assert.strictEqual(X.progress({ size: 200, downloaded: 50 }), 0.25)
  assert.strictEqual(X.progress({ size: 0, downloaded: 50 }), 0)
  assert.strictEqual(X.progress({ size: 10, downloaded: 99 }), 1)
})

test("rich text is escaped, formatted and only links to safe places", () => {
  const wrap = inner => '<span style="white-space: pre-wrap">' + inner + "</span>"
  assert.strictEqual(M.richText('<b>x</b> & "q"', []), wrap("&lt;b&gt;x&lt;/b&gt; &amp; &quot;q&quot;"))
  assert.strictEqual(M.richText("hello world", [{ type: "bold", offset: 0, length: 5 }]), wrap("<b>hello</b> world"))
  assert.strictEqual(M.richText("abcdefgh", [{ type: "bold", offset: 0, length: 5 }, { type: "italic", offset: 3, length: 5 }]),
                     wrap("<b>abc</b><i><b>de</b></i><i>fgh</i>"))
  assert.ok(!M.richText("click", [{ type: "textUrl", offset: 0, length: 5, url: "javascript:alert(1)" }]).includes("<a"))
  assert.ok(!M.richText("click", [{ type: "textUrl", offset: 0, length: 5, url: 'https://x.org/"onmouseover="x' }]).includes("<a"))
  assert.ok(M.richText("see example.com/a", [{ type: "url", offset: 4, length: 13 }]).includes('<a href="https://example.com/a">example.com/a</a>'))
  assert.ok(M.richText("hi @durov", [{ type: "mention", offset: 3, length: 6 }]).includes('href="omagram:mention:durov"'))
  assert.ok(M.richText("hi Ann", [{ type: "mentionName", offset: 3, length: 3, userId: 42 }]).includes('href="omagram:user:42"'))
  assert.ok(M.richText("#news", [{ type: "hashtag", offset: 0, length: 5 }]).includes('href="omagram:search:%23news"'))
  const hidden = M.richText("secret word", [{ type: "spoiler", offset: 0, length: 6 }], false)
  assert.ok(!hidden.includes("secret") && hidden.includes('href="omagram:spoiler"'))
  assert.ok(M.richText("secret word", [{ type: "spoiler", offset: 0, length: 6 }], true).includes("secret"))
  assert.strictEqual(M.richText("short", [{ type: "bold", offset: 3, length: 50 }, { type: "bold", offset: -1, length: 2 }, "junk"]), wrap("short"))
  assert.ok(M.richText("👋 hi", [{ type: "bold", offset: 3, length: 2 }]).includes("<b>hi</b>"), "offsets are UTF-16, like JavaScript strings")
  assert.strictEqual(M.safeUrl("ftp://x.org"), "")
  assert.strictEqual(M.safeUrl("mailto:a@b.c"), "mailto:a@b.c")
})

test("status, typing and read ticks in words", () => {
  const now = Date.UTC(2026, 8, 12, 15, 0, 0)
  assert.strictEqual(M.statusText({ state: "online" }, now), "online")
  assert.strictEqual(M.statusText({ state: "offline", wasOnline: now / 1000 - 30 }, now), "last seen just now")
  assert.strictEqual(M.statusText({ state: "offline", wasOnline: now / 1000 - 5 * 60 }, now), "last seen 5 minutes ago")
  assert.strictEqual(M.statusText({ state: "recently" }, now), "last seen recently")
  assert.strictEqual(M.statusText(null, now), "")
  let actions = M.withAction({}, { chatId: 42, senderId: 7, senderName: "Ann", action: "typing" }, now)
  actions = M.withAction(actions, { chatId: 42, senderId: 8, senderName: "Bob", action: "typing" }, now)
  assert.strictEqual(M.actionText(M.activeActions(actions, 42, now + 1000), false), "Ann and Bob are typing…")
  assert.strictEqual(M.actionText(M.activeActions(actions, 42, now + 1000), true), "typing…")
  actions = M.withAction(actions, { chatId: 42, senderId: 8, action: "cancel" }, now)
  assert.strictEqual(M.actionText(M.activeActions(actions, 42, now + 1000), false), "Ann is typing…")
  assert.strictEqual(M.actionText(M.activeActions(actions, 42, now + 60000), false), "", "actions expire")
  assert.strictEqual(M.receipt(msg(5, { outgoing: true }), { lastReadOutbox: 5 }), "read")
  assert.strictEqual(M.receipt(msg(6, { outgoing: true }), { lastReadOutbox: 5 }), "sent")
  assert.strictEqual(M.receipt(msg(6, { outgoing: true, sending: "pending" }), {}), "sending")
  assert.strictEqual(M.receipt(msg(6), { lastReadOutbox: 9 }), "")
})

test("polls update in place and albums group", () => {
  const withPoll = msg(3, { content: { kind: "poll", text: "Q", poll: { id: "77", question: "Q", options: [] } } })
  const list = [msg(1), withPoll]
  const updated = M.updatePoll(list, { id: "77", question: "Q2", options: [{ index: 0 }] })
  assert.notStrictEqual(updated, list)
  assert.strictEqual(updated[1].content.poll.question, "Q2")
  assert.strictEqual(M.updatePoll(list, { id: "other" }), list, "unchanged lists stay the same object")
  const album = [msg(1), msg(2, { albumId: "9" }), msg(3, { albumId: "9" }), msg(4, { albumId: "8" })]
  eq(M.albumStart(album, 1).map(m => m.id), [2, 3])
  eq(M.albumStart(album, 2), [])
  assert.ok(M.inAlbumAfterFirst(album, 2) && !M.inAlbumAfterFirst(album, 1) && !M.inAlbumAfterFirst(album, 3))
  eq(M.albumStart(album, 3).map(m => m.id), [4])
})

test("the bot keyboard in effect is set or removed by the newest message that says", () => {
  const keyboard = { type: "keyboard", rows: [[{ text: "Start", kind: "text" }]], oneTime: true }
  eq(M.latestKeyboard([msg(1, { markup: keyboard }), msg(2)]), { messageId: 1, rows: [[{ text: "Start", kind: "text" }]], oneTime: true, placeholder: "" })
  assert.strictEqual(M.latestKeyboard([msg(1, { markup: keyboard }), msg(2, { markup: { type: "remove" } })]), null)
  assert.strictEqual(M.latestKeyboard([msg(1, { markup: { type: "inline", rows: [] } })]), null)
  assert.strictEqual(M.latestKeyboard(null), null)
})

test("a message's menu offers only what Telegram allows", () => {
  const text = msg(5, { content: { kind: "text", text: "hi" } })
  eq(M.messageMenu(text, null).map(i => i.id), ["reply", "copy", "select"], "before Telegram has answered")
  const all = { canReply: true, canSave: true, canGetLink: true, canEdit: true, canForward: true, canPin: true,
                canDeleteForAll: true, canDeleteForMe: true }
  eq(M.messageMenu(text, all).map(i => i.id), ["reply", "copy", "link", "edit", "forward", "pin", "select", "deleteAll", "deleteMe"])
  eq(M.messageMenu(Object.assign({}, text, { pinned: true }), { canPin: true }).map(i => i.id), ["copy", "unpin", "select"])
  const photo = msg(6, { content: { kind: "photo", text: "", media: { file: { id: 3 } } } })
  eq(M.messageMenu(photo, { canReply: true, canSave: true }).map(i => i.id), ["reply", "select", "open", "save"])
  eq(M.messageMenu(photo, { canReply: true, canSave: false }).map(i => i.id), ["reply", "select"], "protected content stays in Telegram")
  assert.strictEqual(M.messageMenu(photo, { canEdit: true }).find(i => i.id === "edit").label, "Edit caption")
  assert.ok(M.messageMenu(msg(7, { content: { kind: "poll", text: "Q", poll: { voted: true, closed: false, quiz: false } } }), null)
    .some(i => i.id === "retract"))
  assert.ok(!M.messageMenu(msg(8, { content: { kind: "poll", text: "Q", poll: { voted: true, quiz: true } } }), null)
    .some(i => i.id === "retract"), "a quiz answer is final")
  eq(M.messageMenu(text, all).filter(i => i.danger).map(i => i.id), ["deleteAll", "deleteMe"])
  eq(M.messageMenu(null, all), [])
})

test("mute and chat menus", () => {
  eq(M.muteMenu({ muted: true }).map(i => i.id), ["unmute"])
  eq(M.muteMenu({ muted: false }).map(i => M.muteSeconds(i.id)), [3600, 28800, 172800, M.MUTE_FOREVER])
  assert.strictEqual(M.muteSeconds("unmute"), 0)
  for (const bad of ["mute:", "mute:-5", "mute:0", "mute:9999999999", "junk", null]) assert.strictEqual(M.muteSeconds(bad), -1, String(bad))
  const c = { id: 1, unread: 2, mentions: 0, muted: false, archived: false, positions: { main: { order: "5", pinned: true } } }
  eq(M.chatMenu(c, "main", false).map(i => i.id), ["open", "read", "unpin", "mute", "archive"])
  eq(M.chatMenu(Object.assign({}, c, { unread: 0, muted: true, archived: true }), "main", true).map(i => i.id), ["open", "unmute", "unarchive"])
})

test("albums act as one, selections toggle and copy like Telegram", () => {
  const list = [msg(1), msg(2, { albumId: "9", outgoing: true, content: { kind: "photo", text: "cap" } }),
                msg(3, { albumId: "9", content: { kind: "photo", text: "" } }), msg(4, { senderName: "Ann" })]
  eq(M.albumIds(list, list[1]), [2, 3])
  eq(M.albumIds(list, list[0]), [1])
  let selection = M.toggleSelection({}, [2, 3])
  eq(M.selectedIds(list, selection), [2, 3])
  selection = M.toggleSelection(selection, [4])
  eq(M.selectedIds(list, selection), [2, 3, 4])
  eq(M.selectedIds(list, M.toggleSelection(selection, [2, 3])), [4])
  eq(M.selectedIds(list, M.toggleSelection({ 3: true }, [2, 3])), [2, 3], "a partly selected album becomes selected")
  eq(M.selectedIds(list, { 99: true }), [], "only loaded messages")
  const copied = M.selectionText(list, M.toggleSelection({}, [2, 4]))
  assert.ok(/^You, \[\d\d:\d\d\]\ncap\n\nAnn, \[\d\d:\d\d\]\nm4$/.test(copied), copied)
  assert.ok(M.reactionChosen(msg(1, { reactions: [{ emoji: "👍", chosen: true }] }), "👍"))
  assert.ok(!M.reactionChosen(msg(1, { reactions: [{ emoji: "👍", chosen: false }] }), "👍"))
})

test("files that could run code ask first, and saved files get sensible names", () => {
  for (const name of ["run.sh", "x.DESKTOP", "setup.exe", "noextension", "", "page.html", "tool.AppImage"]) assert.ok(M.riskyFile(name), name)
  for (const name of ["report.pdf", "photo.JPG", "song.mp3", "archive.tar.gz", "voice.oga"]) assert.ok(!M.riskyFile(name), name)
  assert.strictEqual(M.saveName(msg(1, { content: { kind: "file", fileName: "a.pdf", media: { fileName: "a.pdf" } } })), "a.pdf")
  const at = new Date(2026, 8, 12, 9, 5, 7).getTime() / 1000
  assert.strictEqual(M.saveName(msg(1, { date: at, content: { kind: "photo", media: {} } })), "photo_2026-09-12_09-05-07.jpg")
  assert.strictEqual(M.saveName(msg(1, { date: at, content: { kind: "voice", media: {} } })), "voice_2026-09-12_09-05-07.ogg")
})

test("Saved Messages is called that, comes first when forwarding, and is found by name", () => {
  const me = { id: 10, kind: "private", userId: 77, title: "Me Myself", positions: { main: { order: "1" } } }
  const club = { id: 11, kind: "group", title: "Club", positions: { main: { order: "9" } } }
  const news = { id: 12, kind: "channel", title: "News", positions: { archive: { order: "3" } } }
  assert.strictEqual(M.chatTitle(me, 77), "Saved Messages")
  assert.strictEqual(M.chatTitle(me, 0), "Me Myself")
  assert.strictEqual(M.chatTitle({ id: 1, title: "" }, 77), "Deleted account")
  eq(M.forwardTargets([club, news, me], "", 77).map(c => c.id), [10, 11, 12])
  eq(M.forwardTargets([club, news, me], "saved", 77).map(c => c.id), [10])
  eq(M.filterChats([club, me], "club", 77).map(c => c.id), [11])
})

for (const f of failures) console.log("FAIL " + f)
console.log(passed + " passed, " + failures.length + " failed")
process.exit(failures.length ? 1 : 0)
