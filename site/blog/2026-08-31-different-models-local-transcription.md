---
slug: bounding-speech-models-on-apple-silicon
title: "Different Models for Different Jobs in a Local Transcription Pipeline"
description: "How a local Mac transcription app assigns bounded roles to VibeVoice, MOSS, Community-1, and Gemma while Qwen and DiCoW remain behind distinct research gates, with Whisper as the comparison control."
authors: [gigio1023]
tags: [speech-recognition, apple-silicon, local-first, diarization, model-evaluation]
image: /img/social-card.png
---

import useBaseUrl from '@docusaurus/useBaseUrl';

I build [Maccheroni](https://github.com/gigio1023/maccheroni), a transcription app that runs on one Apple Silicon Mac. It is meant for conversations that mix languages inside a single utterance: Korean meetings where English product names appear throughout, language classes, and multilingual calls. Working on it has pushed me toward a particular view of model selection. The useful question is not which speech model is best. It is which narrow job each model family can be held accountable for, and what evidence would justify moving that family from the research shelf into the product.

This note follows the current assignments, the measurements that shaped them, and the boundaries around several candidates. Qwen and DiCoW are part of that story, alongside the models already doing the work.

<!-- truncate -->

<img
  src={useBaseUrl('img/pipeline-light.svg')}
  alt="Maccheroni pipeline: one whole-file speaker timeline, bounded ASR leaves, timestamp merge, and separate post-processing"
/>

## One pipeline, several small authorities

The shipped pipeline refuses to let one model own everything. A whole-file diarization pass with [Community-1 Core ML](https://huggingface.co/aufklarer/Pyannote-Community-1-CoreML) produces the only speaker timeline. ASR runs in bounded leaves and merges into that timeline by timestamp, so a chunk-local speaker guess cannot flip a label later in a long recording. Korean ASR uses [VibeVoice-ASR-8bit](https://huggingface.co/mlx-community/VibeVoice-ASR-8bit), which receives glossary terms as free-text context. Italian and mixed ASR uses [MOSS-Transcribe-Diarize 0.9B](https://huggingface.co/aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8), which receives them as a hotword instruction.

Correction and translation form another boundary. The local route uses a dense [Gemma 4 12B model](https://huggingface.co/mlx-community/gemma-4-12B-it-qat-4bit). An optional remote route sends bounded transcript text through the operator's Codex sign-in. Neither route receives audio, and neither may change speaker assignments or timestamps.

| Job | Current route | What it is allowed to decide |
| --- | --- | --- |
| Korean ASR | VibeVoice ASR 8-bit | Text and local timestamps from bounded audio with free-text glossary context |
| Italian and mixed ASR | MOSS 0.9B MLX INT8 | Text and local timestamps from 120-second-or-shorter leaves with hotword instructions |
| Speaker identity | Community-1 Core ML | The whole-file speaker timeline used by the final merge |
| Text correction and translation | Gemma locally or opt-in Codex | Text-only derived output; never speakers, timestamps, or the raw transcript |

Both ASR models emit speaker labels of their own. Those labels remain in diagnostic output but never become the product's speaker IDs. The whole-file timeline stays authoritative because changing a speaker or a time interval requires acoustic evidence. Every downloadable model is also pinned by Hugging Face ID, revision, and quantization. A family name or parameter count does not identify the weights precisely enough; the same VibeVoice artifact has circulated under 7B, 8B, and 9B labels.

## Glossary transport is a decoding property

The design commitment I would defend hardest is injecting the glossary before decoding. Once an ASR model writes the wrong name, the acoustic evidence that could have distinguished it is gone. Post-processing can make a plausible repair, but it cannot recover a sound the decoder never represented. Glossary transport therefore belongs to each model's native interface, not to a generic replacement step around it.

The Italian benchmark showed how this can fail in the other direction. A Parakeet CTC vocabulary path raised term recall from 0.333 to 0.778 on the conversation fixture. The rest of the row made that gain unusable: character error rate rose from 0.116 to 0.245, backchannel preservation fell from 7/7 to 1/7, and the mechanism inserted glossary terms 12 times into FLEURS audio that contained none of them. Recall without a false-insertion control rewards the wrong behavior. MOSS produced zero glossary terms on the same glossary-free FLEURS control.

The correction stage follows the same restraint. It treats glossary entries as context rather than mandatory substitutions. An uncertain change is marked for review. A four-state comparison scores raw and corrected output with and without decode-time injection, and it counts edits that move a segment away from the reference.

## Silent loss is a contract failure

The second commitment is that no stage may lose speech silently. The concrete incident behind it is the mlx-audio VibeVoice path, which silently truncates audio after a hard 59-minute cap. Maccheroni splits before the backend boundary, and any input beyond a backend limit must fail explicitly or produce a split plan.

MOSS made the same rule visible at a shorter scale. A fixed 600-second synthetic Italian input was evaluated with 120-, 240-, and 300-second leaves. The 120-second route produced five valid end-of-sequence leaves with CER 0.030, WER 0.051, term recall 0.778, and no omitted utterances. At 240 and 300 seconds, the later typed replay produced zero valid end-of-sequence leaves. Both paths closed as `invalid_eos_output`, and neither contributed partial text to the canonical transcript. Forced recovery split the affected 240-second parents into five valid 120-second children.

That is why the production cap is 120 seconds. A failed leaf can split down to 60 and then 30 seconds within a fixed recovery depth. Only complete end-of-sequence output is promoted. The detailed runs and the 2026-08-11 WER recalculation are recorded in the [MOSS long-audio verdict](https://github.com/gigio1023/maccheroni/blob/main/docs/moss-long-audio-verdict.md).

## What the product fixtures measured

The current defaults came from public and synthetic fixtures rather than model descriptions.

<img
  src={useBaseUrl('img/benchmarks-light.svg')}
  alt="Published Maccheroni benchmark results for Korean and Italian ASR and diarization"
/>

| Fixture | Model | CER | WER | Term recall | DER |
| --- | --- | ---: | ---: | ---: | ---: |
| Korean dialogue, 20-term glossary | VibeVoice | 0.081 | 0.141 | 0.95 | unavailable |
| Italian two-speaker synthetic, 9-term glossary | MOSS + Community-1 | 0.033 | 0.085 | 0.778 | 0.048 |
| VoxConverse sample, 78 minutes | VibeVoice + Community-1 | unavailable | unavailable | unavailable | 0.152 |

Community-1 also kept representative labels stable across nine repetitions of the 78-minute sample, but it over-segmented two reference speakers into eight raw labels. That result supports long-file consistency for the representative speakers. It does not solve extra-label reporting or prove performance on a noisy meeting. The fixture boundary matters as much as the number.

## An earlier Qwen route and its missing evidence

An earlier 8-bit Qwen3-ASR 1.7B MLX route was measured on the same Korean sample. With glossary context it recorded CER 0.366, WER 0.314, and term recall 0.25. It was well behind VibeVoice on that fixture, but its 3.74 GiB peak memory was much lower than VibeVoice's 17.05 GiB. That made it interesting as a low-memory fallback.

Quality did not ultimately remove it from the product route. The pinned `speech` 0.0.23 backend exposed no enforceable token cap, terminal reason, token counts, or intra-chunk timestamps. Its transcript could not prove that decoding had ended normally or that output was complete. The adapter now closes that path with a typed `asr_evidence_unavailable` result instead of promoting unverifiable text. The fallback can return when an Apple backend exposes the missing evidence and passes the same fixtures. The original measurements and reversal condition are in the [benchmark verdict](https://github.com/gigio1023/maccheroni/blob/main/docs/benchmark-verdict.md).

This is not a claim that Qwen3-ASR is unsuitable for local speech work. It is a claim about one pinned runtime and one product contract.

## The new research lane: Qwen, DiCoW, and a Whisper control

The first discovery rule considered only models with an existing MLX or Core ML artifact. That made delivery cheap, but it could filter out valuable candidates before their upstream behavior was measured. The current rule ranks expected user value first and treats Apple-runtime availability as conversion cost and risk.

That change reopened [Qwen3-ASR-1.7B-hf](https://huggingface.co/Qwen/Qwen3-ASR-1.7B-hf) in its official Transformers-native form. Its model card lists Korean, English, and Italian, free-form context or hotwords, and both streaming and offline inference. These capabilities map well onto Maccheroni's language and glossary requirements. They remain upstream claims. The exact pinned revision has not completed an MLX conversion, Apple parity run, or product benchmark in this lane.

[Qwen3 ForcedAligner 0.6B](https://huggingface.co/Qwen/Qwen3-ForcedAligner-0.6B-hf) closes independently from ASR. Its model card describes word-level timestamps from audio and text in 11 languages, including Korean and Italian. Those capabilities remain upstream claims. Independent closure matters because an ASR failure should not erase alignment diagnostics, and an aligner failure should not invalidate otherwise useful transcription evidence. The aligner also faces a stricter timestamp test than repeatability. Agreement with its own output shows precision, not acoustic truth. A candidate must pass a predeclared synthetic concatenation-gap fixture with sample-exact acoustic boundaries before its timestamps can anchor a model gate.

[DiCoW](https://huggingface.co/BUT-FIT/DiCoW_v3_MLC), a diarization-conditioned Whisper family aimed at speaker-attributed overlapping speech, targets a different suspected source of correction work. Its conversion is currently blocked, and the reason is not a negative model result. The available Korean material cannot be proven leakage-safe against the candidate training corpora, and the fixtures do not supply the required natural multi-speaker Korean overlap stratum. FLEURS is read speech, HiKE does not provide that overlap condition, and AMI does not cover the product languages.

The DiCoW branch reopens when a public natural Korean corpus passes the frozen corpus and alias exclusion rule. A cheap upstream comparison between the MLC and v3.3 candidates would then run on the same pack, with [Whisper large-v3-turbo](https://huggingface.co/openai/whisper-large-v3-turbo) as the vanilla control, before any converted weights are written. The Qwen branch does not inherit this dataset blocker. It remains subject to its own value review, runtime, parity, and timestamp requirements. The [research lane](https://github.com/gigio1023/maccheroni/blob/main/docs/dicow-conversion-lane.md) keeps those decisions separate.

## When conversion earns its cost

The lane deliberately gives no value credit to a model that merely loads, a converter that merely completes, or an adapter that emits well-formed output. Project-owned conversion requires three findings. The pinned upstream reference must show material value on declared fixtures. The license must permit the exact local derivative and any intended publication or redistribution. The Apple artifact must then match preprocessing, outputs, bounds, failures, and task-level behavior on the same inputs.

The unit behind those gates is correction burden. Maccheroni's success measure is whether one important meeting becomes a reliable speaker-attributed record with no more than 30 minutes of human correction. Candidate value therefore includes language fidelity, glossary recall without false insertion, speaker and timestamp accuracy, supported-device cost, and maintenance load. The nearest product priority is still restoring reproducible empty-cache provisioning for the shipped Korean profile. That baseline has to become easy to reproduce before a new candidate can beat it honestly.

A local speech system is a set of boundaries around changing models: what each family may decide, what evidence its output must carry, and what condition would change its assignment. The model list will keep moving. Those boundaries are the part I expect to keep.

*Disclosure: this note describes research engineering and the current evidence boundaries of the [Maccheroni repository](https://github.com/gigio1023/maccheroni). No Qwen or DiCoW MLX or Core ML port has been completed in the new research lane, and Apple-runtime parity has not been established for either family. All measured results above come from the public and synthetic fixtures recorded in the repository; they do not establish broad performance on private or real-world meetings.*
