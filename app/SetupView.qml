import QtQuick
import qs.Commons
import "Model.js" as Model

// First run: says plainly that Omagram is unofficial (Telegram's API terms require it in the
// intro), and asks for the API id and hash you create yourself. They go to the service,
// which puts them in the keyring; this view never stores them.
FocusScope {
  id: view

  property var app
  property var client
  property bool busy: false
  property string error: ""

  function submit() {
    var id = apiId.text.trim()
    var hash = apiHash.text.trim()
    apiId.error = Model.validApiId(id) ? "" : "The API id is a number."
    apiHash.error = Model.validApiHash(hash) ? "" : "The API hash is 32 characters, 0-9 and a-f."
    if (apiId.error || apiHash.error) return
    view.busy = true
    view.error = ""
    client.request("credentials.set", { apiId: parseInt(id, 10), apiHash: hash }, function (answer) {
      view.busy = false
      if (!answer.ok) view.error = answer.error || "The credentials were not accepted."
      apiHash.clear()
    })
  }

  Flickable {
    anchors.fill: parent
    contentHeight: column.implicitHeight + Style.space(80)
    clip: true

    Column {
      id: column
      width: Math.min(parent.width - Style.space(64), Style.space(520))
      anchors.horizontalCenter: parent.horizontalCenter
      y: Math.max(Style.space(40), (view.height - implicitHeight) / 2)
      spacing: Style.spacing.md

      Text {
        text: "Omagram"
        color: app.foreground
        font.family: app.fontFamily
        font.pixelSize: Style.font.displayLarge
        font.bold: true
      }

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        text: "An unofficial Telegram client for Omarchy. It is not made or endorsed by Telegram."
        color: app.foreground
        font.family: app.fontFamily
        font.pixelSize: Style.font.title
      }

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        textFormat: Text.StyledText
        linkColor: app.accentText
        text: "To connect, Telegram needs an API id and hash that belong to you. Sign in at "
          + "<a href=\"https://my.telegram.org/apps\">my.telegram.org</a>, open "
          + "<b>API development tools</b>, create an app, and copy its two values here. "
          + "They are kept in your keyring, never in a file."
        color: app.foreground
        opacity: 0.85
        font.family: app.fontFamily
        font.pixelSize: Style.font.body
        onLinkActivated: function (link) { Qt.openUrlExternally(link) }
      }

      Item { width: 1; height: Style.space(8) }

      Field {
        id: apiId
        app: view.app
        width: parent.width
        label: "API id"
        placeholder: "1234567"
        maximumLength: 10
        inputMethodHints: Qt.ImhDigitsOnly
        focus: true
        KeyNavigation.tab: apiHash
        onAccepted: apiHash.forceActiveFocus()
      }

      Field {
        id: apiHash
        app: view.app
        width: parent.width
        label: "API hash"
        placeholder: "32 characters"
        secret: true
        maximumLength: 32
        KeyNavigation.tab: continueButton
        onAccepted: view.submit()
      }

      Text {
        visible: view.error !== ""
        width: parent.width
        wrapMode: Text.WordWrap
        text: view.error
        textFormat: Text.PlainText
        color: app.urgent
        font.family: app.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Button {
        id: continueButton
        app: view.app
        text: "Continue"
        primary: true
        busy: view.busy
        KeyNavigation.tab: apiId
        onClicked: view.submit()
      }
    }
  }

  Component.onCompleted: apiId.forceActiveFocus()
}
