from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from unittest import mock
from pathlib import Path
import hashlib

from benchmarks.scripts.dicow.diarizer.community1_reference import (
    CommunityError,
    command_for,
    freeze_mapping,
    merge_segments,
    parse_segments,
    rasterize,
    run_process,
    trailing_json_object,
    validate_elapsed,
    verify_runtime,
    tree_hash,
)


class JSONAndRasterTests(unittest.TestCase):
    def output(self, segments):
        return "cold-load log\n" + json.dumps({"segments": segments}) + "\n"

    def test_unique_trailing_json_after_logs(self):
        value = trailing_json_object('log {not json}\n{"segments": []}\n')
        self.assertEqual(value, {"segments": []})

    def test_malformed_or_multiple_trailing_object_rejected(self):
        with self.assertRaises(CommunityError):
            trailing_json_object("not json")
        with self.assertRaises(CommunityError):
            parse_segments('{"wrong": []}')
        with self.assertRaisesRegex(CommunityError, "duplicate"):
            parse_segments('{"segments":[{"speaker":"a","speaker":"b","start":0,"end":1}]}')

    def test_clip_merge_and_label_canonicalization(self):
        segments = parse_segments(self.output([
            {"speaker": 1, "start": -1, "end": 0.5},
            {"speaker": "1", "start": 0.4, "end": 1.0},
            {"speaker": 2, "start": 29.9, "end": 31},
        ]))
        merged = merge_segments(segments)
        self.assertEqual([(item.label, item.start_s, item.end_s) for item in merged], [("1", 0.0, 1.0), ("2", 29.9, 30.0)])

    def test_nan_reversed_and_wholly_out_of_range_rejected(self):
        bad = (
            {"speaker": "a", "start": float("nan"), "end": 1},
            {"speaker": "a", "start": 2, "end": 1},
            {"speaker": "a", "start": 31, "end": 32},
        )
        for segment in bad:
            with self.subTest(segment=segment), self.assertRaises(CommunityError):
                parse_segments(self.output([segment]))

    def test_frame_center_rule(self):
        segments = parse_segments(self.output([{"speaker": "a", "start": 0.01, "end": 0.03}]))
        labels, raster = rasterize(segments)
        self.assertEqual(labels, ("a",))
        self.assertEqual(raster[0][0], 1)  # center 0.01 is included
        self.assertEqual(raster[0][1], 0)  # center 0.03 is excluded

    def test_subframe_label_without_positive_activity_is_not_real(self):
        segments = parse_segments(self.output([{"speaker": "ghost", "start": 0.011, "end": 0.019}]))
        labels, raster = rasterize(segments)
        self.assertEqual(labels, ())
        self.assertEqual(raster, [])


class MappingTests(unittest.TestCase):
    def refs(self):
        return [[1, 1, 0, 0], [0, 0, 1, 1]]

    def test_zero_labels_produces_two_distinct_absent_slots(self):
        result = freeze_mapping([], [], ["A", "B"], self.refs())
        self.assertEqual([slot["status"] for slot in result["slots"]], ["ABSENT", "ABSENT"])
        self.assertNotEqual(result["slots"][0]["provider_label"], result["slots"][1]["provider_label"])

    def test_one_label_maps_to_max_overlap_and_keeps_denominator(self):
        result = freeze_mapping(["x"], [[0, 0, 1, 1]], ["A", "B"], self.refs())
        self.assertEqual(result["slots"][0]["status"], "ABSENT")
        self.assertEqual(result["slots"][1]["provider_label"], "x")
        self.assertTrue(result["diarizer_undercount"])

    def test_two_labels_use_injective_activity_mapping(self):
        result = freeze_mapping(["z", "a"], [[0, 0, 1, 1], [1, 1, 0, 0]], ["A", "B"], self.refs())
        self.assertEqual([slot["provider_label"] for slot in result["slots"]], ["a", "z"])
        self.assertEqual(result["surplus"], [])

    def test_three_labels_preserve_surplus(self):
        result = freeze_mapping(["x", "y", "surplus"], [[1, 1, 0, 0], [0, 0, 1, 1], [0, 1, 0, 0]], ["A", "B"], self.refs())
        self.assertEqual(result["surplus"], ["surplus"])
        self.assertTrue(result["diarizer_overcount"])

    def test_tie_break_is_stable_under_reordered_provider_ids(self):
        left = freeze_mapping(["b", "a"], [[1, 0], [1, 0]], ["A", "B"], [[1, 0], [0, 1]])
        right = freeze_mapping(["a", "b"], [[1, 0], [1, 0]], ["A", "B"], [[1, 0], [0, 1]])
        self.assertEqual([slot["provider_label"] for slot in left["slots"]], [slot["provider_label"] for slot in right["slots"]])

    def test_tie_break_orders_label_then_reference_id(self):
        result = freeze_mapping(["b", "a"], [[1, 1], [1, 1]], ["Z", "A"], [[1, 1], [1, 1]])
        assignments = {slot["reference_id"]: slot["provider_label"] for slot in result["slots"]}
        self.assertEqual(assignments, {"A": "a", "Z": "b"})


class ProcessTests(unittest.TestCase):
    class FakeProcess:
        returncode = 0
        def __init__(self, *args, **kwargs):
            self.killed = False
        def communicate(self, timeout=None):
            return ('{"segments": []}', "")
        def kill(self):
            self.killed = True

    def test_command_has_no_network_capability_or_known_speaker_count(self):
        command = command_for(Path("/tmp/speech"), Path("/tmp/audio.wav"))
        self.assertEqual(command[0], "/usr/bin/sandbox-exec")
        self.assertIn("--min-speakers", command)
        self.assertNotIn("--max-speakers", command)
        self.assertNotIn("http", " ".join(command))
        profile = Path("benchmarks/scripts/dicow/diarizer/deny-network.sb").read_text()
        self.assertIn("(deny network*)", profile)

    def test_timeout_boundaries_239_240_241(self):
        validate_elapsed(239)
        validate_elapsed(240)
        with self.assertRaisesRegex(CommunityError, "timeout"):
            validate_elapsed(241)

    def test_fake_process_clock_at_240_is_accepted(self):
        values = iter((10.0, 250.0))
        result = run_process(Path("/tmp/speech"), Path("/tmp/a.wav"), popen_factory=self.FakeProcess, clock=lambda: next(values))
        self.assertEqual(result.elapsed_s, 240.0)

    def test_wrong_runtime_or_model_identity_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "canonical.json").write_text(json.dumps({"schema_version": "wrong"}))
            with self.assertRaisesRegex(CommunityError, "shape"):
                verify_runtime(root)

    def test_runtime_binds_exact_model_tree_and_detects_mutation(self):
        from benchmarks.scripts.dicow.common.preflight import artifact_record

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            attempt = root / "attempts" / ("a" * 64 + "-0001")
            attempt.mkdir(parents=True)
            runtime_root = root / "speech-runtime"
            runtime_root.mkdir()
            binary = runtime_root / "speech"
            sandbox = Path("benchmarks/scripts/dicow/diarizer/deny-network.sb").resolve()
            model = root / "community-model"
            binary.write_bytes(b"binary")
            model.mkdir()
            (model / "weights.bin").write_bytes(b"weights")
            binary.chmod(0o555)
            (model / "weights.bin").chmod(0o444)
            model.chmod(0o555)
            community = {
                "model_id": "aufklarer/Pyannote-Community-1-CoreML",
                "model_revision": "a14e6c420d56e8472850649b016a486fd0acbe81",
                "binary": {"path": str(binary), "record": artifact_record(binary, immutable=True)},
                "sandbox_profile": {"path": str(sandbox), "record": artifact_record(sandbox)},
                "model_tree": {"path": str(model), "record": artifact_record(model, immutable=True)},
            }
            canonical = {
                "schema_version": "dicow-e0-preflight-v1", "run_id": "synthetic-run", "run_root": str(root.parent),
                "attempt_fingerprint": "a" * 64,
                "attempt_root": str(attempt), "paths": {"community_snapshot": str(model)},
                "mlx_reused_symbols": [], "mlx_implementation_source": "test", "inspection_sha256": "b" * 64,
                "inspection_outcome": "evidence_blocker", "inspection_verdict": "revise", "inspection_blocker": "test",
                "runtime_bindings": {"aligner": {}, "community1": community}, "resource": {}, "resource_policy": {},
                "future_resource_ledger": {},
                "host": {}, "acquisitions": {}, "promotion_records": {},
                "promotion_final_paths": {"speech-runtime": str(runtime_root)}, "promotion_staged_paths": {},
            }
            (root / "canonical.json").write_text(json.dumps(canonical))
            with mock.patch.dict(
                __import__("os").environ,
                {"DICOW_RUN_ID": "synthetic-run", "DICOW_RUN_ROOT": str(root.parent)},
            ):
                verify_runtime(root)
                model.chmod(0o755)
                (model / "weights.bin").chmod(0o644)
                (model / "weights.bin").write_bytes(b"changed")
                with self.assertRaisesRegex(CommunityError, "model_tree"):
                    verify_runtime(root)

    def test_runtime_rejects_duplicate_and_nonfinite_canonical_json(self):
        for payload in ('{"schema_version":"x","schema_version":"y"}', '{"value":NaN}'):
            with self.subTest(payload=payload), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "canonical.json").write_text(payload)
                with self.assertRaisesRegex(CommunityError, "invalid JSON"):
                    verify_runtime(root)

    def test_live_sandbox_denies_tcp_and_udp(self):
        profile = Path("benchmarks/scripts/dicow/diarizer/deny-network.sb").resolve()
        snippets = (
            "import socket; socket.socket().connect(('127.0.0.1',9))",
            "import socket; socket.socket(socket.AF_INET,socket.SOCK_DGRAM).bind(('127.0.0.1',0))",
        )
        for snippet in snippets:
            result = subprocess.run(
                ["/usr/bin/sandbox-exec", "-f", str(profile), "/usr/bin/python3", "-c", snippet],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not permitted", result.stderr.casefold())


if __name__ == "__main__":
    unittest.main()
