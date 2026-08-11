from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from score import main


def write_segments(path: Path, text: str) -> None:
    document = {
        "segments": [
            {
                "start_s": 0.0,
                "end_s": 1.0,
                "text": text,
            }
        ]
    }
    path.write_text(json.dumps(document), encoding="utf-8")


class ScoreOutputTests(unittest.TestCase):
    def test_existing_output_is_preserved(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            reference = root / "reference.json"
            hypothesis = root / "hypothesis.json"
            output = root / "scores.json"
            write_segments(reference, "hello")
            write_segments(hypothesis, "hello")
            sentinel = b"preserved scorer output\n"
            output.write_bytes(sentinel)

            with patch.object(
                sys,
                "argv",
                [
                    "score.py",
                    "--reference",
                    str(reference),
                    "--hypothesis",
                    str(hypothesis),
                    "--output",
                    str(output),
                ],
            ):
                with self.assertRaises(FileExistsError):
                    main()

            self.assertEqual(output.read_bytes(), sentinel)


if __name__ == "__main__":
    unittest.main()
