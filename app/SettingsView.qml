import QtQuick
import QtQuick.Layouts
import qs.Commons
import "Model.js" as Model
import "Keymap.js" as Keymap

// Settings: your account (what Omagram keeps on this computer, the devices signed in, signing
// out), every keyboard shortcut in Omagram, and the shortcuts that work anywhere.
//
// ↑/↓ or j/k choose. Enter opens an account row -- anything that changes the account asks first,
// answered with Enter or Esc -- or records new keys for an action (the next combination you press
// replaces its keys); A adds a key, Backspace removes its last key, R resets it, Esc closes. While
// recording, Esc cancels. These keys are fixed on purpose: whatever you do to the other shortcuts,
// this screen always works, and Ctrl+, cannot be lost for good (the gear in the chat list opens it
// too).
FocusScope {
  id: settings

  property var app
  property int cursor: 1
  property string recording: ""      // the action being recorded, "" when none
  property bool recordingAdds: false
  property string error: ""
  property var storage: null         // what storage.stats last said
  property var sessions: []
  property bool sessionsOpen: false
  property var confirm: null         // { text, run }: a question waiting for Enter or Esc
  property real nowMs: Date.now()

  readonly property var overrides: settings.app ? settings.app.shortcuts : ({})
  readonly property var globals: settings.app ? settings.app.globalShortcuts : ({})
  readonly property var globalStatus: settings.app ? settings.app.globalStatus : ({})
  readonly property var rows: settings.buildRows()
  readonly property var current: settings.rows[settings.cursor] || null
  readonly property var accountKinds: ["storage", "sessions", "session", "otherSessions", "logout"]

  signal closed()

  onVisibleChanged: {
    if (!visible) return
    settings.recording = ""
    settings.error = ""
    settings.confirm = null
    settings.nowMs = Date.now()
    settings.forceActiveFocus()
    settings.loadStorage()
    settings.loadSessions()
  }

  function loadStorage() {
    settings.app.request("storage.stats", {}, function (answer) { if (answer.ok) settings.storage = answer.result })
  }

  function loadSessions() {
    settings.app.request("sessions.list", {}, function (answer) { if (answer.ok) settings.sessions = answer.result.sessions || [] })
  }

  function buildRows() {
    var out = [{ kind: "header", title: "Account", note: "" },
               { kind: "storage", label: "Storage on this computer" },
               { kind: "sessions", label: "Devices signed in" }]
    if (settings.sessionsOpen) {
      for (var i = 0; i < settings.sessions.length; i++) out.push({ kind: "session", session: settings.sessions[i] })
      if (settings.sessions.some(function (s) { return !s.current })) out.push({ kind: "otherSessions", label: "Sign out every other device" })
    }
    out.push({ kind: "logout", label: "Sign out of Telegram on this computer" })
    out.push({ kind: "header", title: "Shortcuts that work anywhere",
               note: "Registered with Hyprland, never written into your config. They need Super, Ctrl or Alt." },
             { kind: "global", id: "global.quickReply", label: "Quick reply: find a chat and answer" },
             { kind: "global", id: "global.panel", label: "The bar panel" },
             { kind: "global", id: "global.openWindow", label: "Open Omagram" })
    for (var s = 0; s < Keymap.SECTIONS.length; s++) {
      var section = Keymap.SECTIONS[s]
      out.push({ kind: "header", title: section.title,
                 note: section.app === "shell" ? "In Omarchy's shell" : "" })
      for (var a = 0; a < Keymap.ACTIONS.length; a++) {
        var action = Keymap.ACTIONS[a]
        if (action.id.split(".")[0] === section.id) out.push({ kind: "action", id: action.id, label: action.label })
      }
    }
    return out
  }

  function move(delta) {
    var i = Math.max(0, Math.min(settings.rows.length - 1, settings.cursor + delta))
    var dir = delta < 0 ? -1 : 1
    while (settings.rows[i] && settings.rows[i].kind === "header" && i + dir >= 0 && i + dir < settings.rows.length) i += dir
    while (settings.rows[i] && settings.rows[i].kind === "header" && i - dir >= 0 && i - dir < settings.rows.length) i -= dir
    settings.cursor = i
    list.positionViewAtIndex(i, ListView.Contain)
  }

  function editable(row) {
    return !!row && (row.kind === "action" || row.kind === "global")
  }

  function keysOf(row) {
    if (!settings.editable(row)) return []
    if (row.kind === "global") return settings.globals[row.id] ? [settings.globals[row.id]] : []
    return Keymap.keysFor(settings.overrides, row.id)
  }

  function changed(row) {
    if (!settings.editable(row)) return false
    if (row.kind === "global") return !!settings.globals[row.id]
    return Object.prototype.hasOwnProperty.call(settings.overrides, row.id)
  }

  function startRecording(adds) {
    var row = settings.current
    if (!settings.editable(row)) return
    settings.error = ""
    settings.recordingAdds = adds && row.kind === "action"
    settings.recording = row.id
  }

  function send(overrides, globals) {
    settings.error = ""
    settings.app.request("settings.set", { settings: { shortcuts: overrides, globalShortcuts: globals } }, function (answer) {
      if (!answer.ok) settings.error = answer.error || "The settings could not be saved"
    })
  }

  function withGlobal(id, combo) {
    var next = {}
    for (var k in settings.globals) if (k !== id) next[k] = settings.globals[k]
    if (combo) next[id] = combo
    return next
  }

  function capture(event) {
    var mods = event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.ShiftModifier | Qt.MetaModifier)
    if (event.key === Qt.Key_Escape && !mods) {
      settings.recording = ""
      return
    }
    var sequence = Keymap.fromEvent(event.key, event.modifiers)
    if (sequence === "") return   // a modifier on its own: wait for the key
    var id = settings.recording
    settings.recording = ""
    if (id.indexOf("global.") === 0) {
      var combo = Keymap.toHyprland(sequence)
      if (!combo) {
        settings.error = Keymap.label(sequence) + " cannot work anywhere: use Super, Ctrl or Alt with a letter, digit or named key"
        return
      }
      settings.send(settings.overrides, settings.withGlobal(id, combo))
      return
    }
    var keys = settings.recordingAdds ? Keymap.keysFor(settings.overrides, id).concat([sequence]) : [sequence]
    settings.send(Keymap.withKeys(settings.overrides, id, keys), settings.globals)
  }

  function removeLast() {
    var row = settings.current
    if (!settings.editable(row)) return
    if (row.kind === "global") {
      settings.send(settings.overrides, settings.withGlobal(row.id, ""))
      return
    }
    var keys = Keymap.keysFor(settings.overrides, row.id)
    keys.pop()
    settings.send(Keymap.withKeys(settings.overrides, row.id, keys), settings.globals)
  }

  function reset() {
    var row = settings.current
    if (!settings.editable(row)) return
    if (row.kind === "global") settings.send(settings.overrides, settings.withGlobal(row.id, ""))
    else settings.send(Keymap.withKeys(settings.overrides, row.id, Keymap.defaultsFor(row.id)), settings.globals)
  }

  function statusText(id) {
    var state = settings.globalStatus[id] || "off"
    if (!settings.globals[id]) return "Not set"
    return ({ active: "Active", taken: "Taken by another Hyprland binding", failed: "Hyprland refused it",
              unavailable: "Only inside Hyprland", off: "Not active" })[state] || state
  }

  // ---------------------------------------------------------------- the account

  function ask(text, run) {
    settings.error = ""
    settings.confirm = { text: text, run: run }
  }

  function answer(yes) {
    var question = settings.confirm
    settings.confirm = null
    if (yes && question) question.run()
  }

  function activate(row) {
    if (!row) return
    if (row.kind === "storage") {
      settings.ask("Clear the cache? Downloaded photos, videos and files are deleted from this computer; they download again when you open them.", function () {
        settings.app.request("storage.clear", {}, function (answer) {
          if (!answer.ok) { settings.error = answer.error || "The cache could not be cleared"; return }
          settings.app.clearFileStates()
          settings.loadStorage()
        })
      })
    } else if (row.kind === "sessions") {
      settings.sessionsOpen = !settings.sessionsOpen
      if (settings.sessionsOpen) settings.loadSessions()
    } else if (row.kind === "session") {
      if (row.session.current) { settings.error = "That is this computer: to sign out here, use the last row of the account."; return }
      settings.ask("Sign out " + Model.sessionTitle(row.session) + (row.session.device ? " on " + row.session.device : "") + "?", function () {
        settings.app.request("session.terminate", { id: row.session.id }, function (answer) {
          if (!answer.ok) settings.error = answer.error || "That device could not be signed out"
          settings.loadSessions()
        })
      })
    } else if (row.kind === "otherSessions") {
      settings.ask("Sign out every device except this computer?", function () {
        settings.app.request("sessions.terminateOthers", {}, function (answer) {
          if (!answer.ok) settings.error = answer.error || "The other devices could not be signed out"
          settings.loadSessions()
        })
      })
    } else if (row.kind === "logout") {
      settings.ask("Sign out of Telegram here? Your chats stay on Telegram; what Omagram keeps on this computer is removed.", function () {
        settings.app.request("auth.logout", {}, function (answer) {
          if (!answer.ok) settings.error = answer.error || "Could not sign out"
          else settings.closed()
        })
      })
    } else if (settings.editable(row)) {
      settings.startRecording(false)
    }
  }

  Keys.onPressed: function (event) {
    if (settings.recording !== "") {
      settings.capture(event)
      event.accepted = true
      return
    }
    var key = event.key
    if (settings.confirm) {
      if (key === Qt.Key_Return || key === Qt.Key_Enter) settings.answer(true)
      else if (key === Qt.Key_Escape) settings.answer(false)
      event.accepted = true   // nothing else happens while a question waits
      return
    }
    if (key === Qt.Key_Escape) settings.closed()
    else if (key === Qt.Key_Down || key === Qt.Key_J) settings.move(1)
    else if (key === Qt.Key_Up || key === Qt.Key_K) settings.move(-1)
    else if (key === Qt.Key_PageDown) settings.move(8)
    else if (key === Qt.Key_PageUp) settings.move(-8)
    else if (key === Qt.Key_Return || key === Qt.Key_Enter) settings.activate(settings.current)
    else if (key === Qt.Key_A) settings.startRecording(true)
    else if (key === Qt.Key_Backspace || key === Qt.Key_Delete) settings.removeLast()
    else if (key === Qt.Key_R) settings.reset()
    else return
    event.accepted = true
  }

  Rectangle {
    anchors.fill: parent
    color: settings.app.background
  }

  MouseArea { anchors.fill: parent }

  ColumnLayout {
    anchors.fill: parent
    anchors.margins: Style.space(24)
    spacing: Style.space(10)

    RowLayout {
      Layout.fillWidth: true

      Column {
        Layout.fillWidth: true
        spacing: Style.space(4)
        Text {
          text: "Settings"
          color: settings.app.foreground
          font.family: settings.app.fontFamily
          font.pixelSize: Style.font.displayLarge
          font.bold: true
        }
        Text {
          text: "↑↓ choose  ·  Enter open or change  ·  A add a key  ·  Backspace remove  ·  R reset  ·  Esc close"
          color: settings.app.muted
          font.family: settings.app.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // md-close (U+F0156)
      Text {
        text: String.fromCodePoint(0xF0156)
        color: closeArea.containsMouse ? settings.app.accent : settings.app.muted
        font.family: settings.app.glyphFamily
        font.pixelSize: Style.font.title
        MouseArea {
          id: closeArea
          anchors.fill: parent
          anchors.margins: -Style.space(6)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: settings.closed()
        }
      }
    }

    // A question about the account, before anything is changed.
    Rectangle {
      Layout.fillWidth: true
      visible: !!settings.confirm
      Layout.preferredHeight: visible ? Math.max(Style.space(46), confirmText.implicitHeight + Style.space(20)) : 0
      radius: Style.cornerRadius
      color: Qt.rgba(settings.app.urgent.r, settings.app.urgent.g, settings.app.urgent.b, 0.1)
      border.width: 1
      border.color: settings.app.urgent

      Text {
        id: confirmText
        anchors.left: parent.left
        anchors.right: confirmButtons.left
        anchors.leftMargin: Style.space(14)
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
        text: settings.confirm ? settings.confirm.text : ""
        color: settings.app.foreground
        font.family: settings.app.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Row {
        id: confirmButtons
        anchors.right: parent.right
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)

        Repeater {
          model: [{ yes: true, label: "Yes   Enter" }, { yes: false, label: "No   Esc" }]
          delegate: Rectangle {
            id: choice
            required property var modelData
            width: choiceLabel.implicitWidth + Style.space(18)
            height: Style.space(28)
            radius: Style.cornerRadius
            color: choiceArea.containsMouse ? Qt.rgba(settings.app.accent.r, settings.app.accent.g, settings.app.accent.b, 0.3)
                 : (choice.modelData.yes ? Qt.rgba(settings.app.urgent.r, settings.app.urgent.g, settings.app.urgent.b, 0.2) : "transparent")
            Text {
              id: choiceLabel
              anchors.centerIn: parent
              text: choice.modelData.label
              color: settings.app.foreground
              font.family: settings.app.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: choice.modelData.yes
            }
            MouseArea {
              id: choiceArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: settings.answer(choice.modelData.yes)
            }
          }
        }
      }
    }

    Text {
      Layout.fillWidth: true
      visible: settings.error !== ""
      text: settings.error
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      color: settings.app.urgent
      font.family: settings.app.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    ListView {
      id: list
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      model: settings.rows
      boundsBehavior: Flickable.StopAtBounds

      WheelScroll { view: list }

      delegate: Rectangle {
        id: row
        required property var modelData
        required property int index
        readonly property bool header: modelData.kind === "header"
        readonly property bool account: settings.accountKinds.indexOf(modelData.kind) >= 0
        readonly property bool isCursor: index === settings.cursor
        readonly property bool isRecording: settings.editable(modelData) && settings.recording === modelData.id
        readonly property var keys: settings.keysOf(modelData)
        readonly property var clashes: modelData.kind === "action" ? Keymap.conflictsFor(settings.overrides, modelData.id) : []

        width: list.width
        height: header ? Style.space(modelData.note ? 58 : 44)
              : (account ? Style.space(modelData.kind === "session" || modelData.kind === "storage" ? 58 : 44)
                         : Style.space(clashes.length || modelData.kind === "global" ? 58 : 42))
        radius: Style.cornerRadius
        color: row.isCursor && !row.header ? settings.app.selected
             : (rowArea.containsMouse && !row.header ? Qt.rgba(settings.app.foreground.r, settings.app.foreground.g, settings.app.foreground.b, 0.04) : "transparent")

        Column {
          visible: row.header
          anchors.left: parent.left
          anchors.bottom: parent.bottom
          anchors.leftMargin: Style.space(4)
          anchors.bottomMargin: Style.space(6)
          spacing: Style.space(2)
          Text {
            text: row.modelData.title || ""
            color: settings.app.accent
            font.family: settings.app.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
          Text {
            visible: !!row.modelData.note
            text: row.modelData.note || ""
            color: settings.app.muted
            font.family: settings.app.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ---------------------------------------------- account rows
        ColumnLayout {
          visible: row.account
          anchors.fill: parent
          anchors.leftMargin: Style.space(row.modelData.kind === "session" ? 30 : 14)
          anchors.rightMargin: Style.space(14)
          anchors.topMargin: Style.space(6)
          anchors.bottomMargin: Style.space(6)
          spacing: Style.space(2)

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            Text {
              Layout.fillWidth: true
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: row.modelData.kind === "session" ? Model.sessionTitle(row.modelData.session)
                  : row.modelData.label + (row.modelData.kind === "sessions" && settings.sessions.length ? "  (" + settings.sessions.length + ")" : "")
              color: row.modelData.kind === "logout" || row.modelData.kind === "otherSessions" ? settings.app.urgent : settings.app.foreground
              font.family: settings.app.fontFamily
              font.pixelSize: row.modelData.kind === "session" ? Style.font.bodySmall : Style.font.body
            }
            Text {
              textFormat: Text.PlainText
              text: ({ storage: "Enter clears the cache", sessions: settings.sessionsOpen ? "Enter hides them" : "Enter shows them",
                       session: row.modelData.session && row.modelData.session.current ? "this computer" : "Enter signs it out",
                       otherSessions: "Enter", logout: "Enter" })[row.modelData.kind] || ""
              color: settings.app.muted
              font.family: settings.app.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            Layout.fillWidth: true
            visible: text !== ""
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: row.modelData.kind === "storage" ? Model.storageText(settings.storage)
                : (row.modelData.kind === "session" ? Model.sessionDetail(row.modelData.session, settings.nowMs) : "")
            color: settings.app.muted
            font.family: settings.app.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ---------------------------------------------- shortcuts
        ColumnLayout {
          visible: !row.header && !row.account
          anchors.fill: parent
          anchors.leftMargin: Style.space(14)
          anchors.rightMargin: Style.space(14)
          anchors.topMargin: Style.space(6)
          anchors.bottomMargin: Style.space(6)
          spacing: Style.space(2)

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            Text {
              Layout.fillWidth: true
              text: row.modelData.label || ""
              elide: Text.ElideRight
              color: settings.app.foreground
              font.family: settings.app.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              visible: settings.changed(row.modelData) && !row.isRecording
              text: row.modelData.kind === "global" ? "" : "changed"
              color: settings.app.muted
              font.family: settings.app.fontFamily
              font.pixelSize: Style.font.caption
            }

            Rectangle {
              visible: row.isRecording
              implicitWidth: recordingText.implicitWidth + Style.space(16)
              implicitHeight: Style.space(26)
              radius: Style.cornerRadius
              color: Qt.rgba(settings.app.urgent.r, settings.app.urgent.g, settings.app.urgent.b, 0.15)
              border.width: 1
              border.color: settings.app.urgent
              Text {
                id: recordingText
                anchors.centerIn: parent
                text: settings.recordingAdds ? "Press the key to add  ·  Esc cancels" : "Press the new keys  ·  Esc cancels"
                color: settings.app.foreground
                font.family: settings.app.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Repeater {
              model: row.isRecording ? [] : row.keys
              delegate: Rectangle {
                required property var modelData
                implicitWidth: chip.implicitWidth + Style.space(14)
                implicitHeight: Style.space(26)
                radius: Style.cornerRadius
                color: Qt.rgba(settings.app.foreground.r, settings.app.foreground.g, settings.app.foreground.b, 0.08)
                border.width: 1
                border.color: Qt.rgba(settings.app.foreground.r, settings.app.foreground.g, settings.app.foreground.b, 0.18)
                Text {
                  id: chip
                  anchors.centerIn: parent
                  text: row.modelData.kind === "global" ? modelData : Keymap.label(modelData)
                  textFormat: Text.PlainText
                  color: settings.app.foreground
                  font.family: settings.app.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Text {
              visible: !row.isRecording && row.keys.length === 0
              text: row.modelData.kind === "global" ? "Not set" : "Off"
              color: settings.app.muted
              font.family: settings.app.fontFamily
              font.pixelSize: Style.font.caption
              font.italic: true
            }
          }

          Text {
            visible: row.modelData.kind === "global" && !!settings.globals[row.modelData.id]
            text: settings.statusText(row.modelData.id)
            color: (settings.globalStatus[row.modelData.id] || "") === "active" ? settings.app.muted : settings.app.urgent
            font.family: settings.app.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            Layout.fillWidth: true
            visible: row.clashes.length > 0
            elide: Text.ElideRight
            color: settings.app.urgent
            font.family: settings.app.fontFamily
            font.pixelSize: Style.font.caption
            text: {
              var names = []
              for (var i = 0; i < row.clashes.length; i++) {
                for (var j = 0; j < row.clashes[i].ids.length; j++) {
                  var other = row.clashes[i].ids[j]
                  if (other === row.modelData.id) continue
                  var action = Keymap.actionById(other)
                  var section = Keymap.sectionOf(other)
                  names.push(Keymap.label(row.clashes[i].sequence) + " is also " + (action ? action.label : other)
                             + (section ? " (" + section.title + ")" : ""))
                }
              }
              return names.join("  ·  ")
            }
          }
        }

        MouseArea {
          id: rowArea
          anchors.fill: parent
          enabled: !row.header
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          cursorShape: Qt.PointingHandCursor
          onClicked: function (mouse) {
            settings.cursor = row.index
            settings.forceActiveFocus()
            if (row.account) settings.activate(row.modelData)
            else if (mouse.button === Qt.RightButton) settings.reset()
            else settings.startRecording(false)
          }
        }
      }
    }
  }
}
