# Benchmark Scoring Contract

T4, T5, T6, and T14 use only this document and
`benchmarks/scripts/scoring/`. Every report must preserve both raw and
aggregate values so the result can be recalculated.

## Common input

- Text-metric input is UTF-8 JSON. Sort reference and hypothesis segments by
  start time.
- Text normalization applies Unicode NFKC, Unicode casefold, punctuation
  removal, and whitespace normalization. Do not change numbers,
  pronunciations, synonyms, or translations.
- Exclude empty references from the WER and CER denominators and report their
  count separately.
- Aggregate metrics use a micro average: total error count divided by total
  reference-unit count, not the mean of per-file rates.

## Term recall

The denominator is the number of occurrences of reference terms that actually
appear in the reference transcript. Exclude glossary entries that were not
spoken. For each term, the match count is the smaller of its reference
occurrence count and hypothesis occurrence count.

Normalization and matching rules:

- Apply NFKC and casefold to every string. Ignore case differences in Latin
  text.
- For a term containing Hangul, remove all whitespace from both the term and
  transcript, then find the complete term string. A directly attached Korean
  particle or ending still counts as a match.
- For a term containing only Latin letters or digits, ignore differences among
  spaces, hyphens, and underscores. Do not match when a Latin letter or digit
  continues immediately before or after it. `API` matches `api`, but `api`
  inside `capillary` does not. A Korean particle counts as a boundary.
- Fuzzy matches, phonetic similarity, prefixes, and partial word matches score
  0. List an allowed alias as a separate term in the reference annotation.

`term_recall = matched_reference_occurrences / reference_occurrences`. Record
null when the denominator is 0. Glossary-off and glossary-on runs use the same
reference annotation.

For an acceptance-pack ASR run, term recall is mandatory rather than optional.
Use `check_run.py --kind acceptance-asr` for HiKE and
`check_run.py --kind acceptance-full` for the AMI meeting. The latter also
requires a diarization score. The score must retain its aggregate counts and
every per-term count so the aggregate recall can be recalculated.

## Utterance omission

Exclude noise and non-speech reference segments whose `scorable` value is
false. Expand each reference interval by 0.25 seconds on both sides. Count 1
omission when no nonempty lexical hypothesis segment overlaps that interval.
Lexical text contains at least one letter or number. Output in the interval is
not an omission even if its content is wrong; WER and CER count that error.

Report `omitted_utterances`, `scorable_utterances`, and `omission_rate`. If one
long hypothesis segment overlaps several reference intervals, none of those
intervals counts as omitted. Because of this limitation, preserve the raw
segment list in the report.

## WER and CER

- WER: Levenshtein distance over whitespace-delimited tokens after common
  normalization. Korean spacing strongly affects this metric, so CER is the
  primary metric for Korean and mixed Korean-English tracks; report WER as a
  reference value.
- CER: Levenshtein distance over Unicode characters after common normalization
  and removal of all whitespace.
- `error_rate = (substitutions + deletions + insertions) / reference_units`.
  Record S, D, I, and the reference-unit count as well.

Use the same normalization for every reference language. Do not remove Italian
diacritics. Ignore only punctuation and case.

## DER

The primary DER protocol is fixed as follows:

- Use `SPEAKER` entries from RTTM.
- When a UEM exists, score only its intervals. Otherwise score from the first
  reference start to the last reference end.
- The total speaker-boundary collar is 0.25 seconds. Exclude 0.125 seconds on
  each side of every reference boundary from scoring.
- Exclude intervals where at least two reference speakers overlap from primary
  DER (`skip_overlap=true`). An engine that can represent overlap may also
  report a secondary DER with a 0-second collar and overlap included, but it
  does not change the primary ranking.
- Assign hypothesis speaker IDs one-to-one to reference speakers to maximize
  overlap over the whole file. Assign separately per file, never again per
  chunk.
- `DER = (miss + false_alarm + confusion) / reference_speaker_time`. Record all
  four component times in seconds.

Report speaker-count accuracy separately as whether the number of unique
reference speakers equals the number of unique hypothesis speakers over the
whole file. Do not absorb cross-chunk speaker consistency into DER. Record in a
separate table whether the same reference speaker on both sides of a boundary
received the same global hypothesis ID.

## Execution

Fixed self-test and schema-example verification:

```sh
uv run --project benchmarks/scripts/scoring \
  python benchmarks/scripts/scoring/check_contracts.py
uv run --project benchmarks/scripts/scoring \
  python -m unittest discover -s benchmarks/scripts/scoring/tests \
  -t benchmarks/scripts/scoring -v
```

Score one pair:

```sh
uv run --project benchmarks/scripts/scoring \
  python benchmarks/scripts/scoring/score.py \
  --reference reference.json \
  --hypothesis hypothesis.json \
  --terms terms.json \
  --output scores.json
```

Record the script version and git commit in each benchmark report. Preserve the
input and output JSON in a preserved local run directory (create-only, not part
of this repository).
