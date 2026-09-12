import QtQuick
import QtQuick.Layouts
import qs.Commons
import "Model.js" as Model
import "Keymap.js" as Keymap

// The sticker and GIF picker: recent stickers first, then GIFs (yours, or found by typing), then
// each installed sticker set.
// Keyboard: arrows or h/j/k/l move, Tab and Shift+Tab switch tabs, Enter sends, Esc closes. On the
// GIF tab typing searches, ↓ goes from the search to the GIFs and ↑ from the top row back.
// Stickers and GIFs show small and still, so a grid of dozens does not run dozens of animations.
FocusScope {
  id: picker

  property var app
  property real chatId: 0             // GIF search runs in the chat it is for, as Telegram asks
  property var sets: []
  property var items: []              // stickers, or GIFs as { gif, queryId, resultId }
  property int tab: 0
  property int cursor: 0
  property bool loading: false
  property string query: ""
  property string nextOffset: ""
  property int serial: 0
  readonly property bool gifs: picker.tab === 1
  readonly property int cell: Style.space(picker.gifs ? 112 : 84)
  readonly property int columns: Math.max(1, Math.floor(grid.width / cell))

  signal picked(var sticker)
  signal gifPicked(var item)
  signal closed()

  function open() {
    if (picker.gifs) gifSearch.forceActiveFocus()
    else grid.forceActiveFocus()
    if (!picker.sets.length)
      app.request("stickers.sets", {}, function (answer) { if (answer.ok) picker.sets = answer.result.sets || [] })
    show(picker.tab)
  }

  function show(index) {
    var count = picker.sets.length + 2
    picker.tab = ((index % count) + count) % count
    picker.cursor = 0
    picker.items = []
    picker.nextOffset = ""
    picker.serial++
    tabs.positionViewAtIndex(picker.tab, ListView.Contain)
    if (picker.gifs) {
      picker.loadGifs(false)
      return
    }
    var serial = picker.serial
    var done = function (answer) {
      if (serial !== picker.serial) return   // an answer for a tab that was already left
      picker.loading = false
      picker.items = answer.ok ? (answer.result.stickers || []) : []
    }
    picker.loading = true
    if (picker.tab === 0) app.request("stickers.recent", {}, done)
    else app.request("stickers.set", { setId: picker.sets[picker.tab - 2].id }, done)
  }

  // Your saved GIFs while nothing is typed; otherwise what the @gif bot finds, a page at a time.
  function loadGifs(more) {
    if (more && (!picker.query || !picker.nextOffset || picker.loading)) return
    var serial = picker.serial
    picker.loading = true
    if (!picker.query) {
      app.request("gifs.saved", {}, function (answer) {
        if (serial !== picker.serial) return
        picker.loading = false
        picker.items = (answer.ok ? answer.result.gifs || [] : []).map(function (gif) { return { gif: gif } })
      })
      return
    }
    app.request("gifs.search", { chatId: picker.chatId, query: picker.query, offset: more ? picker.nextOffset : "" }, function (answer) {
      if (serial !== picker.serial) return
      picker.loading = false
      if (!answer.ok) return
      var found = (answer.result.results || []).map(function (r) { return { gif: r.gif, queryId: answer.result.queryId, resultId: r.id } })
      picker.items = (more ? picker.items : []).concat(found).slice(0, 300)
      picker.nextOffset = answer.result.nextOffset || ""
    })
  }

  // A pause while typing, so each keystroke does not become a query.
  Timer {
    id: searchLater
    interval: 400
    onTriggered: {
      picker.serial++
      picker.items = []
      picker.cursor = 0
      picker.nextOffset = ""
      picker.loadGifs(false)
    }
  }

  function move(delta) {
    if (!picker.items.length) return
    picker.cursor = Math.max(0, Math.min(picker.items.length - 1, picker.cursor + delta))
    grid.positionViewAtIndex(picker.cursor, GridView.Contain)
    if (picker.gifs && picker.cursor >= picker.items.length - picker.columns * 2) picker.loadGifs(true)
  }

  function send(index) {
    var item = picker.items[index]
    if (!item) return
    if (picker.gifs) picker.gifPicked(item)
    else picker.picked(item)
  }

  function sticker(media) {
    return media ? { id: 0, content: { kind: "sticker", media: media } } : null
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, 0.03)
    Rectangle { width: parent.width; height: 1; color: app.border; opacity: 0.35 }
  }

  ColumnLayout {
    anchors.fill: parent
    anchors.margins: Style.space(10)
    spacing: Style.space(6)

    ListView {
      id: tabs
      Layout.fillWidth: true
      Layout.preferredHeight: Style.space(44)
      orientation: ListView.Horizontal
      spacing: Style.space(6)
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      // md-clock-outline U+F0150, md-file-gif-box U+F0D78
      model: [{ title: "Recent", cover: null, glyph: 0xF0150 }, { title: "GIFs", cover: null, glyph: 0xF0D78 }].concat(picker.sets)

      delegate: Rectangle {
        required property var modelData
        required property int index
        width: Style.space(44)
        height: Style.space(44)
        radius: Style.cornerRadius
        color: index === picker.tab ? app.selected : "transparent"
        border.width: index === picker.tab ? Math.max(1, Style.space(1.5)) : 0
        border.color: app.accent

        MediaView {
          anchors.centerIn: parent
          visible: !!modelData.cover
          app: picker.app
          still: true
          interactive: false
          stickerSize: Style.space(32)
          message: picker.sticker(modelData.cover)
        }
        Text {
          anchors.centerIn: parent
          visible: !modelData.cover
          text: String.fromCodePoint(modelData.glyph || 0xF0150)
          color: app.accent
          font.family: app.glyphFamily
          font.pixelSize: Style.font.title
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            picker.show(index)
            if (picker.gifs) gifSearch.forceActiveFocus()
            else grid.forceActiveFocus()
          }
        }
      }
    }

    Rectangle {
      visible: picker.gifs
      Layout.fillWidth: true
      Layout.preferredHeight: visible ? Style.space(34) : 0
      radius: Style.cornerRadius
      color: Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, 0.05)
      border.width: Math.max(1, Style.space(1.5))
      border.color: gifSearch.activeFocus ? app.accent : "transparent"

      TextInput {
        id: gifSearch
        anchors.fill: parent
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(10)
        verticalAlignment: TextInput.AlignVCenter
        clip: true
        maximumLength: 64
        color: app.foreground
        selectionColor: app.accent
        font.family: app.fontFamily
        font.pixelSize: Style.font.body
        onTextChanged: {
          picker.query = text.trim()
          searchLater.restart()
        }

        Keys.onPressed: function (event) {
          var keys = picker.app.shortcuts
          function is(id) { return Keymap.matchesInText(keys, id, event) }
          if (is("stickers.down")) grid.forceActiveFocus()
          else if (is("stickers.nextSet")) picker.show(picker.tab + 1)
          else if (is("stickers.previousSet")) picker.show(picker.tab - 1)
          else if (is("stickers.send")) picker.send(picker.cursor)
          else if (is("stickers.close")) picker.closed()
          else return
          event.accepted = true
        }

        Text {
          anchors.fill: parent
          verticalAlignment: Text.AlignVCenter
          visible: gifSearch.text === ""
          text: "Search GIFs"
          color: app.muted
          opacity: 0.7
          font: gifSearch.font
        }
      }
    }

    Text {
      Layout.fillWidth: true
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: (picker.tab === 0 ? "Recent" : (picker.gifs ? (picker.query ? "GIFs found" : "Your GIFs")
             : (picker.sets[picker.tab - 2] ? picker.sets[picker.tab - 2].title : "")))
        + "   ←→↑↓ move · Tab next · Enter send · Esc close"
      color: app.muted
      font.family: app.fontFamily
      font.pixelSize: Style.font.caption
    }

    GridView {
      id: grid

      WheelScroll { view: grid }
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      focus: true
      cellWidth: picker.cell
      cellHeight: picker.gifs ? Math.round(picker.cell * 0.75) : picker.cell
      boundsBehavior: Flickable.StopAtBounds
      model: picker.items
      onAtYEndChanged: if (atYEnd && count > 0 && picker.gifs) picker.loadGifs(true)

      Keys.onPressed: function (event) {
        var keys = picker.app.shortcuts
        function is(id) { return Keymap.matches(keys, id, event) }
        if (is("stickers.right")) picker.move(1)
        else if (is("stickers.left")) picker.move(-1)
        else if (is("stickers.down")) picker.move(picker.columns)
        else if (is("stickers.up")) {
          if (picker.gifs && picker.cursor < picker.columns) gifSearch.forceActiveFocus()
          else picker.move(-picker.columns)
        }
        else if (is("stickers.previousSet")) picker.show(picker.tab - 1)
        else if (is("stickers.nextSet")) picker.show(picker.tab + 1)
        else if (is("stickers.send")) picker.send(picker.cursor)
        else if (is("stickers.close")) picker.closed()
        else return
        event.accepted = true
      }

      delegate: Rectangle {
        id: cellItem
        required property var modelData
        required property int index
        width: grid.cellWidth
        height: grid.cellHeight
        radius: Style.cornerRadius
        color: index === picker.cursor && grid.activeFocus ? app.selected
             : (cellMouse.containsMouse ? Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, 0.05) : "transparent")
        border.width: index === picker.cursor && grid.activeFocus ? Math.max(1, Style.space(1.5)) : 0
        border.color: app.accent

        MediaView {
          anchors.centerIn: parent
          visible: !picker.gifs
          app: picker.app
          still: true
          interactive: false
          stickerSize: picker.cell - Style.space(14)
          message: picker.gifs ? null : picker.sticker(cellItem.modelData)
        }

        // A GIF: its still thumbnail, the tiny inline one until that is here.
        Item {
          id: gifCell
          readonly property var gif: picker.gifs ? cellItem.modelData.gif : null
          readonly property var thumb: gifCell.gif && gifCell.gif.thumb && gifCell.gif.thumb.file
                                       && ["jpeg", "png", "webp"].indexOf(gifCell.gif.thumb.format) >= 0
                                       ? picker.app.fileState(gifCell.gif.thumb.file) : null
          visible: picker.gifs
          anchors.fill: parent
          anchors.margins: Style.space(4)
          clip: true

          Component.onCompleted: if (gifCell.thumb && !gifCell.thumb.path && !gifCell.thumb.active) picker.app.download(gifCell.thumb.id, 1)

          Image {
            anchors.fill: parent
            visible: stillGif.status !== Image.Ready
            source: Model.miniUrl(gifCell.gif ? gifCell.gif.mini : null)
            fillMode: Image.PreserveAspectCrop
          }
          Image {
            id: stillGif
            anchors.fill: parent
            source: gifCell.thumb ? Model.fileUrl(gifCell.thumb.path) : ""
            asynchronous: true
            fillMode: Image.PreserveAspectCrop
            sourceSize.width: 320
          }
          Rectangle {
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.margins: Style.space(3)
            width: gifBadge.implicitWidth + Style.space(8)
            height: gifBadge.implicitHeight + Style.space(2)
            radius: Style.cornerRadius
            color: Qt.rgba(0, 0, 0, 0.55)
            Text { id: gifBadge; anchors.centerIn: parent; text: "GIF"; color: "white"; font.pixelSize: Style.font.caption; font.bold: true }
          }
        }

        MouseArea {
          id: cellMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: picker.send(cellItem.index)
        }
      }

      Text {
        anchors.centerIn: parent
        visible: grid.count === 0
        text: picker.loading ? "Loading…"
            : (picker.gifs ? (picker.query ? "No GIFs found" : "No saved GIFs: type to search")
               : (picker.tab === 0 ? "No recent stickers yet" : "This set is empty"))
        color: app.muted
        font.family: app.fontFamily
        font.pixelSize: Style.font.body
      }
    }
  }
}
