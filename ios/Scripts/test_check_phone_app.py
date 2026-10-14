"""Tests for Scripts/check_phone_app.py: does the phone build carry iPad and the Apple Watch app?"""
import unittest

from check_phone_app import IPAD_ORIENTATIONS, problems

APP = {
    "DTPlatformName": "iphoneos",
    "UIDeviceFamily": [1, 2],
    "UISupportedInterfaceOrientations~ipad": sorted(IPAD_ORIENTATIONS),
    "CFBundleShortVersionString": "1.0",
    "CFBundleVersion": "15",
}
CONTROLS = {"UIDeviceFamily": [1, 2]}
WATCH = {
    "DTPlatformName": "watchos",
    "CFBundleIdentifier": "io.forit.squelch.watchkitapp",
    "UIDeviceFamily": [4],
    "WKApplication": True,
    "WKCompanionAppBundleIdentifier": "io.forit.squelch",
    "CFBundleShortVersionString": "1.0",
    "CFBundleVersion": "15",
}


def check(app=APP, platform="iphoneos", controls=CONTROLS, watch=WATCH, assets=True):
    return problems(app, platform, controls, watch, assets)


class ProblemsTest(unittest.TestCase):
    def test_device_build_passes(self):
        self.assertEqual(check(), [])

    def test_simulator_build_passes(self):
        self.assertEqual(check(dict(APP, DTPlatformName="iphonesimulator"), "iphonesimulator",
                               watch=dict(WATCH, DTPlatformName="watchsimulator")), [])

    def test_iphone_only_fails(self):
        found = check(dict(APP, UIDeviceFamily=[1]))
        self.assertEqual(len(found), 1)
        self.assertIn("[1, 2]", found[0])

    def test_portrait_only_ipad_fails(self):
        found = check(dict(APP, **{"UISupportedInterfaceOrientations~ipad": ["UIInterfaceOrientationPortrait"]}))
        self.assertEqual(len(found), 1)
        self.assertIn("LandscapeLeft", found[0])
        self.assertNotIn("UIInterfaceOrientationPortrait,", found[0])

    def test_no_ipad_orientations_at_all_fails(self):
        app = {k: v for k, v in APP.items() if k != "UISupportedInterfaceOrientations~ipad"}
        self.assertEqual(len(check(app)), 1)

    def test_iphone_only_controls_fail(self):
        found = check(controls={"UIDeviceFamily": [1]})
        self.assertEqual(len(found), 1)
        self.assertIn("Controls", found[0])

    def test_missing_controls_fail(self):
        self.assertIn("SquelchControls.appex", check(controls=None)[0])

    def test_missing_watch_app_fails(self):
        found = check(watch=None)
        self.assertEqual(len(found), 1)
        self.assertIn("Watch/SquelchWatch.app", found[0])

    def test_watch_built_for_the_wrong_sdk_fails(self):
        found = check(watch=dict(WATCH, DTPlatformName="iphoneos"))
        self.assertEqual(len(found), 1)
        self.assertIn("'watchos'", found[0])

    def test_watch_with_another_companion_fails(self):
        found = check(watch=dict(WATCH, WKCompanionAppBundleIdentifier="io.forit.calendar"))
        self.assertEqual(len(found), 1)
        self.assertIn("companion", found[0])

    def test_watch_build_number_must_match(self):
        found = check(watch=dict(WATCH, CFBundleVersion="1"))
        self.assertEqual(len(found), 1)
        self.assertIn("CFBundleVersion", found[0])

    def test_watch_without_icon_fails(self):
        found = check(assets=False)
        self.assertEqual(len(found), 1)
        self.assertIn("Assets.car", found[0])

    def test_not_a_watch_app_fails(self):
        watch = {k: v for k, v in WATCH.items() if k != "WKApplication"}
        found = check(watch=dict(watch, UIDeviceFamily=[1]))
        self.assertEqual(len(found), 2)


if __name__ == "__main__":
    unittest.main()
