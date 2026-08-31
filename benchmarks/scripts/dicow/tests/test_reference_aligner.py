from __future__ import annotations

import copy
import hashlib
import json
import tempfile
import unittest
from unittest import mock
from pathlib import Path

from benchmarks.scripts.dicow.aligner.qwen_reference import (
    AlignerError,
    MODEL_ID,
    MODEL_REVISION,
    canonical_json_hash,
    execute_batch,
    require_consistent_repetitions,
    snapshot_tree_hash,
    verify_t9_snapshot,
    validate_manifest,
    validate_result_set,
)


class ReferenceAlignerTests(unittest.TestCase):
    def make_manifest(self, root: Path):
        rows = []
        families = ["hike"] * 12 + ["fleurs-en"] * 8 + ["fleurs-it"] * 8
        languages = ["Korean"] * 12 + ["English"] * 8 + ["Italian"] * 8
        for index, (family, language) in enumerate(zip(families, languages)):
            audio = root / f"audio-{index}.wav"
            audio.write_bytes(f"audio-{index}".encode())
            rows.append({
                "row_id": f"row-{index}",
                "family": family,
                "audio_path": str(audio),
                "audio_sha256": hashlib.sha256(audio.read_bytes()).hexdigest(),
                "source_samples": 16_000,
                "text": "hello world",
                "language": language,
            })
        manifest = {"model_id": MODEL_ID, "model_revision": MODEL_REVISION, "rows": rows}
        manifest["manifest_sha256"] = canonical_json_hash(manifest)
        return manifest

    def generate(self, audio, text, language):
        return ["hello", "world"], [
            {"text": "hello", "start_s": 0.1, "end_s": 0.3},
            {"text": "world", "start_s": 0.4, "end_s": 0.8},
        ]

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.snapshot = self.root / "snapshot"
        self.snapshot.mkdir()
        (self.snapshot / "config.json").write_text("{}")
        self.manifest = self.make_manifest(self.root)

    def tearDown(self):
        self.temporary.cleanup()

    def result(self):
        return execute_batch(self.manifest, self.snapshot, self.generate)

    def test_exact_28_row_order_round_trips(self):
        rows = validate_manifest(self.manifest)
        self.assertEqual(len(rows), 28)
        result = self.result()
        self.assertEqual(len(validate_result_set(self.manifest, result)), 28)

    def test_partial_duplicate_and_reordered_results_rejected(self):
        base = self.result()
        mutations = []
        partial = copy.deepcopy(base)
        partial["results"].pop()
        mutations.append(partial)
        duplicate = copy.deepcopy(base)
        duplicate["results"][1] = duplicate["results"][0]
        mutations.append(duplicate)
        reordered = copy.deepcopy(base)
        reordered["results"][0], reordered["results"][1] = reordered["results"][1], reordered["results"][0]
        mutations.append(reordered)
        for value in mutations:
            with self.subTest(), self.assertRaises(AlignerError):
                validate_result_set(self.manifest, value)

    def test_alignment_mismatch_nonfinite_nonmonotone_and_out_of_bounds_rejected(self):
        field_values = (
            ("text", "different"),
            ("start_s", float("nan")),
            ("start_s", 0.9),
            ("end_s", 1.1),
        )
        for field, value in field_values:
            result = self.result()
            result["results"][0]["words"][1][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(AlignerError):
                validate_result_set(self.manifest, result)

    def test_wrong_input_and_audio_hash_rejected(self):
        result = self.result()
        result["input_manifest_sha256"] = "0" * 64
        with self.assertRaisesRegex(AlignerError, "manifest"):
            validate_result_set(self.manifest, result)
        result = self.result()
        result["results"][0]["audio_sha256"] = "0" * 64
        with self.assertRaisesRegex(AlignerError, "audio"):
            validate_result_set(self.manifest, result)

    def test_two_repetitions_must_be_structurally_consistent_and_fresh(self):
        first = self.result()
        second = copy.deepcopy(first)
        with self.assertRaisesRegex(AlignerError, "fresh"):
            require_consistent_repetitions(first, second)
        second["process_id"] += 1
        require_consistent_repetitions(first, second)
        second["results"][0]["words"][0]["end_s"] = 0.2
        require_consistent_repetitions(first, second)
        second["results"][0]["normalized_units"][0] = "changed"
        with self.assertRaisesRegex(AlignerError, "normalized_units"):
            require_consistent_repetitions(first, second)

    def test_repetition_snapshot_path_and_hash_must_match(self):
        first = self.result()
        second = copy.deepcopy(first)
        second["process_id"] += 1
        second["snapshot_sha256"] = "0" * 64
        with self.assertRaisesRegex(AlignerError, "snapshot_sha256"):
            require_consistent_repetitions(first, second)

    def test_changed_snapshot_hash_is_observable(self):
        before = snapshot_tree_hash(self.snapshot)
        (self.snapshot / "config.json").write_text('{"changed":true}')
        self.assertNotEqual(before, snapshot_tree_hash(self.snapshot))

    def test_t9_snapshot_binding_rejects_substitution(self):
        from benchmarks.scripts.dicow.common.preflight import artifact_record

        preflight = self.root / "e0-preflight"
        attempt = preflight / "attempts" / ("a" * 64 + "-0001")
        attempt.mkdir(parents=True)
        (self.snapshot / "config.json").chmod(0o444)
        self.snapshot.chmod(0o555)
        canonical = {
            "schema_version": "dicow-e0-preflight-v1",
            "run_id": "synthetic-run",
            "run_root": str(preflight.parent),
            "attempt_fingerprint": "a" * 64,
            "attempt_root": str(attempt),
            "runtime_bindings": {
                "aligner": {
                    "model_id": MODEL_ID,
                    "model_revision": MODEL_REVISION,
                    "snapshot": {"path": str(self.snapshot), "record": artifact_record(self.snapshot, immutable=True)},
                },
                "community1": {},
            },
        }
        (preflight / "canonical.json").write_text(json.dumps(canonical))
        with mock.patch.dict(__import__("os").environ, {"DICOW_RUN_ID": "synthetic-run", "DICOW_RUN_ROOT": str(preflight.parent)}):
            verify_t9_snapshot(preflight, self.snapshot)
        substitute = self.root / "substitute"
        substitute.mkdir()
        (substitute / "config.json").write_text("{}")
        with mock.patch.dict(__import__("os").environ, {"DICOW_RUN_ID": "synthetic-run", "DICOW_RUN_ROOT": str(preflight.parent)}), \
             self.assertRaisesRegex(AlignerError, "path"):
            verify_t9_snapshot(preflight, substitute)

    def test_manifest_rejects_family_reorder_and_wrong_model(self):
        reordered = copy.deepcopy(self.manifest)
        reordered["rows"][0]["family"] = "fleurs-en"
        reordered["manifest_sha256"] = canonical_json_hash({key: value for key, value in reordered.items() if key != "manifest_sha256"})
        with self.assertRaisesRegex(AlignerError, "order"):
            validate_manifest(reordered)
        wrong = copy.deepcopy(self.manifest)
        wrong["model_revision"] = "bad"
        with self.assertRaisesRegex(AlignerError, "model"):
            validate_manifest(wrong)


if __name__ == "__main__":
    unittest.main()
