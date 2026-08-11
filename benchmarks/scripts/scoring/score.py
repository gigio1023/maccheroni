#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

from metrics import term_recall, text_error_rate, utterance_omissions
from rttm import diarization_error_rate, read_rttm, read_uem


def _load_json(path: Path) -> object:
    return json.loads(path.read_text(encoding="utf-8"))


def _joined_text(document: dict[str, object]) -> str:
    segments = sorted(
        document["segments"],
        key=lambda segment: (float(segment["start_s"]), float(segment["end_s"])),
    )
    return " ".join(str(segment["text"]) for segment in segments)


def main() -> int:
    parser = argparse.ArgumentParser(description="Score one Maccheroni benchmark pair")
    parser.add_argument("--reference", required=True, type=Path)
    parser.add_argument("--hypothesis", required=True, type=Path)
    parser.add_argument("--terms", type=Path)
    parser.add_argument("--reference-rttm", type=Path)
    parser.add_argument("--hypothesis-rttm", type=Path)
    parser.add_argument("--uem", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()

    reference = _load_json(arguments.reference)
    hypothesis = _load_json(arguments.hypothesis)
    if not isinstance(reference, dict) or not isinstance(hypothesis, dict):
        raise ValueError("reference and hypothesis must be JSON objects")
    reference_text = _joined_text(reference)
    hypothesis_text = _joined_text(hypothesis)
    scores: dict[str, object] = {
        "wer": text_error_rate(reference_text, hypothesis_text, unit="word").as_dict(),
        "cer": text_error_rate(reference_text, hypothesis_text, unit="character").as_dict(),
        "omissions": utterance_omissions(reference["segments"], hypothesis["segments"]),
    }
    if arguments.terms:
        terms = _load_json(arguments.terms)
        if not isinstance(terms, list):
            raise ValueError("terms must be a JSON array")
        scores["terms"] = term_recall(terms, hypothesis_text)

    if bool(arguments.reference_rttm) != bool(arguments.hypothesis_rttm):
        parser.error("--reference-rttm and --hypothesis-rttm must be supplied together")
    if arguments.reference_rttm and arguments.hypothesis_rttm:
        scores["diarization"] = diarization_error_rate(
            read_rttm(arguments.reference_rttm),
            read_rttm(arguments.hypothesis_rttm),
            uem_regions=read_uem(arguments.uem) if arguments.uem else None,
        )

    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    with arguments.output.open("x", encoding="utf-8") as output:
        output.write(
            json.dumps(scores, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
