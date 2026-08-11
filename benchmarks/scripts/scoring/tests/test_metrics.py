from __future__ import annotations

import unittest

from metrics import (
    count_term_occurrences,
    term_recall,
    text_error_rate,
    utterance_omissions,
)


class TextMetricTests(unittest.TestCase):
    def test_wer_ignores_attached_apostrophes_and_hyphens(self) -> None:
        cases = (
            ("ASCII apostrophe", "dont", "don't"),
            ("typographic apostrophe", "dont", "don’t"),
            ("hyphen", "stateoftheart", "state-of-the-art"),
        )
        for label, reference, hypothesis in cases:
            with self.subTest(label=label):
                result = text_error_rate(reference, hypothesis, unit="word")
                self.assertEqual(result.errors, 0)
                self.assertEqual(result.error_rate, 0.0)

    def test_cer_ignores_attached_apostrophes_and_hyphens(self) -> None:
        cases = (
            ("ASCII apostrophe", "dont", "don't"),
            ("typographic apostrophe", "dont", "don’t"),
            ("hyphen", "stateoftheart", "state-of-the-art"),
        )
        for label, reference, hypothesis in cases:
            with self.subTest(label=label):
                result = text_error_rate(reference, hypothesis, unit="character")
                self.assertEqual(result.errors, 0)
                self.assertEqual(result.error_rate, 0.0)

    def test_case_nfkc_and_whitespace_normalization_remain_unchanged(self) -> None:
        for unit in ("word", "character"):
            with self.subTest(unit=unit):
                result = text_error_rate("ＡＰＩ\tReady", "api ready", unit=unit)
                self.assertEqual(result.errors, 0)
                self.assertEqual(result.error_rate, 0.0)

    def test_italian_diacritics_remain_scorable(self) -> None:
        result = text_error_rate("cafe", "cafè", unit="character")
        self.assertEqual(result.substitutions, 1)
        self.assertEqual(result.error_rate, 0.25)

    def test_wer_counts_substitution_deletion_and_insertion(self) -> None:
        result = text_error_rate("one two three", "one too extra four", unit="word")
        self.assertEqual(result.reference_units, 3)
        self.assertEqual(result.errors, 3)
        self.assertAlmostEqual(result.error_rate or 0, 1.0)

    def test_cer_ignores_spaces_case_and_punctuation(self) -> None:
        result = text_error_rate("A b, c", "abx", unit="character")
        self.assertEqual(result.reference_units, 3)
        self.assertEqual(result.substitutions, 1)
        self.assertAlmostEqual(result.error_rate or 0, 1 / 3)


class TermRecallTests(unittest.TestCase):
    def test_korean_spacing_and_latin_case(self) -> None:
        result = term_recall(
            [
                {"term": "판교어", "reference_count": 1},
                {"term": "API", "reference_count": 2},
            ],
            "판교 어에서 api를 확인하고 capillary는 제외합니다.",
        )
        self.assertEqual(result["matched_reference_occurrences"], 2)
        self.assertEqual(result["reference_occurrences"], 3)
        self.assertAlmostEqual(result["term_recall"], 2 / 3)

    def test_latin_partial_match_does_not_count(self) -> None:
        self.assertEqual(count_term_occurrences("API", "capillary"), 0)

    def test_latin_separators_are_equivalent(self) -> None:
        self.assertEqual(count_term_occurrences("Qwen3-ASR", "qwen3 asr은 로컬입니다"), 1)

    def test_space_before_latin_term_preserves_boundary(self) -> None:
        self.assertEqual(count_term_occurrences("API", "Maccheroni API를 확인합니다"), 1)


class OmissionTests(unittest.TestCase):
    def test_counts_reference_interval_without_lexical_output(self) -> None:
        reference = [
            {"start_s": 0.0, "end_s": 1.0, "text": "one"},
            {"start_s": 2.0, "end_s": 3.0, "text": "two"},
            {"start_s": 4.0, "end_s": 5.0, "text": "noise", "scorable": False},
        ]
        hypothesis = [{"start_s": 0.2, "end_s": 0.8, "text": "wrong"}]
        result = utterance_omissions(reference, hypothesis)
        self.assertEqual(result["scorable_utterances"], 2)
        self.assertEqual(result["omitted_utterances"], 1)
        self.assertEqual(result["omitted_reference_indices"], [1])


if __name__ == "__main__":
    unittest.main()
