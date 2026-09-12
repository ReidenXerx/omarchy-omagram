import QtQuick
import QtQuick.Layouts
import qs.Commons
import "Model.js" as Model
import "Keymap.js" as Keymap

// The chat list: folder tabs over the chats of the chosen list. Typing a search finds chats
// in every list, and messages in all chats -- or in the open chat, with Ctrl+Shift+F.
//
// Keyboard (every key can be changed in settings): Ctrl+K or / searches, ↑/↓ or j/k move, Enter
// opens, [ and ] switch tabs, p pins or unpins, a archives or unarchives, m mutes or unmutes, the
// Menu key opens a chat's menu (so does a right click), Esc leaves the search, Tab goes to the
// open chat. Alt+↑/↓ steps through chats from anywhere.
FocusScope {
  id: root

  property var app
  property var chats: []        // the chosen tab's chats, in order
  property var allChats: []     // every known chat, for search and tab counts
  property var tabs: []
  property string listKey: "main"
  property real openChatId: 0
  property real nowMs: Date.now()
  property int cursor: 0

  // Message search: everywhere, or in one chat.
  property real scopeChatId: 0
  property string scopeTitle: ""
  property var messageResults: []
  property string nextOffset: ""
  property real nextFromMessageId: 0
  property bool searching: false
  property int searchSerial: 0

  readonly property int resultsMax: 300
  readonly property string query: search.text.trim()
  readonly property bool searchMode: root.query !== ""
  readonly property var rows: root.buildRows()
  readonly property bool hasMoreMessages: root.searchMode && !root.searching && root.messageResults.length < root.resultsMax
    && (root.scopeChatId ? root.nextFromMessageId > 0 : root.nextOffset !== "")

  signal activated(real chatId)
  signal messageActivated(real chatId, real messageId)
  signal listSelected(string key)
  signal pinRequested(real chatId)
  signal archiveRequested(real chatId)
  signal toChat()
  signal settingsRequested()
  signal muteRequested(real chatId)
  signal readRequested(real chatId)

  property var menuChat: null
  readonly property bool modalOpen: chatMenu.visible

  function buildRows() {
    var out = []
    if (!root.searchMode) {
      for (var i = 0; i < root.chats.length; i++) out.push({ kind: "chat", chat: root.chats[i] })
      return out
    }
    if (!root.scopeChatId) {
      var every = Model.chatsIn(root.allChats, "main").concat(Model.chatsIn(root.allChats, "archive"))
      var found = Model.filterChats(every, root.query, root.app.meId)
      for (var j = 0; j < found.length && j < 50; j++) out.push({ kind: "chat", chat: found[j] })
    }
    if (root.messageResults.length || root.searching)
      out.push({ kind: "header", title: root.scopeChatId ? "Messages in " + root.scopeTitle : "Messages" })
    for (var k = 0; k < root.messageResults.length; k++) out.push({ kind: "message", message: root.messageResults[k] })
    return out
  }

  function focusSearch() {
    search.forceActiveFocus()
    search.selectAll()
  }

  function focusList() {
    listView.forceActiveFocus()
  }

  function searchFor(text) {
    root.scopeChatId = 0
    search.text = text
    root.focusSearch()
  }

  function searchInChat(chatId, title) {
    search.text = ""   // first: clearing the text ends any earlier scope
    root.scopeChatId = chatId
    root.scopeTitle = title || "this chat"
    root.focusSearch()
  }

  function selectable(i) {
    return i >= 0 && i < root.rows.length && root.rows[i].kind !== "header"
  }

  function move(delta) {
    if (!root.rows.length) return
    var dir = delta < 0 ? -1 : 1
    var i = Math.max(0, Math.min(root.rows.length - 1, root.cursor + delta))
    while (!root.selectable(i) && i + dir >= 0 && i + dir < root.rows.length) i += dir
    while (!root.selectable(i) && i - dir >= 0 && i - dir < root.rows.length) i -= dir
    root.cursor = i
    listView.positionViewAtIndex(i, ListView.Contain)
    if (root.hasMoreMessages && i >= root.rows.length - 3) root.searchMessages(true)
  }

  function openCursor() {
    var row = root.rows[root.cursor]
    if (!row) return
    if (row.kind === "chat") root.activated(row.chat.id)
    else if (row.kind === "message") root.messageActivated(row.message.chatId, row.message.id)
  }

  function cursorChat() {
    var row = root.rows[root.cursor]
    return row && row.kind === "chat" ? row.chat : null
  }

  function openChatMenu(chat, x, y) {
    if (!chat) return
    root.menuChat = chat
    chatMenu.open(x, y)
  }

  function openMenuAtCursor() {
    var chat = root.cursorChat()
    if (!chat) return
    var item = listView.itemAtIndex(root.cursor)
    var at = item ? item.mapToItem(root, Style.space(64), item.height / 2) : Qt.point(Style.space(40), Style.space(120))
    root.openChatMenu(chat, at.x, at.y)
  }

  function chatMenuPicked(id) {
    var chat = root.menuChat
    if (!chat) return
    if (id === "open") root.activated(chat.id)
    else if (id === "read") root.readRequested(chat.id)
    else if (id === "pin" || id === "unpin") root.pinRequested(chat.id)
    else if (id === "mute" || id === "unmute") root.muteRequested(chat.id)
    else if (id === "archive" || id === "unarchive") root.archiveRequested(chat.id)
  }

  // From anywhere in the window: open the chat above or below the one that is open.
  function step(delta) {
    if (!root.chats.length) return
    var index = Model.indexOfChat(root.chats, root.openChatId)
    var next = index < 0 ? 0 : Math.max(0, Math.min(root.chats.length - 1, index + delta))
    if (!root.searchMode) {
      root.cursor = next
      listView.positionViewAtIndex(next, ListView.Contain)
    }
    root.activated(root.chats[next].id)
  }

  function tabStep(delta) {
    if (!root.tabs.length) return
    var at = 0
    for (var i = 0; i < root.tabs.length; i++) if (root.tabs[i].key === root.listKey) at = i
    root.listSelected(root.tabs[(at + delta + root.tabs.length) % root.tabs.length].key)
  }

  // ---------------------------------------------------------------- message search

  // A pause while typing, so each keystroke does not become a request to Telegram.
  Timer {
    id: searchDelay
    interval: 350
    onTriggered: root.searchMessages(false)
  }

  onQueryChanged: {
    root.cursor = 0
    root.messageResults = []
    root.nextOffset = ""
    root.nextFromMessageId = 0
    root.searchSerial++
    root.searching = root.searchMode
    if (root.searchMode) {
      searchDelay.restart()
    } else {
      searchDelay.stop()
      root.scopeChatId = 0
    }
  }

  function searchMessages(more) {
    var q = root.query
    if (!q) return
    var serial = root.searchSerial
    var args = { query: q, limit: 30 }
    if (root.scopeChatId) {
      args.chatId = root.scopeChatId
      if (more) args.fromMessageId = root.nextFromMessageId
    } else if (more) {
      args.offset = root.nextOffset
    }
    root.searching = true
    root.app.request("messages.search", args, function (answer) {
      if (serial !== root.searchSerial) return   // the query changed meanwhile
      root.searching = false
      if (!answer.ok) return
      var r = answer.result
      var found = r.messages || []
      root.messageResults = (more ? root.messageResults.concat(found) : found).slice(0, root.resultsMax)
      root.nextOffset = r.nextOffset || ""
      root.nextFromMessageId = r.nextFromMessageId || 0
    })
  }

  onRowsChanged: root.cursor = Math.max(0, Math.min(root.cursor, root.rows.length - 1))
  onListKeyChanged: {
    root.cursor = 0
    listView.positionViewAtBeginning()
  }
  onOpenChatIdChanged: {
    if (root.searchMode) return
    var index = Model.indexOfChat(root.chats, root.openChatId)
    if (index >= 0) root.cursor = index
  }

  ColumnLayout {
    anchors.fill: parent
    spacing: 0

    // ------------------------------------------------ search
    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: Style.space(56)
      color: "transparent"

      Rectangle {
        anchors.fill: parent
        anchors.margins: Style.space(10)
        radius: Style.cornerRadius
        color: Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, 0.05)
        border.width: Math.max(1, Style.space(1.5))
        border.color: search.activeFocus ? app.accent : "transparent"

        TextInput {
          id: search
          anchors.fill: parent
          anchors.leftMargin: Style.space(12)
          anchors.rightMargin: Style.space(40)
          verticalAlignment: TextInput.AlignVCenter
          clip: true
          color: app.foreground
          selectionColor: app.accent
          font.family: app.fontFamily
          font.pixelSize: Style.font.body
          maximumLength: 128

          // In the search box a key that types a letter is text, never a shortcut.
          Keys.onPressed: function (event) {
            var keys = root.app.shortcuts
            if (Keymap.matchesInText(keys, "list.down", event) || event.key === Qt.Key_Tab) {
              root.cursor = 0
              root.move(0)
              root.focusList()
            } else if (Keymap.matchesInText(keys, "list.clearSearch", event)) {
              if (search.text !== "") search.text = ""
              else root.scopeChatId = 0
              root.focusList()
            } else if (Keymap.matchesInText(keys, "list.open", event)) {
              root.cursor = 0
              root.move(0)
              root.openCursor()
            } else {
              return
            }
            event.accepted = true
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            visible: search.text === ""
            text: root.scopeChatId ? "Search in " + root.scopeTitle
                : "Search chats and messages   " + Keymap.label(Keymap.keysFor(root.app.shortcuts, "window.search")[0] || "")
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: app.muted
            opacity: 0.7
            font: search.font
          }
        }

        // md-cog (U+F0493): settings, including every shortcut
        Text {
          anchors.right: parent.right
          anchors.rightMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          text: String.fromCodePoint(0xF0493)
          color: gearArea.containsMouse ? app.accent : app.muted
          font.family: app.glyphFamily
          font.pixelSize: Style.font.body
          MouseArea {
            id: gearArea
            anchors.fill: parent
            anchors.margins: -Style.space(6)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.settingsRequested()
          }
        }
      }
    }

    // ------------------------------------------------ tabs
    Flickable {
      id: tabStrip
      Layout.fillWidth: true
      Layout.preferredHeight: Style.space(34)
      visible: !root.searchMode
      contentWidth: tabRow.implicitWidth + Style.space(20)
      contentHeight: height
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.HorizontalFlick

      Row {
        id: tabRow
        x: Style.space(10)
        height: tabStrip.height
        spacing: Style.space(2)

        Repeater {
          model: root.tabs

          delegate: Item {
            id: tab
            required property var modelData
            readonly property bool current: modelData.key === root.listKey
            readonly property int unread: Model.unreadTotal(Model.chatsIn(root.allChats, modelData.key))

            width: tabLabel.implicitWidth + Style.space(16)
            height: tabRow.height

            Text {
              id: tabLabel
              anchors.centerIn: parent
              text: tab.modelData.title + (tab.unread > 0 ? "  " + (tab.unread > 999 ? "999+" : tab.unread) : "")
              textFormat: Text.PlainText
              color: tab.current ? app.foreground : app.muted
              font.family: app.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: tab.current
            }

            Rectangle {
              visible: tab.current
              anchors.bottom: parent.bottom
              anchors.horizontalCenter: parent.horizontalCenter
              width: tabLabel.implicitWidth
              height: Math.max(2, Style.space(2))
              radius: height / 2
              color: app.accent
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.listSelected(tab.modelData.key)
            }

            onCurrentChanged: {
              if (current) tabStrip.contentX = Math.max(0, Math.min(x - Style.space(20), tabStrip.contentWidth - tabStrip.width))
            }
          }
        }
      }
    }

    // ------------------------------------------------ chats and results
    ListView {
      id: listView
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      model: root.rows
      focus: true
      boundsBehavior: Flickable.StopAtBounds
      highlightFollowsCurrentItem: false

      WheelScroll { view: listView }

      Keys.onPressed: function (event) {
        var keys = root.app.shortcuts
        function is(id) { return Keymap.matches(keys, id, event) }
        if (is("list.down")) root.move(1)
        else if (is("list.up")) root.move(-1)
        else if (is("list.pageDown")) root.move(10)
        else if (is("list.pageUp")) root.move(-10)
        else if (is("list.first")) { root.cursor = 0; root.move(0) }
        else if (is("list.last")) { root.cursor = root.rows.length - 1; root.move(0) }
        else if (is("list.open")) root.openCursor()
        else if (is("list.search")) root.focusSearch()
        else if (is("list.toChat")) root.toChat()
        else if (is("list.previousTab") && !root.searchMode) root.tabStep(-1)
        else if (is("list.nextTab") && !root.searchMode) root.tabStep(1)
        else if (is("list.pin") && !root.searchMode && root.cursorChat()) root.pinRequested(root.cursorChat().id)
        else if (is("list.archive") && root.cursorChat()) root.archiveRequested(root.cursorChat().id)
        else if (is("list.mute") && root.cursorChat()) root.muteRequested(root.cursorChat().id)
        else if (is("list.menu") && root.cursorChat()) root.openMenuAtCursor()
        else if (is("list.clearSearch") && search.text !== "") search.text = ""
        else return
        event.accepted = true
      }

      delegate: Rectangle {
        id: row
        required property var modelData
        required property int index
        readonly property string kind: modelData.kind
        readonly property var chat: kind === "chat" ? modelData.chat : null
        readonly property var message: kind === "message" ? modelData.message : null
        readonly property bool isOpen: !!row.chat && row.chat.id === root.openChatId
        readonly property bool isCursor: index === root.cursor && listView.activeFocus && kind !== "header"

        width: listView.width
        height: kind === "header" ? Style.space(30) : (kind === "message" ? Style.space(58) : Style.space(68))
        color: isCursor ? app.selected
             : (isOpen ? Qt.rgba(app.accent.r, app.accent.g, app.accent.b, 0.12)
                : (hover.containsMouse && kind !== "header" ? Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, 0.04) : "transparent"))

        Rectangle {
          visible: row.isCursor || row.isOpen
          width: Style.space(3)
          height: parent.height
          color: app.accent
        }

        Text {
          visible: row.kind === "header"
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: Style.space(14)
          anchors.rightMargin: Style.space(14)
          anchors.verticalCenter: parent.verticalCenter
          text: (row.modelData.title || "") + (root.searching ? "  ·  searching…" : "")
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: app.muted
          font.family: app.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Loader {
          anchors.fill: parent
          active: row.kind === "chat"
          sourceComponent: chatRow
        }

        Loader {
          anchors.fill: parent
          active: row.kind === "message"
          sourceComponent: messageRow
        }

        Component {
          id: chatRow

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.space(14)
            anchors.rightMargin: Style.space(14)
            spacing: Style.space(12)

            Avatar {
              app: root.app
              chat: row.chat
              size: Style.space(44)
              Layout.preferredWidth: size
              Layout.preferredHeight: size
            }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(3)

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)

                Text {
                  Layout.fillWidth: true
                  text: Model.chatTitle(row.chat, app.meId)
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  color: app.foreground
                  font.family: app.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: row.chat.unread > 0
                }

                Text {
                  text: row.chat.lastMessage ? Model.listTime(row.chat.lastMessage.date, root.nowMs) : ""
                  color: row.chat.unread > 0 && !row.chat.muted ? app.accent : app.muted
                  font.family: app.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)

                Text {
                  readonly property string activity: Model.actionText(Model.activeActions(app.chatActions, row.chat.id, app.clockMs),
                                                                      row.chat.kind === "private")
                  readonly property bool draft: !activity && !!row.chat.draft && row.chat.id !== root.openChatId
                  Layout.fillWidth: true
                  elide: Text.ElideRight
                  maximumLineCount: 1
                  textFormat: Text.PlainText
                  color: activity ? app.accent : (draft ? app.urgent : app.muted)
                  font.family: app.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  text: {
                    if (activity) return activity
                    if (draft) return "Draft: " + row.chat.draft
                    var last = row.chat.lastMessage
                    if (!last) return root.searchMode && row.chat.archived ? "In the archive" : ""
                    var who = last.outgoing ? "You: " : (row.chat.kind !== "private" && last.senderName ? last.senderName + ": " : "")
                    return who + last.text
                  }
                }

                // md-pin (U+F0403) and md-bell-off (U+F009B), from the Nerd Font.
                Text {
                  visible: Model.pinnedIn(row.chat, root.searchMode ? "main" : root.listKey) && !(row.chat.unread > 0)
                  text: "󰐃"
                  color: app.muted
                  font.family: app.glyphFamily
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  visible: row.chat.muted
                  text: "󰂛"
                  color: app.muted
                  font.family: app.glyphFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Rectangle {
                  visible: row.chat.unread > 0 || row.chat.mentions > 0
                  Layout.preferredHeight: Style.space(20)
                  Layout.preferredWidth: Math.max(Style.space(20), badge.implicitWidth + Style.space(12))
                  radius: height / 2
                  color: row.chat.muted ? Qt.rgba(app.muted.r, app.muted.g, app.muted.b, 0.5) : app.accent

                  Text {
                    id: badge
                    anchors.centerIn: parent
                    text: row.chat.mentions > 0 ? "@" : (row.chat.unread > 999 ? "999+" : String(row.chat.unread))
                    color: app.background
                    font.family: app.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }
              }
            }
          }
        }

        Component {
          id: messageRow

          ColumnLayout {
            id: messageBlock
            readonly property var found: Model.findChat(root.allChats, row.message.chatId)
            anchors.fill: parent
            anchors.leftMargin: Style.space(14)
            anchors.rightMargin: Style.space(14)
            anchors.topMargin: Style.space(8)
            anchors.bottomMargin: Style.space(8)
            spacing: Style.space(2)

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Text {
                Layout.fillWidth: true
                text: messageBlock.found ? Model.chatTitle(messageBlock.found, app.meId) : "Chat"
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: app.foreground
                font.family: app.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }

              Text {
                text: Model.listTime(row.message.date, root.nowMs)
                color: app.muted
                font.family: app.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Text {
              Layout.fillWidth: true
              text: (row.message.outgoing ? "You: " : (row.message.senderName ? row.message.senderName + ": " : ""))
                    + Model.previewOf(row.message)
              textFormat: Text.PlainText
              elide: Text.ElideRight
              maximumLineCount: 1
              color: app.muted
              font.family: app.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        MouseArea {
          id: hover
          anchors.fill: parent
          hoverEnabled: true
          enabled: row.kind !== "header"
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          onClicked: function (mouse) {
            root.cursor = row.index
            if (mouse.button !== Qt.RightButton) {
              root.openCursor()
            } else if (row.chat) {
              var at = hover.mapToItem(root, mouse.x, mouse.y)
              root.openChatMenu(row.chat, at.x, at.y)
            }
          }
        }
      }

      Text {
        anchors.centerIn: parent
        width: parent.width - Style.space(40)
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        visible: listView.count === 0
        text: root.searchMode ? (root.searching ? "Searching…" : "Nothing matches")
            : (root.listKey === "main" ? "Loading chats…" : "No chats here")
        color: app.muted
        font.family: app.fontFamily
        font.pixelSize: Style.font.body
      }
    }
  }

  ContextMenu {
    id: chatMenu
    anchors.fill: parent
    app: root.app
    items: Model.chatMenu(root.menuChat ? (Model.findChat(root.allChats, root.menuChat.id) || root.menuChat) : null, root.listKey, root.searchMode)
    onDismissed: root.focusList()
    onPicked: function (id) { root.focusList(); root.chatMenuPicked(id) }
  }
}
