import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "../app/Model.js" as Model

// The bar's quick panel: your most recent chats, and a reply without leaving what you are doing.
//
// Enter or a click starts a reply to the highlighted chat; o or a middle click opens it in the
// window. Text that comes from Telegram is only ever shown as plain text.
Panel {
  id: root
  moduleName: "reidenxerx.omagram"
  // Summon from a key binding: omarchy-shell reidenxerx.omagram.panel toggle
  // (its own target, apart from the overlay, which the shell toggles by plugin id).
  ipcTarget: "reidenxerx.omagram.panel"
  manageIpc: true

  property var anchorItem: null
  property var hostWidget: null
  property var omagram: null
  readonly property var barIdentity: hostWidget || root

  readonly property int rowsShown: 8
  readonly property bool ready: !!root.omagram && root.omagram.ready
  readonly property var rows: root.ready ? root.omagram.chats.slice(0, root.rowsShown) : []
  property int cursor: 0
  property real replyChatId: 0
  readonly property var replyChat: root.replyChatId && root.omagram ? Model.findChat(root.omagram.chats, root.replyChatId) : null
  property bool sending: false
  property string status: ""
  property bool statusError: false
  property real nowMs: Date.now()

  onOpenedChanged: {
    if (opened) {
      root.cursor = 0
      root.status = ""
      root.nowMs = Date.now()
    } else {
      root.cancelReply()
    }
  }

  function move(dy) {
    if (root.rows.length === 0) return
    root.cursor = Math.max(0, Math.min(root.rows.length - 1, root.cursor + dy))
  }

  function previewLine(chat) {
    var m = chat ? chat.lastMessage : null
    if (!m) return ""
    var who = m.outgoing ? "You: " : (chat.kind !== "private" && m.senderName ? m.senderName + ": " : "")
    return who + (m.text || "")
  }

  function startReply(index) {
    var chat = root.rows[index]
    if (!chat) return
    root.cursor = index
    root.replyChatId = chat.id
    root.status = ""
    replyField.text = ""
    Qt.callLater(function () { replyField.forceActiveFocus() })
  }

  function cancelReply() {
    root.replyChatId = 0
    root.sending = false
    replyField.text = ""
    if (root.opened) keyCatcher.forceActiveFocus()
  }

  function openInWindow(index) {
    if (!root.omagram) return
    var chat = root.rows[index]
    if (chat) root.omagram.openChat(chat.id)
    else root.omagram.openWindow()
    root.close()
  }

  function send() {
    var text = replyField.text
    if (!root.replyChatId || root.sending || text.trim() === "") return
    root.sending = true
    var title = root.replyChat ? root.replyChat.title : "the chat"
    root.omagram.sendText(root.replyChatId, text, function (answer) {
      root.sending = false
      if (answer.ok) {
        root.status = "Sent to " + title
        root.statusError = false
        root.cancelReply()
      } else {
        root.status = answer.error || "Could not send"
        root.statusError = true
        replyField.forceActiveFocus()
      }
    })
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    popoutSwitching: root.popoutSwitching
    popoutSwitchClosing: root.popoutSwitchClosing
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    // The house key catcher steers the list; while the reply field has focus it steps aside
    // so typed text reaches the field.
    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: replyField.activeFocus
      onMoveRequested: function (dx, dy) { root.move(dy) }
      onActivateRequested: root.ready ? root.startReply(root.cursor) : root.openInWindow(-1)
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (t) {
        if (t === "o") root.openInWindow(root.cursor)
        else if (t === "r") root.startReply(root.cursor)
      }

      ColumnLayout {
        id: column
        width: parent.width
        spacing: Style.space(4)

        RowLayout {
          Layout.fillWidth: true
          Layout.bottomMargin: Style.space(2)
          spacing: Style.space(8)

          Text {
            Layout.fillWidth: true
            text: "Omagram"
            color: root.barForeground
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }

          Text {
            text: root.ready && root.omagram.unread > 0 ? root.omagram.unread + " unread" : ""
            color: root.barForeground
            opacity: 0.5
            font.pixelSize: Style.font.caption
          }

          // md-open_in_new (U+F03CC)
          Text {
            text: "󰏌"
            color: openArea.containsMouse ? Color.accent : root.barForeground
            opacity: openArea.containsMouse ? 1 : 0.6
            font.family: Style.font.family
            font.pixelSize: Style.font.body

            MouseArea {
              id: openArea
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openInWindow(-1)
            }
          }
        }

        Repeater {
          model: root.rows

          delegate: Rectangle {
            id: row
            required property var modelData
            required property int index
            readonly property bool highlighted: root.cursor === index || rowArea.containsMouse
            readonly property bool replying: root.replyChatId === modelData.id

            Layout.fillWidth: true
            implicitHeight: Style.space(42)
            radius: Style.cornerRadius
            color: row.highlighted || row.replying ? Style.hoverFillFor(root.barForeground, Color.accent) : "transparent"

            ColumnLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              anchors.topMargin: Style.space(4)
              anchors.bottomMargin: Style.space(4)
              spacing: 0

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)

                Text {
                  Layout.fillWidth: true
                  text: row.modelData.title || ""
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  color: root.barForeground
                  font.pixelSize: Style.font.bodySmall
                  font.bold: row.modelData.unread > 0 && !row.modelData.muted
                }

                Text {
                  text: row.modelData.lastMessage ? Model.listTime(row.modelData.lastMessage.date, root.nowMs) : ""
                  color: root.barForeground
                  opacity: 0.45
                  font.pixelSize: Style.font.caption
                }
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)

                Text {
                  Layout.fillWidth: true
                  text: root.previewLine(row.modelData)
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  maximumLineCount: 1
                  color: root.barForeground
                  opacity: 0.55
                  font.pixelSize: Style.font.caption
                }

                Rectangle {
                  visible: row.modelData.unread > 0
                  implicitHeight: Style.space(16)
                  implicitWidth: Math.max(implicitHeight, badge.implicitWidth + Style.space(10))
                  radius: implicitHeight / 2
                  color: row.modelData.muted ? Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.3) : Color.accent

                  Text {
                    id: badge
                    anchors.centerIn: parent
                    text: row.modelData.unread > 999 ? "999+" : String(row.modelData.unread)
                    color: Color.background
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }
              }
            }

            MouseArea {
              id: rowArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              acceptedButtons: Qt.LeftButton | Qt.MiddleButton
              onClicked: function (mouse) {
                if (mouse.button === Qt.MiddleButton) root.openInWindow(row.index)
                else root.startReply(row.index)
              }
            }
          }
        }

        Text {
          Layout.fillWidth: true
          visible: root.rows.length === 0
          horizontalAlignment: Text.AlignHCenter
          topPadding: Style.space(14)
          bottomPadding: Style.space(14)
          wrapMode: Text.Wrap
          text: !root.omagram || !root.omagram.connected ? "Omagram's service is starting"
              : (root.omagram.auth.state === "ready" ? "No chats yet" : "Sign in from the Omagram window. Press Enter to open it.")
          color: root.barForeground
          opacity: 0.5
          font.pixelSize: Style.font.bodySmall
        }

        ColumnLayout {
          Layout.fillWidth: true
          Layout.topMargin: Style.space(4)
          visible: root.replyChatId !== 0
          spacing: Style.space(4)

          Text {
            Layout.fillWidth: true
            text: "Reply to " + (root.replyChat ? root.replyChat.title : "chat")
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.barForeground
            opacity: 0.6
            font.pixelSize: Style.font.caption
          }

          TextField {
            id: replyField
            Layout.fillWidth: true
            placeholderText: root.sending ? "Sending…" : "Message  (Enter sends, Esc cancels)"
            readOnly: root.sending
            foreground: root.barForeground
            onAccepted: root.send()
            Keys.onEscapePressed: function (event) {
              event.accepted = true
              root.cancelReply()
            }
          }
        }

        Text {
          Layout.fillWidth: true
          visible: root.status !== ""
          text: root.status
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.statusError ? Color.urgent : root.barForeground
          opacity: root.statusError ? 0.9 : 0.55
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
