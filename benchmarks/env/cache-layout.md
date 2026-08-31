# Benchmark cache layout

The repository stores only configuration, wrappers, and lock files. Models,
virtual environments, generated smoke audio, FluidAudio source, and smoke
outputs are untracked local state.

Set `MACCHERONI_BENCHMARK_CACHE` to relocate the primary cache. The configured
default is:

```text
~/Library/Caches/Maccheroni/benchmarks/
  build/uv-cache/            cache-local uv download and wheel cache
  build/uv-python/           uv-managed CPython 3.12.13 installation
  build/offline-speech-runtime/ guarded SwiftPM checkout and build scratch
  venvs/mlx-audio/          uv environment (Python 3.12)
  tools/offline-speech-runtime/
    bin/maccheroni-offline-speech-runtime
    provenance.json         binary hash, tracked inputs, and dependency pin
  models/huggingface/       HF_HOME for mlx-audio and pinned snapshots
  qwen3-speech/models/aufklarer/
    Silero-VAD-v6.2.1-CoreML/
    Pyannote-Community-1-CoreML/
  smoke/                    generated synthetic 10-second WAV and outputs
  fluid-audio-source/       pinned FluidAudio source and SwiftPM build product
  models/fluid-audio/       exact HF snapshots used by FluidAudio runners
  sources/speech-swift/     speech-swift source at the MOSS harness revision
  swift-scratch/moss-harness/ SwiftPM checkout and build product for MOSS
  swift-scratch/fluid-diarization-harness/ SwiftPM checkout and build product
  swift-scratch/parakeet-benchmark-harness/ exact TDT + CTC benchmark product
```

Provision the shipped Korean profile into this complete cache with:

```zsh
MACCHERONI_BENCHMARK_CACHE="$cache_root" \
  zsh scripts/setup-transcription-runtime.zsh --profile ko-meeting --json
```

The command downloads exact revisions from their pinned repositories. It never
copies model data from another cache. Re-running verifies existing pinned
bytes and refuses mismatched immutable metadata. It installs CPython 3.12.13
under the selected cache, keeps uv downloads in that cache, and disables
SwiftPM's global dependency cache while building the offline harness. Existing
writer trees are checked before external tools run. The `ko-meeting` runtime
executes a small harness built from speech-swift `v0.0.23` commit
`c1aa219bc2284239ff6917d675a3e1978c840260` and the repository's tracked
`scripts/runners/offline-speech-runtime/Package.resolved`. It passes the local
Silero and Community-1 directories directly to speech-swift. Silero receives
`offlineMode: true`, while Community-1 uses its local-only constructor. Neither
path creates a Hub API client.
The provenance sidecar records the toolchain-dependent executable hash and
binds it to those tracked inputs and the exact dependency revision.

The stock 0.0.23 `speech vad-stream` and `speech diarize` commands do not meet
that contract. They request the moving `main` revision with
`offlineMode: false`, and `HF_HUB_OFFLINE=1` cannot turn that explicit API
argument into an offline load. The `ko-meeting` setup no longer installs or
executes the pinned Homebrew Tahoe bottle. That bottle remains relevant only
to historical run provenance. Other benchmark harnesses keep their separate
tool contracts.

The FluidAudio wrappers keep each exact revision in its own parent directory,
with the canonical leaf name FluidAudio expects:

```text
models/fluid-audio/
  parakeet-<revision>/parakeet-tdt-0.6b-v3/
  parakeet-benchmark-<revision>/parakeet-tdt-0.6b-v3-coreml/
  ctc-<revision>/parakeet-ctc-110m-coreml/
  diarization-<revision>/speaker-diarization/
```

The smoke ASR wrapper passes the first leaf with `--model-dir`. FluidAudio's
CLI can still purge and resolve from `main` after a non-transient model load
failure, so smoke acceptance compares the exact-download tree before and after.
The Stage 2 Parakeet harness instead sets `ModelHub.offlineMode = true` and
loads both TDT and optional CTC leaves directly. The diarization harness also
sets offline mode and passes the revision-specific parent to
`OfflineDiarizerModels.load(from:)`. Neither exact harness uses FluidAudio's
Application Support cache.

The source fixture is local macOS `say` output, then converted to exactly
16 kHz mono PCM WAV and padded or trimmed to 160,000 frames. It is generated
on demand and is not an original recording.

The MOSS harness copies `mlx.metallib` from the installed `speech` formula
beside its external SwiftPM executable because the pinned source build does
not package that MLX resource. The copy remains external build state.
