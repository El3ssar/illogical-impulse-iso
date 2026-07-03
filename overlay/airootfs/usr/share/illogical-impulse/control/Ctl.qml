pragma Singleton

// Illogical Impulse — Control Center command bridge (issue #14).
//
// THE single seam between the GUI and the system: every pane mutation and every
// data read goes through this object, which shells out to `iictl <verb> …`. No
// pane touches the filesystem directly, and the Control Center itself records
// NOTHING reversible — each `iictl` verb records its own ledger entry, so the
// GUI stays a thin, reversible front end (issue #14 "additive & reversible").
//
// Reads spawn their OWN transient Process (concurrent reads never collide; the
// process self-destructs on exit). Long/interactive actions (AUR builds, sudo)
// run either in the in-window Console component or, when a real TTY is wanted,
// in a detached terminal — the welcome card's execDetached(kitty …) pattern.

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: ctl

    // ── JSON reads ───────────────────────────────────────────────────────────
    // run(argv, onJson, onError): run `iictl <argv…>`, parse stdout as JSON, call
    // onJson(obj). argv is the FULL iictl arg list (the caller adds --json/--spec),
    // so this drives both `--json` data verbs and the `--spec` chooser contract.
    function run(argv, onJson, onError) {
        var full = ["iictl"].concat(argv || []);
        var p = _readerComp.createObject(ctl, {
            _argv: full, _mode: "json",
            _onOk: onJson || null, _onErr: onError || null
        });
        if (p) p.running = true;
        else if (onError) onError("Could not start iictl");
    }

    // spec(domain, onSpec, onError): convenience for the chooser contract —
    // `iictl <domain> --spec` → parsed {domain,title,controls[]} object.
    function spec(domain, onSpec, onError) {
        run([String(domain), "--spec"], onSpec, onError);
    }

    // text(argv, onText): run `iictl <argv…>` and return raw stdout text (for
    // human-readable verbs like `doctor`/`version` that emit no JSON). onText is
    // always called with whatever was captured (empty string on failure).
    function text(argv, onText) {
        var full = ["iictl"].concat(argv || []);
        var p = _readerComp.createObject(ctl, {
            _argv: full, _mode: "text", _onOk: onText || null, _onErr: null
        });
        if (p) p.running = true;
        else if (onText) onText("");
    }

    // ── launches ─────────────────────────────────────────────────────────────
    // Launch a long/interactive action in a real terminal window (visible live
    // pacman/paru output, sudo prompts). Mirrors the welcome card's pattern.
    function runInTerminal(cmd, title) {
        Quickshell.execDetached(["kitty", "--title", (title || "iictl"),
            "-e", "bash", "-lc", String(cmd) + '; echo; read -rp "Press Enter to close…"']);
    }

    // Fire-and-forget GUI launch (no terminal, no output capture).
    function runDetached(argv) { Quickshell.execDetached(argv); }

    // ── transient reader ─────────────────────────────────────────────────────
    // splitMarker:"" streams raw chunks we buffer, then parse once on exit
    // (completion never depends on a line/marker race — the welcome-card lesson).
    property Component _readerComp: Component {
        Process {
            id: rp
            property var _argv: []
            property string _mode: "json"
            property var _onOk: null
            property var _onErr: null
            property string _buf: ""
            property string _errBuf: ""
            command: rp._argv
            stdout: SplitParser { splitMarker: ""; onRead: data => rp._buf += data }
            // Capture stderr too — iictl writes its real failure reason there, so
            // the error path can surface an actionable message, not a generic one.
            stderr: SplitParser { splitMarker: ""; onRead: data => rp._errBuf += data }
            onExited: (code, status) => {
                if (rp._mode === "text") {
                    if (rp._onOk) rp._onOk(rp._buf);
                    rp.destroy();
                    return;
                }
                var obj = null, ok = (code === 0);
                if (ok) {
                    try { obj = JSON.parse(rp._buf.length ? rp._buf : "null"); }
                    catch (e) { ok = false; }
                }
                if (ok) { if (rp._onOk) rp._onOk(obj); }
                else if (rp._onErr) {
                    // prefer the stderr diagnostic, then stdout, then a generic note.
                    var msg = rp._errBuf.trim() || rp._buf.trim();
                    rp._onErr(msg.length ? msg
                        : ("iictl " + (rp._argv[1] || "") + " failed (exit " + code + ")"));
                }
                rp.destroy();
            }
        }
    }
}
