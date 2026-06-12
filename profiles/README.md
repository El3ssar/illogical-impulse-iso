# Profiles — your personal layer

A profile bakes *your* stuff on top of the public distro:
`just build <name>` reads `profiles/<name>/` and produces your personal ISO.
Profiles are **git-ignored** (only this README ships) — they're yours,
machine-local, never published.

## Anatomy

```
profiles/<name>/
├── packages.list   # extra packages baked into your ISO (official or AUR,
│                   # classified automatically; one per line, # comments)
├── skel/           # dotfiles merged into /etc/skel LAST (wins over the
│                   # distro layer and upstream dots) — path-mirrors $HOME
└── fetch.list      # pinned git repos cloned into the skel at build time:
                    #   <dest-relative-to-skel> <git-url> <commit-sha>
                    # e.g.:
                    #   .config/nvim  https://github.com/you/nvim-config  abc1234…
```

All three files are optional. Start with:

```sh
mkdir -p profiles/mine/skel
echo "obsidian" > profiles/mine/packages.list
just build mine
```

Full layering rules and vendoring patterns: [docs/GUIDE.md](../docs/GUIDE.md) §4.
