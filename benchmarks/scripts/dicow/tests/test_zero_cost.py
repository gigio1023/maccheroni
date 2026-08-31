from __future__ import annotations

import hashlib
import contextlib
import io
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from benchmarks.scripts.dicow.reference import zero_cost


def _write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


class ZeroCostTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary_root = Path(tempfile.gettempdir()).resolve()
        self.temporary = tempfile.TemporaryDirectory(dir=temporary_root)
        self.root = Path(self.temporary.name)
        self.rttm = self.root / "reference.rttm"
        self.rttm.write_text(
            "SPEAKER fixture 1 0.0 4.0 <NA> <NA> A <NA> <NA>\n"
            "SPEAKER fixture 1 2.0 4.0 <NA> <NA> B <NA> <NA>\n"
            "SPEAKER fixture 1 3.0 1.0 <NA> <NA> A <NA> <NA>\n",
            encoding="utf-8",
        )
        self.timeline = self.root / "timeline.json"
        _write_json(self.timeline, [
            {"start_s": 0.0, "end_s": 4.0, "speaker": "A"},
            {"start_s": 2.0, "end_s": 6.0, "speaker": "B"},
        ])
        self.merged = self.root / "merged.json"
        _write_json(self.merged, {
            "segments": [
                {"start_s": float(i * 2), "end_s": float(i * 2 + 2), "speaker": "0", "text": "public"}
                for i in range(45)
            ]
        })
        self.conflicts = self.root / "conflicts.json"
        _write_json(self.conflicts, [
            {"kind": "overlapping_speech", "segment_index": i, "candidates": ["0", "1"]}
            for i in range(45)
        ])
        self.model = {
            "role": "asr", "hf_model_id": "mlx-community/VibeVoice-ASR-8bit",
            "revision": "a" * 40, "quantization": "int8",
        }
        self.manifest = self.root / "manifest.json"
        _write_json(self.manifest, {"run_id": "fixture", "models": [self.model]})
        self.backend = self.root / "backend.json"
        rows = []
        for i in range(45):
            rows.extend([
                {"start_s": i * 2.0, "end_s": i * 2.0 + 1.0, "speaker": 0, "text": "secret transcript"},
                {"start_s": i * 2.0 + 1.0, "end_s": i * 2.0 + 2.0, "speaker": 1, "text": "secret transcript"},
            ])
        _write_json(self.backend, {"backend": "vibevoice", "model": self.model, "segments": rows})
        self.inputs = zero_cost.PublicInputs(
            overlap_sources=(("rttm", self.rttm), ("timeline", self.timeline)),
            conflicts=self.conflicts,
            merged_segments=self.merged,
            manifest=self.manifest,
            backend_records=(self.backend,),
            conflict_segment_indices=tuple(range(45)),
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _create(self, private: Path | None = None) -> tuple[Path, dict]:
        run = self.root / ("run-private" if private else "run")
        evidence = zero_cost.build_evidence(private, public_inputs=self.inputs)
        output = zero_cost._write_evidence(run, evidence)
        return output, evidence

    def _production_paths(self) -> tuple[dict[str, str], Path]:
        cache_root = self.root / "external-cache"
        run_root = cache_root / "runs" / "run-1"
        return {
            "DICOW_CACHE_ROOT": str(cache_root),
            "DICOW_RUN_ROOT": str(run_root),
        }, run_root / "e3-zero-cost"

    def test_overlap_measure_uses_unique_speakers_and_active_speech_denominator(self) -> None:
        result = zero_cost.overlap_measure(zero_cost._parse_rttm(self.rttm))
        self.assertEqual(result["speech_union_seconds"], 6.0)
        self.assertEqual(result["overlap_seconds"], 2.0)
        self.assertAlmostEqual(result["overlap_share_of_speech"], 1 / 3)

    def test_analyze_and_verify_with_typed_unavailable_private_review(self) -> None:
        before = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in (
            self.rttm, self.timeline, self.conflicts, self.merged, self.manifest, self.backend
        )}
        output, evidence = self._create()
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o444)
        self.assertEqual(evidence["correction_burden"]["availability"], {
            "status": "unavailable", "reason": "private_review_not_provided"
        })
        self.assertEqual(
            evidence["vibevoice_backend_probe"]["conflicts_intersecting_at_least_two_backend_speaker_segments"],
            45,
        )
        zero_cost.verify_run(output.parent, public_inputs=self.inputs)
        after = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in before}
        self.assertEqual(before, after)

    def test_private_review_is_aggregate_only_and_enforces_frozen_causes(self) -> None:
        private = self.root / "private-review.json"
        meeting = "b" * 64
        _write_json(private, {
            "schema_version": zero_cost.PRIVATE_SCHEMA_VERSION,
            "meeting_sha256": meeting,
            "unit": "seconds",
            "annotations": [
                {"second": 1, "intersects_diarizer_overlap": True, "causes": ["missed_target_in_overlap"], "uncertain": False},
                {"second": 2, "intersects_diarizer_overlap": True, "causes": ["duplicate_overlap", "other_speaker_intrusion"], "uncertain": True},
                {"second": 3, "intersects_diarizer_overlap": False, "causes": [], "uncertain": False},
                {"second": 4, "intersects_diarizer_overlap": True, "causes": [], "uncertain": True},
            ],
            "private_note": "must never escape",
        })
        # Unknown top-level private fields fail closed instead of being copied.
        with self.assertRaises(zero_cost.VerificationError):
            zero_cost.build_evidence(private, public_inputs=self.inputs)
        value = json.loads(private.read_text())
        del value["private_note"]
        _write_json(private, value)
        output, evidence = self._create(private)
        aggregate = evidence["correction_burden"]
        self.assertEqual(aggregate["overlap_caused_seconds"], 1)
        self.assertEqual(aggregate["total_seconds"], 4)
        self.assertEqual(aggregate["ratio"], 0.25)
        self.assertEqual(aggregate["percentage"], 25.0)
        self.assertEqual(aggregate["uncertain_seconds"], 2)
        serialized = output.read_text(encoding="utf-8")
        self.assertNotIn(str(private), serialized)
        self.assertNotIn("private_note", serialized)
        self.assertNotIn('"annotations"', serialized)
        with self.assertRaisesRegex(zero_cost.VerificationError, "requires --private-review"):
            zero_cost.verify_run(output.parent, public_inputs=self.inputs)
        zero_cost.verify_run(output.parent, private, public_inputs=self.inputs)

        changed = json.loads(private.read_text())
        changed["annotations"][0]["uncertain"] = True
        _write_json(private, changed)
        with self.assertRaisesRegex(zero_cost.VerificationError, "does not replay"):
            zero_cost.verify_run(output.parent, private, public_inputs=self.inputs)

    def test_private_review_rejects_unknown_causes_duplicates_and_false_types(self) -> None:
        base = {
            "schema_version": zero_cost.PRIVATE_SCHEMA_VERSION,
            "meeting_sha256": "c" * 64,
            "unit": "seconds",
            "annotations": [
                {"second": 1, "intersects_diarizer_overlap": True, "causes": ["invented"], "uncertain": False}
            ],
        }
        private = self.root / "private-invalid.json"
        _write_json(private, base)
        with self.assertRaises(zero_cost.VerificationError):
            zero_cost._private_aggregate(private)
        base["annotations"] = [
            {"second": 1, "intersects_diarizer_overlap": True, "causes": ["duplicate_overlap"], "uncertain": False},
            {"second": 1, "intersects_diarizer_overlap": False, "causes": [], "uncertain": False},
        ]
        _write_json(private, base)
        with self.assertRaises(zero_cost.VerificationError):
            zero_cost._private_aggregate(private)
        base["annotations"] = [
            {"second": True, "intersects_diarizer_overlap": True, "causes": ["duplicate_overlap"], "uncertain": False}
        ]
        _write_json(private, base)
        with self.assertRaises(zero_cost.VerificationError):
            zero_cost._private_aggregate(private)

    def test_tampering_symlinks_and_output_reuse_fail_closed(self) -> None:
        output, _ = self._create()
        output.chmod(0o644)
        with self.assertRaises(zero_cost.VerificationError):
            zero_cost.verify_run(output.parent, public_inputs=self.inputs)
        output.chmod(0o444)
        self.timeline.chmod(0o644)
        _write_json(self.timeline, [{"start_s": 0, "end_s": 9, "speaker": "changed"}])
        with self.assertRaises(zero_cost.VerificationError):
            zero_cost.verify_run(output.parent, public_inputs=self.inputs)
        with self.assertRaises(zero_cost.VerificationError):
            zero_cost._write_evidence(output.parent, {})
        link = self.root / "timeline-link.json"
        os.symlink(self.timeline, link)
        with self.assertRaises(zero_cost.VerificationError):
            zero_cost._parse_timeline(link)

    def test_symlink_in_parent_components_fails_for_inputs_private_and_run(self) -> None:
        real_parent = self.root / "real-parent"
        real_parent.mkdir()
        linked_parent = self.root / "linked-parent"
        os.symlink(real_parent, linked_parent)
        linked_timeline = real_parent / "timeline.json"
        _write_json(linked_timeline, [{"start_s": 0, "end_s": 1, "speaker": "x"}])
        with self.assertRaisesRegex(zero_cost.VerificationError, "symlink component"):
            zero_cost._parse_timeline(linked_parent / "timeline.json")

        private = real_parent / "private.json"
        _write_json(private, {
            "schema_version": zero_cost.PRIVATE_SCHEMA_VERSION,
            "meeting_sha256": "d" * 64,
            "unit": "seconds",
            "annotations": [
                {"second": 0, "intersects_diarizer_overlap": False, "causes": [], "uncertain": False}
            ],
        })
        with self.assertRaisesRegex(zero_cost.VerificationError, "private review failed"):
            zero_cost.build_evidence(linked_parent / "private.json", public_inputs=self.inputs)
        with self.assertRaisesRegex(zero_cost.VerificationError, "symlink component"):
            zero_cost._write_evidence(linked_parent / "run", {})
        output, _ = self._create()
        run_alias = real_parent / "run-alias"
        os.symlink(output.parent, run_alias)
        with self.assertRaisesRegex(zero_cost.VerificationError, "symlink component"):
            zero_cost.verify_run(run_alias, public_inputs=self.inputs)

    def test_symlinked_evidence_output_fails(self) -> None:
        output, _ = self._create()
        saved = self.root / "saved-evidence.json"
        saved.write_bytes(output.read_bytes())
        output.chmod(0o644)
        output.unlink()
        os.symlink(saved, output)
        with self.assertRaisesRegex(zero_cost.VerificationError, "symlink component"):
            zero_cost.verify_run(output.parent, public_inputs=self.inputs)

    def test_wrong_conflict_count_and_out_of_range_index_fail(self) -> None:
        _write_json(self.conflicts, [
            {"kind": "overlapping_speech", "segment_index": i} for i in range(44)
        ])
        with self.assertRaisesRegex(zero_cost.VerificationError, "canonical 45"):
            zero_cost.build_evidence(public_inputs=self.inputs)
        _write_json(self.conflicts, [
            {"kind": "overlapping_speech", "segment_index": i} for i in range(44)
        ] + [{"kind": "overlapping_speech", "segment_index": 999}])
        with self.assertRaises(zero_cost.VerificationError):
            zero_cost.build_evidence(public_inputs=self.inputs)

    def test_duplicate_or_reordered_conflict_identities_fail(self) -> None:
        rows = [
            {"kind": "overlapping_speech", "segment_index": i, "candidates": ["0", "1"]}
            for i in range(45)
        ]
        rows[-1] = dict(rows[0])
        _write_json(self.conflicts, rows)
        with self.assertRaisesRegex(zero_cost.VerificationError, "duplicate rows"):
            zero_cost.build_evidence(public_inputs=self.inputs)
        rows = [
            {"kind": "overlapping_speech", "segment_index": i, "candidates": ["0", "1"]}
            for i in range(45)
        ]
        rows[0], rows[1] = rows[1], rows[0]
        _write_json(self.conflicts, rows)
        with self.assertRaisesRegex(zero_cost.VerificationError, "canonical 45"):
            zero_cost.build_evidence(public_inputs=self.inputs)

    def test_duplicate_backend_paths_fingerprints_and_segments_fail(self) -> None:
        duplicate_path_inputs = zero_cost.PublicInputs(
            self.inputs.overlap_sources,
            self.conflicts,
            self.merged,
            self.manifest,
            (self.backend, self.backend),
            self.inputs.conflict_segment_indices,
        )
        with self.assertRaisesRegex(zero_cost.VerificationError, "paths must be unique"):
            zero_cost.build_evidence(public_inputs=duplicate_path_inputs)

        copied = self.root / "copied-backend.json"
        copied.write_bytes(self.backend.read_bytes())
        duplicate_hash_inputs = zero_cost.PublicInputs(
            self.inputs.overlap_sources,
            self.conflicts,
            self.merged,
            self.manifest,
            (self.backend, copied),
            self.inputs.conflict_segment_indices,
        )
        with self.assertRaisesRegex(zero_cost.VerificationError, "fingerprints must be unique"):
            zero_cost.build_evidence(public_inputs=duplicate_hash_inputs)

        document = json.loads(self.backend.read_text())
        document["segments"].append(dict(document["segments"][0]))
        _write_json(self.backend, document)
        with self.assertRaisesRegex(zero_cost.VerificationError, "duplicate.*segment identity"):
            zero_cost.build_evidence(public_inputs=self.inputs)

    def test_empty_backend_speaker_labels_are_excluded_diagnostics(self) -> None:
        document = json.loads(self.backend.read_text())
        document["segments"][0]["speaker"] = ""
        document["segments"][1]["speaker"] = "   "
        _write_json(self.backend, document)
        evidence = zero_cost.build_evidence(public_inputs=self.inputs)
        probe = evidence["vibevoice_backend_probe"]
        self.assertEqual(probe["excluded_empty_speaker_segment_count"], 2)
        self.assertEqual(probe["valid_backend_speaker_segment_count"], 88)
        self.assertEqual(
            probe["conflicts_intersecting_at_least_two_backend_speaker_segments"], 44
        )

    def test_correction_burden_stop_threshold_uses_ratio(self) -> None:
        self.assertTrue(zero_cost.correction_burden_stops_lane(0.0499))
        self.assertFalse(zero_cost.correction_burden_stops_lane(0.05))
        self.assertFalse(zero_cost.correction_burden_stops_lane(0.0501))
        with self.assertRaises(zero_cost.VerificationError):
            zero_cost.correction_burden_stops_lane(1.01)

    def test_duplicate_json_keys_fail(self) -> None:
        duplicate = self.root / "duplicate.json"
        duplicate.write_text('[{"start_s":0,"start_s":1,"end_s":2,"speaker":"x"}]', encoding="utf-8")
        with self.assertRaisesRegex(zero_cost.VerificationError, "duplicate JSON key"):
            zero_cost._parse_timeline(duplicate)

    def test_repository_voxconverse_baseline_has_exact_45_overlap_conflicts(self) -> None:
        if not os.environ.get(zero_cost.ZERO_COST_INPUT_ROOT_ENV):
            self.skipTest(
                "set {} for the sealed VoxConverse integration evidence".format(
                    zero_cost.ZERO_COST_INPUT_ROOT_ENV
                )
            )
        inputs = zero_cost._canonical_inputs()
        probe = zero_cost._backend_probe(
            inputs.conflicts,
            inputs.merged_segments,
            inputs.manifest,
            inputs.backend_records,
            inputs.conflict_segment_indices,
        )
        self.assertEqual(probe["observed_overlap_conflict_count"], 45)
        self.assertEqual(
            probe["conflicts_intersecting_at_least_two_backend_speaker_segments"], 0
        )
        measure = zero_cost.overlap_measure(
            zero_cost._parse_rttm(dict(inputs.overlap_sources)["voxconverse-rttm"])
        )
        self.assertGreater(measure["overlap_seconds"], 0)

    def test_canonical_ami_is_prepared_in1009_with_expected_measure(self) -> None:
        repo = Path(__file__).resolve().parents[4]
        path = repo / "benchmarks/samples/public/acceptance-pack-v1/prepared/ami-in1009-ihm-mix-v1/reference.rttm"
        self.assertEqual(
            hashlib.sha256(path.read_bytes()).hexdigest(),
            "516e4185f5dd852aa0dbdba11ed7d5f33406c9e4a4c8c63dc40e92f8f523eb25",
        )
        measure = zero_cost.overlap_measure(zero_cost._parse_rttm(path))
        self.assertEqual(measure["overlap_seconds"], 200.082)
        self.assertEqual(measure["speech_union_seconds"], 1080.085)
        self.assertAlmostEqual(measure["overlap_share_of_speech"], 0.18524653152298218)

    def test_exact_cli_surface_analyzes_then_verifies(self) -> None:
        environment, run = self._production_paths()
        with mock.patch.dict(os.environ, environment), mock.patch.object(
            zero_cost, "_canonical_inputs", return_value=self.inputs
        ):
            analyze_args = ["analyze", "--run", str(run)]
            self.assertEqual(zero_cost.main(analyze_args), 0)
            self.assertEqual(zero_cost.main(["verify", "--run", str(run)]), 0)

    def test_production_cli_has_no_arbitrary_public_input_escape_hatch(self) -> None:
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                zero_cost._parser().parse_args([
                    "analyze", "--run", str(self.root / "forbidden"),
                    "--overlap-source", "fake={}".format(self.rttm),
                ])
        synthetic_output, _ = self._create()
        with self.assertRaisesRegex(zero_cost.VerificationError, "public-input tree"):
            zero_cost.verify_run(synthetic_output.parent)

        environment, allowed = self._production_paths()
        outside = self.root / "outside"
        stderr = io.StringIO()
        with mock.patch.dict(os.environ, environment), mock.patch.object(
            zero_cost, "_canonical_inputs", return_value=self.inputs
        ):
            with contextlib.redirect_stderr(stderr):
                self.assertEqual(
                    zero_cost.main(["analyze", "--run", str(outside)]), 2
                )
        self.assertFalse(outside.exists())
        self.assertIn("exactly $DICOW_RUN_ROOT/e3-zero-cost", stderr.getvalue())

        bad_environment = dict(environment)
        bad_environment["DICOW_RUN_ROOT"] = str(self.root / "not-under-cache")
        with mock.patch.dict(os.environ, bad_environment):
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(zero_cost.main(["analyze", "--run", str(allowed)]), 2)

        repo = Path(__file__).resolve().parents[4]
        checkout_cache = repo / "benchmarks" / "never-create-t7-cache"
        checkout_run_root = checkout_cache / "runs" / "run-1"
        checkout_run = checkout_run_root / "e3-zero-cost"
        checkout_environment = {
            "DICOW_CACHE_ROOT": str(checkout_cache),
            "DICOW_RUN_ROOT": str(checkout_run_root),
        }
        with mock.patch.dict(os.environ, checkout_environment):
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(
                    zero_cost.main(["analyze", "--run", str(checkout_run)]), 2
                )
        self.assertFalse(checkout_cache.exists())

    def test_private_path_and_rows_never_appear_in_cli_error(self) -> None:
        private = self.root / "sensitive-private-review-name.json"
        private.write_text('{"private_secret":"row text"}\n', encoding="utf-8")
        stderr = io.StringIO()
        environment, run = self._production_paths()
        with mock.patch.dict(os.environ, environment):
            with contextlib.redirect_stderr(stderr):
                result = zero_cost.main([
                    "analyze", "--run", str(run),
                    "--private-review", str(private),
                ])
        self.assertEqual(result, 2)
        message = stderr.getvalue()
        self.assertNotIn(str(private), message)
        self.assertNotIn("private_secret", message)
        self.assertNotIn("row text", message)

    def test_unavailable_evidence_rejects_private_review_at_verify(self) -> None:
        output, _ = self._create()
        private = self.root / "private-for-unavailable.json"
        _write_json(private, {
            "schema_version": zero_cost.PRIVATE_SCHEMA_VERSION,
            "meeting_sha256": "e" * 64,
            "unit": "seconds",
            "annotations": [
                {"second": 0, "intersects_diarizer_overlap": False, "causes": [], "uncertain": False}
            ],
        })
        with self.assertRaisesRegex(zero_cost.VerificationError, "unavailable.*may not"):
            zero_cost.verify_run(output.parent, private, public_inputs=self.inputs)

    def test_verify_rejects_any_nonaggregate_file_in_run(self) -> None:
        output, _ = self._create()
        (output.parent / "private-rows.json").write_text("forbidden", encoding="utf-8")
        with self.assertRaisesRegex(zero_cost.VerificationError, "only aggregate"):
            zero_cost.verify_run(output.parent, public_inputs=self.inputs)


if __name__ == "__main__":
    unittest.main()
