import datetime
import json
import hashlib
import os
import shlex
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/setup-transcription-runtime.zsh"
MODEL_VERIFIER = ROOT / "scripts/verify-speech-model-closure.py"

RUNTIME_PACKAGE_SHA256 = "5059f0c80bcec9cfc88bc56db8bc48504860ed556930f0225c817feb6607e5fd"
RUNTIME_RESOLVED_SHA256 = "e81c1d4f14185323abc782967b18a2342e36358b696b57be25a702718ab2330c"
RUNTIME_SOURCE_SHA256 = "ba28b93e69c3b0ee6da9b19b328642a797355220f60a82eb87115496b6b8ff79"
SPEECH_REVISION = "c1aa219bc2284239ff6917d675a3e1978c840260"
TOKENIZER_REVISION = "d149729398750b98c0af14eb82c78cfe92750796"
COMMUNITY_REVISION = "a14e6c420d56e8472850649b016a486fd0acbe81"
VAD_REVISION = "523876545a57961474fee9df913e833e130560b8"
COMMUNITY_TREE_SHA256 = "74247105450a08414a71ef5d512a52b706a7c23ac61efdcef051f4e44fae237a"
VAD_TREE_SHA256 = "edd772745342372800516b0da27556cf4aae1db386784620b2590183d94da346"
TOKENIZER_FILES = [
    "config.json",
    "tokenizer.json",
    "tokenizer_config.json",
    "merges.txt",
    "vocab.json",
]


def _write_executable(path: Path, source: str) -> None:
    path.write_text(textwrap.dedent(source).lstrip(), encoding="utf-8")
    path.chmod(0o755)


class FakeRuntime:
    """Isolated fake Hub, harness build, and product-doctor boundary."""

    def __init__(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        temporary_root = Path(self.temporary.name).resolve()
        self.root = temporary_root / "repository"
        self.script = self.root / "scripts/setup-transcription-runtime.zsh"
        self.fake_bin = temporary_root / "fake-bin"
        self.tool_source = temporary_root / "tool-source"
        self.cache = temporary_root / "cache"
        self.uv_log = temporary_root / "uv.jsonl"
        self.hf_log = temporary_root / "hf.jsonl"
        self.swift_log = temporary_root / "swift.jsonl"

        self.script.parent.mkdir(parents=True)
        (self.root / "Sources/MaccheroniASR/Python").mkdir(parents=True)
        runtime_source = ROOT / "scripts/runners/offline-speech-runtime"
        for relative in (
            "Package.swift",
            "Package.resolved",
            "Sources/MaccheroniOfflineSpeechRuntime/main.swift",
        ):
            destination = self.root / "scripts/runners/offline-speech-runtime" / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(runtime_source / relative, destination)
        shutil.copy2(SCRIPT, self.script)
        shutil.copy2(
            MODEL_VERIFIER,
            self.root / "scripts/verify-speech-model-closure.py",
        )
        self.script.chmod(0o755)
        self.fake_bin.mkdir()
        self.tool_source.mkdir()
        self._install_tools()

        self.environment = dict(os.environ)
        self.environment.update(
            {
                "PATH": f"{self.fake_bin}:{self.environment['PATH']}",
                "MACCHERONI_BENCHMARK_CACHE": str(self.cache),
                "FAKE_TOOL_SOURCE": str(self.tool_source),
                "FAKE_UV_LOG": str(self.uv_log),
                "FAKE_HF_LOG": str(self.hf_log),
                "FAKE_SWIFT_LOG": str(self.swift_log),
            }
        )

    def close(self) -> None:
        self.temporary.cleanup()

    def run(self, *arguments: str, **environment: str) -> subprocess.CompletedProcess[str]:
        merged = dict(self.environment)
        merged.update(environment)
        return subprocess.run(
            ["zsh", str(self.script), *arguments],
            cwd=self.root,
            env=merged,
            text=True,
            capture_output=True,
            check=False,
        )

    def hf_calls(self) -> list[list[str]]:
        if not self.hf_log.exists():
            return []
        return [json.loads(line) for line in self.hf_log.read_text().splitlines()]

    def uv_calls(self) -> list[list[str]]:
        if not self.uv_log.exists():
            return []
        return [json.loads(line) for line in self.uv_log.read_text().splitlines()]

    def swift_calls(self) -> list[list[str]]:
        if not self.swift_log.exists():
            return []
        return [json.loads(line) for line in self.swift_log.read_text().splitlines()]

    def _install_tools(self) -> None:
        _write_executable(
            self.fake_bin / "uv",
            """
            #!/usr/bin/python3
            import json
            import os
            import pathlib
            import shutil
            import sys

            with open(os.environ["FAKE_UV_LOG"], "a", encoding="utf-8") as log:
                log.write(json.dumps(sys.argv[1:]) + "\\n")
            cache = pathlib.Path(os.environ["UV_CACHE_DIR"]).resolve()
            benchmark_cache = pathlib.Path(
                os.environ["MACCHERONI_BENCHMARK_CACHE"]
            ).resolve()
            try:
                cache.relative_to(benchmark_cache)
            except ValueError:
                raise SystemExit("uv cache escaped the benchmark cache")
            install_root = pathlib.Path(
                os.environ["UV_PYTHON_INSTALL_DIR"]
            ).resolve()
            if install_root != benchmark_cache / "build/uv-python":
                raise SystemExit("uv Python install escaped the benchmark cache")
            trusted = (
                install_root
                / "cpython-3.12.13-macos-aarch64-none/bin/python3.12"
            )
            if sys.argv[1:] == [
                "python", "install", "--no-config", "--no-bin", "--no-registry",
                "--install-dir", str(install_root), "--cache-dir", str(cache), "3.12.13",
            ]:
                trusted.parent.mkdir(parents=True, exist_ok=True)
                if not trusted.exists():
                    shutil.copy2(
                        pathlib.Path(os.environ["FAKE_TOOL_SOURCE"]) / "python",
                        trusted,
                    )
                    trusted.chmod(0o755)
                raise SystemExit(0)
            if sys.argv[1:] == [
                "python", "find", "--no-config", "--managed-python",
                "--no-python-downloads", "3.12.13",
            ]:
                print(trusted)
                raise SystemExit(0)

            if not sys.argv[1:] or sys.argv[1] != "sync":
                raise SystemExit("unexpected uv invocation")
            if "--no-python-downloads" not in sys.argv[1:]:
                raise SystemExit("uv sync may download Python")
            selected = pathlib.Path(
                sys.argv[sys.argv.index("--python") + 1]
            ).resolve()
            expected = trusted.resolve()
            if selected != expected:
                raise SystemExit("uv sync did not use the exact trusted interpreter")
            if os.environ.get("UV_LINK_MODE") != "copy":
                raise SystemExit("uv sync did not force copy link mode")

            environment = pathlib.Path(os.environ["UV_PROJECT_ENVIRONMENT"])
            binary = environment / "bin"
            binary.mkdir(parents=True, exist_ok=True)
            source = pathlib.Path(os.environ["FAKE_TOOL_SOURCE"])
            for name in ("hf",):
                destination = binary / name
                shutil.copy2(source / name, destination)
                destination.chmod(0o755)
            python = binary / "python"
            if not python.exists() and not python.is_symlink():
                shutil.copy2(source / "python", python)
                python.chmod(0o755)
            """,
        )
        _write_executable(
            self.tool_source / "hf",
            """
            #!/usr/bin/python3
            import json
            import os
            import pathlib
            import sys

            arguments = sys.argv[1:]
            with open(os.environ["FAKE_HF_LOG"], "a", encoding="utf-8") as log:
                log.write(json.dumps(arguments) + "\\n")
            if arguments[:2] == ["cache", "verify"]:
                raise SystemExit(0)
            if len(arguments) < 2 or arguments[0] != "download":
                raise SystemExit(2)

            model = arguments[1]
            revision = arguments[arguments.index("--revision") + 1]
            if revision == "main":
                raise SystemExit("moving main acquisition is forbidden")
            if "--cache-dir" in arguments:
                cache = pathlib.Path(arguments[arguments.index("--cache-dir") + 1])
                repository = cache / ("models--" + model.replace("/", "--"))
                repository.mkdir(parents=True, exist_ok=True)
                if model == "mlx-community/VibeVoice-ASR-8bit":
                    snapshot = repository / "snapshots" / revision
                    snapshot.mkdir(parents=True, exist_ok=True)
                    for name in (
                        "config.json",
                        "model.safetensors.index.json",
                        "model-00001-of-00002.safetensors",
                        "model-00002-of-00002.safetensors",
                    ):
                        (snapshot / name).write_text("fake", encoding="utf-8")
                    tree = repository / "trees" / (revision + ".json")
                    tree.parent.mkdir(parents=True, exist_ok=True)
                    tree.write_text("{}", encoding="utf-8")
                elif model == "Qwen/Qwen2.5-7B":
                    snapshot = repository / "snapshots" / revision
                    blobs = repository / "blobs"
                    snapshot.mkdir(parents=True, exist_ok=True)
                    blobs.mkdir(parents=True, exist_ok=True)
                    for name in arguments[2:arguments.index("--revision")]:
                        blob = blobs / ("blob-" + name.replace(".", "-"))
                        blob.write_text("fake " + name, encoding="utf-8")
                        link = snapshot / name
                        if not link.exists():
                            link.symlink_to(pathlib.Path("../../blobs") / blob.name)
                else:
                    expected = {
                        "aufklarer/Pyannote-Community-1-CoreML": "a14e6c420d56e8472850649b016a486fd0acbe81",
                        "aufklarer/Silero-VAD-v6.2.1-CoreML": "523876545a57961474fee9df913e833e130560b8",
                    }[model]
                    if revision != expected:
                        raise SystemExit("model acquisition does not use the immutable pin")
                    snapshot = repository / "snapshots" / revision
                    snapshot.mkdir(parents=True, exist_ok=True)
                    (snapshot / "config.json").write_text("fake", encoding="utf-8")
                    tree = repository / "trees" / (revision + ".json")
                    tree.parent.mkdir(parents=True, exist_ok=True)
                    tree.write_text("{}", encoding="utf-8")
            elif "--local-dir" in arguments:
                destination = pathlib.Path(arguments[arguments.index("--local-dir") + 1])
                if model == "aufklarer/Pyannote-Community-1-CoreML":
                    names = (
                        "config.json",
                        "embedding.mlmodelc/analytics/coremldata.bin",
                        "embedding.mlmodelc/coremldata.bin",
                        "embedding.mlmodelc/model.mil",
                        "embedding.mlmodelc/weights/weight.bin",
                        "plda.safetensors",
                        "segmentation.mlmodelc/analytics/coremldata.bin",
                        "segmentation.mlmodelc/coremldata.bin",
                        "segmentation.mlmodelc/model.mil",
                        "segmentation.mlmodelc/weights/weight.bin",
                    )
                elif model == "aufklarer/Silero-VAD-v6.2.1-CoreML":
                    names = (
                        "config.json",
                        "silero_vad.mlmodelc/analytics/coremldata.bin",
                        "silero_vad.mlmodelc/coremldata.bin",
                        "silero_vad.mlmodelc/metadata.json",
                        "silero_vad.mlmodelc/model.mil",
                        "silero_vad.mlmodelc/weights/weight.bin",
                    )
                else:
                    raise SystemExit(2)
                for name in names:
                    path = destination / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text("fake " + name, encoding="utf-8")
            else:
                raise SystemExit(2)
            print("fake-download")
            """,
        )
        _write_executable(
            self.tool_source / "python",
            """
            #!/usr/bin/python3
            import hashlib
            import importlib.util
            import os
            import pathlib
            import subprocess
            import sys

            arguments = sys.argv[1:]
            if arguments and arguments[0].endswith("verify-speech-model-closure.py"):
                verifier_path = pathlib.Path(arguments[0])
                specification = importlib.util.spec_from_file_location(
                    "maccheroni_speech_model_verifier", verifier_path
                )
                verifier = importlib.util.module_from_spec(specification)
                specification.loader.exec_module(verifier)
                models_root = pathlib.Path(arguments[1])
                contracts = {}
                for model_name, production_contract in verifier.MODEL_CONTRACTS.items():
                    files = {}
                    tree = hashlib.sha256()
                    for relative in sorted(production_contract["files"]):
                        payload = (models_root / model_name / relative).read_bytes()
                        files[relative] = hashlib.sha256(payload).hexdigest()
                        name = relative.encode("utf-8")
                        tree.update(len(name).to_bytes(4, "big"))
                        tree.update(name)
                        tree.update(payload)
                    contracts[model_name] = {
                        "files": files,
                        "tree": tree.hexdigest(),
                    }
                if os.environ.get("FAKE_CORRUPT_LOCAL_MODEL") == "1":
                    target = models_root / "Pyannote-Community-1-CoreML/config.json"
                    payload = bytearray(target.read_bytes())
                    payload[0] ^= 1
                    target.write_bytes(payload)
                verifier.validate_model_closures(models_root, contracts)
                raise SystemExit(0)
            if arguments and arguments[0] == "-":
                program = sys.stdin.read()
                if "descriptor, temporary = tempfile.mkstemp" in program:
                    _, model, expected, reference_string = arguments
                    reference = pathlib.Path(reference_string)
                    if reference.exists():
                        if reference.read_bytes() != expected.encode("ascii"):
                            raise SystemExit(f"refusing to rewrite mismatched ref: {reference}")
                    else:
                        reference.parent.mkdir(parents=True, exist_ok=True)
                        reference.write_bytes(expected.encode("ascii"))
                    raise SystemExit(0)
                completed = subprocess.run(
                    ["/usr/bin/python3", *arguments], input=program, text=True
                )
                raise SystemExit(completed.returncode)
            os.execv("/usr/bin/python3", ["/usr/bin/python3", *arguments])
            """,
        )
        _write_executable(
            self.fake_bin / "swift",
            """
            #!/usr/bin/python3
            import json
            import os
            import pathlib
            import sys

            arguments = sys.argv[1:]
            with open(os.environ["FAKE_SWIFT_LOG"], "a", encoding="utf-8") as log:
                log.write(json.dumps(arguments) + "\\n")
            if arguments == ["--version"]:
                print("Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)")
                print("Target: arm64-apple-macosx26.0")
                raise SystemExit(0)

            root = pathlib.Path(arguments[arguments.index("--package-path") + 1])
            if root.name == "offline-speech-runtime":
                scratch = pathlib.Path(arguments[arguments.index("--scratch-path") + 1])
                binary = scratch / "arm64-apple-macosx/release"
                if "--show-bin-path" in arguments:
                    print(binary)
                    raise SystemExit(0)
                if os.environ.get("FAKE_RUNTIME_BUILD_FAIL") == "1":
                    raise SystemExit(70)
                product = binary / "maccheroni-offline-speech-runtime"
                product.parent.mkdir(parents=True, exist_ok=True)
                product.write_text("#!/bin/zsh\\nexit 0\\n", encoding="utf-8")
                product.chmod(0o755)
                raise SystemExit(0)

            product = root / ".build/debug/maccheroni"
            product.parent.mkdir(parents=True, exist_ok=True)
            product.write_text(
                '''#!/bin/zsh
                if [[ ${FAKE_DOCTOR_FAIL:-0} == 1 ]]; then
                    print -u2 -- "doctor failed"
                    exit 73
                fi
                if [[ " $* " == *" --json "* ]]; then
                    print -- '{"profile":"ko-meeting","ready":true,"qwen":{"scope":"tokenizer-only"}}'
                else
                    print -- "ko-meeting ready"
                fi
                ''',
                encoding="utf-8",
            )
            product.chmod(0o755)
            """,
        )


class SetupTranscriptionRuntimeTests(unittest.TestCase):
    def test_python_install_root_symlink_fails_before_external_writers(self) -> None:
        fake = FakeRuntime()
        try:
            outside = fake.cache.parent / "outside-python-install"
            outside.mkdir()
            sentinel = outside / "sentinel"
            sentinel.write_text("unchanged", encoding="utf-8")
            build = fake.cache / "build"
            build.mkdir(parents=True)
            (build / "uv-python").symlink_to(outside, target_is_directory=True)

            result = fake.run("--profile", "ko-meeting")

            self.assertEqual(result.returncode, 65, result.stderr)
            self.assertIn("refusing symlinked or special cache path", result.stderr)
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "unchanged")
            self.assertEqual(list(outside.iterdir()), [sentinel])
            self.assertEqual(fake.uv_calls(), [])
            self.assertEqual(fake.hf_calls(), [])
            self.assertEqual(fake.swift_calls(), [])
        finally:
            fake.close()

    def test_python_install_hardlink_fails_before_external_writers(self) -> None:
        fake = FakeRuntime()
        try:
            outside = fake.cache.parent / "outside-python-hardlink"
            outside.write_text("unchanged", encoding="utf-8")
            install_root = fake.cache / "build/uv-python"
            install_root.mkdir(parents=True)
            os.link(outside, install_root / "payload")

            result = fake.run("--profile", "ko-meeting")

            self.assertEqual(result.returncode, 65, result.stderr)
            self.assertIn("multiply-linked external writer file", result.stderr)
            self.assertEqual(outside.read_text(encoding="utf-8"), "unchanged")
            self.assertEqual(
                (install_root / "payload").read_text(encoding="utf-8"),
                "unchanged",
            )
            self.assertEqual(fake.uv_calls(), [])
            self.assertEqual(fake.hf_calls(), [])
            self.assertEqual(fake.swift_calls(), [])
        finally:
            fake.close()

    def test_runtime_build_product_symlink_fails_before_external_writers(self) -> None:
        fake = FakeRuntime()
        try:
            outside = fake.cache.parent / "outside-runtime-product"
            outside.write_text("sentinel", encoding="utf-8")
            product = (
                fake.cache
                / "build/offline-speech-runtime/arm64-apple-macosx/release"
                / "maccheroni-offline-speech-runtime"
            )
            product.parent.mkdir(parents=True)
            product.symlink_to(outside)

            result = fake.run("--profile", "ko-meeting")

            self.assertEqual(result.returncode, 65, result.stderr)
            self.assertIn("external writer symlink outside cache tree", result.stderr)
            self.assertEqual(outside.read_text(encoding="utf-8"), "sentinel")
            self.assertTrue(product.is_symlink())
            self.assertEqual(fake.uv_calls(), [])
            self.assertEqual(fake.hf_calls(), [])
            self.assertEqual(fake.swift_calls(), [])
        finally:
            fake.close()

    def test_runtime_build_product_hardlink_fails_before_external_writers(self) -> None:
        fake = FakeRuntime()
        try:
            outside = fake.cache.parent / "outside-runtime-hardlink"
            outside.write_text("sentinel", encoding="utf-8")
            product = (
                fake.cache
                / "build/offline-speech-runtime/arm64-apple-macosx/release"
                / "maccheroni-offline-speech-runtime"
            )
            product.parent.mkdir(parents=True)
            os.link(outside, product)

            result = fake.run("--profile", "ko-meeting")

            self.assertEqual(result.returncode, 65, result.stderr)
            self.assertIn("multiply-linked external writer file", result.stderr)
            self.assertEqual(outside.read_text(encoding="utf-8"), "sentinel")
            self.assertEqual(product.read_text(encoding="utf-8"), "sentinel")
            self.assertEqual(fake.uv_calls(), [])
            self.assertEqual(fake.hf_calls(), [])
            self.assertEqual(fake.swift_calls(), [])
        finally:
            fake.close()

    def test_venv_hf_symlink_fails_before_external_writers(self) -> None:
        fake = FakeRuntime()
        try:
            outside = fake.cache.parent / "outside-hf-entry"
            outside.write_text("sentinel", encoding="utf-8")
            binary = fake.cache / "venvs/mlx-audio/bin"
            binary.mkdir(parents=True)
            (binary / "hf").symlink_to(outside)

            result = fake.run("--profile", "ko-meeting")

            self.assertEqual(result.returncode, 65, result.stderr)
            self.assertIn("external writer symlink outside cache tree", result.stderr)
            self.assertEqual(outside.read_text(encoding="utf-8"), "sentinel")
            self.assertTrue((binary / "hf").is_symlink())
            self.assertEqual(
                fake.uv_calls(),
                [
                    [
                        "python", "install", "--no-config", "--no-bin",
                        "--no-registry", "--install-dir",
                        str(fake.cache / "build/uv-python"), "--cache-dir",
                        str(fake.cache / "build/uv-cache"), "3.12.13",
                    ],
                    [
                        "python", "find", "--no-config", "--managed-python",
                        "--no-python-downloads", "3.12.13",
                    ],
                ],
            )
            self.assertEqual(fake.hf_calls(), [])
            self.assertEqual(fake.swift_calls(), [])
        finally:
            fake.close()

    def test_venv_hf_hardlink_fails_before_external_writers(self) -> None:
        fake = FakeRuntime()
        try:
            outside = fake.cache.parent / "outside-hf-hardlink"
            outside.write_text("sentinel", encoding="utf-8")
            binary = fake.cache / "venvs/mlx-audio/bin"
            binary.mkdir(parents=True)
            os.link(outside, binary / "hf")

            result = fake.run("--profile", "ko-meeting")

            self.assertEqual(result.returncode, 65, result.stderr)
            self.assertIn("multiply-linked external writer file", result.stderr)
            self.assertEqual(outside.read_text(encoding="utf-8"), "sentinel")
            self.assertEqual(
                (binary / "hf").read_text(encoding="utf-8"),
                "sentinel",
            )
            self.assertEqual(
                fake.uv_calls(),
                [
                    [
                        "python", "install", "--no-config", "--no-bin",
                        "--no-registry", "--install-dir",
                        str(fake.cache / "build/uv-python"), "--cache-dir",
                        str(fake.cache / "build/uv-cache"), "3.12.13",
                    ],
                    [
                        "python", "find", "--no-config", "--managed-python",
                        "--no-python-downloads", "3.12.13",
                    ],
                ],
            )
            self.assertEqual(fake.hf_calls(), [])
            self.assertEqual(fake.swift_calls(), [])
        finally:
            fake.close()

    def test_stale_venv_interpreter_symlink_names_its_cause_and_remedy(self) -> None:
        """The condition a 2026-08-03 provisioning run left in the real cache."""
        fake = FakeRuntime()
        try:
            outside = fake.cache.parent / "untrusted-interpreter"
            outside.mkdir()
            target = outside / "python3"
            target.write_text("#!/bin/zsh\nprint sentinel\n", encoding="utf-8")
            target.chmod(0o755)
            venv = fake.cache / "venvs/mlx-audio"
            binary = venv / "bin"
            binary.mkdir(parents=True)
            (binary / "python").symlink_to(target)

            result = fake.run("--profile", "ko-meeting")
            today = datetime.date.today().strftime("%Y%m%d")

            self.assertEqual(result.returncode, 65, result.stderr)
            self.assertIn("stale provisioning environment", result.stderr)
            self.assertNotIn(
                "external writer symlink outside cache tree", result.stderr
            )
            self.assertIn(str(venv), result.stderr)
            self.assertIn("its interpreter link bin/python", result.stderr)
            self.assertIn(str(target), result.stderr)
            self.assertIn(
                f'mv "{venv}" "{venv}.stale-{today}"',
                result.stderr,
            )
            self.assertIn(
                f'MACCHERONI_BENCHMARK_CACHE="{fake.cache}"',
                result.stderr,
            )
            self.assertIn("--profile ko-meeting", result.stderr)

            self.assertNotIn("rm ", result.stderr)
            self.assertTrue((binary / "python").is_symlink())
            self.assertEqual(
                target.read_text(encoding="utf-8"),
                "#!/bin/zsh\nprint sentinel\n",
            )
            self.assertEqual(
                fake.uv_calls(),
                [
                    [
                        "python", "install", "--no-config", "--no-bin",
                        "--no-registry", "--install-dir",
                        str(fake.cache / "build/uv-python"), "--cache-dir",
                        str(fake.cache / "build/uv-cache"), "3.12.13",
                    ],
                    [
                        "python", "find", "--no-config", "--managed-python",
                        "--no-python-downloads", "3.12.13",
                    ],
                ],
            )
            self.assertEqual(fake.hf_calls(), [])
            self.assertEqual(fake.swift_calls(), [])
        finally:
            fake.close()

    def test_broken_stale_venv_interpreter_symlink_reads_as_stale(self) -> None:
        fake = FakeRuntime()
        try:
            missing = fake.cache.parent / "removed-uv-python/bin/python3"
            binary = fake.cache / "venvs/mlx-audio/bin"
            binary.mkdir(parents=True)
            (binary / "python3.12").symlink_to(missing)

            result = fake.run("--profile", "ko-meeting")

            self.assertEqual(result.returncode, 65, result.stderr)
            self.assertIn("stale provisioning environment", result.stderr)
            self.assertIn("its interpreter link bin/python3.12", result.stderr)
            self.assertIn(f"{missing} (no longer present)", result.stderr)
            self.assertNotIn("rm ", result.stderr)
            self.assertEqual(fake.hf_calls(), [])
            self.assertEqual(fake.swift_calls(), [])
        finally:
            fake.close()

    def test_printed_stale_remedy_moves_aside_and_restores_provisioning(self) -> None:
        fake = FakeRuntime()
        try:
            outside = fake.cache.parent / "earlier-run-interpreter"
            outside.mkdir()
            target = outside / "python3"
            shutil.copy2(fake.tool_source / "python", target)
            target.chmod(0o755)
            venv = fake.cache / "venvs/mlx-audio"
            (venv / "bin").mkdir(parents=True)
            (venv / "bin/python").symlink_to(target)
            (venv / "pyvenv.cfg").write_text("home = elsewhere\n", encoding="utf-8")

            refused = fake.run("--profile", "ko-meeting")
            self.assertEqual(refused.returncode, 65, refused.stderr)

            remedy = [
                line.strip()
                for line in refused.stderr.splitlines()
                if line.strip().startswith("mv ")
            ]
            self.assertEqual(len(remedy), 1, refused.stderr)
            moved = subprocess.run(
                shlex.split(remedy[0]), text=True, capture_output=True, check=False
            )
            self.assertEqual(moved.returncode, 0, moved.stderr)

            aside = Path(shlex.split(remedy[0])[2])
            self.assertEqual(
                (aside / "pyvenv.cfg").read_text(encoding="utf-8"),
                "home = elsewhere\n",
            )

            repaired = fake.run("--profile", "ko-meeting")
            self.assertEqual(repaired.returncode, 0, repaired.stderr)
            self.assertEqual(repaired.stdout.strip(), "ko-meeting ready")
        finally:
            fake.close()

    def test_stale_remedy_never_targets_an_occupied_move_aside_path(self) -> None:
        fake = FakeRuntime()
        try:
            outside = fake.cache.parent / "another-interpreter"
            outside.mkdir()
            target = outside / "python3"
            target.write_text("#!/bin/zsh\nexit 0\n", encoding="utf-8")
            target.chmod(0o755)
            venv = fake.cache / "venvs/mlx-audio"
            (venv / "bin").mkdir(parents=True)
            (venv / "bin/python3").symlink_to(target)
            today = datetime.date.today().strftime("%Y%m%d")
            occupied = venv.with_name(f"mlx-audio.stale-{today}")
            occupied.mkdir()
            (occupied / "keep").write_text("earlier move aside", encoding="utf-8")

            result = fake.run("--profile", "ko-meeting")

            self.assertEqual(result.returncode, 65, result.stderr)
            self.assertIn(
                f'mv "{venv}" "{venv}.stale-{today}-2"',
                result.stderr,
            )
            self.assertEqual(
                (occupied / "keep").read_text(encoding="utf-8"),
                "earlier move aside",
            )
        finally:
            fake.close()

    def test_non_interpreter_venv_escape_keeps_the_unsafe_tree_message(self) -> None:
        """Only bin/python* is residue. Everything else stays a tampering report."""
        for relative in ("lib/python", "bin/activate", "bin/python-wrapper"):
            with self.subTest(relative=relative):
                fake = FakeRuntime()
                try:
                    outside = fake.cache.parent / "outside-payload"
                    outside.write_text("sentinel", encoding="utf-8")
                    entry = fake.cache / "venvs/mlx-audio" / relative
                    entry.parent.mkdir(parents=True)
                    entry.symlink_to(outside)

                    result = fake.run("--profile", "ko-meeting")

                    self.assertEqual(result.returncode, 65, result.stderr)
                    self.assertIn(
                        "refusing external writer symlink outside cache tree",
                        result.stderr,
                    )
                    self.assertNotIn("stale provisioning environment", result.stderr)
                    self.assertEqual(outside.read_text(encoding="utf-8"), "sentinel")
                    self.assertEqual(fake.hf_calls(), [])
                    self.assertEqual(fake.swift_calls(), [])
                finally:
                    fake.close()

    def test_source_build_is_announced_with_its_stages_before_it_runs(self) -> None:
        fake = FakeRuntime()
        try:
            first = fake.run("--profile", "ko-meeting")
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(first.stdout.strip(), "ko-meeting ready")

            announced = [
                line for line in first.stderr.splitlines() if line.startswith("setup: ")
            ]
            joined = "\n".join(announced)
            self.assertIn("compiled from source", joined)
            self.assertIn("tens of minutes", joined)
            self.assertIn("that is progress, not a hang", joined)
            stages = [
                index
                for index, line in enumerate(announced)
                if line.startswith("setup: build stage ")
            ]
            self.assertEqual(len(stages), 4)
            self.assertEqual(stages, sorted(stages))
            self.assertLess(
                announced.index(
                    next(line for line in announced if "tens of minutes" in line)
                ),
                stages[0],
            )

            second = fake.run("--profile", "ko-meeting")
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertIn("already installed in this cache", second.stderr)
            self.assertNotIn("tens of minutes", second.stderr)
            self.assertNotIn("setup: build stage ", second.stderr)
            builds = [
                call for call in fake.swift_calls()
                if "--product" in call
                and call[call.index("--product") + 1]
                    == "maccheroni-offline-speech-runtime"
            ]
            self.assertEqual(len(builds), 1)
        finally:
            fake.close()

    def test_external_venv_python_interpreter_symlink_remains_supported(self) -> None:
        fake = FakeRuntime()
        try:
            binary = fake.cache / "venvs/mlx-audio/bin"
            binary.mkdir(parents=True)
            interpreter = binary / "python"
            trusted = (
                fake.cache
                / "build/uv-python"
                / "cpython-3.12.13-macos-aarch64-none/bin/python3.12"
            )
            trusted.parent.mkdir(parents=True)
            shutil.copy2(fake.tool_source / "python", trusted)
            trusted.chmod(0o755)
            interpreter.symlink_to(trusted)
            inherited_install = fake.cache.parent / "inherited-python-install"
            inherited_install.mkdir()
            sentinel = inherited_install / "sentinel"
            sentinel.write_text("unchanged", encoding="utf-8")

            result = fake.run(
                "--profile",
                "ko-meeting",
                UV_PYTHON_INSTALL_DIR=str(inherited_install),
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(interpreter.is_symlink())
            self.assertEqual(interpreter.resolve(), trusted)
            self.assertEqual(
                fake.uv_calls()[0],
                [
                    "python", "install", "--no-config", "--no-bin",
                    "--no-registry", "--install-dir",
                    str(fake.cache / "build/uv-python"), "--cache-dir",
                    str(fake.cache / "build/uv-cache"), "3.12.13",
                ],
            )
            self.assertEqual(
                fake.uv_calls()[1],
                [
                    "python", "find", "--no-config", "--managed-python",
                    "--no-python-downloads", "3.12.13",
                ],
            )
            sync = fake.uv_calls()[2]
            self.assertEqual(sync[0], "sync")
            self.assertIn("--no-python-downloads", sync)
            self.assertEqual(
                Path(sync[sync.index("--python") + 1]).resolve(),
                trusted.resolve(),
            )
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "unchanged")
            self.assertEqual(list(inherited_install.iterdir()), [sentinel])
        finally:
            fake.close()

    def test_symlinked_venv_target_fails_before_external_writers_run(self) -> None:
        fake = FakeRuntime()
        try:
            outside = fake.cache.parent / "outside-venv"
            outside.mkdir()
            venvs = fake.cache / "venvs"
            venvs.mkdir(parents=True)
            (venvs / "mlx-audio").symlink_to(outside, target_is_directory=True)

            result = fake.run("--profile", "ko-meeting")

            self.assertEqual(result.returncode, 65, result.stderr)
            self.assertIn("refusing symlinked or special cache path", result.stderr)
            self.assertEqual(list(outside.iterdir()), [])
            self.assertEqual(fake.hf_calls(), [])
            self.assertEqual(fake.swift_calls(), [])
        finally:
            fake.close()

    def test_symlinked_hugging_face_root_fails_before_external_writers_run(self) -> None:
        fake = FakeRuntime()
        try:
            outside = fake.cache.parent / "outside-huggingface"
            outside.mkdir()
            models = fake.cache / "models"
            models.mkdir(parents=True)
            (models / "huggingface").symlink_to(outside, target_is_directory=True)

            result = fake.run("--profile", "ko-meeting")

            self.assertEqual(result.returncode, 65, result.stderr)
            self.assertIn("refusing symlinked or special cache path", result.stderr)
            self.assertEqual(list(outside.iterdir()), [])
            self.assertFalse((fake.cache / "venvs/mlx-audio/bin").exists())
            self.assertEqual(fake.hf_calls(), [])
            self.assertEqual(fake.swift_calls(), [])
        finally:
            fake.close()

    def test_symlinked_hugging_face_blob_fails_before_external_writers_run(self) -> None:
        fake = FakeRuntime()
        try:
            outside = fake.cache.parent / "outside-blob"
            outside.write_text("sentinel", encoding="utf-8")
            blobs = (
                fake.cache
                / "models/huggingface/hub/models--mlx-community--VibeVoice-ASR-8bit/blobs"
            )
            blobs.mkdir(parents=True)
            (blobs / "malicious").symlink_to(outside)

            result = fake.run("--profile", "ko-meeting")

            self.assertEqual(result.returncode, 65, result.stderr)
            self.assertIn("refusing symlinked or special cache entry", result.stderr)
            self.assertEqual(outside.read_text(encoding="utf-8"), "sentinel")
            self.assertEqual(fake.hf_calls(), [])
            self.assertEqual(fake.swift_calls(), [])
        finally:
            fake.close()

    def test_broken_cachedir_tag_symlink_fails_before_hub_writer_runs(self) -> None:
        fake = FakeRuntime()
        try:
            outside = fake.cache.parent / "outside-cachedir-tag"
            hub = fake.cache / "models/huggingface/hub"
            hub.mkdir(parents=True)
            (hub / "CACHEDIR.TAG").symlink_to(outside)

            result = fake.run("--profile", "ko-meeting")

            self.assertEqual(result.returncode, 65, result.stderr)
            self.assertIn("refusing symlinked or special cache file", result.stderr)
            self.assertFalse(outside.exists())
            self.assertEqual(fake.hf_calls(), [])
            self.assertEqual(fake.swift_calls(), [])
        finally:
            fake.close()

    def test_symlinked_snapshot_directory_fails_before_hub_writer_runs(self) -> None:
        fake = FakeRuntime()
        try:
            outside = fake.cache.parent / "outside-snapshot"
            outside.mkdir()
            sentinel = outside / "weight.bin"
            sentinel.write_text("sentinel", encoding="utf-8")
            snapshot = (
                fake.cache
                / "models/huggingface/hub"
                / "models--aufklarer--Pyannote-Community-1-CoreML/snapshots"
                / COMMUNITY_REVISION
            )
            snapshot.mkdir(parents=True)
            (snapshot / "embedding.mlmodelc").symlink_to(
                outside,
                target_is_directory=True,
            )

            result = fake.run("--profile", "ko-meeting")

            self.assertEqual(result.returncode, 65, result.stderr)
            self.assertIn("unsafe Hugging Face snapshot directory", result.stderr)
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "sentinel")
            self.assertFalse(sentinel.is_symlink())
            self.assertEqual(fake.hf_calls(), [])
            self.assertEqual(fake.swift_calls(), [])
        finally:
            fake.close()

    def test_broken_no_exist_leaf_symlink_fails_before_hub_writer_runs(self) -> None:
        fake = FakeRuntime()
        try:
            outside = fake.cache.parent / "outside-no-exist-leaf"
            marker_root = (
                fake.cache
                / "models/huggingface/hub/models--Qwen--Qwen2.5-7B/.no_exist"
                / TOKENIZER_REVISION
            )
            marker_root.mkdir(parents=True)
            (marker_root / "missing.json").symlink_to(outside)

            result = fake.run("--profile", "ko-meeting")

            self.assertEqual(result.returncode, 65, result.stderr)
            self.assertIn("refusing symlinked or special cache entry", result.stderr)
            self.assertFalse(outside.exists())
            self.assertEqual(fake.hf_calls(), [])
            self.assertEqual(fake.swift_calls(), [])
        finally:
            fake.close()

    def test_symlinked_local_model_root_fails_before_external_writers_run(self) -> None:
        fake = FakeRuntime()
        try:
            outside = fake.cache.parent / "outside-local-model"
            outside.mkdir()
            models = fake.cache / "qwen3-speech/models/aufklarer"
            models.mkdir(parents=True)
            (models / "Pyannote-Community-1-CoreML").symlink_to(
                outside, target_is_directory=True
            )

            result = fake.run("--profile", "ko-meeting")

            self.assertEqual(result.returncode, 65, result.stderr)
            self.assertIn("refusing symlinked or special cache path", result.stderr)
            self.assertEqual(list(outside.iterdir()), [])
            self.assertFalse((fake.cache / "venvs/mlx-audio/bin").exists())
            self.assertEqual(fake.hf_calls(), [])
            self.assertEqual(fake.swift_calls(), [])
        finally:
            fake.close()

    def test_symlinked_local_model_file_fails_before_external_writers_run(self) -> None:
        fake = FakeRuntime()
        try:
            outside = fake.cache.parent / "outside-config.json"
            outside.write_text("sentinel", encoding="utf-8")
            model = (
                fake.cache
                / "qwen3-speech/models/aufklarer/Pyannote-Community-1-CoreML"
            )
            model.mkdir(parents=True)
            (model / "config.json").symlink_to(outside)

            result = fake.run("--profile", "ko-meeting")

            self.assertEqual(result.returncode, 65, result.stderr)
            self.assertIn("refusing symlinked or special cache entry", result.stderr)
            self.assertEqual(outside.read_text(encoding="utf-8"), "sentinel")
            self.assertEqual(fake.hf_calls(), [])
            self.assertEqual(fake.swift_calls(), [])
        finally:
            fake.close()

    def test_accepts_only_the_exact_ko_meeting_profile_usage(self) -> None:
        invalid_arguments = (
            (),
            ("--profile",),
            ("--profile", "unknown"),
            ("ko-meeting",),
            ("--profile", "ko-meeting", "unexpected"),
        )
        for arguments in invalid_arguments:
            with self.subTest(arguments=arguments):
                fake = FakeRuntime()
                try:
                    result = fake.run(*arguments)
                    self.assertEqual(result.returncode, 64)
                    self.assertEqual(
                        result.stderr.strip(),
                        "usage: scripts/setup-transcription-runtime.zsh --profile ko-meeting [--json]",
                    )
                    self.assertFalse(fake.cache.exists())
                finally:
                    fake.close()

    def test_qwen_hub_call_and_fresh_payload_are_tokenizer_only(self) -> None:
        fake = FakeRuntime()
        try:
            result = fake.run("--profile", "ko-meeting")
            self.assertEqual(result.returncode, 0, result.stderr)

            qwen_calls = [
                call
                for call in fake.hf_calls()
                if call[:2] == ["download", "Qwen/Qwen2.5-7B"]
            ]
            self.assertEqual(len(qwen_calls), 1)
            self.assertEqual(
                qwen_calls[0],
                [
                    "download",
                    "Qwen/Qwen2.5-7B",
                    *TOKENIZER_FILES,
                    "--revision",
                    TOKENIZER_REVISION,
                    "--cache-dir",
                    str(fake.cache / "models/huggingface/hub"),
                    "--quiet",
                ],
            )
            self.assertNotIn("--force-download", qwen_calls[0])
            self.assertFalse(any("*" in argument for argument in qwen_calls[0]))

            snapshot = (
                fake.cache
                / "models/huggingface/hub/models--Qwen--Qwen2.5-7B/snapshots"
                / TOKENIZER_REVISION
            )
            self.assertEqual({path.name for path in snapshot.iterdir()}, set(TOKENIZER_FILES))
            repository_files = {
                path.name.lower() for path in snapshot.parent.parent.rglob("*") if path.is_file()
            }
            self.assertFalse(any(name.endswith((".safetensors", ".bin", ".gguf")) for name in repository_files))

            reference = snapshot.parent.parent / "refs/main"
            self.assertEqual(reference.read_bytes(), TOKENIZER_REVISION.encode("ascii"))
            self.assertEqual(len(reference.read_bytes()), 40)
        finally:
            fake.close()

    def test_speech_models_are_acquired_by_commit_and_refs_are_exact(self) -> None:
        fake = FakeRuntime()
        try:
            result = fake.run("--profile", "ko-meeting")
            self.assertEqual(result.returncode, 0, result.stderr)
            expected = {
                "aufklarer/Pyannote-Community-1-CoreML": COMMUNITY_REVISION,
                "aufklarer/Silero-VAD-v6.2.1-CoreML": VAD_REVISION,
            }
            for model, revision in expected.items():
                downloads = [
                    call
                    for call in fake.hf_calls()
                    if call[:2] == ["download", model]
                ]
                self.assertEqual(len(downloads), 2)
                for call in downloads:
                    self.assertEqual(call[call.index("--revision") + 1], revision)
                    self.assertNotIn("main", call)
                repository = (
                    fake.cache
                    / "models/huggingface/hub"
                    / ("models--" + model.replace("/", "--"))
                )
                reference = repository / "refs/main"
                self.assertEqual(reference.read_bytes(), revision.encode("ascii"))
                self.assertEqual(reference.stat().st_size, 40)
        finally:
            fake.close()

    def test_upstream_alias_drift_cannot_change_exact_acquisition(self) -> None:
        fake = FakeRuntime()
        try:
            result = fake.run(
                "--profile",
                "ko-meeting",
                FAKE_REMOTE_MAIN_MISMATCH="all-models",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            source = fake.script.read_text(encoding="utf-8")
            self.assertNotIn("HfApi", source)
            self.assertNotIn("model_info", source)
            for call in fake.hf_calls():
                if call and call[0] == "download":
                    self.assertNotEqual(call[call.index("--revision") + 1], "main")
        finally:
            fake.close()

    def test_speech_model_closures_enforce_file_and_tree_digests(self) -> None:
        source = MODEL_VERIFIER.read_text(encoding="utf-8")
        self.assertIn(COMMUNITY_TREE_SHA256, source)
        self.assertIn(VAD_TREE_SHA256, source)

        fake = FakeRuntime()
        try:
            result = fake.run(
                "--profile", "ko-meeting", FAKE_CORRUPT_LOCAL_MODEL="1"
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("speech model file digest mismatch", result.stderr)
            self.assertNotIn("ready", result.stdout.lower())
        finally:
            fake.close()

    def test_offline_runtime_build_is_locked_and_provenance_is_complete(self) -> None:
        fake = FakeRuntime()
        try:
            result = fake.run("--profile", "ko-meeting")
            self.assertEqual(result.returncode, 0, result.stderr)
            runtime_root = fake.cache / "tools/offline-speech-runtime"
            executable = runtime_root / "bin/maccheroni-offline-speech-runtime"
            sidecar = runtime_root / "provenance.json"
            self.assertTrue(os.access(executable, os.X_OK))
            executable_sha256 = hashlib.sha256(executable.read_bytes()).hexdigest()
            self.assertEqual(
                json.loads(sidecar.read_text(encoding="utf-8")),
                {
                    "contract_version": "offline-speech-runtime-v1",
                    "speech_revision": SPEECH_REVISION,
                    "package_manifest_sha256": RUNTIME_PACKAGE_SHA256,
                    "package_resolved_sha256": RUNTIME_RESOLVED_SHA256,
                    "harness_source_sha256": RUNTIME_SOURCE_SHA256,
                    "executable_sha256": executable_sha256,
                    "swift_version": (
                        "Apple Swift version 6.3.3 "
                        "(swiftlang-6.3.3.1.3 clang-2100.1.1.101)\n"
                        "Target: arm64-apple-macosx26.0"
                    ),
                },
            )
            self.assertEqual(
                sorted(path.relative_to(runtime_root).as_posix()
                       for path in runtime_root.rglob("*") if path.is_file()),
                ["bin/maccheroni-offline-speech-runtime", "provenance.json"],
            )
            self.assertEqual(
                list((fake.cache / "tools").glob(".offline-speech-runtime.*")),
                [],
            )
            builds = [
                call for call in fake.swift_calls()
                if "--product" in call
                and call[call.index("--product") + 1]
                    == "maccheroni-offline-speech-runtime"
            ]
            self.assertEqual(len(builds), 1)
            build = builds[0]
            self.assertIn("--disable-automatic-resolution", build)
            self.assertIn("--disable-dependency-cache", build)
            self.assertEqual(build[build.index("-c") + 1], "release")
            self.assertEqual(
                Path(build[build.index("--scratch-path") + 1]),
                fake.cache / "build/offline-speech-runtime",
            )
        finally:
            fake.close()

    def test_offline_runtime_install_is_idempotent_and_skips_rebuild(self) -> None:
        fake = FakeRuntime()
        try:
            first = fake.run("--profile", "ko-meeting")
            self.assertEqual(first.returncode, 0, first.stderr)
            runtime_root = fake.cache / "tools/offline-speech-runtime"
            executable = runtime_root / "bin/maccheroni-offline-speech-runtime"
            sidecar = runtime_root / "provenance.json"
            original = (executable.read_bytes(), sidecar.read_bytes())

            second = fake.run("--profile", "ko-meeting")
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual((executable.read_bytes(), sidecar.read_bytes()), original)
            builds = [
                call for call in fake.swift_calls()
                if "--product" in call
                and call[call.index("--product") + 1]
                    == "maccheroni-offline-speech-runtime"
            ]
            self.assertEqual(len(builds), 1)
        finally:
            fake.close()

    def test_mismatched_runtime_provenance_fails_without_rewrite(self) -> None:
        fake = FakeRuntime()
        try:
            initial = fake.run("--profile", "ko-meeting")
            self.assertEqual(initial.returncode, 0, initial.stderr)
            provenance = fake.cache / "tools/offline-speech-runtime/provenance.json"
            original = b'{"untrusted":"keep unchanged"}\n'
            provenance.write_bytes(original)

            result = fake.run("--profile", "ko-meeting")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("provenance fields differ", result.stderr)
            self.assertEqual(provenance.read_bytes(), original)
        finally:
            fake.close()

    def test_mismatched_runtime_binary_fails_without_rewrite(self) -> None:
        fake = FakeRuntime()
        try:
            initial = fake.run("--profile", "ko-meeting")
            self.assertEqual(initial.returncode, 0, initial.stderr)
            runtime_root = fake.cache / "tools/offline-speech-runtime"
            executable = runtime_root / "bin/maccheroni-offline-speech-runtime"
            sidecar = runtime_root / "provenance.json"
            original_sidecar = sidecar.read_bytes()
            tampered = b"#!/bin/zsh\nprint untrusted\n"
            executable.write_bytes(tampered)
            executable.chmod(0o755)

            result = fake.run("--profile", "ko-meeting")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("provenance differs from installed inputs", result.stderr)
            self.assertEqual(executable.read_bytes(), tampered)
            self.assertEqual(sidecar.read_bytes(), original_sidecar)
        finally:
            fake.close()

    def test_partial_runtime_install_fails_without_build_or_rewrite(self) -> None:
        fake = FakeRuntime()
        try:
            runtime_root = fake.cache / "tools/offline-speech-runtime"
            runtime_root.mkdir(parents=True)
            sidecar = runtime_root / "provenance.json"
            original = b'{"untrusted":"preserve"}\n'
            sidecar.write_bytes(original)

            result = fake.run("--profile", "ko-meeting")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("installation is incomplete", result.stderr)
            self.assertEqual(sidecar.read_bytes(), original)
            self.assertFalse((runtime_root / "bin").exists())
            self.assertFalse(any(
                "--product" in call
                and call[call.index("--product") + 1]
                    == "maccheroni-offline-speech-runtime"
                for call in fake.swift_calls()
            ))
        finally:
            fake.close()

    def test_source_mismatch_and_failed_build_never_publish_runtime(self) -> None:
        for environment, mutate_source in (
            ({}, True),
            ({"FAKE_RUNTIME_BUILD_FAIL": "1"}, False),
        ):
            with self.subTest(environment=environment, mutate_source=mutate_source):
                fake = FakeRuntime()
                try:
                    if mutate_source:
                        source = (
                            fake.root
                            / "scripts/runners/offline-speech-runtime"
                            / "Sources/MaccheroniOfflineSpeechRuntime/main.swift"
                        )
                        source.write_text("tampered\n", encoding="utf-8")
                    result = fake.run("--profile", "ko-meeting", **environment)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(
                        (fake.cache / "tools/offline-speech-runtime").exists()
                    )
                    staging = list(
                        (fake.cache / "tools").glob(".offline-speech-runtime.*")
                    )
                    self.assertEqual(staging, [])
                finally:
                    fake.close()

    def test_setup_uses_the_tracked_source_runtime(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("scripts/runners/offline-speech-runtime", source)
        self.assertIn("--disable-automatic-resolution", source)
        self.assertIn("renamex_np", source)

    def test_mismatched_existing_qwen_ref_fails_without_rewrite(self) -> None:
        fake = FakeRuntime()
        try:
            initial = fake.run("--profile", "ko-meeting")
            self.assertEqual(initial.returncode, 0, initial.stderr)
            reference = (
                fake.cache
                / "models/huggingface/hub/models--Qwen--Qwen2.5-7B/refs/main"
            )
            original = "untrusted-revision\n"
            reference.write_text(original, encoding="utf-8")

            result = fake.run("--profile", "ko-meeting")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("refusing to rewrite mismatched ref", result.stderr)
            self.assertEqual(reference.read_text(encoding="utf-8"), original)
        finally:
            fake.close()

    def test_setup_reports_ready_only_after_product_doctor_succeeds(self) -> None:
        fake = FakeRuntime()
        try:
            failed = fake.run(
                "--profile", "ko-meeting", FAKE_DOCTOR_FAIL="1"
            )
            self.assertEqual(failed.returncode, 73)
            self.assertNotIn("ready", failed.stdout.lower())
            self.assertIn("doctor failed", failed.stderr)

            succeeded = fake.run("--profile", "ko-meeting")
            self.assertEqual(succeeded.returncode, 0, succeeded.stderr)
            self.assertEqual(succeeded.stdout.strip(), "ko-meeting ready")
        finally:
            fake.close()

    def test_json_output_is_parseable_safe_and_identifies_tokenizer_scope(self) -> None:
        fake = FakeRuntime()
        try:
            result = fake.run("--profile", "ko-meeting", "--json")
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["profile"], "ko-meeting")
            self.assertIs(payload["ready"], True)
            self.assertEqual(payload["qwen"]["scope"], "tokenizer-only")
            combined = result.stdout + result.stderr
            self.assertNotIn(str(fake.root), combined)
        finally:
            fake.close()

    def test_script_parses_as_zsh(self) -> None:
        result = subprocess.run(
            ["zsh", "-n", str(SCRIPT)],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
