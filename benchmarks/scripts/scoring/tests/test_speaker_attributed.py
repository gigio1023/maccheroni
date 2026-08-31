from __future__ import annotations

from copy import deepcopy
from hashlib import sha256
import json
import unittest

from benchmarks.scripts.dicow.common import manifest as experiment_manifest
from benchmarks.scripts.dicow.tests import test_contract as contract_fixtures
from benchmarks.scripts.scoring.speaker_attributed import (
    BOOTSTRAP_RESAMPLES,
    BOOTSTRAP_SEED,
    EvidenceError,
    aggregate_target_character_hits,
    aggregate_two_target_windows,
    cluster_bootstrap_interval,
    compute_nonoverlap_preservation,
    compute_overlap_contrasts,
    compute_overlap_recovery_contrasts,
    compute_recall_swap_margin,
    compute_swap_margin,
    derive_frozen_mapping,
    deterministic_edit_path,
    diagnostic_best_permutation,
    evaluate_interval_gate,
    evaluate_proportion_gate,
    evaluate_target_character_preservation_gate,
    half_oracle_window_rows,
    legacy_overlap_penalty,
    regional_character_score,
    regional_reference_from_words,
    relative_recall_preservation,
    resolve_mapped_outputs,
    resolve_spurious_outputs,
    s7b_noninferiority_gate,
    score_target,
    score_empty_reference_diagnostic,
    summarize_repetitions,
    summarize_overlap_recovery_gain,
    summarize_target_proportions,
    swapped_provider_slots,
    stable_overlap_target_recall,
    summarize_target_character_preservation,
    target_character_preservation_interval,
    target_threshold_proportion,
    typed_absent_score,
    validate_arm_bindings,
    validate_frozen_mapping,
    _validate_arm_score_record,
)


SHA = "a" * 64
OTHER_SHA = "b" * 64


def mapping_for(overlaps: dict[str, dict[str, float]]):
    return derive_frozen_mapping(("ref-a", "ref-b"), overlaps, window_id="w1")


def reference(text: str, term: str) -> dict[str, object]:
    return {
        "text": text,
        "expected_terms": [{"term": term, "reference_count": 1}],
        "reference_regions": ["O"] * len(text.replace(" ", "")),
    }


def decoded(
    text: str,
    *,
    condition: str = "dicow-full-mix-community1",
    arm_kind: str = "full_window",
    mapping: dict[str, object] | None = None,
    target_id: str | None = None,
    repetition: int = 1,
) -> dict[str, object]:
    return {
        "text": text,
        "model": "dicow",
        "condition": condition,
        "arm_kind": arm_kind,
        "availability": {"status": "available", "reason": None},
        "termination": {"typed": True, "complete": True, "terminal_reason": "eos"},
        "window_id": mapping["window_id"] if mapping is not None else None,
        "mapping_sha256": mapping["mapping_sha256"] if mapping is not None else None,
        "target_id": target_id,
        "repetition": repetition,
    }


def arm(name: str, cer: float, **changes: object) -> dict[str, object]:
    regional = changes.get("regional")
    if regional is None:
        substitutions = int(round(cer * 10)) if 0 <= cer <= 1 else 0
        regional = overlap_regional(substitutions=substitutions)
    replay_score = score_target(
        regional["reference"],
        regional["hypothesis"],
        reference_regions=regional["reference_regions"],
    )
    value: dict[str, object] = {
        "arm_id": name,
        "window_id": "window-1",
        "fixture_family": "hike",
        "target_id": "target-a",
        "reference_id": "reference-a",
        "repetition": 1,
        "availability": {"status": "available", "reason": None},
        "model": "dicow",
        "condition": "dicow-mix-O-community1",
        "provider_assignment": "correct",
        "arm_kind": "crop",
        "cer": cer,
        "wer": replay_score["wer"],
        "cer_counts": replay_score["cer_counts"],
        "wer_counts": replay_score["wer_counts"],
        "term_recall": replay_score["term_recall"],
        "term_details": replay_score["term_details"],
        "absent_term_insertions": replay_score["absent_term_insertions"],
        "cross_speaker_insertions": replay_score["cross_speaker_insertions"],
        "normalized_text": replay_score["normalized_text"],
        "normalized_text_empty": replay_score["normalized_text_empty"],
        "termination": replay_score["termination"],
        "score_replay": replay_score["score_replay"],
        "score_replay_sha256": replay_score["score_replay_sha256"],
        "mapping_sha256": SHA,
        "utility_contract_sha256": SHA,
        "alignment_sha256": SHA,
        "region_labels_sha256": SHA,
        "audio_sha256": SHA,
        "activity_provider_sha256": SHA,
        "stno_sha256": SHA,
        "k_sha256": SHA,
        "k_frames_sha256": SHA,
        "regional": regional,
        "regional_edit_path_sha256": regional["regional_edit_path_sha256"],
        "stable_o_counts": replay_score["stable_o_counts"],
    }
    value.update(changes)
    if "regional_edit_path_sha256" not in changes:
        value["regional_edit_path_sha256"] = value["regional"][
            "regional_edit_path_sha256"
        ]
    return value


def overlap_regional(
    *,
    denominator: int = 10,
    substitutions: int = 0,
    deletions: int = 0,
    insertions: int = 0,
) -> dict[str, object]:
    valid_denominator = max(0, denominator)
    valid_substitutions = min(max(0, substitutions), valid_denominator)
    valid_deletions = min(
        max(0, deletions), valid_denominator - valid_substitutions
    )
    valid_insertions = max(0, insertions)
    reference_units = [chr(0x2500 + index) for index in range(valid_denominator)]
    hypothesis_units = [
        chr(0x2600 + index) if index < valid_substitutions else unit
        for index, unit in enumerate(reference_units)
        if not (
            valid_substitutions
            <= index
            < valid_substitutions + valid_deletions
        )
    ]
    hypothesis_units.extend(chr(0x2700 + index) for index in range(valid_insertions))
    result = regional_character_score(
        "".join(reference_units),
        "".join(hypothesis_units),
        ["O"] * valid_denominator,
    )
    if denominator <= 0 and denominator != valid_denominator:
        result["regional_denominators"]["O"] = denominator
    if substitutions + deletions > valid_denominator:
        result["regional_operation_counts"]["O"]["substitution"] = substitutions
        result["regional_operation_counts"]["O"]["deletion"] = deletions
    if insertions < 0:
        result["regional_operation_counts"]["O"]["insertion"] = insertions
    return result


def binding(value: dict[str, object]) -> dict[str, object]:
    fields = (
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
    return {
        **{field: value[field] for field in fields},
        "regional_edit_path_sha256": value["regional_edit_path_sha256"],
        "score_replay_sha256": value["score_replay_sha256"],
    }


def bootstrap_rows(*, repetitions: tuple[int, ...] = (1,), field: str = "value"):
    rows: list[dict[str, object]] = []
    values = {
        ("hike", "ko"): (0.10, 0.20),
        ("fleurs", "it"): (0.30, 0.40),
        ("fleurs", "en"): (0.50, 0.60),
    }
    for repetition in repetitions:
        for (family, language), pair in values.items():
            for index, value in enumerate(pair):
                rows.append(
                    {
                        "window_id": f"{family}-{language}-{index}",
                        "fixture_family": family,
                        "language": language,
                        "repetition": repetition,
                        field: value,
                    }
                )
    return rows


def cluster_signature(rows):
    return {
        (row["window_id"], row["fixture_family"], row["language"])
        for row in rows
        if row["repetition"] == 1
    }


def target_signature(rows):
    return {
        (row["window_id"], row["target_id"], row["language"])
        for row in rows
        if row["repetition"] == 1
    }


class MappingTests(unittest.TestCase):
    def test_zero_real_labels_produces_two_distinct_absent_slots(self) -> None:
        result = mapping_for({})
        self.assertEqual(result["real_label_count"], 0)
        self.assertTrue(result["diarizer_undercount"])
        self.assertEqual(
            [slot["absent_id"] for slot in result["slots"]],
            ["ABSENT:A", "ABSENT:B"],
        )

    def test_one_real_label_maps_to_maximum_overlap_reference(self) -> None:
        result = mapping_for({"speaker-z": {"ref-a": 3, "ref-b": 7}})
        slots = {slot["reference_id"]: slot for slot in result["slots"]}
        self.assertEqual(slots["ref-b"]["provider_label"], "speaker-z")
        self.assertEqual(slots["ref-a"]["provider_kind"], "ABSENT")

    def test_one_label_tie_breaks_by_lexical_reference_id(self) -> None:
        result = mapping_for({"speaker-z": {"ref-a": 4, "ref-b": 4}})
        slots = {slot["reference_id"]: slot for slot in result["slots"]}
        self.assertEqual(slots["ref-a"]["provider_label"], "speaker-z")

    def test_two_real_labels_choose_maximum_injective_assignment(self) -> None:
        result = mapping_for(
            {
                "speaker-a": {"ref-a": 1, "ref-b": 9},
                "speaker-b": {"ref-a": 8, "ref-b": 2},
            }
        )
        slots = {slot["reference_id"]: slot["provider_label"] for slot in result["slots"]}
        self.assertEqual(slots, {"ref-a": "speaker-b", "ref-b": "speaker-a"})
        self.assertFalse(result["diarizer_undercount"])

    def test_three_real_labels_seals_surplus_and_overcount(self) -> None:
        result = mapping_for(
            {
                "a": {"ref-a": 9, "ref-b": 0},
                "b": {"ref-a": 0, "ref-b": 8},
                "c": {"ref-a": 1, "ref-b": 1},
            }
        )
        self.assertEqual(result["surplus_labels"], ["c"])
        self.assertTrue(result["diarizer_overcount"])

    def test_mapping_rejects_unknown_reference_and_negative_overlap(self) -> None:
        with self.assertRaises(EvidenceError):
            mapping_for({"a": {"ref-c": 1}})
        with self.assertRaises(EvidenceError):
            mapping_for({"a": {"ref-a": -1}})

    def test_zero_activity_label_is_not_a_real_or_surplus_label(self) -> None:
        result = mapping_for({"silent": {"ref-a": 0, "ref-b": 0}})
        self.assertEqual(result["real_label_count"], 0)
        self.assertEqual(result["surplus_labels"], [])
        self.assertEqual(
            result["activity_matrix"],
            {"silent": {"ref-a": 0.0, "ref-b": 0.0}},
        )

    def test_equal_activity_mapping_reports_ambiguity(self) -> None:
        result = mapping_for(
            {"a": {"ref-a": 1, "ref-b": 1}, "b": {"ref-a": 1, "ref-b": 1}}
        )
        self.assertEqual(len(result["tie_chain"]), 2)
        resolved = resolve_mapped_outputs(
            result,
            {"ref-a": reference("alpha", "alpha"), "ref-b": reference("bravo", "bravo")},
            {
                "a": decoded("alpha", mapping=result, target_id="ref-a"),
                "b": decoded("bravo", mapping=result, target_id="ref-b"),
            },
            repetition=1,
        )
        self.assertTrue(resolved["ambiguous"])
        self.assertEqual(resolved["ambiguity_reason"], "equal_activity_objective")

    def test_swapping_moves_absent_provider_without_retagging_sentinel(self) -> None:
        result = mapping_for({"speaker": {"ref-a": 9, "ref-b": 0}})
        swapped = swapped_provider_slots(result)
        by_reference = {slot["reference_id"]: slot for slot in swapped}
        self.assertEqual(by_reference["ref-a"]["provider_kind"], "ABSENT")
        self.assertEqual(by_reference["ref-a"]["absent_id"], "ABSENT:B")
        self.assertEqual(by_reference["ref-b"]["provider_label"], "speaker")

    def test_mapping_replays_activity_hash_objective_and_transcript_independence(self) -> None:
        mapping = mapping_for(
            {
                "speaker-a": {"ref-a": 9, "ref-b": 0},
                "speaker-b": {"ref-a": 0, "ref-b": 8},
            }
        )
        for field, value, message in (
            ("mapping_sha256", OTHER_SHA, "activity-derived replay"),
            ("activity_matrix_sha256", OTHER_SHA, "activity_matrix_sha256"),
            ("transcript_conditioned", True, "transcript-independent"),
            ("objective_values", [999.0], "activity-derived replay"),
        ):
            with self.subTest(field=field):
                changed = deepcopy(mapping)
                changed[field] = value
                with self.assertRaisesRegex(EvidenceError, message):
                    validate_frozen_mapping(changed)


class TargetScoringTests(unittest.TestCase):
    def test_target_score_cer_wer_terms_and_insertions(self) -> None:
        result = score_target(
            "API pronto",
            "api pronto Qwen intruso",
            expected_terms=[{"term": "API", "reference_count": 1}],
            absent_terms=[{"term": "Qwen"}],
            other_target_terms=[{"term": "intruso"}],
        )
        self.assertEqual(result["term_recall"], 1.0)
        self.assertEqual(result["absent_term_insertions"], 1)
        self.assertEqual(result["cross_speaker_insertions"], 1)
        self.assertGreater(result["cer"], 0)
        self.assertGreater(result["wer"], 0)
        self.assertEqual(
            result["termination"],
            {"typed": True, "complete": True, "terminal_reason": "scoring_complete"},
        )
        self.assertEqual(
            result["score_replay"]["expected_terms"],
            [{"term": "api", "reference_count": 1}],
        )
        self.assertEqual(result["score_replay"]["absent_terms"], [{"term": "qwen"}])
        self.assertEqual(
            result["score_replay"]["other_target_terms"],
            [{"term": "intruso", "reference_count": 1}],
        )

    def test_score_replay_preserves_byte_exact_raw_hypothesis(self) -> None:
        raw_hypothesis = "  ＡＰＩ\tPronto  "
        result = score_target("API pronto", raw_hypothesis)
        self.assertEqual(result["score_replay"]["hypothesis"], raw_hypothesis)
        self.assertEqual(result["normalized_text"], "api pronto")

    def test_cross_speaker_terms_exclude_current_terms_and_duplicates(self) -> None:
        result = score_target(
            "API",
            "API API foreign",
            expected_terms=[{"term": "API", "reference_count": 1}],
            other_target_terms=[
                {"term": "API", "reference_count": 1},
                {"term": "foreign", "reference_count": 1},
                {"term": "FOREIGN", "reference_count": 1},
                {"term": "ignored", "reference_count": 0},
            ],
        )
        self.assertEqual(result["cross_speaker_insertions"], 1)

    def test_cross_speaker_insertions_are_not_generic_word_insertions(self) -> None:
        result = score_target(
            "hello",
            "hello foreign noise",
            other_target_terms=[{"term": "foreign", "reference_count": 1}],
        )
        self.assertEqual(result["cross_speaker_insertions"], 1)
        self.assertEqual(result["wer_counts"]["insertions"], 2)
        self.assertNotEqual(
            result["cross_speaker_insertions"], result["wer_counts"]["insertions"]
        )

    def test_target_score_emits_stable_overlap_recall_from_edit_path(self) -> None:
        substituted = score_target(
            "abc", "axc", reference_regions=["O", "O", "O"]
        )
        self.assertAlmostEqual(
            substituted["stable_overlap_target_recall"], 2 / 3
        )
        self.assertEqual(
            substituted["stable_o_counts"],
            {
                "reference_chars": 3,
                "substitutions": 1,
                "deletions": 0,
                "insertions": 0,
                "hits": 2,
                "regional_edit_path_sha256": substituted["regional"][
                    "regional_edit_path_sha256"
                ],
            },
        )
        inserted = score_target(
            "abc", "abxc", reference_regions=["O", "O", "O"]
        )
        self.assertEqual(inserted["stable_overlap_target_recall"], 1.0)
        self.assertGreater(inserted["regional"]["regional_errors"]["O"], 0)

    def test_target_score_requires_stable_overlap_characters_for_recall(self) -> None:
        with self.assertRaisesRegex(EvidenceError, "positive integer"):
            score_target("abc", "abc", reference_regions=["N", "N", "N"])

    def test_typed_absent_has_fixed_total_metrics_and_no_inference(self) -> None:
        result = typed_absent_score(
            "hello API",
            expected_terms=[{"term": "API", "reference_count": 1}],
        )
        self.assertEqual(result["cer"], 1.0)
        self.assertEqual(result["wer"], 1.0)
        self.assertEqual(result["term_recall"], 0.0)
        self.assertFalse(result["asr_invoked"])
        self.assertEqual(result["terminal_reason"], "diarizer_target_absent")

        overlap = typed_absent_score(
            "hello",
            reference_regions=["O", "O", "O", "O", "O"],
        )
        self.assertEqual(overlap["stable_overlap_target_recall"], 0.0)

    def test_typed_absent_rejects_empty_reference(self) -> None:
        with self.assertRaises(EvidenceError):
            typed_absent_score("")

    def test_resolver_keeps_both_targets_and_surplus_diagnostic(self) -> None:
        mapping = mapping_for(
            {
                "a": {"ref-a": 9, "ref-b": 0},
                "b": {"ref-a": 0, "ref-b": 8},
                "surplus": {"ref-a": 1, "ref-b": 1},
            }
        )
        result = resolve_mapped_outputs(
            mapping,
            {"ref-a": reference("hello", "hello"), "ref-b": reference("ciao", "ciao")},
            {
                "a": decoded("hello", mapping=mapping, target_id="ref-a"),
                "b": decoded("ciao", mapping=mapping, target_id="ref-b"),
                "surplus": decoded("noise words", condition="surplus-diagnostic", mapping=mapping, target_id="surplus"),
            },
            repetition=1,
        )
        self.assertEqual(result["target_count"], 2)
        self.assertEqual(result["dropped_targets"], 0)
        self.assertFalse(result["surplus_diagnostics"]["surplus"]["gate_eligible"])

    def test_resolver_synthesizes_absent_but_rejects_missing_real_or_surplus(self) -> None:
        one = mapping_for({"a": {"ref-a": 9, "ref-b": 0}})
        references = {
            "ref-a": reference("hello", "hello"),
            "ref-b": reference("ciao", "ciao"),
        }
        result = resolve_mapped_outputs(
            one,
            references,
            {"a": decoded("hello", mapping=one, target_id="ref-a")},
            repetition=1,
        )
        self.assertEqual(result["mapped_targets"]["ref-b"]["provider_kind"], "ABSENT")
        with self.assertRaises(EvidenceError):
            resolve_mapped_outputs(one, references, {}, repetition=1)

        three = mapping_for(
            {
                "a": {"ref-a": 9},
                "b": {"ref-b": 8},
                "c": {"ref-a": 1, "ref-b": 1},
            }
        )
        with self.assertRaisesRegex(EvidenceError, "missing"):
            resolve_mapped_outputs(
                three,
                references,
                {
                    "a": decoded("hello", mapping=three, target_id="ref-a"),
                    "b": decoded("ciao", mapping=three, target_id="ref-b"),
                },
                repetition=1,
            )

    def test_resolver_scores_absent_and_cross_speaker_insertions(self) -> None:
        mapping = mapping_for(
            {"a": {"ref-a": 9}, "b": {"ref-b": 9}}
        )
        references = {
            "ref-a": {
                **reference("hello", "hello"),
                "absent_terms": [{"term": "qwen"}],
            },
            "ref-b": reference("ciao", "ciao"),
        }
        result = resolve_mapped_outputs(
            mapping,
            references,
            {
                "a": decoded("hello qwen ciao", mapping=mapping, target_id="ref-a"),
                "b": decoded("ciao", mapping=mapping, target_id="ref-b"),
            },
            repetition=1,
        )
        target = result["mapped_targets"]["ref-a"]
        self.assertEqual(target["absent_term_insertions"], 1)
        self.assertEqual(target["cross_speaker_insertions"], 1)

    def test_resolver_rejects_malformed_absent_and_extra_outputs(self) -> None:
        mapping = mapping_for({})
        references = {
            "ref-a": reference("hello", "hello"),
            "ref-b": reference("ciao", "ciao"),
        }
        malformed = deepcopy(mapping)
        malformed["slots"][0]["asr_invoked"] = True
        with self.assertRaisesRegex(EvidenceError, "ABSENT"):
            resolve_mapped_outputs(malformed, references, {}, repetition=1)
        with self.assertRaisesRegex(EvidenceError, "extra"):
            resolve_mapped_outputs(
                mapping, references, {"unexpected": decoded("text")}, repetition=1
            )

    def test_resolved_absent_preserves_sentinel_and_mapping_ambiguity(self) -> None:
        mapping = mapping_for({})
        result = resolve_mapped_outputs(
            mapping,
            {"ref-a": reference("hello", "hello"), "ref-b": reference("ciao", "ciao")},
            {},
            repetition=1,
        )
        self.assertEqual(result["mapped_targets"]["ref-a"]["absent_id"], "ABSENT:A")
        self.assertEqual(result["mapped_targets"]["ref-b"]["absent_id"], "ABSENT:B")

    def test_surplus_and_spurious_require_full_window_typed_dicow_outputs(self) -> None:
        mapping = mapping_for({})
        target_id = mapping["spurious_target_id"]
        output = decoded(
            "", condition="dicow-full-spurious", mapping=mapping, target_id=target_id
        )
        spurious = resolve_spurious_outputs(
            [mapping], {target_id: output}, repetition=1
        )
        self.assertTrue(spurious[target_id]["normalized_text_empty"])
        with self.assertRaises(EvidenceError):
            resolve_spurious_outputs(
                [mapping],
                {
                    target_id: decoded(
                        "",
                        condition="dicow-full-spurious",
                        arm_kind="crop",
                        mapping=mapping,
                        target_id=target_id,
                    )
                },
                repetition=1,
            )
        bad = decoded(
            "", condition="dicow-full-spurious", mapping=mapping, target_id=target_id
        )
        bad["termination"]["complete"] = False
        with self.assertRaisesRegex(EvidenceError, "termination"):
            resolve_spurious_outputs([mapping], {target_id: bad}, repetition=1)
        for failure_reason in ("timeout", "error"):
            with self.subTest(spurious_terminal_reason=failure_reason):
                bad = decoded(
                    "",
                    condition="dicow-full-spurious",
                    mapping=mapping,
                    target_id=target_id,
                )
                bad["termination"]["terminal_reason"] = failure_reason
                with self.assertRaisesRegex(EvidenceError, "termination"):
                    resolve_spurious_outputs(
                        [mapping], {target_id: bad}, repetition=1
                    )

    def test_mapped_output_rejects_failed_terminal_reason(self) -> None:
        mapping = mapping_for(
            {
                "a": {"ref-a": 9, "ref-b": 0},
                "b": {"ref-a": 0, "ref-b": 9},
            }
        )
        references = {
            "ref-a": reference("hello", "hello"),
            "ref-b": reference("ciao", "ciao"),
        }
        outputs = {
            "a": decoded("hello", mapping=mapping, target_id="ref-a"),
            "b": decoded("ciao", mapping=mapping, target_id="ref-b"),
        }
        outputs["a"]["termination"]["terminal_reason"] = "timeout"
        with self.assertRaisesRegex(EvidenceError, "termination"):
            resolve_mapped_outputs(mapping, references, outputs, repetition=1)

    def test_best_permutation_is_diagnostic_only_and_cannot_rescue_swap(self) -> None:
        references = {"ref-a": "alpha", "ref-b": "bravo"}
        outputs = {"speaker-a": "bravo", "speaker-b": "alpha"}
        mapping = mapping_for(
            {
                "speaker-a": {"ref-a": 9, "ref-b": 0},
                "speaker-b": {"ref-a": 0, "ref-b": 9},
            }
        )
        diagnostic = diagnostic_best_permutation(
            references, outputs, mapping=mapping
        )
        self.assertEqual(diagnostic["mean_cer"], 0.0)
        self.assertFalse(diagnostic["gate_eligible"])
        frozen_a = score_target(references["ref-a"], outputs["speaker-a"])["cer"]
        frozen_b = score_target(references["ref-b"], outputs["speaker-b"])["cer"]
        self.assertGreater((frozen_a + frozen_b) / 2, 0.9)
        with self.assertRaisesRegex(EvidenceError, "frozen real labels"):
            diagnostic_best_permutation(
                references, {**outputs, mapping["spurious_target_id"]: "noise"}, mapping=mapping
            )

    def test_spurious_target_is_empty_reference_diagnostic_only(self) -> None:
        result = score_target("", "hallucinated")
        self.assertIsNone(result["cer"])
        self.assertIsNone(result["wer"])
        self.assertFalse(result["normalized_text_empty"])
        diagnostic = score_empty_reference_diagnostic("noise here", kind="spurious")
        self.assertIsNone(diagnostic["cer"])
        self.assertIsNone(diagnostic["wer"])
        self.assertIsNone(diagnostic["cer_counts"])
        self.assertIsNone(diagnostic["wer_counts"])
        self.assertIsNone(diagnostic["term_recall"])
        self.assertEqual(diagnostic["term_details"], [])
        self.assertEqual(diagnostic["absent_term_insertions"], 0)
        self.assertEqual(diagnostic["cross_speaker_insertions"], 0)
        self.assertIsNone(diagnostic["regional"])
        self.assertIsNone(diagnostic["stable_o_counts"])
        self.assertEqual(diagnostic["character_insertions"], 9)
        self.assertEqual(diagnostic["word_insertions"], 2)
        self.assertFalse(diagnostic["gate_eligible"])


class RegionalAttributionTests(unittest.TestCase):
    def test_tie_order_prefers_substitution(self) -> None:
        path = deterministic_edit_path(list("a"), list("b"), ["O"])
        self.assertEqual([operation.operation for operation in path], ["substitution"])

    def test_equal_cost_edit_path_reports_ambiguity(self) -> None:
        result = regional_character_score("aa", "a", ["O", "N"])
        self.assertTrue(result["ambiguous"])
        self.assertEqual(result["ambiguity_reason"], "equal_cost_edit_paths")

    def test_insertion_inherits_previous_or_next_reference_region(self) -> None:
        before = deterministic_edit_path(list("ab"), list("xab"), ["O", "N"])
        self.assertEqual(before[0].operation, "insertion")
        self.assertEqual(before[0].region, "O")
        after = deterministic_edit_path(list("ab"), list("axb"), ["O", "N"])
        insertion = next(op for op in after if op.operation == "insertion")
        self.assertEqual(insertion.region, "O")

    def test_regional_score_keeps_boundary_out_of_o_and_n(self) -> None:
        result = regional_character_score("abc", "axz", ["O", "N", "boundary"])
        self.assertEqual(result["regional_errors"], {"O": 0, "N": 1, "boundary": 1})
        self.assertEqual(result["regional_cer"]["O"], 0.0)
        self.assertEqual(result["regional_cer"]["N"], 1.0)
        self.assertEqual(result["cer"], 2 / 3)
        self.assertEqual(len(result["edit_path"]), 3)

    def test_nonpositive_regional_denominator_is_explicit_none(self) -> None:
        result = regional_character_score("ab", "ab", ["O", "O"])
        self.assertIsNone(result["regional_cer"]["N"])

    def test_region_shape_and_vocabulary_fail_closed(self) -> None:
        with self.assertRaises(EvidenceError):
            regional_character_score("ab", "ab", ["O"])
        with self.assertRaises(EvidenceError):
            regional_character_score("ab", "ab", ["O", "unknown"])

    def test_word_normalization_expansion_inherits_the_word_region(self) -> None:
        text, regions = regional_reference_from_words(
            [{"text": "ＡＰＩ", "region": "O"}, {"text": "caffè", "region": "N"}]
        )
        self.assertEqual(text, "api caffè")
        self.assertEqual(regions, ["O"] * 3 + ["N"] * 5)

    def test_self_consistent_nonminimal_path_is_rejected_by_input_replay(self) -> None:
        result = regional_character_score("a", "a", ["O"])
        result.update(
            {
                "cer": 2.0,
                "errors": 2,
                "substitutions": 0,
                "deletions": 1,
                "insertions": 1,
                "regional_errors": {"O": 2, "N": 0, "boundary": 0},
                "regional_operation_counts": {
                    "O": {"substitution": 0, "deletion": 1, "insertion": 1},
                    "N": {"substitution": 0, "deletion": 0, "insertion": 0},
                    "boundary": {"substitution": 0, "deletion": 0, "insertion": 0},
                },
                "regional_cer": {"O": 2.0, "N": None, "boundary": None},
                "edit_path": [
                    {
                        "operation": "deletion", "reference_index": 0,
                        "hypothesis_index": None, "reference_unit": "a",
                        "hypothesis_unit": None, "region": "O",
                        "equal_cost_operations": ["deletion"],
                    },
                    {
                        "operation": "insertion", "reference_index": None,
                        "hypothesis_index": 0, "reference_unit": None,
                        "hypothesis_unit": "a", "region": "O",
                        "equal_cost_operations": ["insertion"],
                    },
                ],
            }
        )
        result["regional_edit_path_sha256"] = sha256(
            json.dumps(
                result["edit_path"],
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
        ).hexdigest()
        with self.assertRaisesRegex(EvidenceError, "minimal-path replay"):
            stable_overlap_target_recall(result)


class ContrastTests(unittest.TestCase):
    def setUp(self) -> None:
        self.arms = {
            "turbo-clean-O": arm(
                "tc", 0.1, model="turbo", condition="turbo-clean-O",
                provider_assignment="not_applicable", activity_provider_sha256=None,
                stno_sha256=None,
            ),
            "turbo-mix-O": arm(
                "tm", 0.5, model="turbo", condition="turbo-mix-O",
                provider_assignment="not_applicable", activity_provider_sha256=None,
                stno_sha256=None,
            ),
            "dicow-clean-O": arm(
                "dc", 0.2, condition="dicow-clean-O",
                provider_assignment="not_applicable",
            ),
            "dicow-mix-O-oracle": arm(
                "dmo", 0.3, condition="dicow-mix-O-oracle"
            ),
            "dicow-mix-O-community1": arm("dmc", 0.4),
        }
        self.bindings = {name: binding(value) for name, value in self.arms.items()}

    def test_exact_stress_and_difference_in_differences_formulas(self) -> None:
        result = compute_overlap_contrasts(self.arms, self.bindings)
        self.assertAlmostEqual(result["D_turbo^O"], 0.4)
        self.assertAlmostEqual(result["D_dicow,oracle^O"], 0.1)
        self.assertAlmostEqual(result["D_dicow,community1^O"], 0.2)
        self.assertAlmostEqual(result["G_oracle^O"], 0.3)
        self.assertAlmostEqual(result["G_community1^O"], 0.2)

    def test_every_hash_binding_is_checked_before_contrast(self) -> None:
        for arm_name, field in (
            ("turbo-mix-O", "k_sha256"),
            ("turbo-mix-O", "k_frames_sha256"),
            ("turbo-mix-O", "audio_sha256"),
            ("dicow-mix-O-community1", "activity_provider_sha256"),
            ("dicow-mix-O-community1", "stno_sha256"),
        ):
            with self.subTest(arm=arm_name, field=field):
                changed = deepcopy(self.arms)
                changed[arm_name][field] = OTHER_SHA
                with self.assertRaisesRegex(EvidenceError, field):
                    compute_overlap_contrasts(changed, self.bindings)

    def test_overlap_contrasts_require_exact_condition_specific_roles(self) -> None:
        changed = deepcopy(self.arms)
        changed["dicow-mix-O-community1"]["provider_assignment"] = "swapped"
        with self.assertRaisesRegex(EvidenceError, "semantic role"):
            compute_overlap_contrasts(changed, self.bindings)
        changed = deepcopy(self.arms)
        changed["dicow-mix-O-oracle"]["activity_provider_sha256"] = None
        bindings = {name: binding(value) for name, value in changed.items()}
        with self.assertRaisesRegex(EvidenceError, "requires provider"):
            compute_overlap_contrasts(changed, bindings)
        changed = deepcopy(self.arms)
        changed["turbo-mix-O"]["stno_sha256"] = SHA
        bindings = {name: binding(value) for name, value in changed.items()}
        with self.assertRaisesRegex(EvidenceError, "must not carry"):
            compute_overlap_contrasts(changed, bindings)

    def test_individually_sealed_but_causally_unpaired_hashes_are_rejected(self) -> None:
        changed = deepcopy(self.arms)
        changed["dicow-mix-O-oracle"]["k_sha256"] = OTHER_SHA
        bindings = {name: binding(value) for name, value in changed.items()}
        with self.assertRaisesRegex(EvidenceError, "share k_sha256"):
            compute_overlap_contrasts(changed, bindings)
        changed = deepcopy(self.arms)
        changed["dicow-mix-O-community1"]["audio_sha256"] = OTHER_SHA
        bindings = {name: binding(value) for name, value in changed.items()}
        with self.assertRaisesRegex(EvidenceError, "mixture"):
            compute_overlap_contrasts(changed, bindings)
        for field, value in (
            ("window_id", "window-2"),
            ("fixture_family", "fleurs"),
            ("target_id", "target-b"),
            ("reference_id", "reference-b"),
            ("repetition", 2),
        ):
            with self.subTest(identity=field):
                changed = deepcopy(self.arms)
                changed["dicow-mix-O-community1"][field] = value
                with self.assertRaisesRegex(EvidenceError, f"share {field}"):
                    compute_overlap_contrasts(changed, self.bindings)

    def test_binding_requires_all_expected_fields(self) -> None:
        expected = binding(self.arms["turbo-clean-O"])
        del expected["audio_sha256"]
        with self.assertRaisesRegex(EvidenceError, "omits audio_sha256"):
            validate_arm_bindings(self.arms["turbo-clean-O"], expected)
        malformed = deepcopy(self.arms["turbo-clean-O"])
        malformed["audio_sha256"] = "short"
        expected = binding(malformed)
        with self.assertRaisesRegex(EvidenceError, "lowercase SHA-256"):
            validate_arm_bindings(malformed, expected)

    def test_unavailable_or_missing_arm_fails_closed(self) -> None:
        changed = deepcopy(self.arms)
        changed["turbo-mix-O"]["availability"] = "unavailable"
        with self.assertRaises(EvidenceError):
            compute_overlap_contrasts(changed, self.bindings)

    def test_cer_counts_and_successful_termination_are_replayed(self) -> None:
        changed = deepcopy(self.arms)
        changed["turbo-mix-O"]["cer"] += 0.01
        with self.assertRaisesRegex(EvidenceError, "arm cer differs"):
            compute_overlap_contrasts(changed, self.bindings)
        changed = deepcopy(self.arms)
        changed["turbo-mix-O"]["cer_counts"]["errors"] += 1
        with self.assertRaisesRegex(EvidenceError, "cer_counts"):
            compute_overlap_contrasts(changed, self.bindings)
        changed = deepcopy(self.arms)
        changed["turbo-mix-O"]["wer_counts"]["errors"] += 1
        with self.assertRaisesRegex(EvidenceError, "wer_counts"):
            compute_overlap_contrasts(changed, self.bindings)
        changed = deepcopy(self.arms)
        changed["turbo-mix-O"]["term_details"] = [
            {"term": "forged", "reference_count": 1, "predicted_count": 1,
             "matched_count": 1}
        ]
        with self.assertRaisesRegex(EvidenceError, "term_details"):
            compute_overlap_contrasts(changed, self.bindings)
        changed = deepcopy(self.arms)
        changed["turbo-mix-O"]["cross_speaker_insertions"] = 1
        with self.assertRaisesRegex(EvidenceError, "cross_speaker_insertions"):
            compute_overlap_contrasts(changed, self.bindings)
        changed = deepcopy(self.arms)
        changed["turbo-mix-O"]["score_replay"]["absent_terms"] = [
            {"term": "forged"}
        ]
        with self.assertRaisesRegex(EvidenceError, "score_replay|absent_term"):
            compute_overlap_contrasts(changed, self.bindings)
        changed = deepcopy(self.arms)
        changed["turbo-mix-O"]["termination"]["complete"] = False
        with self.assertRaisesRegex(EvidenceError, "successful termination"):
            compute_overlap_contrasts(changed, self.bindings)
        changed = deepcopy(self.arms)
        changed["turbo-mix-O"]["termination"]["terminal_reason"] = "invented"
        with self.assertRaisesRegex(EvidenceError, "successful termination"):
            compute_overlap_contrasts(changed, self.bindings)
        for failure_reason in ("timeout", "error"):
            with self.subTest(terminal_reason=failure_reason):
                changed = deepcopy(self.arms)
                changed["turbo-mix-O"]["termination"][
                    "terminal_reason"
                ] = failure_reason
                with self.assertRaisesRegex(EvidenceError, "successful termination"):
                    compute_overlap_contrasts(changed, self.bindings)
        changed = deepcopy(self.arms)
        changed["turbo-mix-O"]["termination"]["terminal_reason"] = "completed"
        self.assertIn("D_turbo^O", compute_overlap_contrasts(changed, self.bindings))
        del changed["turbo-mix-O"]
        with self.assertRaises(EvidenceError):
            compute_overlap_contrasts(changed, self.bindings)

    def test_nonoverlap_preservation_and_denominator_checks(self) -> None:
        def make_arm(name: str, n_substitutions: int, *, full: bool):
            reference_text = "abcde12345"
            hypothesis = list(reference_text)
            for index in range(n_substitutions):
                hypothesis[5 + index] = chr(ord("x") + index)
            regional = regional_character_score(
                reference_text,
                "".join(hypothesis),
                ["O"] * 5 + ["N"] * 5,
            )
            return arm(
                name,
                n_substitutions / 10,
                regional=regional,
                model="dicow",
                condition=(
                    "dicow-full-mix-community1"
                    if full
                    else "dicow-clean-single-utility"
                ),
                provider_assignment="correct" if full else "not_applicable",
                arm_kind="full_window",
            )

        full = make_arm("full", 2, full=True)
        clean = make_arm("clean", 1, full=False)
        self.assertAlmostEqual(
            compute_nonoverlap_preservation(full, clean, binding(full), binding(clean)),
            0.2,
        )
        full["n_reference_characters"] = 0
        with self.assertRaisesRegex(EvidenceError, "denominator differs"):
            compute_nonoverlap_preservation(full, clean, binding(full), binding(clean))
        full = make_arm("full", 2, full=True)
        clean = make_arm("clean", 1, full=False)
        full["n_cer"] = 0.0
        with self.assertRaisesRegex(EvidenceError, "N CER differs"):
            compute_nonoverlap_preservation(full, clean, binding(full), binding(clean))
        full = make_arm("full", 2, full=True)
        clean = make_arm("clean", 1, full=False)
        full["arm_kind"] = "crop"
        with self.assertRaisesRegex(EvidenceError, "semantic roles"):
            compute_nonoverlap_preservation(full, clean, binding(full), binding(clean))
        no_n = regional_character_score("abcde", "abcde", ["O"] * 5)
        full = arm(
            "full",
            0.0,
            regional=no_n,
            model="dicow",
            condition="dicow-full-mix-community1",
            provider_assignment="correct",
            arm_kind="full_window",
        )
        clean = make_arm("clean", 1, full=False)
        with self.assertRaisesRegex(EvidenceError, "stable-N denominator"):
            compute_nonoverlap_preservation(full, clean, binding(full), binding(clean))
        full = make_arm("full", 2, full=True)
        clean = make_arm("clean", 1, full=False)
        clean["region_labels_sha256"] = OTHER_SHA
        with self.assertRaisesRegex(EvidenceError, "share region_labels_sha256"):
            compute_nonoverlap_preservation(full, clean, binding(full), binding(clean))
        for field, value in (
            ("window_id", "window-2"),
            ("fixture_family", "fleurs"),
            ("target_id", "target-b"),
            ("reference_id", "reference-b"),
            ("repetition", 2),
        ):
            with self.subTest(nonoverlap_identity=field):
                full = make_arm("full", 2, full=True)
                clean = make_arm("clean", 1, full=False)
                clean[field] = value
                with self.assertRaisesRegex(EvidenceError, f"share {field}"):
                    compute_nonoverlap_preservation(
                        full, clean, binding(full), binding(clean)
                    )

    def test_no_glossary_absent_row_replays_numeric_undercount(self) -> None:
        absent = typed_absent_score(
            "hello",
            reference_regions=["O"] * 5,
        )
        expected = {"score_replay_sha256": absent["score_replay_sha256"]}
        _validate_arm_score_record(absent, expected)
        self.assertEqual(absent["cer"], 1.0)
        self.assertEqual(absent["wer"], 1.0)
        self.assertEqual(absent["term_recall"], 0.0)
        forged = deepcopy(absent)
        forged["score_replay"]["hypothesis"] = "invented"
        forged["score_replay_sha256"] = sha256(
            json.dumps(
                forged["score_replay"],
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
        ).hexdigest()
        with self.assertRaisesRegex(EvidenceError, "sealed replay|ABSENT replay"):
            _validate_arm_score_record(
                forged, {"score_replay_sha256": forged["score_replay_sha256"]}
            )

    def test_swap_margin_keeps_shared_evidence_but_allows_recomputed_stno(self) -> None:
        correct = arm("correct", 0.1)
        swapped = arm(
            "swapped", 0.4, stno_sha256=OTHER_SHA,
            provider_assignment="swapped",
        )
        self.assertAlmostEqual(
            compute_swap_margin(correct, swapped, binding(correct), binding(swapped)), 0.3
        )
        swapped["audio_sha256"] = OTHER_SHA
        expected = binding(swapped)
        with self.assertRaisesRegex(EvidenceError, "share audio_sha256"):
            compute_swap_margin(correct, swapped, binding(correct), expected)
        for field, value in (
            ("window_id", "window-2"),
            ("fixture_family", "fleurs"),
            ("target_id", "target-b"),
            ("reference_id", "reference-b"),
            ("repetition", 2),
        ):
            with self.subTest(swap_identity=field):
                swapped = arm(
                    "swapped", 0.4, stno_sha256=OTHER_SHA,
                    provider_assignment="swapped",
                )
                swapped[field] = value
                with self.assertRaisesRegex(EvidenceError, f"share {field}"):
                    compute_swap_margin(
                        correct, swapped, binding(correct), binding(swapped)
                    )
        for field in (
            "activity_provider_sha256",
            "stno_sha256",
            "k_sha256",
            "k_frames_sha256",
        ):
            with self.subTest(missing_swap_binding=field):
                missing = arm("missing", 0.4, provider_assignment="swapped")
                missing[field] = None
                expected = binding(missing)
                with self.assertRaisesRegex(EvidenceError, "share|STNO"):
                    compute_swap_margin(correct, missing, binding(correct), expected)

    def test_legacy_overlap_penalty_is_signed(self) -> None:
        self.assertAlmostEqual(legacy_overlap_penalty(0.3, 0.1), 0.2)


class RecoveryValueTests(unittest.TestCase):
    def setUp(self) -> None:
        self.arms = {
            "turbo-clean-O": arm(
                "tc", 0.0, regional=overlap_regional(), model="turbo",
                condition="turbo-clean-O", provider_assignment="not_applicable",
                activity_provider_sha256=None, stno_sha256=None,
            ),
            "turbo-mix-O": arm(
                "tm", 2.6, regional=overlap_regional(substitutions=4, deletions=2, insertions=20),
                model="turbo", condition="turbo-mix-O",
                provider_assignment="not_applicable", activity_provider_sha256=None,
                stno_sha256=None,
            ),
            "dicow-clean-O": arm(
                "dc", 0.2, regional=overlap_regional(substitutions=2),
                condition="dicow-clean-O", provider_assignment="not_applicable",
            ),
            "dicow-mix-O-oracle": arm(
                "dmo", 0.3, regional=overlap_regional(substitutions=3),
                condition="dicow-mix-O-oracle",
            ),
            "dicow-mix-O-community1": arm(
                "dmc", 0.4, regional=overlap_regional(substitutions=4)
            ),
        }
        self.bindings = {name: binding(value) for name, value in self.arms.items()}

    def test_stable_overlap_recall_ignores_insertions(self) -> None:
        self.assertEqual(
            stable_overlap_target_recall(overlap_regional(insertions=100)), 1.0
        )
        self.assertEqual(
            stable_overlap_target_recall(
                overlap_regional(substitutions=2, deletions=3, insertions=100)
            ),
            0.5,
        )

    def test_recovery_gain_uses_recall_changes_not_cer_above_one(self) -> None:
        result = compute_overlap_recovery_contrasts(self.arms, self.bindings)
        self.assertEqual(result["R_turbo_clean^O"], 1.0)
        self.assertAlmostEqual(result["R_turbo_mix^O"], 0.4)
        self.assertAlmostEqual(result["R_dicow_clean^O"], 0.8)
        self.assertAlmostEqual(result["R_dicow_mix,oracle^O"], 0.7)
        self.assertAlmostEqual(result["R_dicow_mix,community1^O"], 0.6)
        self.assertAlmostEqual(result["G_R_oracle^O"], 0.5)
        self.assertAlmostEqual(result["G_R_community1^O"], 0.4)
        self.assertAlmostEqual(result["relative_preservation_oracle"]["value"], 0.875)
        self.assertAlmostEqual(
            result["relative_preservation_community1"]["value"], 0.75
        )
        self.assertEqual(
            result["target_character_preservation_oracle"]["clean_hit_characters"],
            8,
        )
        self.assertEqual(
            result["target_character_preservation_oracle"]["mix_hit_characters"],
            7,
        )

    def test_relative_preservation_has_typed_nonpositive_denominator(self) -> None:
        result = relative_recall_preservation(0.0, 0.0)
        self.assertEqual(
            result["availability"],
            {
                "status": "unavailable",
                "reason": "nonpositive_clean_stable_overlap_recall",
            },
        )
        self.assertIsNone(result["value"])
        with self.assertRaises(EvidenceError):
            relative_recall_preservation(1.1, 0.5)

    def test_recall_swap_margin_reuses_exact_identity_binding(self) -> None:
        for provider in ("oracle", "community1"):
            with self.subTest(provider=provider):
                correct = arm(
                    f"correct-{provider}",
                    0.2,
                    condition=f"dicow-mix-O-{provider}",
                    regional=overlap_regional(substitutions=2),
                )
                swapped = arm(
                    f"swapped-{provider}",
                    0.8,
                    stno_sha256=OTHER_SHA,
                    condition=f"dicow-mix-O-{provider}",
                    provider_assignment="swapped",
                    regional=overlap_regional(substitutions=8),
                )
                self.assertAlmostEqual(
                    compute_recall_swap_margin(
                        correct, swapped, binding(correct), binding(swapped)
                    ),
                    0.6,
                )
        for field, value in (
            ("window_id", "window-2"),
            ("fixture_family", "fleurs"),
            ("target_id", "other-target"),
            ("reference_id", "other-reference"),
            ("repetition", 2),
        ):
            with self.subTest(identity=field):
                correct = arm(
                    "correct", 0.2, regional=overlap_regional(substitutions=2)
                )
                swapped = arm(
                    "swapped",
                    0.8,
                    stno_sha256=OTHER_SHA,
                    provider_assignment="swapped",
                    regional=overlap_regional(substitutions=8),
                )
                swapped[field] = value
                with self.assertRaisesRegex(EvidenceError, f"share {field}"):
                    compute_recall_swap_margin(
                        correct, swapped, binding(correct), binding(swapped)
                    )

    def test_recovery_gain_rejects_every_cross_arm_identity_mismatch(self) -> None:
        for field, value in (
            ("window_id", "window-2"),
            ("fixture_family", "fleurs"),
            ("target_id", "target-b"),
            ("reference_id", "reference-b"),
            ("repetition", 2),
        ):
            with self.subTest(identity=field):
                changed = deepcopy(self.arms)
                changed["dicow-mix-O-community1"][field] = value
                with self.assertRaisesRegex(EvidenceError, f"share {field}"):
                    compute_overlap_recovery_contrasts(changed, self.bindings)

    def test_recovery_rejects_legacy_string_availability(self) -> None:
        changed = deepcopy(self.arms)
        changed["turbo-mix-O"]["availability"] = "available"
        with self.assertRaisesRegex(EvidenceError, "unavailable"):
            compute_overlap_recovery_contrasts(changed, self.bindings)
        changed = deepcopy(self.arms)
        changed["turbo-mix-O"]["availability"]["extra"] = "not-in-schema"
        with self.assertRaisesRegex(EvidenceError, "unavailable"):
            compute_overlap_recovery_contrasts(changed, self.bindings)

    def test_invalid_stable_overlap_denominator_and_counts_fail_closed(self) -> None:
        with self.assertRaisesRegex(EvidenceError, "positive integer"):
            stable_overlap_target_recall(overlap_regional(denominator=0))
        with self.assertRaisesRegex(EvidenceError, "minimal-path replay"):
            stable_overlap_target_recall(
                overlap_regional(denominator=2, substitutions=2, deletions=1)
            )
        malformed = overlap_regional()
        malformed["regional_operation_counts"]["O"]["insertion"] = -1
        with self.assertRaisesRegex(EvidenceError, "minimal-path replay"):
            stable_overlap_target_recall(malformed)

    def test_recovery_requires_sealed_arithmetically_consistent_edit_path(self) -> None:
        changed = deepcopy(self.arms)
        regional = changed["dicow-mix-O-oracle"]["regional"]
        regional["edit_path"][0]["operation"] = "deletion"
        with self.assertRaisesRegex(EvidenceError, "deterministic score replay|hash"):
            compute_overlap_recovery_contrasts(changed, self.bindings)
        changed = deepcopy(self.arms)
        changed["dicow-mix-O-oracle"]["regional_edit_path_sha256"] = OTHER_SHA
        with self.assertRaisesRegex(EvidenceError, "sealed evidence"):
            compute_overlap_recovery_contrasts(changed, self.bindings)
        changed = deepcopy(self.arms)
        changed["dicow-mix-O-oracle"]["stable_o_counts"]["hits"] += 1
        with self.assertRaisesRegex(EvidenceError, "stable_o_counts"):
            compute_overlap_recovery_contrasts(changed, self.bindings)

    def test_recovery_gain_aggregates_two_targets_then_bootstraps_all_strata(self) -> None:
        target_rows = []
        expected_targets: dict[str, tuple[str, str]] = {}
        window_values = bootstrap_rows(repetitions=(1, 2))
        for row in window_values:
            window_id = row["window_id"]
            targets = (f"{window_id}-a", f"{window_id}-b")
            expected_targets[window_id] = targets
            for target_id, offset in zip(targets, (-0.01, 0.01), strict=True):
                target_rows.append(
                    {
                        "window_id": window_id,
                        "fixture_family": row["fixture_family"],
                        "language": row["language"],
                        "repetition": row["repetition"],
                        "target_id": target_id,
                        "G_R_oracle^O": row["value"] + offset,
                        "G_R_community1^O": row["value"] + offset / 2,
                    }
                )
        expected_clusters = cluster_signature(window_values)
        for provider in ("oracle", "community1"):
            with self.subTest(provider=provider):
                summary = summarize_overlap_recovery_gain(
                    target_rows,
                    provider=provider,
                    expected_targets_by_window=expected_targets,
                    expected_cluster_signature=expected_clusters,
                )
                self.assertEqual(set(summary), {1, 2})
                self.assertEqual(
                    set(summary[1]), {"overall", "ko", "it", "en"}
                )
                self.assertEqual(summary[1]["overall"]["resamples"], 10_000)


class TargetCharacterPreservationTests(unittest.TestCase):
    @staticmethod
    def record(
        provider: str,
        *,
        reference: int,
        clean: int,
        mix: int,
        assignment: str = "correct",
    ) -> dict[str, object]:
        return {
            "condition": f"dicow-mix-O-{provider}",
            "provider_assignment": assignment,
            "stable_o_reference_characters": reference,
            "clean_hit_characters": clean,
            "mix_hit_characters": mix,
        }

    def test_asymmetric_targets_are_character_weighted_not_macro_averaged(self) -> None:
        rows = []
        expected = {}
        for window_id in ("w1", "w2"):
            expected[window_id] = (f"{window_id}-a", f"{window_id}-b")
            rows.extend(
                [
                    {
                        "window_id": window_id,
                        "fixture_family": "hike",
                        "language": "ko",
                        "repetition": 1,
                        "target_id": f"{window_id}-a",
                        "target_slot": "A",
                        "target_character_preservation_oracle": self.record(
                            "oracle", reference=100, clean=100, mix=50
                        ),
                    },
                    {
                        "window_id": window_id,
                        "fixture_family": "hike",
                        "language": "ko",
                        "repetition": 1,
                        "target_id": f"{window_id}-b",
                        "target_slot": "B",
                        "target_character_preservation_oracle": self.record(
                            "oracle", reference=1, clean=1, mix=1
                        ),
                    },
                ]
            )
        windows = aggregate_target_character_hits(
            rows, provider="oracle", expected_targets_by_window=expected
        )
        result = target_character_preservation_interval(windows, stratum="ko")
        self.assertAlmostEqual(result["point"], 102 / 202)
        self.assertNotAlmostEqual(result["point"], (0.5 + 1.0) / 2)

    def test_swapped_assignment_and_missing_target_direction_are_rejected(self) -> None:
        expected = {"w": ("a", "b")}
        rows = [
            {
                "window_id": "w", "fixture_family": "hike", "language": "ko",
                "repetition": 1, "target_id": target, "target_slot": slot,
                "target_character_preservation_community1": self.record(
                    "community1", reference=10, clean=10, mix=8,
                    assignment="swapped" if slot == "B" else "correct",
                ),
            }
            for target, slot in (("a", "A"), ("b", "B"))
        ]
        with self.assertRaisesRegex(EvidenceError, "correct provider assignment"):
            aggregate_target_character_hits(
                rows, provider="community1", expected_targets_by_window=expected
            )
        rows[1]["target_character_preservation_community1"][
            "provider_assignment"
        ] = "correct"
        rows[1]["target_slot"] = "A"
        with self.assertRaisesRegex(EvidenceError, "correct A/B"):
            aggregate_target_character_hits(
                rows, provider="community1", expected_targets_by_window=expected
            )
        rows[0]["target_slot"] = "B"
        with self.assertRaisesRegex(EvidenceError, "frozen A/B slots"):
            aggregate_target_character_hits(
                rows, provider="community1", expected_targets_by_window=expected
            )

    def test_zero_clean_denominators_are_conservative_or_blocking(self) -> None:
        partial = [
            {
                "window_id": "w0", "fixture_family": "hike", "language": "ko",
                "repetition": 1, "clean_hit_characters": 0, "mix_hit_characters": 0,
            },
            {
                "window_id": "w1", "fixture_family": "hike", "language": "ko",
                "repetition": 1, "clean_hit_characters": 10, "mix_hit_characters": 10,
            },
        ]
        result = target_character_preservation_interval(partial, stratum="ko")
        self.assertGreater(result["zero_denominator_resamples"], 0)
        self.assertEqual(result["interval"]["lower"], 0.0)
        blocked = deepcopy(partial)
        blocked[1]["clean_hit_characters"] = 0
        blocked[1]["mix_hit_characters"] = 0
        with self.assertRaisesRegex(EvidenceError, "zero_clean_hit_denominator"):
            target_character_preservation_interval(blocked, stratum="ko")

    def test_preservation_reuses_exact_mean_bootstrap_indices(self) -> None:
        mean_rows = bootstrap_rows()
        ratio_rows = [
            {
                **{key: row[key] for key in (
                    "window_id", "fixture_family", "language", "repetition"
                )},
                "clean_hit_characters": 100,
                "mix_hit_characters": int(row["value"] * 100),
            }
            for row in mean_rows
        ]
        mean = cluster_bootstrap_interval(mean_rows)
        ratio = target_character_preservation_interval(ratio_rows)
        self.assertAlmostEqual(ratio["point"], mean["point"])
        self.assertEqual(ratio["interval"]["kind"], mean["interval"]["kind"])
        self.assertAlmostEqual(
            ratio["interval"]["lower"], mean["interval"]["lower"]
        )
        self.assertAlmostEqual(
            ratio["interval"]["upper"], mean["interval"]["upper"]
        )

    def test_two_repetitions_and_all_language_strata_are_required(self) -> None:
        rows = []
        expected_targets = {}
        source = bootstrap_rows(repetitions=(1, 2))
        for row in source:
            window_id = row["window_id"]
            expected_targets[window_id] = (
                f"{window_id}-a", f"{window_id}-b"
            )
            for target_id, slot in zip(
                expected_targets[window_id], ("A", "B"), strict=True
            ):
                rows.append(
                    {
                        "window_id": window_id,
                        "fixture_family": row["fixture_family"],
                        "language": row["language"],
                        "repetition": row["repetition"],
                        "target_id": target_id,
                        "target_slot": slot,
                        "target_character_preservation_oracle": self.record(
                            "oracle", reference=10, clean=10, mix=8
                        ),
                        "target_character_preservation_community1": self.record(
                            "community1", reference=10, clean=10, mix=8
                        ),
                    }
                )
        for provider in ("oracle", "community1"):
            with self.subTest(provider=provider):
                summary = summarize_target_character_preservation(
                    rows,
                    provider=provider,
                    expected_targets_by_window=expected_targets,
                    expected_cluster_signature=cluster_signature(source),
                )
                self.assertEqual(set(summary), {1, 2})
                self.assertEqual(set(summary[1]), {"overall", "ko", "it", "en"})
                self.assertEqual(summary[1]["ko"]["point"], 0.8)
                self.assertEqual(summary[1]["ko"]["resamples"], 10_000)

    def test_inclusive_point_seven_five_gate_boundary(self) -> None:
        def summaries(
            lower: float, *, point: float = 0.8
        ) -> dict[int, dict[str, dict[str, object]]]:
            return {
                repetition: {
                    stratum: {
                        "point": point,
                        "interval": {
                            "kind": "two_sided_95_percentile",
                            "lower": lower,
                            "upper": 1.0,
                        },
                        "seed": BOOTSTRAP_SEED,
                        "resamples": BOOTSTRAP_RESAMPLES,
                        "percentile_method": "nearest_rank",
                        "weighting": "pooled_stable_o_hit_characters",
                    }
                    for stratum in ("overall", "ko", "it", "en")
                }
                for repetition in (1, 2)
            }

        self.assertFalse(
            evaluate_target_character_preservation_gate(summaries(0.7499))["passed"]
        )
        self.assertTrue(
            evaluate_target_character_preservation_gate(summaries(0.75))["passed"]
        )
        self.assertTrue(
            evaluate_target_character_preservation_gate(summaries(0.7501))["passed"]
        )
        self.assertFalse(
            evaluate_target_character_preservation_gate(
                summaries(0.8, point=0.7499)
            )["passed"]
        )
        self.assertTrue(
            evaluate_target_character_preservation_gate(
                summaries(0.8, point=0.75)
            )["passed"]
        )
        self.assertTrue(
            evaluate_target_character_preservation_gate(
                summaries(0.8, point=0.7501)
            )["passed"]
        )
        rep2_low = summaries(0.8)
        rep2_low[2]["en"]["interval"]["lower"] = 0.7499
        result = evaluate_target_character_preservation_gate(rep2_low)
        self.assertFalse(result["passed"])
        self.assertEqual(result["failures"], [{
            "repetition": 2, "stratum": "en", "point": 0.8,
            "lower": 0.7499, "required_min": 0.75,
        }])


class AggregationAndIntervalTests(unittest.TestCase):
    def test_two_targets_are_averaged_before_window_aggregation(self) -> None:
        rows = [
            {"window_id": "w", "fixture_family": "f", "language": "ko", "repetition": 1, "target_id": "a", "gain": 0.2},
            {"window_id": "w", "fixture_family": "f", "language": "ko", "repetition": 1, "target_id": "b", "gain": 0.6},
        ]
        result = aggregate_two_target_windows(rows, "gain")
        self.assertEqual(result[0]["value"], 0.4)

    def test_target_or_window_cannot_be_dropped(self) -> None:
        one = [{"window_id": "w", "fixture_family": "f", "language": "ko", "repetition": 1, "target_id": "a", "gain": 0.2}]
        with self.assertRaisesRegex(EvidenceError, "exactly two"):
            aggregate_two_target_windows(one, "gain")
        duplicate = one + [dict(one[0])]
        with self.assertRaisesRegex(EvidenceError, "exactly two"):
            aggregate_two_target_windows(duplicate, "gain")
        complete = [
            {"window_id": "w", "fixture_family": "f", "language": "ko", "repetition": 1, "target_id": "a", "gain": 0.2},
            {"window_id": "w", "fixture_family": "f", "language": "ko", "repetition": 1, "target_id": "b", "gain": 0.6},
        ]
        with self.assertRaisesRegex(EvidenceError, "dropped"):
            aggregate_two_target_windows(
                complete,
                "gain",
                expected_targets_by_window={"w": ("a", "b"), "missing": ("c", "d")},
            )

    def test_half_oracle_margin_is_paired_at_window_level(self) -> None:
        rows = []
        for target, oracle, community in (("a", 0.4, 0.3), ("b", 0.2, 0.2)):
            rows.append(
                {
                    "window_id": "w", "fixture_family": "f", "language": "ko",
                    "repetition": 1, "target_id": target,
                    "G_oracle^O": oracle, "G_community1^O": community,
                }
            )
        result = half_oracle_window_rows(rows)
        self.assertAlmostEqual(result[0]["value"], 0.1)

    def test_bootstrap_is_frozen_reproducible_and_stratified(self) -> None:
        rows = bootstrap_rows()
        first = cluster_bootstrap_interval(rows)
        second = cluster_bootstrap_interval(rows)
        self.assertEqual(first, second)
        self.assertAlmostEqual(first["point"], 0.35)
        self.assertEqual(first["seed"], BOOTSTRAP_SEED)
        self.assertEqual(first["resamples"], BOOTSTRAP_RESAMPLES)
        self.assertEqual(first["cluster_count"], 6)
        self.assertEqual(first["stratify_by"], ["fixture_family", "language"])
        self.assertEqual(first["percentile_method"], "nearest_rank")
        self.assertAlmostEqual(first["interval"]["lower"], 0.31666666666666665)
        self.assertAlmostEqual(first["interval"]["upper"], 0.3833333333333333)
        self.assertEqual(first, cluster_bootstrap_interval(list(reversed(rows))))

    def test_one_sided_nonoverlap_upper_interval(self) -> None:
        result = cluster_bootstrap_interval(bootstrap_rows(), one_sided_upper=True)
        self.assertEqual(result["interval"]["kind"], "one_sided_upper_95_percentile")
        self.assertAlmostEqual(result["interval"]["upper"], 0.3833333333333333)
        self.assertNotIn("lower", result["interval"])

    def test_language_stratum_is_not_silently_removed(self) -> None:
        result = cluster_bootstrap_interval(bootstrap_rows(), stratum="ko")
        self.assertEqual(result["cluster_count"], 2)
        self.assertAlmostEqual(result["point"], 0.15)
        with self.assertRaisesRegex(EvidenceError, "no clusters"):
            cluster_bootstrap_interval(
                [row for row in bootstrap_rows() if row["language"] != "ko"],
                stratum="ko",
            )

    def test_missing_or_degenerate_cluster_is_evidence_error(self) -> None:
        rows = bootstrap_rows()
        rows = [row for row in rows if row["window_id"] != "hike-ko-1"]
        with self.assertRaisesRegex(EvidenceError, "two clusters"):
            cluster_bootstrap_interval(rows)
        duplicate = bootstrap_rows() + [dict(bootstrap_rows()[0])]
        with self.assertRaisesRegex(EvidenceError, "unique"):
            cluster_bootstrap_interval(duplicate)

    def test_frozen_bootstrap_parameters_cannot_change(self) -> None:
        with self.assertRaisesRegex(EvidenceError, "frozen"):
            cluster_bootstrap_interval(bootstrap_rows(), resamples=9999)
        with self.assertRaisesRegex(EvidenceError, "frozen"):
            cluster_bootstrap_interval(bootstrap_rows(), seed=1)

    def test_repetitions_are_independent_and_require_same_clusters(self) -> None:
        rows = bootstrap_rows(repetitions=(1, 2))
        expected = cluster_signature(rows)
        result = summarize_repetitions(
            rows,
            required_strata=("overall", "ko"),
            expected_cluster_signature=expected,
        )
        self.assertEqual(set(result), {1, 2})
        changed = [row for row in rows if not (row["repetition"] == 2 and row["window_id"] == "hike-ko-1")]
        with self.assertRaisesRegex(EvidenceError, "complete frozen clusters"):
            summarize_repetitions(
                changed,
                required_strata=("overall",),
                expected_cluster_signature=expected,
            )
        with self.assertRaisesRegex(EvidenceError, "both"):
            summarize_repetitions(
                bootstrap_rows(),
                required_strata=("overall",),
                expected_cluster_signature=expected,
            )
        reduced_both = [row for row in rows if row["window_id"] != "hike-ko-1"]
        with self.assertRaisesRegex(EvidenceError, "complete frozen clusters"):
            summarize_repetitions(
                reduced_both,
                required_strata=("overall",),
                expected_cluster_signature=expected,
            )

    def test_gate_requires_every_repetition_and_stratum(self) -> None:
        summaries = summarize_repetitions(
            bootstrap_rows(repetitions=(1, 2)),
            required_strata=("overall", "ko", "it", "en"),
            expected_cluster_signature=cluster_signature(bootstrap_rows(repetitions=(1, 2))),
        )
        result = evaluate_interval_gate(
            summaries,
            point_min=0.1,
            lower_exclusive=0,
            required_strata=("overall", "ko", "it", "en"),
        )
        self.assertTrue(result["passed"])
        failing = deepcopy(summaries)
        failing[2]["it"]["point"] = -1
        result = evaluate_interval_gate(
            failing,
            point_min=0.1,
            lower_exclusive=0,
            required_strata=("overall", "ko", "it", "en"),
        )
        self.assertFalse(result["passed"])
        self.assertEqual(result["failures"][0]["repetition"], 2)
        self.assertEqual(result["failures"][0]["stratum"], "it")

    def test_s7b_margin_uses_point_zero_and_strict_lower_minus_point_zero_two(self) -> None:
        rows = bootstrap_rows(repetitions=(1, 2))
        expected = cluster_signature(rows)
        result = s7b_noninferiority_gate(rows, expected_cluster_signature=expected)
        self.assertTrue(result["passed"])
        negative = deepcopy(rows)
        for row in negative:
            row["value"] = -0.01
        result = s7b_noninferiority_gate(
            negative, expected_cluster_signature=expected
        )
        self.assertFalse(result["passed"])

        boundary = {
            repetition: {
                stratum: {
                    "point": 0.0,
                    "interval": {"kind": "two_sided_95_percentile", "lower": -0.02, "upper": 0.1},
                }
                for stratum in ("overall", "ko")
            }
            for repetition in (1, 2)
        }
        result = evaluate_interval_gate(
            boundary,
            point_min=0.0,
            lower_exclusive=-0.02,
            required_strata=("overall", "ko"),
        )
        self.assertFalse(result["passed"])
        for repetition in boundary.values():
            for summary in repetition.values():
                summary["interval"]["lower"] = -0.019
        self.assertTrue(
            evaluate_interval_gate(
                boundary,
                point_min=0.0,
                lower_exclusive=-0.02,
                required_strata=("overall", "ko"),
            )["passed"]
        )

    def test_strict_positive_point_gate_rejects_zero(self) -> None:
        summaries = {
            repetition: {
                stratum: {"point": 0.0, "interval": {"lower": 0.01, "upper": 0.1}}
                for stratum in ("overall", "ko")
            }
            for repetition in (1, 2)
        }
        result = evaluate_interval_gate(
            summaries,
            point_min_exclusive=0.0,
            lower_exclusive=0.0,
            required_strata=("overall", "ko"),
        )
        self.assertFalse(result["passed"])

    def test_target_proportions_require_the_frozen_set(self) -> None:
        rows = [
            {"target_id": "a", "swap_margin": 0.2, "empty": True},
            {"target_id": "b", "swap_margin": 0.1, "empty": False},
        ]
        self.assertEqual(
            target_threshold_proportion(
                rows,
                value_field="swap_margin",
                threshold=0.2,
                comparison=">=",
                expected_target_ids=("a", "b"),
            ),
            0.5,
        )
        self.assertEqual(
            target_threshold_proportion(
                rows, value_field="empty", threshold=0, comparison="empty"
            ),
            0.5,
        )
        with self.assertRaisesRegex(EvidenceError, "frozen target set"):
            target_threshold_proportion(
                rows,
                value_field="swap_margin",
                threshold=0.2,
                comparison=">=",
                expected_target_ids=("a", "b", "c"),
            )

    def test_target_proportions_keep_repetitions_and_language_cells_separate(self) -> None:
        rows = []
        for repetition in (1, 2):
            for language in ("ko", "it", "en"):
                for index, value in enumerate((0.3, 0.1)):
                    rows.append(
                        {
                            "window_id": f"{language}-w",
                            "target_id": f"{language}-{index}",
                            "language": language,
                            "repetition": repetition,
                            "margin": value,
                        }
                    )
        result = summarize_target_proportions(
            rows,
            value_field="margin",
            threshold=0.2,
            comparison=">=",
            required_strata=("overall", "ko", "it", "en"),
            expected_target_signature=target_signature(rows),
        )
        self.assertEqual(result[1], {"overall": 0.5, "ko": 0.5, "it": 0.5, "en": 0.5})
        self.assertEqual(result[1], result[2])
        with self.assertRaisesRegex(EvidenceError, "frozen targets"):
            summarize_target_proportions(
                rows[:-1],
                value_field="margin",
                threshold=0.2,
                comparison=">=",
                required_strata=("overall",),
                expected_target_signature=target_signature(rows),
            )

    def test_s4_s5_proportion_gate_requires_every_cell_and_repetition(self) -> None:
        values = {
            1: {"overall": 0.9, "ko": 0.9, "it": 1.0, "en": 1.0},
            2: {"overall": 0.9, "ko": 0.9, "it": 1.0, "en": 1.0},
        }
        self.assertTrue(
            evaluate_proportion_gate(
                values,
                minimum=0.9,
                required_strata=("overall", "ko", "it", "en"),
            )["passed"]
        )
        reduced = deepcopy(values)
        del reduced[2]["en"]
        with self.assertRaisesRegex(EvidenceError, "required stratum"):
            evaluate_proportion_gate(
                reduced,
                minimum=0.9,
                required_strata=("overall", "ko", "it", "en"),
            )

    def test_exact_s4_and_s5_target_proportion_definitions(self) -> None:
        rows = []
        languages = ["ko"] * 12 + ["it"] * 4 + ["en"] * 4
        positive_by_language = {"ko": 9, "it": 3, "en": 3}
        swap_by_language = {"ko": 11, "it": 4, "en": 4}
        seen = {"ko": 0, "it": 0, "en": 0}
        template = []
        for index, language in enumerate(languages):
            local_index = seen[language]
            seen[language] += 1
            template.append(
                {
                    "window_id": f"w-{index // 2}",
                    "target_id": f"t-{index}",
                    "language": language,
                    "G_oracle^O": 0.1 if local_index < positive_by_language[language] else 0.0,
                    "swap_margin": 0.2 if local_index < swap_by_language[language] else 0.19,
                }
            )
        for repetition in (1, 2):
            rows.extend({**row, "repetition": repetition} for row in template)
        expected = target_signature(rows)
        strata = ("overall", "ko", "it", "en")
        s4 = summarize_target_proportions(
            rows,
            value_field="G_oracle^O",
            threshold=0,
            comparison=">",
            required_strata=strata,
            expected_target_signature=expected,
        )
        self.assertTrue(
            evaluate_proportion_gate(s4, minimum=0.7, required_strata=strata)["passed"]
        )
        s5 = summarize_target_proportions(
            rows,
            value_field="swap_margin",
            threshold=0.2,
            comparison=">=",
            required_strata=strata,
            expected_target_signature=expected,
        )
        self.assertTrue(
            evaluate_proportion_gate(s5, minimum=0.9, required_strata=strata)["passed"]
        )


class ContractAdapterRegressionTests(unittest.TestCase):
    def _document(self) -> dict[str, object]:
        return contract_fixtures.ExperimentContractTests()._document()

    def test_empty_reference_diagnostics_keep_null_rates_and_insertion_counts(self) -> None:
        document = self._document()
        experiment_manifest.verify_experiment_document(document)
        spurious = next(
            arm for arm in document["arms"] if arm["condition"] == "dicow-full-spurious"
        )
        self.assertIsNone(spurious["output"]["cer"])
        self.assertIsNone(spurious["output"]["wer"])
        self.assertIsNone(spurious["output"]["term_recall"])
        self.assertIsNone(spurious["output"]["stable_o_counts"])
        self.assertEqual(spurious["output"]["character_insertions"], 0)
        coerced = deepcopy(document)
        target = next(
            arm for arm in coerced["arms"] if arm["condition"] == "dicow-full-spurious"
        )
        target["output"]["cer"] = 0.0
        with self.assertRaises(experiment_manifest.VerificationError):
            experiment_manifest.verify_experiment_document(coerced)
        ordinary = next(
            arm
            for arm in document["arms"]
            if arm["condition"] == "dicow-mix-O-oracle"
            and arm["availability"]["status"] == "available"
        )
        counts = ordinary["output"]["stable_o_counts"]
        self.assertEqual(
            counts["hits"],
            counts["reference_chars"] - counts["substitutions"] - counts["deletions"],
        )
        inconsistent = deepcopy(document)
        ordinary = next(
            arm
            for arm in inconsistent["arms"]
            if arm["condition"] == "dicow-mix-O-oracle"
            and arm["availability"]["status"] == "available"
        )
        ordinary["output"]["stable_o_counts"]["hits"] += 1
        with self.assertRaisesRegex(
            experiment_manifest.VerificationError,
            "stable_o_counts|stable-O hits",
        ):
            experiment_manifest.verify_experiment_document(inconsistent)
        path_mismatch = deepcopy(document)
        ordinary = next(
            arm
            for arm in path_mismatch["arms"]
            if arm["condition"] == "dicow-mix-O-oracle"
            and arm["availability"]["status"] == "available"
        )
        ordinary["output"]["stable_o_counts"][
            "regional_edit_path_sha256"
        ] = OTHER_SHA
        with self.assertRaisesRegex(
            experiment_manifest.VerificationError,
            "regional_edit_path|stable_o_counts",
        ):
            experiment_manifest.verify_experiment_document(path_mismatch)

    def test_spurious_target_and_semantic_provider_are_bound(self) -> None:
        document = self._document()
        wrong_target = deepcopy(document)
        target = next(
            arm for arm in wrong_target["arms"] if arm["condition"] == "dicow-full-spurious"
        )
        target["target_id"] = "unsealed-spurious"
        with self.assertRaisesRegex(
            experiment_manifest.VerificationError,
            "spurious|sealed fixture inventory",
        ):
            experiment_manifest.verify_experiment_document(wrong_target)
        wrong_provider = deepcopy(document)
        target = next(
            arm for arm in wrong_provider["arms"] if arm["condition"] == "dicow-full-spurious"
        )
        target["activity_provider_sha256"] = wrong_provider["activity_providers"]["community1"]
        with self.assertRaisesRegex(experiment_manifest.VerificationError, "semantic provider"):
            experiment_manifest.verify_experiment_document(wrong_provider)

    def test_surplus_diagnostic_has_exact_once_per_label_coverage(self) -> None:
        contract_case = contract_fixtures.ExperimentContractTests()
        document = contract_case._document()
        mapping = document["mappings"][0]
        activity = deepcopy(mapping["activity_matrix"])
        references = [slot["reference_id"] for slot in mapping["slots"]]
        activity["surplus-window-00"] = {
            reference_id: 0.01 for reference_id in references
        }
        mapping.clear()
        mapping.update(
            derive_frozen_mapping(references, activity, window_id="window-00")
        )
        for arm_record in document["arms"]:
            if arm_record["window_id"] == "window-00":
                arm_record["mapping_sha256"] = mapping["mapping_sha256"]
        template = next(
            arm
            for arm in document["arms"]
            if arm["condition"] == "dicow-full-spurious"
            and arm["window_id"] == "window-00"
            and arm["repetition"] == 1
        )
        surplus = deepcopy(template)
        surplus.update(
            {
                "arm_id": "surplus-arm-00",
                "target_id": "surplus-window-00",
                "condition": "surplus-diagnostic",
                "activity_provider_sha256": document["activity_providers"]["community1"],
            }
        )
        surplus["stno"] = deepcopy(surplus["stno"])
        surplus["stno"].update(
            {"provider": "community1", "sha256": contract_case._h("surplus-stno")}
        )
        surplus["output"] = score_empty_reference_diagnostic("", kind="surplus")
        surplus["output"].update(
            {
                "token_ids_sha256": experiment_manifest._canonical_sha(
                    surplus["execution_input"]["result"]["token_ids"]
                ),
                "normalized_text_sha256": sha256(b"").hexdigest(),
                "character_insertions": 0,
                "word_insertions": 0,
            }
        )
        surplus["execution_input"]["result"]["text"] = ""
        surplus["execution_input"].update(
            {
                "attempt_id": "attempt-surplus-arm-00",
                "process_id": "process-surplus-arm-00",
                "session_id": "session-surplus-arm-00",
            }
        )
        document["arms"].append(surplus)
        contract_case._reseal_fixture_and_executions(document)
        experiment_manifest.verify_experiment_document(document)

        duplicate = deepcopy(document)
        duplicate_surplus = deepcopy(surplus)
        duplicate_surplus["arm_id"] = "surplus-arm-00-duplicate"
        duplicate_surplus["execution_input"].update(
            {
                "attempt_id": "attempt-surplus-arm-00-duplicate",
                "process_id": "process-surplus-arm-00-duplicate",
                "session_id": "session-surplus-arm-00-duplicate",
            }
        )
        duplicate["arms"].append(duplicate_surplus)
        contract_case._reseal_fixture_and_executions(duplicate)
        with self.assertRaisesRegex(experiment_manifest.VerificationError, "duplicate surplus"):
            experiment_manifest.verify_experiment_document(duplicate)

        document["arms"].pop()
        contract_case._reseal_fixture_and_executions(document)
        with self.assertRaisesRegex(experiment_manifest.VerificationError, "surplus diagnostics"):
            experiment_manifest.verify_experiment_document(document)


if __name__ == "__main__":
    unittest.main()
