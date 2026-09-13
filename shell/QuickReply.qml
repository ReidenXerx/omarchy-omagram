import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Quick switch and reply, summoned with a key: the quick view (QuickView.qml) in the middle of the screen, the
// chats beside the chat.
//
//   omarchy-shell shell toggle reidenxerx.omagram '{}'              find a chat
//   omarchy-shell shell toggle reidenxerx.omagram '{"chatId":<id>}'  answer that chat
//   omarchy-shell shell toggle reidenxerx.omagram '{"chatId":<id>,"messageId":<id>}'  and show that message's
//                                                                       photo or video over the whole screen
Item {
  id: overlay

  property var shell: null
  property var manifest: null
  property var service: null
  property bool opened: false

  readonly property string pluginId: (manifest && manifest.id) || "reidenxerx.omagram"
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))

  // The shell hands `service` over when this overlay loads, which can be before the plugin's service entry
  // exists; look it up again until it is there.
  function findService() {
    if (!overlay.service && overlay.shell && typeof overlay.shell.serviceFor === "function")
      overlay.service = overlay.shell.serviceFor(overlay.pluginId)
  }

  Timer {
    interval: 1000
    repeat: true
    running: !overlay.service
    triggeredOnStart: true
    onTriggered: overlay.findService()
  }

  // ---------------------------------------------------------------- shell contract

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) { payload = {} }
    overlay.findService()
    overlay.opened = true
    view.reset(payload.chatId, payload.messageId)
  }

  function close() {
    if (!overlay.opened) return   // the shell can ask a closed overlay to close: nothing to put away then
    overlay.opened = false
    view.leave()
  }

  function dismiss() {
    overlay.close()
    if (overlay.shell && typeof overlay.shell.hide === "function") overlay.shell.hide(overlay.pluginId)
  }

  function toggle() {
    if (overlay.opened) overlay.dismiss()
    else overlay.open("{}")
  }

  // ---------------------------------------------------------------- ui

  PanelWindow {
    id: surface
    visible: overlay.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omagram-quick-reply"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: overlay.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.35)
    }

    MouseArea {
      anchors.fill: parent
      onClicked: overlay.dismiss()
    }

    BorderSurface {
      id: card
      width: Math.min(Style.space(940), surface.width - Style.space(64))
      height: Math.min(Style.space(620), surface.height - Style.space(96))
      anchors.centerIn: parent
      radius: Style.cornerRadius
      color: Color.menu.background
      borderSpec: overlay.borderSpec
      padding: Style.spacing.panelPadding

      // Clicks on the card stay on the card.
      MouseArea { anchors.fill: parent }

      QuickView {
        id: view
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        service: overlay.service
        opened: overlay.opened
        onDismissRequested: overlay.dismiss()
        onOpenInWindowRequested: function (chatId) {
          if (!overlay.service) return
          if (chatId) overlay.service.openChat(chatId)
          else overlay.service.openWindow()
          overlay.dismiss()
        }
      }
    }
  }
}
