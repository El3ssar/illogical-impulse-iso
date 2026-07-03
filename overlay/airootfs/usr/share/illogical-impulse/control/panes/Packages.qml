//@ pragma UseQApplication
//@ pragma Env QS_NO_RELOAD_POPUP=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic

// Illogical Impulse — Control Center "Packages" pane (issue #30).
//
// The GUI front end for `iictl pkg` (the one-click software manager). It is
// DELIBERATELY standalone: its own Quickshell config, plain QtQuick, and ZERO
// imports from upstream's shell tree (quickshell/ii) — the same seam class as the
// welcome card. That means it loads on its own with `qs -p Packages.qml` today,
// and will register into the Control Center pane registry unchanged when #14
// lands (one panes/*.qml + one registry line, no shell edits — PROPOSAL §11).
//
// It contains NO package logic: every operation shells out to the CLI engine,
// which is the single source of truth —
//     iictl pkg search|info|list … --json   (read; parsed into models)
//     iictl pkg install|remove|clean         (streamed into an embedded console)
// Long actions run in an in-window console (a Quickshell.Io.Process streamed into
// a TextEdit, the welcome card's proven runInTerminal() pattern) so the user sees
// live pacman/paru output and NO external terminal pops up.
//
// Theming: a small inline "colors" reader FileView-watches upstream's generated
// colors.json (READ-ONLY) so the pane re-themes with the wallpaper, falling back
// to the welcome card's static palette when the file is absent (before the first
// colour run). It NEVER writes that STATE file.

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

ApplicationWindow {
    id: root
    visible: true
    title: "Packages — Illogical Impulse"
    width: 720
    height: 640
    minimumWidth: 560
    minimumHeight: 520
    color: colors.background

    // ── theme: read generated/colors.json READ-ONLY, static fallback ─────────
    // Static fallback palette = the welcome card's constants (kept in sync so a
    // pane shown before the first colour run still looks on-brand).
    QtObject {
        id: colors
        property var palette: ({})
        function _c(key, fallback) {
            return (palette && palette[key] !== undefined && palette[key] !== "")
                ? palette[key] : fallback;
        }
        readonly property color background:       _c("background", "#1E202B")
        readonly property color surface:          _c("surface", "#23283A")
        readonly property color surfaceHigh:      _c("surface_container_high", "#282E3D")
        readonly property color mono:             _c("surface_container_lowest", "#11131A")
        readonly property color onSurface:        _c("on_surface", "#CDD6F4")
        readonly property color onSurfaceVariant: _c("on_surface_variant", "#8E95B3")
        readonly property color primary:          _c("primary", "#45DDBC")
        readonly property color onPrimary:        _c("on_primary", "#16281F")
        readonly property color outline:          _c("outline", "#3A4154")
        readonly property color error:            _c("error", "#F38BA8")
        readonly property color aurAccent:        _c("tertiary", "#F9E2AF")
    }

    // Resolve the STATE path from the environment, never a hardcoded /home.
    readonly property string colorsPath: {
        var s = Quickshell.env("XDG_STATE_HOME");
        var h = Quickshell.env("HOME");
        var base = (s && s.length > 0) ? s : ((h ? h : "") + "/.local/state");
        return base + "/quickshell/user/generated/colors.json";
    }
    FileView {
        id: colorsFile
        path: root.colorsPath
        watchChanges: true
        onFileChanged: reload()
        onLoaded: { try { colors.palette = JSON.parse(colorsFile.text()); } catch (e) { colors.palette = ({}); } }
        onLoadFailed: colors.palette = ({})
    }

    // ── state ────────────────────────────────────────────────────────────────
    property string tab: "search"          // "search" | "installed" | "updates" | "orphans"
    property var    results: []            // parsed rows for the current view
    property string queryText: ""
    property bool   loading: false
    property string loadError: ""
    property var    selected: null        // the row whose detail drawer is open

    // Console (install/remove/clean) overlay state — mirrors the welcome card.
    property bool   consoleOpen: false
    property string runTitle: ""
    property bool   busy: false
    property bool   finished: false
    property int    exitCode: -1
    property string toastText: ""
    property bool   toastError: false

    // ── read helpers: run `iictl pkg … --json`, parse into `results` ─────────
    function runQuery(argv) {
        root.loading = true; root.loadError = ""; root.selected = null;
        reader.buffer = "";
        reader.command = ["iictl", "pkg"].concat(argv).concat(["--json"]);
        reader.running = true;
    }
    function refresh() {
        if (root.tab === "search") {
            if (root.queryText.trim().length === 0) { root.results = []; root.loading = false; return; }
            runQuery(["search", root.queryText.trim()]);
        } else if (root.tab === "installed") {
            runQuery(["list", "explicit"]);
        } else if (root.tab === "updates") {
            runQuery(["list", "updates"]);
        } else if (root.tab === "orphans") {
            runQuery(["list", "orphans"]);
        }
    }
    Process {
        id: reader
        property string buffer: ""
        stdout: SplitParser { splitMarker: ""; onRead: data => reader.buffer += data }
        onRunningChanged: {
            if (!reader.running) {
                root.loading = false;
                try {
                    root.results = JSON.parse(reader.buffer.length ? reader.buffer : "[]");
                } catch (e) {
                    root.results = [];
                    root.loadError = "Could not read package data (is iictl on PATH?)";
                }
            }
        }
    }

    // ── action console: stream `iictl pkg install|remove|clean` in-window ────
    function runAction(title, argv) {
        root.runTitle = title;
        root.consoleOpen = true;
        root.busy = true; root.finished = false; root.exitCode = -1;
        outArea.text = "";
        // NO_COLOR/TERM keep output ANSI-free; a trailing sentinel reports the real
        // rc through the stream (completion never depends on a signal race).
        var joined = argv.map(function (a) { return "'" + String(a).replace(/'/g, "'\\''") + "'"; }).join(" ");
        var payload = "export NO_COLOR=1 TERM=dumb; iictl pkg " + joined
                    + " 2>&1; printf '\\n__IICTL_RC:%d\\n' \"$?\"";
        proc.command = ["bash", "-c", payload];
        proc.running = true;
    }
    function appendChunk(line) {
        if (line.indexOf("__IICTL_RC:") === 0) {
            root.exitCode = parseInt(line.substring("__IICTL_RC:".length)) || 0;
            return;
        }
        outArea.text += line + "\n";
        outFlick.contentY = Math.max(0, outArea.implicitHeight - outFlick.height);
    }
    Process {
        id: proc
        stdout: SplitParser { onRead: data => root.appendChunk(data) }
        stderr: SplitParser { onRead: data => root.appendChunk(data) }
        onRunningChanged: {
            if (!proc.running) {
                root.busy = false; root.finished = true;
                root.toastError = (root.exitCode !== 0);
                root.toastText = (root.exitCode === 0) ? "Done." : "Failed (exit " + root.exitCode + ").";
                toastTimer.restart();
                root.refresh();   // reflect the new installed/removed state
            }
        }
    }
    Timer { id: toastTimer; interval: 3500; onTriggered: root.toastText = "" }

    Component.onCompleted: root.tab = "search"

    // ── shared pill button ───────────────────────────────────────────────────
    component PillButton: Button {
        id: btn
        property bool primary: false
        property bool danger: false
        implicitHeight: 36
        opacity: enabled ? 1.0 : 0.4
        background: Rectangle {
            radius: 10
            color: btn.danger ? (btn.hovered ? Qt.lighter(colors.error, 1.1) : colors.error)
                 : btn.primary ? (btn.hovered ? Qt.lighter(colors.primary, 1.1) : colors.primary)
                 : (btn.hovered ? colors.surfaceHigh : colors.surface)
            border.color: (btn.primary || btn.danger) ? "transparent" : colors.outline
            border.width: 1
            Behavior on color { ColorAnimation { duration: 100 } }
        }
        contentItem: Text {
            text: btn.text
            color: (btn.primary || btn.danger) ? colors.onPrimary : colors.onSurface
            font.pixelSize: 13
            font.bold: btn.primary || btn.danger
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            leftPadding: 12; rightPadding: 12
        }
    }

    component TabButton: Button {
        id: tb
        property string tabId: ""
        implicitHeight: 34
        background: Rectangle {
            radius: 9
            color: root.tab === tb.tabId ? colors.primary : "transparent"
            Behavior on color { ColorAnimation { duration: 100 } }
        }
        contentItem: Text {
            text: tb.text
            color: root.tab === tb.tabId ? colors.onPrimary : colors.onSurfaceVariant
            font.pixelSize: 13
            font.bold: root.tab === tb.tabId
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            leftPadding: 14; rightPadding: 14
        }
        onClicked: { root.tab = tb.tabId; root.queryText = root.queryText; root.refresh(); }
    }

    // ==========================================================================
    // MAIN LAYOUT
    // ==========================================================================
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 18
        spacing: 12
        visible: !root.consoleOpen

        // header
        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Text {
                text: "Packages"
                color: colors.onSurface
                font.pixelSize: 22
                font.bold: true
                Layout.fillWidth: true
            }
            Text {
                text: colorsFile.text().length > 0 ? "themed" : "static theme"
                color: colors.onSurfaceVariant
                font.pixelSize: 11
            }
        }

        // tab strip
        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            TabButton { text: "Search"; tabId: "search" }
            TabButton { text: "Installed"; tabId: "installed" }
            TabButton { text: "Updates"; tabId: "updates" }
            TabButton { text: "Orphans"; tabId: "orphans" }
            Item { Layout.fillWidth: true }
            PillButton {
                text: "Clean orphans"
                visible: root.tab === "orphans" && root.results.length > 0
                onClicked: root.runAction("Remove orphaned packages", ["clean", "--yes"])
            }
        }

        // search field (search tab only)
        TextField {
            id: searchField
            Layout.fillWidth: true
            visible: root.tab === "search"
            placeholderText: "Search official repos + AUR…"
            color: colors.onSurface
            placeholderTextColor: colors.onSurfaceVariant
            selectByMouse: true
            background: Rectangle {
                radius: 9
                color: colors.surface
                border.color: searchField.activeFocus ? colors.primary : colors.outline
                border.width: 1
            }
            onTextChanged: { root.queryText = text; debounce.restart(); }
            Keys.onReturnPressed: { debounce.stop(); root.refresh(); }
        }
        Timer { id: debounce; interval: 350; onTriggered: root.refresh() }

        // results / states
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: 12
            color: colors.surface
            border.color: colors.outline
            border.width: 1

            // loading
            Text {
                anchors.centerIn: parent
                visible: root.loading
                text: "Loading…"
                color: colors.onSurfaceVariant
                font.pixelSize: 14
            }
            // error
            ColumnLayout {
                anchors.centerIn: parent
                visible: !root.loading && root.loadError.length > 0
                spacing: 8
                Text {
                    text: root.loadError
                    color: colors.error
                    font.pixelSize: 14
                    horizontalAlignment: Text.AlignHCenter
                    Layout.alignment: Qt.AlignHCenter
                }
                PillButton { text: "Retry"; Layout.alignment: Qt.AlignHCenter; onClicked: root.refresh() }
            }
            // empty
            Text {
                anchors.centerIn: parent
                visible: !root.loading && root.loadError.length === 0 && root.results.length === 0
                text: root.tab === "search"
                      ? (root.queryText.trim().length === 0 ? "Type to search official repos and the AUR."
                                                            : "No packages match “" + root.queryText.trim() + "”.")
                      : root.tab === "updates" ? "Everything is up to date."
                      : root.tab === "orphans" ? "No orphaned packages."
                      : "Nothing to show."
                color: colors.onSurfaceVariant
                font.pixelSize: 14
                width: parent.width - 40
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }

            // list
            ListView {
                id: list
                anchors.fill: parent
                anchors.margins: 6
                clip: true
                visible: !root.loading && root.loadError.length === 0 && root.results.length > 0
                model: root.results
                spacing: 4
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: Rectangle {
                    width: list.width
                    height: rowCol.implicitHeight + 16
                    radius: 8
                    color: rowMouse.containsMouse ? colors.surfaceHigh : "transparent"
                    property var row: modelData

                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.selected = (root.selected === row ? null : row)
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 10

                        ColumnLayout {
                            id: rowCol
                            Layout.fillWidth: true
                            spacing: 2
                            RowLayout {
                                spacing: 8
                                Text {
                                    text: row.name || ""
                                    color: colors.onSurface
                                    font.pixelSize: 14
                                    font.bold: true
                                }
                                // source badge
                                Rectangle {
                                    visible: (row.source || "") .length > 0
                                    radius: 5
                                    color: (row.source === "aur") ? Qt.alpha(colors.aurAccent, 0.18) : Qt.alpha(colors.primary, 0.15)
                                    implicitWidth: srcTxt.implicitWidth + 12
                                    implicitHeight: srcTxt.implicitHeight + 4
                                    Text {
                                        id: srcTxt
                                        anchors.centerIn: parent
                                        text: (row.source === "aur") ? "AUR" : (row.repo || row.source || "repo")
                                        color: (row.source === "aur") ? colors.aurAccent : colors.primary
                                        font.pixelSize: 10
                                        font.bold: true
                                    }
                                }
                                Text {
                                    visible: row.installed === true
                                    text: "installed"
                                    color: colors.primary
                                    font.pixelSize: 11
                                }
                                Text {
                                    visible: row.protected === true
                                    text: "protected"
                                    color: colors.error
                                    font.pixelSize: 11
                                }
                            }
                            Text {
                                text: row.description || (row.new_version ? ("→ " + row.new_version) : (row.version || ""))
                                color: colors.onSurfaceVariant
                                font.pixelSize: 12
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                visible: text.length > 0
                            }
                        }

                        // per-row action
                        PillButton {
                            text: (row.installed === true) ? "Remove" : "Install"
                            primary: row.installed !== true
                            danger: row.installed === true
                            Layout.preferredWidth: 92
                            visible: !!row.name && root.tab !== "updates"
                            onClicked: {
                                if (row.installed === true)
                                    root.runAction("Remove " + row.name, ["remove", row.name]);
                                else
                                    root.runAction("Install " + row.name, ["install", row.name]);
                            }
                        }
                        PillButton {
                            text: "Update"
                            primary: true
                            Layout.preferredWidth: 92
                            visible: root.tab === "updates"
                            onClicked: root.runAction("Update " + row.name, ["install", row.name])
                        }
                    }
                }
            }
        }

        // detail drawer (a collapsible strip under the list)
        Rectangle {
            Layout.fillWidth: true
            visible: root.selected !== null
            radius: 10
            color: colors.mono
            border.color: colors.outline
            border.width: 1
            implicitHeight: detailCol.implicitHeight + 20
            ColumnLayout {
                id: detailCol
                anchors.fill: parent
                anchors.margins: 10
                spacing: 4
                Text {
                    text: (root.selected ? (root.selected.name || "") : "") + "  " + (root.selected ? (root.selected.version || "") : "")
                    color: colors.onSurface
                    font.pixelSize: 14
                    font.bold: true
                }
                Text {
                    text: root.selected ? (root.selected.description || "") : ""
                    color: colors.onSurfaceVariant
                    font.pixelSize: 12
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    visible: text.length > 0
                }
            }
        }

        // status line + toast
        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Text {
                Layout.fillWidth: true
                text: {
                    var n = root.results.length;
                    if (root.loading) return "";
                    if (root.tab === "search") return n > 0 ? (n + " result" + (n === 1 ? "" : "s")) : "";
                    if (root.tab === "installed") return n + " explicitly-installed";
                    if (root.tab === "updates") return n > 0 ? (n + " update" + (n === 1 ? "" : "s") + " available") : "";
                    if (root.tab === "orphans") return n > 0 ? (n + " orphan" + (n === 1 ? "" : "s")) : "";
                    return "";
                }
                color: colors.onSurfaceVariant
                font.pixelSize: 12
            }
            Text {
                text: root.toastText
                color: root.toastError ? colors.error : colors.primary
                font.pixelSize: 12
                font.bold: true
                visible: root.toastText.length > 0
            }
        }
    }

    // ==========================================================================
    // ACTION CONSOLE OVERLAY (install / remove / clean)
    // ==========================================================================
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 18
        spacing: 12
        visible: root.consoleOpen

        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Text {
                text: root.runTitle
                color: colors.onSurface
                font.pixelSize: 18
                font.bold: true
                Layout.fillWidth: true
                elide: Text.ElideRight
            }
            BusyIndicator {
                running: root.busy
                visible: root.busy
                implicitWidth: 22; implicitHeight: 22
            }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: colors.outline }

        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: 10
            color: colors.mono
            border.color: colors.outline
            border.width: 1
            Flickable {
                id: outFlick
                anchors.fill: parent
                anchors.margins: 10
                clip: true
                contentWidth: outArea.implicitWidth
                contentHeight: outArea.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }
                TextEdit {
                    id: outArea
                    readOnly: true
                    selectByMouse: true
                    wrapMode: TextEdit.NoWrap
                    textFormat: TextEdit.PlainText
                    color: colors.onSurface
                    font.family: "monospace"
                    font.pixelSize: 12
                    text: ""
                }
            }
            Text {
                anchors.centerIn: parent
                visible: outArea.text.length === 0 && root.busy
                text: "Starting…"
                color: colors.onSurfaceVariant
                font.pixelSize: 13
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Text {
                Layout.fillWidth: true
                color: root.busy ? colors.onSurfaceVariant : (root.exitCode === 0 ? colors.primary : colors.error)
                font.pixelSize: 13
                text: root.busy ? "Working…"
                    : root.finished ? (root.exitCode === 0 ? "Done." : "Failed (exit " + root.exitCode + ").")
                    : ""
            }
            PillButton {
                text: "Back"
                Layout.preferredWidth: 110
                enabled: !root.busy
                onClicked: { root.consoleOpen = false; root.finished = false; }
            }
        }
    }
}
