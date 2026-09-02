import importlib.util
import hashlib
import io
import json
import subprocess
import sys
import tempfile
import types
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock


RUNNER = Path(__file__).parents[1] / "maccheroni_asr_runner.py"
SPEC = importlib.util.spec_from_file_location("maccheroni_asr_runner_evidence", RUNNER)
assert SPEC and SPEC.loader
runner = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = runner
SPEC.loader.exec_module(runner)


class StubSTTOutput:
    def __init__(self, *, generated_tokens: int, total_time: float = 1.25):
        self.prompt_tokens = 17
        self.generation_tokens = generated_tokens
        self.total_tokens = 17 + generated_tokens
        self.total_time = total_time


class BackendEvidenceTests(unittest.TestCase):
    def make_hf_dependency(
        self,
        cache_root: Path,
        spec,
        files: tuple[str, ...],
    ) -> tuple[Path, dict[str, object]]:
        repository = runner.hf_repository(cache_root, spec)
        snapshot = runner.hf_snapshot(cache_root, spec)
        snapshot.mkdir(parents=True)
        pins = {}
        tree_files = {}
        for relative in files:
            target = snapshot / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            payload = f"fixture:{relative}".encode("utf-8")
            target.write_bytes(payload)
            blob_id = hashlib.sha1(
                f"blob {len(payload)}\0".encode("ascii") + payload,
                usedforsecurity=False,
            ).hexdigest()
            pins[relative] = runner.HFFilePin(
                size=len(payload),
                sha256=hashlib.sha256(payload).hexdigest(),
                blob_id=blob_id,
            )
            tree_files[relative] = {
                "size": len(payload),
                "blob_id": blob_id,
            }
        (repository / "refs").mkdir()
        (repository / "refs/main").write_text(spec.revision, encoding="ascii")
        (repository / "trees").mkdir()
        (repository / "trees" / f"{spec.revision}.json").write_text(
            json.dumps({
                "format_version": 1,
                "files": tree_files,
            }),
            encoding="utf-8",
        )
        return repository, pins

    def make_vibevoice_closure(self, cache_root: Path):
        _, model_pins = self.make_hf_dependency(
            cache_root,
            runner.MODELS["vibevoice"],
            runner.VIBEVOICE_MODEL_FILES,
        )
        _, tokenizer_pins = self.make_hf_dependency(
            cache_root,
            runner.VIBEVOICE_TOKENIZER,
            runner.VIBEVOICE_TOKENIZER_FILES,
        )
        return model_pins, tokenizer_pins

    def fake_mlx_modules(self, generate):
        mlx_audio = types.ModuleType("mlx_audio")
        stt = types.ModuleType("mlx_audio.stt")
        generate_module = types.ModuleType("mlx_audio.stt.generate")
        utils_module = types.ModuleType("mlx_audio.stt.utils")
        generate_module.generate_transcription = generate
        utils_module.load_model = lambda *_args, **_kwargs: object()
        return {
            "mlx_audio": mlx_audio,
            "mlx_audio.stt": stt,
            "mlx_audio.stt.generate": generate_module,
            "mlx_audio.stt.utils": utils_module,
        }

    def run_vibevoice_stub(
        self,
        generated_tokens: int,
        max_tokens: int,
        raw_json: str = '{"text":"hello","segments":[{"start":0,"end":1,"text":"hello"}]}',
    ):
        with tempfile.TemporaryDirectory() as root_string:
            root = Path(root_string)
            captured = {}

            def generate_transcription(**kwargs):
                captured.update(kwargs)
                Path(kwargs["output_path"] + ".json").write_text(
                    raw_json,
                    encoding="utf-8",
                )
                return StubSTTOutput(generated_tokens=generated_tokens)

            with (
                mock.patch.object(runner, "version", return_value=runner.EXPECTED_MLX_AUDIO),
                mock.patch.object(runner, "assert_vibevoice_closure") as closure_check,
                mock.patch.dict(sys.modules, self.fake_mlx_modules(generate_transcription)),
            ):
                result = runner.run_vibevoice(
                    spec=runner.MODELS["vibevoice"],
                    audio=root / "audio.wav",
                    duration=1.0,
                    entries=[],
                    max_tokens=max_tokens,
                    cache_root=root,
                    work=root,
                )
            captured["closure_check_count"] = closure_check.call_count
            return result, captured

    def test_vibevoice_below_cap_is_observed_end_of_sequence(self) -> None:
        result, captured = self.run_vibevoice_stub(generated_tokens=4, max_tokens=5)

        self.assertEqual(captured["max_tokens"], 5)
        self.assertEqual(captured["closure_check_count"], 2)
        self.assertEqual(result["outcome"], "complete")
        self.assertEqual(result["stop_reason"], "endOfSequence")
        self.assertEqual(result["terminal_evidence"], "observed")
        self.assertEqual(result["timing_granularity"], "segment")
        self.assertEqual(result["metrics"]["prompt_tokens"], 17)
        self.assertEqual(result["metrics"]["generated_tokens"], 4)
        self.assertEqual(result["metrics"]["max_tokens"], 5)
        self.assertEqual(result["metrics"]["total_s"], 1.25)
        self.assertIsNone(result["metrics"]["preprocessing_s"])
        self.assertIn("preprocessing_s", result["metrics_unavailable"])

    def test_vibevoice_closure_requires_tokenizer_snapshot_ref_and_model_tree(self) -> None:
        for missing in ("tokenizer_snapshot", "tokenizer_ref", "model_tree"):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as root_string:
                root = Path(root_string)
                model_pins, tokenizer_pins = self.make_vibevoice_closure(root)
                tokenizer_repository = runner.hf_repository(root, runner.VIBEVOICE_TOKENIZER)
                model_repository = runner.hf_repository(root, runner.MODELS["vibevoice"])
                if missing == "tokenizer_snapshot":
                    (runner.hf_snapshot(root, runner.VIBEVOICE_TOKENIZER) / "tokenizer.json").unlink()
                elif missing == "tokenizer_ref":
                    (tokenizer_repository / "refs/main").unlink()
                else:
                    (model_repository / "trees" / f"{runner.MODELS['vibevoice'].revision}.json").unlink()

                with (
                    mock.patch.object(runner, "VIBEVOICE_MODEL_PINS", model_pins),
                    mock.patch.object(runner, "VIBEVOICE_TOKENIZER_PINS", tokenizer_pins),
                    mock.patch.object(runner, "vibevoice_tokenizer_semantics_are_valid", return_value=True),
                    mock.patch.object(runner, "version", return_value=runner.EXPECTED_MLX_AUDIO),
                ):
                    report = runner.doctor(runner.argparse.Namespace(backend="vibevoice", cache_root=str(root)))

                expected = {
                    "tokenizer_snapshot": "tokenizer_files",
                    "tokenizer_ref": "tokenizer_ref",
                    "model_tree": "model_tree",
                }[missing]
                check = next(item for item in report["checks"] if item["name"] == expected)
                self.assertFalse(check["ok"])
                self.assertFalse(report["ok"])

    def test_vibevoice_closure_rejects_same_size_model_and_tokenizer_corruption(self) -> None:
        cases = (
            ("model", runner.MODELS["vibevoice"], "config.json"),
            ("tokenizer", runner.VIBEVOICE_TOKENIZER, "tokenizer.json"),
        )
        for name, spec, relative in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as root_string:
                root = Path(root_string)
                model_pins, tokenizer_pins = self.make_vibevoice_closure(root)
                target = runner.hf_snapshot(root, spec) / relative
                payload = bytearray(target.read_bytes())
                payload[0] ^= 1
                target.write_bytes(payload)
                with (
                    mock.patch.object(runner, "VIBEVOICE_MODEL_PINS", model_pins),
                    mock.patch.object(runner, "VIBEVOICE_TOKENIZER_PINS", tokenizer_pins),
                    mock.patch.object(runner, "vibevoice_tokenizer_semantics_are_valid", return_value=True),
                    mock.patch.object(runner, "version", return_value=runner.EXPECTED_MLX_AUDIO),
                ):
                    with self.assertRaises(runner.RunnerError):
                        runner.assert_vibevoice_closure(root)
                    report = runner.doctor(
                        runner.argparse.Namespace(backend="vibevoice", cache_root=str(root))
                    )

                check = next(item for item in report["checks"] if item["name"] == f"{name}_files")
                self.assertFalse(check["ok"])
                self.assertFalse(report["ok"])

    def test_vibevoice_tokenizer_semantics_use_bare_offline_repository_id(self) -> None:
        captured = {}

        class Tokenizer:
            eos_token_id = 151643

            @staticmethod
            def convert_tokens_to_ids(token):
                return {
                    "<|object_ref_start|>": 151646,
                    "<|object_ref_end|>": 151647,
                    "<|box_start|>": 151648,
                }[token]

        transformers = types.ModuleType("transformers")

        class AutoTokenizer:
            @staticmethod
            def from_pretrained(model_id, **kwargs):
                captured["model_id"] = model_id
                captured["kwargs"] = kwargs
                captured["hf_home"] = runner.os.environ.get("HF_HOME")
                captured["offline"] = runner.os.environ.get("HF_HUB_OFFLINE")
                return Tokenizer()

        transformers.AutoTokenizer = AutoTokenizer
        with tempfile.TemporaryDirectory() as root_string, mock.patch.dict(
            sys.modules,
            {"transformers": transformers},
        ):
            root = Path(root_string)
            self.assertTrue(runner.vibevoice_tokenizer_semantics_are_valid(root))

        self.assertEqual(captured["model_id"], "Qwen/Qwen2.5-7B")
        self.assertEqual(captured["kwargs"], {"local_files_only": True, "trust_remote_code": True})
        self.assertEqual(captured["hf_home"], str(root / "models/huggingface"))
        self.assertEqual(captured["offline"], "1")

    def test_structured_exception_class_rejects_untrusted_type_name(self) -> None:
        unsafe_type = type("Secret\nBearerToken", (Exception,), {})

        self.assertEqual(runner.safe_exception_class(unsafe_type()), "Exception")
        self.assertEqual(runner.safe_exception_class(RuntimeError()), "RuntimeError")

    def test_vibevoice_at_cap_is_typed_limit_without_promotable_text(self) -> None:
        fixtures = {
            "empty": '{"text":"","segments":[]}',
            "partial-segment": '{"text":"unfinished","segments":[{"start":0,"text":"unfinished"}]}',
        }
        for name, raw_json in fixtures.items():
            with self.subTest(name=name):
                result, _ = self.run_vibevoice_stub(
                    generated_tokens=5,
                    max_tokens=5,
                    raw_json=raw_json,
                )

                self.assertEqual(result["outcome"], "limit")
                self.assertEqual(result["stop_reason"], "maximumTokens")
                self.assertEqual(result["raw_text"], "")
                self.assertEqual(result["segments"], [])
                self.assertEqual(result["metrics"]["generated_tokens"], 5)

    def test_vibevoice_below_cap_rejects_empty_output(self) -> None:
        with self.assertRaisesRegex(runner.RunnerError, "has no segments"):
            self.run_vibevoice_stub(
                generated_tokens=4,
                max_tokens=5,
                raw_json='{"text":"","segments":[]}',
            )

    def test_vibevoice_failure_does_not_promote_dependency_exception_text(self) -> None:
        with tempfile.TemporaryDirectory() as root_string:
            root = Path(root_string)

            def generate_transcription(**_kwargs):
                raise RuntimeError(
                    "private transcript Bearer secret https://user:pass@example.test /Users/private/audio.wav"
                )

            with (
                mock.patch.object(runner, "version", return_value=runner.EXPECTED_MLX_AUDIO),
                mock.patch.object(runner, "assert_vibevoice_closure"),
                mock.patch.dict(sys.modules, self.fake_mlx_modules(generate_transcription)),
            ):
                with self.assertRaises(runner.RunnerError) as failure:
                    runner.run_vibevoice(
                        spec=runner.MODELS["vibevoice"],
                        audio=root / "audio.wav",
                        duration=1.0,
                        entries=[],
                        max_tokens=5,
                        cache_root=root,
                        work=root,
                    )

        self.assertEqual(failure.exception.code, "backend_inference_failed")
        self.assertEqual(str(failure.exception), "VibeVoice inference failed (RuntimeError)")

    def test_vibevoice_rejects_generation_count_above_effective_cap(self) -> None:
        with self.assertRaisesRegex(runner.RunnerError, "exceeds the requested cap"):
            self.run_vibevoice_stub(generated_tokens=6, max_tokens=5)

    def test_qwen_declares_terminal_and_timing_evidence_unavailable(self) -> None:
        with tempfile.TemporaryDirectory() as root_string:
            root = Path(root_string)
            completed = subprocess.CompletedProcess([], 0, "Result: hello\n", "")
            with (
                mock.patch.object(runner, "assert_hf_snapshot"),
                mock.patch.object(runner.shutil, "which", return_value="/usr/local/bin/speech"),
                mock.patch.object(runner, "run_process", return_value=completed),
            ):
                result = runner.run_qwen(
                    spec=runner.MODELS["qwen3"],
                    audio=root / "audio.wav",
                    duration=2.0,
                    entries=[],
                    language=None,
                    max_tokens=37,
                    cache_root=root,
                    timeout_seconds=1.0,
                    work=root,
                )

        self.assertEqual(result["outcome"], "unverified")
        self.assertIsNone(result["stop_reason"])
        self.assertEqual(result["terminal_evidence"], "unavailable")
        self.assertEqual(result["timing_granularity"], "chunk")
        self.assertEqual(result["raw_text"], "hello")
        self.assertEqual(result["segments"], [])
        self.assertNotIn("--max-tokens", result["command"])
        self.assertEqual(result["metrics"]["requested_max_tokens"], 37)
        self.assertIsNone(result["metrics"]["max_tokens"])
        self.assertIsNone(result["metrics"]["generated_tokens"])
        self.assertEqual(result["metrics"]["audio_duration_s"], 2.0)
        self.assertIn("max_tokens", result["metrics_unavailable"])
        self.assertEqual(result["failure"]["code"], "evidence_unavailable")

    def test_qwen_failure_does_not_promote_stderr_content(self) -> None:
        private_stderr = (
            "민감한 전사 표식 private English transcript "
            "Bearer secret-token https://user:pass@example.test/private.wav"
        )
        with tempfile.TemporaryDirectory() as root_string:
            root = Path(root_string)
            completed = subprocess.CompletedProcess([], 73, "", private_stderr)
            with (
                mock.patch.object(runner, "assert_hf_snapshot"),
                mock.patch.object(runner.shutil, "which", return_value="/usr/local/bin/speech"),
                mock.patch.object(runner, "run_process", return_value=completed),
            ):
                with self.assertRaises(runner.RunnerError) as failure:
                    runner.run_qwen(
                        spec=runner.MODELS["qwen3"],
                        audio=root / "audio.wav",
                        duration=2.0,
                        entries=[],
                        language=None,
                        max_tokens=37,
                        cache_root=root,
                        timeout_seconds=1.0,
                        work=root,
                    )

        self.assertEqual(failure.exception.code, "backend_failed")
        self.assertEqual(
            str(failure.exception),
            "Qwen backend exited with status 73",
        )
        self.assertNotIn("민감한 전사 표식", str(failure.exception))
        self.assertNotIn("Bearer", str(failure.exception))
        self.assertNotIn("https://", str(failure.exception))

    def test_moss_invalid_eos_keeps_helper_message_only_in_protected_artifact(self) -> None:
        private_message = (
            "민감한 전사 표식 private English transcript "
            "Bearer secret-token https://user:pass@example.test/private.wav"
        )
        with tempfile.TemporaryDirectory() as root_string:
            root = Path(root_string)
            spec = runner.MODELS["moss"]
            model_dir = root / "models" / f"moss-transcribe-diarize-0.9b-mlx-int8-{spec.revision}"
            metadata = model_dir / ".cache" / "huggingface" / "trees" / f"{spec.revision}.json"
            metadata.parent.mkdir(parents=True)
            metadata.write_text("{}", encoding="utf-8")
            instruction_hash = "a" * 64
            payload = {
                "status": "failed",
                "model": {
                    "hf_id": spec.hf_model_id,
                    "revision": spec.revision,
                    "quantization": spec.quantization,
                },
                "audio": {"duration_s": 1.0},
                "failure": {
                    "code": "invalid_eos_output",
                    "message": private_message,
                },
                "glossary": {
                    "applied": False,
                    "item_count": 0,
                    "instruction_sha256": instruction_hash,
                },
                "language": {
                    "requested": "auto",
                    "instruction_sha256": instruction_hash,
                    "prompt_guidance_applied": False,
                },
                "metrics": {
                    "stop_reason": "endOfSequence",
                    "preprocessing_s": 0.0,
                    "audio_encoder_s": 0.0,
                    "decoder_prefill_s": 0.0,
                    "token_decode_s": 0.0,
                    "total_s": 0.0,
                    "model_load_s": 0.0,
                    "audio_duration_s": 1.0,
                    "prompt_tokens": 1,
                    "generated_tokens": 1,
                    "max_tokens": 37,
                    "context_hard_cap_tokens": 131_072,
                    "peak_rss_bytes": 1,
                },
            }

            def run_process(_command, *, timeout_seconds, env):
                del timeout_seconds, env
                (root / "moss.json").write_text(
                    json.dumps(payload, ensure_ascii=False),
                    encoding="utf-8",
                )
                return subprocess.CompletedProcess([], 1, "", private_message)

            fingerprint = {"sha256": "b" * 64}
            with (
                mock.patch.object(runner, "verify_moss_harness_fingerprint", return_value=fingerprint),
                mock.patch.object(runner, "run_process", side_effect=run_process),
            ):
                result = runner.run_moss(
                    spec=spec,
                    audio=root / "audio.wav",
                    duration=1.0,
                    entries=[],
                    language="auto",
                    max_tokens=37,
                    cache_root=root,
                    work=root,
                    timeout_seconds=1.0,
                )

            artifact_text = Path(result["artifact"]).read_text(encoding="utf-8")

        self.assertEqual(result["outcome"], "invalid_eos_output")
        self.assertEqual(
            result["failure"],
            {
                "code": "invalid_eos_output",
                "message": "MOSS EOS output has no validated segments",
            },
        )
        self.assertIn(private_message, artifact_text)
        self.assertNotIn("민감한 전사 표식", result["failure"]["message"])
        self.assertNotIn("Bearer", result["failure"]["message"])
        self.assertNotIn("https://", result["failure"]["message"])

    @staticmethod
    def transcript_object(start: float, end: float, content: str, speaker: int = 0) -> str:
        return json.dumps(
            {"Start": start, "End": end, "Speaker": speaker, "Content": content},
            ensure_ascii=False,
        )

    def test_repetition_run_counts_consecutive_repeats_not_frequency(self) -> None:
        cases = {
            "": 0,
            "one two three": 1,
            "so so": 2,
            "yes, yes, yes": 3,
            "the plan is the plan is the plan is fine": 3,
            "ok " * 40: 40,
            "네, " * 75: 75,
            # A long passage that reuses one common word without ever repeating
            # a block adjacently is not looping.
            " ".join("the item%d" % index for index in range(20)): 1,
            # A multi-unit phrase cycled adjacently is looping, and is the
            # shape a four-unit window missed on a measured run.
            " ".join(["the customer count rose sharply"] * 30): 30,
        }
        for text, expected in cases.items():
            with self.subTest(text=text[:24]):
                self.assertEqual(runner.repetition_run_length(text), expected)

    def test_phrase_window_catches_the_measured_five_unit_runaway(self) -> None:
        """A five-unit cycle is the shape that defeated a four-unit window.

        A measured collapse repeated a five-unit phrase 333 times inside a
        single unterminated object.  Scored over 1-to-4-grams that reads as 2
        and the payload is filed as a legitimate cap hit; scored over
        1-to-8-grams it reads as 333.
        """
        cycle = "the customer count rose sharply "
        self.assertEqual(runner.VIBEVOICE_REPETITION_PHRASE_UNITS, 8)
        self.assertEqual(runner.repetition_run_length(cycle * 333), 333)
        self.assertTrue(runner.is_repetition_looping(cycle * 333))
        # The same text scored with the old window is why the miss happened.
        self.assertLess(runner.repetition_run_length(cycle * 333, phrase_units=4), 12)

    def test_repetition_threshold_boundary_is_below_at_and_above(self) -> None:
        self.assertFalse(runner.is_repetition_looping("ok " * (runner.VIBEVOICE_REPETITION_RUN_THRESHOLD - 1)))
        self.assertTrue(runner.is_repetition_looping("ok " * runner.VIBEVOICE_REPETITION_RUN_THRESHOLD))
        self.assertTrue(runner.is_repetition_looping("ok " * (runner.VIBEVOICE_REPETITION_RUN_THRESHOLD + 1)))

    def test_a_sub_critical_stutter_that_escapes_is_not_looping(self) -> None:
        """The strongest negative case: an accepted transcript contains the
        same failure mode below the threshold.

        The 240-second Korean leaf that completed with end-of-sequence and
        full coverage carries a segment that repeats one word six times and
        then resumes normal speech.  A detector that fired on it would fail a
        passing run, so the threshold has to clear that shape with margin.
        """
        escaped = "and then " + "again " * 6 + "the meeting moved on to the next item"
        self.assertEqual(runner.repetition_run_length(escaped), 6)
        self.assertFalse(runner.is_repetition_looping(escaped))

        # The same word repeated in the audio itself, transcribed correctly.
        backchannel = "yes, yes, yes. the address is over there"
        self.assertFalse(runner.is_repetition_looping(backchannel))

        prefix = runner.recover_vibevoice_prefix(
            "[" + ",".join([
                self.transcript_object(0.0, 10.0, escaped),
                self.transcript_object(10.0, 20.0, backchannel),
            ]) + "]",
            30.0,
        )
        self.assertEqual(prefix["promoted_object_count"], 2)
        self.assertEqual(prefix["degenerate_object_count"], 0)
        self.assertFalse(prefix["terminal_collapse"])
        self.assertEqual(prefix["coverage_s"], 20.0)

    def test_recovered_episodes_and_the_terminal_one_are_separated_by_position(self) -> None:
        """An episode followed by clean output recovered; the last one did not.

        Position, not episode length, is the discriminator: the evidence that
        an episode was survivable is that correct output follows it.  The
        measured lengths corroborate the split rather than define it.
        """
        episode = "ok, " * 74
        text = "[" + ",".join([
            self.transcript_object(0.0, 10.0, "first clean passage"),
            self.transcript_object(10.0, 20.0, episode),
            self.transcript_object(20.0, 30.0, "recovered clean passage"),
            self.transcript_object(30.0, 40.0, episode),
            self.transcript_object(40.0, 50.0, "recovered a second time"),
        ]) + ',{"Start":50.0,"End":60.0,"Speaker":0,"Content":"' + "ok, " * 1050

        prefix = runner.recover_vibevoice_prefix(text, 90.0)

        self.assertEqual(prefix["promoted_object_count"], 5)
        self.assertEqual(prefix["degenerate_object_count"], 2)
        self.assertEqual(prefix["coverage_s"], 50.0)
        self.assertTrue(prefix["terminal_collapse"])
        # Both survivable episodes stay inside the promoted prefix, marked.
        self.assertEqual(
            [item["degenerate"] for item in prefix["segments"]],
            [False, True, False, True, False],
        )

    def test_prefix_recovery_keeps_an_interior_collapse_and_drops_the_terminal_one(self) -> None:
        collapsed = "ok, " * 40
        text = "[" + ",".join([
            self.transcript_object(0.0, 10.0, "first clean passage"),
            self.transcript_object(10.0, 20.0, collapsed),
            self.transcript_object(20.0, 30.0, "recovered clean passage"),
            self.transcript_object(30.0, 40.0, collapsed),
        ]) + ',{"Start":40.0,"End":50.0,"Speaker":0,"Content":"' + collapsed

        prefix = runner.recover_vibevoice_prefix(text, 60.0)

        self.assertEqual(prefix["complete_object_count"], 4)
        self.assertEqual(prefix["validated_object_count"], 4)
        self.assertEqual(prefix["promoted_object_count"], 3)
        self.assertEqual(prefix["degenerate_object_count"], 2)
        self.assertEqual(prefix["coverage_s"], 30.0)
        self.assertTrue(prefix["terminal_collapse"])
        self.assertEqual([item["degenerate"] for item in prefix["segments"]], [False, True, False])
        self.assertTrue(prefix["raw_text"].startswith("[{"))
        self.assertTrue(prefix["raw_text"].endswith("]"))
        self.assertEqual(len(json.loads(prefix["raw_text"])), 3)

    def test_prefix_recovery_stops_at_the_first_unusable_object(self) -> None:
        text = "[" + ",".join([
            self.transcript_object(0.0, 10.0, "first"),
            self.transcript_object(10.0, 999.0, "beyond the chunk"),
            self.transcript_object(20.0, 30.0, "never reached"),
        ]) + "]"

        prefix = runner.recover_vibevoice_prefix(text, 60.0)

        self.assertEqual(prefix["complete_object_count"], 3)
        self.assertEqual(prefix["validated_object_count"], 1)
        self.assertEqual(prefix["promoted_object_count"], 1)
        self.assertEqual(prefix["coverage_s"], 10.0)
        self.assertFalse(prefix["terminal_collapse"])

    def test_vibevoice_terminal_collapse_is_typed_apart_from_the_token_cap(self) -> None:
        collapsed = "ok, " * 40
        text = (
            "[" + self.transcript_object(0.0, 0.6, "clean opening")
            + ',{"Start":0.6,"End":1.0,"Speaker":0,"Content":"' + collapsed
        )
        result, _ = self.run_vibevoice_stub(
            generated_tokens=5,
            max_tokens=5,
            raw_json=json.dumps({"text": text, "segments": []}, ensure_ascii=False),
        )

        self.assertEqual(result["outcome"], "limit")
        self.assertEqual(result["stop_reason"], "repetitionLooping")
        self.assertEqual(result["raw_text"], "")
        self.assertEqual(result["segments"], [])
        prefix = result["partial_prefix"]
        self.assertTrue(prefix["terminal_collapse"])
        self.assertEqual(prefix["promoted_object_count"], 1)
        self.assertAlmostEqual(prefix["coverage_s"], 0.6)
        self.assertGreaterEqual(prefix["tail_repetition_run"], runner.VIBEVOICE_REPETITION_RUN_THRESHOLD)

    def test_vibevoice_cap_hit_without_collapse_keeps_maximum_tokens(self) -> None:
        text = (
            "[" + self.transcript_object(0.0, 0.6, "clean opening")
            + ',{"Start":0.6,"End":1.0,"Speaker":0,"Content":"still describing new content'
        )
        result, _ = self.run_vibevoice_stub(
            generated_tokens=5,
            max_tokens=5,
            raw_json=json.dumps({"text": text, "segments": []}, ensure_ascii=False),
        )

        self.assertEqual(result["outcome"], "limit")
        self.assertEqual(result["stop_reason"], "maximumTokens")
        prefix = result["partial_prefix"]
        self.assertFalse(prefix["terminal_collapse"])
        self.assertEqual(prefix["promoted_object_count"], 1)

    def test_vibevoice_end_of_sequence_with_a_collapsed_tail_is_not_complete(self) -> None:
        collapsed = "ok, " * 40
        raw_json = json.dumps({
            "text": "[" + ",".join([
                self.transcript_object(0.0, 0.6, "clean opening"),
                self.transcript_object(0.6, 1.0, collapsed),
            ]) + "]",
            "segments": [
                {"start": 0.0, "end": 0.6, "text": "clean opening", "speaker_id": 0},
                {"start": 0.6, "end": 1.0, "text": collapsed, "speaker_id": 0},
            ],
        }, ensure_ascii=False)

        result, _ = self.run_vibevoice_stub(generated_tokens=4, max_tokens=5, raw_json=raw_json)

        self.assertEqual(result["outcome"], "limit")
        self.assertEqual(result["stop_reason"], "repetitionLooping")
        self.assertEqual(result["segments"], [])
        self.assertEqual(result["partial_prefix"]["promoted_object_count"], 1)
        self.assertAlmostEqual(result["partial_prefix"]["coverage_s"], 0.6)

    def test_vibevoice_end_of_sequence_below_the_threshold_stays_complete(self) -> None:
        mild = "ok, " * (runner.VIBEVOICE_REPETITION_RUN_THRESHOLD - 1)
        raw_json = json.dumps({
            "text": "[" + self.transcript_object(0.0, 1.0, mild) + "]",
            "segments": [{"start": 0.0, "end": 1.0, "text": mild, "speaker_id": 0}],
        }, ensure_ascii=False)

        result, _ = self.run_vibevoice_stub(generated_tokens=4, max_tokens=5, raw_json=raw_json)

        self.assertEqual(result["outcome"], "complete")
        self.assertEqual(result["stop_reason"], "endOfSequence")
        self.assertNotIn("degenerate", result["segments"][0])

    def test_unverified_evidence_exits_nonzero(self) -> None:
        document = {
            "outcome": "unverified",
            "failure": {
                "code": "evidence_unavailable",
                "message": "terminal evidence is unavailable",
            },
        }
        with (
            mock.patch.object(runner, "parse_args", return_value=runner.argparse.Namespace(operation="run")),
            mock.patch.object(runner, "run", return_value=document),
            redirect_stdout(io.StringIO()),
            redirect_stderr(io.StringIO()),
        ):
            status = runner.main([])

        self.assertEqual(status, 2)


if __name__ == "__main__":
    unittest.main()
