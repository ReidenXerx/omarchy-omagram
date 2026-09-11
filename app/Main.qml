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
  id: app

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
  readonly property var openChat: Model.findChat(app.chats, app.openChatId)
  property real meId: 0
  property var noOlder: ({})
  property bool loadingOlder: false
  property real nowMs: Date.now()

  function messagesFor(chatId) {
    app.messagesRevision
    return app.messages[chatId] || []
  }

  function setMessages(chatId, list) {
    app.messages[chatId] = list
    app.messagesRevision++
  }

  Timer {
    interval: 30000
    repeat: true
    running: true
    onTriggered: app.nowMs = Date.now()
  }

  // ---------------------------------------------------------------- service

  OmagramClient {
    id: client
    binDir: app.binDir

    onHello: function (result) {
      app.auth = result.auth || { state: "starting" }
      app.meId = result.meId || 0
      app.chats = Model.sortChats(result.chats || [])
      if (app.auth.state === "ready" && app.openChatId) app.openChatById(app.openChatId, true)
    }

    onServiceEvent: function (name, message) { app.onEvent(name, message) }

    onConnectedChanged: if (!connected) app.auth = { state: "connecting" }
  }

  function onEvent(name, e) {
    if (name === "auth") {
      app.auth = e.auth
      if (e.auth.state !== "ready") {
        app.chats = []
        app.messages = ({})
        app.openChatId = 0
      }
    } else if (name === "chat") {
      app.chats = Model.upsertChat(app.chats, e.chat, "main")
    } else if (name === "message") {
      var m = e.message
      if (app.messages[m.chatId]) {
        app.setMessages(m.chatId, Model.mergeMessages(app.messages[m.chatId], [m]))
        if (m.chatId === app.openChatId && !m.outgoing && window.active) app.markRead(m.chatId, [m.id])
      }
    } else if (name === "messageSent" || name === "messageFailed") {
      var sent = e.message
      if (app.messages[sent.chatId]) app.setMessages(sent.chatId, Model.replaceMessage(app.messages[sent.chatId], e.oldMessageId, sent))
    } else if (name === "messageContent") {
      if (app.messages[e.chatId]) app.setMessages(e.chatId, Model.patchMessage(app.messages[e.chatId], e.messageId, { content: e.content }))
    } else if (name === "messageEdited") {
      if (app.messages[e.chatId]) app.setMessages(e.chatId, Model.patchMessage(app.messages[e.chatId], e.messageId, { editDate: e.editDate }))
    } else if (name === "messagesDeleted") {
      if (app.messages[e.chatId]) app.setMessages(e.chatId, Model.removeMessages(app.messages[e.chatId], e.messageIds))
    }
  }

  function openChatById(chatId, force) {
    if (!chatId || (chatId === app.openChatId && !force)) return
    if (app.openChatId && app.openChatId !== chatId) client.request("chat.close", { chatId: app.openChatId })
    app.openChatId = chatId
    client.request("chat.open", { chatId: chatId })
    app.loadHistory(chatId, 0)
  }

  function loadHistory(chatId, fromMessageId) {
    if (fromMessageId && (app.loadingOlder || app.noOlder[chatId])) return
    if (fromMessageId) app.loadingOlder = true
    client.request("chat.history", { chatId: chatId, fromMessageId: fromMessageId, limit: 50 }, function (answer) {
      if (fromMessageId) app.loadingOlder = false
      if (!answer.ok) return
      var incoming = answer.result.messages || []
      var before = (app.messages[chatId] || []).length
      var merged = Model.mergeMessages(app.messages[chatId] || [], incoming)
      app.setMessages(chatId, merged)
      if (fromMessageId && merged.length === before) app.noOlder[chatId] = true
      // TDLib answers the first page from its local cache, which may be short.
      if (!fromMessageId && merged.length > 0 && merged.length < 20) app.loadHistory(chatId, Model.oldestId(merged))
      if (chatId === app.openChatId) {
        var chat = app.openChat
        if (chat && chat.unread > 0) app.markRead(chatId, Model.incomingIds(merged, 100))
      }
    })
  }

  function markRead(chatId, ids) {
    if (ids.length) client.request("chat.read", { chatId: chatId, messageIds: ids })
  }

  // ---------------------------------------------------------------- window

  FloatingWindow {
    id: window
    title: app.openChat ? app.openChat.title + " — Omagram" : "Omagram"
    color: app.background
    implicitWidth: 1100
    implicitHeight: 760
    minimumSize: Qt.size(640, 480)
    visible: true

    // Closing the window ends this process; the service keeps the session.
    onVisibleChanged: if (!visible) Qt.quit()
    onActiveChanged: {
      if (active && app.openChatId && app.openChat && app.openChat.unread > 0)
        app.markRead(app.openChatId, Model.incomingIds(app.messagesFor(app.openChatId), 100))
    }

    Loader {
      anchors.fill: parent
      focus: true
      sourceComponent: {
        var s = app.auth.state
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
          color: app.foreground
          font.family: app.fontFamily
          font.pixelSize: Style.font.displayLarge
          font.bold: true
        }
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          color: app.auth.state === "error" || app.auth.state === "noLibrary" ? app.urgent : app.muted
          font.family: app.fontFamily
          font.pixelSize: Style.font.body
          text: {
            var s = app.auth.state
            if (s === "connecting") return "Connecting to Omagram's service…"
            if (s === "starting") return "Starting…"
            if (s === "noLibrary") return "TDLib is not installed yet. Build it with:\n" + app.binDir + "omagram-build-tdlib"
            if (s === "loggingOut") return "Signing out…"
            if (s === "closing" || s === "closed") return "Closing the session…"
            if (s === "unsupported") return "This sign-in step is not supported yet. Finish it in an official Telegram app, then come back."
            return app.auth.reason || "Something went wrong."
          }
        }
      }
    }
  }

  Component {
    id: setupView
    SetupView { app: app; client: client }
  }

  Component {
    id: loginView
    LoginView { app: app; client: client }
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
          app: app
          Layout.preferredWidth: Math.max(280, Math.min(380, mainScope.width * 0.32))
          Layout.fillHeight: true
          chats: app.chats
          openChatId: app.openChatId
          nowMs: app.nowMs
          onActivated: function (chatId) {
            app.openChatById(chatId, false)
            chatView.focusComposer()
          }
          onToChat: chatView.focusComposer()
        }

        Rectangle {
          Layout.preferredWidth: 1
          Layout.fillHeight: true
          color: app.border
          opacity: 0.35
        }

        ChatView {
          id: chatView
          app: app
          client: client
          Layout.fillWidth: true
          Layout.fillHeight: true
          chat: app.openChat
          messages: app.openChat ? app.messagesFor(app.openChatId) : []
          nowMs: app.nowMs
          onLoadOlder: if (app.openChatId) app.loadHistory(app.openChatId, Model.oldestId(app.messagesFor(app.openChatId)))
          onToList: chatList.focusList()
        }
      }
    }
  }
}
