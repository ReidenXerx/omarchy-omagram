import QtQuick
import QtQuick.Layouts
import qs.Commons
import "Model.js" as Model

// The open chat: messages and the composer.
//
// Composer: Enter sends, Shift+Enter adds a line, Esc cancels a reply or edit (or moves to
// the messages), ↑ in an empty composer edits your last message, Tab moves to the messages.
// Messages: ↑/↓ or j/k select, Enter or o downloads or opens the selected media, Space plays or
// pauses it, r replies, e edits yours, y copies, d or Delete asks to delete (press again to
// confirm), Esc or i returns to the composer, Tab returns to the chat list.
FocusScope {
  id: root

  property var app
  property var client
  property var chat: null
  property var messages: []
  property real nowMs: Date.now()

  property real replyToId: 0
  property real editingId: 0
  property int cursor: -1
  property real confirmDeleteId: 0
  property string notice: ""
  property bool stickToBottom: true

  readonly property var replyTo: root.replyToId ? Model.findMessage(root.messages, root.replyToId) : null
  readonly property var editing: root.editingId ? Model.findMessage(root.messages, root.editingId) : null
  readonly property var selectedMessage: root.cursor >= 0 && root.cursor < root.messages.length ? root.messages[root.cursor] : null

  signal loadOlder()
  signal toList()

  function focusComposer() { composer.forceActiveFocus() }

  function focusMessages() {
    if (!root.messages.length) return
    if (root.cursor < 0 || root.cursor >= root.messages.length) root.cursor = root.messages.length - 1
    messageList.forceActiveFocus()
    messageList.positionViewAtIndex(root.cursor, ListView.Contain)
  }

  function resetForChat() {
    root.replyToId = 0
    root.editingId = 0
    root.cursor = -1
    root.confirmDeleteId = 0
    root.notice = ""
    root.stickToBottom = true
    composer.text = ""
  }

  onChatChanged: {
    if (!root.chat || root.chat.id !== root.lastChatId) {
      root.lastChatId = root.chat ? root.chat.id : 0
      resetForChat()
    }
  }
  property real lastChatId: 0

  onMessagesChanged: {
    if (root.stickToBottom) Qt.callLater(function () { messageList.positionViewAtEnd() })
  }

  function flash(text) {
    root.notice = text
    noticeTimer.restart()
  }

  Timer { id: noticeTimer; interval: 3500; onTriggered: root.notice = "" }

  function send() {
    var text = composer.text.replace(/\s+$/, "")
    if (!root.chat || !text.trim()) return
    if (text.length > 4096) { root.flash("A message can be at most 4096 characters."); return }
    if (root.editingId) {
      var id = root.editingId
      client.request("message.edit", { chatId: root.chat.id, messageId: id, text: text }, function (answer) {
        if (!answer.ok) root.flash("Could not edit: " + (answer.error || "unknown error"))
      })
    } else {
      var args = { chatId: root.chat.id, text: text }
      if (root.replyToId) args.replyToMessageId = root.replyToId
      client.request("message.send", args, function (answer) {
        if (!answer.ok) root.flash("Could not send: " + (answer.error || "unknown error"))
      })
    }
    composer.text = ""
    root.replyToId = 0
    root.editingId = 0
    root.stickToBottom = true
  }

  function startReply(message) {
    if (!message) return
    root.editingId = 0
    root.replyToId = message.id
    root.focusComposer()
  }

  function startEdit(message) {
    if (!message || !message.outgoing || message.content.kind !== "text") return
    root.replyToId = 0
    root.editingId = message.id
    composer.text = message.content.text
    root.focusComposer()
    composer.cursorPosition = composer.length
  }

  function askDelete(message) {
    if (!message) return
    if (root.confirmDeleteId === message.id) {
      client.request("message.delete", { chatId: root.chat.id, messageIds: [message.id], revoke: true }, function (answer) {
        if (!answer.ok) root.flash("Could not delete: " + (answer.error || "unknown error"))
      })
      root.confirmDeleteId = 0
      return
    }
    root.confirmDeleteId = message.id
    root.flash(message.outgoing || root.chat.kind === "private" ? "Press again to delete for everyone" : "Press again to delete")
  }

  function copy(message) {
    if (!message) return
    clipboard.text = message.content.text || Model.previewOf(message)
    clipboard.selectAll()
    clipboard.copy()
    root.flash("Copied")
  }

  TextEdit { id: clipboard; visible: false }

  // ------------------------------------------------ no chat yet
  Text {
    anchors.centerIn: parent
    visible: !root.chat
    text: "Choose a chat   Alt+↑ / Alt+↓"
    color: app.muted
    font.family: app.fontFamily
    font.pixelSize: Style.font.body
  }

  ColumnLayout {
    anchors.fill: parent
    spacing: 0
    visible: !!root.chat

    // ------------------------------------------------ header
    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: Style.space(56)
      color: "transparent"

      Column {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(18)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          text: root.chat ? root.chat.title : ""
          textFormat: Text.PlainText
          color: app.foreground
          font.family: app.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }
        Text {
          text: !root.chat ? "" : ({ private: "Private chat", group: "Group", channel: "Channel", secret: "Secret chat" }[root.chat.kind] || "")
          color: app.muted
          font.family: app.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: app.border; opacity: 0.35 }
    }

    // ------------------------------------------------ messages
    ListView {
      id: messageList
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      model: root.messages
      spacing: Style.space(2)
      boundsBehavior: Flickable.StopAtBounds
      topMargin: Style.space(12)
      bottomMargin: Style.space(12)

      onMovementEnded: root.stickToBottom = atYEnd
      onAtYBeginningChanged: if (atYBeginning && count > 0 && moving) root.loadOlder()
      onContentYChanged: if (contentY <= originY + Style.space(200) && count > 0 && (moving || activeFocus)) root.loadOlder()

      Keys.onPressed: function (event) {
        var key = event.key
        var m = root.selectedMessage
        if (key === Qt.Key_Down || key === Qt.Key_J) {
          root.cursor = Math.min(root.messages.length - 1, root.cursor + 1)
          root.stickToBottom = root.cursor === root.messages.length - 1
          positionViewAtIndex(root.cursor, ListView.Contain)
          event.accepted = true
        } else if (key === Qt.Key_Up || key === Qt.Key_K) {
          root.cursor = Math.max(0, root.cursor - 1)
          root.stickToBottom = false
          positionViewAtIndex(root.cursor, ListView.Contain)
          if (root.cursor < 5) root.loadOlder()
          event.accepted = true
        } else if (key === Qt.Key_R) { root.startReply(m); event.accepted = true }
        else if (key === Qt.Key_E) { root.startEdit(m); event.accepted = true }
        else if (key === Qt.Key_Y) { root.copy(m); event.accepted = true }
        else if (key === Qt.Key_D || key === Qt.Key_Delete) { root.askDelete(m); event.accepted = true }
        else if (key === Qt.Key_Return || key === Qt.Key_Enter || key === Qt.Key_O || key === Qt.Key_Space) {
          var item = messageList.itemAtIndex(root.cursor)
          if (item && item.mediaItem && item.mediaItem.media) {
            if (key === Qt.Key_Space) item.mediaItem.togglePlay()
            else item.mediaItem.activate()
          }
          event.accepted = true
        }
        else if (key === Qt.Key_Escape || key === Qt.Key_I) { root.cursor = -1; root.focusComposer(); event.accepted = true }
        else if (key === Qt.Key_Tab) { root.toList(); event.accepted = true }
        else if (key === Qt.Key_End) { root.cursor = root.messages.length - 1; root.stickToBottom = true; positionViewAtEnd(); event.accepted = true }
      }

      delegate: Item {
        id: row
        required property var modelData
        required property int index

        readonly property var previous: index > 0 ? root.messages[index - 1] : null
        readonly property bool newDay: !previous || !Model.sameDay(previous.date, modelData.date)
        readonly property bool runStart: newDay || !Model.sameRun(previous, modelData)
        readonly property bool showName: !modelData.outgoing && root.chat && root.chat.kind !== "private" && runStart
        readonly property var quoted: modelData.replyTo ? Model.findMessage(root.messages, modelData.replyTo.messageId) : null
        readonly property bool isCursor: index === root.cursor && messageList.activeFocus
        readonly property string label: Model.contentLabel(modelData.content)
        readonly property bool bare: modelData.content.media && (modelData.content.kind === "sticker" || modelData.content.kind === "videoNote")
        property alias mediaItem: mediaView

        width: messageList.width
        height: (newDay ? day.height + Style.space(12) : 0) + (runStart ? Style.space(6) : 0) + bubble.height

        Text {
          id: day
          visible: row.newDay
          anchors.horizontalCenter: parent.horizontalCenter
          y: Style.space(4)
          text: Model.dayLabel(row.modelData.date, root.nowMs)
          color: app.muted
          font.family: app.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Rectangle {
          id: bubble
          readonly property real maxWidth: Math.min(row.width * 0.72, Style.space(640))
          y: row.height - height
          x: row.modelData.outgoing ? row.width - width - Style.space(18) : Style.space(18)
          // Only what is shown counts: a hidden sender name or quote still has an implicit width.
          width: Math.min(maxWidth, Math.max(body.visible ? body.implicitWidth : 0, meta.implicitWidth,
                                            mediaView.visible ? mediaView.implicitWidth : 0,
                                            name.visible ? name.implicitWidth : 0,
                                            kindLabel.visible ? kindLabel.implicitWidth : 0,
                                            quote.visible ? quote.implicitWidth : 0) + Style.space(24))
          height: content.implicitHeight + Style.space(16)
          radius: Style.cornerRadius * 1.5
          // Stickers and round video messages float without a bubble, as in Telegram.
          color: row.bare ? "transparent"
               : (row.modelData.outgoing ? Qt.rgba(app.accent.r, app.accent.g, app.accent.b, 0.2)
                                         : Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, 0.06))
          border.width: row.isCursor ? Math.max(1, Style.space(1.5)) : (row.modelData.id === root.confirmDeleteId ? 1 : 0)
          border.color: row.modelData.id === root.confirmDeleteId ? app.urgent : app.accent

          Column {
            id: content
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(12)
            anchors.topMargin: Style.space(8)
            spacing: Style.space(3)

            Text {
              id: name
              visible: row.showName
              text: row.modelData.senderName || "Unknown"
              textFormat: Text.PlainText
              color: app.accent
              font.family: app.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            Rectangle {
              id: quote
              visible: !!row.modelData.replyTo
              width: parent.width
              implicitWidth: quoteText.implicitWidth + Style.space(12)
              height: quoteText.implicitHeight + Style.space(6)
              color: "transparent"

              Rectangle { width: Style.space(2); height: parent.height; color: app.accent }
              Text {
                id: quoteText
                x: Style.space(8)
                width: parent.width - x
                elide: Text.ElideRight
                maximumLineCount: 2
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                color: app.muted
                font.family: app.fontFamily
                font.pixelSize: Style.font.caption
                text: row.quoted ? (row.quoted.senderName ? row.quoted.senderName + ": " : "") + Model.previewOf(row.quoted) : "Reply to an older message"
              }
            }

            MediaView {
              id: mediaView
              app: root.app
              message: row.modelData
              maxWidth: bubble.maxWidth - Style.space(24)
            }

            Text {
              id: kindLabel
              visible: row.label !== "" && !row.modelData.content.media
              text: row.label
              textFormat: Text.PlainText
              color: app.muted
              font.family: app.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.italic: true
            }

            Text {
              id: body
              visible: text !== ""
              width: Math.min(implicitWidth, bubble.maxWidth - Style.space(24))
              text: row.modelData.content.text || ""
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              color: app.foreground
              font.family: app.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              id: meta
              anchors.right: parent.right
              text: (row.modelData.editDate > 0 ? "edited  " : "") + Model.clock(row.modelData.date)
                + (row.modelData.sending === "pending" ? "  ·  sending" : (row.modelData.sending === "failed" ? "  ·  failed" : ""))
              color: row.modelData.sending === "failed" ? app.urgent : app.muted
              font.family: app.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            onDoubleClicked: root.startReply(row.modelData)
            onClicked: root.cursor = row.index
          }
        }
      }
    }

    // ------------------------------------------------ reply / edit / notice bar
    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: visible ? Style.space(40) : 0
      visible: !!root.replyTo || !!root.editing || root.notice !== ""
      color: Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, 0.04)

      Rectangle { width: Style.space(3); height: parent.height; color: root.notice !== "" && !root.replyTo && !root.editing ? app.muted : app.accent }

      Text {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(18)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(18)
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        textFormat: Text.PlainText
        color: app.foreground
        font.family: app.fontFamily
        font.pixelSize: Style.font.bodySmall
        text: {
          if (root.notice !== "") return root.notice
          if (root.editing) return "Editing   Esc to cancel"
          if (root.replyTo) return "Replying to " + (root.replyTo.outgoing ? "yourself" : (root.replyTo.senderName || "message")) + ": " + Model.previewOf(root.replyTo) + "   Esc to cancel"
          return ""
        }
      }
    }

    // ------------------------------------------------ composer
    Rectangle {
      Layout.fillWidth: true
      // 20 of outer margin and 16 of inner padding around the text, plus room for the caret.
      Layout.preferredHeight: Math.min(Style.space(180), composer.implicitHeight + Style.space(40))
      color: "transparent"

      Rectangle { width: parent.width; height: 1; color: app.border; opacity: 0.35 }

      Rectangle {
        anchors.fill: parent
        anchors.margins: Style.space(10)
        radius: Style.cornerRadius
        color: Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, 0.05)
        border.width: Math.max(1, Style.space(1.5))
        border.color: composer.activeFocus ? app.accent : "transparent"

        Flickable {
          id: composerFlick
          anchors.fill: parent
          anchors.leftMargin: Style.space(12)
          anchors.rightMargin: Style.space(12)
          anchors.topMargin: Style.space(8)
          anchors.bottomMargin: Style.space(8)
          contentHeight: composer.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          TextEdit {
            id: composer
            width: composerFlick.width
            wrapMode: TextEdit.Wrap
            textFormat: TextEdit.PlainText
            color: app.foreground
            selectionColor: app.accent
            font.family: app.fontFamily
            font.pixelSize: Style.font.body
            onCursorRectangleChanged: {
              if (cursorRectangle.y < composerFlick.contentY) composerFlick.contentY = cursorRectangle.y
              else if (cursorRectangle.y + cursorRectangle.height > composerFlick.contentY + composerFlick.height)
                composerFlick.contentY = cursorRectangle.y + cursorRectangle.height - composerFlick.height
            }

            Keys.onPressed: function (event) {
              var key = event.key
              if ((key === Qt.Key_Return || key === Qt.Key_Enter) && !(event.modifiers & Qt.ShiftModifier)) {
                root.send()
                event.accepted = true
              } else if (key === Qt.Key_Escape) {
                if (root.editingId) { root.editingId = 0; composer.text = "" }
                else if (root.replyToId) root.replyToId = 0
                else root.focusMessages()
                event.accepted = true
              } else if (key === Qt.Key_Up && composer.text === "") {
                root.startEdit(Model.lastOwnEditable(root.messages))
                event.accepted = true
              } else if (key === Qt.Key_Tab) {
                root.focusMessages()
                event.accepted = true
              }
            }

            Text {
              visible: composer.text === ""
              text: root.editing ? "Edit message" : "Message   Enter to send, Shift+Enter for a new line"
              color: app.muted
              opacity: 0.7
              font: composer.font
            }
          }
        }
      }
    }
  }
}
