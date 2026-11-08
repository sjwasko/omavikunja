import QtQuick
import QtQuick.Effects

// The Vikunja llama. "mono" paints the bar foreground through the llama's
// silhouette (eyes and nose are cut out), so it follows the theme like the
// other bar icons; "color" shows the official blue-circle logo as is.
Item {
  id: root

  property color color: "white"
  property bool colored: false

  Image {
    id: monoImage
    anchors.fill: parent
    source: Qt.resolvedUrl("vikunja-mono.svg")
    fillMode: Image.PreserveAspectFit
    sourceSize.width: Math.round(width * Screen.devicePixelRatio)
    sourceSize.height: Math.round(height * Screen.devicePixelRatio)
    smooth: true
    // Kept as a hidden layer so the mask can sample it as a texture.
    visible: false
    layer.enabled: !root.colored
  }

  Rectangle {
    anchors.fill: parent
    visible: !root.colored
    color: root.color
    layer.enabled: !root.colored
    layer.effect: MultiEffect {
      maskEnabled: true
      maskSource: monoImage
      maskThresholdMin: 0.5
      maskSpreadAtMin: 1.0
    }
  }

  Image {
    anchors.fill: parent
    visible: root.colored
    source: root.colored ? Qt.resolvedUrl("vikunja-color.svg") : ""
    fillMode: Image.PreserveAspectFit
    sourceSize.width: Math.round(width * Screen.devicePixelRatio)
    sourceSize.height: Math.round(height * Screen.devicePixelRatio)
    smooth: true
  }
}
