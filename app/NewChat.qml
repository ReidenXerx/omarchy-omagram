import QtQuick
import QtQuick.Layouts
import qs.Commons
import "Model.js" as Model
import "Keymap.js" as Keymap

// Starting a conversation: with one of your contacts or anyone by @username, or a new group
// (choose people, then give it a name) or a new channel (a name and what it is about).
// Keys are the "New chat" section of the shortcuts; a click outside cancels.
FocusScope {
  id: dialog

  property var app
  property real nowMs: Date.now()
  property string mode: "people"      // people, members, groupName or channel
  property var contacts: []
  property bool contactsLoaded: false
  property var selected: ({})         // user id -> true: the people of a new group
  property string query: ""
  property int cursor: 0
  property bool busy: false
  property string error: ""

  readonly property bool listing: dialog.mode === "people" || dialog.mode === "members"
  readonly property var rows: dialog.listing ? Model.newChatRows(dialog.mode, dialog.contacts, dialog.query, dialog.selected) : []
  readonly property int selectedCount: Object.keys(dialog.selected).length

  signal opened(real chatId, string notice)
  signal dismissed()

  visible: false
  z: 60

  function open() {
    dialog.selected = ({})
    dialog.busy = false
    groupName.clear()
    channelName.clear()
    channelAbout.clear()
    dialog.visible = true
    dialog.showMode("people")
    dialog.app.request("contacts.list", {}, function (answer) {
      dialog.contactsLoaded = true
      if (answer.ok) dialog.contacts = Model.sortContacts(answer.result.contacts || [])
    })
  }

  function dismiss() {
    if (!dialog.visible) return
    dialog.visible = false
    dialog.dismissed()
  }

  function showMode(mode) {
    dialog.mode = mode
    dialog.cursor = 0
    dialog.error = ""
    search.text = ""
    Qt.callLater(function () {
      if (dialog.listing) search.forceActiveFocus()
      else if (mode === "groupName") groupName.forceActiveFocus()
      else channelName.forceActiveFocus()
    })
  }

  function back() {
    if (dialog.mode === "groupName") dialog.showMode("members")
    else if (dialog.mode !== "people") dialog.showMode("people")
    else dialog.dismiss()
  }

  function move(delta) {
    if (!dialog.rows.length) return
    dialog.cursor = Math.max(0, Math.min(dialog.rows.length - 1, dialog.cursor + delta))
    list.positionViewAtIndex(dialog.cursor, ListView.Contain)
  }

  function pick(index) {
    var row = dialog.rows[index]
    if (!row || dialog.busy) return
    if (row.kind === "action") dialog.showMode(row.id === "group" ? "members" : "channel")
    else if (row.kind === "username") dialog.openUsername(row.username)
    else if (dialog.mode === "members") dialog.toggle(row.contact.userId)
    else dialog.openUser(row.contact.userId)
  }

  function toggle(userId) {
    var next = {}
    for (var id in dialog.selected) next[id] = true
    if (next[userId]) delete next[userId]
    else next[userId] = true
    dialog.selected = next
  }

  function next() {
    if (dialog.busy) return
    if (dialog.mode === "members") dialog.showMode("groupName")
    else if (dialog.mode === "groupName") dialog.createGroup()
    else if (dialog.mode === "channel") dialog.createChannel()
  }

  function finish(answer, failure, notice) {
    dialog.busy = false
    if (!answer.ok || !answer.result.chatId) {
      dialog.error = answer.error || failure
      return
    }
    dialog.visible = false
    dialog.opened(answer.result.chatId, notice || "")
  }

  function openUser(userId) {
    dialog.busy = true
    dialog.app.request("user.chat", { userId: userId }, function (answer) { dialog.finish(answer, "That chat could not be opened") })
  }

  function openUsername(username) {
    dialog.busy = true
    dialog.app.request("username.chat", { username: username }, function (answer) { dialog.finish(answer, "No one on Telegram is @" + username) })
  }

  function createGroup() {
    var title = groupName.text.trim()
    if (!title) { dialog.error = "A group needs a name"; return }
    dialog.busy = true
    dialog.app.request("group.create", { title: title, userIds: Object.keys(dialog.selected).map(Number) }, function (answer) {
      var left = answer.ok ? answer.result.notAdded : 0
      dialog.finish(answer, "The group could not be created",
                    left > 0 ? (left === 1 ? "One person" : left + " people") + " could not be added: their privacy settings do not allow it" : "")
    })
  }

  function createChannel() {
    var title = channelName.text.trim()
    if (!title) { dialog.error = "A channel needs a name"; return }
    dialog.busy = true
    dialog.app.request("channel.create", { title: title, description: channelAbout.text.trim(), channel: true }, function (answer) {
      dialog.finish(answer, "The channel could not be created")
    })
  }

  onActiveFocusChanged: if (!activeFocus && visible) dialog.visible = false

  // Keys from the fields come here when the field does not use them.
  Keys.onPressed: function (event) {
    var keys = dialog.app.shortcuts
    function is(id) { return Keymap.matchesInText(keys, id, event) }
    if (is("newChat.back")) dialog.back()
    else if (dialog.listing && is("newChat.down")) dialog.move(1)
    else if (dialog.listing && is("newChat.up")) dialog.move(-1)
    else if (is("newChat.next")) dialog.next()
    else if (dialog.listing && is("newChat.pick")) dialog.pick(dialog.cursor)
    else return
    event.accepted = true
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.55)
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: dialog.dismiss()
  }

  Rectangle {
    width: Math.min(parent.width - Style.space(40), Style.space(480))
    height: Math.min(parent.height - Style.space(60), Style.space(600))
    anchors.centerIn: parent
    radius: Style.cornerRadius
    color: dialog.app.background
    border.width: 1
    border.color: Qt.rgba(dialog.app.foreground.r, dialog.app.foreground.g, dialog.app.foreground.b, 0.18)

    MouseArea { anchors.fill: parent; acceptedButtons: Qt.LeftButton | Qt.RightButton }

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: Style.space(16)
      spacing: Style.space(10)

      Text {
        Layout.fillWidth: true
        elide: Text.ElideRight
        text: ({ people: "New message", members: "New group: add people" + (dialog.selectedCount ? "  (" + dialog.selectedCount + ")" : ""),
                 groupName: "New group: its name", channel: "New channel" })[dialog.mode] || ""
        color: dialog.app.foreground
        font.family: dialog.app.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
      }

      Rectangle {
        visible: dialog.listing
        Layout.fillWidth: true
        Layout.preferredHeight: visible ? Style.space(36) : 0
        radius: Style.cornerRadius
        color: Qt.rgba(dialog.app.foreground.r, dialog.app.foreground.g, dialog.app.foreground.b, 0.05)
        border.width: Math.max(1, Style.space(1.5))
        border.color: search.activeFocus ? dialog.app.accent : "transparent"

        TextInput {
          id: search
          anchors.fill: parent
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          verticalAlignment: TextInput.AlignVCenter
          clip: true
          maximumLength: 64
          color: dialog.app.foreground
          selectionColor: dialog.app.accent
          font.family: dialog.app.fontFamily
          font.pixelSize: Style.font.body
          onTextChanged: {
            dialog.query = text
            dialog.cursor = 0
          }

          Text {
            anchors.fill: parent
            verticalAlignment: Text.AlignVCenter
            visible: search.text === ""
            text: dialog.mode === "people" ? "Search your contacts, or type a @username" : "Search your contacts"
            color: dialog.app.muted
            opacity: 0.7
            font: search.font
          }
        }
      }

      Field {
        id: groupName
        Layout.fillWidth: true
        visible: dialog.mode === "groupName"
        app: dialog.app
        label: "Group name"
        maximumLength: 128
        onAccepted: dialog.next()
      }

      Field {
        id: channelName
        Layout.fillWidth: true
        visible: dialog.mode === "channel"
        app: dialog.app
        label: "Channel name"
        maximumLength: 128
        KeyNavigation.tab: channelAbout
        onAccepted: channelAbout.forceActiveFocus()
      }

      Field {
        id: channelAbout
        Layout.fillWidth: true
        visible: dialog.mode === "channel"
        app: dialog.app
        label: "What it is about (you can leave this out)"
        maximumLength: 255
        KeyNavigation.tab: channelName
        onAccepted: dialog.next()
      }

      Text {
        Layout.fillWidth: true
        visible: dialog.error !== ""
        wrapMode: Text.Wrap
        text: dialog.error
        textFormat: Text.PlainText
        color: dialog.app.urgent
        font.family: dialog.app.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      ListView {
        id: list
        visible: dialog.listing
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        model: dialog.rows
        boundsBehavior: Flickable.StopAtBounds

        WheelScroll { view: list }

        delegate: Rectangle {
          id: entry
          required property var modelData
          required property int index
          readonly property bool person: entry.modelData.kind === "contact"
          width: list.width
          height: Style.space(50)
          radius: Style.cornerRadius
          color: entry.index === dialog.cursor ? dialog.app.selected
               : (entryArea.containsMouse ? Qt.rgba(dialog.app.foreground.r, dialog.app.foreground.g, dialog.app.foreground.b, 0.05) : "transparent")

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(10)
            spacing: Style.space(10)

            Rectangle {
              visible: !entry.person
              Layout.preferredWidth: Style.space(36)
              Layout.preferredHeight: Style.space(36)
              radius: width / 2
              color: Qt.rgba(dialog.app.accent.r, dialog.app.accent.g, dialog.app.accent.b, 0.22)
              // md-account-group-outline U+F0B58, md-bullhorn-outline U+F0B23, md-at U+F0065
              Text {
                anchors.centerIn: parent
                text: String.fromCodePoint(entry.modelData.id === "group" ? 0xF0B58 : (entry.modelData.id === "channel" ? 0xF0B23 : 0xF0065))
                color: dialog.app.accent
                font.family: dialog.app.glyphFamily
                font.pixelSize: Style.font.title
              }
            }
            Avatar {
              visible: entry.person
              app: dialog.app
              chat: entry.person ? { title: entry.modelData.contact.name, kind: "private", userId: 0, photo: null } : null
              size: Style.space(36)
              Layout.preferredWidth: visible ? size : 0
              Layout.preferredHeight: size
            }
            Column {
              Layout.fillWidth: true
              spacing: Style.space(2)
              Text {
                width: parent.width
                elide: Text.ElideRight
                text: entry.person ? (entry.modelData.contact.name || "Deleted account") : entry.modelData.label
                textFormat: Text.PlainText
                color: entry.person ? dialog.app.foreground : dialog.app.accent
                font.family: dialog.app.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                width: parent.width
                visible: text !== ""
                elide: Text.ElideRight
                text: entry.person ? Model.contactDetail(entry.modelData.contact, dialog.nowMs)
                                   : (entry.modelData.kind === "username" ? "Find this username on Telegram" : "")
                textFormat: Text.PlainText
                color: dialog.app.muted
                font.family: dialog.app.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
            // md-check-circle-outline U+F05E1 when chosen for the group
            Text {
              visible: dialog.mode === "members"
              text: entry.modelData.selected ? String.fromCodePoint(0xF05E1) : ""
              color: dialog.app.accent
              font.family: dialog.app.glyphFamily
              font.pixelSize: Style.font.title
            }
          }
          MouseArea {
            id: entryArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              dialog.cursor = entry.index
              dialog.pick(entry.index)
            }
          }
        }

        Text {
          anchors.centerIn: parent
          visible: list.count === 0
          text: !dialog.contactsLoaded ? "Loading your contacts…" : (dialog.query ? "No contact matches" : "No contacts yet")
          color: dialog.app.muted
          font.family: dialog.app.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      Item {
        visible: !dialog.listing
        Layout.fillHeight: true
      }

      Text {
        Layout.fillWidth: true
        wrapMode: Text.Wrap
        text: {
          var keys = dialog.app.shortcuts
          var pick = Keymap.label(Keymap.keysFor(keys, "newChat.pick")[0] || "")
          var next = Keymap.label(Keymap.keysFor(keys, "newChat.next")[0] || "")
          var back = Keymap.label(Keymap.keysFor(keys, "newChat.back")[0] || "")
          if (dialog.mode === "people") return pick + " opens  ·  " + back + " closes"
          if (dialog.mode === "members") return pick + " adds or removes  ·  " + next + " next  ·  " + back + " back"
          return next + " creates  ·  " + back + " back"
        }
        color: dialog.app.muted
        font.family: dialog.app.fontFamily
        font.pixelSize: Style.font.caption
      }

      RowLayout {
        Layout.fillWidth: true
        visible: dialog.mode !== "people"
        spacing: Style.space(8)

        Item { Layout.fillWidth: true }
        Button {
          app: dialog.app
          text: "Back"
          onClicked: dialog.back()
        }
        Button {
          app: dialog.app
          primary: true
          busy: dialog.busy
          text: dialog.mode === "members" ? "Next" : "Create"
          onClicked: dialog.next()
        }
      }
    }
  }
}
