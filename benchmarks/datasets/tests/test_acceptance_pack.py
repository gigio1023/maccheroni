from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

DATASETS = Path(__file__).resolve().parents[1]
if str(DATASETS) not in sys.path:
    sys.path.insert(0, str(DATASETS))

from acceptance_pack import (
    PackError,
    verify_common_prepared_fixture,
    verify_source_files,
)


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


class AcceptancePackNegativeTests(unittest.TestCase):
    def test_corrupted_source_manifest_hash_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "sources" / "hike" / "source.bin"
            source.parent.mkdir(parents=True)
            source.write_bytes(b"public source")
            fixture = {
                "source": {
                    "files": [
                        {
                            "relative_path": "sources/hike/source.bin",
                            "size_bytes": source.stat().st_size,
                            "sha256": "0" * 64,
                        }
                    ]
                }
            }
            with self.assertRaisesRegex(PackError, "source hash mismatch"):
                verify_source_files(root, fixture)

    def test_truncated_reference_fails_after_hash_manifest_is_updated(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            reference = {
                "schema_version": "1.0.0",
                "segments": [
                    {"speaker": "UNASSIGNED", "start_s": 0.0, "end_s": 1.0, "text": "API"},
                    {"speaker": "UNASSIGNED", "start_s": 1.0, "end_s": 2.0, "text": "ignored"},
                ],
                "num_speakers": 0,
                "source": {"file_name": "input.wav", "sha256": "1" * 64, "duration_s": 2.0},
            }
            write_json(fixture / "reference.segments.json", reference)
            write_json(fixture / "terms.json", [{"term": "API", "reference_count": 1}])
            (fixture / "glossary.txt").write_text("API\n", encoding="utf-8")
            check = {
                "fixture_id": "synthetic",
                "passed": True,
                "reference_segment_count": 2,
                "artifact_sha256": {
                    name: sha256_file(fixture / name)
                    for name in ("reference.segments.json", "terms.json", "glossary.txt")
                },
            }
            write_json(fixture / "fixture-check.json", check)
            verify_common_prepared_fixture(fixture, "synthetic")

            reference["segments"].pop()
            write_json(fixture / "reference.segments.json", reference)
            check["artifact_sha256"]["reference.segments.json"] = sha256_file(
                fixture / "reference.segments.json"
            )
            write_json(fixture / "fixture-check.json", check)
            with self.assertRaisesRegex(PackError, "reference segment count mismatch"):
                verify_common_prepared_fixture(fixture, "synthetic")


if __name__ == "__main__":
    unittest.main()
