import QtQuick
import qs.Commons

// A button that works from the keyboard as well as the mouse: Tab reaches it, Enter or
// Space presses it, and focus is shown with the accent outline.
Rectangle {
  id: button

  property var app
  property string text: ""
  property bool primary: false
  property bool busy: false

  signal clicked()

  activeFocusOnTab: true
  implicitWidth: Math.max(Style.space(120), label.implicitWidth + Style.space(32))
  implicitHeight: Style.space(38)
  radius: Style.cornerRadius
  opacity: enabled ? 1 : 0.5
  color: primary ? app.accent
       : (mouse.containsMouse ? Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, 0.1) : "transparent")
  border.width: Math.max(1, Style.space(1.5))
  border.color: activeFocus ? app.foreground
              : (primary ? app.accent : Qt.rgba(app.foreground.r, app.foreground.g, app.foreground.b, 0.2))

  Keys.onReturnPressed: if (enabled && !busy) clicked()
  Keys.onEnterPressed: if (enabled && !busy) clicked()
  Keys.onSpacePressed: if (enabled && !busy) clicked()

  Text {
    id: label
    anchors.centerIn: parent
    text: button.busy ? "…" : button.text
    color: button.primary ? app.onAccent : app.foreground
    font.family: app.fontFamily
    font.pixelSize: Style.font.body
    font.bold: button.primary
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: if (button.enabled && !button.busy) button.clicked()
  }
}
