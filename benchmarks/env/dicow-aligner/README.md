# DiCoW alignment environment

This lock is only for the Qwen3 ForcedAligner reference path. It deliberately does not
contain the DiCoW PyTorch source or reference runtime.

`mlx-audio==0.4.6` does not declare its Korean tokenizer dependency. The frozen
ForcedAligner path calls `ForceAlignProcessor.encode_timestamp(..., "Korean")`, which
imports `soynlp`; this project therefore pins `soynlp==0.0.493` directly. The T2 Korean
smoke reaches that exact method inside this isolated environment.

After synchronization,
`benchmarks/scripts/dicow/reference/acquire_source.py probe-aligner` creates the
source-metadata evidence. Its `verify-aligner` command reruns the Korean path with
network access disabled. The verifier binds MLX 0.32.0, mlx-audio 0.4.6,
soynlp 0.0.493, Python 3.12.13, the lock hash, and the external environment path.

Use Python 3.12 and place the environment outside the checkout. The sealed benchmark
launcher supplies `UV_PROJECT_ENVIRONMENT` under
`$DICOW_CACHE_ROOT/venvs/aligner/<uv.lock SHA-256>` and refuses a path inside the
repository.

Bootstrap that external path once with an explicit Python 3.12 interpreter before the
clean-room launcher runs. This prevents `uv` from trying to install a managed Python
under the launcher's intentionally unwritable `HOME=/private/var/empty`.

```sh
export DICOW_RUN_ENV=/absolute/path/to/sealed-run.env
python3 benchmarks/scripts/dicow/run_with_env.py \
  --env-file "$DICOW_RUN_ENV" \
  --profile aligner -- \
  uv sync --locked --project benchmarks/env/dicow-aligner --python 3.12
```

Do not run `uv sync` without the launcher and do not create `.venv` in this directory.
