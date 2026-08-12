#!/usr/bin/env bash
# Download the pinned public sources for Korean-English acceptance pack v1.
# Sources and derived fixtures stay under an ignored destination. This script
# never replaces an existing source: it re-verifies it on every invocation.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
destination="${1:-"$repo_root/benchmarks/samples/public/acceptance-pack-v1"}"
manifest="$repo_root/benchmarks/datasets/acceptance-pack-v1.json"

command -v hf >/dev/null || {
  echo "error: Hugging Face CLI (hf) is required for the public HiKE source" >&2
  exit 1
}
command -v curl >/dev/null || {
  echo "error: curl is required for the public AMI sources" >&2
  exit 1
}
command -v shasum >/dev/null || {
  echo "error: shasum is required for source verification" >&2
  exit 1
}

source_hash() {
  shasum -a 256 "$1" | awk '{print $1}'
}

verify_file() {
  local path="$1"
  local expected_size="$2"
  local expected_hash="$3"
  if [[ ! -f "$path" ]]; then
    return 1
  fi
  local actual_size actual_hash
  actual_size="$(stat -f '%z' "$path")"
  actual_hash="$(source_hash "$path")"
  if [[ "$actual_size" != "$expected_size" || "$actual_hash" != "$expected_hash" ]]; then
    echo "error: existing source does not match the pinned manifest: $path" >&2
    echo "expected size/hash: $expected_size $expected_hash" >&2
    echo "actual size/hash:   $actual_size $actual_hash" >&2
    exit 1
  fi
  echo "reverified: $path"
  return 0
}

download_ami() {
  local url="$1"
  local target="$2"
  local expected_size="$3"
  local expected_hash="$4"
  local http_mode="$5"
  if verify_file "$target" "$expected_size" "$expected_hash"; then
    return
  fi
  mkdir -p "$(dirname "$target")"
  local temporary
  temporary="$(mktemp "${target}.part.XXXXXX")"
  trap 'rm -f "$temporary"' RETURN
  # AMI's old Apache mirror sometimes serves the large audio and annotation
  # archive through different HTTP versions. No account or credential is used.
  curl --fail --location --silent --show-error --retry 3 --retry-all-errors \
    "$http_mode" --output "$temporary" "$url"
  local actual_size actual_hash
  actual_size="$(stat -f '%z' "$temporary")"
  actual_hash="$(source_hash "$temporary")"
  if [[ "$actual_size" != "$expected_size" || "$actual_hash" != "$expected_hash" ]]; then
    echo "error: downloaded AMI source failed pinned size/hash verification: $url" >&2
    exit 1
  fi
  if [[ -e "$target" || -L "$target" ]]; then
    echo "error: refusing to replace source that appeared during download: $target" >&2
    exit 1
  fi
  mv "$temporary" "$target"
  trap - RETURN
  echo "downloaded and verified: $target"
}

mkdir -p "$destination/sources/hike" "$destination/sources/ami"

hike_path="$destination/sources/hike/data/test-00000-of-00001.parquet"
if ! verify_file "$hike_path" 235089121 cc807d5e31c92df85a46445b28df2b239f7fb33943a35502161af61c1ee8b4d0; then
  hf download thetaone-ai/HiKE data/test-00000-of-00001.parquet \
    --repo-type dataset \
    --revision 255609b24005e1fcce3f8b3a452260aaf2872cc9 \
    --local-dir "$destination/sources/hike"
  verify_file "$hike_path" 235089121 cc807d5e31c92df85a46445b28df2b239f7fb33943a35502161af61c1ee8b4d0
fi

download_ami \
  "https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/IN1009/audio/IN1009.Mix-Headset.wav" \
  "$destination/sources/ami/IN1009.Mix-Headset.wav" \
  40203138 \
  7ee90aac9105734ab40d3085dcb4d0ad4ba06adc1c24facb2ad843529b489506 \
  --http1.1
download_ami \
  "https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip" \
  "$destination/sources/ami/ami_public_manual_1.6.2.zip" \
  22887865 \
  b56e5babb2496b8795deeeda7e71178d7fbc9963f94276cf2a3f4b56ebbc9f9d \
  --http1.0

echo "PASS: all public acceptance-pack v1 sources match $manifest"
