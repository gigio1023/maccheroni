#!/usr/bin/env python3
"""Verify the exact local CoreML payload consumed by the speech harness."""

from __future__ import annotations

import hashlib
import pathlib
import sys
from collections.abc import Mapping


MODEL_CONTRACTS: Mapping[str, Mapping[str, object]] = {
    "Pyannote-Community-1-CoreML": {
        "files": {
            "config.json": "6bf96d3f361ad1b5bcfbcf2bdf70a2072d211fefd875700231e1f3b2fb69e713",
            "embedding.mlmodelc/analytics/coremldata.bin": "f4b5ad2e2ea815e334acaf162fa42e999ecd9881ecac4166ff43d6bc1d9322d6",
            "embedding.mlmodelc/coremldata.bin": "3ad7a2f309143107fc5394f34592ce80482bf6dbe6831e0588cff44cbaa609e5",
            "embedding.mlmodelc/model.mil": "66d248aad00b3e103151097a9bbba558402933c0cf31c010f66b086ac94d7aaf",
            "embedding.mlmodelc/weights/weight.bin": "1019c1bb4472abfe705da19db3b5d0764adcb2d59dabf766fef74f0963f810f2",
            "plda.safetensors": "aff6294b68b66adcbc1c2a402b1379ecfdd98d8d759dc2cca62b5380babea359",
            "segmentation.mlmodelc/analytics/coremldata.bin": "44d83274cec5ccfe4a959eca359a89e4fd757b1872962449f2206784fb2031e5",
            "segmentation.mlmodelc/coremldata.bin": "5385e1af87712e3027ac96915d3b85de9450681e73ef355dfadd4b274cc9ba58",
            "segmentation.mlmodelc/model.mil": "8c0956cbbce7bac956cb85176fde28353a0d4a1e623f5621b6277b3d256ad0e8",
            "segmentation.mlmodelc/weights/weight.bin": "d2c1c75adec19e64ea732808839b6b8da2968a8a26b8aa3e170ef283df44a6ca",
        },
        "tree": "74247105450a08414a71ef5d512a52b706a7c23ac61efdcef051f4e44fae237a",
    },
    "Silero-VAD-v6.2.1-CoreML": {
        "files": {
            "config.json": "459e764d58cdc13f3db6878adfdf8a29b5fd467ad1f4ef2161137cc115339c81",
            "silero_vad.mlmodelc/analytics/coremldata.bin": "b777c3751d72b7430eac7f8544769a3d918faf77c15db184fec30e44c56007a3",
            "silero_vad.mlmodelc/coremldata.bin": "f6fcd92c3132c9c718e5f54e0e770a8c8075beaa50a5b212a6287273b4ddae67",
            "silero_vad.mlmodelc/metadata.json": "1b953eb3818e7092deedd96e976c05354f77beb2ddc2976fe416af17e47f62d2",
            "silero_vad.mlmodelc/model.mil": "b0a1384c4a664697989d9eb9cfb166b4b85f151206aeefd1bfa391ef9e5ad08f",
            "silero_vad.mlmodelc/weights/weight.bin": "83210545de90c65195e8d6db1b349b7e5c31f989f48d0a908a8dc0e2f586e5f9",
        },
        "tree": "edd772745342372800516b0da27556cf4aae1db386784620b2590183d94da346",
    },
}


def validate_model_closures(
    models_root: pathlib.Path,
    contracts: Mapping[str, Mapping[str, object]] = MODEL_CONTRACTS,
) -> None:
    for model_name, contract in contracts.items():
        root = models_root / model_name
        if not root.is_dir() or root.is_symlink():
            raise SystemExit(f"speech model closure is missing or unsafe: {model_name}")
        files = contract["files"]
        if not isinstance(files, Mapping):
            raise SystemExit(f"speech model closure contract is invalid: {model_name}")
        tree = hashlib.sha256()
        for relative, expected in sorted(files.items()):
            path = root / relative
            if not path.is_file() or path.is_symlink():
                raise SystemExit(
                    f"speech model closure is missing or unsafe: {model_name}/{relative}"
                )
            payload = path.read_bytes()
            actual = hashlib.sha256(payload).hexdigest()
            if actual != expected:
                raise SystemExit(
                    f"speech model file digest mismatch: {model_name}/{relative}"
                )
            name = relative.encode("utf-8")
            tree.update(len(name).to_bytes(4, "big"))
            tree.update(name)
            tree.update(payload)
        if tree.hexdigest() != contract["tree"]:
            raise SystemExit(f"speech model tree digest mismatch: {model_name}")


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: verify-speech-model-closure.py MODELS_ROOT", file=sys.stderr)
        return 64
    validate_model_closures(pathlib.Path(sys.argv[1]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
