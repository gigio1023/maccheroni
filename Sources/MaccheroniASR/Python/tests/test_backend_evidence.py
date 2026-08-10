import importlib.util
import io
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

    def run_vibevoice_stub(self, generated_tokens: int, max_tokens: int):
        with tempfile.TemporaryDirectory() as root_string:
            root = Path(root_string)
            captured = {}

            def generate_transcription(**kwargs):
                captured.update(kwargs)
                Path(kwargs["output_path"] + ".json").write_text(
                    '{"text":"hello","segments":[{"start":0,"end":1,"text":"hello"}]}',
                    encoding="utf-8",
                )
                return StubSTTOutput(generated_tokens=generated_tokens)

            with (
                mock.patch.object(runner, "version", return_value=runner.EXPECTED_MLX_AUDIO),
                mock.patch.object(runner, "assert_hf_snapshot"),
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
            return result, captured

    def test_vibevoice_below_cap_is_observed_end_of_sequence(self) -> None:
        result, captured = self.run_vibevoice_stub(generated_tokens=4, max_tokens=5)

        self.assertEqual(captured["max_tokens"], 5)
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

    def test_vibevoice_at_cap_is_typed_limit_without_promotable_text(self) -> None:
        result, _ = self.run_vibevoice_stub(generated_tokens=5, max_tokens=5)

        self.assertEqual(result["outcome"], "limit")
        self.assertEqual(result["stop_reason"], "maximumTokens")
        self.assertEqual(result["raw_text"], "")
        self.assertEqual(result["segments"], [])
        self.assertEqual(result["metrics"]["generated_tokens"], 5)

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
