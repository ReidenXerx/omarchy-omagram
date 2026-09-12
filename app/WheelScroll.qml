import QtQuick

// Wheel and touchpad scrolling at a useful speed for a Flickable (ListView, GridView). Qt's
// own step is a few lines per wheel notch, which crawls through a chat full of tall messages.
//
// Name the view: a handler declared inside a list is moved onto the list's content item, so
// its parent is not the list -- and a handler that takes the wheel without scrolling anything
// stops the list scrolling at all.
WheelHandler {
  id: handler

  property Flickable view: null

  // Pixels per wheel notch, and how much a touchpad's own pixel deltas are scaled.
  property real notch: 140
  property real touchpadScale: 1.8

  // After every step, for views that react to where they are (stick to the bottom, load older).
  signal scrolled()

  target: null
  acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad

  onWheel: function (event) {
    var view = handler.view
    if (!view) return
    var dy = event.pixelDelta.y !== 0 ? event.pixelDelta.y * handler.touchpadScale
                                      : event.angleDelta.y / 120 * handler.notch
    if (dy === 0) return
    var top = view.originY - view.topMargin
    var bottom = Math.max(top, view.originY + view.contentHeight + view.bottomMargin - view.height)
    view.contentY = Math.max(top, Math.min(bottom, view.contentY - dy))
    event.accepted = true
    handler.scrolled()
  }
}
