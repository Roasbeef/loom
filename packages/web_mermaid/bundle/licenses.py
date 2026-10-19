#!/usr/bin/env python3
"""Collect notices from the locked production dependencies without network access.

Usage: licenses.py OUTPUT. Run after npm ci --ignore-scripts. The release keeps
these notices beside the isolated renderer; ordinary checks verify the stamped
artifact and do not need node_modules or Python package dependencies.
"""

import json
from pathlib import Path
import sys


def notices(root):
    lock = json.loads((root / "package-lock.json").read_text())
    sections = ["Third-party notices for Loom's isolated Mermaid renderer.\n"]
    for relative in sorted(lock["packages"]):
        if not relative:
            continue
        parts = Path(relative).parts
        if parts[0] != "node_modules" or ".." in parts:
            raise ValueError("dependency path is outside node_modules")
        directory = root / relative
        metadata = json.loads((directory / "package.json").read_text())
        license_files = sorted(
            (p for p in directory.iterdir() if p.is_file() and p.name.upper().startswith(
                ("LICENSE", "LICENCE", "COPYING", "NOTICE", "COPYRIGHT")
            )),
            key=lambda p: p.name,
        )
        if not license_files:
            raise ValueError(f"{relative} has no shipped license notice")
        label = f"{metadata['name']} {metadata['version']}"
        sections.append(f"\n{'=' * 72}\n{label}\nLicense: {metadata.get('license', 'see notices')}\n")
        for path in license_files:
            sections.append(f"\n--- {path.name} ---\n{path.read_text(encoding='utf-8')}\n")
    return "".join(sections)


if __name__ == "__main__":
    root = Path(__file__).resolve().parent
    Path(sys.argv[1]).write_text(notices(root), encoding="utf-8")
