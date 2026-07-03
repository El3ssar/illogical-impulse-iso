// Toggle — a labelled, themed on/off switch. The visual state is driven by the
// `checked` property (the model owns truth); user interaction emits toggled(value)
// as a REQUEST — the pane applies it via iictl and updates `checked`, keeping the
// switch and the system in lockstep even if an apply fails.
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

RowLayout {
    id: t
    property string label: ""
    property string hint: ""
    property bool checked: false
    property bool busy: false
    signal toggled(bool value)
    spacing: 12
    Layout.fillWidth: true

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 1
        visible: t.label.length > 0 || t.hint.length > 0
        Text { text: t.label; color: Colors.onSurface; font.pixelSize: 13; visible: t.label.length > 0 }
        Text { text: t.hint; color: Colors.onSurfaceVariant; font.pixelSize: 11; visible: t.hint.length > 0; Layout.fillWidth: true; wrapMode: Text.WordWrap }
    }

    Switch {
        id: sw
        enabled: !t.busy
        opacity: t.busy ? 0.5 : 1.0
        // Reflect the model without a two-way binding fight: sync on model change,
        // request on user toggle.
        Component.onCompleted: sw.checked = t.checked
        Connections { target: t; function onCheckedChanged() { sw.checked = t.checked } }
        onToggled: t.toggled(sw.checked)
        indicator: Rectangle {
            implicitWidth: 44
            implicitHeight: 24
            radius: 12
            color: sw.checked ? Colors.primary : Colors.surfaceHigh
            border.color: sw.checked ? "transparent" : Colors.outline
            border.width: 1
            Behavior on color { ColorAnimation { duration: 120 } }
            Rectangle {
                x: sw.checked ? parent.width - width - 3 : 3
                anchors.verticalCenter: parent.verticalCenter
                width: 18; height: 18; radius: 9
                color: sw.checked ? Colors.onPrimary : Colors.onSurfaceVariant
                Behavior on x { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }
            }
        }
        contentItem: Item {}
    }
}
