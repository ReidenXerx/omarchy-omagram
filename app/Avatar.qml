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

  implicitWidth: avatar.size
  implicitHeight: avatar.size

  // A small profile photo is a few kilobytes: ask for it as soon as it is on screen.
  function fetch() {
    if (avatar.file && !avatar.url && !avatar.file.active && avatar.app && avatar.app.download)
      avatar.app.download(avatar.file.id, 1)
  }
  Component.onCompleted: fetch()
  onFileChanged: fetch()

  Rectangle {
    anchors.fill: parent
    radius: width / 2
    visible: !avatar.shown
    color: Qt.rgba(avatar.app.accent.r, avatar.app.accent.g, avatar.app.accent.b, 0.22)

    Text {
      anchors.centerIn: parent
      text: Model.initials(avatar.chat ? avatar.chat.title : "")
      textFormat: Text.PlainText
      color: avatar.app.accent
      font.family: avatar.app.fontFamily
      font.pixelSize: Math.round(avatar.size * 0.36)
      font.bold: true
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
    visible: avatar.shown
    source: picture
    maskEnabled: true
    maskSource: mask
    maskThresholdMin: 0.5
    maskSpreadAtMin: 1.0
  }
}
