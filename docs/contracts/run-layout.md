# Run Artifact Contract

This document defines the v1 contract for Maccheroni run directories. Every
path is relative to the run root. The original audio is neither moved into nor
overwritten by the run directory. The input SHA-256 in `manifest.json` confirms
that the source file remains the same.

Glossary revisions are not run artifacts. They live at
`<library-root>/Glossaries/Revisions/<sha256>.txt` under the external local
library described in `glossary-format.md`. Do not copy them into a source or
derived run and do not commit them to the repository.

## Directory Structure

```text
<run-id>/
├── manifest.json
├── primary/
│   ├── raw.txt
│   └── segments.json
├── diarization/
│   └── timeline.json
├── merged/
│   ├── segments.json
│   └── conflicts.json
├── postprocess/
│   ├── segments.json
│   ├── conflicts.json
│   └── translation.json
└── derived/
    ├── <derived-id>/
    │   ├── manifest.json
    │   └── postprocess/
    │       ├── segments.json
    │       └── conflicts.json
    └── <derived-id>/
        ├── manifest.json
        └── postprocess/
            └── translation.json
```

Create `postprocess/` only when post-processing runs. A correction run creates
`segments.json` and `conflicts.json`; a translation run creates only
`translation.json`. Do not mix the two forms in one run. All other paths are
required for a successful complete run. An intermediate failure still leaves
`manifest.json`. Do not include artifacts that could not be created in the
manifest's `artifacts` field.

Create `derived/` only for an operation on a completed run. Every immediate
child is a create-only derived artifact set. It has its own manifest conforming
to `derived-manifest.schema.json` and contains exactly one operation form:
correction creates `segments.json` and `conflicts.json`; translation creates
only `translation.json`. Never modify the source manifest, the source run's
legacy `postprocess/` files, or an earlier derived set.

## Meaning of Each File

- `manifest.json`: the run record that conforms to `manifest.schema.json`.
  Atomically replace its temporary file when the run ends. It must record input
  duration, processed duration, truncation status, chunk results, the model's
  HF ID and pinned revision, and quantization. When post-processing runs, the
  optional `postprocess` field records the mode, backend, model ID, published
  revision and quantization, glossary hash, `text-only` input mode, and bounded
  batch ledger. The meaning of `model_id` differs by lane. The local lane pins
  execution to a revision, so the value identifies the model that actually ran.
  In the hosted-service lane, it is the requested model string passed with
  `--model`. Because the CLI does not expose the service's actual serving model,
  this value is unverified. Translation also records the target language and
  the SHA-256 of the canonical merged segment artifact. Leave the revision,
  quantization, and hard output-token limit as `null` when the hosted backend
  does not publish them, and record their status as
  `service-managed-unavailable`.
- `primary/raw.txt`: the backend's unmodified source output. This file is for
  human inspection and is never overwritten by post-processing.
- `primary/segments.json`: the backend output normalized into the common
  segment structure. If no speaker has been assigned yet, `speaker` is
  `UNASSIGNED`.
- `diarization/timeline.json`: the speaker timeline derived from the complete
  original audio. Each entry has `speaker`, `start_s`, `end_s`, and optional
  `confidence`.
- `merged/segments.json`: the canonical result of merging the global timeline
  with chunked ASR. It must pass `segments.schema.json`.
- `merged/conflicts.json`: preserves ambiguous speaker assignments and ASR
  discrepancies. Each conflict contains the target segment's array index,
  `kind`, `candidates`, and `reason`. It never substitutes a correction into the
  source text.
- `postprocess/segments.json`: a separate corrected version proposed by the
  selected post-processing backend. Its speakers and time ranges must match
  `merged/segments.json`.
- `postprocess/conflicts.json`: correction proposals with insufficient
  confidence. It contains both the unchanged source text and the candidates.
- `postprocess/translation.json`: a translation-only artifact conforming to
  `translation.schema.json`. It contains only the canonical segment indexes and
  translations, plus the per-batch prompt, source text, decoded text, and raw
  schema-response byte-budget evidence for batches divided at complete segment
  boundaries. It cannot represent speaker and timestamp fields, so model output
  cannot change the acoustic structure.
- `derived/<derived-id>/manifest.json`: the sealed record for one existing-run
  operation. Its `source` field records the source run ID, the source
  `manifest.json` SHA-256, and the verified `merged/segments.json` path and
  SHA-256. Its `operation` field records the profile used for the operation,
  correction or translation mode, optional target language, selected glossary
  semantics, and the parsed glossary hash and item count. `current-profile`
  means the current invocation profile or explicit override. `source-run`
  means the revision named by the source manifest. Its `postprocess` field
  carries the same backend, model, text-only, and bounded batch evidence as a
  new-audio run. `artifacts` contains only files inside this derived set.

## Writing and Invariants

1. Read the input file's SHA-256 and byte count before starting the run.
2. Write every generated file to a temporary file in the same directory, then
   rename it atomically.
3. Do not modify `primary/raw.txt` or `primary/segments.json` after creating
   them. A retry uses a new `run-id`.
4. Write merge and post-processing output only to new subdirectories. No stage
   opens the original audio path or raw result in write mode.
5. Recalculate the input SHA-256 after the run ends. If it differs from the
   initial value, mark the run failed and preserve the artifacts.
6. If a backend limit prevents processing the entire input, record `status` as
   `partial` or `failed`. Do not hide `coverage.truncated`,
   `processed_duration_s`, or the error message. The application's normal path
   must process chunks before reaching the limit or explicitly reject the
   input.
7. Post-processing forms contiguous batches at complete segment boundaries and
   includes each canonical index exactly once. If one segment exceeds the
   prompt or output planning budget, terminate with a typed failure before
   calling the backend.
8. Exclusively create the translation artifact as a separate file. Before and
   after translation, `primary/raw.txt`, `primary/segments.json`,
   `merged/segments.json`, and the original input SHA-256 must remain unchanged.
9. Before an existing-run operation creates `derived/<derived-id>` or calls a
   backend, decode the source manifest and require a successful complete run.
   Validate every manifest artifact path, reject duplicates and unsafe paths,
   require every listed artifact to exist with its recorded SHA-256, and decode
   the uniquely identified `merged/segments.json` from the same bytes whose hash
   was verified. Require the canonical `primary/raw.txt`,
   `primary/segments.json`, `diarization/timeline.json`,
   `merged/segments.json`, and `merged/conflicts.json` kinds and paths, plus the
   recorded post-processing form. The manifest inventory must equal all regular
   files under the source run except `manifest.json`, the complete `derived/`
   tree, and Finder's `.DS_Store` metadata. Refuse with a typed integrity failure
   if any check fails.
10. An existing-run operation always reads the verified canonical
    `merged/segments.json`. It does not run preprocessing, VAD, ASR,
    diarization, or merge. `current-profile` is the default: an explicit
    `--glossary` takes precedence over the invocation profile path, and the
    exact non-empty bytes are stored as a revision before use. `source-run`
    resolves only the source manifest's glossary hash and item count. A source
    manifest that records no glossary deliberately supplies none. A non-null
    hash with no valid stored revision fails with the typed
    revision-unavailable error before creating a derived set or calling a
    backend. `source-run` cannot be combined with `--glossary`. Never fall back
    between these semantics. A valid current file with zero parsed entries is
    no glossary.
11. Seal a derived manifest only after its output validates against the source
    structure and every new artifact hash verifies. A failed or canceled set may
    remain for audit but is not displayable as a result. Choose the freshest
    successful set by its manifest `finished_at` value, using `derived_id` as a
    deterministic tie-breaker. Never use filesystem modification time. Keep all
    successful earlier sets enumerable in the library and run inspector.

## Identifiers and Time

- Recommended `run-id`: UTC time plus a random suffix in the format
  `20260803T041530Z-7f3a9c`.
- Recommended `derived-id`: the same UTC time plus random suffix form. A derived
  ID is unique only within its source run.
- Time ranges are floating-point seconds from 0 at the start of the original
  file and are interpreted as half-open intervals `[start_s, end_s)`.
- Sort segments and chunks by `start_s`, then `end_s`. When start points are
  equal, place the item with the earlier end point first.
- Paths must not contain absolute paths or `..`. The manifest preserves only
  filenames and relative artifact paths, never personal paths.

## Semantic Validation

The following conditions, which JSON Schema cannot express, must also be
checked.

- Every range satisfies `end_s > start_s` and does not exceed the original
  duration. The floating-point tolerance is 10ms.
- For a successful run, `processed_duration_s` equals `input_duration_s` within
  10ms and `truncated` is false.
- A successful run uses `full` or `chunked` coverage and has at least one
  successful chunk. Its boundaries start at zero, are contiguous within 10ms,
  and end at `input_duration_s` within 10ms. Their total covered duration and
  final boundary both equal `processed_duration_s` within 10ms.
- `chunks_completed <= chunks_planned`, and chunk indexes increase from 0
  without duplicates. `full` has one chunk; `chunked` has more than one.
- A successful run that records a provided glossary also records
  `applied: true`.
- Every segment field satisfies `segments.schema.json`, including confidence
  range, language-tag syntax, unique flags, and flag syntax, in addition to the
  time ordering and speaker-count checks below.
- `num_speakers` equals the number of unique speakers excluding `UNASSIGNED`
  and `UNKNOWN`.
- The speakers and times in post-processing segments exactly match those in the
  merged version.
- Translation `source_segments_sha256` must equal the
  `merged/segments.json` artifact hash. Translation indexes and batch coverage
  must extend from 0 through one less than the canonical segment count without
  duplication or omission.
- The manifest's batch policy, observed maxima, and the translation's per-batch
  byte/token ledger must be reproducible from the same calculation and the
  actual artifact values. Calculate the accepted output bound from the raw
  schema-response bytes, including the JSON envelope and escaping, rather than
  counting only the decoded translations.
- A successful derived manifest's source manifest hash and source segment hash
  must still match the immutable source files. Correction output must preserve
  source, segment count, speakers, time ranges, languages, confidence, and all
  non-review flags. Translation must preserve exact index coverage and must not
  represent acoustic structure.
- A successful derived manifest's glossary hash and item count must match the
  exact revision bytes selected by `glossary_semantics`. A missing hash requires
  a zero item count and means that the selected semantics deliberately supplied
  no glossary.

`benchmarks/scripts/scoring/check_contracts.py` validates schema examples and
the applicable conditions above against run manifests.
