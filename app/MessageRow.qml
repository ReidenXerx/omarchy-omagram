import QtQuick
import QtQuick.Layouts
import qs.Commons
import "Model.js" as Model

// One message in the open chat: a service line ("Ann added Bob"), or a bubble with its sender,
// forward and reply headers, media or an album, text with formatting and links, a link preview,
// a poll, place or contact card, reactions, bot buttons, and its time with read ticks.
//
// Everything from Telegram is shown as plain text or as escaped Rich Text from Model.richText;
// what a click does is decided by the chat view (`view`), never by the message.
Item {
  id: row

  required property var modelData
  required property int index
  property var view
  property var app
  property var messages: []

  readonly property var message: row.modelData
  readonly property var content: row.message && row.message.content ? row.message.content : ({})
  readonly property var previous: row.index > 0 ? row.messages[row.index - 1] : null
  readonly property bool service: row.content.kind === "service"
  readonly property bool hiddenInAlbum: Model.inAlbumAfterFirst(row.messages, row.index)
  readonly property var album: Model.albumStart(row.messages, row.index)
  readonly property bool newDay: !row.previous || !Model.sameDay(row.previous.date, row.message.date)
  readonly property bool runStart: row.newDay || !Model.sameRun(row.previous, row.message)
  readonly property bool showName: !row.message.outgoing && !!row.view.chat && row.view.chat.kind !== "private" && row.runStart && !row.service
  readonly property var quoted: row.message.replyTo ? Model.findMessage(row.messages, row.message.replyTo.messageId) : null
  readonly property bool isCursor: row.index === row.view.cursor && row.view.messagesFocused
  readonly property string label: Model.contentLabel(row.content)
  readonly property bool bare: !!row.content.media && (row.content.kind === "sticker" || row.content.kind === "videoNote") && row.album.length < 2
  readonly property bool revealed: !!row.view.revealed[row.message.id]
  readonly property string receipt: Model.receipt(row.message, row.view.chat)
  readonly property bool cardKind: row.content.kind === "poll" || row.content.kind === "location" || row.content.kind === "contact"
  // An album's caption is usually on one of its messages, not always the first.
  readonly property var textSource: {
    if (row.album.length > 1) {
      for (var i = 0; i < row.album.length; i++) if (row.album[i].content.text) return row.album[i]
    }
    return row.message
  }
  readonly property string codeBackground: "#" + [0x18, Math.round(row.app.foreground.r * 255), Math.round(row.app.foreground.g * 255),
                                                  Math.round(row.app.foreground.b * 255)]
    .map(function (v) { return (v < 16 ? "0" : "") + v.toString(16) }).join("")
  property alias mediaItem: mediaView
  property alias bubbleItem: bubble

  visible: !row.hiddenInAlbum
  height: row.hiddenInAlbum ? 0
        : (row.newDay ? day.height + Style.space(12) : 0) + (row.runStart ? Style.space(6) : 0)
          + (row.service ? servicePill.height : bubble.height)

  Text {
    id: day
    visible: row.newDay && !row.hiddenInAlbum
    anchors.horizontalCenter: parent.horizontalCenter
    y: Style.space(4)
    text: Model.dayLabel(row.message.date, row.view.nowMs)
    color: row.app.muted
    font.family: row.app.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  }

  // ------------------------------------------------ service messages
  Rectangle {
    id: servicePill
    visible: row.service
    anchors.horizontalCenter: parent.horizontalCenter
    y: row.height - height
    width: Math.min(row.width - Style.space(60), serviceText.implicitWidth + Style.space(24))
    height: serviceText.implicitHeight + Style.space(10)
    radius: height / 2
    color: Qt.rgba(row.app.foreground.r, row.app.foreground.g, row.app.foreground.b, 0.06)

    Text {
      id: serviceText
      anchors.centerIn: parent
      width: Math.min(implicitWidth, row.width - Style.space(84))
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      textFormat: Text.PlainText
      text: row.content.text || "Service message"
      color: row.app.muted
      font.family: row.app.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // ------------------------------------------------ the bubble
  Rectangle {
    id: bubble
    visible: !row.service && !row.hiddenInAlbum
    readonly property real maxWidth: Math.min(row.width * 0.72, Style.space(640))
    readonly property real inner: maxWidth - Style.space(24)
    y: row.height - height
    x: row.message.outgoing ? row.width - width - Style.space(18) : Style.space(18)
    // Only what is shown counts: a hidden header or card still has an implicit width.
    width: Math.min(maxWidth, Math.max(body.visible ? body.implicitWidth : 0, meta.implicitWidth,
                                       mediaView.visible ? mediaView.implicitWidth : 0,
                                       albumFlow.visible ? albumFlow.wantedWidth : 0,
                                       name.visible ? name.implicitWidth : 0,
                                       forwarded.visible ? forwarded.implicitWidth : 0,
                                       kindLabel.visible ? kindLabel.implicitWidth : 0,
                                       quote.visible ? quote.implicitWidth : 0,
                                       preview.visible ? preview.implicitWidth : 0,
                                       pollCard.visible ? pollCard.wantedWidth : 0,
                                       place.visible ? place.implicitWidth : 0,
                                       person.visible ? person.implicitWidth : 0,
                                       reactionsFlow.visible ? reactionsFlow.wantedWidth : 0,
                                       buttons.visible ? buttons.wantedWidth : 0) + Style.space(24))
    height: column.implicitHeight + Style.space(16)
    radius: Style.cornerRadius * 1.5
    // Stickers and round video messages float without a bubble, as in Telegram.
    color: row.bare ? "transparent"
         : (row.message.outgoing ? Qt.rgba(row.app.accent.r, row.app.accent.g, row.app.accent.b, 0.2)
                                 : Qt.rgba(row.app.foreground.r, row.app.foreground.g, row.app.foreground.b, 0.06))
    border.width: row.isCursor || !!row.view.selection[row.message.id] ? Math.max(1, Style.space(1.5))
                : (row.message.id === row.view.confirmDeleteId ? 1 : 0)
    border.color: row.message.id === row.view.confirmDeleteId ? row.app.urgent : row.app.accent

    Column {
      id: column
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(12)
      anchors.topMargin: Style.space(8)
      spacing: Style.space(4)

      Text {
        id: name
        visible: row.showName
        text: row.message.senderName || "Unknown"
        textFormat: Text.PlainText
        color: row.app.accent
        font.family: row.app.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }

      Text {
        id: forwarded
        visible: !!row.message.forward
        width: Math.min(implicitWidth, bubble.inner)
        elide: Text.ElideRight
        text: row.message.forward ? "Forwarded from " + row.message.forward.name : ""
        textFormat: Text.PlainText
        color: row.app.accent
        font.family: row.app.fontFamily
        font.pixelSize: Style.font.caption
        font.italic: true
      }

      Rectangle {
        id: quote
        visible: !!row.message.replyTo
        width: parent.width
        implicitWidth: quoteText.implicitWidth + Style.space(12)
        height: quoteText.implicitHeight + Style.space(6)
        color: "transparent"

        Rectangle { width: Style.space(2); height: parent.height; color: row.app.accent }
        Text {
          id: quoteText
          x: Style.space(8)
          width: parent.width - x
          elide: Text.ElideRight
          maximumLineCount: 2
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          color: row.app.muted
          font.family: row.app.fontFamily
          font.pixelSize: Style.font.caption
          text: row.quoted ? (row.quoted.senderName ? row.quoted.senderName + ": " : "") + Model.previewOf(row.quoted) : "Reply to an older message"
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: if (row.message.replyTo) row.view.jumpTo(row.message.replyTo.messageId)
        }
      }

      MediaView {
        id: mediaView
        visible: row.album.length < 2 && !!row.content.media
        app: row.app
        message: row.message
        maxWidth: bubble.inner
        spoiler: !!row.content.spoiler
        revealed: row.revealed
        onRevealRequested: row.view.reveal(row.message.id)
      }

      Flow {
        id: albumFlow
        readonly property real cell: (bubble.inner - spacing) / 2
        // Positioners work out their own implicit size: what they would like is said separately.
        readonly property real wantedWidth: bubble.inner
        visible: row.album.length > 1
        width: parent.width
        spacing: Style.space(4)

        Repeater {
          model: row.album.length > 1 ? row.album : []
          delegate: MediaView {
            required property var modelData
            app: row.app
            message: modelData
            maxWidth: albumFlow.cell
            spoiler: !!modelData.content.spoiler
            revealed: !!row.view.revealed[modelData.id]
            onRevealRequested: row.view.reveal(modelData.id)
          }
        }
      }

      Text {
        id: kindLabel
        visible: row.label !== "" && !row.content.media && !row.cardKind
        text: row.label
        textFormat: Text.PlainText
        color: row.app.muted
        font.family: row.app.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.italic: true
      }

      Text {
        id: body
        readonly property string source: row.textSource.content.text || ""
        visible: source !== "" && !row.cardKind
        width: Math.min(implicitWidth, bubble.inner)
        text: visible ? Model.richText(source, row.textSource.content.entities, row.revealed, row.codeBackground) : ""
        textFormat: Text.RichText
        wrapMode: Text.Wrap
        color: row.app.foreground
        linkColor: row.app.accent
        font.family: row.app.fontFamily
        font.pixelSize: Style.font.body
        onLinkActivated: function (link) { row.view.openLink(link, row.message) }

        HoverHandler { cursorShape: body.hoveredLink ? Qt.PointingHandCursor : Qt.ArrowCursor }
      }

      // ---------------------------------------------- link preview
      Rectangle {
        id: preview
        readonly property var info: row.content.linkPreview || null
        readonly property var photo: preview.info && preview.info.photo ? preview.info.photo : null
        readonly property var photoFile: preview.photo ? row.app.fileState(preview.photo.file) : null
        readonly property string photoUrl: preview.photoFile ? Model.fileUrl(preview.photoFile.path) : ""
        visible: !!preview.info
        width: parent.width
        implicitWidth: Math.min(bubble.inner, Style.space(380))
        implicitHeight: previewColumn.implicitHeight + Style.space(12)
        height: implicitHeight
        radius: Style.cornerRadius
        color: Qt.rgba(row.app.accent.r, row.app.accent.g, row.app.accent.b, 0.08)

        function fetch() {
          if (preview.photoFile && !preview.photoUrl && !preview.photoFile.active) row.app.download(preview.photoFile.id, 1)
        }
        Component.onCompleted: fetch()
        onPhotoFileChanged: fetch()

        Rectangle { width: Style.space(3); height: parent.height; radius: 1; color: row.app.accent }

        Column {
          id: previewColumn
          x: Style.space(10)
          y: Style.space(6)
          width: parent.width - Style.space(16)
          spacing: Style.space(2)

          Text {
            visible: text !== ""
            width: parent.width
            elide: Text.ElideRight
            text: preview.info ? preview.info.siteName : ""
            textFormat: Text.PlainText
            color: row.app.accent
            font.family: row.app.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
          Text {
            visible: text !== ""
            width: parent.width
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            text: preview.info ? preview.info.title : ""
            textFormat: Text.PlainText
            color: row.app.foreground
            font.family: row.app.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
          Text {
            visible: text !== ""
            width: parent.width
            wrapMode: Text.Wrap
            maximumLineCount: 3
            elide: Text.ElideRight
            text: preview.info ? preview.info.description : ""
            textFormat: Text.PlainText
            color: row.app.muted
            font.family: row.app.fontFamily
            font.pixelSize: Style.font.caption
          }
          Image {
            visible: !!preview.photo && status === Image.Ready
            width: parent.width
            height: preview.photo ? Math.min(Style.space(200), width * preview.photo.height / Math.max(1, preview.photo.width)) : 0
            source: preview.photoUrl
            asynchronous: true
            fillMode: Image.PreserveAspectCrop
            sourceSize.width: Math.min(1024, width * 2)
          }
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: if (preview.info) row.view.openLink(preview.info.url, row.message)
        }
      }

      // ---------------------------------------------- poll
      Column {
        id: pollCard
        readonly property var poll: row.content.poll || null
        readonly property bool results: !!pollCard.poll && (pollCard.poll.voted || pollCard.poll.closed)
        readonly property var choices: row.view.pollChoices[row.message.id] || []
        readonly property real wantedWidth: Math.min(bubble.inner, Style.space(360))
        visible: !!pollCard.poll
        width: parent.width
        spacing: Style.space(6)

        Text {
          width: parent.width
          wrapMode: Text.Wrap
          text: pollCard.poll ? pollCard.poll.question : ""
          textFormat: Text.PlainText
          color: row.app.foreground
          font.family: row.app.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
        Text {
          text: !pollCard.poll ? "" : (pollCard.poll.quiz ? "Quiz" : (pollCard.poll.anonymous ? "Anonymous poll" : "Poll"))
                + (pollCard.poll.multiple ? " · several answers" : "") + (pollCard.poll.closed ? " · closed" : "")
          color: row.app.muted
          font.family: row.app.fontFamily
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: pollCard.poll ? pollCard.poll.options : []
          delegate: Item {
            id: option
            required property var modelData
            readonly property bool correct: pollCard.poll.quiz && pollCard.poll.correct.indexOf(modelData.index) >= 0
            readonly property bool picked: pollCard.choices.indexOf(modelData.index) >= 0
            width: pollCard.width
            height: optionText.implicitHeight + Style.space(14)

            Rectangle {
              visible: pollCard.results
              width: parent.width * option.modelData.percent / 100
              height: parent.height
              radius: Style.cornerRadius
              color: option.correct ? Qt.rgba(0.3, 0.7, 0.4, 0.3)
                   : (option.modelData.chosen ? Qt.rgba(row.app.accent.r, row.app.accent.g, row.app.accent.b, 0.3)
                                              : Qt.rgba(row.app.foreground.r, row.app.foreground.g, row.app.foreground.b, 0.08))
            }
            Rectangle {
              visible: !pollCard.results
              anchors.fill: parent
              radius: Style.cornerRadius
              color: option.picked ? Qt.rgba(row.app.accent.r, row.app.accent.g, row.app.accent.b, 0.2) : "transparent"
              border.width: 1
              border.color: optionArea.containsMouse || option.picked ? row.app.accent
                          : Qt.rgba(row.app.foreground.r, row.app.foreground.g, row.app.foreground.b, 0.2)
            }
            Text {
              id: optionText
              x: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.space(64)
              wrapMode: Text.Wrap
              text: (option.modelData.chosen || option.picked ? "✓ " : "") + option.modelData.text
              textFormat: Text.PlainText
              color: row.app.foreground
              font.family: row.app.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              visible: pollCard.results
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: option.modelData.percent + "%"
              color: row.app.muted
              font.family: row.app.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            MouseArea {
              id: optionArea
              anchors.fill: parent
              enabled: !pollCard.results
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: row.view.vote(row.message, option.modelData.index)
            }
          }
        }

        RowLayout {
          width: parent.width
          Text {
            Layout.fillWidth: true
            text: pollCard.poll ? pollCard.poll.total + (pollCard.poll.total === 1 ? " vote" : " votes") : ""
            color: row.app.muted
            font.family: row.app.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            visible: !!pollCard.poll && pollCard.poll.multiple && !pollCard.results && pollCard.choices.length > 0
            text: "Vote"
            color: row.app.accent
            font.family: row.app.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            MouseArea { anchors.fill: parent; anchors.margins: -Style.space(6); cursorShape: Qt.PointingHandCursor; onClicked: row.view.submitVote(row.message) }
          }
        }
      }

      // ---------------------------------------------- place and contact
      Rectangle {
        id: place
        readonly property var location: row.content.location || null
        visible: !!place.location
        width: parent.width
        implicitWidth: Math.min(bubble.inner, Style.space(320))
        implicitHeight: placeColumn.implicitHeight + Style.space(14)
        height: implicitHeight
        radius: Style.cornerRadius
        color: Qt.rgba(row.app.accent.r, row.app.accent.g, row.app.accent.b, 0.08)

        Column {
          id: placeColumn
          x: Style.space(10)
          y: Style.space(7)
          width: parent.width - Style.space(20)
          spacing: Style.space(2)
          Text {
            width: parent.width
            wrapMode: Text.Wrap
            text: "📍 " + (place.location && place.location.title ? place.location.title : "Location")
            textFormat: Text.PlainText
            color: row.app.foreground
            font.family: row.app.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
          Text {
            visible: text !== ""
            width: parent.width
            wrapMode: Text.Wrap
            text: place.location ? place.location.address : ""
            textFormat: Text.PlainText
            color: row.app.muted
            font.family: row.app.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            text: place.location ? place.location.lat.toFixed(5) + ", " + place.location.lon.toFixed(5) + "   Open map ↗" : ""
            color: row.app.accent
            font.family: row.app.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            var l = place.location
            if (l) row.view.openExternal("https://www.openstreetmap.org/?mlat=" + l.lat + "&mlon=" + l.lon + "#map=16/" + l.lat + "/" + l.lon)
          }
        }
      }

      Rectangle {
        id: person
        readonly property var contact: row.content.contact || null
        visible: !!person.contact
        width: parent.width
        implicitWidth: Math.min(bubble.inner, Style.space(300))
        implicitHeight: Style.space(56)
        height: implicitHeight
        radius: Style.cornerRadius
        color: Qt.rgba(row.app.accent.r, row.app.accent.g, row.app.accent.b, 0.08)

        RowLayout {
          anchors.fill: parent
          anchors.margins: Style.space(8)
          spacing: Style.space(10)
          Rectangle {
            Layout.preferredWidth: Style.space(38)
            Layout.preferredHeight: Style.space(38)
            radius: width / 2
            color: Qt.rgba(row.app.accent.r, row.app.accent.g, row.app.accent.b, 0.25)
            Text {
              anchors.centerIn: parent
              text: Model.initials(person.contact ? person.contact.name : "")
              color: row.app.accent
              font.family: row.app.fontFamily
              font.bold: true
            }
          }
          Column {
            Layout.fillWidth: true
            spacing: Style.space(2)
            Text {
              width: parent.width
              elide: Text.ElideRight
              text: person.contact ? person.contact.name : ""
              textFormat: Text.PlainText
              color: row.app.foreground
              font.family: row.app.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
            Text {
              width: parent.width
              elide: Text.ElideRight
              text: person.contact ? person.contact.phone + (person.contact.userId ? "   Message ↗" : "") : ""
              textFormat: Text.PlainText
              color: row.app.muted
              font.family: row.app.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
        MouseArea {
          anchors.fill: parent
          enabled: !!person.contact && person.contact.userId > 0
          cursorShape: Qt.PointingHandCursor
          onClicked: row.view.openUser(person.contact.userId)
        }
      }

      // ---------------------------------------------- reactions
      Flow {
        id: reactionsFlow
        readonly property var list: row.message.reactions || []
        readonly property real wantedWidth: Math.min(bubble.inner, reactionsFlow.list.length * Style.space(62))
        visible: reactionsFlow.list.length > 0
        width: parent.width
        spacing: Style.space(4)

        Repeater {
          model: reactionsFlow.list
          delegate: Rectangle {
            required property var modelData
            height: Style.space(24)
            width: chip.implicitWidth + Style.space(14)
            radius: height / 2
            color: modelData.chosen ? Qt.rgba(row.app.accent.r, row.app.accent.g, row.app.accent.b, 0.3)
                                    : Qt.rgba(row.app.foreground.r, row.app.foreground.g, row.app.foreground.b, 0.08)
            border.width: modelData.chosen ? 1 : 0
            border.color: row.app.accent
            Text {
              id: chip
              anchors.centerIn: parent
              text: (modelData.emoji || "✦") + " " + modelData.count
              color: row.app.foreground
              font.family: row.app.fontFamily
              font.pixelSize: Style.font.caption
            }
            MouseArea {
              anchors.fill: parent
              enabled: !!modelData.emoji && !modelData.paid
              cursorShape: Qt.PointingHandCursor
              onClicked: row.view.toggleReaction(row.message, modelData)
            }
          }
        }
      }

      // ---------------------------------------------- bot buttons
      Column {
        id: buttons
        readonly property var rows: row.message.markup && row.message.markup.type === "inline" ? row.message.markup.rows : []
        readonly property real wantedWidth: Math.min(bubble.inner, Style.space(360))
        visible: buttons.rows.length > 0
        width: parent.width
        spacing: Style.space(4)

        Repeater {
          model: buttons.rows
          delegate: Row {
            id: buttonRow
            required property var modelData
            width: buttons.width
            spacing: Style.space(4)

            Repeater {
              model: buttonRow.modelData
              delegate: Rectangle {
                required property var modelData
                width: (buttonRow.width - buttonRow.spacing * (buttonRow.modelData.length - 1)) / buttonRow.modelData.length
                height: Style.space(30)
                radius: Style.cornerRadius
                color: buttonArea.containsMouse ? Qt.rgba(row.app.accent.r, row.app.accent.g, row.app.accent.b, 0.3)
                                                : Qt.rgba(row.app.accent.r, row.app.accent.g, row.app.accent.b, 0.14)
                Text {
                  anchors.centerIn: parent
                  width: parent.width - Style.space(12)
                  horizontalAlignment: Text.AlignHCenter
                  elide: Text.ElideRight
                  text: modelData.text + (modelData.kind === "url" || modelData.kind === "webApp" ? " ↗" : "")
                  textFormat: Text.PlainText
                  color: row.app.foreground
                  font.family: row.app.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                MouseArea {
                  id: buttonArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: row.view.pressButton(row.message, modelData)
                }
              }
            }
          }
        }
      }

      Text {
        id: meta
        anchors.right: parent.right
        text: (row.message.views > 0 ? row.message.views + " views  ·  " : "")
          + (row.message.editDate > 0 ? "edited  " : "") + Model.clock(row.message.date)
          + (row.receipt === "read" ? "  ✓✓" : (row.receipt === "sent" ? "  ✓" : ""))
          + (row.receipt === "sending" ? "  ·  sending" : (row.receipt === "failed" ? "  ·  failed" : ""))
        color: row.receipt === "failed" ? row.app.urgent : (row.receipt === "read" ? row.app.accent : row.app.muted)
        font.family: row.app.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // Under the bubble's content: media, links and buttons inside take their own clicks; a click
    // anywhere else puts the cursor on the message (Ctrl+click, or any click while messages are
    // selected, selects it), a double click replies, a right click opens its menu.
    MouseArea {
      z: -1
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onDoubleClicked: function (mouse) { if (mouse.button === Qt.LeftButton && !row.view.selecting) row.view.startReply(row.message) }
      onClicked: function (mouse) {
        row.view.cursor = row.index
        if (mouse.button === Qt.RightButton) {
          var at = mapToItem(row.view, mouse.x, mouse.y)
          row.view.openMenu(row.message, at.x, at.y)
        } else if (row.view.selecting || (mouse.modifiers & Qt.ControlModifier)) {
          row.view.toggleSelected(row.message)
        }
      }
    }
  }
}
