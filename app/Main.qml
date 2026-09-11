import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import "Model.js" as Model

// Omagram's window: sign-in first, then chats on the left and the open chat on the right.
//
// All Telegram work happens in omagramd; this only shows what the service reports and sends
// what you type. Text that comes from Telegram is always shown as plain text.
Scope {
  id: omagram

  readonly property string binDir: decodeURIComponent(String(Qt.resolvedUrl("../bin/")).replace("file://", ""))

  // ---------------------------------------------------------------- theme

  readonly property color background: Qt.rgba(Color.menu.background.r, Color.menu.background.g, Color.menu.background.b, 1)
  readonly property color foreground: Color.menu.text
  readonly property color border: Color.menu.border
  readonly property color accent: Color.accent
  readonly property color muted: Color.muted
  readonly property color urgent: Color.urgent
  readonly property color selected: Color.menu.selectedBackground
  readonly property string fontFamily: Style.font.menuFamily
  readonly property string glyphFamily: Style.font.family

  // ---------------------------------------------------------------- state

  property var auth: ({ state: "connecting" })
  property var chats: []
  property var messages: ({})
  property int messagesRevision: 0
  property real openChatId: 0
  readonly property var openChat: Model.findChat(omagram.chats, omagram.openChatId)
  property real meId: 0
  property var noOlder: ({})
  property bool loadingOlder: false
  property real nowMs: Date.now()

  function messagesFor(chatId) {
    omagram.messagesRevision
    return omagram.messages[chatId] || []
  }

  function setMessages(chatId, list) {
    omagram.messages[chatId] = list
    omagram.messagesRevision++
  }

  Timer {
    interval: 30000
    repeat: true
    running: true
    onTriggered: omagram.nowMs = Date.now()
  }

  // ---------------------------------------------------------------- service

  OmagramClient {
    id: service
    binDir: omagram.binDir

    onHello: function (result) {
      omagram.auth = result.auth || { state: "starting" }
      omagram.meId = result.meId || 0
      omagram.chats = Model.sortChats(result.chats || [])
      if (omagram.auth.state === "ready" && omagram.openChatId) omagram.openChatById(omagram.openChatId, true)
    }

    onServiceEvent: function (name, message) { omagram.onEvent(name, message) }

    onConnectedChanged: if (!connected) omagram.auth = { state: "connecting" }
  }

  function onEvent(name, e) {
    if (name === "auth") {
      omagram.auth = e.auth
      if (e.auth.state !== "ready") {
        omagram.chats = []
        omagram.messages = ({})
        omagram.openChatId = 0
      }
    } else if (name === "me") {
      omagram.meId = e.meId || 0
    } else if (name === "chat") {
      omagram.chats = Model.upsertChat(omagram.chats, e.chat, "main")
    } else if (name === "message") {
      var m = e.message
      if (omagram.messages[m.chatId]) {
        omagram.setMessages(m.chatId, Model.mergeMessages(omagram.messages[m.chatId], [m]))
        if (m.chatId === omagram.openChatId && !m.outgoing && window.visible) omagram.markRead(m.chatId, [m.id])
      }
    } else if (name === "messageSent" || name === "messageFailed") {
      var sent = e.message
      if (omagram.messages[sent.chatId]) omagram.setMessages(sent.chatId, Model.replaceMessage(omagram.messages[sent.chatId], e.oldMessageId, sent))
    } else if (name === "messageContent") {
      if (omagram.messages[e.chatId]) omagram.setMessages(e.chatId, Model.patchMessage(omagram.messages[e.chatId], e.messageId, { content: e.content }))
    } else if (name === "messageEdited") {
      if (omagram.messages[e.chatId]) omagram.setMessages(e.chatId, Model.patchMessage(omagram.messages[e.chatId], e.messageId, { editDate: e.editDate }))
    } else if (name === "messagesDeleted") {
      if (omagram.messages[e.chatId]) omagram.setMessages(e.chatId, Model.removeMessages(omagram.messages[e.chatId], e.messageIds))
    }
  }

  function openChatById(chatId, force) {
    if (!chatId || (chatId === omagram.openChatId && !force)) return
    if (omagram.openChatId && omagram.openChatId !== chatId) service.request("chat.close", { chatId: omagram.openChatId })
    omagram.openChatId = chatId
    service.request("chat.open", { chatId: chatId })
    omagram.loadHistory(chatId, 0)
  }

  function loadHistory(chatId, fromMessageId) {
    if (fromMessageId && (omagram.loadingOlder || omagram.noOlder[chatId])) return
    if (fromMessageId) omagram.loadingOlder = true
    service.request("chat.history", { chatId: chatId, fromMessageId: fromMessageId, limit: 50 }, function (answer) {
      if (fromMessageId) omagram.loadingOlder = false
      if (!answer.ok) return
      var incoming = answer.result.messages || []
      var before = (omagram.messages[chatId] || []).length
      var merged = Model.mergeMessages(omagram.messages[chatId] || [], incoming)
      omagram.setMessages(chatId, merged)
      if (fromMessageId && merged.length === before) omagram.noOlder[chatId] = true
      // TDLib answers the first page from its local cache, which may be short.
      if (!fromMessageId && merged.length > 0 && merged.length < 20) omagram.loadHistory(chatId, Model.oldestId(merged))
      if (chatId === omagram.openChatId) {
        var chat = omagram.openChat
        if (chat && chat.unread > 0) omagram.markRead(chatId, Model.incomingIds(merged, 100))
      }
    })
  }

  function markRead(chatId, ids) {
    if (ids.length) service.request("chat.read", { chatId: chatId, messageIds: ids })
  }

  // ---------------------------------------------------------------- window

  FloatingWindow {
    id: window
    title: omagram.openChat ? omagram.openChat.title + " — Omagram" : "Omagram"
    color: omagram.background
    implicitWidth: 1100
    implicitHeight: 760
    minimumSize: Qt.size(640, 480)
    visible: true

    // Closing the window ends this process; the service keeps the session.
    onVisibleChanged: if (!visible) Qt.quit()

    Loader {
      anchors.fill: parent
      focus: true
      sourceComponent: {
        var s = omagram.auth.state
        if (s === "ready") return mainView
        if (s === "needCredentials") return setupView
        if (s === "phone" || s === "code" || s === "password" || s === "qr") return loginView
        return statusView
      }
      onLoaded: if (item) item.forceActiveFocus()
    }
  }

  Component {
    id: statusView
    Item {
      Column {
        anchors.centerIn: parent
        width: Math.min(parent.width - 80, 520)
        spacing: Style.spacing.md

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: "Omagram"
          color: omagram.foreground
          font.family: omagram.fontFamily
          font.pixelSize: Style.font.displayLarge
          font.bold: true
        }
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          color: omagram.auth.state === "error" || omagram.auth.state === "noLibrary" ? omagram.urgent : omagram.muted
          font.family: omagram.fontFamily
          font.pixelSize: Style.font.body
          text: {
            var s = omagram.auth.state
            if (s === "connecting") return "Connecting to Omagram's service…"
            if (s === "starting") return "Starting…"
            if (s === "noLibrary") return "TDLib is not installed yet. Build it with:\n" + omagram.binDir + "omagram-build-tdlib"
            if (s === "loggingOut") return "Signing out…"
            if (s === "closing" || s === "closed") return "Closing the session…"
            if (s === "unsupported") return "This sign-in step is not supported yet. Finish it in an official Telegram app, then come back."
            return omagram.auth.reason || "Something went wrong."
          }
        }
      }
    }
  }

  Component {
    id: setupView
    SetupView { app: omagram; client: service }
  }

  Component {
    id: loginView
    LoginView { app: omagram; client: service }
  }

  Component {
    id: mainView
    FocusScope {
      id: mainScope

      function focusComposer() { chatView.focusComposer() }

      Shortcut { sequences: ["Ctrl+K", "Ctrl+F"]; onActivated: chatList.focusSearch() }
      Shortcut { sequence: "Alt+Up"; onActivated: chatList.step(-1) }
      Shortcut { sequence: "Alt+Down"; onActivated: chatList.step(1) }
      Shortcut { sequence: "Ctrl+1"; onActivated: chatList.focusList() }
      Shortcut { sequence: "Ctrl+2"; onActivated: chatView.focusMessages() }
      Shortcut { sequence: "Ctrl+3"; onActivated: chatView.focusComposer() }

      Component.onCompleted: chatList.focusList()

      RowLayout {
        anchors.fill: parent
        spacing: 0

        ChatList {
          id: chatList
          app: omagram
          Layout.preferredWidth: Math.max(280, Math.min(380, mainScope.width * 0.32))
          Layout.fillHeight: true
          chats: omagram.chats
          openChatId: omagram.openChatId
          nowMs: omagram.nowMs
          onActivated: function (chatId) {
            omagram.openChatById(chatId, false)
            chatView.focusComposer()
          }
          onToChat: chatView.focusComposer()
        }

        Rectangle {
          Layout.preferredWidth: 1
          Layout.fillHeight: true
          color: omagram.border
          opacity: 0.35
        }

        ChatView {
          id: chatView
          app: omagram
          client: service
          Layout.fillWidth: true
          Layout.fillHeight: true
          chat: omagram.openChat
          messages: omagram.openChat ? omagram.messagesFor(omagram.openChatId) : []
          nowMs: omagram.nowMs
          onLoadOlder: if (omagram.openChatId) omagram.loadHistory(omagram.openChatId, Model.oldestId(omagram.messagesFor(omagram.openChatId)))
          onToList: chatList.focusList()
        }
      }
    }
  }
}
