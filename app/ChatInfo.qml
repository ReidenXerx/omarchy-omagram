import QtQuick
import QtQuick.Layouts
import qs.Commons
import "Model.js" as Model
import "Keymap.js" as Keymap

// A chat's info beside its messages: who or what it is, its username, phone, bio or description
// and invite link, what you can do with it, and tabs of its members and of what was shared in it.
// Choosing a member opens a chat with them; choosing anything shared jumps to its message.
//
// Keys are the "Chat info" section of the shortcuts.
FocusScope {
  id: info

  property var app
  property var client
  property var chat: null
  property real nowMs: Date.now()

  property var details: null          // what chat.info said
  property var counts: null           // what chat.mediaCounts said
  property real loadedChatId: 0
  property int serial: 0              // another chat: answers about the one before are dropped
  property string tab: ""
  property int generation: 0          // another tab: answers for the one before are dropped
  property var items: []              // members, or the messages of a media tab
  property real nextFromMessageId: 0
  property int memberOffset: 0
  property bool loading: false
  property bool exhausted: false
  property int cursor: 0

  readonly property int itemsMax: 2000
  readonly property var tabs: Model.infoTabs(info.chat, info.details, info.counts)
  readonly property bool grid: info.tab === "photos" || info.tab === "gifs"

  signal closed()
  signal openUser(real userId)
  signal openMessage(real messageId)
  signal linkActivated(string link)
  signal actionRequested(string id)
  signal copyRequested(string text, string done)

  function ensureLoaded() {
    if (!info.visible || !info.chat || info.loadedChatId === info.chat.id) return
    info.loadedChatId = info.chat.id
    info.serial++
    info.details = null
    info.counts = null
    info.cursor = 0
    var serial = info.serial
    var chatId = info.chat.id
    info.client.request("chat.info", { chatId: chatId }, function (answer) {
      if (serial === info.serial && answer.ok) info.details = answer.result
    })
    info.client.request("chat.mediaCounts", { chatId: chatId }, function (answer) {
      if (serial === info.serial && answer.ok) info.counts = answer.result.counts
    })
    info.selectTab(info.tabs.length ? info.tabs[0].key : "")
  }

  onChatChanged: info.ensureLoaded()
  onVisibleChanged: info.ensureLoaded()

  // Tabs come and go as the counts arrive; one that is gone gives way to the first.
  onTabsChanged: {
    if (info.tabs.some(function (t) { return t.key === info.tab })) return
    info.selectTab(info.tabs.length ? info.tabs[0].key : "")
  }

  function selectTab(key) {
    info.generation++
    info.tab = key
    info.items = []
    info.cursor = 0
    info.nextFromMessageId = 0
    info.memberOffset = 0
    info.loading = false
    info.exhausted = false
    info.loadMore()
  }

  function stepTab(delta) {
    if (!info.tabs.length) return
    var at = 0
    for (var i = 0; i < info.tabs.length; i++) if (info.tabs[i].key === info.tab) at = i
    info.selectTab(info.tabs[(at + delta + info.tabs.length) % info.tabs.length].key)
  }

  function loadMore() {
    if (!info.chat || !info.tab || info.loading || info.exhausted) return
    var generation = info.generation
    var chatId = info.chat.id
    if (info.tab === "members") {
      // A basic group's members all come with its info.
      if (info.details && info.details.members && info.details.members.length) {
        info.items = info.details.members
        info.exhausted = true
        return
      }
      info.loading = true
      info.client.request("chat.members", { chatId: chatId, offset: info.memberOffset, limit: 50 }, function (answer) {
        if (generation !== info.generation) return
        info.loading = false
        var found = answer.ok ? answer.result.members || [] : []
        info.items = info.items.concat(found).slice(0, info.itemsMax)
        info.memberOffset += found.length
        info.exhausted = !answer.ok || found.length === 0 || info.items.length >= Math.min(info.itemsMax, answer.result.total)
      })
    } else {
      info.loading = true
      info.client.request("chat.media", { chatId: chatId, filter: info.tab, fromMessageId: info.nextFromMessageId, limit: 60 }, function (answer) {
        if (generation !== info.generation) return
        info.loading = false
        info.items = info.items.concat(answer.ok ? answer.result.messages || [] : []).slice(0, info.itemsMax)
        info.nextFromMessageId = answer.ok ? answer.result.nextFromMessageId || 0 : 0
        info.exhausted = !info.nextFromMessageId || info.items.length >= info.itemsMax
      })
    }
  }

  function move(delta) {
    if (!info.items.length) return
    info.cursor = Math.max(0, Math.min(info.items.length - 1, info.cursor + (info.grid ? delta * 3 : delta)))
    if (info.grid) gridView.positionViewAtIndex(info.cursor, GridView.Contain)
    else listView.positionViewAtIndex(info.cursor, ListView.Contain)
    if (info.cursor >= info.items.length - 6) info.loadMore()
  }

  function activate(index) {
    var item = info.items[index]
    if (!item) return
    if (info.tab !== "members") info.openMessage(item.id)
    else if (item.type === "user" && item.id) info.openUser(item.id)
  }

  Keys.onPressed: function (event) {
    var keys = info.app.shortcuts
    function is(id) { return Keymap.matches(keys, id, event) }
    if (is("info.close")) info.closed()
    else if (is("info.down")) info.move(1)
    else if (is("info.up")) info.move(-1)
    else if (is("info.open")) info.activate(info.cursor)
    else if (is("info.nextTab")) info.stepTab(1)
    else if (is("info.previousTab")) info.stepTab(-1)
    else return
    event.accepted = true
  }

  Rectangle {
    anchors.fill: parent
    color: info.app.background
  }

  Rectangle { width: 1; height: parent.height; color: info.app.border; opacity: 0.35 }

  ColumnLayout {
    anchors.fill: parent
    anchors.leftMargin: 1
    spacing: 0

    // ------------------------------------------------ title
    Item {
      Layout.fillWidth: true
      Layout.preferredHeight: Style.space(56)

      Text {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(18)
        anchors.verticalCenter: parent.verticalCenter
        text: !info.chat ? "" : (({ private: "User info", secret: "User info", channel: "Channel info" })[info.chat.kind] || "Group info")
        color: info.app.foreground
        font.family: info.app.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
      }

      // md-close U+F0156
      Text {
        anchors.right: parent.right
        anchors.rightMargin: Style.space(16)
        anchors.verticalCenter: parent.verticalCenter
        text: String.fromCodePoint(0xF0156)
        color: closeArea.containsMouse ? info.app.foreground : info.app.muted
        font.family: info.app.glyphFamily
        font.pixelSize: Style.font.title
        MouseArea {
          id: closeArea
          anchors.fill: parent
          anchors.margins: -Style.space(6)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: info.closed()
        }
      }

      Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: info.app.border; opacity: 0.35 }
    }

    // ------------------------------------------------ who or what
    Column {
      Layout.fillWidth: true
      Layout.topMargin: Style.space(16)
      Layout.leftMargin: Style.space(18)
      Layout.rightMargin: Style.space(18)
      spacing: Style.space(6)

      Avatar {
        anchors.horizontalCenter: parent.horizontalCenter
        app: info.app
        chat: info.chat
        size: Style.space(84)
      }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        maximumLineCount: 3
        elide: Text.ElideRight
        text: Model.chatTitle(info.chat, info.app.meId)
        textFormat: Text.PlainText
        color: info.app.foreground
        font.family: info.app.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
      }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: Model.infoSubtitle(info.chat, info.details, info.app.userStatuses, info.nowMs)
        textFormat: Text.PlainText
        color: info.app.muted
        font.family: info.app.fontFamily
        font.pixelSize: Style.font.caption
      }

      Item { width: 1; height: Style.space(4) }

      Repeater {
        model: Model.infoDetails(info.chat, info.details)
        delegate: Column {
          id: detail
          required property var modelData
          width: parent.width
          spacing: Style.space(1)

          Text {
            text: detail.modelData.label + (detail.modelData.copy ? "   click to copy" : "")
            textFormat: Text.PlainText
            color: info.app.muted
            font.family: info.app.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            width: parent.width
            wrapMode: Text.Wrap
            maximumLineCount: 8
            text: detail.modelData.entities ? Model.richText(detail.modelData.value, detail.modelData.entities, true, "transparent", null,
                                                           Model.hexOf(info.app.accentText))
                                            : detail.modelData.value
            textFormat: detail.modelData.entities ? Text.RichText : Text.PlainText
            color: info.app.foreground
            linkColor: info.app.accentText
            font.family: info.app.fontFamily
            font.pixelSize: Style.font.bodySmall
            onLinkActivated: function (link) { info.linkActivated(link) }

            MouseArea {
              anchors.fill: parent
              enabled: !!detail.modelData.copy
              cursorShape: Qt.PointingHandCursor
              onClicked: info.copyRequested(detail.modelData.copy, detail.modelData.label + " copied")
            }
          }
        }
      }

      Item { width: 1; height: Style.space(2) }

      Flow {
        width: parent.width
        spacing: Style.space(6)

        Repeater {
          model: Model.infoActions(info.chat, info.app.meId)
          delegate: Rectangle {
            id: action
            required property var modelData
            width: actionLabel.implicitWidth + Style.space(20)
            height: Style.space(30)
            radius: Style.cornerRadius
            color: actionArea.containsMouse ? Qt.rgba(info.app.foreground.r, info.app.foreground.g, info.app.foreground.b, 0.12)
                                            : Qt.rgba(info.app.foreground.r, info.app.foreground.g, info.app.foreground.b, 0.06)
            Text {
              id: actionLabel
              anchors.centerIn: parent
              text: action.modelData.label
              color: action.modelData.danger ? info.app.urgent : info.app.foreground
              font.family: info.app.fontFamily
              font.pixelSize: Style.font.caption
            }
            MouseArea {
              id: actionArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: info.actionRequested(action.modelData.id)
            }
          }
        }
      }
    }

    // ------------------------------------------------ tabs
    Flickable {
      id: tabStrip
      Layout.fillWidth: true
      Layout.topMargin: Style.space(14)
      Layout.preferredHeight: Style.space(34)
      contentWidth: tabRow.implicitWidth + Style.space(36)
      contentHeight: height
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.HorizontalFlick

      Row {
        id: tabRow
        x: Style.space(18)
        height: tabStrip.height
        spacing: Style.space(16)

        Repeater {
          model: info.tabs
          delegate: Item {
            id: tabItem
            required property var modelData
            readonly property bool current: modelData.key === info.tab
            width: tabLabel.implicitWidth
            height: tabRow.height

            Text {
              id: tabLabel
              anchors.verticalCenter: parent.verticalCenter
              text: tabItem.modelData.label + (tabItem.modelData.count > 0 ? "  " + tabItem.modelData.count : "")
              color: tabItem.current ? info.app.foreground : info.app.muted
              font.family: info.app.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: tabItem.current
            }
            Rectangle {
              visible: tabItem.current
              anchors.bottom: parent.bottom
              width: parent.width
              height: Math.max(2, Style.space(2))
              radius: height / 2
              color: info.app.accent
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: info.selectTab(tabItem.modelData.key)
            }
            onCurrentChanged: if (current) tabStrip.contentX = Math.max(0, Math.min(x - Style.space(20), tabStrip.contentWidth - tabStrip.width))
          }
        }
      }
    }

    // ------------------------------------------------ members, or what was shared
    Item {
      Layout.fillWidth: true
      Layout.fillHeight: true

      ListView {
        id: listView
        anchors.fill: parent
        anchors.topMargin: Style.space(6)
        visible: !info.grid
        clip: true
        model: visible ? info.items : []
        boundsBehavior: Flickable.StopAtBounds
        onAtYEndChanged: if (atYEnd && count > 0) info.loadMore()

        WheelScroll { view: listView }

        delegate: Rectangle {
          id: entry
          required property var modelData
          required property int index
          readonly property bool member: info.tab === "members"
          readonly property var shared: entry.member ? null : Model.sharedRow(entry.modelData, info.tab, info.nowMs)
          width: listView.width
          height: Style.space(54)
          color: entry.index === info.cursor && info.activeFocus ? info.app.selected
               : (entryArea.containsMouse ? Qt.rgba(info.app.foreground.r, info.app.foreground.g, info.app.foreground.b, 0.04) : "transparent")

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.space(18)
            anchors.rightMargin: Style.space(18)
            spacing: Style.space(10)

            Avatar {
              visible: entry.member
              app: info.app
              chat: entry.member ? { title: entry.modelData.name, kind: "private", userId: 0, photo: null } : null
              size: Style.space(34)
              Layout.preferredWidth: visible ? size : 0
              Layout.preferredHeight: size
            }
            Column {
              Layout.fillWidth: true
              spacing: Style.space(2)
              Text {
                width: parent.width
                elide: Text.ElideRight
                text: entry.member ? (entry.modelData.name || "Deleted account") : entry.shared.title
                textFormat: Text.PlainText
                color: info.app.foreground
                font.family: info.app.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                width: parent.width
                elide: Text.ElideRight
                text: entry.member ? Model.memberDetail(entry.modelData, info.nowMs) : entry.shared.detail
                textFormat: Text.PlainText
                color: info.app.muted
                font.family: info.app.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
          MouseArea {
            id: entryArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              info.cursor = entry.index
              info.activate(entry.index)
            }
          }
        }
      }

      GridView {
        id: gridView
        anchors.fill: parent
        anchors.margins: Style.space(8)
        visible: info.grid
        clip: true
        model: visible ? info.items : []
        cellWidth: Math.floor(width / 3)
        cellHeight: cellWidth
        boundsBehavior: Flickable.StopAtBounds
        onAtYEndChanged: if (atYEnd && count > 0) info.loadMore()

        WheelScroll { view: gridView }

        delegate: Item {
          id: cell
          required property var modelData
          required property int index
          readonly property var content: cell.modelData.content || ({})
          readonly property var media: cell.content.media || null
          // A video's small thumbnail; a photo itself (at most 1280 pixels, as in the chat).
          readonly property var picture: !cell.media ? null
              : (cell.media.thumb && cell.media.thumb.file ? info.app.fileState(cell.media.thumb.file)
                 : (cell.content.kind === "photo" ? info.app.fileState(cell.media.file) : null))
          width: gridView.cellWidth
          height: gridView.cellHeight

          Component.onCompleted: if (cell.picture && !cell.picture.path && !cell.picture.active) info.app.download(cell.picture.fileId, 1)

          Rectangle {
            anchors.fill: parent
            anchors.margins: 1
            clip: true
            color: Qt.rgba(info.app.foreground.r, info.app.foreground.g, info.app.foreground.b, 0.06)

            Image {
              anchors.fill: parent
              visible: shown.status !== Image.Ready
              source: Model.miniUrl(cell.media ? cell.media.mini : null)
              fillMode: Image.PreserveAspectCrop
            }
            Image {
              id: shown
              anchors.fill: parent
              source: cell.picture ? Model.fileUrl(cell.picture.path) : ""
              asynchronous: true
              fillMode: Image.PreserveAspectCrop
              sourceSize.width: 320
              sourceSize.height: 320
            }
            Rectangle {
              visible: cell.content.kind === "video" || cell.content.kind === "gif"
              anchors.left: parent.left
              anchors.bottom: parent.bottom
              anchors.margins: Style.space(4)
              width: badge.implicitWidth + Style.space(8)
              height: badge.implicitHeight + Style.space(2)
              radius: Style.cornerRadius
              color: Qt.rgba(0, 0, 0, 0.55)
              Text {
                id: badge
                anchors.centerIn: parent
                text: cell.content.kind === "gif" ? "GIF" : Model.formatDuration(cell.media ? cell.media.duration : 0)
                color: "white"
                font.pixelSize: Style.font.caption
              }
            }
            Rectangle {
              anchors.fill: parent
              visible: cell.index === info.cursor && info.activeFocus
              color: "transparent"
              border.width: Math.max(2, Style.space(2))
              border.color: info.app.accent
            }
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              info.cursor = cell.index
              info.activate(cell.index)
            }
          }
        }
      }

      Text {
        anchors.centerIn: parent
        visible: info.items.length === 0
        text: info.loading || (info.tab !== "" && !info.exhausted) ? "Loading…" : "Nothing here yet"
        color: info.app.muted
        font.family: info.app.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }
  }
}
