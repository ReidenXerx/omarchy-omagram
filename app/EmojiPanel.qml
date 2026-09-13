import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import "Keymap.js" as Keymap
import "emoji/EmojiModel.js" as Emoji

// Emoji, symbols and kaomoji for the message box, with the data and search of the emoji picker plugin: type to
// search their English, Ukrainian and Russian names, arrows move, Enter puts one in at the cursor (the panel
// stays open for more), Tab goes between emoji, symbols and kaomoji, Alt+0 to Alt+5 set the skin tone, Esc
// closes. Opened from a message's menu it offers only the reactions that message may get, and Enter reacts.
FocusScope {
  id: panel

  property var app
  property int tab: 0                      // 0 emoji, 1 symbols, 2 kaomoji
  property string query: ""
  property int cursor: 0
  property var sets: ({})                  // kind -> the searchable items of that kind
  property var byKey: ({})
  property var results: []
  property var allowed: null               // the reactions a message may get, as Telegram writes them; null otherwise
  property bool wanted: false              // the data loads the first time emoji are asked for

  readonly property bool ready: !!panel.sets.emoji
  readonly property bool reacting: panel.allowed !== null
  readonly property var kinds: ["emoji", "symbols", "kaomoji"]
  readonly property var kindNames: ["Emoji", "Symbols", "Kaomoji"]
  readonly property string kind: panel.reacting ? "emoji" : panel.kinds[panel.tab]
  readonly property int tone: panel.app && panel.app.emojiState ? (panel.app.emojiState.tone || 0) : 0
  readonly property var tones: ["✋", "✋🏻", "✋🏼", "✋🏽", "✋🏾", "✋🏿"]
  readonly property var current: panel.results[panel.cursor] || null
  readonly property int cellWidth: Style.space(panel.kind === "kaomoji" ? 136 : 46)
  readonly property int columns: Math.max(1, Math.floor(grid.width / panel.cellWidth))

  signal inserted(string text)
  signal reacted(string emoji)
  signal closed()

  function open() {
    panel.allowed = null
    panel.begin()
  }

  // Only the reactions Telegram allows on the message, found by name like any emoji.
  function openReactions(emoji) {
    panel.allowed = emoji || []
    panel.begin()
  }

  function begin() {
    panel.wanted = true
    search.text = ""
    panel.query = ""
    panel.cursor = 0
    panel.rebuild()
    search.forceActiveFocus()
  }

  function showTab(index) {
    if (panel.reacting) return
    panel.tab = (index + panel.kinds.length) % panel.kinds.length
    panel.cursor = 0
    panel.rebuild()
  }

  function move(delta) {
    if (!panel.results.length) return
    panel.cursor = Math.max(0, Math.min(panel.results.length - 1, panel.cursor + delta))
  }

  // ---------------------------------------------------------------- data

  function localPath(name) {
    return decodeURIComponent(String(Qt.resolvedUrl(name)).replace("file://", ""))
  }

  function load(kind, raw) {
    var data = null
    try { data = JSON.parse(raw) } catch (e) { data = null }
    var sets = Object.assign({}, panel.sets)
    sets[kind] = Emoji.prepare(data, kind)
    var map = {}
    for (var k in sets) for (var i = 0; i < sets[k].length; i++) map[sets[k][i].key] = sets[k][i]
    panel.byKey = map
    panel.sets = sets
    if (panel.visible) panel.rebuild()
  }

  FileView { path: panel.wanted ? panel.localPath("emoji/emoji.json") : ""; onLoaded: panel.load("emoji", text()) }
  FileView { path: panel.wanted ? panel.localPath("emoji/symbols.json") : ""; onLoaded: panel.load("symbols", text()) }
  FileView { path: panel.wanted ? panel.localPath("emoji/kaomoji.json") : ""; onLoaded: panel.load("kaomoji", text()) }

  // Telegram writes some reactions without the variation selector the emoji data has (❤ against ❤️).
  function bare(text) {
    return String(text || "").split(String.fromCharCode(0xFE0F)).join("")
  }

  function recents() {
    return panel.app && panel.app.emojiState && panel.app.emojiState.recents ? panel.app.emojiState.recents : ({})
  }

  function rebuild() {
    var now = Date.now()
    var items = panel.sets[panel.kind] || []
    if (panel.reacting) {
      var allowed = {}
      for (var a = 0; a < panel.allowed.length; a++) allowed[panel.bare(panel.allowed[a])] = panel.allowed[a]
      var named = {}
      items = items.filter(function (item) {
        var fits = allowed[panel.bare(item.e)] !== undefined
        if (fits) named[panel.bare(item.e)] = true
        return fits
      })
      // A reaction the data has no name for still shows, at the end.
      for (var b in allowed)
        if (!named[b]) items.push({ kind: "emoji", key: "emoji:" + allowed[b], e: allowed[b], g: 0, t: null, x: false, names: [], folded: [], hay: "", order: 100000 })
    }
    var out
    if (panel.query === "") {
      var seen = {}
      var recent = Emoji.recentItems(panel.recents(), panel.byKey, now, 30).filter(function (item) {
        var fits = item.kind === panel.kind && (!panel.reacting || items.indexOf(item) >= 0)
        if (fits) seen[item.key] = true
        return fits
      })
      out = recent.concat(items.filter(function (item) { return !seen[item.key] }))
    } else {
      out = Emoji.search(items, panel.query, 400, panel.recents(), now)
    }
    panel.results = out
    panel.cursor = Math.max(0, Math.min(panel.cursor, out.length - 1))
  }

  // ---------------------------------------------------------------- choosing

  // The reaction as Telegram writes it, for an item of the data.
  function reactionOf(item) {
    for (var i = 0; i < panel.allowed.length; i++) if (panel.bare(panel.allowed[i]) === panel.bare(item.e)) return panel.allowed[i]
    return item.e
  }

  function record(key) {
    if (!panel.app || !panel.app.saveEmojiState) return
    var state = panel.app.emojiState || {}
    panel.app.saveEmojiState({ tone: state.tone || 0, recents: Emoji.recordUse(state.recents || {}, key, Date.now()) })
  }

  function choose(index) {
    var item = panel.results[index]
    if (!item) return
    panel.record(item.key)
    if (panel.reacting) panel.reacted(panel.reactionOf(item))
    else panel.inserted(Emoji.textFor(item, panel.tone))
  }

  function setTone(tone) {
    if (!panel.app || !panel.app.saveEmojiState || !(tone >= 0 && tone <= 5)) return
    var state = panel.app.emojiState || {}
    panel.app.saveEmojiState({ tone: tone, recents: state.recents || {} })
  }

  // Out of the recent ones: only while they show, with nothing typed.
  function forget(index) {
    var item = panel.results[index]
    var state = panel.app && panel.app.emojiState ? panel.app.emojiState : {}
    if (!item || panel.query !== "" || !panel.app.saveEmojiState || !(state.recents || {})[item.key]) return
    panel.app.saveEmojiState({ tone: state.tone || 0, recents: Emoji.forget(state.recents, item.key) })
    panel.rebuild()
  }

  // Emoji for ":name" while typing, best first, with their names in the other languages beside them.
  function suggest(query, limit) {
    panel.wanted = true
    if (!panel.ready) return []
    return Emoji.search(panel.sets.emoji, query, limit, panel.recents(), Date.now()).map(function (item) {
      var text = Emoji.textFor(item, panel.tone)
      return { label: text + "   " + (item.names[0] || ""), detail: item.names.slice(1).filter(function (n) { return !!n }).join("  ·  "),
               insert: text, command: false, emojiKey: item.key }
    })
  }

  // ---------------------------------------------------------------- the panel

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(panel.app.foreground.r, panel.app.foreground.g, panel.app.foreground.b, 0.03)

    Rectangle { width: parent.width; height: 1; color: panel.app.border; opacity: 0.35 }
  }

  ColumnLayout {
    anchors.fill: parent
    anchors.margins: Style.space(10)
    spacing: Style.space(6)

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(6)

      Repeater {
        model: panel.reacting ? ["Reactions"] : panel.kindNames

        delegate: Rectangle {
          id: tabChip
          required property var modelData
          required property int index
          readonly property bool current: panel.reacting || tabChip.index === panel.tab
          Layout.preferredHeight: Style.space(30)
          Layout.preferredWidth: tabLabel.implicitWidth + Style.space(22)
          radius: Style.cornerRadius
          color: tabChip.current ? panel.app.selected
               : (tabArea.containsMouse ? Qt.rgba(panel.app.foreground.r, panel.app.foreground.g, panel.app.foreground.b, 0.05) : "transparent")

          Text {
            id: tabLabel
            anchors.centerIn: parent
            text: tabChip.modelData
            textFormat: Text.PlainText
            color: tabChip.current ? panel.app.foreground : panel.app.muted
            font.family: panel.app.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: tabChip.current
          }
          MouseArea {
            id: tabArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              panel.showTab(tabChip.index)
              search.forceActiveFocus()
            }
          }
        }
      }

      Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: Style.space(30)
        radius: Style.cornerRadius
        color: Qt.rgba(panel.app.foreground.r, panel.app.foreground.g, panel.app.foreground.b, 0.05)
        border.width: Math.max(1, Style.space(1.5))
        border.color: search.activeFocus ? panel.app.accent : "transparent"

        TextInput {
          id: search
          anchors.fill: parent
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          verticalAlignment: TextInput.AlignVCenter
          clip: true
          maximumLength: 64
          color: panel.app.foreground
          selectionColor: panel.app.accent
          font.family: panel.app.fontFamily
          font.pixelSize: Style.font.body
          onTextChanged: {
            panel.query = text.trim()
            panel.cursor = 0
            panel.rebuild()
          }

          Keys.onPressed: function (event) {
            var keys = panel.app.shortcuts
            function is(id) { return Keymap.matchesInText(keys, id, event) }
            if (is("emoji.left")) panel.move(-1)
            else if (is("emoji.right")) panel.move(1)
            else if (is("emoji.up")) panel.move(-panel.columns)
            else if (is("emoji.down")) panel.move(panel.columns)
            else if (is("emoji.nextKind")) panel.showTab(panel.tab + 1)
            else if (is("emoji.previousKind")) panel.showTab(panel.tab - 1)
            else if (is("emoji.insert")) panel.choose(panel.cursor)
            else if (is("emoji.tone")) panel.setTone(event.key - Qt.Key_0)
            else if (is("emoji.forget")) panel.forget(panel.cursor)
            else if (is("emoji.close")) panel.closed()
            else return
            event.accepted = true
          }

          Text {
            anchors.fill: parent
            verticalAlignment: Text.AlignVCenter
            visible: search.text === ""
            text: panel.reacting ? "Find a reaction by name" : "Search in English, Ukrainian or Russian"
            textFormat: Text.PlainText
            color: panel.app.muted
            font: search.font
          }
        }
      }

      Row {
        visible: panel.kind === "emoji"
        spacing: Style.space(2)

        Repeater {
          model: panel.tones

          delegate: Rectangle {
            id: toneChip
            required property var modelData
            required property int index
            width: Style.space(28)
            height: Style.space(28)
            radius: Style.cornerRadius
            color: toneChip.index === panel.tone ? panel.app.selected : "transparent"

            Text {
              anchors.centerIn: parent
              text: toneChip.modelData
              textFormat: Text.PlainText
              font.pixelSize: Style.font.body
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                panel.setTone(toneChip.index)
                search.forceActiveFocus()
              }
            }
          }
        }
      }
    }

    GridView {
      id: grid
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      cellWidth: Math.floor(grid.width / panel.columns)
      cellHeight: Style.space(panel.kind === "kaomoji" ? 38 : 44)
      model: panel.results
      currentIndex: panel.cursor
      boundsBehavior: Flickable.StopAtBounds
      onCurrentIndexChanged: grid.positionViewAtIndex(grid.currentIndex, GridView.Contain)

      WheelScroll { view: grid }

      delegate: Rectangle {
        id: glyphCell
        required property var modelData
        required property int index
        width: grid.cellWidth - Style.space(4)
        height: grid.cellHeight - Style.space(4)
        radius: Style.cornerRadius
        color: glyphCell.index === panel.cursor ? panel.app.selected
             : (cellArea.containsMouse ? Qt.rgba(panel.app.foreground.r, panel.app.foreground.g, panel.app.foreground.b, 0.06) : "transparent")

        Text {
          anchors.centerIn: parent
          width: parent.width - Style.space(6)
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
          text: Emoji.textFor(glyphCell.modelData, panel.tone)
          textFormat: Text.PlainText
          color: panel.app.foreground
          font.family: panel.app.fontFamily
          font.pixelSize: panel.kind === "kaomoji" ? Style.font.bodySmall : Style.font.title
        }
        MouseArea {
          id: cellArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            panel.cursor = glyphCell.index
            panel.choose(glyphCell.index)
            search.forceActiveFocus()
          }
        }
      }

      Text {
        anchors.centerIn: parent
        visible: grid.count === 0
        text: !panel.ready ? "Loading…" : (panel.query ? "Nothing by that name" : "Nothing here")
        textFormat: Text.PlainText
        color: panel.app.muted
        font.family: panel.app.fontFamily
        font.pixelSize: Style.font.body
      }
    }

    // What the cursor is on, by its names; and the keys.
    Text {
      Layout.fillWidth: true
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: (panel.current && panel.current.names.length
             ? panel.current.names.filter(function (n) { return !!n }).join("  ·  ") + "     " : "")
            + (panel.reacting ? "Enter reacts" : "Enter puts it in · Tab emoji, symbols, kaomoji · Alt+0–5 skin tone") + " · Esc closes"
      color: panel.app.muted
      font.family: panel.app.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
