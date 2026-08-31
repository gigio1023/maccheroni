# Korean-English Acceptance Pack v1

This pack measures the two parts of Maccheroni's job that the earlier public
fixtures do not cover together:

- `hike-code-switch-v1`: Korean-English code-switched ASR and glossary recall.
- `ami-in1009-ihm-mix-v1`: one 20.9-minute, four-speaker meeting for ASR,
  diarization, and glossary recall.

The repository distributes no corpus audio, annotations, derived WAV files, or
reference transcripts. The user downloads each source under its own licence
into `benchmarks/samples/public/acceptance-pack-v1/`, which is ignored by Git.
The tracked [manifest](acceptance-pack-v1.json) contains only acquisition URLs,
immutable revisions, sizes, hashes, and deterministic preparation rules.

## Acquire and prepare

```sh
bash benchmarks/datasets/acquire-acceptance-pack-v1.sh

UV_CACHE_DIR=/private/tmp/maccheroni-acceptance-uv-cache \
  uv run --with pyarrow --with jsonschema \
  python benchmarks/datasets/prepare-acceptance-pack-v1.py

UV_CACHE_DIR=/private/tmp/maccheroni-acceptance-uv-cache \
  uv run --with pyarrow --with jsonschema \
  python benchmarks/datasets/verify-acceptance-pack-v1.py
```

The acquisition script makes no login attempt. It refuses to replace an
existing source, and every second invocation re-hashes the existing bytes. The
AMI endpoints are public but old: the script uses HTTP/1.1 for the WAV and
HTTP/1.0 for the annotation archive because their Apache mirror has served the
two artifacts differently. A download or checksum failure stops the script;
it never swaps in a different AMI meeting or a third-party mirror.

Preparation creates a fixture exactly once. A later invocation is a read-only
re-verification. Each fixture directory contains only ignored artifacts:
`reference.segments.json`, `terms.json`, `glossary.txt`, `selection.json`, and
`fixture-check.json`; HiKE additionally contains its extracted item WAVs and a
concatenated reel, while AMI uses the downloaded source WAV directly. The check
file seals every artifact except itself and records source hashes before and
after preparation.

## HiKE rule

The source is `thetaone-ai/HiKE` test data at commit
`255609b24005e1fcce3f8b3a452260aaf2872cc9`: 1,121 public Korean-English
utterances under Apache-2.0. The pack pins the 235,089,121-byte Parquet blob
with SHA-256
`cc807d5e31c92df85a46445b28df2b239f7fb33943a35502161af61c1ee8b4d0`.

HiKE is an ASR and glossary fixture, not a diarization or natural-meeting
fixture. The preparer selects twelve utterances without inspecting perceived
quality: four each from the source's `word`, `phrase`, and `sentence`
code-switch levels. An eligible row has a unique ID, nonempty category and
normalized transcript, Hangul and Latin text, at least one source-labeled
loanword whose English form occurs in the transcript, and valid 2–20 second
16 kHz mono PCM audio. Within each level it ranks categories and then sample
IDs by SHA-256 with the fixed `maccheroni-acceptance-hike-v1` salt. It takes
one row from each of the first four ranked categories, only using a clearly
recorded globally ranked fallback if there are fewer categories.

The tracked manifest also pins the resulting row IDs, row positions, audio
SHA-256 values, and durations. Preparation recomputes the rule and rejects a
result that differs from that ledger.

The twelve source clips are concatenated in level/category/rank order with
0.5-second silences. `reference.segments.json` retains `text_normalized`
exactly as released, including its Korean loanword spelling; CER and WER do not
silently apply HiKE's separate PIER loanword mapping.

Its glossary derives only from HiKE's `loanwords` annotation. It takes each
English label that occurs in the assembled reference, deduplicates by NFKC
casefold, preserves the first source spelling, and counts occurrences using
the canonical scorer's exact matching rules. This metric is therefore labeled
**official-loanword term recall**, not general named-entity recall.

## AMI IN1009 rule

The source is the AMI Meeting Corpus's natural non-scenario meeting `IN1009`,
not the separate scenario session `IS1009a` through `IS1009d`. It pins the
public IHM-mix recording and manual annotation release 1.6.2 under CC BY 4.0.
The official download URLs and hashes live in the manifest, including hashes of
the nine manual annotation members actually used. The AMI corpus licence is
available at <https://groups.inf.ed.ac.uk/ami/corpus/license.shtml>.

The deliberate microphone choice is **IHM-mix**: one mono mix of all four
near-field headset channels. It gives diarization one real meeting waveform and
resembles a captured meeting mix more closely than isolated headset channels.
It is a clean-mix evaluation, so no result may be described as a far-field or
room-microphone measurement.

`meetings.xml` maps local A–D channels to AMI's global `MIO*` speaker IDs. For
each positive-duration manual segment, preparation resolves the NITE word-ID
range against that speaker's `words` XML. It retains the released lexical word
surface text and parent timestamps. The ASR reference contains the 274 segments
with lexical words. The RTTM retains all 290 positive-duration manual segments,
including the 16 without lexical words, so diarization still receives the
complete manual activity reference. The validator rejects a changed selected
segment list, item count, source hash, or source archive member.

AMI's glossary comes from the complete assembled reference rather than a
hand-picked technical list. It keeps normalized Latin tokens of at least three
letters that occur three through eight times, excluding the documented fixed
English/filler stoplist in the preparer. It then applies the same exact term
matching and reference-count calculation as the scorer. Every injected term is
therefore present in this meeting's reference.

## Run and score an acceptance fixture

The acceptance runner keeps product output immutable. It creates the source run
first, inventories every regular file, and writes scores into a separate
create-only evaluation directory. It refuses an existing evaluation ID before
starting a model. HiKE accepts only `acceptance-asr`; AMI accepts only
`acceptance-full`.

```sh
MACCHERONI_ACCEPTANCE_MODEL_RUN=1 \
MACCHERONI_BENCHMARK_CACHE="$cache_root" \
  bash benchmarks/scripts/runners/run_acceptance_pack_v1.sh \
  hike-code-switch-v1 acceptance-asr \
  benchmarks/runs/post-v1-reliability-reset/hike-code-switch-v1 \
  --evaluation-id "$evaluation_id"

MACCHERONI_ACCEPTANCE_MODEL_RUN=1 \
MACCHERONI_BENCHMARK_CACHE="$cache_root" \
  bash benchmarks/scripts/runners/run_acceptance_pack_v1.sh \
  ami-in1009-ihm-mix-v1 acceptance-full \
  benchmarks/runs/post-v1-reliability-reset/ami-in1009-ihm-mix-v1 \
  --evaluation-id "$evaluation_id"
```

Set `MACCHERONI_ACCEPTANCE_MODEL_RUN=1` only after confirming that no other
model process is active. The runner also requires at least 36 GiB of physical
memory, the provisioned `ko-meeting` cache, a passing profile doctor, and one
global acceptance-run lock. It never starts HiKE and AMI model runs together.

The 36 GiB check is a benchmark-only model-launch stop condition inherited
unchanged from the bounded Korean-profile smoke. It is not a product minimum
and does not claim that physical capacity proves current availability. The
constraint unit is bytes and the runner evaluates
`hw.memsize >= 36 * 1024^3`; the boundary contract rejects one byte below the
limit and admits the limit and one byte above it to the remaining doctor,
active-process, cache, and global-lock checks. No extra headroom factor is
applied. Revisit the stop condition only after a controlled lower-memory
acceptance campaign establishes a new supported range. A host below it can
still verify or score a preserved source run without launching a model.

To score a preserved source run without loading a model, add
`--source-run <run>`. To check only the fixture hashes and closed fixture-kind
mapping, add `--dry-run`; this creates no output.

Verify an envelope independently:

```sh
uv run --project benchmarks/env/dicow-reference \
  python benchmarks/scripts/scoring/check_acceptance_evaluation.py verify \
  --fixture-root benchmarks/samples/public/acceptance-pack-v1/prepared/hike-code-switch-v1 \
  --input benchmarks/samples/public/acceptance-pack-v1/prepared/hike-code-switch-v1/input.wav \
  --source-run <run> \
  --output <evaluation>
```

Before any model launch, the runner replays fixture construction from the
pinned public sources. This includes every HiKE transcript, glossary term,
item WAV, and concatenated reel, plus every AMI transcript, glossary term, and
complete RTTM row. It rejects fixture files outside the fixture check's exact
artifact inventory.

`evaluation.json` seals the fixture check, public source payloads, every
prepared fixture artifact, the source manifest and complete source-run file
inventory, exact `ko-meeting` model identities, the applied glossary, every
scored input, scorer sources, and `scores.json`. The safe evaluation ID must
equal its directory name, and verification rejects every unknown top-level or
nested envelope field. Its runner-evidence summary
proves that every promoted ASR leaf completed with observed terminal evidence,
an unchanged input, the pinned VibeVoice identity, and the exact applied
glossary. It also binds the root and leaf sample ranges to the unique sealed
normalized WAV, requiring gap-free, overlap-free coverage and byte-identical
PCM slices. For AMI, the evaluation derives `hypothesis.rttm` deterministically
from the sealed whole-file timeline and seals both RTTM inputs. Verification
recomputes the scores and the RTTM rather than trusting the recorded result.
`Qwen/Qwen2.5-7B` remains VibeVoice's pinned tokenizer-only dependency; the
evaluation never reports it as an inference model.

Creation verifies the complete evaluation in a private sibling staging
directory. macOS then publishes it with an atomic no-replace rename. A failed
verification remains unpublished, while a concurrently claimed evaluation ID
is never overwritten.

The verdict is structural only. Any measured CER, WER, omission count, term
recall, or DER can pass this integrity check. These commands do not publish
numbers. Store runs under the ignored, create-only `benchmarks/runs/` tree; the
maintainer decides whether a campaign enters `published-results.json`.

## Bounded Korean-profile smoke

The optional smoke uses exactly one approximately seven-second HiKE excerpt and
the real `ko-meeting` profile. It does not execute a matrix or update published
results. The runner refuses to start below 36 GiB physical memory, uses an
exclusive temporary lock, and requires an explicit confirmation that no other
model process is running:

```sh
MACCHERONI_ACCEPTANCE_SMOKE=1 \
  bash benchmarks/scripts/runners/run_acceptance_hike_smoke.sh
```

It first runs the read-only profile doctor, then runs one local transcription
with the fixture glossary. If doctor cannot report ready, stop there and retain
the command rather than forcing a model load.
