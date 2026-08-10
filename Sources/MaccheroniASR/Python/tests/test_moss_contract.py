import hashlib
import importlib.util
import json
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


RUNNER = Path(__file__).parents[1] / "maccheroni_asr_runner.py"
SPEC = importlib.util.spec_from_file_location("maccheroni_asr_runner", RUNNER)
assert SPEC and SPEC.loader
runner = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = runner
SPEC.loader.exec_module(runner)


def digest(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def moss_payload(
    *,
    status: str,
    stop_reason: str,
    raw_text: str,
    segments: list,
    instruction: str,
    duration: float = 4.0,
) -> dict:
    return {
        "status": status,
        "model": {
            "hf_id": runner.MODELS["moss"].hf_model_id,
            "revision": runner.MODELS["moss"].revision,
            "quantization": runner.MODELS["moss"].quantization,
        },
        "audio": {"duration_s": duration},
        "glossary": {"applied": True, "item_count": 1, "instruction_sha256": instruction},
        "language": {
            "requested": "it",
            "instruction_sha256": instruction,
            "prompt_guidance_applied": True,
        },
        "raw_text": raw_text,
        "segments": segments,
        "metrics": {
            "stop_reason": stop_reason,
            "preprocessing_s": 0,
            "audio_encoder_s": 0,
            "decoder_prefill_s": 0,
            "token_decode_s": 0,
            "total_s": 0,
            "model_load_s": 0,
            "audio_duration_s": duration,
            "prompt_tokens": 1,
            "generated_tokens": 1,
            "max_tokens": 5120,
            "context_hard_cap_tokens": 131072,
            "peak_rss_bytes": 0,
        },
    }


class MossContractTests(unittest.TestCase):
    def test_language_hint_uses_an_unambiguous_display_name(self) -> None:
        italian = runner.moss_harness_instruction([], "it")
        self.assertIn("Language: Italian.", italian)
        self.assertNotIn("Language: it.", italian)
        fallback = runner.moss_harness_instruction([], "x-test")
        self.assertIn("BCP-47 tag 'x-test'", fallback)

    def make_cache(self) -> tuple[tempfile.TemporaryDirectory[str], Path]:
        temporary = tempfile.TemporaryDirectory()
        cache = Path(temporary.name)
        root = cache / "swift-scratch/moss-harness/arm64-apple-macosx/release"
        root.mkdir(parents=True)
        binary = root / "MaccheroniMossHarness"
        binary.write_bytes(b"synthetic helper")
        binary.chmod(binary.stat().st_mode | stat.S_IXUSR)
        metallib = root / "mlx.metallib"
        metallib.write_bytes(b"synthetic metallib")
        swift = "Swift version synthetic"
        fingerprint = {
            "contract_version": "moss-harness-v2",
            "source_tree_sha256": digest(b"source"),
            "package_swift_sha256": digest(b"package"),
            "package_resolved_sha256": digest(b"resolved"),
            "swift_version": swift,
            "swift_version_sha256": digest(swift.encode()),
            "target_architecture": "arm64",
            "configuration": "release",
            "build_flags": ["--configuration", "release", "--arch", "arm64", "--product", "MaccheroniMossHarness"],
            "executable_sha256": digest(binary.read_bytes()),
            "metallib_sha256": digest(metallib.read_bytes()),
        }
        Path(str(binary) + ".fingerprint.json").write_text(json.dumps(fingerprint), encoding="utf-8")
        return temporary, cache

    def test_valid_release_fingerprint_returns_sidecar_hash(self) -> None:
        temporary, cache = self.make_cache()
        with temporary:
            found = runner.verify_moss_harness_fingerprint(cache)
            self.assertEqual(found["contract_version"], "moss-harness-v2")
            self.assertEqual(len(found["sha256"]), 64)

    def test_missing_stale_and_malformed_fingerprints_are_distinguished(self) -> None:
        temporary, cache = self.make_cache()
        with temporary:
            binary, _, sidecar = runner.moss_harness_paths(cache)
            sidecar.unlink()
            with self.assertRaisesRegex(runner.RunnerError, "fingerprint is missing"):
                runner.verify_moss_harness_fingerprint(cache)
            sidecar.write_text("{broken", encoding="utf-8")
            with self.assertRaisesRegex(runner.RunnerError, "fingerprint is malformed"):
                runner.verify_moss_harness_fingerprint(cache)
            payload = {"contract_version": "moss-harness-v2"}
            sidecar.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(runner.RunnerError, "lacks the required"):
                runner.verify_moss_harness_fingerprint(cache)
            # Recreate valid then mutate the helper, which is a stale cache.
            temporary.cleanup()
        temporary, cache = self.make_cache()
        with temporary:
            binary, _, _ = runner.moss_harness_paths(cache)
            binary.write_bytes(b"changed helper")
            with self.assertRaisesRegex(runner.RunnerError, "no longer matches"):
                runner.verify_moss_harness_fingerprint(cache)

    def test_max_tokens_is_bounded_at_context_cap(self) -> None:
        args = runner.parse_args(["run", "--backend", "moss", "--audio", "x", "--start-s", "0", "--end-s", "1", "--injection-mode", "none", "--cache-root", "x", "--output", "y", "--max-tokens", "131073"])
        self.assertEqual(args.max_tokens, 131073)

    def test_fingerprint_rejects_swift_digest_and_symlink_tamper(self) -> None:
        temporary, cache = self.make_cache()
        with temporary:
            binary, _, sidecar = runner.moss_harness_paths(cache)
            payload = json.loads(sidecar.read_text(encoding="utf-8"))
            payload["swift_version_sha256"] = digest(b"wrong")
            sidecar.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(runner.RunnerError, "lacks the required"):
                runner.verify_moss_harness_fingerprint(cache)
            sidecar.unlink()
            sidecar.symlink_to(binary)
            with self.assertRaisesRegex(runner.RunnerError, "fingerprint is missing"):
                runner.verify_moss_harness_fingerprint(cache)

    def test_run_rejects_tokens_above_hard_context_before_audio_access(self) -> None:
        args = runner.argparse.Namespace(backend="moss", max_tokens=131073)
        with self.assertRaisesRegex(runner.RunnerError, "1...131072"):
            runner.run(args)

    def test_prompt_plan_counts_chunked_audio_and_rejects_context_overflow(self) -> None:
        from tokenizers import Tokenizer, models

        with tempfile.TemporaryDirectory() as root_string:
            cache = Path(root_string)
            model = cache / "models/moss-transcribe-diarize-0.9b-mlx-int8-90aa65287111a327db98eb83e325bd5332945edd"
            (model / ".cache/huggingface/trees").mkdir(parents=True)
            (model / ".cache/huggingface/trees/90aa65287111a327db98eb83e325bd5332945edd.json").write_text("{}", encoding="utf-8")
            vocabulary = {
                "[UNK]": 0,
                "<|audio_pad|>": 1,
                "<|im_end|>": 2,
                **{digit: index + 3 for index, digit in enumerate("0123456789")},
            }
            tokenizer = Tokenizer(models.WordLevel(vocabulary, unk_token="[UNK]"))
            tokenizer.save(str(model / "tokenizer.json"))
            (model / "processor_config.json").write_text(json.dumps({
                "audio_tokens_per_second": 12.5,
                "time_marker_every_seconds": 5,
                "enable_time_marker": True,
            }), encoding="utf-8")
            glossary = cache / "glossary.txt"
            glossary.write_text("\ufeff# owner notes\r\n Maccheroni \r\nMaccheroni\r\n", encoding="utf-8")
            original_glossary_sha = runner.sha256_file(glossary)
            args = runner.argparse.Namespace(
                sample_count=240 * 16_000,
                language="it",
                glossary=str(glossary),
                glossary_sha256=original_glossary_sha,
                cache_root=str(cache),
                max_tokens=5_120,
            )
            original = runner.verify_moss_harness_fingerprint
            runner.verify_moss_harness_fingerprint = lambda _cache: {
                "sha256": digest(b"sidecar")
            }
            try:
                plan = runner.plan_moss_prompt(args)
                self.assertEqual(plan["audio_tokens"], 3_000)
                self.assertEqual(
                    plan["prompt_tokens"],
                    plan["text_tokens"] + plan["audio_span_tokens"],
                )
                self.assertEqual(
                    plan["context_upper_bound_tokens"],
                    plan["prompt_tokens"] + 5_120,
                )
                self.assertEqual(plan["glossary_sha256"], original_glossary_sha)
                self.assertNotEqual(
                    plan["glossary_payload_sha256"],
                    original_glossary_sha,
                )
                args.max_tokens = 130_000
                with self.assertRaisesRegex(runner.RunnerError, "exceeding"):
                    runner.plan_moss_prompt(args)
            finally:
                runner.verify_moss_harness_fingerprint = original

    def test_moss_exit_matrix_and_partial_exclusion(self) -> None:
        temporary, cache = self.make_cache()
        with temporary:
            model = cache / "models/moss-transcribe-diarize-0.9b-mlx-int8-90aa65287111a327db98eb83e325bd5332945edd/.cache/huggingface/trees"
            model.mkdir(parents=True)
            (model / "90aa65287111a327db98eb83e325bd5332945edd.json").write_text("{}", encoding="utf-8")
            work = cache / "work"; work.mkdir()
            original_fingerprint, original_process = runner.verify_moss_harness_fingerprint, runner.run_process
            runner.verify_moss_harness_fingerprint = lambda _cache: {"path": str(cache / "helper.fingerprint.json"), "sha256": digest(b"sidecar")}
            try:
                for stop, exit_code, expected_outcome in (("endOfSequence", 0, "complete"), ("maximumTokens", 75, "limit"), ("contextLimit", 76, "limit")):
                    output = work / "moss.json"
                    instruction = digest(b"instruction")
                    payload = {
                        "status": "complete" if exit_code == 0 else "incomplete",
                        "model": {"hf_id": runner.MODELS["moss"].hf_model_id, "revision": runner.MODELS["moss"].revision, "quantization": runner.MODELS["moss"].quantization},
                        "audio": {"duration_s": 4.0},
                        "glossary": {"applied": True, "item_count": 1, "instruction_sha256": instruction},
                        "language": {"requested": "it", "instruction_sha256": instruction, "prompt_guidance_applied": True},
                        "raw_text": "partial" if exit_code else "complete",
                        "segments": [{"start_s": 0, "end_s": 4, "speaker": "S1", "text": "complete"}],
                        "metrics": {"stop_reason": stop, "preprocessing_s": 0, "audio_encoder_s": 0, "decoder_prefill_s": 0, "token_decode_s": 0, "total_s": 0, "model_load_s": 0, "audio_duration_s": 4.0, "prompt_tokens": 1, "generated_tokens": 1, "max_tokens": 5120, "context_hard_cap_tokens": 131072, "peak_rss_bytes": 0},
                    }
                    output.write_text(json.dumps(payload), encoding="utf-8")
                    runner.run_process = lambda *args, code=exit_code, **kwargs: subprocess.CompletedProcess([], code, "", "")
                    found = runner.run_moss(spec=runner.MODELS["moss"], audio=cache / "audio.wav", duration=4.0, entries=["Maccheroni"], language="it", max_tokens=5120, cache_root=cache, work=work, timeout_seconds=1)
                    self.assertEqual(found["outcome"], expected_outcome)
                    self.assertEqual(found["metrics"]["requested_max_tokens"], 5120)
                    if expected_outcome == "limit":
                        self.assertEqual(found["raw_text"], "")
                        self.assertEqual(found["segments"], [])
                    output.unlink()
                payload["status"] = "failed"
                payload["raw_text"] = "partial output must stay in the raw helper artifact"
                payload["segments"] = []
                payload["metrics"]["stop_reason"] = "endOfSequence"
                payload["failure"] = {
                    "code": "invalid_eos_output",
                    "message": "MOSS EOS output has no validated segments",
                }
                output.write_text(json.dumps(payload), encoding="utf-8")
                runner.run_process = lambda *args, **kwargs: subprocess.CompletedProcess([], 1, "", "")
                found = runner.run_moss(spec=runner.MODELS["moss"], audio=cache / "audio.wav", duration=4.0, entries=["Maccheroni"], language="it", max_tokens=5120, cache_root=cache, work=work, timeout_seconds=1)
                self.assertEqual(found["outcome"], "invalid_eos_output")
                self.assertEqual(found["failure"]["code"], "invalid_eos_output")
                self.assertEqual(found["raw_text"], "")
                self.assertEqual(found["segments"], [])
                self.assertEqual(found["diagnostics"]["invalid_eos_source"], "harness")
                output.unlink()
                # A helper status/exit mismatch is never accepted as a typed limit.
                payload["failure"]["code"] = "wrong_failure_code"
                output.write_text(json.dumps(payload), encoding="utf-8")
                runner.run_process = lambda *args, **kwargs: subprocess.CompletedProcess([], 1, "", "")
                with self.assertRaisesRegex(runner.RunnerError, "exit/status/stop mismatch"):
                    runner.run_moss(spec=runner.MODELS["moss"], audio=cache / "audio.wav", duration=4.0, entries=["Maccheroni"], language="it", max_tokens=5120, cache_root=cache, work=work, timeout_seconds=1)
                output.unlink()
                payload["failure"]["code"] = "invalid_eos_output"
                # The typed failure needs all four elements: a wrong exit code
                # and a wrong status each fall back to a contract mismatch.
                for exit_code, status in ((2, "failed"), (1, "complete")):
                    payload["status"] = status
                    output.write_text(json.dumps(payload), encoding="utf-8")
                    runner.run_process = lambda *args, code=exit_code, **kwargs: subprocess.CompletedProcess([], code, "", "")
                    with self.assertRaisesRegex(runner.RunnerError, "exit/status/stop mismatch"):
                        runner.run_moss(spec=runner.MODELS["moss"], audio=cache / "audio.wav", duration=4.0, entries=["Maccheroni"], language="it", max_tokens=5120, cache_root=cache, work=work, timeout_seconds=1)
                    output.unlink()
                payload["status"] = "failed"
                payload.pop("failure")
                output.write_text(json.dumps(payload), encoding="utf-8")
                runner.run_process = lambda *args, **kwargs: subprocess.CompletedProcess([], 0, "", "")
                with self.assertRaisesRegex(runner.RunnerError, "exit/status/stop mismatch"):
                    runner.run_moss(spec=runner.MODELS["moss"], audio=cache / "audio.wav", duration=4.0, entries=["Maccheroni"], language="it", max_tokens=5120, cache_root=cache, work=work, timeout_seconds=1)
            finally:
                runner.verify_moss_harness_fingerprint, runner.run_process = original_fingerprint, original_process

    def prepare_moss_model(self, cache: Path) -> Path:
        trees = cache / "models/moss-transcribe-diarize-0.9b-mlx-int8-90aa65287111a327db98eb83e325bd5332945edd/.cache/huggingface/trees"
        trees.mkdir(parents=True)
        (trees / "90aa65287111a327db98eb83e325bd5332945edd.json").write_text("{}", encoding="utf-8")
        work = cache / "work"
        work.mkdir()
        return work

    def test_eos_structure_failures_close_as_typed_invalid_eos_output(self) -> None:
        temporary, cache = self.make_cache()
        with temporary:
            work = self.prepare_moss_model(cache)
            output = work / "moss.json"
            instruction = digest(b"instruction")
            original_fingerprint, original_process = runner.verify_moss_harness_fingerprint, runner.run_process
            runner.verify_moss_harness_fingerprint = lambda _cache: {"path": str(cache / "helper.fingerprint.json"), "sha256": digest(b"sidecar")}
            runner.run_process = lambda *args, **kwargs: subprocess.CompletedProcess([], 0, "", "")
            try:
                variants = {
                    "out_of_range_timestamp": (
                        "transcript",
                        [{"start_s": 0, "end_s": 9.5, "speaker": "S1", "text": "beyond the chunk"}],
                        "outside chunk duration",
                    ),
                    "empty_segments": ("transcript", [], "no validated segments"),
                    "blank_raw_text": (
                        "   ",
                        [{"start_s": 0, "end_s": 4, "speaker": "S1", "text": "present"}],
                        "no raw transcript",
                    ),
                    "blank_segment_text": (
                        "transcript",
                        [{"start_s": 0, "end_s": 4, "speaker": "S1", "text": "  "}],
                        "empty text",
                    ),
                    "non_numeric_timestamp": (
                        "transcript",
                        [{"start_s": "0", "end_s": 4, "speaker": "S1", "text": "present"}],
                        "invalid timestamps",
                    ),
                }
                for name, (raw_text, segments, expected) in variants.items():
                    with self.subTest(variant=name):
                        # The harness reports a clean EOS; only the runner sees
                        # that the structure is incomplete.
                        payload = moss_payload(
                            status="complete",
                            stop_reason="endOfSequence",
                            raw_text=raw_text,
                            segments=segments,
                            instruction=instruction,
                        )
                        output.write_text(json.dumps(payload), encoding="utf-8")
                        found = runner.run_moss(spec=runner.MODELS["moss"], audio=cache / "audio.wav", duration=4.0, entries=["Maccheroni"], language="it", max_tokens=5120, cache_root=cache, work=work, timeout_seconds=1)
                        self.assertEqual(found["outcome"], "invalid_eos_output")
                        self.assertEqual(found["failure"]["code"], "invalid_eos_output")
                        self.assertIn(expected, found["failure"]["message"])
                        self.assertEqual(found["raw_text"], "")
                        self.assertEqual(found["segments"], [])
                        self.assertEqual(found["stop_reason"], "endOfSequence")
                        self.assertEqual(found["diagnostics"]["invalid_eos_source"], "runner")
                        output.unlink()

                payload = moss_payload(
                    status="complete",
                    stop_reason="endOfSequence",
                    raw_text="transcript",
                    segments=[{"start_s": 0, "end_s": 4, "speaker": "S1", "text": "present"}],
                    instruction=instruction,
                )
                output.write_text(json.dumps(payload), encoding="utf-8")
                complete = runner.run_moss(spec=runner.MODELS["moss"], audio=cache / "audio.wav", duration=4.0, entries=["Maccheroni"], language="it", max_tokens=5120, cache_root=cache, work=work, timeout_seconds=1)
                self.assertEqual(complete["outcome"], "complete")
                self.assertEqual(complete["segments"][0]["speaker"], "S1")
                self.assertNotIn("diagnostics", complete)
            finally:
                runner.verify_moss_harness_fingerprint, runner.run_process = original_fingerprint, original_process

    def test_runner_detected_invalid_eos_writes_the_protective_record(self) -> None:
        temporary, cache = self.make_cache()
        with temporary:
            work = self.prepare_moss_model(cache)
            helper_output = work / "moss.json"
            instruction = digest(b"instruction")
            audio = cache / "input.wav"
            with runner.wave.open(str(audio), "wb") as stream:
                stream.setnchannels(1)
                stream.setsampwidth(2)
                stream.setframerate(16_000)
                stream.writeframes(b"\x00\x00" * 64_000)
            glossary = cache / "glossary.txt"
            glossary.write_text("Maccheroni\n", encoding="utf-8")
            original_fingerprint, original_process, original_run_moss = (
                runner.verify_moss_harness_fingerprint,
                runner.run_process,
                runner.run_moss,
            )
            runner.verify_moss_harness_fingerprint = lambda _cache: {"path": str(cache / "helper.fingerprint.json"), "sha256": digest(b"sidecar")}
            runner.run_process = lambda *args, **kwargs: subprocess.CompletedProcess([], 0, "", "")
            try:
                payload = moss_payload(
                    status="complete",
                    stop_reason="endOfSequence",
                    raw_text="transcript",
                    segments=[{"start_s": 0, "end_s": 9.5, "speaker": "S1", "text": "beyond the chunk"}],
                    instruction=instruction,
                )
                helper_output.write_text(json.dumps(payload), encoding="utf-8")
                classified = runner.run_moss(spec=runner.MODELS["moss"], audio=audio, duration=4.0, entries=["Maccheroni"], language="it", max_tokens=5120, cache_root=cache, work=work, timeout_seconds=1)
                runner.run_moss = lambda **_kwargs: classified
                output = cache / "runner.json"
                args = runner.argparse.Namespace(
                    backend="moss",
                    audio=str(audio),
                    start_s=0.0,
                    end_s=4.0,
                    language="it",
                    glossary=str(glossary),
                    glossary_sha256=runner.sha256_file(glossary),
                    injection_mode="hotword_instruction",
                    cache_root=str(cache),
                    output=str(output),
                    timeout_seconds=1.0,
                    max_tokens=5_120,
                )
                document = runner.run(args)
                self.assertEqual(document["outcome"], "invalid_eos_output")
                self.assertEqual(document["failure"]["code"], "invalid_eos_output")
                self.assertEqual(document["raw_text"], "")
                self.assertEqual(document["segments"], [])
                self.assertEqual(document["coverage"]["processed_duration_s"], 0)
                self.assertTrue(document["coverage"]["truncated"])
                self.assertEqual(document["diagnostics"]["invalid_eos_source"], "runner")
                self.assertTrue(output.is_file())
                original_hash = runner.sha256_file(output)
                with self.assertRaisesRegex(runner.RunnerError, "refusing to overwrite"):
                    runner.run(args)
                self.assertEqual(runner.sha256_file(output), original_hash)
            finally:
                runner.verify_moss_harness_fingerprint, runner.run_process, runner.run_moss = (
                    original_fingerprint,
                    original_process,
                    original_run_moss,
                )

    def test_limit_outcome_preserves_a_contradictory_failure_block(self) -> None:
        temporary, cache = self.make_cache()
        with temporary:
            work = self.prepare_moss_model(cache)
            output = work / "moss.json"
            instruction = digest(b"instruction")
            original_fingerprint, original_process = runner.verify_moss_harness_fingerprint, runner.run_process
            runner.verify_moss_harness_fingerprint = lambda _cache: {"path": str(cache / "helper.fingerprint.json"), "sha256": digest(b"sidecar")}
            try:
                for stop, exit_code in (("maximumTokens", 75), ("contextLimit", 76)):
                    with self.subTest(stop_reason=stop):
                        payload = moss_payload(
                            status="incomplete",
                            stop_reason=stop,
                            raw_text="partial",
                            segments=[{"start_s": 0, "end_s": 4, "speaker": "S1", "text": "partial"}],
                            instruction=instruction,
                        )
                        payload["failure"] = {"code": "invalid_eos_output", "message": "contradictory helper failure"}
                        output.write_text(json.dumps(payload), encoding="utf-8")
                        runner.run_process = lambda *args, code=exit_code, **kwargs: subprocess.CompletedProcess([], code, "", "")
                        found = runner.run_moss(spec=runner.MODELS["moss"], audio=cache / "audio.wav", duration=4.0, entries=["Maccheroni"], language="it", max_tokens=5120, cache_root=cache, work=work, timeout_seconds=1)
                        self.assertEqual(found["outcome"], "limit")
                        self.assertEqual(found["raw_text"], "")
                        self.assertEqual(found["segments"], [])
                        self.assertNotIn("failure", found)
                        self.assertEqual(
                            found["diagnostics"]["helper_failure"],
                            {"code": "invalid_eos_output", "message": "contradictory helper failure"},
                        )
                        output.unlink()
            finally:
                runner.verify_moss_harness_fingerprint, runner.run_process = original_fingerprint, original_process

    def test_outer_limit_record_is_create_only_and_preserves_input_hash(self) -> None:
        with tempfile.TemporaryDirectory() as root_string:
            root = Path(root_string)
            audio = root / "input.wav"
            with runner.wave.open(str(audio), "wb") as stream:
                stream.setnchannels(1)
                stream.setsampwidth(2)
                stream.setframerate(16_000)
                stream.writeframes(b"\x00\x00" * 16_000)
            glossary = root / "glossary.txt"
            glossary.write_text("Maccheroni\n", encoding="utf-8")
            helper = root / "helper.json"
            helper.write_text('{"raw_text":"isolated partial"}\n', encoding="utf-8")
            sidecar = root / "helper.fingerprint.json"
            sidecar.write_text("{}\n", encoding="utf-8")
            instruction = digest(b"instruction")
            swift = "Swift synthetic"
            fingerprint = {
                "path": str(sidecar),
                "sha256": digest(sidecar.read_bytes()),
                "contract_version": "moss-harness-v2",
                "source_tree_sha256": digest(b"source"),
                "package_swift_sha256": digest(b"package"),
                "package_resolved_sha256": digest(b"resolved"),
                "swift_version": swift,
                "swift_version_sha256": digest(swift.encode()),
                "target_architecture": "arm64",
                "configuration": "release",
                "build_flags": runner.MOSS_HARNESS_FLAGS,
                "executable_sha256": digest(b"binary"),
                "metallib_sha256": digest(b"metallib"),
            }
            metrics = {
                "preprocessing_s": 0,
                "audio_encoder_s": 0,
                "decoder_prefill_s": 0,
                "token_decode_s": 0,
                "total_s": 0,
                "model_load_s": 0,
                "audio_duration_s": 1.0,
                "prompt_tokens": 10,
                "generated_tokens": 5_120,
                "max_tokens": 5_120,
                "context_hard_cap_tokens": 131_072,
                "peak_rss_bytes": 0,
            }
            original_run_moss = runner.run_moss
            runner.run_moss = lambda **_kwargs: {
                "outcome": "limit",
                "stop_reason": "maximumTokens",
                "raw_text": "",
                "segments": [],
                "command": ["synthetic-helper", "--max-tokens", "5120"],
                "artifact": helper,
                "fingerprint": fingerprint,
                "instruction_hash": instruction,
                "metrics": metrics,
            }
            output = root / "runner.json"
            args = runner.argparse.Namespace(
                backend="moss",
                audio=str(audio),
                start_s=0.0,
                end_s=1.0,
                language="it",
                glossary=str(glossary),
                glossary_sha256=runner.sha256_file(glossary),
                injection_mode="hotword_instruction",
                cache_root=str(root / "cache"),
                output=str(output),
                timeout_seconds=1.0,
                max_tokens=5_120,
            )
            try:
                document = runner.run(args)
                original_output_hash = runner.sha256_file(output)
                self.assertEqual(document["outcome"], "limit")
                self.assertEqual(document["raw_text"], "")
                self.assertEqual(document["segments"], [])
                self.assertEqual(document["coverage"]["processed_duration_s"], 0)
                self.assertTrue(document["coverage"]["truncated"])
                self.assertEqual(document["input"]["sha256_before"], runner.sha256_file(audio))
                self.assertEqual(document["input"]["sha256_after"], runner.sha256_file(audio))
                self.assertEqual(document["backend_raw_artifact"]["sha256"], runner.sha256_file(helper))
                with self.assertRaisesRegex(runner.RunnerError, "refusing to overwrite"):
                    runner.run(args)
                self.assertEqual(runner.sha256_file(output), original_output_hash)

                output_without_glossary = root / "runner-without-glossary.json"
                args_without_glossary = runner.argparse.Namespace(
                    backend="moss",
                    audio=str(audio),
                    start_s=0.0,
                    end_s=1.0,
                    language="it",
                    glossary=None,
                    glossary_sha256=None,
                    injection_mode="none",
                    cache_root=str(root / "cache"),
                    output=str(output_without_glossary),
                    timeout_seconds=1.0,
                    max_tokens=5_120,
                )
                without_glossary = runner.run(args_without_glossary)
                self.assertFalse(without_glossary["glossary"]["provided"])
                self.assertFalse(without_glossary["glossary"]["applied"])
                self.assertEqual(
                    without_glossary["glossary"]["payload_entry_count"],
                    0,
                )
                self.assertIsNone(
                    without_glossary["glossary"]["payload_sha256"]
                )

                runner.run_moss = lambda **_kwargs: {
                    "outcome": "invalid_eos_output",
                    "stop_reason": "endOfSequence",
                    "raw_text": "",
                    "segments": [],
                    "failure": {
                        "code": "invalid_eos_output",
                        "message": "MOSS EOS output has no validated segments",
                    },
                    "command": ["synthetic-helper", "--max-tokens", "5120"],
                    "artifact": helper,
                    "fingerprint": fingerprint,
                    "instruction_hash": instruction,
                    "metrics": metrics,
                }
                invalid_output = root / "invalid-eos.json"
                invalid_args = runner.argparse.Namespace(
                    **{**vars(args), "output": str(invalid_output)}
                )
                invalid = runner.run(invalid_args)
                self.assertEqual(invalid["outcome"], "invalid_eos_output")
                self.assertEqual(invalid["failure"]["code"], "invalid_eos_output")
                self.assertEqual(invalid["raw_text"], "")
                self.assertEqual(invalid["segments"], [])
                self.assertEqual(invalid["coverage"]["processed_duration_s"], 0)
                self.assertTrue(invalid["coverage"]["truncated"])
                self.assertTrue(invalid_output.is_file())
            finally:
                runner.run_moss = original_run_moss


if __name__ == "__main__":
    unittest.main()
