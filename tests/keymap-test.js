#!/usr/bin/env node
// node tests/keymap-test.js — app/Keymap.js: parsing, matching key presses, overrides, clashes.
"use strict"
const fs = require("fs")
const path = require("path")
const vm = require("vm")
const assert = require("assert")

const source = fs.readFileSync(path.join(__dirname, "..", "app", "Keymap.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
const box = {}
vm.runInNewContext(source + "\nthis.K = { SHIFT, CTRL, ALT, META, SECTIONS, ACTIONS, actionById, sectionOf, fromEvent, normalize, defaultsFor, keysFor, matches, matchesInText, matchesText, types, toHyprland, withKeys, conflicts, conflictsFor, label }", box)
const K = box.K
const plain = v => JSON.parse(JSON.stringify(v))
const eq = (a, b, msg) => msg === undefined ? assert.deepStrictEqual(plain(a), plain(b)) : assert.deepStrictEqual(plain(a), plain(b), msg)

let passed = 0
const failures = []
function test(name, fn) {
  try { fn(); passed++ } catch (e) { failures.push(name + "\n    " + e.message) }
}

// Qt key codes
const KEY = { A: 0x41, G: 0x47, J: 0x4a, R: 0x52, ONE: 0x31, SLASH: 0x2f, QUESTION: 0x3f, BRACKET: 0x5b, COMMA: 0x2c,
  ESC: 0x01000000, TAB: 0x01000001, BACKTAB: 0x01000002, RETURN: 0x01000004, ENTER: 0x01000005, DEL: 0x01000007,
  UP: 0x01000013, DOWN: 0x01000015, PGDOWN: 0x01000017, F5: 0x01000034, SHIFTKEY: 0x01000020, CTRLKEY: 0x01000021, SPACE: 0x20 }
const KEYPAD = 0x20000000

test("key presses become sequences", () => {
  assert.strictEqual(K.fromEvent(KEY.R, K.CTRL | K.SHIFT), "Ctrl+Shift+R")
  assert.strictEqual(K.fromEvent(KEY.J, 0), "J")
  assert.strictEqual(K.fromEvent(KEY.G, K.SHIFT), "Shift+G")
  assert.strictEqual(K.fromEvent(KEY.UP, K.ALT), "Alt+Up")
  assert.strictEqual(K.fromEvent(KEY.PGDOWN, K.CTRL), "Ctrl+PgDown")
  assert.strictEqual(K.fromEvent(KEY.ENTER, KEYPAD), "Enter")
  assert.strictEqual(K.fromEvent(KEY.BACKTAB, K.SHIFT), "Shift+Tab")
  assert.strictEqual(K.fromEvent(KEY.QUESTION, K.SHIFT), "?", "shift is part of a punctuation key")
  assert.strictEqual(K.fromEvent(KEY.COMMA, K.CTRL), "Ctrl+,")
  assert.strictEqual(K.fromEvent(KEY.F5, 0), "F5")
  assert.strictEqual(K.fromEvent(KEY.SPACE, 0), "Space")
  assert.strictEqual(K.fromEvent(KEY.SHIFTKEY, K.SHIFT), "", "a lone modifier is no shortcut")
  assert.strictEqual(K.fromEvent(KEY.CTRLKEY, K.CTRL), "")
  assert.strictEqual(K.fromEvent(0x01000300, 0), "", "keys without a name")
})

test("written sequences are normalized", () => {
  assert.strictEqual(K.normalize("ctrl + shift + r"), "Ctrl+Shift+R")
  assert.strictEqual(K.normalize("Shift+Ctrl+r"), "Ctrl+Shift+R")
  assert.strictEqual(K.normalize("Page Down"), "PgDown")
  assert.strictEqual(K.normalize("Escape"), "Esc")
  assert.strictEqual(K.normalize("super+x"), "Meta+X")
  assert.strictEqual(K.normalize("Backtab"), "Shift+Tab")
  assert.strictEqual(K.normalize("Shift+/"), "/")
  assert.strictEqual(K.normalize("Ctrl++"), "Ctrl++")
  assert.strictEqual(K.normalize("f12"), "F12")
  for (const bad of ["", "Ctrl+", "Hyper+X", "Ctrl+Nope", "F99", "x".repeat(50), null, 5, "Ctrl+ab"])
    assert.strictEqual(K.normalize(bad), "", String(bad))
})

test("every default is valid, unique per action and has a section", () => {
  const ids = new Set()
  for (const a of K.ACTIONS) {
    assert.ok(!ids.has(a.id), "duplicate id " + a.id)
    ids.add(a.id)
    assert.ok(K.sectionOf(a.id), "no section for " + a.id)
    assert.strictEqual(K.defaultsFor(a.id).length, a.keys.length, "invalid default in " + a.id)
  }
})

test("the defaults do not clash", () => {
  eq(K.conflicts({}), [])
})

test("matching uses overrides, and an empty list switches an action off", () => {
  const ev = (key, modifiers) => ({ key, modifiers })
  assert.ok(K.matches({}, "window.voice", ev(KEY.R, K.CTRL)))
  assert.ok(!K.matches({}, "window.voice", ev(KEY.R, K.CTRL | K.SHIFT)))
  const mine = K.withKeys({}, "window.voice", ["Ctrl+Alt+V"])
  eq(mine, { "window.voice": ["Ctrl+Alt+V"] })
  assert.ok(!K.matches(mine, "window.voice", ev(KEY.R, K.CTRL)))
  assert.ok(K.matches(mine, "window.voice", ev(0x56, K.CTRL | K.ALT)))
  const off = K.withKeys({}, "list.pin", [])
  eq(K.keysFor(off, "list.pin"), [])
  assert.ok(!K.matches(off, "list.pin", ev(0x50, 0)))
  eq(K.withKeys(mine, "window.voice", ["ctrl+r"]), {}, "back to the default stores nothing")
  assert.ok(!K.matches({}, "no.such", ev(KEY.R, K.CTRL)))
})

test("clashes: same scope, or anything against a window-wide shortcut", () => {
  const sameScope = K.withKeys({}, "list.pin", ["A"])
  eq(K.conflicts(sameScope).map(c => [c.sequence, c.ids.slice().sort()]), [["A", ["list.archive", "list.pin"]]])
  const otherScope = K.withKeys({}, "messages.reply", ["A"])
  eq(K.conflicts(otherScope), [], "the list and the messages never have the keyboard at once")
  const windowWide = K.withKeys({}, "window.stickers", ["J"])
  const found = K.conflictsFor(windowWide, "window.stickers").map(c => c.ids.slice().sort())
  eq(found, [["list.down", "menu.down", "messages.down", "stickers.down", "window.stickers"]])
})

test("in a text field, keys that type are text", () => {
  const ev = (key, modifiers) => ({ key, modifiers })
  assert.ok(K.matches({}, "list.open", ev(0x4c, 0)), "L opens a chat from the list")
  assert.ok(!K.matchesInText({}, "list.open", ev(0x4c, 0)), "but types an l in the search")
  assert.ok(K.matchesInText({}, "list.open", ev(KEY.RETURN, 0)))
  assert.ok(K.matchesInText(K.withKeys({}, "composer.send", ["Ctrl+Return"]), "composer.send", ev(KEY.RETURN, K.CTRL)))
  assert.ok(!K.matchesInText(K.withKeys({}, "composer.send", ["Shift+J"]), "composer.send", ev(KEY.J, K.SHIFT)))
  assert.ok(!K.matchesInText(K.withKeys({}, "composer.send", ["Space"]), "composer.send", ev(KEY.SPACE, 0)))
  assert.ok(K.types("?") && K.types("Shift+G") && K.types("Space") && !K.types("Ctrl+G") && !K.types("Esc"))
  assert.ok(K.matchesText({}, "panel.reply", "r") && !K.matchesText({}, "panel.reply", "x") && !K.matchesText({}, "panel.reply", ""))
})

test("combinations for Hyprland", () => {
  assert.strictEqual(K.toHyprland("Meta+Alt+M"), "SUPER + ALT + M")
  assert.strictEqual(K.toHyprland("Ctrl+Shift+,"), "CTRL + COMMA", "shift is part of a punctuation key")
  assert.strictEqual(K.toHyprland("Ctrl+Shift+PgDown"), "CTRL + SHIFT + PAGE_DOWN")
  assert.strictEqual(K.toHyprland("Alt+F13"), "ALT + F13")
  for (const bad of ["M", "Shift+A", "Meta+F30", "Ctrl++", "nonsense"]) assert.strictEqual(K.toHyprland(bad), "", bad)
})

test("the Menu key and Shift+F10 open menus", () => {
  assert.strictEqual(K.fromEvent(0x01000055, 0), "Menu")
  assert.strictEqual(K.normalize("menu"), "Menu")
  assert.strictEqual(K.fromEvent(0x01000039, K.SHIFT), "Shift+F10")
  assert.ok(K.matches({}, "messages.menu", { key: 0x01000055, modifiers: 0 }))
  assert.ok(K.matches({}, "list.menu", { key: 0x01000039, modifiers: K.SHIFT }))
  assert.strictEqual(K.toHyprland("Ctrl+Menu"), "", "not a key Hyprland binds")
})

test("labels for people", () => {
  assert.strictEqual(K.label("ctrl+up"), "Ctrl + ↑")
  assert.strictEqual(K.label("Return"), "Enter")
  assert.strictEqual(K.label("Ctrl++"), "Ctrl + +")
  assert.strictEqual(K.label("nonsense+q"), "")
})

for (const f of failures) console.log("FAIL " + f)
console.log(passed + " passed, " + failures.length + " failed")
process.exit(failures.length ? 1 : 0)
