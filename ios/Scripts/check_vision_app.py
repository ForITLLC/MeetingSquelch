#!/usr/bin/env python3
"""Fail the build when Squelch.app built for Apple Vision Pro isn't the native visionOS app.

Native means built against the visionOS SDK: DTPlatformName xros (xrsimulator in the
simulator) and UIDeviceFamily [7]. The iPhone binary in "Designed for iPhone" mode says
iphoneos and [1]. The Controls extension has no visionOS form, so the app carries no
PlugIns, and the Apple Watch app belongs to the iPhone, so it carries no Watch/ either. The layered icon (AppIcon-Vision) must have reached the bundle: without it the
visionOS Info.plist has no CFBundleIcons (for-iCommon docs/visionos.md, step 4). The App
Intents metadata must be there, as in the iPhone build.

Pure logic in problems() (Scripts/test_check_vision_app.py).

Usage:
  check_vision_app.py <Squelch.app> xros|xrsimulator
"""
from __future__ import annotations

import pathlib
import plistlib
import sys


def problems(info: dict, platform: str, has_plugins: bool, has_intents: bool, has_watch: bool = False) -> list[str]:
    """What is wrong with a visionOS app bundle, one line each; empty when it is right."""
    out = []
    if info.get("DTPlatformName") != platform:
        out.append(f"DTPlatformName is {info.get('DTPlatformName')!r}, not {platform!r}")
    if info.get("UIDeviceFamily") != [7]:
        out.append(f"UIDeviceFamily is {info.get('UIDeviceFamily')!r}, not [7]")
    if has_plugins:
        out.append("the app has PlugIns: the Controls extension belongs to the iPhone build only")
    if has_watch:
        out.append("the app has Watch/: the Apple Watch app belongs to the iPhone build only")
    if "CFBundleIcons" not in info:
        out.append("no CFBundleIcons: the visionOS icon (AppIcon-Vision) did not reach the bundle")
    if not has_intents:
        out.append("no Metadata.appintents in the app")
    return out


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[2] not in ("xros", "xrsimulator"):
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    app = pathlib.Path(argv[1])
    with open(app / "Info.plist", "rb") as f:
        info = plistlib.load(f)
    found = problems(info, argv[2], (app / "PlugIns").exists(), (app / "Metadata.appintents").is_dir(),
                     (app / "Watch").exists())
    for p in found:
        print(f"::error::{app.name} for visionOS: {p}")
    if not found:
        print(f"{app.name}: native visionOS ({argv[2]}, UIDeviceFamily [7]), no PlugIns or Watch, icon and App Intents in")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
