// Shell pane — drives `iictl shell` (issue #15) through the generic chooser
// renderer. fish stays the default; switching installs the shell if missing,
// themes it, and is fully reversible (the verb records the prior login shell).
import QtQuick
import "../_ui"

SpecForm {
    domain: "shell"
    heading: "Shell"
    blurb: "Choose your login shell. fish is the default; switching is a one-command, reversible opt-in — the target shell is installed online if missing, themed, and the prior shell is recorded."
}
