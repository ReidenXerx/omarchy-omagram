import QtQuick
import QtQuick.Layouts
import qs.Commons
import "Model.js" as Model
import "Keymap.js" as Keymap

// Making a poll or a quiz: a question and 2 to 12 answers, anonymous or not, one answer or several; a quiz
// marks its right answer and may explain it. Enter goes on to the next field and, from the last answer with
// text, adds one; empty answers are left out when it is sent. Keys are the "Making a poll" section of the
// shortcuts; a click outside cancels.
FocusScope {
  id: dialog

  property var app
  property string where: ""          // the chat it goes to
  property bool channel: false       // a poll in a channel is anonymous
  property bool anonymous: true
  property bool multiple: false
  property bool quiz: false
  property int rightRow: 0           // a quiz's right answer, as a row of the answers
  property string error: ""
  readonly property int answersMax: 12

  signal sendRequested(var poll)
  signal dismissed()

  visible: false
  z: 60

  ListModel { id: answers }

  function open(where, channel) {
    dialog.where = where || ""
    dialog.channel = channel === true
    dialog.anonymous = true
    dialog.multiple = false
    dialog.quiz = false
    dialog.rightRow = 0
    dialog.error = ""
    question.clear()
    explanation.clear()
    answers.clear()
    answers.append({ answer: "" })
    answers.append({ answer: "" })
    dialog.visible = true
    question.forceActiveFocus()
  }

  function dismiss() {
    if (!dialog.visible) return
    dialog.visible = false
    dialog.dismissed()
  }

  function keyLabel(id) {
    return Keymap.label(Keymap.keysFor(dialog.app.shortcuts, id)[0] || "")
  }

  // The poll as typed: empty answers left out, and the right one counted among the rest.
  function poll() {
    var options = []
    var correct = -1
    for (var i = 0; i < answers.count; i++) {
      var text = String(answers.get(i).answer).trim()
      if (text === "") continue
      if (i === dialog.rightRow) correct = options.length
      options.push(text)
    }
    return { question: question.text.trim(), options: options, anonymous: dialog.anonymous || dialog.channel,
             multiple: dialog.multiple && !dialog.quiz, quiz: dialog.quiz, correct: correct,
             explanation: dialog.quiz ? explanation.text.trim() : "" }
  }

  function send() {
    var p = dialog.poll()
    var problem = Model.pollProblem(p)
    if (problem !== "") { dialog.error = problem; return }
    dialog.visible = false
    dialog.sendRequested(p)
  }

  function focusAnswer(row) {
    var item = answerRepeater.itemAt(row)
    if (item) item.takeFocus()
  }

  // Enter in an answer: the next one; after the last, a new one if it has text (up to 12), or on.
  function nextFrom(row) {
    if (row + 1 < answers.count) { dialog.focusAnswer(row + 1); return }
    if (String(answers.get(row).answer).trim() !== "" && answers.count < dialog.answersMax) {
      answers.append({ answer: "" })
      Qt.callLater(function () { dialog.focusAnswer(row + 1) })
      return
    }
    if (dialog.quiz) explanation.forceActiveFocus()
    else sendButton.forceActiveFocus()
  }

  function removeRow(row) {
    if (answers.count <= 2 || row < 0 || row >= answers.count) return
    Qt.callLater(function () {
      answers.remove(row)
      if (dialog.rightRow === row) dialog.rightRow = 0
      else if (dialog.rightRow > row) dialog.rightRow--
    })
  }

  function focusedAnswerRow() {
    for (var i = 0; i < answers.count; i++) {
      var item = answerRepeater.itemAt(i)
      if (item && item.hasKeys) return i
    }
    return -1
  }

  // Tab and Shift+Tab: the question, the answers, a quiz's explanation, the choices, Send.
  function focusStep(delta) {
    var order = [question]
    for (var i = 0; i < answers.count; i++) order.push(answerRepeater.itemAt(i))
    if (dialog.quiz) order.push(explanation)
    if (!dialog.channel) order.push(anonymousButton)
    if (!dialog.quiz) order.push(multipleButton)
    order.push(quizButton, sendButton)
    var at = -1
    for (var j = 0; j < order.length; j++) {
      if (order[j] && (order[j].activeFocus || order[j].hasKeys === true)) at = j
    }
    var next = order[(at + delta + order.length) % order.length]
    if (!next) return
    if (typeof next.takeFocus === "function") next.takeFocus()
    else next.forceActiveFocus()
  }

  Keys.onPressed: function (event) {
    var keys = dialog.app.shortcuts
    function is(id) { return Keymap.matchesInText(keys, id, event) }
    if (is("poll.send")) dialog.send()
    else if (is("poll.close")) dialog.dismiss()
    else if (is("poll.next")) dialog.focusStep(1)
    else if (is("poll.previous")) dialog.focusStep(-1)
    else if (is("poll.right") && dialog.quiz && dialog.focusedAnswerRow() >= 0) dialog.rightRow = dialog.focusedAnswerRow()
    event.accepted = true   // the rest of the window waits while a poll is being made
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.55)
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: dialog.dismiss()
  }

  Rectangle {
    width: Math.min(parent.width - Style.space(40), Style.space(520))
    height: Math.min(parent.height - Style.space(40), content.implicitHeight + Style.space(32))
    anchors.centerIn: parent
    radius: Style.cornerRadius
    color: dialog.app.background
    border.width: 1
    border.color: Qt.rgba(dialog.app.foreground.r, dialog.app.foreground.g, dialog.app.foreground.b, 0.18)

    MouseArea { anchors.fill: parent; acceptedButtons: Qt.LeftButton | Qt.RightButton }

    Flickable {
      id: scroller
      anchors.fill: parent
      anchors.margins: Style.space(16)
      contentWidth: width
      contentHeight: content.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      ColumnLayout {
        id: content
        width: scroller.width
        spacing: Style.space(10)

        Text {
          Layout.fillWidth: true
          elide: Text.ElideRight
          text: (dialog.quiz ? "A quiz" : "A poll") + (dialog.where ? " for " + dialog.where : "")
          textFormat: Text.PlainText
          color: dialog.app.foreground
          font.family: dialog.app.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Text {
          Layout.fillWidth: true
          wrapMode: Text.Wrap
          text: "Enter goes on, and adds an answer after the last   ·   " + dialog.keyLabel("poll.send") + " sends   ·   "
                + dialog.keyLabel("poll.close") + " cancels"
          color: dialog.app.muted
          font.family: dialog.app.fontFamily
          font.pixelSize: Style.font.caption
        }

        Field {
          id: question
          Layout.fillWidth: true
          app: dialog.app
          label: "Question"
          maximumLength: 255
          onAccepted: dialog.focusAnswer(0)
        }

        Text {
          Layout.fillWidth: true
          wrapMode: Text.Wrap
          text: dialog.quiz ? "Answers: mark the right one with its circle, or " + dialog.keyLabel("poll.right") + " in it" : "Answers"
          color: dialog.app.muted
          font.family: dialog.app.fontFamily
          font.pixelSize: Style.font.caption
        }

        Repeater {
          id: answerRepeater
          model: answers

          delegate: RowLayout {
            id: answerRow
            required property int index
            required property string answer
            readonly property bool hasKeys: answerField.activeFocus
            Layout.fillWidth: true
            spacing: Style.space(8)

            function takeFocus() { answerField.forceActiveFocus() }

            Text {
              visible: dialog.quiz
              text: answerRow.index === dialog.rightRow ? "●" : "○"
              color: answerRow.index === dialog.rightRow ? dialog.app.accent : dialog.app.muted
              font.family: dialog.app.fontFamily
              font.pixelSize: Style.font.title
              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(6)
                cursorShape: Qt.PointingHandCursor
                onClicked: dialog.rightRow = answerRow.index
              }
            }

            Field {
              id: answerField
              Layout.fillWidth: true
              app: dialog.app
              placeholder: "Answer " + (answerRow.index + 1)
              maximumLength: 100
              Component.onCompleted: answerField.text = answerRow.answer
              onTextChanged: {
                if (answerRow.index < answers.count && answers.get(answerRow.index).answer !== answerField.text)
                  answers.setProperty(answerRow.index, "answer", answerField.text)
              }
              onAccepted: dialog.nextFrom(answerRow.index)
            }

            Text {
              visible: answers.count > 2
              text: "×"
              color: removeArea.containsMouse ? dialog.app.urgent : dialog.app.muted
              font.family: dialog.app.fontFamily
              font.pixelSize: Style.font.title
              MouseArea {
                id: removeArea
                anchors.fill: parent
                anchors.margins: -Style.space(6)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: dialog.removeRow(answerRow.index)
              }
            }
          }
        }

        Field {
          id: explanation
          Layout.fillWidth: true
          visible: dialog.quiz
          app: dialog.app
          label: "What a wrong answer is told (you can leave this out)"
          maximumLength: 200
          onAccepted: sendButton.forceActiveFocus()
        }

        Flow {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Button {
            id: anonymousButton
            visible: !dialog.channel
            app: dialog.app
            text: (dialog.anonymous ? "✓  " : "") + "Anonymous"
            onClicked: dialog.anonymous = !dialog.anonymous
          }
          Button {
            id: multipleButton
            visible: !dialog.quiz
            app: dialog.app
            text: (dialog.multiple ? "✓  " : "") + "Several answers"
            onClicked: dialog.multiple = !dialog.multiple
          }
          Button {
            id: quizButton
            app: dialog.app
            text: (dialog.quiz ? "✓  " : "") + "Quiz"
            onClicked: dialog.quiz = !dialog.quiz
          }
        }

        Text {
          Layout.fillWidth: true
          visible: dialog.error !== ""
          wrapMode: Text.Wrap
          text: dialog.error
          textFormat: Text.PlainText
          color: dialog.app.urgent
          font.family: dialog.app.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Item { Layout.fillWidth: true }
          Button {
            app: dialog.app
            text: "Cancel"
            onClicked: dialog.dismiss()
          }
          Button {
            id: sendButton
            app: dialog.app
            primary: true
            text: dialog.quiz ? "Send the quiz" : "Send the poll"
            onClicked: dialog.send()
          }
        }
      }
    }
  }
}
