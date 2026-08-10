"""Load and format the tracked source for published benchmark results."""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
import json
from pathlib import Path
from typing import Any


BENCHMARKS = Path(__file__).resolve().parents[2]
REPOSITORY = BENCHMARKS.parent
DATA_PATH = BENCHMARKS / "published-results.json"
README_FILENAMES = (
    "README.md",
    "README.de.md",
    "README.es.md",
    "README.fr.md",
    "README.it.md",
    "README.ja.md",
    "README.ko.md",
    "README.pt.md",
    "README.ru.md",
    "README.zh-Hans.md",
)
README_METRIC_COLUMNS = ("cer", "wer", "term_recall", "omissions", "der")


class PublishedResultsError(ValueError):
    """Report an invalid published-results declaration."""


def _decimal(value: object, context: str) -> Decimal:
    try:
        parsed = Decimal(str(value))
    except InvalidOperation as error:
        raise PublishedResultsError(f"{context} is not a decimal") from error
    if not parsed.is_finite() or parsed < 0:
        raise PublishedResultsError(f"{context} must be finite and nonnegative")
    return parsed


def _validate_timestamp(value: object, context: str) -> None:
    if not isinstance(value, str):
        raise PublishedResultsError(f"{context} must be an ISO 8601 string")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise PublishedResultsError(f"{context} must be an ISO 8601 timestamp") from error
    if parsed.tzinfo is None:
        raise PublishedResultsError(f"{context} must include a timezone")


def validate_results(results: dict[str, Any]) -> None:
    if results.get("schema_version") != 1:
        raise PublishedResultsError("schema_version must be 1")
    rounding = results.get("rounding", {})
    if rounding.get("mode") != "ROUND_HALF_UP":
        raise PublishedResultsError("rounding.mode must be ROUND_HALF_UP")
    surfaces = rounding.get("surfaces")
    if not isinstance(surfaces, dict) or not surfaces:
        raise PublishedResultsError("rounding.surfaces must be a nonempty object")

    sources = results.get("sources")
    if not isinstance(sources, dict) or not sources:
        raise PublishedResultsError("sources must be a nonempty object")
    for source_id, source in sources.items():
        if not isinstance(source, dict):
            raise PublishedResultsError(f"sources.{source_id} must be an object")
        for field in ("artifact", "artifact_sha256", "run_id", "run_kind"):
            if not isinstance(source.get(field), str) or not source[field]:
                raise PublishedResultsError(f"sources.{source_id}.{field} is required")
        _validate_timestamp(source.get("measured_at"), f"sources.{source_id}.measured_at")
        values = source.get("values")
        if not isinstance(values, dict) or not values:
            raise PublishedResultsError(f"sources.{source_id}.values must be nonempty")
        derivations = source.get("derivations", {})
        if not isinstance(derivations, dict):
            raise PublishedResultsError(f"sources.{source_id}.derivations must be an object")
        for metric, value in values.items():
            if not isinstance(metric, str) or not metric:
                raise PublishedResultsError(f"sources.{source_id} has an invalid metric")
            _decimal(value, f"sources.{source_id}.values.{metric}")
            if metric.startswith("derived.") and metric not in derivations:
                raise PublishedResultsError(
                    f"sources.{source_id}.values.{metric} needs derivation metadata"
                )
        for metric, derivation in derivations.items():
            if metric not in values or not metric.startswith("derived."):
                raise PublishedResultsError(
                    f"sources.{source_id}.derivations.{metric} has no derived value"
                )
            if not isinstance(derivation, dict) or not derivation.get("rule"):
                raise PublishedResultsError(
                    f"sources.{source_id}.derivations.{metric}.rule is required"
                )
            evidence = derivation.get("evidence")
            if not isinstance(evidence, list) or not evidence or not all(
                isinstance(item, str) and item for item in evidence
            ):
                raise PublishedResultsError(
                    f"sources.{source_id}.derivations.{metric}.evidence is required"
                )

    fixtures = results.get("fixtures")
    if not isinstance(fixtures, list) or not fixtures:
        raise PublishedResultsError("fixtures must be a nonempty array")
    fixture_ids: set[str] = set()
    measurements: dict[tuple[str, str], dict[str, Any]] = {}
    for fixture in fixtures:
        fixture_id = fixture.get("fixture") if isinstance(fixture, dict) else None
        if not isinstance(fixture_id, str) or not fixture_id:
            raise PublishedResultsError("every fixture needs a nonempty fixture ID")
        if fixture_id in fixture_ids:
            raise PublishedResultsError(f"duplicate fixture: {fixture_id}")
        fixture_ids.add(fixture_id)
        if not isinstance(fixture.get("readme_model"), str):
            raise PublishedResultsError(f"{fixture_id}.readme_model is required")
        metrics = fixture.get("metrics")
        if not isinstance(metrics, dict) or not metrics:
            raise PublishedResultsError(f"{fixture_id}.metrics must be nonempty")
        for metric_name, measurement in metrics.items():
            context = f"{fixture_id}.{metric_name}"
            if not isinstance(measurement, dict):
                raise PublishedResultsError(f"{context} must be an object")
            for field in ("kind", "metric", "source"):
                if not isinstance(measurement.get(field), str) or not measurement[field]:
                    raise PublishedResultsError(f"{context}.{field} is required")
            if measurement["source"] not in sources:
                raise PublishedResultsError(f"{context} names an unknown source")
            source_values = sources[measurement["source"]]["values"]
            if measurement["metric"] not in source_values:
                raise PublishedResultsError(f"{context} metric is absent from its source")
            value = _decimal(source_values[measurement["metric"]], f"{context}.value")
            if measurement["kind"] == "count" and value != value.to_integral_value():
                raise PublishedResultsError(f"{context}.value must be an integer count")
            if not any(measurement["kind"] in rules for rules in surfaces.values()):
                raise PublishedResultsError(f"{context}.kind has no rounding rule")
            identity = (fixture_id, measurement["metric"])
            if identity in measurements:
                raise PublishedResultsError(
                    f"duplicate source metric {measurement['metric']} for {fixture_id}"
                )
            measurements[identity] = measurement

    readme = results.get("readme", {})
    row_order = readme.get("row_order")
    if (
        not isinstance(row_order, list)
        or len(row_order) != len(fixture_ids)
        or set(row_order) != fixture_ids
    ):
        raise PublishedResultsError("readme.row_order must name every fixture exactly once")
    if not isinstance(readme.get("placeholder"), str):
        raise PublishedResultsError("readme.placeholder is required")
    if readme.get("metric_columns") != list(README_METRIC_COLUMNS):
        raise PublishedResultsError(
            f"readme.metric_columns must be {list(README_METRIC_COLUMNS)}"
        )

    leaf_cap = results.get("leaf_cap")
    if not isinstance(leaf_cap, dict) or not isinstance(leaf_cap.get("cases"), list):
        raise PublishedResultsError("leaf_cap.cases must be an array")
    case_ids: set[str] = set()
    owners = [
        ("leaf_cap", leaf_cap),
        *[(case.get("case"), case) for case in leaf_cap["cases"]],
    ]
    for owner_id, owner in owners:
        if not isinstance(owner_id, str) or not owner_id:
            raise PublishedResultsError("every leaf-cap case needs a nonempty case ID")
        if owner_id != "leaf_cap":
            if owner_id in case_ids:
                raise PublishedResultsError(f"duplicate leaf-cap case: {owner_id}")
            case_ids.add(owner_id)
        metrics = owner.get("metrics") if isinstance(owner, dict) else None
        if not isinstance(metrics, dict) or not metrics:
            raise PublishedResultsError(f"{owner_id}.metrics must be nonempty")
        for metric_name, measurement in metrics.items():
            context = f"{owner_id}.{metric_name}"
            if not isinstance(measurement, dict):
                raise PublishedResultsError(f"{context} must be an object")
            for field in ("kind", "metric", "source"):
                if not isinstance(measurement.get(field), str) or not measurement[field]:
                    raise PublishedResultsError(f"{context}.{field} is required")
            source = sources.get(measurement["source"])
            if source is None or measurement["metric"] not in source["values"]:
                raise PublishedResultsError(f"{context} metric is absent from its source")
            value = _decimal(source["values"][measurement["metric"]], f"{context}.value")
            if measurement["kind"] == "count" and value != value.to_integral_value():
                raise PublishedResultsError(f"{context}.value must be an integer count")
            if measurement["kind"] not in surfaces.get("figure", {}):
                raise PublishedResultsError(f"{context}.kind has no figure rounding rule")
    case_order = leaf_cap.get("case_order")
    if (
        not isinstance(case_order, list)
        or len(case_order) != len(case_ids)
        or set(case_order) != case_ids
    ):
        raise PublishedResultsError("leaf_cap.case_order must name every case exactly once")

    for decision in results.get("canonical_run_decisions", ()):
        if decision.get("alternative_source") not in sources:
            raise PublishedResultsError("canonical decision has unknown alternative_source")
        identity = (decision.get("fixture"), decision.get("metric"))
        measurement = measurements.get(identity)
        if measurement is None:
            raise PublishedResultsError("canonical decision does not identify one measurement")
        alternative = sources[decision["alternative_source"]]
        if decision["metric"] not in alternative["values"]:
            raise PublishedResultsError(
                "canonical alternative source does not expose the selected metric"
            )


def load_results(path: Path = DATA_PATH) -> dict[str, Any]:
    results = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(results, dict):
        raise PublishedResultsError("published results must be a JSON object")
    validate_results(results)
    return results


def display_path(path: Path, repository: Path = REPOSITORY) -> str:
    try:
        return str(path.resolve().relative_to(repository.resolve()))
    except ValueError:
        return str(path)


def fixture_result(results: dict[str, Any], fixture_id: str) -> dict[str, Any]:
    matches = [fixture for fixture in results["fixtures"] if fixture["fixture"] == fixture_id]
    if len(matches) != 1:
        raise PublishedResultsError(f"expected one fixture named {fixture_id}")
    return matches[0]


def _measurement_text(
    results: dict[str, Any], measurement: dict[str, Any], surface: str
) -> str:
    source = results["sources"][measurement["source"]]
    value = source["values"][measurement["metric"]]
    return format_value(results, value, measurement["kind"], surface)


def format_value(
    results: dict[str, Any], value: object, kind: str, surface: str
) -> str:
    try:
        rule = results["rounding"]["surfaces"][surface][kind]
    except KeyError as error:
        raise PublishedResultsError(f"no {surface} rounding rule for {kind}") from error
    places = rule["decimal_places"]
    if not isinstance(places, int) or places < 0:
        raise PublishedResultsError(f"invalid decimal_places for {surface}.{kind}")
    quantum = Decimal(1).scaleb(-places)
    rounded = _decimal(value, f"{surface}.{kind} value").quantize(
        quantum, rounding=ROUND_HALF_UP
    )
    formatted = f"{rounded:.{places}f}"
    if rule.get("strip_trailing_zeroes") and "." in formatted:
        formatted = formatted.rstrip("0").rstrip(".")
    return formatted


def metric_text(
    results: dict[str, Any], fixture_id: str, metric_name: str, surface: str
) -> str:
    fixture = fixture_result(results, fixture_id)
    measurement = fixture["metrics"].get(metric_name)
    if measurement is None:
        return results["readme"]["placeholder"]
    return _measurement_text(results, measurement, surface)


def metric_decimal(
    results: dict[str, Any], fixture_id: str, metric_name: str, surface: str
) -> Decimal:
    value = metric_text(results, fixture_id, metric_name, surface)
    if value == results["readme"]["placeholder"]:
        raise PublishedResultsError(f"{fixture_id}.{metric_name} is not measured")
    return Decimal(value)


def setting_text(results: dict[str, Any], setting_name: str, surface: str) -> str:
    setting = results["publication_settings"][setting_name]
    return format_value(results, setting["value"], setting["kind"], surface)


def setting_decimal(results: dict[str, Any], setting_name: str, surface: str) -> Decimal:
    return Decimal(setting_text(results, setting_name, surface))


def leaf_cap_case(results: dict[str, Any], case_id: str) -> dict[str, Any]:
    matches = [case for case in results["leaf_cap"]["cases"] if case["case"] == case_id]
    if len(matches) != 1:
        raise PublishedResultsError(f"expected one leaf-cap case named {case_id}")
    return matches[0]


def leaf_cap_text(
    results: dict[str, Any], metric_name: str, surface: str, case_id: str | None = None
) -> str:
    owner = results["leaf_cap"] if case_id is None else leaf_cap_case(results, case_id)
    measurement = owner["metrics"][metric_name]
    return _measurement_text(results, measurement, surface)


def leaf_cap_decimal(
    results: dict[str, Any], metric_name: str, surface: str, case_id: str | None = None
) -> Decimal:
    return Decimal(leaf_cap_text(results, metric_name, surface, case_id))
