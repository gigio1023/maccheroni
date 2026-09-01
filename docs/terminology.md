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
verified against commit `f3f4cd1`. When a definition site moves, move the anchor
rather than dropping the term.

## Run model

- **run**: One transcription of one input audio file into one create-only run
  directory, recorded by a single `manifest.json`.
  `Sources/MaccheroniCore/Contracts.swift:603`
- **derived run**: A sealed correction or translation computed from an already
  completed run's verified `merged/segments.json`, written under
  `derived/<derived-id>/` with its own manifest. It never modifies the source
  run. `Sources/MaccheroniCore/DerivedRuns.swift:79`,
  `docs/contracts/run-layout.md:49`
- **evaluation envelope**: The immutable JSON record binding one acceptance-pack
  score to the exact fixture, source run file set, model tuple, runner evidence,
  glossary, scorer file hashes, and result hash that produced it. Verification
  reconstructs it and rejects any difference.
  `benchmarks/scripts/scoring/check_acceptance_evaluation.py:1651`
- **chunk**: A product-level work unit of the preprocessing plan: a contiguous
  time range of the input, cut at silence where one is available, carried in the
  manifest with a status. `Sources/MaccheroniPreprocess/ChunkPlanner.swift:8`,
  `Sources/MaccheroniCore/Contracts.swift:536`
- **leaf** (inference leaf): A contiguous, half-open PCM sample range submitted
  to exactly one backend invocation, addressed by sample index rather than by
  timestamp. `Sources/MaccheroniPreprocess/ChunkPlanner.swift:136`
- **chunk versus leaf**: Deliberately separate concepts, not synonyms: a chunk
  describes product-level work, a leaf describes one backend invocation. The
  separation is stated at the boundary-source types.
  `Sources/MaccheroniPreprocess/ChunkPlanner.swift:123`
- **initial leaf**: A leaf from the first plan, at depth 0. The initial plan
  covers every sample of the input exactly once.
  `Sources/MaccheroniPreprocess/ChunkPlanner.swift:208`
- **recovery leaf**: One of the two children produced by splitting a
  limit-failed parent leaf. Depth increases by one, both children are strictly
  smaller than the parent, and already completed siblings are never re-planned.
  `Sources/MaccheroniPreprocess/ChunkPlanner.swift:261`
- **leaf policy**: The per-backend bounds that govern leaf planning: sample
  rate, minimum, preferred and maximum initial duration, minimum recovery
  duration, maximum recovery depth, and token budget.
  `Sources/MaccheroniCLI/CLIApplication.swift:48` for the type,
  `Sources/MaccheroniCLI/CLIApplication.swift:61` for the per-backend values,
  `Sources/MaccheroniPreprocess/ChunkPlanner.swift:169` for the planner-side
  shape.

## Termination and promotion

- **terminal reason**: The decoder condition a pinned ASR helper reports for one
  leaf. Exactly three values exist; serialized as `stop_reason`.
  `Sources/MaccheroniASR/ASRAdapters.swift:167`
- **`endOfSequence`**: The decoder emitted end of sequence before reaching the
  output cap. The only terminal reason a complete result may carry.
  `Sources/MaccheroniASR/ASRAdapters.swift:168`
- **`maximumTokens`**: Generation stopped at the requested output cap. On the
  VibeVoice path this is inferred rather than reported: `mlx-audio` consumes EOS
  without yielding it, so exhausting the generator produces exactly `max_tokens`
  tokens. `Sources/MaccheroniASR/ASRAdapters.swift:169`, inferred at
  `Sources/MaccheroniASR/Python/maccheroni_asr_runner.py:727`
- **`contextLimit`**: Generation stopped at the model's context capacity. Only
  the MOSS path can report it; VibeVoice through `mlx-audio` 0.4.6 exposes no
  context hard cap and records `null` plus an unavailable reason.
  `Sources/MaccheroniASR/ASRAdapters.swift:170`,
  `docs/engineering-constraint-policy.md:483`
- **limit outcome**: An attempt that ended on `maximumTokens` or `contextLimit`.
  It deliberately carries no transcript: the caller must split and retry the
  audio range rather than promote partial text.
  `Sources/MaccheroniASR/ASRAdapters.swift:218`
- **limit exhausted**: The terminal state reached when a limit outcome cannot be
  recovered: recovery is unavailable for the backend, the depth budget is spent,
  or a child would fall below the minimum recovery duration.
  `Sources/MaccheroniCLI/CLIApplication.swift:346`, decided at the recovery gate
  `Sources/MaccheroniCLI/CLIApplication.swift:1901`. At `f3f4cd1` that gate
  admits only MOSS, so a limit outcome on any other backend is exhausted
  immediately and records the error code `MOSS_LIMIT_EXHAUSTED` regardless of
  which backend ran. `Sources/MaccheroniCLI/CLIApplication.swift:32`
- **canonical promotion**: Moving an attempt result into the run's canonical
  artifacts, allowed only after every promotion condition passes: the full
  planned range processed, a completion stop reason, schema and timestamp range
  validated, glossary and language contract evidence present, model and runner
  identity recorded, and the source hash unchanged.
  `docs/engineering-constraint-policy.md:222` for the conditions,
  `Sources/MaccheroniCLI/CLIApplication.swift:430` for the sealed record, and
  `Sources/MaccheroniCLI/CLIApplication.swift:363` for the per-attempt flag.
- **coverage**: How much of the input was actually processed: input duration,
  processed duration, truncation flag, strategy, and chunks planned against
  chunks completed. `Sources/MaccheroniCore/Contracts.swift:493`
- **truncated**: The coverage flag stating that processed duration is short of
  input duration. It is a statement of fact in the manifest, never a reason to
  call a run complete. `Sources/MaccheroniCore/Contracts.swift:496`

## Failure modes

- **repetition degeneration**: An autoregressive decoder that stops producing
  new content and emits one token repeatedly until the output cap. It is not the
  same event as a transcript that legitimately reaches the cap with real
  content, and its signature differs: the raw backend payload carries
  `"segments": []` after a correct prefix. At `f3f4cd1` no dedicated terminal
  reason exists for it. The only test in the tree is
  `Sources/MaccheroniASR/Python/maccheroni_asr_runner.py:727`, which buckets
  both events as `maximumTokens`. The distinguishing evidence survives only in
  the preserved raw backend artifact,
  `Sources/MaccheroniASR/Python/maccheroni_asr_runner.py:1135`, written to
  `primary/chunks/<index>/backend.raw` at
  `Sources/MaccheroniCLI/CLIApplication.swift:1330`.
- **long-form hallucination**: Output that is fluent and structurally plausible
  but not grounded in the audio, appearing as input length grows. It also has no
  dedicated symbol at `f3f4cd1`. The closest recorded surface is the
  structural-completeness constraint, where longer leaves reported an
  `endOfSequence` stop but lost timestamp markers and produced no verifiable
  segments; that condition closes the attempt as `invalid_eos_output` and keeps
  the raw output as a diagnostic artifact only.
  `docs/engineering-constraint-policy.md:433`,
  `Sources/MaccheroniCLI/CLIApplication.swift:347`
- **silent truncation**: Dropping input beyond a backend's duration limit
  without failing or splitting. Prohibited: input beyond the limit must fail
  explicitly or produce a split plan. `PROJECT.md:82`

## Diarization and merge

- **diarization timeline**: The speaker timeline computed once over the complete
  original audio, before enhancement, and used for the whole run.
  `Sources/MaccheroniCore/Contracts.swift:104`,
  `docs/contracts/run-layout.md:78`
- **turn**: One entry of that timeline: one speaker label over one contiguous
  interval, with optional confidence.
  `Sources/MaccheroniCore/Contracts.swift:84`; the merger names the same value
  `turn` at `Sources/MaccheroniMerge/TimelineMerger.swift:404`, and the scoring
  side reads RTTM turns at `benchmarks/scripts/scoring/rttm.py:10`.
- **overlap share**: For one ASR segment, the fraction of its total clipped
  speaker-overlap time held by the top-ranked speaker. Attribution requires it
  to reach `dominantSpeakerShare`, 0.60 by default.
  `Sources/MaccheroniMerge/TimelineMerger.swift:442`, threshold at
  `Sources/MaccheroniMerge/TimelineMerger.swift:93`. Measurement notes use the
  phrase in a second sense: the share of speech time in which two or more
  speakers are concurrently active, a property of the recording rather than of
  one segment. The concurrency test behind that sense is
  `Sources/MaccheroniMerge/TimelineMerger.swift:480`. Say which one is meant.
- **merge**: Joining chunked ASR output with the whole-file diarization timeline
  by timestamp, producing `merged/segments.json` and `merged/conflicts.json`.
  `Sources/MaccheroniMerge/TimelineMerger.swift:128`,
  `docs/contracts/run-layout.md:81`
- **speaker attribution**: Deciding which global speaker owns one ASR segment.
  It yields `UNKNOWN` when no timeline speaker overlaps the segment, when
  timeline coverage of the segment falls below `minimumTimelineCoverage`, or
  when no speaker's overlap share is dominant; the ranked candidates are
  preserved in the conflict record instead of being collapsed away.
  `Sources/MaccheroniMerge/TimelineMerger.swift:395`
- **backend speaker evidence**: A backend's own per-segment speaker label. It
  never becomes the segment's speaker: it is reduced to the flag
  `backend_speaker_evidence` while `speaker` stays `UNASSIGNED` until merge
  attributes it. `Sources/MaccheroniASR/ASRAdapters.swift:947`
- **global speaker namespace**: The single set of speaker IDs produced by
  running diarization once over the complete file. Every chunk's segments are
  attributed into that one namespace; per-chunk speaker labels are never a
  namespace of their own. `UNASSIGNED` means not yet attributed and `UNKNOWN`
  means attribution was attempted and refused; neither counts toward
  `num_speakers`. `PROJECT.md:49`, `docs/contracts/run-layout.md:196`

## Glossary

- **glossary injection mode**: How glossary terms reach the backend at decode
  time. Each backend requires exactly one mode and a mismatch is rejected before
  execution. `Sources/MaccheroniCore/Contracts.swift:378`, per-backend
  requirement at `Sources/MaccheroniASR/ASRAdapters.swift:52`
- **`free_text_context`**: Terms enter the backend's free-text context prompt.
  Required by VibeVoice and Qwen3. `Sources/MaccheroniCore/Contracts.swift:380`,
  `Sources/MaccheroniASR/ASRAdapters.swift:54`
- **`hotword_instruction`**: Terms enter the backend as a hotword instruction.
  Required by MOSS. `Sources/MaccheroniCore/Contracts.swift:381`,
  `Sources/MaccheroniASR/ASRAdapters.swift:55`
- **term recall**: Matched reference occurrences divided by reference
  occurrences, where the denominator counts only terms actually spoken in the
  reference and each term's match count is the smaller of its reference and
  hypothesis counts. `null` when the denominator is 0.
  `benchmarks/scripts/scoring/metrics.py:152`, protocol at
  `docs/contracts/scoring.md:19`
- **`correct_to_incorrect`**: The count of applied correction changes whose raw
  text had zero CER errors and zero WER errors and whose corrected text is worse
  on both. It measures correction harm, not correction gain, and its numerical
  guardrail is deferred. `benchmarks/scripts/scoring/score_corrected.py:905`,
  project status in decision D44 at `PROJECT.md:459`

## Measurement

- **CER**: Levenshtein error rate over Unicode characters after NFKC, casefold,
  punctuation removal, and whitespace removal. The primary text metric for
  Korean and mixed Korean-English tracks.
  `benchmarks/scripts/scoring/metrics.py:90`, protocol at
  `docs/contracts/scoring.md:63`
- **WER**: The same Levenshtein error rate over whitespace-delimited tokens.
  Korean spacing distorts it, so it is a reference value rather than the primary
  metric on Korean tracks. `benchmarks/scripts/scoring/metrics.py:90`,
  `docs/contracts/scoring.md:63`
- **DER**: `(miss + false_alarm + confusion) / reference_speaker_time` under the
  fixed protocol: 0.25-second total collar, overlap excluded from primary DER,
  and hypothesis speakers mapped one-to-one to reference speakers over the whole
  file rather than per chunk. `benchmarks/scripts/scoring/rttm.py:109`, protocol
  at `docs/contracts/scoring.md:77`
- **ablation**: A comparison in which exactly one condition differs between two
  otherwise identical sealed runs, so the difference in the metric is
  attributable to that condition. The tracked example is the paired-endpoint
  correction comparison.
  `benchmarks/scripts/scoring/compare_correction_paths.py:33`
- **held-out observation**: An observation made on data that was not used to
  choose the method, the threshold, or the condition being judged. Required,
  together with a predeclared calibration method, before a measurement campaign
  can support a quality claim. `PROJECT.md:119`

## Identity

- **model identity**: HF model ID plus revision plus quantization. All three are
  required and a parameter-count alias is not an identifier, because the same
  weights have been published as 7B, 8B, and 9B. `PROJECT.md:100` for the
  judgment rule, `Sources/MaccheroniCore/Contracts.swift:359` for the recorded
  form.
