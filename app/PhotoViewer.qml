import QtQuick
import qs.Commons
import "Model.js" as Model

// A photo at full size over the chat. Keyboard: ←/→ or h/l step through the chat's photos,
// Esc or q closes; a click anywhere closes too. The photo is the file the service already
// vouched for, downloaded on demand when you step to one that is not on disk yet.
FocusScope {
  id: viewer

  property var app
  property var messages: []
  property real messageId: 0

  signal closed()

  readonly property var photos: (viewer.messages || []).filter(function (m) {
    return m && m.content && m.content.kind === "photo" && m.content.media
  })
  readonly property int index: {
    for (var i = 0; i < viewer.photos.length; i++) if (viewer.photos[i].id === viewer.messageId) return i
    return -1
  }
  readonly property var current: viewer.index >= 0 ? viewer.photos[viewer.index] : null
  readonly property var file: viewer.current ? app.fileState(viewer.current.content.media.file) : null
  readonly property string url: viewer.file ? Model.fileUrl(viewer.file.path) : ""

  visible: viewer.messageId > 0
  onVisibleChanged: if (visible) forceActiveFocus()
  onFileChanged: if (viewer.file && !viewer.url && !viewer.file.active) app.download(viewer.file.id, 32)

  function step(delta) {
    var next = viewer.index + delta
    if (viewer.index >= 0 && next >= 0 && next < viewer.photos.length) app.openPhoto(viewer.photos[next])
  }

  Keys.onPressed: function (event) {
    if (event.key === Qt.Key_Escape || event.key === Qt.Key_Q) { viewer.closed(); event.accepted = true }
    else if (event.key === Qt.Key_Left || event.key === Qt.Key_H) { viewer.step(-1); event.accepted = true }
    else if (event.key === Qt.Key_Right || event.key === Qt.Key_L) { viewer.step(1); event.accepted = true }
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.92)
  }

  MouseArea {
    anchors.fill: parent
    onClicked: viewer.closed()
  }

  Image {
    anchors.fill: parent
    anchors.margins: Style.space(48)
    anchors.bottomMargin: Style.space(80)
    visible: photo.status !== Image.Ready
    source: viewer.current ? Model.miniUrl(viewer.current.content.media.mini) : ""
    fillMode: Image.PreserveAspectFit
    smooth: true
  }

  Image {
    id: photo
    anchors.fill: parent
    anchors.margins: Style.space(48)
    anchors.bottomMargin: Style.space(80)
    source: viewer.url
    asynchronous: true
    fillMode: Image.PreserveAspectFit
  }

  Column {
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(20)
    width: Math.min(parent.width - Style.space(96), Style.space(900))
    spacing: Style.space(6)

    Text {
      width: parent.width
      visible: text !== ""
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      maximumLineCount: 2
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: viewer.current ? (viewer.current.content.text || "") : ""
      color: "white"
      font.family: app.fontFamily
      font.pixelSize: Style.font.body
    }
    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: (viewer.index + 1) + " of " + viewer.photos.length
        + (viewer.file && viewer.file.active ? "  ·  loading " + Math.round(Model.progress(viewer.file) * 100) + "%" : "")
        + "   ← → to step, Esc to close"
      color: Qt.rgba(1, 1, 1, 0.6)
      font.family: app.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
