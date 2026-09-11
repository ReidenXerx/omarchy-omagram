import QtQuick
import QtQuick.Layouts
import qs.Commons

// The sticker picker: recent stickers first, then each installed set.
// Keyboard: arrows or h/j/k/l move, Tab and Shift+Tab switch sets, Enter sends, Esc closes.
// Stickers show small and still (animated ones as their thumbnail), so a grid of dozens does
// not run dozens of animations.
FocusScope {
  id: picker

  property var app
  property var sets: []
  property var stickers: []
  property int tab: 0
  property int cursor: 0
  property bool loading: false
  readonly property int cell: Style.space(84)
  readonly property int columns: Math.max(1, Math.floor(grid.width / cell))

  signal picked(var sticker)
  signal closed()

  function open() {
    grid.forceActiveFocus()
    if (!picker.sets.length)
      app.request("stickers.sets", {}, function (answer) { if (answer.ok) picker.sets = answer.result.sets || [] })
    show(picker.tab)
  }

  function show(index) {
    var count = picker.sets.length + 1
    picker.tab = ((index % count) + count) % count
    picker.cursor = 0
    picker.loading = true
    picker.stickers = []
    var wanted = picker.tab
    var done = function (answer) {
      if (picker.tab !== wanted) return   // an answer for a tab that was already left
      picker.loading = false
      picker.stickers = answer.ok ? (answer.result.stickers || []) : []
    }
    if (wanted === 0) app.request("stickers.recent", {}, done)
    else app.request("stickers.set", { setId: picker.sets[wanted - 1].id }, done)
    tabs.positionViewAtIndex(wanted, ListView.Contain)
  }

  function move(delta) {
    if (!picker.stickers.length) return
    picker.cursor = Math.max(0, Math.min(picker.stickers.length - 1, picker.cursor + delta))
    grid.positionViewAtIndex(picker.cursor, GridView.Contain)
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
      model: [{ title: "Recent", cover: null }].concat(picker.sets)

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
          // md-clock-outline U+F0150
          text: "󰅐"
          color: app.accent
          font.family: app.glyphFamily
          font.pixelSize: Style.font.title
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: { picker.show(index); grid.forceActiveFocus() }
        }
      }
    }

    Text {
      Layout.fillWidth: true
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: (picker.tab === 0 ? "Recent" : (picker.sets[picker.tab - 1] ? picker.sets[picker.tab - 1].title : ""))
        + "   ←→↑↓ move · Tab next set · Enter send · Esc close"
      color: app.muted
      font.family: app.fontFamily
      font.pixelSize: Style.font.caption
    }

    GridView {
      id: grid

      WheelScroll {}
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      focus: true
      cellWidth: picker.cell
      cellHeight: picker.cell
      boundsBehavior: Flickable.StopAtBounds
      model: picker.stickers

      Keys.onPressed: function (event) {
        var key = event.key
        if (key === Qt.Key_Right || key === Qt.Key_L) { picker.move(1); event.accepted = true }
        else if (key === Qt.Key_Left || key === Qt.Key_H) { picker.move(-1); event.accepted = true }
        else if (key === Qt.Key_Down || key === Qt.Key_J) { picker.move(picker.columns); event.accepted = true }
        else if (key === Qt.Key_Up || key === Qt.Key_K) { picker.move(-picker.columns); event.accepted = true }
        else if (key === Qt.Key_Backtab || (key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) { picker.show(picker.tab - 1); event.accepted = true }
        else if (key === Qt.Key_Tab) { picker.show(picker.tab + 1); event.accepted = true }
        else if (key === Qt.Key_Return || key === Qt.Key_Enter) {
          if (picker.stickers[picker.cursor]) picker.picked(picker.stickers[picker.cursor])
          event.accepted = true
        }
        else if (key === Qt.Key_Escape) { picker.closed(); event.accepted = true }
      }

      delegate: Rectangle {
        id: cellItem
        required property var modelData
        required property int index
        width: picker.cell
        height: picker.cell
        radius: Style.cornerRadius
        color: index === picker.cursor && grid.activeFocus ? app.selected
             : (cellMouse.containsMouse ? Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, 0.05) : "transparent")
        border.width: index === picker.cursor && grid.activeFocus ? Math.max(1, Style.space(1.5)) : 0
        border.color: app.accent

        MediaView {
          anchors.centerIn: parent
          app: picker.app
          still: true
          interactive: false
          stickerSize: picker.cell - Style.space(14)
          message: picker.sticker(cellItem.modelData)
        }
        MouseArea {
          id: cellMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: picker.picked(cellItem.modelData)
        }
      }

      Text {
        anchors.centerIn: parent
        visible: grid.count === 0
        text: picker.loading ? "Loading stickers…" : (picker.tab === 0 ? "No recent stickers yet" : "This set is empty")
        color: app.muted
        font.family: app.fontFamily
        font.pixelSize: Style.font.body
      }
    }
  }
}
