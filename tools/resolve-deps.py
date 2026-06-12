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

# Hardcoded — these are upstream illogical-impulse meta-packages always present
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


def find_pkgbuilds(root: Path) -> list[Path]:
    pkgs = [p for name in METAPKGS
            if (p := root / name / "PKGBUILD").is_file()]
    for sub in root.rglob("PKGBUILD"):
        if sub in pkgs or any(part.startswith(".") for part in sub.parts):
            continue
        if re.search(r"^package\s*\(\)", sub.read_text(), re.MULTILINE):
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
    content = re.sub(r"#[^\n]*", "", content)
    m = re.search(r"depends\s*=\s*\((.*?)\)", content, re.DOTALL)
    if not m:
        return []
    out = []
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

    # Pass 1: which PKGBUILDs are locally buildable
    for pb in pkgbuilds:
        content = pb.read_text()
        name = parse_pkgname(content)
        if name and re.search(r"^package\s*\(\)", content, re.MULTILINE):
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
