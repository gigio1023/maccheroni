# Speaker-Proposal Accuracy on AMI IN1009

Status: measurement record, 2026-09-04. It answers the item in `PROJECT.md`
section 6 that asks for the D50 confirmations to be measured against a ground
truth before any revisit of overturns. It records evidence only; what D50's
confirm-or-decline stance becomes is the maintainer's decision.

The question has three parts. How often does a confirmation under D50 name the
speaker the reference names? How often is a decline right? And what would the
acoustic evidence alone have got right on the same segments, so the language
layer's contribution is visible as a difference rather than as a number on its
own? A fourth quantity, how the speaker the model would have named instead
fares, is what a later decision about overturns would rest on, and it is read
off the decline reasons at the end.

Terms follow `docs/terminology.md`: *run*, *derived run*, *speaker
attribution*, *attribution outcome*, *segment overlap share*, *timeline
coverage*, *confirm-or-decline*. A *proposal* is a confirmation of the
top-ranked candidate; a *decline* is a recorded refusal with its cause.

Headline, on the annotated span of one English clean-mix meeting: the D50
confirmations name the reference's clear speaker 11 times out of 15 (0.733,
95 % interval 0.48 to 0.89); confirming every top-ranked candidate without a
model would have scored 15 of 19 (0.789); the twelve segments the model
declined on its own were genuinely mixed eight times and had a correct
top-ranked candidate the other four; and the speaker the model's reasons
pointed to instead of the top-ranked candidate was right once in seven.

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
The audio runs on to 1256.35 s with unannotated French conversation after the
meeting ends.

### Source runs

The sealed 2026-08-31 evaluation `ami-20260831-t8-02` (SHA-256
`41336850701d0bd368aab7b726b6e32d0483303864904b3c830753f8f77a15fd`) is not
on disk any more: its create-only run tree lived under an ignored path in a
verification worktree that has since been removed, and only its hashes and
metrics survive in `PROJECT.md` D44. Two fresh runs were therefore made through
the shipped `ko-meeting` profile with the fixture glossary, the same command the
acceptance runner issues, with no model, backend, chunk, token, timeout, retry,
fallback, or cache setting changed. Both use
`mlx-community/VibeVoice-ASR-8bit` at `725c72e54d6ef875472c27fbc50fab470a960940`
(int8, mlx-audio-vibevoice 0.4.6), `aufklarer/Silero-VAD-v6.2.1-CoreML` at
`523876545a57961474fee9df913e833e130560b8` (coreml-float16) and
`aufklarer/Pyannote-Community-1-CoreML` at
`a14e6c420d56e8472850649b016a486fd0acbe81` (coreml-fp32).

**Run A, the full file.** This is the sealed fixture's input.

```text
run ID            20260904T112500Z-719d01
status            succeeded, coverage 1256.3466875 / 1256.3466875 s, 11 of 11 chunks, not truncated, wall 589.55 s
manifest.json     ef8f87761f9b4a45b7b858b15347cebc13a309c890955cc051fcf00d34a8eb2a
merged/segments   38681d9bfbd0cc1e4828a0df1cc02b356dd29b39782377b0eb8a00d7421184c8   248 segments, num_speakers 4, 53 UNKNOWN
merged/conflicts  69f08ece6c7c308597a8701f7d1384c5a25327cd53cec443e1695d08d2d40a51   191 records: 138 overlapping_speech, 53 ambiguous_speaker
diarization/timeline 06e39bd024ae63c10aa331ff18741c0b10c509a49f4faf3dfedc3ff54c126a1e   431 turns
```

An acceptance evaluation envelope was created for run A so its diarization
could be compared with the sealed one:

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
had two chunks, so the merged segment set is the fresh run's own.

**Run B, the annotated span.** The shipped Codex proposal path cannot complete
on run A (see "Why run A has no proposal" below), so the same pipeline was run
on the audio cut to 0 to 1201.0 s, which contains the whole annotated span and
drops only the unannotated French tail. The cut keeps every reference timestamp
valid; it was made with Python's `wave` module by writing the first 19,216,000
frames of the 16 kHz mono PCM16 source unchanged. Run B is a subset of the
sealed fixture, not the sealed fixture.

```text
input             IN1009.Mix-Headset.annotated-span.wav, 1201.0 s, 38432044 bytes
                  SHA-256 f14d4341de1cad1cfe908cb0836ed0c88c85361a4e65fc6851718c34e2a2c009
run ID            20260904T115532Z-a36db4
status            succeeded, coverage 1201.0 / 1201.0 s, 11 of 11 chunks, not truncated, wall 536.09 s
manifest.json     9de7714e4fda0a0b75be75053e278f4df3d2658c8b7e411692613b9258e60c44
merged/segments   11ebd9a7e8b87a4d827ba2fbc20903051d390eb5302ea3cfd39b2e250b41e827   240 segments, num_speakers 4, 44 UNKNOWN
merged/conflicts  eb24016bf5fa3cbe16be0f944761f3553e95c62d3620ff0c417d7ac3c366c49e
diarization/timeline a2124490f1798e8b4956d1f4d9ec1ff456c3c7e525b3d49027e921bb95d4e369   427 turns
```

No evaluation envelope exists for run B: the acceptance checker seals the
pinned fixture input and refuses any other. Both run trees stay ignored under
`benchmarks/runs/`; only hashes, counts and timestamps are recorded here.

### Derived run

The proposal was driven the way the 2026-09-02 D50 measurement was driven: the
opt-in integration test `actualSpeakerProposalDerivesFromAPreservedRun` over the
preserved run, with a profiles file that sets `ko-meeting` to `postprocess:
codex`, through `CodexPostprocessBackend` (`codex-app-server`, codex-cli
0.153.2, model `gpt-5.6-sol`, authenticated; the profile doctor reported
ready). Run B's set succeeded:

```text
derived ID        20260904T120502Z-aa1090, status succeeded, wall 101.55 s
manifest.json     a8752aaa02f9459ada6e85a5c830564b0f38fb20ec91c2fbe5c42ba92354b8f6
speaker/proposals.json 36f04cd0777f91d6eb3fd512775c945d63992da7995ee6354681ad90c740df20
constraint        confirm-or-decline; source coverage complete, 1201.0 of 1201.0 s
batches           12 planned, maximum prompt 4999 bytes, maximum response 1876 bytes,
                  maximum accepted output upper bound 3060 of the 4096-token planning budget
result            44 unattributed: 24 proposals (confirmations), 20 declines
```

**Why run A has no proposal.** Two attempts on run A ended in the typed
failure `POSTPROCESS_ERROR`, "backend output needs a conservative 5291-token
upper bound, above the 4096-token planning budget" (5280 on the second
attempt), each leaving a create-only failed derived set with no artifact
(`20260904T114405Z-bba735`, `20260904T114701Z-fabe1e`). The cause is
structural. `TextBatchPlanner` packs consecutive segments into batches of at
most 32 segments or 16384 prompt bytes; English AMI segments are short, median
42 bytes, so the segment cap binds. After the model answers, `SpeakerProposer`
computes an accepted output upper bound of `response bytes + 32 + 96 ×
decisions` and refuses the batch when it exceeds the planning budget. On run A
the unannotated tail is transcribed as `[Environmental Sounds]`,
`[Unintelligible Speech]` and French sentences, the whole-file timeline places
no turn under most of it, and every one of those segments is `UNKNOWN`, so the
last batch carries 21 targets: a reserve of 2048 tokens plus a response of
about 3.2 KB, roughly 155 bytes per JSON decision with a one-sentence reason,
exceeds 4096. Every other batch carries 3 to 6 targets. On the 2026-09-01
Korean recording the same policy planned 20 batches with a maximum accepted
bound of 2630, because Korean text is longer per segment and the prompt-byte
cap split batches before the segment cap did. The local backend is not a
fallback here: it is not provisioned on the measuring machine, and its batch
policy reserves 96 output tokens per decision against a 768-token planning
budget, so an eight-target batch is refused at 800 tokens before a single
response byte is counted. This is a coupled-constraint gap of the kind
`docs/engineering-constraint-policy.md` exists to name, and it belongs to that
ledger; it is not a D50 question.

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
hypothesis speaker's total speech. Run B's matrix:

| hypothesis | MIO018 | MIO099 | MIO100 | MIO101 | mapped to | purity |
| --- | ---: | ---: | ---: | ---: | --- | ---: |
| 0 | 44.1 | 28.8 | 17.0 | 172.0 | MIO101 | 0.904 |
| 1 | 518.5 | 37.2 | 44.9 | 50.2 | MIO018 | 0.961 |
| 2 | 30.8 | 159.0 | 30.3 | 28.2 | MIO099 | 0.939 |
| 3 | 43.0 | 24.7 | 220.9 | 13.2 | MIO100 | 0.930 |

Run A's matrix differs by at most 1.4 s in any cell and gives the same
mapping, which is also the one the evaluation envelope's DER scorer found.

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
constraint decided carry the model's own structured answer; on this run the
model never named a speaker other than the top-ranked candidate in that
channel, so the speaker it would have chosen instead is read from its decline
reasons by hand, in the last table.

## Results

### Segments

Run B: 240 merged segments, 196 attributed by the merge, 44 left `UNKNOWN`.
Reference truth over all 240 is clear 188, ambiguous 49, no reference speech
3; over the 44 unattributed it is clear 22, ambiguous 19, no reference speech
3 (segment 0 before the first annotated turn, and two `[Environmental
Sounds]` or `[Music]` segments the annotation does not cover).

| evidence state of the 44 unattributed | count | attribution outcome | count |
| --- | ---: | --- | ---: |
| `no_candidates` | 6 | `no_overlapping_turn` | 6 |
| `exact_tie` | 2 | `no_dominant_speaker` | 20 |
| `near_tie` | 5 | `coverage_below_threshold` | 18 |
| `lead` | 14 | | |
| `dominant_low_coverage` | 6 | | |
| `single_candidate` | 11 | | |

### Acoustic accuracy

Run B, the same run the proposal was made over:

| family | n | strict correct | strict precision | strict 95 % CI | lenient correct | lenient precision | ambiguous | no reference speech |
| --- | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: |
| merge `speaker_attribution` (attributed segments) | 196 | 155 / 166 | 0.934 | [0.89, 0.96] | 169 / 186 | 0.909 | 30 | 0 |
| `top_ranked_candidate` (unattributed segments) | 36 | 15 / 19 | 0.789 | [0.57, 0.91] | 22 / 32 | 0.688 | 17 | 0 |
| by state `near_tie` | 5 | 0 / 1 | 0.000 | [0.00, 0.79] | 0 / 2 | 0.000 | 4 | 0 |
| by state `lead` | 14 | 2 / 4 | 0.500 | [0.15, 0.85] | 8 / 13 | 0.615 | 10 | 0 |
| by state `dominant_low_coverage` | 6 | 3 / 3 | 1.000 | [0.44, 1.00] | 4 / 6 | 0.667 | 3 | 0 |
| by state `single_candidate` | 11 | 10 / 11 | 0.909 | [0.62, 0.98] | 10 / 11 | 0.909 | 0 | 0 |
| by outcome `coverage_below_threshold` | 18 | 14 / 15 | 0.933 | [0.70, 0.99] | 15 / 18 | 0.833 | 3 | 0 |
| by outcome `no_dominant_speaker` | 18 | 1 / 4 | 0.250 | [0.05, 0.70] | 7 / 14 | 0.500 | 14 | 0 |

Run A, the full file, gives the same picture: attribution 154 / 163 (0.945),
top-ranked candidate 15 / 20 (0.750, [0.53, 0.89]), `coverage_below_threshold`
14 / 16, `no_dominant_speaker` 1 / 4 with 14 of 18 genuinely mixed.

Two readings of the acoustic baseline matter for what follows. Where the merge
refused a speaker for lack of a dominant share, the reference agrees the
segment is mixed in 14 of 18 cases, and on the 4 with a clear reference speaker
the top-ranked candidate was right once. Where the merge refused for low
timeline coverage, the top-ranked candidate was right on 14 of 15 clear
segments. The wrong top-ranked candidates on clear segments are segment 6
(share 0.53 against 0.47, the reference at 0.68 for the other candidate), 172
(0.52, a near tie, the reference at 0.63 for the other), 195 (0.59, the
reference at 0.88 for the other) and 236 (`[Human Sounds]`, a single candidate
under low coverage where the reference speaker is someone else).

### Speaker proposal

Confirmation coverage is 24 of 44 unattributed segments, 0.545.

| family | n | strict correct | strict precision | strict 95 % CI | lenient correct | lenient precision | ambiguous | no reference speech |
| --- | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: |
| confirmations | 24 | 11 / 15 | 0.733 | [0.48, 0.89] | 16 / 22 | 0.727 | 9 | 0 |
| by state `near_tie` | 3 | 0 / 1 | 0.000 | [0.00, 0.79] | 0 / 1 | 0.000 | 2 | 0 |
| by state `lead` | 8 | 1 / 3 | 0.333 | [0.06, 0.79] | 5 / 8 | 0.625 | 5 | 0 |
| by state `dominant_low_coverage` | 4 | 2 / 2 | 1.000 | [0.34, 1.00] | 3 / 4 | 0.750 | 2 | 0 |
| by state `single_candidate` | 9 | 8 / 9 | 0.889 | [0.56, 0.98] | 8 / 9 | 0.889 | 0 | 0 |
| by outcome `coverage_below_threshold` | 13 | 10 / 11 | 0.909 | [0.62, 0.98] | 11 / 13 | 0.846 | 2 | 0 |
| by outcome `no_dominant_speaker` | 11 | 1 / 4 | 0.250 | [0.05, 0.70] | 5 / 9 | 0.556 | 7 | 0 |
| `top_ranked_candidate` on the 12 model-declined segments | 12 | 4 / 4 | 1.000 | [0.51, 1.00] | 6 / 10 | 0.600 | 8 | 0 |

The four confirmations that name the wrong speaker on a clear segment are the
four segments whose top-ranked candidate was already wrong (6, 172, 195, 236):
the model confirmed each with a conversational reason ("Speaker 1 briefly
confirms speaker 0's question"). Twenty-three of the 24 confirmed speakers
were at least present in the reference inside the segment; the exception is
236, `[Human Sounds]`. Nine confirmations sit on segments the reference calls
mixed, seven of them under `no_dominant_speaker`, where a single-speaker claim
is at best half right.

| decline cause | n | justified | overcautious | top-ranked candidate on the clear ones |
| --- | ---: | ---: | ---: | --- |
| `model_declined` | 12 | 8 | 4 | right 4 of 4 |
| `no_acoustic_candidates` | 6 | 6 | 0 | none to confirm; the model declined too |
| `no_top_ranked_candidate` (exact tie) | 2 | 2 | 0 | none to confirm; the model declined too |

The eight justified model declines are all segments the reference calls mixed
(13, 51, 64, 111, 141, 214, 226, 228). The four overcautious ones are 4
("Um."), 106 ("More busy, I would say."), 227 ("Yeah, sure.") and 231
("Huh."), where the top-ranked candidate was the reference's clear speaker; for
227 and 231 the model's reason was that a brief generic reply gives no
conversational basis to confirm. No decline had the cause
`model_disagreed_with_top_ranked_candidate`: instructed never to propose
another speaker, the model complied and declined instead, so the structured
`model_answer` channel carries no overturn on this run.

### What the language layer added or cost

| quantity | strict | lenient |
| --- | ---: | ---: |
| `top_ranked_candidate` precision, all 36 unattributed segments with a top candidate | 0.789 (15 / 19) | 0.688 (22 / 32) |
| confirmed subset, 24 | 0.733 (11 / 15) | 0.727 (16 / 22) |
| declined subset with a top candidate, 12 | 1.000 (4 / 4) | 0.600 (6 / 10) |

Against confirming every top-ranked candidate, the model's filter kept all
four wrong ones and removed four right ones on clear segments, so on the
segments where the reference is unambiguous it subtracted. Under the lenient
reading it enriched slightly, 0.727 against 0.688, because eight of the twelve
segments it declined are mixed. Its coverage cost is 12 of 36 candidates. The
intervals of every row overlap, so the honest summary is that on this clip the
language layer neither improved nor clearly damaged the precision of the
top-ranked candidate, and that its declines fell mostly on segments where a
single-speaker answer does not exist.

### The speaker the model would have named instead

The prompt asks the model, when the conversation points to a speaker other
than the top-ranked candidate, to decline and name that speaker in its reason.
Eight of the twelve model declines do. Read by hand from
`speaker/proposals.json` and scored after mapping:

| segment | candidates (share) | top-ranked | reason names | reference | model's speaker | top-ranked |
| ---: | --- | --- | --- | --- | --- | --- |
| 4 | 1 (0.83), 0 (0.17) | 1 | 0 | clear MIO018 | wrong | right |
| 13 | 1 (0.50), 2 (0.50) | 1 | 2 | ambiguous, MIO099 leads at 0.50 | right (lenient) | wrong (lenient) |
| 51 | 3 (0.42), 1 (0.36), 2 (0.22) | 3 | 1 | ambiguous, MIO099 leads at 0.38 | wrong (lenient) | wrong (lenient) |
| 64 | 2 (0.52), 0 (0.38), 3 (0.10) | 2 | 0 | ambiguous, MIO099 leads at 0.44 | wrong (lenient) | right (lenient) |
| 106 | 1 (0.51), 3 (0.36), 0 (0.13) | 1 | 3 | clear MIO018 | wrong | right |
| 111 | 3 (0.57), 1 (0.43) | 3 | 1 | ambiguous, MIO100 leads at 0.57 | wrong (lenient) | right (lenient) |
| 141 | 1 (0.45), 3 (0.32), 0 (0.12), 2 (0.11) | 1 | 2 | ambiguous, MIO100 leads at 0.42 | wrong (lenient) | wrong (lenient) |
| 214 | 2 (0.54), 1 (0.46) | 2 | 1 | ambiguous, exact reference tie | undefined | undefined |

On the seven scorable rows the speaker the conversation pointed to was right
once and the top-ranked candidate was right four times; on the two clear
segments the overturn would have been wrong both times. This is the only
overturn evidence the run yields, it is seven segments of one English meeting,
and it points the same way as D50's basis.

## Caveats

- One clip is not a distribution. Every precision above rests on between 1 and
  32 scorable segments and the intervals say so.
- AMI IN1009 is English, a clean headset mix, with a recording overlap share of
  0.185 over turns averaging 4.51 s. The real recordings the `ko-meeting`
  profile is for are Korean mixed-language meetings; the one measured on
  2026-09-01 had a 43.4 % overlap share over 761 turns averaging 2.11 s, and 110
  of 248 segments unattributed against 44 of 240 here. The language layer
  reasons over transcript text, and the transcript here is English at CER 0.23.
- The proposal was scored on run B, the annotated span, because the shipped
  path cannot complete on the full file. The cut removes nothing the reference
  annotates, but run B is a subset of the sealed fixture and its ASR segments
  are its own; the acoustic baseline on run A is reported beside it.
- Neither run is the sealed `ami-20260831-t8-02`. Run A's diarization
  reproduces the sealed hypothesis RTTM byte for byte; the ASR segments do not,
  because the shipped leaf policy has changed since.
- The per-segment truth is an overlap reading of manual turn boundaries clipped
  to ASR timestamps that VibeVoice produced per leaf. A segment whose timestamps
  drift into a neighbouring turn is scored against that turn; no collar is
  applied. The attributed-segment precision of 0.934 bounds how much this costs.
- The mapping is whole-file and one-to-one. Cluster impurity of 4 to 10 % per
  hypothesis speaker is counted against whichever claim inherits it.
- The last table is a hand reading of free-text reasons, not a scorer output.
- The model's output is not deterministic; the two failed attempts on run A
  differed by 11 tokens in the bound they hit, and a repeat of run B's proposal
  would not reproduce these 24 and 20 exactly.

## Reproduce

```sh
# source run through the shipped profile, under the model lane lock
.build/debug/maccheroni run benchmarks/samples/public/acceptance-pack-v1/sources/ami/IN1009.Mix-Headset.wav \
  --profile ko-meeting \
  --glossary benchmarks/samples/public/acceptance-pack-v1/prepared/ami-in1009-ihm-mix-v1/glossary.txt \
  --output-root benchmarks/runs/<lane>/source-runs --json

# annotated-span input for run B: the first 19,216,000 frames (1201.0 s) of the source WAV, written unchanged
python3 - <<'EOF'
import wave
with wave.open("benchmarks/samples/public/acceptance-pack-v1/sources/ami/IN1009.Mix-Headset.wav", "rb") as source:
    frames = source.readframes(19_216_000)
with wave.open("IN1009.Mix-Headset.annotated-span.wav", "wb") as target:
    target.setparams((1, 2, 16000, 19_216_000, "NONE", "not compressed"))
    target.writeframes(frames)
EOF

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
