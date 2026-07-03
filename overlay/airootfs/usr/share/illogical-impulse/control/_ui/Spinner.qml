// Spinner — a themed indeterminate progress ring (a dot orbiting a faint ring).
// Self-contained (no Controls style dependency) so it themes cleanly from Colors.
import QtQuick
import ".."

Item {
    id: sp
    property int size: 24
    property bool running: true
    implicitWidth: size
    implicitHeight: size

    Rectangle {   // faint full ring
        anchors.fill: parent
        radius: width / 2
        color: "transparent"
        border.width: Math.max(2, sp.size / 9)
        border.color: Qt.alpha(Colors.primary, 0.22)
    }

    Item {   // rotating head
        id: head
        anchors.fill: parent
        visible: sp.running
        Rectangle {
            width: Math.max(3, sp.size / 5)
            height: width
            radius: width / 2
            color: Colors.primary
            x: parent.width / 2 - width / 2
            y: -height / 2 + Math.max(2, sp.size / 9) / 2
        }
        RotationAnimator on rotation {
            running: sp.running && sp.visible
            from: 0; to: 360
            duration: 900
            loops: Animation.Infinite
        }
    }
}
