// Console — an in-window streaming action console. A pane calls run(cmd, title)
// for any long/interactive mutation (installs, AUR builds, `iictl … set`); the
// child bash process streams live output into a scrolling view, and a trailing
// __IICTL_RC sentinel reports the real exit code (completion never depends on a
// signal race — the welcome-card lesson). No external terminal pops up; the UI
// never freezes (the process is async). Emits done(exitCode) and closed().
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Quickshell.Io
import ".."

Item {
    id: con
    property bool open: false
    property string title: ""
    property bool busy: false
    property bool finished: false
    property int exitCode: -1
    signal done(int code)
    signal closed()
    visible: open

    function run(cmd, title) {
        con.title = title && title.length ? title : "Working…";
        con.open = true; con.busy = true; con.finished = false; con.exitCode = -1;
        out.text = "";
        // NO_COLOR/TERM keep output ANSI-free; sentinel carries the real rc.
        var payload = "export NO_COLOR=1 TERM=dumb; " + cmd
                    + " 2>&1; printf '\\n__IICTL_RC:%d\\n' \"$?\"";
        proc.command = ["bash", "-c", payload];
        proc.running = true;
    }
    function _append(line) {
        if (line.indexOf("__IICTL_RC:") === 0) {
            con.exitCode = parseInt(line.substring(11)) || 0;
            return;
        }
        out.text += line + "\n";
        flick.contentY = Math.max(0, out.implicitHeight - flick.height);
    }
    function close() {
        if (con.busy) return;
        con.open = false; con.finished = false;
        con.closed();
    }

    Process {
        id: proc
        stdout: SplitParser { onRead: data => con._append(data) }
        stderr: SplitParser { onRead: data => con._append(data) }
        onRunningChanged: {
            if (!proc.running) {
                con.busy = false; con.finished = true;
                con.done(con.exitCode);
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 12

        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Text {
                text: con.title
                color: Colors.onSurface
                font.pixelSize: 17
                font.bold: true
                Layout.fillWidth: true
                elide: Text.ElideRight
            }
            Spinner { size: 20; running: con.busy; visible: con.busy }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Colors.outline }

        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: 10
            color: Colors.mono
            border.color: Colors.outline
            border.width: 1
            Flickable {
                id: flick
                anchors.fill: parent
                anchors.margins: 10
                clip: true
                contentWidth: out.implicitWidth
                contentHeight: out.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }
                TextEdit {
                    id: out
                    readOnly: true
                    selectByMouse: true
                    wrapMode: TextEdit.NoWrap
                    textFormat: TextEdit.PlainText
                    color: Colors.onSurface
                    font.family: "monospace"
                    font.pixelSize: 12
                }
            }
            Text {
                anchors.centerIn: parent
                visible: out.text.length === 0 && con.busy
                text: "Starting…"
                color: Colors.onSurfaceVariant
                font.pixelSize: 13
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Text {
                Layout.fillWidth: true
                color: con.busy ? Colors.onSurfaceVariant
                     : (con.exitCode === 0 ? Colors.primary : Colors.error)
                font.pixelSize: 13
                text: con.busy ? "Working…"
                    : con.finished ? (con.exitCode === 0 ? "Done." : "Failed (exit " + con.exitCode + ").")
                    : ""
            }
            PillButton {
                text: "Back"
                glyph: "arrow_back"
                Layout.preferredWidth: 120
                enabled: !con.busy
                onClicked: con.close()
            }
        }
    }
}
