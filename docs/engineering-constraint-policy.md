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
