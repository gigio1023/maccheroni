# Contributing to Maccheroni

Maccheroni is a small personal project with an unusually strict evidence
culture. Issues and focused pull requests are welcome; large features should
start as an issue so scope can be agreed first.

## Development setup

Requirements: Apple Silicon Mac, macOS 26, Xcode 26, [uv](https://docs.astral.sh/uv/).

```bash
git clone https://github.com/gigio1023/maccheroni.git
cd maccheroni
swift build && swift test          # portable, cache-independent Swift suite
zsh scripts/build-app.zsh          # builds and codesigns Maccheroni.app
.build/debug/maccheroni doctor     # reports observed runtime and model readiness
```

For the optional local post-processing model, run
`zsh scripts/setup-postprocess-runtime.zsh`.

## Testing

The default Swift suite uses bundled or generated fixtures. It does not depend
on an owner model cache, external benchmark runs, or the owner-provisioned
model Python environment.

```bash
swift test
swift test --filter MaccheroniASRTests            # one suite while iterating
```

Real VibeVoice, Silero, and Community-1 inference is an explicit integration
lane. Provision the exact `ko-meeting` closure, then opt in:

```bash
cache_root="$HOME/Library/Caches/Maccheroni/benchmarks"
MACCHERONI_BENCHMARK_CACHE="$cache_root" \
  zsh scripts/setup-transcription-runtime.zsh --profile ko-meeting
MACCHERONI_RUN_MODEL_INTEGRATION=1 MACCHERONI_BENCHMARK_CACHE="$cache_root" MACCHERONI_HF_HOME="$cache_root/models/huggingface" swift test --filter MaccheroniModelIntegrationTests
```

The opt-in tests fail with a prerequisite error when setup is missing or the
runtime is incomplete. Model data and the pinned Python environment stay in
the external benchmark cache. Change `cache_root` to relocate it while keeping
setup and test paths aligned. This closure includes the tokenizer
files that mlx-audio's VibeVoice adapter reads from `Qwen/Qwen2.5-7B`; it does
not include Qwen inference weights or the MOSS runtime.

Python contract suites:

```bash
uv run --project Sources/MaccheroniASR/Python python -m unittest discover -s Sources/MaccheroniASR/Python/tests
uv run --project benchmarks/scripts/scoring python -m unittest benchmarks/scripts/scoring/tests/test_evaluate_moss_long_audio.py
uv run --project benchmarks/scripts/scoring python -m unittest benchmarks/scripts/scoring/tests/test_evaluate_t14.py
uv run --project benchmarks/scripts/scoring python -m unittest benchmarks.scripts.scoring.tests.test_speaker_attributed
uv run --project benchmarks/scripts/scoring python -m unittest benchmarks.scripts.dicow.tests.test_contract
uv run --project benchmarks/env/dicow-aligner python -m unittest benchmarks.scripts.dicow.tests.test_inspect benchmarks.scripts.dicow.tests.test_preflight
uv run --project benchmarks/env/dicow-reference python -m unittest benchmarks.datasets.tests.test_overlap_pack
uv run --no-project python -m unittest benchmarks/scripts/runners/tests/test_moss_long_audio_eval_gate.py
```

All Python tooling runs through [uv](https://docs.astral.sh/uv/): each Python
project in the tree carries its own `pyproject.toml` and `uv.lock`, and
`uv run --project <dir>` creates and reuses the pinned environment on demand.
No system Python, manual virtualenv, or `pip install` step is required.

Benchmark run artifacts are create-only local directories under
`benchmarks/runs/` and are gitignored. Never commit them, never overwrite or
delete an existing run, and never retrofit a scorer to make a preserved run
pass — the scorers derive their verdicts and carry negative tests that pin
that behavior.

### Publishing a benchmark number

Every number in the README tables and in the two generated figures comes from
`benchmarks/published-results.json`. Nothing else is a source: do not edit a
README metric or a committed SVG by hand.

To publish a new or re-measured value:

1. Preserve the run under `benchmarks/runs/`, then copy its exact value, run ID,
   run kind, artifact path, artifact SHA-256, and measurement time into the
   `sources` block. Values are exact decimal strings, not JSON numbers; the
   declaration rounds them for display.
2. Point the relevant fixture metric at that source, and add the fixture to
   `readme.row_order` if it is new.
3. Update the corresponding cells and image alt text in all ten README files.
4. Regenerate the figures, then verify:

```bash
uv run --no-project python -m unittest discover -s benchmarks/scripts/figures/tests
uv run --no-project python benchmarks/scripts/figures/check_readme_benchmarks.py
uv run --no-project python benchmarks/scripts/figures/render_readme_figures.py
```

`render_readme_figures.py` writes to `docs/assets` by default; pass
`--output-dir` to render elsewhere, and `--data` to render from an alternative
declaration. The consistency check compares the ten READMEs against the
declaration only. It does not open a run artifact, recompute an artifact hash,
or inspect a committed SVG, so artifact provenance and figure contents remain
owner-verified.

## Verification standard

Every claim in this repository is held to command-level evidence: a completion
claim must name the command that was run and the output that was observed.
What "verified" means for the core claims:

| Claim | Evidence | Reproduce |
|---|---|---|
| Glossary reaches the decoder per leaf | Hash-sealed payloads in run manifests; T14 glossary contract | `swift test`; owner-side: `uv run --project benchmarks/scripts/scoring python benchmarks/scripts/scoring/evaluate_t14.py` |
| Global speaker consistency | 78-min chunk-boundary stability 1.0; zero mismatches at all root boundaries | same |
| No promotion of truncated output | Typed `invalid_eos_output` / limit outcomes; EOS-only promotion fixtures | `swift test` |
| Originals immutable through post-processing | Byte-identical hash assertions before/after correction and translation | `swift test` |
| Codex lane sends no audio or paths | Invocation-argument and payload fixtures; checksummed live roundtrip evidence | `swift test` |

The T14 evaluator, long-audio matrix, and sealed DiCoW integration replays need local
artifacts that are not in the repository. Portable suites skip those owner-side paths
unless their explicit environment variables are present. Evaluation IDs and SHA-256
seals for preserved runs are recorded in [docs/](docs/).

**Not verified:** real-world accents, overlapping speech, and noisy rooms
beyond the public/synthetic fixtures; the OS-level read scope of the Codex app-server
read-only sandbox; the service-side identity of the Codex model (manifests record the
requested model).

## Commit conventions

- English, imperative subject line, one logical change per commit.
- Write a detailed body for every non-trivial commit. The body alone — without
  the diff, an issue tracker, or chat history — must let a later reader
  reconstruct three things:
  1. **Intent and background**: what problem or observation motivated the
     change, and any constraint or prior decision that shaped it.
  2. **The work**: what was changed, at the level of behavior and structure,
     not a file-by-file paraphrase of the diff.
  3. **Verification**: the commands run and the results observed.
- Keep the body dry and technical, and write it to be globally publishable:
  no personal information, no private paths or hostnames, no profanity, and
  no sensitive or legally encumbered content. If a detail cannot be published,
  it does not belong in the message; keep it in local notes and reference the
  public evidence instead.
- No co-author trailers and no tool/session links in commit messages.
- Never commit: real recordings, model caches, audio files (public or
  synthetic fixtures under `Tests/**/Fixtures/` are the only exception),
  benchmark run outputs, or personal file paths.
- No force pushes to `main`.

## Engineering constraints

- Before changing anything that moves an execution bound — model, backend,
  chunk length, token budgets, timeouts, retries, fallbacks, caching — read
  [docs/engineering-constraint-policy.md](docs/engineering-constraint-policy.md)
  and validate the combination of individual limits with the same calculation
  and tests it prescribes.
- Models are pinned by Hugging Face ID + revision + quantization. Changing a
  pin requires re-running the relevant benchmark matrix and recording the new
  evidence; results are recorded by ID and revision, never by parameter-count
  nicknames.
- Originals and raw transcripts are immutable; run outputs are create-only;
  failures are typed. A change that can silently drop data will not be merged.

## Issues

A useful bug report includes:

- macOS and Xcode versions, Mac model.
- The exact command or app action, and the profile used (`ko-meeting`,
  `it-dialogue`, ...).
- `maccheroni doctor` output.
- Structural metadata from the run manifest (status, `failure.code`, attempt
  outcomes) — never attach recordings, transcript contents, or personal paths.

## Pull requests

- Open an issue first for anything beyond a small fix.
- Behavior changes need fixture-based tests; keep new code adapter-shaped so a
  backend change stays out of app code.
- Before submitting, pass locally: `swift build && swift test`, the Python
  suites above, and `zsh scripts/build-app.zsh` when packaging or resources
  changed.
- UI strings must keep the String Catalog's 10-locale parity — the fixtures in
  `AppShellTests` enforce key counts and placeholder parity.
- A README content change propagates to all ten language files.
- `PROJECT.md`'s decision log is append-only: decisions are superseded by new
  entries, never rewritten. Docs, code identifiers, and commit messages are
  in English.

## License

MIT. By contributing you agree your changes are licensed under the same terms.
