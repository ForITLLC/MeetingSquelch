"""Tests for Scripts/check_intent_metadata.py — App Intents text must not name an
Apple product, or App Store Connect drops the build after the upload (ITMS-90626)."""
import contextlib
import io
import json
import pathlib
import tempfile
import unittest

import check_intent_metadata as cim


def action(description, title="Toggle Mute"):
    """The shape xcode-tools 27A266a writes for one intent in extract.actionsdata."""
    return {
        "descriptionMetadata": {"descriptionText": {"key": description}},
        "title": {"key": title},
        "fullyQualifiedTypeName": "Squelch.ToggleMuteIntent",
        "mangledTypeName": "7Squelch16ToggleMuteIntentV",
        "identifier": "ToggleMuteIntent",
    }


class FindProductNamesTests(unittest.TestCase):
    def test_flags_the_descriptions_apple_rejected_in_build_3(self):
        meta = {"actions": {"ToggleMuteIntent": action("Mutes or unmutes you in the call on your Mac.")}}
        hits = cim.find_product_names(meta)
        self.assertEqual(len(hits), 1)
        self.assertIn("descriptionText.key", hits[0])

    def test_any_case_and_other_products(self):
        for text in ["on your mac", "ask SIRI", "from your iPhone", "in macOS", "with Apple Watch"]:
            self.assertTrue(cim.find_product_names({"t": {"key": text}}), text)

    def test_whole_words_only(self):
        for text in ["Turns your camera on or off", "Command + M", "the machine", "Macro", "pineapple"]:
            self.assertEqual(cim.find_product_names({"t": {"key": text}}), [], text)

    def test_type_names_and_identifiers_are_not_text(self):
        meta = {"actions": {"MacIntent": {"identifier": "Mac", "fullyQualifiedTypeName": "Squelch.Mac",
                                          "systemImageName": "macbook", "title": {"key": "Toggle Mute"}}}}
        self.assertEqual(cim.find_product_names(meta), [])

    def test_phrases_in_lists(self):
        meta = {"autoShortcuts": [{"phraseTemplates": [{"key": "${applicationName} mute"},
                                                       {"key": "Mute my Mac with ${applicationName}"}]}]}
        hits = cim.find_product_names(meta)
        self.assertEqual(len(hits), 1)
        self.assertIn("phraseTemplates[1]", hits[0])


SOURCE = """
struct ToggleMuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Mute"
}
struct GetCallStatusIntent: AppIntent {}
struct CallStatus: AppEntity {}
// struct OldIntent: AppIntent {}
"""


class MissingActionsTests(unittest.TestCase):
    def test_every_intent_listed_passes(self):
        meta = {"actions": {"ToggleMuteIntent": {}, "GetCallStatusIntent": {}}}
        self.assertEqual(cim.missing_actions(meta, [SOURCE]), [])

    def test_an_intent_the_metadata_lacks_is_named(self):
        meta = {"actions": {"ToggleMuteIntent": {}}}
        self.assertEqual(cim.missing_actions(meta, [SOURCE]), ["GetCallStatusIntent"])

    def test_no_metadata_misses_them_all(self):
        self.assertEqual(cim.missing_actions({}, [SOURCE]), ["GetCallStatusIntent", "ToggleMuteIntent"])


class MainTests(unittest.TestCase):
    def run_main(self, app_meta, appex_meta, source=None):
        with tempfile.TemporaryDirectory() as d:
            for rel, meta in [("Squelch.app", app_meta), ("Squelch.app/PlugIns/SquelchControls.appex", appex_meta)]:
                p = pathlib.Path(d, rel, "Metadata.appintents")
                p.mkdir(parents=True)
                (p / "extract.actionsdata").write_text(json.dumps(meta))
            args = [str(pathlib.Path(d, "Squelch.app"))]
            if source is not None:
                pathlib.Path(d, "Intents.swift").write_text(source)
                args.append(str(pathlib.Path(d, "Intents.swift")))
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = cim.main(args)
        return code, out.getvalue()

    def test_clean_app_passes(self):
        clean = {"actions": {"ToggleMuteIntent": action("Mutes or unmutes you in the call on your computer.")}}
        code, out = self.run_main(clean, clean)
        self.assertEqual(code, 0)
        self.assertNotIn("::error", out)

    def test_a_name_in_the_extension_fails_the_step(self):
        clean = {"actions": {"ToggleMuteIntent": action("Mutes or unmutes you in the call on your computer.")}}
        bad = {"actions": {"ToggleMuteIntent": action("Leaves the call on your Mac.")}}
        code, out = self.run_main(clean, bad)
        self.assertEqual(code, 1)
        self.assertIn("::error title=Apple product name in App Intents metadata::SquelchControls.appex", out)

    def test_an_intent_missing_from_the_app_fails_the_step(self):
        app = {"actions": {"ToggleMuteIntent": action("Mutes or unmutes you in the call on your computer.")}}
        both = {"actions": {"ToggleMuteIntent": app["actions"]["ToggleMuteIntent"], "GetCallStatusIntent": {}}}
        code, out = self.run_main(app, both, SOURCE)
        self.assertEqual(code, 1)
        self.assertIn("::error title=Intent missing from App Intents metadata::Squelch.app has no action "
                      "GetCallStatusIntent", out)

    def test_every_intent_in_the_app_passes_and_is_listed(self):
        both = {"actions": {"ToggleMuteIntent": action("Mutes or unmutes you in the call on your computer."),
                            "GetCallStatusIntent": {}}}
        code, out = self.run_main(both, {"actions": {}}, SOURCE)
        self.assertEqual(code, 0, out)
        self.assertIn("Squelch.app: no Apple product names in intent text; actions: GetCallStatusIntent ToggleMuteIntent", out)

    def test_no_metadata_is_an_error(self):
        with tempfile.TemporaryDirectory() as d, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cim.main([d]), 1)


if __name__ == "__main__":
    unittest.main()
