#!/usr/bin/env python3
"""Copy Subversion and its non-system libraries into Mortar/Vendor/svn.

Load paths are rewritten to @loader_path so the tools run on a Mac that
does not have Homebrew installed. System libraries stay where they are.
"""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "Vendor" / "svn"
BIN_SRC = Path("/opt/homebrew/bin")
TOOLS = ["svn", "svnadmin", "svnlook", "svnversion", "svnmucc"]
SYSTEM_PREFIXES = ("/usr/lib/", "/System/", "/Library/Frameworks/")


def otool_deps(path: Path) -> list[str]:
    output = subprocess.check_output(["otool", "-L", str(path)], text=True)
    deps: list[str] = []
    for line in output.splitlines()[1:]:
        line = line.strip()
        if not line:
            continue
        deps.append(line.split(" (", 1)[0].strip())
    return deps


def is_system(dep: str) -> bool:
    return dep.startswith(SYSTEM_PREFIXES) or dep.startswith("@loader_path")


def resolve_dep(dep: str, owner: Path) -> Path | None:
    if is_system(dep) or dep.startswith("@"):
        if dep.startswith("@rpath/"):
            name = dep.split("/", 1)[1]
            for folder in (owner.parent, Path("/opt/homebrew/lib"), Path("/opt/homebrew/opt")):
                candidate = folder / name
                if candidate.exists():
                    return candidate.resolve()
            matches = list(Path("/opt/homebrew").glob(f"**/lib/{name}"))
            if matches:
                return matches[0].resolve()
        return None
    path = Path(dep)
    if path.exists():
        return path.resolve()
    return None


def main() -> int:
    if OUT.exists():
        shutil.rmtree(OUT)
    bin_dir = OUT / "bin"
    lib_dir = OUT / "lib"
    bin_dir.mkdir(parents=True)
    lib_dir.mkdir(parents=True)

    binaries = []
    for name in TOOLS:
        source = BIN_SRC / name
        if not source.exists():
            print(f"missing {source}", file=sys.stderr)
            return 1
        destination = bin_dir / name
        shutil.copy2(source, destination, follow_symlinks=True)
        destination.chmod(destination.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        binaries.append(destination)

    copied: dict[Path, Path] = {}
    pending = list(binaries)
    seen: set[Path] = set()
    while pending:
        current = pending.pop()
        if current in seen:
            continue
        seen.add(current)
        for dep in otool_deps(current):
            if dep == str(current):
                continue
            resolved = resolve_dep(dep, current)
            if resolved is None or is_system(dep):
                continue
            if resolved in copied:
                continue
            destination = lib_dir / resolved.name
            if destination.exists() and destination.resolve() != resolved:
                destination = lib_dir / f"{resolved.parent.name}-{resolved.name}"
            shutil.copy2(resolved, destination, follow_symlinks=True)
            copied[resolved] = destination
            pending.append(destination)

    def bundled_name(dep: str, owner: Path) -> str | None:
        resolved = resolve_dep(dep, owner)
        if resolved is None:
            return None
        target = copied.get(resolved)
        if target is None:
            return None
        if owner.parent == lib_dir:
            return f"@loader_path/{target.name}"
        return f"@loader_path/../lib/{target.name}"

    for path in binaries + list(copied.values()):
        if path.parent == lib_dir:
            subprocess.check_call(["install_name_tool", "-id", f"@loader_path/{path.name}", str(path)])
        for dep in otool_deps(path):
            if dep.startswith("@loader_path"):
                continue
            rewritten = bundled_name(dep, path)
            if rewritten is None:
                continue
            if dep == rewritten:
                continue
            subprocess.check_call(["install_name_tool", "-change", dep, rewritten, str(path)])
        subprocess.check_call(["codesign", "--force", "--sign", "-", str(path)], stdout=subprocess.DEVNULL)

    unresolved = []
    for path in binaries + list(copied.values()):
        for dep in otool_deps(path):
            if dep.startswith("@loader_path") or is_system(dep):
                continue
            if Path(dep).name == path.name and path.parent == lib_dir:
                continue
            unresolved.append(f"{path.name} -> {dep}")
    if unresolved:
        print("unresolved dependencies:", file=sys.stderr)
        for item in unresolved:
            print(item, file=sys.stderr)
        return 1

    bundle = ROOT / "Mortar" / "SVN.bundle"
    if bundle.exists():
        shutil.rmtree(bundle)
    shutil.copytree(OUT, bundle)
    print(f"bundled {len(binaries)} tools and {len(copied)} libraries into {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
