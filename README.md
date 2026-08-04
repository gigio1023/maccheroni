<p align="center">
  <img src="docs/assets/banner.png" alt="Maccheroni — a waveform interleaved with macaroni, two speaker lines woven through" width="100%">
</p>

<h1 align="center">Maccheroni</h1>

<p align="center">
  Local-first transcription for mixed-language speech on Apple Silicon.<br>
  Glossary injection at decode time · whole-file speaker diarization · audio never leaves your Mac.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2026%20(arm64)-black" alt="platform">
  <img src="https://img.shields.io/badge/swift-6-F05138" alt="swift">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license">
</p>

<p align="center">
  <b>English</b> · <a href="README.de.md">Deutsch</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.it.md">Italiano</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.pt.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.zh-Hans.md">简体中文</a>
</p>

---

**Maccheroni** (from *macaronic speech* — utterances that mix languages) transcribes the conversations most apps quietly get wrong: Korean meetings with English product names in every sentence, language classes, multilingual calls. Everything runs on-device with pinned MLX/CoreML models.

What an export looks like (illustrative sample, not model output):

```markdown
**Speaker 1** [00:04] Did the smoke tests pass on staging before we merged that PR?
**Speaker 2** [00:09] Yes, and the Kubernetes rollout was clean. [UNCERTAIN] There's
                      still a latency spike on the [CONFLICT: Grafana|Graphana]
                      dashboard, though.
**Speaker 1** [00:17] Alright, then the release window stays as planned.
```

Uncertain corrections are flagged, never silently substituted. Speaker labels come from one whole-file diarization pass, so they stay consistent across a two-hour recording.

<p align="center">
  <img src="docs/assets/screenshots/transcript.png" alt="Maccheroni transcript view: two speakers with global labels and per-segment evidence chips, next to a run inspector listing run status, pinned model revisions, and the glossary record" width="100%">
</p>
<p align="center"><em>Every run keeps its evidence: the inspector shows the exact pinned models, the run status, and whether the glossary reached the decoder.</em></p>

## Why this exists

On 2026-08-02 we audited seven macOS local transcription apps at source level. None passed the combination that real mixed-language meetings need:

- Apps with local diarization didn't deliver the glossary to the ASR model (post-hoc string substitution, dead SDK parameters, or cloud-only dictionaries).
- The app with the cleanest model-level glossary had no diarization.
- "Multilingual support" almost always means *one language per session*, which is exactly what mixed-language speech is not.

The parts all exist at the library layer. The combination didn't exist at the app layer. So this repo builds it — and the audit lives in [docs/reference-project-source-audit.md](docs/reference-project-source-audit.md).

## What makes it different

1. **Glossary at decode time.** Names and technical terms enter the model's context before decoding, because an ASR error destroys the acoustic evidence the moment it happens. Post-processing can polish text; it cannot recover what the decoder never wrote. Every leaf's glossary payload is hash-sealed into the run manifest.
2. **One diarization pass owns the speakers.** The whole file is diarized once; that timeline is the only speaker authority. ASR runs in bounded chunks and merges by timestamp — chunk-local speaker guesses can never flip a label across a boundary.
3. **No silent data loss, ever.** Inputs beyond a backend's limit fail explicitly or produce a split plan. Truncated model output is a typed failure (`invalid_eos_output`), not a shorter transcript. Originals and raw transcripts are immutable; corrections and translations are separate create-only artifacts.

## How it works

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/pipeline-dark.drawio.svg">
  <img src="docs/assets/pipeline-light.drawio.svg" alt="Pipeline diagram: on your Mac, capture feeds whole-file diarization and 120-second ASR leaves with per-leaf glossary injection; the timestamp merge, where the timeline owns speakers, feeds optional on-device post-processing; the only thing that leaves the Mac is the opt-in remote post-processing lane, an external vendor reached through your Codex sign-in, text only" width="100%">
</picture>

Failed leaves are re-split within typed bounds (30 s minimum, depth 3) and only end-of-sequence outputs are ever promoted to the canonical transcript. The optional Codex lane sends bounded transcript text, the active glossary, and instructions — never audio, never file paths — through your own ChatGPT/Codex subscription.

## Models

Everything is pinned by Hugging Face ID + revision + quantization and recorded in every run manifest.

| Role | Model | Revision | Quantization |
|---|---|---|---|
| ASR (Italian / mixed) | `aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8` | `90aa6528` | int8-decoder + fp16-audio-vq-kv |
| ASR (Korean) | `mlx-community/VibeVoice-ASR-8bit` | `725c72e5` | int8 |
| VAD | `aufklarer/Silero-VAD-v6.2.1-CoreML` | `52387654` | coreml-float16 |
| Diarization | `aufklarer/Pyannote-Community-1-CoreML` | `a14e6c42` | coreml-fp32 |
| Post-processing (local) | `mlx-community/gemma-4-12B-it-qat-4bit` | `e70c6b3b` | qat-int4 (mlx-vlm 0.6.6) |
| Post-processing (remote, text-only) | `gpt-5.6-sol` via Codex app server | service-managed | n/a |

## Measured results

All from public or synthetic fixtures; evaluation IDs and artifact hashes are recorded in [docs/](docs/).

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/benchmarks-dark.svg">
  <img src="docs/assets/benchmarks-light.svg" alt="Bar charts: CER and WER per fixture (Korean dialogue 0.081/0.128, Italian two-speaker 0.033/0.081), glossary term recall (0.95 and 0.778 against the 0.75 gate), and diarization error rate (0.048 synthetic, 0.152 VoxConverse)" width="100%">
</picture>

| Fixture | Model | CER | WER | Term recall | Omissions | DER |
|---|---|---:|---:|---:|---:|---:|
| Korean dialogue, 20-term glossary | VibeVoice | 0.081 | 0.128 | 0.95 | 0 | — |
| Italian 2-speaker synthetic (10 min), 9-term glossary | MOSS | 0.033 | 0.081 | 0.78 | 0 | 0.048 |
| VoxConverse sample (78 min) | VibeVoice + Pyannote | — | — | — | — | 0.152 |

Korean and Italian are the first two language profiles; new language fixtures join this table as they are measured.

Chunk-boundary speaker stability on the 78-minute sample: 1.0 for both reference speakers. A fixed 600-second matrix showed that MOSS leaves above 120 s lose timestamp structure entirely, which is why the production leaf cap is 120 s — details in [docs/moss-long-audio-verdict.md](docs/moss-long-audio-verdict.md).

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/leaf-cap-dark.svg">
  <img src="docs/assets/leaf-cap-light.svg" alt="Bar chart: on the same 600-second input, 120-second leaves yield 5 canonical end-of-sequence leaves (pass), 240- and 300-second leaves yield 0 valid leaves (typed invalid_eos_output failures), and forced recovery from 240-second parents yields 5 valid 120-second children" width="100%">
</picture>

## Install

There are no packaged releases yet — build from source.

Requirements: Apple Silicon Mac, macOS 26, Xcode 26, [uv](https://docs.astral.sh/uv/).

```bash
git clone https://github.com/gigio1023/maccheroni.git
cd maccheroni
swift build && swift test          # 153 tests
zsh scripts/build-app.zsh          # builds and codesigns Maccheroni.app
```

The app prints its bundle path when the build, resource-allowlist inventory, and strict codesign checks all pass. Model weights download on first use; `maccheroni doctor` verifies runtimes and pinned snapshots:

```bash
.build/debug/maccheroni doctor
.build/debug/maccheroni run recording.wav --profile it-dialogue
```

Profiles ship for Korean meetings (`ko-meeting`, VibeVoice) and Italian dialogue (`it-dialogue`, MOSS). For the optional local post-processing model, run `zsh scripts/setup-postprocess-runtime.zsh`.

## Privacy

<p align="center">
  <img src="docs/assets/screenshots/capture.png" alt="Maccheroni capture view: profile picker with measured metrics, post-processing choice between Codex, Local, and None, and the notice that audio never leaves this Mac" width="100%">
</p>

- Transcription, VAD, and diarization are fully local. Audio bytes never reach any network path — this is enforced by tests, not policy.
- The optional Codex post-processing lane is text-only and opt-in per run. It opens a one-turn `codex app-server` session using the cached ChatGPT subscription sign-in. The thread is ephemeral and read-only, tools are disabled, and approval requests are declined; the prompt contains segment text, the active glossary, and instructions. API-key authentication is not accepted for this lane. Choosing the local MLX model instead keeps even text on-device.
- Failure messages are length-capped and path-redacted before they enter run manifests.

## Limitations

- Apple Silicon + macOS 26 only. No Intel, no iOS, no Windows/Linux.
- Post-transcription only — no live captions (deliberately, quality first).
- Mixed-language quality is verified on fixtures, not yet on months of real meetings.
- The Codex lane requires your own Codex CLI login and subscription quota.
- UI is English by default with 10 localizations; ko/it strings are still marked for human review.

## Contributing

Issues and focused pull requests are welcome. Build and test commands, the verification standard behind this README's claims, commit rules, and issue/PR conventions live in [CONTRIBUTING.md](CONTRIBUTING.md).

## Repository map

| Path | What it is |
|---|---|
| `Sources/` | Swift package: Core, Preprocess, ASR, Diarize, Merge, Postprocess, CLI, App |
| `Tests/` | 153 fixture-based tests across 17 suites |
| `benchmarks/scripts/` | Runners and scorers with derived verdicts and negative tests |
| `docs/` | Research digest, source audits, constraint policy, contracts (JSON schemas), UI design |
| `scripts/` | App bundle build, MOSS harness build, post-processing runtime setup |
| [PROJECT.md](PROJECT.md) | Intent hierarchy: pillars, non-goals, judgment rules, append-only decision log |
| [AGENTS.md](AGENTS.md) | Operating conventions for working in this repo |

Every completion claim in the docs carries the command that produced it and its observed output.

## License & acknowledgements

MIT. Standing on: [speech-swift](https://github.com/soniqo/speech-swift) (MLX/CoreML speech runtimes), the MOSS, VibeVoice, Silero, and pyannote model authors, and [mlx](https://github.com/ml-explore/mlx). The reference-project source audit in `docs/` credits the 24 open-source projects whose designs — good and bad — shaped this one.
