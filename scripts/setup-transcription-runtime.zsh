#!/bin/zsh
# Provision the complete pinned ko-meeting runtime into one cache root.
set -euo pipefail
umask 077

repo_root=${0:A:h:h}
script_path=${0:A}
python_project="$repo_root/Sources/MaccheroniASR/Python"
cache_root="${MACCHERONI_BENCHMARK_CACHE:-$HOME/Library/Caches/Maccheroni/benchmarks}"
cache_root=$(/usr/bin/python3 - "$cache_root" <<'PY'
import os
import pathlib
import stat
import sys

requested = pathlib.Path(os.path.abspath(pathlib.Path(sys.argv[1]).expanduser()))
try:
    metadata = requested.lstat()
except FileNotFoundError:
    pass
else:
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise SystemExit(f"cache root must be a real directory: {requested}")
print(requested.resolve(strict=False))
PY
)
hf_home="$cache_root/models/huggingface"
hf_cache="$hf_home/hub"
runtime_source="$repo_root/scripts/runners/offline-speech-runtime"
runtime_package="$runtime_source/Package.swift"
runtime_resolved="$runtime_source/Package.resolved"
runtime_main="$runtime_source/Sources/MaccheroniOfflineSpeechRuntime/main.swift"
runtime_package_digest='5059f0c80bcec9cfc88bc56db8bc48504860ed556930f0225c817feb6607e5fd'
runtime_resolved_digest='e81c1d4f14185323abc782967b18a2342e36358b696b57be25a702718ab2330c'
runtime_main_digest='ba28b93e69c3b0ee6da9b19b328642a797355220f60a82eb87115496b6b8ff79'
speech_revision='c1aa219bc2284239ff6917d675a3e1978c840260'
runtime_tool_root="$cache_root/tools/offline-speech-runtime"
runtime_bin_dir="$runtime_tool_root/bin"
runtime_binary="$runtime_bin_dir/maccheroni-offline-speech-runtime"
runtime_sidecar="$runtime_tool_root/provenance.json"
runtime_scratch="$cache_root/build/offline-speech-runtime"
uv_cache="$cache_root/build/uv-cache"
uv_python_install="$cache_root/build/uv-python"
json=false
temporary_install=''

cleanup() {
    if [[ -n $temporary_install && -d $temporary_install ]]; then
        rm -rf -- "$temporary_install"
    fi
}
trap cleanup EXIT HUP INT TERM

vibe_id='mlx-community/VibeVoice-ASR-8bit'
vibe_revision='725c72e54d6ef875472c27fbc50fab470a960940'
tokenizer_id='Qwen/Qwen2.5-7B'
tokenizer_revision='d149729398750b98c0af14eb82c78cfe92750796'
community_id='aufklarer/Pyannote-Community-1-CoreML'
community_revision='a14e6c420d56e8472850649b016a486fd0acbe81'
vad_id='aufklarer/Silero-VAD-v6.2.1-CoreML'
vad_revision='523876545a57961474fee9df913e833e130560b8'
vibe_repository="$hf_cache/models--mlx-community--VibeVoice-ASR-8bit"
tokenizer_repository="$hf_cache/models--Qwen--Qwen2.5-7B"
community_repository="$hf_cache/models--aufklarer--Pyannote-Community-1-CoreML"
vad_repository="$hf_cache/models--aufklarer--Silero-VAD-v6.2.1-CoreML"
speech_models="$cache_root/qwen3-speech/models/aufklarer"
community_model="$speech_models/Pyannote-Community-1-CoreML"
vad_model="$speech_models/Silero-VAD-v6.2.1-CoreML"

usage() {
    print -u2 -- 'usage: scripts/setup-transcription-runtime.zsh --profile ko-meeting [--json]'
    exit 64
}

profile=''
while (( $# > 0 )); do
    case "$1" in
        --profile)
            (( $# >= 2 )) || usage
            profile=$2
            shift 2
            ;;
        --json)
            json=true
            shift
            ;;
        *) usage ;;
    esac
done
[[ $profile == ko-meeting ]] || usage

# The remedy printed by a stale-environment refusal has to reproduce this
# invocation, including the cache root the caller selected.
provision_command="zsh \"$script_path\" --profile $profile"
if [[ -n ${MACCHERONI_BENCHMARK_CACHE:-} ]]; then
    provision_command="MACCHERONI_BENCHMARK_CACHE=\"$cache_root\" $provision_command"
fi

# Progress goes to stderr so that --json keeps stdout to the doctor payload.
announce() {
    print -u2 -- "setup: $*"
}

for tool in uv shasum swift; do
    command -v "$tool" >/dev/null || {
        print -u2 -- "error: $tool is required"
        exit 69
    }
done

ensure_real_directory() {
    local directory=$1
    /usr/bin/python3 - "$cache_root" "$directory" <<'PY' || return 65
import os
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
try:
    target.relative_to(root)
except ValueError as error:
    raise SystemExit(f"refusing directory outside cache root: {target}") from error

current = pathlib.Path(target.anchor)
for component in target.parts[1:]:
    current /= component
    try:
        metadata = os.stat(current, follow_symlinks=False)
    except FileNotFoundError:
        try:
            os.mkdir(current, 0o700)
        except FileExistsError:
            metadata = os.stat(current, follow_symlinks=False)
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
                raise SystemExit(f"refusing symlinked or special cache path: {current}")
    else:
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            raise SystemExit(f"refusing symlinked or special cache path: {current}")
PY
}

validate_real_tree() {
    local directory=$1
    /usr/bin/python3 - "$directory" <<'PY' || return 65
import os
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1])
for current, directories, files in os.walk(root, topdown=True, followlinks=False):
    for name in (*directories, *files):
        entry = pathlib.Path(current) / name
        metadata = os.stat(entry, follow_symlinks=False)
        if stat.S_ISLNK(metadata.st_mode) or not (
            stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode)
        ):
            raise SystemExit(f"refusing symlinked or special cache entry: {entry}")
PY
}

validate_regular_file_or_absent() {
    local path=$1
    /usr/bin/python3 - "$path" <<'PY' || return 65
import os
import pathlib
import stat
import sys

path = pathlib.Path(sys.argv[1])
try:
    metadata = os.stat(path, follow_symlinks=False)
except FileNotFoundError:
    raise SystemExit(0)
if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
    raise SystemExit(f"refusing symlinked or special cache file: {path}")
PY
}

validate_external_writer_tree() {
    local directory=$1
    local policy=$2
    local trusted_python=${3:-}
    /usr/bin/python3 - "$directory" "$policy" "$trusted_python" \
        "$provision_command" <<'PY' || return 65
import datetime
import os
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1]).resolve(strict=True)
policy = sys.argv[2]
trusted_python_string = sys.argv[3]
provision_command = sys.argv[4]
if policy not in {"venv", "scratch"}:
    raise SystemExit(f"unknown external-writer tree policy: {policy}")


def stale_environment_report(relative, resolved, target_exists):
    """Report a venv an earlier provisioning run left pointing at its own Python.

    This is residue, not tampering, so it gets its own wording and a remedy
    that moves the directory aside. The script never removes it.
    """
    today = datetime.date.today().strftime("%Y%m%d")
    aside = root.with_name(f"{root.name}.stale-{today}")
    attempt = 2
    while aside.exists() or aside.is_symlink():
        aside = root.with_name(f"{root.name}.stale-{today}-{attempt}")
        attempt += 1
    target = resolved if target_exists else f"{resolved} (no longer present)"
    return "\n".join(
        [
            f"stale provisioning environment: {root}",
            f"  cause: its interpreter link {relative} points outside the cache tree, at",
            f"    {target}",
            "  a provisioning run that used a different Python leaves this behind. the",
            "  environment cannot be vouched for, so provisioning stops here rather",
            "  than reusing or repairing it.",
            "  remedy: move it aside and provision again. nothing is deleted, and the",
            "  moved copy stays readable if you want to inspect it.",
            f"    mv \"{root}\" \"{aside}\"",
            f"    {provision_command}",
        ]
    )


trusted_python = None
if trusted_python_string:
    try:
        trusted_python = pathlib.Path(trusted_python_string).resolve(strict=True)
        trusted_metadata = os.stat(trusted_python, follow_symlinks=False)
    except FileNotFoundError as error:
        raise SystemExit("trusted Python 3.12 interpreter is missing") from error
    if not stat.S_ISREG(trusted_metadata.st_mode) or not os.access(trusted_python, os.X_OK):
        raise SystemExit("trusted Python 3.12 interpreter is not a regular executable")

for current, directories, files in os.walk(root, topdown=True, followlinks=False):
    for name in (*directories, *files):
        entry = pathlib.Path(current) / name
        metadata = os.lstat(entry)
        if stat.S_ISLNK(metadata.st_mode):
            resolved = entry.resolve(strict=False)
            try:
                resolved.relative_to(root)
            except ValueError:
                relative = entry.relative_to(root)
                interpreter_link = (
                    policy == "venv"
                    and relative.parent == pathlib.Path("bin")
                    and relative.name in {"python", "python3", "python3.12"}
                )
                try:
                    target_metadata = os.stat(resolved, follow_symlinks=False)
                except FileNotFoundError:
                    target_metadata = None
                if not (
                    interpreter_link
                    and trusted_python is not None
                    and resolved == trusted_python
                    and target_metadata is not None
                    and stat.S_ISREG(target_metadata.st_mode)
                    and os.access(resolved, os.X_OK)
                ):
                    if interpreter_link:
                        raise SystemExit(
                            stale_environment_report(
                                relative, resolved, target_metadata is not None
                            )
                        )
                    raise SystemExit(
                        f"refusing external writer symlink outside cache tree: {entry}"
                    )
            continue
        if stat.S_ISREG(metadata.st_mode):
            if metadata.st_nlink != 1:
                raise SystemExit(
                    f"refusing multiply-linked external writer file: {entry}"
                )
            continue
        if not stat.S_ISDIR(metadata.st_mode):
            raise SystemExit(f"refusing special external writer entry: {entry}")
PY
}

validate_pinned_python() {
    local interpreter=$1
    /usr/bin/python3 - "$interpreter" "$uv_python_install" <<'PY' || return 65
import os
import pathlib
import stat
import sys

interpreter = pathlib.Path(sys.argv[1]).resolve(strict=True)
install_root = pathlib.Path(sys.argv[2]).resolve(strict=True)
try:
    interpreter.relative_to(install_root)
except ValueError as error:
    raise SystemExit("uv selected Python outside the guarded install root") from error
metadata = os.stat(interpreter, follow_symlinks=False)
if not stat.S_ISREG(metadata.st_mode) or not os.access(interpreter, os.X_OK):
    raise SystemExit("uv selected Python is not a regular executable")
PY
}

validate_hf_snapshot_tree() {
    local snapshot=$1
    local repository=$2
    /usr/bin/python3 - "$snapshot" "$repository" <<'PY' || return 65
import os
import pathlib
import stat
import sys

snapshot = pathlib.Path(sys.argv[1])
repository = pathlib.Path(sys.argv[2])
blobs = (repository / "blobs").resolve(strict=True)
for current, directories, files in os.walk(snapshot, topdown=True, followlinks=False):
    for name in directories:
        entry = pathlib.Path(current) / name
        metadata = os.stat(entry, follow_symlinks=False)
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            raise SystemExit(f"refusing unsafe Hugging Face snapshot directory: {entry}")
    for name in files:
        entry = pathlib.Path(current) / name
        metadata = os.stat(entry, follow_symlinks=False)
        if stat.S_ISREG(metadata.st_mode):
            continue
        if not stat.S_ISLNK(metadata.st_mode):
            raise SystemExit(f"refusing special Hugging Face snapshot entry: {entry}")
        try:
            target = entry.resolve(strict=True)
            target_metadata = os.stat(target, follow_symlinks=False)
        except (FileNotFoundError, RuntimeError):
            raise SystemExit(f"refusing unsafe Hugging Face snapshot link: {entry}")
        if target.parent != blobs or not stat.S_ISREG(target_metadata.st_mode):
            raise SystemExit(f"refusing unsafe Hugging Face snapshot link: {entry}")
PY
}

# Validate every known write-bearing directory before an external writer runs.
# Snapshot file symlinks remain valid because only their directory chain is
# hardened here.
write_directories=(
    "$cache_root"
    "$cache_root/venvs"
    "$cache_root/venvs/mlx-audio"
    "$cache_root/models"
    "$hf_home"
    "$hf_cache"
    "$hf_cache/.locks"
    "$cache_root/tools"
    "$cache_root/build"
    "$uv_cache"
    "$uv_python_install"
    "$runtime_scratch"
    "$cache_root/qwen3-speech"
    "$cache_root/qwen3-speech/models"
    "$speech_models"
)
for repository in "$vibe_repository" "$tokenizer_repository" \
    "$community_repository" "$vad_repository"; do
    write_directories+=(
        "$repository"
        "$repository/blobs"
        "$repository/refs"
        "$repository/snapshots"
        "$repository/trees"
        "$repository/.no_exist"
        "$hf_cache/.locks/${repository:t}"
    )
done
write_directories+=(
    "$vibe_repository/snapshots/$vibe_revision"
    "$tokenizer_repository/snapshots/$tokenizer_revision"
    "$community_repository/snapshots/$community_revision"
    "$vad_repository/snapshots/$vad_revision"
    "$vibe_repository/.no_exist/$vibe_revision"
    "$tokenizer_repository/.no_exist/$tokenizer_revision"
    "$community_repository/.no_exist/$community_revision"
    "$vad_repository/.no_exist/$vad_revision"
    "$community_model"
    "$community_model/.cache"
    "$community_model/.cache/huggingface"
    "$community_model/embedding.mlmodelc"
    "$community_model/embedding.mlmodelc/analytics"
    "$community_model/embedding.mlmodelc/weights"
    "$community_model/segmentation.mlmodelc"
    "$community_model/segmentation.mlmodelc/analytics"
    "$community_model/segmentation.mlmodelc/weights"
    "$vad_model"
    "$vad_model/.cache"
    "$vad_model/.cache/huggingface"
    "$vad_model/silero_vad.mlmodelc"
    "$vad_model/silero_vad.mlmodelc/analytics"
    "$vad_model/silero_vad.mlmodelc/weights"
)
for directory in "${write_directories[@]}"; do
    ensure_real_directory "$directory"
done
validate_regular_file_or_absent "$hf_cache/CACHEDIR.TAG"
for repository in "$vibe_repository" "$tokenizer_repository" \
    "$community_repository" "$vad_repository"; do
    validate_real_tree "$repository/blobs"
    validate_real_tree "$repository/refs"
    validate_real_tree "$repository/trees"
    validate_real_tree "$repository/.no_exist"
    validate_real_tree "$hf_cache/.locks/${repository:t}"
done
validate_hf_snapshot_tree \
    "$vibe_repository/snapshots/$vibe_revision" "$vibe_repository"
validate_hf_snapshot_tree \
    "$tokenizer_repository/snapshots/$tokenizer_revision" "$tokenizer_repository"
validate_hf_snapshot_tree \
    "$community_repository/snapshots/$community_revision" "$community_repository"
validate_hf_snapshot_tree \
    "$vad_repository/snapshots/$vad_revision" "$vad_repository"
validate_real_tree "$community_model"
validate_real_tree "$vad_model"
for directory in "$runtime_tool_root" "$runtime_bin_dir"; do
    if [[ -e "$directory" || -L "$directory" ]]; then
        ensure_real_directory "$directory"
    fi
done
validate_external_writer_tree "$uv_cache" scratch
validate_external_writer_tree "$uv_python_install" scratch
validate_external_writer_tree "$runtime_scratch" scratch
uv_tool=$(command -v uv)
run_uv() {
    env -u UV_CONFIG_FILE -u UV_MANAGED_PYTHON -u UV_NO_MANAGED_PYTHON \
        -u UV_OFFLINE -u UV_PYTHON -u UV_PYTHON_DOWNLOADS \
        -u UV_PYTHON_INSTALL_BIN -u UV_PYTHON_INSTALL_DIR \
        -u UV_SYSTEM_PYTHON UV_CACHE_DIR="$uv_cache" \
        UV_LINK_MODE=copy UV_PYTHON_INSTALL_DIR="$uv_python_install" \
        "$uv_tool" "$@"
}
run_uv python install --no-config --no-bin --no-registry \
    --install-dir "$uv_python_install" --cache-dir "$uv_cache" 3.12.13
validate_external_writer_tree "$uv_python_install" scratch
trusted_python=$(run_uv python find --no-config --managed-python \
    --no-python-downloads 3.12.13)
[[ -n ${trusted_python//[[:space:]]/} ]] || {
    print -u2 -- 'error: uv did not resolve the pinned Python 3.12.13 interpreter'
    exit 69
}
validate_pinned_python "$trusted_python"
validate_external_writer_tree \
    "$cache_root/venvs/mlx-audio" venv "$trusted_python"

UV_PROJECT_ENVIRONMENT="$cache_root/venvs/mlx-audio" \
    run_uv sync --no-config --frozen --inexact --project "$python_project" \
        --python "$trusted_python" --no-python-downloads
validate_external_writer_tree "$uv_python_install" scratch
validate_external_writer_tree \
    "$cache_root/venvs/mlx-audio" venv "$trusted_python"
hf_tool="$cache_root/venvs/mlx-audio/bin/hf"
[[ -x "$hf_tool" ]] || {
    print -u2 -- "error: pinned ASR environment did not install the hf CLI: $hf_tool"
    exit 69
}

verify_runtime_source() {
    local source_path=$1
    local expected=$2
    [[ -f "$source_path" && ! -L "$source_path" \
       && $(shasum -a 256 "$source_path" | awk '{print $1}') == "$expected" ]] || {
        print -u2 -- "error: offline speech runtime source differs from its pin: $source_path"
        exit 65
    }
}
verify_runtime_source "$runtime_package" "$runtime_package_digest"
verify_runtime_source "$runtime_resolved" "$runtime_resolved_digest"
verify_runtime_source "$runtime_main" "$runtime_main_digest"

verify_installed_runtime() {
    local binary=$1
    local sidecar=$2
    /usr/bin/python3 - "$binary" "$sidecar" \
        "$speech_revision" "$runtime_package_digest" \
        "$runtime_resolved_digest" "$runtime_main_digest" <<'PY'
import hashlib
import json
import pathlib
import sys

binary_string, sidecar_string, speech_revision, package_sha256, resolved_sha256, source_sha256 = sys.argv[1:]
binary = pathlib.Path(binary_string)
sidecar = pathlib.Path(sidecar_string)
if not binary.is_file() or binary.is_symlink() or not sidecar.is_file() or sidecar.is_symlink():
    raise SystemExit("offline speech runtime installation is incomplete or unsafe")
executable_sha256 = hashlib.sha256(binary.read_bytes()).hexdigest()
try:
    payload = json.loads(sidecar.read_text(encoding="utf-8"))
except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
    raise SystemExit("offline speech runtime provenance is unreadable") from error
expected = {
    "contract_version": "offline-speech-runtime-v1",
    "speech_revision": speech_revision,
    "package_manifest_sha256": package_sha256,
    "package_resolved_sha256": resolved_sha256,
    "harness_source_sha256": source_sha256,
    "executable_sha256": executable_sha256,
}
if set(payload) != {*expected, "swift_version"}:
    raise SystemExit("offline speech runtime provenance fields differ from the contract")
if any(payload.get(key) != value for key, value in expected.items()):
    raise SystemExit("offline speech runtime provenance differs from installed inputs")
if not isinstance(payload.get("swift_version"), str) or not payload["swift_version"].strip():
    raise SystemExit("offline speech runtime provenance lacks a Swift version")
PY
    [[ -x "$binary" ]] || {
        print -u2 -- 'error: offline speech runtime is not executable'
        exit 65
    }
}

if [[ -e "$runtime_tool_root" ]]; then
    [[ -d "$runtime_tool_root" && ! -L "$runtime_tool_root" ]] || {
        print -u2 -- "error: refusing unsafe offline speech runtime path: $runtime_tool_root"
        exit 65
    }
    announce 'offline speech runtime is already installed in this cache; verifying it instead of rebuilding'
    verify_installed_runtime "$runtime_binary" "$runtime_sidecar"
else
    announce 'offline speech runtime is not installed in this cache'
    announce 'it is compiled from source, not downloaded: swift build walks the whole pinned speech dependency tree'
    announce 'on a first provisioning this step takes tens of minutes and prints hundreds of compile lines; that is progress, not a hang'
    announce 'build stage 1 of 4: validating the build scratch tree'
    validate_external_writer_tree "$runtime_scratch" scratch
    announce 'build stage 2 of 4: compiling maccheroni-offline-speech-runtime in release configuration (swift build output follows)'
    swift build --package-path "$runtime_source" \
        --scratch-path "$runtime_scratch" --disable-automatic-resolution \
        --disable-dependency-cache -c release \
        --product maccheroni-offline-speech-runtime 1>&2
    announce 'build stage 3 of 4: checking the built executable against the pinned sources'
    runtime_build_bin=$(swift build --package-path "$runtime_source" \
        --scratch-path "$runtime_scratch" --disable-automatic-resolution \
        --disable-dependency-cache -c release --show-bin-path)
    built_runtime="$runtime_build_bin/maccheroni-offline-speech-runtime"
    [[ -f "$built_runtime" && ! -L "$built_runtime" && -x "$built_runtime" ]] || {
        print -u2 -- 'error: offline speech runtime build did not produce its executable'
        exit 70
    }
    verify_runtime_source "$runtime_package" "$runtime_package_digest"
    verify_runtime_source "$runtime_resolved" "$runtime_resolved_digest"
    verify_runtime_source "$runtime_main" "$runtime_main_digest"
    swift_version=$(swift --version)
    [[ -n ${swift_version//[[:space:]]/} ]] || {
        print -u2 -- 'error: Swift version is empty'
        exit 70
    }

    announce 'build stage 4 of 4: installing the runtime and recording its provenance'
    temporary_install=$(mktemp -d "$cache_root/tools/.offline-speech-runtime.XXXXXX")
    temporary_bin="$temporary_install/bin"
    temporary_runtime="$temporary_bin/maccheroni-offline-speech-runtime"
    temporary_sidecar="$temporary_install/provenance.json"
    mkdir "$temporary_bin"
    cp "$built_runtime" "$temporary_runtime"
    chmod 700 "$temporary_runtime"
    runtime_executable_digest=$(shasum -a 256 "$temporary_runtime" | awk '{print $1}')
    /usr/bin/python3 - "$temporary_sidecar" "$speech_revision" \
        "$runtime_package_digest" "$runtime_resolved_digest" \
        "$runtime_main_digest" "$runtime_executable_digest" \
        "$swift_version" <<'PY'
import json
import pathlib
import sys

path, speech_revision, package_sha256, resolved_sha256, source_sha256, executable_sha256, swift_version = sys.argv[1:]
payload = {
    "contract_version": "offline-speech-runtime-v1",
    "speech_revision": speech_revision,
    "package_manifest_sha256": package_sha256,
    "package_resolved_sha256": resolved_sha256,
    "harness_source_sha256": source_sha256,
    "executable_sha256": executable_sha256,
    "swift_version": swift_version,
}
pathlib.Path(path).write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
    verify_installed_runtime "$temporary_runtime" "$temporary_sidecar"
    /usr/bin/python3 - "$temporary_install" "$runtime_tool_root" <<'PY'
import ctypes
import errno
import os
import sys

source, destination = (os.fsencode(value) for value in sys.argv[1:])
libc = ctypes.CDLL(None, use_errno=True)
rename_exclusive = libc.renamex_np
rename_exclusive.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
rename_exclusive.restype = ctypes.c_int
if rename_exclusive(source, destination, 0x00000004) != 0:
    error = ctypes.get_errno()
    if error in (errno.EEXIST, errno.ENOTEMPTY):
        raise SystemExit("refusing to replace existing offline speech runtime")
    raise OSError(error, os.strerror(error), os.fsdecode(destination))
PY
    temporary_install=''
    verify_installed_runtime "$runtime_binary" "$runtime_sidecar"
    announce 'offline speech runtime build finished'
fi

"$hf_tool" download "$vibe_id" --revision "$vibe_revision" --cache-dir "$hf_cache" --quiet >/dev/null
"$hf_tool" download "$tokenizer_id" \
    config.json tokenizer.json tokenizer_config.json merges.txt vocab.json \
    --revision "$tokenizer_revision" --cache-dir "$hf_cache" --quiet >/dev/null
"$hf_tool" download "$community_id" --revision "$community_revision" \
    --cache-dir "$hf_cache" --quiet >/dev/null
"$hf_tool" download "$vad_id" --revision "$vad_revision" \
    --cache-dir "$hf_cache" --quiet >/dev/null

"$hf_tool" cache verify "$vibe_id" --revision "$vibe_revision" \
    --cache-dir "$hf_cache" --fail-on-missing-files --quiet >/dev/null
if ! "$hf_tool" cache verify "$tokenizer_id" --revision "$tokenizer_revision" \
    --cache-dir "$hf_cache" --quiet >/dev/null 2>/dev/null; then
    print -u2 -- 'error: Qwen tokenizer payload checksum verification failed'
    exit 65
fi
"$hf_tool" cache verify "$community_id" --revision "$community_revision" \
    --cache-dir "$hf_cache" --fail-on-missing-files --quiet >/dev/null
"$hf_tool" cache verify "$vad_id" --revision "$vad_revision" \
    --cache-dir "$hf_cache" --fail-on-missing-files --quiet >/dev/null

"$hf_tool" download "$community_id" --revision "$community_revision" \
    --local-dir "$speech_models/Pyannote-Community-1-CoreML" --quiet >/dev/null
"$hf_tool" download "$vad_id" --revision "$vad_revision" \
    --local-dir "$speech_models/Silero-VAD-v6.2.1-CoreML" --quiet >/dev/null

verify_ref() {
    local model_id=$1
    local expected=$2
    local repository="$hf_cache/models--${model_id//\//--}"
    local reference="$repository/refs/main"
    [[ -f "$reference" && ! -L "$reference" \
       && $(stat -f %z "$reference") == 40 \
       && $(<"$reference") == "$expected" ]] || {
        print -u2 -- "error: $model_id main ref does not equal pinned revision $expected"
        exit 65
    }
}

install_ref() {
    local model_id=$1
    local expected=$2
    local repository="$hf_cache/models--${model_id//\//--}"
    local reference="$repository/refs/main"
    "$cache_root/venvs/mlx-audio/bin/python" - "$model_id" "$expected" \
        "$reference" <<'PY'
import os
import pathlib
import sys
import tempfile

model_id, expected, reference_string = sys.argv[1:]
reference = pathlib.Path(reference_string)
encoded = expected.encode("ascii")
if len(encoded) != 40:
    raise SystemExit(f"invalid pinned revision for {model_id}: expected 40 ASCII bytes")
if reference.is_symlink():
    raise SystemExit(f"refusing symlinked ref: {reference}")
if reference.exists():
    if reference.read_bytes() != encoded:
        raise SystemExit(f"refusing to rewrite mismatched ref: {reference}")
    raise SystemExit(0)
reference.parent.mkdir(parents=True, exist_ok=True)
if reference.parent.is_symlink():
    raise SystemExit(f"refusing symlinked ref directory: {reference.parent}")
descriptor, temporary = tempfile.mkstemp(prefix=".main.", dir=reference.parent)
try:
    with os.fdopen(descriptor, "wb") as destination:
        destination.write(encoded)
    try:
        os.link(temporary, reference)
    except FileExistsError:
        if reference.is_symlink() or reference.read_bytes() != encoded:
            raise SystemExit(f"refusing to rewrite mismatched ref: {reference}")
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

install_ref "$tokenizer_id" "$tokenizer_revision"
install_ref "$community_id" "$community_revision"
install_ref "$vad_id" "$vad_revision"
verify_ref "$tokenizer_id" "$tokenizer_revision"
verify_ref "$community_id" "$community_revision"
verify_ref "$vad_id" "$vad_revision"

vibe_snapshot="$vibe_repository/snapshots/$vibe_revision"
vibe_tree="$vibe_repository/trees/$vibe_revision.json"
tokenizer_snapshot="$hf_cache/models--Qwen--Qwen2.5-7B/snapshots/$tokenizer_revision"
for required in config.json model.safetensors.index.json \
    model-00001-of-00002.safetensors model-00002-of-00002.safetensors; do
    [[ -f "$vibe_snapshot/$required" ]] || {
        print -u2 -- "error: VibeVoice snapshot is incomplete: $required"
        exit 66
    }
done
[[ -f "$vibe_tree" ]] || {
    print -u2 -- 'error: VibeVoice Hub tree metadata is missing'
    exit 66
}
for required in config.json tokenizer.json tokenizer_config.json merges.txt vocab.json; do
    [[ -f "$tokenizer_snapshot/$required" ]] || {
        print -u2 -- "error: Qwen tokenizer snapshot is incomplete: $required"
        exit 66
    }
done
"$cache_root/venvs/mlx-audio/bin/python" - "$tokenizer_snapshot" <<'PY'
import pathlib
import sys

snapshot = pathlib.Path(sys.argv[1])
expected = {"config.json", "tokenizer.json", "tokenizer_config.json", "merges.txt", "vocab.json"}
entries = {entry.name for entry in snapshot.iterdir()}
if not expected.issubset(entries):
    raise SystemExit(f"Qwen tokenizer snapshot is missing entries: {sorted(expected - entries)!r}")
resolved = {(snapshot / name).resolve(strict=True) for name in expected}
repository = snapshot.parent.parent
blobs = {entry.resolve() for entry in (repository / "blobs").iterdir() if entry.is_file()}
if not resolved.issubset(blobs):
    raise SystemExit("Qwen tokenizer payload does not resolve inside the selected repository blobs")
PY

"$cache_root/venvs/mlx-audio/bin/python" \
    "$repo_root/scripts/verify-speech-model-closure.py" "$speech_models"

swift build --package-path "$repo_root" --product maccheroni 1>&2
cli="$repo_root/.build/debug/maccheroni"
[[ -x "$cli" ]] || {
    print -u2 -- "error: maccheroni build did not produce the doctor executable: $cli"
    exit 70
}
if [[ $json == true ]]; then
    MACCHERONI_BENCHMARK_CACHE="$cache_root" MACCHERONI_HF_HOME="$hf_home" \
        "$cli" doctor --profile ko-meeting --json
else
    MACCHERONI_BENCHMARK_CACHE="$cache_root" MACCHERONI_HF_HOME="$hf_home" \
        "$cli" doctor --profile ko-meeting
fi
