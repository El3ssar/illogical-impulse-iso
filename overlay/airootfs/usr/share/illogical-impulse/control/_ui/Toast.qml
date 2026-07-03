// Toast — a transient success/failure banner. Call show(msg, isError); it fades
// in, holds for `duration`, then fades out. The parent anchors it (e.g. bottom
// centre); it animates opacity + scale only, so it never fights the anchor.
import QtQuick
import ".."

Rectangle {
    id: toast
    property bool error: false
    property int duration: 3500
    property bool shown: false

    radius: 11
    color: Colors.surfaceHigh
    border.color: toast.error ? Colors.error : Colors.outline
    border.width: 1
    implicitWidth: rowc.implicitWidth + 30
    implicitHeight: rowc.implicitHeight + 20
    opacity: shown ? 1 : 0
    scale: shown ? 1 : 0.96
    visible: opacity > 0.01

    Behavior on opacity { NumberAnimation { duration: 160 } }
    Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

    Row {
        id: rowc
        anchors.centerIn: parent
        spacing: 8
        Text {
            text: toast.error ? "error" : "check_circle"
            font.family: "Material Symbols Rounded"
            font.pixelSize: 18
            color: toast.error ? Colors.error : Colors.primary
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            id: label
            color: Colors.onSurface
            font.pixelSize: 13
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    Timer { id: hideT; interval: toast.duration; onTriggered: toast.shown = false }

    function show(msg, isError) {
        label.text = msg;
        toast.error = !!isError;
        toast.shown = true;
        hideT.restart();
    }
    function hide() { toast.shown = false; hideT.stop(); }
}
