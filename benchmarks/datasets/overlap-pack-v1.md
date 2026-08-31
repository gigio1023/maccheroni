# overlap-pack-v1

This declaration freezes the public reference pack used to decide whether target-conditioned overlap decoding is worth an Apple-native DiCoW implementation. It does not contain audio, transcripts, alignments, diarizer output, or model weights. Those artifacts are created outside the repository in one fingerprinted, create-only attempt.

The pack does not prove that FLEURS or HiKE was excluded from any evaluated model's training data. Results support transport, scoring, and conversion-parity diagnostics. They do not support product-quality promotion.

The utility pack contains ten constructed 30-second mono PCM16 windows: six fixed HiKE pairs, two English FLEURS pairs, and two Italian FLEURS pairs. These yield twenty pair targets. Twelve HiKE singles, the eight selected FLEURS singles, and two independently ranked Korean FLEURS controls are also sealed. AMI IN1009 `[95,155)` is split into two parity-only windows and does not support an overlap-utility claim.

## Fixed construction

For source lengths `n_A` and `n_B`, the overlap is `floor(2*min(n_A,n_B)/5)` samples and B starts at `n_A-overlap_samples`. Each PCM16 source becomes binary64 by division by 32768 and is peak-normalized to the literal `0.7079457843841379`. The placed tracks are added in A-then-B order. `mix_gain` is `0.999/mix_peak` only when the peak exceeds `0.999`; otherwise it is exactly `1.0`. The same gain applies to both component tracks and the mixture. Values are clamped to `[-1,32767/32768]`, multiplied by 32768, rounded to nearest with ties to even, cast to signed int16, and zero-padded to 480,000 samples. A zero-peak source or overlong pair blocks evidence.

Activity uses half-open supports and 50 Hz frame centers. STNO files are row-major little-endian float32 in class order `silence,target,non_target,overlap`, with logical shape `[4,1500]`. The reference runtime consumes `[B,4,1500]`; the MLX runtime receives one explicit transpose to `[B,1500,4]`.

## Frozen selection and isolation

The aligner manifest order is twelve HiKE rows, eight English FLEURS rows, and eight Italian FLEURS rows. Exactly two fresh offline Qwen3 ForcedAligner processes consume that identical 28-row manifest. Partial, duplicated, reordered, non-monotone, out-of-bounds, or structurally inconsistent results invalidate the attempt.

Each result must preserve the same row IDs, source hashes, normalized units, model identity, and T9-bound snapshot record. Timestamps may vary between repetitions but each result must remain finite, monotone, and inside its source duration. Each FLEURS locale first ranks all test rows lasting 4 through 12 seconds by SHA-256 of the literal `maccheroni-overlap-pack-v1`, locale, and row ID. The first eight form the immutable candidate pool. Pair evaluation keeps the earlier row as A. It removes only an ineligible row, retains an eligible survivor, never swaps roles, and stops after two pairs. Exhaustion blocks evidence.

After the final ten mixtures are known, the preparer launches one fresh Community-1 child per mixture with network denied. The aligner snapshot, Community model subtree, speech binary, and sandbox profile must match the full artifact records in T9's canonical preflight selector before and after use. Each diarizer record binds its exact sandboxed command, input audio hash, stdout and stderr hashes, exit status, elapsed time, and recomputed activity. Labels come only from its clipped, merged 50 Hz activity. Text never influences A/B mapping. Zero, one, two, and surplus-label outcomes remain explicit. A synthetic padded-silence label is separate from real labels and mapping.

A stable word must remain wholly inside the same overlap or non-overlap region with 320 samples of context in both aligner repetitions. Every HiKE target needs stable overlap and non-overlap words. One failure emits `korean_geometry_unavailable`, produces no partial Korean utility rows, and cannot shrink the frozen twenty-target denominator.

Agreement between repetitions establishes precision, not acoustic boundary accuracy. Before any overlap-region metric from this pack can support a gate, the exact aligner revision used to build it must pass a predeclared concatenation-gap fixture with sample-exact acoustic boundaries.

## Crop and license boundary

Target crops preserve original window coordinates. Their core spans all stable overlap words across both aligner repetitions. Each side receives at most 320 samples of the declared Hann context. The crop uses binary64 pi `3.141592653589793`, retains the pair's `mix_gain`, applies no post-crop normalization, and keeps interfering audio inside K. Frames outside K are exact STNO silence.

HiKE is Apache-2.0. FLEURS, AMI, and Community-1 are CC-BY-4.0. Tracked declarations record source identity, licenses, and attribution. The external pack binds immutable hashes to those declarations. Private recordings are rejected. Real or public pack outputs must stay outside the tracked tree; only small synthetic test fixtures may be tracked. No transcript, alignment, raw diarizer result, model cache, or converted weight may enter the tracked tree.
