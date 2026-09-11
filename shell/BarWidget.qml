import QtQuick
import qs.Commons
import qs.Ui

// Omagram in the bar: a message glyph with a dot while unmuted chats have unread messages.
// Left click opens the quick panel (recent chats, reply without leaving what you are doing),
// right click opens the window.
BarWidget {
  id: root
  moduleName: "reidenxerx.omagram"

  readonly property string pluginId: "reidenxerx.omagram"

  // The plugin's service entry, found through the bar's shell facade. The shell may create
  // services after bar widgets, so the lookup is retried until it succeeds.
  property var omagram: null

  function findService() {
    if (root.omagram) return
    var shell = root.bar ? root.bar.shell : null
    root.omagram = shell && typeof shell.serviceFor === "function" ? shell.serviceFor(root.pluginId) : null
    injectPanel()
  }

  Timer {
    interval: 1000
    repeat: true
    running: !root.omagram
    triggeredOnStart: true
    onTriggered: root.findService()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("omagram" in target) target.omagram = root.omagram
  }

  function togglePanel() { if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle() }
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item && panelLoader.item.open) panelLoader.item.open() }
  function close() { if (panelLoader.item && panelLoader.item.close) panelLoader.item.close() }
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  readonly property int unread: root.omagram ? root.omagram.unread : 0
  readonly property bool ready: root.omagram ? root.omagram.ready : false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onBarChanged: { findService(); injectPanel() }
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // md-message_text_outline (U+F036A), checked against the font's cmap: a neutral message
    // glyph, not Telegram's paper plane, which the API terms keep for Telegram itself.
    text: "󰍪"
    foreground: root.bar ? root.bar.barForeground : Color.foreground
    tooltipText: !root.ready ? "Omagram"
               : (root.unread > 0 ? "Omagram: " + root.unread + " unread" : "Omagram: no unread messages")
    onPressed: function (b) {
      if (b === Qt.RightButton && root.omagram) root.omagram.openWindow()
      else root.togglePanel()
    }

    // A dot, like the bell's unread mark, drawn over the button so the glyph stays centred.
    Rectangle {
      visible: root.ready && root.unread > 0
      width: Style.space(6)
      height: width
      radius: width / 2
      color: Color.accent
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: Style.space(3)
      anchors.topMargin: Style.space(5)
    }
  }
}
