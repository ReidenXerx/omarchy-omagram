import QtQuick
import qs.Commons
import "Model.js" as Model

// Sign-in: your phone number, or a QR code scanned with Telegram on your phone; then the code
// Telegram sends and the cloud password if the account has one. Each step is one field and
// Enter; errors from Telegram are shown under it. What you type goes straight to the service and
// is cleared from the field once sent.
FocusScope {
  id: view

  property var app
  property var client
  readonly property string step: app.auth.state
  property bool busy: false
  property string error: ""
  property bool phoneInstead: false      // on the QR step: typing a phone number after all

  readonly property bool askingPhone: view.step === "phone" || (view.step === "qr" && view.phoneInstead)
  readonly property bool showingQr: view.step === "qr" && !view.phoneInstead

  onStepChanged: {
    view.error = ""
    view.busy = false
    view.phoneInstead = false
    Qt.callLater(function () { field.clear(); field.forceActiveFocus() })
  }

  function send(cmd, args) {
    view.busy = true
    view.error = ""
    client.request(cmd, args, function (answer) {
      view.busy = false
      if (!answer.ok) {
        view.error = friendly(answer.error)
        field.forceActiveFocus()
      }
    })
  }

  function friendly(error) {
    var e = String(error || "")
    if (e.indexOf("PHONE_NUMBER_INVALID") >= 0) return "Telegram does not recognise that phone number. Include the country code."
    if (e.indexOf("PHONE_CODE_INVALID") >= 0) return "That code is not right. Check the latest code Telegram sent."
    if (e.indexOf("PHONE_CODE_EXPIRED") >= 0) return "That code has expired. Start again with your phone number."
    if (e.indexOf("PASSWORD_HASH_INVALID") >= 0) return "That password is not right."
    if (e.indexOf("FLOOD_WAIT") >= 0) return "Telegram asks you to wait before trying again."
    if (e.indexOf("API_ID_INVALID") >= 0) return "Telegram rejected the API id and hash. Check them at my.telegram.org."
    return e || "Something went wrong."
  }

  function submit() {
    var value = field.text
    if (view.askingPhone) {
      var phone = Model.cleanPhone(value)
      if (!phone) { view.error = "Enter your phone number with its country code, like +380 67 123 4567."; return }
      send("auth.phone", { phone: phone })
    } else if (step === "code") {
      if (!Model.validCode(value)) { view.error = "The code is digits only."; return }
      send("auth.code", { code: value.trim() })
    } else if (step === "password") {
      if (!value) { view.error = "Enter your cloud password."; return }
      send("auth.password", { password: value })
      field.clear()
    }
  }

  function switchMethod() {
    if (view.step === "phone") {
      view.send("auth.qr", {})
    } else {
      view.phoneInstead = !view.phoneInstead
      view.error = ""
      Qt.callLater(function () { field.forceActiveFocus() })
    }
  }

  Column {
    width: Math.min(parent.width - Style.space(64), Style.space(460))
    anchors.centerIn: parent
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
      color: app.foreground
      opacity: 0.85
      textFormat: Text.PlainText
      font.family: app.fontFamily
      font.pixelSize: Style.font.body
      text: {
        if (view.askingPhone) return "Sign in with the phone number of your Telegram account."
        if (view.step === "code") {
          var via = app.auth.via === "TelegramMessage" ? "in your Telegram app" : (app.auth.via === "Sms" ? "by SMS" : "")
          return "Telegram sent a code " + (via ? via + " " : "") + "to " + (app.auth.phone || "your phone") + "."
        }
        if (view.step === "password") return "This account has a cloud password." + (app.auth.hint ? " Hint: " + app.auth.hint : "")
        return "Open Telegram on your phone, go to Settings → Devices → Link Desktop Device, and scan this code."
      }
    }

    // The code refreshes by itself: Telegram hands out a new link every half minute or so.
    Rectangle {
      visible: view.showingQr
      width: Style.space(260)
      height: width
      radius: Style.cornerRadius
      color: "white"

      Image {
        anchors.fill: parent
        anchors.margins: Style.space(10)
        visible: !!app.auth.image
        source: app.auth.image || ""
        fillMode: Image.PreserveAspectFit
        smooth: false
      }
      Text {
        anchors.centerIn: parent
        width: parent.width - Style.space(32)
        visible: !app.auth.image
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: "Showing the code needs qrencode (sudo pacman -S qrencode). Or use your phone number."
        color: "black"
        font.family: app.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    Field {
      id: field
      app: view.app
      width: parent.width
      visible: !view.showingQr
      label: view.askingPhone ? "Phone number" : (view.step === "code" ? "Code" : "Cloud password")
      placeholder: view.askingPhone ? "+380 67 123 4567" : ""
      secret: view.step === "password"
      maximumLength: view.step === "password" ? 512 : 32
      inputMethodHints: view.step === "password" ? Qt.ImhSensitiveData | Qt.ImhNoPredictiveText : Qt.ImhDialableCharactersOnly
      error: view.error
      focus: true
      KeyNavigation.tab: submitButton.visible ? submitButton : methodButton
      onAccepted: view.submit()
    }

    Text {
      visible: view.showingQr && view.error !== ""
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: view.error
      color: app.urgent
      font.family: app.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Row {
      spacing: Style.space(10)

      Button {
        id: submitButton
        app: view.app
        visible: !view.showingQr
        text: view.step === "password" ? "Sign in" : "Continue"
        primary: true
        busy: view.busy
        KeyNavigation.tab: methodButton.visible ? methodButton : field
        onClicked: view.submit()
      }

      Button {
        id: methodButton
        app: view.app
        visible: view.step === "phone" || view.step === "qr"
        text: view.step === "phone" ? "Use a QR code instead" : (view.phoneInstead ? "Show the QR code" : "Use my phone number")
        busy: view.busy && view.step === "phone"
        KeyNavigation.tab: field
        onClicked: view.switchMethod()
      }
    }
  }
}
