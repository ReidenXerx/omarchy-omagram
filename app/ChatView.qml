import QtQuick
import QtQuick.Layouts
import QtQuick.Dialogs
import Quickshell
import qs.Commons
import "Model.js" as Model
import "Keymap.js" as Keymap

// The open chat: messages and the composer.
//
// Composer: Enter sends, Shift+Enter adds a line, Esc cancels a reply or edit (or moves to
// the messages), ↑ in an empty composer edits your last message, Tab moves to the messages.
// Anywhere in the chat: Ctrl+O attaches photos or files, Ctrl+Shift+O sends files uncompressed,
// Ctrl+S opens stickers; files dropped on the chat are sent.
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
  property bool stickersOpen: false

  readonly property var replyTo: root.replyToId ? Model.findMessage(root.messages, root.replyToId) : null
  readonly property var editing: root.editingId ? Model.findMessage(root.messages, root.editingId) : null
  readonly property var selectedMessage: root.cursor >= 0 && root.cursor < root.messages.length ? root.messages[root.cursor] : null

  signal loadOlder()
  signal toList()
  signal searchRequested(string text)

  // What the messages need from here: which spoilers you opened, poll answers being chosen,
  // messages selected, and a question waiting in the bar (joining a group, starting a bot).
  property var revealed: ({})
  property var pollChoices: ({})
  property var selection: ({})
  readonly property bool selecting: Object.keys(root.selection).length > 0
  readonly property bool messagesFocused: messageList.activeFocus
  property var prompt: null
  readonly property var keyboard: Model.latestKeyboard(root.messages)
  property real keyboardHiddenFor: 0

  function focusComposer() { composer.forceActiveFocus() }

  function focusMessages() {
    if (!root.messages.length) return
    if (root.cursor < 0 || root.cursor >= root.messages.length) root.cursor = root.messages.length - 1
    messageList.forceActiveFocus()
    messageList.positionViewAtIndex(root.cursor, ListView.Contain)
  }

  // A message found by search: the cursor goes to it if it is loaded.
  function focusMessage(messageId) {
    for (var i = 0; i < root.messages.length; i++) {
      if (root.messages[i].id !== messageId) continue
      root.cursor = i
      root.stickToBottom = false
      messageList.forceActiveFocus()
      messageList.positionViewAtIndex(i, ListView.Center)
      return true
    }
    return false
  }

  function resetForChat() {
    root.revealed = ({})
    root.pollChoices = ({})
    root.selection = ({})
    root.prompt = null
    root.replyToId = 0
    root.editingId = 0
    root.cursor = -1
    root.confirmDeleteId = 0
    root.notice = ""
    root.stickToBottom = true
    root.stickersOpen = false
    composer.text = ""
  }

  function attach(asPhoto) {
    if (!root.chat) return
    attachDialog.asPhoto = asPhoto
    attachDialog.open()
  }

  function urlToPath(url) {
    var s = String(url)
    return s.indexOf("file://") === 0 ? decodeURIComponent(s.slice(7)) : ""
  }

  function sendPaths(paths, asPhoto) {
    if (!root.chat) return
    // Ten at a time at most: a stray drop of a whole folder should not become a flood.
    for (var i = 0; i < paths.length && i < 10; i++) {
      app.sendFile(root.chat.id, paths[i], asPhoto, i === 0 ? root.replyToId : 0, function (answer) {
        if (!answer.ok) root.flash("Could not send: " + (answer.error || "unknown error"))
      })
    }
    if (paths.length > 10) root.flash("Sent the first 10 files")
    root.replyToId = 0
    root.stickToBottom = true
  }

  function toggleStickers() {
    if (!root.chat) return
    root.stickersOpen = !root.stickersOpen
    if (root.stickersOpen) Qt.callLater(function () { stickerPicker.open() })
    else root.focusComposer()
  }

  readonly property bool shortcutsOn: !!root.chat && !app.settingsOpen
  Shortcut { sequences: Keymap.keysFor(app.shortcuts, "window.attach"); enabled: root.shortcutsOn; onActivated: root.attach(true) }
  Shortcut { sequences: Keymap.keysFor(app.shortcuts, "window.attachFiles"); enabled: root.shortcutsOn; onActivated: root.attach(false) }
  Shortcut { sequences: Keymap.keysFor(app.shortcuts, "window.stickers"); enabled: root.shortcutsOn; onActivated: root.toggleStickers() }
  Shortcut {
    sequences: Keymap.keysFor(app.shortcuts, "window.voice")
    enabled: root.shortcutsOn && !videoNote.visible
    onActivated: root.recordingVoice ? root.stopVoice(true) : root.startVoice()
  }
  Shortcut {
    sequences: Keymap.keysFor(app.shortcuts, "window.videoNote")
    enabled: root.shortcutsOn && !root.recordingVoice
    onActivated: videoNote.open(root.chat.id)
  }
  Shortcut { sequences: Keymap.keysFor(app.shortcuts, "voice.send"); enabled: root.recordingVoice && !app.settingsOpen; onActivated: root.stopVoice(true) }
  Shortcut { sequences: Keymap.keysFor(app.shortcuts, "voice.cancel"); enabled: root.recordingVoice && !app.settingsOpen; onActivated: root.stopVoice(false) }

  // ---------------------------------------------------------------- voice messages

  readonly property bool recordingVoice: !!app.recording && app.recording.state === "voice"
                                         && !!root.chat && app.recording.chatId === root.chat.id
  property real recordingNow: Date.now()
  readonly property real recordingSeconds: root.recordingVoice ? Math.max(0, (root.recordingNow - app.recording.startedAt) / 1000) : 0

  Timer {
    interval: 200
    repeat: true
    running: root.recordingVoice
    onTriggered: root.recordingNow = Date.now()
  }

  function startVoice() {
    if (!root.chat || root.recordingVoice) return
    root.recordingNow = Date.now()
    client.request("voice.start", { chatId: root.chat.id }, function (answer) {
      if (!answer.ok) root.flash("Could not record: " + (answer.error || "no microphone"))
    })
  }

  function stopVoice(send) {
    var args = { send: send }
    if (send && root.replyToId) args.replyToMessageId = root.replyToId
    client.request("voice.stop", args, function (answer) {
      if (!answer.ok) root.flash(answer.error || "Could not send the voice message")
    })
    if (send) {
      root.replyToId = 0
      root.stickToBottom = true
    }
    Qt.callLater(root.focusComposer)
  }

  function composerAction(action) {
    if (!root.chat) return
    if (action === "attach") root.attach(true)
    else if (action === "stickers") root.toggleStickers()
    else if (action === "video") videoNote.open(root.chat.id)
    else if (action === "voice") root.startVoice()
  }

  FileDialog {
    id: attachDialog
    property bool asPhoto: true
    title: asPhoto ? "Send photos or files" : "Send as files"
    fileMode: FileDialog.OpenFiles
    onAccepted: {
      var paths = []
      for (var i = 0; i < selectedFiles.length; i++) {
        var path = root.urlToPath(selectedFiles[i])
        if (path) paths.push(path)
      }
      root.sendPaths(paths, asPhoto)
      root.focusComposer()
    }
    onRejected: root.focusComposer()
  }

  DropArea {
    anchors.fill: parent
    enabled: !!root.chat
    onDropped: function (drop) {
      if (!drop.hasUrls) return
      root.sendPaths(drop.urls.map(root.urlToPath).filter(function (p) { return p !== "" }), true)
      drop.accept()
    }

    Rectangle {
      anchors.fill: parent
      visible: parent.containsDrag
      color: Qt.rgba(app.accent.r, app.accent.g, app.accent.b, 0.12)
      border.width: Math.max(1, Style.space(2))
      border.color: app.accent
      z: 10
      Text {
        anchors.centerIn: parent
        text: "Drop to send"
        color: app.foreground
        font.family: app.fontFamily
        font.pixelSize: Style.font.title
      }
    }
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

  // ---------------------------------------------------------------- what messages ask for

  function copyOf(map) {
    var next = {}
    for (var k in map) next[k] = map[k]
    return next
  }

  function reveal(id) {
    var next = root.copyOf(root.revealed)
    next[id] = true
    root.revealed = next
  }

  function stepFrom(index, delta) {
    var i = index + delta
    while (i > 0 && i < root.messages.length - 1 && Model.inAlbumAfterFirst(root.messages, i)) i += delta
    if (delta < 0) while (i > 0 && Model.inAlbumAfterFirst(root.messages, i)) i--
    return Math.max(0, Math.min(root.messages.length - 1, i))
  }

  function jumpTo(messageId) {
    if (!root.focusMessage(messageId) && root.chat) app.openChatAt(root.chat.id, messageId)
  }

  function openExternal(url) {
    var safe = Model.safeUrl(url)
    if (!safe) { root.flash("That link cannot be opened"); return }
    Quickshell.execDetached(["/usr/bin/xdg-open", safe])
  }

  function openUsername(username) {
    client.request("username.chat", { username: username }, function (answer) {
      if (answer.ok && answer.result.chatId) app.openChatById(answer.result.chatId, false)
      else root.flash("No one on Telegram is @" + username)
    })
  }

  function openUser(userId) {
    if (!userId) return
    client.request("user.chat", { userId: userId }, function (answer) {
      if (answer.ok && answer.result.chatId) app.openChatById(answer.result.chatId, false)
      else root.flash(answer.error || "That chat cannot be opened")
    })
  }

  function sendText(text) {
    if (!root.chat || !text) return
    client.request("message.send", { chatId: root.chat.id, text: text }, function (answer) {
      if (!answer.ok) root.flash("Could not send: " + (answer.error || "unknown error"))
    })
    root.stickToBottom = true
  }

  function openLink(link, message) {
    var s = String(link || "")
    if (s === "omagram:spoiler") { if (message) root.reveal(message.id); return }
    if (s.indexOf("omagram:mention:") === 0) { root.openUsername(decodeURIComponent(s.slice(16))); return }
    if (s.indexOf("omagram:user:") === 0) { root.openUser(Number(s.slice(13))); return }
    if (s.indexOf("omagram:search:") === 0) { root.searchRequested(decodeURIComponent(s.slice(15))); return }
    if (s.indexOf("omagram:command:") === 0) { root.sendText(decodeURIComponent(s.slice(16))); return }
    var url = Model.safeUrl(s)
    if (!url) return
    if (/^mailto:/i.test(url)) { root.openExternal(url); return }
    client.request("link.open", { url: url }, function (answer) {
      if (!answer.ok) { root.flash(answer.error || "That link cannot be opened"); return }
      var r = answer.result
      if (r.kind === "external") {
        root.openExternal(r.url)
      } else if (r.kind === "chat" && r.chatId) {
        if (r.messageId) app.openChatAt(r.chatId, r.messageId)
        else app.openChatById(r.chatId, false)
        if (r.botStart) root.prompt = { text: "Start the bot?", action: "Start",
                                        run: function () { client.request("bot.start", { chatId: r.chatId, parameter: r.botStart }) } }
      } else if (r.kind === "invite") {
        if (r.chatId) { app.openChatById(r.chatId, false); return }
        root.prompt = { text: "Join “" + r.title + "”" + (r.members ? " (" + r.members + " members)" : "") + "?", action: "Join",
                        run: function () {
                          client.request("chat.joinLink", { link: r.link }, function (joined) {
                            if (joined.ok && joined.result.chatId) app.openChatById(joined.result.chatId, false)
                            else root.flash(joined.error || "Could not join")
                          })
                        } }
      }
    })
  }

  function runPrompt(accept) {
    var p = root.prompt
    root.prompt = null
    if (accept && p && p.run) p.run()
  }

  function pressButton(message, button) {
    if (!message || !button) return
    if (button.kind === "callback") {
      client.request("button.callback", { chatId: message.chatId, messageId: message.id, data: button.data }, function (answer) {
        if (!answer.ok) { root.flash(answer.error || "The bot did not answer"); return }
        if (answer.result.url) root.openLink(answer.result.url, message)
        else if (answer.result.text) root.flash(answer.result.text)
      })
    } else if (button.kind === "url") {
      root.openLink(button.url, message)
    } else if (button.kind === "user") {
      root.openUser(button.userId)
    } else if (button.kind === "copy") {
      clipboard.text = button.copyText
      clipboard.selectAll()
      clipboard.copy()
      root.flash("Copied")
    } else {
      root.flash("“" + button.text + "” needs an official Telegram app")
    }
  }

  function pressKey(button) {
    if (!button || !root.keyboard) return
    if (button.kind !== "text") { root.flash("“" + button.text + "” needs an official Telegram app"); return }
    root.sendText(button.text)
    if (root.keyboard.oneTime) root.keyboardHiddenFor = root.keyboard.messageId
  }

  function vote(message, index) {
    var poll = message && message.content ? message.content.poll : null
    if (!poll || poll.closed) return
    if (!poll.multiple) {
      client.request("poll.vote", { chatId: message.chatId, messageId: message.id, optionIds: [index] }, function (answer) {
        if (!answer.ok) root.flash(answer.error || "Could not vote")
      })
      return
    }
    var chosen = (root.pollChoices[message.id] || []).slice()
    var at = chosen.indexOf(index)
    if (at >= 0) chosen.splice(at, 1)
    else chosen.push(index)
    var next = root.copyOf(root.pollChoices)
    next[message.id] = chosen
    root.pollChoices = next
  }

  function submitVote(message) {
    var chosen = root.pollChoices[message.id] || []
    if (!chosen.length) return
    client.request("poll.vote", { chatId: message.chatId, messageId: message.id, optionIds: chosen }, function (answer) {
      if (!answer.ok) root.flash(answer.error || "Could not vote")
    })
    var next = root.copyOf(root.pollChoices)
    delete next[message.id]
    root.pollChoices = next
  }

  function toggleReaction(message, reaction) {
    if (!message || !reaction || !reaction.emoji) return
    client.request("reaction.set", { chatId: message.chatId, messageId: message.id, emoji: reaction.emoji, chosen: !reaction.chosen },
                   function (answer) { if (!answer.ok) root.flash(answer.error || "Could not react") })
  }

  function toggleSelected(message) {
    if (!message) return
    var next = root.copyOf(root.selection)
    if (next[message.id]) delete next[message.id]
    else next[message.id] = true
    root.selection = next
  }

  // Filled in with the message menu.
  function openMenu(message, x, y) {}

  Shortcut { sequences: ["Return", "Enter"]; enabled: !!root.prompt && !app.settingsOpen; onActivated: root.runPrompt(true) }
  Shortcut { sequence: "Escape"; enabled: !!root.prompt && !app.settingsOpen; onActivated: root.runPrompt(false) }

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

      Avatar {
        id: headerAvatar
        anchors.left: parent.left
        anchors.leftMargin: Style.space(18)
        anchors.verticalCenter: parent.verticalCenter
        app: root.app
        chat: root.chat
        size: Style.space(38)
      }

      Column {
        anchors.left: headerAvatar.right
        anchors.leftMargin: Style.space(12)
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
          readonly property string activity: !root.chat ? ""
              : Model.actionText(Model.activeActions(app.chatActions, root.chat.id, app.clockMs), root.chat.kind === "private")
          text: !root.chat ? "" : (activity
              || (root.chat.kind === "private" ? (root.chat.bot ? "bot" : Model.statusText(app.userStatuses[root.chat.userId] || root.chat.status, root.nowMs))
                  : ({ group: "Group", channel: "Channel", secret: "Secret chat" }[root.chat.kind] || "")))
          textFormat: Text.PlainText
          color: activity ? app.accent : app.muted
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

      WheelScroll {
        view: messageList
        onScrolled: {
          root.stickToBottom = messageList.atYEnd
          if (messageList.contentY <= messageList.originY + Style.space(200) && messageList.count > 0) root.loadOlder()
        }
      }

      onMovementEnded: root.stickToBottom = atYEnd
      onAtYBeginningChanged: if (atYBeginning && count > 0 && moving) root.loadOlder()
      onContentYChanged: if (contentY <= originY + Style.space(200) && count > 0 && (moving || activeFocus)) root.loadOlder()

      Keys.onPressed: function (event) {
        var keys = root.app.shortcuts
        var selected = root.selectedMessage
        function is(id) { return Keymap.matches(keys, id, event) }
        if (is("messages.down")) {
          root.cursor = root.stepFrom(root.cursor, 1)
          root.stickToBottom = root.cursor === root.messages.length - 1
          positionViewAtIndex(root.cursor, ListView.Contain)
        } else if (is("messages.up")) {
          root.cursor = root.stepFrom(root.cursor, -1)
          root.stickToBottom = false
          positionViewAtIndex(root.cursor, ListView.Contain)
          if (root.cursor < 5) root.loadOlder()
        } else if (is("messages.reply")) root.startReply(selected)
        else if (is("messages.edit")) root.startEdit(selected)
        else if (is("messages.copy")) root.copy(selected)
        else if (is("messages.delete")) root.askDelete(selected)
        else if (is("messages.play") || is("messages.open")) {
          var item = messageList.itemAtIndex(root.cursor)
          if (item && item.mediaItem && item.mediaItem.media) {
            if (is("messages.play")) item.mediaItem.togglePlay()
            else item.mediaItem.activate()
          }
        }
        else if (is("messages.toComposer")) { root.cursor = -1; root.focusComposer() }
        else if (is("messages.toList")) root.toList()
        else if (is("messages.last")) { root.cursor = root.messages.length - 1; root.stickToBottom = true; positionViewAtEnd() }
        else return
        event.accepted = true
      }

      delegate: MessageRow {
        width: messageList.width
        view: root
        app: root.app
        messages: root.messages
      }
    }

    // ------------------------------------------------ reply / edit / notice bar
    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: visible ? Style.space(40) : 0
      visible: !!root.replyTo || !!root.editing || root.notice !== "" || !!root.prompt
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
          if (root.prompt) return root.prompt.text + "   Enter: " + root.prompt.action + "  ·  Esc: cancel"
          if (root.notice !== "") return root.notice
          if (root.editing) return "Editing   Esc to cancel"
          if (root.replyTo) return "Replying to " + (root.replyTo.outgoing ? "yourself" : (root.replyTo.senderName || "message")) + ": " + Model.previewOf(root.replyTo) + "   Esc to cancel"
          return ""
        }
      }
    }

    // ------------------------------------------------ a bot's keyboard
    Rectangle {
      id: botKeyboard
      Layout.fillWidth: true
      visible: !!root.keyboard && root.keyboardHiddenFor !== root.keyboard.messageId && !root.recordingVoice
      Layout.preferredHeight: visible ? keyboardColumn.implicitHeight + Style.space(16) : 0
      color: Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, 0.03)

      Column {
        id: keyboardColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(8)
        spacing: Style.space(4)

        Repeater {
          model: root.keyboard ? root.keyboard.rows : []
          delegate: Row {
            id: keyRow
            required property var modelData
            width: keyboardColumn.width
            spacing: Style.space(4)
            Repeater {
              model: keyRow.modelData
              delegate: Rectangle {
                required property var modelData
                width: (keyRow.width - keyRow.spacing * (keyRow.modelData.length - 1)) / keyRow.modelData.length
                height: Style.space(32)
                radius: Style.cornerRadius
                color: keyArea.containsMouse ? Qt.rgba(app.accent.r, app.accent.g, app.accent.b, 0.3)
                                             : Qt.rgba(app.accent.r, app.accent.g, app.accent.b, 0.14)
                Text {
                  anchors.centerIn: parent
                  width: parent.width - Style.space(12)
                  horizontalAlignment: Text.AlignHCenter
                  elide: Text.ElideRight
                  text: modelData.text
                  textFormat: Text.PlainText
                  color: app.foreground
                  font.family: app.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                MouseArea {
                  id: keyArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.pressKey(modelData)
                }
              }
            }
          }
        }
      }
    }

    // ------------------------------------------------ stickers
    StickerPicker {
      id: stickerPicker
      Layout.fillWidth: true
      Layout.preferredHeight: root.stickersOpen ? Style.space(320) : 0
      visible: root.stickersOpen
      app: root.app
      onPicked: function (sticker) {
        if (!root.chat) return
        app.sendSticker(root.chat.id, sticker, root.replyToId, function (answer) {
          if (!answer.ok) root.flash("Could not send: " + (answer.error || "unknown error"))
        })
        root.replyToId = 0
        root.stickersOpen = false
        root.stickToBottom = true
        root.focusComposer()
      }
      onClosed: {
        root.stickersOpen = false
        root.focusComposer()
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
        visible: !root.recordingVoice
        anchors.left: parent.left
        anchors.right: composerButtons.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
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
              var keys = root.app.shortcuts
              function is(id) { return Keymap.matchesInText(keys, id, event) }
              if (is("composer.send")) root.send()
              else if (is("composer.newLine")) composer.insert(composer.cursorPosition, "\n")
              else if (is("composer.cancel")) {
                if (root.editingId) { root.editingId = 0; composer.text = "" }
                else if (root.replyToId) root.replyToId = 0
                else root.focusMessages()
              }
              else if (is("composer.editLast") && composer.text === "") root.startEdit(Model.lastOwnEditable(root.messages))
              else if (is("composer.toMessages")) root.focusMessages()
              else return
              event.accepted = true
            }

            Text {
              visible: composer.text === ""
              text: root.editing ? "Edit message"
                  : "Message   " + Keymap.label(Keymap.keysFor(app.shortcuts, "composer.send")[0] || "") + " to send, "
                    + Keymap.label(Keymap.keysFor(app.shortcuts, "composer.newLine")[0] || "") + " for a new line"
              color: app.muted
              opacity: 0.7
              font: composer.font
            }
          }
        }
      }

      // Attach, stickers, a video message, a voice message.
      Row {
        id: composerButtons
        visible: !root.recordingVoice
        anchors.right: parent.right
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0

        Repeater {
          // md-paperclip U+F03E2, md-sticker-emoji U+F0785, md-video U+F0567, md-microphone U+F036C
          model: [
            { glyph: String.fromCodePoint(0xF03E2), action: "attach", hint: "Attach photos or files   " + Keymap.label(Keymap.keysFor(app.shortcuts, "window.attach")[0] || "") },
            { glyph: String.fromCodePoint(0xF0785), action: "stickers", hint: "Stickers   " + Keymap.label(Keymap.keysFor(app.shortcuts, "window.stickers")[0] || "") },
            { glyph: String.fromCodePoint(0xF0567), action: "video", hint: "Video message   " + Keymap.label(Keymap.keysFor(app.shortcuts, "window.videoNote")[0] || "") },
            { glyph: String.fromCodePoint(0xF036C), action: "voice", hint: "Voice message   " + Keymap.label(Keymap.keysFor(app.shortcuts, "window.voice")[0] || "") }
          ]
          delegate: Item {
            id: composerButton
            required property var modelData
            width: Style.space(38)
            height: Style.space(38)

            Text {
              anchors.centerIn: parent
              text: composerButton.modelData.glyph
              color: buttonArea.containsMouse || (composerButton.modelData.action === "stickers" && root.stickersOpen) ? app.accent : app.muted
              font.family: app.glyphFamily
              font.pixelSize: Style.font.title
            }
            MouseArea {
              id: buttonArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.composerAction(composerButton.modelData.action)
              onContainsMouseChanged: if (containsMouse) root.flash(composerButton.modelData.hint)
            }
          }
        }
      }

      // Recording a voice message: replaces the composer until it is sent or cancelled.
      Rectangle {
        visible: root.recordingVoice
        anchors.fill: parent
        anchors.margins: Style.space(10)
        radius: Style.cornerRadius
        color: Qt.rgba(app.urgent.r, app.urgent.g, app.urgent.b, 0.1)
        border.width: Math.max(1, Style.space(1.5))
        border.color: app.urgent

        Row {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(14)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(10)

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(10)
            height: width
            radius: width / 2
            color: app.urgent
            SequentialAnimation on opacity {
              running: root.recordingVoice
              loops: Animation.Infinite
              NumberAnimation { to: 0.25; duration: 600 }
              NumberAnimation { to: 1; duration: 600 }
            }
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Recording  " + Model.formatDuration(root.recordingSeconds)
            color: app.foreground
            font.family: app.fontFamily
            font.pixelSize: Style.font.body
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: Keymap.label(Keymap.keysFor(app.shortcuts, "voice.send")[0] || "") + " sends  ·  "
                  + Keymap.label(Keymap.keysFor(app.shortcuts, "voice.cancel")[0] || "") + " cancels"
            color: app.muted
            font.family: app.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Row {
          anchors.right: parent.right
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)

          Repeater {
            // md-close U+F0156, md-send U+F048A
            model: [
              { glyph: String.fromCodePoint(0xF0156), send: false },
              { glyph: String.fromCodePoint(0xF048A), send: true }
            ]
            delegate: Item {
              id: recordButton
              required property var modelData
              width: Style.space(38)
              height: Style.space(38)
              Text {
                anchors.centerIn: parent
                text: recordButton.modelData.glyph
                color: recordButton.modelData.send ? app.accent : (recordArea.containsMouse ? app.urgent : app.muted)
                font.family: app.glyphFamily
                font.pixelSize: Style.font.title
              }
              MouseArea {
                id: recordArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.stopVoice(recordButton.modelData.send)
              }
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------ video messages
  VideoNoteRecorder {
    id: videoNote
    anchors.fill: parent
    app: root.app
    onRecorded: function (chatId, path) {
      var args = { chatId: chatId, path: path }
      if (root.replyToId) args.replyToMessageId = root.replyToId
      root.replyToId = 0
      root.stickToBottom = true
      root.flash("Preparing the video message…")
      client.request("videonote.send", args, function (answer) {
        if (!answer.ok) root.flash("Could not send the video message: " + (answer.error || "unknown error"))
      })
      root.focusComposer()
    }
    onDiscarded: function (path) {
      if (path) client.request("videonote.discard", { path: path })
      root.focusComposer()
    }
    onFailed: function (message) { root.flash(message) }
  }
}
