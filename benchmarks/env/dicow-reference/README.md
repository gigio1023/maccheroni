# DiCoW PyTorch reference environment

This lock runs the pinned upstream source as a CPU-only semantic reference. It does not
contain model weights and must not be shared with the MLX aligner or shipped app
environment.

The sealed lock pins `transformers==4.42.0`. The current probe accepts only source
`config.json` files that record that version. If the nine-file source import fails, the
probe preserves the traceback and blocks the evidence lane.

A relock is a separate, explicit change. Preserve the initial failure evidence, pin the
released version named by `config.json`, regenerate `uv.lock` and the external
environment, update the probe's expected version and branch evidence, then rerun the
complete acquisition and verification. Only one such relock is allowed; a second import
failure blocks the evidence lane.

`benchmarks/scripts/dicow/reference/acquire_source.py probe-reference` imports all six
source modules as one synthetic package with Hub and Transformers offline modes enabled.
Its evidence binds all nine acquired payload records, the acquisition-manifest hash,
exact module paths and hashes, Python 3.12.13, Transformers 4.42.0, NumPy 1.26.4, and
CPU-only PyTorch 2.8.0.

The pinned `hf` 1.21.0 rejects `--cache-dir` together with `--local-dir`. The approved
acquisition therefore uses only the explicit local directory while setting the private
`HF_HUB_CACHE`. It validates the CLI's exact local-directory metadata names, commit,
ETag shape, and finite timestamp before removing that metadata and sealing a snapshot
with exactly nine regular files. It also inventories all private cache side effects and
fingerprints the wrapper's shebang interpreter, distribution RECORD, and
`huggingface_hub` package tree before and after the download.

Use Python 3.12 and place the environment outside the checkout. The sealed benchmark
launcher supplies `UV_PROJECT_ENVIRONMENT` under
`$DICOW_CACHE_ROOT/venvs/reference/<uv.lock SHA-256>` and refuses a path inside the
repository.

Bootstrap that external path once with an explicit Python 3.12 interpreter before the
clean-room launcher runs. This prevents `uv` from trying to install a managed Python
under the launcher's intentionally unwritable `HOME=/private/var/empty`.

```sh
export DICOW_RUN_ENV=/absolute/path/to/sealed-run.env
python3 benchmarks/scripts/dicow/run_with_env.py \
  --env-file "$DICOW_RUN_ENV" \
  --profile reference -- \
  uv sync --locked --project benchmarks/env/dicow-reference --python 3.12
```

Do not run `uv sync` without the launcher and do not create `.venv` in this directory.
