import QtQuick
import Quickshell
import Quickshell.Io

// A connection to omagramd, used by the window and by the plugin inside Omarchy's shell. A
// request gets exactly one callback with the service's answer; everything else the service
// says arrives as serviceEvent(name, message). While there is no connection it is retried,
// and the window also starts the service (the service itself allows only one instance).
Item {
  id: client

  property string binDir: ""
  // Where the service listens. Without XDG_RUNTIME_DIR there is no telling whose runtime
  // directory it is, so nothing is guessed and no connection is made.
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property string socketPath: client.runtimeDir.charAt(0) === "/" ? client.runtimeDir + "/omagram/omagram.sock" : ""
  readonly property bool connected: !!client.sock && client.sock.connected

  // Omagram's own window: notification clicks that open a chat are handed to it.
  property bool window: false
  // Off inside Omarchy's shell, where the plugin's service entry keeps omagramd running.
  property bool autoStart: true

  property int nextId: 1
  property var callbacks: ({})
  property real lastStartAttempt: 0
  property var sock: null

  signal hello(var result)
  signal serviceEvent(string name, var message)

  function request(cmd, args, callback) {
    // The socket itself, not `connected`: that binding may not have caught up yet inside the
    // socket's own connection handler, which is where hello is sent.
    if (!client.sock || !client.sock.connected) {
      if (callback) callback({ ok: false, error: "Omagram's service is not running" })
      return
    }
    var id = client.nextId++
    if (callback) client.callbacks[id] = callback
    client.sock.write(JSON.stringify({ id: id, cmd: cmd, args: args || {} }) + "\n")
    client.sock.flush()
  }

  function handleLine(line) {
    var message = null
    try { message = JSON.parse(line) } catch (e) { return }
    if (!message || typeof message !== "object") return
    if (typeof message.id === "number") {
      var callback = client.callbacks[message.id]
      if (callback) {
        delete client.callbacks[message.id]
        callback(message)
      }
      return
    }
    if (typeof message.event === "string") client.serviceEvent(message.event, message)
  }

  function failPending() {
    var pending = client.callbacks
    client.callbacks = ({})
    for (var id in pending) pending[id]({ ok: false, error: "The connection to Omagram's service was lost" })
  }

  function startService() {
    var now = Date.now()
    if (!client.autoStart || now - client.lastStartAttempt < 10000 || !client.binDir) return
    client.lastStartAttempt = now
    Quickshell.execDetached(["/usr/bin/python3", client.binDir + "omagram", "--service"])
  }

  // A fresh Socket for every attempt. One whose connection was refused does not try again
  // when its `connected` is set back to true, so a shell that started before the service
  // was listening would otherwise never connect.
  //
  // Connected only once it is `sock`: a local connection can complete synchronously, and its
  // handler would otherwise run before the assignment and be taken for a stale socket.
  function reconnect() {
    if (!client.socketPath) return
    var old = client.sock
    client.sock = socketComponent.createObject(client)
    if (old) old.destroy()
    if (client.sock) client.sock.connected = true
  }

  Component {
    id: socketComponent

    Socket {
      id: socket
      path: client.socketPath
      connected: false

      parser: SplitParser {
        onRead: function (line) { if (socket === client.sock) client.handleLine(line) }
      }

      // A socket being replaced can still report; only the current one speaks for the client.
      onConnectionStateChanged: {
        if (socket !== client.sock) return
        if (connected) {
          retry.interval = 500
          client.request("hello", { window: client.window }, function (answer) { if (answer.ok) client.hello(answer.result) })
        } else {
          client.failPending()
        }
      }
    }
  }

  Component.onCompleted: client.reconnect()

  // Retries for as long as there is no connection, backing off to five seconds.
  Timer {
    id: retry
    interval: 500
    repeat: true
    running: !client.connected
    onTriggered: {
      client.startService()
      interval = Math.min(5000, interval * 2)
      client.reconnect()
    }
  }
}
