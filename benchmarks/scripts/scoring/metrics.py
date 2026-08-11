from __future__ import annotations

from dataclasses import dataclass
import re
import unicodedata
from typing import Iterable, Literal, Sequence


@dataclass(frozen=True)
class EditCounts:
    substitutions: int
    deletions: int
    insertions: int
    reference_units: int

    @property
    def errors(self) -> int:
        return self.substitutions + self.deletions + self.insertions

    @property
    def error_rate(self) -> float | None:
        if self.reference_units == 0:
            return None
        return self.errors / self.reference_units

    def as_dict(self) -> dict[str, int | float | None]:
        return {
            "substitutions": self.substitutions,
            "deletions": self.deletions,
            "insertions": self.insertions,
            "reference_units": self.reference_units,
            "errors": self.errors,
            "error_rate": self.error_rate,
        }


def normalize_text(text: str, *, remove_spaces: bool = False) -> str:
    """Apply the normalization fixed by docs/contracts/scoring.md."""

    normalized = unicodedata.normalize("NFKC", text).casefold()
    normalized = "".join(
        "" if unicodedata.category(character).startswith("P") else character
        for character in normalized
    )
    normalized = " ".join(normalized.split())
    if remove_spaces:
        return "".join(normalized.split())
    return normalized


def _choose_edit(
    candidates: Iterable[tuple[int, int, int, int]],
) -> tuple[int, int, int, int]:
    # Minimize total errors. For equal totals, prefer a substitution over a
    # delete+insert representation, then fewer deletions, then insertions.
    return min(candidates, key=lambda value: (value[0], value[2] + value[3], value[2], value[3]))


def levenshtein_counts(reference: Sequence[str], hypothesis: Sequence[str]) -> EditCounts:
    """Return Levenshtein S/D/I counts with a deterministic tie break."""

    previous: list[tuple[int, int, int, int]] = [
        (index, 0, 0, index) for index in range(len(hypothesis) + 1)
    ]
    for ref_index, ref_unit in enumerate(reference, start=1):
        current: list[tuple[int, int, int, int]] = [(ref_index, 0, ref_index, 0)]
        for hyp_index, hyp_unit in enumerate(hypothesis, start=1):
            if ref_unit == hyp_unit:
                current.append(previous[hyp_index - 1])
                continue

            diagonal = previous[hyp_index - 1]
            deletion = previous[hyp_index]
            insertion = current[hyp_index - 1]
            current.append(
                _choose_edit(
                    (
                        (diagonal[0] + 1, diagonal[1] + 1, diagonal[2], diagonal[3]),
                        (deletion[0] + 1, deletion[1], deletion[2] + 1, deletion[3]),
                        (insertion[0] + 1, insertion[1], insertion[2], insertion[3] + 1),
                    )
                )
            )
        previous = current

    _, substitutions, deletions, insertions = previous[-1]
    return EditCounts(substitutions, deletions, insertions, len(reference))


def text_error_rate(
    reference: str,
    hypothesis: str,
    *,
    unit: Literal["word", "character"],
) -> EditCounts:
    if unit == "word":
        ref_units = normalize_text(reference).split()
        hyp_units = normalize_text(hypothesis).split()
    elif unit == "character":
        ref_units = list(normalize_text(reference, remove_spaces=True))
        hyp_units = list(normalize_text(hypothesis, remove_spaces=True))
    else:
        raise ValueError(f"unsupported unit: {unit}")
    return levenshtein_counts(ref_units, hyp_units)


def _contains_hangul(text: str) -> bool:
    return any(
        "HANGUL" in unicodedata.name(character, "")
        for character in text
    )


def _is_latin_alnum(character: str) -> bool:
    return character.isdigit() or (
        unicodedata.category(character).startswith("L")
        and "LATIN" in unicodedata.name(character, "")
    )


def count_term_occurrences(term: str, transcript: str) -> int:
    """Count non-overlapping exact normalized term occurrences."""

    if not term.strip():
        raise ValueError("term must not be empty")

    if _contains_hangul(term):
        normalized_term = "".join(unicodedata.normalize("NFKC", term).casefold().split())
        normalized_transcript = "".join(
            unicodedata.normalize("NFKC", transcript).casefold().split()
        )
        return len(re.findall(re.escape(normalized_term), normalized_transcript))

    normalized_term = unicodedata.normalize("NFKC", term).casefold().strip()
    normalized_transcript = unicodedata.normalize("NFKC", transcript).casefold()
    components = [component for component in re.split(r"[\s_-]+", normalized_term) if component]
    if not components:
        raise ValueError("term must contain a non-separator character")
    pattern = re.compile(r"[\s_-]*".join(re.escape(component) for component in components))
    count = 0
    for match in pattern.finditer(normalized_transcript):
        left = normalized_transcript[match.start() - 1] if match.start() else None
        right = normalized_transcript[match.end()] if match.end() < len(normalized_transcript) else None
        if left is not None and _is_latin_alnum(left):
            continue
        if right is not None and _is_latin_alnum(right):
            continue
        count += 1
    return count


def term_recall(
    terms: Sequence[dict[str, object]],
    hypothesis: str,
) -> dict[str, object]:
    details: list[dict[str, object]] = []
    reference_total = 0
    matched_total = 0
    for annotation in terms:
        term = str(annotation["term"])
        reference_count = int(annotation["reference_count"])
        if reference_count < 0:
            raise ValueError(f"negative reference_count for {term!r}")
        predicted_count = count_term_occurrences(term, hypothesis)
        matched_count = min(reference_count, predicted_count)
        reference_total += reference_count
        matched_total += matched_count
        details.append(
            {
                "term": term,
                "reference_count": reference_count,
                "predicted_count": predicted_count,
                "matched_count": matched_count,
            }
        )

    return {
        "matched_reference_occurrences": matched_total,
        "reference_occurrences": reference_total,
        "term_recall": matched_total / reference_total if reference_total else None,
        "terms": details,
    }


def _has_lexical_text(text: str) -> bool:
    return any(unicodedata.category(character)[0] in {"L", "N"} for character in text)


def utterance_omissions(
    reference_segments: Sequence[dict[str, object]],
    hypothesis_segments: Sequence[dict[str, object]],
    *,
    collar_s: float = 0.25,
) -> dict[str, int | float | None | list[int]]:
    omitted_indices: list[int] = []
    scorable = 0
    lexical_hypotheses = [
        segment
        for segment in hypothesis_segments
        if _has_lexical_text(str(segment.get("text", "")))
    ]
    for index, reference in enumerate(reference_segments):
        if reference.get("scorable", True) is False:
            continue
        scorable += 1
        start = max(0.0, float(reference["start_s"]) - collar_s)
        end = float(reference["end_s"]) + collar_s
        present = any(
            float(hypothesis["end_s"]) > start and float(hypothesis["start_s"]) < end
            for hypothesis in lexical_hypotheses
        )
        if not present:
            omitted_indices.append(index)

    omitted = len(omitted_indices)
    return {
        "omitted_utterances": omitted,
        "scorable_utterances": scorable,
        "omission_rate": omitted / scorable if scorable else None,
        "omitted_reference_indices": omitted_indices,
    }
