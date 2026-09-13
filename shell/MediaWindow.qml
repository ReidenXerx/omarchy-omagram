import QtQuick
import Quickshell
import Quickshell.Wayland

// The quick view's photo or video over the whole screen (MediaViewer.qml), in a window of its own: above
// everything, with the keyboard. The quick view loads this file only while something is open.
PanelWindow {
  id: window

  property var host: null   // the quick view

  visible: true
  screen: window.host && window.host.QsWindow.window ? window.host.QsWindow.window.screen : null
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "omagram-quick-media"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

  MediaViewer {
    anchors.fill: parent
    host: window.host
    items: window.host ? window.host.mediaItems : []
    messageId: window.host ? window.host.viewingId : 0
    Component.onCompleted: forceActiveFocus()
    onClosed: window.host.closeMedia()
    onPlayed: {
      window.host.closeMedia()
      window.host.dismissRequested()
    }
    onOpenInWindowRequested: function (chatId) {
      window.host.closeMedia()
      window.host.openInWindowRequested(chatId)
    }
  }
}
