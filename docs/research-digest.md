# Research Digest (as of 2026-08-02)

This document contains only the verified facts from the underlying research
that are needed to implement this repository. Every item was checked against a
primary source: an official repository, Hugging Face metadata, or source code.
The underlying research notes and decision history live outside this
repository; this digest is the summary of record.

## Why not an existing app (the missing requirement combination)

7 apps were inspected down to source level on 2026-08-02. The required
combination is (a) mixed-language speech quality, (b) local diarization and
timestamps, (c) chunked long-file processing, (d) model-level glossary
injection, (e) structured export, and (f) fully local operation.

- Muesli: its personal dictionary performs **post-processing replacement**
  through Jaro-Winkler matching in `CustomWordMatcher.swift`. No backend
  `transcribe()` method accepts a prompt or context parameter.
- Anarlog (formerly Hyprnote): its local pyannote ONNX diarization and VAD
  chunking crate are strong, but the `custom_vocabulary` SDK parameter for local
  Parakeet is always empty: **dead code**.
- Spokenly: it provides local Qwen3-ASR, diarization, and speakerId JSON, but
  model-level dictionaries are **cloud-model only** (GPT-4o, Soniox).
- TypeWhisper: glossary context injection was verified by measurement, but
  diarization is **cloud-only** (AssemblyAI).
- local-whisper (gabrimatic): it has the cleanest glossary mechanism (automatic
  4,096-character Qwen3 context construction and 20-minute chunks), but **no
  diarization**.
- TranscriptionSuite: both the MLX and CUDA VibeVoice backends discard
  `initial_prompt` and `num_speakers` with `del`. The repository contains no
  hotword string at all.
- MacWhisper, Whisper Snapper, Superwhisper, VoiceInk, HyperWhisper: none combine
  a Qwen-family model, diarization, and a model-level glossary.

Conclusion: the gap exists at the app layer, while all components exist at the
library layer.

## ASR model facts (verified)

| Model | Key facts | Caveat |
|---|---|---|
| VibeVoice-ASR (`microsoft/VibeVoice-ASR`) | 51 languages (including ko and it); explicit within- and cross-utterance code-switching; joint ASR, diarization, and timestamp output; free-text context rather than structured hotwords; no speaker-count hint parameter; MIT | Measured safetensors size is 8.67B (HF edition 8.33B). GitHub documentation calls it 7B and third parties call it 9B, so record only ID and revision. There is effectively no Swift port (the path is Python through mlx-audio). The mlx-audio port truncates input beyond `MAX_DURATION_SECONDS = 59 * 60` with only a warning log. |
| Qwen3-ASR (`Qwen/Qwen3-ASR-0.6B/1.7B`) | 52 languages and dialects (including ko and it); free-text context injection; Apache-2.0; native single-pass limit of 20 minutes | **No code-switching claim appears in 1st-party sources** (the commercial DashScope documentation specifies single-language only). Timestamps require a separate ForcedAligner-0.6B, in 5-minute units, for 11 languages. |
| MOSS-Transcribe-Diarize (`OpenMOSS-Team/...`, 0.9B) | Single-pass ASR, diarization, and timestamps; 90 minutes; hotword instruction; 50+ languages including ko; outperforms VibeVoice in some benchmarks | No explicit code-switching claim. Very new, released in 2026-07. |
| Parakeet v3 (`nvidia/parakeet-tdt-0.6b-v3`) | 25 European languages including it; word and segment timestamps; CC-BY-4.0 | **No Korean** |
| Whisper family | One weight set plus a decode-time language token (verified in source, 100 languages); when unspecified, the first 30 seconds are used for automatic detection | Fixing one language token breaks mixed-language speech, so it is unsuitable for the Pangyo-speech track. |

## Swift engine layer (verified)

- **speech-swift** (`soniqo/speech-swift`, Apache-2.0, macOS 15+, SPM plus
  `brew install speech` CLI): `Qwen3ASR.transcribe(context: String?)`,
  `MossTranscribe` (instruction hotword, whole-file only), and a built-in
  ForcedAligner. `speech diarize --engine {pyannote|community1|sortformer}`:
  - pyannote engine: **MLX** segmentation and WeSpeaker embeddings, no upper
    speaker-count limit, and `--target-speaker` enrollment support.
  - community1 engine: CoreML, configurable speaker-count range, reported DER
    parity of 4.66% on a VoxConverse subset.
  - sortformer engine: CoreML, 4-speaker limit (8 for the
    Ultra-Sortformer fine-tune), streaming support.
  Risk: 6 months old and effectively maintained by 1 person (586 of about
  600 commits).
- **FluidAudio** (`FluidInference/FluidAudio`, Apache-2.0, 2.6k stars, named
  production users): Parakeet v3 CoreML (Italian included, Korean absent), CTC
  custom-vocabulary boosting (word list; 99.4% dictionary recall in its own
  benchmark; batch pipeline only), offline diarization (pyannote Community-1
  CoreML, 1-2 MB memory per hour), speaker enrollment API, and Silero VAD
  CoreML.
- **Maccheroni's merge contract is first-party code**: WhisperX implements
  speaker assignment by summing overlap time between ASR segments and a
  diarization timeline (`whisperx/diarize.py`, follow-up source audit on
  2026-08-03). None of the audited projects also satisfied Maccheroni's
  create-only raw preservation, separate conflicts, canonical whole-file global
  speakers, and schema contract.
- **Apple SpeechTranscriber** (macOS 26): no custom-vocabulary support (official
  Apple engineer response, developer.apple.com/forums/thread/801877). Excluded
  from the default-backend candidates.
- **argmax-oss-swift** (formerly WhisperKit, MIT, 6.3k stars): a monorepo with
  WhisperKit ASR and SpeakerKit (pyannote v4 family). Alternative pool.
- **Codex integration**: `codex app-server` exposes a JSONL protocol over stdio.
  Maccheroni initializes one isolated process per request, confirms a ChatGPT
  subscription account with `account/read`, and starts one ephemeral read-only turn
  with a JSON Schema `outputSchema`. Tools are disabled and approval requests are
  declined. The app server owns the Codex CLI login cache and token refresh.

## Preprocessing (verified)

- On by default: 16 kHz mono conversion, peak normalization (neither Whisper
  nor speech-swift has a loudness-normalization stage, and ASR practice favors
  peak over LUFS), and Silero VAD (silence map and chunk boundaries).
- Opt-in: DeepFilterNet3 enhancement (speech-swift provides CoreML by default
  and MLX; over 60 seconds it uses `enhanceChunked` with crossfade). **Why it is
  off by default**: 3 papers report that enhancement worsens modern-ASR WER
  even on clean audio by 1.3-3.2% (arXiv:2603.04710, 2512.17562, 2605.12107).
- Run diarization on audio that has not passed through enhancement, to avoid
  speaker-embedding distortion. This is a mechanism-based inference; no direct
  measurement study was found.
- Apple provides no 1st-party denoising API for files. Voice Isolation is a
  real-time microphone mode only.

## Not yet measured (benchmark targets)

1. VibeVoice versus Qwen3 (1.7B) versus MOSS on a Pangyo-speech sample: glossary
   recall, dropped utterances, processing time, and memory, with the same
   glossary injection for each.
2. Korean and Italian sample DER and processing time for 3 diarization
   candidates: speech-swift pyannote/community1 and FluidAudio offline.
3. Backchannel preservation and speaker boundaries in fast multi-speaker
   Italian conversation.
4. Global speaker consistency on a 70-80-minute file and the observed behavior
   of mlx-audio's 59-minute truncation.
5. The actual memory ceiling on an M5 Pro with 48 GB; official documentation
   gives no Apple Silicon memory requirement.

## Underlying documents

- The underlying research notes live outside this repository; this digest is
  the summary of record.
- Detailed plans and decision history are likewise maintained outside the
  tracked tree.

## 2026-08-04 TranscriptionSuite recheck (adoption review)

After fetching upstream, origin/main still matched the audited pinned commit
`3ac4e07` (2026-08-03), with no new commits. The whole product was reanalyzed
for adoption rather than only checking risk patterns. Facts added to the prior
record:

- The VibeVoice-family discard of `initial_prompt`/`num_speakers` with `del` and
  the 0 occurrences of a hotword string remain unchanged. 5 Whisper
  backends (faster-whisper, openai whisper, generic and diarized WhisperX,
  whisper.cpp, and MLX Whisper) do pass `initial_prompt` to the decoder.
  WhisperX's diarized path was fixed in GH-274 and has a regression test.
- MLX Whisper is the only prompt-accepting backend that can actually run on
  Apple Silicon (Metal). WhisperX and whisper.cpp use Docker-required profiles.
  The only delivery mechanism is a global value in user config YAML; there is
  no UI or per-job glossary, and the 2-pass diarization path drops per-request
  prompts. No path provides hotword biasing.
- There is no code-switching handling: each job has 1 language code. The only
  Korean-capable Metal models are MLX Whisper and MLX VibeVoice, and the latter
  discards the prompt, so the Pangyo-speech requirement effectively converges on
  MLX Whisper alone.
- Model provenance is absent: records contain only a backend-family string, no
  model ID, revision, or quantization, and the repository has 0 pinned
  `revision=` occurrences.
- Diarization: pyannote (whole file, requires an HF token) and Sortformer
  (hard-coded 4-speaker limit, unverified label carryover across chunks). A
  static defect can load pyannote even when Sortformer is selected in the UI,
  because the delivery chain passes an empty string.
- Strengths: partial-result salvage and orphan-job recovery, nondestructive
  editing and speaker-alias UI, FTS5 search, and a 1.23:1 test density. App-layer
  completeness is high. GPL-3.0 permits personal use, but distributing ported
  code propagates the GPL.

Conclusion unchanged: the 2026-08-02 diagnosis that "the required combination
(mixed-language speech + diarization + glossary + local operation) does not
exist at the app layer" still applies to the audited repository state.
