import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import "Model.js" as Model
import "Keymap.js" as Keymap

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
  property var recording: ({ state: "idle" })   // a voice message being recorded, as the service reports it

  // Your shortcuts (only what differs from Keymap.js's defaults) and the global ones.
  property var shortcuts: ({})

  // Live details: who is typing where (they expire on their own), and people's online status.
  property var chatActions: ({})
  property var userStatuses: ({})
  property real clockMs: Date.now()
  signal pinnedChanged(real chatId)

  Timer {
    interval: 1000
    repeat: true
    running: Object.keys(omagram.chatActions).length > 0
    onTriggered: omagram.clockMs = Date.now()
  }
  property var globalShortcuts: ({})
  property var globalStatus: ({})
  property bool settingsOpen: false

  function applySettings(view) {
    if (!view || !view.settings) return
    omagram.shortcuts = view.settings.shortcuts || ({})
    omagram.globalShortcuts = view.settings.globalShortcuts || ({})
    omagram.globalStatus = view.globalStatus || ({})
  }
  property var chats: []
  property var messages: ({})
  property int messagesRevision: 0
  property real openChatId: 0
  readonly property var openChat: Model.findChat(omagram.chats, omagram.openChatId)
  property real meId: 0
  property var noOlder: ({})
  property bool loadingOlder: false
  property real nowMs: Date.now()

  // Every known chat, whatever list it is in; the tabs pick theirs with Model.chatsIn().
  property var folders: []
  property int mainPosition: 0
  property string listKey: "main"
  property var loadedLists: ({})
  readonly property var tabs: Model.listTabs(omagram.folders, omagram.mainPosition)
  readonly property var listChats: Model.chatsIn(omagram.chats, omagram.listKey)

  // Whether you are looking at Omagram: the focused window's app id is ours. The service keeps
  // the chat you are reading out of desktop notifications, and new messages count as read only
  // while this is true.
  readonly property bool windowFocused: !!(Hyprland.activeToplevel && Hyprland.activeToplevel.wayland
                                          && Hyprland.activeToplevel.wayland.appId === "omagram")
  readonly property real focusedChatId: omagram.windowFocused ? omagram.openChatId : 0
  onFocusedChatIdChanged: if (omagram.auth.state === "ready") service.request("ui.focus", { chatId: omagram.focusedChatId })
  onWindowFocusedChanged: if (omagram.windowFocused) omagram.markOpenChatRead()

  // A notification's Open or Reply, or `omagram --chat <id>`.
  function openFromService(target) {
    if (!target || !target.chatId) return
    omagram.openChatById(target.chatId, false)
    if (screen.item && screen.item.focusComposer) Qt.callLater(function () { screen.item.focusComposer() })
  }

  property var files: ({})
  property int filesRevision: 0
  property var lottieCache: ({})

  // A file's latest known state: from a download answer or a progress event if there has
  // been one, otherwise as its message described it.
  function fileState(file) {
    omagram.filesRevision
    if (!file) return null
    return omagram.files[file.id] || file
  }

  function setFile(view) {
    if (!view || !view.id) return
    if (!omagram.files[view.id] && Object.keys(omagram.files).length >= 4000) {
      // Bounded: only downloads still running are kept; the rest come back from their messages.
      var kept = {}
      for (var id in omagram.files) if (omagram.files[id].active) kept[id] = omagram.files[id]
      omagram.files = kept
    }
    omagram.files[view.id] = view
    omagram.filesRevision++
  }

  function download(fileId, priority) {
    service.request("file.download", { fileId: fileId, priority: priority || 16 }, function (answer) {
      if (answer.ok) omagram.setFile(answer.result)
    })
  }

  // Animated stickers need their Lottie JSON, which the service unpacks once per sticker.
  function lottiePath(fileId, callback) {
    if (omagram.lottieCache[fileId]) { callback(omagram.lottieCache[fileId]); return }
    service.request("sticker.lottie", { fileId: fileId }, function (answer) {
      var path = answer.ok && answer.result && answer.result.path ? answer.result.path : ""
      if (path) {
        if (Object.keys(omagram.lottieCache).length >= 2000) omagram.lottieCache = ({})
        omagram.lottieCache[fileId] = path
      }
      callback(path)
    })
  }

  function messagesFor(chatId) {
    omagram.messagesRevision
    return omagram.messages[chatId] || []
  }

  function setMessages(chatId, list) {
    omagram.messages[chatId] = list
    omagram.messagesRevision++
  }

  // The histories of the last 30 chats opened stay loaded; older ones are let go, and load
  // again when their chat is opened.
  property var historyOrder: []
  function keepMessagesOf(chatId) {
    var order = omagram.historyOrder.filter(function (id) { return id !== chatId })
    order.push(chatId)
    while (order.length > 30) {
      var gone = order.shift()
      delete omagram.messages[gone]
      delete omagram.noOlder[gone]
    }
    omagram.historyOrder = order
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
    window: true

    onHello: function (result) {
      omagram.auth = result.auth || { state: "starting" }
      omagram.meId = result.meId || 0
      omagram.applySettings(result)
      omagram.chats = result.allChats || result.chats || []
      omagram.folders = result.folders || []
      omagram.mainPosition = result.mainPosition || 0
      omagram.loadedLists = ({})
      if (omagram.auth.state === "ready" && omagram.openChatId) omagram.openChatById(omagram.openChatId, true)
      if (omagram.auth.state === "ready") {
        service.request("ui.focus", { chatId: omagram.focusedChatId })
        omagram.openFromService(result.open)
      }
    }

    onServiceEvent: function (name, message) { omagram.onEvent(name, message) }

    onConnectedChanged: {
      if (connected) return
      omagram.auth = { state: "connecting" }
      omagram.recording = { state: "idle" }
    }
  }

  function onEvent(name, e) {
    if (name === "auth") {
      omagram.auth = e.auth
      if (e.auth.state !== "ready") {
        omagram.chats = []
        omagram.messages = ({})
        omagram.openChatId = 0
        omagram.folders = []
        omagram.listKey = "main"
      }
    } else if (name === "open") {
      omagram.openFromService(e)
    } else if (name === "folders") {
      omagram.folders = e.folders || []
      omagram.mainPosition = e.mainPosition || 0
      if (!omagram.tabs.some(function (t) { return t.key === omagram.listKey })) omagram.listKey = "main"
    } else if (name === "file") {
      omagram.setFile(e.file)
    } else if (name === "me") {
      omagram.meId = e.meId || 0
    } else if (name === "chat") {
      omagram.chats = Model.upsertKnown(omagram.chats, e.chat)
    } else if (name === "message") {
      var m = e.message
      if (omagram.messages[m.chatId]) {
        omagram.setMessages(m.chatId, Model.mergeMessages(omagram.messages[m.chatId], [m]))
        if (m.chatId === omagram.openChatId && !m.outgoing && omagram.windowFocused) omagram.markRead(m.chatId, [m.id])
      }
    } else if (name === "messageSent" || name === "messageFailed") {
      var sent = e.message
      if (omagram.messages[sent.chatId]) omagram.setMessages(sent.chatId, Model.replaceMessage(omagram.messages[sent.chatId], e.oldMessageId, sent))
    } else if (name === "messageContent") {
      if (omagram.messages[e.chatId]) omagram.setMessages(e.chatId, Model.patchMessage(omagram.messages[e.chatId], e.messageId, { content: e.content }))
    } else if (name === "messageEdited") {
      if (omagram.messages[e.chatId]) omagram.setMessages(e.chatId, Model.patchMessage(omagram.messages[e.chatId], e.messageId, { editDate: e.editDate }))
    } else if (name === "messageInteraction") {
      if (omagram.messages[e.chatId])
        omagram.setMessages(e.chatId, Model.patchMessage(omagram.messages[e.chatId], e.messageId, { reactions: e.reactions, views: e.views }))
    } else if (name === "messagePinned") {
      if (omagram.messages[e.chatId])
        omagram.setMessages(e.chatId, Model.patchMessage(omagram.messages[e.chatId], e.messageId, { pinned: e.pinned }))
      omagram.pinnedChanged(e.chatId)
    } else if (name === "poll") {
      for (var pollChat in omagram.messages) {
        var polled = Model.updatePoll(omagram.messages[pollChat], e.poll)
        if (polled !== omagram.messages[pollChat]) omagram.setMessages(pollChat, polled)
      }
    } else if (name === "chatAction") {
      omagram.clockMs = Date.now()
      omagram.chatActions = Model.withAction(omagram.chatActions, e, omagram.clockMs)
    } else if (name === "userStatus") {
      var statuses = {}
      for (var who in omagram.userStatuses) statuses[who] = omagram.userStatuses[who]
      statuses[e.userId] = e.status
      omagram.userStatuses = statuses
    } else if (name === "settings") {
      omagram.applySettings(e)
    } else if (name === "recording") {
      omagram.recording = e
    } else if (name === "messagesDeleted") {
      if (omagram.messages[e.chatId]) omagram.setMessages(e.chatId, Model.removeMessages(omagram.messages[e.chatId], e.messageIds))
    }
  }

  function request(cmd, args, callback) {
    service.request(cmd, args, callback)
  }

  function sendFile(chatId, path, asPhoto, replyToId, callback) {
    var args = { chatId: chatId, path: path, asPhoto: asPhoto !== false }
    if (replyToId) args.replyToMessageId = replyToId
    service.request("message.sendFile", args, callback || function () {})
  }

  function sendSticker(chatId, sticker, replyToId, callback) {
    var args = { chatId: chatId, fileId: sticker.file.id, width: sticker.width || 0, height: sticker.height || 0,
                 emoji: sticker.emoji || "" }
    if (replyToId) args.replyToMessageId = replyToId
    service.request("message.sendSticker", args, callback || function () {})
  }

  // ---------------------------------------------------------------- lists

  function selectList(key) {
    if (!key) return
    omagram.listKey = key
    if (omagram.loadedLists[key] || omagram.auth.state !== "ready") return
    omagram.loadedLists[key] = true
    service.request("chats.load", { list: key, limit: 100 })
  }

  function togglePin(chatId) {
    var chat = Model.findChat(omagram.chats, chatId)
    if (!chat) return
    var key = Model.orderIn(chat, omagram.listKey) !== "0" ? omagram.listKey : "main"
    service.request("chat.pin", { chatId: chatId, list: key, pinned: !Model.pinnedIn(chat, key) }, function (answer) {
      if (!answer.ok && screen.item && screen.item.notify) screen.item.notify(answer.error || "Could not change the pin")
    })
  }

  function toggleArchive(chatId) {
    var chat = Model.findChat(omagram.chats, chatId)
    if (!chat) return
    service.request("chat.archive", { chatId: chatId, archived: !chat.archived }, function (answer) {
      if (!answer.ok && screen.item && screen.item.notify) screen.item.notify(answer.error || "Could not move the chat")
    })
  }

  // Muting is Telegram's own setting, so it applies on every device.
  function muteChat(chatId, seconds) {
    service.request("chat.mute", { chatId: chatId, muteFor: seconds }, function (answer) {
      if (!answer.ok && screen.item && screen.item.notify) screen.item.notify(answer.error || "Could not change the chat's notifications")
    })
  }

  function toggleMute(chatId) {
    var chat = Model.findChat(omagram.chats, chatId)
    if (chat) omagram.muteChat(chatId, chat.muted ? 0 : Model.MUTE_FOREVER)
  }

  function markChatRead(chatId) {
    var chat = Model.findChat(omagram.chats, chatId)
    if (!chat) return
    if (chat.lastMessage && chat.lastMessage.id) omagram.markRead(chatId, [chat.lastMessage.id])
    if (chat.mentions > 0) service.request("chat.readMentions", { chatId: chatId })
    if (chat.markedUnread) service.request("chat.markUnread", { chatId: chatId, unread: false })
  }

  function markChatUnread(chatId) {
    service.request("chat.markUnread", { chatId: chatId, unread: true }, function (answer) {
      if (!answer.ok && screen.item && screen.item.notify) screen.item.notify(answer.error || "Could not mark the chat unread")
    })
  }

  // After the cache is cleared no downloaded path is valid any more: files and stickers load again.
  function clearFileStates() {
    omagram.files = ({})
    omagram.filesRevision++
    omagram.lottieCache = ({})
  }

  function openFile(message) {
    if (screen.item && screen.item.openFile) screen.item.openFile(message)
  }

  // A message found by search: open its chat, load the messages around it, put the cursor on it.
  function openChatAt(chatId, messageId) {
    omagram.openChatById(chatId, false)
    service.request("chat.history", { chatId: chatId, fromMessageId: messageId, offset: -20, limit: 40 }, function (answer) {
      if (!answer.ok || chatId !== omagram.openChatId) return
      omagram.setMessages(chatId, Model.mergeMessages(omagram.messages[chatId] || [], answer.result.messages || []))
      Qt.callLater(function () { if (screen.item && screen.item.focusMessage) screen.item.focusMessage(messageId) })
    })
  }

  property real viewerMessageId: 0

  function openPhoto(message) {
    if (message && message.id) omagram.viewerMessageId = message.id
  }

  function openChatById(chatId, force) {
    if (!chatId || (chatId === omagram.openChatId && !force)) return
    omagram.viewerMessageId = 0
    omagram.keepMessagesOf(chatId)
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
      if (chatId === omagram.openChatId) omagram.markOpenChatRead()
    })
  }

  // Only while you can see it: a chat opened from a notification is read once the window has focus.
  function markOpenChatRead() {
    var chat = omagram.openChat
    if (chat && chat.unread > 0 && omagram.windowFocused)
      omagram.markRead(chat.id, Model.incomingIds(omagram.messages[chat.id] || [], 100))
  }

  function markRead(chatId, ids) {
    if (ids.length) service.request("chat.read", { chatId: chatId, messageIds: ids })
  }

  // ---------------------------------------------------------------- window

  FloatingWindow {
    id: window
    title: omagram.openChat ? Model.chatTitle(omagram.openChat, omagram.meId) + " — Omagram" : "Omagram"
    color: omagram.background
    implicitWidth: 1100
    implicitHeight: 760
    minimumSize: Qt.size(640, 480)
    visible: true

    // Closing the window ends this process; the service keeps the session.
    onVisibleChanged: if (!visible) Qt.quit()

    Loader {
      id: screen
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

    Shortcut {
      sequences: Keymap.keysFor(omagram.shortcuts, "window.settings")
      enabled: !omagram.settingsOpen
      onActivated: omagram.settingsOpen = true
    }

    SettingsView {
      anchors.fill: parent
      app: omagram
      visible: omagram.settingsOpen
      onClosed: {
        omagram.settingsOpen = false
        if (screen.item) screen.item.forceActiveFocus()
      }
    }

  }

  // A photo opens over the whole screen the window is on, above everything, with the keyboard.
  PanelWindow {
    id: photoWindow
    visible: omagram.viewerMessageId > 0
    screen: window.screen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omagram-photo"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    PhotoViewer {
      anchors.fill: parent
      app: omagram
      messages: omagram.openChat ? omagram.messagesFor(omagram.openChatId) : []
      messageId: omagram.viewerMessageId
      onClosed: {
        omagram.viewerMessageId = 0
        if (screen.item && screen.item.focusMessages) screen.item.focusMessages()
      }
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
          textFormat: Text.PlainText
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
      function focusMessages() { chatView.focusMessages() }
      function focusMessage(id) { return chatView.focusMessage(id) }
      function notify(text) { chatView.flash(text) }
      function openFile(message) { chatView.openFile(message) }

      // A menu or the forward dialog has the keyboard: the window's shortcuts wait.
      readonly property bool modal: chatView.modalOpen || chatList.modalOpen || forwardPicker.visible

      Shortcut { sequences: Keymap.keysFor(omagram.shortcuts, "window.search"); enabled: !omagram.settingsOpen && !mainScope.modal; onActivated: chatList.focusSearch() }
      Shortcut { sequences: Keymap.keysFor(omagram.shortcuts, "window.previousChat"); enabled: !omagram.settingsOpen && !mainScope.modal; onActivated: chatList.step(-1) }
      Shortcut { sequences: Keymap.keysFor(omagram.shortcuts, "window.nextChat"); enabled: !omagram.settingsOpen && !mainScope.modal; onActivated: chatList.step(1) }
      Shortcut { sequences: Keymap.keysFor(omagram.shortcuts, "window.focusList"); enabled: !omagram.settingsOpen && !mainScope.modal; onActivated: chatList.focusList() }
      Shortcut { sequences: Keymap.keysFor(omagram.shortcuts, "window.focusMessages"); enabled: !omagram.settingsOpen && !mainScope.modal; onActivated: chatView.focusMessages() }
      Shortcut { sequences: Keymap.keysFor(omagram.shortcuts, "window.focusComposer"); enabled: !omagram.settingsOpen && !mainScope.modal; onActivated: chatView.focusComposer() }
      Shortcut { sequences: Keymap.keysFor(omagram.shortcuts, "window.nextTab"); enabled: !omagram.settingsOpen && !mainScope.modal; onActivated: chatList.tabStep(1) }
      Shortcut { sequences: Keymap.keysFor(omagram.shortcuts, "window.previousTab"); enabled: !omagram.settingsOpen && !mainScope.modal; onActivated: chatList.tabStep(-1) }
      Shortcut {
        sequences: Keymap.keysFor(omagram.shortcuts, "window.searchInChat")
        enabled: !!omagram.openChat && !omagram.settingsOpen && !mainScope.modal
        onActivated: chatList.searchInChat(omagram.openChatId, omagram.openChat ? omagram.openChat.title : "")
      }

      Component.onCompleted: chatList.focusList()

      RowLayout {
        anchors.fill: parent
        spacing: 0

        ChatList {
          id: chatList
          app: omagram
          Layout.preferredWidth: Math.max(280, Math.min(380, mainScope.width * 0.32))
          Layout.fillHeight: true
          chats: omagram.listChats
          allChats: omagram.chats
          tabs: omagram.tabs
          listKey: omagram.listKey
          openChatId: omagram.openChatId
          nowMs: omagram.nowMs
          onListSelected: function (key) { omagram.selectList(key) }
          onMessageActivated: function (chatId, messageId) { omagram.openChatAt(chatId, messageId) }
          onPinRequested: function (chatId) { omagram.togglePin(chatId) }
          onArchiveRequested: function (chatId) { omagram.toggleArchive(chatId) }
          onSettingsRequested: omagram.settingsOpen = true
          onMuteRequested: function (chatId) { omagram.toggleMute(chatId) }
          onReadRequested: function (chatId) { omagram.markChatRead(chatId) }
          onUnreadRequested: function (chatId) { omagram.markChatUnread(chatId) }
          onInfoRequested: function (chatId) {
            omagram.openChatById(chatId, false)
            Qt.callLater(function () { chatView.openInfo() })
          }
          onLeaveRequested: function (chatId) { chatView.askLeaveChat(Model.findChat(omagram.chats, chatId)) }
          onClearRequested: function (chatId, removeFromList) { chatView.askClearChat(Model.findChat(omagram.chats, chatId), removeFromList) }
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
          blocked: forwardPicker.visible || chatList.modalOpen
          onSearchRequested: function (text) { chatList.searchFor(text) }
          onSearchInChatRequested: chatList.searchInChat(omagram.openChatId, Model.chatTitle(omagram.openChat, omagram.meId))
          onForwardRequested: function (fromChatId, messageIds) { forwardPicker.open(fromChatId, messageIds) }
          onToList: chatList.focusList()
        }
      }

      ForwardPicker {
        id: forwardPicker
        anchors.fill: parent
        app: omagram
        chats: omagram.chats
        onPicked: function (chatId, title) {
          service.request("message.forward", { chatId: chatId, fromChatId: forwardPicker.fromChatId, messageIds: forwardPicker.messageIds },
                          function (answer) { chatView.flash(answer.ok ? "Forwarded to " + title : "Could not forward: " + (answer.error || "unknown error")) })
          chatView.clearSelection()
          chatView.focusMessages()
        }
        onDismissed: chatView.focusMessages()
      }
    }
  }
}
