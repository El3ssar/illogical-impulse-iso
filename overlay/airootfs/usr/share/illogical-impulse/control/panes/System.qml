// System & Updates pane — the health/maintenance home: a live `iictl doctor`
// summary, system updates + the stable/edge update channel (#27), the Quickshell
// venv rebuild, and the deep restore-vanilla (also peels install-time groups).
// Every mutating action streams through the in-window Console (never silent).
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."
import "../_ui"

Item {
    id: pane
    property string doctorText: ""
    property bool doctorLoading: true
    property bool confirmRevert: false

    Component.onCompleted: refresh()
    function refresh() {
        pane.doctorLoading = true;
        Ctl.text(["doctor"], function (t) { pane.doctorText = t.trim(); pane.doctorLoading = false; });
    }
    function runAction(cmd, title) { consoleOverlay.run(cmd, title); }

    Flickable {
        anchors.fill: parent
        visible: !consoleOverlay.open
        clip: true
        contentWidth: width
        contentHeight: col.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        ColumnLayout {
            id: col
            width: parent.width
            spacing: 14

            // updates
            Card {
                Layout.fillWidth: true
                Section {
                    title: "Updates"
                    subtitle: "Update the whole system (repos + AUR + dots) and choose the dots update channel."
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10
                        PillButton {
                            primary: true
                            glyph: "system_update_alt"
                            text: "Update everything"
                            onClicked: pane.runAction("iictl update --system", "Update everything")
                        }
                        Item { Layout.fillWidth: true }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10
                        Text { text: "Channel:"; color: Colors.onSurfaceVariant; font.pixelSize: 12 }
                        PillButton { text: "stable"; onClicked: pane.runAction("iictl update --channel stable", "Channel → stable") }
                        PillButton { text: "edge"; onClicked: pane.runAction("iictl update --channel edge", "Channel → edge") }
                        Item { Layout.fillWidth: true }
                    }
                }
            }

            // health
            Card {
                Layout.fillWidth: true
                Section {
                    title: "Health check"
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10
                        Text {
                            Layout.fillWidth: true
                            visible: pane.doctorLoading
                            text: "Running iictl doctor…"
                            color: Colors.onSurfaceVariant
                            font.pixelSize: 12
                        }
                        PillButton { glyph: "refresh"; text: "Re-run"; onClicked: pane.refresh() }
                        PillButton { glyph: "medical_services"; text: "Rebuild venv"; onClicked: pane.runAction("iictl venv", "Rebuild Quickshell venv") }
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        visible: !pane.doctorLoading && pane.doctorText.length > 0
                        radius: 10
                        color: Colors.mono
                        border.color: Colors.outline
                        border.width: 1
                        implicitHeight: Math.min(dr.implicitHeight + 20, 240)
                        Flickable {
                            anchors.fill: parent
                            anchors.margins: 10
                            clip: true
                            contentWidth: width
                            contentHeight: dr.implicitHeight
                            boundsBehavior: Flickable.StopAtBounds
                            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                            TextEdit {
                                id: dr
                                width: parent.width
                                readOnly: true
                                selectByMouse: true
                                wrapMode: TextEdit.Wrap
                                textFormat: TextEdit.PlainText
                                color: Colors.onSurfaceVariant
                                font.family: "monospace"
                                font.pixelSize: 12
                                text: pane.doctorText
                            }
                        }
                    }
                    // honest empty/error state — never a silent blank (#14 review).
                    Text {
                        Layout.fillWidth: true
                        visible: !pane.doctorLoading && pane.doctorText.length === 0
                        text: "Could not run iictl doctor — is iictl on PATH? Press Re-run to retry."
                        color: Colors.onSurfaceVariant
                        font.pixelSize: 12
                        wrapMode: Text.WordWrap
                    }
                }
            }

            // restore vanilla (deep)
            Card {
                Layout.fillWidth: true
                Section {
                    title: "Restore vanilla"
                    subtitle: "Reverse-replay the ledger to return to upstream. Deep restore also removes the install-time group memberships the distro added."
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10
                        visible: !pane.confirmRevert
                        PillButton { glyph: "restart_alt"; text: "Preview (dry run)"; onClicked: pane.runAction("iictl revert-all --deep --dry-run", "Deep revert — dry run") }
                        PillButton { danger: true; glyph: "undo"; text: "Deep restore…"; onClicked: pane.confirmRevert = true }
                        Item { Layout.fillWidth: true }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        visible: pane.confirmRevert
                        Text {
                            text: "Deep restore undoes distro tweaks AND removes the added groups (video/input/wheel…). Continue?"
                            color: Colors.onSurface
                            font.pixelSize: 13
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                        }
                        RowLayout {
                            spacing: 10
                            PillButton { danger: true; text: "Yes, deep restore"; onClicked: { pane.confirmRevert = false; pane.runAction("iictl revert-all --deep", "Deep restore vanilla"); } }
                            PillButton { text: "Cancel"; onClicked: pane.confirmRevert = false }
                        }
                    }
                }
            }
        }
    }

    Console {
        id: consoleOverlay
        anchors.fill: parent
        onDone: function (code) {
            toast.show(code === 0 ? "Done." : "Failed (exit " + code + ").", code !== 0);
            pane.refresh();
        }
    }
    Toast {
        id: toast
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 16
    }
}
