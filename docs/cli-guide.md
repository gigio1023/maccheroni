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

`doctor` is read-only and does not download models. It inspects the configured
recording, run, library, and active model-cache roots. Roots on the same volume
are grouped so one free-space value is reported for that volume. Text mode
prints `key=value` lines. JSON mode returns `command`, `ready`,
`schema_version`, `values`, and the typed `storage` object. The typed storage
contract is doctor schema `1.1.0`. Failed checks set
`ready` to `false` and exit nonzero while keeping JSON on stdout.

The text storage fields use stable indexes:

```text
storage.observable=true
storage.volume_count=1
storage.volume.0.id=volume-01234567-89ab-cdef-0123-456789abcdef
storage.volume.0.name=External SSD
storage.volume.0.roles=recordings,runs
storage.volume.0.available_bytes=42133790720
storage.volume.0.capacity_status=available
storage.root_count=2
storage.root.0.id=library.recordings
storage.root.0.role=recordings
storage.root.0.status=available
storage.root.0.bookmark_status=current
storage.root.0.volume_id=volume-01234567-89ab-cdef-0123-456789abcdef
storage.root.1.id=library.runs
storage.root.1.role=runs
storage.root.1.status=available
storage.root.1.bookmark_status=current
storage.root.1.volume_id=volume-01234567-89ab-cdef-0123-456789abcdef
```

The corresponding JSON shape is:

```json
{
  "storage": {
    "observable": true,
    "roots": [
      {
        "bookmark_status": "current",
        "id": "library.recordings",
        "role": "recordings",
        "status": "available",
        "volume_id": "volume-01234567-89ab-cdef-0123-456789abcdef"
      },
      {
        "bookmark_status": "current",
        "id": "library.runs",
        "role": "runs",
        "status": "available",
        "volume_id": "volume-01234567-89ab-cdef-0123-456789abcdef"
      }
    ],
    "volumes": [
      {
        "available_bytes": 42133790720,
        "capacity_status": "available",
        "id": "volume-01234567-89ab-cdef-0123-456789abcdef",
        "name": "External SSD",
        "roles": ["recordings", "runs"]
      }
    ]
  }
}
```

`name` is the localized volume name and `id` distinguishes volumes that share
a name. Roles can include `recordings`, `runs`, `library_metadata`,
`request_logs`, `glossaries`, `asr_model_cache`, `vad_model_cache`,
`diarization_model_cache`, `postprocess_model_cache`, and `temporary_work`.
The selected Fluid diarization output is temporary work; ASR attempt output is
part of the run root.

A root that has not been created yet reports `not_created` and uses its nearest
existing ancestor to identify the prospective volume. An absent root below
`/Volumes/<name>` reports `unmounted` without attributing system-volume free
space. Other failures report `unreadable` or `bookmark_unavailable`. Bookmark
state is `none`, `current`, `stale`, or `unavailable`; a stale bookmark remains
a reported fact because `doctor` does not refresh preferences. If capacity
cannot be read, `available_bytes` is `null` in JSON and `unavailable` in text.

The report does not apply a minimum-free-space threshold, headroom, or retained
storage formula. `check.storage` and `storage.observable` indicate whether the
configured roots and capacity facts could be observed. A measured value of
zero bytes is still an observed fact.

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
- JSON is one UTF-8 line with sorted keys. `run`, `postprocess`, and
  `capabilities` use schema `1.0.0`; the volume-aware `doctor` envelope uses
  schema `1.1.0`.
- Doctor storage facts are typed under `storage`; non-storage diagnostics remain
  string values under `values`.
- Syntax errors exit 64. Product failures and failed readiness checks exit nonzero.
