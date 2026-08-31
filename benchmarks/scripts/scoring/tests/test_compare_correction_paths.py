from __future__ import annotations

from contextlib import redirect_stdout
from copy import deepcopy
from hashlib import sha256
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest


SCORING = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCORING))

from compare_correction_paths import compare_correction_paths, main  # noqa: E402
from score_corrected import score_corrected_run  # noqa: E402


SOURCE_SHA256 = "0" * 64
OTHER_SOURCE_SHA256 = "f" * 64
GLOSSARY_SHA256 = "1" * 64
ASR_MODEL = {
    "role": "asr",
    "hf_model_id": "example/asr-model",
    "revision": "a" * 40,
    "quantization": "int8",
}
SOURCE_ARTIFACT_KINDS = {
    "primary/raw.txt": "primary_raw",
    "primary/segments.json": "primary_segments",
    "diarization/timeline.json": "diarization_timeline",
    "merged/segments.json": "merged_segments",
    "merged/conflicts.json": "merged_conflicts",
}
REFERENCE_TEXTS = (
    "Maccheroni builds transcripts",
    "Qwen3-ASR works locally",
    "Keep this correct",
    "Review uncertain term",
)
NO_GLOSSARY_TEXTS = (
    "Macaroni builds transcripts",
    "Qwen three ASR works locally",
    "Keep this correct",
    "...",
)
DECODE_GLOSSARY_TEXTS = (
    "Maccheroni builds transcripts",
    "Qwen3-ASR works locally",
    "Keep this correct",
    "...",
)
DECODE_CORRECTED_TEXTS = (
    "Maccheroni builds transcripts",
    "Qwen3-ASR works locally",
    "Keep this wrong",
    "Review uncertain term",
)
NO_GLOSSARY_CORRECTED_TEXTS = (
    "Maccheroni builds transcripts",
    "Qwen3-ASR works locally",
    "Keep this correct",
    "...",
)


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def load_json(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def file_sha256(path: Path) -> str:
    return sha256(path.read_bytes()).hexdigest()


def tree_hashes(root: Path) -> dict[str, str]:
    return {
        path.relative_to(root).as_posix(): file_sha256(path)
        for path in root.rglob("*")
        if path.is_file() and not path.is_symlink()
    }


def segments_document(
    texts: tuple[str, ...],
    *,
    source_sha256: str = SOURCE_SHA256,
    reviewed_indices: set[int] | None = None,
    assigned_speakers: bool = True,
) -> dict[str, object]:
    reviewed = reviewed_indices or set()
    segments = []
    for index, text in enumerate(texts):
        segment: dict[str, object] = {
            "speaker": (
                f"SPEAKER_{index % 2:02d}" if assigned_speakers else "UNASSIGNED"
            ),
            "start_s": float(index),
            "end_s": float(index) + 0.5,
            "text": text,
            "language": "en",
        }
        if index in reviewed:
            segment["flags"] = ["uncertain", "conflict"]
        segments.append(segment)
    return {
        "schema_version": "1.0.0",
        "segments": segments,
        "num_speakers": 2 if assigned_speakers else 0,
        "source": {
            "file_name": "synthetic.wav",
            "sha256": source_sha256,
            "duration_s": 4.0,
        },
    }


def batching_provenance() -> dict[str, object]:
    return {
        "maximum_prompt_utf8_bytes": 16_384,
        "maximum_segments_per_batch": 32,
        "maximum_output_tokens": None,
        "output_token_limit_status": "service-managed-unavailable",
        "output_token_planning_budget": 4_096,
        "output_tokens_per_input_utf8_byte_permille": 2_000,
        "base_output_token_reserve": 32,
        "per_segment_output_token_reserve": 96,
        "batches_planned": 1,
        "maximum_observed_prompt_utf8_bytes": 512,
        "maximum_observed_input_text_utf8_bytes": 128,
        "maximum_observed_estimated_output_tokens": 672,
        "maximum_observed_output_text_utf8_bytes": 96,
        "maximum_observed_response_utf8_bytes": 160,
        "maximum_observed_accepted_output_token_upper_bound": 576,
    }


def create_run(
    root: Path,
    *,
    run_id: str,
    raw_texts: tuple[str, ...],
    decode_glossary: bool,
) -> Path:
    run = root / run_id
    primary = segments_document(raw_texts, assigned_speakers=False)
    merged = segments_document(raw_texts)
    write_json(run / "primary/segments.json", primary)
    (run / "primary/raw.txt").write_text(
        " ".join(raw_texts) + "\n", encoding="utf-8"
    )
    write_json(
        run / "diarization/timeline.json",
        [
            {"speaker": "SPEAKER_00", "start_s": 0.0, "end_s": 1.0},
            {"speaker": "SPEAKER_01", "start_s": 1.0, "end_s": 2.0},
            {"speaker": "SPEAKER_00", "start_s": 2.0, "end_s": 3.0},
            {"speaker": "SPEAKER_01", "start_s": 3.0, "end_s": 4.0},
        ],
    )
    write_json(run / "merged/segments.json", merged)
    write_json(run / "merged/conflicts.json", [])

    artifact_paths = [
        "primary/raw.txt",
        "primary/segments.json",
        "diarization/timeline.json",
        "merged/segments.json",
        "merged/conflicts.json",
    ]
    manifest: dict[str, object] = {
        "schema_version": "1.0.0",
        "run_id": run_id,
        "status": "succeeded",
        "input": {
            "file_name": "synthetic.wav",
            "sha256": SOURCE_SHA256,
            "size_bytes": 0,
        },
        "backend": {"name": "synthetic-asr", "version": "1.0.0"},
        "models": [ASR_MODEL],
        "glossary": (
            {
                "provided": True,
                "sha256": GLOSSARY_SHA256,
                "item_count": 2,
                "injection_mode": "free_text_context",
                "applied": True,
            }
            if decode_glossary
            else {
                "provided": False,
                "sha256": None,
                "item_count": 0,
                "injection_mode": "none",
                "applied": False,
            }
        ),
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
            {"index": 0, "start_s": 0.0, "end_s": 4.0, "status": "succeeded"}
        ],
        "timing": {
            "started_at": "2026-08-11T00:00:00Z",
            "finished_at": "2026-08-11T00:00:01Z",
            "wall_time_s": 1.0,
        },
        "peak_memory_bytes": 1,
        "artifacts": [
            {
                "kind": SOURCE_ARTIFACT_KINDS[relative],
                "path": relative,
                "sha256": file_sha256(run / relative),
            }
            for relative in artifact_paths
        ],
        "failure": None,
    }
    write_json(run / "manifest.json", manifest)
    return run


def create_derived(
    run: Path,
    *,
    derived_id: str,
    corrected_texts: tuple[str, ...],
    conflicts: list[dict[str, object]],
) -> str:
    derived = run / "derived" / derived_id
    reviewed = {int(value["segment_index"]) for value in conflicts}
    corrected = segments_document(corrected_texts, reviewed_indices=reviewed)
    write_json(derived / "postprocess/segments.json", corrected)
    write_json(derived / "postprocess/conflicts.json", conflicts)
    source_manifest = load_json(run / "manifest.json")
    write_json(
        derived / "manifest.json",
        {
            "schema_version": "1.0.0",
            "derived_id": derived_id,
            "status": "succeeded",
            "source": {
                "run_id": source_manifest["run_id"],
                "manifest_sha256": file_sha256(run / "manifest.json"),
                "segments_path": "merged/segments.json",
                "segments_sha256": file_sha256(run / "merged/segments.json"),
            },
            "operation": {
                "profile_name": "ko-meeting",
                "mode": "correction",
                "target_language": None,
                "glossary_semantics": "current-profile",
                "glossary_sha256": GLOSSARY_SHA256,
                "glossary_item_count": 2,
            },
            "timing": {
                "started_at": "2026-08-12T00:00:00Z",
                "finished_at": "2026-08-12T00:00:01Z",
                "wall_time_s": 1.0,
            },
            "artifacts": [
                {
                    "kind": "postprocess_segments",
                    "path": "postprocess/segments.json",
                    "sha256": file_sha256(derived / "postprocess/segments.json"),
                },
                {
                    "kind": "postprocess_conflicts",
                    "path": "postprocess/conflicts.json",
                    "sha256": file_sha256(derived / "postprocess/conflicts.json"),
                },
            ],
            "failure": None,
            "postprocess": {
                "backend": {"name": "codex-app-server", "version": "0.146.0"},
                "model_id": "gpt-5.6-sol",
                "model_revision": None,
                "quantization": None,
                "input_mode": "text-only",
                "glossary_sha256": GLOSSARY_SHA256,
                "mode": "correction",
                "target_language": None,
                "source_segments_sha256": None,
                "batching": batching_provenance(),
            },
        },
    )
    return derived_id


def write_placeholder_thresholds(path: Path) -> None:
    metrics = {
        "cer.error_rate": {
            "better_when": "lower",
            "minimum_improvement": None,
        },
        "wer.error_rate": {
            "better_when": "lower",
            "minimum_improvement": None,
        },
        "terms.term_recall": {
            "better_when": "higher",
            "minimum_improvement": None,
        },
        "omissions.omitted_utterances": {
            "better_when": "lower",
            "minimum_improvement": None,
        },
    }
    write_json(
        path,
        {
            "schema_version": "1.0.0",
            "status": "placeholder",
            "maintainer_action": (
                "Set every null threshold and change status to configured."
            ),
            "comparisons": {
                name: deepcopy(metrics)
                for name in (
                    "decode_time_injection_gain",
                    "correction_gain",
                    "correction_gain_without_decode_time_injection",
                )
            },
            "guardrails": {
                "decode_glossary_corrected.correct_to_incorrect": {
                    "maximum_count": None
                },
                "no_glossary_corrected.correct_to_incorrect": {
                    "maximum_count": None
                },
            },
        },
    )


def configure_permissive_thresholds(path: Path) -> None:
    thresholds = load_json(path)
    thresholds["status"] = "configured"
    for metrics in thresholds["comparisons"].values():
        for specification in metrics.values():
            specification["minimum_improvement"] = -1_000.0
    thresholds["guardrails"][
        "decode_glossary_corrected.correct_to_incorrect"
    ]["maximum_count"] = 1
    thresholds["guardrails"][
        "no_glossary_corrected.correct_to_incorrect"
    ]["maximum_count"] = 0
    write_json(path, thresholds)


class FourStateFixture:
    def __init__(self, root: Path) -> None:
        self.reference = root / "reference.segments.json"
        self.terms = root / "terms.json"
        self.thresholds = root / "thresholds.json"
        write_json(self.reference, segments_document(REFERENCE_TEXTS))
        write_json(
            self.terms,
            [
                {"term": "Maccheroni", "reference_count": 1},
                {"term": "Qwen3-ASR", "reference_count": 1},
            ],
        )
        write_placeholder_thresholds(self.thresholds)
        runs = root / "runs"
        self.no_glossary = create_run(
            runs,
            run_id="fixture-no-glossary",
            raw_texts=NO_GLOSSARY_TEXTS,
            decode_glossary=False,
        )
        self.decode_glossary = create_run(
            runs,
            run_id="fixture-decode-glossary",
            raw_texts=DECODE_GLOSSARY_TEXTS,
            decode_glossary=True,
        )
        self.decode_glossary_derived_id = create_derived(
            self.decode_glossary,
            derived_id="derived-decode-corrected",
            corrected_texts=DECODE_CORRECTED_TEXTS,
            conflicts=[
                {
                    "segment_index": 0,
                    "original_text": REFERENCE_TEXTS[0],
                    "candidate_text": NO_GLOSSARY_TEXTS[0],
                    "reason": "Synthetic uncertain regression",
                }
            ],
        )
        self.no_glossary_derived_id = create_derived(
            self.no_glossary,
            derived_id="derived-no-glossary-corrected",
            corrected_texts=NO_GLOSSARY_CORRECTED_TEXTS,
            conflicts=[
                {
                    "segment_index": 3,
                    "original_text": NO_GLOSSARY_TEXTS[3],
                    "candidate_text": REFERENCE_TEXTS[3],
                    "reason": "Synthetic uncertain repair",
                }
            ],
        )

    def compare(self) -> dict[str, object]:
        return compare_correction_paths(
            reference_path=self.reference,
            terms_path=self.terms,
            no_glossary_run=self.no_glossary,
            decode_glossary_run=self.decode_glossary,
            decode_glossary_derived_id=self.decode_glossary_derived_id,
            no_glossary_derived_id=self.no_glossary_derived_id,
            thresholds_path=self.thresholds,
        )

    def cli_arguments(self, output: Path) -> list[str]:
        return [
            "--reference",
            str(self.reference),
            "--terms",
            str(self.terms),
            "--no-glossary-run",
            str(self.no_glossary),
            "--decode-glossary-run",
            str(self.decode_glossary),
            "--decode-glossary-derived-id",
            self.decode_glossary_derived_id,
            "--no-glossary-derived-id",
            self.no_glossary_derived_id,
            "--thresholds",
            str(self.thresholds),
            "--output",
            str(output),
        ]


def rewrite_manifest(run: Path, update) -> None:
    path = run / "manifest.json"
    manifest = load_json(path)
    update(manifest)
    write_json(path, manifest)


def rewrite_derived_manifest(run: Path, derived_id: str, update) -> None:
    path = run / "derived" / derived_id / "manifest.json"
    manifest = load_json(path)
    update(manifest)
    write_json(path, manifest)


def rewrite_derived_artifact(
    run: Path, derived_id: str, relative: str, update
) -> None:
    root = run / "derived" / derived_id
    path = root / relative
    document = load_json(path)
    update(document)
    write_json(path, document)

    def reseal(manifest: dict[str, object]) -> None:
        artifact = next(
            value for value in manifest["artifacts"]
            if value["path"] == relative
        )
        artifact["sha256"] = file_sha256(path)

    rewrite_derived_manifest(run, derived_id, reseal)


def replace_run_source(run: Path, source_sha256: str) -> None:
    for relative in (
        "primary/segments.json",
        "merged/segments.json",
        "postprocess/segments.json",
    ):
        path = run / relative
        if not path.exists():
            continue
        document = load_json(path)
        document["source"]["sha256"] = source_sha256
        write_json(path, document)

    def update(manifest: dict[str, object]) -> None:
        manifest["input"]["sha256"] = source_sha256
        artifacts = manifest["artifacts"]
        for artifact in artifacts:
            artifact["sha256"] = file_sha256(run / str(artifact["path"]))

    rewrite_manifest(run, update)


class CompareCorrectionPathsTests(unittest.TestCase):
    def assert_metric(
        self,
        metrics: dict[str, object],
        *,
        cer_errors: int,
        cer_rate: float,
        wer_errors: int,
        wer_rate: float,
        term_recall: float,
        omissions: int,
    ) -> None:
        self.assertEqual(metrics["cer"]["errors"], cer_errors)
        self.assertEqual(metrics["cer"]["reference_units"], 81)
        self.assertEqual(metrics["cer"]["error_rate"], cer_rate)
        self.assertEqual(metrics["wer"]["errors"], wer_errors)
        self.assertEqual(metrics["wer"]["reference_units"], 12)
        self.assertEqual(metrics["wer"]["error_rate"], wer_rate)
        self.assertEqual(metrics["terms"]["term_recall"], term_recall)
        self.assertEqual(
            metrics["omissions"]["omitted_utterances"], omissions
        )

    def assert_delta(
        self,
        comparison: dict[str, object],
        metric: str,
        *,
        baseline: float | int,
        candidate: float | int,
        better_when: str,
        improvement: float | int,
        status: str,
    ) -> None:
        value = comparison["metrics"][metric]
        self.assertEqual(value["baseline"], baseline)
        self.assertEqual(value["candidate"], candidate)
        self.assertEqual(
            value["candidate_minus_baseline"], candidate - baseline
        )
        self.assertEqual(value["better_when"], better_when)
        self.assertEqual(value["improvement"], improvement)
        self.assertEqual(value["status"], status)

    def test_four_state_metrics_deltas_activity_and_placeholder_verdict(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = FourStateFixture(Path(temporary))
            verdict = fixture.compare()

            self.assertEqual(verdict["schema_version"], "1.0.0")
            self.assertEqual(verdict["status"], "not_configured")
            self.assertIsNone(verdict["passed"])
            states = verdict["states"]
            self.assert_metric(
                states["no_glossary"]["raw"]["metrics"],
                cer_errors=27,
                cer_rate=27 / 81,
                wer_errors=7,
                wer_rate=7 / 12,
                term_recall=0.0,
                omissions=1,
            )
            self.assert_metric(
                states["decode_glossary"]["raw"]["metrics"],
                cer_errors=19,
                cer_rate=19 / 81,
                wer_errors=3,
                wer_rate=3 / 12,
                term_recall=1.0,
                omissions=1,
            )
            self.assert_metric(
                states["decode_glossary_corrected"]["corrected"]["metrics"],
                cer_errors=6,
                cer_rate=6 / 81,
                wer_errors=1,
                wer_rate=1 / 12,
                term_recall=1.0,
                omissions=0,
            )
            self.assert_metric(
                states["no_glossary_corrected"]["corrected"]["metrics"],
                cer_errors=19,
                cer_rate=19 / 81,
                wer_errors=3,
                wer_rate=3 / 12,
                term_recall=1.0,
                omissions=1,
            )

            comparisons = verdict["comparisons"]
            decode = comparisons["decode_time_injection_gain"]
            self.assertEqual(
                decode["baseline"], {"state": "no_glossary", "output": "raw"}
            )
            self.assertEqual(
                decode["candidate"],
                {"state": "decode_glossary", "output": "raw"},
            )
            self.assert_delta(
                decode,
                "cer.error_rate",
                baseline=27 / 81,
                candidate=19 / 81,
                better_when="lower",
                improvement=8 / 81,
                status="improved",
            )
            self.assert_delta(
                decode,
                "wer.error_rate",
                baseline=7 / 12,
                candidate=3 / 12,
                better_when="lower",
                improvement=4 / 12,
                status="improved",
            )
            self.assert_delta(
                decode,
                "terms.term_recall",
                baseline=0.0,
                candidate=1.0,
                better_when="higher",
                improvement=1.0,
                status="improved",
            )
            self.assert_delta(
                decode,
                "omissions.omitted_utterances",
                baseline=1,
                candidate=1,
                better_when="lower",
                improvement=0,
                status="unchanged",
            )

            correction = comparisons["correction_gain"]
            self.assertEqual(
                correction["baseline"],
                {"state": "decode_glossary_corrected", "output": "raw"},
            )
            self.assertEqual(
                correction["candidate"],
                {"state": "decode_glossary_corrected", "output": "corrected"},
            )
            self.assert_delta(
                correction,
                "cer.error_rate",
                baseline=19 / 81,
                candidate=6 / 81,
                better_when="lower",
                improvement=13 / 81,
                status="improved",
            )
            self.assert_delta(
                correction,
                "wer.error_rate",
                baseline=3 / 12,
                candidate=1 / 12,
                better_when="lower",
                improvement=2 / 12,
                status="improved",
            )
            self.assert_delta(
                correction,
                "terms.term_recall",
                baseline=1.0,
                candidate=1.0,
                better_when="higher",
                improvement=0.0,
                status="unchanged",
            )
            self.assert_delta(
                correction,
                "omissions.omitted_utterances",
                baseline=1,
                candidate=0,
                better_when="lower",
                improvement=1,
                status="improved",
            )

            correction_without_decode = comparisons[
                "correction_gain_without_decode_time_injection"
            ]
            self.assertEqual(
                correction_without_decode["baseline"],
                {"state": "no_glossary_corrected", "output": "raw"},
            )
            self.assertEqual(
                correction_without_decode["candidate"],
                {"state": "no_glossary_corrected", "output": "corrected"},
            )
            self.assert_delta(
                correction_without_decode,
                "cer.error_rate",
                baseline=27 / 81,
                candidate=19 / 81,
                better_when="lower",
                improvement=8 / 81,
                status="improved",
            )
            self.assert_delta(
                correction_without_decode,
                "wer.error_rate",
                baseline=7 / 12,
                candidate=3 / 12,
                better_when="lower",
                improvement=4 / 12,
                status="improved",
            )
            self.assert_delta(
                correction_without_decode,
                "terms.term_recall",
                baseline=0.0,
                candidate=1.0,
                better_when="higher",
                improvement=1.0,
                status="improved",
            )
            self.assert_delta(
                correction_without_decode,
                "omissions.omitted_utterances",
                baseline=1,
                candidate=1,
                better_when="lower",
                improvement=0,
                status="unchanged",
            )

            decode_activity = states["decode_glossary_corrected"][
                "correction_activity"
            ]
            self.assertEqual(decode_activity["applied"], 2)
            self.assertEqual(decode_activity["review"], 1)
            self.assertEqual(decode_activity["total_proposals"], 3)
            decode_effects = states["decode_glossary_corrected"][
                "correction_effects"
            ]
            self.assertEqual(decode_effects["closer"], 1)
            self.assertEqual(decode_effects["worse"], 1)
            self.assertEqual(decode_effects["correct_to_incorrect"], 1)

            no_decode_activity = states["no_glossary_corrected"][
                "correction_activity"
            ]
            self.assertEqual(no_decode_activity["applied"], 2)
            self.assertEqual(no_decode_activity["review"], 1)
            self.assertEqual(no_decode_activity["total_proposals"], 3)
            no_decode_effects = states["no_glossary_corrected"][
                "correction_effects"
            ]
            self.assertEqual(no_decode_effects["closer"], 2)
            self.assertEqual(no_decode_effects["worse"], 0)
            self.assertEqual(no_decode_effects["correct_to_incorrect"], 0)

    def test_cli_refuses_to_overwrite_an_existing_verdict(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = FourStateFixture(root)
            output = root / "verdict.json"
            output.write_text("sentinel\n", encoding="utf-8")

            with self.assertRaises(FileExistsError):
                main(fixture.cli_arguments(output))

            self.assertEqual(output.read_text(encoding="utf-8"), "sentinel\n")

    def test_cli_creates_a_placeholder_verdict_from_selected_derived_sets(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = FourStateFixture(root)
            output = root / "verdict.json"

            with redirect_stdout(io.StringIO()):
                exit_code = main(fixture.cli_arguments(output))
            self.assertEqual(exit_code, 0)

            verdict = load_json(output)
            self.assertEqual(verdict["status"], "not_configured")
            self.assertIsNone(verdict["passed"])
            self.assertEqual(
                verdict["states"]["decode_glossary_corrected"]["derived_id"],
                fixture.decode_glossary_derived_id,
            )
            self.assertEqual(
                verdict["states"]["no_glossary_corrected"]["derived_id"],
                fixture.no_glossary_derived_id,
            )

    def test_rejects_source_and_derived_hash_tampering(self) -> None:
        mutations = ("source_artifact", "source_manifest", "derived_artifact")
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                with tempfile.TemporaryDirectory() as temporary:
                    fixture = FourStateFixture(Path(temporary))
                    if mutation == "source_artifact":
                        path = fixture.decode_glossary / "merged/segments.json"
                        path.write_bytes(path.read_bytes() + b" \n")
                    elif mutation == "source_manifest":
                        rewrite_manifest(
                            fixture.decode_glossary,
                            lambda manifest: manifest.update(
                                {"peak_memory_bytes": 2}
                            ),
                        )
                    else:
                        path = (
                            fixture.decode_glossary
                            / "derived"
                            / fixture.decode_glossary_derived_id
                            / "postprocess/segments.json"
                        )
                        path.write_bytes(path.read_bytes() + b" \n")
                    with self.assertRaisesRegex(
                        ValueError, r"hash mismatch|source lineage"
                    ):
                        fixture.compare()

    def test_rejects_mutated_selected_derived_id(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = FourStateFixture(Path(temporary))
            rewrite_derived_manifest(
                fixture.decode_glossary,
                fixture.decode_glossary_derived_id,
                lambda manifest: manifest.update({"derived_id": "different-id"}),
            )
            with self.assertRaisesRegex(ValueError, r"selected derived ID"):
                fixture.compare()

    def test_rejects_derived_speaker_timestamp_source_and_coverage_mutation(self) -> None:
        mutations = {
            "speaker": lambda document: document["segments"][1].update(
                {"speaker": "SPEAKER_99"}
            ),
            "timestamp": lambda document: document["segments"][1].update(
                {"end_s": 1.75}
            ),
            "source": lambda document: document["source"].update(
                {"sha256": OTHER_SOURCE_SHA256}
            ),
            "coverage": lambda document: document["segments"].pop(),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                with tempfile.TemporaryDirectory() as temporary:
                    fixture = FourStateFixture(Path(temporary))
                    rewrite_derived_artifact(
                        fixture.decode_glossary,
                        fixture.decode_glossary_derived_id,
                        "postprocess/segments.json",
                        mutate,
                    )
                    with self.assertRaisesRegex(
                        ValueError,
                        r"speaker|immutable|source|segment|schema|semantics",
                    ):
                        fixture.compare()

    def test_rejects_mismatched_derived_profile_and_model_identity(self) -> None:
        mutations = {
            "profile": lambda manifest: manifest["operation"].update(
                {"profile_name": "different-profile"}
            ),
            "model": lambda manifest: manifest["postprocess"].update(
                {"model_id": "different/model"}
            ),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                with tempfile.TemporaryDirectory() as temporary:
                    fixture = FourStateFixture(Path(temporary))
                    rewrite_derived_manifest(
                        fixture.no_glossary,
                        fixture.no_glossary_derived_id,
                        mutate,
                    )
                    with self.assertRaisesRegex(
                        ValueError, r"mismatched.*(profile|model)"
                    ):
                        fixture.compare()

    def test_default_comparator_rejects_mutable_root_postprocess_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = FourStateFixture(Path(temporary))
            write_json(
                fixture.no_glossary / "postprocess/segments.json",
                segments_document(NO_GLOSSARY_TEXTS),
            )
            with self.assertRaisesRegex(
                ValueError, r"inventory|mutable root postprocess"
            ):
                fixture.compare()

    def test_rejects_a_foreign_reference_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = FourStateFixture(Path(temporary))
            reference = load_json(fixture.reference)
            reference["source"]["sha256"] = OTHER_SOURCE_SHA256
            write_json(fixture.reference, reference)

            with self.assertRaisesRegex(ValueError, r"reference source identity"):
                fixture.compare()

    def test_rejects_unlisted_and_symlinked_source_artifacts(self) -> None:
        mutations = ("unlisted", "symlink", "duplicate_required_kind")
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                with tempfile.TemporaryDirectory() as temporary:
                    fixture = FourStateFixture(Path(temporary))
                    if mutation == "unlisted":
                        (fixture.no_glossary / "unlisted.txt").write_text(
                            "synthetic unlisted evidence\n", encoding="utf-8"
                        )
                    elif mutation == "symlink":
                        merged = fixture.no_glossary / "merged/segments.json"
                        merged.unlink()
                        merged.symlink_to("../primary/segments.json")
                    else:
                        scores = fixture.no_glossary / "scores.json"
                        write_json(scores, {"synthetic": True})
                        rewrite_manifest(
                            fixture.no_glossary,
                            lambda manifest: manifest["artifacts"].append(
                                {
                                    "kind": "primary_raw",
                                    "path": "scores.json",
                                    "sha256": file_sha256(scores),
                                }
                            ),
                        )

                    with self.assertRaisesRegex(
                        ValueError,
                        r"inventory|symbolic link|unsafe|exactly one canonical",
                    ):
                        fixture.compare()

    def test_cli_rejects_outputs_inside_source_and_selected_derived_trees(self) -> None:
        locations = ("source", "derived")
        for location in locations:
            with self.subTest(location=location):
                with tempfile.TemporaryDirectory() as temporary:
                    fixture = FourStateFixture(Path(temporary))
                    if location == "source":
                        output = fixture.no_glossary / "verdict.json"
                    else:
                        output = (
                            fixture.decode_glossary
                            / "derived"
                            / fixture.decode_glossary_derived_id
                            / "verdict.json"
                        )
                    before = {
                        "no_glossary": tree_hashes(fixture.no_glossary),
                        "decode_glossary": tree_hashes(fixture.decode_glossary),
                    }

                    with self.assertRaisesRegex(
                        ValueError, r"outside immutable input tree"
                    ):
                        main(fixture.cli_arguments(output))

                    self.assertFalse(output.exists())
                    self.assertEqual(
                        before,
                        {
                            "no_glossary": tree_hashes(fixture.no_glossary),
                            "decode_glossary": tree_hashes(fixture.decode_glossary),
                        },
                    )

    def test_rejects_a_glossary_role_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = FourStateFixture(Path(temporary))

            def remove_glossary(manifest: dict[str, object]) -> None:
                manifest["glossary"] = {
                    "provided": False,
                    "sha256": None,
                    "item_count": 0,
                    "injection_mode": "none",
                    "applied": False,
                }

            rewrite_manifest(fixture.decode_glossary, remove_glossary)
            with self.assertRaisesRegex(ValueError, "[Gg]lossary"):
                fixture.compare()

    def test_rejects_runs_with_different_sources(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = FourStateFixture(Path(temporary))
            replace_run_source(
                fixture.no_glossary,
                OTHER_SOURCE_SHA256,
            )
            with self.assertRaisesRegex(ValueError, "source"):
                fixture.compare()

    def test_rejects_translation_in_a_corrected_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = FourStateFixture(Path(temporary))

            def make_translation(manifest: dict[str, object]) -> None:
                postprocess = manifest["postprocess"]
                postprocess["mode"] = "translation"
                postprocess["target_language"] = "en"
                postprocess["source_segments_sha256"] = "2" * 64

            rewrite_derived_manifest(
                fixture.decode_glossary,
                fixture.decode_glossary_derived_id,
                make_translation,
            )
            with self.assertRaisesRegex(ValueError, r"translation|correction|schema"):
                fixture.compare()

    def test_rejects_succeeded_truncated_and_incomplete_runs(self) -> None:
        hostile_coverages = {
            "truncated": {
                "input_duration_s": 10.0,
                "processed_duration_s": 1.0,
                "truncated": True,
                "strategy": "backend_truncated",
                "chunks_planned": 1,
                "chunks_completed": 0,
                "message": "hostile truncated run",
            },
            "incomplete": {
                "input_duration_s": 10.0,
                "processed_duration_s": 1.0,
                "truncated": False,
                "strategy": "full",
                "chunks_planned": 1,
                "chunks_completed": 0,
            },
        }
        for name, coverage in hostile_coverages.items():
            with self.subTest(name=name):
                with tempfile.TemporaryDirectory() as temporary:
                    fixture = FourStateFixture(Path(temporary))
                    for run in (
                        fixture.no_glossary,
                        fixture.decode_glossary,
                    ):
                        rewrite_manifest(
                            run,
                            lambda manifest, value=coverage: manifest.update(
                                {"coverage": deepcopy(value)}
                            ),
                        )

                    with self.assertRaisesRegex(
                        ValueError,
                        r"truncated|successful run|full input|chunks_completed|False",
                    ):
                        fixture.compare()

    def test_rejects_failed_gapped_overlapping_and_incomplete_chunk_coverage(self) -> None:
        def failed(manifest: dict[str, object]) -> None:
            manifest["chunk_boundaries"][0]["status"] = "failed"

        def chunked(
            manifest: dict[str, object],
            first_end: float,
            second_start: float,
            second_end: float = 4.0,
        ) -> None:
            manifest["coverage"].update(
                {
                    "strategy": "chunked",
                    "chunks_planned": 2,
                    "chunks_completed": 2,
                    "processed_duration_s": 4.0,
                    "truncated": False,
                }
            )
            manifest["chunk_boundaries"] = [
                {
                    "index": 0,
                    "start_s": 0.0,
                    "end_s": first_end,
                    "status": "succeeded",
                },
                {
                    "index": 1,
                    "start_s": second_start,
                    "end_s": second_end,
                    "status": "succeeded",
                },
            ]

        mutations = {
            "failed": failed,
            "gap": lambda manifest: chunked(manifest, 1.9, 2.1),
            "overlap": lambda manifest: chunked(manifest, 2.1, 1.9),
            "incomplete": lambda manifest: chunked(manifest, 2.0, 2.0, 3.9),
            "truncated": lambda manifest: manifest["coverage"].update(
                {"truncated": True}
            ),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                with tempfile.TemporaryDirectory() as temporary:
                    fixture = FourStateFixture(Path(temporary))
                    rewrite_manifest(fixture.decode_glossary, mutate)

                    with self.assertRaisesRegex(
                        ValueError,
                        r"coverage|boundary|truncated|successful run",
                    ):
                        fixture.compare()

    def test_standalone_current_scorer_rejects_an_unapplied_source_glossary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = FourStateFixture(Path(temporary))
            rewrite_manifest(
                fixture.decode_glossary,
                lambda manifest: manifest["glossary"].update({"applied": False}),
            )
            rewrite_derived_manifest(
                fixture.decode_glossary,
                fixture.decode_glossary_derived_id,
                lambda manifest: manifest["source"].update(
                    {
                        "manifest_sha256": file_sha256(
                            fixture.decode_glossary / "manifest.json"
                        )
                    }
                ),
            )

            with self.assertRaisesRegex(ValueError, r"did not apply.*glossary"):
                score_corrected_run(
                    fixture.decode_glossary,
                    fixture.reference,
                    fixture.terms,
                    derived_id=fixture.decode_glossary_derived_id,
                )

    def test_rejects_nonfinite_source_derived_and_segment_numbers(self) -> None:
        mutations = ("source_nan", "derived_nan", "source_infinity", "derived_infinity")
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                with tempfile.TemporaryDirectory() as temporary:
                    fixture = FourStateFixture(Path(temporary))
                    if mutation == "source_nan":
                        rewrite_manifest(
                            fixture.decode_glossary,
                            lambda manifest: manifest["coverage"].update(
                                {"input_duration_s": float("nan")}
                            ),
                        )
                    elif mutation == "derived_nan":
                        rewrite_derived_manifest(
                            fixture.decode_glossary,
                            fixture.decode_glossary_derived_id,
                            lambda manifest: manifest["timing"].update(
                                {"wall_time_s": float("nan")}
                            ),
                        )
                    elif mutation == "source_infinity":
                        path = fixture.decode_glossary / "merged/segments.json"
                        document = load_json(path)
                        document["segments"][0]["end_s"] = float("inf")
                        write_json(path, document)
                        rewrite_manifest(
                            fixture.decode_glossary,
                            lambda manifest: next(
                                artifact for artifact in manifest["artifacts"]
                                if artifact["path"] == "merged/segments.json"
                            ).update({"sha256": file_sha256(path)}),
                        )
                    else:
                        rewrite_derived_artifact(
                            fixture.decode_glossary,
                            fixture.decode_glossary_derived_id,
                            "postprocess/segments.json",
                            lambda document: document["segments"][0].update(
                                {"start_s": float("-inf")}
                            ),
                        )

                    with self.assertRaisesRegex(
                        ValueError, r"non-finite|cannot read"
                    ):
                        fixture.compare()

    def test_current_derived_manifest_requires_explicit_correction_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = FourStateFixture(Path(temporary))
            rewrite_derived_manifest(
                fixture.decode_glossary,
                fixture.decode_glossary_derived_id,
                lambda manifest: manifest["postprocess"].pop("mode"),
            )
            with self.assertRaisesRegex(ValueError, r"schema|mode"):
                fixture.compare()

    def test_safety_guardrail_fails_closed_when_an_applied_change_is_unscorable(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = FourStateFixture(Path(temporary))
            reference = load_json(fixture.reference)
            reference["segments"][0]["start_s"] = 0.01
            write_json(fixture.reference, reference)
            configure_permissive_thresholds(fixture.thresholds)

            verdict = fixture.compare()

            self.assertEqual(verdict["status"], "failed")
            self.assertIs(verdict["passed"], False)
            effects = verdict["states"]["no_glossary_corrected"][
                "correction_effects"
            ]
            self.assertEqual(effects["unscorable"], 1)
            self.assertIsNone(effects["correction_made_worse_count"])
            check = next(
                check
                for check in verdict["threshold_evaluation"]["checks"]
                if check.get("guardrail")
                == "no_glossary_corrected.correct_to_incorrect"
            )
            self.assertIs(check["passed"], False)
            self.assertEqual(check["reason"], "unscorable > 0")
            self.assertEqual(check["unscorable"], 1)


if __name__ == "__main__":
    unittest.main()
