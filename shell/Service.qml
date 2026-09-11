import QtQuick
import Quickshell
import Quickshell.Io
import "../app"
import "../app/Model.js" as Model

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
  readonly property bool connected: client.connected
  readonly property bool ready: client.connected && service.auth.state === "ready"
  readonly property int unread: Model.unreadTotal(service.chats)

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

  // ---------------------------------------------------------------- the connection

  OmagramClient {
    id: client
    binDir: service.binDir
    autoStart: false

    onHello: function (result) {
      service.auth = result.auth || { state: "starting" }
      service.meId = result.meId || 0
      service.chats = Model.sortChats(result.chats || [])
    }

    onServiceEvent: function (name, e) {
      if (name === "auth") {
        service.auth = e.auth
        if (e.auth.state !== "ready") service.chats = []
      } else if (name === "me") {
        service.meId = e.meId || 0
      } else if (name === "chat") {
        service.chats = Model.upsertChat(service.chats, e.chat, "main")
      } else if (name.indexOf("message") === 0) {
        service.messageEvent(name, e)
      }
    }

    onConnectedChanged: if (!connected) service.auth = { state: "connecting" }
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
