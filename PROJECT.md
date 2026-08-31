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

**Can the shipped `ko-meeting` profile produce a reliable mixed-language,
multi-speaker record with every applied correction aligned to reference evidence?** The
2026-08-31 HiKE run verifies mixed-language ASR and decoding-time glossary use. The AMI
IN1009 clean IHM mix verifies long-form ASR and one global four-speaker timeline. These
are separate component measurements: neither fixture combines mixed-language speech
with multiple scored speakers, and neither measures human correction time. The
four-state correction comparison observed aggregate CER and WER improvements, but all
five applied changes were unscorable under exact-interval reference alignment.
`correct_to_incorrect` and broader per-change regression therefore remain unknown. A
valid next measurement campaign needs one sealed C3 condition that combines the two
speech properties, complete structural evidence, scorable correction changes, and a
predeclared calibration method with held-out or repeated observation.

## 6. Current Position

- **now**: The 2026-08-31 post-v1 reliability reset is merged on the default branch with
  fresh-cache `ko-meeting` provisioning, cache-independent tests, bounded subprocess
  fixtures, immutable evaluation envelopes, correction comparison, and reproducible
  Stage 2 fixture construction. Two consecutive empty-cache Swift runs passed 324 tests
  in 25 suites. The explicit model integration, package build, strict codesign, and
  product doctor also passed. Unpublished evaluation `hike-20260831-t7-04` is sealed by
  SHA-256 `055122968710f3b3732b8eb2cd9e0c8bc8d137919b4f8ac2835bbe5b931d533d`;
  unpublished evaluation `ami-20260831-t8-02` by
  `41336850701d0bd368aab7b726b6e32d0483303864904b3c830753f8f77a15fd`;
  and unpublished comparison `hike-20260831-t9-01` by
  `8b5bdbccd5bb260b9c5cfb1882e8ab63b8f45ff15f38b5f5b4fa44d2f32b5b87`.
  Exact metrics remain local. The threshold declaration remains a placeholder, so none
  of these observations is a quality pass, profile promotion, product acceptance, or
  closure of C3.
- **next**: Add or select a public mixed-language, multi-speaker C3 fixture. Run a
  measurement-only campaign through the fixed shipped profile with a predeclared
  calibration method and held-out or repeated observation. Make every applied
  correction alignable to reference evidence and record a nonzero adequate denominator
  for both correction paths. Keep the D43 DiCoW conversion lane separate from this
  shipped-baseline campaign. Do not change a model, backend, chunk, token, timeout,
  retry, fallback, or cache setting to make the measurement pass.
- **under review**: Raw-quality thresholds and their campaign scope; a rate or scoped
  maximum for `correct_to_incorrect`; broader per-change regression measurement;
  generalization to real-meeting accents, overlap, and noise; the Codex backend's
  OS-level read scope; the output coefficient for new models; and VibeVoice memory use.
- **success measure**: Retain the north-star question: can 1 important meeting become a
  reliable speaker-attributed record with no more than 30 minutes of human correction?
  The current public component measurements did not measure human review time, so this
  is not a current acceptance gate. Supporting observations remain reference-term
  recall, omitted utterance count, speaker-count accuracy, processing time, and human
  review time.

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
