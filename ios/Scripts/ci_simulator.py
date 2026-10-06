#!/usr/bin/env python3
"""Prints the udid of the simulator the view tests run on: an iPhone or an iPad on the
newest iOS runtime the machine has. The CI Mac carries whatever Xcode it
was last updated to, so the workflows ask for a kind of device, not a model and OS."""
import json
import subprocess
import sys

PREFERRED = {"iphone": ["Pro Max", "Pro", ""], "ipad": ["Pro 13", "Pro", ""]}


def runtime_version(key):
    # com.apple.CoreSimulator.SimRuntime.iOS-27-0 -> (27, 0)
    tail = key.rsplit(".", 1)[-1]
    if not tail.startswith("iOS-"):
        return None
    try:
        return tuple(int(p) for p in tail[4:].split("-"))
    except ValueError:
        return None


def pick(devices, kind):
    prefix = "iPhone" if kind == "iphone" else "iPad"
    runtimes = sorted(
        ((runtime_version(k), v) for k, v in devices.items() if runtime_version(k)),
        key=lambda pair: pair[0],
        reverse=True,
    )
    for _, listed in runtimes:
        found = [d for d in listed if d.get("isAvailable", True) and d["name"].startswith(prefix)]
        for hint in PREFERRED[kind]:
            for device in found:
                if hint in device["name"]:
                    return device["udid"]
    return None


def main():
    kind = sys.argv[1] if len(sys.argv) > 1 else "iphone"
    if kind not in PREFERRED:
        sys.exit(f"usage: ci_simulator.py iphone|ipad (got {kind})")
    listing = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "-j"],
        check=True, capture_output=True, text=True,
    ).stdout
    udid = pick(json.loads(listing)["devices"], kind)
    if not udid:
        sys.exit(f"no available {kind} simulator")
    print(udid)


if __name__ == "__main__":
    main()
