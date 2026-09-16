import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "../app" as App

// Omagram in the bar: its mark, with a dot while unmuted chats have unread messages.
// Left click opens the quick panel (recent chats, reply without leaving what you are doing),
// right click opens a menu: the window, notifications on or off, or quit.
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

  // The right-click menu. PopupCard is what the bar's own widgets use for one, so it sits
  // where the tray's menu sits and closes when you click away.
  property bool menuOpen: false

  readonly property var menuEntries: [
    { action: "open", label: "Open Omagram" },
    { action: "quiet", label: root.omagram && root.omagram.quiet ? "Turn notifications on" : "Mute notifications" },
    { action: "quit", label: "Quit" }
  ]

  function runMenu(action) {
    root.menuOpen = false
    if (!root.omagram) return
    if (action === "open") root.omagram.openWindow()
    else if (action === "quiet") root.omagram.setQuiet(!root.omagram.quiet)
    else if (action === "quit") { root.close(); root.omagram.quit() }
  }

  PopupCard {
    id: menu
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.menuOpen && !!root.omagram
    padding: Style.space(8)
    contentWidth: menu.fittedContentWidth(Style.space(220))
    contentHeight: menu.fittedContentHeight(menuColumn.implicitHeight)
    onVisibleChanged: if (!visible) root.menuOpen = false

    Column {
      id: menuColumn
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: Style.space(2)

      Repeater {
        model: root.menuEntries

        delegate: Rectangle {
          id: entry
          required property var modelData
          width: parent.width
          height: Style.space(30)
          radius: Style.space(6)
          color: entryHover.hovered ? Style.hoverFillFor(Color.popups.text, Color.accent) : "transparent"

          HoverHandler { id: entryHover }

          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: entry.modelData.label
            elide: Text.ElideRight
            color: entry.modelData.action === "quit" ? Color.urgent : Color.popups.text
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.runMenu(entry.modelData.action)
          }
        }
      }
    }
  }

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
    // Omagram's own mark, the Ring (app/RingMark.qml), in the bar's text colour like every status glyph --
    // not Telegram's paper plane, which the API terms keep for Telegram itself.
    foreground: root.bar ? root.bar.barForeground : Color.foreground
    iconComponent: Component {
      Item {
        App.RingMark {
          anchors.centerIn: parent
          size: Style.space(16)   // measured: the same ink as the message glyph it replaced, 13 px across in a 27 px slot
          color: button.foreground
        }
      }
    }
    tooltipText: !root.ready ? "Omagram"
               : (root.unread > 0 ? "Omagram: " + root.unread + " unread" : "Omagram: no unread messages")
    onPressed: function (b) {
      if (b === Qt.RightButton) root.menuOpen = !root.menuOpen
      else {
        root.menuOpen = false
        // Reaching for Omagram after quitting brings the service back.
        if (root.omagram && root.omagram.stopped) root.omagram.stopped = false
        root.togglePanel()
      }
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
