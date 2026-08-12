#!/usr/bin/env bash
# Run one short HiKE acceptance excerpt through the real ko-meeting profile.
# It never starts more than one model process and requires explicit operator
# confirmation because the VibeVoice profile has measured above 17 GiB peak RAM.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fixture_root="${1:-"$repo_root/benchmarks/samples/public/acceptance-pack-v1/prepared/hike-code-switch-v1"}"
output_root="${2:-"$repo_root/benchmarks/runs/acceptance-hike-smoke"}"
lock_path="${TMPDIR:-/private/tmp}/maccheroni-acceptance-hike-smoke.lock"

[[ "${MACCHERONI_ACCEPTANCE_SMOKE:-}" == "1" ]] || {
  echo "error: set MACCHERONI_ACCEPTANCE_SMOKE=1 only after confirming no other model process is running" >&2
  exit 2
}
[[ -f "$fixture_root/items/00.wav" && -f "$fixture_root/glossary.txt" ]] || {
  echo "error: prepared HiKE fixture is missing; run prepare-acceptance-pack-v1.py first" >&2
  exit 2
}

memory_bytes="$(sysctl -n hw.memsize)"
minimum_bytes=$((36 * 1024 * 1024 * 1024))
(( memory_bytes >= minimum_bytes )) || {
  echo "error: refuses ko-meeting smoke below 36 GiB physical memory" >&2
  exit 2
}

if ! mkdir "$lock_path" 2>/dev/null; then
  echo "error: another acceptance HiKE smoke already holds $lock_path" >&2
  exit 2
fi
trap 'rmdir "$lock_path"' EXIT

cd "$repo_root"
swift run maccheroni doctor --profile ko-meeting --json

# The CLI creates a fresh run directory below this ignored root. It receives a
# single 7-second public excerpt and one glossary only; it never runs a matrix.
swift run maccheroni run "$fixture_root/items/00.wav" \
  --profile ko-meeting \
  --glossary "$fixture_root/glossary.txt" \
  --output-root "$output_root" \
  --json
