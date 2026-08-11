# Maccheroni v1 Benchmark Verdict

Status: final. The maintainer confirmed the T7 verdict on 2026-08-03.

## Final decisions

| Path | Default | Fallback | Implementation role |
| --- | --- | --- | --- |
| Speaker diarization | community1 CoreML | FluidAudio offline CoreML | Create the whole-file timeline |
| Korean ASR | VibeVoice ASR 8bit, `free_text_context` | None; Qwen3-ASR withdrawn by D37 | Chunk transcription and glossary injection |
| Italian ASR | MOSS 0.9B MLX INT8, `hotword_instruction` | VibeVoice ASR 8bit, `free_text_context` | Chunk transcription and glossary injection |

Every profile uses the selected whole-file speaker timeline. The default path
is community1 and the fallback is FluidAudio. Speaker labels emitted by
VibeVoice and MOSS remain in the raw backend output but do not become the
default speaker IDs. T12 assigns ASR time spans to the selected timeline by
overlap.

This verdict closes the candidate status in D7 and D8. The Italian default
changes the Parakeet v3 plus CTC vocabulary premise in D9 and T11. `PROJECT.md`
keeps the earlier record and supersedes D7, D8, and D9 with D22, D23, and D24.
The T11 difference remains in local working notes as a plan deviation, while
the Parakeet harness and benchmark artifacts remain regression evidence.

## Pinned models

| Role | HF model ID | revision | quantization |
| --- | --- | --- | --- |
| community1 | `aufklarer/Pyannote-Community-1-CoreML` | `a14e6c420d56e8472850649b016a486fd0acbe81` | `coreml-fp32` |
| FluidAudio fallback | `FluidInference/speaker-diarization-coreml` | `1ed7a662fdc7109e36d822db793ee6eebdaf8594` | `coreml-fp32+fp16` |
| VibeVoice 8bit | `mlx-community/VibeVoice-ASR-8bit` | `725c72e54d6ef875472c27fbc50fab470a960940` | `int8` |
| Qwen3-ASR diagnostic only | `aufklarer/Qwen3-ASR-1.7B-MLX-8bit` | `e5450a26d1fd417c45fc9c405651ddc3180a27a6` | `int8` |
| MOSS Italian | `aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8` | `90aa65287111a327db98eb83e325bd5332945edd` | `int8-decoder+fp16-audio-vq-kv` |

The model registry and every run manifest record all three fields together. A
model name or file size alone does not identify a variant.

## Evidence for the verdict

### Speaker diarization

On a two-speaker Italian conversation, community1 recorded speaker count 2/2,
DER 0.048, and mean speaker-boundary error of 0.088 seconds. On VoxConverse
`rcxzg`, it was the only one of the three candidates to report the correct
speaker count of 4/4, with DER 0.052. FluidAudio recorded DER 0.098 and speaker
count 4/3 on the same evaluation set, but it was the lightest at 0.92 seconds
and 0.59 GiB peak memory. It remains the fallback when community1 cannot run.

On a repeated 78-minute evaluation set, community1 over-segmented the two
ground-truth speakers into 8. The representative raw labels for both
ground-truth speakers remained stable across all 9 repetitions. This result
supports representative-speaker consistency on long files but does not resolve
small extra labels. T12 and T14 must separately verify ID preservation across
chunk boundaries and reporting of extra-label conflicts.

### Korean ASR

VibeVoice 8bit with glossary-on recorded CER 0.081, WER 0.128, reference-term
recall 0.95, and 0 empty utterances on a mixed Korean-English sample. The
bf16 variant produced the same transcript but took 5.42 times as long and used
1.48 times the peak memory. The 8bit variant is the default.

Qwen3-ASR with glossary-on recorded CER 0.366, WER 0.301, and term recall 0.25
on the same sample. It cannot replace the default quality, but its peak memory
was 3.74 GiB versus VibeVoice's 17.05 GiB. D23 selected it as the low-memory
fallback from this benchmark evidence. D37 withdraws that product fallback:
the pinned `speech` 0.0.23 backend exposes no enforceable token cap, terminal
reason, token counts, or intra-chunk timestamps. Qwen attempts remain available
for diagnostic evidence but fail with typed `asr_evidence_unavailable` rather
than promoting unverifiable output. The fallback may return when a backend
version exposes all required evidence.

### Italian ASR

MOSS with glossary-on recorded CER 0.033, WER 0.081, term recall 0.778, and
backchannels 7/7 on a synthetic two-speaker conversation. Processing took 3.04
seconds and peak memory was 1.98 GiB. On Italian FLEURS with no glossary terms,
it predicted 0 terms and produced CER 0.007 and WER 0.028, identical to
glossary-off.

VibeVoice 8bit with glossary-on recorded CER 0.089, WER 0.145, term recall
0.778, and backchannels 7/7 on the same conversation. If MOSS fails, the
VibeVoice adapter implemented for the Korean path can serve as the Italian
fallback.

Parakeet CTC vocabulary raised conversation term recall from 0.333 to 0.778 but
worsened CER from 0.116 to 0.245. Backchannel preservation fell from 7/7 to
1/7. It inserted glossary terms 12 times in FLEURS audio that contained none.
The 27 replacement records contain the CTC score and decision reason, proving
that injection ran. The current replacement rule cannot be the v1 default.

## Implementation impact

- T10 places community1 and FluidAudio offline behind the same
  `DiarizerBackend` contract. community1 is the default and FluidAudio is a
  user-visible fallback.
- T11 places VibeVoice 8bit, Qwen3-ASR 1.7B, and MOSS behind the `ASRBackend`
  contract. It passes the glossary in each backend's decode-time format and
  preserves the raw output unchanged. Qwen remains diagnostic-only and returns
  typed `asr_evidence_unavailable`; it is not a product fallback.
- The Parakeet product adapter is outside v1 scope. The reason it differs from
  the earlier T11 wording remains in local working notes as a plan deviation.
  Reconsider it when a CTC replacement threshold achieves both 0 excess
  insertions on glossary-free input and backchannels 7/7 on a new evaluation
  set.
- MOSS and VibeVoice speaker IDs are reference information. The selected
  whole-file timeline determines the final `speaker`; uncertain overlap remains
  a T12 conflict.
- Every subprocess adapter promotes exit codes, backend limits, and truncation
  to errors. T9 chunking avoids VibeVoice's 59-minute limit, and the manifest
  rechecks full source coverage.

## Remaining risks

- The Korean default passed on a public mixed Korean-English sample. There is
  still no evidence that a real meeting with accents, overlapping speech, and
  room noise achieves the same term recall.
- The fast Italian conversation is a synthetic two-speaker sample. Actual
  backchannel speed and overlap are checked further with the T14 public
  evaluation and a private real recording, validated through structural
  metadata only; not part of this repository. The private recording is an
  optional input and does not block completion.
- community1 over-segmented the 78-minute evaluation set into 8 labels. T14
  checks cross-chunk speaker consistency and conflicts without overwriting the
  raw timeline.
- VibeVoice 8bit used 17.05 GiB peak memory on the mixed-language sample. No
  Korean fallback currently satisfies the promotion-evidence contract, so a
  low-memory or VibeVoice environment failure must fail explicitly.
- MOSS is a new backend. Pin the exact revision and keep implementation details
  behind the adapter. If exit status or processed coverage is unclear, fail the
  run.

The next question in section 5 of `PROJECT.md` moves from model discovery to
long-file speaker over-segmentation and generalization to real meetings. Once
T14 verifies cross-chunk speaker consistency, glossary application, and an
unchanged source hash on a public evaluation set, reassess this risk.

## Verification material

| Task | Report | Matrix summary | SHA-256 |
| --- | --- | --- | --- |
| T4 Korean ASR | preserved local run directory `ko-asr` (create-only, not part of this repository), `report.md` | `t4-matrix.stdout.json` | report `e7ae579afa0ed3f6ee52db6bf8f7a122241162abf20ea67b8bb7a3aa2368bf41`, summary `6e8cdf4776a02bbbadf5a4ddc8fd874b11e8ebc76e30c2f69e75df3e06d67160` |
| T5 speaker diarization | preserved local run directory `diarization` (create-only, not part of this repository), `report.md` | `t5-matrix.stdout.json` | report `7d69d545736876e7f9515a44ccaea7d1cdd8ca388c21ba705aefb18437a6985f`, summary `f27df23ac812d1343acdfdd303678c13fce11b216a112207abe944fedc486f07` |
| T6 Italian ASR | preserved local run directory `it-asr` (create-only, not part of this repository), `report.md` | `t6-r2-matrix.stdout.json` | report `ccef6e8bea3ac8d38f039aa3d946e0145e661e19f2deed1a890045d75402d5b8`, summary `7d7e6bb620343777c32d4273ee09748db4ca5ebbbc41e548131d18bef9235860` |

Each report records the run ID, pinned model tuple, glossary condition, scores,
processing time, memory, and independent verification result. All raw
transcripts and inputs remain in preserved local run directories, and their
hashes are identical before and after execution. No remote service was used
during the benchmark, and the audio did not leave the device.

## Final record in PROJECT.md

- D22 supersedes D7. community1 CoreML is the default diarization spine;
  FluidAudio offline CoreML is the explicit fallback.
- D23 supersedes D8. VibeVoice ASR 8bit with `free_text_context` is the Korean
  default. Its Qwen3-ASR low-memory fallback clause is superseded by D37.
- D37 withdraws Qwen3-ASR as a product fallback until a backend exposes the
  terminal, token, and intra-chunk timestamp evidence required for promotion.
- D24 supersedes D9. MOSS 0.9B MLX INT8 with `hotword_instruction` is the Italian
  default. VibeVoice 8bit is the fallback, and Parakeet CTC remains
  benchmark-only.
- Section 5 of `PROJECT.md`: update the next risk to long-file speaker
  over-segmentation, VibeVoice memory, and real-meeting generalization.
- The T11 deviation replaces the Parakeet product-adapter requirement with the
  selections above.

The maintainer's confirmation applies this record to `PROJECT.md` and the T11
implementation scope.
