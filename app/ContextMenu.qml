import QtQuick
import qs.Commons
import "Keymap.js" as Keymap

// A menu at the pointer: a row of quick reactions when there are any, then its items. Whoever
// opens it says what is in it (`items`: [{ id, label, danger }]) and what choosing does.
//
// Keys are the "Menus" section of the shortcuts, and 1-8 choose a quick reaction. A click outside
// or the close key dismisses it; the keyboard moving elsewhere closes it without a word.
FocusScope {
  id: menu

  property var app
  property var items: []
  property var reactions: []
  property var chosen: []        // reactions that are already yours
  property real menuX: 0
  property real menuY: 0
  property int cursor: 0

  signal picked(string id)
  signal reacted(string emoji)
  signal dismissed()

  visible: false
  z: 50

  function open(x, y) {
    menu.menuX = x
    menu.menuY = y
    menu.cursor = 0
    menu.visible = true
    menu.forceActiveFocus()
  }

  function close() {
    menu.visible = false
  }

  function dismiss() {
    if (!menu.visible) return
    menu.close()
    menu.dismissed()
  }

  function pick(index) {
    var item = menu.items[index]
    if (!menu.visible || !item) return
    menu.close()
    menu.picked(item.id)
  }

  function react(emoji) {
    if (!menu.visible || !emoji) return
    menu.close()
    menu.reacted(emoji)
  }

  onItemsChanged: menu.cursor = Math.max(0, Math.min(menu.cursor, menu.items.length - 1))
  onActiveFocusChanged: if (!activeFocus) menu.close()

  Keys.onPressed: function (event) {
    var keys = menu.app.shortcuts
    function is(id) { return Keymap.matches(keys, id, event) }
    var digit = event.key - Qt.Key_1
    if (is("menu.close")) menu.dismiss()
    else if (is("menu.down")) menu.cursor = Math.min(menu.items.length - 1, menu.cursor + 1)
    else if (is("menu.up")) menu.cursor = Math.max(0, menu.cursor - 1)
    else if (is("menu.pick")) menu.pick(menu.cursor)
    else if (digit >= 0 && digit < 8 && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)))
      menu.react(menu.reactions[digit])
    else return
    event.accepted = true
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onPressed: menu.dismiss()
  }

  Rectangle {
    id: card
    width: Math.min(Style.space(260), menu.width - Style.space(16))
    height: cardColumn.implicitHeight + Style.space(12)
    x: Math.max(Style.space(8), Math.min(menu.width - width - Style.space(8), menu.menuX))
    y: Math.max(Style.space(8), Math.min(menu.height - height - Style.space(8), menu.menuY))
    radius: Style.cornerRadius
    color: menu.app.background
    border.width: 1
    border.color: Qt.rgba(menu.app.foreground.r, menu.app.foreground.g, menu.app.foreground.b, 0.18)

    // A click on the card is not a click outside.
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.LeftButton | Qt.RightButton }

    Column {
      id: cardColumn
      x: Style.space(6)
      y: Style.space(6)
      width: parent.width - Style.space(12)
      spacing: Style.space(2)

      Row {
        visible: menu.reactions.length > 0
        spacing: Style.space(2)

        Repeater {
          model: menu.reactions.slice(0, 8)
          delegate: Rectangle {
            id: reaction
            required property var modelData
            readonly property bool mine: menu.chosen.indexOf(modelData) >= 0
            width: Style.space(28)
            height: width
            radius: width / 2
            color: reactionArea.containsMouse || reaction.mine
                   ? Qt.rgba(menu.app.accent.r, menu.app.accent.g, menu.app.accent.b, reaction.mine ? 0.3 : 0.2) : "transparent"
            Text {
              anchors.centerIn: parent
              text: reaction.modelData
              textFormat: Text.PlainText
              font.pixelSize: Style.font.body
            }
            MouseArea {
              id: reactionArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: menu.react(reaction.modelData)
            }
          }
        }
      }

      Rectangle {
        visible: menu.reactions.length > 0
        width: parent.width
        height: 1
        color: Qt.rgba(menu.app.foreground.r, menu.app.foreground.g, menu.app.foreground.b, 0.1)
      }

      Repeater {
        model: menu.items
        delegate: Rectangle {
          id: entry
          required property var modelData
          required property int index
          width: cardColumn.width
          height: Style.space(32)
          radius: Style.cornerRadius
          color: entry.index === menu.cursor ? menu.app.selected : "transparent"

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(10)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            text: entry.modelData.label
            textFormat: Text.PlainText
            color: entry.modelData.danger ? menu.app.urgent : menu.app.foreground
            font.family: menu.app.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: menu.cursor = entry.index
            onClicked: menu.pick(entry.index)
          }
        }
      }
    }
  }
}
