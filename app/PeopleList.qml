import QtQuick
import QtQuick.Layouts
import qs.Commons
import "Keymap.js" as Keymap

// The people around a message: who reacted to it and with what, or who has seen it. Enter or a click on
// someone opens a chat with them. Keys are those of choosing a chat to forward to; a click outside closes it.
FocusScope {
  id: list

  property var app
  property string title: ""
  property var rows: []                // [{ type: "user" or "chat", id, name, detail }]
  property bool loading: false
  property int cursor: 0

  signal picked(var row)
  signal dismissed()

  visible: false
  z: 60

  function open(title) {
    list.title = title
    list.rows = []
    list.cursor = 0
    list.loading = true
    list.visible = true
    view.forceActiveFocus()
  }

  function show(rows) {
    list.loading = false
    list.rows = rows || []
  }

  function dismiss() {
    if (!list.visible) return
    list.visible = false
    list.dismissed()
  }

  function choose(index) {
    var row = list.rows[index]
    if (!row) return
    list.visible = false
    list.picked(row)
  }

  function move(delta) {
    if (!list.rows.length) return
    list.cursor = Math.max(0, Math.min(list.rows.length - 1, list.cursor + delta))
    view.positionViewAtIndex(list.cursor, ListView.Contain)
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.55)
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: list.dismiss()
  }

  Rectangle {
    width: Math.min(parent.width - Style.space(40), Style.space(420))
    // As tall as its rows, up to a screenful; the title and margins take the rest.
    height: Math.min(parent.height - Style.space(60), Style.space(480),
                     Style.space(14) * 2 + Style.space(10) + Style.space(30) + Math.max(1, list.rows.length) * Style.space(46))
    anchors.centerIn: parent
    radius: Style.cornerRadius
    color: list.app.background
    border.width: 1
    border.color: Qt.rgba(list.app.foreground.r, list.app.foreground.g, list.app.foreground.b, 0.18)

    MouseArea { anchors.fill: parent; acceptedButtons: Qt.LeftButton | Qt.RightButton }

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: Style.space(14)
      spacing: Style.space(10)

      Text {
        Layout.fillWidth: true
        elide: Text.ElideRight
        text: list.title + (list.rows.length ? "  (" + list.rows.length + ")" : "")
        textFormat: Text.PlainText
        color: list.app.foreground
        font.family: list.app.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
      }

      ListView {
        id: view
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        focus: true
        model: list.rows
        boundsBehavior: Flickable.StopAtBounds

        WheelScroll { view: view }

        Keys.onPressed: function (event) {
          var keys = list.app.shortcuts
          function is(id) { return Keymap.matches(keys, id, event) }
          if (is("picker.down")) list.move(1)
          else if (is("picker.up")) list.move(-1)
          else if (is("picker.pick")) list.choose(list.cursor)
          else if (is("picker.close")) list.dismiss()
          else return
          event.accepted = true
        }

        delegate: Rectangle {
          id: person
          required property var modelData
          required property int index
          width: view.width
          height: Style.space(46)
          radius: Style.cornerRadius
          color: person.index === list.cursor ? list.app.selected
               : (personArea.containsMouse ? Qt.rgba(list.app.foreground.r, list.app.foreground.g, list.app.foreground.b, 0.05) : "transparent")

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            spacing: Style.space(10)

            Text {
              Layout.fillWidth: true
              elide: Text.ElideRight
              text: person.modelData.name
              textFormat: Text.PlainText
              color: list.app.foreground
              font.family: list.app.fontFamily
              font.pixelSize: Style.font.body
            }
            Text {
              text: person.modelData.detail || ""
              textFormat: Text.PlainText
              color: list.app.muted
              font.family: list.app.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          MouseArea {
            id: personArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: list.choose(person.index)
          }
        }

        Text {
          anchors.centerIn: parent
          visible: view.count === 0
          text: list.loading ? "Loading…" : "Nobody yet"
          color: list.app.muted
          font.family: list.app.fontFamily
          font.pixelSize: Style.font.body
        }
      }
    }
  }
}
