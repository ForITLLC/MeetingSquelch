#!/usr/bin/env python3
"""Fail the build when Squelch.app built for iPhone and iPad is missing a platform.

The one app runs on iPhone and iPad: UIDeviceFamily [1, 2], and on iPad every orientation, which
Split View and Stage Manager need and App Store Connect checks (for-iCommon docs/ipad.md). The
Controls extension is [1, 2] too. The Apple Watch app sits in Watch/SquelchWatch.app: built for
watchOS (DTPlatformName watchos, watchsimulator in the simulator), family [4], with the phone as
its companion, its icon compiled in, and the same version and build number as the phone, or
App Store Connect refuses the upload (task 80C907B2).

Pure logic in problems() (Scripts/test_check_phone_app.py).

Usage:
  check_phone_app.py <Squelch.app> iphoneos|iphonesimulator
"""
from __future__ import annotations

import pathlib
import plistlib
import sys
from typing import Optional

COMPANION = "io.forit.squelch"
WATCH_ID = "io.forit.squelch.watchkitapp"
IPAD_ORIENTATIONS = {
    "UIInterfaceOrientationPortrait",
    "UIInterfaceOrientationPortraitUpsideDown",
    "UIInterfaceOrientationLandscapeLeft",
    "UIInterfaceOrientationLandscapeRight",
}
WATCH_PLATFORM = {"iphoneos": "watchos", "iphonesimulator": "watchsimulator"}


def problems(app: dict, platform: str, controls: Optional[dict], watch: Optional[dict],
             watch_has_assets: bool) -> list[str]:
    """What is wrong with the phone app bundle, one line each; empty when it is right."""
    out = []
    if app.get("DTPlatformName") != platform:
        out.append(f"DTPlatformName is {app.get('DTPlatformName')!r}, not {platform!r}")
    if app.get("UIDeviceFamily") != [1, 2]:
        out.append(f"UIDeviceFamily is {app.get('UIDeviceFamily')!r}, not [1, 2] (iPhone and iPad)")
    missing = IPAD_ORIENTATIONS - set(app.get("UISupportedInterfaceOrientations~ipad") or [])
    if missing:
        out.append(f"iPad orientations missing: {', '.join(sorted(missing))}")
    if controls is None:
        out.append("no PlugIns/SquelchControls.appex")
    elif controls.get("UIDeviceFamily") != [1, 2]:
        out.append(f"the Controls extension's UIDeviceFamily is {controls.get('UIDeviceFamily')!r}, not [1, 2]")
    if watch is None:
        out.append("no Watch/SquelchWatch.app: the Apple Watch app is not embedded")
        return out
    want = WATCH_PLATFORM[platform]
    if watch.get("DTPlatformName") != want:
        out.append(f"the Watch app's DTPlatformName is {watch.get('DTPlatformName')!r}, not {want!r}")
    if watch.get("CFBundleIdentifier") != WATCH_ID:
        out.append(f"the Watch app's bundle id is {watch.get('CFBundleIdentifier')!r}, not {WATCH_ID!r}")
    if watch.get("UIDeviceFamily") != [4]:
        out.append(f"the Watch app's UIDeviceFamily is {watch.get('UIDeviceFamily')!r}, not [4]")
    if watch.get("WKApplication") is not True:
        out.append("the Watch app has no WKApplication = true")
    if watch.get("WKCompanionAppBundleIdentifier") != COMPANION:
        out.append(f"the Watch app's companion is {watch.get('WKCompanionAppBundleIdentifier')!r}, not {COMPANION!r}")
    for k in ("CFBundleShortVersionString", "CFBundleVersion"):
        if watch.get(k) != app.get(k):
            out.append(f"the Watch app's {k} is {watch.get(k)!r}, the phone's {app.get(k)!r}")
    if not watch_has_assets:
        out.append("the Watch app has no Assets.car: its icon did not compile in")
    return out


def _plist(path: pathlib.Path) -> Optional[dict]:
    if not path.is_file():
        return None
    with open(path, "rb") as f:
        return plistlib.load(f)


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[2] not in WATCH_PLATFORM:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    app = pathlib.Path(argv[1])
    watch = app / "Watch" / "SquelchWatch.app"
    found = problems(_plist(app / "Info.plist") or {}, argv[2],
                     _plist(app / "PlugIns" / "SquelchControls.appex" / "Info.plist"),
                     _plist(watch / "Info.plist"), (watch / "Assets.car").is_file())
    for p in found:
        print(f"::error::{app.name} for {argv[2]}: {p}")
    if not found:
        print(f"{app.name}: iPhone and iPad ({argv[2]}, every iPad orientation), Controls for both, "
              f"and the Apple Watch app ({WATCH_PLATFORM[argv[2]]}) with the same version and build")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
