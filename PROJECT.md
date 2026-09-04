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
4. **Do not change speakers or timestamps without acoustic evidence.** A source run's
   speaker assignments and time intervals come from acoustic evidence only; text
   post-processing, including LLM processing, cannot modify them there. Amended
   2026-09-02: a *derived* run may carry a non-acoustic speaker proposal, provided it is
   marked as a proposal, shows the acoustic candidates and their shares beside it, and
   leaves the source run untouched. Whether such a proposal may ever become the default
   reading layer is deliberately left open; see D46.
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

**How much of a real meeting must a reader re-check by ear before the record is worth
trusting?** Superseded 2026-09-02. The previous question presumed the shipped
`ko-meeting` profile could process a real recording at all; on 2026-09-01 it could not,
and the repair changed what is worth asking. One real 20.7-minute Korean meeting now
completes at 97.5 % coverage with the lost 30.56 s named. What it does not settle is
attribution: 110 of 248 merged segments carry no speaker, against a 43.4 % overlap
share and 761 diarization turns averaging 2.11 s. The acoustic evidence for most of
those segments exists and sits just under the assignment thresholds rather than being
absent. So the open question is where the remaining judgment should come from, how much
of it a reader must verify, and what a non-acoustic proposal may claim. The first
measurement of that claim, on one English AMI clip on 2026-09-04, found the model's
confirmations no more precise than the acoustic top-ranked candidate alone (11 of 15
against 15 of 19 on clear segments) and its declines mostly on segments the reference
itself calls mixed. The public component measurements still do not combine
mixed-language speech with multiple scored speakers, and `correct_to_incorrect` remains unmeasured, with one observed instance: a
glossary entry inserted twice where the speaker said something else.

## 6. Current Position

- **now**: PR #30 merged on 2026-09-03 as `e3dcc62`, a squash of twelve commits carrying
  the 2026-09-01 real-usage repairs, the layered attribution work, and D45-D52. An
  independent read-only review of that branch against this document produced 24
  findings, 6 High, 13 Medium and 5 Low; all 24 are closed in the merged tree, each
  behaviour change with a named test. Re-verified at `e3dcc62` on 2026-09-04 in a fresh
  checkout: `swift test` 533 tests in 32 suites pass, of which 6 are opt-in model and
  backend lanes that skip without their environment and 8 are offscreen render tests
  that return without asserting unless `P6_RENDER` is set and the private fixture is
  present; the ASR Python suite 38; the provisioning script suite 38; the contract
  checker passes all four schemas; 472 localized keys present in all ten locales and the
  string catalog; `git diff --check` clean; all 84 `path:line` anchors in
  `docs/terminology.md` resolve. The 20.7-minute recording still completes at
  **1212.52 s of 1243.08 s (97.5 %)** with the lost range `[871.552, 902.112) s` named
  and 248 merged segments of which 110 carry no speaker. The D50 confirm-or-decline set
  over it holds 59 confirmations and 51 declines, 26 by the model, 23 exact ties and 2
  with no overlapping turn, zero proposals naming a non-top-ranked speaker, and the
  source `merged/segments.json` is byte-identical afterwards. On 2026-09-03 the app
  bundle, driven through its model layer against a real library, imported a 7-minute
  clip and transcribed it through its own runner at 420.012 of 420.012 s in 4 of 4
  chunks, 576 s wall, 31 segments, 48 conflicts each carrying speaker evidence, 21 of
  the 31 without a speaker on a 70 % overlap passage; chunk 0 was recovered by a split
  after its first attempt looped, according to the test's own record, since the same
  test then moved the run to the Trash. No control was clicked and no live frame was
  seen. The 2026-08-31 sealed evaluations are untouched: PR #30 changed no file under
  `benchmarks/`, and their seals remain
  `hike-20260831-t7-04` `055122968710f3b3732b8eb2cd9e0c8bc8d137919b4f8ac2835bbe5b931d533d`,
  `ami-20260831-t8-02` `41336850701d0bd368aab7b726b6e32d0483303864904b3c830753f8f77a15fd`,
  `hike-20260831-t9-01` `8b5bdbccd5bb260b9c5cfb1882e8ab63b8f45ff15f38b5f5b4fa44d2f32b5b87`.
  The threshold declaration is still a placeholder, so none of this is a quality pass,
  a profile promotion, or closure of C3.
- **next** (revised 2026-09-04; the previous `next` listed review findings that the
  commit recording it had already closed): (1) the D50 confirmations and declines were
  measured on 2026-09-04 against the AMI reference, on the IN1009 audio cut to its
  annotated span, a declared subset of the sealed fixture, through the shipped profile
  and the same Codex path as the D50 set (`docs/speaker-proposal-accuracy.md`). Over
  44 unattributed segments: 24 confirmations, 20 declines; confirmation precision
  11/15 strict (0.733, 95 % interval 0.48 to 0.89) against 15/19 (0.789) for confirming
  every top-ranked candidate without a model; the four wrong confirmations are the
  four segments whose top-ranked candidate was already wrong; the twelve model declines
  fall on eight reference-mixed segments and four where the acoustics were right; read
  by hand from eight decline reasons, the speaker the conversation pointed to was right
  once against four times for the acoustics. On this clip the language layer neither
  improved nor clearly damaged the top-ranked candidate's precision, and its declines
  fell mostly where a single-speaker answer does not exist. Overturns stay disallowed;
  nothing measured argues for loosening D50. Next on this lane: the same measurement
  on a second clip with overlap, and the full-span run once batch planning splits by
  target count (see `under review`). (2) One timed human correction pass on the
  20.7-minute real meeting, recording only timing and structural metadata. It is the
  only thing that can answer the north-star question, and it was blocked until
  2026-09-04 by an app defect: the runner threw on a `partial` manifest, so the
  recording could never be opened in the app. (3) The app defects fixed on 2026-09-04
  and awaiting review on a draft branch: partial runs open as completed runs with the
  loss named on the transcript, in exports and in the sidebar; backend non-speech
  tokens (`[Silence]`, `[Human Sounds]`, `[Environmental Sounds]`) typed as non-speech
  events instead of reaching the text column as speech; the switch between two
  available layers rendered through the D48 harness; model decline reasons rendered
  with display names at read time and written in plain language; and failed-request
  scratch retention anchored on the run's lifetime. Then the carried conditions: reopen the C3 fixture only after one uninterrupted
  10-minute completion through the shipped profile, and add overlap share and
  backchannel density to its acceptance criteria when reopening, because the current
  TTS candidate is concatenated and carries 0 % overlap; keep the D43 DiCoW lane
  separate and re-aimed per D47. Do not change a model, backend, chunk, token, timeout,
  retry, fallback, or cache setting to make a measurement pass.
- **under review**: The ASR-to-diarization granularity mismatch and the merge assignment
  thresholds, where 0.60 is kept on measurement and `minimumTimelineCoverage` 0.50 is
  kept under acknowledged ignorance; the AMI four-speaker signal that the right
  dominant-share value may depend on speaker count; whether a marked non-acoustic
  speaker proposal may ever be the default reading layer (D46); per-term glossary
  insertion risk for short acronyms, with one observed false insertion, and glossary
  application that differed between two decodes of the same chunk under the same
  glossary; speaker identity and speaker count varying with the diarization window,
  since the whole file resolves 2 speakers where a 420 s clip resolves 3; raw-quality
  thresholds and a rate or scoped maximum for `correct_to_incorrect`; a decoder-level
  early abort for repetition, which would have saved roughly 10 of one run's 28 minutes
  but cannot be validated without truncating leaves that would have recovered; whether
  the failure screen's details box, which shows the engine's own message with the run
  ID, path and fingerprint stripped, satisfies the rule that no raw code reaches that
  screen; how the suite count should report tests that cannot run on a fresh clone,
  since 8 render tests pass without asserting and 6 opt-in lanes skip; whether the
  language layer earns its place at all, since on one English clip it neither improved
  nor damaged the acoustic candidate's precision while costing 12 of 36 candidates in
  coverage; speaker-proposal batch planning, which reserves tokens per target and let
  one 21-target batch overflow the output budget and lose the whole derived set, so
  batches should be split by target count rather than the budget raised; the engine's
  hallucinated text after a recording ends, six French sentences and five non-speech
  markers on the 55 s AMI tail; existing-run post-processing, which still gates on a
  complete run, so a partial run is readable but not post-processable from the app;
  Korean particle agreement after a substituted speaker name in rendered reasons;
  generalization to other accents, overlap, and noise; the Codex backend's OS-level
  read scope; and VibeVoice memory use.
- **success measure**: Retain the north-star question: can 1 important meeting become a
  reliable speaker-attributed record with no more than 30 minutes of human correction?
  Still not a current acceptance gate, because human review time has never been
  measured. The 2026-09-01 run gives the first input to it, and the 2026-09-02 inventory
  partitions it from artifacts alone: of 248 segments, 51 have no speaker and no
  proposal, 59 carry a confirmation still owed as a decision, 82 flagged rows are
  settled by the printed shares, 56 need nothing, and 30.56 s has no transcript at all.
  Under D48 that inventory sharpens the question without answering it: it carries no
  time figure, and a timed human pass, now item (2) of `next`, remains the only thing
  that can close it. Supporting observations remain reference-term recall, omitted
  utterance count, speaker-count accuracy, processing time, and human review time.

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
- D34 [maintainer] Replaces D33's authentication-custody clause (decided 2026-08-10).
  For each readiness probe or text transformation, Maccheroni reads the active native
  Codex ChatGPT credential only long enough to extract a safely unexpired access token,
  account ID, and plan type, then injects those fields through `account/login/start`
  into an app-server whose fresh mode-0700 `CODEX_HOME` contains no user configuration
  and whose credential store is forced to `ephemeral`. Maccheroni never logs, persists,
  refreshes, or modifies the credential; when safe validity cannot be proved or the
  child requests refresh, the operation fails before output promotion and directs the
  user to refresh or sign in through Codex. Native Codex remains the sole writer of its
  credential store. Promotion record (2026-08-16): the maintainer confirmed this
  decision; provenance changed from inference to maintainer without altering its
  content.
- D35 [inference] Published README benchmark results and both generated benchmark figures
  derive from `benchmarks/published-results.json` (decided 2026-08-10). Rates use
  decimal round-half-up: CER, WER, and DER display to 3 places; README term recall
  displays to 2 places; figure term recall displays to at most 3 places; counts and
  whole-second durations remain integers. The canonical VoxConverse DER is
  `0.15230835199390363` from end-to-end run
  `20260803T044246Z-cebdff`, displayed as `0.152`, because the README row describes the
  shipped VibeVoice plus Pyannote pipeline. The same fixture and scoring policy produced
  `0.15320167706894244` in standalone diarization run
  `t5-20260803-voxconverse-ppgjx-78m-community1-r1`; it remains the reversible
  alternative. Reversing this choice means changing that metric's source in the
  declaration, after which its exact value and provenance resolve together and the
  renderer and ten-README consistency check identify every publication update.
- D36 [maintainer] Republish text metrics under the declared punctuation-removal
  normalization (decided 2026-08-11). The scorer replaced Unicode punctuation with
  spaces, contradicting `docs/contracts/scoring.md` and splitting contractions and
  hyphenated forms into extra word tokens. It now deletes punctuation after NFKC and
  casefold. Published Korean VibeVoice WER changes from `0.1282051282051282` to
  `0.14102564102564102`, and Italian MOSS WER changes from `0.08064516129032258` to
  `0.0847457627118644`. CER is invariant because character scoring removes all
  whitespace after common normalization. The declaration, ten READMEs, generated
  figures, profile resource, and historical verdict summaries are republished together.
- D37 [maintainer] Supersedes D23's fallback clause (decided 2026-08-11). Qwen3-ASR is
  withdrawn as a product fallback because the pinned `speech` 0.0.23 backend exposes no
  enforceable token cap, decoder terminal reason, token counts, or intra-chunk
  timestamps, so its output cannot carry the evidence required for promotion. The
  adapter fails this path with typed `asr_evidence_unavailable` while retaining
  diagnostic evidence. Qwen3-ASR may return as a fallback when a backend version
  exposes all missing terminal, token, and timestamp evidence. D23's VibeVoice Korean
  default remains in force. Promotion record (2026-08-16): the maintainer confirmed
  this decision; provenance changed from inference to maintainer without altering
  its content.
- D38 [maintainer] Reframes public positioning from market exclusivity to personal
  configurability (decided 2026-08-12). The README family no longer claims that apps
  with local diarization do not deliver glossaries to the ASR model, that the app with
  the cleanest model-level glossary lacked diarization, that multilingual support
  almost always means one language per session, or that the combination did not exist
  at the app layer. A 2026-08-12 recheck found public counterexamples: Superwhisper
  documents recognition-time vocabulary for its local Whisper models plus offline
  speaker separation, and Transcribe Anything's pinned source forwards
  `initial_prompt` and diarization to a local WhisperX. The 2026-08-02 audit excluded
  closed-source apps, so its scope cannot support market-wide conclusions. The
  replacement framing presents Maccheroni as a personal, configurable tool whose
  per-conversation profiles pair pinned models with glossary context and a whole-file
  speaker authority, measure those pairings on public fixtures, and seal run evidence.
  Section 1 retains the dated, named 2026-08-02 audit findings as history. From this
  decision onward, comparative statements about other products require a named
  product, version, route, and evidence.
- D39 [inference] Close the glossary correction loop with immutable existing-run
  derivations (decided 2026-08-12). A completed run may create correction or
  translation sets under `derived/<derived-id>/` from its hash-verified canonical
  `merged/segments.json`. Each set has a sealed manifest that records the source run,
  source manifest and segment hashes, operation profile, current-profile glossary hash,
  backend and model, and the unchanged D30 batch evidence. Verify the source manifest
  and every listed artifact before creating a set or calling a text backend. Never run
  preprocessing, ASR, diarization, or merge for this operation, and never modify the
  source run or an earlier set. Use the current invocation profile glossary because old
  runs retain its former hash and count but not its bytes; treat a parsed zero-entry
  file as no glossary. The library selects the freshest successful set by sealed
  completion time and derived ID while keeping earlier sets visible.
- D40 [inference] Supersedes D39's current-profile-only glossary limitation
  (decided 2026-08-12). Store every non-empty glossary's exact source bytes as a
  create-only content-addressed revision at
  `<library-root>/Glossaries/Revisions/<sha256>.txt`, outside the repository and all
  immutable run directories. The mutable per-profile file remains the editor
  projection. Reuse an already verified revision for unchanged bytes and never rewrite
  or repair an existing revision path. Existing-run correction and translation default
  to the invocation profile's current glossary but may explicitly resolve the source
  manifest's recorded hash and item count. A null source hash means no glossary. A
  missing or invalid non-null revision fails as typed unavailable without substituting
  current content or reconstructing bytes. Runs made before this storage contract
  commonly have no revision and must be shown as unavailable rather than recovered.
- D41 [inference] Report storage readiness as observed per-volume facts (decided
  2026-08-12). Resolve the configured library, recording, run, model-cache, and
  backend work roots through one shared computation, group roles with Foundation's
  volume identity, and expose a localized volume name, roles, and available bytes in
  the App and doctor schema 1.1.0. Preserve missing, unmounted, unreadable, stale, and
  unavailable-bookmark states instead of substituting another volume. A measured zero
  bytes is still observable. Do not infer a minimum, headroom, quota, retention
  formula, or sufficiency verdict until a maintainer adopts that execution policy.
- D42 [maintainer] Do not prefilter open model discovery by the availability of an MLX
  or Core ML artifact (decided 2026-08-30). Rank product-aligned ASR,
  target-speaker/overlap recovery, audio preprocessing, alignment, and dense
  post-processing candidates by material user value and upstream reference evidence
  first. Treat Apple-runtime availability as delivery cost and risk, not eligibility.
  When a winning reference lacks a suitable Apple-native artifact, permit a
  project-owned MLX or Core ML conversion and the bounded serving code needed to run
  it. An experimental port that lacks end-to-end parity or drops the product evidence
  contract is not suitable merely because it loads. Portability alone is not a
  promotion reason. Before implementation, verify that the model license permits the
  intended derivative and redistribution. Pin the upstream model ID and revision,
  converter source revision, calibration-data provenance, quantization recipe, runtime
  version, and artifact hashes. Compare the converted artifact with the upstream
  reference on the same public or synthetic fixtures and apply the supported-range and
  boundary policy in `docs/engineering-constraint-policy.md`. Prefer a bounded library,
  runner, or conversion over a persistent server. D2 continues to govern all product
  execution and all private audio. A non-product upstream reference may run in an
  isolated research environment only on public or synthetic fixtures to establish
  conversion parity; it cannot become a shipped backend or receive private recordings.
  This decision does not relax D17's dense-model rule, D37's Qwen evidence gate, or the
  Section 3 non-goal against building a diarization model; a neural diarization inference
  port still requires an explicit replacement of that non-goal.
- D43 [maintainer] Start an experimental project-owned Apple conversion lane for
  `BUT-FIT/DiCoW_v3_MLC@99c64e8dc409a158816e808a1ee556cdfd0af51c` after a fresh
  Claude Code Fable Max review of product value, the smallest useful conversion
  boundary, and stop conditions (decided 2026-08-30). This authorizes inspection of the
  pinned upstream model and source, reference execution on public or synthetic audio,
  converter development, a BF16 MLX parity prototype, and the bounded research runner
  needed to verify it. Record evidence that changes the target or stops the port rather
  than forcing completion. This decision does not promote DiCoW into a product profile,
  permit private audio in a non-Apple reference runtime, replace the shipped-baseline
  repair in the Current Position, or relax D42's license, parity, evidence, and
  constraint gates.
- D44 [maintainer] Defer numerical raw-quality thresholds and a maximum
  `correct_to_incorrect` guardrail after the 2026-08-31 post-v1 reliability campaign
  (decided 2026-09-01). Keep
  `benchmarks/scripts/scoring/correction-comparison-thresholds.json` in its all-null
  placeholder state, SHA-256
  `4f90b718fd15e89b20353562cd2220020a38d308f157b2f2f5eb4f7b4de6f38e`.
  A next campaign is measurement-valid only when the immutable evaluation verifier
  passes its source, fixture, model, glossary, terminal, scorer, schema, result, and
  file-hash contracts; every planned chunk completes with an observed successful
  terminal reason; source coverage is exact and untruncated; segments are nonempty and
  valid; and source artifacts remain immutable. These are integrity gates for recording
  evidence. CER, WER, term recall, omissions, DER, processing time, and human review time
  remain observations without pass or fail, candidate promotion, profile promotion, or
  product-acceptance meaning until a separate numerical policy is adopted.

  The HiKE evidence consists of source manifest SHA-256
  `4183c7481e14c1a1b6d04531b7d9210956da9ba57d2ee7f97674527e65132bec`, score
  SHA-256 `2884f0bc20cdd0aeb0b49933622a6939214ebbfa55e9628e19b76a00a07f587d`,
  and evaluation `hike-20260831-t7-04` SHA-256
  `055122968710f3b3732b8eb2cd9e0c8bc8d137919b4f8ac2835bbe5b931d533d`.
  It measures Korean-English mixed-language ASR without scored multi-speaker
  diarization. The AMI clean IHM evidence consists of source manifest SHA-256
  `9c395f4519bce95db6121746ed89f732bb21e1cb06189e0d587813ec377f7889`, score
  SHA-256 `354366ea8607c358a18b4ae014fc2e730f794302fb61cb2dff0c5450d8ca5d34`,
  hypothesis RTTM SHA-256
  `16acc3f12f4991e07cd600f8e8a23684645ca5c84c180380ac89cbf7c28d638f`,
  and evaluation `ami-20260831-t8-02` SHA-256
  `41336850701d0bd368aab7b726b6e32d0483303864904b3c830753f8f77a15fd`.
  It measures clean English ASR and four-speaker diarization. Their component results
  cannot be combined into an end-to-end claim and do not close the mixed-language,
  multi-speaker C3 gap.

  Four-state comparison `hike-20260831-t9-01`, SHA-256
  `8b5bdbccd5bb260b9c5cfb1882e8ab63b8f45ff15f38b5f5b4fa44d2f32b5b87`,
  links no-glossary source manifest
  `4f3d64276546b482517a2654f462f6c805032740f360ad9be3791ba91d702deb`
  and derivation
  `98d8df698a08d765a4d5cbad9e93fc2dc12833f6ef4771f2cefa660d2c0d68b9`
  with decode-glossary source manifest
  `4183c7481e14c1a1b6d04531b7d9210956da9ba57d2ee7f97674527e65132bec`
  and derivation
  `6f1b9869af14435e60697461a5fbd4d59b7024d8a0be6d366d12d72661a44640`.
  All five applied changes lacked a unique reference segment with the exact interval,
  so `correct_to_incorrect` is unknown rather than zero. The current comparator also
  does not measure every way an already-imperfect segment can become worse; aggregate
  improvements cannot establish general correction safety.

  Retain the 30-minute human-correction success measure as an unmeasured north-star
  question, not a current acceptance gate. Revisit raw-quality thresholds after a
  predeclared calibration campaign and held-out or repeated observation include a
  sealed mixed-language, multi-speaker fixture. Revisit the `correct_to_incorrect`
  guardrail after both correction paths have a predeclared adequate nonzero denominator,
  every applied change is harm-scorable, and the result is scoped to a fixed campaign or
  expressed as a rate; broaden the scorer before naming it a general correction-harm
  limit. Revisit the human outcome after one timed local review that records only timing
  and structural metadata. A private real recording remains optional under D19.

- D45 [maintainer] Replaces D19's clause that a private real recording is optional final
  validation rather than a gate (decided 2026-09-02). One real-recording smoke run
  through the shipped profile is required before any quality campaign or quality claim.
  Basis: on 2026-09-01 a single 20.7-minute private recording surfaced five defects in
  minutes that 324 passing tests and two public fixtures had not, including a run that
  discarded a complete transcript and a diarization validator rejecting about half of
  all mid-file clips on an arbitrary tie-break. D19's other terms are unchanged and
  binding: no recording, transcript, or run output enters version control, and only
  structural metadata such as durations, counts, ratios, and stop reasons may be
  quoted into a tracked document. The gate is a smoke run. It asks whether the profile runs and what it produces;
  scoring the output is a separate campaign.
- D46 [maintainer] Adopt a layered reading model for speaker attribution, provisionally
  (decided 2026-09-02). The source run keeps acoustic-only assignment. A derived run may
  carry a non-acoustic speaker proposal, including one from an LLM, when it is marked as
  a proposal, carries the acoustic candidates and their shares beside it, and leaves the
  source untouched. Judgment rule 4 is amended to that effect and judgment rules 3 and 5
  are unchanged. Order matters and is part of this decision: first disclose the ranked
  candidates and per-candidate shares that `TimelineMerger.speakerAssignment` already
  computes and discards, then re-examine the 0.60 dominant-share and 0.50 coverage
  thresholds against real overlap, and only then apply a non-acoustic proposal to what
  remains. Basis: on the 2026-09-01 run 110 of 248 segments carry no speaker, and the
  measured cases sit just below the thresholds rather than lacking evidence, so disclosure
  closes most of the gap before any inference is needed. This decision deliberately does not settle
  whether a proposal may become the default reading layer, which model produces it, or
  what it may claim. Revisit when the disclosure and threshold work lands and the
  remaining unattributed share is known, or if any measured `correct_to_incorrect` rate
  suggests a non-acoustic proposal harms more than it helps.
- D47 [maintainer] Re-aim the D43 DiCoW conversion lane's value question at
  overlap-region speaker attribution rather than mixed-language ASR (decided 2026-09-02).
  This does not promote DiCoW into a product profile and does not schedule the lane.
  Basis: the 2026-09-01 recording carries a 43.4 % overlap share, and the attribution gap
  is concentrated where speakers overlap, which is the property that lane could speak to.

- D48 [maintainer] Verification of app-facing and taste-shaped work is done by the agent
  inspecting rendered artifacts, not by the maintainer acting as the instrument (decided
  2026-09-02). Basis: the maintainer is not a specialist in transcript-reading interface
  design, and three app surfaces shipped on 2026-09-01 with test-level evidence only
  because the agent environment has no Screen Recording or Accessibility permission and
  `screencapture` fails with `could not create image from display`. Offscreen rendering
  needs neither permission: the package targets `.macOS(.v26)` and the app test target
  links the app module, so SwiftUI's `ImageRenderer` can rasterise a view with no window
  server. The standing expectation is therefore that a screen is rendered to an image
  from real fixture data, at more than one width and in both appearances, and that the
  agent reads the image back and names concrete defects or states why it found none.
  "It looks fine" is not a report. This does not move any decision away from the
  maintainer, who still owns intent, pillars, non-goals and judgment rules; it moves the
  act of looking. It also does not close anything that genuinely requires a human: human
  correction time in particular stays unmeasured and cannot be estimated into existence,
  and an agent-produced effort estimate must say so rather than stand in for it.
  Known limits, recorded 2026-09-02 after the first use: SwiftUI's offscreen renderer
  returns nothing for content inside a `ScrollView`, `List` or grouped `Form`, and
  draws `TextField`, `Slider` and AppKit-backed button styles as placeholders. Views
  must be structured so their content can be rendered outside a scroll container, and
  text fields, sliders and hover-revealed affordances remain unjudged by this method.
  A report under D48 states which controls it could not see rather than implying full
  coverage. Amended 2026-09-02, second use: laying the view out in an `NSHostingView`
  and drawing it with `cacheDisplay(in:to:)` renders text fields, sliders, scroll-view
  content, grouped forms and spinners, under the same permissions budget. `List` still
  renders blank. The hosting-view path is the one to use; `ImageRenderer` remains
  acceptable only for views that contain none of those controls.

- D49 [maintainer] Extend D39 so a derived set may be created from a run whose coverage
  is incomplete, for the speaker-proposal family only (decided 2026-09-02). D39 says a
  *completed* run may create correction or translation sets; the real 20.7-minute
  recording is `status: partial` with 30.56 s missing, so under D39 alone it could never
  carry the layer D46 exists to enable. Every integrity check D39 requires is kept:
  source manifest and artifact hash verification, inventory, merged-document validity,
  the required artifact set, immutability of the source run and of earlier sets, and no
  preprocessing, ASR, diarization or merge. `verifyCompletedRun` itself is unchanged, so
  correction and translation keep their existing gate; the extension is a sibling entry
  point. Two conditions, both of which exist because a proposal over an incomplete
  transcript that presents as complete would be the same class of false claim the
  2026-09-01 repairs removed: the derived manifest records whether the source coverage
  was complete, and the covered and missing durations travel with that flag. Revisit if a derived family other than speaker-proposal wants the same
  relaxation, which should be argued separately rather than inherited.

- D50 [maintainer] Constrain the first speaker-proposal iteration to confirm-or-decline
  (decided 2026-09-02). On the first real proposal run over the 2026-09-01 recording,
  110 unattributed segments produced 99 proposals and 11 declines; of the 99, 76
  agreed with the top-ranked candidate (the speaker with the largest overlap share, below the
  0.60 bar) and 23 did not. Basis corrected the same day: those 23 were not overturns
  of a clear lean — every one was an exact overlap tie with no top-ranked candidate to
  contradict, and the model had picked one side of the tie. A tie-break is still a
  speaker assignment resting on no acoustic evidence, which is what judgment rule 4 was
  written against and the distortion the maintainer named when proposing this
  direction; the correction changes the description of the 23, not the decision. With no ground truth to tell a correct overturn from a
  plausible wrong one, the first iteration permits a proposal only when it names the
  top-ranked candidate, and otherwise declines with its reason. The 76 confirmations alone
  fill about 69 % of the unattributed segments. Overturns become permissible only after
  a measurement shows they are right more often than wrong, which is a separate
  campaign. D46's provisional status and revisit triggers are unchanged.
- D51 [maintainer] A run that loses one leaf keeps everything else, on every backend
  (decided 2026-09-02). Before this, a leaf that exhausted split recovery aborted the
  whole run before merge and discarded every completed chunk; on the 2026-09-01
  recording, 30.56 s of unrecoverable audio destroyed sixteen minutes of correct
  transcript, and the manifest reported `status: partial` with a processed duration
  while no transcript existed anywhere. The abort path was generic, so the repair
  applies to MOSS as well as VibeVoice; the MOSS behaviour it replaces was asserted by a
  test but recorded in no decision, and D28 governs MOSS leaf durations only. D28's
  bounds, depth 3, the token cap and the promotion conditions are unchanged. A run now
  fails outright only when nothing anywhere was promotable, `partial` is written only
  when canonical artifacts exist, and `processed_duration_s` sums every promoted range
  rather than stopping at the first gap. Recorded as a decision because it reverses a
  prior assertion that a test had made on purpose.

- D52 [maintainer] A renamed wire value keeps its legacy value accepted on read, and a
  sealed artifact is never rewritten to follow a rename (decided 2026-09-02). Basis: the
  2026-09-02 terminology audit renamed the failure code `ASR_REPETITION_DEGENERATION`
  to `ASR_REPETITION_LOOPING` and the proposal key `acoustic_leader` to
  `top_ranked_candidate`. The first rename silently regressed every run written
  before it — the app's classifier accepted only the new code, so a sealed manifest
  carrying the old one lost its specific cause and its stopped-at stage on screen. The
  second was migrated on disk in the private working directory, and the migration was
  incomplete on its first pass because the derived set's manifest still carried the
  pre-migration content hash, so the app rejected the set with `artifactHashMismatch`
  until the hash was refreshed; the integrity check did its job. Rule: a reader accepts
  the legacy value at the same case as the new one, with a comment naming the rename;
  judgment rule 3 governs artifacts, so a sealed manifest is read through the alias
  and left byte-identical. Where a private artifact must be migrated for local use,
  every hash that seals it is refreshed in the same step and the original is kept
  beside it.

## Project-wide Done Criteria

- After D26, v1 completion additionally requires the completion judgment in the MOSS
  long-form token-budget refinement plan kept in local working notes outside the tracked
  tree. A public or synthetic long-file MOSS run must prove, in an inspectable artifact,
  the backend leaf limit, glossary application, chunk-boundary global speakers, model and
  runner fingerprints, and immutable source hashes. Restated 2026-09-02: the former "EOS
  for every promoted leaf" is now checked as `primary/promotion.json` listing every
  attempt in exactly one of `eos_leaf_attempt_ids` or `partial_prefix_attempt_ids`, with
  `partial_prefix_attempt_ids` empty. Prefix promotion means a promoted leaf may not have
  reached end of sequence, so the criterion is made checkable rather than loosened; a run
  with a promoted prefix states so instead of being counted as fully EOS.
- Swift code must pass `swift build` and `swift test` with the Xcode 26 general-release
  toolchain (D21), and new features require fixture-based tests.
- Every completion claim includes the command that ran and its observed result. A prose
  claim alone is insufficient.
- A change that downloads or runs a model must record model ID + revision + quantization
  in the manifest.
- Do not commit sensitive real recordings or model caches. Tests use only public or
  synthetic audio fixtures.
