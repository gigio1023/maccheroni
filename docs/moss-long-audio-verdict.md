# MOSS Long-Audio Fixed Evaluation Verdict

The verdict date is 2026-08-04. Production MOSS initial leaves are fixed at a
minimum of 60 seconds, a preferred duration of 120 seconds, and a maximum of
120 seconds. The 5,120-token output cap and recovery with a 30-second minimum
and depth 3, triggered only by `maximumTokens` or `contextLimit`, remain in
place.

## Evaluation Contract and Evidence

The evaluation ID is `moss-long-audio-20260803T163040Z-b828dff1`. The product
run was executed at commit `b828dff154020db953a0fc3f6d401e2c54bac327`. The
same 600-second local synthetic 2-speaker Italian input was tested with
120-second, 240-second, and 300-second leaves and under a separate forced
recovery condition of 240 seconds/1,024 tokens.

- input SHA-256:
  `c44cea08cf263eacd69c8f95bb13e6a8e2bcdb2308ad7d223c0874bd99b2d8d4`
- source fixture: repeated `italian-dialogue`, generated with `/usr/bin/say`,
  20 times. Before and after execution, the runner compared the known hashes
  of the source WAV, reference, glossary, terms, selection, and fixture check.
- ASR model: `aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8`
- revision: `90aa65287111a327db98eb83e325bd5332945edd`
- quantization: `int8-decoder+fp16-audio-vq-kv`
- helper contract: `moss-harness-v2`
- helper fingerprint SHA-256:
  `c01d11b9b3b86db7f3b6c2e4a170e1d6f3dc36a9960680d152088abb7da5f0d4`
- experiment SHA-256:
  `cb070ba5c3874f720f3c190ccecad30e32b5b2c0c64cb7a6d73eda3b225134d2`
- evaluation SHA-256:
  `8496c39e623e09e75de8623aed95f00c911ec048478eb6f639c78fbff1dfa7fc`
- evaluator source SHA-256:
  `5aa6e6748101789a4fe677f078542befd206508551649cd665d30c312b745c1d`

The product runs and scores remain in preserved local create-only run
directories that are not part of this repository. The evaluator recalculated
each manifest's hash list, attempt request and outcome, `asr-constraints.json`,
EOS promotion, and physical WAV. The model ID, 40-character revision,
quantization, helper fingerprint, glossary source, and payload hash also
matched for every leaf. The input hashes before and after execution matched in
every execution record.

## Fixed-Candidate Results

| initial leaf | quality | CER | WER | term recall | omissions | EOS/limit | wall | helper peak RSS |
|---:|---|---:|---:|---:|---:|---:|---:|---:|
| 120 seconds | pass | 0.030 | 0.051 | 0.778 | 0 | 5/0 | 59.45 seconds | 1.440 GB |
| 240 seconds | fail | 0.054 | 0.132 | 0.689 | 0 | 3/0 | 62.42 seconds | 1.451 GB |
| 300 seconds | fail | 0.073 | 0.169 | 0.667 | 0 | 2/0 | 65.15 seconds | 1.456 GB |
| 240 seconds/1,024 forced | pass | 0.030 | 0.051 | 0.778 | 0 | 5/2 | 73.78 seconds | 1.452 GB |

WER values were recalculated on 2026-08-11 after the scorer was corrected to remove punctuation instead of replacing it with whitespace, matching the existing scoring contract; CER is unchanged.

The fixed gates are CER 0.10, WER 0.15, overall term recall 0.75, utterance
omissions 0, boundary WER 0.20, and speaker-repeat stability 1.0. Only the
120-second candidate passed all gates. The two longer candidates used fewer
processes, but their term recall fell below the threshold and their wall time
was longer. The five 120-second helper calls totaled 28.10 seconds, aggregate
model load was 1.92 seconds, and the helper-process setup difference was
2.52 seconds. This run does not support introducing a resident worker.

The whole-file diarization timeline of every candidate matched 100% across all
30,000 20ms frames. Both reference speakers retained the same global label
through all 20 repetitions. No merged segment received a speaker different
from the global timeline, and the root-boundary utterance omission count was 0.

## Forced Recovery Verdict

Under the 1,024-token condition, two 240-second parents closed as
`limit_isolated` and each split into 120-second children. Including the
120-second tail, there were 5 canonical EOS leaves. The partial output of
the two parents was absent from the promotion list, and only the five EOS
results covered samples 0 through 9,600,000 without gaps or overlaps. The CER,
WER, term recall, omissions, and speaker stability of the canonical result
matched the fixed 120-second candidate. This result supports a recovery
contract that reduces only the failed range instead of raising the output cap
to preserve a long call.

## Scorer Correction Record

After all four product runs completed, the first evaluator execution failed
because it read the camelCase keys of Swift `ASRLanguageEvidence` as snake_case.
The product runs were not rerun. The actual Codable contract was verified from
the preserved artifacts, then the scorer and regression test were corrected.

The initial scorer applied the same 0.75 threshold to term recall in the
boundary ±10-second windows and to the whole result. The boundary windows
contained only 7 of the 9 terms, and the 120-second candidate missed the same
two terms in every window, producing 5/7. The overall result was 7/9 and passed
the fixed gate; the boundaries did not introduce additional loss. Overall term
recall remains 0.75. The boundary gate uses WER, utterance omissions, reference
speech cuts, and global speaker mismatches, while per-boundary term hits remain
diagnostic values. The revisit condition for this change is recorded in local
working notes outside the tracked tree.

## Production Application

Use 120 seconds as the hard initial maximum. The initial minimum is 60 seconds
so files whose duration is not a multiple of 120 seconds do not lose samples.
For example, plan a 19-minute file as 9 120-second roots and 1 60-second
tail. Process a shorter whole input at its actual duration. Reduce only a
120-second range that reaches a limit to 60 seconds and, if necessary, to
30 seconds. Do not include text from the previous leaf or overlap. Reinject
the same language instruction and glossary payload into every leaf. Run
diarization once over the entire file and use it as the canonical global
speaker source for the merge.

## Private Real-Recording Supplemental Validation

A private real recording, validated through structural metadata only; not part
of this repository. The 1148.670667-second recording was run locally at
commit `b8480447822c`. The successful run ID is
`20260803T170339Z-dd6e3c`, and the manifest SHA-256 is
`dbeec057ee84177e2a39d2d18236eec1f6ef09650605399411e7d4cabcb6faeb`.
Before execution, in the manifest, in the promotion seal, and after execution,
the input SHA-256 was
`4a392f603e08867b0045fcb228685a4878e8a41bd077c34e8225ddb46111c00b`.

The run covered all 18,378,731 samples without gaps using 10 roots of no more
than 120 seconds. All 10 attempts reached EOS, with no limit parent or partial
promotion. All recalculated hashes matched for the 112 manifest artifacts,
10 promotion results, and canonical output. Across the ±10-second windows of
the 9 root boundaries, 45 merged segments had 0 mismatches with the
whole-file timeline speaker. 1 could not be assigned a timeline overlap and
was explicitly labeled `UNKNOWN`; it was not misassigned to another speaker.
The exact model tuple and helper fingerprint matched the fixed evaluation.

The application's `it-dialogue` profile had no configured glossary, so the run
accurately recorded that none was provided. The synthetic fixed evaluation
above verifies glossary delivery and term recall. The first supplemental run
revealed that the language-instruction hash was also being recorded as the
empty glossary-payload hash. Commit `b848044` separated the two evidence items,
and the same source was rerun. The failed run was not deleted. This document
does not contain transcript content, and this supplemental validation does not
replace the public or synthetic gate evidence.

## 2026-08-04 Additional Typed Final Matrix Evidence

This section neither deletes the earlier evaluation nor reinterprets its
results at the time. It is newer evidence from rerunning the same 600-second
synthetic input in a new local create-only directory, outside this repository,
with the minimal language prompt and typed `invalid_eos_output` contract in the
recorded source state.

- evaluation ID: `moss-long-audio-20260803T182646Z-fd5ca427`
- experiment SHA-256:
  `0f7f5217ecd9d349c91bfa63b3026a4dcbc2374896ffd6bab5becb39244130e8`
- evaluation SHA-256:
  `73ec3810a72c5e184abb1f57a506f182bc5c67b16bae3aa4f43c7ddbb031b2af`
- generated input SHA-256:
  `c44cea08cf263eacd69c8f95bb13e6a8e2bcdb2308ad7d223c0874bd99b2d8d4`
- source input SHA-256 before/after:
  `ee83dbc56293bf3e3385401c164ebcd79bc375d0d0014f782529d97922900ef6`
- ASR model: `aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8`
- revision: `90aa65287111a327db98eb83e325bd5332945edd`
- quantization: `int8-decoder+fp16-audio-vq-kv`
- helper fingerprint SHA-256:
  `e665562d9513615376275bf37538c42abe1dbc77a7051f9d13a2507caa0e96a1`

| case | structural verdict | quality verdict | canonical EOS | CER | WER | term recall | omissions |
|---|---|---|---:|---:|---:|---:|---:|
| 120 seconds/5,120 | valid | pass | 5 | 0.0364 | 0.0508 | 0.7778 | 0 |
| 240 seconds/5,120 | `invalid_eos_output` | excluded from comparison | 0 | unavailable | unavailable | unavailable | unavailable |
| 300 seconds/5,120 | `invalid_eos_output` | excluded from comparison | 0 | unavailable | unavailable | unavailable | unavailable |
| 240 seconds/1,024 forced | recovered with valid 120-second children | pass | 5 | 0.0364 | 0.0508 | 0.7778 | 0 |

The 240-second and 300-second helper calls reported an EOS stop but had no
timestamp markers or verifiable segments. The stable codes in the manifest,
attempt outcome, and helper failure all matched `invalid_eos_output`. Both
results were preserved only as raw evidence and were not included in canonical
promotion. Unmeasured time and quality were recorded as `null` or `unavailable`
rather than fabricated as 0. Under these latest conditions, there were 0
valid 240-second EOS leaves and 0 valid 300-second EOS leaves. Only the
120-second direct candidate worked.

The forced case isolated two 240-second limit parents and promoted only five
120-second EOS children. Top-level `passed` becomes true only when the
candidate-120 and forced-recovery quality gates pass, all run integrity values
are true, and there are 0 unexplained failures. Only candidate-120 enters
the quality comparison. The fresh evaluator matched the existing JSON byte for
byte, exited 0, reported `passed: true`, and suggested 120 seconds.

This result strengthens the basis for keeping the production maximum at
120 seconds. Rerun this matrix under a new evaluation ID when extending the
policy to leaves longer than 120 seconds or changing the model revision,
tokenizer, helper, or prompt format. If `invalid_eos_output` is observed in a
production leaf of 120 seconds or less, review the current v1 explicit-failure
contract and evaluate any bounded-recovery extension under a separate plan.

## 2026-08-04 Evaluator Provenance Record

The 2026-08-04 review found that this document's typed final matrix
`evaluation.json` did not identify the evaluator that produced it. Its
`git_head` is `fd5ca427`, the source state at execution time, but the tracked
evaluator at that commit predates the correction. The artifact alone therefore
could not identify its derivation code.

After the repair, the evaluator records `evaluator_source_sha256` and
`evaluator_git_head` in new evaluations. The preserved local
`moss-long-audio-final/evaluation.json` artifact is outside this repository and
remains in the old format under the create-only contract. Reverification
compares every other field while excluding those two provenance fields. The
evaluation SHA-256 cited by this document,
`73ec3810a72c5e184abb1f57a506f182bc5c67b16bae3aa4f43c7ddbb031b2af`,
did not change. Rerunning the current evaluator on the day of the repair still
exited 0 and reported `passed: true`.
