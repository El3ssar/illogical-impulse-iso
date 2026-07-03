// Overview pane — the Control Center landing: a system summary (iictl version),
// the primary quick actions (update / health check / reopen welcome), and the
// home of `iictl revert-all` (restore vanilla upstream). Every mutating action
// streams through the shared in-window Console; nothing is run behind the user's
// back. All work goes through the Ctl singleton → iictl (reversible by design).
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."
import "../_ui"

Item {
    id: pane
    property string versionText: ""
    property bool versionLoaded: false
    property bool confirmRevert: false

    Component.onCompleted: refresh()
    function refresh() {
        pane.versionLoaded = false;
        Ctl.text(["version"], function (t) { pane.versionText = t.trim(); pane.versionLoaded = true; });
    }
    function runAction(cmd, title) { consoleOverlay.run(cmd, title); }

    // ── content ───────────────────────────────────────────────────────────────
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
            spacing: 16

            // hero
            RowLayout {
                Layout.fillWidth: true
                spacing: 14
                Image {
                    source: "/usr/share/pixmaps/illogical-impulse.png"
                    sourceSize.width: 56
                    sourceSize.height: 56
                    fillMode: Image.PreserveAspectFit
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Text {
                        text: "Control Center"
                        color: Colors.onSurface
                        font.pixelSize: 24
                        font.bold: true
                    }
                    Text {
                        text: "One place for every reversible tweak — shells, editor, packages, theming and more. Complements the rice's own Super+I settings; never replaces it."
                        color: Colors.onSurfaceVariant
                        font.pixelSize: 12
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                    }
                }
            }

            // system summary
            Card {
                Layout.fillWidth: true
                Section {
                    title: "System"
                    Text {
                        text: !pane.versionLoaded ? "Reading release info…"
                            : (pane.versionText.length ? pane.versionText
                               : "Release info unavailable (is iictl on PATH?)")
                        color: Colors.onSurfaceVariant
                        font.family: "monospace"
                        font.pixelSize: 12
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                    }
                }
            }

            // quick actions
            Card {
                Layout.fillWidth: true
                Section {
                    title: "Quick actions"
                    subtitle: "Long actions stream live in this window; nothing runs silently."
                    GridLayout {
                        Layout.fillWidth: true
                        columns: 2
                        columnSpacing: 10
                        rowSpacing: 10
                        PillButton {
                            Layout.fillWidth: true
                            primary: true
                            glyph: "system_update_alt"
                            text: "Update everything"
                            onClicked: pane.runAction("iictl update --system", "Update everything")
                        }
                        PillButton {
                            Layout.fillWidth: true
                            glyph: "health_and_safety"
                            text: "Run a health check"
                            onClicked: pane.runAction("iictl doctor", "Health check")
                        }
                        PillButton {
                            Layout.fillWidth: true
                            glyph: "waving_hand"
                            text: "Reopen welcome card"
                            onClicked: Ctl.runDetached(["iictl", "welcome"])
                        }
                        PillButton {
                            Layout.fillWidth: true
                            glyph: "menu_book"
                            text: "Offline quickstart"
                            onClicked: Ctl.runInTerminal("iictl docs | less -R", "Quickstart")
                        }
                    }
                }
            }

            // restore vanilla (the reversibility home)
            Card {
                Layout.fillWidth: true
                Section {
                    title: "Restore vanilla"
                    subtitle: "Reverse-replay the ledger to undo every distro addition and return to upstream. --deep also peels install-time group memberships."
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10
                        visible: !pane.confirmRevert
                        PillButton {
                            glyph: "restart_alt"
                            text: "Preview (dry run)"
                            onClicked: pane.runAction("iictl revert-all --dry-run", "Revert — dry run")
                        }
                        PillButton {
                            danger: true
                            glyph: "undo"
                            text: "Restore vanilla…"
                            onClicked: pane.confirmRevert = true
                        }
                        Item { Layout.fillWidth: true }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        visible: pane.confirmRevert
                        Text {
                            text: "This undoes distro tweaks recorded in the ledger. Continue?"
                            color: Colors.onSurface
                            font.pixelSize: 13
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                        }
                        RowLayout {
                            spacing: 10
                            PillButton {
                                danger: true
                                text: "Yes, restore vanilla"
                                onClicked: { pane.confirmRevert = false; pane.runAction("iictl revert-all", "Restore vanilla"); }
                            }
                            PillButton {
                                text: "Cancel"
                                onClicked: pane.confirmRevert = false
                            }
                        }
                    }
                }
            }
        }
    }

    // ── streaming console + toast ──────────────────────────────────────────────
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
