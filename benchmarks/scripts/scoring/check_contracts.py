#!/usr/bin/env python3
from __future__ import annotations

from collections.abc import Callable
from copy import deepcopy
import json
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker, ValidationError


SCRIPT_DIR = Path(__file__).resolve().parent
REPOSITORY_ROOT = SCRIPT_DIR.parents[2]


def _load(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def _validate_segments_semantics(document: dict[str, object]) -> None:
    segments = document["segments"]
    duration = float(document["source"]["duration_s"])
    previous_key = (-1.0, -1.0)
    speakers: set[str] = set()
    for index, segment in enumerate(segments):
        start = float(segment["start_s"])
        end = float(segment["end_s"])
        if end <= start:
            raise ValueError(f"segment {index}: end_s must be greater than start_s")
        if end > duration + 0.01:
            raise ValueError(f"segment {index}: extends past source duration")
        key = (start, end)
        if key < previous_key:
            raise ValueError(f"segment {index}: segments are not time-sorted")
        previous_key = key
        if segment["speaker"] not in {"UNASSIGNED", "UNKNOWN"}:
            speakers.add(segment["speaker"])
    if len(speakers) != document["num_speakers"]:
        raise ValueError("num_speakers does not match unique attributed speakers")


def _validate_manifest_semantics(document: dict[str, object]) -> None:
    coverage = document["coverage"]
    if coverage["chunks_completed"] > coverage["chunks_planned"]:
        raise ValueError("chunks_completed exceeds chunks_planned")
    if coverage["processed_duration_s"] > coverage["input_duration_s"] + 0.01:
        raise ValueError("processed duration exceeds input duration")
    if document["status"] == "succeeded" and abs(
        coverage["processed_duration_s"] - coverage["input_duration_s"]
    ) > 0.01:
        raise ValueError("successful run does not cover the full input")
    if (
        document["status"] == "succeeded"
        and coverage["chunks_completed"] != coverage["chunks_planned"]
    ):
        raise ValueError("successful run has incomplete chunks_completed coverage")

    expected_index = 0
    for chunk in document["chunk_boundaries"]:
        if chunk["index"] != expected_index:
            raise ValueError("chunk indices must be contiguous from zero")
        if chunk["end_s"] <= chunk["start_s"]:
            raise ValueError(f"chunk {expected_index}: end_s must be greater than start_s")
        expected_index += 1

    postprocess = document.get("postprocess")
    if not postprocess or not postprocess.get("batching"):
        return
    batching = postprocess["batching"]
    hard_limit = batching["maximum_output_tokens"]
    status = batching["output_token_limit_status"]
    if (status == "configured") != (hard_limit is not None):
        raise ValueError("postprocess hard output limit status is inconsistent")
    planning_budget = batching["output_token_planning_budget"]
    if hard_limit is not None and planning_budget > hard_limit:
        raise ValueError("postprocess planning budget exceeds the hard output limit")
    if (
        batching["maximum_observed_prompt_utf8_bytes"]
        > batching["maximum_prompt_utf8_bytes"]
    ):
        raise ValueError("observed postprocess prompt exceeds its declared limit")
    if (
        batching["maximum_observed_estimated_output_tokens"] > planning_budget
        or batching["maximum_observed_accepted_output_token_upper_bound"]
        > planning_budget
    ):
        raise ValueError("observed postprocess output evidence exceeds its budget")
    if (
        batching["maximum_observed_response_utf8_bytes"]
        < batching["maximum_observed_output_text_utf8_bytes"]
    ):
        raise ValueError("raw postprocess response is smaller than decoded text")


def _estimated_output_tokens(
    batching: dict[str, object], input_bytes: int, segment_count: int
) -> int:
    permille = int(batching["output_tokens_per_input_utf8_byte_permille"])
    source_estimate = (input_bytes * permille + 999) // 1_000
    return (
        int(batching["base_output_token_reserve"])
        + segment_count * int(batching["per_segment_output_token_reserve"])
        + source_estimate
    )


def _accepted_output_upper_bound(
    batching: dict[str, object], response_bytes: int, segment_count: int
) -> int:
    return (
        int(batching["base_output_token_reserve"])
        + segment_count * int(batching["per_segment_output_token_reserve"])
        + response_bytes
    )


def _validate_translation_semantics(
    translation: dict[str, object],
    manifest: dict[str, object],
    source_texts: list[str],
) -> None:
    postprocess = manifest["postprocess"]
    batching = postprocess["batching"]
    if postprocess["mode"] != "translation":
        raise ValueError("translation artifact is attached to a non-translation run")
    if translation["target_language"] != postprocess["target_language"]:
        raise ValueError("translation target does not match manifest provenance")
    if translation["source_segments_sha256"] != postprocess["source_segments_sha256"]:
        raise ValueError("translation source hash does not match manifest provenance")

    expected_indices = list(range(len(source_texts)))
    translations = translation["translations"]
    translations_by_index = {
        item["segment_index"]: item["translated_text"] for item in translations
    }
    if sorted(translations_by_index) != expected_indices:
        raise ValueError("translation indices do not exactly cover the canonical source")
    if len(translations_by_index) != len(translations):
        raise ValueError("translation indices are duplicated")

    batches = translation["batches"]
    if len(batches) != batching["batches_planned"]:
        raise ValueError("translation batch count differs from its manifest")
    batched_indices: list[int] = []
    observed: dict[str, list[int]] = {
        "maximum_observed_prompt_utf8_bytes": [],
        "maximum_observed_input_text_utf8_bytes": [],
        "maximum_observed_estimated_output_tokens": [],
        "maximum_observed_output_text_utf8_bytes": [],
        "maximum_observed_response_utf8_bytes": [],
        "maximum_observed_accepted_output_token_upper_bound": [],
    }
    planning_budget = int(batching["output_token_planning_budget"])
    for expected_batch_index, batch in enumerate(batches):
        if batch["batch_index"] != expected_batch_index:
            raise ValueError("translation batch indices must be contiguous from zero")
        indices = batch["segment_indices"]
        if len(indices) > batching["maximum_segments_per_batch"]:
            raise ValueError("translation batch exceeds its segment limit")
        if any(index not in expected_indices for index in indices):
            raise ValueError("translation batch refers outside the canonical source")
        input_bytes = sum(len(source_texts[index].encode("utf-8")) for index in indices)
        output_bytes = sum(
            len(translations_by_index[index].encode("utf-8")) for index in indices
        )
        estimated = _estimated_output_tokens(batching, input_bytes, len(indices))
        response_bytes = batch["response_utf8_bytes"]
        accepted = _accepted_output_upper_bound(batching, response_bytes, len(indices))
        if batch["input_text_utf8_bytes"] != input_bytes:
            raise ValueError("translation batch source byte evidence is not reproducible")
        if batch["output_text_utf8_bytes"] != output_bytes:
            raise ValueError("translation batch output byte evidence is not reproducible")
        if response_bytes < output_bytes:
            raise ValueError("translation raw response is smaller than decoded text")
        if batch["estimated_output_tokens"] != estimated:
            raise ValueError("translation batch output estimate is not reproducible")
        if batch["accepted_output_token_upper_bound"] != accepted:
            raise ValueError("translation batch accepted output bound is not reproducible")
        if batch["prompt_utf8_bytes"] > batching["maximum_prompt_utf8_bytes"]:
            raise ValueError("translation batch prompt exceeds its declared limit")
        if estimated > planning_budget or accepted > planning_budget:
            raise ValueError("translation batch exceeds its output planning budget")
        batched_indices.extend(indices)
        observed["maximum_observed_prompt_utf8_bytes"].append(
            batch["prompt_utf8_bytes"]
        )
        observed["maximum_observed_input_text_utf8_bytes"].append(input_bytes)
        observed["maximum_observed_estimated_output_tokens"].append(estimated)
        observed["maximum_observed_output_text_utf8_bytes"].append(output_bytes)
        observed["maximum_observed_response_utf8_bytes"].append(response_bytes)
        observed["maximum_observed_accepted_output_token_upper_bound"].append(accepted)

    if batched_indices != expected_indices:
        raise ValueError("translation batches are not exact contiguous source coverage")
    for manifest_key, values in observed.items():
        if batching[manifest_key] != max(values):
            raise ValueError(f"translation manifest maximum is stale: {manifest_key}")


def _expect_schema_failure(
    validator: Draft202012Validator, document: dict[str, object], message: str
) -> None:
    try:
        validator.validate(document)
    except ValidationError:
        return
    raise AssertionError(message)


def _expect_semantic_failure(check: Callable[[], None], message: str) -> None:
    """Assert a document the schema accepts is still rejected by semantics.

    Index coverage and batch ordering are structurally valid JSON, so only the
    semantic pass can catch them.
    """
    try:
        check()
    except ValueError:
        return
    raise AssertionError(message)


def main() -> int:
    segments_schema = _load(REPOSITORY_ROOT / "docs/contracts/segments.schema.json")
    manifest_schema = _load(REPOSITORY_ROOT / "docs/contracts/manifest.schema.json")
    translation_schema = _load(
        REPOSITORY_ROOT / "docs/contracts/translation.schema.json"
    )
    Draft202012Validator.check_schema(segments_schema)
    Draft202012Validator.check_schema(manifest_schema)
    Draft202012Validator.check_schema(translation_schema)

    checker = FormatChecker()
    segments_validator = Draft202012Validator(segments_schema, format_checker=checker)
    manifest_validator = Draft202012Validator(manifest_schema, format_checker=checker)
    translation_validator = Draft202012Validator(
        translation_schema, format_checker=checker
    )
    segments = _load(SCRIPT_DIR / "fixtures/segments.example.json")
    manifest = _load(SCRIPT_DIR / "fixtures/manifest.example.json")
    segments_validator.validate(segments)
    manifest_validator.validate(manifest)
    _validate_segments_semantics(segments)
    _validate_manifest_semantics(manifest)

    legacy_postprocessed = deepcopy(manifest)
    legacy_postprocessed["models"].append(
        {
            "role": "postprocess",
            "hf_model_id": "mlx-community/gemma-4-12B-it-qat-4bit",
            "revision": "e70c6b3ba0979b3357dcd2f223ad8bde7787a6b6",
            "quantization": "qat-int4",
        }
    )
    legacy_postprocessed["postprocess"] = {
        "backend": {"name": "mlx-vlm", "version": "0.6.6"},
        "model_id": "mlx-community/gemma-4-12B-it-qat-4bit",
        "model_revision": "e70c6b3ba0979b3357dcd2f223ad8bde7787a6b6",
        "quantization": "qat-int4",
        "input_mode": "text-only",
        "glossary_sha256": None,
    }
    manifest_validator.validate(legacy_postprocessed)

    source_texts = ["ciao", "mondo"]
    source_hash = "3" * 64
    batching = {
        "maximum_prompt_utf8_bytes": 1_024,
        "maximum_segments_per_batch": 1,
        "maximum_output_tokens": None,
        "output_token_limit_status": "service-managed-unavailable",
        "output_token_planning_budget": 256,
        "output_tokens_per_input_utf8_byte_permille": 2_000,
        "base_output_token_reserve": 32,
        "per_segment_output_token_reserve": 96,
        "batches_planned": 2,
        "maximum_observed_prompt_utf8_bytes": 258,
        "maximum_observed_input_text_utf8_bytes": 5,
        "maximum_observed_estimated_output_tokens": 138,
        "maximum_observed_output_text_utf8_bytes": 5,
        "maximum_observed_response_utf8_bytes": 65,
        "maximum_observed_accepted_output_token_upper_bound": 193,
    }
    translated_manifest = deepcopy(manifest)
    translated_manifest["postprocess"] = {
        "backend": {"name": "codex-cli", "version": "codex-cli 0.146.0"},
        "model_id": "gpt-5.6-sol",
        "model_revision": None,
        "quantization": None,
        "input_mode": "text-only",
        "glossary_sha256": None,
        "mode": "translation",
        "target_language": "en",
        "source_segments_sha256": source_hash,
        "batching": batching,
    }
    translated_manifest["artifacts"].append(
        {
            "kind": "postprocess_translation",
            "path": "postprocess/translation.json",
            "sha256": "4" * 64,
        }
    )
    translation = {
        "schema_version": "1.0.0",
        "target_language": "en",
        "source_segments_sha256": source_hash,
        "batches": [
            {
                "batch_index": 0,
                "segment_indices": [0],
                "prompt_utf8_bytes": 256,
                "input_text_utf8_bytes": 4,
                "estimated_output_tokens": 136,
                "output_text_utf8_bytes": 5,
                "response_utf8_bytes": 64,
                "accepted_output_token_upper_bound": 192,
            },
            {
                "batch_index": 1,
                "segment_indices": [1],
                "prompt_utf8_bytes": 258,
                "input_text_utf8_bytes": 5,
                "estimated_output_tokens": 138,
                "output_text_utf8_bytes": 5,
                "response_utf8_bytes": 65,
                "accepted_output_token_upper_bound": 193,
            },
        ],
        "translations": [
            {"segment_index": 0, "translated_text": "hello"},
            {"segment_index": 1, "translated_text": "world"},
        ],
    }
    manifest_validator.validate(translated_manifest)
    translation_validator.validate(translation)
    _validate_manifest_semantics(translated_manifest)
    _validate_translation_semantics(translation, translated_manifest, source_texts)

    invalid = deepcopy(manifest)
    invalid["coverage"]["truncated"] = True
    _expect_schema_failure(
        manifest_validator,
        invalid,
        "a succeeded but truncated manifest passed validation",
    )
    incomplete = deepcopy(manifest)
    incomplete["coverage"]["chunks_completed"] = 0
    manifest_validator.validate(incomplete)
    _expect_semantic_failure(
        lambda: _validate_manifest_semantics(incomplete),
        "a succeeded manifest with incomplete chunks passed semantic validation",
    )
    structurally_unsafe = deepcopy(translation)
    structurally_unsafe["translations"][0]["speaker"] = "SPEAKER_00"
    _expect_schema_failure(
        translation_validator,
        structurally_unsafe,
        "translation schema allowed a speaker field",
    )
    missing_batching = deepcopy(translated_manifest)
    del missing_batching["postprocess"]["batching"]
    _expect_schema_failure(
        manifest_validator,
        missing_batching,
        "translation manifest passed without batching provenance",
    )

    duplicated_index = deepcopy(translation)
    duplicated_index["translations"].append(
        {"segment_index": 1, "translated_text": "world"}
    )
    translation_validator.validate(duplicated_index)
    _expect_semantic_failure(
        lambda: _validate_translation_semantics(
            duplicated_index, translated_manifest, source_texts
        ),
        "a duplicated translation index passed semantic validation",
    )

    missing_index = deepcopy(translation)
    del missing_index["translations"][1]
    translation_validator.validate(missing_index)
    _expect_semantic_failure(
        lambda: _validate_translation_semantics(
            missing_index, translated_manifest, source_texts
        ),
        "a missing translation index passed semantic validation",
    )

    reordered_batches = deepcopy(translation)
    reordered_batches["batches"] = [
        dict(reordered_batches["batches"][1], batch_index=0),
        dict(reordered_batches["batches"][0], batch_index=1),
    ]
    translation_validator.validate(reordered_batches)
    _expect_semantic_failure(
        lambda: _validate_translation_semantics(
            reordered_batches, translated_manifest, source_texts
        ),
        "reordered translation batches passed semantic validation",
    )

    renumbered_batches = deepcopy(translation)
    renumbered_batches["batches"] = list(reversed(renumbered_batches["batches"]))
    translation_validator.validate(renumbered_batches)
    _expect_semantic_failure(
        lambda: _validate_translation_semantics(
            renumbered_batches, translated_manifest, source_texts
        ),
        "non-contiguous translation batch indices passed semantic validation",
    )

    print("PASS segments.schema.json: schema + example + semantic checks")
    print(
        "PASS manifest.schema.json: base + legacy correction + bounded translation "
        "examples + truncation and incomplete-coverage guards + semantic checks"
    )
    print(
        "PASS translation.schema.json: two bounded batches + exact coverage + "
        "reproducible byte/token ledger + forbidden speaker field + duplicate, "
        "missing, reordered and renumbered index guards"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
