from __future__ import annotations

from copy import deepcopy
from pathlib import Path
import sys
import unittest


FIGURES = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(FIGURES))

from check_readme_benchmarks import check_readme_text, check_repository  # noqa: E402
from published_results import (  # noqa: E402
    DATA_PATH,
    README_FILENAMES,
    REPOSITORY,
    fixture_result,
    leaf_cap_text,
    load_results,
    metric_text,
    PublishedResultsError,
    validate_results,
)


class PublishedResultsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.results = load_results(DATA_PATH)

    def test_all_ten_readmes_match_the_declaration(self) -> None:
        self.assertEqual(check_repository(REPOSITORY, self.results), [])
        self.assertEqual(len(README_FILENAMES), 10)

    def test_declared_rounding_preserves_the_current_publication(self) -> None:
        self.assertEqual(
            metric_text(self.results, "voxconverse-ppgjx-78m", "der", "readme"),
            "0.152",
        )
        self.assertEqual(
            metric_text(self.results, "italian-dialogue", "term_recall", "readme"),
            "0.78",
        )
        self.assertEqual(
            metric_text(self.results, "italian-dialogue", "term_recall", "figure"),
            "0.778",
        )
        self.assertEqual(
            metric_text(
                self.results,
                "voxconverse-ppgjx-78m",
                "speaker_stability",
                "figure",
            ),
            "1.0",
        )

    def test_leaf_cap_figure_values_resolve_from_declared_runs(self) -> None:
        self.assertEqual(
            [
                leaf_cap_text(
                    self.results, "valid_eos_leaves", "figure", case_id
                )
                for case_id in self.results["leaf_cap"]["case_order"]
            ],
            ["5", "0", "0", "5"],
        )
        self.assertEqual(
            leaf_cap_text(
                self.results, "cer", "figure", "forced-recovery-240-1024"
            ),
            "0.036",
        )

    def test_stability_check_is_not_anchored_to_the_current_value(self) -> None:
        changed = deepcopy(self.results)
        changed["sources"]["voxconverse-e2e-stability"]["values"][
            "speakers.*.stability"
        ] = "0.9"
        validate_results(changed)
        readme = REPOSITORY / "README.md"
        text = readme.read_text(encoding="utf-8").replace("1.0", "0.9")
        self.assertEqual(check_readme_text(readme, text, changed), [])

    def test_schema_rejects_a_vacuous_readme_column_list(self) -> None:
        broken = deepcopy(self.results)
        broken["readme"]["metric_columns"].remove("der")
        with self.assertRaises(PublishedResultsError):
            validate_results(broken)

    def test_switching_to_the_standalone_der_is_detected_in_every_readme(self) -> None:
        perturbed = deepcopy(self.results)
        fixture = fixture_result(perturbed, "voxconverse-ppgjx-78m")
        fixture["metrics"]["der"]["source"] = "voxconverse-standalone-der"
        validate_results(perturbed)

        errors = check_repository(REPOSITORY, perturbed)
        self.assertTrue(errors)
        for name in README_FILENAMES:
            with self.subTest(name=name):
                self.assertTrue(any(error.startswith(f"{name}:") for error in errors))
        self.assertTrue(
            any("expected 0.153 from declaration, found 0.152" in error for error in errors)
        )


if __name__ == "__main__":
    unittest.main()
