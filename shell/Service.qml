import QtQuick
import Quickshell
import Quickshell.Io
import "../app"
import "../app/Model.js" as Model
import Quickshell.Hyprland

// Omagram inside Omarchy's shell: keeps the Telegram service running for as long as the
// shell is, and holds the one connection the bar panel and the quick-reply overlay share.
//
// Only what those need lives here -- the chat list, who you are, whether you are signed in.
// Messages are asked for when a panel shows them, and the window keeps its own connection.
Item {
  id: service

  property var shell: null
  property var manifest: null

  readonly property string python: "/usr/bin/python3"
  readonly property string binDir: decodeURIComponent(String(Qt.resolvedUrl("../bin/")).replace("file://", ""))

  property var auth: ({ state: "connecting" })
  property var chats: []
  property real meId: 0
  property var shortcuts: ({})   // your shortcut choices; Keymap.js has the defaults
  readonly property bool connected: client.connected
  readonly property bool ready: client.connected && service.auth.state === "ready"
  readonly property int unread: Model.unreadTotal(service.chats)
  // For the quick view: the voice or round video message being listened to ({ fileId: 0 } when none), one
  // being recorded ({ state: "idle" | "voice" | "video", startedAt, preview }), and what the service last said
  // about a file (a sticker or photo coming down), by file id.
  property var playing: ({ fileId: 0 })
  property var recording: ({ state: "idle" })
  property var files: ({})
  // Where the quick view was when it closed, in the panel or the overlay alike: the chat and the words not yet
  // sent. It opens there again within the hour, so a conversation carried on through it picks up where it was.
  property real quickChatId: 0
  property string quickDraft: ""
  property real quickClosedAt: 0

  function noteFile(file) {
    if (!file || !file.id) return
    var files = Object.keys(service.files).length > 500 ? {} : Object.assign({}, service.files)
    files[file.id] = file
    service.files = files
  }

  function download(fileId) {
    if (!fileId) return
    client.request("file.download", { fileId: fileId, priority: 8 }, function (answer) {
      if (answer.ok && answer.result) service.noteFile(answer.result)
    })
  }

  // Messages as the service reports them (message, messageSent, messageFailed,
  // messageContent, messageEdited, messagesDeleted), for a panel showing a chat's history.
  signal messageEvent(string name, var event)

  // ---------------------------------------------------------------- the service process

  // With --with-parent it ends with the shell. If a copy started by the window already holds
  // the lock this one exits at once, and trying again later takes over when that copy ends.
  Process {
    id: daemon
    command: [service.python, service.binDir + "omagramd", "--with-parent"]
    running: true
    onExited: restart.restart()
  }

  Timer {
    id: restart
    interval: 30000
    onTriggered: if (!daemon.running) daemon.running = true
  }

  // Omagram in the app launcher: Omarchy's launcher lists desktop entries, not plugins, so each start
  // checks ~/.local/share/applications/omagram.desktop and rewrites it only when it is out of date.
  Process {
    command: [service.python, service.binDir + "omagram", "--desktop-entry"]
    running: true
  }

  // ---------------------------------------------------------------- the connection

  OmagramClient {
    id: client
    binDir: service.binDir
    autoStart: false

    onHello: function (result) {
      service.auth = result.auth || { state: "starting" }
      service.meId = result.meId || 0
      service.shortcuts = result.settings ? (result.settings.shortcuts || ({})) : ({})
      service.chats = Model.sortChats(result.chats || [])
    }

    onServiceEvent: function (name, e) {
      if (name === "auth") {
        service.auth = e.auth
        if (e.auth.state !== "ready") service.chats = []
      } else if (name === "settings") {
        service.shortcuts = e.settings ? (e.settings.shortcuts || ({})) : ({})
      } else if (name === "me") {
        service.meId = e.meId || 0
      } else if (name === "chat") {
        service.chats = Model.upsertChat(service.chats, e.chat, "main")
      } else if (name.indexOf("message") === 0) {
        service.messageEvent(name, e)
      } else if (name === "playing") {
        service.playing = e
      } else if (name === "recording") {
        service.recording = e
      } else if (name === "file") {
        service.noteFile(e.file)
      }
    }

    onConnectedChanged: if (!connected) service.auth = { state: "connecting" }
  }

  // A Hyprland config reload drops runtime bindings: have the service register your global
  // shortcuts again.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event && String(event.name) === "configreloaded") client.request("shortcuts.apply", {})
    }
  }

  function request(cmd, args, callback) {
    client.request(cmd, args, callback)
  }

  function sendText(chatId, text, callback) {
    client.request("message.send", { chatId: chatId, text: text }, callback || function () {})
  }

  // ---------------------------------------------------------------- the window

  function openWindow() {
    Quickshell.execDetached([service.python, service.binDir + "omagram"])
  }

  function openChat(chatId) {
    var id = Number(chatId)
    if (!Number.isSafeInteger(id) || id === 0) return service.openWindow()
    Quickshell.execDetached([service.python, service.binDir + "omagram", "--chat", String(id)])
  }
}
