# Offline speech runtime

This executable gives Maccheroni a fixed offline entry point for the two
speech-swift 0.0.23 pipelines used by the `ko-meeting` profile. The Swift
package pins speech-swift by commit and checks in `Package.resolved` so its
transitive SwiftPM graph is reproducible.

`--cache-dir` is the exact local Hugging Face repository root for the command's
model. The setup script installs those roots below
`qwen3-speech/models/aufklarer` in the selected Maccheroni cache.

```sh
maccheroni-offline-speech-runtime vad-stream input.wav \
  --cache-dir /path/to/Silero-VAD-v6.2.1-CoreML --json

maccheroni-offline-speech-runtime diarize input.wav \
  --cache-dir /path/to/Pyannote-Community-1-CoreML --json \
  --min-speakers 1 --max-speakers 4
```

Silero passes `offlineMode: true` and an explicit local cache directory.
Community-1 uses `fromLocal(directory:)`, which has no download path.
The process writes only its final JSON document to standard output. Failure
diagnostics use fixed messages and never echo input paths or decoded content.
