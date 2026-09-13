import QtQuick
import QtQuick.Layouts
import qs.Commons
import "Model.js" as Model
import "Keymap.js" as Keymap

// Where to forward messages: type to find a chat and choose it. Saved Messages comes first.
// Keys are the "Choosing a chat to forward to" section of the shortcuts; a click outside cancels.
FocusScope {
  id: picker

  property var app
  property var chats: []
  property var messageIds: []
  property real fromChatId: 0
  property string title: ""     // said instead of "Forward … to…" when a chat is chosen for something else
  property string query: ""
  property int cursor: 0

  readonly property var results: picker.visible ? Model.forwardTargets(picker.chats, picker.query, picker.app.meId) : []

  signal picked(real chatId, string title)
  signal dismissed()

  visible: false
  z: 60

  function open(fromChatId, ids) {
    picker.fromChatId = fromChatId
    picker.messageIds = ids || []
    picker.cursor = 0
    search.text = ""
    picker.visible = true
    search.forceActiveFocus()
  }

  function dismiss() {
    if (!picker.visible) return
    picker.visible = false
    picker.dismissed()
  }

  function choose(index) {
    var chat = picker.results[index]
    if (!picker.visible || !chat) return
    picker.visible = false
    picker.picked(chat.id, Model.chatTitle(chat, picker.app.meId))
  }

  function move(delta) {
    if (!picker.results.length) return
    picker.cursor = Math.max(0, Math.min(picker.results.length - 1, picker.cursor + delta))
    list.positionViewAtIndex(picker.cursor, ListView.Contain)
  }

  onActiveFocusChanged: if (!activeFocus) picker.visible = false

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.55)
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: picker.dismiss()
  }

  Rectangle {
    width: Math.min(parent.width - Style.space(40), Style.space(460))
    height: Math.min(parent.height - Style.space(60), Style.space(560))
    anchors.centerIn: parent
    radius: Style.cornerRadius
    color: picker.app.background
    border.width: 1
    border.color: Qt.rgba(picker.app.foreground.r, picker.app.foreground.g, picker.app.foreground.b, 0.18)

    MouseArea { anchors.fill: parent; acceptedButtons: Qt.LeftButton | Qt.RightButton }

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: Style.space(14)
      spacing: Style.space(10)

      Text {
        Layout.fillWidth: true
        elide: Text.ElideRight
        text: picker.title !== "" ? picker.title
            : "Forward " + (picker.messageIds.length === 1 ? "the message" : picker.messageIds.length + " messages") + " to…"
        color: picker.app.foreground
        font.family: picker.app.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
      }

      Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: Style.space(36)
        radius: Style.cornerRadius
        color: Qt.rgba(picker.app.foreground.r, picker.app.foreground.g, picker.app.foreground.b, 0.05)
        border.width: Math.max(1, Style.space(1.5))
        border.color: search.activeFocus ? picker.app.accent : "transparent"

        TextInput {
          id: search
          anchors.fill: parent
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          verticalAlignment: TextInput.AlignVCenter
          clip: true
          maximumLength: 128
          color: picker.app.foreground
          selectionColor: picker.app.accent
          font.family: picker.app.fontFamily
          font.pixelSize: Style.font.body
          onTextChanged: {
            picker.query = text
            picker.cursor = 0
          }

          Keys.onPressed: function (event) {
            var keys = picker.app.shortcuts
            function is(id) { return Keymap.matchesInText(keys, id, event) }
            if (is("picker.down")) picker.move(1)
            else if (is("picker.up")) picker.move(-1)
            else if (is("picker.pick")) picker.choose(picker.cursor)
            else if (is("picker.close")) picker.dismiss()
            else return
            event.accepted = true
          }

          Text {
            anchors.fill: parent
            verticalAlignment: Text.AlignVCenter
            visible: search.text === ""
            text: "Find a chat"
            color: picker.app.muted
            opacity: 0.7
            font: search.font
          }
        }
      }

      ListView {
        id: list
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        model: picker.results
        boundsBehavior: Flickable.StopAtBounds

        WheelScroll { view: list }

        delegate: Rectangle {
          id: target
          required property var modelData
          required property int index
          width: list.width
          height: Style.space(50)
          radius: Style.cornerRadius
          color: target.index === picker.cursor ? picker.app.selected
               : (targetArea.containsMouse ? Qt.rgba(picker.app.foreground.r, picker.app.foreground.g, picker.app.foreground.b, 0.05) : "transparent")

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            spacing: Style.space(10)

            Avatar {
              app: picker.app
              chat: target.modelData
              size: Style.space(36)
              Layout.preferredWidth: size
              Layout.preferredHeight: size
            }
            Text {
              Layout.fillWidth: true
              elide: Text.ElideRight
              text: Model.chatTitle(target.modelData, picker.app.meId)
              textFormat: Text.PlainText
              color: picker.app.foreground
              font.family: picker.app.fontFamily
              font.pixelSize: Style.font.body
            }
          }
          MouseArea {
            id: targetArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: picker.choose(target.index)
          }
        }

        Text {
          anchors.centerIn: parent
          visible: list.count === 0
          text: "No chat matches"
          color: picker.app.muted
          font.family: picker.app.fontFamily
          font.pixelSize: Style.font.body
        }
      }
    }
  }
}
