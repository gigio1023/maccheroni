# Pinned benchmark tools

This record is for the local Apple Silicon benchmark environment. It is not an
app dependency declaration.

| tool | exact installed or pinned version | setup |
| --- | --- | --- |
| speech-swift offline runtime | `soniqo/speech-swift` commit `c1aa219bc2284239ff6917d675a3e1978c840260` (`v0.0.23`) | setup builds `scripts/runners/offline-speech-runtime/` with its tracked `Package.resolved`; the harness opens the pinned local Silero and Community-1 directories without a Hub lookup |
| Python | CPython 3.12.13 | installed by `uv` under the selected Maccheroni cache |
| uv | 0.12.7 verified prerequisite; not installed or pinned by setup | uses cache-local download and Python-install roots, then synchronizes `Sources/MaccheroniASR/Python/uv.lock` into the external venv |
| mlx-audio | 0.4.6 | `uv sync --frozen --inexact --project Sources/MaccheroniASR/Python --python <cache-local CPython 3.12.13> --no-python-downloads` with `UV_PROJECT_ENVIRONMENT` under the selected cache |
| FluidAudio CLI and diarization harness | `FluidInference/FluidAudio` git `5390df9752c8fc583596018360c5fd70d6fa6c75` | external clone or exact harness dependency; models come from the wrapper's exact `hf download` commands |
| VibeVoice benchmark bridge | mlx-audio 0.4.6 | tracked bridge passes the exact HF revision and checks the snapshot before and after inference |
| Parakeet benchmark harness | `FluidInference/FluidAudio` git `5390df9752c8fc583596018360c5fd70d6fa6c75` | tracked offline harness injects exact local TDT and CTC model leaves |
| MOSS MLX harness | `soniqo/speech-swift` git `37c99dd856cfacfe952b2e48ecdb3c9dedc77625` | tracked harness, all SwiftPM checkouts/products external |

The stock speech-swift 0.0.23 CLI is not part of the `ko-meeting` execution
path. Its `vad-stream` and `diarize` commands request `main` with
`offlineMode: false`. Setting `HF_HUB_OFFLINE=1` does not override that explicit
API choice. The setup command therefore builds the repository's narrow offline
harness from the exact source commit and locked SwiftPM graph. The harness
opens the provisioned model directories directly. Silero receives
`offlineMode: true`; Community-1 uses its local-only constructor. Neither path
creates a Hub API client. The harness preserves the stock 0.0.23 JSON output
schema. Setup installs it as
`tools/offline-speech-runtime/bin/maccheroni-offline-speech-runtime` under the
benchmark cache. Its build hash depends on the installed Swift toolchain, so
`tools/offline-speech-runtime/provenance.json` binds the actual executable to
the tracked harness inputs and exact speech-swift revision.

## Bootstrap commands

```zsh
cache_root="$HOME/Library/Caches/Maccheroni/benchmarks"
mkdir -p "$cache_root/venvs" "$cache_root/models" "$cache_root/smoke"
MACCHERONI_BENCHMARK_CACHE="$cache_root" \
  zsh scripts/setup-transcription-runtime.zsh --profile ko-meeting
git clone https://github.com/FluidInference/FluidAudio.git "$cache_root/fluid-audio-source"
git -C "$cache_root/fluid-audio-source" checkout --detach 5390df9752c8fc583596018360c5fd70d6fa6c75
swift build --package-path "$cache_root/fluid-audio-source"
```

The clone must be empty before the `git clone` command. Never place the clone,
venv, models, or smoke outputs in this repository.

The wrappers under `benchmarks/scripts/runners/` use only locally generated
audio. They do not upload an input audio file.

Smoke outputs are immutable. Set `MACCHERONI_SMOKE_RUN_ID` to a new value that
contains only letters, digits, period, underscore, or hyphen for a fresh run;
the wrappers exit 73 instead of replacing an existing output. The speech CLI
wrappers retain stdout plus model identity in external `.log` artifacts.

`run_moss_smoke.sh` downloads its exact MOSS revision with the isolated
environment's `hf` CLI, builds with `--scratch-path` under the cache, then
runs `MossMLXModel.fromDirectory`. It retains `MossMLXModel.defaultInstruction`
and adds glossary terms only as candidate spellings that require acoustic
support. The harness rejects a pre-existing output path rather than replacing
raw or prior output.

## Compatibility finding

The stock speech-swift 0.0.23 CLI accepts only `qwen3`, `parakeet`, `nemotron`,
`omnilingual`, `whisper`, `qwen3-coreml`, and `qwen3-coreml-full` for
`speech transcribe --engine`. It rejects `--engine moss`. The pinned MOSS MLX
harness above remains a separate contract. The `ko-meeting` VAD and
Community-1 path also uses its own offline harness because the stock CLI's
moving-`main` lookups cannot prove a closed, pinned runtime.

mlx-audio 0.4.6 also requires the VibeVoice repository ID so it can load that
repository's model module. Passing the equivalent local snapshot path fails as
an unsupported model type. The Stage 2 bridge calls `load_model` with the
repository ID and exact 40-character revision, runs with the Hub in offline
mode, and hashes the selected snapshot's linked blob contents before and after
inference. It rejects VibeVoice's silent 59-minute truncation path before model
loading.

FluidAudio's CLI loads its custom-vocabulary CTC helper from the default
Application Support cache and does not expose an exact revision argument. The
Stage 2 Parakeet harness replaces that invocation surface with direct offline
loads of the pinned TDT and CTC directories. The vocabulary path remains an
acoustically grounded CTC rescoring pass after base TDT decoding; it is not a
text-only substitution and it retains both base and final text as evidence.
