"""Check every localized README against the published benchmark declaration."""

from __future__ import annotations

import argparse
from collections import Counter
from pathlib import Path
import re
from typing import Any, Sequence

from published_results import (
    DATA_PATH,
    README_FILENAMES,
    REPOSITORY,
    display_path,
    fixture_result,
    leaf_cap_text,
    load_results,
    metric_text,
    setting_text,
)


ALT_IMAGE = 'src="docs/assets/benchmarks-light.svg"'
LEAF_CAP_ALT_IMAGE = 'src="docs/assets/leaf-cap-light.svg"'
DECIMAL_TOKEN = re.compile(r"(?<![\d.])0\.\d+(?![\d.])")
STABILITY_TOKEN = re.compile(r"(?<![\d.])\d+\.\d+(?![\d.])")
INTEGER_TOKEN = re.compile(r"(?<![\d.])\d+(?![\d.])")


def markdown_cells(line: str) -> list[str]:
    if not line.lstrip().startswith("|"):
        return []
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


def benchmark_rows(text: str) -> tuple[list[list[str]], list[str]]:
    lines = text.splitlines()
    headers = [
        index
        for index, line in enumerate(lines)
        if len(markdown_cells(line)) == 7
        and markdown_cells(line)[2] == "CER"
        and markdown_cells(line)[3] == "WER"
        and markdown_cells(line)[6] == "DER"
    ]
    if len(headers) != 1:
        return [], [f"expected one 7-column CER/WER/DER table, found {len(headers)}"]
    rows: list[list[str]] = []
    for line in lines[headers[0] + 2 :]:
        cells = markdown_cells(line)
        if not cells:
            break
        rows.append(cells)
    return rows, []


def expected_alt_values(results: dict[str, Any]) -> list[str]:
    values = []
    for item in results["figure"]["alt_sequence"]:
        if "setting" in item:
            values.append(setting_text(results, item["setting"], "figure"))
        else:
            values.append(metric_text(results, item["fixture"], item["metric"], "figure"))
    return values


def expected_leaf_cap_alt_values(results: dict[str, Any]) -> list[str]:
    values = []
    for item in results["leaf_cap"]["alt_sequence"]:
        values.append(
            leaf_cap_text(results, item["metric"], "figure", item.get("case"))
        )
    return values


def check_readme_text(path: Path, text: str, results: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    rows, table_errors = benchmark_rows(text)
    errors.extend(f"{path.name}: {error}" for error in table_errors)
    if not table_errors:
        expected_fixtures = [
            fixture_result(results, fixture_id)
            for fixture_id in results["readme"]["row_order"]
        ]
        expected_models = [fixture["readme_model"] for fixture in expected_fixtures]
        actual_models = [row[1] for row in rows if len(row) == 7]
        if actual_models != expected_models:
            errors.append(
                f"{path.name}: expected benchmark model rows {expected_models}, found {actual_models}"
            )
        else:
            for fixture, row in zip(expected_fixtures, rows):
                expected_metrics = [
                    metric_text(
                        results,
                        fixture["fixture"],
                        metric_name,
                        "readme",
                    )
                    for metric_name in results["readme"]["metric_columns"]
                ]
                actual_metrics = row[2:]
                for metric_name, expected, actual in zip(
                    results["readme"]["metric_columns"],
                    expected_metrics,
                    actual_metrics,
                ):
                    if actual != expected:
                        errors.append(
                            f"{path.name}: {fixture['readme_model']} {metric_name}: "
                            f"expected {expected} from declaration, found {actual}"
                        )

    alt_lines = [line for line in text.splitlines() if ALT_IMAGE in line]
    if len(alt_lines) != 1:
        errors.append(
            f"{path.name}: expected one benchmark image alt line, found {len(alt_lines)}"
        )
    else:
        alt_match = re.search(r'alt="([^"]*)"', alt_lines[0])
        if alt_match is None:
            errors.append(f"{path.name}: benchmark image has no alt text")
        else:
            expected = Counter(expected_alt_values(results))
            actual = Counter(DECIMAL_TOKEN.findall(alt_match.group(1)))
            if actual != expected:
                errors.append(
                    f"{path.name}: benchmark image decimals expected {dict(expected)}, "
                    f"found {dict(actual)}"
                )

    leaf_alt_lines = [line for line in text.splitlines() if LEAF_CAP_ALT_IMAGE in line]
    if len(leaf_alt_lines) != 1:
        errors.append(
            f"{path.name}: expected one leaf-cap image alt line, "
            f"found {len(leaf_alt_lines)}"
        )
    else:
        alt_match = re.search(r'alt="([^"]*)"', leaf_alt_lines[0])
        if alt_match is None:
            errors.append(f"{path.name}: leaf-cap image has no alt text")
        else:
            expected = Counter(expected_leaf_cap_alt_values(results))
            actual = Counter(INTEGER_TOKEN.findall(alt_match.group(1)))
            if actual != expected:
                errors.append(
                    f"{path.name}: leaf-cap image integers expected {dict(expected)}, "
                    f"found {dict(actual)}"
                )

    verdict_lines = [
        line
        for line in text.splitlines()
        if "docs/moss-long-audio-verdict.md" in line
    ]
    expected_stability = metric_text(
        results, "voxconverse-ppgjx-78m", "speaker_stability", "figure"
    )
    if len(verdict_lines) != 1:
        errors.append(
            f"{path.name}: expected one published stability line, "
            f"found {len(verdict_lines)}"
        )
    elif STABILITY_TOKEN.findall(verdict_lines[0]) != [expected_stability]:
        errors.append(
            f"{path.name}: published stability expected {expected_stability}"
        )
    return errors


def check_repository(repository: Path, results: dict[str, Any]) -> list[str]:
    expected_names = set(README_FILENAMES)
    actual_names = {path.name for path in repository.glob("README*.md")}
    errors: list[str] = []
    if actual_names != expected_names:
        errors.append(
            "README locale set differs from D32: "
            f"expected {sorted(expected_names)}, found {sorted(actual_names)}"
        )
    for name in README_FILENAMES:
        path = repository / name
        if path.is_file():
            errors.extend(check_readme_text(path, path.read_text(encoding="utf-8"), results))
    return errors


def parse_arguments(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, default=DATA_PATH)
    parser.add_argument("--repository", type=Path, default=REPOSITORY)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    results = load_results(arguments.data)
    errors = check_repository(arguments.repository, results)
    if errors:
        for error in errors:
            print(error)
        return 1
    print(
        f"published benchmark tables and image alt text match "
        f"{display_path(arguments.data, arguments.repository)} in "
        f"{len(README_FILENAMES)} README files"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
