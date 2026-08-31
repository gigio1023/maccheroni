# Research Digest

This is the implementation-facing summary of the project's model and product research.
External claims use primary sources such as official repositories, model cards, source
code, and papers. Dated findings remain historical; later decisions in
[PROJECT.md](../PROJECT.md) govern when they conflict.

## 2026-08-02 application audit (historical)

The audit examined seven open-source application routes for mixed-language speech,
local diarization and timestamps, bounded long-file processing, decode-time glossary
input, structured export, and local audio handling.

| Application | Finding at the audited revision |
| --- | --- |
| Muesli | Its personal dictionary was a post-processing matcher, not decoder context. |
| Anarlog, formerly Hyprnote | Local diarization and VAD were useful, but the local Parakeet vocabulary parameter was always empty. |
| Spokenly | Local Qwen3-ASR, diarization, and speaker JSON existed; model-level dictionaries were cloud-only. |
| TypeWhisper | Glossary context reached ASR, while diarization was cloud-only. |
| local-whisper | Qwen3 context construction existed, but diarization did not. |
| TranscriptionSuite | VibeVoice paths discarded prompt and speaker-count inputs. |
| MacWhisper, Whisper Snapper, Superwhisper, VoiceInk, HyperWhisper | The inspected routes did not provide the complete combination. |

This was never a market-wide result. D38 withdrew that interpretation after named
counterexamples were found. New comparisons must name a product, revision, execution
route, and evidence.

## Product anchors

The shipped model identities remain fixed until a candidate wins the same fixtures and
preserves the run contract.

| Role | Current product model | Relevant verified behavior |
| --- | --- | --- |
| Korean ASR | `mlx-community/VibeVoice-ASR-8bit@725c72e5` | Korean, English, and Italian support; free-text context; joint transcript, speaker, and timestamp output upstream. The current MLX path has a 59-minute input guard and depends indirectly on a pinned Qwen tokenizer. |
| Italian and mixed ASR | `aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8@90aa6528` | Instruction hotwords, ASR, speakers, and timestamps. The product caps leaves at 120 seconds because longer measured leaves lost timestamp structure. |
| Diarization | `aufklarer/Pyannote-Community-1-CoreML@a14e6c42` | Whole-file speaker authority. Chunk-local ASR labels never override its timeline. |
| VAD | `aufklarer/Silero-VAD-v6.2.1-CoreML@52387654` | Local silence map and split input. |
| Local post-processing | `mlx-community/gemma-4-12B-it-qat-4bit@e70c6b3b` | Dense local correction and translation baseline. |

Preprocessing keeps 16 kHz mono conversion, peak normalization, and Silero VAD on by
default. DeepFilterNet3 remains opt-in because published evaluations show that speech
enhancement can worsen modern-ASR error rates, including on clean speech. Diarization
runs on audio that has not passed through enhancement to avoid changing speaker
embeddings.

The product still needs an empty-cache provisioning repair. `ko-meeting` depends on the
VibeVoice snapshot, an indirect pinned `Qwen/Qwen2.5-7B` tokenizer, and Hugging Face
reference/tree metadata. The source checkout does not yet provision and diagnose that
complete closure reproducibly. Fixing it precedes candidate promotion because it
creates the baseline every candidate must beat.

## 2026-08-31 model and Apple-runtime refresh

D42 changed the discovery rule: lack of an existing MLX or Core ML artifact is a cost,
not a reason to discard a valuable model. Maccheroni may implement its own conversion
and bounded runner after upstream value, rights, and parity gates pass. Loading a model,
emitting JSON, or satisfying a schema does not show that the model reduces correction
work.

Candidate value is judged by correction-time reduction, language fidelity, glossary
recall without false insertion, speaker and timestamp accuracy, supported-device cost,
and maintenance burden. The current evidence does not justify changing a product pin.

### Shortlist

| Candidate | Why it remains relevant | Current disposition |
| --- | --- | --- |
| [`Qwen3-ASR-1.7B-hf@bcd2b5b`](https://huggingface.co/Qwen/Qwen3-ASR-1.7B-hf/tree/bcd2b5b7f32b480ab5790554cfa8347f246a14f3) | Official Transformers-native ASR supports Korean, English, Italian, context or hotwords, and streaming or offline inference. | Required candidate if the lane proceeds; J1 may still stop all work. Source identity and rights permit bounded implementation work; Apple parity and the D37 evidence contract remain unestablished. |
| [`Qwen3-ForcedAligner-0.6B-hf@c07281d`](https://huggingface.co/Qwen/Qwen3-ForcedAligner-0.6B-hf/tree/c07281df297b9905d24a508279258cccf987a064) | Official 11-language aligner includes Korean and produces word-level timestamps from audio plus text. | Evaluate independently from ASR. The exact c072 Apple semantic bridge is unestablished, so a thin model implementation or converter may be needed. |
| [`BUT-FIT/DiCoW_v3_MLC@99c64e8`](https://huggingface.co/BUT-FIT/DiCoW_v3_MLC/tree/99c64e8dc409a158816e808a1ee556cdfd0af51c) | Diarization-conditioned Whisper targets speaker-attributed overlap and reports conversation-level Korean, English, and Italian evidence. | Conversion is blocked until a leakage-safe natural Korean overlap stratum exists. Published conversation metrics do not establish Maccheroni's overlap-region value. |
| [`BUT-FIT/DiCoW_v3_3@c34b64d`](https://huggingface.co/BUT-FIT/DiCoW_v3_3/tree/c34b64d9a9c5148c65fd355bb188d60343a6b44f) | Same-family challenger with stronger English overlap evidence. | Compare upstream with MLC on the same pack only after the Korean evidence blocker clears. |
| [`BUT-FIT/SE-DiCoW@470fce9`](https://huggingface.co/BUT-FIT/SE-DiCoW/tree/470fce9ffff844dd53a27751cdf6c6df9efecb39) | Self-enrollment and per-layer conditioning target fully overlapped speech. | Watch for Korean and Italian evidence; do not retarget from MLC on English results alone. |
| [`TaurenMountain/PS4@8feb7a1`](https://huggingface.co/TaurenMountain/PS4/tree/8feb7a1b3da1264659f155c42bfb40a5be88d730) | Target-speaker extraction could preserve the shipped ASR and glossary paths. | Timeboxed fallback if overlap causes material correction work and direct DiCoW fails glossary or attribution gates. |
| [`microsoft/VibeVoice-ASR-BitNet@66e7802`](https://huggingface.co/microsoft/VibeVoice-ASR-BitNet/tree/66e78021ab8f5f06133d1ab421ba4d348bda97c9) | Smaller official CPU artifact with product-language coverage and context prompting. | Low-memory experiment only if supported-device measurements justify the quality and kernel cost. |
| [`espnet/owsm_ctc_v4_1B@6db4171`](https://huggingface.co/espnet/owsm_ctc_v4_1B/tree/6db41715b887d65d2d6936a290e7844cb98f9d29) | Open multilingual control covering the product languages. | Run upstream only if code switching becomes a measured correction cause and a useful glossary path is defined. |

Blind separation remains secondary. DAVE TIGER-M is a small two-stream control and
MossFormer2-SS uses broadly portable operations, but neither supplies a stable
long-form global-speaker contract. Diarization model development remains a project
non-goal. Community-1 stays authoritative unless a separately adopted decision changes
that boundary.

### Qwen family disposition

The official Qwen3-ASR card lists 30 languages and 22 Chinese dialects, Korean among
them, free-form prompt context, and Transformers-native support from version 5.13.0.
The official ForcedAligner supports 11 languages and up to five minutes of speech per
unit. These are upstream capabilities. They do not prove the behavior of an MLX or
Core ML implementation.

Existing Apple projects and community weights lower implementation cost, but the exact
bcd2 ASR and c072 aligner still require source-lineage, tensor, preprocessing, decode,
and public-fixture comparisons. Reuse the existing path only if those checks pass.
Otherwise implement the smallest project-owned adapter or converter. Start at BF16 or
the appropriate reference precision; consider int8 only after parity.

D37 remains in force. Qwen ASR cannot return as a product fallback until one Apple
adapter reports an enforceable token cap, generated-token count, typed terminal reason,
and validated timestamps while passing the quality fixtures. The aligner needs
independent acoustic timestamp truth; agreement with its own text-derived output is not
enough.

Large or service-only Qwen audio models remain ceiling references. They do not justify
a local port without a smaller Qwen3-ASR comparison and a measured quality margin that
repays memory and implementation cost.

### DiCoW disposition

The first DiCoW plan assumed that HiKE and FLEURS could support a Korean value gate.
The pre-model audit invalidated that assumption because training-data exclusion was not
proven and the fixtures do not supply the required natural multi-speaker overlap
stratum. This is an evidence blocker, not evidence that DiCoW is poor.

Reopen DiCoW only when a public natural Korean corpus passes the frozen corpus and alias
exclusion rule for both MLC and v3.3. Then run the predeclared cheap upstream comparison
before writing converted weights. If no candidate passes the absolute overlap,
non-overlap, glossary, language, speaker, and timestamp gates, convert neither.

The Qwen branch does not inherit this blocker. A formal value review must decide whether
Qwen adapter and conversion work is worth doing now or should stop behind shipped
baseline restoration. The review may choose either outcome and must not rubber-stamp a
prewritten Qwen-only result.

The detailed contract, pins, claim ceilings, and reversal conditions are in
[docs/dicow-conversion-lane.md](dicow-conversion-lane.md).

### Other Apple routes

Before creating a new converter, audit the exact revision of existing speech-swift,
mlx-audio, mlx-audio-swift, ExecuTorch, or llama.cpp support. Those projects contain
routes for some Qwen, Omnilingual, Nemotron, Cohere, Voxtral, VibeVoice, and alignment
models. A family name in a source tree is not proof that the pinned checkpoint,
preprocessing, timestamps, terminal evidence, or Metal execution path matches this
project.

Gemma 4 12B remains the dense post-processing baseline. Qwen, Ministral, Granite,
Apertus, Hy-MT, and TranslateGemma variants are worth testing only through the existing
correction harness. Structured JSON and tool calling are implementation properties.
Promotion requires fewer harmful edits while preserving all segments, speakers,
timestamps, proper nouns, numbers, and clean-control glossary terms.

### Conversion and serving rule

Project-owned conversion follows three gates:

1. the pinned upstream reference shows material value on public or synthetic fixtures;
2. the license permits the exact local derivative and any intended publication or
   redistribution action;
3. the Apple artifact matches preprocessing, model outputs, bounds, failures, and
   task-level behavior on the same inputs.

Pin the upstream revision, converter source, calibration provenance, quantization
recipe, runtime version, and artifact hashes. Converted weights and run outputs stay
outside the repository. Prefer a library or one-shot runner. Add a persistent server
only when measured startup or lifetime cost requires it and a separate product decision
authorizes it.

### Evidence still needed

- Empty-cache `ko-meeting` provisioning and complete doctor diagnostics.
- A leakage-safe natural Korean overlap stratum for DiCoW.
- Exact bcd2 Qwen ASR Apple lineage and D37 behavior.
- Exact c072 ForcedAligner semantic compatibility and independent acoustic timestamp
  truth.
- Supported-device peak memory, latency, cancellation, and repeatability for every
  candidate that reaches materialization.
- A local correction-burden study that measures whether overlap, glossary, speaker,
  code-switch, or timestamp errors dominate real work without publishing private audio
  or transcript content.

Primary sources for the current Qwen claims are the
[Qwen3-ASR model card](https://huggingface.co/Qwen/Qwen3-ASR-1.7B-hf),
[Qwen3 ForcedAligner model card](https://huggingface.co/Qwen/Qwen3-ForcedAligner-0.6B-hf),
and [Qwen3-ASR source](https://github.com/QwenLM/Qwen3-ASR). DiCoW implementation facts
come from the [official DiCoW repository](https://github.com/BUTSpeechFIT/DiCoW) and
the pinned model cards above.
