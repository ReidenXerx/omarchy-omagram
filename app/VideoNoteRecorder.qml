import QtQuick
import QtQuick.Effects
import QtMultimedia
import Quickshell
import qs.Commons
import "Model.js" as Model
import "Keymap.js" as Keymap

// Recording a video message: a round preview of the camera, up to a minute.
//
// Keyboard: Space or Enter starts recording, Enter sends, Esc cancels. The camera and the
// microphone are only open while this is showing. The recording is written to Omagram's
// private recording directory; the service cuts it to a square and sends it.
FocusScope {
  id: noteRecorder

  property var app
  property real chatId: 0
  readonly property int maxSeconds: 60

  property string phase: "closed"   // closed | preview | recording | stopping
  property bool sendWhenStopped: false
  property real startedAt: 0
  property real now: Date.now()
  readonly property real seconds: noteRecorder.phase === "recording" || noteRecorder.phase === "stopping"
                                  ? Math.max(0, (noteRecorder.now - noteRecorder.startedAt) / 1000) : 0
  readonly property var mediaRecorder: capture.item ? capture.item.recorder : null

  signal recorded(real chatId, string path)
  signal discarded(string path)
  signal failed(string message)

  visible: noteRecorder.phase !== "closed"

  function open(chatId) {
    if (noteRecorder.phase !== "closed" || !chatId) return
    noteRecorder.chatId = chatId
    noteRecorder.sendWhenStopped = false
    noteRecorder.phase = "preview"
    noteRecorder.forceActiveFocus()
  }

  function start() {
    var dir = Quickshell.env("XDG_RUNTIME_DIR")
    if (noteRecorder.phase !== "preview" || !dir || !noteRecorder.mediaRecorder) return
    noteRecorder.mediaRecorder.outputLocation = "file://" + dir + "/omagram/rec/note-" + Date.now() + ".mp4"
    noteRecorder.mediaRecorder.record()
    noteRecorder.startedAt = Date.now()
    noteRecorder.now = noteRecorder.startedAt
    noteRecorder.phase = "recording"
  }

  function finish(send) {
    if (noteRecorder.phase === "recording" && noteRecorder.mediaRecorder) {
      noteRecorder.sendWhenStopped = send
      noteRecorder.now = Date.now()
      noteRecorder.phase = "stopping"
      noteRecorder.mediaRecorder.stop()
    } else if (noteRecorder.phase === "preview") {
      noteRecorder.phase = "closed"
      noteRecorder.discarded("")
    }
  }

  function stopped() {
    var path = decodeURIComponent(String(noteRecorder.mediaRecorder ? noteRecorder.mediaRecorder.actualLocation : "").replace(/^file:\/\//, ""))
    var send = noteRecorder.sendWhenStopped && noteRecorder.seconds >= 1 && path !== ""
    noteRecorder.phase = "closed"
    if (send) noteRecorder.recorded(noteRecorder.chatId, path)
    else noteRecorder.discarded(path)
  }

  Keys.onPressed: function (event) {
    var keys = noteRecorder.app.shortcuts
    if (Keymap.matches(keys, "videoNote.cancel", event)) noteRecorder.finish(false)
    else if (Keymap.matches(keys, "videoNote.record", event)) {
      if (noteRecorder.phase === "preview") noteRecorder.start()
      else noteRecorder.finish(true)
    } else return
    event.accepted = true
  }

  Timer {
    interval: 100
    repeat: true
    running: noteRecorder.phase === "recording"
    onTriggered: {
      noteRecorder.now = Date.now()
      if (noteRecorder.seconds >= noteRecorder.maxSeconds) noteRecorder.finish(true)
    }
  }

  // Only while showing: closing releases the camera and the microphone.
  Loader {
    id: capture
    active: noteRecorder.visible
    sourceComponent: CaptureSession {
      camera: Camera {
        active: true
        onErrorOccurred: function (error, message) { noteRecorder.failed(message || "The camera could not be opened") }
      }
      audioInput: AudioInput {}
      videoOutput: preview
      recorder: MediaRecorder {
        id: mediaRecorderItem
        onRecorderStateChanged: {
          if (recorderState === MediaRecorder.StoppedState && noteRecorder.phase === "stopping") noteRecorder.stopped()
        }
        onErrorOccurred: function (error, message) {
          noteRecorder.failed(message || "Recording failed")
          if (noteRecorder.phase === "recording" || noteRecorder.phase === "stopping") noteRecorder.phase = "closed"
        }
      }
    }
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.8)
  }

  MouseArea { anchors.fill: parent }

  Column {
    anchors.centerIn: parent
    spacing: Style.space(18)

    Item {
      id: circle
      anchors.horizontalCenter: parent.horizontalCenter
      width: Math.round(Math.min(noteRecorder.width, noteRecorder.height) * 0.55)
      height: width

      Item {
        id: previewSource
        anchors.fill: parent
        visible: false
        layer.enabled: true
        VideoOutput {
          id: preview
          anchors.fill: parent
          fillMode: VideoOutput.PreserveAspectCrop
        }
      }
      Rectangle {
        id: circleMask
        anchors.fill: parent
        radius: width / 2
        visible: false
        layer.enabled: true
      }
      Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: Qt.rgba(1, 1, 1, 0.06)
      }
      MultiEffect {
        anchors.fill: parent
        source: previewSource
        maskEnabled: true
        maskSource: circleMask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
      }
      Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: "transparent"
        border.width: Style.space(4)
        border.color: noteRecorder.phase === "recording" ? noteRecorder.app.urgent : Qt.rgba(1, 1, 1, 0.25)
      }
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      readonly property string recordKey: Keymap.label(Keymap.keysFor(noteRecorder.app.shortcuts, "videoNote.record")[0] || "")
      readonly property string cancelKey: Keymap.label(Keymap.keysFor(noteRecorder.app.shortcuts, "videoNote.cancel")[0] || "")
      text: noteRecorder.phase === "preview" ? recordKey + " to start recording  ·  " + cancelKey + " to cancel"
          : (Model.formatDuration(noteRecorder.seconds) + " / " + Model.formatDuration(noteRecorder.maxSeconds)
             + "   " + recordKey + " to send  ·  " + cancelKey + " to cancel")
      color: "white"
      font.family: noteRecorder.app.fontFamily
      font.pixelSize: Style.font.body
    }

    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(24)

      Repeater {
        // md-close (U+F0156); md-record-circle (U+F044A) to start, md-send (U+F048A) to send
        model: [
          { glyph: String.fromCodePoint(0xF0156), action: "cancel" },
          { glyph: String.fromCodePoint(noteRecorder.phase === "preview" ? 0xF044A : 0xF048A), action: "main" }
        ]
        delegate: Rectangle {
          required property var modelData
          width: Style.space(56)
          height: width
          radius: width / 2
          color: modelData.action === "main" ? (noteRecorder.phase === "preview" ? noteRecorder.app.urgent : noteRecorder.app.accent)
                                             : Qt.rgba(1, 1, 1, 0.12)
          Text {
            anchors.centerIn: parent
            text: modelData.glyph
            color: "white"
            font.family: noteRecorder.app.glyphFamily
            font.pixelSize: Style.font.title
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (modelData.action === "cancel") noteRecorder.finish(false)
              else if (noteRecorder.phase === "preview") noteRecorder.start()
              else noteRecorder.finish(true)
            }
          }
        }
      }
    }
  }
}
