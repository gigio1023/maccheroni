"""Deterministic speaker-target/non-target/overlap mask construction."""

from __future__ import annotations

import hashlib
from typing import Sequence

import numpy as np

from benchmarks.scripts.dicow.common.fixtures import FRAME_COUNT, FixtureError, Interval, k_frames


CLASS_ORDER = ("silence", "target", "non_target", "overlap")
REFERENCE_SHAPE = (4, FRAME_COUNT)
RUNTIME_SHAPE = (FRAME_COUNT, 4)


def _binary_activity(activity: np.ndarray | Sequence[Sequence[int]]) -> np.ndarray:
    value = np.asarray(activity)
    if value.ndim != 2 or value.shape[1] != FRAME_COUNT:
        raise FixtureError("speaker activity must have logical shape [S,1500]")
    if not np.all((value == 0) | (value == 1)):
        raise FixtureError("speaker activity must be binary")
    return value.astype(np.uint8, copy=False)


def target_stno(
    activity: np.ndarray | Sequence[Sequence[int]],
    target_row: int,
    frame_mask: np.ndarray | Sequence[int] | None = None,
) -> np.ndarray:
    speakers = _binary_activity(activity)
    if not 0 <= target_row < speakers.shape[0]:
        raise FixtureError("target activity row is out of range")
    if frame_mask is None:
        active_crop = np.ones(FRAME_COUNT, dtype=np.uint8)
    else:
        active_crop = np.asarray(frame_mask)
        if active_crop.shape != (FRAME_COUNT,) or not np.all((active_crop == 0) | (active_crop == 1)):
            raise FixtureError("k_frames must be binary with shape [1500]")
        active_crop = active_crop.astype(np.uint8, copy=False)
    target = speakers[target_row] & active_crop
    if speakers.shape[0] == 1:
        non_target = np.zeros(FRAME_COUNT, dtype=np.uint8)
    else:
        non_target = np.bitwise_or.reduce(np.delete(speakers, target_row, axis=0), axis=0) & active_crop
    overlap = target & non_target
    target_only = target & (1 - non_target)
    non_target_only = non_target & (1 - target)
    silence = 1 - (target_only | non_target_only | overlap)
    result = np.stack((silence, target_only, non_target_only, overlap)).astype("<f4")
    if not np.all(result.sum(axis=0) == 1.0):
        raise FixtureError("STNO classes are not one-hot")
    return result


def clean_target_stno(target_activity: Sequence[int] | np.ndarray, frame_mask: Sequence[int] | np.ndarray) -> np.ndarray:
    target = np.asarray(target_activity)
    if target.shape != (FRAME_COUNT,):
        raise FixtureError("clean target activity must have shape [1500]")
    return target_stno(target.reshape(1, FRAME_COUNT), 0, frame_mask)


def crop_k_frames(crop: Interval) -> np.ndarray:
    return k_frames(crop)


def reference_to_runtime(batch: np.ndarray) -> np.ndarray:
    value = np.asarray(batch)
    if value.ndim != 3 or value.shape[1:] != REFERENCE_SHAPE:
        raise FixtureError("reference STNO batch must have shape [B,4,1500]")
    return np.transpose(value, (0, 2, 1)).copy()


def runtime_to_reference(batch: np.ndarray) -> np.ndarray:
    value = np.asarray(batch)
    if value.ndim != 3 or value.shape[1:] != RUNTIME_SHAPE:
        raise FixtureError("runtime STNO batch must have shape [B,1500,4]")
    return np.transpose(value, (0, 2, 1)).copy()


def encode_reference(mask: np.ndarray) -> bytes:
    value = np.asarray(mask)
    if value.shape != REFERENCE_SHAPE:
        raise FixtureError("STNO mask must have shape [4,1500]")
    return value.astype("<f4", copy=False).tobytes(order="C")


def decode_reference(payload: bytes) -> np.ndarray:
    if len(payload) != 4 * FRAME_COUNT * 4:
        raise FixtureError("STNO payload has the wrong byte length")
    result = np.frombuffer(payload, dtype="<f4").reshape(REFERENCE_SHAPE).copy()
    if not np.all((result == 0.0) | (result == 1.0)) or not np.all(result.sum(axis=0) == 1.0):
        raise FixtureError("STNO payload is not one-hot")
    return result


def stno_record(mask: np.ndarray, provider: str) -> dict[str, object]:
    payload = encode_reference(mask)
    return {
        "provider": provider,
        "class_order": list(CLASS_ORDER),
        "logical_shape": [4, FRAME_COUNT],
        "reference_runtime_shape": [1, 4, FRAME_COUNT],
        "mlx_runtime_shape": [1, FRAME_COUNT, 4],
        "dtype": "little-endian-float32",
        "sha256": hashlib.sha256(payload).hexdigest(),
        "bytes": len(payload),
    }
