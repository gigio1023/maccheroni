# Speaker-Proposal Accuracy on AMI IN1009

Status: measurement record, 2026-09-04. It answers the item in `PROJECT.md`
section 6 that asks for the D50 confirmations to be measured against a ground
truth before any revisit of overturns. It records evidence only; what D50's
confirm-or-decline stance becomes is the maintainer's decision.

The question has three parts. How often does a confirmation under D50 name the
speaker the reference names? How often is a decline right? And what would the
acoustic evidence alone have got right on the same segments, so the language
layer's contribution is visible as a difference rather than as a number on its
own? A fourth quantity, the accuracy of the answers the constraint refused, is
what a later decision about overturns would rest on, and the artifact keeps
those answers, so it is measured here as well.

Terms follow `docs/terminology.md`: *run*, *derived run*, *speaker
attribution*, *attribution outcome*, *segment overlap share*, *timeline
coverage*, *confirm-or-decline*. A *proposal* is a confirmation of the
top-ranked candidate; a *decline* is a recorded refusal with its cause.

## Evidence

### Fixture

`ami-in1009-ihm-mix-v1` from `benchmarks/datasets/acceptance-pack-v1.json`:
AMI meeting IN1009, one mono mix of four near-field headset channels, 1256.35 s,
English, four speakers. The recording is a clean mix and this document makes no
far-field or room-microphone claim.

| file | SHA-256 |
| --- | --- |
| `sources/ami/IN1009.Mix-Headset.wav` | `7ee90aac9105734ab40d3085dcb4d0ad4ba06adc1c24facb2ad843529b489506` |
| `prepared/ami-in1009-ihm-mix-v1/reference.rttm` (290 turns, speakers MIO018, MIO099, MIO100, MIO101) | `516e4185f5dd852aa0dbdba11ed7d5f33406c9e4a4c8c63dc40e92f8f523eb25` |
| `prepared/ami-in1009-ihm-mix-v1/glossary.txt` (103 terms) | `51c9b4f7fc5a004a586a38371554c982c230a44a2c91bd37d4d05a82bcb2522f` |

The reference RTTM is the manual segment annotation with AMI's global speaker
IDs, so it is a per-speaker ground truth. Its speech spans 32.736 s to
1200.86 s; 1080.1 s of speech in union, of which 200.1 s has two or more
speakers active, a recording overlap share of 0.185 over turns averaging 4.51 s.

### Source run

The sealed 2026-08-31 evaluation `ami-20260831-t8-02` (SHA-256
`41336850701d0bd368aab7b726b6e32d0483303864904b3c830753f8f77a15fd`) is not
on disk any more: its create-only run tree lived under an ignored path in a
verification worktree that has since been removed, and only its hashes and
metrics survive in `PROJECT.md` D44. A fresh run was therefore made through the
shipped `ko-meeting` profile with the fixture glossary, the same command the
acceptance runner issues, with no model, backend, chunk, token, timeout, retry,
fallback, or cache setting changed:

```text
run ID            20260904T112500Z-719d01
status            succeeded, coverage 1256.3466875 / 1256.3466875 s, 11 of 11 chunks, not truncated
wall time         589.55 s
asr               mlx-community/VibeVoice-ASR-8bit @ 725c72e54d6ef875472c27fbc50fab470a960940, int8, mlx-audio-vibevoice 0.4.6
vad               aufklarer/Silero-VAD-v6.2.1-CoreML @ 523876545a57961474fee9df913e833e130560b8, coreml-float16
diarization       aufklarer/Pyannote-Community-1-CoreML @ a14e6c420d56e8472850649b016a486fd0acbe81, coreml-fp32
glossary          applied, free_text_context, 103 items, SHA-256 51c9b4f7…2522f
manifest.json     ef8f87761f9b4a45b7b858b15347cebc13a309c890955cc051fcf00d34a8eb2a
merged/segments   38681d9bfbd0cc1e4828a0df1cc02b356dd29b39782377b0eb8a00d7421184c8   248 segments, num_speakers 4
merged/conflicts  69f08ece6c7c308597a8701f7d1384c5a25327cd53cec443e1695d08d2d40a51   191 records: 138 overlapping_speech, 53 ambiguous_speaker
diarization/timeline 06e39bd024ae63c10aa331ff18741c0b10c509a49f4faf3dfedc3ff54c126a1e   431 turns
```

An acceptance evaluation envelope was created for the fresh run so its
diarization could be compared with the sealed one:

```text
evaluation ID     ami-20260904-d50-01, passed
hypothesis.rttm   16acc3f12f4991e07cd600f8e8a23684645ca5c84c180380ac89cbf7c28d638f   byte-identical to the sealed t8 hypothesis RTTM
DER               0.06536338315972955, speakers 4 / 4                                  identical to t8
scores.json       f07edaf9b0d89077344f274cd7245a348843d3a1a8d027a2904c3ba9823f553b
CER 0.2305, term recall 0.9509 (407 / 428), omitted utterances 0 / 274             t8: CER 0.2208, term recall 0.9533
```

The whole-file speaker timeline, and with it every candidate share the proposal
reads, is the same as in the sealed evaluation. The ASR output differs because
the shipped leaf policy now cuts eleven leaves of about 120 s where the t8 run
had two chunks, so the merged segment set is the fresh run's own. The run tree
stays ignored under `benchmarks/runs/`; only hashes, counts and timestamps are
recorded here.

### Derived run

The proposal was driven the way the 2026-09-02 D50 measurement was driven: the
opt-in integration test `actualSpeakerProposalDerivesFromAPreservedRun` over the
preserved run, with a profiles file that sets `ko-meeting` to `postprocess:
codex`, the `CodexPostprocessBackend` (`codex-app-server`, codex-cli 0.153.2,
model `gpt-5.6-sol`, authenticated; the profile doctor reported ready). No
proposal artifact exists for this run. Both attempts ended in the typed failure
`POSTPROCESS_ERROR`, "backend output needs a conservative 5291-token upper
bound, above the 4096-token planning budget" (5280 on the second attempt), and
each left a create-only failed derived set with no artifact:

```text
derived/20260904T114405Z-bba735   status failed, wall 115.87 s, POSTPROCESS_ERROR, 5291 > 4096
derived/20260904T114701Z-fabe1e   status failed, wall 106.38 s, POSTPROCESS_ERROR, 5280 > 4096
```

The failure is structural rather than noise; section "Speaker proposal" below
reconstructs it from the artifacts. The local backend is not a usable fallback:
it is not provisioned on the measuring machine, and its batch policy reserves
96 output tokens per decision against a 768-token planning budget, so a batch
of eight target segments is refused at 800 tokens before a single response
byte is counted. No model, backend, chunk, token, timeout, retry, fallback, or
cache setting was changed to make either path complete.

## Method

The scorer is `scripts/score-speaker-proposal.py`, standard library only, with
its synthetic-fixture test in `scripts/tests/test_score_speaker_proposal.py`.
It reads `merged/segments.json`, `merged/conflicts.json` and
`diarization/timeline.json` from the run, the reference RTTM, and optionally
one `speaker-proposal` derived set. Every number below comes from those files.

**Cluster-to-reference mapping.** The run's global speaker namespace is mapped
onto the reference speakers by maximal whole-file overlap, one hypothesis
speaker to at most one reference speaker, by the same exact search the DER
scorer uses (`benchmarks/scripts/scoring/rttm.py`). The overlap matrix is in
seconds of intersecting speech; purity is the mapped overlap over the
hypothesis speaker's total speech.

| hypothesis | MIO018 | MIO099 | MIO100 | MIO101 | mapped to | purity |
| --- | ---: | ---: | ---: | ---: | --- | ---: |
| 0 | 44.0 | 27.9 | 16.2 | 172.8 | MIO101 | 0.900 |
| 1 | 518.5 | 37.2 | 44.9 | 50.2 | MIO018 | 0.949 |
| 2 | 30.8 | 159.0 | 30.3 | 28.2 | MIO099 | 0.939 |
| 3 | 43.1 | 25.6 | 221.8 | 12.4 | MIO100 | 0.936 |

The mapping is the one the evaluation envelope's DER scorer found as well.

**Per-segment reference truth.** For each merged segment the reference turns
are clipped to the segment's interval. The segment's truth is *clear* when one
reference speaker holds at least 0.60 of the reference speech inside the
interval, the same bar the merger applies to its own candidates, *ambiguous*
when reference speakers share the interval with no one reaching that bar or
with an exact tie, and *no reference speech* when nothing is annotated there.
A claimed speaker is scored after mapping. **Strict precision** counts only
clear segments: correct when the mapped speaker is the reference's dominant
speaker. **Lenient precision** counts every segment with a unique leading
reference speaker at any share. Intervals are Wilson 95 % score intervals,
shown because most denominators are small.

**Evidence states.** The merge's candidate list for each unattributed segment
is classed as `no_candidates` (no diarization turn beneath the segment),
`exact_tie` (the top candidates hold equal overlap, so no top-ranked candidate
exists), `near_tie` (a unique top-ranked candidate whose share leads the
runner-up by less than 0.05), `lead` (a larger lead below the 0.60 bar),
`dominant_low_coverage` (a share at or above 0.60 but timeline coverage below
0.50) and `single_candidate` (one candidate at share 1.0, blocked by coverage).

**Decline correctness.** A decline is *justified* when there was no top-ranked
candidate to confirm, when the reference has no clear speaker for the interval,
or when the top-ranked candidate names the wrong speaker; *overcautious* when
the top-ranked candidate was the reference's clear speaker. Declines the
constraint decided carry the model's own answer, which is scored the same way,
so the artifact says how the overturn or tie-break would have fared.

## Results

### Segments

248 merged segments: 195 attributed by the merge, 53 left `UNKNOWN`. Reference
truth over all 248 is clear 185, ambiguous 50, no reference speech 13; over the
53 unattributed it is clear 22, ambiguous 19, no reference speech 12.

| evidence state of the 53 unattributed | count | attribution outcome | count |
| --- | ---: | --- | ---: |
| `no_candidates` | 12 | `no_overlapping_turn` | 12 |
| `exact_tie` | 2 | `no_dominant_speaker` | 20 |
| `near_tie` | 5 | `coverage_below_threshold` | 21 |
| `lead` | 14 | | |
| `dominant_low_coverage` | 10 | | |
| `single_candidate` | 10 | | |

The thirteen no-reference-speech segments are the recording's head and tail:
segment 0 (0.00 s to 32.23 s, `[Environmental Sounds]`, before the first
annotated turn) and twelve segments between 1179.6 s and 1256.3 s (230, 237 to
247), around and after the last annotated turn, where VibeVoice emitted
`[Environmental Sounds]`, `[Unintelligible Speech]` and several French sentences
that the annotation does not contain. Ten of the twelve `no_candidates`
segments are among them. No speaker claim on those segments has a defined
truth, and they are excluded from every precision below by construction.

### Acoustic accuracy

| family | n | strict correct | strict precision | strict 95 % CI | lenient correct | lenient precision | ambiguous | no reference speech |
| --- | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: |
| merge `speaker_attribution` (attributed segments) | 195 | 154 / 163 | 0.945 | [0.90, 0.97] | 169 / 184 | 0.918 | 31 | 1 |
| `top_ranked_candidate` (unattributed segments) | 39 | 15 / 20 | 0.750 | [0.53, 0.89] | 22 / 33 | 0.667 | 17 | 2 |
| by state `near_tie` | 5 | 0 / 1 | 0.000 | [0.00, 0.79] | 0 / 2 | 0.000 | 4 | 0 |
| by state `lead` | 14 | 2 / 4 | 0.500 | [0.15, 0.85] | 8 / 13 | 0.615 | 10 | 0 |
| by state `dominant_low_coverage` | 10 | 5 / 5 | 1.000 | [0.57, 1.00] | 6 / 8 | 0.750 | 3 | 2 |
| by state `single_candidate` | 10 | 8 / 10 | 0.800 | [0.49, 0.94] | 8 / 10 | 0.800 | 0 | 0 |
| by outcome `coverage_below_threshold` | 21 | 14 / 16 | 0.875 | [0.64, 0.96] | 15 / 19 | 0.789 | 3 | 2 |
| by outcome `no_dominant_speaker` | 18 | 1 / 4 | 0.250 | [0.05, 0.70] | 7 / 14 | 0.500 | 14 | 0 |

Two readings of the acoustic baseline matter for what follows. Where the merge
refused a speaker for lack of a dominant share, the reference agrees the
segment is mixed in 14 of 18 cases, and on the 4 with a clear reference speaker
the top-ranked candidate was right once. Where the merge refused for low
timeline coverage, the top-ranked candidate was right on 14 of 16 clear
segments. The five wrong top-ranked candidates on clear segments are segment 6
(share 0.534 against 0.466, the reference at 0.68 for the other candidate), 172
(0.524, a near tie), 195 (0.591, the reference at 0.88 for the other), and 227
and 233 (a single candidate at share 1.0 under low coverage, where the reference
speaker was not the one the timeline placed there).

### Speaker proposal

No confirmation or decline could be scored, because the shipped Codex
speaker-proposal path did not complete on this run. What the artifacts do show
is why, and it is a coupled-constraint failure of the kind
`docs/engineering-constraint-policy.md` exists to name.

`TextBatchPlanner` packs consecutive segments into batches of at most 32
segments or 16384 prompt bytes. English AMI segments are short, median 42
bytes, so every batch reaches the 32-segment cap: seven batches of 32 and one
of 24. After the model answers, `SpeakerProposer` computes an accepted output
upper bound of `response bytes + 32 + 96 × decisions` and refuses the batch
when it exceeds the 4096-token planning budget. The bound is a byte count taken
as a token count plus a per-decision reserve, so it is decided mostly by how
many targets one batch carries and how long the model's `reason` strings are.

| batch (segment indices) | targets | input text bytes | reserve 32 + 96 × targets | response bytes implied by 5291 |
| --- | ---: | ---: | ---: | ---: |
| 0 to 31 | 5 | 1508 | 512 | 4779 |
| 32 to 63 | 4 | 2307 | 416 | 4875 |
| 64 to 95 | 3 | 2350 | 320 | 4971 |
| 96 to 127 | 4 | 1716 | 416 | 4875 |
| 128 to 159 | 5 | 1448 | 512 | 4779 |
| 160 to 191 | 5 | 2023 | 512 | 4779 |
| 192 to 223 | 6 | 1798 | 608 | 4683 |
| 224 to 247 | 21 | 717 | 2048 | 3243 |

Only the last batch is consistent with the observed bound: 21 targets reserve
2048 tokens, and a response of about 3.2 KB, roughly 155 bytes per decision, is
what a JSON decision with a one-sentence English reason costs. Every other
batch would need a response above 4.6 KB for three to six decisions. The 21
targets are every segment from 224 to 247 except 232, 234 and 241, the end of
the recording: the last annotated turn ends at 1200.86 s, the audio runs on to
1256.3 s with French conversation the annotation does not contain, the
whole-file timeline places no turn under most of it, and VibeVoice transcribes
it as `[Environmental Sounds]`, `[Unintelligible Speech]` and French sentences,
all `UNKNOWN`. A run whose unattributed segments cluster
at one end of the file therefore produces one batch the shipped budget cannot
accept, and the shipped path fails the whole derived set, twice, with the same
cause. On the 2026-09-01 Korean recording the same policy planned 20 batches
and observed a maximum accepted bound of 2630, because Korean text is longer
per segment and the prompt-byte cap split the batches before the segment cap
did.

The measurement the section 6 item asks for is therefore still open on this
fixture. Three things would each let it close, and none of them is this
document's to decide: rerunning on the audio trimmed to the annotated span, so
the tail batch does not exist; a batch policy that plans targets per batch
against the output budget rather than segments per batch against the prompt
budget, which is an execution-scope change under the constraint policy; or a
proposal path that fails one batch and declines its segments with a recorded
cause instead of failing the set, which D51's reasoning about leaves would
suggest but which is a product decision.

### What the language layer added or cost

Not measurable on this run: there is no proposal artifact. The acoustic
baseline it would be measured against is above: on the 39 unattributed
segments with a top-ranked candidate, confirming every one would have been
right on 15 of the 20 with a clear reference speaker and on 22 of 33 under the
lenient reading.

## Caveats

- One clip is not a distribution. Every precision above rests on between 1 and
  33 scorable segments and the intervals say so.
- AMI IN1009 is English, a clean headset mix, with a recording overlap share of
  0.185 over turns averaging 4.51 s. The real recordings the `ko-meeting`
  profile is for are Korean mixed-language meetings; the one measured on
  2026-09-01 had a 43.4 % overlap share over 761 turns averaging 2.11 s, and 110
  of 248 segments unattributed against 53 here. The language layer's reasoning
  is over transcript text, and the transcript here is English at CER 0.23.
- The source run is a fresh run, not the sealed `ami-20260831-t8-02`. Its
  diarization reproduces the sealed hypothesis RTTM byte for byte; its ASR
  segments do not, because the shipped leaf policy has changed since.
- The per-segment truth is an overlap reading of manual turn boundaries clipped
  to ASR timestamps that VibeVoice produced per leaf. A segment whose timestamps
  drift into a neighbouring turn is scored against that turn; no collar is
  applied. The attributed-segment precision of 0.945 bounds how much this costs.
- The mapping is whole-file and one-to-one. Cluster impurity of 5 to 10 % per
  hypothesis speaker is counted against whichever claim inherits it.
- Thirteen segments lie outside the annotated span and carry undefined truth;
  a proposal or decline there is neither right nor wrong here.

## Reproduce

```sh
# source run through the shipped profile, under the model lane lock
.build/debug/maccheroni run benchmarks/samples/public/acceptance-pack-v1/sources/ami/IN1009.Mix-Headset.wav \
  --profile ko-meeting \
  --glossary benchmarks/samples/public/acceptance-pack-v1/prepared/ami-in1009-ihm-mix-v1/glossary.txt \
  --output-root benchmarks/runs/<lane>/source-runs --json

# speaker proposal with the Codex backend: a profiles file that sets ko-meeting to postprocess "codex"
MACCHERONI_RUN_SPEAKER_PROPOSAL_INTEGRATION=1 \
MACCHERONI_SPEAKER_PROPOSAL_RUN=benchmarks/runs/<lane>/source-runs/<run-id> \
MACCHERONI_SPEAKER_PROPOSAL_PROFILES=<profiles.json> \
swift test --filter actualSpeakerProposalDerivesFromAPreservedRun

# scoring
python3 scripts/score-speaker-proposal.py \
  --reference-rttm benchmarks/samples/public/acceptance-pack-v1/prepared/ami-in1009-ihm-mix-v1/reference.rttm \
  --run benchmarks/runs/<lane>/source-runs/<run-id> \
  --proposal benchmarks/runs/<lane>/source-runs/<run-id>/derived/<derived-id> \
  --json <report.json>
python3 -m unittest discover -s scripts/tests -p "test_score_speaker_proposal.py"
```
