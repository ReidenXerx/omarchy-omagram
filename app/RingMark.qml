import QtQuick
import QtQuick.Shapes

// Omagram's mark, the Ring: the O of Omarchy with a speech tail. Drawn natively in one colour, so it stays
// crisp from a bar slot up; the geometry is the 64-unit drawing in assets/omagram.svg.
Item {
  id: mark

  property real size: 16
  property color color: "white"
  readonly property real unit: mark.size / 64

  width: mark.size
  height: mark.size
  implicitWidth: mark.size
  implicitHeight: mark.size

  // The O: radius 19 around (34, 29), 7 wide.
  Rectangle {
    x: 11.5 * mark.unit
    y: 6.5 * mark.unit
    width: 45 * mark.unit
    height: width
    radius: width / 2
    color: "transparent"
    border.width: 7 * mark.unit
    border.color: mark.color
    antialiasing: true
  }

  // The tail, its corners rounded.
  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      fillColor: mark.color
      strokeColor: mark.color
      strokeWidth: 2.5 * mark.unit
      joinStyle: ShapePath.RoundJoin
      startX: 21.1 * mark.unit
      startY: 47.4 * mark.unit
      PathLine { x: 12 * mark.unit; y: 33.7 * mark.unit }
      PathLine { x: 8.5 * mark.unit; y: 55.5 * mark.unit }
      PathLine { x: 21.1 * mark.unit; y: 47.4 * mark.unit }
    }
  }
}
