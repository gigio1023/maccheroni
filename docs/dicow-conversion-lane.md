# DiCoW and Qwen Apple Evidence Lane

This lane decides whether project-owned Apple Silicon work is worth doing for DiCoW
and Qwen speech models. It is a research contract, not a product roadmap. A converter,
JSON adapter, or model that merely loads earns no value credit.

The lane follows [PROJECT.md](../PROJECT.md) decisions D37, D42, and D43. Reference
execution may use public or synthetic audio in an isolated non-product environment.
Private audio remains restricted to the local product path.

## Current boundary

The tracked verifier now expresses the following evidence boundary:

- DiCoW implementation is blocked. The available Korean material is not proven
  leakage-safe against the candidate training corpora, so it cannot establish natural
  Korean product value.
- Qwen source identity and action-specific rights are sufficient to design a bounded
  adapter or converter. They do not establish Apple-runtime compatibility, conversion
  parity, timestamp truth, or product readiness.
- The Qwen ForcedAligner semantic audit has no active authority. Its status is
  `semantic_authority_rejected`, its verdict is `unestablished`, and its active bundle
  is null.
- A formal J1 value judgment must still choose whether the remaining Qwen work is
  valuable enough to continue. The contract permits `proceed_qwen_only` or
  `revise_or_stop_all`; it does not pre-record either result.
- Restoring reproducible empty-cache provisioning for the shipped `ko-meeting`
  profile remains the nearer product priority.

The DiCoW branch can reopen only in a successor plan after a public natural Korean
stratum passes the frozen training-corpus and alias exclusion rule for both DiCoW
candidates. That successor must run the cheap upstream MLC-versus-v3.3 comparison
before any MLX conversion.

## Pinned candidates

| Role | Exact authority | Present use |
| --- | --- | --- |
| DiCoW incumbent | `BUT-FIT/DiCoW_v3_MLC@99c64e8dc409a158816e808a1ee556cdfd0af51c` | Upstream overlap hypothesis; conversion blocked |
| DiCoW challenger | `BUT-FIT/DiCoW_v3_3@c34b64d9a9c5148c65fd355bb188d60343a6b44f` | Same-pack comparison after the evidence blocker clears |
| Vanilla control | `openai/whisper-large-v3-turbo@41f01f3fe87f28c78e2fbf8b568835947dd65ed9` | Common ASR control |
| Qwen ASR | `Qwen/Qwen3-ASR-1.7B-hf@bcd2b5b7f32b480ab5790554cfa8347f246a14f3` | Candidate bounded Apple adapter or conversion |
| Qwen aligner | `Qwen/Qwen3-ForcedAligner-0.6B-hf@c07281df297b9905d24a508279258cccf987a064` | Candidate independent acoustic timestamp path |
| Diarizer | `aufklarer/Pyannote-Community-1-CoreML@a14e6c420d56e8472850649b016a486fd0acbe81` | Existing whole-file speaker authority |
| FLEURS | `google/fleurs@70bb2e84b976b7e960aa89f1c648e09c59f894dd` | Transport and scoring fixture |
| HiKE | `thetaone-ai/HiKE@255609b24005e1fcce3f8b3a452260aaf2872cc9` | Korean-English transport and scoring fixture |

The older non-`-hf` Qwen aligner pin belongs to the original diagnostic partitioner.
It is not interchangeable with the current c072 candidate and cannot support a
current-revision compatibility claim.

## What the evidence can establish

`overlap-pack-v1` fixes public-source identities, synthetic mixing geometry, glossary
terms, speaker mappings, and score inputs before model output is read. Its contract is
in [benchmarks/datasets/overlap-pack-v1.md](../benchmarks/datasets/overlap-pack-v1.md)
and [overlap-pack-v1.json](../benchmarks/datasets/overlap-pack-v1.json).

The pack may establish:

- deterministic acquisition, transport, mixing, scoring, and failure behavior;
- reference-to-Apple parity on the same declared inputs;
- overlap recovery, non-overlap preservation, glossary recall, speaker assignment,
  timestamp behavior, and resource observations when the required strata are valid.

It may not establish product promotion from HiKE or FLEURS while training-data
exclusion is unproven. FLEURS is read speech, HiKE is not the required multi-speaker
natural overlap stratum, and AMI alone does not cover the product languages. A missing
measurement is recorded as unavailable with a reason, never as zero or success.
Repeat-alignment stability shows precision rather than acoustic accuracy. Overlap-region
metrics may enter a gate only after the exact aligner revision used for the pack passes
the predeclared concatenation-gap fixture with sample-exact acoustic boundaries.

The JSON schemas freeze structure and bounds:

- [dicow-experiment.schema.json](contracts/dicow-experiment.schema.json) covers model
  identity, fixture geometry, arms, failures, estimands, token bounds, and resources.
- [dicow-gate.schema.json](contracts/dicow-gate.schema.json) covers branch decisions,
  evidence hashes, closures, frontier refreshes, and judgment provenance.

Semantic verifiers recompute hashes and relationships that JSON Schema cannot prove.
Schema conformance is necessary infrastructure, not evidence that a model helps users.

## Qwen work boundary

Qwen ASR and alignment close independently. An ASR failure must not suppress aligner
diagnostics, and an aligner failure must not suppress ASR evidence.

Q1 is design and implementation work. It may:

- audit an existing Apple path for exact bcd2 lineage and behavior;
- implement the smallest adapter that preserves prompt and hotword transport;
- implement a project-owned converter when reuse cannot satisfy the pinned contract;
- expose an enforceable token cap, generated-token count, typed terminal reason, and
  validated timestamps without introducing a persistent service.

Q2 materializes weights and runs public or synthetic comparisons. Reuse is accepted
only after exact source lineage, tensor inventory, quantization derivation, runtime
identity, and behavior match the official reference. A failed reuse attempt may fall
back to the Q1-owned converter after its rejection and resource costs are recorded.

The c072 aligner starts at BF16 or an exact same-source reference precision. Framework
agreement does not prove acoustic timestamp truth. Timestamp evidence requires a
predeclared synthetic concatenation-gap fixture with sample-exact acoustic boundaries.
Optional int8 work begins only after the higher-precision path passes.

The earlier semantic-v4 diagnostic is non-authoritative because it did not bind the
executed CPython standard-library bytes, omitted `libmlx.dylib`, and left an
installed-runtime time-of-check/time-of-use gap. It must not be cited for any of these
claims:

- new model code is required;
- weights-only reuse is supported;
- model or conversion parity;
- runtime compatibility.

## DiCoW work boundary

If the evidence blocker clears, MLC and v3.3 receive identical audio, references,
prompts, speaker masks, request order, repetitions, and scorers. Only candidates that
pass every applicable absolute gate enter selection. A graph-incompatible candidate
is excluded with a named follow-up; it is not counted as a quality loss.

A selected DiCoW derivative is BF16 first. The lane forbids a second candidate
conversion, CTC prefix scoring, Python per-frame hot loops, and new handwritten kernels
unless a successor decision expands the scope. CTC tensors may be omitted only after
fresh perturbation runs prove that they do not affect decoder dataflow or output.

Conversion still requires three separate findings:

1. upstream value on the declared fixtures;
2. end-to-end parity of preprocessing, masks, decoding, timestamps, and typed failures;
3. product value large enough to repay memory, latency, and maintenance cost.

Loading a checkpoint satisfies none of these by itself.

## Rights, resources, and serving

Rights are evaluated per action: private reference evaluation, local derivative
creation, converter publication, weight publication, and app redistribution are
separate decisions. For local experimental conversion, treat DiCoW's checkpoint and
processor files as CC BY 4.0. Resolve the conflicting model-card fields before
publishing converted weights or redistributing them with the app. Qwen's Apache-2.0
model card does not remove the need to bind the exact source and artifact used.

Converted weights remain outside the checkout. The repository contains no recordings,
model caches, or run outputs. Every writer checks its actual phase peak plus 2 GiB of
temporary headroom before creating bytes. A failed storage preflight is an operational
blocker, not a model verdict.

Prefer a library, one-shot runner, or bounded worker. A persistent server needs measured
startup or lifetime evidence and a separate product decision. Network listeners,
remote audio APIs, and multi-user serving are outside this lane.

## Decision flow

```text
source and rights audit
        |
        v
pre-model evidence audit
        |
        +-- DiCoW evidence blocker --> close DiCoW until reversal condition
        |
        v
J1 product-value judgment
        |
        +-- Qwen value justifies work --> Q1 design --> Q2 materialize and compare
        |
        +-- value does not justify work --> revise or stop
        |
        +-- later valid DiCoW evidence --> upstream comparison --> BF16 parity prototype
```

Fable reviews the product-value decision from a bounded packet whose mechanical facts
are hash-bound. It may challenge the proposed direction. The verifier rejects a
DiCoW-proceed result while the current evidence blocker stands and rejects a Qwen-only
result that omits the DiCoW reversal condition.

The tracked task-state authority authenticates canonical J1, J2, and final transitions.
J2 selection evidence is not yet bound to the R8 and R9 result graph, so R10 remains
unsupported even after the current DiCoW blocker clears. The final gate is an advisory
closeout record and cannot promote model evidence. The later plan also describes
task-local closures for a failed turbo stress run and candidate ineligibility, but it
does not define canonical authority paths or exact skip transitions for them. Do not
execute those stages or publish their skipped task states until a successor contract
adds the missing evidence bindings, authorities, and verifier tests.

## Reproduction

Keep all environments and run roots outside the checkout. Supply the sealed environment
file explicitly rather than relying on inherited shell state:

```sh
DICOW_RUN_ENV=/absolute/path/to/sealed-run.env
python3 benchmarks/scripts/dicow/run_with_env.py \
  --env-file "$DICOW_RUN_ENV" --profile scoring -- \
  uv run --project benchmarks/scripts/scoring python -m unittest
```

Portable repository checks do not require model weights:

```sh
uv run --project benchmarks/scripts/scoring python -m unittest \
  benchmarks.scripts.scoring.tests.test_speaker_attributed
uv run --project benchmarks/env/dicow-aligner python -m unittest \
  benchmarks.scripts.dicow.tests.test_inspect
uv run --project benchmarks/env/dicow-reference python -m unittest \
  benchmarks.datasets.tests.test_overlap_pack
```

Owner-side integration replays require separately sealed public dataset and runtime
roots. Tests skip those paths unless their explicit environment variables are present.
Any later model result must name the exact command, observed output, artifact hashes,
and remaining unverified claims before it can change this document's boundary.
