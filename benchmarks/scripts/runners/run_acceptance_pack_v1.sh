#!/usr/bin/env bash
# Run or reuse one acceptance-pack source run, then create a separate immutable evaluation.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
checker="$repo_root/benchmarks/scripts/scoring/check_acceptance_evaluation.py"
checker_project="$repo_root/benchmarks/env/dicow-reference"
acceptance_root="${MACCHERONI_ACCEPTANCE_ROOT:-$repo_root/benchmarks/samples/public/acceptance-pack-v1}"

if [[ -n "${MACCHERONI_ACCEPTANCE_TESTING:-}" || -n "${MACCHERONI_ACCEPTANCE_TEST_PACK_MANIFEST:-}" || -n "${MACCHERONI_ACCEPTANCE_PYTHON:-}" ]]; then
  echo "error: acceptance test-mode environment is forbidden" >&2
  exit 2
fi

usage() {
  cat >&2 <<'EOF'
usage: run_acceptance_pack_v1.sh FIXTURE_ID KIND OUTPUT_ROOT [options]

FIXTURE_ID and KIND must be one of:
  hike-code-switch-v1 acceptance-asr
  ami-in1009-ihm-mix-v1 acceptance-full

options:
  --source-run PATH       score an existing immutable product run; start no model
  --evaluation-id ID      select the create-only evaluation directory name
  --fixture-root PATH     override the prepared fixture directory
  --input PATH            override the fixture input path
  --cli PATH              use this built maccheroni executable
  --dry-run               verify fixture inputs and print the selected contract only
EOF
  exit 2
}

(( $# >= 3 )) || usage
fixture_id=$1
kind=$2
output_root=$3
shift 3

source_run=""
evaluation_id=""
fixture_root=""
input_path=""
cli="${MACCHERONI_CLI:-$repo_root/.build/debug/maccheroni}"
dry_run=0
while (( $# )); do
  case "$1" in
    --source-run)
      (( $# >= 2 )) || usage
      source_run=$2
      shift 2
      ;;
    --evaluation-id)
      (( $# >= 2 )) || usage
      evaluation_id=$2
      shift 2
      ;;
    --fixture-root)
      (( $# >= 2 )) || usage
      fixture_root=$2
      shift 2
      ;;
    --input)
      (( $# >= 2 )) || usage
      input_path=$2
      shift 2
      ;;
    --cli)
      (( $# >= 2 )) || usage
      cli=$2
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    *) usage ;;
  esac
done

case "$fixture_id:$kind" in
  hike-code-switch-v1:acceptance-asr)
    fixture_root="${fixture_root:-$acceptance_root/prepared/hike-code-switch-v1}"
    input_path="${input_path:-$fixture_root/input.wav}"
    ;;
  ami-in1009-ihm-mix-v1:acceptance-full)
    fixture_root="${fixture_root:-$acceptance_root/prepared/ami-in1009-ihm-mix-v1}"
    input_path="${input_path:-$acceptance_root/sources/ami/IN1009.Mix-Headset.wav}"
    ;;
  *)
    echo "error: fixture ID and evaluation kind are not a valid acceptance-pack pair" >&2
    exit 2
    ;;
esac

[[ -f "$fixture_root/fixture-check.json" && -f "$fixture_root/glossary.txt" ]] || {
  echo "error: prepared fixture is missing: $fixture_id" >&2
  exit 2
}
[[ -f "$input_path" ]] || {
  echo "error: fixture input is missing: $fixture_id" >&2
  exit 2
}

checker_command=(uv run --project "$checker_project" python "$checker")

if ! preflight_output="$("${checker_command[@]}" preflight \
    --fixture-id "$fixture_id" \
    --kind "$kind" \
    --fixture-root "$fixture_root" \
    --input "$input_path" 2>/dev/null)"; then
  echo "error: acceptance fixture preflight failed" >&2
  exit 1
fi
printf '%s\n' "$preflight_output"

if (( dry_run )); then
  exit 0
fi

if [[ -z "$evaluation_id" ]]; then
  git_head="$(git -C "$repo_root" rev-parse --short=8 HEAD)"
  evaluation_id="acceptance-$(date -u +%Y%m%dT%H%M%SZ)-${git_head}-$RANDOM"
fi
[[ "$evaluation_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || {
  echo "error: evaluation ID must match the manifest-safe 1-128 character form" >&2
  exit 2
}
evaluation_output="$output_root/evaluations/$evaluation_id"
[[ ! -L "$output_root" ]] || {
  echo "error: output root must not be a symlink" >&2
  exit 2
}
[[ ! -e "$evaluation_output" && ! -L "$evaluation_output" ]] || {
  echo "error: create-only evaluation ID already exists" >&2
  exit 2
}

if [[ -z "$source_run" ]]; then
  [[ "${MACCHERONI_ACCEPTANCE_MODEL_RUN:-}" == "1" ]] || {
    echo "error: set MACCHERONI_ACCEPTANCE_MODEL_RUN=1 only after confirming no other model process is active" >&2
    exit 2
  }
  [[ -n "${MACCHERONI_BENCHMARK_CACHE:-}" ]] || {
    echo "error: MACCHERONI_BENCHMARK_CACHE must select the provisioned ko-meeting cache" >&2
    exit 2
  }
  [[ -x "$cli" ]] || {
    echo "error: maccheroni executable is missing" >&2
    exit 2
  }
  if pgrep -f 'mlx_audio|maccheroni_asr_runner.py|maccheroni-offline-speech-runtime.*(diarize|vad)' >/dev/null 2>&1; then
    echo "error: another local model process is active" >&2
    exit 2
  fi
  memory_bytes="$(sysctl -n hw.memsize)"
  if ! "${checker_command[@]}" memory-check --bytes "$memory_bytes" >/dev/null 2>&1; then
    echo "error: refuses acceptance model run below 36 GiB physical memory" >&2
    exit 2
  fi
  lock_path="${TMPDIR:-/private/tmp}/maccheroni-acceptance-pack-v1.lock"
  if ! mkdir "$lock_path" 2>/dev/null; then
    echo "error: another acceptance model run holds the exclusive lock" >&2
    exit 2
  fi
  doctor_log=""
  before_inventory=""
  after_inventory=""
  run_json=""
  cleanup_model_run() {
    [[ -z "$doctor_log" ]] || rm -f -- "$doctor_log"
    [[ -z "$before_inventory" ]] || rm -f -- "$before_inventory"
    [[ -z "$after_inventory" ]] || rm -f -- "$after_inventory"
    [[ -z "$run_json" ]] || rm -f -- "$run_json"
    rmdir "$lock_path" 2>/dev/null || true
  }
  trap cleanup_model_run EXIT

  doctor_log="$(mktemp "${TMPDIR:-/private/tmp}/maccheroni-acceptance-doctor.XXXXXX")"
  if ! "$cli" doctor --profile ko-meeting --json >"$doctor_log" 2>&1; then
    echo "error: ko-meeting profile doctor did not report ready" >&2
    exit 1
  fi
  runs_root="$output_root/source-runs"
  mkdir -p "$runs_root"
  before_inventory="$(mktemp "${TMPDIR:-/private/tmp}/maccheroni-acceptance-before.XXXXXX")"
  after_inventory="$(mktemp "${TMPDIR:-/private/tmp}/maccheroni-acceptance-after.XXXXXX")"
  run_json="$(mktemp "${TMPDIR:-/private/tmp}/maccheroni-acceptance-run.XXXXXX")"
  find "$runs_root" -mindepth 1 -maxdepth 1 -type d -print | LC_ALL=C sort >"$before_inventory"
  if ! "$cli" run "$input_path" \
      --profile ko-meeting \
      --glossary "$fixture_root/glossary.txt" \
      --output-root "$runs_root" \
      --json >"$run_json" 2>&1; then
    echo "error: acceptance product run failed" >&2
    exit 1
  fi
  find "$runs_root" -mindepth 1 -maxdepth 1 -type d -print | LC_ALL=C sort >"$after_inventory"
  source_run="$(comm -13 "$before_inventory" "$after_inventory")"
  [[ -n "$source_run" && "$(printf '%s\n' "$source_run" | wc -l | tr -d ' ')" == "1" ]] || {
    echo "error: product run did not create exactly one direct-child source run" >&2
    exit 1
  }
  if ! printed_run="$(/usr/bin/python3 - "$run_json" 2>/dev/null <<'PY'
import json
from pathlib import Path
import sys

document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
path = document.get("run_path") if isinstance(document, dict) else None
if not isinstance(path, str) or not path:
    raise SystemExit("product JSON has no run_path")
print(Path(path).resolve())
PY
)"; then
    echo "error: product JSON did not provide a valid run path" >&2
    exit 1
  fi
  [[ "$printed_run" == "$(cd "$source_run" && pwd -P)" && "$(dirname "$printed_run")" == "$(cd "$runs_root" && pwd -P)" ]] || {
    echo "error: product JSON run_path is not the unique direct-child source run" >&2
    exit 1
  }
fi

if ! create_output="$("${checker_command[@]}" create \
    --evaluation-id "$evaluation_id" \
    --fixture-id "$fixture_id" \
    --kind "$kind" \
    --fixture-root "$fixture_root" \
    --input "$input_path" \
    --source-run "$source_run" \
    --output "$evaluation_output" 2>/dev/null)"; then
  echo "error: acceptance evaluation creation failed" >&2
  exit 1
fi
printf '%s\n' "$create_output"

if ! "${checker_command[@]}" verify \
    --fixture-root "$fixture_root" \
    --input "$input_path" \
    --source-run "$source_run" \
    --output "$evaluation_output" >/dev/null 2>&1; then
  echo "error: published acceptance evaluation verification failed" >&2
  exit 1
fi
