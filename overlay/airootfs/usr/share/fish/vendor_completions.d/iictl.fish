# iictl(1) fish completion — Illogical Impulse distro CLI.
#
# Distro-owned system file (NOT a user dotfile): lives under
# /usr/share/fish/vendor_completions.d/, auto-loaded by fish's vendor
# completion mechanism. Additive + reversible: deleting this file simply stops
# offering iictl completions; it edits no user config and no upstream path.
#
# Plugin verbs are discovered DYNAMICALLY from /usr/local/lib/ii/iictl.d/ at
# completion time, with each verb's #help: header as its description — drop a
# new iictl.d/<verb> file in and it tab-completes here with no edit.

# A verb is being completed only when no verb has been given yet (first token).
function __iictl_needs_command
    set -l cmd (commandline -opc)
    test (count $cmd) -eq 1
end

# Emit "verb<TAB>description" for every executable iictl.d/ plugin, reading the
# #help: header (its own tab-separated "verb<TAB>desc") for the description.
function __iictl_plugin_verbs
    set -l dir /usr/local/lib/ii/iictl.d
    test -d $dir; or return 0
    for f in $dir/*
        test -x "$f" -a -f "$f"; or continue
        set -l verb (basename $f)
        # #help: line is "#help:<sep>verb<sep>description"; take the trailing
        # description after the verb token. Fall back to the bare verb.
        set -l hl (string match -r '^#help:\s+\S+\s+(.+)$' < $f | tail -1)
        if test (count $hl) -ge 2
            printf '%s\t%s\n' $verb $hl[2]
        else
            printf '%s\n' $verb
        end
    end
end

# Built-in verbs (mirror the iictl case-arms / #help: block) with descriptions.
complete -c iictl -f -n __iictl_needs_command -a update  -d 'update the dots (./setup); --system upgrades repos+AUR first'
complete -c iictl -f -n __iictl_needs_command -a doctor  -d 'health checks (venv, greetd, boot, pacman)'
complete -c iictl -f -n __iictl_needs_command -a venv    -d 'rebuild the Quickshell python venv'
complete -c iictl -f -n __iictl_needs_command -a welcome -d 'show the distro welcome card'
complete -c iictl -f -n __iictl_needs_command -a version -d 'distro build + dots commit'
complete -c iictl -f -n __iictl_needs_command -a help    -d 'show grouped help'

# Dynamic plugin verbs (with #help: descriptions).
complete -c iictl -f -n __iictl_needs_command -a '(__iictl_plugin_verbs)'

# Well-known built-in flags (second token).
complete -c iictl -f -n '__fish_seen_subcommand_from update'  -a '--system --check'
complete -c iictl -f -n '__fish_seen_subcommand_from welcome' -a '--auto'
