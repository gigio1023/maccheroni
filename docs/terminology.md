# Project Terminology

One meaning per term, fixed by one place in the tree. This document exists
because the same word has been used for different things across `PROJECT.md`,
the contracts, the code, and working notes: a chunk is not a leaf, a limit
outcome is not a limit exhaustion, a backend's speaker label is not a speaker,
and hitting the token cap is not the same event as a decoder that fell into a
repeating loop.

Every entry gives a one-line definition and a `path:line` pointer to the
definition site, meaning a type, an enum case, a schema field, or the policy
paragraph that fixes the meaning, in preference to any use site. Anchors were
re-verified against the working tree on 2026-09-04 by opening each line and
checking that the named symbol sits on it. When a definition site moves, move
the anchor rather than dropping the term.

Every entry also carries one marker. **[field]** means the term has a published
definition outside this project and is used here in that sense. **[project]**
means the project coined the term or narrowed it, and the entry names the
nearest field term so a reader can translate. A coinage is kept only where the
field has no word for the distinction the project needs.

## Run model

- **run** [project]: One transcription of one input audio file into one
  create-only run directory, recorded by a single `manifest.json`. The ordinary
  word, narrowed here to exactly that unit.
  `Sources/MaccheroniCore/Contracts.swift:603`
- **derived run** [project]: A sealed operation computed from a source run's
  verified `merged/segments.json`, written under `derived/<derived-id>/` with
  its own manifest. The source was required to be complete until D49; a
  speaker-proposal set may now derive from a partial source, and its manifest
  then records the covered and missing durations. It never modifies the source
  run. The "derived" half is standard provenance vocabulary — W3C PROV-O's
  `prov:wasDerivedFrom`, and the code's own lineage type carries the same word —
  while the run-level artifact is the project's.
  `Sources/MaccheroniCore/DerivedRuns.swift:306` for the manifest,
  `Sources/MaccheroniCore/DerivedRuns.swift:9` for the lineage that binds it to
  the source, `docs/contracts/run-layout.md:53`
- **`DerivedOperationKind`** [project]: What a derived run produced: a text
  operation over the transcript, `text-postprocess`, or a marked non-acoustic
  speaker proposal over segments the source left unattributed,
  `speaker-proposal`. Read `kind` to decide what a derived run is, and read
  `mode` only after `kind` says a text operation ran, because a speaker-proposal
  manifest still carries a non-optional `mode`. The field has no term: this
  discriminates two derived families the project invented.
  `Sources/MaccheroniCore/DerivedRuns.swift:106`
- **evaluation envelope** [project]: The immutable JSON record binding one
  acceptance-pack score to the exact fixture, source run file set, model tuple,
  runner evidence, glossary, scorer file hashes, and result hash that produced
  it. Verification reconstructs it and rejects any difference. Both halves of
  the name are field-shaped — W3C PROV-O covers the provenance binding, and
  "envelope" for a wrapper carrying a payload plus its metadata is the SOAP
  sense — and the compound is the project's.
  `benchmarks/scripts/scoring/check_acceptance_evaluation.py:1651`
- **chunk** [project]: A product-level work unit of the preprocessing plan: a
  contiguous time range of the input, cut at silence where one is available,
  carried in the manifest with a status. The ASR field calls any such unit a
  chunk, a window or a segment; this project reserves the word for the
  product-level unit. `Sources/MaccheroniPreprocess/ChunkPlanner.swift:8`,
  `Sources/MaccheroniCore/Contracts.swift:536`
- **leaf** (inference leaf) [project]: A contiguous, half-open PCM sample range
  submitted to exactly one backend invocation, addressed by sample index rather
  than by timestamp. The field would call this a chunk or a window as well,
  which is why the two are separated here.
  `Sources/MaccheroniPreprocess/ChunkPlanner.swift:136`
- **chunk versus leaf** [project]: Separate concepts. A chunk describes
  product-level work; a leaf describes one backend invocation. The separation is
  stated at the boundary-source types.
  `Sources/MaccheroniPreprocess/ChunkPlanner.swift:123`
- **initial leaf** [project]: A leaf from the first plan, at depth 0. The
  initial plan covers every sample of the input exactly once.
  `Sources/MaccheroniPreprocess/ChunkPlanner.swift:208`
- **recovery leaf** [project]: One of the two children produced by splitting a
  limit-failed parent leaf. Depth increases by one, both children are strictly
  smaller than the parent, and already completed siblings are never re-planned.
  `Sources/MaccheroniPreprocess/ChunkPlanner.swift:261`
- **leaf policy** [project]: The per-backend bounds that govern leaf planning:
  sample rate, minimum, preferred and maximum initial duration, minimum recovery
  duration, maximum recovery depth, and token budget. A composite of *leaf*, so
  the field names no equivalent.
  `Sources/MaccheroniCLI/CLIApplication.swift:59` for the type,
  `Sources/MaccheroniCLI/CLIApplication.swift:72` for the per-backend values,
  `Sources/MaccheroniPreprocess/ChunkPlanner.swift:169` for the planner-side
  shape.

## Termination and promotion

- **stop reason** [field]: The decoder condition a pinned ASR helper reports for
  one leaf. Four values exist; serialized as `stop_reason`, which is the
  field's own name for it. Anthropic's Messages API calls it `stop_reason`;
  OpenAI's Chat Completions API calls the same field `finish_reason`.
  `Sources/MaccheroniASR/ASRAdapters.swift:167`
- **`endOfSequence`** [field]: The decoder emitted end of sequence before
  reaching the output cap. The only stop reason a complete result may carry.
  `Sources/MaccheroniASR/ASRAdapters.swift:168`
- **`maximumTokens`** [field]: Generation stopped at the requested output cap,
  the stop the field spells `length` or `max_tokens`. On the VibeVoice path this
  is inferred rather than reported: `mlx-audio` consumes EOS without yielding
  it, so exhausting the generator produces exactly `max_tokens` tokens.
  `Sources/MaccheroniASR/ASRAdapters.swift:169`, inferred at
  `Sources/MaccheroniASR/Python/maccheroni_asr_runner.py:950`
- **`contextLimit`** [field]: Generation stopped at the model's context
  capacity. Only the MOSS path can report it; VibeVoice through `mlx-audio`
  0.4.6 exposes no context hard cap and records `null` plus an unavailable
  reason. `Sources/MaccheroniASR/ASRAdapters.swift:170`,
  `docs/engineering-constraint-policy.md:483`
- **`repetitionLooping`** [project]: The dedicated stop reason for
  repetition looping, added 2026-09-01: the decoder stopped producing new
  content and repeated one token or a short phrase to the end of generation. It
  is a limit outcome like the other two, and the recovered prefix travels with
  it in `ASRLimitRecord.partialPrefix`. See *repetition looping* under Failure
  modes. `Sources/MaccheroniASR/ASRAdapters.swift:176`
- **limit outcome** [project]: An attempt that ended on any stop reason other
  than `endOfSequence`. It carries no complete transcript: the caller splits and
  retries the audio range rather than promoting partial text, and only a spent
  range may promote a recovered prefix. The field names the individual values,
  `length` and `max_tokens`, and has no name for the class, which this project
  needs because the class is what decides recovery.
  `Sources/MaccheroniASR/ASRAdapters.swift:205` for the test,
  `Sources/MaccheroniASR/ASRAdapters.swift:250` for the record it carries.
- **limit exhausted** [project]: The state an attempt reaches when its limit
  outcome cannot be recovered: recovery is unavailable for the backend, the
  depth budget is spent, or a child would fall below the minimum recovery
  duration. The ordinary phrasing is *retry budget exhausted*. Under D51 an
  exhausted leaf loses its own range and no more.
  `Sources/MaccheroniCLI/CLIApplication.swift:390` for the attempt status,
  decided at the recovery gate
  `Sources/MaccheroniCLI/CLIApplication.swift:2979`. The error code follows the
  backend and the stop reason: `MOSS_LIMIT_EXHAUSTED` on MOSS,
  `ASR_REPETITION_LOOPING` for a repetition stop on any other backend, and
  `ASR_LIMIT_EXHAUSTED` otherwise.
  `Sources/MaccheroniCLI/CLIApplication.swift:2812` for the branch,
  `Sources/MaccheroniCLI/CLIApplication.swift:39` for the codes.
- **canonical promotion** [project]: Moving an attempt result into the run's
  canonical artifacts, allowed only after every promotion condition passes: the
  full planned range processed, a completion stop reason, schema and timestamp
  range validated, glossary and language contract evidence present, model and
  runner identity recorded, and the source hash unchanged. "Promotion" is
  borrowed from CI/CD artifact promotion and used in that sense; the compound is
  the project's, and the field has no term for promoting the leading valid
  portion of a truncated decode, which this project calls **prefix promotion**
  and lists apart in `primary/promotion.json`.
  `docs/engineering-constraint-policy.md:222` for the conditions,
  `Sources/MaccheroniCLI/CLIApplication.swift:656` for the sealed
  `CanonicalPromotionRecord`, and
  `Sources/MaccheroniCLI/CLIApplication.swift:434` for the per-attempt flag.
- **coverage** [project]: How much of the input was actually processed: input
  duration, processed duration, truncation flag, strategy, and chunks planned
  against chunks completed. This is the run-level sense; the per-segment
  quantity is *timeline coverage* below.
  `Sources/MaccheroniCore/Contracts.swift:493`
- **truncated** [project]: The coverage flag stating that processed duration is
  short of input duration. It states a fact in the manifest. A run is not
  complete because it is set. `Sources/MaccheroniCore/Contracts.swift:496`

## Failure modes

- **repetition looping** [field]: An autoregressive decoder that stops producing
  new content and repeats one token or a short phrase until the output cap.
  Radford et al., "Robust Speech Recognition via Large-Scale Weak Supervision",
  ICML 2023 (arXiv:2212.04356), names beam search and temperature fallback as
  heuristics that reduce repetition looping in long-form transcription. The
  broader phenomenon is *neural text degeneration*: Holtzman, Buys, Du, Forbes
  and Choi, "The Curious Case of Neural Text Degeneration", ICLR 2020
  (arXiv:1904.09751). It is not the same event as a transcript that legitimately
  reaches the cap with real content, and its signature differs: the raw backend
  payload carries `"segments": []` after a correct prefix, because the
  transcript array was never closed. A leaf whose generation entered a loop is
  called a **collapsed leaf**, the project's short form for the same thing.
  Since 2026-09-01 the condition has a dedicated stop reason,
  `repetitionLooping` at `Sources/MaccheroniASR/ASRAdapters.swift:176`, and
  a run-level error code, `ASR_REPETITION_LOOPING` at
  `Sources/MaccheroniCLI/CLIApplication.swift:41`. The detector is
  `repetition_run_length`, the longest run
  of consecutive identical 1-to-8-gram units,
  `Sources/MaccheroniASR/Python/maccheroni_asr_runner.py:673`, with its
  threshold of 12 at
  `Sources/MaccheroniASR/Python/maccheroni_asr_runner.py:51` and the threshold
  test `is_repetition_looping` at
  `Sources/MaccheroniASR/Python/maccheroni_asr_runner.py:703`. It cannot see a
  phrase longer than eight units cycling. The distinguishing
  evidence is preserved whole in `primary/chunks/<index>/backend.raw`,
  `Sources/MaccheroniCLI/CLIApplication.swift:2057`.
- **long-form hallucination** [field]: Output that is fluent and structurally
  plausible but not grounded in the audio, appearing as input length grows.
  "Hallucination" is universal in the generation literature and "long-form" is
  the ASR field's word for whole-file transcription (Radford et al. 2023). It
  still has no dedicated symbol here. The closest recorded surface is the
  structural-completeness constraint, where longer leaves reported an
  `endOfSequence` stop but lost timestamp markers and produced no verifiable
  segments; that condition closes the attempt as `invalid_eos_output` and keeps
  the raw output as a diagnostic artifact only.
  `docs/engineering-constraint-policy.md:433`,
  `Sources/MaccheroniCLI/CLIApplication.swift:393`
- **silent truncation** [project]: Dropping input beyond a backend's duration
  limit without failing or splitting. Prohibited: input beyond the limit must
  fail explicitly or produce a split plan. The ordinary term is *silent data
  loss*, which is the wording of the judgment rule itself. `PROJECT.md:82`

## Diarization and merge

- **diarization timeline** [field]: The speaker timeline computed once over the
  complete original audio, before enhancement, and used for the whole run.
  `Sources/MaccheroniCore/Contracts.swift:104`,
  `docs/contracts/run-layout.md:111`
- **turn** [field]: One entry of that timeline: one speaker label over one
  contiguous interval, with optional confidence. Standard in conversation
  analysis and in diarization; the contract type is `TimelineSegment`.
  `Sources/MaccheroniCore/Contracts.swift:84`; the
  merger names the same value `turn` at
  `Sources/MaccheroniMerge/TimelineMerger.swift:529`, and the scoring side reads
  RTTM turns at `benchmarks/scripts/scoring/rttm.py:10`.
- **overlap share** [project]: Two quantities carry this name. Use the full
  sub-term so a reader knows which one is meant.
  - **segment overlap share**: for one ASR segment, the fraction of its total
    clipped speaker-overlap time held by the top-ranked candidate. Attribution
    requires it to reach `dominantSpeakerShare`, 0.60 by default.
    `Sources/MaccheroniMerge/TimelineMerger.swift:74`, threshold at
    `Sources/MaccheroniMerge/TimelineMerger.swift:203`.
  - **recording overlap share**: the share of speech time in which two or more
    speakers are concurrently active, a property of the recording rather than of
    one segment. The field term for this sense is *overlapped speech ratio*, as
    reported in the DIHARD challenge summaries. The concurrency test behind it
    is `hasConcurrentDistinctSpeakers`,
    `Sources/MaccheroniMerge/TimelineMerger.swift:624`.
- **timeline coverage** [project]: For one ASR segment, the union of the
  diarization turns clipped to it, over the segment's duration. Attribution
  requires it to reach `minimumTimelineCoverage`, 0.50 by default. It is the
  per-segment sense of *coverage*, and the field has no single name for it.
  `Sources/MaccheroniMerge/TimelineMerger.swift:131`, threshold at
  `Sources/MaccheroniMerge/TimelineMerger.swift:204`, applied at
  `Sources/MaccheroniMerge/TimelineMerger.swift:578`.
- **order normalization** [project]: Putting diarization turns that start at the
  identical timestamp into the order the run artifact contract asks for, earlier
  end point first, and recording every turn that moved. Only array position
  changes; the speaker and both timestamps are carried through untouched. The
  field phrase is *canonical ordering*, or a *deterministic tie-break*; the
  project keeps its own name because the shipped artifact
  `diarization/order-normalizations.json` already carries it.
  `Sources/MaccheroniDiarize/DiarizationAdapters.swift:99`, written at
  `Sources/MaccheroniCLI/CLIApplication.swift:1968`.
- **merge** [project]: Joining chunked ASR output with the whole-file
  diarization timeline by timestamp, producing `merged/segments.json` and
  `merged/conflicts.json`. The ordinary word, fixed here to that one stage.
  `Sources/MaccheroniMerge/TimelineMerger.swift:244`,
  `docs/contracts/run-layout.md:114`
- **speaker attribution** [field]: Deciding which global speaker owns one ASR
  segment. It yields `UNKNOWN` when no timeline speaker overlaps the segment,
  when timeline coverage of the segment falls below `minimumTimelineCoverage`,
  or when no speaker's segment overlap share is dominant; the ranked candidates
  are preserved in the conflict record either way. Which branch it took is the
  segment's **attribution outcome**.
  `Sources/MaccheroniMerge/TimelineMerger.swift:520`, outcomes at
  `Sources/MaccheroniMerge/TimelineMerger.swift:54`.
- **backend speaker evidence** [project]: A backend's own per-segment speaker
  label. It never becomes the segment's speaker: it is reduced to the flag
  `backend_speaker_evidence` while `speaker` stays `UNASSIGNED` until merge
  attributes it. The field has *speaker-attributed ASR* for the capability
  (Kanda et al., Interspeech 2020 and 2021) and no term for a label withheld
  from authority on purpose. `Sources/MaccheroniASR/ASRAdapters.swift:858`
- **global speaker namespace** [project]: The single set of speaker IDs produced
  by running diarization once over the complete file. Every chunk's segments are
  attributed into that one namespace; per-chunk speaker labels are never a
  namespace of their own. `UNASSIGNED` means not yet attributed and `UNKNOWN`
  means attribution was attempted and refused; neither counts toward
  `num_speakers`. The field's framing is *global* against *local*, meaning
  per-window, speaker labels, so *global speaker label space* would be closer;
  "namespace" is the one word here imported from programming. `PROJECT.md:49`,
  `docs/contracts/run-layout.md:248`
- **confirm-or-decline** [project]: The constraint D50 places on the first
  speaker-proposal iteration. A proposal may confirm the top-ranked candidate,
  the one holding the largest segment overlap share below the bar that would
  have assigned it, or it declines and records its reason. It may never name
  another speaker. Human-in-the-loop labelling calls the analogous restriction
  *verification-only*.
  `Sources/MaccheroniPostprocess/Postprocess.swift:411`, decided at
  `PROJECT.md:644`.

## Glossary

- **glossary injection mode** [project]: How glossary terms reach the backend at
  decode time. Each backend requires exactly one mode and a mismatch is rejected
  before execution. The field calls the capability *contextual biasing*; the
  one-mode-per-backend requirement is the project's.
  `Sources/MaccheroniCore/Contracts.swift:378`, per-backend requirement at
  `Sources/MaccheroniASR/ASRAdapters.swift:52`
- **`free_text_context`** [project]: Terms enter the backend's free-text context
  prompt. Required by VibeVoice and Qwen3, whose adapters ask for
  `freeTextContext`. `Sources/MaccheroniCore/Contracts.swift:380`,
  `Sources/MaccheroniASR/ASRAdapters.swift:54`
- **`hotword_instruction`** [project]: Terms enter the backend as a hotword
  instruction. Required by MOSS, whose adapter asks for
  `hotwordInstruction`. "Hotword" is the field's word for a biasing term; the
  mode name is the project's. `Sources/MaccheroniCore/Contracts.swift:381`,
  `Sources/MaccheroniASR/ASRAdapters.swift:55`
- **term recall** [project]: Matched reference occurrences divided by reference
  occurrences, where the denominator counts only terms actually spoken in the
  reference and each term's match count is the smaller of its reference and
  hypothesis counts. `null` when the denominator is 0. Contextual-biasing ASR
  scores the same question with biased and unbiased WER, and "keyword recall" is
  used informally, but no published definition matching this one was confirmed,
  so the project's definition stands on its own.
  `benchmarks/scripts/scoring/metrics.py:152`, protocol at
  `docs/contracts/scoring.md:19`
- **`correct_to_incorrect`** [project]: The count of applied correction changes
  whose raw text had zero CER errors and zero WER errors and whose corrected
  text is worse on both. It measures correction harm, not correction gain, and
  its numerical guardrail is deferred. Grammatical error correction and
  post-editing evaluation know the concept under names such as
  *over-correction*, and no single established name was confirmed.
  `benchmarks/scripts/scoring/score_corrected.py:905`, project status in
  decision D44 at `PROJECT.md:511`

## Measurement

- **CER** [field]: Levenshtein error rate over Unicode characters after NFKC,
  casefold, punctuation removal, and whitespace removal. The primary text metric
  for Korean and mixed Korean-English tracks. Both rates come from one
  `text_error_rate`. `benchmarks/scripts/scoring/metrics.py:90`, protocol at
  `docs/contracts/scoring.md:63`
- **WER** [field]: The same Levenshtein error rate over whitespace-delimited
  tokens, from the same `text_error_rate`. Korean spacing distorts it, so it is
  a reference value rather than the primary metric on Korean tracks.
  `benchmarks/scripts/scoring/metrics.py:90`, `docs/contracts/scoring.md:63`
- **DER** [field]: `(miss + false_alarm + confusion) / reference_speaker_time`
  under the fixed NIST Rich Transcription protocol: 0.25-second total collar,
  overlap excluded from primary DER, and hypothesis speakers mapped one-to-one
  to reference speakers over the whole file rather than per chunk. Computed by
  `diarization_error_rate`. `benchmarks/scripts/scoring/rttm.py:109`,
  protocol at
  `docs/contracts/scoring.md:77`
- **ablation** [field]: A comparison in which exactly one condition differs
  between two otherwise identical sealed runs, so the difference in the metric
  is attributable to that condition. The tracked example is the paired
  `COMPARISON_ENDPOINTS` correction comparison.
  `benchmarks/scripts/scoring/compare_correction_paths.py:33`
- **held-out observation** [field]: An observation made on data that was not
  used to choose the method, the threshold, or the condition being judged.
  Required, together with a predeclared calibration method, before a measurement
  campaign can support a quality claim. `PROJECT.md:560`

## Identity

- **model identity** [project]: HF model ID plus revision plus quantization. All
  three are required and a parameter-count alias is not an identifier, because
  the same weights have been published as 7B, 8B, and 9B. The field names the
  three parts; requiring all of them together as the identifier is judgment rule
  8. `PROJECT.md:104` for the judgment rule,
  `Sources/MaccheroniCore/Contracts.swift:359` for the recorded form.
