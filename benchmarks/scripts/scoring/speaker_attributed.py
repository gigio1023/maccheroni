"""Fail-closed speaker-attributed scoring for the DiCoW overlap experiment.

The module deliberately operates on text and sealed identifiers only.  Audio,
activity, and STNO construction belong to earlier stages; their hashes are inputs
which must be bound before any contrast is calculated.
"""

from __future__ import annotations

from collections import Counter, defaultdict
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from hashlib import sha256
import itertools
import json
import math
import random
import re
from typing import Literal

try:  # Package import used by the plan check.
    from .metrics import count_term_occurrences, normalize_text, text_error_rate
except ImportError:  # Direct script-directory import used by existing scorers.
    from metrics import count_term_occurrences, normalize_text, text_error_rate


BOOTSTRAP_SEED = 20_260_830
BOOTSTRAP_RESAMPLES = 10_000
BOOTSTRAP_CONFIDENCE = 0.95
PERCENTILE_METHOD = "nearest_rank"
REQUIRED_GATE_STRATA = ("overall", "ko", "it", "en")
REGIONS = ("O", "N", "boundary")
SUCCESS_TERMINAL_REASONS = {
    "eos",
    "eos_token",
    "scored",
    "scoring_complete",
    "completed",
    "diarizer_target_absent",
}
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
HASH_FIELDS = (
    "mapping_sha256",
    "utility_contract_sha256",
    "alignment_sha256",
    "region_labels_sha256",
    "audio_sha256",
    "activity_provider_sha256",
    "stno_sha256",
    "k_sha256",
    "k_frames_sha256",
)


class EvidenceError(ValueError):
    """Raised when incomplete or inconsistent evidence would bias a result."""


def _canonical_sha256(value: object) -> str:
    payload = json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return sha256(payload).hexdigest()


def _finite(value: object, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise EvidenceError(f"{name} must be numeric")
    result = float(value)
    if not math.isfinite(result):
        raise EvidenceError(f"{name} must be finite")
    return result


def _nonnegative(value: object, name: str) -> float:
    result = _finite(value, name)
    if result < 0:
        raise EvidenceError(f"{name} must be nonnegative")
    return result


def _require_available(value: object, name: str) -> None:
    """Accept only the exact available branch of the contract availability type."""

    if (
        not isinstance(value, Mapping)
        or set(value) != {"status", "reason"}
        or value.get("status") != "available"
        or value.get("reason") is not None
    ):
        raise EvidenceError(f"{name} is unavailable")


def derive_frozen_mapping(
    reference_ids: Sequence[str],
    activity_overlap: Mapping[str, Mapping[str, int | float]],
    *,
    window_id: str,
) -> dict[str, object]:
    """Derive the two fixed reference slots without consulting transcript text.

    ``reference_ids`` is ordered by the already frozen A/B source order.  Real labels
    are assigned injectively.  With one label, its maximum-overlap reference wins;
    with no labels, the two slots receive distinct typed ABSENT sentinels.
    """

    if (
        len(reference_ids) != 2
        or any(not isinstance(value, str) or not value for value in reference_ids)
        or len(set(reference_ids)) != 2
    ):
        raise EvidenceError("exactly two distinct ordered reference IDs are required")
    if not window_id:
        raise EvidenceError("window_id must not be empty")
    refs = tuple(reference_ids)
    if any(not isinstance(value, str) or not value for value in activity_overlap):
        raise EvidenceError("real labels must not be empty")
    supplied_labels = tuple(sorted(activity_overlap))

    matrix: dict[str, dict[str, float]] = {}
    for label in supplied_labels:
        row = activity_overlap[label]
        if not isinstance(row, Mapping):
            raise EvidenceError("activity matrix rows must be objects")
        unknown = set(row) - set(refs)
        if unknown:
            raise EvidenceError(f"activity matrix has unknown references: {sorted(unknown)!r}")
        matrix[label] = {
            ref: _nonnegative(row.get(ref, 0), f"overlap[{label!r}][{ref!r}]")
            for ref in refs
        }
    # R_w contains only labels with positive in-bounds activity.  Preserve the
    # complete supplied matrix as immutable evidence even though a zero row is not
    # a real target and cannot become surplus.
    active_matrix = {
        label: row for label, row in matrix.items() if sum(row.values()) > 0
    }
    labels = tuple(sorted(active_matrix))

    assigned: dict[str, str] = {}
    objective_values: list[float] = []
    tie_chain: list[str] = []
    if len(labels) >= 2:
        candidates: list[tuple[float, tuple[str, str]]] = []
        for pair in itertools.permutations(labels, 2):
            objective = (
                active_matrix[pair[0]][refs[0]]
                + active_matrix[pair[1]][refs[1]]
            )
            candidates.append((objective, pair))
        best_value = max(value for value, _ in candidates)
        tied = sorted(
            (pair for value, pair in candidates if value == best_value),
            key=lambda pair: tuple(sorted(zip(pair, refs, strict=True))),
        )
        chosen = tied[0]
        assigned = {refs[0]: chosen[0], refs[1]: chosen[1]}
        objective_values = sorted({value for value, _ in candidates}, reverse=True)
        tie_chain = [f"{refs[0]}={pair[0]};{refs[1]}={pair[1]}" for pair in tied]
    elif len(labels) == 1:
        label = labels[0]
        best_value = max(active_matrix[label].values())
        chosen_ref = min(
            ref for ref in refs if active_matrix[label][ref] == best_value
        )
        assigned = {chosen_ref: label}
        objective_values = sorted(active_matrix[label].values(), reverse=True)
        tie_chain = [
            ref for ref in sorted(refs) if active_matrix[label][ref] == best_value
        ]

    slots: list[dict[str, object]] = []
    used_labels: set[str] = set()
    for slot_name, ref in zip(("A", "B"), refs, strict=True):
        label = assigned.get(ref)
        if label is None:
            slots.append(
                {
                    "slot": slot_name,
                    "reference_id": ref,
                    "provider_kind": "ABSENT",
                    "provider_label": None,
                    "absent_id": f"ABSENT:{slot_name}",
                    "asr_invoked": False,
                    "terminal_reason": "diarizer_target_absent",
                }
            )
        else:
            used_labels.add(label)
            slots.append(
                {
                    "slot": slot_name,
                    "reference_id": ref,
                    "provider_kind": "real_label",
                    "provider_label": label,
                    "absent_id": None,
                    "asr_invoked": True,
                    "terminal_reason": None,
                }
            )

    mapping: dict[str, object] = {
        "window_id": window_id,
        "activity_matrix": matrix,
        "objective_values": objective_values or [0.0],
        "tie_chain": tie_chain,
        "transcript_conditioned": False,
        "real_label_count": len(labels),
        "slots": slots,
        "surplus_labels": sorted(set(labels) - used_labels),
        "spurious_target_id": f"SPURIOUS:{window_id}",
        "diarizer_undercount": len(labels) < 2,
        "diarizer_overcount": len(labels) > 2,
    }
    mapping["activity_matrix_sha256"] = _canonical_sha256(matrix)
    mapping["mapping_sha256"] = _canonical_sha256(mapping)
    return mapping


def swapped_provider_slots(mapping: Mapping[str, object]) -> list[dict[str, object]]:
    """Exchange providers while preserving frozen target references and sentinel IDs."""

    validate_frozen_mapping(mapping)
    raw_slots = mapping.get("slots")
    if not isinstance(raw_slots, Sequence) or isinstance(raw_slots, (str, bytes)) or len(raw_slots) != 2:
        raise EvidenceError("mapping must contain exactly two slots")
    slots = [dict(slot) for slot in raw_slots if isinstance(slot, Mapping)]
    if len(slots) != 2:
        raise EvidenceError("mapping slots must be objects")
    provider_fields = (
        "provider_kind",
        "provider_label",
        "absent_id",
        "asr_invoked",
        "terminal_reason",
    )
    providers = [{field: slot.get(field) for field in provider_fields} for slot in slots]
    result: list[dict[str, object]] = []
    for index, slot in enumerate(slots):
        result.append(
            {
                "slot": slot.get("slot"),
                "reference_id": slot.get("reference_id"),
                **providers[1 - index],
            }
        )
    return result


def validate_frozen_mapping(mapping: Mapping[str, object]) -> None:
    """Validate the complete typed two-slot mapping before any output is resolved."""

    if mapping.get("transcript_conditioned") is not False:
        raise EvidenceError("mapping must be explicitly transcript-independent")
    raw_activity = mapping.get("activity_matrix")
    if not isinstance(raw_activity, Mapping):
        raise EvidenceError("mapping omits immutable activity evidence")
    activity: dict[str, dict[str, int | float]] = {}
    for label, raw_row in raw_activity.items():
        if not isinstance(label, str) or not label or not isinstance(raw_row, Mapping):
            raise EvidenceError("mapping activity evidence is malformed")
        activity[label] = dict(raw_row)
    if mapping.get("activity_matrix_sha256") != _canonical_sha256(activity):
        raise EvidenceError("activity_matrix_sha256 does not match immutable activity")

    raw_slots = mapping.get("slots")
    if not isinstance(raw_slots, Sequence) or isinstance(raw_slots, (str, bytes)) or len(raw_slots) != 2:
        raise EvidenceError("mapping must contain exactly two typed slots")
    slots: list[Mapping[str, object]] = []
    for slot in raw_slots:
        if not isinstance(slot, Mapping):
            raise EvidenceError("mapping slots must be objects")
        slots.append(slot)
    if {slot.get("slot") for slot in slots} != {"A", "B"}:
        raise EvidenceError("mapping must contain unique A and B slots")
    reference_ids = [str(slot.get("reference_id", "")) for slot in slots]
    if any(not value for value in reference_ids) or len(set(reference_ids)) != 2:
        raise EvidenceError("mapping slots must contain two distinct references")
    real_labels: list[str] = []
    for slot in slots:
        kind = slot.get("provider_kind")
        if kind == "ABSENT":
            expected_id = f"ABSENT:{slot['slot']}"
            if (
                slot.get("provider_label") is not None
                or slot.get("absent_id") != expected_id
                or slot.get("asr_invoked") is not False
                or slot.get("terminal_reason") != "diarizer_target_absent"
            ):
                raise EvidenceError("ABSENT mapping slot is not typed and non-invoking")
        elif kind == "real_label":
            label = str(slot.get("provider_label", ""))
            if (
                not label
                or slot.get("absent_id") is not None
                or slot.get("asr_invoked") is not True
            ):
                raise EvidenceError("real-label mapping slot is malformed")
            real_labels.append(label)
        else:
            raise EvidenceError("mapping slot has unknown provider_kind")
    if len(real_labels) != len(set(real_labels)):
        raise EvidenceError("one real label cannot fill both target slots")
    raw_surplus = mapping.get("surplus_labels")
    if not isinstance(raw_surplus, Sequence) or isinstance(raw_surplus, (str, bytes)):
        raise EvidenceError("surplus_labels must be a sequence")
    surplus = [str(label) for label in raw_surplus]
    if any(not label for label in surplus) or len(surplus) != len(set(surplus)):
        raise EvidenceError("surplus labels must be nonempty and unique")
    if set(real_labels) & set(surplus):
        raise EvidenceError("mapped labels and surplus labels must be disjoint")
    real_count = len(real_labels) + len(surplus)
    if mapping.get("real_label_count") != real_count:
        raise EvidenceError("real_label_count does not match mapped plus surplus labels")
    if mapping.get("diarizer_undercount") is not (real_count < 2):
        raise EvidenceError("diarizer_undercount flag is inconsistent")
    if mapping.get("diarizer_overcount") is not (real_count > 2):
        raise EvidenceError("diarizer_overcount flag is inconsistent")
    spurious_target_id = str(mapping.get("spurious_target_id", ""))
    if not spurious_target_id or spurious_target_id in set(reference_ids) | set(real_labels) | set(surplus):
        raise EvidenceError("spurious_target_id is missing or collides with frozen identities")
    replayed = derive_frozen_mapping(
        reference_ids,
        activity,
        window_id=str(mapping.get("window_id", "")),
    )
    if dict(mapping) != replayed:
        raise EvidenceError("mapping differs from the activity-derived replay")


@dataclass(frozen=True)
class EditOperation:
    operation: Literal["match", "substitution", "deletion", "insertion"]
    reference_index: int | None
    hypothesis_index: int | None
    reference_unit: str | None
    hypothesis_unit: str | None
    region: Literal["O", "N", "boundary"] | None
    equal_cost_operations: tuple[str, ...]

    def as_dict(self) -> dict[str, object]:
        return {
            "operation": self.operation,
            "reference_index": self.reference_index,
            "hypothesis_index": self.hypothesis_index,
            "reference_unit": self.reference_unit,
            "hypothesis_unit": self.hypothesis_unit,
            "region": self.region,
            "equal_cost_operations": list(self.equal_cost_operations),
        }


def deterministic_edit_path(
    reference: Sequence[str],
    hypothesis: Sequence[str],
    reference_regions: Sequence[str] | None = None,
) -> list[EditOperation]:
    """Return a replayable Levenshtein path using match, S, D, I tie order."""

    if reference_regions is None:
        regions = ("boundary",) * len(reference)
    else:
        if len(reference_regions) != len(reference):
            raise EvidenceError("reference region count must equal reference unit count")
        if any(region not in REGIONS for region in reference_regions):
            raise EvidenceError("reference regions must be O, N, or boundary")
        regions = tuple(reference_regions)

    n, m = len(reference), len(hypothesis)
    costs = [[0] * (m + 1) for _ in range(n + 1)]
    parent: list[list[tuple[int, int, str, tuple[str, ...]] | None]] = [
        [None] * (m + 1) for _ in range(n + 1)
    ]
    for i in range(1, n + 1):
        costs[i][0] = i
        parent[i][0] = (i - 1, 0, "deletion", ("deletion",))
    for j in range(1, m + 1):
        costs[0][j] = j
        parent[0][j] = (0, j - 1, "insertion", ("insertion",))

    priority = {"match": 0, "substitution": 1, "deletion": 2, "insertion": 3}
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            diagonal_op = "match" if reference[i - 1] == hypothesis[j - 1] else "substitution"
            candidates = (
                (costs[i - 1][j - 1] + (diagonal_op != "match"), priority[diagonal_op], i - 1, j - 1, diagonal_op),
                (costs[i - 1][j] + 1, priority["deletion"], i - 1, j, "deletion"),
                (costs[i][j - 1] + 1, priority["insertion"], i, j - 1, "insertion"),
            )
            minimum_cost = min(candidate[0] for candidate in candidates)
            equal_operations = tuple(
                candidate[4]
                for candidate in sorted(candidates, key=lambda candidate: candidate[1])
                if candidate[0] == minimum_cost
            )
            cost, _, old_i, old_j, operation = min(candidates)
            costs[i][j] = int(cost)
            parent[i][j] = (old_i, old_j, operation, equal_operations)

    reverse_path: list[EditOperation] = []
    i, j = n, m
    while i or j:
        step = parent[i][j]
        if step is None:
            raise AssertionError("edit path is incomplete")
        old_i, old_j, operation, equal_operations = step
        if operation in {"match", "substitution"}:
            ref_index, hyp_index = i - 1, j - 1
            region = regions[ref_index]
        elif operation == "deletion":
            ref_index, hyp_index = i - 1, None
            region = regions[ref_index]
        else:
            ref_index, hyp_index = None, j - 1
            # An insertion inherits the previous reference label.  Before the first
            # reference character it inherits the next label.
            anchor = i - 1 if i > 0 else (0 if n else None)
            region = regions[anchor] if anchor is not None else None
        reverse_path.append(
            EditOperation(
                operation=operation,  # type: ignore[arg-type]
                reference_index=ref_index,
                hypothesis_index=hyp_index,
                reference_unit=reference[ref_index] if ref_index is not None else None,
                hypothesis_unit=hypothesis[hyp_index] if hyp_index is not None else None,
                region=region,  # type: ignore[arg-type]
                equal_cost_operations=equal_operations,
            )
        )
        i, j = old_i, old_j
    reverse_path.reverse()
    return reverse_path


def regional_character_score(
    reference: str,
    hypothesis: str,
    reference_regions: Sequence[str],
) -> dict[str, object]:
    """Score total and O/N character error rates with deterministic attribution."""

    ref_units = list(normalize_text(reference, remove_spaces=True))
    hyp_units = list(normalize_text(hypothesis, remove_spaces=True))
    if len(reference_regions) != len(ref_units):
        raise EvidenceError(
            "reference_regions must label normalized, space-free reference characters"
        )
    path = deterministic_edit_path(ref_units, hyp_units, reference_regions)
    denominators = Counter(reference_regions)
    errors: Counter[str] = Counter()
    counts: Counter[str] = Counter()
    regional_operations: dict[str, Counter[str]] = {
        region: Counter() for region in REGIONS
    }
    for operation in path:
        if operation.operation != "match":
            counts[operation.operation] += 1
            if operation.region is not None:
                errors[operation.region] += 1
                regional_operations[operation.region][operation.operation] += 1
    total_denominator = len(ref_units)
    total_errors = sum(counts.values())
    rates = {
        region: (
            errors[region] / denominators[region] if denominators[region] > 0 else None
        )
        for region in REGIONS
    }
    edit_path = [operation.as_dict() for operation in path]
    result: dict[str, object] = {
        "reference": "".join(ref_units),
        "hypothesis": "".join(hyp_units),
        "reference_regions": list(reference_regions),
        "cer": total_errors / total_denominator if total_denominator else None,
        "errors": total_errors,
        "reference_characters": total_denominator,
        "substitutions": counts["substitution"],
        "deletions": counts["deletion"],
        "insertions": counts["insertion"],
        "regional_errors": {region: errors[region] for region in REGIONS},
        "regional_operation_counts": {
            region: {
                operation: regional_operations[region][operation]
                for operation in ("substitution", "deletion", "insertion")
            }
            for region in REGIONS
        },
        "regional_denominators": {region: denominators[region] for region in REGIONS},
        "regional_cer": rates,
        "edit_path": edit_path,
        "ambiguous": any(len(operation.equal_cost_operations) > 1 for operation in path),
        "ambiguity_reason": (
            "equal_cost_edit_paths"
            if any(len(operation.equal_cost_operations) > 1 for operation in path)
            else None
        ),
    }
    result["regional_edit_path_sha256"] = _canonical_sha256(edit_path)
    return result


def stable_overlap_target_counts(
    regional_score: Mapping[str, object],
) -> dict[str, int]:
    """Return replay-checked stable-O reference, missed, and hit counts."""

    replay_reference = regional_score.get("reference")
    replay_hypothesis = regional_score.get("hypothesis")
    replay_regions = regional_score.get("reference_regions")
    if (
        not isinstance(replay_reference, str)
        or not isinstance(replay_hypothesis, str)
        or not isinstance(replay_regions, Sequence)
        or isinstance(replay_regions, (str, bytes))
    ):
        raise EvidenceError("regional score omits normalized replay inputs")
    recomputed = regional_character_score(
        replay_reference, replay_hypothesis, list(replay_regions)
    )
    if dict(regional_score) != recomputed:
        raise EvidenceError("regional score differs from deterministic minimal-path replay")

    raw_denominators = regional_score.get("regional_denominators")
    raw_operations = regional_score.get("regional_operation_counts")
    if not isinstance(raw_denominators, Mapping) or not isinstance(raw_operations, Mapping):
        raise EvidenceError("regional score omits replayable operation counts")
    denominator = raw_denominators.get("O")
    if isinstance(denominator, bool) or not isinstance(denominator, int) or denominator <= 0:
        raise EvidenceError("stable-O recall denominator must be a positive integer")
    overlap_operations = raw_operations.get("O")
    if not isinstance(overlap_operations, Mapping):
        raise EvidenceError("regional score omits stable-O operation counts")
    if set(overlap_operations) != {"substitution", "deletion", "insertion"}:
        raise EvidenceError("stable-O operation counts have the wrong shape")
    substitutions = overlap_operations["substitution"]
    deletions = overlap_operations["deletion"]
    for name, value in overlap_operations.items():
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise EvidenceError(f"stable-O {name} count must be a nonnegative integer")
    missed = substitutions + deletions
    if missed > denominator:
        raise EvidenceError("stable-O substitutions plus deletions exceed the denominator")
    raw_path = regional_score.get("edit_path")
    if not isinstance(raw_path, Sequence) or isinstance(raw_path, (str, bytes)):
        raise EvidenceError("regional score omits its replayable edit path")
    sealed_path_hash = regional_score.get("regional_edit_path_sha256")
    if (
        not isinstance(sealed_path_hash, str)
        or SHA256_PATTERN.fullmatch(sealed_path_hash) is None
        or _canonical_sha256(raw_path) != sealed_path_hash
    ):
        raise EvidenceError("regional edit path hash does not match its path")
    replay_denominators: Counter[str] = Counter()
    replay_operations: dict[str, Counter[str]] = {
        region: Counter() for region in REGIONS
    }
    reference_indices: list[int] = []
    hypothesis_indices: list[int] = []
    operation_fields = {
        "operation",
        "reference_index",
        "hypothesis_index",
        "reference_unit",
        "hypothesis_unit",
        "region",
        "equal_cost_operations",
    }
    for raw_operation in raw_path:
        if not isinstance(raw_operation, Mapping) or set(raw_operation) != operation_fields:
            raise EvidenceError("regional edit path operation has the wrong shape")
        operation = raw_operation.get("operation")
        region = raw_operation.get("region")
        if operation not in {"match", "substitution", "deletion", "insertion"}:
            raise EvidenceError("regional edit path has an unknown operation")
        if region not in REGIONS:
            raise EvidenceError("regional edit path has an invalid region")
        reference_index = raw_operation.get("reference_index")
        hypothesis_index = raw_operation.get("hypothesis_index")
        if operation == "insertion":
            if reference_index is not None or raw_operation.get("reference_unit") is not None:
                raise EvidenceError("insertion carries a reference unit")
        else:
            if isinstance(reference_index, bool) or not isinstance(reference_index, int):
                raise EvidenceError("reference-consuming edit lacks an integer index")
            if (
                not isinstance(raw_operation.get("reference_unit"), str)
                or len(str(raw_operation.get("reference_unit"))) != 1
            ):
                raise EvidenceError("reference-consuming edit lacks its unit")
            reference_indices.append(reference_index)
            replay_denominators[str(region)] += 1
        if operation == "deletion":
            if hypothesis_index is not None or raw_operation.get("hypothesis_unit") is not None:
                raise EvidenceError("deletion carries a hypothesis unit")
        else:
            if isinstance(hypothesis_index, bool) or not isinstance(hypothesis_index, int):
                raise EvidenceError("hypothesis-consuming edit lacks an integer index")
            if (
                not isinstance(raw_operation.get("hypothesis_unit"), str)
                or len(str(raw_operation.get("hypothesis_unit"))) != 1
            ):
                raise EvidenceError("hypothesis-consuming edit lacks its unit")
            hypothesis_indices.append(hypothesis_index)
        if operation == "match" and raw_operation.get("reference_unit") != raw_operation.get(
            "hypothesis_unit"
        ):
            raise EvidenceError("match edit contains unequal units")
        if operation == "substitution" and raw_operation.get(
            "reference_unit"
        ) == raw_operation.get("hypothesis_unit"):
            raise EvidenceError("substitution edit contains equal units")
        ties = raw_operation.get("equal_cost_operations")
        if (
            not isinstance(ties, Sequence)
            or isinstance(ties, (str, bytes))
            or operation not in ties
            or any(
                item not in {"match", "substitution", "deletion", "insertion"}
                for item in ties
            )
        ):
            raise EvidenceError("regional edit path tie evidence is invalid")
        if operation != "match":
            replay_operations[str(region)][str(operation)] += 1
    if reference_indices != list(range(len(reference_indices))):
        raise EvidenceError("regional edit path reference indices are not contiguous")
    if hypothesis_indices != list(range(len(hypothesis_indices))):
        raise EvidenceError("regional edit path hypothesis indices are not contiguous")
    reference_characters = regional_score.get("reference_characters")
    if (
        isinstance(reference_characters, bool)
        or not isinstance(reference_characters, int)
        or reference_characters != len(reference_indices)
    ):
        raise EvidenceError("regional reference length does not match the edit path")
    for region in REGIONS:
        raw_denominator = raw_denominators.get(region)
        if (
            isinstance(raw_denominator, bool)
            or not isinstance(raw_denominator, int)
            or raw_denominator < 0
            or raw_denominator != replay_denominators[region]
        ):
            raise EvidenceError("regional denominators do not match the edit path")
        region_operations = raw_operations.get(region)
        if not isinstance(region_operations, Mapping) or set(region_operations) != {
            "substitution",
            "deletion",
            "insertion",
        }:
            raise EvidenceError("regional operation counts have the wrong shape")
        for operation in ("substitution", "deletion", "insertion"):
            observed_count = region_operations.get(operation)
            if (
                isinstance(observed_count, bool)
                or not isinstance(observed_count, int)
                or observed_count < 0
                or observed_count != replay_operations[region][operation]
            ):
                raise EvidenceError("regional operation counts do not match the edit path")
    replay_totals = {
        operation: sum(replay_operations[region][operation] for region in REGIONS)
        for operation in ("substitution", "deletion", "insertion")
    }
    for operation, total in replay_totals.items():
        observed_total = regional_score.get(f"{operation}s")
        if (
            isinstance(observed_total, bool)
            or not isinstance(observed_total, int)
            or observed_total != total
        ):
            raise EvidenceError("regional total operation counts do not match the edit path")
    observed_errors = regional_score.get("errors")
    if (
        isinstance(observed_errors, bool)
        or not isinstance(observed_errors, int)
        or observed_errors != sum(replay_totals.values())
    ):
        raise EvidenceError("regional total errors do not match the edit path")
    raw_regional_errors = regional_score.get("regional_errors")
    if not isinstance(raw_regional_errors, Mapping):
        raise EvidenceError("regional score omits regional error totals")
    for region in REGIONS:
        observed_region_errors = raw_regional_errors.get(region)
        if (
            isinstance(observed_region_errors, bool)
            or not isinstance(observed_region_errors, int)
            or observed_region_errors != sum(replay_operations[region].values())
        ):
            raise EvidenceError("regional errors do not match the edit path")
    result: dict[str, object] = {
        "reference_characters": denominator,
        "missed_characters": missed,
        "hit_characters": denominator - missed,
    }
    return result  # type: ignore[return-value]


def stable_overlap_target_recall(regional_score: Mapping[str, object]) -> float:
    """Return stable-O character recall, excluding interference insertions.

    R = 1 - (stable-O substitutions + deletions) / stable-O reference chars.
    Insertions remain visible in CER but cannot make suppression look like recovery.
    """

    counts = stable_overlap_target_counts(regional_score)
    return counts["hit_characters"] / counts["reference_characters"]


def regional_reference_from_words(
    words: Sequence[Mapping[str, object]],
) -> tuple[str, list[str]]:
    """Normalize words independently so every expanded character inherits its region."""

    normalized_words: list[str] = []
    regions: list[str] = []
    for word in words:
        text = str(word.get("text", ""))
        region = str(word.get("region", ""))
        if region not in REGIONS:
            raise EvidenceError("word region must be O, N, or boundary")
        normalized = normalize_text(text, remove_spaces=True)
        if not normalized:
            raise EvidenceError("regional word must retain characters after normalization")
        normalized_words.append(normalized)
        regions.extend([region] * len(normalized))
    if not normalized_words:
        raise EvidenceError("regional reference must contain words")
    return " ".join(normalized_words), regions


def _normalized_term_key(term: str) -> str:
    return normalize_text(term, remove_spaces=True)


def _unique_term_annotations(
    terms: Sequence[Mapping[str, object]],
) -> list[Mapping[str, object]]:
    unique: list[Mapping[str, object]] = []
    seen: set[str] = set()
    for annotation in terms:
        if not isinstance(annotation, Mapping):
            raise EvidenceError("term annotations must be objects")
        term = str(annotation.get("term", ""))
        if not term.strip():
            raise EvidenceError("term annotations must contain a nonempty term")
        key = _normalized_term_key(term)
        if key in seen:
            continue
        seen.add(key)
        unique.append(annotation)
    return unique


def _term_count(terms: Sequence[Mapping[str, object]], hypothesis: str) -> int:
    total = 0
    for annotation in _unique_term_annotations(terms):
        term = str(annotation.get("term", ""))
        if not term.strip():
            raise EvidenceError("term annotations must contain a nonempty term")
        total += count_term_occurrences(term, hypothesis)
    return total


def score_target(
    reference: str,
    hypothesis: str,
    *,
    expected_terms: Sequence[Mapping[str, object]] = (),
    absent_terms: Sequence[Mapping[str, object]] = (),
    other_target_terms: Sequence[Mapping[str, object]] = (),
    reference_regions: Sequence[str] | None = None,
) -> dict[str, object]:
    """Compute complete per-target text metrics without changing speaker mapping."""

    cer = text_error_rate(reference, hypothesis, unit="character")
    wer = text_error_rate(reference, hypothesis, unit="word")
    expected_total = 0
    matched_total = 0
    details: list[dict[str, object]] = []
    unique_expected_terms = _unique_term_annotations(expected_terms)
    unique_absent_terms = _unique_term_annotations(absent_terms)
    unique_other_target_terms = _unique_term_annotations(other_target_terms)
    for annotations, default in (
        (unique_expected_terms, 0),
        (unique_other_target_terms, 1),
    ):
        for annotation in annotations:
            count = annotation.get("reference_count", default)
            if isinstance(count, bool) or not isinstance(count, int) or count < 0:
                raise EvidenceError("term reference_count must be a nonnegative integer")
    current_term_keys = {
        _normalized_term_key(str(annotation.get("term", "")))
        for annotation in unique_expected_terms
        if int(annotation.get("reference_count", 0)) > 0
    }
    for annotation in unique_expected_terms:
        term = str(annotation.get("term", ""))
        if not term.strip():
            raise EvidenceError("term annotations must contain a nonempty term")
        raw_reference_count = annotation.get("reference_count", 0)
        if isinstance(raw_reference_count, bool) or not isinstance(
            raw_reference_count, int
        ):
            raise EvidenceError("term reference_count must be an integer")
        reference_count = raw_reference_count
        if reference_count < 0:
            raise EvidenceError("term reference_count must be nonnegative")
        predicted = count_term_occurrences(term, hypothesis)
        matched = min(reference_count, predicted)
        expected_total += reference_count
        matched_total += matched
        details.append(
            {
                "term": normalize_text(term),
                "reference_count": reference_count,
                "predicted_count": predicted,
                "matched_count": matched,
            }
        )
    cross_terms = [
        annotation
        for annotation in unique_other_target_terms
        if int(annotation.get("reference_count", 1)) > 0
        and _normalized_term_key(str(annotation.get("term", ""))) not in current_term_keys
    ]
    score: dict[str, object] = {
        "cer": cer.error_rate,
        "wer": wer.error_rate,
        "cer_counts": cer.as_dict(),
        "wer_counts": wer.as_dict(),
        "term_recall": matched_total / expected_total if expected_total else None,
        "term_details": details,
        "absent_term_insertions": _term_count(unique_absent_terms, hypothesis),
        "cross_speaker_insertions": _term_count(cross_terms, hypothesis),
        "normalized_text": normalize_text(hypothesis),
        "normalized_text_empty": not bool(normalize_text(hypothesis, remove_spaces=True)),
        "ambiguous": False,
        "ambiguity_reason": None,
        "termination": {
            "typed": True,
            "complete": True,
            "terminal_reason": "scoring_complete",
        },
        "score_replay": {
            "reference": reference,
            "hypothesis": hypothesis,
            "expected_terms": [
                {
                    "term": normalize_text(str(annotation["term"])),
                    "reference_count": int(annotation.get("reference_count", 0)),
                }
                for annotation in unique_expected_terms
            ],
            "absent_terms": [
                {"term": normalize_text(str(annotation["term"]))}
                for annotation in unique_absent_terms
            ],
            "other_target_terms": [
                {
                    "term": normalize_text(str(annotation["term"])),
                    "reference_count": int(annotation.get("reference_count", 1)),
                }
                for annotation in unique_other_target_terms
            ],
            "reference_regions": (
                list(reference_regions) if reference_regions is not None else None
            ),
        },
    }
    if reference_regions is not None:
        score["regional"] = regional_character_score(
            reference, hypothesis, reference_regions
        )
        stable_counts = stable_overlap_target_counts(score["regional"])
        overlap_operations = score["regional"]["regional_operation_counts"]["O"]
        score["stable_o_counts"] = {
            "reference_chars": stable_counts["reference_characters"],
            "substitutions": overlap_operations["substitution"],
            "deletions": overlap_operations["deletion"],
            "insertions": overlap_operations["insertion"],
            "hits": stable_counts["hit_characters"],
            "regional_edit_path_sha256": score["regional"][
                "regional_edit_path_sha256"
            ],
        }
        score["stable_overlap_target_recall"] = (
            stable_counts["hit_characters"] / stable_counts["reference_characters"]
        )
        score["ambiguous"] = score["regional"]["ambiguous"]
        score["ambiguity_reason"] = score["regional"]["ambiguity_reason"]
    score["score_replay_sha256"] = _canonical_sha256(score["score_replay"])
    return score


def typed_absent_score(
    reference: str,
    *,
    expected_terms: Sequence[Mapping[str, object]] = (),
    reference_regions: Sequence[str] | None = None,
) -> dict[str, object]:
    """Create the sole valid no-inference target result."""

    if not normalize_text(reference, remove_spaces=True):
        raise EvidenceError("ABSENT requires a nonempty stable reference")
    score = score_target(
        reference,
        "",
        expected_terms=expected_terms,
        reference_regions=reference_regions,
    )
    score.update(
        {
            "provider_kind": "ABSENT",
            "asr_invoked": False,
            "terminal_reason": "diarizer_target_absent",
            "token_ids": [],
            "term_recall": 0.0,
            "termination": {
                "typed": True,
                "complete": True,
                "terminal_reason": "diarizer_target_absent",
            },
        }
    )
    # The contract fixes these values explicitly, even for word/token corner cases.
    score["cer"] = 1.0
    score["wer"] = 1.0
    return score


def resolve_mapped_outputs(
    mapping: Mapping[str, object],
    references: Mapping[str, Mapping[str, object]],
    real_outputs: Mapping[str, object],
    *,
    repetition: int,
    mapped_condition: str = "dicow-full-mix-community1",
    mapped_arm_kind: str = "full_window",
) -> dict[str, object]:
    """Score every frozen reference and every surplus label, or fail closed."""

    validate_frozen_mapping(mapping)
    slots = mapping.get("slots")
    if not isinstance(slots, Sequence) or isinstance(slots, (str, bytes)) or len(slots) != 2:
        raise EvidenceError("mapping must contain two slots")
    mapped_real_labels = {
        str(slot.get("provider_label"))
        for slot in slots
        if isinstance(slot, Mapping) and slot.get("provider_kind") == "real_label"
    }
    surplus_labels = {str(label) for label in mapping.get("surplus_labels", ())}
    if set(real_outputs) != mapped_real_labels | surplus_labels:
        missing = sorted((mapped_real_labels | surplus_labels) - set(real_outputs))
        extra = sorted(set(real_outputs) - (mapped_real_labels | surplus_labels))
        raise EvidenceError(f"output labels differ from frozen mapping: missing={missing!r}, extra={extra!r}")

    reference_ids = [str(slot["reference_id"]) for slot in slots if isinstance(slot, Mapping)]
    mapped: dict[str, object] = {}
    for raw_slot in slots:
        if not isinstance(raw_slot, Mapping):
            raise EvidenceError("mapping slot must be an object")
        reference_id = str(raw_slot.get("reference_id", ""))
        if reference_id not in references:
            raise EvidenceError(f"missing frozen reference {reference_id!r}")
        reference = references[reference_id]
        text = str(reference.get("text", ""))
        terms = reference.get("expected_terms", ())
        regions = reference.get("reference_regions")
        region_sequence = (
            regions
            if isinstance(regions, Sequence) and not isinstance(regions, (str, bytes))
            else None
        )
        if raw_slot.get("provider_kind") == "ABSENT":
            result = typed_absent_score(
                text,
                expected_terms=terms if isinstance(terms, Sequence) else (),
                reference_regions=region_sequence,
            )
            result["absent_id"] = raw_slot.get("absent_id")
        elif raw_slot.get("provider_kind") == "real_label":
            label = str(raw_slot.get("provider_label", ""))
            if not label or label not in real_outputs:
                raise EvidenceError(f"missing mapped-real output for {label!r}")
            output_text = _validated_output_text(
                real_outputs[label],
                expected_condition=mapped_condition,
                expected_arm_kind=mapped_arm_kind,
                expected_window_id=str(mapping.get("window_id", "")),
                expected_target_id=reference_id,
                expected_mapping_sha256=str(mapping.get("mapping_sha256", "")),
                expected_repetition=repetition,
            )
            other_reference_id = next(value for value in reference_ids if value != reference_id)
            other_reference = references.get(other_reference_id)
            if not isinstance(other_reference, Mapping):
                raise EvidenceError(f"missing other frozen reference {other_reference_id!r}")
            absent_terms = reference.get("absent_terms", ())
            other_terms = other_reference.get("expected_terms", ())
            result = score_target(
                text,
                output_text,
                expected_terms=terms if isinstance(terms, Sequence) else (),
                absent_terms=(
                    absent_terms
                    if isinstance(absent_terms, Sequence) and not isinstance(absent_terms, (str, bytes))
                    else ()
                ),
                other_target_terms=(
                    other_terms
                    if isinstance(other_terms, Sequence) and not isinstance(other_terms, (str, bytes))
                    else ()
                ),
                reference_regions=region_sequence,
            )
            result["provider_kind"] = "real_label"
            result["provider_label"] = label
        else:
            raise EvidenceError("mapping slot has unknown provider_kind")
        mapped[reference_id] = result

    surplus: dict[str, object] = {}
    raw_surplus = mapping.get("surplus_labels", ())
    if not isinstance(raw_surplus, Sequence) or isinstance(raw_surplus, (str, bytes)):
        raise EvidenceError("surplus_labels must be a sequence")
    for raw_label in raw_surplus:
        label = str(raw_label)
        hypothesis = _validated_output_text(
            real_outputs[label],
            expected_condition="surplus-diagnostic",
            expected_arm_kind="full_window",
            expected_window_id=str(mapping.get("window_id", "")),
            expected_target_id=label,
            expected_mapping_sha256=str(mapping.get("mapping_sha256", "")),
            expected_repetition=repetition,
        )
        surplus[label] = score_empty_reference_diagnostic(hypothesis, kind="surplus")
    result: dict[str, object] = {
        "mapped_targets": mapped,
        "surplus_diagnostics": surplus,
        "target_count": 2,
        "dropped_targets": 0,
        "ambiguous": len(mapping.get("tie_chain", ())) > 1,
        "ambiguity_reason": (
            "equal_activity_objective"
            if len(mapping.get("tie_chain", ())) > 1
            else None
        ),
    }
    return result


def _validated_output_text(
    raw_output: object,
    *,
    expected_condition: str,
    expected_arm_kind: str,
    expected_window_id: str,
    expected_target_id: str,
    expected_mapping_sha256: str,
    expected_repetition: int,
) -> str:
    if not isinstance(raw_output, Mapping):
        raise EvidenceError("model output must be a structured arm record")
    if raw_output.get("model") != "dicow":
        raise EvidenceError("speaker-attributed output must come from DiCoW")
    if raw_output.get("condition") != expected_condition:
        raise EvidenceError("model output condition differs from the required arm")
    if raw_output.get("arm_kind") != expected_arm_kind:
        raise EvidenceError("model output uses the wrong arm kind")
    _require_available(raw_output.get("availability"), "model output")
    if raw_output.get("window_id") != expected_window_id:
        raise EvidenceError("model output is bound to the wrong window")
    if raw_output.get("target_id") != expected_target_id:
        raise EvidenceError("model output is bound to the wrong target")
    if raw_output.get("mapping_sha256") != expected_mapping_sha256:
        raise EvidenceError("model output is bound to the wrong mapping")
    if raw_output.get("repetition") != expected_repetition or expected_repetition not in {1, 2}:
        raise EvidenceError("model output is bound to the wrong repetition")
    termination = raw_output.get("termination")
    if (
        not isinstance(termination, Mapping)
        or set(termination) != {"typed", "complete", "terminal_reason"}
        or termination.get("typed") is not True
        or termination.get("complete") is not True
        or termination.get("terminal_reason") not in SUCCESS_TERMINAL_REASONS
    ):
        raise EvidenceError("model output lacks typed successful termination")
    text = raw_output.get("text")
    if not isinstance(text, str):
        raise EvidenceError("model output text must be a string")
    return text


def resolve_spurious_outputs(
    mappings: Sequence[Mapping[str, object]],
    raw_outputs: Mapping[str, object],
    *,
    repetition: int,
) -> dict[str, dict[str, object]]:
    """Resolve exactly one sealed full-window spurious arm per frozen window."""

    by_target: dict[str, Mapping[str, object]] = {}
    for mapping in mappings:
        validate_frozen_mapping(mapping)
        target_id = str(mapping["spurious_target_id"])
        if target_id in by_target:
            raise EvidenceError("duplicate spurious target ID across mappings")
        by_target[target_id] = mapping
    if not by_target:
        raise EvidenceError("spurious coverage requires frozen mappings")
    if set(raw_outputs) != set(by_target):
        missing = sorted(set(by_target) - set(raw_outputs))
        extra = sorted(set(raw_outputs) - set(by_target))
        raise EvidenceError(f"spurious output coverage differs from mappings: missing={missing!r}, extra={extra!r}")
    resolved: dict[str, dict[str, object]] = {}
    for target_id, mapping in sorted(by_target.items()):
        text = _validated_output_text(
            raw_outputs[target_id],
            expected_condition="dicow-full-spurious",
            expected_arm_kind="full_window",
            expected_window_id=str(mapping["window_id"]),
            expected_target_id=target_id,
            expected_mapping_sha256=str(mapping["mapping_sha256"]),
            expected_repetition=repetition,
        )
        resolved[target_id] = score_empty_reference_diagnostic(text, kind="spurious")
    return resolved


def score_empty_reference_diagnostic(
    hypothesis: str, *, kind: Literal["surplus", "spurious"]
) -> dict[str, object]:
    """Score an output whose reference is intentionally empty and gate-ineligible."""

    normalized = normalize_text(hypothesis)
    result: dict[str, object] = {
        "kind": kind,
        "reference": "",
        "hypothesis": hypothesis,
        "normalized_text": normalized,
        "cer": None,
        "wer": None,
        "cer_counts": None,
        "wer_counts": None,
        "term_recall": None,
        "term_details": [],
        "absent_term_insertions": 0,
        "cross_speaker_insertions": 0,
        "regional": None,
        "stable_o_counts": None,
        "character_insertions": len(normalize_text(hypothesis, remove_spaces=True)),
        "word_insertions": len(normalized.split()),
        "normalized_text_empty": not bool(normalize_text(hypothesis, remove_spaces=True)),
        "gate_eligible": False,
        "ambiguous": False,
        "ambiguity_reason": "empty_reference_diagnostic",
        "termination": {
            "typed": True,
            "complete": True,
            "terminal_reason": "scoring_complete",
        },
        "score_replay": {
            "reference": "",
            "hypothesis": hypothesis,
            "expected_terms": [],
            "absent_terms": [],
            "other_target_terms": [],
            "reference_regions": None,
        },
    }
    result["score_replay_sha256"] = _canonical_sha256(result["score_replay"])
    return result


def diagnostic_best_permutation(
    reference_texts: Mapping[str, str],
    hypotheses: Mapping[str, str],
    *,
    mapping: Mapping[str, object],
) -> dict[str, object]:
    """Return the transcript-conditioned best assignment as a diagnostic only."""

    validate_frozen_mapping(mapping)
    if len(reference_texts) != 2:
        raise EvidenceError("diagnostic permutation requires two references")
    mapping_refs = {
        str(slot["reference_id"])
        for slot in mapping["slots"]
        if isinstance(slot, Mapping)
    }
    if set(reference_texts) != mapping_refs:
        raise EvidenceError("diagnostic references differ from the frozen mapping")
    expected_labels = {
        str(slot["provider_label"])
        for slot in mapping["slots"]
        if isinstance(slot, Mapping) and slot.get("provider_kind") == "real_label"
    } | {str(label) for label in mapping["surplus_labels"]}
    if set(hypotheses) != expected_labels:
        raise EvidenceError("diagnostic hypotheses differ from frozen real labels")
    refs = tuple(sorted(reference_texts))
    labels = tuple(sorted(hypotheses))
    providers = labels + ("ABSENT:A", "ABSENT:B")
    candidates: list[tuple[float, tuple[str, str]]] = []
    for pair in itertools.permutations(providers, 2):
        if pair[0].startswith("ABSENT") and pair[1].startswith("ABSENT") and pair[0] == pair[1]:
            continue
        total = 0.0
        for ref, provider in zip(refs, pair, strict=True):
            hypothesis = "" if provider.startswith("ABSENT") else hypotheses[provider]
            rate = text_error_rate(reference_texts[ref], hypothesis, unit="character").error_rate
            if rate is None:
                raise EvidenceError("diagnostic reference must be nonempty")
            total += rate
        candidates.append((total, pair))
    if not candidates:
        raise EvidenceError("diagnostic assignment has no candidates")
    value, pair = min(candidates, key=lambda item: (item[0], item[1]))
    return {
        "assignment": dict(zip(refs, pair, strict=True)),
        "mean_cer": value / 2,
        "gate_eligible": False,
        "transcript_conditioned": True,
    }


def validate_arm_bindings(
    arm: Mapping[str, object], expected: Mapping[str, object]
) -> None:
    """Bind every sealed hash before allowing the arm into a contrast."""

    arm_id = str(arm.get("arm_id", "<unknown>"))
    always_required = {
        "mapping_sha256",
        "utility_contract_sha256",
        "alignment_sha256",
        "region_labels_sha256",
        "audio_sha256",
    }
    for field in HASH_FIELDS:
        if field not in expected:
            raise EvidenceError(f"{arm_id}: expected binding omits {field}")
        observed = arm.get(field)
        sealed = expected[field]
        if field in always_required and (observed is None or sealed is None):
            raise EvidenceError(f"{arm_id}: {field} must be bound")
        if observed is not None and (
            not isinstance(observed, str) or SHA256_PATTERN.fullmatch(observed) is None
        ):
            raise EvidenceError(f"{arm_id}: {field} is not a lowercase SHA-256")
        if sealed is not None and (
            not isinstance(sealed, str) or SHA256_PATTERN.fullmatch(sealed) is None
        ):
            raise EvidenceError(f"{arm_id}: sealed {field} is not a lowercase SHA-256")
        if observed != sealed:
            raise EvidenceError(f"{arm_id}: {field} does not match sealed evidence")
    if arm.get("stno_sha256") is not None and arm.get("activity_provider_sha256") is None:
        raise EvidenceError(f"{arm_id}: STNO requires an activity-provider hash")


def _validate_arm_score_record(
    arm: Mapping[str, object], expected: Mapping[str, object]
) -> None:
    """Recompute every scorer-owned field from the arm's self-contained replay input."""

    termination = arm.get("termination")
    if (
        not isinstance(termination, Mapping)
        or set(termination) != {"typed", "complete", "terminal_reason"}
        or termination.get("typed") is not True
        or termination.get("complete") is not True
        or termination.get("terminal_reason") not in SUCCESS_TERMINAL_REASONS
    ):
        raise EvidenceError("available arm lacks typed successful termination")
    if termination.get("terminal_reason") == "diarizer_target_absent" and (
        arm.get("provider_kind") != "ABSENT" or arm.get("asr_invoked") is not False
    ):
        raise EvidenceError("ABSENT termination is not bound to a non-invoked sentinel")
    replay = arm.get("score_replay")
    replay_fields = {
        "reference",
        "hypothesis",
        "expected_terms",
        "absent_terms",
        "other_target_terms",
        "reference_regions",
    }
    if not isinstance(replay, Mapping) or set(replay) != replay_fields:
        raise EvidenceError("arm omits exact score replay evidence")
    observed_replay_hash = arm.get("score_replay_sha256")
    sealed_replay_hash = expected.get("score_replay_sha256")
    if (
        not isinstance(observed_replay_hash, str)
        or SHA256_PATTERN.fullmatch(observed_replay_hash) is None
        or not isinstance(sealed_replay_hash, str)
        or SHA256_PATTERN.fullmatch(sealed_replay_hash) is None
        or observed_replay_hash != sealed_replay_hash
        or observed_replay_hash != _canonical_sha256(replay)
    ):
        raise EvidenceError("score_replay_sha256 differs from sealed replay evidence")
    reference = replay.get("reference")
    hypothesis = replay.get("hypothesis")
    if not isinstance(reference, str) or not isinstance(hypothesis, str):
        raise EvidenceError("score replay reference and hypothesis must be strings")
    term_inputs: dict[str, Sequence[Mapping[str, object]]] = {}
    for field in ("expected_terms", "absent_terms", "other_target_terms"):
        raw_terms = replay.get(field)
        if not isinstance(raw_terms, Sequence) or isinstance(raw_terms, (str, bytes)):
            raise EvidenceError(f"score replay {field} must be an annotation list")
        if any(not isinstance(annotation, Mapping) for annotation in raw_terms):
            raise EvidenceError(f"score replay {field} contains a malformed annotation")
        expected_fields = {"term"} if field == "absent_terms" else {
            "term",
            "reference_count",
        }
        for annotation in raw_terms:
            if set(annotation) != expected_fields:
                raise EvidenceError(f"score replay {field} annotation has the wrong shape")
            term = annotation.get("term")
            if (
                not isinstance(term, str)
                or not term
                or term != normalize_text(term)
            ):
                raise EvidenceError(f"score replay {field} term is not normalized")
        term_inputs[field] = list(raw_terms)  # type: ignore[list-item]
    raw_regions = replay.get("reference_regions")
    if raw_regions is not None and (
        not isinstance(raw_regions, Sequence) or isinstance(raw_regions, (str, bytes))
    ):
        raise EvidenceError("score replay reference_regions must be a list or null")
    if termination.get("terminal_reason") == "diarizer_target_absent":
        if hypothesis or term_inputs["absent_terms"] or term_inputs["other_target_terms"]:
            raise EvidenceError("ABSENT replay must contain an empty non-invoked output")
        recomputed = typed_absent_score(
            reference,
            expected_terms=term_inputs["expected_terms"],
            reference_regions=(list(raw_regions) if raw_regions is not None else None),
        )
    else:
        recomputed = score_target(
            reference,
            hypothesis,
            expected_terms=term_inputs["expected_terms"],
            absent_terms=term_inputs["absent_terms"],
            other_target_terms=term_inputs["other_target_terms"],
            reference_regions=(list(raw_regions) if raw_regions is not None else None),
        )
    if dict(replay) != recomputed["score_replay"]:
        raise EvidenceError("arm score_replay is not canonical")
    replay_owned_fields = (
        "cer",
        "wer",
        "cer_counts",
        "wer_counts",
        "term_recall",
        "term_details",
        "absent_term_insertions",
        "cross_speaker_insertions",
        "normalized_text",
        "normalized_text_empty",
        "regional",
        "stable_o_counts",
    )
    for field in replay_owned_fields:
        if arm.get(field) != recomputed.get(field):
            raise EvidenceError(f"arm {field} differs from deterministic score replay")


def _bound_cer(
    arm: Mapping[str, object], expected: Mapping[str, object]
) -> float:
    validate_arm_bindings(arm, expected)
    _require_available(
        arm.get("availability"), f"{arm.get('arm_id', '<unknown>')}: arm"
    )
    _validate_arm_score_record(arm, expected)
    return _nonnegative(arm.get("cer"), "arm CER")


def _bound_overlap_recall(
    arm: Mapping[str, object], expected: Mapping[str, object]
) -> float:
    validate_arm_bindings(arm, expected)
    _require_available(
        arm.get("availability"), f"{arm.get('arm_id', '<unknown>')}: arm"
    )
    regional = arm.get("regional")
    if not isinstance(regional, Mapping):
        raise EvidenceError("overlap-recovery arm omits regional edit evidence")
    observed_path_hash = arm.get("regional_edit_path_sha256")
    sealed_path_hash = expected.get("regional_edit_path_sha256")
    for name, value in (
        ("regional edit-path hash", observed_path_hash),
        ("sealed regional edit-path hash", sealed_path_hash),
    ):
        if not isinstance(value, str) or SHA256_PATTERN.fullmatch(value) is None:
            raise EvidenceError(f"{name} is not a lowercase SHA-256")
    if (
        observed_path_hash != sealed_path_hash
        or observed_path_hash != regional.get("regional_edit_path_sha256")
    ):
        raise EvidenceError("regional edit-path hash differs from sealed evidence")
    counts = stable_overlap_target_counts(regional)
    overlap_operations = regional["regional_operation_counts"]["O"]
    expected_counts = {
        "reference_chars": counts["reference_characters"],
        "substitutions": overlap_operations["substitution"],
        "deletions": overlap_operations["deletion"],
        "insertions": overlap_operations["insertion"],
        "hits": counts["hit_characters"],
        "regional_edit_path_sha256": observed_path_hash,
    }
    if arm.get("stable_o_counts") != expected_counts:
        raise EvidenceError("arm stable_o_counts differ from the sealed edit path")
    return counts["hit_characters"] / counts["reference_characters"]


def _validate_overlap_arm_roles(
    arms: Mapping[str, Mapping[str, object]],
) -> None:
    expected_roles = {
        "turbo-clean-O": ("turbo", "not_applicable"),
        "turbo-mix-O": ("turbo", "not_applicable"),
        "dicow-clean-O": ("dicow", "not_applicable"),
        "dicow-mix-O-oracle": ("dicow", "correct"),
        "dicow-mix-O-community1": ("dicow", "correct"),
    }
    for condition, (model, assignment) in expected_roles.items():
        arm = arms[condition]
        if (
            arm.get("condition") != condition
            or arm.get("model") != model
            or arm.get("provider_assignment") != assignment
            or arm.get("arm_kind") != "crop"
        ):
            raise EvidenceError(f"{condition}: arm semantic role is not exact")
        provider_hash = arm.get("activity_provider_sha256")
        stno_hash = arm.get("stno_sha256")
        if model == "turbo":
            if provider_hash is not None or stno_hash is not None:
                raise EvidenceError(f"{condition}: turbo must not carry provider/STNO hashes")
        elif provider_hash is None or stno_hash is None:
            raise EvidenceError(f"{condition}: DiCoW requires provider and STNO hashes")


def compute_overlap_contrasts(
    arms: Mapping[str, Mapping[str, object]],
    expected_bindings: Mapping[str, Mapping[str, object]],
) -> dict[str, float]:
    """Compute the frozen crop estimands after exact binding verification."""

    required = (
        "turbo-clean-O",
        "turbo-mix-O",
        "dicow-clean-O",
        "dicow-mix-O-oracle",
        "dicow-mix-O-community1",
    )
    missing = [name for name in required if name not in arms or name not in expected_bindings]
    if missing:
        raise EvidenceError(f"missing required contrast arms: {missing!r}")
    _validate_overlap_arm_roles(arms)
    cer = {
        name: _bound_cer(arms[name], expected_bindings[name]) for name in required
    }
    common_fields = (
        "mapping_sha256",
        "utility_contract_sha256",
        "alignment_sha256",
        "region_labels_sha256",
        "k_sha256",
        "k_frames_sha256",
    )
    for field in common_fields:
        values = {arms[name].get(field) for name in required}
        if len(values) != 1 or None in values:
            raise EvidenceError(f"crop contrast arms do not share {field}")
    for field in (
        "window_id",
        "fixture_family",
        "target_id",
        "reference_id",
        "repetition",
    ):
        values = {arms[name].get(field) for name in required}
        if len(values) != 1 or None in values:
            raise EvidenceError(f"crop contrast arms do not share {field}")
    if next(iter({arms[name].get("repetition") for name in required})) not in {1, 2}:
        raise EvidenceError("crop contrast repetition must be 1 or 2")
    clean_audio = {
        arms["turbo-clean-O"].get("audio_sha256"),
        arms["dicow-clean-O"].get("audio_sha256"),
    }
    if len(clean_audio) != 1 or None in clean_audio:
        raise EvidenceError("clean crop arms do not share audio_sha256")
    mix_audio = {
        arms[name].get("audio_sha256")
        for name in (
            "turbo-mix-O",
            "dicow-mix-O-oracle",
            "dicow-mix-O-community1",
        )
    }
    if len(mix_audio) != 1 or None in mix_audio:
        raise EvidenceError("mixture crop arms do not share audio_sha256")
    d_turbo = cer["turbo-mix-O"] - cer["turbo-clean-O"]
    d_oracle = cer["dicow-mix-O-oracle"] - cer["dicow-clean-O"]
    d_community = cer["dicow-mix-O-community1"] - cer["dicow-clean-O"]
    return {
        "D_turbo^O": d_turbo,
        "D_dicow,oracle^O": d_oracle,
        "D_dicow,community1^O": d_community,
        "G_oracle^O": d_turbo - d_oracle,
        "G_community1^O": d_turbo - d_community,
    }


def relative_recall_preservation(
    mix_recall: float, clean_recall: float
) -> dict[str, object]:
    """Return R_mix/R_clean or a typed unavailable result for a zero denominator."""

    mix = _finite(mix_recall, "mixture stable-O recall")
    clean = _finite(clean_recall, "clean stable-O recall")
    if not 0 <= mix <= 1 or not 0 <= clean <= 1:
        raise EvidenceError("stable-O recall must be between zero and one")
    if clean <= 0:
        return {
            "availability": {
                "status": "unavailable",
                "reason": "nonpositive_clean_stable_overlap_recall",
            },
            "value": None,
        }
    return {
        "availability": {"status": "available", "reason": None},
        "value": mix / clean,
    }


def compute_overlap_recovery_contrasts(
    arms: Mapping[str, Mapping[str, object]],
    expected_bindings: Mapping[str, Mapping[str, object]],
) -> dict[str, object]:
    """Compute insertion-resistant stable-O recovery for oracle and Community-1."""

    # Reuse the CER path solely as the causal pairing and complete-arm validator.
    compute_overlap_contrasts(arms, expected_bindings)
    required = (
        "turbo-clean-O",
        "turbo-mix-O",
        "dicow-clean-O",
        "dicow-mix-O-oracle",
        "dicow-mix-O-community1",
    )
    recall: dict[str, float] = {}
    counts: dict[str, dict[str, int]] = {}
    for name in required:
        recall[name] = _bound_overlap_recall(arms[name], expected_bindings[name])
        regional = arms[name].get("regional")
        if not isinstance(regional, Mapping):
            raise EvidenceError("overlap-recovery arm omits regional edit evidence")
        counts[name] = stable_overlap_target_counts(regional)
    reference_counts = {
        value["reference_characters"] for value in counts.values()
    }
    if len(reference_counts) != 1:
        raise EvidenceError("paired overlap arms do not share stable-O reference characters")
    turbo_delta = recall["turbo-mix-O"] - recall["turbo-clean-O"]
    oracle_delta = recall["dicow-mix-O-oracle"] - recall["dicow-clean-O"]
    community_delta = (
        recall["dicow-mix-O-community1"] - recall["dicow-clean-O"]
    )
    return {
        "R_turbo_clean^O": recall["turbo-clean-O"],
        "R_turbo_mix^O": recall["turbo-mix-O"],
        "R_dicow_clean^O": recall["dicow-clean-O"],
        "R_dicow_mix,oracle^O": recall["dicow-mix-O-oracle"],
        "R_dicow_mix,community1^O": recall["dicow-mix-O-community1"],
        "G_R_oracle^O": oracle_delta - turbo_delta,
        "G_R_community1^O": community_delta - turbo_delta,
        "relative_preservation_oracle": relative_recall_preservation(
            recall["dicow-mix-O-oracle"], recall["dicow-clean-O"]
        ),
        "relative_preservation_community1": relative_recall_preservation(
            recall["dicow-mix-O-community1"], recall["dicow-clean-O"]
        ),
        "target_character_preservation_oracle": {
            "condition": "dicow-mix-O-oracle",
            "provider_assignment": "correct",
            "stable_o_reference_characters": counts["dicow-clean-O"][
                "reference_characters"
            ],
            "clean_hit_characters": counts["dicow-clean-O"]["hit_characters"],
            "mix_hit_characters": counts["dicow-mix-O-oracle"]["hit_characters"],
        },
        "target_character_preservation_community1": {
            "condition": "dicow-mix-O-community1",
            "provider_assignment": "correct",
            "stable_o_reference_characters": counts["dicow-clean-O"][
                "reference_characters"
            ],
            "clean_hit_characters": counts["dicow-clean-O"]["hit_characters"],
            "mix_hit_characters": counts["dicow-mix-O-community1"][
                "hit_characters"
            ],
        },
    }


def compute_nonoverlap_preservation(
    full_mix: Mapping[str, object],
    clean_single: Mapping[str, object],
    expected_full_mix: Mapping[str, object],
    expected_clean_single: Mapping[str, object],
) -> float:
    """Return P_q^N from stable-N CER, rejecting a nonpositive denominator."""

    validate_arm_bindings(full_mix, expected_full_mix)
    validate_arm_bindings(clean_single, expected_clean_single)
    _require_available(full_mix.get("availability"), "non-overlap arm")
    _require_available(clean_single.get("availability"), "non-overlap arm")
    _validate_arm_score_record(full_mix, expected_full_mix)
    _validate_arm_score_record(clean_single, expected_clean_single)
    if (
        full_mix.get("model") != "dicow"
        or full_mix.get("condition")
        not in {"dicow-full-mix-oracle", "dicow-full-mix-community1"}
        or full_mix.get("provider_assignment") != "correct"
        or full_mix.get("arm_kind") != "full_window"
        or clean_single.get("model") != "dicow"
        or clean_single.get("condition") != "dicow-clean-single-utility"
        or clean_single.get("provider_assignment") != "not_applicable"
        or clean_single.get("arm_kind") != "full_window"
    ):
        raise EvidenceError("non-overlap arms do not have exact full/clean semantic roles")
    for arm in (full_mix, clean_single):
        if arm.get("activity_provider_sha256") is None or arm.get("stno_sha256") is None:
            raise EvidenceError("non-overlap DiCoW arms require provider and STNO hashes")
    for field in (
        "mapping_sha256",
        "utility_contract_sha256",
        "alignment_sha256",
        "region_labels_sha256",
    ):
        if full_mix.get(field) != clean_single.get(field):
            raise EvidenceError(f"non-overlap arms do not share {field}")
    for field in (
        "window_id",
        "fixture_family",
        "target_id",
        "reference_id",
        "repetition",
    ):
        if full_mix.get(field) is None or full_mix.get(field) != clean_single.get(field):
            raise EvidenceError(f"non-overlap arms do not share {field}")
    if full_mix.get("repetition") not in {1, 2}:
        raise EvidenceError("non-overlap repetition must be 1 or 2")
    n_cer: list[float] = []
    for arm in (full_mix, clean_single):
        regional = arm.get("regional")
        if not isinstance(regional, Mapping):
            raise EvidenceError("non-overlap arm omits deterministic regional evidence")
        denominators = regional.get("regional_denominators")
        errors = regional.get("regional_errors")
        if not isinstance(denominators, Mapping) or not isinstance(errors, Mapping):
            raise EvidenceError("non-overlap arm omits regional N counts")
        denominator = denominators.get("N")
        error_count = errors.get("N")
        if (
            isinstance(denominator, bool)
            or not isinstance(denominator, int)
            or denominator <= 0
        ):
            raise EvidenceError("stable-N denominator must be positive")
        if (
            isinstance(error_count, bool)
            or not isinstance(error_count, int)
            or error_count < 0
        ):
            raise EvidenceError("stable-N error count must be a nonnegative integer")
        computed = error_count / denominator
        if "n_reference_characters" in arm and arm.get(
            "n_reference_characters"
        ) != denominator:
            raise EvidenceError("asserted stable-N denominator differs from replay")
        if "n_cer" in arm and not math.isclose(
            _nonnegative(arm.get("n_cer"), "asserted N CER"),
            computed,
            rel_tol=1e-12,
            abs_tol=1e-12,
        ):
            raise EvidenceError("asserted N CER differs from replay")
        n_cer.append(computed)
    return n_cer[0] - n_cer[1]


def compute_swap_margin(
    correct: Mapping[str, object],
    swapped: Mapping[str, object],
    expected_correct: Mapping[str, object],
    expected_swapped: Mapping[str, object],
) -> float:
    """Return swapped-mask CER minus correct-mask CER after binding both arms."""

    correct_cer = _bound_cer(correct, expected_correct)
    swapped_cer = _bound_cer(swapped, expected_swapped)
    if (
        correct.get("model") != "dicow"
        or swapped.get("model") != "dicow"
        or correct.get("condition")
        not in {"dicow-mix-O-oracle", "dicow-mix-O-community1"}
        or swapped.get("condition") != correct.get("condition")
        or correct.get("provider_assignment") != "correct"
        or swapped.get("provider_assignment") != "swapped"
        or correct.get("arm_kind") != "crop"
        or swapped.get("arm_kind") != "crop"
    ):
        raise EvidenceError("swap arms do not have exact correct/swapped semantic roles")
    shared_fields = (
        "mapping_sha256",
        "utility_contract_sha256",
        "alignment_sha256",
        "region_labels_sha256",
        "audio_sha256",
        "activity_provider_sha256",
        "k_sha256",
        "k_frames_sha256",
    )
    for field in shared_fields:
        if correct.get(field) is None or correct.get(field) != swapped.get(field):
            raise EvidenceError(f"swap arms do not share {field}")
    for field in (
        "window_id",
        "fixture_family",
        "target_id",
        "reference_id",
        "repetition",
    ):
        if correct.get(field) is None or correct.get(field) != swapped.get(field):
            raise EvidenceError(f"swap arms do not share {field}")
    if correct.get("repetition") not in {1, 2}:
        raise EvidenceError("swap repetition must be 1 or 2")
    if correct.get("stno_sha256") is None or swapped.get("stno_sha256") is None:
        raise EvidenceError("swap arms require typed STNO hashes")
    # STNO differs by construction because the two provider slots were exchanged.
    return swapped_cer - correct_cer


def compute_recall_swap_margin(
    correct: Mapping[str, object],
    swapped: Mapping[str, object],
    expected_correct: Mapping[str, object],
    expected_swapped: Mapping[str, object],
) -> float:
    """Return correct-minus-swapped stable-O recall with exact causal identity binding."""

    # This validates hashes, availability, K/audio/provider identity, and all causal IDs.
    compute_swap_margin(correct, swapped, expected_correct, expected_swapped)
    correct_recall = _bound_overlap_recall(correct, expected_correct)
    swapped_recall = _bound_overlap_recall(swapped, expected_swapped)
    return correct_recall - swapped_recall


def aggregate_two_target_windows(
    rows: Sequence[Mapping[str, object]],
    value_field: str,
    *,
    expected_targets_by_window: Mapping[str, Sequence[str]] | None = None,
) -> list[dict[str, object]]:
    """Average exactly two target values in every constructed window."""

    if not rows:
        raise EvidenceError("no target rows were supplied")
    repetitions = {int(row.get("repetition", 0)) for row in rows}
    if len(repetitions) != 1 or repetitions == {0}:
        raise EvidenceError("one complete repetition is required per aggregation")
    grouped: dict[tuple[str, str, str], list[Mapping[str, object]]] = defaultdict(list)
    for row in rows:
        window_id = str(row.get("window_id", ""))
        family = str(row.get("fixture_family", ""))
        language = str(row.get("language", ""))
        target_id = str(row.get("target_id", ""))
        if not all((window_id, family, language, target_id)):
            raise EvidenceError("target row omits cluster identity")
        grouped[(window_id, family, language)].append(row)
    result: list[dict[str, object]] = []
    for (window_id, family, language), members in sorted(grouped.items()):
        target_ids = [str(member["target_id"]) for member in members]
        if len(members) != 2 or len(set(target_ids)) != 2:
            raise EvidenceError(f"window {window_id!r} must contain exactly two targets")
        if expected_targets_by_window is not None:
            if window_id not in expected_targets_by_window:
                raise EvidenceError(f"unexpected window {window_id!r}")
            if set(target_ids) != set(expected_targets_by_window[window_id]):
                raise EvidenceError(f"window {window_id!r} does not contain frozen targets")
        values = [_finite(member.get(value_field), value_field) for member in members]
        result.append(
            {
                "window_id": window_id,
                "fixture_family": family,
                "language": language,
                "repetition": next(iter(repetitions)),
                "target_ids": sorted(target_ids),
                "value": sum(values) / 2,
            }
        )
    if expected_targets_by_window is not None and {
        str(row["window_id"]) for row in result
    } != set(expected_targets_by_window):
        raise EvidenceError("one or more frozen windows were dropped")
    return result


def half_oracle_window_rows(
    target_rows: Sequence[Mapping[str, object]],
) -> list[dict[str, object]]:
    """Calculate G_community1,w - 0.5*G_oracle,w after target aggregation."""

    oracle = aggregate_two_target_windows(target_rows, "G_oracle^O")
    community = aggregate_two_target_windows(target_rows, "G_community1^O")
    oracle_by_id = {str(row["window_id"]): row for row in oracle}
    community_by_id = {str(row["window_id"]): row for row in community}
    if oracle_by_id.keys() != community_by_id.keys():
        raise EvidenceError("oracle and Community-1 windows do not match")
    result: list[dict[str, object]] = []
    for window_id in sorted(oracle_by_id):
        left = oracle_by_id[window_id]
        right = community_by_id[window_id]
        if any(left[key] != right[key] for key in ("fixture_family", "language", "repetition", "target_ids")):
            raise EvidenceError(f"window {window_id!r} is not paired")
        result.append(
            {
                **{key: right[key] for key in ("window_id", "fixture_family", "language", "repetition")},
                "value": _finite(right["value"], "Community-1 window gain")
                - 0.5 * _finite(left["value"], "oracle window gain"),
            }
        )
    return result


def summarize_overlap_recovery_gain(
    target_rows: Sequence[Mapping[str, object]],
    *,
    provider: Literal["oracle", "community1"],
    expected_targets_by_window: Mapping[str, Sequence[str]],
    expected_cluster_signature: Iterable[tuple[str, str, str]],
) -> dict[int, dict[str, dict[str, object]]]:
    """Aggregate two targets per window and bootstrap G_R in every frozen stratum."""

    field = f"G_R_{provider}^O"
    by_repetition: dict[int, list[Mapping[str, object]]] = defaultdict(list)
    for row in target_rows:
        repetition = int(row.get("repetition", 0))
        if repetition not in {1, 2}:
            raise EvidenceError("recovery target repetition must be 1 or 2")
        by_repetition[repetition].append(row)
    if set(by_repetition) != {1, 2}:
        raise EvidenceError("recovery gain requires both complete repetitions")
    windows: list[dict[str, object]] = []
    for repetition in (1, 2):
        windows.extend(
            aggregate_two_target_windows(
                by_repetition[repetition],
                field,
                expected_targets_by_window=expected_targets_by_window,
            )
        )
    return summarize_repetitions(
        windows,
        required_strata=REQUIRED_GATE_STRATA,
        expected_cluster_signature=expected_cluster_signature,
    )


def aggregate_target_character_hits(
    target_rows: Sequence[Mapping[str, object]],
    *,
    provider: Literal["oracle", "community1"],
    expected_targets_by_window: Mapping[str, Sequence[str]],
) -> list[dict[str, object]]:
    """Pool both correct A/B target directions into character-count window rows."""

    if not target_rows:
        raise EvidenceError("target-character preservation requires target rows")
    repetitions = {int(row.get("repetition", 0)) for row in target_rows}
    if len(repetitions) != 1 or repetitions == {0}:
        raise EvidenceError("one complete repetition is required per preservation aggregation")
    repetition = next(iter(repetitions))
    if repetition not in {1, 2}:
        raise EvidenceError("preservation repetition must be 1 or 2")
    record_field = f"target_character_preservation_{provider}"
    expected_condition = f"dicow-mix-O-{provider}"
    grouped: dict[tuple[str, str, str], list[Mapping[str, object]]] = defaultdict(list)
    for row in target_rows:
        window_id = str(row.get("window_id", ""))
        family = str(row.get("fixture_family", ""))
        language = str(row.get("language", ""))
        target_id = str(row.get("target_id", ""))
        target_slot = str(row.get("target_slot", ""))
        if not all((window_id, family, language, target_id)) or target_slot not in {"A", "B"}:
            raise EvidenceError("preservation target row omits exact cluster or A/B identity")
        record = row.get(record_field)
        if not isinstance(record, Mapping) or set(record) != {
            "condition",
            "provider_assignment",
            "stable_o_reference_characters",
            "clean_hit_characters",
            "mix_hit_characters",
        }:
            raise EvidenceError("preservation target row omits the replayable count record")
        if (
            record.get("condition") != expected_condition
            or record.get("provider_assignment") != "correct"
        ):
            raise EvidenceError("preservation accepts only the correct provider assignment")
        for name in (
            "stable_o_reference_characters",
            "clean_hit_characters",
            "mix_hit_characters",
        ):
            value = record.get(name)
            if isinstance(value, bool) or not isinstance(value, int) or value < 0:
                raise EvidenceError(f"{name} must be a nonnegative integer")
        reference_characters = int(record["stable_o_reference_characters"])
        if reference_characters <= 0:
            raise EvidenceError("stable-O reference characters must be positive")
        if (
            int(record["clean_hit_characters"]) > reference_characters
            or int(record["mix_hit_characters"]) > reference_characters
        ):
            raise EvidenceError("stable-O hits exceed the matching reference count")
        grouped[(window_id, family, language)].append(row)
    result: list[dict[str, object]] = []
    for (window_id, family, language), members in sorted(grouped.items()):
        target_ids = [str(member["target_id"]) for member in members]
        target_slots = [str(member["target_slot"]) for member in members]
        if (
            len(members) != 2
            or len(set(target_ids)) != 2
            or set(target_slots) != {"A", "B"}
        ):
            raise EvidenceError(f"window {window_id!r} must contain correct A/B targets")
        if window_id not in expected_targets_by_window:
            raise EvidenceError(f"window {window_id!r} does not contain frozen targets")
        frozen_targets = tuple(str(value) for value in expected_targets_by_window[window_id])
        if (
            len(frozen_targets) != 2
            or len(set(frozen_targets)) != 2
            or set(target_ids) != set(frozen_targets)
        ):
            raise EvidenceError(f"window {window_id!r} does not contain frozen targets")
        slot_by_target = {
            str(member["target_id"]): str(member["target_slot"])
            for member in members
        }
        if slot_by_target != {frozen_targets[0]: "A", frozen_targets[1]: "B"}:
            raise EvidenceError(
                f"window {window_id!r} target IDs are not bound to frozen A/B slots"
            )
        records = [member[record_field] for member in members]
        result.append(
            {
                "window_id": window_id,
                "fixture_family": family,
                "language": language,
                "repetition": repetition,
                "target_ids": sorted(target_ids),
                "clean_hit_characters": sum(
                    int(record["clean_hit_characters"]) for record in records
                ),
                "mix_hit_characters": sum(
                    int(record["mix_hit_characters"]) for record in records
                ),
            }
        )
    if {str(row["window_id"]) for row in result} != set(expected_targets_by_window):
        raise EvidenceError("one or more frozen preservation windows were dropped")
    return result


def _nearest_rank(values: Sequence[float], probability: float) -> float:
    if not values:
        raise EvidenceError("percentile requires observations")
    ordered = sorted(values)
    rank = max(1, math.ceil(probability * len(ordered)))
    return ordered[rank - 1]


def _cluster_groups(
    window_rows: Sequence[Mapping[str, object]],
    stratum: Literal["overall", "ko", "it", "en"],
) -> tuple[list[Mapping[str, object]], list[tuple[tuple[str, str], list[Mapping[str, object]]]]]:
    if not window_rows:
        raise EvidenceError("bootstrap requires window rows")
    repetitions = {int(row.get("repetition", 0)) for row in window_rows}
    if len(repetitions) != 1 or repetitions == {0}:
        raise EvidenceError("bootstrap may contain exactly one complete repetition")
    selected = sorted(
        (row for row in window_rows if stratum == "overall" or row.get("language") == stratum),
        key=lambda row: (
            str(row.get("fixture_family", "")),
            str(row.get("language", "")),
            str(row.get("window_id", "")),
        ),
    )
    if not selected:
        raise EvidenceError(f"no clusters for stratum {stratum!r}")
    window_ids = [str(row.get("window_id", "")) for row in selected]
    if any(not value for value in window_ids) or len(window_ids) != len(set(window_ids)):
        raise EvidenceError("cluster IDs must be nonempty and unique")
    grouped: dict[tuple[str, str], list[Mapping[str, object]]] = defaultdict(list)
    for row in selected:
        family = str(row.get("fixture_family", ""))
        language = str(row.get("language", ""))
        if not family or language not in {"ko", "it", "en"}:
            raise EvidenceError("cluster row has invalid fixture family or language")
        grouped[(family, language)].append(row)
    if any(len(rows) < 2 for rows in grouped.values()):
        raise EvidenceError("every applicable family-language stratum needs two clusters")
    return selected, [(key, grouped[key]) for key in sorted(grouped)]


def _frozen_cluster_resample_indices(
    group_sizes: Sequence[int], *, seed: int, resamples: int
) -> Iterable[tuple[tuple[int, ...], ...]]:
    """Yield the single frozen cluster-index stream shared by every estimand."""

    rng = random.Random(seed)
    for _ in range(resamples):
        yield tuple(
            tuple(rng.randrange(size) for _ in range(size)) for size in group_sizes
        )


def cluster_bootstrap_interval(
    window_rows: Sequence[Mapping[str, object]],
    *,
    stratum: Literal["overall", "ko", "it", "en"] = "overall",
    one_sided_upper: bool = False,
    seed: int = BOOTSTRAP_SEED,
    resamples: int = BOOTSTRAP_RESAMPLES,
) -> dict[str, object]:
    """Deterministic paired cluster bootstrap, stratified by family and language."""

    if seed != BOOTSTRAP_SEED or resamples != BOOTSTRAP_RESAMPLES:
        raise EvidenceError("bootstrap seed and resample count are frozen")
    selected, row_groups = _cluster_groups(window_rows, stratum)
    value_groups = [
        [_finite(row.get("value"), "cluster value") for row in rows]
        for _, rows in row_groups
    ]
    point_values = [value for values in value_groups for value in values]
    point = sum(point_values) / len(point_values)
    sampled_means: list[float] = []
    for group_indices in _frozen_cluster_resample_indices(
        [len(values) for values in value_groups], seed=seed, resamples=resamples
    ):
        sample = [
            values[index]
            for values, indices in zip(value_groups, group_indices, strict=True)
            for index in indices
        ]
        sampled_means.append(sum(sample) / len(sample))
    if one_sided_upper:
        interval: dict[str, object] = {
            "kind": "one_sided_upper_95_percentile",
            "upper": _nearest_rank(sampled_means, 0.95),
        }
    else:
        interval = {
            "kind": "two_sided_95_percentile",
            "lower": _nearest_rank(sampled_means, 0.025),
            "upper": _nearest_rank(sampled_means, 0.975),
        }
    return {
        "point": point,
        "interval": interval,
        "cluster_count": len(selected),
        "stratum": stratum,
        "seed": seed,
        "resamples": resamples,
        "stratify_by": ["fixture_family", "language"],
        "percentile_method": PERCENTILE_METHOD,
        "ambiguous": False,
        "ambiguity_reason": None,
    }


def target_character_preservation_interval(
    window_rows: Sequence[Mapping[str, object]],
    *,
    stratum: Literal["overall", "ko", "it", "en"] = "overall",
    seed: int = BOOTSTRAP_SEED,
    resamples: int = BOOTSTRAP_RESAMPLES,
) -> dict[str, object]:
    """Bootstrap the character-weighted pooled mix-hit/clean-hit preservation ratio."""

    if seed != BOOTSTRAP_SEED or resamples != BOOTSTRAP_RESAMPLES:
        raise EvidenceError("bootstrap seed and resample count are frozen")
    selected, row_groups = _cluster_groups(window_rows, stratum)
    count_groups: list[list[tuple[int, int]]] = []
    for _, rows in row_groups:
        counts: list[tuple[int, int]] = []
        for row in rows:
            clean = row.get("clean_hit_characters")
            mix = row.get("mix_hit_characters")
            for name, value in (
                ("clean_hit_characters", clean),
                ("mix_hit_characters", mix),
            ):
                if isinstance(value, bool) or not isinstance(value, int) or value < 0:
                    raise EvidenceError(f"{name} must be a nonnegative integer")
            counts.append((int(clean), int(mix)))
        count_groups.append(counts)
    clean_total = sum(clean for counts in count_groups for clean, _ in counts)
    mix_total = sum(mix for counts in count_groups for _, mix in counts)
    if clean_total <= 0:
        raise EvidenceError(
            f"target_character_preservation:{stratum}:zero_clean_hit_denominator"
        )
    sampled_ratios: list[float] = []
    zero_denominator_resamples = 0
    for group_indices in _frozen_cluster_resample_indices(
        [len(counts) for counts in count_groups], seed=seed, resamples=resamples
    ):
        sampled_clean = 0
        sampled_mix = 0
        for counts, indices in zip(count_groups, group_indices, strict=True):
            for index in indices:
                clean, mix = counts[index]
                sampled_clean += clean
                sampled_mix += mix
        if sampled_clean == 0:
            zero_denominator_resamples += 1
            sampled_ratios.append(0.0)
        else:
            sampled_ratios.append(sampled_mix / sampled_clean)
    return {
        "point": mix_total / clean_total,
        "interval": {
            "kind": "two_sided_95_percentile",
            "lower": _nearest_rank(sampled_ratios, 0.025),
            "upper": _nearest_rank(sampled_ratios, 0.975),
        },
        "cluster_count": len(selected),
        "stratum": stratum,
        "seed": seed,
        "resamples": resamples,
        "stratify_by": ["fixture_family", "language"],
        "percentile_method": PERCENTILE_METHOD,
        "weighting": "pooled_stable_o_hit_characters",
        "zero_denominator_resamples": zero_denominator_resamples,
        "ambiguous": False,
        "ambiguity_reason": None,
    }


def summarize_target_character_preservation(
    target_rows: Sequence[Mapping[str, object]],
    *,
    provider: Literal["oracle", "community1"],
    expected_targets_by_window: Mapping[str, Sequence[str]],
    expected_cluster_signature: Iterable[tuple[str, str, str]],
) -> dict[int, dict[str, dict[str, object]]]:
    """Summarize pooled correct-assignment preservation in all frozen cells."""

    by_repetition: dict[int, list[Mapping[str, object]]] = defaultdict(list)
    for row in target_rows:
        repetition = int(row.get("repetition", 0))
        if repetition not in {1, 2}:
            raise EvidenceError("preservation target repetition must be 1 or 2")
        by_repetition[repetition].append(row)
    if set(by_repetition) != {1, 2}:
        raise EvidenceError("preservation requires both complete repetitions")
    expected = _normalized_signature(
        expected_cluster_signature, "expected cluster signature"
    )
    windows_by_repetition = {
        repetition: aggregate_target_character_hits(
            by_repetition[repetition],
            provider=provider,
            expected_targets_by_window=expected_targets_by_window,
        )
        for repetition in (1, 2)
    }
    signatures = {
        repetition: {
            (
                str(row["window_id"]),
                str(row["fixture_family"]),
                str(row["language"]),
            )
            for row in rows
        }
        for repetition, rows in windows_by_repetition.items()
    }
    if signatures[1] != signatures[2] or signatures[1] != expected:
        raise EvidenceError("preservation repetitions omit frozen clusters")
    return {
        repetition: {
            stratum: target_character_preservation_interval(
                windows_by_repetition[repetition], stratum=stratum
            )
            for stratum in REQUIRED_GATE_STRATA
        }
        for repetition in (1, 2)
    }


def evaluate_target_character_preservation_gate(
    summaries: Mapping[int, Mapping[str, Mapping[str, object]]],
) -> dict[str, object]:
    """Require every frozen 95% lower bound to meet the inclusive 0.75 floor."""

    if set(summaries) != {1, 2}:
        raise EvidenceError("preservation gate requires repetitions 1 and 2")
    failures: list[dict[str, object]] = []
    for repetition in (1, 2):
        cells = summaries[repetition]
        if set(cells) != set(REQUIRED_GATE_STRATA):
            raise EvidenceError("preservation gate omits a frozen stratum")
        for stratum in REQUIRED_GATE_STRATA:
            summary = cells[stratum]
            interval = summary.get("interval")
            if not isinstance(interval, Mapping):
                raise EvidenceError("preservation summary omits its interval")
            if (
                interval.get("kind") != "two_sided_95_percentile"
                or summary.get("seed") != BOOTSTRAP_SEED
                or summary.get("resamples") != BOOTSTRAP_RESAMPLES
                or summary.get("percentile_method") != PERCENTILE_METHOD
                or summary.get("weighting") != "pooled_stable_o_hit_characters"
            ):
                raise EvidenceError("preservation summary does not use the frozen pooled statistic")
            point = _finite(summary.get("point"), "preservation point")
            lower = _finite(interval.get("lower"), "preservation lower bound")
            if point < 0.75 or lower < 0.75:
                failures.append(
                    {
                        "repetition": repetition,
                        "stratum": stratum,
                        "point": point,
                        "lower": lower,
                        "required_min": 0.75,
                    }
                )
    return {"passed": not failures, "failures": failures}


def target_threshold_proportion(
    target_rows: Sequence[Mapping[str, object]],
    *,
    value_field: str,
    threshold: float,
    comparison: Literal[">", ">=", "empty"],
    expected_target_ids: Iterable[str] | None = None,
) -> float:
    """Compute a target proportion while proving that no target disappeared."""

    if not target_rows:
        raise EvidenceError("target proportion requires target rows")
    identities = [str(row.get("target_id", "")) for row in target_rows]
    if any(not identity for identity in identities) or len(identities) != len(set(identities)):
        raise EvidenceError("target proportion identities must be nonempty and unique")
    if expected_target_ids is not None and set(identities) != set(expected_target_ids):
        raise EvidenceError("target proportion does not contain the frozen target set")
    passed = 0
    for row in target_rows:
        if comparison == "empty":
            if row.get(value_field) is not True:
                if row.get(value_field) is not False:
                    raise EvidenceError(f"{value_field} must be boolean")
            outcome = row[value_field] is True
        else:
            value = _finite(row.get(value_field), value_field)
            outcome = value > threshold if comparison == ">" else value >= threshold
        passed += int(outcome)
    return passed / len(target_rows)


def _normalized_signature(
    signature: Iterable[tuple[str, str, str]], name: str
) -> set[tuple[str, str, str]]:
    result = {tuple(str(value) for value in item) for item in signature}
    if any(len(item) != 3 or any(not value for value in item) for item in result):
        raise EvidenceError(f"{name} contains an invalid identity")
    if not result:
        raise EvidenceError(f"{name} must not be empty")
    return result


def summarize_repetitions(
    window_rows: Sequence[Mapping[str, object]],
    *,
    required_strata: Sequence[Literal["overall", "ko", "it", "en"]],
    expected_cluster_signature: Iterable[tuple[str, str, str]],
    one_sided_upper: bool = False,
) -> dict[int, dict[str, dict[str, object]]]:
    """Summarize each repetition independently and reject incomplete cluster sets."""

    by_repetition: dict[int, list[Mapping[str, object]]] = defaultdict(list)
    for row in window_rows:
        repetition = int(row.get("repetition", 0))
        if repetition not in {1, 2}:
            raise EvidenceError("repetition must be 1 or 2")
        by_repetition[repetition].append(row)
    if set(by_repetition) != {1, 2}:
        raise EvidenceError("both complete repetitions are required")
    signatures = {
        repetition: {
            (str(row.get("window_id", "")), str(row.get("fixture_family", "")), str(row.get("language", "")))
            for row in rows
        }
        for repetition, rows in by_repetition.items()
    }
    expected = _normalized_signature(expected_cluster_signature, "expected cluster signature")
    if signatures[1] != signatures[2] or signatures[1] != expected:
        raise EvidenceError("repetitions do not contain the complete frozen clusters")
    strata = tuple(required_strata)
    if not strata or len(set(strata)) != len(strata) or any(
        stratum not in REQUIRED_GATE_STRATA for stratum in strata
    ):
        raise EvidenceError("required_strata is invalid")
    return {
        repetition: {
            stratum: cluster_bootstrap_interval(
                by_repetition[repetition],
                stratum=stratum,
                one_sided_upper=one_sided_upper,
            )
            for stratum in strata
        }
        for repetition in (1, 2)
    }


def summarize_target_proportions(
    target_rows: Sequence[Mapping[str, object]],
    *,
    value_field: str,
    threshold: float,
    comparison: Literal[">", ">=", "empty"],
    required_strata: Sequence[Literal["overall", "ko", "it", "en"]],
    expected_target_signature: Iterable[tuple[str, str, str]],
) -> dict[int, dict[str, float]]:
    """Report a frozen target proportion per repetition and requested language cell."""

    by_repetition: dict[int, list[Mapping[str, object]]] = defaultdict(list)
    for row in target_rows:
        repetition = int(row.get("repetition", 0))
        if repetition not in {1, 2}:
            raise EvidenceError("repetition must be 1 or 2")
        language = str(row.get("language", ""))
        if language not in {"ko", "it", "en"}:
            raise EvidenceError("target row has invalid language")
        by_repetition[repetition].append(row)
    if set(by_repetition) != {1, 2}:
        raise EvidenceError("both repetitions are required for target proportions")
    signatures = {
        repetition: {
            (str(row.get("window_id", "")), str(row.get("target_id", "")), str(row.get("language", "")))
            for row in rows
        }
        for repetition, rows in by_repetition.items()
    }
    expected = _normalized_signature(expected_target_signature, "expected target signature")
    if signatures[1] != signatures[2] or signatures[1] != expected:
        raise EvidenceError("target proportion repetitions do not contain the frozen targets")
    strata = tuple(required_strata)
    if not strata or len(set(strata)) != len(strata) or any(
        stratum not in REQUIRED_GATE_STRATA for stratum in strata
    ):
        raise EvidenceError("required_strata is invalid")
    result: dict[int, dict[str, float]] = {}
    for repetition in (1, 2):
        result[repetition] = {}
        for stratum in strata:
            selected = [
                row
                for row in by_repetition[repetition]
                if stratum == "overall" or row["language"] == stratum
            ]
            if not selected:
                raise EvidenceError(f"target proportion has no {stratum!r} stratum")
            result[repetition][stratum] = target_threshold_proportion(
                selected,
                value_field=value_field,
                threshold=threshold,
                comparison=comparison,
            )
    return result


def evaluate_interval_gate(
    summaries: Mapping[int, Mapping[str, Mapping[str, object]]],
    *,
    point_min: float | None = None,
    point_min_exclusive: float | None = None,
    point_max: float | None = None,
    lower_exclusive: float | None = None,
    upper_max: float | None = None,
    required_strata: Sequence[Literal["overall", "ko", "it", "en"]],
) -> dict[str, object]:
    """Apply one frozen rule to every repetition and language summary."""

    if set(summaries) != {1, 2}:
        raise EvidenceError("gate requires two independent repetitions")
    required = set(required_strata)
    if not required or any(set(summaries[repetition]) != required for repetition in (1, 2)):
        raise EvidenceError("gate summaries omit or add a required stratum")
    failures: list[dict[str, object]] = []
    for repetition in (1, 2):
        if not summaries[repetition]:
            raise EvidenceError("repetition summary must not be empty")
        for stratum, summary in summaries[repetition].items():
            point = _finite(summary.get("point"), "gate point")
            interval = summary.get("interval")
            if not isinstance(interval, Mapping):
                raise EvidenceError("gate interval is missing")
            reasons: list[str] = []
            if point_min is not None and point < point_min:
                reasons.append("point_below_minimum")
            if point_min_exclusive is not None and point <= point_min_exclusive:
                reasons.append("point_not_above_exclusive_minimum")
            if point_max is not None and point > point_max:
                reasons.append("point_above_maximum")
            if lower_exclusive is not None:
                lower = _finite(interval.get("lower"), "interval lower bound")
                if lower <= lower_exclusive:
                    reasons.append("lower_bound_not_exclusive")
            if upper_max is not None:
                upper = _finite(interval.get("upper"), "interval upper bound")
                if upper > upper_max:
                    reasons.append("upper_bound_above_maximum")
            if reasons:
                failures.append(
                    {"repetition": repetition, "stratum": stratum, "reasons": reasons}
                )
    return {
        "passed": not failures,
        "failures": failures,
        "whole_repetition_independent": True,
        "ambiguous": False,
        "ambiguity_reason": None,
    }


def evaluate_proportion_gate(
    proportions: Mapping[int, Mapping[str, float]],
    *,
    minimum: float,
    required_strata: Sequence[Literal["overall", "ko", "it", "en"]],
) -> dict[str, object]:
    """Require a frozen target proportion in every repetition and language cell."""

    if set(proportions) != {1, 2}:
        raise EvidenceError("proportion gate requires both repetitions")
    required = set(required_strata)
    failures: list[dict[str, object]] = []
    for repetition in (1, 2):
        if set(proportions[repetition]) != required:
            raise EvidenceError("proportion gate omits or adds a required stratum")
        for stratum, raw_value in proportions[repetition].items():
            value = _finite(raw_value, "target proportion")
            if value < 0 or value > 1:
                raise EvidenceError("target proportion must be between zero and one")
            if value < minimum:
                failures.append(
                    {"repetition": repetition, "stratum": stratum, "value": value}
                )
    return {
        "passed": not failures,
        "failures": failures,
        "whole_repetition_independent": True,
        "ambiguous": False,
        "ambiguity_reason": None,
    }


def s7b_noninferiority_gate(
    window_rows: Sequence[Mapping[str, object]],
    *,
    strata: Sequence[Literal["overall", "ko", "it", "en"]] = ("overall", "ko"),
    expected_cluster_signature: Iterable[tuple[str, str, str]],
) -> dict[str, object]:
    summaries = summarize_repetitions(
        window_rows,
        required_strata=strata,
        expected_cluster_signature=expected_cluster_signature,
    )
    return evaluate_interval_gate(
        summaries,
        point_min=0.0,
        lower_exclusive=-0.02,
        required_strata=strata,
    )


def legacy_overlap_penalty(mix_cer: float, single_cer: float) -> float:
    """Legacy full-reference diagnostic; never an overlap-recovery estimand."""

    return _nonnegative(mix_cer, "mix CER") - _nonnegative(single_cer, "single CER")
