//@ pragma UseQApplication
//@ pragma Env QS_NO_RELOAD_POPUP=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic

// Illogical Impulse — dev-dashboard widget (issue #20), the v1 reference widget
// for the additive Quickshell widget framework.
//
// Deliberately standalone: plain QtQuick + the shared _lib (Theme + Panel) only,
// ZERO imports from upstream's quickshell/ii tree — if end-4 redesigns the rice
// tomorrow, this still runs. It is a surface upstream LACKS (verified: no devdash/
// sysmon under modules/ or services/), so it adds rather than duplicates.
//
// Cards are driven by Quickshell.Io.Process shelling to small, bash -n-clean
// helper scripts in cards/ (git / containers / CI / resources). Re-themes live by
// composing Theme, which watches upstream's generated colors.json (READ-ONLY).
//
// Reaches the user only via `iictl widget enable devdash` (or the Super+Alt+W
// leader). Reversible: delete this dir + the state marker + the fenced execs.lua/
// keybinds.lua blocks (or run `iictl revert-all`) → the vanilla rice returns.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../_lib"

Panel {
    id: dash
    surfaceColor: Theme.surface
    borderColor: Theme.outline
    implicitWidth: 470
    implicitHeight: 640

    readonly property string cardsDir: "/usr/share/illogical-impulse/widgets/devdash/cards"

    // A card runs one helper script and streams its output into a mono pane, with
    // a manual refresh and a periodic auto-refresh.
    component Card: ColumnLayout {
        id: card
        property string title: ""
        property string script: ""
        property string body: ""
        property bool busy: false
        Layout.fillWidth: true
        spacing: 6

        function refresh() {
            card.body = "";
            card.busy = true;
            proc.command = ["bash", dash.cardsDir + "/" + card.script];
            proc.running = true;
        }
        Process {
            id: proc
            stdout: SplitParser { onRead: line => card.body += line + "\n" }
            stderr: SplitParser { onRead: line => card.body += line + "\n" }
            onRunningChanged: if (!proc.running) card.busy = false
        }
        Component.onCompleted: card.refresh()
        Timer { interval: 30000; running: true; repeat: true; onTriggered: card.refresh() }

        RowLayout {
            Layout.fillWidth: true
            Text {
                text: card.title
                color: Theme.primary
                font.pixelSize: 14
                font.bold: true
                Layout.fillWidth: true
                elide: Text.ElideRight
            }
            Text {
                text: card.busy ? "…" : "↻"   // refresh glyph
                color: Theme.onSurfaceVariant
                font.pixelSize: 15
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: card.refresh() }
            }
        }
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: bodyText.implicitHeight + 16
            radius: 10
            color: Theme.surfaceLow
            border.color: Theme.outline
            border.width: 1
            Text {
                id: bodyText
                anchors.fill: parent
                anchors.margins: 8
                text: card.body.length > 0 ? card.body : (card.busy ? "loading…" : "(no data)")
                color: Theme.onSurface
                font.family: "monospace"
                font.pixelSize: 11
                wrapMode: Text.NoWrap
                textFormat: Text.PlainText
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 12

        RowLayout {
            Layout.fillWidth: true
            Text {
                text: "Dev Dashboard"
                color: Theme.onSurface
                font.pixelSize: 18
                font.bold: true
                Layout.fillWidth: true
            }
            Text {
                text: Theme.live ? "themed" : "static"
                color: Theme.onSurfaceVariant
                font.pixelSize: 10
            }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.outline }

        Card { title: "Git · ~/Projects"; script: "git.sh" }
        Card { title: "Containers";          script: "containers.sh" }
        Card { title: "CI · recent runs"; script: "ci.sh" }
        Card { title: "Resources";           script: "resources.sh" }

        Item { Layout.fillHeight: true }

        Text {
            text: "Super+Alt+W → D toggles  ·  iictl widget"
            color: Theme.onSurfaceVariant
            font.pixelSize: 10
            Layout.alignment: Qt.AlignHCenter
        }
    }
}
