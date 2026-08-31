# Model ledger

Every benchmark manifest must repeat the exact HF ID, revision, and
quantization from this ledger. `pending download` never means a wrapper may
silently replace the model with another one.

| purpose | HF model ID | revision | manifest quantization | state |
| --- | --- | --- | --- | --- |
| VibeVoice-ASR smoke | `microsoft/VibeVoice-ASR` | `d0c9efdb8d614685062c04425d91e01b6f37d944` | bf16 | downloaded and smoke-tested |
| VibeVoice-ASR benchmark variant | `mlx-community/VibeVoice-ASR-8bit` | `725c72e54d6ef875472c27fbc50fab470a960940` | `int8` | downloaded for exact-revision T4/T6 runs |
| VibeVoice-ASR benchmark variant | `mlx-community/VibeVoice-ASR-bf16` | `12076ff8cb141fcb672abc9f8957b08aab5ecf94` | `bf16` | downloaded for exact-revision T4/T6 runs |
| Qwen3-ASR 1.7B | `aufklarer/Qwen3-ASR-1.7B-MLX-8bit` | `e5450a26d1fd417c45fc9c405651ddc3180a27a6` | `int8` | downloaded and smoke-tested |
| Qwen upstream reference | `Qwen/Qwen3-ASR-1.7B` | `7278e1e70fe206f11671096ffdd38061171dd6e5` | `bf16` | provenance only; the runner uses the MLX int8 row above |
| MOSS MLX runner | `aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8` | `90aa65287111a327db98eb83e325bd5332945edd` | `int8-decoder+fp16-audio-vq-kv` | downloaded and smoke-tested with decode-time hotword instruction |
| MOSS upstream reference | `OpenMOSS-Team/MOSS-Transcribe-Diarize` | `e8681d68e7042738ffca8ac8212bc8fcb1131ab8` | `unknown` | provenance only; runner uses the pinned MLX INT8 row above |
| Parakeet v3 upstream reference | `nvidia/parakeet-tdt-0.6b-v3` | `7c35754d166cca382ad1e53e68b01e7c575f3a1d` | `bf16` | provenance only |
| Parakeet v3 CoreML runner | `FluidInference/parakeet-tdt-0.6b-v3-coreml` | `aed02740059203c4a87495924f685de3722ae9ce` | `coreml-int8-mixed6-fp16` | downloaded and smoke-tested |
| Parakeet CTC vocabulary rescorer | `FluidInference/parakeet-ctc-110m-coreml` | `accdafd8cf8a2ff1cabe3c11e54416b405d409aa` | `coreml-fp16-mixed6-sparse` | downloaded for the offline exact-revision T6 glossary path |
| speech-swift pyannote segmentation | `aufklarer/Pyannote-Segmentation-MLX` | `abef0110277063f0ea117a802832a3eba22af84c` | `fp32` | downloaded and smoke-tested |
| speech-swift pyannote embedding | `aufklarer/WeSpeaker-ResNet34-LM-MLX` | `26499ce11ad1b48ac96aacc8d6fa433f941bdc96` | `fp32` | downloaded and smoke-tested |
| speech-swift community1 | `aufklarer/Pyannote-Community-1-CoreML` | `a14e6c420d56e8472850649b016a486fd0acbe81` | `coreml-fp32` | downloaded and smoke-tested |
| speech-swift Silero VAD | `aufklarer/Silero-VAD-v6.2.1-CoreML` | `523876545a57961474fee9df913e833e130560b8` | `coreml-float16` | downloaded for the pinned offline runtime |
| FluidAudio offline diarization | `FluidInference/speaker-diarization-coreml` | `1ed7a662fdc7109e36d822db793ee6eebdaf8594` | `coreml-fp32+fp16` | downloaded and smoke-tested by the offline-only harness |

Manifest quantization values are schema-safe identity tokens. The selected
CoreML snapshot metadata expands them as follows: Parakeet v3 uses an Int8
preprocessor, a mixed Float16 and 6-bit-palettized encoder, and Float16
decoder/joint models. Its CTC helper uses a Float16 mel model and a mixed
Float16, 6-bit-palettized, sparse encoder. Community-1 stores FP32 graph and
weights. FluidAudio offline diarization stores segmentation, FBank, and PLDA
as Float32 and its embedding model as Float16. Runtime graphs can still contain
non-weight integer and Float32 operations.

The locked mlx-audio 0.4.6 VibeVoice adapter indirectly uses the tokenizer
from `Qwen/Qwen2.5-7B` revision
`d149729398750b98c0af14eb82c78cfe92750796`. Provisioning fetches exactly
`config.json`, `tokenizer.json`, `tokenizer_config.json`, `merges.txt`, and
`vocab.json`. It does not fetch or load Qwen inference weights, so
quantization is not applicable. The Qwen revision identifies this adapter's
text vocabulary. It does not identify VibeVoice's release age and does not
apply to every VibeVoice runtime.
