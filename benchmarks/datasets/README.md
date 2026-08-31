# Public Evaluation Datasets

This directory contains only provenance, pinned revisions, and reproducible acquisition
commands. Downloaded audio and source Parquet files remain local under
`benchmarks/samples/public/`; that path is gitignored. Use only public data. Do not read
or copy private recordings.

## Acquisition

Authenticate the Hugging Face CLI before running:

```sh
hf auth whoami
bash benchmarks/datasets/acquire-public-datasets.sh
uv run --with pyarrow python benchmarks/datasets/check-public-datasets.py
```

The script pins every file to a commit revision. The default destination is
`benchmarks/samples/public/`; pass another local path as the first argument when needed.
For example, run
`bash benchmarks/datasets/acquire-public-datasets.sh /tmp/maccheroni-public-datasets`.

## Rebuilding the legacy Stage 2 fixtures

The eight Stage 2 fixtures are generated artifacts and stay ignored. The tracked
builder reads only the pinned public source tree and writes a separate mirror root. It
keeps the historical `benchmarks/runs/...` logical paths inside that mirror so the six
toolchain-deterministic `fixture-check.json` files remain byte-identical to their
originals.

```sh
bash benchmarks/datasets/acquire-public-datasets.sh
fixture_root="benchmarks/runs/post-v1-reliability-reset/fixture-rebuild"
uv run --project benchmarks/scripts/fixtures --frozen python \
  benchmarks/scripts/fixtures/build_stage2_fixtures.py \
  --source-root . \
  --output-root "$fixture_root"
uv run --project benchmarks/scripts/fixtures --frozen python \
  benchmarks/scripts/fixtures/verify_stage2_fixtures.py \
  --source-root . \
  --fixture-root "$fixture_root"
```

Both tools fail closed when any pinned public-source hash changes. The builder also
refuses to overwrite any of the eight target directories. The verifier checks the
historical SHA-256 ledger for `hike-tech`, both FLEURS fixtures, `ko-code-switch`, and
the two VoxConverse fixtures. `voxconverse-ppgjx-78m` is a ninefold repeated reel for
duration and global-speaker checks. It is not a natural 78-minute conversation.

`italian-dialogue` and its byte-copied `it-dialogue` view use macOS `/usr/bin/say`.
Their selections record the exact macOS product and build versions, `say` binary hash,
code-signing identifier, voice, rate, and text. OS updates can change the waveform. The
verifier therefore requires exact current-host provenance and reports whether it matches
the historical generator, but it does not require historical fixture hashes for these
two host-bound outputs.

## ASR: FLEURS Test Split by Language

| Target | Selected source | Pinned revision | Selected scope | Ground-truth format | License |
| --- | --- | --- | --- | --- | --- |
| Korean | [dataset card](https://huggingface.co/datasets/google/fleurs), [direct source](https://huggingface.co/datasets/google/fleurs/resolve/70bb2e84b976b7e960aa89f1c648e09c59f894dd/parquet-data/ko_kr/test-00000-of-00001.parquet), `parquet-data/ko_kr/test-00000-of-00001.parquet` | `70bb2e84b976b7e960aa89f1c648e09c59f894dd` | Complete pinned Parquet, 382 utterances | Parquet `transcription` (normalized ground truth) and `raw_transcription` (original ground truth). `audio` is 16 kHz speech. | [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/deed.en) |
| Italian | [dataset card](https://huggingface.co/datasets/google/fleurs), [direct source](https://huggingface.co/datasets/google/fleurs/resolve/70bb2e84b976b7e960aa89f1c648e09c59f894dd/parquet-data/it_it/test-00000-of-00001.parquet), `parquet-data/it_it/test-00000-of-00001.parquet` | `70bb2e84b976b7e960aa89f1c648e09c59f894dd` | Complete pinned Parquet, 865 utterances | Same as above | [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/deed.en) |
| English | [dataset card](https://huggingface.co/datasets/google/fleurs), [direct source](https://huggingface.co/datasets/google/fleurs/resolve/70bb2e84b976b7e960aa89f1c648e09c59f894dd/parquet-data/en_us/test-00000-of-00001.parquet), `parquet-data/en_us/test-00000-of-00001.parquet` | `70bb2e84b976b7e960aa89f1c648e09c59f894dd` | Complete pinned Parquet, 647 utterances | Same as above | [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/deed.en) |

The official FLEURS dataset card states that each language configuration contains 264
test examples and the features listed above (`audio`, `transcription`,
`raw_transcription`, `id`). However, `check-public-datasets.py` reads 382/865/647 rows
from the actual pinned Parquet files at the same revision. This contradiction remains
unresolved. Consumers must record whether they use the three complete pinned files or
a separately verified official export that matches the card counts. The source file sizes
are 291,159,866 B for Korean, 806,437,035 B for Italian, and 401,722,686 B for English.
These 3 files provide per-language ASR baselines for single-speaker read speech.
Do not treat them as representative of meeting speech quality, diarization, or
code-switching quality.

## Multi-Speaker Diarization: VoxConverse

| Target | Selected source | Pinned revision | Selected scope | Ground-truth format | License |
| --- | --- | --- | --- | --- | --- |
| Multi-speaker English | [dataset card](https://huggingface.co/datasets/diarizers-community/voxconverse), [direct source](https://huggingface.co/datasets/diarizers-community/voxconverse/resolve/3acfa1b45ca4b7419aee999d67d94c617f9c9d47/data/dev-00000-of-00005.parquet), `data/dev-00000-of-00005.parquet` | `3acfa1b45ca4b7419aee999d67d94c617f9c9d47` | Complete dev shard 0/5, 485,283,393 B, 44 clips | Equal-length Parquet arrays `timestamps_start`, `timestamps_end`, and `speakers`; each index represents one speaker segment. `export-voxconverse-rttm.py` generates 44 RTTM files from these three columns without loss. | [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/deed.en) |

This distribution is the official
[VoxConverse](https://www.robots.ox.ac.uk/~vgg/data/voxconverse/index.html) dataset
preprocessed into Parquet by `diarizers`. The selected shard is not the complete dev
split. The dataset card's count of 216 clips across all 5 dev shards conflicts with
the example split counts shown on the card: `train=136`, `validation=18`, `test=16`.
Inspect the actual Parquet row count and timestamp arrays and record the scope used. Do
not use the example split counts in this README as ground truth.

## Korean-English Code-Switching: HiKE

| Target | Selected source | Pinned revision | Selected scope | Ground-truth format | License |
| --- | --- | --- | --- | --- | --- |
| Natural Korean-English code-switching ASR | [dataset card](https://huggingface.co/datasets/thetaone-ai/HiKE), [direct source](https://huggingface.co/datasets/thetaone-ai/HiKE/resolve/255609b24005e1fcce3f8b3a452260aaf2872cc9/data/test-00000-of-00001.parquet), `data/test-00000-of-00001.parquet` | `255609b24005e1fcce3f8b3a452260aaf2872cc9` | Complete test split, 1,121 utterances, 235,089,121 B | `text` (transcript), `text_normalized` (normalized transcript), `text_pier_labeled` (PIER markers), `cs_level`, `cs_levels_all`, `category`, `loanwords`, `sample_id`, `audio` | [Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0) |

The official [HiKE dataset card](https://huggingface.co/datasets/thetaone-ai/HiKE)
describes a natural Korean-English code-switching ASR benchmark and specifies the 9
features above and 1,121 test examples. Use `text_normalized` for general ASR scores and
preserve `text_pier_labeled`, `loanwords`, and `cs_level` for glossary recall and
code-switching analysis. Do not replace the normalization or labels with arbitrary values.

## Scope and Follow-Up Cautions

- Store only audio obtained from public sources under this path. When creating derived
  WAV files, do not overwrite the source Parquet. Record the separate output path and
  generation command in the run manifest.
- FLEURS and HiKE provide per-utterance audio and transcript ground truth. VoxConverse
  provides no transcript ground truth and provides only diarization ground truth. Do
  not force ASR WER and DER into the same material.
- No evidence here proves that FLEURS or HiKE was excluded from an evaluated model's
  training data. Use them for transport, scoring, and conversion-parity diagnostics,
  not product-quality promotion. The frozen overlap construction is documented in
  [`overlap-pack-v1.md`](./overlap-pack-v1.md).
- Every model runner must record the model's Hugging Face ID, revision, and quantization
  in the run manifest. Dataset acquisition does not use a model.
