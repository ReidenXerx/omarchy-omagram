import QtQuick
import QtQuick.Effects
import qs.Commons
import "Model.js" as Model

// A chat's photo in a circle: its tiny inline thumbnail straight away, the real photo once it
// is downloaded, and the chat's initials when it has no photo.
Item {
  id: avatar

  property var app
  property var chat
  property real size: Style.space(44)

  readonly property var photo: avatar.chat && avatar.chat.photo ? avatar.chat.photo : null
  readonly property var file: avatar.photo && avatar.app ? avatar.app.fileState(avatar.photo.file) : null
  readonly property string url: avatar.file ? Model.fileUrl(avatar.file.path) : ""
  readonly property string source: avatar.url || (avatar.photo ? Model.miniUrl(avatar.photo.mini) : "")
  readonly property bool shown: picture.status === Image.Ready
  // Your chat with yourself is Saved Messages, marked with a bookmark as Telegram does.
  readonly property bool saved: !!avatar.chat && avatar.chat.kind === "private" && !!avatar.app && !!avatar.app.meId
                                && avatar.chat.userId === avatar.app.meId

  implicitWidth: avatar.size
  implicitHeight: avatar.size

  // A small profile photo is a few kilobytes: ask for it as soon as it is on screen.
  function fetch() {
    if (avatar.saved) return
    if (avatar.file && !avatar.url && !avatar.file.active && avatar.app && avatar.app.download)
      avatar.app.download(avatar.file.id, 1)
  }
  Component.onCompleted: fetch()
  onFileChanged: fetch()

  Rectangle {
    anchors.fill: parent
    radius: width / 2
    visible: !avatar.shown || avatar.saved
    color: Qt.rgba(avatar.app.accent.r, avatar.app.accent.g, avatar.app.accent.b, 0.22)

    Text {
      anchors.centerIn: parent
      // md-bookmark U+F00C0
      text: avatar.saved ? String.fromCodePoint(0xF00C0) : Model.initials(avatar.chat ? avatar.chat.title : "")
      textFormat: Text.PlainText
      color: avatar.app.foreground
      font.family: avatar.saved ? (avatar.app.glyphFamily || Style.font.family) : avatar.app.fontFamily
      font.pixelSize: Math.round(avatar.size * (avatar.saved ? 0.46 : 0.36))
      font.bold: !avatar.saved
    }
  }

  Image {
    id: picture
    anchors.fill: parent
    visible: false
    source: avatar.source
    asynchronous: true
    fillMode: Image.PreserveAspectCrop
    sourceSize.width: Math.round(avatar.size * 2)
    sourceSize.height: Math.round(avatar.size * 2)
    smooth: true
  }

  Rectangle {
    id: mask
    anchors.fill: parent
    radius: width / 2
    visible: false
    layer.enabled: true
  }

  MultiEffect {
    anchors.fill: parent
    visible: avatar.shown && !avatar.saved
    source: picture
    maskEnabled: true
    maskSource: mask
    maskThresholdMin: 0.5
    maskSpreadAtMin: 1.0
  }
}
