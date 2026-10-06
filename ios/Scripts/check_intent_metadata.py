#!/usr/bin/env python3
"""Fail the build when the App Intents metadata names an Apple product.

App Store Connect reads every intent's title, description and Siri phrase out of
Metadata.appintents/extract.actionsdata after the upload, and rejects the build when
one names an Apple product (ITMS-90626 "Invalid Siri Support ... cannot contain
"mac""). altool still says UPLOAD SUCCEEDED; the build just never appears. Squelch
build 1.0 (3) was lost that way to "on your Mac" in three intent
descriptions. This reads the same file before the upload, so the run stops here.

Only the text people see is checked: the "key" and "defaultValue" of each localized
string. Type names, identifiers and symbol names are not.

Pure logic in find_product_names (Scripts/test_check_intent_metadata.py).

Usage:
  check_intent_metadata.py <Squelch.app>   (checks the app and every extension in it)
"""
from __future__ import annotations

import json
import pathlib
import re
import sys

# Whole words, any case: Apple's check reported "mac" for "Mac".
PRODUCT_NAMES = [
    "Apple", "Siri", "iPhone", "iPad", "iPod", "Mac", "MacBook", "iMac", "macOS", "iOS", "iPadOS",
    "watchOS", "visionOS", "tvOS", "AirPods", "FaceTime", "HomePod", "iCloud", "iMessage", "CarPlay",
]
PATTERN = re.compile(r"\b(" + "|".join(PRODUCT_NAMES) + r")\b", re.IGNORECASE)
TEXT_FIELDS = {"key", "defaultValue"}


def find_product_names(metadata: dict) -> list[str]:
    """One line per user-facing string that names an Apple product: '<path>: <text>'."""
    found = []

    def walk(node, path):
        if isinstance(node, dict):
            for k, v in node.items():
                if isinstance(v, str):
                    if k in TEXT_FIELDS and PATTERN.search(v):
                        found.append(f"{path}.{k}: {v}")
                else:
                    walk(v, f"{path}.{k}")
        elif isinstance(node, list):
            for i, v in enumerate(node):
                if isinstance(v, str):
                    continue
                walk(v, f"{path}[{i}]")

    walk(metadata, "")
    return found


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    files = sorted(pathlib.Path(argv[0]).glob("**/Metadata.appintents/extract.actionsdata"))
    if not files:
        print(f"::error::no App Intents metadata under {argv[0]}")
        return 1
    bad = 0
    for f in files:
        hits = find_product_names(json.loads(f.read_text()))
        for h in hits:
            print(f"::error title=Apple product name in App Intents metadata::{f.parent.parent.name} {h}")
        bad += len(hits)
        print(f"{f.parent.parent.name}: {'no' if not hits else len(hits)} Apple product names in intent text")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
