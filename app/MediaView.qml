import QtQuick
import QtQuick.Effects
import QtMultimedia
import Qt.labs.lottieqt
import qs.Commons
import "Model.js" as Model

// Photos, stickers, GIFs, voice and video messages, videos and files inside a message.
//
// The service downloads media into TDLib's files directory; this view only shows files that
// are already on disk (as file:// URLs to paths the service vouched for) and asks for
// downloads. Every kind has a known size before anything loads, so the chat never jumps.
// Keyboard: activate() downloads what is missing and plays or pauses what is here.
Item {
  id: view

  property var app
  property var message
  property real maxWidth: 360
  // The sticker picker shows stickers small and still (animated ones as their thumbnail)
  // and handles clicks itself.
  property real stickerSize: Style.space(180)
  property bool still: false
  property bool interactive: true
  // Spoiler media stays covered, and does not play behind the cover, until you choose to see it.
  property bool spoiler: false
  property bool revealed: false
  readonly property bool covered: view.spoiler && !view.revealed
  signal revealRequested()

  readonly property var content: message ? message.content : null
  readonly property string kind: content ? content.kind : ""
  readonly property var media: content && content.media ? content.media : null
  // Never null: pieces keep evaluating for a moment while a message leaves the list,
  // after its media is gone.
  readonly property var info: media || ({})
  readonly property var file: media ? app.fileState(media.file) : null
  readonly property string url: file ? Model.fileUrl(file.path) : ""
  readonly property bool ready: url !== ""
  readonly property bool downloading: !!file && file.active
  readonly property real fraction: Model.progress(file)
  readonly property var thumbFile: info.thumb && info.thumb.file ? app.fileState(info.thumb.file) : null
  readonly property string thumbUrl: thumbFile ? Model.fileUrl(thumbFile.path) : ""

  readonly property var box: {
    if (!media) return { width: 0, height: 0 }
    var wide = Math.min(maxWidth, Style.space(360))
    if (kind === "photo") return Model.fitSize(media.width, media.height, wide, Style.space(360))
    if (kind === "sticker") return Model.fitSize(media.width || 512, media.height || 512, stickerSize, stickerSize)
    if (kind === "gif" || kind === "video") return Model.fitSize(media.width, media.height, wide, Style.space(320))
    if (kind === "videoNote") return { width: Style.space(200), height: Style.space(200) }
    return { width: Math.min(maxWidth, Style.space(300)), height: Style.space(48) }
  }

  visible: media !== null
  implicitWidth: box.width
  implicitHeight: box.height

  function download(priority) {
    if (file && !ready && !downloading) app.download(file.id, priority || 16)
  }

  function activate() {
    if (!media) return
    if (covered) { revealRequested(); return }
    if (!ready) { download(32); return }
    if (kind === "photo") { app.openPhoto(message); return }
    togglePlay()
  }

  function togglePlay() {
    if (covered) { revealRequested(); return }
    if (loader.item && loader.item.toggle) loader.item.toggle()
  }

  Component.onCompleted: {
    if (!media) return
    if (still && kind === "sticker" && info.format !== "webp") {
      if (thumbFile && !thumbUrl && !thumbFile.active) app.download(thumbFile.id, 8)
      return
    }
    if (Model.autoDownload(kind, file ? file.size : 0)) download(kind === "sticker" ? 20 : 12)
  }

  Loader {
    id: loader
    width: view.box.width
    height: view.box.height
    sourceComponent: ({ photo: photoView, sticker: stickerView, gif: gifView, video: videoView, videoNote: videoNoteView,
                        voice: voiceView, audio: fileView, file: fileView })[view.kind] || null
  }

  MouseArea {
    anchors.fill: parent
    enabled: view.interactive && view.kind !== "file" && view.kind !== "audio"
    cursorShape: Qt.PointingHandCursor
    onClicked: view.activate()
  }

  // ------------------------------------------------ shared pieces

  component Placeholder: Image {
    anchors.fill: parent
    source: Model.miniUrl(view.media ? view.info.mini : null)
    fillMode: Image.PreserveAspectCrop
    smooth: true
  }

  component ProgressBar: Rectangle {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.margins: Style.space(8)
    height: Style.space(4)
    radius: height / 2
    visible: view.downloading && !view.ready
    color: Qt.rgba(0, 0, 0, 0.45)
    Rectangle {
      width: parent.width * view.fraction
      height: parent.height
      radius: parent.radius
      color: view.app.accent
    }
  }

  component PlayBadge: Rectangle {
    anchors.centerIn: parent
    width: Style.space(48)
    height: width
    radius: width / 2
    color: Qt.rgba(0, 0, 0, 0.5)
    property bool playing: false
    Text {
      anchors.centerIn: parent
      // md-download U+F01DA, md-play U+F040A, md-pause U+F03E4
      text: !view.ready ? "󰇚" : (parent.playing ? "󰏤" : "󰐊")
      color: "white"
      font.family: view.app.glyphFamily
      font.pixelSize: Style.font.title
    }
  }

  // ------------------------------------------------ photo
  Component {
    id: photoView
    Item {
      clip: true
      Placeholder { visible: full.status !== Image.Ready }
      Image {
        id: full
        anchors.fill: parent
        source: view.url
        asynchronous: true
        fillMode: Image.PreserveAspectCrop
        sourceSize.width: Math.min(2048, width * 2)
        sourceSize.height: Math.min(2048, height * 2)
      }
      ProgressBar {}
    }
  }

  // ------------------------------------------------ sticker
  Component {
    id: stickerView
    Item {
      id: sticker
      property string lottie: ""
      readonly property string format: view.info.format

      function fetch() {
        if (format === "tgs" && !view.still && view.ready && lottie === "" && view.file && view.app)
          // The answer is asynchronous: by the time it comes the message may have scrolled
          // away and this piece been destroyed.
          view.app.lottiePath(view.file.id, function (path) { if (sticker) sticker.lottie = path })
      }
      Component.onCompleted: fetch()
      Connections {
        target: view
        function onReadyChanged() { sticker.fetch() }
      }

      Text {
        anchors.centerIn: parent
        visible: !(format === "webp" && still.status === Image.Ready) && !(format === "tgs" && sticker.lottie !== "" && !view.still)
                 && !(format === "webm" && view.ready && !view.still) && !(view.still && stillThumb.status === Image.Ready)
        text: view.info.emoji || "🙂"
        font.pixelSize: Math.round(parent.height * 0.45)
        opacity: 0.35
      }
      Image {
        id: still
        anchors.fill: parent
        visible: format === "webp"
        source: format === "webp" ? view.url : ""
        asynchronous: true
        fillMode: Image.PreserveAspectFit
        sourceSize.width: 512
        sourceSize.height: 512
      }
      Image {
        id: stillThumb
        anchors.fill: parent
        visible: view.still && format !== "webp"
        source: visible ? view.thumbUrl : ""
        asynchronous: true
        fillMode: Image.PreserveAspectFit
      }
      Loader {
        anchors.fill: parent
        active: format === "tgs" && sticker.lottie !== "" && !view.still
        sourceComponent: LottieAnimation {
          source: Model.fileUrl(sticker.lottie)
          autoPlay: true
          loops: LottieAnimation.Infinite
        }
      }
      Loader {
        anchors.fill: parent
        active: format === "webm" && view.ready && !view.still
        sourceComponent: Video {
          source: view.url
          autoPlay: true
          muted: true
          loops: MediaPlayer.Infinite
          fillMode: VideoOutput.PreserveAspectFit
        }
      }
    }
  }

  // ------------------------------------------------ GIF
  Component {
    id: gifView
    Item {
      clip: true
      Placeholder { visible: !view.ready }
      Loader {
        anchors.fill: parent
        active: view.ready && !view.covered
        sourceComponent: Video {
          source: view.url
          autoPlay: true
          muted: true
          loops: MediaPlayer.Infinite
          fillMode: VideoOutput.PreserveAspectCrop
        }
      }
      Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.margins: Style.space(8)
        width: gifLabel.implicitWidth + Style.space(12)
        height: gifLabel.implicitHeight + Style.space(4)
        radius: Style.cornerRadius
        color: Qt.rgba(0, 0, 0, 0.5)
        Text { id: gifLabel; anchors.centerIn: parent; text: "GIF"; color: "white"; font.pixelSize: Style.font.caption; font.bold: true }
      }
      ProgressBar {}
    }
  }

  // ------------------------------------------------ video
  Component {
    id: videoView
    Item {
      id: videoItem
      clip: true
      property bool started: false

      function toggle() {
        if (!view.ready) { view.download(32); return }
        if (!started) { started = true; return }
        if (videoLoader.item) {
          if (videoLoader.item.playbackState === MediaPlayer.PlayingState) videoLoader.item.pause()
          else videoLoader.item.play()
        }
      }

      Placeholder { visible: !videoItem.started }
      Loader {
        id: videoLoader
        anchors.fill: parent
        active: videoItem.started && view.ready
        sourceComponent: Video {
          source: view.url
          autoPlay: true
          fillMode: VideoOutput.PreserveAspectFit
        }
      }
      PlayBadge {
        visible: !videoItem.started || (videoLoader.item && videoLoader.item.playbackState !== MediaPlayer.PlayingState)
        playing: false
      }
      Rectangle {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Style.space(8)
        width: videoTime.implicitWidth + Style.space(12)
        height: videoTime.implicitHeight + Style.space(4)
        radius: Style.cornerRadius
        color: Qt.rgba(0, 0, 0, 0.5)
        Text {
          id: videoTime
          anchors.centerIn: parent
          text: view.downloading ? Math.round(view.fraction * 100) + "%" : Model.formatDuration(view.info.duration)
          color: "white"
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // ------------------------------------------------ video message (round)
  Component {
    id: videoNoteView
    Item {
      id: note
      property bool sound: false

      function toggle() {
        if (!view.ready) { view.download(32); return }
        if (!noteVideo.item) return
        if (!sound) {
          sound = true
          noteVideo.item.position = 0
          noteVideo.item.play()
        } else if (noteVideo.item.playbackState === MediaPlayer.PlayingState) {
          noteVideo.item.pause()
        } else {
          noteVideo.item.play()
        }
      }

      Item {
        id: noteSource
        anchors.fill: parent
        visible: false
        layer.enabled: true
        Placeholder { visible: !view.ready }
        Loader {
          id: noteVideo
          anchors.fill: parent
          active: view.ready
          sourceComponent: Video {
            source: view.url
            autoPlay: true
            muted: !note.sound
            loops: note.sound ? 1 : MediaPlayer.Infinite
            fillMode: VideoOutput.PreserveAspectCrop
            onStopped: note.sound = false
          }
        }
      }
      Rectangle {
        id: noteMask
        anchors.fill: parent
        radius: width / 2
        visible: false
        layer.enabled: true
      }
      MultiEffect {
        anchors.fill: parent
        source: noteSource
        maskEnabled: true
        maskSource: noteMask
      }
      Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: "transparent"
        border.width: view.downloading ? Style.space(3) : 0
        border.color: view.app.accent
        opacity: 0.8
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Style.space(10)
        text: Model.formatDuration(view.info.duration) + (note.sound ? "" : "  󰖁")
        color: "white"
        style: Text.Outline
        styleColor: Qt.rgba(0, 0, 0, 0.6)
        font.family: view.app.glyphFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // ------------------------------------------------ voice message
  Component {
    id: voiceView
    Item {
      id: voice
      readonly property bool playing: audio.playbackState === MediaPlayer.PlayingState
      readonly property real played: audio.duration > 0 ? audio.position / audio.duration : 0

      function toggle() {
        if (!view.ready) { view.download(32); return }
        if (playing) audio.pause()
        else audio.play()
      }

      MediaPlayer {
        id: audio
        source: view.ready ? view.url : ""
        audioOutput: AudioOutput {}
        onMediaStatusChanged: if (mediaStatus === MediaPlayer.EndOfMedia) position = 0
      }

      Rectangle {
        id: voiceButton
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(40)
        height: width
        radius: width / 2
        color: view.app.accent
        Text {
          anchors.centerIn: parent
          text: !view.ready ? "󰇚" : (voice.playing ? "󰏤" : "󰐊")
          color: view.app.background
          font.family: view.app.glyphFamily
          font.pixelSize: Style.font.title
        }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: voice.toggle() }
      }

      Row {
        id: bars
        anchors.left: voiceButton.right
        anchors.leftMargin: Style.space(10)
        anchors.right: voiceTime.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        height: Style.space(28)
        spacing: Style.space(2)
        readonly property var samples: view.info.waveform && view.info.waveform.length ? view.info.waveform : [4, 8, 12, 8, 4, 8, 12, 8]
        readonly property real barWidth: Math.max(1, (width - spacing * (samples.length - 1)) / samples.length)

        Repeater {
          model: bars.samples
          delegate: Rectangle {
            required property var modelData
            required property int index
            anchors.verticalCenter: parent.verticalCenter
            width: bars.barWidth
            height: Math.max(Style.space(3), bars.height * modelData / 31)
            radius: width / 2
            color: (index + 0.5) / bars.samples.length <= (voice.playing || voice.played > 0 ? voice.played : 0)
                   ? view.app.accent : view.app.muted
            opacity: view.ready ? 1 : 0.4 + 0.6 * view.fraction
          }
        }
      }

      Text {
        id: voiceTime
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: voice.playing || voice.played > 0 ? Model.formatDuration(audio.position / 1000) : Model.formatDuration(view.info.duration)
        color: view.app.muted
        font.family: view.app.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // ------------------------------------------------ file and audio
  Component {
    id: fileView
    Item {
      id: fileItem
      readonly property bool isAudio: view.kind === "audio"
      readonly property bool playing: isAudio && track.playbackState === MediaPlayer.PlayingState

      function toggle() {
        if (!view.ready) { view.download(32); return }
        if (!isAudio) return
        if (playing) track.pause()
        else track.play()
      }

      MediaPlayer {
        id: track
        source: fileItem.isAudio && view.ready ? view.url : ""
        audioOutput: AudioOutput {}
      }

      Rectangle {
        id: fileButton
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(40)
        height: width
        radius: width / 2
        color: Qt.rgba(view.app.accent.r, view.app.accent.g, view.app.accent.b, 0.25)
        Text {
          anchors.centerIn: parent
          // md-download U+F01DA, md-music-note U+F0387, md-file-outline U+F0224, md-play/pause
          text: !view.ready ? "󰇚" : (fileItem.isAudio ? (fileItem.playing ? "󰏤" : "󰎇") : "󰈤")
          color: view.app.accent
          font.family: view.app.glyphFamily
          font.pixelSize: Style.font.title
        }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: fileItem.toggle() }
      }

      Column {
        anchors.left: fileButton.right
        anchors.leftMargin: Style.space(10)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          width: parent.width
          elide: Text.ElideMiddle
          textFormat: Text.PlainText
          text: fileItem.isAudio && view.info.title ? (view.info.performer ? view.info.performer + " — " : "") + view.info.title
                                                     : (view.info.fileName || "File")
          color: view.app.foreground
          font.family: view.app.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Text {
          text: view.downloading ? Model.formatSize(view.file.downloaded) + " of " + Model.formatSize(view.file.size)
                : (view.ready ? Model.formatSize(view.file.size) + "  ·  downloaded" : Model.formatSize(view.file ? view.file.size : 0))
          color: view.app.muted
          font.family: view.app.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // ------------------------------------------------ spoiler cover
  Rectangle {
    anchors.fill: parent
    visible: view.covered && view.media !== null
    radius: Style.cornerRadius
    color: Qt.rgba(0.08, 0.08, 0.08, 1)
    clip: true

    Image {
      anchors.fill: parent
      source: Model.miniUrl(view.info.mini)
      fillMode: Image.PreserveAspectCrop
      opacity: 0.3
    }
    Text {
      anchors.centerIn: parent
      text: "Spoiler  ·  click to show"
      color: "white"
      font.family: view.app.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: view.revealRequested()
    }
  }
}
