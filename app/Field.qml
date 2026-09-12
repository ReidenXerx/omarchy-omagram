import QtQuick
import qs.Commons

// A labelled text field in Omarchy's menu style. Enter emits accepted(); the focused field
// shows an accent outline so keyboard focus is always visible.
FocusScope {
  id: field

  property var app
  property string label: ""
  property string placeholder: ""
  property string error: ""
  property bool secret: false
  property alias text: input.text
  property alias inputMethodHints: input.inputMethodHints
  property int maximumLength: 256

  signal accepted()

  implicitWidth: 360
  implicitHeight: column.implicitHeight

  function clear() { input.text = "" }

  Column {
    id: column
    width: parent.width
    spacing: Style.space(6)

    Text {
      visible: field.label !== ""
      text: field.label
      textFormat: Text.PlainText
      color: field.app.muted
      font.family: field.app.fontFamily
      font.pixelSize: Style.font.caption
    }

    Rectangle {
      width: parent.width
      height: Math.max(Style.space(38), input.implicitHeight + Style.space(16))
      radius: Style.cornerRadius
      color: Qt.rgba(field.app.foreground.r, field.app.foreground.g, field.app.foreground.b, 0.05)
      border.width: Math.max(1, Style.space(1.5))
      border.color: input.activeFocus ? field.app.accent
                  : (field.error ? field.app.urgent : Qt.rgba(field.app.foreground.r, field.app.foreground.g, field.app.foreground.b, 0.15))

      TextInput {
        id: input
        anchors.fill: parent
        anchors.leftMargin: Style.space(12)
        anchors.rightMargin: Style.space(12)
        verticalAlignment: TextInput.AlignVCenter
        focus: true
        clip: true
        color: field.app.foreground
        selectionColor: field.app.accent
        font.family: field.app.fontFamily
        font.pixelSize: Style.font.body
        echoMode: field.secret ? TextInput.Password : TextInput.Normal
        maximumLength: field.maximumLength
        onAccepted: field.accepted()

        Text {
          anchors.verticalCenter: parent.verticalCenter
          visible: input.text === ""
          text: field.placeholder
          textFormat: Text.PlainText
          color: field.app.muted
          opacity: 0.7
          font: input.font
        }
      }
    }

    Text {
      visible: field.error !== ""
      width: parent.width
      wrapMode: Text.WordWrap
      text: field.error
      textFormat: Text.PlainText
      color: field.app.urgent
      font.family: field.app.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
