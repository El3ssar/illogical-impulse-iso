// ErrorState — the honest failure rendering: an error glyph, the message, and a
// Retry button. Never leave a data view silently blank on failure.
import QtQuick
import QtQuick.Layouts
import ".."

ColumnLayout {
    id: err
    property string message: "Something went wrong."
    property bool canRetry: true
    signal retry()
    spacing: 12

    Text {
        Layout.alignment: Qt.AlignHCenter
        text: "error"
        font.family: "Material Symbols Rounded"
        font.pixelSize: 44
        color: Qt.alpha(Colors.error, 0.85)
    }
    Text {
        Layout.alignment: Qt.AlignHCenter
        Layout.maximumWidth: 420
        text: err.message
        color: Colors.error
        font.pixelSize: 13
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
    }
    PillButton {
        Layout.alignment: Qt.AlignHCenter
        visible: err.canRetry
        text: "Retry"
        glyph: "refresh"
        onClicked: err.retry()
    }
}
