// Badge — a small tinted pill label (source/status chips). Tint defaults to the
// accent; pass tint: Colors.tertiary / Colors.error for AUR / protected etc.
import QtQuick
import ".."

Rectangle {
    id: badge
    property string text: ""
    property color tint: Colors.primary
    radius: 5
    color: Qt.alpha(tint, 0.16)
    implicitWidth: label.implicitWidth + 12
    implicitHeight: label.implicitHeight + 5
    Text {
        id: label
        anchors.centerIn: parent
        text: badge.text
        color: badge.tint
        font.pixelSize: 10
        font.bold: true
    }
}
