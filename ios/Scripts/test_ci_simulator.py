import unittest

from ci_simulator import pick

DEVICES = {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [
        {"name": "iPhone 17 Pro Max", "udid": "OLD-PHONE", "isAvailable": True},
        {"name": "iPad Pro 13-inch (M4)", "udid": "OLD-PAD", "isAvailable": True},
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
        {"name": "iPhone 17", "udid": "PLAIN", "isAvailable": True},
        {"name": "iPhone 18 Pro Max", "udid": "NEW-PHONE", "isAvailable": True},
        {"name": "iPad mini (A17 Pro)", "udid": "MINI-PAD", "isAvailable": True},
        {"name": "iPad Pro 13-inch (M5)", "udid": "NEW-PAD", "isAvailable": True},
    ],
    "com.apple.CoreSimulator.SimRuntime.watchOS-12-0": [
        {"name": "Apple Watch", "udid": "WATCH", "isAvailable": True},
    ],
}


class PickTests(unittest.TestCase):
    def test_the_newest_runtime_and_the_biggest_iphone(self):
        self.assertEqual(pick(DEVICES, "iphone"), "NEW-PHONE")

    def test_the_newest_runtime_and_the_biggest_ipad(self):
        self.assertEqual(pick(DEVICES, "ipad"), "NEW-PAD")

    def test_an_older_runtime_when_the_newest_has_none_of_that_kind(self):
        devices = {k: [d for d in v if "iPad" not in d["name"] or "26" in k] for k, v in DEVICES.items()}
        self.assertEqual(pick(devices, "ipad"), "OLD-PAD")

    def test_none_when_there_is_no_such_device(self):
        self.assertIsNone(pick({"com.apple.CoreSimulator.SimRuntime.watchOS-12-0": []}, "iphone"))


if __name__ == "__main__":
    unittest.main()
