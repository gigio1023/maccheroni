# Coupled Constraint Design and Verification Policy

Status: Draft 1
Effective date: 2026-08-03

## Purpose

Individual limits may each appear reasonable yet eliminate the supported range
when combined. A path that paired 20-minute chunks with a 1,024-output-token
limit demonstrated this. This policy requires the relationships among input,
output, context, memory, time, storage, concurrency, retries, and fallback to be
calculated before implementation and checked again with execution evidence.

The goal of this policy is not to predict every failure. It establishes a closed
loop that prevents silent loss or repeated failure when a new constraint emerges
and feeds observations into the next plan.

## Scope

Apply this policy whenever any of the following changes:

- model, backend, decoder, chunk size, batch size, context limit, or output limit
- timeout, retry, fallback, queue, concurrency, cache, or helper executable
- file size or duration, request body, retention period, or disk quota
- conditions for promoting a partial result to a final result
- glossary, language pin, privacy mode, or postprocessing that changes input semantics

Copy edits, sorting, renaming, and mechanical refactors that do not affect
behavior do not require a new constraint ledger. Tests must still confirm that
the change does not delete or bypass an existing contract.

## Required Deliverables

Every affected execution path must have these four deliverables:

1. Constraint ledger: record variables, units, sources, formulas, headroom, and failure modes.
2. Supported-range calculation: determine the range that satisfies every hard constraint simultaneously.
3. Boundary tests: execute immediately below, exactly at, and immediately above each limit.
4. Execution evidence: record planned and actual values, stop reasons, and attempt lineage in the manifest.

## Constraint Ledger

Keep the ledger in a versioned document or typed configuration close to the
code. Comments alone are insufficient.

| Field | Content |
|---|---|
| `name` | stable constraint ID |
| `variable` | quantity being limited |
| `unit` | one fixed unit such as seconds, tokens, bytes, or jobs |
| `scope` | model, backend, device class, profile, pipeline stage |
| `kind` | hard, empirical, operator choice |
| `source` | upstream source line, model config, benchmark manifest, product decision |
| `formula` | relationship to other variables and rounding direction |
| `headroom` | margin and rationale for selecting it |
| `observed_range` | sample count, minimum, maximum, date |
| `failure_mode` | preflight rejection, typed runtime stop, resource exhaustion |
| `telemetry` | runtime values to measure without recording the transcript |
| `review_trigger` | conditions involving model revision, toolchain, device, or sample range that trigger review |

Distinguish exact limits from empirical coefficients. For example, the MOSS
context of 131,072 tokens is a hard constraint. The observed output rate of
7.7882 tokens per second from successful samples is an empirical coefficient.
Do not treat them as equally certain.

## Supported-Range Calculation

### 1. Normalize units

Calculate every formula in explicitly declared units. Do not mix MB and MiB,
samples and seconds, or input tokens and generated tokens. Record conversion
formulas and rounding direction in the ledger.

### 2. Separate causal variables

Even at the same input duration, different variables can drive resource use.

- wall audio seconds increase encoder work and audio prompt tokens.
- speech seconds and speaking density increase generated tokens.
- speaker and timestamp formats can increase token counts even for the same character count.
- output cap affects KV cache, processing time, and result completeness simultaneously.
- overlap can improve boundary recall but adds deduplication and timestamp-rebasing costs.

Do not explain everything with one proxy variable. Keep unmeasurable variables
as conservative bounds with explicit uncertainty.

### 3. Solve all constraints together

Calculate the maximum range permitted by each constraint, then select the
smallest range as the product's supported range.

```text
safe_input = min(
  context_budget_limit,
  output_budget_limit,
  memory_budget_limit,
  timeout_budget_limit,
  storage_budget_limit,
  backend_hard_limit
)
```

Do not stop after calculating the duration of a single attempt. Also limit the
aggregate cost created by concurrent execution and the retry tree.

```text
peak_memory = resident_models
  + concurrent_attempts * per_attempt_peak

maximum_attempts = initial_leaves * (2^(maximum_recovery_depth + 1) - 1)

retained_storage = immutable_source
  + successful_leaf_artifacts
  + failed_attempt_artifacts
  + temporary_headroom
  + cache_growth
```

For sequential execution, `concurrent_attempts` is 1. Record this value in the
ledger instead of hiding it as an assumption. Bound retries by the worst case
in which every initial leaf fails to the maximum depth. If actual artifacts
retain both parent and child audio, count the duplicated storage. If available
disk space before execution is less than this bound, reject the plan or select
a smaller retention policy visible to the maintainer. Do not silently delete
the source or failure evidence.

If the supported range is smaller than the product promise, choose one of
these three options:

1. Split the input at meaning-preserving boundaries.
2. Increase the resource limit with evidence.
3. Narrow the supported promise and expose it in the UI and contract.

Do not omit the calculation and hope for runtime success.

### 4. Leave headroom for empirical coefficients

Apply headroom to the worst observed value. Mark a coefficient as provisional
when the sample is small or the distribution is skewed. If a new observation
exceeds the envelope, preserve that execution as failure evidence and update
the coefficient and test range together. Do not use averages alone for hard
planning.

### 5. Set chunk duration per backend

A backend description that permits long input is not product guidance to send
that duration in one call. Define `preferred`, `maximum`, and `recovery minimum`
separately.

1. Calculate the maximum permitted by hard context, memory, and timeout constraints.
2. Apply headroom to observed output density and calculate the smaller output maximum.
3. Compare preferred-duration candidates using model-specific quality samples.
4. If a silence boundary exists near the preferred duration, split there.
5. Measure model-load and prompt overhead for chunks that are too short.

Do not raise the output cap to accommodate a long shared product chunk. The
product planner selects a safe chunk for each backend. Obtain information that
requires full-file context in a separate global stage when possible. Maccheroni
runs diarization once over the entire file, maps short ASR chunks back to the
source timestamps, and assigns them to the same speaker timeline.

Overlap is not the default. Validate contiguous splits at silence boundaries
first. If overlap is added, implement deduplication, timestamp ownership, and
source coverage together and require measurements showing improvement over the
non-overlapping result for the same fixture.

## Planning and Execution Contract

### Preflight plan

Before execution, build a plan from backend capabilities and input metadata.
Measure values that require reading the entire file, such as VAD, in an
inexpensive preprocessing stage. Record the selected constraints, calculated
values, headroom, expected chunks, and expected maximum resources in the plan.

Do not pass input above a hard limit directly to the backend. Plan smaller
input above an empirical envelope or indicate that adaptive recovery will run
during execution.

### Partial results

Distinguish these states:

- `complete`: every input range passed the contract.
- `partial`: only some ranges completed, and the missing ranges are explicit.
- `failed`: there is no result to promote as canonical.
- `canceled`: the maintainer canceled the run. Preserve completed outputs and incomplete attempts.

Do not promote timeout, output limit, context limit, parse salvage, or a skipped
chunk to `complete`. A partial transcript may remain as a diagnostic artifact,
but it cannot replace the canonical raw transcript or merged result.

### Retries

A retry must change at least one failure condition. Record changed values in
the attempt lineage.

- Split the chunk into smaller ranges.
- Increase the output or timeout budget within the range supported by evidence.
- Switch to a backend that supports the same semantic contract.
- Replace a corrupt or differently fingerprinted helper with a verified build.

Do not provide a button that reruns a deterministic limit failure with the same
input, binary, and configuration. Set maximum depth, minimum chunk duration,
and total attempt count so recovery always terminates.

### Fallback

Fallback compares semantic contracts as well as success status. Do not fall
back automatically if doing so loses glossary injection, language pin,
diarization, timestamps, privacy, or model provenance. Show the difference to
the maintainer and require an explicit choice.

## Artifacts and Promotion

Write every attempt to a create-only directory. Do not overwrite the request,
outcome, raw output, or audio of a closed attempt. One `manifest.json` that
shows the current state of the whole run may be replaced atomically. This file
is a state index rather than canonical raw data, and every state before and
after replacement must be reconstructable from append-only events or closed
attempt files. Do not modify the final success manifest after it closes.
Promote an attempt result to canonical only after all these conditions pass:

- It processed every planned input range.
- The backend stop reason indicates completion.
- The schema and timestamp range were validated.
- There is evidence that the glossary and language contract were applied.
- The model ID, revision, quantization, and runner fingerprint are recorded.
- The source hash matches its pre-execution value.

An adaptive split creates child attempts of the original chunk. Each child
records its range on the source timeline. Diarization reuses the global speaker
ID from the whole-file timeline.

## Runner and Cache Fingerprints

The existence of a helper executable does not prove the correct code version.
Build a build fingerprint from digests of the following inputs:

- helper source tree
- dependency lockfile
- compiler and toolchain version
- target architecture and build configuration
- feature flags and build options that affect results

If the expected and cached fingerprints differ, rebuild or fail explicitly.
Do not compare only paths and modification times. The manifest records helper
fingerprint and model provenance separately.

## Boundary and Combination Tests

### Single constraint

For each hard limit `L`, define three tests:

- `L - ε`: succeeds without truncation.
- `L`: matches the documented inclusive or exclusive rule.
- `L + ε`: performs the specified preflight rejection, split, or typed failure.

ε is the smallest meaningful unit. Use 1 byte for files, 1 sample or 1 frame for
audio, 1 token for tokens, and 1 job for queues.

### Coupled constraints

Do not claim completion from single-axis tests alone. Construct pairwise
combinations of real product profiles and backends, then execute high-risk
combinations through the full path.

Required combinations are:

- long input and high output density
- long input and glossary
- splitting, overlap, and timestamp rebasing
- splitting and global speaker identity
- output limit and partial artifact
- timeout and cancel escalation
- retry and create-only lineage
- fallback with glossary and privacy semantic equivalence
- model revision change and helper cache mismatch
- insufficient disk and source retention

Do not rely only on expensive long-file tests. Reproduce limit recovery in
every test run with a small injectable token cap and short fixture. Separately
verify the real resource path with a public or synthetic long file.

### Combination coverage table

The test plan includes a table whose rows are product profiles or backends and
whose columns are risk axes. Each cell contains a test ID or run ID. An empty
cell is unverified. Do not fill it with a long-file success from another
backend or a short-file success from the same backend.

## Minimum Manifest Evidence

Record these values without copying a sensitive transcript into the log:

- input bytes, duration, samples, VAD speech duration
- planned chunks and actual attempt tree
- backend, model ID, revision, and quantization for every attempt
- helper build fingerprint and toolchain
- prompt tokens, generated tokens, output cap, context cap
- peak memory and timeout budget, including whether each is measurable
- stop reason, completed range, missing range
- glossary hash, item count, injection mode, backend confirmation value
- retry reason, parent attempt, changed condition
- promotion or isolation decision
- source hash before and after execution

Record an unmeasurable value as `unavailable` with a reason instead of omitting
it. Store estimates in fields separate from observations.

## Change Review Order

1. Map the affected pipeline stages and downstream consumers.
2. Extract hard constraints from upstream source and model configuration.
3. Determine the range and sample count of empirical coefficients from existing run manifests.
4. Update the constraint ledger and supported-range formula first.
5. Implement preflight, runtime failure, recovery, and promotion.
6. Add single-boundary and coupled-boundary tests.
7. Verify deployment artifacts, including stale caches.
8. Compare planned values with observations from an actual run and update the ledger.

Reviewers ask whether all constraints that make up the product promise meet in
the same formula and tests, rather than whether a constant was increased.

## 2026-08-10 Glossary-Aware Correction Prompt Constraint

Correction uses glossary entries as supporting context only when the supplied
entry list is nonempty. The instruction identifies the encoded input path as
`INPUT.glossary.entries`, treats entries as expected terms rather than required
output, prohibits insertion without a plausible occurrence in the segment, and
routes uncertain glossary-based corrections to review. An absent or empty entry
list retains the previous instruction.

| Field | Value |
|---|---|
| `name` | `postprocess_correction_glossary_instruction_bytes` |
| `variable` | rendered correction prompt size |
| `unit` | UTF-8 bytes |
| `scope` | Codex and local correction batches with nonempty glossaries |
| `kind` | hard backend prompt limits with fixed instruction overhead |
| `source` | D30 backend limits and `PostprocessPrompt` rendered-byte accounting |
| `formula` | `rendered_prompt = instruction + "\nINPUT:\n" + sorted_input_json`; the conditional instruction adds `318 + 1 = 319` bytes |
| `headroom` | fixture: 928 bytes local and 15,264 bytes Codex; output-budget-saturating one-segment ASCII input: 665 bytes local and 13,337 bytes Codex |
| `observed_range` | one- and two-segment synthetic requests, absent, empty, and two-entry glossaries, 2026-08-10 |
| `failure_mode` | split a multi-segment candidate or reject an oversized single segment with `batchPromptTooLarge` |
| `telemetry` | `prompt_utf8_bytes` and manifest batching maxima |
| `review_trigger` | instruction, payload shape, prompt limit, segment limit, or output-budget formula changes |

The existing two-entry, two-segment correction fixture grew from 801 to 1,120
bytes. The local limit remains 2,048 bytes, leaving 928 bytes. The Codex limit
remains 16,384 bytes, leaving 15,264 bytes. The fixture contains 27 input text
bytes, so its output estimate is unchanged:

```text
32 + ceil(27 * 2000 / 1000) + 2 * 96 = 278 tokens
768 - 278 = 490 tokens of local planning margin
```

At the output-planning limit, a one-segment local batch with 320 ordinary ASCII
input bytes renders a 1,383-byte prompt and leaves 665 bytes. A one-segment
Codex batch with 1,984 input bytes renders a 3,047-byte prompt and leaves 13,337
bytes. Instruction bytes do not enter the output estimate directly. The planner
checks rendered prompt bytes and estimated output tokens independently, then
recalculates both after a split.

There is no fixed positive margin for arbitrary glossary contents or JSON
escaping. The planner measures the final encoded prompt for every candidate.
`correctionPromptBoundaryIsAcceptedBelowAndAtLimitThenRejectedAbove` exercises
the nonempty-glossary correction path at one byte below, exactly at, and one byte
above a configured prompt limit. The prompt contract tests separately cover
nonempty, absent, and empty glossary inputs and require both correction backends
to receive the same guidance and payload.

## MOSS Application Example

The MOSS long-file fix was the first application of this policy.

- hard context: 131,072 tokens
- audio context rate: 12.5 tokens per second
- runtime output cap: upstream default 5,120 tokens
- observed canonical output density: the 120-second, 240-second, and 300-second
  candidates in the fixed 600-second evaluation produced 7.633, 7.820, and
  7.940 tokens per second. Forced-recovery density that recounts limit parents
  is not used for canonical capacity planning.
- provisional structure density: the coefficients by which speaker-turn count
  and timestamp format affect generation volume are still `unavailable`.
  Record the global diarization turn count and calibrate it with a rapid
  speaker-alternation fixture.
- production initial leaf: minimum 60 seconds, preferred 120 seconds, maximum 120 seconds
- planning headroom: the measured generation volume of a 120-second leaf is
  916 tokens, or 17.9% of the cap. The combined context upper bound of the
  exact 1,727-token prompt and output budget is 6,847, or 5.2% of the hard
  131,072-token context.
- planning shape: split a 10-to-20-minute top-level work interval into
  2-minute MOSS leaves. Process a final remainder of at least 60 seconds as
  is. Preserve a shorter full input or final interval as one leaf without
  dropping samples.
- recovery: on `maximumTokens` or `contextLimit`, bisect at the nearest silence
  boundary around the midpoint of the source timeline. The first child of a
  120-second leaf is approximately 60 seconds.
- recovery progress: both children must be strictly smaller than the parent.
  Use the exact sample midpoint when there is no valid internal silence.
- recovery bound: minimum child 30 seconds, maximum depth 3. A 120-second
  parent can shrink to 60 and 30 seconds. If it still reaches a limit, fail the run.
- promotion: complete only when every leaf chunk reaches EOS
- provenance: MOSS model tuple and harness build fingerprint
- context carry: send only the same glossary to each leaf. Do not use text
  generated by the previous leaf or overlap until a regression fixture proves
  a benefit.
- prompt contract: record the hash and item count showing that the exact
  glossary and language pin entered the actual MOSS instruction for every
  leaf. A result label in the requested language is not transmission evidence.
  Include the actual prompt tokens of a large glossary in the context
  calculation and reject it before execution if it overflows.
- concurrency: v1 runs MOSS leaves sequentially and fixes concurrent attempts
  at 1. Consider a model-reuse worker with a separate lifecycle and cancellation
  contract only after measurements show that independent-call setup costs are
  a meaningful share of total time.
- tests: run fixed comparisons at 2, 4, and 5 minutes and forced recovery at
  4 minutes/1,024 tokens. Continue testing immediately below, exactly at, and
  immediately above the cap with combinations of dense/sparse, glossary,
  global speaker, and stale harness conditions.

Initial values came from pinned sources documented in the [Open-Source
Transcription Project Source Audit](reference-project-source-audit.md) and from
preserved local run evidence outside this repository. Production leaf decisions
follow the [MOSS Long-Audio Fixed Evaluation](moss-long-audio-verdict.md). If a
new long-file result exceeds the current envelope, do not silently expand the
values. Preserve the failure artifacts in a local create-only run directory
outside this repository and invoke the policy's review trigger.

## 2026-08-04 MOSS Structural-Completeness Observed Constraint

In the fixed 600-second matrix with the minimal language prompt, all five
120-second leaves produced EOS results containing timestamp markers and
segments. The 240-second and 300-second leaves for the same input reported an
EOS stop but lost timestamp markers and could not produce verifiable segments.
Each case had 0 valid EOS leaves. The token cap and hard context had ample
headroom, so this observation is a structural-completeness constraint that the
output-budget formula alone cannot explain.

The MOSS supported-range calculation must also satisfy these conditions:

```text
structured_output_supported =
  stop_reason == endOfSequence
  and timestamp_markers_present
  and validated_segment_count > 0
  and segment_timestamps_in_requested_range
```

Do not declare completion from an EOS stop alone. If these conditions fail,
close the attempt with typed `invalid_eos_output` and preserve the raw output
only as a diagnostic artifact. Leave unmeasured processing time and quality as
`null` or `unavailable`. Do not promote the result to canonical raw, coverage,
or merge.

The current production maximum is 120 seconds. The 240-second and 300-second
fixed candidates may be disqualified only when the manifest, attempt, and
helper typed codes all match `invalid_eos_output` and candidate-120, forced
recovery, and the integrity of every preserved run each pass. Any other nonzero
exit fails the matrix.

Rerun the structural-completeness matrix when extending the policy to leaves
longer than 120 seconds or changing the model revision, tokenizer, helper
source, language prompt, or glossary prompt. Observing the same typed failure
in a leaf of 120 seconds or less also triggers review. Do not silently raise the
limit or let the parser salvage text without timestamps. Preserve causal
evidence and evaluate bounded splitting or model replacement under a separate
contract.

## 2026-08-10 VibeVoice and Qwen Evidence Constraints

This change makes the existing 5,120-token product request effective for
VibeVoice. It does not select or raise a token limit. The same requested value
reaches Qwen evidence records, but the pinned `speech` 0.0.23 command cannot
accept it as an inference limit.

| name | variable and unit | scope and kind | source and formula | headroom and observed range | failure mode and telemetry | review trigger |
|---|---|---|---|---|---|---|
| `vibevoice_requested_output_cap` | generated output, tokens | VibeVoice, operator choice made effective | `CLIASRInferencePolicy.maximumTokens`, passed unchanged to `mlx-audio` `max_tokens` | no new headroom; the production value remains 5,120; injectable contract tests cover one token below, exactly at, and one token above a test cap | below cap records observed EOS; at cap records typed `maximumTokens`; an impossible count above cap is malformed; record requested cap, effective cap, prompt tokens, generated tokens, and aggregate generation time | `mlx-audio` version, VibeVoice generator loop, tokenizer, or cap policy changes |
| `vibevoice_context_hard_cap` | context capacity, tokens | VibeVoice, unavailable observation | `mlx-audio` 0.4.6 exposes no context hard-cap value through this backend | unavailable; never substitute the requested output cap | record `null` plus an unavailable reason; a runtime error cannot be promoted | upstream begins exposing a context cap or a context-limit stop |
| `qwen_effective_output_cap` | generated output, tokens | Qwen through `speech` 0.0.23, unavailable enforcement | the command has no max-token option and emits no generated-token count or stop reason | unavailable; the requested 5,120 tokens are recorded separately and are not claimed as effective | preserve stdout as diagnostic evidence, record `null` plus reasons, and fail with `asr_evidence_unavailable` | `speech` adds an enforceable cap, token counts, and a typed stop reason |
| `qwen_intra_chunk_timing` | segment boundaries, seconds | Qwen through `speech` 0.0.23, unavailable observation | the command emits one transcript string and no timestamped segments | unavailable; a synthetic `[0, duration]` range is forbidden | record chunk-only granularity, no normalized segments, zero promotable coverage, and fail before speaker attribution | `speech` adds validated segment or word timestamps |

The supported-range calculation for the pinned VibeVoice path was:

```text
input_duration_supported = min(product_leaf_maximum_1,200_s,
                               backend_duration_maximum_3,540_s)
                         = 1,200_s

verified_complete =
  terminal_evidence == observed
  and generated_tokens < effective_max_tokens
  and stop_reason == endOfSequence
  and timing_granularity == segment
  and validated_segment_count > 0
```

Both statements are superseded by the 2026-09-01 VibeVoice repetition
degeneration section below. The 1,200-second leaf maximum was derived from
duration alone, with no measured leaf at that duration, and `verified_complete`
carried no repetition term. The historical values stay here so the change is
legible.

Equality with the effective output cap is a limit outcome. The 2026-09-01
section replaces its zero-promotable-coverage clause: a limit outcome still
carries no complete result, but the leading valid prefix recovered from the raw
payload may be promoted as explicit partial coverage. The runner rejects a
generated-token count above the effective cap as a contract mismatch.

For the pinned Qwen path, no verified-complete range exists:

```text
verified_complete_supported = false
  because effective_max_tokens is unavailable
  or terminal_evidence is unavailable
  or intra_chunk_timing is unavailable
```

The Qwen command may still run to preserve diagnostic text and proof of context
transport. Neither status zero nor a `Result:` line can promote that text to a
complete or speaker-attributed transcript. Recalculate this range and add the
same below, at, and above boundary tests before enabling promotion for a newer
backend.

## 2026-09-01 VibeVoice Repetition Looping and Leaf Re-derivation

Real-usage runs of a 20.7-minute meeting recording through the shipped
`ko-meeting` profile failed at every leaf longer than four minutes. The token
cap was not the binding limit in any of them. Generation collapsed into a
repeated token and then ran to the cap, so the leaf reached the cap without
producing new content. This section replaces the VibeVoice leaf bounds derived
in the 2026-08-10 section, adds the repetition-looping term the supported-range
calculation lacked, and defines what a collapsed leaf may still promote.

Read the bound below as a conservative operating limit, not as a safe
threshold. **No leaf duration measured so far is sufficient for correctness on
its own**, including durations at or below 240 seconds; the falsifying
observations are named in the confound section and repeated in the ledger.

### Observations

Nine VibeVoice leaves, one leaf each, `mlx-community/VibeVoice-ASR-8bit` at
revision `725c72e5...a960940` `int8` through `mlx-audio` 0.4.6, output cap
5,120 tokens, 18-entry glossary except where noted.

Two audio classes, not two languages. Class A is one private meeting
recording: a 96 kbps mp3, two speakers, 70.3 % of speech time with more than
one speaker active, dense spontaneous backchannel. Class B is AMI IN1009
Mix-Headset: uncompressed, a different room, mic path, and speaker count. The
fixtures also differ in language, so language, codec, overlap, and mic path are
all confounded across the two classes and none of them is established as the
cause. The class label is used below in place of a language label for exactly
that reason.

| leaf seconds | class | glossary | prompt tokens | generated | terminal | outcome |
|---|---|---|---|---|---|---|
| 120.024 | A (0 s) | yes | 1,042 | 749 | `endOfSequence` | complete |
| 240.012 | A (0 s) | yes | 1,942 | 1,431 | `endOfSequence` | complete |
| 240.012 | A (45 s) | yes | 1,942 | 5,120 | cap | collapsed |
| 285.012 | A (0 s) | yes | 2,279 | 5,120 | cap | collapsed |
| 330.012 | A (0 s) | yes | 2,617 | 5,120 | cap | collapsed |
| 420.012 | A (0 s) | yes | 3,292 | 5,120 | cap | collapsed |
| 420.012 | A (0 s) | no | 3,215 | 5,120 | cap | collapsed |
| 641.664 | A (0 s) | yes | 4,954 | 5,120 | cap | collapsed |
| 420.032 | B | no | 3,215 | 3,197 | `endOfSequence` | complete |

The load-bearing comparison is the last two class-A rows against the class-B
row: an identical 420-second leaf, no glossary on either, same profile, same
binary, collapsed twice on class A and completed on class B. That isolates the
glossary out of the picture. It does not isolate language, because the codec,
overlap share, mic path, and speaker count differ in the same step.

Audio prompt tokens are exactly linear in leaf duration across all nine runs:

```text
prompt_tokens = 65 + floor(7.5 * leaf_seconds) + glossary_tokens
glossary_tokens = 77 for the 18-entry fixture, 0 with no glossary
```

Every row reproduces to the token. Generated tokens per audio second on the
three accepted leaves in this table are 6.2404 (A, 120 s), 5.9622 (A, 240 s),
and 7.6113 (B, 420 s). These nine runs are one leaf each, so none of them is a
dense short leaf, and 7.6113 looked like the worst case until the full-file run
produced an accepted 31.87 s leaf at 23.34. **23.34 is the coefficient carried
forward**; the derivation and the correction are in the supported-range section
below.

### Ledger

| name | variable and unit | scope and kind | source and formula | headroom and observed range | failure mode and telemetry | review trigger |
|---|---|---|---|---|---|---|
| `vibevoice_audio_context_rate` | prompt context, tokens per audio second | VibeVoice, empirical exact fit | measured `prompt_tokens` against leaf duration, `prompt = 65 + floor(7.5 * s) + glossary`, floor rounding | no headroom needed; 9 of 9 runs reproduce exactly, 120.024-641.664 s, 2026-08-31 to 2026-09-01 | over-plan rejects before launch; record prompt tokens, generated tokens, and leaf duration per attempt | model revision, tokenizer, prompt template, or audio frontend changes |
| `vibevoice_generated_token_density` | generated output, tokens per audio second | VibeVoice, empirical coefficient | accepted end-of-sequence leaves only; collapsed leaves are excluded because their count is the cap, not a density | worst observed **23.34** with a 1.5x planning factor; 24 accepted leaf measurements across four runs, 18 of them distinct, 30.56-420.032 s, both audio classes; the driver is segment density rather than audio seconds, and the worst case is a 31.87 s leaf carrying 22 segments of rapid backchannel | output-budget over-plan; record generated tokens, segment count, and audio duration | a new accepted leaf exceeds the envelope, or the segment density of a track changes |
| `vibevoice_segment_structure_density` | segments per audio second on accepted leaves, count per second | VibeVoice, empirical coefficient replacing an `unavailable` | measured segment count against leaf duration; each segment costs a fixed JSON scaffold of roughly 20-25 tokens on top of its text | 0.050-0.690 segments per second across the same 24 measurements; the 0.690 case is the 23.34 tok/s worst case above, and segment density and token density rank together at both extremes | it inflates generated tokens at constant audio duration, so the output budget must be planned from it and not from audio seconds alone | a track with faster speaker alternation than the measured maximum |
| `vibevoice_repetition_run` | longest run of consecutive identical 1-to-8-gram units, count | VibeVoice, empirical detector threshold | `repetition_run_length` in `Sources/MaccheroniASR/Python/maccheroni_asr_runner.py`; threshold 12 | worst run inside an accepted transcript is 6 at any width up to 8, measured across 16 accepted and 13 collapsed payloads; the smallest run inside a collapsed payload is 339; the threshold of 12 sits in that 56x gap with a 2x factor over the worst accepted case and 28x below the smallest collapsed one | typed `repetitionLooping` stop reason with a recovered prefix; record threshold, longest run inside the prefix, and longest run in the discarded tail | model revision, tokenizer, prompt template, or a new accepted transcript with a run at or above 12 |
| `vibevoice_initial_leaf_duration` | leaf duration, seconds | VibeVoice, **conservative operating limit, not a validated safe threshold** | duration above which collapse is systematic rather than sporadic on class A; it is not a correctness condition and no duration bound is derivable from this data as one | maximum 120 s; 4 of 4 leaves collapsed between 285 s and 642 s and 1 of 2 at 240 s, against 1 of 8 leaves between 53 s and 120 s; collapse is observed both above and below the bound, so it reduces exposure and bounds the size of one collapse rather than preventing collapse | preflight split by the leaf planner, then split recovery, then prefix promotion; record planned leaf count and per-leaf duration | any collapse below 60 s, or clean 240 s leaves at several independent offsets across more than one recording and audio class |
| `vibevoice_recovery_depth` | recovery tree depth, levels | VibeVoice, derived from the two duration bounds | 120 s maximum with a 30 s recovery minimum admits 120 -> 60 -> 30 | depth 2; a depth-3 child would be 15 s, below the recovery minimum; for a parent under 120 s the 30 s minimum binds before the depth does, so recovery is one level and then prefix promotion | `ASR_LIMIT_EXHAUSTED` or `ASR_REPETITION_LOOPING` after the tree is spent; record attempt lineage and depth | either duration bound changes |

### Supported-range calculation

```text
output_budget_limit          = floor(5,120 / (23.34 * 1.5)) = 146 s
conservative_operating_limit = 120 s      # not a correctness condition
backend_duration_maximum     = 3,540 s

input_duration_supported = min(output_budget_limit_146_s,
                               conservative_operating_limit_120_s,
                               backend_duration_maximum_3,540_s)
                         = 120_s
```

The output-budget term was first calculated as 448 s from a worst observed
density of 7.6113 tokens per audio second. That coefficient was falsified by an
accepted leaf in the 2026-09-01 full-file run: 31.87 s carrying 22 segments of
rapid backchannel generated 744 tokens, 23.34 per audio second. The driver is
segment density, not audio seconds - each segment costs a fixed JSON scaffold on
top of its text - which is the same structure-density effect the MOSS section
carries as `unavailable`. Recomputed, the output budget permits 146 s. The
120-second leaf still clears it, but the margin is 1.2x, down from 3.7x, so the
token cap is now close to binding on a dense leaf where it previously was not.
Record the segment count per attempt so this coefficient can be tracked.

`conservative_operating_limit` is the only term in that minimum that is not
derived from a hard or exactly-fitted quantity, and it is not called an
envelope. Collapse has been observed both above it and below it. It
narrows the shipped 600/900/1,200-second values, every one of which is far
above any duration that has ever completed on class A, and it caps how much
audio one collapse can put at risk; it does not make a leaf safe. Correctness
comes from the detection, recovery, and promotion contract below.

The token cap did not cause any observed failure: every collapsed leaf reached
the cap by repeating content, not by running out of budget for real transcript,
and raising the cap would not have made any of them succeed. The cap stays at
5,120 tokens. It is no longer far from binding, though - at the corrected
density a leaf of 146 s would exhaust it legitimately, so the cap and the
operating limit are now within 1.2x of each other, down from 3.7x.

Context at the production leaf:

```text
prompt_tokens(120 s, 18-entry glossary) = 65 + 900 + 77 = 1,042
context_upper_bound = 1,042 + 5,120 = 6,162 tokens
```

`mlx-audio` 0.4.6 still exposes no context hard cap for this backend, so the
ratio of 6,162 to capacity remains `unavailable` rather than estimated.

Production initial leaf: minimum 60 seconds, preferred 120 seconds, maximum 120
seconds. Recovery: minimum child 30 seconds, maximum depth 2. Concurrency stays
1. The retry tree and retained audio follow the shared formulas:

```text
maximum_attempts = initial_leaves * (2^(2 + 1) - 1) = initial_leaves * 7
retained_pcm_bytes <= total_samples * (2 + 2) * 2
```

Processing-time cost of the narrower leaf: a 1,242-second file plans 11 initial
leaves instead of 2. Generation time is content-proportional and therefore
roughly unchanged; the added cost is per-leaf model load, bounded by the
13.3-second residual between the 120-second run's 44.27-second wall time and its
31.00-second aggregate generation time, which also contains that run's
whole-file preprocessing and diarization. Nine additional leaves therefore add
at most about 120 seconds. That is the cost of never losing a leaf. It is
recorded here.

### Completeness and promotion

```text
verified_complete =
  terminal_evidence == observed
  and generated_tokens < effective_max_tokens
  and stop_reason == endOfSequence
  and timing_granularity == segment
  and validated_segment_count > 0
  and repetition_run_length(last_validated_segment) < 12
```

The last clause is the term the 2026-08-10 formula lacked. An end-of-sequence
stop whose final segment is degenerate is not a complete result: it is closed as
a limit outcome with the `repetitionLooping` stop reason and the same
recovered prefix as a cap-reached collapse.

```text
terminal_collapse =
  repetition_run_length(trailing_undecodable_text) >= 12
  or (trailing_undecodable_text is empty
      and repetition_run_length(last_complete_object) >= 12)

promoted_prefix = leading complete objects up to and including the last
                  non-degenerate object; trailing degenerate objects are
                  dropped, an interior one is kept and flagged
                  repetition_looping
```

Repetition looping is intermittent before it is terminal. In the 285-second
class-A leaf a fully collapsed passage at 169.00-176.74 s is followed by correct
output through 235.11 s, so a detector that stopped at the first repeated run
would discard 66 seconds of recoverable transcript. Only the terminal region
decides the stop reason, and only trailing degenerate objects are dropped.

**Position, not repetition-run length, is the discriminator.** The evidence that
a repetition run was survivable is that correct output follows it; the evidence
that one was fatal is that generation ended inside it. Measured run counts and
lengths corroborate that split without defining it:

| payload | runs | interior run lengths | terminal run length |
|---|---|---|---|
| 285.012 s leaf | 4 | 75, 72, 75 | 1,047 |
| 330.012 s leaf | 4 | 75, 72, 75 | 1,077 |
| 420.012 s leaf | 1 | none | 1,672 |
| 420.012 s leaf, no glossary | 1 | none | 2,505 |
| 641.664 s leaf | 1 | none | 4,497 |
| 240.012 s leaf from 45 s | 1 | none | 2,428 |
| 120.024 s accepted leaf | 0 | none | none |
| 240.012 s accepted leaf | 0 | none | none |
| 420.032 s accepted class-B leaf | 0 | none | none |

Three separated bands: at most 6 repeats inside an accepted transcript, 72 to
75 for a repetition run the decoder escaped, and 1,047 to 4,497 for one it did
not. The detection threshold of 12 sits in the first gap and every run-length
band is far from it, so the exact number decides nothing. A run-length rule
would also separate these payloads, but it would be a proxy: it would have to
guess which lengths are survivable, where the position rule reads the answer
off the output. The bands come from six failing and three accepted payloads on
two recordings, so treat the numbers as corroboration and not as calibration.

A limit outcome still cannot become a complete result. When the recovery tree is
spent, the promoted prefix becomes explicit partial coverage:

```text
promotable_partial_prefix =
  stop_reason is a limit outcome
  and recovery is unavailable or exhausted
  and promoted_object_count > 0
  and promoted_coverage_s > 0

run_status = partial
coverage.truncated = true
coverage.strategy = backend_truncated
coverage.processed_duration_s = sum of promoted leaf coverage
failure.code = ASR_REPETITION_LOOPING or ASR_LIMIT_EXHAUSTED
```

Every unpromoted range is named in `primary/partial-coverage.json` with its
attempt ID and stop reason, and the manifest failure message repeats them.
Judgment rule 2 holds: nothing is silently truncated, and the covered duration
is stated rather than inferred.

**No minimum promotable share, and no claim that a promoted prefix is clean.**
The 240-second class-A leaf that started at 45 s recovers exactly one object,
22.79 s of 240.012 s, under 10 % of the leaf, and that object is itself visibly
degraded: it stutters a discourse filler several times before the repetition
run begins. Two separate decisions apply to it.

Promote it. The policy's own state definitions settle this: `failed` means
there is no result to promote, and 22.79 seconds of transcript is a result, so
the run is `partial` with 217.22 seconds named as missing. A reader cannot
mistake 22.79 of 240.012 for success when the manifest states both numbers, the
`truncated` flag, the `backend_truncated` strategy, and the missing range. A
minimum share would discard real transcript to protect a reader who is already
being told the share, and any threshold for it would be invented rather than
measured.

Do not call it clean. Coverage is the only claim promotion makes. Text quality
is reported separately and per segment: a segment measured at or above the
repetition threshold carries the `repetition_looping` flag through merge
into `merged/segments.json`, the attempt record states how many promoted
segments carry it alongside the longest repeated run inside the prefix and in
the discarded tail, and the raw payload is preserved whole. Sub-threshold
degradation like this leaf's stutter is not flagged: its longest repeated run
measures 2, against 6 inside the accepted 240-second leaf and a threshold of 12,
so any rule that caught it would fire on ordinary speech. It stays visible in
the text itself.

A common misreading follows from the chunk status vocabulary, which has no partial
value. A chunk whose leaf promoted only a prefix is still marked `succeeded`,
because it did produce a promoted transcript, so `chunks_completed` can equal
`chunks_planned` on a run that did not cover its input. Coverage is read from
`processed_duration_s` against `input_duration_s`, the `truncated` flag, the
`backend_truncated` strategy, and `primary/partial-coverage.json`. It is never
read from the chunk count, so any surface that renders coverage reads those
five.

**A lost leaf ends the leaf, not the run.** When recovery is spent and no
prefix can be promoted, that leaf's range is recorded as unrecovered and the
run continues: sibling leaves keep their transcript, later chunks are still
processed, and merge and canonical promotion still happen over everything that
did complete. The run fails outright only when nothing anywhere was promotable,
in which case it carries the typed cause of its first missing range. This applies
to every backend, MOSS included.

That is a change to MOSS's behaviour and it is recorded here. A
MOSS run that exhausted its recovery depth previously aborted before merge and
discarded every completed leaf, keeping their `result.json` files on disk with
nothing promoted. It now promotes them and names the missing range. D28's leaf
policy, the depth-3 recovery tree, the 5,120-token cap and the promotion
conditions are all unchanged; only what happens after recovery is finally spent
is different, and it changes toward the `partial` state this document already
defined. The failure stays explicit and keeps the `MOSS_LIMIT_EXHAUSTED` code.

```text
run_status =
  failed    if no leaf anywhere was promoted
  partial   if some leaf was promoted and any range is missing
  succeeded if every planned range was covered

coverage.processed_duration_s = sum over every promoted leaf of its covered
                                range, across all chunks, never truncated at
                                the first gap
```

`partial` is a claim that a transcript exists. It may not be written from chunk
bookkeeping alone: a run that aborts before promotion has no transcript
anywhere, so it is `failed` with a processed duration of zero rather than
`partial` with the duration it happened to reach before aborting. A cancel is
the exception the partial-results contract already names: it preserves its
completed-chunk accounting, because `canceled` states plainly that the run
stopped early.

**A promoted complete leaf must stay distinguishable from a promoted prefix.**
The project's done criteria require end of sequence for every promoted leaf, and
prefix promotion produces a promoted leaf that did not reach it. The two are
therefore separated in the artifact, so the criterion can be restated against
what the run directory actually records:

| | promoted complete leaf | promoted prefix |
|---|---|---|
| `outcome.json` `status` | `eos_complete` | `partial_prefix_promoted` |
| `outcome.json` `stop_reason` | `endOfSequence` | a typed limit reason |
| covers its planned range | yes | no, coverage is short |
| `promotion.json` | `eos_leaf_attempt_ids` | `partial_prefix_attempt_ids` |
| `chunks/<i>/backend.raw` | `eos_leaf_attempt_ids` | `partial_prefix_attempt_ids` |

An attempt appears in exactly one of those two lists, never both. A reader
holding only the run directory can therefore answer "did every promoted leaf
reach end of sequence" by checking whether `partial_prefix_attempt_ids` is
empty.

The attempt record invites a second misreading. `canonical_promoted` in
`primary/attempts/<id>/outcome.json` is written `false` on every attempt,
including one whose recovered prefix was promoted, and it is not the field to
read. Attempt records are create-only and are sealed when the attempt closes,
while canonical promotion happens later - after merge, after the source hash is
rechecked - and can still fail at that point. Writing `true` at attempt close
would be a claim about an event that has not happened yet, and the layout
permits no second write to a closed attempt.

The record written at promotion is the authority: `primary/promotion.json`
lists `eos_leaf_attempt_ids` for attempts that covered their range and
`partial_prefix_attempt_ids` for attempts whose prefix was promoted, and an
attempt appears in exactly one of them. `primary/chunks/<index>/backend.raw`
carries the same split per root chunk. A reader asking whether one attempt
reached the canonical transcript looks there, not at `canonical_promoted`.

Recovery is available on the VibeVoice path, and a limit outcome on a non-MOSS
backend no longer records `MOSS_LIMIT_EXHAUSTED`. The MOSS bounds, the MOSS
recovery tree, the 5,120-token cap, and every model pin are unchanged.

### What the 2026-09-01 full-file run lost, and why

The first full-file re-measurement is the reason the run-level contract above
exists. A 1,243-second file planned 12 chunks. Eleven of them, and both halves
of a twelfth, produced transcript: 13 attempts, 152 segments, covering
0-991.6 s. One range failed for real - samples 13,944,832 to 14,433,792, which
is 871.55-902.11 s, 30.56 seconds, 2.5 % of the file - because its leaf emitted
zero complete objects and so had no prefix to promote.

Every one of those 152 segments was discarded. The run aborted before merge and
wrote no `merged/`, no `primary/segments.json`, no `primary/promotion.json`. The
manifest nevertheless recorded `status: partial` with
`processed_duration_s: 871.552`, which was false twice over: no transcript
existed, and the figure stopped at the first gap and so omitted two further
leaves that had succeeded at 902.1-991.6 s.

Both defects are closed above. The same evidence now produces a `partial` run
that promotes 0-871.55 s and 902.11-991.6 s and beyond, names 871.55-902.11 s in
`primary/partial-coverage.json` with its attempt ID and stop reason, and
counts every promoted second rather than stopping at the gap.

The same run also falsified the detector. Three of its attempts recorded
`maximumTokens` while generating 5,120 tokens for 30 to 120 seconds of audio.
They were collapses: the repetition run cycled a five-unit phrase 333 times
inside an object that never closed, which a four-unit window scores as 2. With
the window at eight the three type as `repetitionLooping`, and the failure
code changes from `ASR_LIMIT_EXHAUSTED` to `ASR_REPETITION_LOOPING`. Widening
the window does not recover that range - there were never any complete objects
in it - but it stops the cause being misreported.

### Boundary tests

| bound | below | at | above |
|---|---|---|---|
| initial leaf 120 s | 119.999_9375 s plans 1 leaf | 120.000 s plans 1 leaf | 120.000_0625 s plans 2 leaves, neither above 120 s |
| repetition run 12 | 11 consecutive repeats stays promotable | 12 repeats marks the object degenerate | 13 repeats marks it degenerate |
| recovery depth 2 | a depth-1 leaf splits again | a depth-2 leaf is the recovery floor and promotes its prefix | no depth-3 attempt is planned; `maximum_attempt_count` is `leaves * 7` |
| a lost leaf | a leaf with a promotable prefix promotes it and the run continues | a leaf with nothing promotable is recorded as unrecovered and the run continues | a run with nothing promotable anywhere fails with the typed cause of its first lost range |

ε is one sample at 16 kHz for durations and one repeat for runs. The leaf
boundary is `vibeVoiceLeafPolicyIsBoundedBelowAtAndAboveItsMeasuredMaximum` in
`Tests/MaccheroniCLITests/MaccheroniCLITests.swift`; the repetition boundary is
`test_repetition_threshold_boundary_is_below_at_and_above` in
`Sources/MaccheroniASR/Python/tests/test_backend_evidence.py`; the recovery and
promotion boundaries are `vibeVoiceCollapseSplitsAndRecoversInsteadOfKillingTheRun`,
`vibeVoiceCollapseAtTheRecoveryFloorPromotesTheValidPrefix`, and
`vibeVoiceCollapseWithNoPrefixFailsWithItsOwnCode`. The run-level contract is
`oneUnrecoverableChunkDoesNotDiscardTheChunksAroundIt`, which loses a whole
middle chunk of a three-chunk run and asserts that the chunks on either side are
still merged and promoted, and
`MOSSDepthExhaustionFailsExplicitlyAndPromotesSuccessfulSiblings` for the same
contract on MOSS. `secondChunkFailureLeavesAnAuditableFailedRunWithNoFalseCoverage`
pins the other half: an abort before promotion reports `failed` with zero
processed duration, never `partial`.

Offline replay against six preserved failing payloads and three preserved
accepted payloads reproduces the recovered coverage exactly: 235.11 s of a
285.012 s leaf, 235.05 s of 330.012 s, 2.65 s of 420.012 s, 2.62 s of the
no-glossary 420.012 s, 81.91 s of 641.664 s, and 22.79 s of the 240.012 s leaf
that started at 45 s. The three accepted payloads classify as not collapsed with
full coverage, so the detector does not fire on them. The replay needs no model.

### The confound, stated

This bound is conditional on one passage of one class-A recording plus one
public class-B fixture. It is not a general property of the model, and it is not
a correctness condition.

- Every class-A clip except one starts at 0 s of the same recording, so those
  clips are nested prefixes of one passage rather than independent samples.
- The 285-second and 330-second leaves both stop clean at the same absolute
  position, about 235 s. Two different leaf durations failing at the same
  content position is a content signal, not a duration signal.
- Collapse onset is not monotonic in leaf length: 2.65 s at 420 s, 81.91 s at
  641.664 s, 235 s at both 285 s and 330 s, 22.79 s at 240 s from 45 s.
- **`ko-240-off45` falsifies 240 s as a safe duration.** The one clip that does
  not start at 0 s, 240.012 s beginning at 45 s, collapsed after 22.79 s, while
  the 240-second clip beginning at 0 s completed with full coverage. Duration
  held constant, outcome flipped, so content matters.
- Duration matters as well, and the two cannot be separated. The 240-second
  clip from 0 s transcribes cleanly through audio that the 285-second clip from
  0 s collapses inside at 169.0 s. Appending 45 s to the end of a clip changed
  behaviour 116 s earlier, which content at 169 s cannot explain. **Duration and
  content jointly determine failure, and no duration bound alone is derivable
  from this data.**
- 120 s is not a safe duration either: the live section below records a collapse
  at 107.584 s alongside clean leaves at 102.720 s and 119.708 s. A bound at or
  below 240 s is therefore **not sufficient for correctness**, and this document
  does not claim one is.
- Class B completed at 420 s and roughly 628 s. Language, codec, overlap
  share, mic path, and speaker count all differ between the classes in one step,
  so nothing here establishes which of them drives collapse; the repeated token
  being a discourse filler dense in spontaneous speech and sparse in headset
  audio is a hypothesis with evidence, not a cause, and nobody has manipulated
  backchannel density to test it. If the operating limit is class-dependent, a
  single VibeVoice leaf policy is too coarse, and the policy takes the smallest
  observed operating limit across conditions as the shared value.

What would falsify the 120-second bound: repeated collapse at or below 120
seconds, which would move the bound down; or a set of clean 240-second leaves at
several independent offsets across more than one recording and more than one
language, which would move it up. A single additional clean run at 240 s from
0 s on the same passage would not, because that observation already exists and
is already contradicted.

### First live test of the bound, 2026-09-01

The two clips that failed before this change were re-run through the repaired
profile at their original durations. Both now finish with full coverage:
285.012 s of 285.012 s in 320.8 s wall, and 330.012 s of 330.012 s in 334.7 s
wall, three planned leaves each, glossary applied, `chunked` strategy, no
failure object. Neither recorded `MOSS_LIMIT_EXHAUSTED`.

| leaf | seconds | generated | terminal | outcome |
|---|---|---|---|---|
| `chunk-0000-root` | 107.584 | 5,120 | `repetitionLooping` | collapsed, split |
| `chunk-0000-root-l` | 53.440 | 351 | `endOfSequence` | complete |
| `chunk-0000-root-r` | 54.144 | 354 | `endOfSequence` | complete |
| `chunk-0001-root` | 102.720 | 706 | `endOfSequence` | complete |
| `chunk-0002-root` (285 s clip) | 74.708 | 492 | `endOfSequence` | complete |
| `chunk-0002-root` (330 s clip) | 119.708 | 874 | `endOfSequence` | complete |

The first leaf of the passage collapsed at 107.584 seconds, below the new
120-second maximum, while a 119.708-second leaf of the same recording completed
and a 102.720-second leaf completed. The bound's own first live test therefore
contradicts any reading of it as a safe duration. Its recovered prefix covered
42.55 s of 107.584 s, 3 of 3 recovered objects clean, longest repeated run 1,193
in the discarded tail. Recovery, not the bound, is what saved both runs: the
collapsed leaf split into two halves that both reached end of sequence, so
neither run needed prefix promotion.

This is recorded as failure evidence rather than as a reason to move the number.
Duration does not order collapse inside the 53-to-120-second band, so any bound
chosen inside that band would be false precision. What the measurements do
support is a two-regime reading: collapse is systematic above 240 seconds and
sporadic at or below 120 seconds. The bound keeps planning inside the sporadic
regime and bounds the size of one collapse; recovery and prefix promotion, not
the bound, are what keep a run.

Verification on this backend cannot assert transcript text. On the same
1.35-2.65 s of audio the model emits different words in different runs, so a
re-run that produces different text is not a regression. Live checks assert
stop reason, coverage, promotion behaviour, and token accounting instead. At
identical leaf input the runs did agree exactly: the two clips share their first
three leaves and reported the same 351, 354, and 706 generated tokens in both,
so the observed variation is across differing prompts and leaf extents rather
than repeated runs of one input.

Prefix promotion itself was not exercised live, because recovery cleared the one
live collapse. It is verified by the offline replay above and by the unit tests
named in the boundary table. That gap closes the first time a leaf collapses at
or below the 60-second recovery floor.

Detector limits worth recording. The run measure counts repeats of 1-to-8-unit
n-grams, so a collapse that cycles a phrase longer than eight units would score
low and go undetected. The window was four units until a measured collapse
cycled a five-unit phrase 333 times and was filed as a legitimate cap hit; see
the 2026-09-01 full-file section below. Eight is the widest window validated
against every accepted payload available, and widening it further has no
evidence either way. Units are split on whitespace and common punctuation, so a
script written without spaces would need a character-level measure. Both remain
review triggers if a new track is added.

## 2026-09-02 Merge Speaker-Assignment Thresholds

`TimelineMerger` names a global speaker for an ASR segment only when one
diarization speaker holds a dominant share of the segment's clipped overlap and
the timeline covers enough of the segment. Two values decide it:
`dominantSpeakerShare`, today 0.60, and `minimumTimelineCoverage`, today 0.50.
Neither is an execution-scope value - they touch no model, backend, chunk,
token, timeout, retry, fallback, or cache setting - but they decide what the
product will and will not claim about a speaker, so they carry the same ledger,
supported-range calculation, boundary tests, and execution evidence this policy
requires of a limit.

**Decision: keep both values. 0.60 is kept on measurement; 0.50 is kept under
acknowledged ignorance.** The two have different evidential status, and
this section records the difference.

Judgment rule 4 holds throughout. A threshold decides how acoustic evidence is
read, never what it says: the chosen speaker is always the top-ranked candidate,
and the ranking reads neither threshold. A threshold changes only whether a
speaker is named.

Terminology note: `docs/terminology.md` gives *overlap share* two senses. Below,
**segment overlap share** is the per-segment quantity compared against
`dominantSpeakerShare`, and **recording overlap share** is the share of speech
time with two or more speakers concurrently active.

### Observations

One private 20.7-minute Korean meeting run through the shipped `ko-meeting`
profile on 2026-09-01, run `20260901T122702Z-f2d938`: 248 merged segments, 761
turns averaging 2.11 s, recording overlap share 43.4 %, 110 segments
unattributed. Structural metadata only; the recording, the run, and the study
stay outside this repository. The study is
`~/maccheroni-usage-20260901/threshold-study/` and reruns offline from the
preserved artifacts with `check.sh`, no model required.

The structural fact everything below rests on was verified twice. An offline
reimplementation of `speakerAssignment(for:timeline:)` reproduces all eight
preserved runs - 571 segments - with zero speaker mismatches and identical
conflict counts, and re-merging the two preserved runs through the shipped
merger reproduces their `merged/segments.json` byte for byte. A threshold sweep
therefore counts what a different bar would name without changing whom it would
name.

Where the 110 unattributed segments come from, re-merged through the shipped
merger on 2026-09-02:

| attribution outcome | segments | reachable within the swept range |
|---|---|---|
| `no_dominant_speaker` | 100 | 77 |
| `coverage_below_threshold` | 8 | 4 |
| `no_overlapping_turn` | 2 | 0 |

The swept range is `dominantSpeakerShare` at or above 0.50, the lowest the
configuration accepts, and `minimumTimelineCoverage` at or above 0.20. All 8
coverage-blocked segments carry a top share above 0.50, so a coverage bar below
0.138 would eventually reach every one of them; 4 are reached at 0.35 and no more
at 0.20.

**25 of the 110 are out of reach of any value at all.** 23 are exact 50/50 ties
that the margin rule refuses at every bar including 0.50, and 2 have no turn
beneath them. Only 85 segments are in play, and the top-share distribution of the
100 is what a lower bar would actually reach:

| segment overlap share of the top candidate | segments | first attributed by a bar at |
|---|---|---|
| exactly 0.500 | 23 | no value |
| (0.500, 0.55) | 45 | 0.50 |
| [0.55, 0.58) | 20 | 0.55 |
| [0.58, 0.60) | 12 | 0.58 |

Sweep through the shipped merger, attributed / unattributed of 248:

| dominant \ coverage | 0.20 | 0.35 | 0.50 | 0.70 |
|---|---|---|---|---|
| 0.50 | 222/26 | 221/27 | 215/33 | 199/49 |
| 0.55 | 176/72 | 175/73 | 170/78 | 154/94 |
| 0.58 | 154/94 | 154/94 | 150/98 | 134/114 |
| **0.60** | 142/106 | 142/106 | **138/110** | 123/125 |
| 0.65 | 128/120 | 128/120 | 124/124 | 109/139 |
| 0.70 | 114/134 | 114/134 | 110/138 | 96/152 |

Coverage gain alone cannot decide this, because lowering a bar always attributes
more. The deciding quantity is how many of those newly named segments would name
the wrong speaker. No reference speaker labelling exists for this recording, so
two proxies were built and neither is truth.

- **E1, a different model.** VibeVoice's own per-segment backend speaker
  evidence, which the product reduces to a flag and never promotes to a speaker.
  Its labels are leaf-local, so the local-to-global mapping is fitted only on
  segments the shipped thresholds already attribute and evaluated only on the
  rest, leave-one-out inside the fit set, restricted to mapping cells of purity
  at least 0.90 over at least 5 s of fit mass.
- **E2, a different window, no ASR at all.** Eleven preserved clip diarizations
  from the same recording shifted into absolute time, offsets verified by
  normalized cross-correlation at 0.995 or better, and the top-ranked candidate
  recomputed per segment.

| segment overlap share | E1 scored | E1 disagree | E1 rate | E2 scored | E2 flips | E2 rate |
|---|---|---|---|---|---|---|
| [0.50, 0.55) | 37 | 7 | 0.189 | 119 | 13 | 0.109 |
| [0.55, 0.60) | 23 | 4 | 0.174 | 52 | 11 | 0.212 |
| [0.60, 0.70) | 15 | 1 | 0.067 | 48 | 0 | 0.000 |
| [0.70, 0.85) | 22 | 1 | 0.045 | 0 | 0 | - |
| [0.85, 1.00) | 52 | 1 | 0.019 | 27 | 0 | 0.000 |

E2's window-level counts are not independent - each segment is seen 5 to 10
times - so its honest denominator is per segment: 3 of 23 segments below 0.60 are
unstable against 0 of 10 above.

### Ledger

| name | variable and unit | scope and kind | source and formula | headroom and observed range | failure mode and telemetry | review trigger |
|---|---|---|---|---|---|---|
| `merge_dominant_speaker_share` | top candidate's share of a segment's clipped speaker-overlap time, ratio | merge stage, all profiles; empirical decision boundary | `TimelineMergeConfiguration.dominantSpeakerShare`; attribute when `share + Double.ulpOfOne >= bar` and the top candidate either leads the runner-up by more than `overlapEpsilonS` or is the only candidate; the denominator is total clipped speaker overlap, **not segment duration** | kept at 0.60; two proxies put the top-ranked speaker's error at 0.019-0.067 above the bar and 0.174-0.212 in the two bands below it, over 248 segments at 43.4 % recording overlap, 2026-09-02; both figures are floors | refuse to name a speaker: `UNKNOWN` with outcome `no_dominant_speaker`, ranked candidates and shares preserved in `merged/conflicts.json` | a reference labelling for any part of a real meeting; a recording with more than two speakers and a proxy that resolves all of them; a diarization backend or revision with different turn-boundary noise |
| `merge_minimum_timeline_coverage` | union of clipped turns over segment duration, ratio | merge stage, all profiles; **unmeasured, kept by default** | `TimelineMergeConfiguration.minimumTimelineCoverage`; attribute when `coverage + Double.ulpOfOne >= bar` | kept at 0.50 with **no supporting measurement**: it blocks 8 of 248 segments, 4 of which a bar at 0.35 or 0.20 reaches and 2 of which are scorable, both agreeing, CI [0.00, 0.66] | refuse to name a speaker: `UNKNOWN` with outcome `coverage_below_threshold`, same evidence preserved | a recording where more than a few percent of segments are coverage-blocked, which would give this value a denominator; any change to VAD or turn padding that moves coverage systematically |

Both values are recorded per conflict record in `speaker_attribution.thresholds`,
because `merged/conflicts.json` must stay a bare array and no other run artifact
carries the merge configuration. A change to either must keep writing them.

### Supported-range calculation

```text
newly_attributed(bar)     = { segment : bar <= top_share < 0.60,
                              margin rule holds, coverage >= 0.50 }
e_b                       = 1/52 = 0.0192      # proxy error, anchored on
                                               # share >= 0.85 where e_m ~ 0
e_m(set)                  = (d/n - e_b) / (1 - 2 e_b)   # two-rater correction
expected_wrong_added(bar) = e_m(newly_attributed(bar)) * |newly_attributed(bar)|

baseline at 0.60 / 0.50   = 138 attributed, scored 87, disagree 3,
                            e_m 0.016, ~2.2 expected wrong
```

| bar | attributed | newly named | scored | disagree | e_m | expected wrong added |
|---|---|---|---|---|---|---|
| 0.50 | 215 | 77 | 50 | 11 | 0.209 | ~16.1 |
| 0.52 | 200 | 62 | 43 | 9 | 0.198 | ~12.3 |
| 0.55 | 170 | 32 | 22 | 4 | 0.169 | ~5.4 |
| 0.58 | 150 | 12 | 9 | 2 | 0.211 | ~2.5 |
| **0.60** | **138** | **0** | - | - | - | **0** |

```text
lower the bar only if
  e_m(newly attributed) <= e_m(already attributed) = 0.016

observed e_m below 0.60 = 0.169 to 0.211, an order of magnitude higher
smallest available move, 0.60 -> 0.58:
  +12 named (+4.8 % of the transcript), +2.5 expected wrong against ~2.2 standing
  => roughly doubles the wrong count
largest move, 0.60 -> 0.50:
  +77 named, +16.1 expected wrong, about one wrong speaker per five gained

raise the bar only if there is error to remove above it
  E1 above 0.60: 1 of 15, 1 of 22, 1 of 52;  E2 above 0.60: 0 of 75
  0.65 removes 14 segments and 0.70 removes 28 to remove nothing measured

supported_dominant_share = 0.60
```

Every `e_m` above is a **floor**. The two-rater correction assumes independent
errors, and both models fail in overlapped speech, which is exactly where the
ambiguous segments are; correlated errors depress observed disagreement. The
purity restriction pushes the same way, since a pure mapping cell tends to sit in
a one-speaker-dominated region where the ambiguous segments are also easier.

The trade at 0.60 is a visible refusal against an invisible wrong name. This
calculation does not price that; it reports that the smallest move available
doubles the wrong count to buy 4.8 % more named segments, and the product
judgment that a refusal costs a reader less than a false name is what makes that
a bad trade. The arithmetic holds either way. Reverse the judgment and the
decision reverses with it.

For `minimumTimelineCoverage` the calculation cannot be completed:

```text
segments blocked by coverage alone at 0.50 : 8 of 248 (3.2 %)
of those, would also pass the dominant test: 5
recovered by relaxing 0.50 -> 0.35         : 4
recovered by relaxing 0.50 -> 0.20         : 4    # the fifth has coverage 0.138
scorable against either proxy              : 2, both agreeing, CI [0.00, 0.66]

supported_minimum_timeline_coverage = unmeasurable on this data
```

Keeping 0.50 is therefore recorded as a decision made under acknowledged
ignorance, not as a measured optimum. What the data does show is why the rule
exists at all: one 3.54 s segment carries 0.49 s of turn evidence, coverage
0.138, with a top share of 0.861. Attributing it would let 14 % of an interval
name the speaker of the whole. That is a rationale for having the rule, not a
calibration of its value.

### Boundary tests

| bound | below | at | above |
|---|---|---|---|
| dominant share 0.60 | 0.5999 refuses with `no_dominant_speaker` | 0.6000 names the top candidate | 0.6001 names it |
| timeline coverage 0.50 | 0.4999 refuses with `coverage_below_threshold` | 0.5000 names the only candidate | 0.5001 names it |
| margin rule | - | an exact 50/50 tie refuses at 0.50, 0.55 and 0.60 alike | - |

ε is 1 ms of turn duration on a 10-second segment, which moves share and coverage
by 1e-4: far above double rounding, far below anything diarization resolves. Both
comparisons are inclusive at the bar, through a `Double.ulpOfOne` slack.
The tests are `dominantShareThresholdRefusesBelowAndAttributesAtAndAbove`,
`coverageThresholdRefusesBelowAndAttributesAtAndAbove`,
`anExactTieIsRefusedAtEveryConfigurableDominantShare`,
`theShippedThresholdsAreTheExaminedDefaults`, and
`loweringTheBarNamesMoreSpeakersAndNeverChangesAChosenOne` in
`Tests/MaccheroniMergeTests/MaccheroniMergeTests.swift`. The last one pins the
property the whole calculation depends on: a lower bar names more segments and
never renames one already named.

Execution evidence, 2026-09-02. Re-merging the preserved full-file run through
the shipped merger gives 248 segments, 110 `UNKNOWN`, distribution 80 / 58 / 110,
byte-identical to the preserved `merged/segments.json`. The 120-second baseline
run gives 8 segments and 6 `UNKNOWN`, also byte-identical. Both counts are
unchanged, as keeping the values predicts.

### The observation that cuts against this decision

Without the purity restriction, E1's table over the same segments reads 0.22,
0.22, 0.41, 0.19, 0.18 - flat, with a Cochran-Armitage trend test at z = -1.09,
p = 0.28. That table is dominated by ten mapping cells that are near coin flips,
so it measures the proxy rather than the merger, but the restriction that removes
them is a judgment call and the decision depends on it. E2 corroborates the
direction without using the ASR model at all, which is why the recommendation
does not rest on E1 alone.

### What would falsify this

- A reference speaker labelling for any part of this meeting, or a timed human
  pass over the 77 reachable unattributed segments. If fewer than about 5 of the
  77 turn out to be wrong under the top-ranked candidate, `dominantSpeakerShare`
  should go to 0.50.
- A diarization backend whose turn boundaries are stable enough that E2's flip
  rate below 0.60 drops to zero. The break at 0.60 is a property of this
  timeline's boundary noise, not a law.
- A recording with more than two speakers and a proxy that resolves all of them.
- Any measured cost asymmetry that reverses the product judgment above, for
  instance a reading surface where an unattributed segment costs a reader as much
  as a wrongly attributed one.

### What this did not measure

- **The high-overlap end.** The named cross-check, the 120-second baseline at
  70.3 % recording overlap, cannot discriminate: 8 segments, and the backend
  speaker evidence resolves exactly one usable mapping cell there, so E1 is a
  constant predictor and its 0 % disagreement is an artifact. The same holds for
  the 240-second ablation clip. Conditions that do discriminate were substituted:
  the ko-420-late clips at 27.2 % overlap over 177 segments, and the public AMI
  fixture at 7.9 % overlap with 4 speakers over 82 segments. Both show error
  falling with share across [0.50, 0.60), [0.60, 0.85) and [0.85, 1.00): 0.333,
  0.160, 0.020 for the clips and 1.000, 0.529, 0.057 for AMI, against 0.183,
  0.054, 0.019 for the full meeting. The 59-70 % overlap band remains unmeasured,
  and this section does not certify either threshold there.
- **Speaker count.** On the AMI fixture the error is still 9 of 17 inside
  [0.60, 0.85), a band 0.60 accepts. Its proxy resolves only 3 of 4 speakers,
  which inflates disagreement, so this is a signal rather than a measurement. It
  suggests the right bar depends on speaker count and that 0.60 may be the wrong
  question for a four-speaker recording. That is a separate investigation, not a
  reason to move a value now.
- **`minimumTimelineCoverage`**, for the reason given in the calculation above.
- **One recording, one language, two speakers.** The 27 % cross-check is the same
  meeting's audio in a different window. AMI is the only independent recording
  here and it disagrees about where the bar belongs.
