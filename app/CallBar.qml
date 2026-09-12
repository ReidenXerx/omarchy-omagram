import QtQuick
import QtQuick.Layouts
import qs.Commons

// An incoming call. Omagram cannot take calls -- TDLib carries a call's signalling but brings no
// voice engine -- so the bar says who is calling, to decline here or answer in another Telegram app.
Rectangle {
  id: bar

  property var app
  property var call: null   // as the service's "call" event describes it

  signal declined(int callId)

  implicitHeight: Style.space(48)
  visible: !!bar.call
  color: bar.app.background

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(bar.app.accent.r, bar.app.accent.g, bar.app.accent.b, 0.16)
  }

  RowLayout {
    anchors.fill: parent
    anchors.leftMargin: Style.space(16)
    anchors.rightMargin: Style.space(10)
    spacing: Style.space(10)

    // md-phone-incoming U+F03F7
    Text {
      text: String.fromCodePoint(0xF03F7)
      color: bar.app.accent
      font.family: bar.app.glyphFamily
      font.pixelSize: Style.font.title
    }
    Text {
      Layout.fillWidth: true
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: !bar.call ? ""
          : (bar.call.name || "Someone") + (bar.call.video ? " is video calling you" : " is calling you")
            + ". Omagram cannot take calls: answer in another Telegram app."
      color: bar.app.foreground
      font.family: bar.app.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Button {
      app: bar.app
      text: "Decline"
      onClicked: if (bar.call) bar.declined(bar.call.id)
    }
  }
}
