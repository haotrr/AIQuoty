#!/usr/bin/env python3
"""Fail CI when AIQuoty.xcodeproj has conflicting object IDs or missing app sources."""

from __future__ import annotations

import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PBX = ROOT / "AIQuoty.xcodeproj" / "project.pbxproj"
APP_SOURCES = ROOT / "Apps" / "AIQuoty" / "Sources"
APP_SOURCES_PHASE_ID = "FA8F9B785702BD7EFB786A8B"


def main() -> int:
    if not PBX.is_file():
        print(f"ERROR: missing {PBX}", file=sys.stderr)
        return 1

    text = PBX.read_text(encoding="utf-8")
    errors: list[str] = []

    definitions: dict[str, list[str]] = defaultdict(list)
    for match in re.finditer(
        r"^[\t ]*([0-9A-F]{24})\s*/\*[^*]*\*/\s*=\s*\{isa\s*=\s*([^;]+);",
        text,
        re.M,
    ):
        definitions[match.group(1)].append(match.group(0).strip())

    for object_id, lines in sorted(definitions.items()):
        if len(lines) > 1:
            errors.append(
                f"Conflicting PBX object ID {object_id} defined {len(lines)} times:\n"
                + "\n".join(f"  - {line}" for line in lines)
            )

    phase = re.search(
        rf"{APP_SOURCES_PHASE_ID} /\* Sources \*/ = \{{.*?files = \((.*?)\);",
        text,
        re.S,
    )
    if phase is None:
        errors.append(f"Could not find AIQuoty Sources build phase {APP_SOURCES_PHASE_ID}")
        compiled: list[str] = []
    else:
        compiled = [
            match.group(1)
            for match in re.finditer(r"/\* ([^*]+?) in Sources \*/", phase.group(1))
        ]

    on_disk = sorted(path.name for path in APP_SOURCES.rglob("*.swift"))
    missing = [name for name in on_disk if name not in compiled]
    if missing:
        errors.append(
            "App Swift files present on disk but missing from AIQuoty Xcode Sources phase:\n"
            + "\n".join(f"  - {name}" for name in missing)
        )

    extras = [name for name in compiled if name not in on_disk]
    if extras:
        errors.append(
            "AIQuoty Xcode Sources phase lists Swift files that are not on disk:\n"
            + "\n".join(f"  - {name}" for name in extras)
        )

    if "LocalWebDashboardServer.swift" not in compiled:
        errors.append("LocalWebDashboardServer.swift is not in the AIQuoty target Sources phase")

    if errors:
        print("AIQuoty.xcodeproj validation failed:", file=sys.stderr)
        for error in errors:
            print(error, file=sys.stderr)
            print(file=sys.stderr)
        return 1

    print(
        "AIQuoty.xcodeproj OK: "
        f"{len(compiled)} app sources, no conflicting object IDs"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
