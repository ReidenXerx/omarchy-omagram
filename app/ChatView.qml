import QtQuick
import QtQuick.Layouts
import QtQuick.Dialogs
import Quickshell
import qs.Commons
import "Model.js" as Model
import "Keymap.js" as Keymap

// The open chat: its header, the pinned message, messages and the composer.
//
// Every key is in Keymap.js and can be changed in settings. By default -- composer: Enter sends,
// Ctrl+Shift+Enter sends without sound, Ctrl+Alt+Enter sends later, Shift+Enter adds a line, Esc
// cancels a reply or edit, ↑ in an empty composer edits your last message, pasting a copied image
// offers to send it. Anywhere in the chat: Ctrl+O attaches,
// Ctrl+S opens stickers, Ctrl+; emoji, Ctrl+M jumps to a mention, Ctrl+Shift+M mutes; files
// dropped on the chat are sent. Messages: ↑/↓ or j/k select, Enter opens media, r replies, e
// edits, y copies, f forwards, x selects, p pins, s saves a file, m opens the message's menu,
// d or Delete asks to delete (press again to confirm), Esc returns to the composer. A right
// click opens a message's menu; Ctrl+click selects.
FocusScope {
  id: root

  property var app
  property var client
  property var chat: null
  property var history: []            // the chat's messages, or its open topic's
  property real nowMs: Date.now()

  property real replyToId: 0
  property real editingId: 0
  property int cursor: -1
  property real confirmDeleteId: 0
  property string notice: ""
  property bool stickToBottom: true
  property bool stickersOpen: false
  property bool emojiOpen: false             // the emoji panel, in the stickers' place
  property var reactionTarget: null          // the message the emoji panel finds a reaction for
  onStickersOpenChanged: if (stickersOpen) root.emojiOpen = false
  onEmojiOpenChanged: if (emojiOpen) root.stickersOpen = false

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

  // The message menu and what Telegram allows for its message; the mute menu in the header.
  property var menuMessage: null
  property var menuProperties: null
  property var menuReactions: []
  property bool menuToComposer: false
  readonly property bool modalOpen: messageMenu.visible || muteMenu.visible || sendMenu.visible || rescheduleMenu.visible
                                    || moreMenu.visible || diceMenu.visible || peoplePicker.visible || pollComposer.visible || peopleList.visible || autoDeleteMenu.visible
  readonly property var people: peopleList    // who reacted or has seen a message, for checks from outside
  readonly property var emoji: emojiPanel
  readonly property var polls: pollComposer   // the poll being made, for checks from outside
  property bool blocked: false        // a dialog over the whole window, such as choosing where to forward
  property bool confirmDeleteRevoke: true
  property var pinnedMessage: null
  property bool infoOpen: false

  // What the list shows: the history, or the chat's scheduled messages while scheduledOpen.
  property bool scheduledOpen: false
  property var scheduledMessages: []
  property bool scheduledLoading: false
  readonly property var messages: root.scheduledOpen ? root.scheduledMessages : root.history
  property var sendMenuItems: []
  property var rescheduleItems: []
  property var rescheduleMessage: null

  // Translations under their messages: message id -> null while on its way, then { text, entities }.
  property var translations: ({})

  // A secret chat takes messages once both devices have set it up, and none after it has ended.
  readonly property bool secretBlocked: !!root.chat && root.chat.kind === "secret" && (!root.chat.secret || root.chat.secret.state !== "ready")

  // A forum group opens on its topics; a topic opened shows its messages, and what is sent goes
  // there. Comments under a channel post, or the replies to a message, open the same way: as a
  // thread of the chat they live in. The composer's text belongs to draftChatId (and draftTopicId,
  // a thread's when draftThread) until it is saved.
  readonly property bool forum: !!root.chat && root.chat.forum === true
  readonly property bool threadOpen: !!root.chat && !!app.openTopic && app.openTopic.thread === true && app.openTopic.chatId === root.chat.id
  readonly property real topicId: (root.forum || root.threadOpen) && app.openTopic && app.openTopic.chatId === root.chat.id ? app.openTopic.id : 0
  readonly property bool showTopics: root.forum && !root.topicId
  property real draftChatId: 0
  property real draftTopicId: 0
  property bool draftThread: false

  // Telegram keeps drafts, so they follow you to your other devices; while you type, the chat
  // sees "typing…" as it would from any Telegram app.
  property bool settingText: false
  property string savedDraft: ""
  property string draftBeforeEdit: ""
  property bool editingCaption: false
  property real lastTypingMs: 0

  signal forwardRequested(real fromChatId, var messageIds)
  signal searchInChatRequested()

  function focusComposer() {
    if (root.showTopics) topicList.forceActiveFocus()
    else if (root.composerBlock !== "" && !root.scheduledOpen) blockButton.forceActiveFocus()
    else composer.forceActiveFocus()
  }

  // Where you cannot write, a bar stands in for the message box: join the group or channel, or mute a
  // channel only its admins post in.
  readonly property string composerBlock: Model.composerBlock(root.chat)
  readonly property bool canWrite: root.composerBlock === "" && !root.secretBlocked

  // Once Telegram says you are in, the message box comes back where the bar was, with the keys.
  property real joiningChatId: 0

  function joinChat() {
    if (!root.chat) return
    var chatId = root.chat.id
    var channel = root.chat.kind === "channel"
    root.joiningChatId = chatId
    client.request("chat.join", { chatId: chatId }, function (answer) {
      root.flash(answer.ok ? Model.joinText(answer.result.state, channel) : (answer.error || "Could not join"))
    })
  }

  onComposerBlockChanged: {
    if (root.composerBlock !== "" || !root.chat || root.chat.id !== root.joiningChatId) return
    root.joiningChatId = 0
    composer.forceActiveFocus()
  }

  function focusMessages() {
    if (root.showTopics) { topicList.forceActiveFocus(); return }
    if (!root.messages.length) return
    if (root.cursor < 0 || root.cursor >= root.messages.length) root.cursor = root.messages.length - 1
    messageList.forceActiveFocus()
    messageList.positionViewAtIndex(root.cursor, ListView.Contain)
  }

  // A message found by search: the cursor goes to it if it is loaded.
  function focusMessage(messageId) {
    root.closeScheduled()
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
    messageMenu.close()
    muteMenu.close()
    sendMenu.close()
    rescheduleMenu.close()
    autoDeleteMenu.close()
    draftTimer.stop()
    root.revealed = ({})
    root.pollChoices = ({})
    root.selection = ({})
    root.prompt = null
    root.replyToId = 0
    root.editingId = 0
    root.editingCaption = false
    root.draftBeforeEdit = ""
    root.cursor = -1
    root.confirmDeleteId = 0
    root.notice = ""
    root.stickToBottom = true
    root.stickersOpen = false
    root.emojiOpen = false
    root.reactionTarget = null
    root.pinnedMessage = null
    root.lastTypingMs = 0
    root.translations = ({})
    root.botCommands = null
    root.suggestions = []
    root.attachments = []
    root.joiningChatId = 0
    root.locationOpen = false
    root.dateOpen = false
    root.forgetLinkPreview()
    root.scheduledOpen = false
    root.scheduledMessages = []
    // The chat's draft, as Telegram keeps it: you continue where you left off, on any device.
    root.draftChatId = root.chat ? root.chat.id : 0
    root.draftTopicId = root.topicId
    root.draftThread = root.threadOpen
    root.savedDraft = root.topicId ? (app.openTopic.draft || "") : (root.chat && root.chat.draft ? root.chat.draft : "")
    root.setComposerText(root.savedDraft)
    root.loadPinned()
  }

  // Into a forum topic, or back to the topic list: what was being written stays with the topic
  // it was written in, and the topic opened brings back its own draft.
  function switchTopic() {
    root.leaveChat()
    root.closeScheduled()
    root.draftTopicId = root.topicId
    root.draftThread = root.threadOpen
    root.replyToId = 0
    root.editingId = 0
    root.editingCaption = false
    root.draftBeforeEdit = ""
    root.selection = ({})
    root.cursor = -1
    root.confirmDeleteId = 0
    root.stickToBottom = true
    root.savedDraft = root.topicId ? (app.openTopic.draft || "") : (root.chat.draft || "")
    root.setComposerText(root.savedDraft)
  }

  // ---------------------------------------------------------------- more to send: dice, contact cards, locations

  property bool locationOpen: false
  readonly property var typedLocation: root.locationOpen ? Model.parseLocation(locationField.text) : null

  function openMoreMenu(item) {
    if (!root.chat || !root.canWrite) return
    var at = item ? item.mapToItem(root, 0, 0) : composer.mapToItem(root, composer.cursorRectangle.x, composer.cursorRectangle.y)
    moreMenu.open(at.x, at.y - Style.space(4))
  }

  function morePicked(id) {
    if (!root.chat) return
    if (id === "poll") {
      pollComposer.open(Model.chatTitle(root.chat, app.meId), root.chat.kind === "channel")
    } else if (id === "dice") {
      var at = composer.mapToItem(root, composer.cursorRectangle.x, composer.cursorRectangle.y)
      diceMenu.open(at.x, at.y - Style.space(4))
    } else if (id === "contact") {
      peoplePicker.open(0, [])
    } else if (id === "location") {
      root.openLocationBar()
    }
  }

  // What the + button sends goes where a message would: into the open topic or thread, as a reply.
  function sendExtra(command, args, what) {
    if (!root.chat) return
    args.chatId = root.chat.id
    root.target(args)
    if (root.replyToId) args.replyToMessageId = root.replyToId
    client.request(command, args, function (answer) {
      if (!answer.ok) root.flash("Could not send " + what + ": " + (answer.error || "unknown error"))
    })
    root.replyToId = 0
    root.stickToBottom = true
  }

  function sendDice(emoji) {
    root.sendExtra("message.sendDice", { emoji: emoji }, "the dice")
  }

  function sendPoll(poll) {
    root.focusComposer()
    root.sendExtra("message.sendPoll", { question: poll.question, options: poll.options, anonymous: poll.anonymous,
                                         multiple: poll.multiple, quiz: poll.quiz, correct: poll.correct,
                                         explanation: poll.explanation }, "the poll")
  }

  function shareContact(chatId) {
    root.focusComposer()
    var person = Model.findChat(app.chats || [], chatId)
    if (person && person.userId) root.sendExtra("message.sendContact", { userId: person.userId }, "the contact card")
  }

  property bool dateOpen: false
  readonly property var typedDay: root.dateOpen ? Model.parseDay(dateField.text, root.nowMs) : null

  function openDateBar() {
    if (!root.chat) return
    root.locationOpen = false
    dateField.text = ""
    root.dateOpen = true
    dateField.forceActiveFocus()
  }

  function closeDateBar() {
    root.dateOpen = false
    dateField.text = ""
    root.focusComposer()
  }

  // The last message sent by the end of that day: the chat opens around it.
  function jumpToDay() {
    var start = Model.parseDay(dateField.text, root.nowMs)
    if (start === null || !root.chat) return
    var chatId = root.chat.id
    client.request("chat.messageByDate", { chatId: chatId, date: start + 86399 }, function (answer) {
      if (!root.chat || root.chat.id !== chatId) return
      if (answer.ok && answer.result.messageId) root.jumpTo(answer.result.messageId)
      else root.flash("No messages on or before that day")
    })
    root.closeDateBar()
  }

  function openLocationBar() {
    locationField.text = ""
    root.dateOpen = false
    root.locationOpen = true
    locationField.forceActiveFocus()
  }

  function closeLocationBar() {
    root.locationOpen = false
    locationField.text = ""
    root.focusComposer()
  }

  function sendLocation() {
    var place = Model.parseLocation(locationField.text)
    if (!place) return
    root.sendExtra("message.sendLocation", { latitude: place.latitude, longitude: place.longitude }, "the location")
    root.closeLocationBar()
  }

  function attach(asPhoto) {
    if (!root.chat || !root.canWrite) return
    attachDialog.asPhoto = asPhoto
    attachDialog.open()
  }

  function urlToPath(url) {
    var s = String(url)
    return s.indexOf("file://") === 0 ? decodeURIComponent(s.slice(7)) : ""
  }

  // Files wait above the message box until sent, so a caption can go with them: the text in the box.
  // Ten at most, as many as an album holds; a stray drop of a whole folder does not become a flood.
  property var attachments: []            // [{ path, name, kind }]
  property bool attachAsMedia: true

  function addAttachments(paths, asMedia) {
    if (!root.chat || !paths.length || !root.canWrite) return
    if (!root.attachments.length) root.attachAsMedia = asMedia !== false
    var next = root.attachments.slice()
    for (var i = 0; i < paths.length; i++) {
      if (next.some(function (a) { return a.path === paths[i] })) continue
      if (next.length >= 10) {
        root.flash("Ten files go at once: the rest were left out")
        break
      }
      next.push({ path: paths[i], name: paths[i].split("/").pop(), kind: Model.attachmentKind(paths[i]) })
    }
    root.attachments = next
    root.focusComposer()
  }

  function removeAttachment(index) {
    var next = root.attachments.slice()
    next.splice(index, 1)
    root.attachments = next
  }

  // Photos and videos go as albums, files and music as albums of their own, the caption on the first.
  function sendAttachments(options) {
    var caption = composer.text.replace(/\s+$/, "")
    if (caption.length > 2048) { root.flash("That caption is too long."); return }
    var args = root.target({ chatId: root.chat.id, paths: root.attachments.map(function (a) { return a.path }),
                             asMedia: root.attachAsMedia, caption: caption })
    if (root.replyToId) args.replyToMessageId = root.replyToId
    if (options && typeof options.silent === "boolean") args.silent = options.silent
    if (options && options.sendAt) args.sendAt = options.sendAt
    client.request("message.sendFiles", args, function (answer) {
      if (!answer.ok) root.flash("Could not send: " + (answer.error || "unknown error"))
    })
    root.attachments = []
    draftTimer.stop()
    root.savedDraft = ""
    root.lastTypingMs = 0
    root.setComposerText("")
    root.replyToId = 0
    root.forgetLinkPreview()
    root.stickToBottom = true
  }

  function toggleStickers() {
    if (!root.chat || !root.canWrite) return
    root.stickersOpen = !root.stickersOpen
    if (root.stickersOpen) Qt.callLater(function () { stickerPicker.open() })
    else root.focusComposer()
  }

  readonly property bool shortcutsOn: !!root.chat && !app.settingsOpen && !root.modalOpen && !root.blocked
  Shortcut { sequences: Keymap.keysFor(app.shortcuts, "window.attach"); enabled: root.shortcutsOn; onActivated: root.attach(true) }
  Shortcut { sequences: Keymap.keysFor(app.shortcuts, "window.attachFiles"); enabled: root.shortcutsOn; onActivated: root.attach(false) }
  Shortcut { sequences: Keymap.keysFor(app.shortcuts, "window.stickers"); enabled: root.shortcutsOn; onActivated: root.toggleStickers() }
  Shortcut { sequences: Keymap.keysFor(app.shortcuts, "window.more"); enabled: root.shortcutsOn && root.canWrite; onActivated: root.openMoreMenu(null) }
  Shortcut {
    sequences: Keymap.keysFor(app.shortcuts, "window.voice")
    enabled: root.shortcutsOn && !videoNote.visible
    onActivated: root.recordingVoice ? root.stopVoice(true) : root.startVoice()
  }
  Shortcut {
    sequences: Keymap.keysFor(app.shortcuts, "window.videoNote")
    enabled: root.shortcutsOn && !root.recordingVoice && root.canWrite
    onActivated: videoNote.open(root.chat.id)
  }
  Shortcut { sequences: Keymap.keysFor(app.shortcuts, "voice.send"); enabled: root.recordingVoice && !app.settingsOpen; onActivated: root.stopVoice(true) }
  Shortcut { sequences: Keymap.keysFor(app.shortcuts, "voice.cancel"); enabled: root.recordingVoice && !app.settingsOpen; onActivated: root.stopVoice(false) }
  Shortcut { sequences: Keymap.keysFor(app.shortcuts, "window.emoji"); enabled: root.shortcutsOn; onActivated: root.openEmoji() }
  Shortcut { sequences: Keymap.keysFor(app.shortcuts, "window.nextMention"); enabled: root.shortcutsOn; onActivated: root.nextMention() }
  Shortcut { sequences: Keymap.keysFor(app.shortcuts, "window.nextReaction"); enabled: root.shortcutsOn; onActivated: root.nextReaction() }
  Shortcut { sequences: Keymap.keysFor(app.shortcuts, "window.jumpToDate"); enabled: root.shortcutsOn; onActivated: root.openDateBar() }
  Shortcut { sequences: Keymap.keysFor(app.shortcuts, "window.autoDelete"); enabled: root.shortcutsOn; onActivated: root.openAutoDeleteMenu() }
  Shortcut { sequences: Keymap.keysFor(app.shortcuts, "window.silent"); enabled: root.shortcutsOn; onActivated: root.toggleSilent() }
  Shortcut { sequences: Keymap.keysFor(app.shortcuts, "window.mute"); enabled: root.shortcutsOn; onActivated: app.toggleMute(root.chat.id) }
  Shortcut {
    sequences: Keymap.keysFor(app.shortcuts, "window.pinnedMessage")
    enabled: root.shortcutsOn && !!root.pinnedMessage
    onActivated: root.jumpTo(root.pinnedMessage.id)
  }
  Shortcut { sequences: Keymap.keysFor(app.shortcuts, "window.chatInfo"); enabled: root.shortcutsOn; onActivated: root.toggleInfo() }
  Shortcut { sequences: Keymap.keysFor(app.shortcuts, "window.topicList"); enabled: root.shortcutsOn && root.topicId > 0; onActivated: app.closeTopic() }

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
    if (!root.chat || root.recordingVoice || !root.canWrite) return
    root.recordingNow = Date.now()
    client.request("voice.start", { chatId: root.chat.id }, function (answer) {
      if (!answer.ok) root.flash("Could not record: " + (answer.error || "no microphone"))
    })
  }

  function stopVoice(send) {
    var args = root.target({ send: send })
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

  function composerAction(action, item) {
    if (!root.chat || !root.canWrite) return
    if (action === "later") root.openSendMenu(item)
    else if (action === "attach") root.attach(true)
    else if (action === "emoji") root.openEmoji()
    else if (action === "stickers") root.toggleStickers()
    else if (action === "video") videoNote.open(root.chat.id)
    else if (action === "voice") root.startVoice()
    else if (action === "more") root.openMoreMenu(item)
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
      root.addAttachments(paths, asPhoto)
    }
    onRejected: root.focusComposer()
  }

  DropArea {
    anchors.fill: parent
    enabled: !!root.chat
    onDropped: function (drop) {
      if (!drop.hasUrls) return
      root.addAttachments(drop.urls.map(root.urlToPath).filter(function (p) { return p !== "" }), true)
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
      if (root.lastChatId) root.leaveChat()
      root.lastChatId = root.chat ? root.chat.id : 0
      resetForChat()
    }
  }
  onTopicIdChanged: if (root.chat && root.chat.id === root.draftChatId && root.topicId !== root.draftTopicId) root.switchTopic()
  property real lastChatId: 0

  // The rows shown, one per message id, edited in place as the messages change. A new array as
  // the model rebuilt every row on each message sent, received or edited, and the view spent a
  // frame at the wrong place before it was put back at the bottom.
  ListModel { id: rows }
  property var rowIds: []

  function syncRows() {
    var cursorId = root.cursor >= 0 && root.cursor < root.rowIds.length ? root.rowIds[root.cursor] : 0
    var ids = Model.syncRows(rows, root.rowIds, root.messages)
    root.rowIds = ids
    // The cursor stays on its message when older ones load above it.
    if (cursorId) {
      var at = ids.indexOf(cursorId)
      root.cursor = at >= 0 ? at : Math.min(root.cursor, ids.length - 1)
    }
  }

  onMessagesChanged: {
    root.syncRows()
    if (root.stickToBottom) messageList.positionViewAtEnd()   // before the next frame is drawn
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

  // The comments under a channel post, or the replies to a message: they open as a thread of the
  // chat they live in, and Alt+Left leads back here.
  function openThread(message) {
    if (!message || !root.chat || message.sendAt || message.sending) return
    if (root.threadOpen && (message.id === root.topicId || message.threadId === root.topicId)) return   // this thread
    if (!message.replies && !message.threadId) { root.flash("This message has no comments or replies"); return }
    app.openThread(message.chatId, message.id)
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
    client.request("message.send", root.target({ chatId: root.chat.id, text: text }), function (answer) {
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
      } else if (r.kind === "proxy") {
        root.prompt = { text: "Connect to Telegram through the " + (Model.PROXY_TYPE_NAMES[r.type] || "") + " proxy " + r.server + ":" + r.port + "?",
                        action: "Use it",
                        run: function () {
                          client.request("proxy.addLink", { link: r.link }, function (added) {
                            root.flash(added.ok ? "Connecting through " + r.server + ":" + r.port : (added.error || "Could not add the proxy"))
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
      root.copyText(button.copyText)
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

  // An album is selected as a whole, as it is shown.
  function toggleSelected(message) {
    if (!message || root.scheduledOpen) return
    root.selection = Model.toggleSelection(root.selection, Model.albumIds(root.messages, message))
  }

  function clearSelection() { root.selection = ({}) }

  readonly property bool promptKeysOn: !!root.prompt && !app.settingsOpen && !root.modalOpen && !root.blocked
  Shortcut { sequences: Keymap.keysFor(app.shortcuts, "prompt.accept"); enabled: root.promptKeysOn; onActivated: root.runPrompt(true) }
  Shortcut { sequences: Keymap.keysFor(app.shortcuts, "prompt.cancel"); enabled: root.promptKeysOn; onActivated: root.runPrompt(false) }

  // ---------------------------------------------------------------- the message menu

  function openMenu(message, x, y) {
    if (!message || !root.chat || message.content.kind === "service") return
    root.menuToComposer = composer.activeFocus
    root.menuMessage = message
    root.menuProperties = null
    root.menuReactions = []
    messageMenu.open(x, y)
    if (message.sending || message.sendAt) return   // not sent yet: there is nothing to ask
    var id = message.id
    client.request("message.properties", { chatId: message.chatId, messageId: id }, function (answer) {
      if (answer.ok && messageMenu.visible && root.menuMessage && root.menuMessage.id === id) root.menuProperties = answer.result
    })
    client.request("reactions.available", { chatId: message.chatId, messageId: id }, function (answer) {
      if (answer.ok && messageMenu.visible && root.menuMessage && root.menuMessage.id === id)
        root.menuReactions = (answer.result.emoji || []).slice(0, 8)
    })
  }

  // The selected message's menu, from the keyboard: beside its bubble.
  function openMenuAtCursor() {
    if (!root.selectedMessage) return
    var item = messageList.itemAtIndex(root.cursor)
    var at = item ? item.bubbleItem.mapToItem(root, Math.min(item.bubbleItem.width, Style.space(48)), Math.min(item.bubbleItem.height, Style.space(28)))
                  : Qt.point(root.width / 2, root.height / 2)
    root.openMenu(root.selectedMessage, at.x, at.y)
  }

  function afterMenu() {
    if (root.menuToComposer) root.focusComposer()
    else root.focusMessages()
  }

  function menuPicked(id) {
    var message = root.menuMessage
    if (!message || !root.chat) return
    if (id === "reply") root.startReply(message)
    else if (id === "thread") root.openThread(message)
    else if (id === "favoriteSticker") root.favoriteSticker(message)
    else if (id === "stickerSet") root.openStickerSet(message)
    else if (id === "moreReactions") root.openReactionPicker(message)
    else if (id === "reactions") root.showReactions(message)
    else if (id === "viewers") root.showViewers(message)
    else if (id === "copy") root.copyText(message.content.text)
    else if (id === "link") root.copyLink(message)
    else if (id === "edit") root.startEdit(root.captionHolder(message), true)
    else if (id === "forward") root.forward(Model.albumIds(root.messages, message))
    else if (id === "pin" || id === "unpin") root.setPinned(message, id === "pin")
    else if (id === "select") root.toggleSelected(message)
    else if (id === "open") root.openFile(message)
    else if (id === "save") root.saveFile(message)
    else if (id === "retract") root.retractVote(message)
    else if (id === "deleteAll" || id === "deleteMe") root.confirmDelete(Model.albumIds(root.messages, message), id === "deleteAll")
    else if (id === "translate") root.translate(root.captionHolder(message))
    else if (id === "untranslate") root.untranslate(root.captionHolder(message))
    else if (id === "sendNow") root.reschedule(message, 0)
    else if (id === "reschedule") root.openRescheduleMenu(message)
  }

  function favoriteSticker(message) {
    var media = message && message.content ? message.content.media : null
    if (!media || !media.file) return
    client.request("sticker.favorite", { fileId: media.file.id, favorite: true }, function (answer) {
      root.flash(answer.ok ? "Added to your favorite stickers" : (answer.error || "Could not add it to your favorites"))
    })
  }

  // A sticker's set, in the sticker picker: one of yours, or shown last with A to add it.
  function openStickerSet(message) {
    var media = message && message.content ? message.content.media : null
    if (!media || !media.setId || !root.chat) return
    root.stickersOpen = true
    Qt.callLater(function () { stickerPicker.openSet(media.setId) })
  }
  readonly property var stickers: stickerPicker   // the sticker picker, for checks from outside

  function react(message, emoji) {
    if (!message || !emoji) return
    client.request("reaction.set", { chatId: message.chatId, messageId: message.id, emoji: emoji, chosen: !Model.reactionChosen(message, emoji) },
                   function (answer) { if (!answer.ok) root.flash(answer.error || "Could not react") })
  }

  function retractVote(message) {
    client.request("poll.vote", { chatId: message.chatId, messageId: message.id, optionIds: [] }, function (answer) {
      if (!answer.ok) root.flash(answer.error || "Could not retract the vote")
    })
  }

  // An album's caption is on one of its messages, not always the first.
  function captionHolder(message) {
    if (!message.albumId) return message
    for (var i = 0; i < root.messages.length; i++) {
      var m = root.messages[i]
      if (m.albumId === message.albumId && m.content.text) return m
    }
    return message
  }

  function copyText(text, done) {
    clipboard.text = text
    clipboard.selectAll()
    clipboard.copy()
    root.flash(done || "Copied")
  }

  function copyLink(message) {
    if (!message) return
    client.request("message.link", { chatId: message.chatId, messageId: message.id }, function (answer) {
      if (answer.ok && answer.result.link)
        root.copyText(answer.result.link, answer.result.public ? "Link copied" : "Link copied: it opens only for members of this chat")
      else root.flash(answer.error || "This message has no link")
    })
  }

  function setPinned(message, pinned) {
    if (!message) return
    client.request("message.pin", { chatId: message.chatId, messageId: message.id, pinned: pinned }, function (answer) {
      if (!answer.ok) root.flash(answer.error || (pinned ? "Could not pin the message" : "Could not unpin the message"))
    })
  }

  function loadPinned() {
    if (!root.chat) return
    var chatId = root.chat.id
    client.request("chat.pinned", { chatId: chatId }, function (answer) {
      if (root.chat && root.chat.id === chatId) root.pinnedMessage = answer.ok ? answer.result.message : null
    })
  }

  Connections {
    target: root.app
    function onPinnedChanged(chatId) { if (root.chat && chatId === root.chat.id) root.loadPinned() }
    function onTopicsChanged(chatId) { if (root.forum && chatId === root.chat.id) topicList.refresh() }
    function onScheduledChanged(chatId) { if (root.scheduledOpen && root.chat && chatId === root.chat.id) scheduledReload.restart() }
  }

  // A scheduled message going out arrives as several updates at once: the list loads once for them.
  Timer { id: scheduledReload; interval: 300; onTriggered: root.loadScheduled() }

  // ---------------------------------------------------------------- sending later, scheduled messages

  // The other ways to send what is typed: without sound, at a time, once the other person is online.
  function openSendMenu(item) {
    if (!root.chat || root.editingId || root.secretBlocked) return
    root.sendMenuItems = Model.sendMenu(root.chat, app.meId, root.nowMs, composer.text.trim() !== "")
    if (!root.sendMenuItems.length) { root.flash("Type a message first"); return }
    // Above what opened it: the clock button, or the text cursor.
    var at = item ? item.mapToItem(root, 0, 0) : composer.mapToItem(root, composer.cursorRectangle.x, composer.cursorRectangle.y)
    sendMenu.open(at.x, at.y - Style.space(4))
  }

  function openScheduled() {
    if (!root.chat) return
    if (root.editingId) root.finishEdit()
    root.selection = ({})
    root.scheduledMessages = []
    root.scheduledOpen = true
    root.cursor = -1
    root.stickToBottom = true
    root.loadScheduled()
    messageList.forceActiveFocus()
  }

  function closeScheduled() {
    if (!root.scheduledOpen) return
    if (root.editingId) root.finishEdit()
    root.scheduledOpen = false
    root.scheduledMessages = []
    root.cursor = -1
    root.stickToBottom = true
  }

  function loadScheduled() {
    if (!root.chat || !root.scheduledOpen) return
    var chatId = root.chat.id
    root.scheduledLoading = true
    client.request("chat.scheduled", { chatId: chatId }, function (answer) {
      if (!root.chat || root.chat.id !== chatId || !root.scheduledOpen) return
      root.scheduledLoading = false
      if (!answer.ok) { root.flash(answer.error || "Could not load the scheduled messages"); return }
      root.scheduledMessages = Model.scheduledOrder(answer.result.messages)
      if (root.cursor >= root.scheduledMessages.length) root.cursor = root.scheduledMessages.length - 1
    })
  }

  // sendAt: a date in seconds, -1 once the other person is online, 0 to send it now.
  function reschedule(message, sendAt) {
    if (!message) return
    client.request("message.reschedule", { chatId: message.chatId, messageId: message.id, sendAt: sendAt }, function (answer) {
      if (!answer.ok) { root.flash(answer.error || "Could not change when the message is sent"); return }
      root.flash(sendAt ? "It will be sent " + Model.scheduleText(sendAt, Date.now()) : "Sent")
      scheduledReload.restart()
    })
  }

  function openRescheduleMenu(message) {
    if (!message || !root.chat) return
    root.rescheduleMessage = message
    root.rescheduleItems = Model.rescheduleMenu(root.chat, app.meId, root.nowMs)
    rescheduleMenu.open(messageMenu.menuX, messageMenu.menuY)
  }

  // A GIF from the picker: one of yours, or one the search found.
  function sendGif(item) {
    if (!root.chat || !item || !item.gif || (!item.queryId && !(item.gif.file && item.gif.file.id))) return
    var args = root.target({ chatId: root.chat.id })
    if (item.queryId) {
      args.queryId = item.queryId
      args.resultId = item.resultId
    } else {
      args.fileId = item.gif.file.id
      args.width = item.gif.width || 0
      args.height = item.gif.height || 0
      args.duration = item.gif.duration || 0
    }
    if (root.replyToId) args.replyToMessageId = root.replyToId
    client.request("message.sendGif", args, function (answer) {
      if (!answer.ok) root.flash("Could not send the GIF: " + (answer.error || "unknown error"))
    })
    // As with stickers, the picker stays open for another one.
    root.replyToId = 0
    root.stickToBottom = true
  }

  // ---------------------------------------------------------------- translation

  // Into the language of this computer, shown under the original.
  function translate(message) {
    if (!message || !message.content || !message.content.text) return
    var id = message.id
    var chatId = message.chatId
    var next = root.copyOf(root.translations)
    next[id] = null
    root.translations = next
    client.request("message.translate", { chatId: chatId, messageId: id }, function (answer) {
      if (!root.chat || root.chat.id !== chatId || root.translations[id] !== null) return
      var done = root.copyOf(root.translations)
      if (answer.ok && answer.result.text) {
        done[id] = answer.result
      } else {
        delete done[id]
        root.flash(answer.error || "Could not translate the message")
      }
      root.translations = done
    })
  }

  function untranslate(message) {
    if (!message) return
    var next = root.copyOf(root.translations)
    delete next[message.id]
    root.translations = next
  }

  // ---------------------------------------------------------------- forwarding and deleting

  function forward(ids) {
    if (!root.chat || !ids || !ids.length) return
    root.forwardRequested(root.chat.id, ids.slice(0, 100))
  }

  function forwardSelection() {
    root.forward(Model.selectedIds(root.messages, root.selection))
  }

  function deleteMessages(ids, revoke) {
    if (!root.chat || !ids.length) return
    client.request("message.delete", { chatId: root.chat.id, messageIds: ids.slice(0, 100), revoke: revoke }, function (answer) {
      if (!answer.ok) root.flash("Could not delete: " + (answer.error || "unknown error"))
    })
  }

  function confirmDelete(ids, revoke) {
    if (!ids.length) return
    root.prompt = { text: (ids.length === 1 ? "Delete the message" : "Delete " + ids.length + " messages") + (revoke ? " for everyone?" : " for you?"),
                    action: "Delete", run: function () { root.deleteMessages(ids, revoke); root.clearSelection() } }
  }

  // Telegram deletes for everyone what it allows to be, and the rest only for you.
  function deleteSelection() {
    var ids = Model.selectedIds(root.messages, root.selection)
    if (!ids.length) return
    root.prompt = { text: "Delete " + (ids.length === 1 ? "the message" : ids.length + " messages") + ", for everyone where allowed?",
                    action: "Delete", run: function () { root.deleteMessages(ids, true); root.clearSelection() } }
  }

  function runSelection(action) {
    if (action === "forward") root.forwardSelection()
    else if (action === "copy") root.copy(null)
    else if (action === "delete") root.deleteSelection()
    else root.clearSelection()
  }

  // ---------------------------------------------------------------- files, mentions, emoji, pasting

  function fileOf(message) {
    var media = message && message.content ? message.content.media : null
    return media && media.file ? app.fileState(media.file) : null
  }

  function openFile(message) {
    var file = root.fileOf(message)
    if (!file) return
    if (!file.path) { app.download(file.fileId, 32); root.flash("Downloading… open it again when it is done"); return }
    var name = Model.saveName(message)
    var run = function () {
      client.request("file.open", { fileId: file.fileId }, function (answer) { if (!answer.ok) root.flash(answer.error || "Could not open the file") })
    }
    if (Model.riskyFile(name) || Model.riskyFile(file.path.split("/").pop()))
      root.prompt = { text: "“" + name + "” could run a program on this computer. Open it anyway?", action: "Open", run: run }
    else run()
  }

  function saveFile(message) {
    var file = root.fileOf(message)
    if (!file) return
    if (!file.path) { app.download(file.fileId, 32); root.flash("Downloading… save it again when it is done"); return }
    client.request("file.save", { fileId: file.fileId, fileName: Model.saveName(message) }, function (answer) {
      if (answer.ok) root.flash("Saved to Downloads as " + String(answer.result.path).split("/").pop())
      else root.flash(answer.error || "Could not save the file")
    })
  }

  function openMuteMenu(item) {
    if (!root.chat) return
    var at = item.mapToItem(root, item.width, item.height)
    muteMenu.open(at.x - Style.space(260), at.y)
  }

  function nextMention() {
    if (!root.chat) return
    var chatId = root.chat.id
    client.request("chat.nextMention", root.target({ chatId: chatId }), function (answer) {
      if (!answer.ok || !root.chat || root.chat.id !== chatId) return
      if (answer.result.messageId) {
        root.jumpTo(answer.result.messageId)
        app.markRead(chatId, [answer.result.messageId])   // seen now, so the mention is read
      } else {
        client.request("chat.readMentions", root.target({ chatId: chatId }))
      }
    })
  }

  // The next message of yours with a reaction you have not seen; seeing it reads its reactions.
  function nextReaction() {
    if (!root.chat) return
    var chatId = root.chat.id
    client.request("chat.nextReaction", root.target({ chatId: chatId }), function (answer) {
      if (!answer.ok || !root.chat || root.chat.id !== chatId) return
      if (answer.result.messageId) {
        root.jumpTo(answer.result.messageId)
        app.markRead(chatId, [answer.result.messageId])
      } else {
        client.request("chat.readReactions", root.target({ chatId: chatId }))
      }
    })
  }

  function showReactions(message) {
    if (!message) return
    peopleList.open("Who reacted")
    client.request("message.reactions", { chatId: message.chatId, messageId: message.id }, function (answer) {
      if (!peopleList.visible) return
      if (!answer.ok) { peopleList.show([]); root.flash(answer.error || "Telegram did not say who reacted"); return }
      peopleList.show((answer.result.reactions || []).map(function (r) {
        return { type: r.type, id: r.id, name: r.name, detail: (r.emoji || "a reaction") + "   " + Model.listTime(r.date, root.nowMs) }
      }))
    })
  }

  function showViewers(message) {
    if (!message) return
    peopleList.open("Who has seen it")
    client.request("message.viewers", { chatId: message.chatId, messageId: message.id }, function (answer) {
      if (!peopleList.visible) return
      if (!answer.ok) { peopleList.show([]); root.flash(answer.error || "Telegram did not say who has seen it"); return }
      peopleList.show((answer.result.viewers || []).map(function (v) {
        return { type: "user", id: v.userId, name: v.name, detail: v.date ? "seen " + Model.listTime(v.date, root.nowMs) : "seen" }
      }))
    })
  }

  function openPerson(row) {
    root.focusMessages()
    if (row.type === "user") root.openUser(row.id)
    else app.openChatById(row.id, false)
  }

  function toBottom() {
    if (!root.chat) return
    root.stickToBottom = true
    messageList.positionViewAtEnd()
    app.loadHistory(root.chat.id, 0)
  }

  // ---------------------------------------------------------------- the chat's info

  function openInfo() {
    if (!root.chat) return
    root.infoOpen = true
    Qt.callLater(function () { infoPanel.forceActiveFocus() })
  }

  function closeInfo() {
    root.infoOpen = false
    root.focusComposer()
  }

  function toggleInfo() {
    if (root.infoOpen) root.closeInfo()
    else root.openInfo()
  }

  function infoAction(id) {
    if (!root.chat) return
    if (id === "mute") app.toggleMute(root.chat.id)
    else if (id === "search") root.searchInChatRequested()
    else if (id === "leave") root.askLeaveChat(root.chat)
    else if (id === "clear" || id === "delete") root.askClearChat(root.chat, id === "delete")
    else if (id === "secret") root.startSecretChat(root.chat)
    else if (id === "endSecret") root.askEndSecret(root.chat)
    else if (id === "autoDelete") root.openAutoDeleteMenu()
    else if (id === "hearSound") client.request("sounds.play", { userId: root.chat.userId })
    else if (id === "otherSound") client.request("sounds.another", { userId: root.chat.userId }, function (answer) {
      root.flash(answer.ok ? "A new sound for them: this is it" : (answer.error || "Could not change their sound"))
    })
  }

  // Silent sending, Telegram's own setting of the chat: everything sent here goes without sound until it is off.
  function toggleSilent() {
    if (!root.chat || !root.canWrite) return
    var chatId = root.chat.id
    var silent = !root.chat.silent
    client.request("chat.setSilent", { chatId: chatId, silent: silent }, function (answer) {
      if (!answer.ok) root.flash(answer.error || "Telegram did not take the change")
      else root.flash(silent ? "Silent sending is on: messages here go without sound" : "Silent sending is off")
    })
  }

  // After how long messages in the open chat disappear: from its info, or its key.
  function openAutoDeleteMenu() {
    if (!root.chat) return
    if (!root.chat.canSetAutoDelete) { root.flash("Messages cannot be set to disappear in this chat"); return }
    autoDeleteMenu.open(Math.max(Style.space(12), root.width - Style.space(300)), Style.space(64))
  }

  function setAutoDelete(chat, seconds) {
    client.request("chat.setAutoDelete", { chatId: chat.id, seconds: seconds }, function (answer) {
      if (!answer.ok) root.flash(answer.error || "Telegram did not take the change")
      else root.flash(seconds ? "Messages now disappear after " + Model.autoDeleteText(seconds) : "Messages stay now")
    })
  }

  function askLeaveChat(chat) {
    if (!chat) return
    var chatId = chat.id
    root.prompt = { text: "Leave “" + Model.chatTitle(chat, app.meId) + "”?", action: "Leave",
                    run: function () {
                      client.request("chat.leave", { chatId: chatId }, function (answer) { if (!answer.ok) root.flash(answer.error || "Could not leave") })
                      root.infoOpen = false
                    } }
  }

  // Your copy only: the other side keeps theirs, as when you clear a chat in any Telegram app.
  function askClearChat(chat, removeFromList) {
    if (!chat) return
    var chatId = chat.id
    root.prompt = { text: (removeFromList ? "Delete the chat with “" : "Clear the history of “") + Model.chatTitle(chat, app.meId) + "” for you?",
                    action: removeFromList ? "Delete" : "Clear",
                    run: function () {
                      client.request("chat.clearHistory", { chatId: chatId, removeFromList: removeFromList, revoke: false }, function (answer) {
                        if (!answer.ok) root.flash(answer.error || "Could not clear the history")
                      })
                      if (removeFromList) root.infoOpen = false
                    } }
  }

  // A secret chat lives on this computer only, as Telegram's secret chats do on any device.
  function startSecretChat(chat) {
    if (!chat || !chat.userId) return
    client.request("secret.create", { userId: chat.userId }, function (answer) {
      if (!answer.ok || !answer.result.chatId) { root.flash(answer.error || "Could not start a secret chat"); return }
      root.infoOpen = false
      app.openChatById(answer.result.chatId, false)
    })
  }

  function askEndSecret(chat) {
    if (!chat) return
    var chatId = chat.id
    root.prompt = { text: "End the secret chat with “" + Model.chatTitle(chat, app.meId) + "”? Nothing more can be sent in it.", action: "End",
                    run: function () {
                      client.request("secret.close", { chatId: chatId }, function (answer) { if (!answer.ok) root.flash(answer.error || "Could not end the secret chat") })
                    } }
  }

  // Omarchy's emoji picker types the emoji into whatever has the keyboard: the message box.
  function openEmoji() {
    if (!root.chat) return
    if (root.emojiOpen && !emojiPanel.reacting) {
      root.closeEmoji()
      return
    }
    root.reactionTarget = null
    root.emojiOpen = true
    Qt.callLater(function () { emojiPanel.open() })
  }

  function closeEmoji() {
    root.emojiOpen = false
    root.reactionTarget = null
    root.focusComposer()
  }

  // Every reaction the message may get, found by name: from its menu.
  function openReactionPicker(message) {
    if (!message || !root.chat) return
    var id = message.id
    root.reactionTarget = message
    client.request("reactions.available", { chatId: message.chatId, messageId: id, all: true }, function (answer) {
      if (!root.reactionTarget || root.reactionTarget.id !== id) return
      if (!answer.ok) {
        root.reactionTarget = null
        root.flash(answer.error || "Telegram did not say which reactions it takes")
        return
      }
      root.emojiOpen = true
      Qt.callLater(function () { emojiPanel.openReactions(answer.result.emoji || []) })
    })
  }

  // Ctrl+V: files a file manager copied, or a copied picture, wait above the message box to be sent like attached ones;
  // anything else pastes as text. `asMedia` false (Ctrl+Shift+V) sends them as files, as they are.
  function pasteFromClipboard(asMedia) {
    if (!root.chat || root.editingId || !root.canWrite) {
      composer.paste()
      return
    }
    var chatId = root.chat.id
    client.request("clipboard.files", {}, function (answer) {
      if (!root.chat || root.chat.id !== chatId) return
      var found = answer.ok && answer.result ? answer.result : { paths: [], skipped: 0 }
      var paths = Array.isArray(found.paths) ? found.paths : []
      if (found.skipped > 0)
        root.flash(found.skipped === 1 ? "A folder or an empty or unreadable file was left out"
                                       : found.skipped + " folders or empty or unreadable files were left out")
      if (paths.length) {
        root.addAttachments(paths, asMedia)
        if (asMedia === false) root.attachAsMedia = false
      } else if (!(found.skipped > 0)) {
        composer.paste()
      }
    })
  }

  // ---------------------------------------------------------------- drafts and typing

  function setComposerText(text) {
    root.settingText = true
    composer.text = text
    root.settingText = false
  }

  Timer { id: draftTimer; interval: 1500; onTriggered: root.saveDraft() }

  function saveDraft() {
    if (!root.draftChatId) return
    var text = (root.editingId ? root.draftBeforeEdit : composer.text).replace(/\s+$/, "").slice(0, 4096)
    if (text === root.savedDraft) return
    root.savedDraft = text
    var args = { chatId: root.draftChatId, text: text }
    if (root.draftTopicId) args[root.draftThread ? "threadId" : "topicId"] = root.draftTopicId
    if (root.replyToId && !root.editingId) args.replyToMessageId = root.replyToId
    client.request("chat.draft", args)
  }

  function composerEdited() {
    suggestLater.restart()
    previewLater.restart()
    if (root.settingText || !root.chat) return
    draftTimer.restart()
    if (root.editingId) return
    if (composer.text === "") {
      if (root.lastTypingMs) client.request("chat.action", root.target({ chatId: root.chat.id, action: "cancel" }))
      root.lastTypingMs = 0
    } else if (Date.now() - root.lastTypingMs > 4500) {   // Telegram shows an action for about five seconds
      root.lastTypingMs = Date.now()
      client.request("chat.action", root.target({ chatId: root.chat.id, action: "typing" }))
    }
  }

  // ---------------------------------------------------------------- a link's preview while typing

  property var linkPreview: null              // what Telegram would show for the first link typed
  property string linkPreviewLink: ""         // the link it was asked about
  property string linkPreviewMode: "below"    // under the text, "above" it, or "none"

  Timer { id: previewLater; interval: 700; onTriggered: root.lookUpLinkPreview() }

  function lookUpLinkPreview() {
    var link = root.editingId || root.attachments.length ? "" : Model.composerLink(composer.text)
    if (link === root.linkPreviewLink) return
    root.linkPreviewLink = link
    root.linkPreview = null
    if (!link) { root.linkPreviewMode = "below"; return }
    client.request("message.linkPreview", { text: composer.text.slice(0, 8192) }, function (answer) {
      if (root.linkPreviewLink === link) root.linkPreview = answer.ok ? answer.result.preview : null
    })
  }

  function cycleLinkPreview() {
    if (!root.linkPreview && root.linkPreviewMode === "below") return
    root.linkPreviewMode = ({ below: "above", above: "none", none: "below" })[root.linkPreviewMode]
  }

  function forgetLinkPreview() {
    previewLater.stop()
    root.linkPreview = null
    root.linkPreviewLink = ""
    root.linkPreviewMode = "below"
  }

  // Leaving where the composer's text belongs: its draft is saved and "typing…" ends there.
  function leaveChat() {
    draftTimer.stop()
    root.saveDraft()
    if (root.lastTypingMs && root.draftChatId) {
      var args = { chatId: root.draftChatId, action: "cancel" }
      if (root.draftTopicId) args[root.draftThread ? "threadId" : "topicId"] = root.draftTopicId
      client.request("chat.action", args)
    }
    root.lastTypingMs = 0
  }

  function flash(text) {
    root.notice = text
    noticeTimer.restart()
  }

  Timer { id: noticeTimer; interval: 3500; onTriggered: root.notice = "" }

  // What is sent from here goes into the open topic, or the open thread.
  function target(args) {
    if (root.topicId) args[root.threadOpen ? "threadId" : "topicId"] = root.topicId
    return args
  }

  // `options`: { silent } sends without sound; { sendAt } at a date in seconds, or with -1 once the
  // other person is online.
  function send(options) {
    var text = composer.text.replace(/\s+$/, "")
    if (!root.chat) return
    if (root.editingId) {
      if (!root.editingCaption && !text.trim()) return
      // The service checks the length once the formatting markers are read.
      if (text.length > (root.editingCaption ? 2048 : 8192)) { root.flash((root.editingCaption ? "That caption" : "That message") + " is too long."); return }
      var scheduled = root.scheduledOpen
      client.request("message.edit", { chatId: root.chat.id, messageId: root.editingId, text: text, caption: root.editingCaption }, function (answer) {
        if (!answer.ok) root.flash("Could not edit: " + (answer.error || "unknown error"))
        else if (scheduled) root.loadScheduled()
      })
      root.finishEdit()
      if (scheduled) root.focusMessages()
      return
    }
    if (root.attachments.length) {
      root.sendAttachments(options)
      return
    }
    if (!text.trim()) return
    if (text.length > 8192) { root.flash("That message is too long."); return }
    var args = root.target({ chatId: root.chat.id, text: text })
    if (root.replyToId) args.replyToMessageId = root.replyToId
    if (root.linkPreviewMode !== "below") args.linkPreview = root.linkPreviewMode
    var later = options && options.sendAt ? options.sendAt : 0
    if (options && typeof options.silent === "boolean") args.silent = options.silent
    if (later) args.sendAt = later
    client.request("message.send", args, function (answer) {
      if (!answer.ok) root.flash("Could not send: " + (answer.error || "unknown error"))
      else if (later) root.flash("It will be sent " + Model.scheduleText(later, Date.now()))
    })
    // Sending clears the draft on Telegram's side and ends "typing…".
    draftTimer.stop()
    root.savedDraft = ""
    root.lastTypingMs = 0
    root.setComposerText("")
    root.replyToId = 0
    root.forgetLinkPreview()
    root.stickToBottom = true
  }

  function startReply(message) {
    if (!message) return
    if (root.editingId) root.finishEdit()
    root.replyToId = message.id
    root.focusComposer()
  }

  // Your own text messages and captions; `allowed` when Telegram said this one may be edited.
  function startEdit(message, allowed) {
    if (!message || !message.content || (!allowed && !message.outgoing)) return
    var kind = message.content.kind
    if (kind !== "text" && Model.CAPTION_KINDS.indexOf(kind) < 0) return
    if (!root.editingId) root.draftBeforeEdit = composer.text
    root.replyToId = 0
    root.editingId = message.id
    root.editingCaption = kind !== "text"
    root.setComposerText(message.content.text || "")
    root.focusComposer()
    composer.cursorPosition = composer.length
    // Its formatting comes back as the Markdown it can be typed in, once the service has written it.
    var id = message.id
    var plain = composer.text
    if (message.sending || !(message.content.entities || []).length) return
    client.request("message.markdown", { chatId: message.chatId, messageId: id }, function (answer) {
      if (!answer.ok || root.editingId !== id || composer.text !== plain) return
      root.setComposerText(answer.result.text)
      composer.cursorPosition = composer.length
    })
  }

  // Formatting is typed as Telegram's Markdown, as in its own apps: a formatting key puts the markers
  // around the selection (or at the cursor) and takes them off again.
  function wrapSelection(before, after) {
    var a = composer.selectionStart
    var b = composer.selectionEnd
    var r = Model.markdownToggle(composer.text, a, b, before, after)
    if (r.wrapped) {
      composer.insert(b, after)
      composer.insert(a, before)
    } else {
      composer.remove(b, b + after.length)
      composer.remove(a - before.length, a)
    }
    composer.select(r.start, r.end)
    return r
  }

  // A link: the selection becomes its text, and the cursor waits where the address goes.
  function wrapLink() {
    var hadText = composer.selectionEnd > composer.selectionStart
    var r = root.wrapSelection("[", "]()")
    if (r.wrapped && hadText) composer.cursorPosition = r.end + 2
  }

  // ---------------------------------------------------------------- suggestions while typing

  // @someone in a group, and the /commands of the chat's bots, completing what is typed at the cursor.
  property var suggestions: []            // [{ label, detail, insert, command }]
  property int suggestionCursor: 0
  property var suggestionToken: ({ kind: "", query: "", start: 0, end: 0 })
  property var botCommands: null          // the chat's bots' commands, once asked for
  property int suggestionSerial: 0
  property string dismissedToken: ""      // closed with Esc: it stays closed until what is typed changes

  Timer { id: suggestLater; interval: 150; onTriggered: root.updateSuggestions() }

  function closeSuggestions() {
    var t = root.suggestionToken
    root.dismissedToken = t.kind + ":" + t.start + ":" + t.query
    root.suggestions = []
  }

  function updateSuggestions() {
    var token = Model.suggestToken(composer.text, composer.cursorPosition)
    root.suggestionToken = token
    if (!root.chat || !composer.activeFocus || !token.kind || token.kind + ":" + token.start + ":" + token.query === root.dismissedToken) {
      root.suggestions = []
      return
    }
    var chatId = root.chat.id
    var group = root.chat.kind === "group"
    var serial = ++root.suggestionSerial
    if (token.kind === "command") {
      if (root.botCommands === null) {
        root.botCommands = []
        client.request("chat.commands", { chatId: chatId }, function (answer) {
          if (!root.chat || root.chat.id !== chatId) return
          root.botCommands = answer.ok ? (answer.result.commands || []) : []
          if (root.botCommands.length) root.updateSuggestions()
        })
      }
      root.suggestions = Model.matchCommands(root.botCommands, token.query).map(function (c) {
        return { label: "/" + c.command, detail: c.description + (group && c.bot ? "  ·  @" + c.bot : ""),
                 insert: Model.commandText(c, group), command: true }
      })
      root.suggestionCursor = 0
    } else if (token.kind === "emoji") {
      root.suggestions = emojiPanel.suggest(token.query, 6)
      root.suggestionCursor = 0
    } else if (token.kind === "mention" && group) {
      client.request("chat.mentions", root.target({ chatId: chatId, query: token.query }), function (answer) {
        if (serial !== root.suggestionSerial || !root.chat || root.chat.id !== chatId) return
        root.suggestions = (answer.ok ? answer.result.people || [] : []).map(function (p) {
          return { label: p.name, detail: p.username ? "@" + p.username : (p.bot ? "bot" : ""), insert: Model.mentionText(p), command: false }
        })
        root.suggestionCursor = 0
      })
    } else {
      root.suggestions = []
    }
  }

  // `send`: a bot command goes at once, as picking one does in Telegram's apps.
  function pickSuggestion(index, send) {
    var item = root.suggestions[index]
    var token = root.suggestionToken
    if (!item) return
    composer.remove(token.start, token.end)
    composer.insert(token.start, item.insert)
    composer.cursorPosition = token.start + item.insert.length
    if (item.emojiKey) emojiPanel.record(item.emojiKey)
    root.suggestions = []
    if (send && item.command) root.send()
  }

  function suggestionKey(event) {
    var keys = root.app.shortcuts
    function is(id) { return Keymap.matchesInText(keys, id, event) }
    if (is("suggest.next")) root.suggestionCursor = Math.min(root.suggestions.length - 1, root.suggestionCursor + 1)
    else if (is("suggest.previous")) root.suggestionCursor = Math.max(0, root.suggestionCursor - 1)
    else if (is("suggest.pick")) root.pickSuggestion(root.suggestionCursor, false)
    else if (is("suggest.send")) root.pickSuggestion(root.suggestionCursor, true)
    else if (is("suggest.close")) root.closeSuggestions()
    else return false
    return true
  }

  // Leaving an edit brings back what you were writing before it.
  function finishEdit() {
    root.editingId = 0
    root.editingCaption = false
    root.setComposerText(root.draftBeforeEdit)
    root.draftBeforeEdit = ""
  }

  // d twice deletes: for everyone when Telegram allows it, otherwise only for you.
  function askDelete(message) {
    if (root.selecting) { root.deleteSelection(); return }
    if (!message || !root.chat) return
    if (root.confirmDeleteId === message.id) {
      root.deleteMessages(Model.albumIds(root.messages, message), root.confirmDeleteRevoke)
      root.confirmDeleteId = 0
      return
    }
    var id = message.id
    root.confirmDeleteId = id
    root.confirmDeleteRevoke = true
    root.flash("Press again to delete")
    if (message.sending || message.sendAt) return
    client.request("message.properties", { chatId: message.chatId, messageId: id }, function (answer) {
      if (!answer.ok || root.confirmDeleteId !== id) return
      var p = answer.result
      root.confirmDeleteRevoke = p.canDeleteForAll
      if (!p.canDeleteForAll && !p.canDeleteForMe) {
        root.confirmDeleteId = 0
        root.flash("This message cannot be deleted")
      } else {
        root.flash(p.canDeleteForAll ? "Press again to delete for everyone" : "Press again to delete it for you")
      }
    })
  }

  function copy(message) {
    if (root.selecting) {
      var count = Model.selectedIds(root.messages, root.selection).length
      root.copyText(Model.selectionText(root.messages, root.selection), count === 1 ? "Copied the message" : "Copied " + count + " messages")
      return
    }
    if (message) root.copyText(root.captionHolder(message).content.text || Model.previewOf(message))
  }

  // Plain text only: copied text is never parsed as markup, which would drop tags from a message
  // and could even fetch the images it names.
  TextEdit { id: clipboard; visible: false; textFormat: TextEdit.PlainText }

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
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.right: infoPanel.visible ? infoPanel.left : parent.right
    spacing: 0
    visible: !!root.chat

    // ------------------------------------------------ header
    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: Style.space(56)
      color: "transparent"

      // md-arrow-left U+F004D: from a topic back to the forum's topics, from scheduled messages to the chat
      Item {
        id: backButton
        readonly property bool shown: root.topicId > 0 || root.scheduledOpen
        anchors.left: parent.left
        anchors.leftMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        width: backButton.shown ? Style.space(32) : 0
        height: Style.space(32)
        visible: backButton.shown

        Text {
          anchors.centerIn: parent
          text: String.fromCodePoint(0xF004D)
          color: backArea.containsMouse ? app.foreground : app.muted
          font.family: app.glyphFamily
          font.pixelSize: Style.font.title
        }
        MouseArea {
          id: backArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            if (!root.scheduledOpen) { app.closeTopic(); return }
            root.closeScheduled()
            root.focusComposer()
          }
          onContainsMouseChanged: if (containsMouse) root.flash(root.scheduledOpen ? "Back to the chat   " + Keymap.label(Keymap.keysFor(app.shortcuts, "messages.toComposer")[0] || "")
                                                                : (root.threadOpen ? "Back to the message   " : "Back to the topics   ")
                                                                  + Keymap.label(Keymap.keysFor(app.shortcuts, "window.topicList")[0] || ""))
        }
      }

      Avatar {
        id: headerAvatar
        anchors.left: backButton.right
        anchors.leftMargin: backButton.shown ? Style.space(4) : Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        app: root.app
        chat: root.chat
        size: Style.space(38)
      }

      Column {
        anchors.left: headerAvatar.right
        anchors.leftMargin: Style.space(12)
        anchors.right: headerButtons.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          width: parent.width
          elide: Text.ElideRight
          text: root.scheduledOpen ? "Scheduled messages" : (root.topicId ? app.openTopic.name : (root.chat ? Model.chatTitle(root.chat, app.meId) : ""))
          textFormat: Text.PlainText
          color: app.foreground
          font.family: app.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }
        Text {
          readonly property string activity: !root.chat || root.scheduledOpen ? ""
              : Model.actionText(Model.activeActions(app.chatActions, root.chat.id, app.clockMs), root.chat.kind === "private" || root.chat.kind === "secret")
          width: parent.width
          elide: Text.ElideRight
          text: !root.chat ? "" : (activity
              || (root.scheduledOpen ? Model.chatTitle(root.chat, app.meId)
                  : (root.topicId ? (root.threadOpen ? (app.openTopic.subtitle || Model.chatTitle(root.chat, app.meId))
                                                     : "Topic in " + Model.chatTitle(root.chat, app.meId))
                     : (root.chat.kind === "private"
                        ? (root.chat.userId === app.meId ? "" : (root.chat.bot ? "bot" : Model.statusText(app.userStatuses[root.chat.userId] || root.chat.status, root.nowMs)))
                        : (root.chat.kind === "secret" ? "Secret chat: " + Model.secretStateText(root.chat)
                           : (root.forum ? "Topics" : Model.memberCountText(root.chat.memberCount, root.chat.kind === "channel")))))))
          textFormat: Text.PlainText
          color: activity ? app.accentText : app.muted
          font.family: app.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // Search in this chat; its notifications.
      Row {
        id: headerButtons
        anchors.right: parent.right
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter

        Repeater {
          // md-magnify U+F0349; md-bell-outline U+F009C, md-bell-off U+F009B; md-information-outline U+F02FD
          // md-calendar-clock U+F00F0: the chat has scheduled messages
          model: (root.chat && root.chat.hasScheduled && !root.scheduledOpen ? [
            { glyph: String.fromCodePoint(0xF00F0), action: "scheduled", hint: "Scheduled messages" }
          ] : []).concat([
            { glyph: String.fromCodePoint(0xF0349), action: "search",
              hint: "Search in this chat   " + Keymap.label(Keymap.keysFor(app.shortcuts, "window.searchInChat")[0] || "") },
            { glyph: String.fromCodePoint(0xF02FD), action: "info",
              hint: "The chat's info   " + Keymap.label(Keymap.keysFor(app.shortcuts, "window.chatInfo")[0] || "") },
            { glyph: String.fromCodePoint(root.chat && root.chat.muted ? 0xF009B : 0xF009C), action: "mute",
              hint: (root.chat && root.chat.muted ? "Muted" : "Notifications are on") + "   " + Keymap.label(Keymap.keysFor(app.shortcuts, "window.mute")[0] || "") }
          ])
          delegate: Item {
            id: headerButton
            required property var modelData
            width: Style.space(36)
            height: Style.space(36)

            Text {
              anchors.centerIn: parent
              text: headerButton.modelData.glyph
              color: headerArea.containsMouse ? app.foreground : app.muted
              font.family: app.glyphFamily
              font.pixelSize: Style.font.title
            }
            MouseArea {
              id: headerArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                var action = headerButton.modelData.action
                if (action === "search") root.searchInChatRequested()
                else if (action === "info") root.toggleInfo()
                else if (action === "scheduled") root.openScheduled()
                else root.openMuteMenu(headerButton)
              }
              onContainsMouseChanged: if (containsMouse) root.flash(headerButton.modelData.hint)
            }
          }
        }
      }

      Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: app.border; opacity: 0.35 }
    }

    // ------------------------------------------------ the pinned message
    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: visible ? Style.space(44) : 0
      visible: !!root.pinnedMessage && !root.showTopics && !root.scheduledOpen
      color: Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, 0.03)

      Rectangle {
        x: Style.space(18)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(3)
        height: parent.height - Style.space(14)
        radius: width / 2
        color: app.accent
      }
      Column {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(30)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(18)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          text: "Pinned message   " + Keymap.label(Keymap.keysFor(app.shortcuts, "window.pinnedMessage")[0] || "")
          color: app.muted
          font.family: app.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
        Text {
          width: parent.width
          elide: Text.ElideRight
          text: root.pinnedMessage ? Model.previewOf(root.pinnedMessage) : ""
          textFormat: Text.PlainText
          color: app.foreground
          font.family: app.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: if (root.pinnedMessage) root.jumpTo(root.pinnedMessage.id)
      }
      Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: app.border; opacity: 0.25 }
    }

    // ------------------------------------------------ a forum's topics
    TopicList {
      id: topicList
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: root.showTopics
      app: root.app
      client: root.client
      chat: root.forum ? root.chat : null
      nowMs: root.nowMs
      onOpened: function (topic) {
        app.selectTopic(topic)
        Qt.callLater(root.focusComposer)
      }
    }

    // ------------------------------------------------ messages
    Item {
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: !root.showTopics

      ListView {
        id: messageList
        anchors.fill: parent
        clip: true
        model: rows
        spacing: Style.space(2)
        boundsBehavior: Flickable.StopAtBounds
        topMargin: Style.space(12)
        // Space under the newest message as a footer, not a bottom margin: going to the end counts
        // a footer, and would stop short of a margin.
        footer: Item { width: 1; height: Style.space(12) }

        WheelScroll {
          view: messageList
          onScrolled: {
            root.stickToBottom = messageList.atYEnd
            if (messageList.contentY <= messageList.originY + Style.space(200) && messageList.count > 0) root.loadOlder()
          }
        }

        onMovementEnded: root.stickToBottom = atYEnd
        // The message box growing or shrinking, or a bar above it coming and going, keeps the
        // newest message in view.
        onHeightChanged: if (root.stickToBottom) positionViewAtEnd()
        onAtYBeginningChanged: if (atYBeginning && count > 0 && moving) root.loadOlder()
        onContentYChanged: {
          // Manual contentY changes from WheelScroll can update atYEnd after its callback. Track
          // the settled position here too, or a later fullscreen resize snaps the user to the end.
          root.stickToBottom = atYEnd
          if (contentY <= originY + Style.space(200) && count > 0 && (moving || activeFocus)) root.loadOlder()
        }

        Keys.onPressed: function (event) {
          var keys = root.app.shortcuts
          var selected = root.selectedMessage
          function is(id) { return Keymap.matches(keys, id, event) }
          // A scheduled message cannot be replied to, forwarded, selected, pinned or linked yet.
          if (root.scheduledOpen && ["messages.reply", "messages.forward", "messages.select", "messages.pin", "messages.link", "messages.thread"].some(is)) {
            event.accepted = true
            return
          }
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
          else if (is("messages.edit")) root.startEdit(selected ? root.captionHolder(selected) : null)
          else if (is("messages.copy")) root.copy(selected)
          else if (is("messages.delete")) root.askDelete(selected)
          else if (is("messages.play") || is("messages.open")) {
            var item = messageList.itemAtIndex(root.cursor)
            if (item && item.mediaItem && item.mediaItem.media) {
              if (is("messages.play")) item.mediaItem.togglePlay()
              else item.mediaItem.activate()
            }
          }
          else if (is("messages.toComposer")) {
            if (root.selecting) root.clearSelection()
            else {
              root.closeScheduled()
              root.cursor = -1
              root.focusComposer()
            }
          }
          else if (is("messages.toList")) root.toList()
          else if (is("messages.last")) { root.cursor = root.messages.length - 1; root.stickToBottom = true; positionViewAtEnd() }
          else if (is("messages.menu")) root.openMenuAtCursor()
          else if (is("messages.forward")) {
            if (root.selecting) root.forwardSelection()
            else if (selected) root.forward(Model.albumIds(root.messages, selected))
          }
          else if (is("messages.select")) root.toggleSelected(selected)
          else if (is("messages.pin")) { if (selected) root.setPinned(selected, !selected.pinned) }
          else if (is("messages.save")) { if (selected) root.saveFile(selected) }
          else if (is("messages.link")) { if (selected) root.copyLink(selected) }
          else if (is("messages.thread")) root.openThread(selected)
          else if (is("messages.speed")) root.flash("Voice and video messages play at " + Model.speedLabel(app.cycleSpeed()))
          else return
          event.accepted = true
        }

        delegate: MessageRow {
          width: messageList.width
          view: root
          app: root.app
          messages: root.messages
          motionEnabled: root.app.windowFocused
                         && Model.inViewport(y, height, messageList.contentY, messageList.height, Style.space(160))
        }
      }

      Text {
        anchors.centerIn: parent
        visible: root.scheduledOpen && messageList.count === 0
        text: root.scheduledLoading ? "Loading…" : "No scheduled messages"
        color: app.muted
        font.family: app.fontFamily
        font.pixelSize: Style.font.body
      }

      // Your unread mentions, and the way back to the newest messages with how many are unread.
      Column {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: Style.space(22)
        anchors.bottomMargin: Style.space(18)
        spacing: Style.space(14)

        FloatButton {
          visible: count > 0 && !root.scheduledOpen
          glyph: String.fromCodePoint(0xF02D5)   // md-heart-outline
          count: root.chat && root.chat.unreadReactions > 0 ? root.chat.unreadReactions : 0
          onActivated: root.nextReaction()
        }
        FloatButton {
          visible: !!root.chat && root.chat.mentions > 0 && !root.scheduledOpen
          glyph: String.fromCodePoint(0xF0065)   // md-at
          count: root.chat ? root.chat.mentions : 0
          onActivated: root.nextMention()
        }
        FloatButton {
          visible: !!root.chat && messageList.count > 0 && !messageList.atYEnd && !root.scheduledOpen
          glyph: String.fromCodePoint(0xF0140)   // md-chevron-down
          count: root.chat ? root.chat.unread : 0
          onActivated: root.toBottom()
        }
      }
    }

    // ------------------------------------------------ reply / edit / notice bar, and questions
    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: visible ? Style.space(40) : 0
      visible: !!root.prompt || root.notice !== "" || (root.composerBlock === "" && (!!root.replyTo || !!root.editing))
      color: Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, 0.04)

      Rectangle {
        width: Style.space(3)
        height: parent.height
        color: root.prompt ? app.urgent : (root.notice !== "" && !root.replyTo && !root.editing ? app.muted : app.accent)
      }

      Text {
        readonly property string cancelKey: Keymap.label(Keymap.keysFor(app.shortcuts, "composer.cancel")[0] || "")
        anchors.left: parent.left
        anchors.leftMargin: Style.space(18)
        anchors.right: promptButtons.visible ? promptButtons.left : parent.right
        anchors.rightMargin: Style.space(18)
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        textFormat: Text.PlainText
        color: app.foreground
        font.family: app.fontFamily
        font.pixelSize: Style.font.bodySmall
        text: {
          if (root.prompt) return root.prompt.text
          if (root.notice !== "") return root.notice
          if (root.editing) return (root.editingCaption ? "Editing the caption" : "Editing") + "   " + cancelKey + " to cancel"
          if (root.replyTo) return "Replying to " + (root.replyTo.outgoing ? "yourself" : (root.replyTo.senderName || "message")) + ": "
                                   + Model.previewOf(root.replyTo) + "   " + cancelKey + " to cancel"
          return ""
        }
      }

      // A question's answers, with their keys.
      Row {
        id: promptButtons
        visible: !!root.prompt
        anchors.right: parent.right
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)

        Repeater {
          model: root.prompt ? [
            { accept: true, label: root.prompt.action + "   " + Keymap.label(Keymap.keysFor(app.shortcuts, "prompt.accept")[0] || "") },
            { accept: false, label: "Cancel   " + Keymap.label(Keymap.keysFor(app.shortcuts, "prompt.cancel")[0] || "") }
          ] : []
          delegate: Rectangle {
            id: promptAnswer
            required property var modelData
            width: promptLabel.implicitWidth + Style.space(18)
            height: Style.space(28)
            radius: Style.cornerRadius
            color: promptArea.containsMouse ? Qt.rgba(app.accent.r, app.accent.g, app.accent.b, 0.3)
                 : (promptAnswer.modelData.accept ? Qt.rgba(app.accent.r, app.accent.g, app.accent.b, 0.14) : "transparent")
            Text {
              id: promptLabel
              anchors.centerIn: parent
              text: promptAnswer.modelData.label
              textFormat: Text.PlainText
              color: app.foreground
              font.family: app.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: promptAnswer.modelData.accept
            }
            MouseArea {
              id: promptArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.runPrompt(promptAnswer.modelData.accept)
            }
          }
        }
      }
    }

    // ------------------------------------------------ selected messages
    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: visible ? Style.space(40) : 0
      visible: root.selecting && !!root.chat
      color: Qt.rgba(app.accent.r, app.accent.g, app.accent.b, 0.1)

      Text {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(18)
        anchors.verticalCenter: parent.verticalCenter
        text: Model.selectedIds(root.messages, root.selection).length + " selected"
        color: app.foreground
        font.family: app.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }

      Row {
        anchors.right: parent.right
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)

        Repeater {
          model: [
            { action: "forward", label: "Forward", key: "messages.forward" },
            { action: "copy", label: "Copy", key: "messages.copy" },
            { action: "delete", label: "Delete", key: "messages.delete" },
            { action: "clear", label: "Cancel", key: "messages.toComposer" }
          ]
          delegate: Rectangle {
            id: selectionAction
            required property var modelData
            width: selectionLabel.implicitWidth + Style.space(18)
            height: Style.space(28)
            radius: Style.cornerRadius
            color: selectionArea.containsMouse ? Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, 0.12) : "transparent"
            Text {
              id: selectionLabel
              anchors.centerIn: parent
              text: selectionAction.modelData.label + "   " + Keymap.label(Keymap.keysFor(app.shortcuts, selectionAction.modelData.key)[0] || "")
              color: selectionAction.modelData.action === "delete" ? app.urgent : app.foreground
              font.family: app.fontFamily
              font.pixelSize: Style.font.caption
            }
            MouseArea {
              id: selectionArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.runSelection(selectionAction.modelData.action)
            }
          }
        }
      }
    }

    // ------------------------------------------------ a bot's keyboard
    Rectangle {
      id: botKeyboard
      Layout.fillWidth: true
      visible: !!root.keyboard && root.keyboardHiddenFor !== root.keyboard.messageId && !root.recordingVoice && !root.showTopics
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
                color: keyArea.containsMouse ? Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, 0.16)
                                             : Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, 0.08)
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
      chatId: root.chat ? root.chat.id : 0
      onGifPicked: function (item) { root.sendGif(item) }
      onNotice: function (text) { root.flash(text) }
      onPicked: function (sticker) {
        if (!root.chat) return
        app.sendSticker(root.chat.id, sticker, root.replyToId, function (answer) {
          if (!answer.ok) root.flash("Could not send: " + (answer.error || "unknown error"))
        })
        // The picker stays open for another sticker; Esc closes it and goes back to the message box.
        root.replyToId = 0
        root.stickToBottom = true
      }
      onClosed: {
        root.stickersOpen = false
        root.focusComposer()
      }
    }

    // ------------------------------------------------ emoji
    EmojiPanel {
      id: emojiPanel
      Layout.fillWidth: true
      Layout.preferredHeight: root.emojiOpen ? Style.space(300) : 0
      visible: root.emojiOpen
      app: root.app
      onInserted: function (text) {
        var at = composer.cursorPosition
        composer.insert(at, text)
        composer.cursorPosition = at + text.length
      }
      onReacted: function (emoji) {
        var message = root.reactionTarget
        root.reactionTarget = null
        root.emojiOpen = false
        root.focusMessages()
        root.react(message, emoji)
      }
      onClosed: root.closeEmoji()
      onReadyChanged: if (ready) root.updateSuggestions()
    }

    // ------------------------------------------------ a date to go to
    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: visible ? dateColumn.implicitHeight + Style.space(20) : 0
      visible: root.dateOpen && !!root.chat && !root.showTopics
      color: Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, 0.03)

      Rectangle { width: parent.width; height: 1; color: app.border; opacity: 0.35 }

      Column {
        id: dateColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(10)
        spacing: Style.space(4)

        Field {
          id: dateField
          width: parent.width
          app: root.app
          label: "Go to a date: today, yesterday, 1 Sep, 01.09.2026 or 2026-09-01   ·   Enter goes   ·   Esc cancels"
          placeholder: "1 Sep"
          maximumLength: 32
          error: dateField.text.trim() !== "" && root.typedDay === null ? "That is not a day to go to" : ""
          onAccepted: root.jumpToDay()
          Keys.onEscapePressed: root.closeDateBar()
        }
        Text {
          visible: root.typedDay !== null
          text: "Goes to the last message of " + Model.dayLabel(root.typedDay || 0, root.nowMs)
          textFormat: Text.PlainText
          color: app.muted
          font.family: app.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    // ------------------------------------------------ a location to send
    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: visible ? locationColumn.implicitHeight + Style.space(20) : 0
      visible: root.locationOpen && !!root.chat && !root.showTopics
      color: Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, 0.03)

      Rectangle { width: parent.width; height: 1; color: app.border; opacity: 0.35 }

      Column {
        id: locationColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(10)
        spacing: Style.space(4)

        Field {
          id: locationField
          width: parent.width
          app: root.app
          label: "A location: coordinates, or a link from Google Maps or OpenStreetMap   ·   Enter sends   ·   Esc cancels"
          placeholder: "50.4501, 30.5234"
          maximumLength: 2048
          error: locationField.text.trim() !== "" && !root.typedLocation ? "No coordinates in that: paste a map link, or type them like 50.4501, 30.5234" : ""
          onAccepted: root.sendLocation()
          Keys.onEscapePressed: root.closeLocationBar()
        }
        Text {
          visible: !!root.typedLocation
          text: "Sends the place at " + Model.locationText(root.typedLocation)
          textFormat: Text.PlainText
          color: app.muted
          font.family: app.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    // ------------------------------------------------ files waiting to be sent
    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: visible ? Style.space(82) : 0
      visible: root.attachments.length > 0 && !root.showTopics
      color: Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, 0.03)

      Rectangle { width: parent.width; height: 1; color: app.border; opacity: 0.35 }

      ListView {
        id: attachmentList
        anchors.left: parent.left
        anchors.right: attachmentMode.left
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        height: Style.space(64)
        orientation: ListView.Horizontal
        spacing: Style.space(8)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.attachments

        delegate: Rectangle {
          id: attachment
          required property var modelData
          required property int index
          width: Style.space(64)
          height: Style.space(64)
          radius: Style.cornerRadius
          color: Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, 0.06)
          clip: true

          Image {
            id: thumbnail
            anchors.fill: parent
            visible: status === Image.Ready
            source: attachment.modelData.kind === "photo" ? "file://" + attachment.modelData.path : ""
            sourceSize.width: 128
            sourceSize.height: 128
            asynchronous: true
            fillMode: Image.PreserveAspectCrop
          }
          // What has no picture shows what it is: md-video U+F0567, md-music-note U+F0387, md-file-outline U+F0224
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            y: Style.space(10)
            visible: !thumbnail.visible
            text: String.fromCodePoint(attachment.modelData.kind === "video" ? 0xF0567 : (attachment.modelData.kind === "audio" ? 0xF0387 : 0xF0224))
            color: app.foreground
            font.family: app.glyphFamily
            font.pixelSize: Style.font.title
          }
          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: Style.space(4)
            visible: !thumbnail.visible
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideMiddle
            text: attachment.modelData.name
            textFormat: Text.PlainText
            color: app.muted
            font.family: app.fontFamily
            font.pixelSize: Style.font.caption
          }
          // md-close U+F0156: leave this one out
          Rectangle {
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: Style.space(3)
            width: Style.space(18)
            height: width
            radius: width / 2
            color: Qt.rgba(0, 0, 0, removeArea.containsMouse ? 0.8 : 0.55)
            Text {
              anchors.centerIn: parent
              text: String.fromCodePoint(0xF0156)
              color: "white"
              font.family: app.glyphFamily
              font.pixelSize: Style.font.caption
            }
            MouseArea {
              id: removeArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.removeAttachment(attachment.index)
            }
          }
        }
      }

      Column {
        id: attachmentMode
        anchors.right: parent.right
        anchors.rightMargin: Style.space(14)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(250)
        spacing: Style.space(4)

        // Photos and videos as themselves, or everything as files.
        Rectangle {
          width: parent.width
          height: Style.space(28)
          radius: Style.cornerRadius
          color: Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, modeArea.containsMouse ? 0.16 : 0.08)
          Text {
            anchors.centerIn: parent
            width: parent.width - Style.space(12)
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: root.attachAsMedia ? "As photos and videos" : "As files"
            textFormat: Text.PlainText
            color: app.foreground
            font.family: app.fontFamily
            font.pixelSize: Style.font.caption
          }
          MouseArea {
            id: modeArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.attachAsMedia = !root.attachAsMedia
            onContainsMouseChanged: if (containsMouse) root.flash(root.attachAsMedia ? "Click to send them as files, as they are"
                                                                                   : "Click to send photos and videos as themselves")
          }
        }
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
          text: (root.attachments.length === 1 ? "1 file" : root.attachments.length + " files") + "   "
                + Keymap.label(Keymap.keysFor(app.shortcuts, "composer.cancel")[0] || "") + " takes them away"
          textFormat: Text.PlainText
          color: app.muted
          font.family: app.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    // ------------------------------------------------ suggestions while typing
    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: visible ? suggestionList.height + Style.space(9) : 0
      visible: root.suggestions.length > 0 && !root.showTopics
      color: Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, 0.03)

      Rectangle { width: parent.width; height: 1; color: app.border; opacity: 0.35 }

      ListView {
        id: suggestionList
        x: Style.space(10)
        y: Style.space(5)
        width: parent.width - Style.space(20)
        height: Math.min(6, count) * Style.space(34)
        clip: true
        interactive: count > 6
        boundsBehavior: Flickable.StopAtBounds
        model: root.suggestions
        currentIndex: root.suggestionCursor
        onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

        delegate: Rectangle {
          id: suggestion
          required property var modelData
          required property int index
          width: suggestionList.width
          height: Style.space(34)
          radius: Style.cornerRadius
          color: suggestion.index === root.suggestionCursor ? app.selected
               : (suggestionArea.containsMouse ? Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, 0.05) : "transparent")

          Text {
            id: suggestionLabel
            anchors.left: parent.left
            anchors.leftMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            text: suggestion.modelData.label
            textFormat: Text.PlainText
            color: app.foreground
            font.family: app.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
          Text {
            anchors.left: suggestionLabel.right
            anchors.leftMargin: Style.space(12)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            text: suggestion.modelData.detail
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: app.muted
            font.family: app.fontFamily
            font.pixelSize: Style.font.caption
          }
          MouseArea {
            id: suggestionArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              root.pickSuggestion(suggestion.index, false)
              composer.forceActiveFocus()
            }
          }
        }
      }
    }

    // ------------------------------------------------ a link's preview, as it will be sent
    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: visible ? linkPreviewRow.implicitHeight + Style.space(14) : 0
      visible: !!root.chat && root.composerBlock === "" && !root.editingId
               && (!!root.linkPreview || (root.linkPreviewMode === "none" && root.linkPreviewLink !== ""))
      color: Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, 0.03)

      Rectangle { width: Style.space(3); height: parent.height; color: root.linkPreviewMode === "none" ? app.muted : app.accent }

      RowLayout {
        id: linkPreviewRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(18)
        anchors.rightMargin: Style.space(14)
        spacing: Style.space(12)

        Column {
          Layout.fillWidth: true
          spacing: Style.space(1)

          Text {
            width: parent.width
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: root.linkPreviewMode === "none" ? "No link preview"
                : (root.linkPreview ? (root.linkPreview.siteName || root.linkPreview.displayUrl || "Link preview") : "")
            color: root.linkPreviewMode === "none" ? app.muted : app.accentText
            font.family: app.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
          Text {
            visible: root.linkPreviewMode !== "none" && text !== ""
            width: parent.width
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: root.linkPreview ? (root.linkPreview.title || root.linkPreview.description || "") : ""
            color: app.foreground
            font.family: app.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        Text {
          readonly property string key: Keymap.label(Keymap.keysFor(app.shortcuts, "composer.linkPreview")[0] || "")
          text: ({ below: "Under the text", above: "Above the text", none: "Left out" })[root.linkPreviewMode] + "   " + key + " changes it"
          textFormat: Text.PlainText
          color: app.muted
          font.family: app.fontFamily
          font.pixelSize: Style.font.caption

          MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.cycleLinkPreview() }
        }
      }
    }

    // ------------------------------------------------ where you cannot write
    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: visible ? Style.space(58) : 0
      visible: !!root.chat && root.composerBlock !== "" && !root.showTopics && !root.scheduledOpen
      color: "transparent"

      Rectangle { width: parent.width; height: 1; color: app.border; opacity: 0.35 }

      Row {
        anchors.centerIn: parent
        spacing: Style.space(14)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: root.composerBlock === "join" ? (root.chat && root.chat.kind === "channel" ? "You are not in this channel" : "You are not in this group")
              : root.composerBlock === "channel" ? "Only the channel's admins post here"
              : root.composerBlock === "left" ? "You left this group: someone in it can add you back"
              : "You can't send messages here"
          textFormat: Text.PlainText
          color: app.muted
          font.family: app.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Button {
          id: blockButton
          anchors.verticalCenter: parent.verticalCenter
          visible: root.composerBlock === "join" || root.composerBlock === "channel"
          app: root.app
          primary: root.composerBlock === "join"
          text: root.composerBlock === "join" ? (root.chat && root.chat.kind === "channel" ? "Join channel" : "Join group")
              : (root.chat && root.chat.muted ? "Unmute" : "Mute")
          onClicked: {
            if (root.composerBlock === "join") root.joinChat()
            else if (root.chat) app.toggleMute(root.chat.id)
          }
        }
      }
    }

    // ------------------------------------------------ composer
    Rectangle {
      Layout.fillWidth: true
      // With scheduled messages listed, only while one of them is being edited.
      visible: !root.showTopics && (!root.scheduledOpen || root.editingId > 0) && root.composerBlock === ""
      // 20 of outer margin and 16 of inner padding around the text, plus room for the caret.
      Layout.preferredHeight: Math.min(Style.space(180), composer.implicitHeight + Style.space(40))
      color: "transparent"

      Rectangle { width: parent.width; height: 1; color: app.border; opacity: 0.35 }

      Rectangle {
        visible: !root.recordingVoice && !root.secretBlocked
        anchors.left: parent.left
        anchors.right: composerButtons.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.margins: Style.space(10)
        radius: Style.cornerRadius
        readonly property bool silent: !!root.chat && root.chat.silent === true
        color: Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, silent ? 0.02 : 0.05)
        border.width: Math.max(1, Style.space(1.5))
        // Silent sending draws the box as an outline, focused or not: a message without sound is never a surprise.
        border.color: silent ? Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, composer.activeFocus ? 0.55 : 0.3)
                             : (composer.activeFocus ? app.accent : "transparent")

        Rectangle {
          id: silentChip
          visible: parent.silent
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.leftMargin: Style.space(8)
          anchors.topMargin: Style.space(7)
          width: silentChipRow.implicitWidth + Style.space(14)
          height: silentChipRow.implicitHeight + Style.space(6)
          radius: height / 2
          color: Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, 0.08)

          Row {
            id: silentChipRow
            anchors.centerIn: parent
            spacing: Style.space(5)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: String.fromCodePoint(0xF00A0)   // md-bell-sleep
              color: app.foreground
              font.family: app.glyphFamily
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Silent"
              textFormat: Text.PlainText
              color: app.foreground
              font.family: app.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggleSilent()
          }
        }

        Flickable {
          id: composerFlick
          anchors.fill: parent
          anchors.leftMargin: silentChip.visible ? silentChip.width + Style.space(16) : Style.space(12)
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

            onTextChanged: root.composerEdited()
            onCursorPositionChanged: suggestLater.restart()

            Keys.onPressed: function (event) {
              var keys = root.app.shortcuts
              function is(id) { return Keymap.matchesInText(keys, id, event) }
              // Suggestions, while they show, take the keys that move through them.
              if (root.suggestions.length && root.suggestionKey(event)) {
                event.accepted = true
                return
              }
              // A text box takes Enter before any shortcut can, so a question is answered here.
              if (root.prompt && is("prompt.accept")) root.runPrompt(true)
              else if (root.prompt && is("prompt.cancel")) root.runPrompt(false)
              // Copied files or a copied picture wait to be sent; with neither on the clipboard the text is pasted.
              else if (event.matches(StandardKey.Paste)) root.pasteFromClipboard(root.attachments.length ? root.attachAsMedia : true)
              else if (is("composer.pasteFiles")) root.pasteFromClipboard(false)
              else if (is("composer.sendSilent")) root.send({ silent: true })
              else if (is("composer.later")) root.openSendMenu(null)
              else if (is("composer.bold")) root.wrapSelection("**", "**")
              else if (is("composer.italic")) root.wrapSelection("__", "__")
              else if (is("composer.strikethrough")) root.wrapSelection("~~", "~~")
              else if (is("composer.code")) root.wrapSelection("`", "`")
              else if (is("composer.spoiler")) root.wrapSelection("||", "||")
              else if (is("composer.link")) root.wrapLink()
              else if (is("composer.linkPreview")) root.cycleLinkPreview()
              else if (is("composer.send")) root.send()
              else if (is("composer.newLine")) composer.insert(composer.cursorPosition, "\n")
              else if (is("composer.cancel")) {
                if (root.editingId) {
                  root.finishEdit()
                  if (root.scheduledOpen) root.focusMessages()
                }
                else if (root.replyToId) root.replyToId = 0
                else if (root.attachments.length) root.attachments = []
                else if (root.selecting) root.clearSelection()
                else root.focusMessages()
              }
              else if (is("composer.editLast") && composer.text === "") root.startEdit(Model.lastOwnEditable(root.messages))
              else if (is("composer.toMessages")) root.focusMessages()
              else return
              event.accepted = true
            }

            Text {
              visible: composer.text === ""
              text: root.editing ? (root.editingCaption ? "Caption" : "Edit message")
                  : root.attachments.length ? "A caption for the files, if you like   "
                                              + Keymap.label(Keymap.keysFor(app.shortcuts, "composer.send")[0] || "") + " to send"
                  : (root.threadOpen ? (app.openTopic.name === "Comments" ? "Comment" : "Reply") : "Message") + "   "
                    + Keymap.label(Keymap.keysFor(app.shortcuts, "composer.send")[0] || "")
                    + (root.chat && root.chat.silent ? " to send without sound, " : " to send, ")
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
        visible: !root.recordingVoice && !root.secretBlocked
        anchors.right: parent.right
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0

        Repeater {
          // md-bell-sleep U+F00A0 (its outline U+F0A93), md-send-clock-outline U+F1164, md-emoticon-outline U+F01F2, md-paperclip U+F03E2,
          // md-plus-circle-outline U+F0419, md-sticker-emoji U+F0785, md-video U+F0567, md-microphone U+F036C
          model: [
            { glyph: String.fromCodePoint(root.chat && root.chat.silent ? 0xF00A0 : 0xF0A93), action: "silent",
              hint: (root.chat && root.chat.silent ? "Silent sending is on: messages here go without sound" : "Silent sending in this chat")
                    + "   " + Keymap.label(Keymap.keysFor(app.shortcuts, "window.silent")[0] || "") },
            { glyph: String.fromCodePoint(0xF1164), action: "later",
              hint: "Send later or without sound   " + Keymap.label(Keymap.keysFor(app.shortcuts, "composer.later")[0] || "") },
            { glyph: String.fromCodePoint(0xF01F2), action: "emoji", hint: "Emoji   " + Keymap.label(Keymap.keysFor(app.shortcuts, "window.emoji")[0] || "") },
            { glyph: String.fromCodePoint(0xF03E2), action: "attach", hint: "Attach photos or files   " + Keymap.label(Keymap.keysFor(app.shortcuts, "window.attach")[0] || "") },
            { glyph: String.fromCodePoint(0xF0419), action: "more", hint: "A poll, dice, a contact card or a location   " + Keymap.label(Keymap.keysFor(app.shortcuts, "window.more")[0] || "") },
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
              color: buttonArea.containsMouse || (composerButton.modelData.action === "stickers" && root.stickersOpen)
                     || (composerButton.modelData.action === "silent" && !!root.chat && root.chat.silent) ? app.foreground : app.muted
              font.family: app.glyphFamily
              font.pixelSize: Style.font.title
            }
            MouseArea {
              id: buttonArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (composerButton.modelData.action === "silent") root.toggleSilent()
                else root.composerAction(composerButton.modelData.action, composerButton)
              }
              onContainsMouseChanged: if (containsMouse) root.flash(composerButton.modelData.hint)
            }
          }
        }
      }

      // A secret chat not set up yet, or ended: why nothing can be written.
      Row {
        visible: root.secretBlocked
        anchors.centerIn: parent
        spacing: Style.space(8)

        // md-lock-outline U+F0341
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: String.fromCodePoint(0xF0341)
          color: app.muted
          font.family: app.glyphFamily
          font.pixelSize: Style.font.body
        }
        Text {
          readonly property string stateText: Model.secretStateText(root.chat)
          anchors.verticalCenter: parent.verticalCenter
          text: stateText.charAt(0).toUpperCase() + stateText.slice(1)
          textFormat: Text.PlainText
          color: app.muted
          font.family: app.fontFamily
          font.pixelSize: Style.font.body
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
                color: recordButton.modelData.send ? app.accentText : (recordArea.containsMouse ? app.urgent : app.muted)
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

  // ------------------------------------------------ the chat's info
  ChatInfo {
    id: infoPanel
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: Math.min(Style.space(380), Math.max(Style.space(300), root.width * 0.38))
    visible: root.infoOpen && !!root.chat
    app: root.app
    client: root.client
    chat: root.chat
    nowMs: root.nowMs
    onClosed: root.closeInfo()
    onOpenUser: function (userId) { root.openUser(userId) }
    onOpenMessage: function (messageId) { root.jumpTo(messageId) }
    onLinkActivated: function (link) { root.openLink(link, null) }
    onActionRequested: function (id) { root.infoAction(id) }
    onCopyRequested: function (text, done) { root.copyText(text, done) }
  }

  // ------------------------------------------------ video messages
  VideoNoteRecorder {
    id: videoNote
    anchors.fill: parent
    app: root.app
    onRecorded: function (chatId, path) {
      var args = root.target({ chatId: chatId, path: path })
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

  // ------------------------------------------------ menus
  ContextMenu {
    id: messageMenu
    anchors.fill: parent
    app: root.app
    items: Model.messageMenu(root.menuMessage, root.menuProperties,
                             !!root.menuMessage && root.translations[root.captionHolder(root.menuMessage).id] !== undefined, root.chat)
           .concat(root.menuReactions.length ? [{ id: "moreReactions", label: "More reactions…" }] : [])
    reactions: root.menuReactions
    chosen: root.menuMessage ? (root.menuMessage.reactions || []).filter(function (r) { return r.chosen }).map(function (r) { return r.emoji }) : []
    onDismissed: root.afterMenu()
    onPicked: function (id) { root.afterMenu(); root.menuPicked(id) }
    onReacted: function (emoji) { root.afterMenu(); root.react(root.menuMessage, emoji) }
  }

  ContextMenu {
    id: muteMenu
    anchors.fill: parent
    app: root.app
    items: Model.muteMenu(root.chat)
    onDismissed: root.focusComposer()
    onPicked: function (id) {
      root.focusComposer()
      if (root.chat && Model.muteSeconds(id) >= 0) app.muteChat(root.chat.id, Model.muteSeconds(id))
    }
  }

  ContextMenu {
    id: autoDeleteMenu
    anchors.fill: parent
    app: root.app
    items: Model.autoDeleteMenu(root.chat)
    onDismissed: root.focusComposer()
    onPicked: function (id) {
      root.focusComposer()
      if (root.chat && Model.autoDeleteSeconds(id) >= 0) root.setAutoDelete(root.chat, Model.autoDeleteSeconds(id))
    }
  }

  PeopleList {
    id: peopleList
    anchors.fill: parent
    app: root.app
    onPicked: function (row) { root.openPerson(row) }
    onDismissed: root.focusMessages()
  }

  // The + button: a poll, dice, a person's contact card, a location.
  PollComposer {
    id: pollComposer
    anchors.fill: parent
    app: root.app
    onSendRequested: function (poll) { root.sendPoll(poll) }
    onDismissed: root.focusComposer()
  }

  ContextMenu {
    id: moreMenu
    anchors.fill: parent
    app: root.app
    upward: true
    items: Model.moreMenu(root.chat, app.meId)
    onDismissed: root.focusComposer()
    onPicked: function (id) { root.morePicked(id) }
  }

  ContextMenu {
    id: diceMenu
    anchors.fill: parent
    app: root.app
    upward: true
    items: Model.diceMenu()
    onDismissed: root.focusComposer()
    onPicked: function (id) {
      root.focusComposer()
      if (id.indexOf("dice:") === 0) root.sendDice(id.slice(5))
    }
  }

  // Whose contact card to share: the forward picker, people only.
  ForwardPicker {
    id: peoplePicker
    anchors.fill: parent
    app: root.app
    chats: root.app && root.app.chats ? root.app.chats : []
    peopleOnly: true
    title: "Share whose contact card?"
    onPicked: function (chatId, title) { root.shareContact(chatId) }
    onDismissed: root.focusComposer()
  }

  ContextMenu {
    id: sendMenu
    anchors.fill: parent
    app: root.app
    upward: true
    items: root.sendMenuItems
    onDismissed: root.focusComposer()
    onPicked: function (id) {
      root.focusComposer()
      if (id === "scheduled") { root.openScheduled(); return }
      var choice = Model.sendChoice(id)
      if (choice) root.send(choice)
    }
  }

  ContextMenu {
    id: rescheduleMenu
    anchors.fill: parent
    app: root.app
    items: root.rescheduleItems
    onDismissed: root.focusMessages()
    onPicked: function (id) {
      root.focusMessages()
      var choice = Model.sendChoice(id)
      if (choice && root.rescheduleMessage) root.reschedule(root.rescheduleMessage, choice.sendAt)
    }
  }

  // A round button floating over the messages, with a count on it.
  component FloatButton: Rectangle {
    id: floatButton
    property string glyph: ""
    property int count: 0
    signal activated()

    width: Style.space(42)
    height: width
    radius: width / 2
    color: root.app.background
    border.width: 1
    border.color: Qt.rgba(root.app.foreground.r, root.app.foreground.g, root.app.foreground.b, floatArea.containsMouse ? 0.4 : 0.18)

    Text {
      anchors.centerIn: parent
      text: floatButton.glyph
      color: floatArea.containsMouse ? root.app.accentText : root.app.foreground
      font.family: root.app.glyphFamily
      font.pixelSize: Style.font.title
    }
    Rectangle {
      visible: floatButton.count > 0
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.verticalCenter: parent.top
      height: Style.space(18)
      width: Math.max(height, countText.implicitWidth + Style.space(10))
      radius: height / 2
      color: root.app.accent
      Text {
        id: countText
        anchors.centerIn: parent
        text: floatButton.count > 999 ? "999+" : String(floatButton.count)
        color: root.app.onAccent
        font.family: root.app.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }
    MouseArea {
      id: floatArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: floatButton.activated()
    }
  }
}
