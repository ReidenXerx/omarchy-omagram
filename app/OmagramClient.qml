import QtQuick
import Quickshell
import Quickshell.Io

// The window's connection to omagramd. A request gets exactly one callback with the
// service's answer; everything else the service says arrives as serviceEvent(name, message).
// If the service is not there, it is started (the service itself allows only one instance)
// and the connection is retried.
Item {
  id: client

  property string binDir: ""
  readonly property string socketPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000") + "/omagram/omagram.sock"
  readonly property bool connected: sock.connected

  property int nextId: 1
  property var callbacks: ({})
  property real lastStartAttempt: 0

  signal hello(var result)
  signal serviceEvent(string name, var message)

  function request(cmd, args, callback) {
    if (!sock.connected) {
      if (callback) callback({ ok: false, error: "Omagram's service is not running" })
      return
    }
    var id = client.nextId++
    if (callback) client.callbacks[id] = callback
    sock.write(JSON.stringify({ id: id, cmd: cmd, args: args || {} }) + "\n")
    sock.flush()
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
    if (now - client.lastStartAttempt < 10000 || !client.binDir) return
    client.lastStartAttempt = now
    Quickshell.execDetached(["/usr/bin/python3", client.binDir + "omagram", "--service"])
  }

  Socket {
    id: sock
    path: client.socketPath
    connected: true

    parser: SplitParser {
      onRead: function (line) { client.handleLine(line) }
    }

    onConnectionStateChanged: {
      if (connected) {
        retry.interval = 500
        client.request("hello", {}, function (answer) { if (answer.ok) client.hello(answer.result) })
      } else {
        client.failPending()
        retry.restart()
      }
    }

    onError: function (error) {
      client.startService()
      retry.restart()
    }
  }

  // Back off to five seconds while the service is away.
  Timer {
    id: retry
    interval: 500
    onTriggered: {
      interval = Math.min(5000, interval * 2)
      sock.connected = false
      sock.connected = true
    }
  }
}
