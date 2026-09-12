import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "../app"
import "../app/Model.js" as Model
import "../app/Keymap.js" as Keymap

// Quick switch and reply, summoned with a key: find a chat by typing, read its latest
// messages, answer, and be back where you were.
//
//   omarchy-shell shell toggle reidenxerx.omagram '{}'              find a chat
//   omarchy-shell shell toggle reidenxerx.omagram '{"chatId":<id>}'  reply to that chat
//
// Type to search · ↑/↓ or Ctrl+J/K choose · Enter reply · Ctrl+O open in the window ·
// Esc goes back a step, then closes. Text from Telegram is only ever shown as plain text.
Item {
  id: overlay

  property var shell: null
  property var manifest: null
  property var service: null
  property bool opened: false

  readonly property string pluginId: (manifest && manifest.id) || "reidenxerx.omagram"

  // ---------------------------------------------------------------- theme

  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property color selected: Color.menu.selectedBackground
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
  readonly property string fontFamily: Style.font.menuFamily

  // ---------------------------------------------------------------- state

  readonly property bool ready: !!overlay.service && overlay.service.ready
  readonly property string unavailableText: !overlay.service ? "Omagram's service is not loaded"
    : (!overlay.service.connected ? "Connecting to Omagram…" : "Omagram is not signed in")

  // The shell hands `service` over when this overlay loads, which can be before the plugin's
  // service entry exists; look it up again until it is there.
  function findService() {
    if (!overlay.service && overlay.shell && typeof overlay.shell.serviceFor === "function")
      overlay.service = overlay.shell.serviceFor(overlay.pluginId)
  }

  Timer {
    interval: 1000
    repeat: true
    running: !overlay.service
    triggeredOnStart: true
    onTriggered: overlay.findService()
  }
  readonly property var chats: overlay.ready ? overlay.service.chats : []
  property string query: ""
  readonly property var results: Model.filterChats(overlay.chats, overlay.query).slice(0, 60)
  property int cursor: 0
  readonly property var highlighted: overlay.results[overlay.cursor] || null
  property real replyChatId: 0
  readonly property var replyChat: overlay.replyChatId ? Model.findChat(overlay.chats, overlay.replyChatId) : null
  readonly property real shownChatId: overlay.replyChatId || (overlay.highlighted ? overlay.highlighted.id : 0)
  readonly property var shownChat: overlay.replyChat || overlay.highlighted
  property var history: []
  property real historyChatId: 0
  property int historySerial: 0
  property bool sending: false
  property string status: ""
  property real nowMs: Date.now()

  onQueryChanged: overlay.cursor = 0
  onShownChatIdChanged: historyDelay.restart()

  // ---------------------------------------------------------------- shell contract

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) { payload = {} }
    overlay.findService()
    overlay.opened = true
    overlay.nowMs = Date.now()
    overlay.status = ""
    overlay.sending = false
    overlay.replyChatId = 0
    overlay.cursor = 0
    search.text = ""
    composer.text = ""
    var id = Number(payload.chatId)
    if (Number.isSafeInteger(id) && id !== 0) overlay.reply(id)
    else Qt.callLater(function () { search.forceActiveFocus() })
    // The chat shown may be the same one as last time, so no change would ask for it.
    historyDelay.restart()
  }

  function close() {
    overlay.opened = false
    overlay.replyChatId = 0
    overlay.sending = false
  }

  function dismiss() {
    overlay.close()
    if (overlay.shell && typeof overlay.shell.hide === "function") overlay.shell.hide(overlay.pluginId)
  }

  function toggle() {
    if (overlay.opened) overlay.dismiss()
    else overlay.open("{}")
  }

  // ---------------------------------------------------------------- actions

  function move(delta) {
    if (overlay.results.length === 0) return
    overlay.cursor = Math.max(0, Math.min(overlay.results.length - 1, overlay.cursor + delta))
    chatList.positionViewAtIndex(overlay.cursor, ListView.Contain)
  }

  function reply(chatId) {
    if (!chatId) return
    var index = Model.indexOfChat(overlay.results, chatId)
    if (index >= 0) {
      overlay.cursor = index
      chatList.positionViewAtIndex(index, ListView.Contain)
    }
    overlay.replyChatId = chatId
    overlay.status = ""
    Qt.callLater(function () { composer.forceActiveFocus() })
  }

  function back() {
    overlay.replyChatId = 0
    overlay.status = ""
    search.forceActiveFocus()
  }

  function openInWindow() {
    if (!overlay.service) return
    if (overlay.shownChatId) overlay.service.openChat(overlay.shownChatId)
    else overlay.service.openWindow()
    overlay.dismiss()
  }

  function send() {
    var text = composer.text
    if (!overlay.replyChatId || overlay.sending || text.trim() === "" || !overlay.ready) return
    overlay.sending = true
    overlay.service.sendText(overlay.replyChatId, text, function (answer) {
      overlay.sending = false
      if (answer.ok) {
        composer.text = ""
        overlay.dismiss()
      } else {
        overlay.status = answer.error || "Could not send"
        composer.forceActiveFocus()
      }
    })
  }

  // ---------------------------------------------------------------- history

  // A short pause, so holding an arrow key does not ask for every chat it passes.
  Timer {
    id: historyDelay
    interval: 120
    onTriggered: overlay.loadHistory()
  }

  function loadHistory() {
    var chatId = overlay.shownChatId
    var serial = ++overlay.historySerial
    if (!chatId || !overlay.ready || !overlay.opened) {
      overlay.history = []
      overlay.historyChatId = 0
      return
    }
    if (chatId !== overlay.historyChatId) overlay.history = []
    overlay.fetchHistory(chatId, 0, serial)
  }

  // TDLib answers the first page from its local cache, which can hold a single message; one
  // more page from the oldest message fills the pane.
  function fetchHistory(chatId, fromMessageId, serial) {
    overlay.service.request("chat.history", { chatId: chatId, fromMessageId: fromMessageId, limit: 20 }, function (answer) {
      if (serial !== overlay.historySerial) return   // a newer chat was chosen meanwhile
      overlay.historyChatId = chatId
      var incoming = answer.ok ? (answer.result.messages || []) : []
      var merged = Model.mergeMessages(fromMessageId ? overlay.history : [], incoming)
      overlay.history = merged
      messageList.positionViewAtEnd()
      if (!fromMessageId && merged.length > 0 && merged.length < 12) overlay.fetchHistory(chatId, Model.oldestId(merged), serial)
    })
  }

  // The history's rows, one per message id, edited in place as in the window's chat: a new array as
  // the model rebuilt every row and lost the view's place for a frame.
  ListModel { id: historyRows }
  property var historyIds: []
  onHistoryChanged: overlay.historyIds = Model.syncRows(historyRows, overlay.historyIds, overlay.history)

  Connections {
    target: overlay.service
    ignoreUnknownSignals: true

    function onMessageEvent(name, e) {
      if (!overlay.opened || !overlay.historyChatId) return
      if (e.message && e.message.sendAt) return   // scheduled: part of no history until it goes out
      if (name === "message" && e.message.chatId === overlay.historyChatId) {
        overlay.history = Model.mergeMessages(overlay.history, [e.message])
        messageList.positionViewAtEnd()
      } else if ((name === "messageSent" || name === "messageFailed") && e.message.chatId === overlay.historyChatId) {
        overlay.history = Model.replaceMessage(overlay.history, e.oldMessageId, e.message)
      } else if (name === "messagesDeleted" && e.chatId === overlay.historyChatId) {
        overlay.history = Model.removeMessages(overlay.history, e.messageIds)
      }
    }
  }

  // ---------------------------------------------------------------- ui

  PanelWindow {
    id: surface
    visible: overlay.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omagram-quick-reply"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: overlay.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.35)
    }

    MouseArea {
      anchors.fill: parent
      onClicked: overlay.dismiss()
    }

    BorderSurface {
      id: card
      width: Math.min(Style.space(860), surface.width - Style.space(64))
      height: Math.min(Style.space(560), surface.height - Style.space(96))
      anchors.centerIn: parent
      radius: Style.cornerRadius
      color: overlay.background
      borderSpec: overlay.borderSpec
      padding: Style.spacing.panelPadding

      // Clicks on the card stay on the card.
      MouseArea { anchors.fill: parent }

      ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.md

        // ------------------------------------------------ search
        Item {
          Layout.fillWidth: true
          implicitHeight: Style.space(34)

          TextInput {
            id: search
            anchors.fill: parent
            verticalAlignment: TextInput.AlignVCenter
            color: overlay.foreground
            selectionColor: overlay.selected
            font.family: overlay.fontFamily
            font.pixelSize: Style.font.body
            clip: true
            onTextChanged: overlay.query = text

            Keys.onPressed: function (event) {
              var keys = overlay.service ? overlay.service.shortcuts : ({})
              function is(id) { return Keymap.matchesInText(keys, id, event) }
              if (is("quick.down")) overlay.move(1)
              else if (is("quick.up")) overlay.move(-1)
              else if (is("quick.pageDown")) overlay.move(8)
              else if (is("quick.pageUp")) overlay.move(-8)
              else if (is("quick.reply")) { if (overlay.highlighted) overlay.reply(overlay.highlighted.id) }
              else if (is("quick.openInWindow")) overlay.openInWindow()
              else if (is("quick.close")) {
                if (search.text !== "") search.text = ""
                else overlay.dismiss()
              }
              else return
              event.accepted = true
            }

            Text {
              anchors.fill: parent
              verticalAlignment: Text.AlignVCenter
              visible: search.text === ""
              text: overlay.ready ? "Find a chat" : overlay.unavailableText
              color: overlay.foreground
              opacity: 0.4
              font: search.font
            }
          }

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1
            color: overlay.foreground
            opacity: 0.12
          }
        }

        RowLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: Style.spacing.md

          // ------------------------------------------------ chats
          ListView {
            id: chatList

            WheelScroll { view: chatList }
            Layout.preferredWidth: Math.round(card.width * 0.36)
            Layout.fillHeight: true
            clip: true
            model: overlay.results
            currentIndex: overlay.cursor
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
              id: chatRow
              required property var modelData
              required property int index
              width: ListView.view.width
              height: Style.space(40)
              radius: Style.cornerRadius
              color: overlay.cursor === index ? overlay.selected
                   : (chatArea.containsMouse ? Style.hoverFillFor(overlay.foreground, overlay.accent) : "transparent")

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(6)

                Text {
                  Layout.fillWidth: true
                  text: chatRow.modelData.title || ""
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  color: overlay.foreground
                  font.family: overlay.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: chatRow.modelData.unread > 0 && !chatRow.modelData.muted
                }

                Text {
                  visible: chatRow.modelData.unread > 0
                  text: chatRow.modelData.unread > 999 ? "999+" : String(chatRow.modelData.unread)
                  color: chatRow.modelData.muted ? overlay.foreground : overlay.accent
                  opacity: chatRow.modelData.muted ? 0.5 : 1
                  font.family: overlay.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }

              MouseArea {
                id: chatArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  overlay.cursor = chatRow.index
                  overlay.reply(chatRow.modelData.id)
                }
              }
            }

            Text {
              anchors.centerIn: parent
              visible: overlay.results.length === 0
              text: overlay.ready ? "No chat matches" : ""
              color: overlay.foreground
              opacity: 0.45
              font.family: overlay.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Rectangle {
            Layout.fillHeight: true
            implicitWidth: 1
            color: overlay.foreground
            opacity: 0.12
          }

          // ------------------------------------------------ the chat
          ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Style.space(6)

            Text {
              Layout.fillWidth: true
              text: overlay.shownChat ? overlay.shownChat.title : ""
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: overlay.foreground
              font.family: overlay.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }

            ListView {
              id: messageList

              WheelScroll { view: messageList }
              Layout.fillWidth: true
              Layout.fillHeight: true
              clip: true
              spacing: Style.space(6)
              model: historyRows
              boundsBehavior: Flickable.StopAtBounds

              delegate: Column {
                id: line
                required property real mid
                required property int index
                readonly property var found: Model.rowMessage(overlay.history, line.index, line.mid)
                property var kept: null
                onFoundChanged: if (line.found) line.kept = line.found
                Component.onCompleted: line.kept = line.found
                readonly property var message: line.found || line.kept || Model.NO_MESSAGE
                width: ListView.view.width
                spacing: 0

                Text {
                  width: parent.width
                  text: (line.message.outgoing ? "You" : (line.message.senderName || (overlay.shownChat ? overlay.shownChat.title : "")))
                        + "  ·  " + Model.clock(line.message.date)
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  color: line.message.outgoing ? overlay.foreground : overlay.accent
                  opacity: line.message.outgoing ? 0.55 : 0.9
                  font.family: overlay.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  width: parent.width
                  text: Model.previewOf(line.message)
                  textFormat: Text.PlainText
                  wrapMode: Text.Wrap
                  maximumLineCount: 6
                  elide: Text.ElideRight
                  color: overlay.foreground
                  font.family: overlay.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }

            Text {
              Layout.fillWidth: true
              visible: overlay.status !== ""
              text: overlay.status
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: overlay.urgent
              font.family: overlay.fontFamily
              font.pixelSize: Style.font.caption
            }

            // ---------------------------------------------- composer
            Rectangle {
              Layout.fillWidth: true
              implicitHeight: Math.min(Style.space(120), composer.contentHeight + Style.space(16))
              radius: Style.cornerRadius
              color: "transparent"
              border.width: 1
              border.color: composer.activeFocus ? overlay.accent : Qt.rgba(overlay.foreground.r, overlay.foreground.g, overlay.foreground.b, 0.2)

              TextEdit {
                id: composer
                anchors.fill: parent
                anchors.margins: Style.space(8)
                wrapMode: TextEdit.Wrap
                textFormat: TextEdit.PlainText
                color: overlay.foreground
                selectionColor: overlay.selected
                font.family: overlay.fontFamily
                font.pixelSize: Style.font.bodySmall
                readOnly: overlay.sending

                Keys.onPressed: function (event) {
                  var keys = overlay.service ? overlay.service.shortcuts : ({})
                  function is(id) { return Keymap.matchesInText(keys, id, event) }
                  if (is("quickMessage.send")) {
                    if (overlay.replyChatId) overlay.send()
                    else if (overlay.highlighted) overlay.reply(overlay.highlighted.id)
                  }
                  else if (is("quickMessage.back")) overlay.back()
                  else if (is("quickMessage.openInWindow")) overlay.openInWindow()
                  else return
                  event.accepted = true
                }

                Text {
                  anchors.fill: parent
                  visible: composer.text === ""
                  text: overlay.sending ? "Sending…"
                      : (overlay.replyChatId ? "Message  ·  Enter sends, Shift+Enter new line, Esc back"
                                             : "Enter to reply  ·  Ctrl+O opens in Omagram")
                  color: overlay.foreground
                  opacity: 0.4
                  elide: Text.ElideRight
                  font: composer.font
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.IBeamCursor
                onClicked: {
                  if (!overlay.replyChatId && overlay.highlighted) overlay.reply(overlay.highlighted.id)
                  else composer.forceActiveFocus()
                }
              }
            }
          }
        }
      }
    }
  }
}
