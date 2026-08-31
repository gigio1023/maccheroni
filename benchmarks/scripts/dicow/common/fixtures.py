"""Pure construction rules for the DiCoW overlap fixture pack.

Audio remains signed PCM16 until it enters the canonical binary64 mixer.  All
time geometry is represented as half-open integer sample intervals so the
preparer and independent verifier can recreate the same evidence byte for byte.
"""

from __future__ import annotations

import hashlib
import math
import unicodedata
from dataclasses import dataclass
from typing import Iterable, Mapping, Sequence

import numpy as np

from benchmarks.scripts.scoring.metrics import count_term_occurrences


SAMPLE_RATE = 16_000
WINDOW_SAMPLES = 480_000
FRAME_SAMPLES = 320
FRAME_COUNT = 1_500
NORMALIZED_PEAK = 0.7079457843841379
MIX_LIMIT = 0.999
FORMULA_VERSION = "binary64-pcm16-v1"
REGION_CONTEXT_SAMPLES = 320
FLEURS_SALT = "maccheroni-overlap-pack-v1"


class FixtureError(RuntimeError):
    """A source or derived fixture violates the frozen pack contract."""


@dataclass(frozen=True)
class Interval:
    start: int
    end: int

    def __post_init__(self) -> None:
        if self.start < 0 or self.end < self.start:
            raise FixtureError("invalid half-open interval")

    @property
    def length(self) -> int:
        return self.end - self.start

    def contains(self, other: "Interval") -> bool:
        return self.start <= other.start and other.end <= self.end

    def intersects(self, other: "Interval") -> bool:
        return self.start < other.end and other.start < self.end


@dataclass(frozen=True)
class MixResult:
    source_a_samples: int
    source_b_samples: int
    overlap_samples: int
    b_start: int
    normalization_gain_a: float
    normalization_gain_b: float
    mix_gain: float
    pre_quantization_peak_a: float
    pre_quantization_peak_b: float
    pre_quantization_mix_peak: float
    post_quantization_peak_a: int
    post_quantization_peak_b: int
    post_quantization_mix_peak: int
    component_a: np.ndarray
    component_b: np.ndarray
    mixture: np.ndarray
    formula_version: str = FORMULA_VERSION

    @property
    def support_a(self) -> Interval:
        return Interval(0, self.source_a_samples)

    @property
    def support_b(self) -> Interval:
        return Interval(self.b_start, self.b_start + self.source_b_samples)

    @property
    def overlap(self) -> Interval:
        return interval_intersection(self.support_a, self.support_b)


@dataclass(frozen=True)
class StableWord:
    text: str
    start: int
    end: int
    region: str


@dataclass(frozen=True)
class CropGeometry:
    overlap: Interval
    core: Interval
    crop: Interval
    left_context: int
    right_context: int


def _pcm16_array(samples: Sequence[int] | np.ndarray, label: str) -> np.ndarray:
    value = np.asarray(samples)
    if value.ndim != 1:
        raise FixtureError(f"{label} must be mono")
    if value.dtype != np.int16:
        if not np.issubdtype(value.dtype, np.integer):
            raise FixtureError(f"{label} must contain integer PCM16 samples")
        if value.size and (int(value.min()) < -32768 or int(value.max()) > 32767):
            raise FixtureError(f"{label} contains an out-of-range PCM16 sample")
        value = value.astype(np.int16)
    if not 0 < value.size <= WINDOW_SAMPLES:
        raise FixtureError(f"{label} length must be in [1,{WINDOW_SAMPLES}]")
    return value


def quantize_pcm16(values: np.ndarray | Sequence[float]) -> np.ndarray:
    """Clamp binary64 values and use IEEE ties-to-even rounding."""

    source = np.asarray(values, dtype=np.float64)
    clipped = np.clip(source, -1.0, 32767.0 / 32768.0)
    return np.rint(clipped * 32768.0).astype("<i2")


def canonical_mix(
    source_a: Sequence[int] | np.ndarray,
    source_b: Sequence[int] | np.ndarray,
) -> MixResult:
    a_pcm = _pcm16_array(source_a, "source A")
    b_pcm = _pcm16_array(source_b, "source B")
    n_a, n_b = int(a_pcm.size), int(b_pcm.size)
    overlap_samples = (2 * min(n_a, n_b)) // 5
    b_start = n_a - overlap_samples
    if b_start + n_b > WINDOW_SAMPLES:
        raise FixtureError("constructed pair exceeds the 30-second window")

    a = a_pcm.astype(np.float64) / 32768.0
    b = b_pcm.astype(np.float64) / 32768.0
    peak_a = float(np.max(np.abs(a)))
    peak_b = float(np.max(np.abs(b)))
    if peak_a == 0.0 or peak_b == 0.0:
        raise FixtureError("zero-peak source is not valid fixture evidence")
    gain_a = NORMALIZED_PEAK / peak_a
    gain_b = NORMALIZED_PEAK / peak_b

    placed_a = np.zeros(WINDOW_SAMPLES, dtype=np.float64)
    placed_b = np.zeros(WINDOW_SAMPLES, dtype=np.float64)
    placed_a[:n_a] = a * gain_a
    placed_b[b_start : b_start + n_b] = b * gain_b
    summed = placed_a + placed_b  # The addition order is contractually A then B.
    mix_peak = float(np.max(np.abs(summed)))
    mix_gain = MIX_LIMIT / mix_peak if mix_peak > MIX_LIMIT else 1.0
    placed_a *= mix_gain
    placed_b *= mix_gain
    summed *= mix_gain

    component_a = quantize_pcm16(placed_a)
    component_b = quantize_pcm16(placed_b)
    mixture = quantize_pcm16(summed)
    return MixResult(
        source_a_samples=n_a,
        source_b_samples=n_b,
        overlap_samples=overlap_samples,
        b_start=b_start,
        normalization_gain_a=gain_a,
        normalization_gain_b=gain_b,
        mix_gain=mix_gain,
        pre_quantization_peak_a=float(np.max(np.abs(placed_a))),
        pre_quantization_peak_b=float(np.max(np.abs(placed_b))),
        pre_quantization_mix_peak=float(np.max(np.abs(summed))),
        post_quantization_peak_a=int(np.max(np.abs(component_a.astype(np.int32)))),
        post_quantization_peak_b=int(np.max(np.abs(component_b.astype(np.int32)))),
        post_quantization_mix_peak=int(np.max(np.abs(mixture.astype(np.int32)))),
        component_a=component_a,
        component_b=component_b,
        mixture=mixture,
    )


def pad_single(samples: Sequence[int] | np.ndarray) -> np.ndarray:
    source = _pcm16_array(samples, "single source")
    result = np.zeros(WINDOW_SAMPLES, dtype="<i2")
    result[: source.size] = source
    return result


def interval_intersection(left: Interval, right: Interval) -> Interval:
    start, end = max(left.start, right.start), min(left.end, right.end)
    return Interval(start, max(start, end))


def interval_subtract(source: Interval, removed: Interval) -> tuple[Interval, ...]:
    overlap = interval_intersection(source, removed)
    if overlap.length == 0:
        return (source,)
    result = []
    if source.start < overlap.start:
        result.append(Interval(source.start, overlap.start))
    if overlap.end < source.end:
        result.append(Interval(overlap.end, source.end))
    return tuple(result)


def seconds_to_source_interval(start_s: float, end_s: float, source_count: int) -> Interval:
    if not math.isfinite(start_s) or not math.isfinite(end_s) or end_s <= start_s:
        raise FixtureError("alignment word time must be finite and increasing")
    interval = Interval(math.floor(SAMPLE_RATE * start_s), math.ceil(SAMPLE_RATE * end_s))
    if interval.length == 0 or interval.end > source_count:
        raise FixtureError("alignment word lies outside its source clip")
    return interval


def _word_region(interval: Interval, overlap: Interval, non_overlap: tuple[Interval, ...]) -> str:
    expanded_start = interval.start - REGION_CONTEXT_SAMPLES
    expanded_end = interval.end + REGION_CONTEXT_SAMPLES
    if expanded_start < 0:
        return "boundary"
    expanded = Interval(expanded_start, expanded_end)
    if overlap.contains(expanded):
        return "O"
    if any(region.contains(expanded) for region in non_overlap):
        return "N"
    return "boundary"


def classify_stable_words(
    repetitions: Sequence[Sequence[Mapping[str, object]]],
    *,
    source_count: int,
    shift: int,
    source_support: Interval,
    overlap: Interval,
) -> tuple[StableWord, ...]:
    """Classify identical ordered words from two aligner repetitions."""

    if len(repetitions) != 2:
        raise FixtureError("exactly two aligner repetitions are required")
    if len(repetitions[0]) != len(repetitions[1]):
        raise FixtureError("aligner repetitions have different word counts")
    non_overlap = interval_subtract(source_support, overlap)
    result = []
    previous_ends = [-1, -1]
    for left, right in zip(repetitions[0], repetitions[1]):
        if left.get("text") != right.get("text") or not isinstance(left.get("text"), str):
            raise FixtureError("aligner normalized-unit round trip mismatch")
        intervals = []
        labels = []
        for repetition_index, record in enumerate((left, right)):
            try:
                interval = seconds_to_source_interval(
                    float(record["start_s"]), float(record["end_s"]), source_count
                )
            except (KeyError, TypeError, ValueError) as error:
                raise FixtureError("malformed alignment word") from error
            shifted = Interval(interval.start + shift, interval.end + shift)
            if shifted.start < previous_ends[repetition_index]:
                raise FixtureError("alignment words must be monotone in both repetitions")
            previous_ends[repetition_index] = shifted.end
            intervals.append(shifted)
            labels.append(_word_region(shifted, overlap, non_overlap))
        region = labels[0] if labels[0] == labels[1] else "boundary"
        result.append(
            StableWord(
                text=str(left["text"]),
                start=min(item.start for item in intervals),
                end=max(item.end for item in intervals),
                region=region,
            )
        )
    return tuple(result)


def require_target_geometry(words: Sequence[StableWord], overlap: Interval) -> CropGeometry:
    overlap_words = [word for word in words if word.region == "O"]
    if not overlap_words or not any(word.region == "N" for word in words):
        raise FixtureError("target lacks a stable O or stable N word")
    core = Interval(min(word.start for word in overlap_words), max(word.end for word in overlap_words))
    left_context = min(REGION_CONTEXT_SAMPLES, core.start - overlap.start)
    right_context = min(REGION_CONTEXT_SAMPLES, overlap.end - core.end)
    if left_context < 0 or right_context < 0 or core.length == 0:
        raise FixtureError("invalid overlap crop core")
    crop = Interval(core.start - left_context, core.end + right_context)
    return CropGeometry(overlap, core, crop, left_context, right_context)


def crop_weights(geometry: CropGeometry, window_samples: int = WINDOW_SAMPLES) -> np.ndarray:
    weights = np.zeros(window_samples, dtype=np.float64)
    core = geometry.core
    weights[core.start : core.end] = 1.0
    if geometry.left_context:
        indices = np.arange(1, geometry.left_context + 1, dtype=np.float64)
        weights[geometry.crop.start : core.start] = 0.5 - 0.5 * np.cos(
            3.141592653589793 * indices / geometry.left_context
        )
    if geometry.right_context:
        indices = np.arange(geometry.right_context, dtype=np.float64)
        weights[core.end : geometry.crop.end] = 0.5 + 0.5 * np.cos(
            3.141592653589793 * indices / geometry.right_context
        )
    return weights


def apply_crop(samples: Sequence[int] | np.ndarray, geometry: CropGeometry) -> np.ndarray:
    source = np.asarray(samples)
    if source.dtype != np.int16 or source.shape != (WINDOW_SAMPLES,):
        raise FixtureError("crop input must be a 30-second PCM16 window")
    normalized = source.astype(np.float64) / 32768.0
    return quantize_pcm16(normalized * crop_weights(geometry))


def k_frames(crop: Interval) -> np.ndarray:
    values = np.zeros(FRAME_COUNT, dtype=np.uint8)
    for frame in range(FRAME_COUNT):
        if Interval(frame * FRAME_SAMPLES, (frame + 1) * FRAME_SAMPLES).intersects(crop):
            values[frame] = 1
    return values


def oracle_activity(source_supports: Sequence[Interval]) -> np.ndarray:
    activity = np.zeros((len(source_supports), FRAME_COUNT), dtype=np.uint8)
    for row, support in enumerate(source_supports):
        for frame in range(FRAME_COUNT):
            center = frame * FRAME_SAMPLES + FRAME_SAMPLES // 2
            activity[row, frame] = int(support.start <= center < support.end)
    return activity


def canonical_text(text: str) -> str:
    return " ".join(unicodedata.normalize("NFKC", text).casefold().split())


def rank_fleurs_rows(locale: str, rows: Iterable[Mapping[str, object]]) -> list[Mapping[str, object]]:
    eligible = []
    for row in rows:
        row_id = str(row.get("row_id", ""))
        duration = row.get("duration_s")
        if not row_id or not isinstance(duration, (int, float)) or not 4.0 <= float(duration) <= 12.0:
            continue
        key = hashlib.sha256((FLEURS_SALT + locale + row_id).encode("utf-8")).hexdigest()
        eligible.append((key, row_id, row))
    eligible.sort(key=lambda item: (item[0], item[1]))
    if len(eligible) < 8:
        raise FixtureError(f"{locale} has fewer than eight duration-eligible rows")
    return [item[2] for item in eligible[:8]]


def select_fleurs_pairs(
    ordered_rows: Sequence[Mapping[str, object]],
    eligibility: Mapping[str, bool],
) -> tuple[list[tuple[str, str]], list[dict[str, object]]]:
    """Select two pairs while removing only ineligible rows from the queue."""

    if len(ordered_rows) != 8:
        raise FixtureError("FLEURS candidate pool must contain exactly eight rows")
    queue = [str(row["row_id"]) for row in ordered_rows]
    selected: list[tuple[str, str]] = []
    attempts: list[dict[str, object]] = []
    while len(selected) < 2:
        if len(queue) < 2:
            raise FixtureError("FLEURS eight-row candidate pool exhausted")
        a, b = queue[0], queue[1]
        pass_a, pass_b = bool(eligibility.get(a, False)), bool(eligibility.get(b, False))
        attempts.append({"a": a, "b": b, "eligible_a": pass_a, "eligible_b": pass_b})
        if pass_a and pass_b:
            selected.append((a, b))
            del queue[:2]
        else:
            queue = [item for item in queue if item not in ({a} if not pass_a else set())]
            queue = [item for item in queue if item not in ({b} if not pass_b else set())]
    return selected, attempts


def enforce_korean_all_or_nothing(eligibility: Mapping[str, bool], expected_ids: Sequence[str]) -> dict[str, object]:
    if len(expected_ids) != 12 or len(set(expected_ids)) != 12:
        raise FixtureError("the HiKE geometry contract requires twelve unique targets")
    rows = [{"target_id": item, "eligible": bool(eligibility.get(item, False))} for item in expected_ids]
    available = all(row["eligible"] for row in rows)
    return {
        "status": "available" if available else "korean_geometry_unavailable",
        "eligibility": rows,
        "utility_target_ids": list(expected_ids) if available else [],
        "utility_denominator": 20 if available else None,
    }


def derive_absent_terms(official_terms: Iterable[str], clean_references: Sequence[str]) -> list[str]:
    references = " ".join(clean_references)
    candidates = {canonical_text(term): term for term in official_terms if canonical_text(term)}
    absent = [
        original
        for normalized, original in candidates.items()
        if count_term_occurrences(original, references) == 0
    ]
    absent.sort(key=lambda term: hashlib.sha256((FLEURS_SALT + "-absent-ko" + canonical_text(term)).encode()).hexdigest())
    if len(absent) < 8:
        raise FixtureError("fewer than eight normalized absent terms remain")
    return absent[:8]


def sha256_pcm16(samples: np.ndarray) -> str:
    if samples.dtype != np.dtype("<i2"):
        samples = samples.astype("<i2")
    return hashlib.sha256(samples.tobytes(order="C")).hexdigest()
