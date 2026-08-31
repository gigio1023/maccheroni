import json
import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
PACKAGE = (ROOT / "Package.swift").read_text(encoding="utf-8")
RESOLVED = json.loads((ROOT / "Package.resolved").read_text(encoding="utf-8"))
SOURCE = (
    ROOT / "Sources" / "MaccheroniOfflineSpeechRuntime" / "main.swift"
).read_text(encoding="utf-8")


class OfflineSpeechRuntimeContractTests(unittest.TestCase):
    def test_speech_swift_revision_is_exact(self):
        self.assertIn(
            'url: "https://github.com/soniqo/speech-swift.git"',
            PACKAGE,
        )
        self.assertIn(
            'revision: "c1aa219bc2284239ff6917d675a3e1978c840260"',
            PACKAGE,
        )
        self.assertNotRegex(PACKAGE, r'branch:|from:\s*"')

        speech_pin = next(
            pin for pin in RESOLVED["pins"] if pin["identity"] == "speech-swift"
        )
        self.assertEqual(
            speech_pin["state"],
            {"revision": "c1aa219bc2284239ff6917d675a3e1978c840260"},
        )

    def test_every_swiftpm_dependency_has_a_locked_revision(self):
        self.assertGreater(len(RESOLVED["pins"]), 0)
        for pin in RESOLVED["pins"]:
            self.assertRegex(pin["state"]["revision"], r"^[0-9a-f]{40}$")

    def test_model_loads_are_explicitly_offline(self):
        self.assertEqual(SOURCE.count("offlineMode: true"), 1)
        self.assertRegex(
            SOURCE,
            r"SileroVADModel\.fromPretrained\([\s\S]*?engine: \.coreml,[\s\S]*?cacheDir: arguments\.cacheDirectory,[\s\S]*?offlineMode: true",
        )
        self.assertRegex(
            SOURCE,
            r"Community1DiarizationPipeline\.fromLocal\([\s\S]*?directory: arguments\.cacheDirectory",
        )
        self.assertNotIn("Community1DiarizationPipeline.fromPretrained", SOURCE)

    def test_model_ids_are_exact(self):
        self.assertIn(
            '"aufklarer/Silero-VAD-v6.2.1-CoreML"',
            SOURCE,
        )
        self.assertIn(
            '"aufklarer/Pyannote-Community-1-CoreML"',
            SOURCE,
        )

    def test_harness_has_no_network_client(self):
        for forbidden in (
            "HubApi(",
            "URLSession",
            "downloadWeights(",
            "snapshot_download",
        ):
            self.assertNotIn(forbidden, SOURCE)

    def test_stdout_is_reserved_for_json(self):
        self.assertNotIn("print(", SOURCE)
        self.assertEqual(SOURCE.count("FileHandle.standardOutput.write"), 1)
        self.assertNotRegex(SOURCE, r"writeDiagnostic\([^\n]*error")
        self.assertIn(".prettyPrinted", SOURCE)

    def test_timestamps_preserve_stock_cli_precision(self):
        self.assertEqual(SOURCE.count("roundedSeconds("), 7)
        self.assertIn("(Double(value) * 1_000).rounded() / 1_000", SOURCE)


if __name__ == "__main__":
    unittest.main()
