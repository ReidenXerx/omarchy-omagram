import QtQuick
import QtQuick.Layouts
import qs.Commons
import "Model.js" as Model

// The chat list. Keyboard: Ctrl+K or / searches, ↑/↓ or j/k move, Enter opens, Esc leaves
// the search, Tab goes to the open chat. Alt+↑/↓ steps through chats from anywhere.
FocusScope {
  id: root

  property var app
  property var chats: []
  property real openChatId: 0
  property real nowMs: Date.now()
  property int cursor: 0

  readonly property var shown: Model.filterChats(root.chats, search.text)

  signal activated(real chatId)
  signal toChat()

  function focusSearch() {
    search.forceActiveFocus()
    search.selectAll()
  }

  function focusList() {
    listView.forceActiveFocus()
  }

  function move(delta) {
    if (!root.shown.length) return
    root.cursor = Math.max(0, Math.min(root.shown.length - 1, root.cursor + delta))
    listView.positionViewAtIndex(root.cursor, ListView.Contain)
  }

  function openCursor() {
    if (root.cursor >= 0 && root.cursor < root.shown.length) root.activated(root.shown[root.cursor].id)
  }

  // From anywhere in the window: open the chat above or below the one that is open.
  function step(delta) {
    if (!root.shown.length) return
    var index = Model.indexOfChat(root.shown, root.openChatId)
    root.cursor = index < 0 ? 0 : Math.max(0, Math.min(root.shown.length - 1, index + delta))
    listView.positionViewAtIndex(root.cursor, ListView.Contain)
    root.activated(root.shown[root.cursor].id)
  }

  onShownChanged: root.cursor = Math.max(0, Math.min(root.cursor, root.shown.length - 1))
  onOpenChatIdChanged: {
    var index = Model.indexOfChat(root.shown, root.openChatId)
    if (index >= 0) root.cursor = index
  }

  ColumnLayout {
    anchors.fill: parent
    spacing: 0

    // ------------------------------------------------ search
    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: Style.space(56)
      color: "transparent"

      Rectangle {
        anchors.fill: parent
        anchors.margins: Style.space(10)
        radius: Style.cornerRadius
        color: Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, 0.05)
        border.width: Math.max(1, Style.space(1.5))
        border.color: search.activeFocus ? app.accent : "transparent"

        TextInput {
          id: search
          anchors.fill: parent
          anchors.leftMargin: Style.space(12)
          anchors.rightMargin: Style.space(12)
          verticalAlignment: TextInput.AlignVCenter
          clip: true
          color: app.foreground
          selectionColor: app.accent
          font.family: app.fontFamily
          font.pixelSize: Style.font.body
          maximumLength: 128

          Keys.onPressed: function (event) {
            if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab) {
              root.cursor = 0
              root.focusList()
              event.accepted = true
            } else if (event.key === Qt.Key_Escape) {
              search.text = ""
              root.focusList()
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.cursor = 0
              root.openCursor()
              event.accepted = true
            }
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: search.text === ""
            text: "Search chats   Ctrl+K"
            color: app.muted
            opacity: 0.7
            font: search.font
          }
        }
      }
    }

    // ------------------------------------------------ chats
    ListView {
      id: listView
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      model: root.shown
      focus: true
      boundsBehavior: Flickable.StopAtBounds
      highlightFollowsCurrentItem: false

      Keys.onPressed: function (event) {
        var key = event.key
        if (key === Qt.Key_Down || key === Qt.Key_J) { root.move(1); event.accepted = true }
        else if (key === Qt.Key_Up || key === Qt.Key_K) { root.move(-1); event.accepted = true }
        else if (key === Qt.Key_PageDown) { root.move(10); event.accepted = true }
        else if (key === Qt.Key_PageUp) { root.move(-10); event.accepted = true }
        else if (key === Qt.Key_Home || key === Qt.Key_G && !(event.modifiers & Qt.ShiftModifier)) { root.cursor = 0; root.move(0); event.accepted = true }
        else if (key === Qt.Key_End || key === Qt.Key_G) { root.cursor = root.shown.length - 1; root.move(0); event.accepted = true }
        else if (key === Qt.Key_Return || key === Qt.Key_Enter || key === Qt.Key_L || key === Qt.Key_Right) { root.openCursor(); event.accepted = true }
        else if (key === Qt.Key_Slash) { root.focusSearch(); event.accepted = true }
        else if (key === Qt.Key_Tab) { root.toChat(); event.accepted = true }
        else if (key === Qt.Key_Escape && search.text !== "") { search.text = ""; event.accepted = true }
      }

      delegate: Rectangle {
        id: row
        required property var modelData
        required property int index
        readonly property bool isOpen: modelData.id === root.openChatId
        readonly property bool isCursor: index === root.cursor && listView.activeFocus

        width: listView.width
        height: Style.space(68)
        color: isCursor ? app.selected
             : (isOpen ? Qt.rgba(app.accent.r, app.accent.g, app.accent.b, 0.12)
                : (hover.containsMouse ? Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, 0.04) : "transparent"))

        Rectangle {
          visible: row.isCursor || row.isOpen
          width: Style.space(3)
          height: parent.height
          color: app.accent
        }

        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: Style.space(14)
          anchors.rightMargin: Style.space(14)
          spacing: Style.space(12)

          Rectangle {
            Layout.preferredWidth: Style.space(44)
            Layout.preferredHeight: Style.space(44)
            radius: width / 2
            color: Qt.rgba(app.accent.r, app.accent.g, app.accent.b, 0.22)

            Text {
              anchors.centerIn: parent
              text: Model.initials(row.modelData.title)
              color: app.accent
              font.family: app.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(3)

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Text {
                Layout.fillWidth: true
                text: row.modelData.title || "Deleted account"
                elide: Text.ElideRight
                textFormat: Text.PlainText
                color: app.foreground
                font.family: app.fontFamily
                font.pixelSize: Style.font.body
                font.bold: row.modelData.unread > 0
              }

              Text {
                text: row.modelData.lastMessage ? Model.listTime(row.modelData.lastMessage.date, root.nowMs) : ""
                color: row.modelData.unread > 0 && !row.modelData.muted ? app.accent : app.muted
                font.family: app.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Text {
                Layout.fillWidth: true
                elide: Text.ElideRight
                maximumLineCount: 1
                textFormat: Text.PlainText
                color: app.muted
                font.family: app.fontFamily
                font.pixelSize: Style.font.bodySmall
                text: {
                  var last = row.modelData.lastMessage
                  if (!last) return ""
                  var who = last.outgoing ? "You: " : (row.modelData.kind !== "private" && last.senderName ? last.senderName + ": " : "")
                  return who + last.text
                }
              }

              // md-pin (U+F0403) and md-bell-off (U+F009B), from the Nerd Font.
              Text {
                visible: row.modelData.pinned && !(row.modelData.unread > 0)
                text: "󰐃"
                color: app.muted
                font.family: app.glyphFamily
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                visible: row.modelData.muted
                text: "󰂛"
                color: app.muted
                font.family: app.glyphFamily
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                visible: row.modelData.unread > 0 || row.modelData.mentions > 0
                Layout.preferredHeight: Style.space(20)
                Layout.preferredWidth: Math.max(Style.space(20), badge.implicitWidth + Style.space(12))
                radius: height / 2
                color: row.modelData.muted ? Qt.rgba(app.muted.r, app.muted.g, app.muted.b, 0.5) : app.accent

                Text {
                  id: badge
                  anchors.centerIn: parent
                  text: row.modelData.mentions > 0 ? "@" : (row.modelData.unread > 999 ? "999+" : String(row.modelData.unread))
                  color: app.background
                  font.family: app.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }
            }
          }
        }

        MouseArea {
          id: hover
          anchors.fill: parent
          hoverEnabled: true
          onClicked: {
            root.cursor = row.index
            root.activated(row.modelData.id)
          }
        }
      }

      Text {
        anchors.centerIn: parent
        visible: listView.count === 0
        text: search.text ? "No chats match" : "Loading chats…"
        color: app.muted
        font.family: app.fontFamily
        font.pixelSize: Style.font.body
      }
    }
  }
}
