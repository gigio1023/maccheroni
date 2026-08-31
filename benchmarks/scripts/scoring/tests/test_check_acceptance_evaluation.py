from __future__ import annotations

from copy import deepcopy
from hashlib import sha256
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import wave


SCORING = Path(__file__).resolve().parents[1]
REPOSITORY = SCORING.parents[2]
sys.path.insert(0, str(SCORING))

import check_acceptance_evaluation as evaluation_module  # noqa: E402
from check_acceptance_evaluation import (  # noqa: E402
    MINIMUM_ACCEPTANCE_MEMORY_BYTES,
    EvaluationError,
    acceptance_memory_supported,
    create_evaluation,
    snapshot_tree,
    validate_exact_partition,
    validate_runner_evidence,
    verify_evaluation,
    vibevoice_glossary_payload_sha256,
)


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def digest(path: Path) -> str:
    return sha256(path.read_bytes()).hexdigest()


def write_wav(path: Path, seconds: int = 2) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(16_000)
        output.writeframes(b"\0\0" * 16_000 * seconds)


class AcceptanceEvaluationTests(unittest.TestCase):
    @staticmethod
    def reseal_manifest_artifact(
        manifest: dict[str, object], run: Path, relative: str
    ) -> None:
        for artifact in manifest["artifacts"]:
            if artifact["path"] == relative:
                artifact["sha256"] = digest(run / relative)
                return
        manifest["artifacts"].append(
            {"kind": "synthetic_adversarial", "path": relative, "sha256": digest(run / relative)}
        )

    @staticmethod
    def make_fake_runner_commands(root: Path) -> Path:
        binaries = root / "fake-bin"
        binaries.mkdir()
        uv = binaries / "uv"
        uv.write_text(
            """#!/bin/sh
command=$6
case "$command" in
  preflight) printf '%s\\n' '{"fixture_id":"synthetic","model_started":false,"passed":true}' ;;
  memory-check) printf '%s\\n' '{"passed":true}' ;;
  create)
    shift 6
    output=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--output" ]; then output=$2; break; fi
      shift
    done
    mkdir -p "$output"
    printf '{}\\n' >"$output/evaluation.json"
    printf '{}\\n' >"$output/scores.json"
    printf '%s\\n' '{"evaluation_id":"synthetic","passed":true}'
    ;;
  verify) exit 0 ;;
  *) exit 2 ;;
esac
""",
            encoding="utf-8",
        )
        uv.chmod(0o700)
        (binaries / "pgrep").write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
        (binaries / "pgrep").chmod(0o700)
        (binaries / "sysctl").write_text(
            "#!/bin/sh\nprintf '%s\\n' 68719476736\n",
            encoding="utf-8",
        )
        (binaries / "sysctl").chmod(0o700)
        return binaries

    def make_case(self, root: Path, fixture_id: str) -> tuple[Path, Path, Path]:
        # Synthetic fixtures inject a bounded in-process source verifier. Public
        # CLI execution always uses the canonical pack and source-derived replay.
        evaluation_module.verify_source_derived_fixture = lambda *_args: None
        acceptance = root / "acceptance"
        fixture = acceptance / "prepared" / fixture_id
        source_blob = acceptance / "sources" / "public.bin"
        source_blob.parent.mkdir(parents=True)
        source_blob.write_bytes(b"public synthetic fixture source\n")

        if fixture_id == "hike-code-switch-v1":
            input_path = fixture / "input.wav"
        else:
            input_path = acceptance / "sources" / "ami" / "IN1009.Mix-Headset.wav"
        write_wav(input_path)
        input_hash = digest(input_path)
        source = {
            "file_name": input_path.name,
            "sha256": input_hash,
            "duration_s": 2.0,
        }
        reference = {
            "schema_version": "1.0.0",
            "segments": [
                {
                    "speaker": "SPEAKER_00" if fixture_id.startswith("ami") else "UNASSIGNED",
                    "start_s": 0.0,
                    "end_s": 2.0,
                    "text": "hello API",
                    "language": "en",
                }
            ],
            "num_speakers": 1 if fixture_id.startswith("ami") else 0,
            "source": source,
        }
        terms = [{"term": "API", "reference_count": 1}]
        write_json(fixture / "reference.segments.json", reference)
        write_json(fixture / "terms.json", terms)
        (fixture / "glossary.txt").write_text("API\n", encoding="utf-8")
        write_json(fixture / "selection.json", {"fixture_id": fixture_id})
        if fixture_id == "ami-in1009-ihm-mix-v1":
            (fixture / "reference.rttm").write_text(
                "SPEAKER IN1009 1 0.000000 2.000000 <NA> <NA> MIO001 <NA> <NA>\n",
                encoding="utf-8",
            )

        artifacts = {
            relative: digest(fixture / relative)
            for relative in (
                "reference.segments.json",
                "terms.json",
                "glossary.txt",
                "selection.json",
            )
        }
        if fixture_id == "hike-code-switch-v1":
            artifacts["input.wav"] = input_hash
        else:
            artifacts["reference.rttm"] = digest(fixture / "reference.rttm")
        source_hashes = {"sources/public.bin": digest(source_blob)}
        if fixture_id == "ami-in1009-ihm-mix-v1":
            source_hashes["sources/ami/IN1009.Mix-Headset.wav"] = input_hash
        pack_manifest = root / "acceptance-pack-v1.json"
        write_json(
            pack_manifest,
            {
                "schema_version": "1.0.0",
                "fixtures": [
                    {
                        "fixture_id": fixture_id,
                        "source": {
                            "files": [
                                {"relative_path": relative, "sha256": value}
                                for relative, value in source_hashes.items()
                            ]
                        },
                    }
                ],
            },
        )
        evaluation_module.PACK_MANIFEST = pack_manifest
        write_json(
            fixture / "fixture-check.json",
            {
                "fixture_id": fixture_id,
                "passed": True,
                "source_hashes_before": source_hashes,
                "source_hashes_after": source_hashes,
                "artifact_sha256": artifacts,
                "input_wav": {
                    "sha256": input_hash,
                    "size_bytes": input_path.stat().st_size,
                    "duration_s": 2.0,
                    "sample_rate_hz": 16_000,
                    "channels": 1,
                    "sample_width_bytes": 2,
                },
                "reference_segment_count": 1,
                "term_count": 1,
            },
        )
        run = self.make_source_run(root, input_path, fixture / "glossary.txt", reference)
        return fixture, input_path, run

    def make_source_run(
        self,
        root: Path,
        input_path: Path,
        glossary: Path,
        reference: dict[str, object],
    ) -> Path:
        run = root / "source-run"
        primary = deepcopy(reference)
        primary["segments"][0]["speaker"] = "UNASSIGNED"
        primary["num_speakers"] = 0
        merged = deepcopy(reference)
        merged["segments"][0]["speaker"] = "SPEAKER_00"
        merged["num_speakers"] = 1
        (run / "primary").mkdir(parents=True)
        preprocessed_relative = "preprocess/normalized.wav"
        write_wav(run / preprocessed_relative)
        (run / "primary/raw.txt").write_text("hello API\n", encoding="utf-8")
        write_json(run / "primary/segments.json", primary)
        write_json(
            run / "diarization/timeline.json",
            [{"speaker": "SPEAKER_00", "start_s": 0.0, "end_s": 2.0}],
        )
        write_json(run / "merged/segments.json", merged)
        write_json(run / "merged/conflicts.json", [])
        glossary_record = {
            "provided": True,
            "sha256": digest(glossary),
            "item_count": 1,
            "injection_mode": "free_text_context",
            "applied": True,
        }
        attempt = run / "primary/attempts/chunk-0"
        write_wav(attempt / "audio.wav")
        audio_hash = digest(attempt / "audio.wav")
        request_relative = "primary/attempts/chunk-0/request.json"
        runner_relative = "primary/attempts/chunk-0/runner-record.json"
        raw_relative = "primary/attempts/chunk-0/backend.raw"
        result_relative = "primary/attempts/chunk-0/result.json"
        outcome_relative = "primary/attempts/chunk-0/outcome.json"
        promotion_relative = "primary/promotion.json"
        write_json(
            run / request_relative,
            {
                "attempt_id": "chunk-0",
                "root_chunk_index": 0,
                "start_sample": 0,
                "end_sample": 32_000,
                "sample_rate_hz": 16_000,
                "audio_path": "primary/attempts/chunk-0/audio.wav",
                "audio_sha256": audio_hash,
                "backend": "vibevoice",
                "language": "auto",
                "model": {
                    "role": "asr",
                    "hf_model_id": "mlx-community/VibeVoice-ASR-8bit",
                    "revision": "725c72e54d6ef875472c27fbc50fab470a960940",
                    "quantization": "int8",
                },
                "glossary": {**glossary_record, "applied": False},
            },
        )
        write_json(run / result_relative, {"raw_text": "hello API", "segments": merged["segments"]})
        (run / raw_relative).write_text("synthetic backend evidence\n", encoding="utf-8")
        payload_hash = vibevoice_glossary_payload_sha256(glossary)
        canonical_payload_hash = digest(glossary)
        write_json(
            run / runner_relative,
            {
                "backend": "vibevoice",
                "model": {
                    "role": "asr",
                    "hf_model_id": "mlx-community/VibeVoice-ASR-8bit",
                    "revision": "725c72e54d6ef875472c27fbc50fab470a960940",
                    "quantization": "int8",
                },
                "outcome": "complete",
                "stop_reason": "endOfSequence",
                "terminal_evidence": "observed",
                "coverage": {"input_duration_s": 2.0, "processed_duration_s": 2.0, "truncated": False},
                "input": {"sha256_before": audio_hash, "sha256_after": audio_hash},
                "language": {
                    "requested": "auto",
                    "instruction_sha256": payload_hash,
                    "prompt_guidance_applied": False,
                },
                "glossary": {
                    **glossary_record,
                    "canonical_payload_sha256": canonical_payload_hash,
                    "payload_sha256": payload_hash,
                    "payload_entry_count": 1,
                    "instruction_sha256": payload_hash,
                },
            },
        )
        write_json(
            run / outcome_relative,
            {
                "attempt_id": "chunk-0",
                "status": "eos_complete",
                "stop_reason": "endOfSequence",
                "canonical_promoted": False,
                "child_attempt_ids": [],
                "request_sha256": digest(run / request_relative),
                "runner_record_path": runner_relative,
                "runner_record_sha256": digest(run / runner_relative),
                "backend_raw_path": raw_relative,
                "backend_raw_sha256": digest(run / raw_relative),
                "result_path": result_relative,
                "result_sha256": digest(run / result_relative),
                "glossary": glossary_record,
                "glossary_payload_sha256": payload_hash,
                "glossary_payload_entry_count": 1,
                "language": {
                    "requested": "auto",
                    "instruction_sha256": payload_hash,
                    "prompt_guidance_applied": False,
                },
                "error_code": None,
                "error_message": None,
            },
        )
        root_audio_relative = "primary/chunks/0/audio.wav"
        root_index_relative = "primary/chunks/0/backend.raw"
        write_wav(run / root_audio_relative)
        write_json(
            run / root_index_relative,
            {
                "schema_version": "1.0.0",
                "root_chunk_index": 0,
                "root_attempt_id": "chunk-0000-root",
                "eos_leaf_attempt_ids": ["chunk-0"],
                "eos_leaf_result_sha256": [digest(run / result_relative)],
            },
        )
        canonical_paths = (
            "primary/raw.txt",
            "primary/segments.json",
            "merged/segments.json",
            "merged/conflicts.json",
        )
        write_json(
            run / promotion_relative,
            {
                "schema_version": "1.0.0",
                "input_sha256_before": digest(input_path),
                "input_sha256_at_promotion": digest(input_path),
                "eos_leaf_attempt_ids": ["chunk-0"],
                "eos_leaf_result_sha256": [digest(run / result_relative)],
                "canonical_artifact_sha256": {
                    relative: digest(run / relative) for relative in canonical_paths
                },
            },
        )
        paths = (
            "primary/raw.txt",
            "primary/segments.json",
            "diarization/timeline.json",
            "merged/segments.json",
            "merged/conflicts.json",
            "primary/attempts/chunk-0/audio.wav",
            request_relative,
            runner_relative,
            raw_relative,
            result_relative,
            outcome_relative,
            promotion_relative,
            root_audio_relative,
            root_index_relative,
            preprocessed_relative,
        )
        manifest = {
            "schema_version": "1.0.0",
            "run_id": "synthetic-source-run",
            "status": "succeeded",
            "input": {
                "file_name": input_path.name,
                "sha256": digest(input_path),
                "size_bytes": input_path.stat().st_size,
            },
            "backend": {"name": "mlx-audio-vibevoice", "version": "0.4.6"},
            "models": [
                {
                    "role": "asr",
                    "hf_model_id": "mlx-community/VibeVoice-ASR-8bit",
                    "revision": "725c72e54d6ef875472c27fbc50fab470a960940",
                    "quantization": "int8",
                },
                {
                    "role": "vad",
                    "hf_model_id": "aufklarer/Silero-VAD-v6.2.1-CoreML",
                    "revision": "523876545a57961474fee9df913e833e130560b8",
                    "quantization": "coreml-float16",
                },
                {
                    "role": "diarization",
                    "hf_model_id": "aufklarer/Pyannote-Community-1-CoreML",
                    "revision": "a14e6c420d56e8472850649b016a486fd0acbe81",
                    "quantization": "coreml-fp32",
                },
            ],
            "glossary": glossary_record,
            "preprocessing": {
                "sample_rate_hz": 16_000,
                "channels": 1,
                "peak_normalization": True,
                "vad": {"enabled": True, "backend": "silero"},
                "enhancement": {"enabled": False, "backend": None},
            },
            "coverage": {
                "input_duration_s": 2.0,
                "processed_duration_s": 2.0,
                "truncated": False,
                "strategy": "full",
                "chunks_planned": 1,
                "chunks_completed": 1,
            },
            "chunk_boundaries": [
                {"index": 0, "start_s": 0.0, "end_s": 2.0, "status": "succeeded"}
            ],
            "timing": {
                "started_at": "2026-08-31T00:00:00Z",
                "finished_at": "2026-08-31T00:00:01Z",
                "wall_time_s": 1.0,
            },
            "peak_memory_bytes": 1,
            "artifacts": [
                {
                    "kind": "preprocessed_audio"
                    if relative == preprocessed_relative
                    else relative.replace("/", "_"),
                    "path": relative,
                    "sha256": digest(run / relative),
                }
                for relative in paths
            ],
            "failure": None,
        }
        write_json(run / "manifest.json", manifest)
        return run

    def create(self, root: Path, fixture_id: str, evaluation_id: str = "eval-1"):
        fixture, input_path, run = self.make_case(root, fixture_id)
        kind = "acceptance-asr" if fixture_id.startswith("hike") else "acceptance-full"
        evaluation = root / "evaluations" / evaluation_id
        envelope = create_evaluation(
            evaluation_id=evaluation_id,
            fixture_id=fixture_id,
            kind=kind,
            fixture_root=fixture,
            input_path=input_path,
            source_run=run,
            output=evaluation,
        )
        return fixture, input_path, run, evaluation, envelope

    def test_asr_create_verify_is_create_only_and_preserves_source_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture, input_path, run, evaluation, envelope = self.create(
                root, "hike-code-switch-v1"
            )
            before = snapshot_tree(run)
            verified = verify_evaluation(
                evaluation=evaluation,
                fixture_root=fixture,
                input_path=input_path,
                source_run=run,
            )
            self.assertEqual(verified, envelope)
            self.assertEqual(snapshot_tree(run), before)
            self.assertNotIn(str(root), json.dumps(envelope))
            self.assertFalse(
                any(
                    "Qwen/Qwen2.5-7B" == item["hf_model_id"]
                    for item in envelope["models"]["identities"]
                )
            )
            self.assertEqual(sorted(path.name for path in evaluation.iterdir()), ["evaluation.json", "scores.json"])
            with self.assertRaisesRegex(FileExistsError, "create-only"):
                create_evaluation(
                    evaluation_id="eval-1",
                    fixture_id="hike-code-switch-v1",
                    kind="acceptance-asr",
                    fixture_root=fixture,
                    input_path=input_path,
                    source_run=run,
                    output=evaluation,
                )

    def test_ami_derives_and_reverifies_hypothesis_rttm(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture, input_path, run, evaluation, _ = self.create(
                Path(temporary).resolve(), "ami-in1009-ihm-mix-v1"
            )
            self.assertIn("SPEAKER IN1009", (evaluation / "hypothesis.rttm").read_text(encoding="utf-8"))
            verify_evaluation(
                evaluation=evaluation,
                fixture_root=fixture,
                input_path=input_path,
                source_run=run,
            )

    def test_fixture_kind_mapping_is_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture, input_path, run = self.make_case(root, "hike-code-switch-v1")
            with self.assertRaisesRegex(EvaluationError, "requires acceptance-asr"):
                create_evaluation(
                    evaluation_id="bad-kind",
                    fixture_id="hike-code-switch-v1",
                    kind="acceptance-full",
                    fixture_root=fixture,
                    input_path=input_path,
                    source_run=run,
                    output=root / "evaluation",
                )

    def test_every_referenced_hash_record_rejects_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture, input_path, run, evaluation, _ = self.create(
                root, "ami-in1009-ihm-mix-v1"
            )
            mutations = {
                "source": lambda value: value["source_run"].__setitem__("manifest_sha256", "0" * 64),
                "fixture": lambda value: value["fixture"].__setitem__("fixture_check_sha256", "0" * 64),
                "model": lambda value: value["models"].__setitem__("identity_sha256", "0" * 64),
                "glossary": lambda value: value["glossary"].__setitem__("sha256", "0" * 64),
                "rttm": lambda value: value["rttm"].__setitem__("reference_sha256", "0" * 64),
                "scorer": lambda value: value["scorer"]["files"].__setitem__(
                    "benchmarks/scripts/scoring/score.py", "0" * 64
                ),
                "result": lambda value: value["result"].__setitem__("sha256", "0" * 64),
            }
            for label, mutate in mutations.items():
                with self.subTest(label=label):
                    candidate = root / f"tampered-{label}" / evaluation.name
                    shutil.copytree(evaluation, candidate)
                    envelope_path = candidate / "evaluation.json"
                    envelope = json.loads(envelope_path.read_text(encoding="utf-8"))
                    mutate(envelope)
                    write_json(envelope_path, envelope)
                    with self.assertRaises(EvaluationError):
                        verify_evaluation(
                            evaluation=candidate,
                            fixture_root=fixture,
                            input_path=input_path,
                            source_run=run,
                        )

    def test_exact_envelope_rejects_unknown_fields_and_invocation_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture, input_path, run, evaluation, _ = self.create(
                root, "hike-code-switch-v1"
            )
            mutations = {
                "top-level-private-notes": lambda value: value.__setitem__(
                    "private_notes", "must not be published"
                ),
                "nested-private-notes": lambda value: value["scorer"].__setitem__(
                    "private_notes", "must not be published"
                ),
                "scorer-invocation": lambda value: value["scorer"].__setitem__(
                    "invocation", "trust the recorded score"
                ),
            }
            for label, mutate in mutations.items():
                with self.subTest(label=label):
                    candidate = root / label / evaluation.name
                    shutil.copytree(evaluation, candidate)
                    envelope_path = candidate / "evaluation.json"
                    envelope = json.loads(envelope_path.read_text(encoding="utf-8"))
                    mutate(envelope)
                    write_json(envelope_path, envelope)
                    with self.assertRaisesRegex(EvaluationError, "exact reconstructed contract"):
                        verify_evaluation(
                            evaluation=candidate,
                            fixture_root=fixture,
                            input_path=input_path,
                            source_run=run,
                        )

    def test_copied_evaluation_directory_name_must_match_sealed_id(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture, input_path, run, evaluation, _ = self.create(
                root, "hike-code-switch-v1"
            )
            renamed = root / "renamed-evaluation"
            shutil.copytree(evaluation, renamed)
            with self.assertRaisesRegex(EvaluationError, "directory name differs"):
                verify_evaluation(
                    evaluation=renamed,
                    fixture_root=fixture,
                    input_path=input_path,
                    source_run=run,
                )

    def test_every_envelope_hash_occurrence_rejects_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture, input_path, run, evaluation, _ = self.create(
                root, "hike-code-switch-v1"
            )
            document = json.loads((evaluation / "evaluation.json").read_text(encoding="utf-8"))
            paths: list[tuple[object, ...]] = []

            def collect(value: object, path: tuple[object, ...] = ()) -> None:
                if isinstance(value, dict):
                    for key, item in value.items():
                        collect(item, (*path, key))
                elif isinstance(value, list):
                    for index, item in enumerate(value):
                        collect(item, (*path, index))
                elif isinstance(value, str) and len(value) == 64 and set(value) <= set("0123456789abcdef"):
                    paths.append(path)

            collect(document)
            self.assertGreater(len(paths), 20)
            for index, path in enumerate(paths):
                with self.subTest(index=index, path=path):
                    candidate = root / f"all-hashes-{index}" / evaluation.name
                    shutil.copytree(evaluation, candidate)
                    mutated = deepcopy(document)
                    cursor = mutated
                    for component in path[:-1]:
                        cursor = cursor[component]
                    original = cursor[path[-1]]
                    cursor[path[-1]] = ("0" if original[0] != "0" else "1") + original[1:]
                    write_json(candidate / "evaluation.json", mutated)
                    with self.assertRaises(EvaluationError):
                        verify_evaluation(
                            evaluation=candidate,
                            fixture_root=fixture,
                            input_path=input_path,
                            source_run=run,
                        )

    def test_fixture_tree_must_exactly_match_artifact_seals(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture, input_path, run = self.make_case(root, "hike-code-switch-v1")
            (fixture / "private-notes.txt").write_text("synthetic extra\n", encoding="utf-8")
            with self.assertRaisesRegex(EvaluationError, "outside fixture-check"):
                create_evaluation(
                    evaluation_id="extra-fixture-file",
                    fixture_id="hike-code-switch-v1",
                    kind="acceptance-asr",
                    fixture_root=fixture,
                    input_path=input_path,
                    source_run=run,
                    output=root / "evaluations/extra-fixture-file",
                )

    def test_source_derived_verifier_rejects_self_consistent_fixture_rewrite(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture, input_path, run = self.make_case(root, "hike-code-switch-v1")
            reference_path = fixture / "reference.segments.json"
            reference = json.loads(reference_path.read_text(encoding="utf-8"))
            reference["segments"][0]["text"] = "rewritten API"
            write_json(reference_path, reference)
            check_path = fixture / "fixture-check.json"
            check = json.loads(check_path.read_text(encoding="utf-8"))
            check["artifact_sha256"]["reference.segments.json"] = digest(reference_path)
            write_json(check_path, check)
            evaluation_module.verify_source_derived_fixture = lambda *_args: (_ for _ in ()).throw(
                EvaluationError("source-derived prepared fixture verification failed")
            )
            with self.assertRaisesRegex(EvaluationError, "source-derived"):
                create_evaluation(
                    evaluation_id="rewritten-fixture",
                    fixture_id="hike-code-switch-v1",
                    kind="acceptance-asr",
                    fixture_root=fixture,
                    input_path=input_path,
                    source_run=run,
                    output=root / "evaluations/rewritten-fixture",
                )

    def test_hike_source_derivation_replays_text_glossary_items_and_reel(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            acceptance = root / "acceptance"
            fixture_root = acceptance / "prepared/hike-code-switch-v1"
            clip = root / "clip.wav"
            write_wav(clip)
            audio_bytes = clip.read_bytes()
            source_path = acceptance / "sources/hike/data/test-00000-of-00001.parquet"
            source_path.parent.mkdir(parents=True)
            source_path.write_bytes(b"synthetic parquet stand-in")
            row = {
                "row_index": 7,
                "sample_id": "sample-7",
                "cs_level": "word",
                "category": "synthetic",
                "text_normalized": "hello API",
                "loanwords": [{"English": "API", "Korean": "에이피아이"}],
                "audio_bytes": audio_bytes,
                "source_audio_sha256": digest(clip),
                "source_audio_path": None,
                "source_duration_s": 2.0,
                "selection_kind": "category",
            }
            expected_selection = {"algorithm_id": "synthetic-selection"}
            fixture = {
                "fixture_id": "hike-code-switch-v1",
                "source": {"dataset_id": "synthetic/HiKE", "revision": "a" * 40},
                "selection": {"silence_between_items_s": 0.5},
            }
            (fixture_root / "items").mkdir(parents=True)
            (fixture_root / "items/00.wav").write_bytes(audio_bytes)
            (fixture_root / "input.wav").write_bytes(audio_bytes)
            reference = {
                "segments": [
                    {
                        "speaker": "UNASSIGNED",
                        "start_s": 0.0,
                        "end_s": 2.0,
                        "text": "hello API",
                        "language": "ko-en",
                    }
                ]
            }
            terms = [{"term": "API", "reference_count": 1}]
            write_json(fixture_root / "reference.segments.json", reference)
            write_json(fixture_root / "terms.json", terms)
            (fixture_root / "glossary.txt").write_text("API\n", encoding="utf-8")
            write_json(
                fixture_root / "selection.json",
                {
                    "fixture_id": "hike-code-switch-v1",
                    "source": {
                        "dataset_id": "synthetic/HiKE",
                        "revision": "a" * 40,
                        "source_sha256": digest(source_path),
                    },
                    "selection": expected_selection,
                    "items": [
                        {
                            "order": 0,
                            "row_index": 7,
                            "sample_id": "sample-7",
                            "cs_level": "word",
                            "category": "synthetic",
                            "selection_kind": "category",
                            "text_normalized": "hello API",
                            "loanwords": [{"English": "API", "Korean": "에이피아이"}],
                            "source_audio_path": None,
                            "source_audio_sha256": digest(clip),
                            "source_duration_s": 2.0,
                            "item_wav": "items/00.wav",
                            "item_wav_sha256": digest(clip),
                            "reel_start_s": 0.0,
                            "reel_end_s": 2.0,
                        }
                    ],
                    "reference_text": "hello API",
                    "term_source_sample_ids": {"api": ["sample-7"]},
                },
            )
            original_rows = evaluation_module.hike_rows
            original_select = evaluation_module.select_hike_rows
            evaluation_module.hike_rows = lambda *_args: [row]
            evaluation_module.select_hike_rows = lambda *_args: ([row], expected_selection)
            try:
                evaluation_module.verify_hike_source_derivation(
                    acceptance, fixture, fixture_root
                )
                cases = (
                    (fixture_root / "items/00.wav", b"item tamper"),
                    (fixture_root / "input.wav", b"reel tamper"),
                    (fixture_root / "reference.segments.json", b'{"segments": []}\n'),
                    (fixture_root / "glossary.txt", b"WRONG\n"),
                )
                for path, replacement in cases:
                    with self.subTest(path=path.name):
                        original_bytes = path.read_bytes()
                        path.write_bytes(replacement)
                        with self.assertRaises(EvaluationError):
                            evaluation_module.verify_hike_source_derivation(
                                acceptance, fixture, fixture_root
                            )
                        path.write_bytes(original_bytes)
            finally:
                evaluation_module.hike_rows = original_rows
                evaluation_module.select_hike_rows = original_select

    def test_ami_source_derivation_replays_full_rttm_text_and_glossary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            acceptance = root / "acceptance"
            fixture_root = acceptance / "prepared/ami-in1009-ihm-mix-v1"
            audio = acceptance / "sources/ami/IN1009.Mix-Headset.wav"
            archive = acceptance / "sources/ami/ami_public_manual_1.6.2.zip"
            write_wav(audio)
            archive.parent.mkdir(parents=True, exist_ok=True)
            archive.write_bytes(b"synthetic annotation stand-in")
            asr = [
                {
                    "speaker": "MIO001",
                    "start_s": 0.0,
                    "end_s": 2.0,
                    "text": "hello API",
                    "language": "en",
                }
            ]
            turns = [{"speaker": "MIO001", "start_s": 0.0, "end_s": 2.0, "text": "hello API"}]
            mapping = {"A": "MIO001", "B": "MIO002", "C": "MIO003", "D": "MIO004"}
            terms = [{"term": "API", "reference_count": 1}]
            derivation = {
                "expected_lexical_segment_count": 1,
                "expected_lexical_word_count": 2,
                "expected_rttm_turn_count": 1,
                "expected_speaker_count": 1,
            }
            fixture = {
                "fixture_id": "ami-in1009-ihm-mix-v1",
                "source": {"meeting_id": "IN1009"},
                "reference_derivation": derivation,
            }
            reference = {
                "segments": asr,
                "source": {
                    "file_name": audio.name,
                    "sha256": digest(audio),
                    "duration_s": 2.0,
                },
            }
            write_json(fixture_root / "reference.segments.json", reference)
            write_json(fixture_root / "terms.json", terms)
            (fixture_root / "glossary.txt").write_text("API\n", encoding="utf-8")
            (fixture_root / "reference.rttm").write_text(
                "SPEAKER IN1009 1 0.000000 2.000000 <NA> <NA> MIO001 <NA> <NA>\n",
                encoding="utf-8",
            )
            write_json(
                fixture_root / "selection.json",
                {
                    "fixture_id": "ami-in1009-ihm-mix-v1",
                    "source": {
                        "meeting_id": "IN1009",
                        "audio_sha256": digest(audio),
                        "annotations_sha256": digest(archive),
                    },
                    "speaker_mapping": mapping,
                    "reference_derivation": derivation,
                    "reference_text": "hello API",
                    "lexical_word_count": 2,
                    "term_reference_occurrences": {"API": 1},
                },
            )
            original_reference = evaluation_module.ami_reference_from_archive
            original_glossary = evaluation_module.derive_ami_glossary
            evaluation_module.ami_reference_from_archive = lambda *_args: (asr, turns, mapping)
            evaluation_module.derive_ami_glossary = lambda *_args: terms
            try:
                evaluation_module.verify_ami_source_derivation(
                    acceptance, fixture, fixture_root
                )
                cases = (
                    (
                        fixture_root / "reference.rttm",
                        b"SPEAKER IN1009 1 0.100000 1.900000 <NA> <NA> MIO001 <NA> <NA>\n",
                    ),
                    (fixture_root / "reference.segments.json", b'{"segments": []}\n'),
                    (fixture_root / "glossary.txt", b"WRONG\n"),
                )
                for path, replacement in cases:
                    with self.subTest(path=path.name):
                        original_bytes = path.read_bytes()
                        path.write_bytes(replacement)
                        with self.assertRaises(EvaluationError):
                            evaluation_module.verify_ami_source_derivation(
                                acceptance, fixture, fixture_root
                            )
                        path.write_bytes(original_bytes)
            finally:
                evaluation_module.ami_reference_from_archive = original_reference
                evaluation_module.derive_ami_glossary = original_glossary

    def test_transitive_verifier_hash_tamper_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture, input_path, run, evaluation, _ = self.create(
                root, "hike-code-switch-v1"
            )
            original = evaluation_module.scorer_hashes

            def tampered_hashes() -> dict[str, str]:
                value = original()
                value["docs/contracts/manifest.schema.json"] = "0" * 64
                return value

            evaluation_module.scorer_hashes = tampered_hashes
            try:
                with self.assertRaisesRegex(EvaluationError, "scorer hash"):
                    verify_evaluation(
                        evaluation=evaluation,
                        fixture_root=fixture,
                        input_path=input_path,
                        source_run=run,
                    )
            finally:
                evaluation_module.scorer_hashes = original

    def test_atomic_exclusive_publication_does_not_replace_racing_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture, input_path, run = self.make_case(root, "hike-code-switch-v1")
            output = root / "evaluations/race-eval"
            original = evaluation_module.publish_directory_exclusive

            def racing_publish(**arguments: object) -> None:
                destination = Path(arguments["destination_parent"]) / str(
                    arguments["destination_name"]
                )
                destination.mkdir()
                (destination / "attacker-sentinel").write_text("keep\n", encoding="utf-8")
                original(**arguments)

            evaluation_module.publish_directory_exclusive = racing_publish
            try:
                with self.assertRaisesRegex(FileExistsError, "create-only"):
                    create_evaluation(
                        evaluation_id="race-eval",
                        fixture_id="hike-code-switch-v1",
                        kind="acceptance-asr",
                        fixture_root=fixture,
                        input_path=input_path,
                        source_run=run,
                        output=output,
                    )
            finally:
                evaluation_module.publish_directory_exclusive = original
            self.assertEqual((output / "attacker-sentinel").read_text(encoding="utf-8"), "keep\n")
            self.assertFalse((output / "evaluation.json").exists())

    def test_prepublication_failure_never_creates_final_evaluation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture, input_path, run = self.make_case(root, "hike-code-switch-v1")
            output = root / "evaluations/scorer-failure"
            original = evaluation_module.run_scorer
            evaluation_module.run_scorer = lambda *_args: (_ for _ in ()).throw(
                EvaluationError("synthetic scorer failure")
            )
            try:
                with self.assertRaisesRegex(EvaluationError, "synthetic scorer failure"):
                    create_evaluation(
                        evaluation_id="scorer-failure",
                        fixture_id="hike-code-switch-v1",
                        kind="acceptance-asr",
                        fixture_root=fixture,
                        input_path=input_path,
                        source_run=run,
                        output=output,
                    )
            finally:
                evaluation_module.run_scorer = original
            self.assertFalse(output.exists())

    def test_fd_anchored_publication_rejects_parent_swap_into_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture, input_path, run = self.make_case(root, "hike-code-switch-v1")
            output = root / "evaluations/parent-swap"
            before = snapshot_tree(run)
            original = evaluation_module.publish_directory_exclusive

            def swap_parent(**arguments: object) -> None:
                destination_parent = Path(arguments["destination_parent"])
                moved_parent = root / "moved-evaluations"
                destination_parent.rename(moved_parent)
                destination_parent.symlink_to(run, target_is_directory=True)
                original(**arguments)

            evaluation_module.publish_directory_exclusive = swap_parent
            try:
                with self.assertRaisesRegex(EvaluationError, "parent identity changed"):
                    create_evaluation(
                        evaluation_id="parent-swap",
                        fixture_id="hike-code-switch-v1",
                        kind="acceptance-asr",
                        fixture_root=fixture,
                        input_path=input_path,
                        source_run=run,
                        output=output,
                    )
            finally:
                evaluation_module.publish_directory_exclusive = original
            self.assertEqual(snapshot_tree(run), before)
            self.assertFalse((run / "parent-swap").exists())

    def test_output_aliases_and_immutable_tree_containment_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture, input_path, run = self.make_case(root, "hike-code-switch-v1")
            before = snapshot_tree(run)
            aliased_output = root / "outside" / ".." / "source-run" / "inside-source"
            with self.assertRaisesRegex(EvaluationError, "outside the immutable source"):
                create_evaluation(
                    evaluation_id="inside-source",
                    fixture_id="hike-code-switch-v1",
                    kind="acceptance-asr",
                    fixture_root=fixture,
                    input_path=input_path,
                    source_run=run,
                    output=aliased_output,
                )
            self.assertEqual(snapshot_tree(run), before)
            target_parent = root / "real-output"
            target_parent.mkdir()
            symlink_parent = root / "linked-output"
            symlink_parent.symlink_to(target_parent, target_is_directory=True)
            with self.assertRaisesRegex(EvaluationError, "symlinked path component"):
                create_evaluation(
                    evaluation_id="symlink-eval",
                    fixture_id="hike-code-switch-v1",
                    kind="acceptance-asr",
                    fixture_root=fixture,
                    input_path=input_path,
                    source_run=run,
                    output=symlink_parent / "symlink-eval",
                )
            self.assertEqual(list(target_parent.iterdir()), [])

    def test_source_manifest_nonfinite_numbers_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture, input_path, run = self.make_case(root, "hike-code-switch-v1")
            manifest_path = run / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["coverage"]["input_duration_s"] = float("nan")
            write_json(manifest_path, manifest)
            with self.assertRaisesRegex(EvaluationError, "non-finite"):
                create_evaluation(
                    evaluation_id="nonfinite-source",
                    fixture_id="hike-code-switch-v1",
                    kind="acceptance-asr",
                    fixture_root=fixture,
                    input_path=input_path,
                    source_run=run,
                    output=root / "evaluations/nonfinite-source",
                )

    def test_source_fixture_rttm_and_result_byte_tampering_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture, input_path, run, evaluation, _ = self.create(
                root, "ami-in1009-ihm-mix-v1"
            )
            cases = (
                ("source", run / "primary/raw.txt"),
                ("fixture", fixture / "selection.json"),
                ("rttm", evaluation / "hypothesis.rttm"),
                ("result", evaluation / "scores.json"),
            )
            for label, path in cases:
                with self.subTest(label=label):
                    original = path.read_bytes()
                    path.write_bytes(original + b"tamper")
                    with self.assertRaises((EvaluationError, ValueError, json.JSONDecodeError)):
                        verify_evaluation(
                            evaluation=evaluation,
                            fixture_root=fixture,
                            input_path=input_path,
                            source_run=run,
                        )
                    path.write_bytes(original)

    def test_runner_evidence_requires_observed_complete_terminal_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            _, input_path, run = self.make_case(root, "hike-code-switch-v1")
            manifest = json.loads((run / "manifest.json").read_text(encoding="utf-8"))
            runner_path = run / "primary/attempts/chunk-0/runner-record.json"
            runner = json.loads(runner_path.read_text(encoding="utf-8"))
            runner["terminal_evidence"] = "unavailable"
            write_json(runner_path, runner)
            outcome_path = run / "primary/attempts/chunk-0/outcome.json"
            outcome = json.loads(outcome_path.read_text(encoding="utf-8"))
            outcome["runner_record_sha256"] = digest(runner_path)
            write_json(outcome_path, outcome)
            self.reseal_manifest_artifact(
                manifest, run, "primary/attempts/chunk-0/runner-record.json"
            )
            self.reseal_manifest_artifact(
                manifest, run, "primary/attempts/chunk-0/outcome.json"
            )
            with self.assertRaisesRegex(EvaluationError, "terminal or input evidence"):
                validate_runner_evidence(
                    run,
                    manifest,
                    vibevoice_glossary_payload_sha256(input_path.parent / "glossary.txt"),
                )

    def test_runner_evidence_hashes_actual_leaf_audio_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            _, input_path, run = self.make_case(root, "hike-code-switch-v1")
            manifest = json.loads((run / "manifest.json").read_text(encoding="utf-8"))
            audio_path = run / "primary/attempts/chunk-0/audio.wav"
            original_audio_hash = digest(audio_path)
            fake_hash = "f" * 64
            request_path = run / "primary/attempts/chunk-0/request.json"
            runner_path = run / "primary/attempts/chunk-0/runner-record.json"
            outcome_path = run / "primary/attempts/chunk-0/outcome.json"
            request = json.loads(request_path.read_text(encoding="utf-8"))
            request["audio_sha256"] = fake_hash
            write_json(request_path, request)
            runner = json.loads(runner_path.read_text(encoding="utf-8"))
            runner["input"] = {"sha256_before": fake_hash, "sha256_after": fake_hash}
            write_json(runner_path, runner)
            outcome = json.loads(outcome_path.read_text(encoding="utf-8"))
            outcome["request_sha256"] = digest(request_path)
            outcome["runner_record_sha256"] = digest(runner_path)
            write_json(outcome_path, outcome)
            for relative in (
                "primary/attempts/chunk-0/request.json",
                "primary/attempts/chunk-0/runner-record.json",
                "primary/attempts/chunk-0/outcome.json",
            ):
                self.reseal_manifest_artifact(manifest, run, relative)
            self.assertEqual(digest(audio_path), original_audio_hash)
            with self.assertRaisesRegex(EvaluationError, "differs from audio.wav"):
                validate_runner_evidence(
                    run,
                    manifest,
                    vibevoice_glossary_payload_sha256(input_path.parent / "glossary.txt"),
                )

    def test_runner_evidence_rejects_noncanonical_leaf_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            _, input_path, run = self.make_case(root, "hike-code-switch-v1")
            manifest = json.loads((run / "manifest.json").read_text(encoding="utf-8"))
            alternate_relative = "primary/attempts/chunk-0/alternate-runner-record.json"
            shutil.copyfile(
                run / "primary/attempts/chunk-0/runner-record.json",
                run / alternate_relative,
            )
            self.reseal_manifest_artifact(manifest, run, alternate_relative)
            outcome_path = run / "primary/attempts/chunk-0/outcome.json"
            outcome = json.loads(outcome_path.read_text(encoding="utf-8"))
            outcome["runner_record_path"] = alternate_relative
            outcome["runner_record_sha256"] = digest(run / alternate_relative)
            write_json(outcome_path, outcome)
            self.reseal_manifest_artifact(
                manifest, run, "primary/attempts/chunk-0/outcome.json"
            )
            with self.assertRaisesRegex(EvaluationError, "path is not canonical"):
                validate_runner_evidence(
                    run,
                    manifest,
                    vibevoice_glossary_payload_sha256(input_path.parent / "glossary.txt"),
                )

    def test_runner_evidence_rejects_request_attempt_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            _, input_path, run = self.make_case(root, "hike-code-switch-v1")
            manifest = json.loads((run / "manifest.json").read_text(encoding="utf-8"))
            request_path = run / "primary/attempts/chunk-0/request.json"
            outcome_path = run / "primary/attempts/chunk-0/outcome.json"
            request = json.loads(request_path.read_text(encoding="utf-8"))
            request["attempt_id"] = "different-leaf"
            write_json(request_path, request)
            outcome = json.loads(outcome_path.read_text(encoding="utf-8"))
            outcome["request_sha256"] = digest(request_path)
            write_json(outcome_path, outcome)
            self.reseal_manifest_artifact(
                manifest, run, "primary/attempts/chunk-0/request.json"
            )
            self.reseal_manifest_artifact(
                manifest, run, "primary/attempts/chunk-0/outcome.json"
            )
            with self.assertRaisesRegex(EvaluationError, "invalid request provenance"):
                validate_runner_evidence(
                    run,
                    manifest,
                    vibevoice_glossary_payload_sha256(input_path.parent / "glossary.txt"),
                )

    def test_runner_evidence_rejects_range_root_rate_and_arbitrary_wav_reseals(self) -> None:
        mutations = {
            "wrong-root": ("root_chunk_index", 1),
            "wrong-rate": ("sample_rate_hz", 8_000),
            "wrong-range": ("end_sample", 31_999),
        }
        for label, (field, value) in mutations.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                _, input_path, run = self.make_case(root, "hike-code-switch-v1")
                manifest = json.loads((run / "manifest.json").read_text(encoding="utf-8"))
                request_path = run / "primary/attempts/chunk-0/request.json"
                outcome_path = run / "primary/attempts/chunk-0/outcome.json"
                request = json.loads(request_path.read_text(encoding="utf-8"))
                request[field] = value
                write_json(request_path, request)
                outcome = json.loads(outcome_path.read_text(encoding="utf-8"))
                outcome["request_sha256"] = digest(request_path)
                write_json(outcome_path, outcome)
                self.reseal_manifest_artifact(
                    manifest, run, "primary/attempts/chunk-0/request.json"
                )
                self.reseal_manifest_artifact(
                    manifest, run, "primary/attempts/chunk-0/outcome.json"
                )
                with self.assertRaises(EvaluationError):
                    validate_runner_evidence(
                        run,
                        manifest,
                        vibevoice_glossary_payload_sha256(input_path.parent / "glossary.txt"),
                    )

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            _, input_path, run = self.make_case(root, "hike-code-switch-v1")
            manifest = json.loads((run / "manifest.json").read_text(encoding="utf-8"))
            audio_path = run / "primary/attempts/chunk-0/audio.wav"
            with wave.open(str(audio_path), "wb") as output:
                output.setnchannels(1)
                output.setsampwidth(2)
                output.setframerate(16_000)
                output.writeframes(b"\x01\x00" * 32_000)
            request_path = run / "primary/attempts/chunk-0/request.json"
            runner_path = run / "primary/attempts/chunk-0/runner-record.json"
            outcome_path = run / "primary/attempts/chunk-0/outcome.json"
            request = json.loads(request_path.read_text(encoding="utf-8"))
            request["audio_sha256"] = digest(audio_path)
            write_json(request_path, request)
            runner = json.loads(runner_path.read_text(encoding="utf-8"))
            runner["input"] = {
                "sha256_before": digest(audio_path),
                "sha256_after": digest(audio_path),
            }
            write_json(runner_path, runner)
            outcome = json.loads(outcome_path.read_text(encoding="utf-8"))
            outcome["request_sha256"] = digest(request_path)
            outcome["runner_record_sha256"] = digest(runner_path)
            write_json(outcome_path, outcome)
            for relative in (
                "primary/attempts/chunk-0/audio.wav",
                "primary/attempts/chunk-0/request.json",
                "primary/attempts/chunk-0/runner-record.json",
                "primary/attempts/chunk-0/outcome.json",
            ):
                self.reseal_manifest_artifact(manifest, run, relative)
            with self.assertRaisesRegex(EvaluationError, "preprocessed-input range"):
                validate_runner_evidence(
                    run,
                    manifest,
                    vibevoice_glossary_payload_sha256(input_path.parent / "glossary.txt"),
                )

    def test_runner_evidence_uses_sealed_normalized_audio_not_raw_fixture_pcm(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture, input_path, run = self.make_case(root, "hike-code-switch-v1")
            manifest_path = run / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            normalized_paths = (
                run / "preprocess/normalized.wav",
                run / "primary/chunks/0/audio.wav",
                run / "primary/attempts/chunk-0/audio.wav",
            )
            for path in normalized_paths:
                with wave.open(str(path), "wb") as output:
                    output.setnchannels(1)
                    output.setsampwidth(2)
                    output.setframerate(16_000)
                    output.writeframes(b"\x01\x00" * 32_000)
            self.assertNotEqual(digest(input_path), digest(normalized_paths[0]))
            request_path = run / "primary/attempts/chunk-0/request.json"
            runner_path = run / "primary/attempts/chunk-0/runner-record.json"
            outcome_path = run / "primary/attempts/chunk-0/outcome.json"
            normalized_hash = digest(normalized_paths[0])
            request = json.loads(request_path.read_text(encoding="utf-8"))
            request["audio_sha256"] = normalized_hash
            write_json(request_path, request)
            runner = json.loads(runner_path.read_text(encoding="utf-8"))
            runner["input"] = {
                "sha256_before": normalized_hash,
                "sha256_after": normalized_hash,
            }
            write_json(runner_path, runner)
            outcome = json.loads(outcome_path.read_text(encoding="utf-8"))
            outcome["request_sha256"] = digest(request_path)
            outcome["runner_record_sha256"] = digest(runner_path)
            write_json(outcome_path, outcome)
            for relative in (
                "preprocess/normalized.wav",
                "primary/chunks/0/audio.wav",
                "primary/attempts/chunk-0/audio.wav",
                "primary/attempts/chunk-0/request.json",
                "primary/attempts/chunk-0/runner-record.json",
                "primary/attempts/chunk-0/outcome.json",
            ):
                self.reseal_manifest_artifact(manifest, run, relative)
            write_json(manifest_path, manifest)
            envelope = create_evaluation(
                evaluation_id="normalized-source",
                fixture_id="hike-code-switch-v1",
                kind="acceptance-asr",
                fixture_root=fixture,
                input_path=input_path,
                source_run=run,
                output=root / "evaluations/normalized-source",
            )
            self.assertTrue(envelope["runner_evidence"]["input_unchanged"])

    def test_runner_evidence_rejects_self_consistent_glossary_reseals(self) -> None:
        fake_hash = "f" * 64

        def canonical_tamper(runner: dict[str, object], outcome: dict[str, object]) -> None:
            runner["glossary"]["canonical_payload_sha256"] = fake_hash

        def count_tamper(runner: dict[str, object], outcome: dict[str, object]) -> None:
            runner["glossary"]["payload_entry_count"] = 999
            outcome["glossary_payload_entry_count"] = 999

        def payload_tamper(runner: dict[str, object], outcome: dict[str, object]) -> None:
            runner["glossary"]["payload_sha256"] = fake_hash
            runner["glossary"]["instruction_sha256"] = fake_hash
            runner["language"]["instruction_sha256"] = fake_hash
            outcome["glossary_payload_sha256"] = fake_hash
            outcome["language"]["instruction_sha256"] = fake_hash

        def instruction_tamper(runner: dict[str, object], outcome: dict[str, object]) -> None:
            runner["glossary"]["instruction_sha256"] = fake_hash
            runner["language"]["instruction_sha256"] = fake_hash
            outcome["language"]["instruction_sha256"] = fake_hash

        for label, mutate in (
            ("canonical-payload", canonical_tamper),
            ("entry-count", count_tamper),
            ("payload-and-both-sides", payload_tamper),
            ("instruction", instruction_tamper),
        ):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                _, input_path, run = self.make_case(root, "hike-code-switch-v1")
                manifest = json.loads((run / "manifest.json").read_text(encoding="utf-8"))
                runner_path = run / "primary/attempts/chunk-0/runner-record.json"
                outcome_path = run / "primary/attempts/chunk-0/outcome.json"
                runner = json.loads(runner_path.read_text(encoding="utf-8"))
                outcome = json.loads(outcome_path.read_text(encoding="utf-8"))
                mutate(runner, outcome)
                write_json(runner_path, runner)
                outcome["runner_record_sha256"] = digest(runner_path)
                write_json(outcome_path, outcome)
                self.reseal_manifest_artifact(
                    manifest, run, "primary/attempts/chunk-0/runner-record.json"
                )
                self.reseal_manifest_artifact(
                    manifest, run, "primary/attempts/chunk-0/outcome.json"
                )
                with self.assertRaisesRegex(EvaluationError, "glossary application"):
                    validate_runner_evidence(
                        run,
                        manifest,
                        vibevoice_glossary_payload_sha256(
                            input_path.parent / "glossary.txt"
                        ),
                    )

    def test_exact_partition_rejects_leaf_and_root_gaps_and_overlaps(self) -> None:
        validate_exact_partition([(0, 10), (10, 20)], 0, 20, label="valid")
        for label, ranges in (
            ("gap", [(0, 9), (10, 20)]),
            ("overlap", [(0, 11), (10, 20)]),
            ("tail", [(0, 19)]),
        ):
            with self.subTest(label=label), self.assertRaises(EvaluationError):
                validate_exact_partition(ranges, 0, 20, label="synthetic partition")

    def test_public_checker_refuses_test_mode_environment(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            environment = dict(os.environ)
            environment["MACCHERONI_ACCEPTANCE_TESTING"] = "1"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(REPOSITORY / "benchmarks/scripts/scoring/check_acceptance_evaluation.py"),
                    "preflight",
                    "--fixture-root",
                    str(root / "private-fixture"),
                    "--input",
                    str(root / "private-input.wav"),
                    "--fixture-id",
                    "hike-code-switch-v1",
                    "--kind",
                    "acceptance-asr",
                ],
                cwd=REPOSITORY,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(completed.returncode, 1)
            self.assertIn("test-mode-environment", completed.stderr)
            self.assertNotIn(str(root), completed.stderr)

    def test_runner_preflight_failure_never_invokes_cli(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture, input_path, _ = self.make_case(root, "hike-code-switch-v1")
            output = root / "runner-output"
            marker = root / "cli-was-invoked"
            fake_cli = root / "fake-cli"
            fake_cli.write_text(f"#!/bin/sh\ntouch '{marker}'\n", encoding="utf-8")
            fake_cli.chmod(0o700)
            environment = dict(os.environ)
            environment["MACCHERONI_ACCEPTANCE_MODEL_RUN"] = "1"
            environment["MACCHERONI_BENCHMARK_CACHE"] = "synthetic-cache"
            completed = subprocess.run(
                [
                    "bash",
                    str(REPOSITORY / "benchmarks/scripts/runners/run_acceptance_pack_v1.sh"),
                    "hike-code-switch-v1",
                    "acceptance-asr",
                    str(output),
                    "--cli",
                    str(fake_cli),
                    "--fixture-root",
                    str(fixture),
                    "--input",
                    str(input_path),
                ],
                cwd=REPOSITORY,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertFalse(marker.exists())
            self.assertFalse(output.exists())

    def test_runner_dry_run_and_source_run_success_branches(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture, input_path, run = self.make_case(root, "hike-code-switch-v1")
            binaries = self.make_fake_runner_commands(root)
            environment = dict(os.environ)
            environment["PATH"] = f"{binaries}:/usr/bin:/bin"
            runner = REPOSITORY / "benchmarks/scripts/runners/run_acceptance_pack_v1.sh"
            dry_output = root / "dry-output"
            dry = subprocess.run(
                [
                    "bash",
                    str(runner),
                    "hike-code-switch-v1",
                    "acceptance-asr",
                    str(dry_output),
                    "--dry-run",
                    "--fixture-root",
                    str(fixture),
                    "--input",
                    str(input_path),
                ],
                cwd=REPOSITORY,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(dry.returncode, 0, dry.stderr)
            self.assertIn('"model_started":false', dry.stdout)
            self.assertFalse(dry_output.exists())
            output = root / "source-output"
            reused = subprocess.run(
                [
                    "bash",
                    str(runner),
                    "hike-code-switch-v1",
                    "acceptance-asr",
                    str(output),
                    "--source-run",
                    str(run),
                    "--evaluation-id",
                    "source-reuse",
                    "--fixture-root",
                    str(fixture),
                    "--input",
                    str(input_path),
                ],
                cwd=REPOSITORY,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(reused.returncode, 0, reused.stderr)
            self.assertIn('"evaluation_id":"synthetic"', reused.stdout)
            self.assertTrue(
                (output / "evaluations/source-reuse/evaluation.json").is_file()
            )

    def test_runner_doctor_failure_cleans_redacted_diagnostic_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture, input_path, _ = self.make_case(root, "hike-code-switch-v1")
            binaries = self.make_fake_runner_commands(root)
            fake_cli = root / "failing-cli"
            fake_cli.write_text(
                f"#!/bin/sh\necho 'sensitive operator path {root}' >&2\nexit 1\n",
                encoding="utf-8",
            )
            fake_cli.chmod(0o700)
            temporary_files = root / "temporary-files"
            temporary_files.mkdir()
            environment = dict(os.environ)
            environment.update(
                {
                    "MACCHERONI_ACCEPTANCE_MODEL_RUN": "1",
                    "MACCHERONI_BENCHMARK_CACHE": "synthetic-cache",
                    "PATH": f"{binaries}:/usr/bin:/bin",
                    "TMPDIR": str(temporary_files),
                }
            )
            completed = subprocess.run(
                [
                    "bash",
                    str(REPOSITORY / "benchmarks/scripts/runners/run_acceptance_pack_v1.sh"),
                    "hike-code-switch-v1",
                    "acceptance-asr",
                    str(root / "doctor-output"),
                    "--evaluation-id",
                    "doctor-failure",
                    "--fixture-root",
                    str(fixture),
                    "--input",
                    str(input_path),
                    "--cli",
                    str(fake_cli),
                ],
                cwd=REPOSITORY,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("doctor did not report ready", completed.stderr)
            self.assertNotIn(str(root), completed.stderr)
            self.assertEqual(list(temporary_files.iterdir()), [])

    def test_benchmark_memory_stop_condition_boundaries(self) -> None:
        self.assertFalse(acceptance_memory_supported(MINIMUM_ACCEPTANCE_MEMORY_BYTES - 1))
        self.assertTrue(acceptance_memory_supported(MINIMUM_ACCEPTANCE_MEMORY_BYTES))
        self.assertTrue(acceptance_memory_supported(MINIMUM_ACCEPTANCE_MEMORY_BYTES + 1))


if __name__ == "__main__":
    unittest.main()
