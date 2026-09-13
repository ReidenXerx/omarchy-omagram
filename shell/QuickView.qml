import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "../app"
import "../app/Model.js" as Model
import "../app/Keymap.js" as Keymap

// The quick view: find a chat, read its latest messages and answer without leaving what you are doing -- in
// words, with a sticker, a voice message or a round video message -- and listen to the voice and round video
// messages people sent, seeing their stickers (bigger under the pointer). The same view is the quick-reply
// overlay, wide, with the chats beside the chat, and the bar's panel, compact, where the chat takes the chats'
// place.
//
// Recording and listening happen in Omagram's service, never here: the shell loads no media player, and a round
// video shows while it records as a small picture the recorder rewrites several times a second. Text from
// Telegram is only ever shown as plain text.
Item {
  id: quick

  property var service: null
  property bool compact: false
  property bool opened: false

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color accent: Color.accent
  property color urgent: Color.urgent
  property color selected: Color.menu.selectedBackground
  property string fontFamily: Style.font.menuFamily

  // Text that reads on this ground, as in the window: the theme's text colour that stands out more, and the
  // accent moved toward it until it reads.
  readonly property color text: quick.ink(Model.bestTextColor(quick.background, [quick.foreground, Color.foreground]))
  readonly property color muted: Qt.rgba(quick.text.r, quick.text.g, quick.text.b, 0.62)
  readonly property color accentText: quick.ink(Model.readableColor(quick.accent, quick.background, quick.text, 4.5))
  readonly property color onAccent: quick.ink(Model.inkOnFill(quick.accent, [quick.text, quick.background], 4.5))

  signal dismissRequested()
  signal openInWindowRequested(real chatId)
  signal tabRequested(int direction)

  function ink(c) { return Qt.rgba(c.r, c.g, c.b, 1) }

  // The first key you have for an action, written as the window writes keys.
  function keyText(id) { return Keymap.label(Keymap.keysFor(quick.keys, id)[0] || "") }

  // "Ctrl + R voice  ·  Ctrl + S stickers" from [action id, word, ...], leaving out actions without a key.
  function hints(pairs) {
    var out = []
    for (var i = 0; i + 1 < pairs.length; i += 2) {
      var key = quick.keyText(pairs[i])
      if (key !== "") out.push(key + " " + pairs[i + 1])
    }
    return out.join("  ·  ")
  }

  // ---------------------------------------------------------------- state

  readonly property bool ready: !!quick.service && quick.service.ready
  readonly property var keys: quick.service ? quick.service.shortcuts : ({})
  readonly property string unavailableText: !quick.service ? "Omagram's service is not loaded"
    : (!quick.service.connected ? "Connecting to Omagram…" : "Omagram is not signed in")
  readonly property var chats: quick.ready ? quick.service.chats : []
  property string query: ""
  readonly property var results: Model.filterChats(quick.chats, quick.query).slice(0, 60)
  property int cursor: 0
  readonly property var highlighted: quick.results[quick.cursor] || null
  property real replyChatId: 0
  readonly property var replyChat: quick.replyChatId ? Model.findChat(quick.chats, quick.replyChatId) : null
  readonly property real shownChatId: quick.replyChatId || (!quick.compact && quick.highlighted ? quick.highlighted.id : 0)
  readonly property var shownChat: quick.replyChat || (!quick.compact ? quick.highlighted : null)
  property var history: []
  property real historyChatId: 0
  property int historySerial: 0
  property bool sending: false
  property string status: ""
  property real nowMs: Date.now()
  property bool stickersOpen: false
  property var stickers: []
  property int stickerCursor: 0
  property var hoverSticker: null
  property var asked: ({})   // sticker pictures already asked for, by file id
  property string toolHint: ""   // what the tool under the pointer is, and its key
  // The keys that work where your typing goes.
  readonly property string keysHint: quick.replyChatId
    ? quick.hints(["quickMessage.send", "sends", "quickMessage.voice", "voice", "quickMessage.videoNote", "round video",
                   "quickMessage.stickers", "stickers", "quickMessage.play", "listen", "quickMessage.back", "back"])
    : quick.hints(["quick.reply", "answers", "quick.openInWindow", "opens in Omagram", "quick.close", "closes"])
  readonly property var playing: quick.service && quick.service.playing ? quick.service.playing : ({ fileId: 0 })
  readonly property var recording: quick.service && quick.service.recording ? quick.service.recording : ({ state: "idle" })
  readonly property bool recordingHere: quick.recording.state !== "idle" && quick.replyChatId !== 0 && quick.recording.chatId === quick.replyChatId
  readonly property Item focusItem: quick.replyChatId ? composer : search

  onQueryChanged: quick.cursor = 0
  onShownChatIdChanged: historyDelay.restart()

  // The clock that moves a recording's time and a message's progress along.
  Timer {
    interval: 200
    repeat: true
    running: quick.opened && (quick.playing.fileId !== 0 || quick.recording.state !== "idle")
    onTriggered: quick.nowMs = Date.now()
  }

  // ---------------------------------------------------------------- opening and closing

  // A fresh start each time it shows; `chatId` answers that chat straight away.
  function reset(chatId) {
    quick.nowMs = Date.now()
    quick.status = ""
    quick.sending = false
    quick.replyChatId = 0
    quick.cursor = 0
    quick.stickersOpen = false
    quick.hoverSticker = null
    quick.asked = ({})
    search.text = ""
    composer.text = ""
    var id = Number(chatId)
    if (Number.isSafeInteger(id) && id !== 0) quick.reply(id)
    else Qt.callLater(function () { search.forceActiveFocus() })
    historyDelay.restart()   // the chat shown may be the one from last time, so nothing else would ask for it
  }

  // It is hidden: a recording half made is thrown away. What is playing goes on.
  function leave() {
    if (quick.recordingHere) quick.stopRecording(false)
    quick.replyChatId = 0
    quick.sending = false
    quick.stickersOpen = false
    quick.hoverSticker = null
  }

  // ---------------------------------------------------------------- chats and answering

  function move(delta) {
    if (quick.results.length === 0) return
    quick.cursor = Math.max(0, Math.min(quick.results.length - 1, quick.cursor + delta))
    chatList.positionViewAtIndex(quick.cursor, ListView.Contain)
  }

  function reply(chatId) {
    if (!chatId) return
    var index = Model.indexOfChat(quick.results, chatId)
    if (index >= 0) {
      quick.cursor = index
      chatList.positionViewAtIndex(index, ListView.Contain)
    }
    quick.replyChatId = chatId
    quick.status = ""
    Qt.callLater(function () { composer.forceActiveFocus() })
  }

  // Esc: out of a recording (thrown away), out of the stickers, then back to finding a chat.
  function back() {
    if (quick.recordingHere) {
      quick.stopRecording(false)
      return
    }
    if (quick.stickersOpen) {
      quick.stickersOpen = false
      quick.hoverSticker = null
      composer.forceActiveFocus()
      return
    }
    quick.replyChatId = 0
    quick.status = ""
    search.forceActiveFocus()
  }

  function send() {
    var text = composer.text
    if (!quick.replyChatId || quick.sending || text.trim() === "" || !quick.ready) return
    quick.sending = true
    quick.service.sendText(quick.replyChatId, text, function (answer) {
      quick.sending = false
      if (answer.ok) {
        composer.text = ""
        quick.dismissRequested()
      } else {
        quick.status = answer.error || "Could not send"
        composer.forceActiveFocus()
      }
    })
  }

  // ---------------------------------------------------------------- voice and round video messages

  function startRecording(kind) {
    if (!quick.replyChatId || !quick.ready || quick.recording.state !== "idle") return
    quick.stickersOpen = false
    quick.status = ""
    quick.service.request(kind === "video" ? "videonote.record" : "voice.start", { chatId: quick.replyChatId }, function (answer) {
      if (!answer.ok) quick.status = answer.error || "Could not record"
    })
  }

  function stopRecording(send) {
    if (!quick.recordingHere) return
    var video = quick.recording.state === "video"
    if (send) quick.sending = true
    quick.service.request(video ? "videonote.stop" : "voice.stop", { send: send }, function (answer) {
      quick.sending = false
      if (!answer.ok) quick.status = answer.error || "Could not send it"
      else if (send) quick.dismissRequested()
    })
  }

  function playable(message) {
    var content = message && message.content ? message.content : null
    return content && (content.kind === "voice" || content.kind === "videoNote") && content.media && content.media.file ? content.media : null
  }

  function togglePlay(message) {
    var media = quick.playable(message)
    if (!media || !quick.ready) return
    if (quick.playing.fileId === media.file.id) {
      quick.service.request("media.stop", {})
      return
    }
    quick.status = ""
    quick.service.request("media.play", { chatId: message.chatId, messageId: message.id, fileId: media.file.id }, function (answer) {
      if (!answer.ok) quick.status = answer.error || "Could not play it"
    })
  }

  // The newest voice or round video message in the chat shown, or stop what is playing.
  function playLatest() {
    if (quick.playing.fileId) {
      quick.service.request("media.stop", {})
      return
    }
    for (var i = quick.history.length - 1; i >= 0; i--) {
      if (quick.playable(quick.history[i])) {
        quick.togglePlay(quick.history[i])
        return
      }
    }
    quick.status = "Nothing here to listen to"
  }

  function progress(media) {
    if (!media || !media.file || quick.playing.fileId !== media.file.id || !(media.duration > 0)) return 0
    var elapsed = (quick.nowMs - quick.playing.startedAt) / 1000 * (quick.playing.rate || 1)
    return Math.max(0, Math.min(1, elapsed / media.duration))
  }

  function duration(seconds) {
    var s = Math.max(0, Math.floor(Number(seconds) || 0))
    return Math.floor(s / 60) + ":" + (s % 60 < 10 ? "0" : "") + (s % 60)
  }

  // ---------------------------------------------------------------- stickers

  function openStickers() {
    if (!quick.replyChatId || !quick.ready || quick.recordingHere) return
    quick.stickersOpen = !quick.stickersOpen
    quick.hoverSticker = null
    if (!quick.stickersOpen) {
      composer.forceActiveFocus()
      return
    }
    quick.stickerCursor = 0
    if (!quick.stickers.length) {
      quick.service.request("stickers.recent", {}, function (answer) {
        if (answer.ok) quick.stickers = (answer.result.stickers || []).slice(0, 48)
      })
    }
    Qt.callLater(function () { stickerGrid.forceActiveFocus() })
  }

  function sendSticker(sticker) {
    if (!sticker || !sticker.file || !quick.replyChatId || quick.sending) return
    quick.sending = true
    quick.service.request("message.sendSticker", { chatId: quick.replyChatId, fileId: sticker.file.id, width: sticker.width || 0,
                                                   height: sticker.height || 0, emoji: sticker.emoji || "" }, function (answer) {
      quick.sending = false
      if (answer.ok) quick.dismissRequested()
      else quick.status = answer.error || "Could not send the sticker"
    })
  }

  function fileOf(file) {
    if (!file) return null
    var known = quick.service && quick.service.files ? quick.service.files[file.id] : null
    return known || file
  }

  // The file of a sticker's picture the shell can draw: the sticker itself when it is WebP, else a still
  // thumbnail. Animated stickers show their emoji when they have neither.
  function stickerPicture(media) {
    if (!media) return null
    if (media.format === "webp") return media.file
    return media.thumb && ["webp", "jpeg", "png"].indexOf(media.thumb.format) >= 0 ? media.thumb.file : null
  }

  function stickerSource(media) {
    var file = quick.fileOf(quick.stickerPicture(media))
    return file && file.path ? Model.fileUrl(file.path) : ""
  }

  // Asked for once each time the view opens, as rows and cells appear, when not here yet.
  function fetchSticker(media) {
    var known = quick.fileOf(quick.stickerPicture(media))
    if (!quick.service || !known || known.path || known.active || quick.asked[known.id]) return
    quick.asked[known.id] = true
    quick.service.download(known.id)
  }

  // ---------------------------------------------------------------- history

  // A short pause, so holding an arrow key does not ask for every chat it passes.
  Timer {
    id: historyDelay
    interval: 120
    onTriggered: quick.loadHistory()
  }

  function loadHistory() {
    var chatId = quick.shownChatId
    var serial = ++quick.historySerial
    if (!chatId || !quick.ready || !quick.opened) {
      quick.history = []
      quick.historyChatId = 0
      return
    }
    if (chatId !== quick.historyChatId) quick.history = []
    quick.fetchHistory(chatId, 0, serial)
  }

  // TDLib answers the first page from its local cache, which can hold a single message; one more page from the
  // oldest message fills the pane.
  function fetchHistory(chatId, fromMessageId, serial) {
    quick.service.request("chat.history", { chatId: chatId, fromMessageId: fromMessageId, limit: 20 }, function (answer) {
      if (serial !== quick.historySerial) return   // a newer chat was chosen meanwhile
      quick.historyChatId = chatId
      var incoming = answer.ok ? (answer.result.messages || []) : []
      var merged = Model.mergeMessages(fromMessageId ? quick.history : [], incoming)
      quick.history = merged
      messageList.positionViewAtEnd()
      if (!fromMessageId && merged.length > 0 && merged.length < 12) quick.fetchHistory(chatId, Model.oldestId(merged), serial)
    })
  }

  // Rows by message id, edited in place as in the window's chat: a new array as the model rebuilt every row.
  ListModel { id: historyRows }
  property var historyIds: []
  onHistoryChanged: quick.historyIds = Model.syncRows(historyRows, quick.historyIds, quick.history)

  Connections {
    target: quick.service
    ignoreUnknownSignals: true

    function onMessageEvent(name, e) {
      if (!quick.opened || !quick.historyChatId) return
      if (e.message && e.message.sendAt) return   // scheduled: part of no history until it goes out
      if (name === "message" && e.message.chatId === quick.historyChatId) {
        quick.history = Model.mergeMessages(quick.history, [e.message])
        messageList.positionViewAtEnd()
      } else if ((name === "messageSent" || name === "messageFailed") && e.message.chatId === quick.historyChatId) {
        quick.history = Model.replaceMessage(quick.history, e.oldMessageId, e.message)
      } else if (name === "messagesDeleted" && e.chatId === quick.historyChatId) {
        quick.history = Model.removeMessages(quick.history, e.messageIds)
      }
    }
  }

  // ---------------------------------------------------------------- the view

  RowLayout {
    anchors.fill: parent
    spacing: Style.spacing.md

    // ---------------------------------------------- the chats
    ColumnLayout {
      visible: !quick.compact || quick.replyChatId === 0
      Layout.preferredWidth: quick.compact ? -1 : Math.round(quick.width * 0.34)
      Layout.fillWidth: quick.compact
      Layout.fillHeight: true
      spacing: Style.space(6)

      Item {
        Layout.fillWidth: true
        implicitHeight: Style.space(34)

        TextInput {
          id: search
          anchors.fill: parent
          verticalAlignment: TextInput.AlignVCenter
          color: quick.text
          selectionColor: quick.selected
          font.family: quick.fontFamily
          font.pixelSize: Style.font.body
          clip: true
          onTextChanged: quick.query = text

          Keys.onPressed: function (event) {
            function is(id) { return Keymap.matchesInText(quick.keys, id, event) }
            if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) quick.tabRequested(event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) ? -1 : 1)
            else if (is("quick.down")) quick.move(1)
            else if (is("quick.up")) quick.move(-1)
            else if (is("quick.pageDown")) quick.move(8)
            else if (is("quick.pageUp")) quick.move(-8)
            else if (is("quick.reply")) {
              if (quick.highlighted) quick.reply(quick.highlighted.id)
              else if (!quick.ready) quick.openInWindowRequested(0)
            }
            else if (is("quick.openInWindow")) quick.openInWindowRequested(quick.highlighted ? quick.highlighted.id : 0)
            else if (is("quick.close")) {
              if (search.text !== "") search.text = ""
              else quick.dismissRequested()
            }
            else return
            event.accepted = true
          }

          Text {
            anchors.fill: parent
            verticalAlignment: Text.AlignVCenter
            visible: search.text === ""
            text: quick.ready ? "Find a chat" : quick.unavailableText
            textFormat: Text.PlainText
            color: quick.muted
            font: search.font
          }
        }

        Rectangle {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: 1
          color: quick.text
          opacity: 0.12
        }
      }

      ListView {
        id: chatList

        WheelScroll { view: chatList }
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        model: quick.results
        currentIndex: quick.cursor
        boundsBehavior: Flickable.StopAtBounds

        delegate: Rectangle {
          id: chatRow
          required property var modelData
          required property int index
          readonly property var last: chatRow.modelData.lastMessage || null
          width: ListView.view.width
          height: Style.space(46)
          radius: Style.cornerRadius
          color: quick.cursor === chatRow.index ? quick.selected
               : (chatArea.containsMouse ? Qt.rgba(quick.text.r, quick.text.g, quick.text.b, 0.05) : "transparent")

          ColumnLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            anchors.topMargin: Style.space(4)
            anchors.bottomMargin: Style.space(4)
            spacing: 0

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Text {
                Layout.fillWidth: true
                text: chatRow.modelData.title || ""
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: quick.text
                font.family: quick.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: chatRow.modelData.unread > 0 && !chatRow.modelData.muted
              }
              Rectangle {
                visible: chatRow.modelData.unread > 0
                implicitHeight: Style.space(16)
                implicitWidth: Math.max(implicitHeight, unreadText.implicitWidth + Style.space(10))
                radius: implicitHeight / 2
                color: chatRow.modelData.muted ? Qt.rgba(quick.text.r, quick.text.g, quick.text.b, 0.25) : quick.accent

                Text {
                  id: unreadText
                  anchors.centerIn: parent
                  text: chatRow.modelData.unread > 999 ? "999+" : String(chatRow.modelData.unread)
                  color: chatRow.modelData.muted ? quick.text : quick.onAccent
                  font.family: quick.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }
            }
            Text {
              Layout.fillWidth: true
              text: chatRow.last ? (chatRow.last.outgoing ? "You: " : (chatRow.modelData.kind !== "private" && chatRow.last.senderName ? chatRow.last.senderName + ": " : ""))
                                   + (chatRow.last.text || "") : ""
              textFormat: Text.PlainText
              elide: Text.ElideRight
              maximumLineCount: 1
              color: quick.muted
              font.family: quick.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          MouseArea {
            id: chatArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
            onClicked: function (mouse) {
              if (mouse.button === Qt.MiddleButton) {
                quick.openInWindowRequested(chatRow.modelData.id)
                return
              }
              quick.cursor = chatRow.index
              quick.reply(chatRow.modelData.id)
            }
          }
        }

        Text {
          anchors.centerIn: parent
          visible: quick.results.length === 0
          text: quick.ready ? "No chat matches" : "Enter opens Omagram"
          textFormat: Text.PlainText
          color: quick.muted
          font.family: quick.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }

    Rectangle {
      visible: !quick.compact
      Layout.fillHeight: true
      implicitWidth: 1
      color: quick.text
      opacity: 0.12
    }

    // ---------------------------------------------- the chat
    ColumnLayout {
      visible: !quick.compact || quick.replyChatId !== 0
      Layout.fillWidth: true
      Layout.fillHeight: true
      spacing: Style.space(6)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        // md-arrow-left U+F004D: back to the chats, in the panel
        Text {
          visible: quick.compact
          text: String.fromCodePoint(0xF004D)
          color: backArea.containsMouse ? quick.text : quick.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.body

          MouseArea {
            id: backArea
            anchors.fill: parent
            anchors.margins: -Style.space(4)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: quick.back()
          }
        }
        Text {
          Layout.fillWidth: true
          text: quick.shownChat ? quick.shownChat.title : ""
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: quick.text
          font.family: quick.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
        // md-bell-sleep U+F00A0: the chat sends silently
        Text {
          visible: !!quick.shownChat && quick.shownChat.silent === true
          text: String.fromCodePoint(0xF00A0)
          color: quick.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
        // md-open-in-new U+F03CC
        Text {
          visible: quick.shownChatId !== 0
          text: String.fromCodePoint(0xF03CC)
          color: openArea.containsMouse ? quick.text : quick.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.body

          MouseArea {
            id: openArea
            anchors.fill: parent
            anchors.margins: -Style.space(4)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: quick.openInWindowRequested(quick.shownChatId)
          }
        }
      }

      Item {
        Layout.fillWidth: true
        Layout.fillHeight: true

        ListView {
          id: messageList

          WheelScroll { view: messageList }
          anchors.fill: parent
          clip: true
          spacing: Style.space(8)
          model: historyRows
          boundsBehavior: Flickable.StopAtBounds

          // Kept at its newest messages while a recording bar or the stickers take room from it, unless you
          // scrolled up.
          property bool followsEnd: true
          onContentYChanged: messageList.followsEnd = messageList.atYEnd
          onHeightChanged: if (messageList.followsEnd) messageList.positionViewAtEnd()

          delegate: Column {
            id: line
            required property real mid
            required property int index
            readonly property var found: Model.rowMessage(quick.history, line.index, line.mid)
            property var kept: null
            onFoundChanged: if (line.found) line.kept = line.found
            Component.onCompleted: {
              line.kept = line.found
              if (line.kind === "sticker") quick.fetchSticker(line.media)
            }
            readonly property var message: line.found || line.kept || Model.NO_MESSAGE
            readonly property var content: line.message.content || ({})
            readonly property string kind: line.content.kind || ""
            readonly property var media: line.content.media || null
            readonly property bool drawn: ["sticker", "voice", "videoNote", "photo"].indexOf(line.kind) >= 0
            onMediaChanged: if (line.kind === "sticker") quick.fetchSticker(line.media)
            width: ListView.view.width
            spacing: Style.space(3)

            Text {
              width: parent.width
              text: (line.message.outgoing ? "You" : (line.message.senderName || (quick.shownChat ? quick.shownChat.title : "")))
                    + "  ·  " + Model.clock(line.message.date)
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: quick.muted
              font.family: quick.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: !line.message.outgoing
            }

            Text {
              visible: text !== ""
              width: parent.width
              text: line.drawn ? (line.content.text || "") : Model.previewOf(line.message)
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              maximumLineCount: 6
              elide: Text.ElideRight
              color: quick.text
              font.family: quick.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            // A sticker, small; bigger under the pointer.
            Item {
              visible: line.kind === "sticker"
              width: Style.space(72)
              height: visible ? Style.space(72) : 0

              Image {
                id: stickerImage
                anchors.fill: parent
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                source: line.kind === "sticker" ? quick.stickerSource(line.media) : ""
                sourceSize.width: 144
                sourceSize.height: 144
              }
              Text {
                anchors.centerIn: parent
                visible: stickerImage.status !== Image.Ready
                text: line.media && line.media.emoji ? line.media.emoji : "Sticker"
                textFormat: Text.PlainText
                color: quick.muted
                font.pixelSize: Style.font.title
              }
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onContainsMouseChanged: {
                  if (containsMouse) quick.hoverSticker = line.media
                  else if (quick.hoverSticker === line.media) quick.hoverSticker = null
                }
              }
            }

            // A photo: its tiny preview, enough to tell what it is.
            Image {
              visible: line.kind === "photo" && !!line.media && !!line.media.mini
              width: visible ? Math.min(parent.width, Style.space(96) * (line.media.width || 1) / Math.max(1, line.media.height || 1)) : 0
              height: visible ? Style.space(96) : 0
              fillMode: Image.PreserveAspectCrop
              source: visible ? Model.miniUrl(line.media.mini) : ""
            }

            // A voice or round video message: listen to it here.
            Rectangle {
              id: listen
              readonly property bool playingThis: !!line.media && !!line.media.file && quick.playing.fileId === line.media.file.id
              visible: line.kind === "voice" || line.kind === "videoNote"
              width: Math.min(parent.width, Style.space(280))
              height: visible ? Style.space(line.kind === "videoNote" ? 64 : 42) : 0
              radius: Style.cornerRadius
              color: Qt.rgba(quick.text.r, quick.text.g, quick.text.b, listenArea.containsMouse ? 0.1 : 0.06)

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(10)

                Item {
                  Layout.preferredWidth: line.kind === "videoNote" ? Style.space(50) : Style.space(28)
                  Layout.preferredHeight: Layout.preferredWidth

                  Image {
                    id: noteFace
                    anchors.fill: parent
                    visible: false
                    fillMode: Image.PreserveAspectCrop
                    source: line.kind === "videoNote" && line.media && line.media.mini ? Model.miniUrl(line.media.mini) : ""
                  }
                  Rectangle {
                    id: noteMask
                    anchors.fill: parent
                    radius: width / 2
                    visible: false
                    layer.enabled: true
                  }
                  MultiEffect {
                    anchors.fill: parent
                    visible: line.kind === "videoNote" && noteFace.status === Image.Ready
                    source: noteFace
                    maskEnabled: true
                    maskSource: noteMask
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 1.0
                  }
                  Rectangle {
                    anchors.centerIn: parent
                    width: Style.space(28)
                    height: width
                    radius: width / 2
                    color: listen.playingThis ? quick.accent : Qt.rgba(quick.background.r, quick.background.g, quick.background.b, 0.75)
                    border.width: listen.playingThis ? 0 : 1
                    border.color: Qt.rgba(quick.text.r, quick.text.g, quick.text.b, 0.3)

                    // md-pause U+F03E4, md-play U+F040A
                    Text {
                      anchors.centerIn: parent
                      text: String.fromCodePoint(listen.playingThis ? 0xF03E4 : 0xF040A)
                      color: listen.playingThis ? quick.onAccent : quick.text
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                    }
                  }
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(4)

                  Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: Style.space(3)
                    radius: height / 2
                    color: Qt.rgba(quick.text.r, quick.text.g, quick.text.b, 0.18)

                    Rectangle {
                      width: parent.width * quick.progress(line.media)
                      height: parent.height
                      radius: height / 2
                      color: quick.accent
                    }
                  }
                  Text {
                    Layout.fillWidth: true
                    text: (line.kind === "videoNote" ? "Round video" : "Voice message") + "  ·  "
                          + (listen.playingThis ? quick.duration(quick.progress(line.media) * (line.media ? line.media.duration : 0)) + " of " : "")
                          + quick.duration(line.media ? line.media.duration : 0)
                          + (line.media && line.media.listened === false && line.media.viewed !== true && !line.message.outgoing ? "  ·  new" : "")
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    color: quick.muted
                    font.family: quick.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              MouseArea {
                id: listenArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: quick.togglePlay(line.message)
              }
            }
          }
        }

        // The sticker under the pointer, bigger.
        Rectangle {
          visible: !!quick.hoverSticker
          z: 10
          anchors.right: parent.right
          anchors.top: parent.top
          width: Style.space(196)
          height: width
          radius: Style.cornerRadius
          color: quick.background
          border.width: 1
          border.color: Qt.rgba(quick.text.r, quick.text.g, quick.text.b, 0.16)

          Image {
            anchors.fill: parent
            anchors.margins: Style.space(10)
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            source: quick.hoverSticker ? quick.stickerSource(quick.hoverSticker) : ""
            sourceSize.width: 384
            sourceSize.height: 384
          }
        }

        Text {
          anchors.centerIn: parent
          visible: historyRows.count === 0 && quick.shownChatId !== 0
          text: "Loading…"
          textFormat: Text.PlainText
          color: quick.muted
          font.family: quick.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      Text {
        Layout.fillWidth: true
        visible: quick.status !== ""
        text: quick.status
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: quick.urgent
        font.family: quick.fontFamily
        font.pixelSize: Style.font.caption
      }

      // ---------------------------------------------- recording
      Rectangle {
        Layout.fillWidth: true
        visible: quick.recordingHere
        implicitHeight: recordRow.implicitHeight + Style.space(20)
        radius: Style.cornerRadius
        color: Qt.rgba(quick.urgent.r, quick.urgent.g, quick.urgent.b, 0.1)
        border.width: 1
        border.color: quick.urgent

        RowLayout {
          id: recordRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(12)

          // What the camera sees, in the circle the message will be.
          Item {
            visible: quick.recording.state === "video"
            Layout.preferredWidth: Style.space(96)
            Layout.preferredHeight: Style.space(96)

            Image {
              id: cameraFace
              anchors.fill: parent
              visible: false
              cache: false
              asynchronous: false
              retainWhileLoading: true
              fillMode: Image.PreserveAspectCrop
              source: quick.recording.state === "video" && quick.recording.preview
                      ? Model.fileUrl(quick.recording.preview) + "?frame=" + Math.floor(quick.nowMs / 150) : ""
            }
            Rectangle {
              id: cameraMask
              anchors.fill: parent
              radius: width / 2
              visible: false
              layer.enabled: true
            }
            MultiEffect {
              anchors.fill: parent
              source: cameraFace
              maskEnabled: true
              maskSource: cameraMask
              maskThresholdMin: 0.5
              maskSpreadAtMin: 1.0
            }
            Rectangle {
              anchors.fill: parent
              radius: width / 2
              color: "transparent"
              border.width: Math.max(1, Style.space(2))
              border.color: quick.urgent
            }
          }

          Rectangle {
            Layout.preferredWidth: Style.space(10)
            Layout.preferredHeight: Style.space(10)
            radius: width / 2
            color: quick.urgent
            opacity: Math.floor(quick.nowMs / 600) % 2 === 0 ? 1 : 0.35
          }
          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(2)

            Text {
              Layout.fillWidth: true
              text: (quick.recording.state === "video" ? "Recording a round video message" : "Recording a voice message") + "   "
                    + quick.duration((quick.nowMs - (quick.recording.startedAt || quick.nowMs)) / 1000)
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              color: quick.text
              font.family: quick.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
            Text {
              Layout.fillWidth: true
              text: quick.sending ? "Sending…" : quick.hints(["quickMessage.send", "sends it", "quickMessage.back", "throws it away"])
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              color: quick.muted
              font.family: quick.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      // ---------------------------------------------- stickers to send
      GridView {
        id: stickerGrid
        visible: quick.stickersOpen
        Layout.fillWidth: true
        // As many rows as the stickers fill, two at most; the rest scroll.
        Layout.preferredHeight: visible ? Math.min(2, Math.max(1, Math.ceil(stickerGrid.count / Math.max(1, Math.floor(stickerGrid.width / stickerGrid.cellWidth))))) * stickerGrid.cellHeight : 0
        clip: true
        cellWidth: Style.space(72)
        cellHeight: Style.space(72)
        model: quick.stickers
        currentIndex: quick.stickerCursor
        boundsBehavior: Flickable.StopAtBounds
        onCurrentIndexChanged: stickerGrid.positionViewAtIndex(stickerGrid.currentIndex, GridView.Contain)

        Keys.onPressed: function (event) {
          function is(id) { return Keymap.matches(quick.keys, id, event) }
          var columns = Math.max(1, Math.floor(stickerGrid.width / stickerGrid.cellWidth))
          var last = quick.stickers.length - 1
          if (is("stickers.right")) quick.stickerCursor = Math.min(last, quick.stickerCursor + 1)
          else if (is("stickers.left")) quick.stickerCursor = Math.max(0, quick.stickerCursor - 1)
          else if (is("stickers.down")) quick.stickerCursor = Math.min(last, quick.stickerCursor + columns)
          else if (is("stickers.up")) quick.stickerCursor = Math.max(0, quick.stickerCursor - columns)
          else if (is("stickers.send")) quick.sendSticker(quick.stickers[quick.stickerCursor])
          else if (is("stickers.close")) quick.back()
          else return
          event.accepted = true
        }

        delegate: Rectangle {
          id: stickerCell
          required property var modelData
          required property int index
          width: stickerGrid.cellWidth - Style.space(4)
          height: width
          radius: Style.cornerRadius
          color: stickerCell.index === quick.stickerCursor ? quick.selected : "transparent"
          Component.onCompleted: quick.fetchSticker(stickerCell.modelData)

          Image {
            anchors.fill: parent
            anchors.margins: Style.space(6)
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            source: quick.stickerSource(stickerCell.modelData)
            sourceSize.width: 128
            sourceSize.height: 128
          }
          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: quick.sendSticker(stickerCell.modelData)
            onContainsMouseChanged: quick.hoverSticker = containsMouse ? stickerCell.modelData : null
          }
        }

        Text {
          anchors.centerIn: parent
          visible: stickerGrid.count === 0
          text: "Your recent stickers show here"
          textFormat: Text.PlainText
          color: quick.muted
          font.family: quick.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      // ---------------------------------------------- composer
      Rectangle {
        Layout.fillWidth: true
        implicitHeight: Math.min(Style.space(120), Math.max(composer.contentHeight, Style.space(20)) + Style.space(16))
        radius: Style.cornerRadius
        color: "transparent"
        border.width: 1
        border.color: composer.activeFocus ? quick.accent : Qt.rgba(quick.text.r, quick.text.g, quick.text.b, 0.2)

        TextEdit {
          id: composer
          anchors.left: parent.left
          anchors.right: tools.visible ? tools.left : parent.right
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          anchors.margins: Style.space(8)
          wrapMode: TextEdit.Wrap
          textFormat: TextEdit.PlainText
          color: quick.text
          selectionColor: quick.selected
          font.family: quick.fontFamily
          font.pixelSize: Style.font.bodySmall
          readOnly: quick.sending || quick.recordingHere

          Keys.onPressed: function (event) {
            function is(id) { return Keymap.matchesInText(quick.keys, id, event) }
            if (quick.recordingHere) {
              if (is("quickMessage.send")) quick.stopRecording(true)
              else if (is("quickMessage.back")) quick.stopRecording(false)
              else return
            }
            else if (is("quickMessage.send")) {
              if (quick.replyChatId) quick.send()
              else if (quick.highlighted) quick.reply(quick.highlighted.id)
            }
            else if (is("quickMessage.back")) quick.back()
            else if (is("quickMessage.openInWindow")) quick.openInWindowRequested(quick.shownChatId)
            else if (is("quickMessage.voice")) quick.startRecording("voice")
            else if (is("quickMessage.videoNote")) quick.startRecording("video")
            else if (is("quickMessage.play")) quick.playLatest()
            else if (is("quickMessage.stickers")) quick.openStickers()
            else return
            event.accepted = true
          }

          Text {
            anchors.fill: parent
            visible: composer.text === ""
            text: quick.recordingHere ? "Recording…" : quick.sending ? "Sending…" : (quick.replyChatId ? "Message" : "Choose a chat to answer")
            textFormat: Text.PlainText
            color: quick.muted
            elide: Text.ElideRight
            font: composer.font
          }
        }

        // md-sticker-emoji U+F0785, md-microphone U+F036C, md-video U+F0567
        Row {
          id: tools
          visible: quick.replyChatId !== 0
          anchors.right: parent.right
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter

          Repeater {
            model: [{ glyph: 0xF0785, action: "stickers", name: "Stickers", key: "quickMessage.stickers" },
                    { glyph: 0xF036C, action: "voice", name: "Voice message", key: "quickMessage.voice" },
                    { glyph: 0xF0567, action: "video", name: "Round video message", key: "quickMessage.videoNote" }]

            delegate: Item {
              id: tool
              required property var modelData
              width: Style.space(30)
              height: Style.space(30)

              Text {
                anchors.centerIn: parent
                text: String.fromCodePoint(tool.modelData.glyph)
                color: toolArea.containsMouse || (tool.modelData.action === "stickers" && quick.stickersOpen) ? quick.text : quick.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
              MouseArea {
                id: toolArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (tool.modelData.action === "stickers") quick.openStickers()
                  else quick.startRecording(tool.modelData.action)
                }
                onContainsMouseChanged: quick.toolHint = containsMouse
                  ? [tool.modelData.name, quick.keyText(tool.modelData.key)].filter(function (s) { return s !== "" }).join("  ·  ") : ""
              }
            }
          }
        }

        MouseArea {
          anchors.left: parent.left
          anchors.right: tools.visible ? tools.left : parent.right
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          cursorShape: Qt.IBeamCursor
          onClicked: {
            if (!quick.replyChatId && quick.highlighted) quick.reply(quick.highlighted.id)
            else composer.forceActiveFocus()
          }
        }
      }

      // What the keys do here, or what the tool under the pointer is.
      Text {
        Layout.fillWidth: true
        visible: !quick.recordingHere
        text: quick.toolHint !== "" ? quick.toolHint : quick.keysHint
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: quick.muted
        font.family: quick.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
