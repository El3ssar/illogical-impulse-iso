pragma Singleton

// Illogical Impulse — Control Center Material You theme singleton (issue #14).
//
// Watches upstream's generated palette at
//   $XDG_STATE_HOME/quickshell/user/generated/colors.json
// (matugen output). That path is upstream-owned runtime STATE — READ-ONLY: we
// FileView-watch it and NEVER write it (PROPOSAL §3; CLAUDE.md §"Historic bugs").
// When it is missing or unreadable we fall back to a static palette (the welcome
// card's literal hex constants, kept in sync with control/panes/Packages.qml) so
// the app still renders on-brand before the first wallpaper/colour run.
//
// This is the exact pattern the widget framework's _lib/Theme.qml uses; the
// Control Center keeps its own copy so it stays a standalone config with ZERO
// imports from upstream's quickshell/ii tree.

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    // Parsed colors.json object ({} until/unless the file loads). `live` is true
    // once a real palette is in hand (panes show a "themed" vs "static" hint).
    property var palette: ({})
    readonly property bool live: root.palette && Object.keys(root.palette).length > 0

    // Resolve the STATE path from the environment, never a hardcoded /home.
    readonly property string colorsPath: {
        var s = Quickshell.env("XDG_STATE_HOME");
        var h = Quickshell.env("HOME");
        var base = (s && s.length > 0) ? s : ((h ? h : "") + "/.local/state");
        return base + "/quickshell/user/generated/colors.json";
    }

    // _c(key, fallback) — a palette role with a static fallback. Reading
    // root.palette inside the binding makes every colour re-evaluate live when the
    // watched file changes (QML tracks the property read through the call).
    function _c(key, fallback) {
        return (root.palette && root.palette[key] !== undefined && root.palette[key] !== "")
            ? root.palette[key] : fallback;
    }

    // Curated named roles → Material You keys, each with a welcome-card fallback.
    readonly property color background:       _c("background", "#1E202B")
    readonly property color surface:          _c("surface", "#23283A")
    readonly property color surfaceLow:       _c("surface_container", "#191B24")
    readonly property color surfaceHigh:      _c("surface_container_high", "#282E3D")
    readonly property color mono:             _c("surface_container_lowest", "#11131A")
    readonly property color onSurface:        _c("on_surface", "#CDD6F4")
    readonly property color onSurfaceVariant: _c("on_surface_variant", "#8E95B3")
    readonly property color primary:          _c("primary", "#45DDBC")
    readonly property color onPrimary:        _c("on_primary", "#16281F")
    readonly property color outline:          _c("outline", "#3A4154")
    readonly property color error:            _c("error", "#F38BA8")
    readonly property color secondary:        _c("secondary", "#A6ADC8")
    readonly property color tertiary:         _c("tertiary", "#F9E2AF")

    function _parse(t) {
        try { root.palette = JSON.parse(t); }
        catch (e) { root.palette = ({}); }
    }

    // FileView watches the palette and re-parses on change. READ-ONLY: no write
    // path here, ever. A missing/unreadable file leaves the static fallback.
    FileView {
        id: colorsFile
        path: root.colorsPath
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root._parse(colorsFile.text())
        onLoadFailed: root.palette = ({})
    }
}
