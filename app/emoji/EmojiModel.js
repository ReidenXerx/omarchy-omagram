.pragma library

// Search, ranking and recents for the picker. Pure functions with no QML in them,
// so tests/model-test.js runs them under node.

var HALF_LIFE_MS = 7 * 24 * 3600 * 1000
var MAX_RECENTS = 80

// Lowercase, and fold what people type interchangeably: ё/е, and the apostrophes
// Ukrainian words use (м'ята, мʼята, м’ята).
function fold(s) {
  return String(s || "").toLowerCase().replace(/ё/g, "е").replace(/[ʼ’`]/g, "'")
}

// Turn one data file ({groups, items}) into searchable items of one kind.
function prepare(data, kind) {
  var src = (data && Array.isArray(data.items)) ? data.items : []
  var out = []
  for (var i = 0; i < src.length; i++) {
    var it = src[i]
    if (!it || !it.e) continue
    var names = Array.isArray(it.n) ? it.n.filter(function(n) { return !!n }) : []
    out.push({
      kind: kind,
      key: kind + ":" + it.e,
      e: it.e,
      g: it.g || 0,
      t: Array.isArray(it.t) ? it.t : null,
      x: it.x === 1,
      names: names,
      folded: names.map(fold),
      hay: fold((it.k || "") + " " + names.join(" ")),
      order: i
    })
  }
  return out
}

function groups(data) {
  return (data && Array.isArray(data.groups)) ? data.groups : []
}

function tokens(query) {
  return fold(query).split(/\s+/).filter(function(t) { return t.length > 0 })
}

function startsWord(text, token) {
  var at = text.indexOf(token)
  while (at !== -1) {
    if (at === 0 || /[\s,:;|(«"'\-]/.test(text.charAt(at - 1))) return true
    at = text.indexOf(token, at + 1)
  }
  return false
}

// 0 means no match. Every token has to match somewhere; how well decides the rank.
function score(item, toks, whole) {
  if (toks.length === 0) return 1
  var total = 0
  for (var i = 0; i < toks.length; i++) {
    var t = toks[i]
    var s = 0
    for (var n = 0; n < item.folded.length && s < 100; n++) {
      if (item.folded[n].indexOf(t) === 0) s = 100
      else if (s < 70 && startsWord(item.folded[n], t)) s = 70
    }
    if (s === 0) {
      if (startsWord(item.hay, t)) s = 45
      else if (t.length >= 2 && item.hay.indexOf(t) !== -1) s = 15
      else if (item.e === t) s = 100
      else return 0
    }
    total += s
  }
  for (var m = 0; m < item.folded.length; m++)
    if (item.folded[m] === whole) { total += 200; break }
  return total
}

function frecency(entry, now) {
  if (!entry) return 0
  var age = Math.max(0, now - (Number(entry.t) || 0))
  return (Number(entry.c) || 0) * Math.pow(0.5, age / HALF_LIFE_MS)
}

// Items matching the query, best first. Things you use often float up a little, but
// never above a clearly better match.
function search(items, query, limit, recents, now) {
  var toks = tokens(query)
  var whole = fold(query).trim()
  var scored = []
  for (var i = 0; i < items.length; i++) {
    var s = score(items[i], toks, whole)
    if (s <= 0) continue
    var boost = recents ? Math.min(30, frecency(recents[items[i].key], now) * 10) : 0
    scored.push({ item: items[i], s: s + boost })
  }
  scored.sort(function(a, b) { return (b.s - a.s) || (a.item.order - b.item.order) })
  var out = []
  for (var j = 0; j < scored.length && j < limit; j++) out.push(scored[j].item)
  return out
}

function inGroup(items, group) {
  return items.filter(function(it) { return it.g === group })
}

// Index of the first item of each group, for jumping with the group chips.
function groupStarts(items) {
  var starts = {}
  for (var i = 0; i < items.length; i++)
    if (starts[items[i].g] === undefined) starts[items[i].g] = i
  return starts
}

// ------------------------------------------------------------------ what to type

// The emoji in the chosen tone (1-5), falling back to the default one.
function withTone(item, tone) {
  if (item && item.t && tone >= 1 && tone <= 5 && item.t[tone - 1]) return item.t[tone - 1]
  return item ? item.e : ""
}

function textFor(item, tone) {
  if (!item) return ""
  if (item.kind === "emoji") return withTone(item, tone)
  // Symbols that are also emoji (e.g. ☺, ✈) get VS15, so they arrive as text rather
  // than turning into a colour emoji in the app they are typed into.
  if (item.kind === "symbols" && item.x) return item.e + "︎"
  return item.e
}

// ------------------------------------------------------------------ state

var TAB_IDS = ["emoji", "symbols", "kaomoji", "gif"]

function normalizeState(parsed) {
  var state = { tone: 0, tab: "emoji", recents: {} }
  if (!parsed || typeof parsed !== "object") return state
  var tone = Number(parsed.tone)
  if (tone >= 0 && tone <= 5 && Math.floor(tone) === tone) state.tone = tone
  if (TAB_IDS.indexOf(parsed.tab) !== -1) state.tab = parsed.tab
  var r = parsed.recents
  if (r && typeof r === "object") {
    for (var key in r) {
      var e = r[key]
      if (!e || typeof e !== "object" || !(Number(e.c) > 0) || !(Number(e.t) > 0)) continue
      var entry = { c: Number(e.c), t: Number(e.t) }
      if (e.gif && typeof e.gif === "object" && e.gif.id) entry.gif = e.gif
      state.recents[key] = entry
    }
  }
  return state
}

// A new recents map with `key` used once more at `now`. The stored count is decayed up
// to now before adding, so one old burst of use fades instead of pinning an item.
function recordUse(recents, key, now, extra) {
  var next = {}
  for (var k in recents) next[k] = recents[k]
  var prev = next[key]
  var entry = { c: frecency(prev, now) + 1, t: now }
  if (extra && extra.gif) entry.gif = extra.gif
  next[key] = entry
  var keys = Object.keys(next)
  if (keys.length > MAX_RECENTS) {
    keys.sort(function(a, b) { return frecency(next[b], now) - frecency(next[a], now) })
    for (var i = MAX_RECENTS; i < keys.length; i++) delete next[keys[i]]
  }
  return next
}

// Recent items, most-used first. Local items resolve through byKey; GIFs carry their
// own card in the entry, since there is no local data to look them up in.
function recentItems(recents, byKey, now, limit) {
  var keys = Object.keys(recents || {})
  keys.sort(function(a, b) { return frecency(recents[b], now) - frecency(recents[a], now) })
  var out = []
  for (var i = 0; i < keys.length && out.length < limit; i++) {
    var key = keys[i]
    if (byKey[key]) out.push(byKey[key])
    else if (key.indexOf("gif:") === 0 && recents[key].gif) out.push(gifItem(recents[key].gif))
  }
  return out
}

function forget(recents, key) {
  var next = {}
  for (var k in recents) if (k !== key) next[k] = recents[k]
  return next
}

// ------------------------------------------------------------------ GIFs

function gifItem(g) {
  return {
    kind: "gif",
    key: "gif:" + g.id,
    e: "",
    id: String(g.id),
    title: String(g.title || ""),
    preview: String(g.preview || ""),
    url: String(g.url || ""),
    w: Number(g.w) || 1,
    h: Number(g.h) || 1,
    names: g.title ? [String(g.title)] : [],
    order: 0
  }
}

// What the picker remembers about a GIF: ids and links only. KLIPY's terms allow
// keeping search-result thumbnails and nothing else, so no file is ever stored.
function gifCard(item) {
  return { id: item.id, title: item.title, preview: item.preview, url: item.url, w: item.w, h: item.h }
}

// Parse what `emoji-picker gif search|trending` printed. `q` and `page` echo the request
// (q is null when the reply was unreadable, so it cannot be matched to one).
function parseGifReply(raw) {
  var parsed = null
  try { parsed = JSON.parse(String(raw || "")) } catch (e) { parsed = null }
  if (!parsed || typeof parsed !== "object")
    return { error: "bad-reply", items: [], hasNext: false, q: null, page: 1 }
  var q = typeof parsed.q === "string" ? parsed.q : null
  var page = Number(parsed.page) >= 1 ? Math.floor(Number(parsed.page)) : 1
  if (parsed.error) return { error: String(parsed.error), items: [], hasNext: false, q: q, page: page }
  var list = Array.isArray(parsed.items) ? parsed.items : []
  var items = []
  for (var i = 0; i < list.length; i++)
    if (list[i] && list[i].id && list[i].preview && list[i].url) items.push(gifItem(list[i]))
  return { error: "", items: items, hasNext: parsed.hasNext === true, q: q, page: page }
}

// Append a page of GIFs, skipping any the earlier pages already had.
function appendGifs(existing, more) {
  var seen = {}
  for (var i = 0; i < existing.length; i++) seen[existing[i].id] = true
  return existing.concat(more.filter(function(g) { return !seen[g.id] }))
}

var GIF_ERRORS = {
  "no-key": "GIF search needs a free KLIPY API key.",
  "bad-key": "KLIPY did not accept the API key.",
  "rate-limited": "KLIPY's hourly limit is used up. Try again later.",
  "offline": "Could not reach KLIPY.",
  "bad-reply": "KLIPY sent something unexpected."
}

function gifErrorText(code) {
  return GIF_ERRORS[code] || ("GIF search failed (" + code + ").")
}

// ------------------------------------------------------------------ grid movement

function clamp(index, count) {
  if (count <= 0) return 0
  return Math.max(0, Math.min(count - 1, index))
}

function move(index, delta, count) {
  return clamp(index + delta, count)
}

function moveRow(index, rows, columns, count) {
  return clamp(index + rows * Math.max(1, columns), count)
}
