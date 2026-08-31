#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h:h}"
command_name="${1:-}"
shift || true

case "$command_name" in
  build)
    if [[ "${1:-}" != "--env-file" || -z "${2:-}" || $# -ne 2 ]]; then
      print -u2 'usage: build-overlap-pack-v1.zsh build --env-file /absolute/path'
      exit 2
    fi
    exec python3 "$repo_root/benchmarks/scripts/dicow/run_with_env.py" \
      --env-file "$2" --profile reference -- \
      zsh -euc 'uv run --locked --project benchmarks/env/dicow-reference python benchmarks/datasets/prepare-overlap-pack-v1.py build --env-file "$1"' -- "$2"
    ;;
  verify)
    if [[ "${1:-}" != "--env-file" || -z "${2:-}" || $# -ne 2 ]]; then
      print -u2 'usage: build-overlap-pack-v1.zsh verify --env-file /absolute/path'
      exit 2
    fi
    exec python3 "$repo_root/benchmarks/scripts/dicow/run_with_env.py" \
      --env-file "$2" --profile reference -- \
      zsh -euc 'env HF_HUB_OFFLINE=1 uv run --locked --project benchmarks/env/dicow-reference python benchmarks/datasets/verify-overlap-pack-v1.py --pack "$DICOW_PACK_ROOT"'
    ;;
  *)
    print -u2 'usage: build-overlap-pack-v1.zsh {build|verify} --env-file /absolute/path'
    exit 2
    ;;
esac
