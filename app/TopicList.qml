import QtQuick
import QtQuick.Layouts
import qs.Commons
import "Model.js" as Model
import "Keymap.js" as Keymap

// A forum group's topics, pinned ones first, then the most recently active: each with its
// icon, its last message and how much is unread. Choosing one opens its messages.
// Keys are the "Topics" section of the shortcuts.
FocusScope {
  id: topics

  property var app
  property var client
  property var chat: null
  property real nowMs: Date.now()

  property var list: []
  property var next: null            // where the next page starts; null at the end
  property bool loading: false
  property int cursor: 0
  property int serial: 0
  property real loadedChatId: 0

  signal opened(var topic)

  function reload() {
    if (!topics.chat) return
    topics.serial++
    topics.loadedChatId = topics.chat.id
    topics.list = []
    topics.next = null
    topics.cursor = 0
    topics.loading = false
    topics.fetch(false)
  }

  // A page of topics: the first again to catch up with what changed, or the next one.
  function fetch(more) {
    if (!topics.chat || topics.loading || (more && !topics.next)) return
    var serial = topics.serial
    var args = { chatId: topics.chat.id, limit: 50 }
    if (more) {
      args.offsetDate = topics.next.offsetDate
      args.offsetMessageId = topics.next.offsetMessageId
      args.offsetTopicId = topics.next.offsetTopicId
    }
    topics.loading = true
    topics.client.request("topics.list", args, function (answer) {
      if (serial !== topics.serial) return
      topics.loading = false
      if (!answer.ok) return
      var found = answer.result.topics || []
      topics.list = Model.mergeTopics(topics.list, found)
      if (more || topics.next === null) {
        var n = answer.result.next
        topics.next = found.length && n && (n.offsetDate || n.offsetMessageId || n.offsetTopicId) ? n : null
      }
    })
  }

  Timer { id: refreshLater; interval: 1200; onTriggered: topics.fetch(false) }

  function refresh() { refreshLater.restart() }

  onChatChanged: {
    if (!topics.chat) return
    if (topics.chat.id !== topics.loadedChatId) topics.reload()
    else if (topics.visible) topics.refresh()   // a new message somewhere in the forum
  }
  onVisibleChanged: if (topics.visible && topics.chat && topics.chat.id === topics.loadedChatId) topics.refresh()

  function move(delta) {
    if (!topics.list.length) return
    topics.cursor = Math.max(0, Math.min(topics.list.length - 1, topics.cursor + delta))
    listView.positionViewAtIndex(topics.cursor, ListView.Contain)
    if (topics.cursor >= topics.list.length - 5) topics.fetch(true)
  }

  function openAt(index) {
    var topic = topics.list[index]
    if (topic) topics.opened(topic)
  }

  Keys.onPressed: function (event) {
    var keys = topics.app.shortcuts
    function is(id) { return Keymap.matches(keys, id, event) }
    if (is("topics.down")) topics.move(1)
    else if (is("topics.up")) topics.move(-1)
    else if (is("topics.open")) topics.openAt(topics.cursor)
    else return
    event.accepted = true
  }

  ListView {
    id: listView
    anchors.fill: parent
    anchors.topMargin: Style.space(6)
    clip: true
    model: topics.list
    boundsBehavior: Flickable.StopAtBounds
    onAtYEndChanged: if (atYEnd && count > 0) topics.fetch(true)

    WheelScroll { view: listView }

    delegate: Rectangle {
      id: row
      required property var modelData
      required property int index
      readonly property var last: row.modelData.lastMessage
      width: listView.width
      height: Style.space(66)
      color: row.index === topics.cursor && topics.activeFocus ? topics.app.selected
           : (rowArea.containsMouse ? Qt.rgba(topics.app.foreground.r, topics.app.foreground.g, topics.app.foreground.b, 0.04) : "transparent")

      RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Style.space(18)
        anchors.rightMargin: Style.space(18)
        spacing: Style.space(12)

        // The topic's icon: its colour and first letter, or # for General.
        Rectangle {
          Layout.preferredWidth: Style.space(40)
          Layout.preferredHeight: Style.space(40)
          radius: width / 2
          color: Model.topicColor(row.modelData.color)
          Text {
            anchors.centerIn: parent
            text: Model.topicLetter(row.modelData)
            textFormat: Text.PlainText
            color: "white"
            font.family: topics.app.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(3)

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)
            Text {
              Layout.fillWidth: true
              elide: Text.ElideRight
              text: row.modelData.name || "Topic"
              textFormat: Text.PlainText
              color: topics.app.foreground
              font.family: topics.app.fontFamily
              font.pixelSize: Style.font.body
              font.bold: row.modelData.unread > 0
            }
            Text {
              visible: row.modelData.closed
              text: "closed"
              color: topics.app.muted
              font.family: topics.app.fontFamily
              font.pixelSize: Style.font.caption
            }
            // md-pin U+F0403
            Text {
              visible: row.modelData.pinned
              text: String.fromCodePoint(0xF0403)
              color: topics.app.muted
              font.family: topics.app.glyphFamily
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              text: row.last ? Model.listTime(row.last.date, topics.nowMs) : ""
              color: row.modelData.unread > 0 ? topics.app.foreground : topics.app.muted
              font.family: topics.app.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)
            Text {
              Layout.fillWidth: true
              elide: Text.ElideRight
              maximumLineCount: 1
              text: row.modelData.draft ? "Draft: " + row.modelData.draft
                  : (row.last ? (row.last.outgoing ? "You: " : (row.last.senderName ? row.last.senderName + ": " : "")) + row.last.text : "")
              textFormat: Text.PlainText
              color: row.modelData.draft ? topics.app.urgent : topics.app.muted
              font.family: topics.app.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Rectangle {
              visible: row.modelData.unread > 0 || row.modelData.mentions > 0
              Layout.preferredHeight: Style.space(20)
              Layout.preferredWidth: Math.max(Style.space(20), count.implicitWidth + Style.space(12))
              radius: height / 2
              color: topics.chat && topics.chat.muted ? Qt.rgba(topics.app.muted.r, topics.app.muted.g, topics.app.muted.b, 0.5) : topics.app.accent
              Text {
                id: count
                anchors.centerIn: parent
                text: row.modelData.mentions > 0 ? "@" : (row.modelData.unread > 999 ? "999+" : String(row.modelData.unread))
                color: topics.chat && topics.chat.muted ? topics.app.background : topics.app.onAccent
                font.family: topics.app.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }
          }
        }
      }

      MouseArea {
        id: rowArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          topics.cursor = row.index
          topics.openAt(row.index)
        }
      }
    }

    Text {
      anchors.centerIn: parent
      visible: listView.count === 0
      text: topics.loading ? "Loading topics…" : "No topics yet"
      color: topics.app.muted
      font.family: topics.app.fontFamily
      font.pixelSize: Style.font.body
    }
  }
}
