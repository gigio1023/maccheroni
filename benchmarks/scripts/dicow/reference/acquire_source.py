#!/usr/bin/env python3
"""Acquire the pinned DiCoW source payload with a verified Hugging Face CLI.

Only standard-library modules are used so this program can establish the source
boundary before either experiment environment exists.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import traceback
from pathlib import Path
from typing import Dict, Iterable, Mapping, Optional, Sequence


MODEL_ID = "BUT-FIT/DiCoW_v3_MLC"
REVISION = "99c64e8dc409a158816e808a1ee556cdfd0af51c"
FILES = (
    "config.json",
    "config.py",
    "decoding.py",
    "encoder.py",
    "generation.py",
    "generation_config.json",
    "modeling_dicow.py",
    "preprocessor_config.json",
    "utils.py",
)
HF_LINK = Path(
    os.environ.get("MACCHERONI_HF_CLI")
    or shutil.which("hf")
    or "/usr/local/bin/hf"
)
HF_REALPATH = HF_LINK.resolve(strict=False)
HF_VERSION = "1.21.0"
SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
ANSI_ESCAPE_RE = re.compile(r"\x1b\[[0-9;]*m")
HEX_RE = re.compile(r"[0-9a-f]+\Z")


class AcquisitionError(RuntimeError):
    """Raised when the acquisition boundary cannot be proven."""


def _sha256(path: Path) -> str:
    return hashlib.sha256(_read_stable_file(path, str(path))).hexdigest()


def _reject_symlink_components(path: Path, label: str) -> None:
    if not path.is_absolute() or os.path.normpath(str(path)) != str(path) or str(path) == os.sep:
        raise AcquisitionError("{} must be an absolute normalized non-root path".format(label))
    current = Path(path.anchor)
    for component in path.parts[1:]:
        current = current / component
        try:
            info = os.lstat(str(current))
        except FileNotFoundError:
            return
        if stat.S_ISLNK(info.st_mode):
            raise AcquisitionError("{} contains a symlink component".format(label))


def _stable_file(path: Path, label: str):
    _reject_symlink_components(path, label)
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(str(path), flags)
    except OSError as error:
        raise AcquisitionError("cannot open {}: {}".format(label, error))
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise AcquisitionError("{} must be a regular file".format(label))
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    path_info = os.lstat(str(path))
    identities = (
        (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns),
        (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns),
        (path_info.st_dev, path_info.st_ino, path_info.st_size, path_info.st_mtime_ns),
    )
    if identities[0] != identities[1] or identities[1] != identities[2]:
        raise AcquisitionError("{} changed while it was read".format(label))
    return b"".join(chunks), after


def _read_stable_file(path: Path, label: str) -> bytes:
    return _stable_file(path, label)[0]


def _regular_file(path: Path, label: str) -> os.stat_result:
    return _stable_file(path, label)[1]


def _stable_record(path: Path, label: str) -> Dict[str, object]:
    data, info = _stable_file(path, label)
    return {
        "sha256": hashlib.sha256(data).hexdigest(),
        "bytes": info.st_size,
        "mode": "0{:03o}".format(stat.S_IMODE(info.st_mode)),
    }


def _tool_environment() -> Dict[str, str]:
    return {
        "PATH": SYSTEM_PATH,
        "HOME": "/private/var/empty",
        "LC_ALL": "C",
        "PYTHONNOUSERSITE": "1",
        "PYTHONUTF8": "1",
    }


def observe_hf_tool() -> Dict[str, str]:
    """Return the exact live host-tool tuple or fail closed."""

    try:
        link_info = os.lstat(str(HF_LINK))
    except OSError as error:
        raise AcquisitionError("hf link is unavailable: {}".format(error))
    if stat.S_ISLNK(link_info.st_mode):
        if HF_LINK.resolve(strict=True) != HF_REALPATH:
            raise AcquisitionError("hf link target differs from the observed target")
    elif not stat.S_ISREG(link_info.st_mode):
        raise AcquisitionError("hf command must be a regular file or symbolic link")
    _regular_file(HF_REALPATH, "hf target")
    if not os.access(str(HF_REALPATH), os.X_OK):
        raise AcquisitionError("hf target is not executable")
    sha256 = _sha256(HF_REALPATH)
    result = subprocess.run(
        [str(HF_REALPATH), "version"],
        env=_tool_environment(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=30,
        check=False,
    )
    if result.returncode != 0:
        raise AcquisitionError("hf version failed: {}".format(result.stderr.strip()))
    rendered = ANSI_ESCAPE_RE.sub("", result.stdout).strip()
    accepted = ("version={}".format(HF_VERSION), "✓ hf version\n  version: {}".format(HF_VERSION))
    if rendered not in accepted:
        raise AcquisitionError("hf version differs from version={}".format(HF_VERSION))
    return {
        "path": str(HF_LINK),
        "realpath": str(HF_REALPATH),
        "sha256": sha256,
        "version": HF_VERSION,
    }


def observe_hf_runtime() -> Dict[str, object]:
    """Fingerprint the interpreter and installed Hub code behind the wrapper."""

    wrapper = _read_stable_file(HF_REALPATH, "hf wrapper")
    first_line = wrapper.splitlines()[0].decode("utf-8")
    if not first_line.startswith("#!"):
        raise AcquisitionError("hf wrapper has no shebang interpreter")
    interpreter = Path(first_line[2:])
    if not interpreter.is_absolute() or not interpreter.exists():
        raise AcquisitionError("hf shebang interpreter is unavailable")
    interpreter_realpath = interpreter.resolve(strict=True)
    interpreter_record = _stable_record(interpreter_realpath, "hf interpreter")
    probe_code = (
        "import importlib.metadata,json,huggingface_hub,pathlib,sys;"
        "d=importlib.metadata.distribution('huggingface_hub');"
        "print(json.dumps({'version':huggingface_hub.__version__,"
        "'package_root':str(pathlib.Path(huggingface_hub.__file__).resolve().parent),"
        "'dist_info':str(pathlib.Path(d._path).resolve()),"
        "'sys_executable':sys.executable,'sys_executable_realpath':str(pathlib.Path(sys.executable).resolve())},sort_keys=True))"
    )
    result = subprocess.run(
        [str(interpreter), "-c", probe_code],
        env=_tool_environment(),
        cwd="/private/var/empty",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=30,
        check=False,
    )
    if result.returncode != 0:
        raise AcquisitionError("hf runtime probe failed: {}".format(result.stderr.strip()))
    try:
        probe = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise AcquisitionError("hf runtime probe returned invalid JSON: {}".format(error))
    if probe.get("version") != HF_VERSION or probe.get("sys_executable") != str(interpreter) or probe.get("sys_executable_realpath") != str(interpreter_realpath):
        raise AcquisitionError("hf runtime interpreter/version differs from the wrapper")
    package_root = Path(probe.get("package_root", ""))
    dist_info = Path(probe.get("dist_info", ""))
    if (
        package_root.name != "huggingface_hub"
        or package_root.parent != dist_info.parent
        or dist_info.name != "huggingface_hub-{}.dist-info".format(HF_VERSION)
    ):
        raise AcquisitionError("hf runtime package paths differ from the observed distribution")
    record_path = dist_info / "RECORD"
    distribution_record = _stable_record(record_path, "huggingface_hub RECORD")
    files = []
    for path in sorted(package_root.rglob("*")):
        relative = path.relative_to(package_root).as_posix()
        if "__pycache__" in path.parts or path.suffix in (".pyc", ".pyo"):
            continue
        if path.is_symlink():
            raise AcquisitionError("huggingface_hub package tree contains a symlink")
        if path.is_dir():
            continue
        record = _stable_record(path, "huggingface_hub package {}".format(relative))
        files.append(
            {
                "path": relative,
                **record,
            }
        )
    inventory_bytes = json.dumps(files, separators=(",", ":"), sort_keys=True).encode("utf-8")
    return {
        "wrapper_shebang": first_line,
        "interpreter_path": str(interpreter),
        "interpreter_realpath": str(interpreter_realpath),
        "interpreter_sha256": interpreter_record["sha256"],
        "interpreter_bytes": interpreter_record["bytes"],
        "interpreter_mode": interpreter_record["mode"],
        "huggingface_hub_version": probe["version"],
        "package_root": str(package_root),
        "dist_info": str(dist_info),
        "record_sha256": distribution_record["sha256"],
        "record_bytes": distribution_record["bytes"],
        "package_file_count": len(files),
        "package_bytes": sum(item["bytes"] for item in files),
        "package_inventory_sha256": hashlib.sha256(inventory_bytes).hexdigest(),
        "package_files": files,
    }


def _private_directories(output: Path) -> Iterable[Path]:
    for relative in (
        "home",
        "hf-home",
        "hf-cache",
        "snapshot",
        "xdg-cache",
        "xdg-config",
        "tmp",
    ):
        yield output / relative


def child_environment(output: Path) -> Dict[str, str]:
    """Build the complete download environment without inheriting parent state."""

    return {
        "PATH": SYSTEM_PATH,
        "HOME": str(output / "home"),
        "HF_HOME": str(output / "hf-home"),
        "HF_HUB_CACHE": str(output / "hf-cache"),
        "HF_ENDPOINT": "https://huggingface.co",
        "HF_HUB_OFFLINE": "0",
        "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1",
        "HF_HUB_DISABLE_TELEMETRY": "1",
        "HF_HUB_DISABLE_XET": "1",
        "XDG_CACHE_HOME": str(output / "xdg-cache"),
        "XDG_CONFIG_HOME": str(output / "xdg-config"),
        "TMPDIR": str(output / "tmp"),
        "PYTHONNOUSERSITE": "1",
        "PYTHONUTF8": "1",
        "LC_ALL": "C",
    }


def download_command(output: Path) -> Sequence[str]:
    return (
        str(HF_REALPATH),
        "download",
        MODEL_ID,
        *FILES,
        "--revision",
        REVISION,
        "--local-dir",
        str(output / "snapshot"),
    )


def _remove_verified_hf_metadata(snapshot: Path) -> bool:
    """Remove only hf 1.21.0's known local-dir bookkeeping after validation."""

    metadata_root = snapshot / ".cache" / "huggingface"
    if not metadata_root.exists() and not metadata_root.is_symlink():
        raise AcquisitionError("hf local-dir metadata is missing")
    if metadata_root.is_symlink() or not metadata_root.is_dir():
        raise AcquisitionError("hf local-dir metadata root must be a directory")
    expected_files = {
        ".gitignore",
        "CACHEDIR.TAG",
        *("download/{}.metadata".format(name) for name in FILES),
    }
    observed_files = set()
    observed_directories = set()
    for path in sorted(metadata_root.rglob("*")):
        relative = path.relative_to(metadata_root).as_posix()
        if path.is_symlink():
            raise AcquisitionError("hf local-dir metadata contains a symlink: {}".format(relative))
        if path.is_dir():
            observed_directories.add(relative)
        elif path.is_file():
            _regular_file(path, "hf local-dir metadata {}".format(relative))
            observed_files.add(relative)
        else:
            raise AcquisitionError("hf local-dir metadata contains a special file: {}".format(relative))
    if observed_directories != {"download"} or observed_files != expected_files:
        raise AcquisitionError("hf local-dir metadata differs from the exact known file set")
    for name in FILES:
        metadata_path = metadata_root / "download" / (name + ".metadata")
        lines = _read_stable_file(metadata_path, "hf metadata {}".format(name)).decode("utf-8").splitlines()
        if len(lines) != 3 or lines[0] != REVISION or len(lines[1]) not in (40, 64) or not HEX_RE.fullmatch(lines[1]):
            raise AcquisitionError("hf local-dir metadata content is invalid for {}".format(name))
        try:
            timestamp = float(lines[2])
        except ValueError:
            raise AcquisitionError("hf local-dir metadata timestamp is invalid for {}".format(name))
        if not math.isfinite(timestamp):
            raise AcquisitionError("hf local-dir metadata timestamp is non-finite for {}".format(name))
    for relative in sorted(expected_files, key=lambda value: value.count("/"), reverse=True):
        (metadata_root / relative).unlink()
    (metadata_root / "download").rmdir()
    metadata_root.rmdir()
    (snapshot / ".cache").rmdir()
    return True


def _private_inventory(output: Path) -> Dict[str, object]:
    inventories = {}
    allowed_hf_home_files = {".agent_harnesses.json", ".check_for_update_done"}
    for name in ("home", "hf-home", "hf-cache", "xdg-cache", "xdg-config", "tmp"):
        root = output / name
        if root.is_symlink() or not root.is_dir():
            raise AcquisitionError("private directory {} is missing or unsafe".format(name))
        files = []
        directories = []
        for path in sorted(root.rglob("*")):
            relative = path.relative_to(root).as_posix()
            if path.is_symlink():
                raise AcquisitionError("private directory {} contains a symlink".format(name))
            if path.is_dir():
                directories.append(relative)
            elif path.is_file():
                record = _stable_record(path, "private side effect {}/{}".format(name, relative))
                files.append(
                    {
                        "path": relative,
                        **record,
                    }
                )
            else:
                raise AcquisitionError("private directory {} contains a special file".format(name))
        if directories:
            raise AcquisitionError("private directory {} contains unexpected subdirectories".format(name))
        observed_files = {item["path"] for item in files}
        if name == "hf-home":
            if observed_files != allowed_hf_home_files:
                raise AcquisitionError("hf-home side effects differ from the exact known set")
        elif observed_files:
            raise AcquisitionError("private directory {} contains unexpected files".format(name))
        inventories[name] = {"directories": directories, "files": files}
    return {
        "schema_version": "dicow-source-private-inventory-v1",
        "policy": "only_exact_hf_1_21_0_hf_home_side_effects",
        "directories": inventories,
    }


def _payload_records(snapshot: Path) -> Sequence[Dict[str, object]]:
    expected = set(FILES)
    observed = set()
    records = []
    for path in sorted(snapshot.rglob("*")):
        relative = path.relative_to(snapshot).as_posix()
        if path.is_symlink():
            raise AcquisitionError("snapshot contains a symlink: {}".format(relative))
        if path.is_dir():
            raise AcquisitionError("snapshot contains an additional directory: {}".format(relative))
        if path.is_file():
            observed.add(relative)
            if relative not in expected:
                raise AcquisitionError("snapshot contains an additional payload: {}".format(relative))
            record = _stable_record(path, "payload {}".format(relative))
            if record["bytes"] <= 0:
                raise AcquisitionError("payload is empty: {}".format(relative))
            records.append(
                {
                    "path": "snapshot/{}".format(relative),
                    **record,
                }
            )
        else:
            raise AcquisitionError("snapshot contains a special file: {}".format(relative))
    missing = expected - observed
    if missing:
        raise AcquisitionError("snapshot is missing payloads: {}".format(", ".join(sorted(missing))))
    if observed - expected:
        raise AcquisitionError("snapshot contains unexpected payloads")
    return records


def _write_atomic(path: Path, data: bytes) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=".{}-".format(path.name), dir=str(path.parent))
    temporary_path = Path(temporary)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(str(temporary_path), str(path))
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


def acquire(output: Path) -> None:
    _reject_symlink_components(output.parent, "output parent")
    if not output.is_absolute() or os.path.normpath(str(output)) != str(output):
        raise AcquisitionError("output must be absolute and normalized")
    if output.name != "t2-source-metadata":
        raise AcquisitionError("output must end in t2-source-metadata")
    if output.exists() or output.is_symlink():
        raise AcquisitionError("output must be absent")
    before = observe_hf_tool()
    runtime_before = observe_hf_runtime()
    output.mkdir(parents=False, mode=0o755)
    for directory in _private_directories(output):
        directory.mkdir(mode=0o700)

    environment = child_environment(output)
    command = list(download_command(output))
    result = subprocess.run(
        command,
        env=environment,
        cwd=str(output / "home"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=900,
        check=False,
    )
    after = observe_hf_tool()
    runtime_after = observe_hf_runtime()
    if after != before:
        raise AcquisitionError("hf tool changed during acquisition")
    if runtime_after != runtime_before:
        raise AcquisitionError("hf runtime changed during acquisition")
    if result.returncode != 0:
        raise AcquisitionError("hf download failed: {}".format(result.stderr.strip()))

    metadata_removed = _remove_verified_hf_metadata(output / "snapshot")
    payloads = _payload_records(output / "snapshot")
    inventory = _private_inventory(output)
    sums = "".join("{}  {}\n".format(item["sha256"], item["path"]) for item in payloads)
    _write_atomic(output / "SHA256SUMS", sums.encode("ascii"))
    inventory_bytes = (json.dumps(inventory, indent=2, sort_keys=True) + "\n").encode("utf-8")
    _write_atomic(output / "private-inventory.json", inventory_bytes)
    manifest = {
        "schema_version": "dicow-source-acquisition-v1",
        "model_id": MODEL_ID,
        "revision": REVISION,
        "hf_tool_pre": before,
        "hf_tool_post": after,
        "hf_runtime_pre": runtime_before,
        "hf_runtime_post": runtime_after,
        "child_env": environment,
        "command": command,
        "hf_local_dir_metadata": {
            "policy": "exact_hf_1_21_0_known_set_then_remove",
            "removed_before_seal": metadata_removed,
        },
        "private_inventory_sha256": hashlib.sha256(inventory_bytes).hexdigest(),
        "payloads": payloads,
        "default_cache_used": False,
    }
    encoded = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
    _write_atomic(output / "manifest.json", encoded)


def verify_manifest(path: Path) -> None:
    _reject_symlink_components(path, "manifest")
    try:
        value = json.loads(_read_stable_file(path, "manifest").decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AcquisitionError("manifest is invalid: {}".format(error))
    expected_keys = {
        "schema_version", "model_id", "revision", "hf_tool_pre", "hf_tool_post",
        "hf_runtime_pre", "hf_runtime_post", "child_env", "command",
        "hf_local_dir_metadata", "private_inventory_sha256", "payloads",
        "default_cache_used",
    }
    if set(value) != expected_keys:
        raise AcquisitionError("manifest key set differs from the exact contract")
    if value.get("hf_tool_pre") != value.get("hf_tool_post"):
        raise AcquisitionError("manifest tool tuples differ")
    if value.get("hf_tool_pre") != observe_hf_tool():
        raise AcquisitionError("live hf tool differs from acquisition manifest")
    if value.get("hf_runtime_pre") != value.get("hf_runtime_post"):
        raise AcquisitionError("manifest hf runtime tuples differ")
    if value.get("hf_runtime_pre") != observe_hf_runtime():
        raise AcquisitionError("live hf runtime differs from acquisition manifest")
    if value.get("model_id") != MODEL_ID or value.get("revision") != REVISION:
        raise AcquisitionError("manifest source identity differs from pins")
    if value.get("schema_version") != "dicow-source-acquisition-v1":
        raise AcquisitionError("manifest schema version is wrong")
    if value.get("child_env") != child_environment(path.parent):
        raise AcquisitionError("manifest child environment differs from the clean contract")
    if value.get("command") != list(download_command(path.parent)):
        raise AcquisitionError("manifest command differs from the fixed command")
    expected_cleanup = {
        "policy": "exact_hf_1_21_0_known_set_then_remove",
        "removed_before_seal": True,
    }
    if value.get("hf_local_dir_metadata") != expected_cleanup:
        raise AcquisitionError("manifest metadata-cleanup evidence differs from the contract")
    inventory_path = path.parent / "private-inventory.json"
    if inventory_path.is_symlink() or not inventory_path.is_file():
        raise AcquisitionError("private inventory evidence is missing")
    inventory_bytes = _read_stable_file(inventory_path, "private inventory")
    if value.get("private_inventory_sha256") != hashlib.sha256(inventory_bytes).hexdigest():
        raise AcquisitionError("private inventory hash differs from the manifest")
    try:
        recorded_inventory = json.loads(inventory_bytes.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AcquisitionError("private inventory evidence is invalid: {}".format(error))
    if recorded_inventory != _private_inventory(path.parent):
        raise AcquisitionError("private inventory evidence differs from disk")
    current = _payload_records(path.parent / "snapshot")
    if value.get("payloads") != current or value.get("default_cache_used") is not False:
        raise AcquisitionError("manifest payload evidence differs from disk")
    sums_path = path.parent / "SHA256SUMS"
    sums = _read_stable_file(sums_path, "SHA256SUMS").decode("ascii")
    expected_sums = "".join("{}  {}\n".format(item["sha256"], item["path"]) for item in current)
    if sums != expected_sums:
        raise AcquisitionError("SHA256SUMS differs from the payload evidence")
    allowed_directories = {"home", "hf-home", "hf-cache", "snapshot", "xdg-cache", "xdg-config", "tmp"}
    allowed_files = {
        "SHA256SUMS",
        "private-inventory.json",
        "manifest.json",
        "reference-import.json",
        "aligner-korean-smoke.json",
    }
    observed_directories = set()
    observed_files = set()
    for entry in path.parent.iterdir():
        if entry.is_symlink():
            raise AcquisitionError("acquisition root contains a symlink")
        if entry.is_dir():
            observed_directories.add(entry.name)
        elif entry.is_file():
            observed_files.add(entry.name)
        else:
            raise AcquisitionError("acquisition root contains a special file")
    if observed_directories != allowed_directories or not {"SHA256SUMS", "private-inventory.json", "manifest.json"}.issubset(observed_files) or observed_files - allowed_files:
        raise AcquisitionError("acquisition root inventory differs from the exact contract")


REFERENCE_MODULES = ("config", "decoding", "encoder", "utils", "generation", "modeling_dicow")
REFERENCE_PROBE = r'''import hashlib,importlib,json,os,pathlib,sys,types
import numpy,torch,transformers
root=pathlib.Path(os.environ["DICOW_SOURCE_ROOT"])
package=types.ModuleType("dicow_source")
package.__path__=[str(root)]
sys.modules["dicow_source"]=package
records=[]
for name in %r:
    module=importlib.import_module("dicow_source."+name)
    path=pathlib.Path(module.__file__).resolve()
    data=path.read_bytes()
    records.append({"module":name,"path":str(path),"sha256":hashlib.sha256(data).hexdigest(),"bytes":len(data)})
print(json.dumps({"modules":records,"installed":{"numpy":numpy.__version__,"torch":torch.__version__,"torch_cuda":torch.version.cuda,"transformers":transformers.__version__,"python":sys.version.split()[0]}},sort_keys=True))
''' % (REFERENCE_MODULES,)


def _reference_probe(source_root: Path, reference_venv: Path, lock_path: Path) -> Dict[str, object]:
    _reject_symlink_components(source_root, "source root")
    if source_root.is_symlink() or not source_root.is_dir():
        raise AcquisitionError("source root must be a real directory")
    payloads = _payload_records(source_root)
    acquisition_manifest = source_root.parent / "manifest.json"
    verify_manifest(acquisition_manifest)
    acquisition_manifest_sha256 = _sha256(acquisition_manifest)
    repository = Path(__file__).resolve().parents[4]
    expected_lock = repository / "benchmarks" / "env" / "dicow-reference" / "uv.lock"
    if lock_path.resolve() != expected_lock or lock_path.is_symlink():
        raise AcquisitionError("reference lock path differs from the repository contract")
    lock_record = _stable_record(lock_path, "reference lock")
    lock_sha256 = lock_record["sha256"]
    expected_venv = source_root.parents[3] / "venvs" / "reference" / lock_sha256
    if reference_venv != expected_venv or reference_venv.name != lock_sha256 or reference_venv.is_symlink() or not reference_venv.is_dir():
        raise AcquisitionError("reference venv is not bound to the lock SHA-256")
    interpreter = reference_venv / "bin" / "python"
    if not interpreter.exists() or not os.access(str(interpreter), os.X_OK):
        raise AcquisitionError("reference interpreter is unavailable")
    environment = {
        "PATH": SYSTEM_PATH,
        "HOME": "/private/var/empty",
        "LC_ALL": "C",
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONNOUSERSITE": "1",
        "PYTHONUTF8": "1",
        "HF_HUB_OFFLINE": "1",
        "TRANSFORMERS_OFFLINE": "1",
        "DICOW_SOURCE_ROOT": str(source_root),
    }
    result = subprocess.run(
        [str(interpreter), "-c", REFERENCE_PROBE],
        env=environment,
        cwd="/private/var/empty",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=120,
        check=False,
    )
    config = json.loads(_read_stable_file(source_root / "config.json", "source config").decode("utf-8"))
    base = {
        "config_transformers_version": config.get("transformers_version"),
        "acquisition_manifest_sha256": acquisition_manifest_sha256,
        "acquisition_payloads": payloads,
        "reference_lock": {
            "path": str(lock_path),
            **lock_record,
        },
        "reference_venv": str(reference_venv),
        "command": [str(interpreter), "-c", "REFERENCE_PROBE"],
        "child_env": environment,
    }
    if result.returncode != 0:
        base.update({"result": "import_error", "traceback": result.stderr})
        return base
    try:
        probe = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise AcquisitionError("reference probe returned invalid JSON: {}".format(error))
    expected_paths = {
        name: str((source_root / (name + ".py")).resolve()) for name in REFERENCE_MODULES
    }
    modules = probe.get("modules")
    installed = probe.get("installed")
    if not isinstance(modules, list) or [item.get("module") for item in modules] != list(REFERENCE_MODULES):
        raise AcquisitionError("reference probe module order differs from the contract")
    for item in modules:
        name = item["module"]
        path = source_root / (name + ".py")
        live_record = _stable_record(path, "reference module {}".format(name))
        if item.get("path") != expected_paths[name] or item.get("sha256") != live_record["sha256"] or item.get("bytes") != live_record["bytes"]:
            raise AcquisitionError("reference probe module evidence differs for {}".format(name))
    if not isinstance(installed, dict) or installed.get("transformers") != "4.42.0" or installed.get("numpy") != "1.26.4" or installed.get("torch") != "2.8.0" or installed.get("python") != "3.12.13" or installed.get("torch_cuda") is not None:
        raise AcquisitionError("reference probe installed runtime differs from the source/CPU contract")
    base.update({"result": "ok", "traceback": None, "modules": modules, "installed": installed})
    return base


def probe_reference(source_root: Path, reference_venv: Path, lock_path: Path, output: Path) -> None:
    if output != source_root.parent / "reference-import.json":
        raise AcquisitionError("reference probe output path differs from the contract")
    if output.exists() or output.is_symlink():
        raise AcquisitionError("reference probe output must be absent")
    evidence = _reference_probe(source_root, reference_venv, lock_path)
    evidence.update(
        {
            "schema_version": "dicow-reference-import-v2",
            "selected_branch": "initial_4_42_0" if evidence["config_transformers_version"] == "4.42.0" else "one_allowed_relock",
            "fallback_relock_used": evidence["config_transformers_version"] != "4.42.0",
        }
    )
    if evidence["config_transformers_version"] != "4.42.0":
        raise AcquisitionError("a fallback re-lock requires preserved initial-failure evidence")
    _write_atomic(output, (json.dumps(evidence, indent=2, sort_keys=True) + "\n").encode("utf-8"))
    if evidence["result"] != "ok":
        raise AcquisitionError("reference source import failed; traceback was recorded")


def verify_reference(source_root: Path, reference_venv: Path, lock_path: Path, evidence_path: Path) -> None:
    if evidence_path != source_root.parent / "reference-import.json" or evidence_path.is_symlink() or not evidence_path.is_file():
        raise AcquisitionError("reference evidence must be a regular file")
    recorded = json.loads(_read_stable_file(evidence_path, "reference evidence").decode("utf-8"))
    live = _reference_probe(source_root, reference_venv, lock_path)
    for key in ("config_transformers_version", "acquisition_manifest_sha256", "acquisition_payloads", "reference_lock", "reference_venv", "command", "child_env", "result", "traceback", "modules", "installed"):
        if recorded.get(key) != live.get(key):
            raise AcquisitionError("reference evidence differs from live probe: {}".format(key))
    if recorded.get("schema_version") != "dicow-reference-import-v2":
        raise AcquisitionError("reference evidence schema is wrong")
    if recorded.get("selected_branch") != "initial_4_42_0" or recorded.get("fallback_relock_used") is not False:
        raise AcquisitionError("reference branch evidence is wrong")


ALIGNER_PROBE = r'''import importlib.metadata,json,sys
from mlx_audio.stt.models.qwen3_asr.qwen3_forced_aligner import ForceAlignProcessor
from soynlp.tokenizer import LTokenizer
processor=ForceAlignProcessor()
words,encoded=processor.encode_timestamp("안녕하세요 세계","Korean")
print(json.dumps({"installed":{"mlx":importlib.metadata.version("mlx"),"mlx_audio":importlib.metadata.version("mlx-audio"),"soynlp":importlib.metadata.version("soynlp"),"python":sys.version.split()[0]},"words":words,"encoded":encoded,"tokenizer_class":processor.ko_tokenizer.__class__.__name__,"tokenizer_module":processor.ko_tokenizer.__class__.__module__},ensure_ascii=False,sort_keys=True))
'''


def _aligner_probe(metadata_root: Path, aligner_venv: Path, lock_path: Path) -> Dict[str, object]:
    _reject_symlink_components(metadata_root, "source metadata root")
    verify_manifest(metadata_root / "manifest.json")
    repository = Path(__file__).resolve().parents[4]
    expected_lock = repository / "benchmarks" / "env" / "dicow-aligner" / "uv.lock"
    if lock_path.resolve() != expected_lock or lock_path.is_symlink():
        raise AcquisitionError("aligner lock path differs from the repository contract")
    lock_record = _stable_record(lock_path, "aligner lock")
    lock_sha256 = lock_record["sha256"]
    expected_venv = metadata_root.parents[2] / "venvs" / "aligner" / lock_sha256
    if aligner_venv != expected_venv or aligner_venv.is_symlink() or not aligner_venv.is_dir():
        raise AcquisitionError("aligner venv is not bound to the lock SHA-256")
    interpreter = aligner_venv / "bin" / "python"
    if not interpreter.exists() or not os.access(str(interpreter), os.X_OK):
        raise AcquisitionError("aligner interpreter is unavailable")
    environment = {
        "PATH": SYSTEM_PATH,
        "HOME": "/private/var/empty",
        "LC_ALL": "C",
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONNOUSERSITE": "1",
        "PYTHONUTF8": "1",
        "HF_HUB_OFFLINE": "1",
    }
    result = subprocess.run(
        [str(interpreter), "-W", "ignore", "-c", ALIGNER_PROBE],
        env=environment,
        cwd="/private/var/empty",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=120,
        check=False,
    )
    base = {
        "aligner_lock": {
            "path": str(lock_path),
            **lock_record,
        },
        "aligner_venv": str(aligner_venv),
        "command": [str(interpreter), "-W", "ignore", "-c", "ALIGNER_PROBE"],
        "child_env": environment,
    }
    if result.returncode != 0:
        base.update({"result": "import_error", "traceback": result.stderr})
        return base
    try:
        probe = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise AcquisitionError("aligner probe returned invalid JSON: {}".format(error))
    expected_versions = {"mlx": "0.32.0", "mlx_audio": "0.4.6", "soynlp": "0.0.493", "python": "3.12.13"}
    if probe.get("installed") != expected_versions:
        raise AcquisitionError("aligner installed runtime differs from the lock contract")
    if not probe.get("words") or not probe.get("encoded", "").startswith("<|audio_start|><|audio_pad|><|audio_end|>") or not probe["encoded"].endswith("<timestamp><timestamp>"):
        raise AcquisitionError("Korean aligner tokenization output is structurally wrong")
    if probe.get("tokenizer_class") != "LTokenizer" or probe.get("tokenizer_module") != "soynlp.tokenizer._tokenizer":
        raise AcquisitionError("Korean aligner did not use the pinned soynlp tokenizer")
    base.update({"result": "ok", "traceback": None, "probe": probe})
    return base


def probe_aligner(metadata_root: Path, aligner_venv: Path, lock_path: Path, output: Path) -> None:
    if output != metadata_root / "aligner-korean-smoke.json":
        raise AcquisitionError("aligner probe output path differs from the contract")
    if output.exists() or output.is_symlink():
        raise AcquisitionError("aligner probe output must be absent")
    evidence = _aligner_probe(metadata_root, aligner_venv, lock_path)
    evidence["schema_version"] = "dicow-aligner-korean-smoke-v2"
    _write_atomic(output, (json.dumps(evidence, indent=2, sort_keys=True) + "\n").encode("utf-8"))
    if evidence["result"] != "ok":
        raise AcquisitionError("Korean aligner probe failed; traceback was recorded")


def verify_aligner(metadata_root: Path, aligner_venv: Path, lock_path: Path, evidence_path: Path) -> None:
    if evidence_path != metadata_root / "aligner-korean-smoke.json" or evidence_path.is_symlink() or not evidence_path.is_file():
        raise AcquisitionError("aligner evidence path differs from the contract")
    recorded = json.loads(_read_stable_file(evidence_path, "aligner evidence").decode("utf-8"))
    live = _aligner_probe(metadata_root, aligner_venv, lock_path)
    if recorded.get("schema_version") != "dicow-aligner-korean-smoke-v2":
        raise AcquisitionError("aligner evidence schema is wrong")
    for key in ("aligner_lock", "aligner_venv", "command", "child_env", "result", "traceback", "probe"):
        if recorded.get(key) != live.get(key):
            raise AcquisitionError("aligner evidence differs from live probe: {}".format(key))


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    acquire_parser = subparsers.add_parser("acquire")
    acquire_parser.add_argument("--output", required=True, type=Path)
    verify_parser = subparsers.add_parser("verify-tool")
    verify_parser.add_argument("--manifest", required=True, type=Path)
    probe_parser = subparsers.add_parser("probe-reference")
    probe_parser.add_argument("--source-root", required=True, type=Path)
    probe_parser.add_argument("--reference-venv", required=True, type=Path)
    probe_parser.add_argument("--lock", required=True, type=Path)
    probe_parser.add_argument("--output", required=True, type=Path)
    verify_reference_parser = subparsers.add_parser("verify-reference")
    verify_reference_parser.add_argument("--source-root", required=True, type=Path)
    verify_reference_parser.add_argument("--reference-venv", required=True, type=Path)
    verify_reference_parser.add_argument("--lock", required=True, type=Path)
    verify_reference_parser.add_argument("--evidence", required=True, type=Path)
    aligner_parser = subparsers.add_parser("probe-aligner")
    aligner_parser.add_argument("--metadata-root", required=True, type=Path)
    aligner_parser.add_argument("--aligner-venv", required=True, type=Path)
    aligner_parser.add_argument("--lock", required=True, type=Path)
    aligner_parser.add_argument("--output", required=True, type=Path)
    verify_aligner_parser = subparsers.add_parser("verify-aligner")
    verify_aligner_parser.add_argument("--metadata-root", required=True, type=Path)
    verify_aligner_parser.add_argument("--aligner-venv", required=True, type=Path)
    verify_aligner_parser.add_argument("--lock", required=True, type=Path)
    verify_aligner_parser.add_argument("--evidence", required=True, type=Path)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        if arguments.command == "acquire":
            acquire(arguments.output)
        elif arguments.command == "verify-tool":
            verify_manifest(arguments.manifest)
        elif arguments.command == "probe-reference":
            probe_reference(arguments.source_root, arguments.reference_venv, arguments.lock, arguments.output)
        elif arguments.command == "verify-reference":
            verify_reference(arguments.source_root, arguments.reference_venv, arguments.lock, arguments.evidence)
        elif arguments.command == "probe-aligner":
            probe_aligner(arguments.metadata_root, arguments.aligner_venv, arguments.lock, arguments.output)
        else:
            verify_aligner(arguments.metadata_root, arguments.aligner_venv, arguments.lock, arguments.evidence)
    except (AcquisitionError, OSError, subprocess.SubprocessError) as error:
        print("source acquisition failed: {}".format(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
