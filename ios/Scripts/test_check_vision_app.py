"""Tests for Scripts/check_vision_app.py: is the Apple Vision Pro build the native visionOS app?"""
import unittest

from check_vision_app import problems

NATIVE = {"DTPlatformName": "xros", "UIDeviceFamily": [7], "CFBundleIcons": {"CFBundlePrimaryIcon": {}}}


class ProblemsTest(unittest.TestCase):
    def test_native_build_passes(self):
        self.assertEqual(problems(NATIVE, "xros", has_plugins=False, has_intents=True), [])

    def test_simulator_build_passes_as_xrsimulator(self):
        info = dict(NATIVE, DTPlatformName="xrsimulator")
        self.assertEqual(problems(info, "xrsimulator", has_plugins=False, has_intents=True), [])

    def test_designed_for_iphone_binary_fails(self):
        info = dict(NATIVE, DTPlatformName="iphoneos", UIDeviceFamily=[1])
        found = problems(info, "xros", has_plugins=False, has_intents=True)
        self.assertEqual(len(found), 2)
        self.assertIn("'iphoneos'", found[0])
        self.assertIn("[1]", found[1])

    def test_iphone_and_vision_family_fails(self):
        info = dict(NATIVE, UIDeviceFamily=[1, 7])
        self.assertEqual(len(problems(info, "xros", has_plugins=False, has_intents=True)), 1)

    def test_embedded_controls_extension_fails(self):
        found = problems(NATIVE, "xros", has_plugins=True, has_intents=True)
        self.assertEqual(len(found), 1)
        self.assertIn("PlugIns", found[0])

    def test_embedded_watch_app_fails(self):
        found = problems(NATIVE, "xros", has_plugins=False, has_intents=True, has_watch=True)
        self.assertEqual(len(found), 1)
        self.assertIn("Watch/", found[0])

    def test_missing_icon_fails(self):
        info = {k: v for k, v in NATIVE.items() if k != "CFBundleIcons"}
        found = problems(info, "xros", has_plugins=False, has_intents=True)
        self.assertEqual(len(found), 1)
        self.assertIn("AppIcon-Vision", found[0])

    def test_missing_intents_fails(self):
        found = problems(NATIVE, "xros", has_plugins=False, has_intents=False)
        self.assertEqual(found, ["no Metadata.appintents in the app"])


if __name__ == "__main__":
    unittest.main()
