# CLI guide

Build the executable from the repository root:

```bash
swift build --product maccheroni
```

## Discover commands

```bash
.build/debug/maccheroni help
.build/debug/maccheroni help run
.build/debug/maccheroni capabilities --json
.build/debug/maccheroni --generate-completion-script zsh
```

`help` provides readable command usage. `capabilities --json` reports commands, side effects, output contracts, and JSON support for coding agents.

## Check readiness

```bash
.build/debug/maccheroni doctor
.build/debug/maccheroni doctor --json
```

`doctor` is read-only and does not download models. Text mode prints `key=value` lines. JSON mode returns `command`, `ready`, `schema_version`, and `values`. Failed checks set `ready` to `false` and exit nonzero while keeping JSON on stdout.

## Transcribe audio

```bash
.build/debug/maccheroni run recording.wav --profile it-dialogue
.build/debug/maccheroni run recording.wav --profile it-dialogue --json
```

Use `--profiles PATH` for another profile registry, `--output-root PATH` for the run parent directory, and `--glossary PATH` for decoding terms. Text mode prints the new run directory. JSON mode returns `command`, `run_path`, and `schema_version`.

A run creates a directory and may download local model assets. Audio never leaves the Mac. A selected text-only post-processing backend may receive transcript text but never audio.

## Output contract

- Results go to stdout; errors go to stderr.
- Commands never prompt.
- JSON is one UTF-8 line with sorted keys and `schema_version: "1.0.0"`.
- Syntax errors exit 64. Product failures and failed readiness checks exit nonzero.
