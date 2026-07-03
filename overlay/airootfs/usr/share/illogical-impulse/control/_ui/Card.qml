// Card — a themed rounded surface container. The base panel every pane composes.
// Content goes into the default property (child items). Reads Colors so it
// re-themes live with the wallpaper.
import QtQuick
import QtQuick.Layouts
import ".."

Rectangle {
    id: card
    default property alias content: inner.data
    property int pad: 16
    radius: 14
    color: Colors.surface
    border.color: Colors.outline
    border.width: 1
    implicitWidth: inner.implicitWidth + pad * 2
    implicitHeight: inner.implicitHeight + pad * 2

    ColumnLayout {
        id: inner
        anchors.fill: parent
        anchors.margins: card.pad
        spacing: 10
    }
}
