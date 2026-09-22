import QtQuick
import QtQuick.Layouts
import qs.Commons
import "Model.js" as Model
import "Keymap.js" as Keymap

// Where to forward messages: type to find a chat and choose it. Saved Messages comes first.
// Keys are the "Choosing a chat to forward to" section of the shortcuts; a click outside cancels.
FocusScope {
  id: picker

  property var app
  property var chats: []
  property var messageIds: []
  property real fromChatId: 0
  property bool peopleOnly: false   // only people, as for sharing someone's contact card
  property string title: ""     // said instead of "Forward … to…" when a chat is chosen for something else
  property string query: ""
  property int cursor: 0

  readonly property var results: !picker.visible ? [] : Model.forwardTargets(picker.chats, picker.query, picker.app.meId).filter(function (c) {
    return !picker.peopleOnly || (c.kind === "private" && !c.bot && c.userId !== picker.app.meId)
  })

  // Forwarding the same thing to three people should be one trip through this
  // window, not three. Ticking is opt-in, because this picker is also used for
  // "choose a chat" jobs where more than one makes no sense.
  property bool multiple: false
  property var chosen: []          // chat ids, in the order they were ticked

  signal picked(real chatId, string title)
  signal pickedMany(var ids, var titles)
  signal dismissed()

  visible: false
  z: 60

  function open(fromChatId, ids) {
    picker.fromChatId = fromChatId
    picker.messageIds = ids || []
    picker.cursor = 0
    picker.chosen = []
    search.text = ""
    picker.visible = true
    search.forceActiveFocus()
  }

  function dismiss() {
    if (!picker.visible) return
    picker.visible = false
    picker.dismissed()
  }

  function isChosen(id) {
    for (var i = 0; i < picker.chosen.length; i++) if (picker.chosen[i] === id) return true
    return false
  }

  function toggle(index) {
    var chat = picker.results[index]
    if (!picker.multiple || !chat) return
    var next = []
    var had = false
    for (var i = 0; i < picker.chosen.length; i++) {
      if (picker.chosen[i] === chat.id) had = true
      else next.push(picker.chosen[i])
    }
    if (!had) next.push(chat.id)
    picker.chosen = next
  }

  function titleOf(id) {
    for (var i = 0; i < picker.chats.length; i++) {
      if (picker.chats[i].id === id) return Model.chatTitle(picker.chats[i], picker.app.meId)
    }
    return ""
  }

  // Enter sends: to everything ticked, or -- when nothing is -- to the chat
  // under the cursor, so the one-chat habit still costs a single keystroke.
  function choose(index) {
    if (!picker.visible) return
    if (picker.multiple && picker.chosen.length) {
      var ids = picker.chosen.slice()
      var titles = []
      for (var i = 0; i < ids.length; i++) titles.push(picker.titleOf(ids[i]))
      picker.visible = false
      picker.pickedMany(ids, titles)
      return
    }
    var chat = picker.results[index]
    if (!chat) return
    picker.visible = false
    if (picker.multiple) picker.pickedMany([chat.id], [Model.chatTitle(chat, picker.app.meId)])
    else picker.picked(chat.id, Model.chatTitle(chat, picker.app.meId))
  }

  function move(delta) {
    if (!picker.results.length) return
    picker.cursor = Math.max(0, Math.min(picker.results.length - 1, picker.cursor + delta))
    list.positionViewAtIndex(picker.cursor, ListView.Contain)
  }

  onActiveFocusChanged: if (!activeFocus) picker.visible = false

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.55)
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: picker.dismiss()
  }

  Rectangle {
    width: Math.min(parent.width - Style.space(40), Style.space(460))
    height: Math.min(parent.height - Style.space(60), Style.space(560))
    anchors.centerIn: parent
    radius: Style.cornerRadius
    color: picker.app.background
    border.width: 1
    border.color: Qt.rgba(picker.app.foreground.r, picker.app.foreground.g, picker.app.foreground.b, 0.18)

    MouseArea { anchors.fill: parent; acceptedButtons: Qt.LeftButton | Qt.RightButton }

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: Style.space(14)
      spacing: Style.space(10)

      Text {
        Layout.fillWidth: true
        elide: Text.ElideRight
        text: picker.title !== "" ? picker.title
            : picker.chosen.length
              ? "Forward to " + picker.chosen.length + (picker.chosen.length === 1 ? " chat" : " chats")
              : "Forward " + (picker.messageIds.length === 1 ? "the message" : picker.messageIds.length + " messages") + " to…"
        color: picker.app.foreground
        font.family: picker.app.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
      }

      Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: Style.space(36)
        radius: Style.cornerRadius
        color: Qt.rgba(picker.app.foreground.r, picker.app.foreground.g, picker.app.foreground.b, 0.05)
        border.width: Math.max(1, Style.space(1.5))
        border.color: search.activeFocus ? picker.app.accent : "transparent"

        TextInput {
          id: search
          anchors.fill: parent
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          verticalAlignment: TextInput.AlignVCenter
          clip: true
          maximumLength: 128
          color: picker.app.foreground
          selectionColor: picker.app.accent
          font.family: picker.app.fontFamily
          font.pixelSize: Style.font.body
          onTextChanged: {
            picker.query = text
            picker.cursor = 0
          }

          Keys.onPressed: function (event) {
            var keys = picker.app.shortcuts
            function is(id) { return Keymap.matchesInText(keys, id, event) }
            if (is("picker.down")) picker.move(1)
            else if (is("picker.up")) picker.move(-1)
            else if (is("picker.toggle") && picker.multiple) picker.toggle(picker.cursor)
            else if (is("picker.pick")) picker.choose(picker.cursor)
            else if (is("picker.close")) picker.dismiss()
            else return
            event.accepted = true
          }

          Text {
            anchors.fill: parent
            verticalAlignment: Text.AlignVCenter
            visible: search.text === ""
            text: "Find a chat"
            color: picker.app.muted
            opacity: 0.7
            font: search.font
          }
        }
      }

      ListView {
        id: list
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        model: picker.results
        boundsBehavior: Flickable.StopAtBounds

        WheelScroll { view: list }

        delegate: Rectangle {
          id: target
          required property var modelData
          required property int index
          width: list.width
          height: Style.space(50)
          radius: Style.cornerRadius
          color: target.index === picker.cursor ? picker.app.selected
               : (targetArea.containsMouse ? Qt.rgba(picker.app.foreground.r, picker.app.foreground.g, picker.app.foreground.b, 0.05) : "transparent")

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            spacing: Style.space(10)

            // Only while ticking, and only where it says something: a column of
            // empty boxes down the side of every chat is noise, not information.
            Text {
              textFormat: Text.PlainText
              visible: picker.multiple && picker.isChosen(target.modelData.id)
              text: "\u2713"
              color: picker.app.accent
              font.family: picker.app.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }

            Avatar {
              app: picker.app
              chat: target.modelData
              size: Style.space(36)
              Layout.preferredWidth: size
              Layout.preferredHeight: size
            }
            Text {
              Layout.fillWidth: true
              elide: Text.ElideRight
              text: Model.chatTitle(target.modelData, picker.app.meId)
              textFormat: Text.PlainText
              color: picker.app.foreground
              font.family: picker.app.fontFamily
              font.pixelSize: Style.font.body
            }
          }
          MouseArea {
            id: targetArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: picker.multiple ? picker.toggle(target.index) : picker.choose(target.index)
          }
        }

        Text {
          anchors.centerIn: parent
          visible: list.count === 0
          text: "No chat matches"
          color: picker.app.muted
          font.family: picker.app.fontFamily
          font.pixelSize: Style.font.body
        }
      }
    }
  }
}
