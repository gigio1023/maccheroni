# PROJECT.md — Maccheroni

A local transcription app for macOS on Apple Silicon. It transcribes mixed-language
conversations with glossary injection and speaker diarization without sending audio off
the device.

The name Maccheroni comes from the linguistic term *macaronic speech*, in which one
utterance mixes multiple languages. Korean-English "Pangyo speech" is exactly this
phenomenon, and the Italian word covers both primary usage tracks under one name.

<!-- maintainer-owned: Sections 1-4 (reason for existence, pillars, non-goals, and
judgment rules) belong to the maintainer. The initial draft was derived from records on
2026-08-03 and remained provisional until the maintainer confirmed it.
Renegotiate with the maintainer before editing sections 1-4. -->

## 1. Why It Exists (Diagnosis)

Most commercial apps use "multilingual support" to mean selecting one language per
session. Real conversations do not work that way. Korean IT meetings continuously mix
English terms and product names into Korean sentences ("Pangyo speech"), while language
classes and multinational group conversations move between languages both within and
across utterances. This scenario often performs poorly even in apps that claim support.

Concrete incident: a source-level re-audit of 7 local macOS transcription apps on
2026-08-02 found no single app that passed. Apps with local diarization did not pass a
glossary to the ASR model: Muesli used Jaro-Winkler post-processing replacement,
Anarlog's SDK parameter was dead code, and Spokenly's model-level dictionary was
cloud-only. The app with the cleanest model-level glossary, local-whisper, had no
diarization. The required combination (mixed-language utterance quality + diarization +
glossary + local processing) did not exist at the app layer, although all components
existed at the CLI/library layer. That gap is why Maccheroni exists.

The previous alternative, uploading audio to a hosted model playground, provides
insufficient privacy control regardless of transcription quality.

## 2. Pillars

- P1. **Mixed-language speech is a first-class scenario.** Design for utterances that
  embed terms from another language in the primary language ("Pangyo speech") and for
  cross-language conversations. This does not mean polishing a separate single-language
  mode UI for every language.
- P2. **Inject the glossary during decoding.** An ASR error destroys acoustic evidence
  at decoding time, so personal names, pet names, and technical terms must enter the
  model context. Post-processing replacement or LLM correction cannot substitute for
  this; post-correction is complementary.
- P3. **Audio never leaves the device.** Transcription completes locally on Apple Silicon
  (MLX/CoreML). This does not prohibit explicitly opted-in cloud benchmarks or
  text-only post-correction through the configured remote backend.
- P4. **Chunked processing with globally consistent speakers.** Do not send a 1-2-hour
  recording to a model in one operation. Run diarization over the complete file
  to create a global speaker timeline, process ASR in 10-20 minute chunks, and merge by
  timestamp. This rules out relying on a model's long-context claims for convenience.
- P5. **Verification drives implementation.** Sample benchmarks, pinned fixtures, and
  JSON Schema contracts make behavior inspectable. An implementation claim is not
  completion; completion requires the command that ran and the observed result.

## 3. Non-goals

- **Do not make cloud transcription services the default path.** Privacy is part of the
  reason this project exists. The only exception is a quality-ceiling benchmark on a
  sample explicitly approved by the maintainer.
- **Do not implement real-time streaming transcription in v1.** Post-processing quality
  takes priority. Revisit when real use repeatedly shows a need for live reference
  during meetings.
- **Do not target App Store distribution, multiple users, or a server product.** The app
  is for local use. Revisit when external users actually appear.
- **Do not fork Muesli.** Source inspection confirmed on 2026-08-02 that its personal
  dictionary is a post-processing replacement and no backend receives a prompt
  parameter.
- **Do not build a diarization model.** speech-swift already provides a native MLX
  pyannote engine. Its only unported component, PLDA/VBx clustering, is not a neural
  network operation and offers no practical benefit from an MLX port.
- **Do not build meeting search, notes, or calendar integration.** Existing apps cover
  that territory. Revisit if 1 month of real use repeatedly records this problem.

## 4. Judgment Rules

1. If model-selection claims in documentation conflict with a sample benchmark, **the
   sample benchmark wins.** Official documentation is used only to select candidates.
   Basis: primary sources did not establish Qwen3-ASR code-switching, while VibeVoice
   stated it explicitly; documentation alone would reverse the selection.
2. **Silent data loss violates the contract.** Input beyond a backend's duration limit
   must fail explicitly or produce a split plan. Basis: mlx-audio VibeVoice silently
   truncates after 59 minutes, `MAX_DURATION_SECONDS = 59 * 60`.
3. **No stage overwrites an original.** Source audio and raw transcripts are immutable;
   corrected transcripts are separate files. The underlying transcript-cleaning
   operational notes live outside this repository.
4. **Do not change speakers or timestamps without acoustic evidence.** Text
   post-processing, including LLM processing, cannot modify speaker assignments or time
   intervals.
5. **Mark uncertain corrections instead of replacing them.** A conflict list for human
   review is safer than plausible automatic correction.
6. **Put external dependencies behind adapters.** If one backend fails, only its adapter
   should change, not application code. Basis: speech-swift was 6 months old and
   effectively maintained by one person at the time of review.
7. **Audio enhancement is off by default.** Record enabled enhancement in the manifest,
   and run diarization on audio that has not passed through enhancement. Basis: 3 papers
   from 2025-2026 report that enhancement worsens current ASR WER even on clean
   audio: arXiv:2603.04710, 2512.17562, 2605.12107.
8. **Identify a model only by HF model ID, revision, and quantization.** Do not use a
   parameter-count alias as an identifier. Basis: VibeVoice labels the same weights as
   7B/8B/9B.

<!-- end maintainer-owned sections. The digest below records current project state. -->

## 5. Most Important Current Question (Risk)

**Does the text-to-text output budget remain conservative for real long-form inputs and
new models?** D29 correction and translation use bounded batches at segment boundaries,
pre-call output budgeting, a second check against raw schema response bytes, exact
coverage, and a separate create-only translation artifact. An actual two-batch request
with synthetic Italian text and `gpt-5.6-sol` is preserved in the create-only run
`t7-codex-actual-20260803T230231Z-e1852cd5-0caa38d1-d9e4-4085-b9dd-59341acb6576`.
The SHA-256 of `evidence.json` is
`331c578fb88e3ddee628d919a0e20eff6ea0f97d638cc233c213f153459f0f51`. The fixture
confirmed that audio, the raw transcript, speakers, and timestamps remained unchanged.
MOSS transcription retains 120-second leaves, 5,120 output tokens, EOS-only promotion,
and typed recovery. Remaining risks are recalibrating when a new model or a real
long-form input changes the output expansion factor, and the inability of the Codex
app-server read-only sandbox to fully prevent macOS-level reads outside an empty working
directory. A private real recording, validated through structural metadata
only; not part of this repository. It remains optional validation under D19 and does
not block v1 completion.

## 6. Current Position

- **now**: T1-T16, the MOSS long-file improvements, and D29 correction and translation
  are complete for v1. At product baseline `5a74fa3`, Xcode 26 passed 140 Swift tests in
  16 suites, the complete build, and the strictly codesigned app bundle. The T7 exact
  check passed 43 App tests and 15 CLI tests. Two synthetic text-only batches ran with
  authenticated `codex-cli 0.146.0` and `gpt-5.6-sol`, preserving the input hash and
  recording the text-only boundary in a checksummed artifact. From the actual backend
  artifact baseline `e1852cd` through the final product, there were 0 diffs in the
  post-processing backend, actual test, and evidence runner. Two consecutive tracked T14
  runs at the final product baseline were
  `t14-20260803T232022243105Z-5a74fa3d-a649bb42` and
  `t14-20260803T232023289691Z-5a74fa3d-1331e04d`. Their summary SHA-256 values were
  `2f272671814cc2949445c4a7fc45b7901a7903f02e8a8084d571537170eb0df0` and
  `7798686a431d59d5ac23388285ad61214c270a8dc7d91a522fdd32c290f0c6d8`, respectively.
  Both passed strict no-regression, source hash, glossary, and chunk-boundary global
  speaker contracts. Failed runs, recordings, raw transcripts, and existing artifacts
  remain in preserved local run directories that are create-only and not part of this
  repository. The active Codex transport now uses a fresh `codex app-server` process for
  each readiness probe or text transformation. It accepts only a ChatGPT subscription
  account, creates one ephemeral read-only thread, disables tools, declines approval
  requests, and records new manifests as `codex-app-server`.
- **next**: If the maintainer chooses, validate correction time and translation quality
  on a real meeting. If the model revision, backend output format, or long-form output
  expansion changes, recalibrate the budget coefficient with the fixture and an actual
  synthetic round trip.
- **under review**: Generalization to real-meeting accents, overlapping speech, and
  noise; reducing the backend CLI's OS-level read scope; the output coefficient for new
  models; and VibeVoice memory use.
- **success measure**: Can 1 important meeting become a reliable speaker-attributed
  record with no more than 30 minutes of human correction? Supporting metrics are
  reference-term recall, omitted utterance count, speaker-count accuracy, processing
  time, and human review time.

## Decisions

Decision provenance: [maintainer] confirmed by the maintainer, [inference] inferred from
evidence, [default] adopted convention. Reversals are appended as replacement records,
not deleted.

- D1 [maintainer] Build a new Swift-based macOS app rather than adopt an existing app.
  The 2026-08-02 re-audit satisfied the rule that the project should not be built if one
  app already met the required combination.
- D2 [maintainer] Apple Silicon local-only processing (MLX/CoreML). Do not consider CUDA.
- D3 [maintainer] Split long files. Do not send 1-2 hours to a model in one
  operation.
- D4 [maintainer] Make both file input and in-app recording with AVAudioEngine core
  features.
- D5 [maintainer] Connect correction and translation through Codex (`codex exec`,
  subscription quota), at lower priority.
- D6 [maintainer] Keep this repository local-only for the time being. Do not publish it
  to a remote (decided 2026-08-03).
- D7 [inference] Diarization spine candidates: the pyannote engine (MLX) and community1
  engine (CoreML) in speech-swift `diarize`, plus FluidAudio offline (CoreML). Select by
  sample benchmark.
- D8 [inference] Korean-track ASR candidates: speech-swift `Qwen3ASR` (free-text
  context), speech-swift `MossTranscribe` (hotword instruction, integrated path), and
  mlx-audio VibeVoice (Python subprocess, strongest official code-switching evidence).
  Select by sample benchmark.
- D9 [inference] Italian-track ASR: FluidAudio Parakeet v3 + CTC custom vocabulary. It is
  for single-language discourse with the language fixed.
- D10 [inference] Preprocessing defaults: 16kHz mono conversion, peak normalization, and
  Silero VAD for chunk-boundary decisions. DeepFilterNet3 enhancement is opt-in.
- D11 [inference] Profile-based model routing: before recording, the selected profile
  makes the registry choose model family, size, quantization variant, and language lock
  as one set. Language performance displays accumulate this project's sample benchmark
  values rather than vendor metadata.
- D12 [default] Artifact contract: every run records a raw transcript,
  `segments.json` (speaker, start, end, text), and a run manifest (model ID, revision,
  quantization, glossary hash, preprocessing settings, processing time).
- D13 [inference] The benchmark precedes application implementation. The benchmark runs
  through raw CLIs without the app, so there is no reason to build the app first.
- D14 [maintainer] The project name is Maccheroni (confirmed 2026-08-03). A personal
  checkout location is not part of the repository contract. The Swift module prefix is
  `Maccheroni`, and the CLI executable is `maccheroni`. The naming review checked and
  avoided collisions with earlier names for the same concept: Sotto, Verbale, and Myna.
- D15 [maintainer] v1 is complete when every task in the written build plan kept in local
  working notes outside the tracked tree passes its completion judgment and the results
  are committed to this repository. Delivery ends with the repository commit (local
  use, App Store remains a non-goal, and D6 remains local-only at this point in the
  history).
- D16 [maintainer] The default UI language is English, with major languages localized
  through a String Catalog. v1 translations are en (default), ko, it, ja, zh-Hans, es,
  fr, de, pt, and ru. Mark en, ko, and it for human review.
- D17 [maintainer] Post-processing (correction and translation) has 2 backends: Codex
  (subscription authentication, text only) and a local MLX LLM. Select a current dense
  instruct model in the Gemma class, not an MoE model, during implementation. The choice
  is a simple UI toggle at run time, with no assumption that cloud processing is the
  default. Record backend and model in the run manifest. Audio never leaves the device
  under either choice.
- D18 [maintainer] In-app recording captures microphone and system audio simultaneously
  through a CoreAudio process tap or ScreenCaptureKit. For remote meetings such as Zoom,
  record system sound directly instead of recapturing it through the speakers. Preserve
  the 2 channels separately; channel provenance may assist diarization.
- D19 [maintainer] Minimize maintainer intervention in benchmarks. Prefer public datasets
  obtained with an authenticated hf CLI. A private real recording, validated through
  structural metadata only; not part of this repository. It is optional final validation
  rather than a gate. Routine dataset research may use a lightweight investigation;
  complex multihop research requires a full direct analysis.
- D20 [maintainer] Design precedes the feature list for the UI. `docs/ui-design.md` is
  the input to T15. Record important design judgments there, but do not add productization
  mechanisms such as KPIs, usage instrumentation, or onboarding.
- D21 [maintainer] The toolchain targets the Xcode 26 general release (decided
  2026-08-03). Do not consider Xcode 27 or its beta-only APIs, including new SwiftUI 27
  APIs. The deployment target is macOS 26. Revisit when Xcode 27 reaches general release
  and the maintainer decides to switch.
- D22 [maintainer] Replaces D7. The default diarization spine is community1 CoreML.
  FluidAudio offline CoreML is the explicit fallback. The maintainer confirmed the
  2026-08-03 T7 benchmark verdict.
- D23 [maintainer] Replaces D8. The default Korean ASR is VibeVoice ASR 8bit with
  `free_text_context` glossary injection. Qwen3-ASR 1.7B MLX 8bit is the low-memory
  fallback.
- D24 [maintainer] Replaces D9. The default Italian ASR is MOSS 0.9B MLX INT8 with
  `hotword_instruction` glossary injection. VibeVoice ASR 8bit is the fallback.
  Preserve Parakeet CTC vocabulary for benchmarks only in v1 because it over-inserts
  terms. The basis and reconsideration conditions are in `docs/benchmark-verdict.md`.
- D25 [inference] Fix the D17 local post-processing model to dense 11.95B
  `mlx-community/gemma-4-12B-it-qat-4bit`, revision
  `e70c6b3ba0979b3357dcd2f223ad8bde7787a6b6`, `qat-int4`. The runner is `mlx-vlm`
  0.6.6. Specify `gpt-5.6-terra`, an actually supported model for the subscription
  account at the time of the decision, for the Codex backend and record it with the CLI
  version in the manifest. Revisit when a new dense instruct candidate passes the same
  structure-preservation and correction contracts on synthetic and public fixtures.
  Notation record (2026-08-04): `gpt-5.6-terra` was an assumption at decision time; the
  Codex-lane model actually used for implementation and verification was
  `gpt-5.6-sol` (D30). This sentence corrects the notation without reversing the
  decision.
- D26 [maintainer] Makes the MOSS execution unit in D3 and P4 concrete. Do not send a
  19-minute recording to MOSS in one operation. First audit how open-source
  transcription projects split inputs, recover failures, and preserve originals. Then
  divide work into short backend-specific leaves and reflect the result in policy and
  implementation. Retain the previous 10-20 minute interval only as a higher-level work
  unit when needed (decided 2026-08-03).
- D27 [inference] The provisional MOSS leaf policy uses a preferred length of 240 seconds,
  an initial maximum of 300 seconds, and an output limit of 5,120 tokens.
  `maximumTokens` and `contextLimit` bisect only the affected range at an intermediate
  silence boundary. If no valid silence exists, use the exact sample midpoint. Reassess
  by comparing boundary omissions, glossary behavior, global speakers, processing time,
  and memory in fixed 2-, 4-, and 5-minute runs. The basis and rejected patterns
  are in `docs/reference-project-source-audit.md` and
  `docs/engineering-constraint-policy.md`.
- D29 [maintainer] Replaces D17's default direction (decided 2026-08-04).
  Post-processing (correction and translation) was originally intended to favor the
  remote backend. After subscription authentication, connect to the Codex app server and
  call a frontier model supported by that subscription's usage limit, such as
  gpt-5.6-sol. This path is text-to-text only; audio never leaves the device, preserving
  P3. The local MLX dense model from D25 is the fallback when local-only text processing
  is preferred. Translation of transcription output is the representative use case for
  this path, although no translation mode existed at the time of the decision. Retain
  D25's rule to record the actual model ID and CLI version in the manifest. An earlier
  requirements record had narrowed the design toward local processing; the maintainer
  corrected it. Implementation record (2026-08-04): the preceding statement that no
  translation mode existed preserves the state at decision time. D30 supersedes the
  implementation state. Translation now uses a separate create-only artifact, exact
  segment coverage, and an immutable source-structure contract. The app allows selection
  of a Codex or Local backend and a target language.
- D28 [inference] Replaces D27's provisional duration. In a fixed 600-second synthetic
  evaluation, only 120 seconds passed all criteria together: CER 0.030, WER 0.048,
  glossary term recall 0.778, 0 omitted utterances, and speaker repetition stability
  1.0. At 240 and 300 seconds, term recall was 0.689 and 0.667, respectively. Fix the
  production MOSS initial leaf to minimum 60 seconds, preferred 120 seconds, maximum 120
  seconds. The 60-second minimum accepts the last segment of input that does not divide
  evenly into 120 seconds without losing source samples. Retain the 5,120-token output
  limit, 30-second recovery minimum, and depth 3. The basis and scorer change record are
  in `docs/moss-long-audio-verdict.md`. The 2026-08-04 typed final matrix
  `moss-long-audio-20260803T182646Z-fd5ca427` reconfirmed the policy with helper
  fingerprint `e665562d...e96a1`. The 120-second and forced-recovery cases passed quality
  and integrity gates. The 240- and 300-second direct candidates each produced 0 valid
  EOS leaves. Both failures were isolated as exact `invalid_eos_output` values with no
  canonical promotion. This additional evidence retains the 120-second maximum and
  requires reassessment when the model revision or prompt changes.
- D30 [inference] Makes D29's v1 implementation concrete. An authenticated fresh setup
  defaults to Codex; an unauthenticated setup defaults to local MLX; preserve a saved
  selection. Codex uses `gpt-5.6-sol`, a prompt limit of 16,384 UTF-8 bytes, 32 segments
  per batch, and an operator planning budget of 4,096. If the service hard output cap is
  unknown, record `service_managed_unavailable`. Local processing uses a prompt limit of
  2,048 bytes, 8 segments, a hard cap of 1,024, and a planning budget of 768. Before each
  call, both paths plan output as
  `base + ceil(input_bytes × 2000/1000) + per_segment`; before promotion, they recheck
  actual raw schema response bytes plus reserve. Translation is a separate create-only
  artifact that includes the canonical merged SHA-256 and every segment index exactly
  once, and cannot represent speaker or timestamp fields. An actual two-batch synthetic
  text-only round trip with `codex-cli 0.146.0` and `gpt-5.6-sol` passed this contract.
  The evidence run is
  `t7-codex-actual-20260803T230231Z-e1852cd5-0caa38d1-d9e4-4085-b9dd-59341acb6576`;
  no private recording, private transcript, or audio bytes were given to the backend.
  The record explicitly states that it did not verify the Codex read-only sandbox's
  full macOS read scope. Reassess the raw-byte coefficient and planning budget if the
  Codex CLI begins to provide exact generated-token usage reliably or the model revision
  changes.
- D31 [maintainer] Replaces D6 (decided 2026-08-04). After v1 completion and independent
  review, publish this repository as a public GitHub repository. Adding a remote and
  pushing are allowed. The public scope is every tracked file. Local working notes,
  preserved local run directories that are create-only and not part of this repository,
  real recordings, and model caches remain excluded from version control. P3, which
  states that audio never leaves the device, is an application contract rather than a
  repository-location contract and remains unchanged. At this point in the decision
  history, the README was canonically English with README.ko.md and README.it.md for
  the human-review locales en, ko, and it. The license is MIT.
- D32 [maintainer] Extends D31's documentation convention (decided 2026-08-04). The
  canonical README is English with nine localized siblings: de, es, fr, it, ja, ko, pt,
  ru, and zh-Hans. All other tracked documentation is English; detailed personal and
  session-bound records live outside the tracked tree.
- D33 [maintainer] Replaces the active Codex transport described by D5 and D30 (decided
  2026-08-04). Use the cached ChatGPT subscription authentication through an isolated
  `codex app-server` stdio session. Do not invoke `codex exec` for product correction or
  translation and do not accept an API key as fallback. Each readiness probe or text
  transformation owns one app-server process. A transformation creates one ephemeral
  read-only thread, disables tools, declines approval requests, supplies the existing
  schema and fixed `gpt-5.6-sol` model, and reaps the exact process tree. Preserve D30's
  model, prompt, batch, output-budget, and historical evidence records. New manifests
  identify the backend as `codex-app-server`; historical `codex-cli` manifests remain
  valid and decodable.

## Project-wide Done Criteria

- After D26, v1 completion additionally requires the completion judgment in the MOSS
  long-form token-budget refinement plan kept in local working notes outside the tracked
  tree. A public or synthetic long-file MOSS run must prove, in an inspectable artifact,
  the backend leaf limit, EOS for every promoted leaf, glossary application,
  chunk-boundary global speakers, model and runner fingerprints, and immutable source
  hashes.
- Swift code must pass `swift build` and `swift test` with the Xcode 26 general-release
  toolchain (D21), and new features require fixture-based tests.
- Every completion claim includes the command that ran and its observed result. A prose
  claim alone is insufficient.
- A change that downloads or runs a model must record model ID + revision + quantization
  in the manifest.
- Do not commit sensitive real recordings or model caches. Tests use only public or
  synthetic audio fixtures.
