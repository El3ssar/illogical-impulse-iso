// SpecForm — the generic renderer for the iictl chooser contract
// (`iictl <domain> --spec`, the choice/list/toggle schema shared with the
// iictl-tui ratatui renderer; BLUEPRINT §"iictl chooser contract"). It draws a
// domain's configurable surface as native GUI controls and applies every pick by
// shelling out to the domain's own `iictl` verb — so it mutates NOTHING itself;
// each change flows through the bash verb and the ledger (reversible by design).
//
// This is why a whole class of panes (Shell, Editor, Plugins, Dev Packs, Theme,
// Terminal…) is one tiny file: `SpecForm { domain: "shell" }`. Adding a control
// to a domain's spec surfaces it here for free — CLI/GUI parity is structural.
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

Item {
    id: form
    property string domain: ""
    property string heading: ""
    property string blurb: ""

    property var spec: null
    property bool loading: true
    property string error: ""
    readonly property var controls: (spec && spec.controls) ? spec.controls : []

    Component.onCompleted: reload()
    onDomainChanged: reload()

    function reload() {
        form.loading = true; form.error = "";
        Ctl.spec(form.domain,
            function (obj) { form.spec = obj; form.loading = false; form.error = ""; },
            function (msg) { form.error = msg; form.loading = false; });
    }

    // Shell-quote one argv token for the bash payload the Console runs.
    function _shq(a) { return "'" + String(a).replace(/'/g, "'\\''") + "'"; }

    // Run an apply* argv (with %v/%s substituted) through the streaming Console.
    function apply(argv, value, source, title) {
        var subst = (argv || []).map(function (t) {
            t = String(t).split("%v").join(value === undefined ? "" : value);
            if (source !== undefined && source !== null) t = t.split("%s").join(source);
            return t;
        });
        var cmd = "iictl " + subst.map(form._shq).join(" ");
        consoleOverlay.run(cmd, title || (form.heading.length ? form.heading : form.domain));
    }

    // ── main content (hidden while the action console is open) ────────────────
    ColumnLayout {
        anchors.fill: parent
        spacing: 14
        visible: !consoleOverlay.open

        // header
        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                Text {
                    text: form.heading.length ? form.heading
                        : (form.spec && form.spec.title ? form.spec.title : form.domain)
                    color: Colors.onSurface
                    font.pixelSize: 22
                    font.bold: true
                }
                Text {
                    text: form.blurb
                    visible: form.blurb.length > 0
                    color: Colors.onSurfaceVariant
                    font.pixelSize: 12
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                }
            }
            Text {
                text: Colors.live ? "themed" : "static theme"
                color: Colors.onSurfaceVariant
                font.pixelSize: 11
            }
            PillButton {
                text: "Refresh"
                glyph: "refresh"
                enabled: !form.loading
                onClicked: form.reload()
            }
        }

        // states
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            // loading
            RowLayout {
                anchors.centerIn: parent
                visible: form.loading
                spacing: 10
                Spinner { size: 22; running: form.loading }
                Text { text: "Loading…"; color: Colors.onSurfaceVariant; font.pixelSize: 14 }
            }

            // error
            ErrorState {
                anchors.centerIn: parent
                width: Math.min(parent.width - 40, 460)
                visible: !form.loading && form.error.length > 0
                message: "Could not read " + form.domain + " settings.\n" + form.error
                onRetry: form.reload()
            }

            // empty
            EmptyState {
                anchors.centerIn: parent
                width: Math.min(parent.width - 40, 460)
                visible: !form.loading && form.error.length === 0 && form.controls.length === 0
                glyph: "tune"
                message: "This domain exposes no configurable options yet."
            }

            // content
            Flickable {
                anchors.fill: parent
                visible: !form.loading && form.error.length === 0 && form.controls.length > 0
                clip: true
                contentWidth: width
                contentHeight: controlsCol.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                ColumnLayout {
                    id: controlsCol
                    width: parent.width
                    spacing: 18

                    Repeater {
                        model: form.controls
                        delegate: ColumnLayout {
                            id: ctrlRoot
                            required property var modelData
                            readonly property var ctrl: modelData
                            Layout.fillWidth: true
                            spacing: 8

                            // per-list local state (dynamic candidates)
                            property string pickedSource: (ctrl.sources && ctrl.sources.length) ? ctrl.sources[0] : ""
                            property var cands: []
                            property bool candLoading: false
                            property string candError: ""

                            function _has(arr, v) {
                                if (!arr) return false;
                                for (var i = 0; i < arr.length; ++i) if (arr[i] === v) return true;
                                return false;
                            }
                            function loadCandidates() {
                                if (!ctrl.candidates || !ctrl.candidates.length) return;
                                ctrlRoot.candLoading = true; ctrlRoot.candError = "";
                                var argv = ctrl.candidates.map(function (t) {
                                    return String(t).split("%s").join(ctrlRoot.pickedSource);
                                });
                                Ctl.text(argv, function (txt) {
                                    var out = [];
                                    var lines = String(txt).split("\n");
                                    for (var i = 0; i < lines.length; ++i) {
                                        var l = lines[i].trim();
                                        if (l.length && l.indexOf("#") !== 0) out.push(l);
                                    }
                                    ctrlRoot.cands = out;
                                    ctrlRoot.candLoading = false;
                                });
                            }

                            // control label
                            Text {
                                text: ctrl.label || ctrl.id || ""
                                color: Colors.onSurface
                                font.pixelSize: 15
                                font.bold: true
                                visible: text.length > 0
                            }

                            // ── CHOICE ────────────────────────────────────────
                            Flow {
                                Layout.fillWidth: true
                                visible: ctrl.type === "choice"
                                spacing: 8
                                Repeater {
                                    model: ctrl.type === "choice" ? ctrl.options : []
                                    delegate: PillButton {
                                        required property var modelData
                                        readonly property bool isCurrent: modelData.value === ctrl.current
                                        text: (modelData.label && modelData.label.length) ? modelData.label : modelData.value
                                        primary: isCurrent
                                        glyph: isCurrent ? "check" : ""
                                        onClicked: {
                                            if (isCurrent) return;
                                            form.apply(ctrl.apply, modelData.value, null,
                                                       (ctrl.label || form.domain) + " → " + text);
                                        }
                                    }
                                }
                            }

                            // ── TOGGLE ────────────────────────────────────────
                            Toggle {
                                Layout.fillWidth: true
                                visible: ctrl.type === "toggle"
                                label: ctrl.label || ctrl.id || ""
                                checked: ctrl.current === true
                                onToggled: function (value) {
                                    form.apply(value ? ctrl.apply_on : ctrl.apply_off, "", null,
                                               (ctrl.label || form.domain) + (value ? " → on" : " → off"));
                                }
                            }

                            // ── LIST ──────────────────────────────────────────
                            ColumnLayout {
                                Layout.fillWidth: true
                                visible: ctrl.type === "list"
                                spacing: 8

                                // current members (removable)
                                Text {
                                    text: "Enabled"
                                    color: Colors.onSurfaceVariant
                                    font.pixelSize: 12
                                    visible: ctrl.type === "list"
                                }
                                Text {
                                    text: "None yet."
                                    color: Colors.onSurfaceVariant
                                    font.pixelSize: 12
                                    visible: ctrl.type === "list" && (!ctrl.current || ctrl.current.length === 0)
                                }
                                Repeater {
                                    model: ctrl.type === "list" ? (ctrl.current || []) : []
                                    delegate: ListRow {
                                        required property var modelData
                                        title: modelData
                                        PillButton {
                                            text: "Remove"
                                            danger: true
                                            Layout.preferredWidth: 96
                                            onClicked: form.apply(ctrl.apply_remove, modelData, null,
                                                                  "Remove " + modelData)
                                        }
                                    }
                                }

                                Rectangle { Layout.fillWidth: true; height: 1; color: Colors.outline; opacity: 0.5 }

                                // add from inline options (options not already enabled)
                                Text {
                                    text: "Add"
                                    color: Colors.onSurfaceVariant
                                    font.pixelSize: 12
                                    visible: ctrl.type === "list" && ctrl.options && ctrl.options.length > 0
                                }
                                Repeater {
                                    model: (ctrl.type === "list" && ctrl.options) ? ctrl.options : []
                                    delegate: ListRow {
                                        required property var modelData
                                        visible: !ctrlRoot._has(ctrl.current, modelData.value)
                                        title: (modelData.label && modelData.label.length) ? modelData.label : modelData.value
                                        PillButton {
                                            text: "Add"
                                            primary: true
                                            Layout.preferredWidth: 96
                                            onClicked: form.apply(ctrl.apply_add, modelData.value, null,
                                                                  "Add " + title)
                                        }
                                    }
                                }

                                // add from dynamic candidates (source-driven, #48)
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    visible: ctrl.type === "list" && ctrl.candidates && ctrl.candidates.length > 0

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8
                                        Text { text: "Source:"; color: Colors.onSurfaceVariant; font.pixelSize: 12 }
                                        Flow {
                                            Layout.fillWidth: true
                                            spacing: 6
                                            Repeater {
                                                model: ctrl.sources || []
                                                delegate: PillButton {
                                                    required property var modelData
                                                    text: modelData
                                                    primary: modelData === ctrlRoot.pickedSource
                                                    onClicked: { ctrlRoot.pickedSource = modelData; ctrlRoot.cands = []; }
                                                }
                                            }
                                        }
                                        PillButton {
                                            text: "Browse"
                                            glyph: "search"
                                            enabled: !ctrlRoot.candLoading
                                            onClicked: ctrlRoot.loadCandidates()
                                        }
                                    }
                                    RowLayout {
                                        visible: ctrlRoot.candLoading
                                        spacing: 8
                                        Spinner { size: 18; running: ctrlRoot.candLoading }
                                        Text { text: "Loading candidates…"; color: Colors.onSurfaceVariant; font.pixelSize: 12 }
                                    }
                                    Repeater {
                                        model: ctrlRoot.cands
                                        delegate: ListRow {
                                            required property var modelData
                                            visible: !ctrlRoot._has(ctrl.current, modelData)
                                            title: modelData
                                            PillButton {
                                                text: "Add"
                                                primary: true
                                                Layout.preferredWidth: 96
                                                onClicked: form.apply(ctrl.apply_add, modelData, ctrlRoot.pickedSource,
                                                                      "Add " + modelData)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ── streaming action console overlay ──────────────────────────────────────
    Console {
        id: consoleOverlay
        anchors.fill: parent
        onDone: function (code) {
            toast.show(code === 0 ? "Done." : "Failed (exit " + code + ").", code !== 0);
            form.reload();   // reflect the new state
        }
    }

    // ── toast ─────────────────────────────────────────────────────────────────
    Toast {
        id: toast
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 16
    }
}
