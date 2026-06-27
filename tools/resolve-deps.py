#!/usr/bin/env python3
"""
Scrape upstream/illogical-impulse/sdata/dist-arch/*/PKGBUILD into three lists
under <outdir>/:
    official.list       — packages found in Arch pacman -Si
    aur-prebuild.list   — packages NOT in Arch repos (AUR or local PKGBUILD)
    local-dirs.list     — directories of locally-shippable PKGBUILDs
    local-names.list    — names of locally-shippable PKGBUILDs

Usage:
    resolve-deps.py <dotfiles_root> <outdir> [packages.add]

Called by prepare.sh; also usable standalone as an audit tool.
"""

from __future__ import annotations
import os, re, subprocess, sys
from pathlib import Path

# Known-present baseline. NOT the discovery mechanism (that is structural — see
# find_pkgbuilds below) but a drift tripwire: validate.sh (BUILD-02) asserts every
# entry still resolves to a real PKGBUILD, so an upstream rename screams at build
# time instead of silently shipping a missing-dependency ISO. Discovery no longer
# depends on this list — a NEW dependency-only meta-package is picked up by its
# `illogical-impulse-` pkgname + absent package() body, not by being hand-added here.
METAPKGS = [
    "illogical-impulse-audio", "illogical-impulse-backlight",
    "illogical-impulse-basic", "illogical-impulse-fonts-themes",
    "illogical-impulse-kde", "illogical-impulse-portal",
    "illogical-impulse-python", "illogical-impulse-screencapture",
    "illogical-impulse-toolkit", "illogical-impulse-widgets",
    "illogical-impulse-hyprland",
    "illogical-impulse-microtex-git", "illogical-impulse-quickshell-git",
    "illogical-impulse-bibata-modern-classic-bin",
]

# Prefix every upstream illogical-impulse meta-package shares. A dependency-only
# meta-package (no package() body) is recognised structurally by this prefix, so
# an upstream bump that adds a new one is scraped automatically.
META_PREFIX = "illogical-impulse-"


def _has_package_body(content: str) -> bool:
    return bool(re.search(r"^\s*package\s*\(\)", content, re.MULTILINE))


def find_pkgbuilds(root: Path) -> list[Path]:
    """Every PKGBUILD whose depends must be scraped, discovered STRUCTURALLY.

    Two structural classes are collected (the hardcoded METAPKGS list is NOT a
    discovery input — it is only cross-checked by validate.sh):
      • locally-buildable PKGBUILDs   — have a package() body
      • dependency-only meta-packages — no package() body, but the pkgname
        starts with illogical-impulse- (these used to be found ONLY via the
        hardcoded list; an upstream-added one was silently dropped — BUILD-02)
    """
    pkgs: list[Path] = []
    for sub in sorted(root.rglob("PKGBUILD")):
        # Skip dot-dirs WITHIN the tree, but only relative to root — an ancestor
        # like .../.claude/worktrees/... must not poison every match (the absolute
        # path is what prepare.sh passes in).
        if any(part.startswith(".") for part in sub.relative_to(root).parts):
            continue
        content = sub.read_text()
        if _has_package_body(content):
            pkgs.append(sub)
            continue
        name = parse_pkgname(content)
        if name and name.startswith(META_PREFIX):
            pkgs.append(sub)
    return pkgs


def parse_pkgname(content: str) -> str | None:
    m = re.search(r"^pkgname\s*=\s*(.+)$", content, re.MULTILINE)
    if not m:
        return None
    raw = m.group(1).strip().strip("()\"'").split()[0].strip("\"'")
    if "$" in raw:  # $_prefix-foo style
        env = {}
        for var in ("_prefix", "_pkgname"):
            vm = re.search(rf"^{var}=(.+)$", content, re.MULTILINE)
            if vm:
                env[var] = vm.group(1).strip().strip("'\"")
        for k, v in env.items():
            raw = raw.replace(f"${k}", v)
        raw = raw.split()[0]
    return raw


def parse_depends(content: str) -> list[str]:
    """Collect runtime deps from every depends array in a PKGBUILD.

    Handles `depends=(...)`, append form `depends+=(...)`, and arch-suffixed
    arrays (`depends_x86_64=(...)`, `depends_aarch64=(...)`) — all of which are
    legitimate ways an upstream bump could declare a dependency. Tokens that
    reference a `$var` are dropped (can't resolve them reliably here).
    """
    content = re.sub(r"#[^\n]*", "", content)
    out: list[str] = []
    # depends, depends+=, depends_<arch>, depends_<arch>+=
    for m in re.finditer(
        r"\bdepends(?:_[A-Za-z0-9_]+)?\s*\+?=\s*\((.*?)\)", content, re.DOTALL
    ):
        for tok in m.group(1).split():
            tok = re.sub(r"[><=].*", "", tok.strip("'\"")).strip()
            if tok and "$" not in tok:
                out.append(tok)
    return out


def is_official(name: str) -> bool:
    return subprocess.run(["pacman", "-Si", name],
                          stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    dots_root = Path(sys.argv[1])
    outdir = Path(sys.argv[2])
    pkgadd = Path(sys.argv[3]) if len(sys.argv) > 3 else None
    pkgbuild_dir = dots_root / "sdata" / "dist-arch"
    if not pkgbuild_dir.is_dir():
        print(f"ERROR: {pkgbuild_dir} missing", file=sys.stderr)
        return 1
    outdir.mkdir(parents=True, exist_ok=True)

    local_names: set[str] = set()
    local_dirs: list[Path] = []
    all_deps: list[str] = []
    pkgbuilds = find_pkgbuilds(pkgbuild_dir)

    # Pass 1: which PKGBUILDs are locally buildable (have a package() body)
    for pb in pkgbuilds:
        content = pb.read_text()
        name = parse_pkgname(content)
        if name and _has_package_body(content):
            local_names.add(name)
            local_dirs.append(pb.parent)

    # Pass 2: collect depends from every PKGBUILD
    for pb in pkgbuilds:
        for d in parse_depends(pb.read_text()):
            if d not in local_names:
                all_deps.append(d)

    overlay: list[str] = []
    if pkgadd and pkgadd.is_file():
        overlay = [
            line.split("#", 1)[0].strip()
            for line in pkgadd.read_text().splitlines()
            if line.split("#", 1)[0].strip()
        ]

    candidates = sorted(set(all_deps) | set(overlay))
    official, aur = [], []
    if subprocess.run(["which", "pacman"],
                      stdout=subprocess.DEVNULL).returncode == 0:
        for pkg in candidates:
            if pkg in local_names:
                continue
            (official if is_official(pkg) else aur).append(pkg)
    else:
        aur.extend(pkg for pkg in candidates if pkg not in local_names)

    (outdir / "official.list").write_text("\n".join(official) + ("\n" if official else ""))
    (outdir / "aur-prebuild.list").write_text(
        "\n".join(sorted(set(aur) | local_names)) + ("\n" if aur or local_names else "")
    )
    (outdir / "local-dirs.list").write_text(
        "\n".join(str(d) for d in sorted(set(local_dirs))) + ("\n" if local_dirs else "")
    )
    (outdir / "local-names.list").write_text(
        "\n".join(sorted(local_names)) + ("\n" if local_names else "")
    )

    print(f"{len(official)} official, {len(aur)} AUR, {len(local_names)} local PKGBUILDs",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
