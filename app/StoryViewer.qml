import QtQuick
import QtMultimedia
import qs.Commons
import "Model.js" as Model
import "Keymap.js" as Keymap

// Stories over the whole screen, one after another: a photo for six seconds, a video to its end,
// then the next chat's. Keyboard: ←/→ or h/l step, Space pauses, Esc or q closes; a click on the
// left third goes back, anywhere else forward. Opening a story tells Telegram you have seen it, as
// every Telegram app does, so its poster sees you among its viewers.
FocusScope {
  id: viewer

  property var app
  property var client
  property var chats: []          // chats with active stories, as Model.storyChats orders them
  property real chatId: 0         // 0 while closed
  property int storyId: 0
  property var story: null        // what story.get answered, once it has
  property string error: ""
  property bool paused: false
  property real shownMs: 0
  property int serial: 0          // another story: answers about the one before are dropped

  readonly property int photoMs: 6000
  readonly property var active: Model.findStories(viewer.chats, viewer.chatId)
  readonly property var stories: viewer.active ? viewer.active.stories : []
  readonly property int index: {
    for (var i = 0; i < viewer.stories.length; i++) if (viewer.stories[i].id === viewer.storyId) return i
    return -1
  }
  readonly property var media: viewer.story ? viewer.story.media : null
  readonly property var file: viewer.media ? viewer.app.fileState(viewer.media.file) : null
  readonly property string url: viewer.file ? Model.fileUrl(viewer.file.path) : ""
  // Who posted it; your own stories are yours, not Saved Messages.
  readonly property var poster: {
    var known = Model.findChat(viewer.app.chats, viewer.chatId)
    var title = viewer.chatId === viewer.app.meId ? "Your story"
              : (known ? Model.chatTitle(known, viewer.app.meId) : (viewer.active ? viewer.active.title : ""))
    return { id: viewer.chatId, title: title, kind: "story", photo: known ? known.photo : null }
  }
  readonly property real progress: !viewer.story ? 0
      : (viewer.story.kind === "video" ? (videoLoader.item ? videoLoader.item.progress : 0) : Math.min(1, viewer.shownMs / viewer.photoMs))
  readonly property string status: viewer.error !== "" ? viewer.error
      : (!viewer.story ? "Loading…"
         : (viewer.story.kind === "live" ? "A live story: watch it in an official Telegram app"
            : (viewer.story.kind !== "photo" && viewer.story.kind !== "video" ? "This story needs an official Telegram app"
               : (viewer.url === "" ? "Loading " + Math.round(Model.progress(viewer.file) * 100) + "%" : ""))))

  signal closed()

  visible: viewer.chatId !== 0
  onVisibleChanged: if (visible) forceActiveFocus()
  onFileChanged: if (viewer.file && !viewer.url && !viewer.file.active) viewer.app.download(viewer.file.fileId, 32)

  function show(chatId, storyId) {
    viewer.leave()
    viewer.chatId = chatId
    viewer.storyId = storyId
    viewer.error = ""
    viewer.paused = false
    viewer.shownMs = 0
    var serial = ++viewer.serial
    viewer.client.request("story.get", { chatId: chatId, storyId: storyId }, function (answer) {
      if (serial !== viewer.serial) return
      if (!answer.ok || !answer.result.story) {
        viewer.error = answer.error || "This story is no longer available"
        return
      }
      viewer.story = answer.result.story
      viewer.client.request("story.open", { chatId: chatId, storyId: storyId })
    })
  }

  // Telegram hears the story is no longer being viewed.
  function leave() {
    if (viewer.story) viewer.client.request("story.close", { chatId: viewer.story.chatId, storyId: viewer.story.id })
    viewer.story = null
  }

  function finish() {
    viewer.leave()
    viewer.serial++
    viewer.chatId = 0
    viewer.storyId = 0
    viewer.closed()
  }

  function step(delta) {
    var next = Model.storyStep(viewer.chats, viewer.chatId, viewer.storyId, delta)
    if (next) viewer.show(next.chatId, next.storyId)
    else if (delta > 0) viewer.finish()
  }

  Keys.onPressed: function (event) {
    var keys = viewer.app.shortcuts
    if (Keymap.matches(keys, "story.close", event)) viewer.finish()
    else if (Keymap.matches(keys, "story.previous", event)) viewer.step(-1)
    else if (Keymap.matches(keys, "story.next", event)) viewer.step(1)
    else if (Keymap.matches(keys, "story.pause", event)) viewer.paused = !viewer.paused
    else return
    event.accepted = true
  }

  // A photo stays six seconds on screen, not counting while it loads or is paused.
  Timer {
    interval: 100
    repeat: true
    running: viewer.visible && !viewer.paused && !!viewer.story && viewer.story.kind === "photo" && photo.status === Image.Ready
    onTriggered: {
      viewer.shownMs += interval
      if (viewer.shownMs >= viewer.photoMs) viewer.step(1)
    }
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.97)   // over the whole screen: whatever is behind should not show through
  }

  MouseArea {
    anchors.fill: parent
    onClicked: function (mouse) { viewer.step(mouse.x < width / 3 ? -1 : 1) }
  }

  // A story is tall: it gets the screen's height at a phone's proportions.
  Item {
    id: stage
    anchors.centerIn: parent
    height: parent.height - Style.space(40)
    width: Math.min(parent.width - Style.space(40), height * 9 / 16)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: Qt.rgba(1, 1, 1, 0.04)
    }

    Image {
      anchors.fill: parent
      visible: photo.status !== Image.Ready && !videoLoader.item
      source: viewer.media ? Model.miniUrl(viewer.media.mini) : ""
      fillMode: Image.PreserveAspectFit
    }

    Image {
      id: photo
      anchors.fill: parent
      source: viewer.story && viewer.story.kind === "photo" ? viewer.url : ""
      asynchronous: true
      fillMode: Image.PreserveAspectFit
    }

    Loader {
      id: videoLoader
      anchors.fill: parent
      active: !!viewer.story && viewer.story.kind === "video" && viewer.url !== ""
      sourceComponent: Item {
        readonly property real progress: player.duration > 0 ? player.position / player.duration : 0

        MediaPlayer {
          id: player
          source: viewer.url
          videoOutput: output
          audioOutput: AudioOutput {}
          onMediaStatusChanged: if (mediaStatus === MediaPlayer.EndOfMedia) Qt.callLater(function () { viewer.step(1) })
        }
        VideoOutput {
          id: output
          anchors.fill: parent
          fillMode: VideoOutput.PreserveAspectFit
        }
        Connections {
          target: viewer
          function onPausedChanged() {
            if (viewer.paused) player.pause()
            else player.play()
          }
        }
        Component.onCompleted: if (!viewer.paused) player.play()
      }
    }

    Text {
      anchors.centerIn: parent
      width: parent.width - Style.space(40)
      visible: viewer.status !== ""
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      textFormat: Text.PlainText
      text: viewer.status
      color: "white"
      font.family: viewer.app.fontFamily
      font.pixelSize: Style.font.body
    }

    // How far through the chat's stories: one bar each.
    Row {
      id: bars
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(10)
      spacing: Style.space(4)

      Repeater {
        model: viewer.stories
        delegate: Rectangle {
          required property int index
          width: (bars.width - bars.spacing * (viewer.stories.length - 1)) / Math.max(1, viewer.stories.length)
          height: Style.space(3)
          radius: height / 2
          color: Qt.rgba(1, 1, 1, 0.3)

          Rectangle {
            height: parent.height
            radius: parent.radius
            color: "white"
            width: parent.width * (index < viewer.index ? 1 : (index > viewer.index ? 0 : viewer.progress))
          }
        }
      }
    }

    Row {
      anchors.left: parent.left
      anchors.top: bars.bottom
      anchors.margins: Style.space(10)
      spacing: Style.space(10)

      Avatar {
        app: viewer.app
        chat: viewer.poster
        size: Style.space(36)
      }
      Column {
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          text: viewer.poster.title
          textFormat: Text.PlainText
          color: "white"
          font.family: viewer.app.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
        Text {
          text: !viewer.story ? "" : Model.clock(viewer.story.date)
                + (viewer.paused ? "  ·  paused" : "")
                + (viewer.story.views > 0 ? "  ·  " + viewer.story.views + (viewer.story.views === 1 ? " view" : " views") : "")
          color: Qt.rgba(1, 1, 1, 0.7)
          font.family: viewer.app.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    Column {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: Style.space(14)
      spacing: Style.space(8)

      Text {
        width: parent.width
        visible: text !== ""
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        maximumLineCount: 4
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: viewer.story ? viewer.story.caption.text : ""
        color: "white"
        style: Text.Raised
        styleColor: Qt.rgba(0, 0, 0, 0.6)
        font.family: viewer.app.fontFamily
        font.pixelSize: Style.font.body
      }
      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        text: Keymap.label(Keymap.keysFor(viewer.app.shortcuts, "story.previous")[0] || "") + " "
              + Keymap.label(Keymap.keysFor(viewer.app.shortcuts, "story.next")[0] || "") + " to step, "
              + Keymap.label(Keymap.keysFor(viewer.app.shortcuts, "story.pause")[0] || "") + " to pause, "
              + Keymap.label(Keymap.keysFor(viewer.app.shortcuts, "story.close")[0] || "") + " to close"
        color: Qt.rgba(1, 1, 1, 0.55)
        font.family: viewer.app.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
