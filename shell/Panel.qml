import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// The bar's panel: the quick view (QuickView.qml), compact, under Omagram's bar icon. The chats first; choosing
// one puts the chat in their place, and Esc or the arrow goes back to them.
Panel {
  id: root
  moduleName: "reidenxerx.omagram"
  // Summon from a key binding: omarchy-shell reidenxerx.omagram.panel toggle
  // (its own target, apart from the overlay, which the shell toggles by plugin id).
  ipcTarget: "reidenxerx.omagram.panel"
  manageIpc: true

  property var anchorItem: null
  property var hostWidget: null
  property var omagram: null
  readonly property var barIdentity: hostWidget || root
  readonly property int viewHeight: Style.space(560)

  onOpenedChanged: {
    if (opened) view.reset(0)
    else view.leave()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: view.focusItem
    popoutSwitching: root.popoutSwitching
    popoutSwitchClosing: root.popoutSwitchClosing
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(root.viewHeight)

    QuickView {
      id: view
      width: parent.width
      height: Math.max(Style.space(240), panel.contentHeight - panel.verticalContentInset)
      compact: true
      service: root.omagram
      opened: root.opened
      background: Color.popups.background
      foreground: root.barForeground
      selected: Style.hoverFillFor(root.barForeground, Color.accent)
      onDismissRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onOpenInWindowRequested: function (chatId) {
        if (!root.omagram) return
        if (chatId) root.omagram.openChat(chatId)
        else root.omagram.openWindow()
        root.close()
      }
    }
  }
}
