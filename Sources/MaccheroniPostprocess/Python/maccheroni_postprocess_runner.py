#!/usr/bin/env python3
"""Offline, text-only MLX-VLM postprocessing runner.

The Swift adapter owns the output schema. This runner receives only its prompt on
stdin and emits one schema-compatible JSON object on stdout.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections.abc import Mapping
from typing import Any


def extract_json_object(text: str) -> dict[str, Any]:
    """Return one JSON object, allowing only an optional JSON Markdown fence."""
    candidate = text.strip()
    if candidate.startswith("```json\n") and candidate.endswith("\n```"):
        candidate = candidate[len("```json\n") : -len("\n```")].strip()
    elif candidate.startswith("```\n") and candidate.endswith("\n```"):
        candidate = candidate[len("```\n") : -len("\n```")].strip()
    if not candidate.startswith("{"):
        raise ValueError("model response does not start with a JSON object")
    decoder = json.JSONDecoder()
    value, end = decoder.raw_decode(candidate)
    if candidate[end:].strip():
        raise ValueError("model response contains text after its JSON object")
    if not isinstance(value, dict):
        raise ValueError("model response JSON value is not an object")
    return value


def extract_generated_text(generated: Any) -> str:
    """Extract text from mlx-vlm's GenerationResult without coercing unknown output."""
    if isinstance(generated, str):
        return generated
    if isinstance(generated, Mapping):
        text = generated.get("text")
    else:
        text = getattr(generated, "text", None)
    if not isinstance(text, str):
        raise ValueError("mlx-vlm generate returned no text")
    return text


def validate_output(value: dict[str, Any], mode: str) -> dict[str, Any]:
    if mode == "correction":
        if set(value) != {"proposals"} or not isinstance(value["proposals"], list):
            raise ValueError("output must contain only proposals")
        for proposal in value["proposals"]:
            if not isinstance(proposal, dict) or set(proposal) != {
                "segment_index", "replacement_text", "disposition", "reason"
            }:
                raise ValueError("each proposal must contain only schema fields")
            if not isinstance(proposal["segment_index"], int) or proposal["segment_index"] < 0:
                raise ValueError("segment_index must be a nonnegative integer")
            if not isinstance(proposal["replacement_text"], str) or not proposal["replacement_text"].strip():
                raise ValueError("replacement_text must not be empty")
            if proposal["disposition"] not in {"apply", "review"}:
                raise ValueError("disposition must be apply or review")
            if not isinstance(proposal["reason"], str):
                raise ValueError("reason must be a string")
        return value

    if mode == "speaker-proposal":
        if set(value) != {"speaker_proposals"} or not isinstance(
            value["speaker_proposals"], list
        ):
            raise ValueError("output must contain only speaker_proposals")
        for decision in value["speaker_proposals"]:
            if not isinstance(decision, dict) or set(decision) != {
                "segment_index", "proposed_speaker", "disposition", "reason"
            }:
                raise ValueError("each speaker proposal must contain only schema fields")
            if not isinstance(decision["segment_index"], int) or decision["segment_index"] < 0:
                raise ValueError("segment_index must be a nonnegative integer")
            if not isinstance(decision["proposed_speaker"], str):
                raise ValueError("proposed_speaker must be a string")
            if decision["disposition"] not in {"propose", "decline"}:
                raise ValueError("disposition must be propose or decline")
            # A decline names no speaker; that is what makes it a decline and
            # not a proposal the reader could mistake for one.
            if decision["disposition"] == "decline" and decision["proposed_speaker"]:
                raise ValueError("a declined segment must not name a speaker")
            if decision["disposition"] == "propose" and not decision["proposed_speaker"]:
                raise ValueError("a proposed segment must name a speaker")
            if not isinstance(decision["reason"], str) or not decision["reason"].strip():
                raise ValueError("reason must not be empty")
        return value

    if set(value) != {"translations"} or not isinstance(value["translations"], list):
        raise ValueError("output must contain only translations")
    for translation in value["translations"]:
        if not isinstance(translation, dict) or set(translation) != {
            "segment_index", "translated_text"
        }:
            raise ValueError("each translation must contain only schema fields")
        if not isinstance(translation["segment_index"], int) or translation["segment_index"] < 0:
            raise ValueError("segment_index must be a nonnegative integer")
        if not isinstance(translation["translated_text"], str) or not translation["translated_text"].strip():
            raise ValueError("translated_text must not be empty")
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-path", required=True)
    parser.add_argument(
        "--mode",
        choices=("correction", "translation", "speaker-proposal"),
        required=True,
    )
    parser.add_argument("--max-tokens", type=int, required=True)
    args = parser.parse_args()

    if args.max_tokens <= 0:
        raise ValueError("max-tokens must be positive")

    prompt = sys.stdin.read()
    if not prompt:
        raise ValueError("empty prompt")
    if not os.path.isdir(args.model_path):
        raise ValueError("pinned local model snapshot is missing")

    # Import only after argument checks so every failure goes to stderr, never stdout.
    import mlx.core as mx
    from mlx_vlm import generate, load
    from mlx_vlm.prompt_utils import apply_chat_template
    from mlx_vlm.utils import load_config

    mx.random.seed(0)
    model, processor = load(args.model_path)
    formatted_prompt = apply_chat_template(processor, load_config(args.model_path), prompt)
    generated = generate(
        model,
        processor,
        formatted_prompt,
        max_tokens=args.max_tokens,
        temperature=0.0,
        verbose=False,
    )
    value = validate_output(
        extract_json_object(extract_generated_text(generated)),
        args.mode,
    )
    sys.stdout.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:  # runner errors must not corrupt stdout JSON
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
