from __future__ import annotations

from copy import deepcopy
from hashlib import sha256
import json
from pathlib import Path
import re
import tempfile
import unittest

from score_corrected import main, score_corrected_run as _score_corrected_run


def score_corrected_run(
    run_root: Path, reference_path: Path, terms_path: Path
) -> dict[str, object]:
    """Exercise the one explicitly retained pre-D39 read path."""

    return _score_corrected_run(
        run_root,
        reference_path,
        terms_path,
        allow_legacy_root_postprocess=True,
    )


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def file_sha256(path: Path) -> str:
    return sha256(path.read_bytes()).hexdigest()


def segment(
    index: int,
    text: str,
    *,
    speaker: str | None = None,
) -> dict[str, object]:
    return {
        "speaker": speaker or f"SPEAKER_{index % 2:02d}",
        "start_s": float(index),
        "end_s": float(index + 1),
        "text": text,
        "language": "en",
        "confidence": 0.9,
        "flags": [],
    }


def document(texts: list[str]) -> dict[str, object]:
    return {
        "schema_version": "1.0.0",
        "segments": [segment(index, text) for index, text in enumerate(texts)],
        "num_speakers": 2,
        "source": {
            "file_name": "synthetic.wav",
            "sha256": "0" * 64,
            "duration_s": float(len(texts)),
        },
    }


class CorrectedScorerTests(unittest.TestCase):
    def make_run(self, root: Path) -> tuple[Path, Path, Path]:
        run_root = root / "run"
        raw = document(["alpha betta", "gamma", "delta", "review text"])
        corrected = deepcopy(raw)
        corrected["segments"][0]["text"] = "alpha beta"
        corrected["segments"][1]["text"] = "gamut"
        corrected["segments"][2]["flags"] = ["uncertain", "conflict"]
        conflicts = [
            {
                "segment_index": 2,
                "original_text": "delta",
                "candidate_text": "della",
                "reason": "possible name correction",
            }
        ]
        reference = document(["alpha beta", "gamma", "delta", "review text"])
        terms = [
            {"term": "alpha", "reference_count": 1},
            {"term": "gamma", "reference_count": 1},
            {"term": "delta", "reference_count": 1},
        ]

        write_json(run_root / "merged" / "segments.json", raw)
        write_json(run_root / "postprocess" / "segments.json", corrected)
        write_json(run_root / "postprocess" / "conflicts.json", conflicts)
        artifact_paths = (
            "merged/segments.json",
            "postprocess/segments.json",
            "postprocess/conflicts.json",
        )
        write_json(
            run_root / "manifest.json",
            {
                "schema_version": "1.0.0",
                "run_id": "run",
                "status": "succeeded",
                "input": {
                    "file_name": "synthetic.wav",
                    "sha256": "0" * 64,
                    "size_bytes": 0,
                },
                "backend": {"name": "synthetic-asr", "version": "1.0.0"},
                "models": [
                    {
                        "role": "asr",
                        "hf_model_id": "example/asr-model",
                        "revision": "a" * 40,
                        "quantization": "int8",
                    }
                ],
                "glossary": {
                    "provided": False,
                    "sha256": None,
                    "item_count": 0,
                    "injection_mode": "none",
                    "applied": False,
                },
                "preprocessing": {
                    "sample_rate_hz": 16_000,
                    "channels": 1,
                    "peak_normalization": False,
                    "vad": {"enabled": False, "backend": None},
                    "enhancement": {"enabled": False, "backend": None},
                },
                "coverage": {
                    "input_duration_s": 4.0,
                    "processed_duration_s": 4.0,
                    "truncated": False,
                    "strategy": "full",
                    "chunks_planned": 1,
                    "chunks_completed": 1,
                },
                "chunk_boundaries": [
                    {
                        "index": 0,
                        "start_s": 0.0,
                        "end_s": 4.0,
                        "status": "succeeded",
                    }
                ],
                "timing": {
                    "started_at": "2026-08-11T00:00:00Z",
                    "finished_at": "2026-08-11T00:00:01Z",
                    "wall_time_s": 1.0,
                },
                "peak_memory_bytes": 1,
                "artifacts": [
                    {
                        "kind": relative.replace("/", "_").replace(".", "_"),
                        "path": relative,
                        "sha256": file_sha256(run_root / relative),
                    }
                    for relative in artifact_paths
                ],
                "failure": None,
                "postprocess": {
                    "backend": {"name": "codex-app-server", "version": "0.146.0"},
                    "model_id": "gpt-5.6-sol",
                    "model_revision": None,
                    "quantization": None,
                    "input_mode": "text-only",
                    "glossary_sha256": None,
                    "mode": "correction",
                },
            },
        )
        reference_path = root / "reference.segments.json"
        terms_path = root / "terms.json"
        write_json(reference_path, reference)
        write_json(terms_path, terms)
        return run_root, reference_path, terms_path

    def load_run_document(self, run_root: Path, relative: str) -> object:
        return json.loads((run_root / relative).read_text(encoding="utf-8"))

    def write_run_document(self, run_root: Path, relative: str, value: object) -> None:
        write_json(run_root / relative, value)
        manifest_path = run_root / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        for artifact in manifest["artifacts"]:
            if artifact["path"] == relative:
                artifact["sha256"] = file_sha256(run_root / relative)
                write_json(manifest_path, manifest)
                return
        self.fail(f"fixture manifest does not declare {relative}")

    def test_legacy_root_postprocess_requires_an_explicit_compatibility_flag(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            run_root, reference_path, terms_path = self.make_run(
                Path(temporary_directory)
            )
            manifest_path = run_root / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["postprocess"].pop("mode")
            write_json(manifest_path, manifest)

            with self.assertRaisesRegex(ValueError, r"selected derived ID"):
                _score_corrected_run(run_root, reference_path, terms_path)

            result = _score_corrected_run(
                run_root,
                reference_path,
                terms_path,
                allow_legacy_root_postprocess=True,
            )
            self.assertIsNone(result["run"]["derived_id"])

    def test_preserves_preexisting_source_review_flags_without_a_new_conflict(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            run_root, reference_path, terms_path = self.make_run(
                Path(temporary_directory)
            )
            for relative in (
                "merged/segments.json",
                "postprocess/segments.json",
            ):
                document = self.load_run_document(run_root, relative)
                document["segments"][3]["flags"] = ["conflict", "uncertain"]
                self.write_run_document(run_root, relative, document)

            result = score_corrected_run(run_root, reference_path, terms_path)

            self.assertEqual(
                result["correction_outcomes"]["flagged_for_review"], 1
            )
            self.assertEqual(result["correction_outcomes"]["applied_text_changes"], 2)

    def test_scorable_false_reference_keeps_changed_segment_unscorable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            run_root, reference_path, terms_path = self.make_run(
                Path(temporary_directory)
            )
            reference = json.loads(reference_path.read_text(encoding="utf-8"))
            reference["segments"][0]["scorable"] = False
            write_json(reference_path, reference)

            direction = score_corrected_run(
                run_root, reference_path, terms_path
            )["applied_correction_direction"]

            self.assertEqual(direction["evaluated_applied_text_changes"], 1)
            self.assertEqual(direction["unevaluated_applied_text_changes"], 1)
            self.assertEqual(direction["unevaluated_segments"][0]["segment_index"], 0)

    def test_rejects_a_reference_from_a_different_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            run_root, reference_path, terms_path = self.make_run(
                Path(temporary_directory)
            )
            reference = json.loads(reference_path.read_text(encoding="utf-8"))
            reference["source"]["sha256"] = "f" * 64
            write_json(reference_path, reference)

            with self.assertRaisesRegex(ValueError, r"reference source identity"):
                score_corrected_run(run_root, reference_path, terms_path)

    def test_cli_rejects_an_output_inside_the_source_run(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            run_root, reference_path, terms_path = self.make_run(root)
            output_path = run_root / "corrected-scores.json"
            manifest_before = (run_root / "manifest.json").read_bytes()

            with self.assertRaisesRegex(
                ValueError, r"outside immutable input tree"
            ):
                main(
                    [
                        "--run-root",
                        str(run_root),
                        "--reference",
                        str(reference_path),
                        "--terms",
                        str(terms_path),
                        "--allow-legacy-root-postprocess",
                        "--output",
                        str(output_path),
                    ]
                )

            self.assertFalse(output_path.exists())
            self.assertEqual(
                (run_root / "manifest.json").read_bytes(), manifest_before
            )

    def test_rejects_schema_invalid_review_artifact_from_hostile_probe(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            run_root, reference_path, terms_path = self.make_run(
                Path(temporary_directory)
            )
            corrected = self.load_run_document(
                run_root, "postprocess/segments.json"
            )
            corrected["segments"][2]["text"] = ""
            corrected["segments"][2]["flags"] = ["uncertain", "conflict"]
            self.write_run_document(
                run_root, "postprocess/segments.json", corrected
            )
            self.write_run_document(run_root, "postprocess/conflicts.json", [])

            with self.assertRaisesRegex(ValueError, r"postprocess.*schema|segment 2"):
                score_corrected_run(run_root, reference_path, terms_path)

    def test_requires_review_flags_and_conflicts_in_both_directions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            run_root, reference_path, terms_path = self.make_run(
                Path(temporary_directory)
            )
            self.write_run_document(run_root, "postprocess/conflicts.json", [])

            with self.assertRaisesRegex(ValueError, r"segment 2.*conflict"):
                score_corrected_run(run_root, reference_path, terms_path)

    def test_review_conflict_requires_flags_and_preserved_source_text(self) -> None:
        for mutation, message in (
            ("missing_flags", r"segment 2.*review flags"),
            ("changed_text", r"segment 2.*flagged.*changed"),
        ):
            with self.subTest(mutation=mutation):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    run_root, reference_path, terms_path = self.make_run(
                        Path(temporary_directory)
                    )
                    corrected = self.load_run_document(
                        run_root, "postprocess/segments.json"
                    )
                    if mutation == "missing_flags":
                        corrected["segments"][2]["flags"] = []
                    else:
                        corrected["segments"][2]["text"] = "della"
                    self.write_run_document(
                        run_root, "postprocess/segments.json", corrected
                    )

                    with self.assertRaisesRegex(ValueError, message):
                        score_corrected_run(
                            run_root, reference_path, terms_path
                        )

    def test_rejects_schema_invalid_raw_transcript(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            run_root, reference_path, terms_path = self.make_run(
                Path(temporary_directory)
            )
            raw = self.load_run_document(run_root, "merged/segments.json")
            raw["segments"][0]["text"] = ""
            self.write_run_document(run_root, "merged/segments.json", raw)

            with self.assertRaisesRegex(ValueError, r"merged.*schema|segment 0"):
                score_corrected_run(run_root, reference_path, terms_path)

    def test_rejects_wrong_manifest_hash_for_each_scored_artifact(self) -> None:
        for relative in (
            "merged/segments.json",
            "postprocess/segments.json",
            "postprocess/conflicts.json",
        ):
            with self.subTest(relative=relative):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    run_root, reference_path, terms_path = self.make_run(
                        Path(temporary_directory)
                    )
                    manifest_path = run_root / "manifest.json"
                    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                    for artifact in manifest["artifacts"]:
                        if artifact["path"] == relative:
                            artifact["sha256"] = "f" * 64
                            break
                    write_json(manifest_path, manifest)

                    with self.assertRaisesRegex(
                        ValueError,
                        rf"artifact hash mismatch: {re.escape(relative)}",
                    ):
                        score_corrected_run(run_root, reference_path, terms_path)

    def test_scores_raw_and_corrected_and_reports_explicit_directional_deltas(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            run_root, reference_path, terms_path = self.make_run(
                Path(temporary_directory)
            )

            result = score_corrected_run(run_root, reference_path, terms_path)

            raw_scores = result["scores"]["raw"]
            corrected_scores = result["scores"]["corrected"]
            self.assertEqual(raw_scores["wer"]["errors"], 1)
            self.assertEqual(corrected_scores["wer"]["errors"], 1)
            self.assertEqual(raw_scores["terms"]["term_recall"], 1.0)
            self.assertAlmostEqual(corrected_scores["terms"]["term_recall"], 2 / 3)
            self.assertEqual(raw_scores["omissions"]["omitted_utterances"], 0)
            self.assertEqual(corrected_scores["omissions"]["omitted_utterances"], 0)

            deltas = result["metric_deltas"]
            self.assertEqual(
                deltas["wer.error_rate"],
                {
                    "raw": raw_scores["wer"]["error_rate"],
                    "corrected": corrected_scores["wer"]["error_rate"],
                    "corrected_minus_raw": 0.0,
                    "better_when": "lower",
                    "outcome": "unchanged",
                },
            )
            self.assertEqual(deltas["cer.error_rate"]["better_when"], "lower")
            self.assertEqual(deltas["cer.error_rate"]["outcome"], "regressed")
            self.assertGreater(
                deltas["cer.error_rate"]["corrected_minus_raw"], 0.0
            )
            self.assertEqual(deltas["terms.term_recall"]["better_when"], "higher")
            self.assertEqual(deltas["terms.term_recall"]["outcome"], "regressed")
            self.assertAlmostEqual(
                deltas["terms.term_recall"]["corrected_minus_raw"], -1 / 3
            )
            self.assertEqual(
                deltas["omissions.omitted_utterances"]["outcome"], "unchanged"
            )
            self.assertEqual(
                deltas["omissions.omission_rate"]["outcome"], "unchanged"
            )

    def test_rejects_changed_speaker_and_names_segment_and_field(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            run_root, reference_path, terms_path = self.make_run(
                Path(temporary_directory)
            )
            corrected = self.load_run_document(
                run_root, "postprocess/segments.json"
            )
            corrected["segments"][1]["speaker"] = "SPEAKER_99"
            self.write_run_document(
                run_root, "postprocess/segments.json", corrected
            )

            with self.assertRaisesRegex(ValueError, r"segment 1.*speaker"):
                score_corrected_run(run_root, reference_path, terms_path)

    def test_rejects_changed_start_and_end_and_names_segment_and_field(self) -> None:
        for field, value in (("start_s", 1.01), ("end_s", 2.01)):
            with self.subTest(field=field):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    run_root, reference_path, terms_path = self.make_run(
                        Path(temporary_directory)
                    )
                    corrected = self.load_run_document(
                        run_root, "postprocess/segments.json"
                    )
                    corrected["segments"][1][field] = value
                    self.write_run_document(
                        run_root, "postprocess/segments.json", corrected
                    )

                    with self.assertRaisesRegex(
                        ValueError, rf"segment 1.*{field}"
                    ):
                        score_corrected_run(run_root, reference_path, terms_path)

    def test_rejects_changed_segment_count_and_names_first_missing_segment(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            run_root, reference_path, terms_path = self.make_run(
                Path(temporary_directory)
            )
            corrected = self.load_run_document(
                run_root, "postprocess/segments.json"
            )
            corrected["segments"].pop()
            self.write_run_document(
                run_root, "postprocess/segments.json", corrected
            )

            with self.assertRaisesRegex(ValueError, r"segment 3.*(missing|count)"):
                score_corrected_run(run_root, reference_path, terms_path)

    def test_rejects_changed_source_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            run_root, reference_path, terms_path = self.make_run(
                Path(temporary_directory)
            )
            corrected = self.load_run_document(
                run_root, "postprocess/segments.json"
            )
            corrected["source"]["sha256"] = "1" * 64
            self.write_run_document(
                run_root, "postprocess/segments.json", corrected
            )

            with self.assertRaisesRegex(ValueError, r"source"):
                score_corrected_run(run_root, reference_path, terms_path)

    def test_counts_applied_text_changes_and_review_conflicts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            run_root, reference_path, terms_path = self.make_run(
                Path(temporary_directory)
            )

            outcomes = score_corrected_run(
                run_root, reference_path, terms_path
            )["correction_outcomes"]

            self.assertEqual(outcomes["applied_text_changes"], 2)
            self.assertEqual(outcomes["flagged_for_review"], 1)
            self.assertEqual(outcomes["observable_proposal_outcomes"], 3)
            self.assertAlmostEqual(outcomes["applied_fraction"], 2 / 3)
            self.assertAlmostEqual(outcomes["review_fraction"], 1 / 3)
            self.assertEqual(
                outcomes["applied_count_basis"],
                "raw_corrected_text_difference",
            )

    def test_rejects_malformed_duplicate_and_out_of_range_conflicts(self) -> None:
        mutations = {
            "malformed": (
                [{"segment_index": 2}],
                r"conflict 0.*(candidate_text|fields)",
            ),
            "duplicate": (
                [
                    {
                        "segment_index": 2,
                        "original_text": "delta",
                        "candidate_text": "della",
                        "reason": "first",
                    },
                    {
                        "segment_index": 2,
                        "original_text": "delta",
                        "candidate_text": "dell'arte",
                        "reason": "second",
                    },
                ],
                r"(duplicate.*segment 2|segment 2.*duplicate)",
            ),
            "out_of_range": (
                [
                    {
                        "segment_index": 99,
                        "original_text": "missing",
                        "candidate_text": "candidate",
                        "reason": "bad index",
                    }
                ],
                r"(segment 99.*range|range.*segment 99)",
            ),
        }
        for name, (conflicts, message) in mutations.items():
            with self.subTest(name=name):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    run_root, reference_path, terms_path = self.make_run(
                        Path(temporary_directory)
                    )
                    self.write_run_document(
                        run_root, "postprocess/conflicts.json", conflicts
                    )

                    with self.assertRaisesRegex(ValueError, message):
                        score_corrected_run(
                            run_root, reference_path, terms_path
                        )

    def test_exact_unique_reference_alignment_counts_closer_and_further(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            run_root, reference_path, terms_path = self.make_run(
                Path(temporary_directory)
            )

            direction = score_corrected_run(
                run_root, reference_path, terms_path
            )["applied_correction_direction"]

            self.assertEqual(
                direction["alignment_method"],
                "unique_reference_segment_with_exact_interval",
            )
            self.assertEqual(
                direction["classification_method"],
                "pareto_cer_and_wer_edit_errors",
            )
            self.assertEqual(direction["evaluated_applied_text_changes"], 2)
            self.assertEqual(direction["unevaluated_applied_text_changes"], 0)
            self.assertEqual(direction["closer"], 1)
            self.assertEqual(direction["further"], 1)
            self.assertEqual(direction["unchanged"], 0)
            self.assertEqual(direction["mixed"], 0)
            self.assertEqual(direction["observed_correction_made_worse_count"], 1)
            self.assertEqual(direction["correction_made_worse_count"], 1)
            classifications = {
                item["segment_index"]: item["classification"]
                for item in direction["segments"]
            }
            self.assertEqual(classifications, {0: "closer", 1: "further"})
            further = next(
                item for item in direction["segments"] if item["segment_index"] == 1
            )
            self.assertEqual(further["raw"], {"cer_errors": 0, "wer_errors": 0})
            self.assertGreater(further["corrected"]["cer_errors"], 0)
            self.assertGreater(further["corrected"]["wer_errors"], 0)

    def test_applied_change_without_unique_exact_reference_is_unevaluated(self) -> None:
        for mutation in ("different_interval", "duplicate_interval"):
            with self.subTest(mutation=mutation):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    root = Path(temporary_directory)
                    run_root, reference_path, terms_path = self.make_run(root)
                    reference = json.loads(reference_path.read_text(encoding="utf-8"))
                    if mutation == "different_interval":
                        reference["segments"][0]["start_s"] = 0.01
                    else:
                        reference["segments"].insert(
                            1,
                            deepcopy(reference["segments"][0])
                        )
                    write_json(reference_path, reference)

                    direction = score_corrected_run(
                        run_root, reference_path, terms_path
                    )["applied_correction_direction"]

                    self.assertEqual(direction["evaluated_applied_text_changes"], 1)
                    self.assertEqual(direction["unevaluated_applied_text_changes"], 1)
                    self.assertEqual(
                        direction["observed_correction_made_worse_count"], 1
                    )
                    self.assertIsNone(direction["correction_made_worse_count"])
                    self.assertEqual(
                        [item["segment_index"] for item in direction["unevaluated_segments"]],
                        [0],
                    )
                    self.assertIn(
                        "unique reference segment",
                        direction["unevaluated_segments"][0]["reason"],
                    )

    def test_cli_refuses_to_overwrite_output_and_preserves_existing_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            run_root, reference_path, terms_path = self.make_run(root)
            output_path = root / "corrected-scores.json"
            sentinel = b'{"sentinel":true}\n'
            output_path.write_bytes(sentinel)

            with self.assertRaises(FileExistsError):
                main(
                    [
                        "--run-root",
                        str(run_root),
                        "--reference",
                        str(reference_path),
                        "--terms",
                        str(terms_path),
                        "--allow-legacy-root-postprocess",
                        "--output",
                        str(output_path),
                    ]
                )

            self.assertEqual(output_path.read_bytes(), sentinel)


if __name__ == "__main__":
    unittest.main()
