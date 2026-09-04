import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCORER = ROOT / "scripts/score-speaker-proposal.py"

UNKNOWN = "UNKNOWN"


def _rttm(rows):
    return "".join(
        f"SPEAKER synthetic 1 {start:.3f} {end - start:.3f} <NA> <NA> {speaker} <NA> <NA>\n"
        for speaker, start, end in rows
    )


def _candidate(speaker, overlap_s, share):
    return {"speaker": speaker, "overlap_s": overlap_s, "share": share}


class SyntheticFixture:
    """A three-speaker reference with a run whose evidence covers every state."""

    reference = [
        ("A", 0.0, 10.0),
        ("B", 10.0, 20.0),
        ("A", 20.0, 30.0),
        ("B", 30.0, 40.0),
        ("A", 38.0, 40.0),
        ("C", 40.0, 50.0),
    ]
    timeline = [
        {"speaker": "0", "start_s": 0.0, "end_s": 9.5},
        {"speaker": "1", "start_s": 10.0, "end_s": 20.0},
        {"speaker": "0", "start_s": 20.0, "end_s": 30.0},
        {"speaker": "1", "start_s": 30.0, "end_s": 39.0},
        {"speaker": "2", "start_s": 40.0, "end_s": 50.0},
    ]
    segments = [
        {"start_s": 0.0, "end_s": 5.0, "speaker": "0", "text": "a"},
        {"start_s": 5.0, "end_s": 10.0, "speaker": "1", "text": "b"},
        {"start_s": 10.0, "end_s": 15.0, "speaker": UNKNOWN, "text": "c"},
        {"start_s": 22.0, "end_s": 28.0, "speaker": UNKNOWN, "text": "d"},
        {"start_s": 30.0, "end_s": 36.0, "speaker": UNKNOWN, "text": "e"},
        {"start_s": 45.0, "end_s": 50.0, "speaker": UNKNOWN, "text": "f"},
        {"start_s": 36.0, "end_s": 40.0, "speaker": UNKNOWN, "text": "g"},
        {"start_s": 15.0, "end_s": 20.0, "speaker": UNKNOWN, "text": "h"},
        {"start_s": 19.0, "end_s": 21.0, "speaker": UNKNOWN, "text": "i"},
    ]
    evidence = {
        # dominant share, coverage below threshold; top "1" -> B, truth B
        2: ("coverage_below_threshold", [_candidate("1", 4.0, 0.8), _candidate("0", 1.0, 0.2)]),
        # exact tie; truth A
        3: ("no_dominant_speaker", [_candidate("0", 3.0, 0.5), _candidate("1", 3.0, 0.5)]),
        # lead; top "0" -> A, truth B (top wrong)
        4: ("no_dominant_speaker", [_candidate("0", 3.3, 0.55), _candidate("1", 2.7, 0.45)]),
        # no candidates; truth C
        5: ("no_overlapping_turn", []),
        # near tie; top "1" -> B, truth B
        6: ("no_dominant_speaker", [_candidate("1", 2.08, 0.52), _candidate("0", 1.92, 0.48)]),
        # near tie; top "0" -> A, truth B (top wrong)
        7: ("no_dominant_speaker", [_candidate("0", 2.6, 0.52), _candidate("1", 2.4, 0.48)]),
        # lead; top "1"; truth is an exact reference tie (ambiguous)
        8: ("no_dominant_speaker", [_candidate("1", 0.87, 0.58), _candidate("0", 0.63, 0.42)]),
    }

    @classmethod
    def conflicts(cls):
        thresholds = {
            "dominant_speaker_share": 0.6,
            "minimum_timeline_coverage": 0.5,
            "overlap_epsilon_s": 1e-9,
        }
        conflicts = []
        for index, (outcome, candidates) in cls.evidence.items():
            conflicts.append(
                {
                    "segment_index": index,
                    "kind": "ambiguous_speaker",
                    "candidates": [c["speaker"] for c in candidates],
                    "reason": "synthetic",
                    "speaker_attribution": {
                        "outcome": outcome,
                        "candidates": candidates,
                        "timeline_coverage": 0.4 if outcome == "coverage_below_threshold" else 0.9,
                        "thresholds": thresholds,
                    },
                }
            )
        # A duplicate overlapping-speech record must not displace the ambiguous one.
        conflicts.append(
            {
                "segment_index": 4,
                "kind": "overlapping_speech",
                "candidates": ["1", "0"],
                "reason": "synthetic",
                "speaker_attribution": {
                    "outcome": "no_dominant_speaker",
                    "candidates": [_candidate("1", 9.0, 0.9), _candidate("0", 1.0, 0.1)],
                    "timeline_coverage": 0.9,
                    "thresholds": thresholds,
                },
            }
        )
        return conflicts

    @classmethod
    def proposals(cls, segments_sha256):
        def record(index, **extra):
            outcome, candidates = cls.evidence[index]
            return {
                "segment_index": index,
                "acoustic_outcome": outcome,
                "acoustic_timeline_coverage": 0.9,
                "acoustic_candidates": candidates,
                **extra,
            }

        def answer(index, speaker):
            return {
                "segment_index": index,
                "proposed_speaker": speaker,
                "disposition": "propose",
                "reason": "synthetic",
            }

        return {
            "schema_version": "1.0.0",
            "layer": "speaker-proposal",
            "constraint": "confirm-or-decline",
            "source_segments_sha256": segments_sha256,
            "source_coverage": {"complete": True},
            "unattributed_speakers": ["UNASSIGNED", "UNKNOWN"],
            "proposals": [
                record(2, proposed_speaker="1", reason="synthetic"),
                record(6, proposed_speaker="1", reason="synthetic"),
                record(7, proposed_speaker="0", reason="synthetic"),
            ],
            "declined": [
                record(
                    3,
                    reason="tie",
                    cause="no_top_ranked_candidate",
                    top_ranked_candidate=None,
                    model_answer=answer(3, "0"),
                ),
                record(
                    4,
                    reason="disagreed",
                    cause="model_disagreed_with_top_ranked_candidate",
                    top_ranked_candidate="0",
                    model_answer=answer(4, "1"),
                ),
                record(
                    5,
                    reason="no candidates",
                    cause="no_acoustic_candidates",
                    top_ranked_candidate=None,
                    model_answer=answer(5, "2"),
                ),
                record(8, reason="unsure", cause="model_declined", top_ranked_candidate="1"),
            ],
            "batches": [],
        }

    @classmethod
    def write(cls, root: Path):
        run = root / "run"
        (run / "merged").mkdir(parents=True)
        (run / "diarization").mkdir()
        (root / "reference.rttm").write_text(_rttm(cls.reference), encoding="utf-8")
        (run / "diarization" / "timeline.json").write_text(
            json.dumps(cls.timeline), encoding="utf-8"
        )
        segments_path = run / "merged" / "segments.json"
        segments_path.write_text(
            json.dumps({"schema_version": "1.0.0", "num_speakers": 3, "segments": cls.segments}),
            encoding="utf-8",
        )
        (run / "merged" / "conflicts.json").write_text(
            json.dumps(cls.conflicts()), encoding="utf-8"
        )
        (run / "manifest.json").write_text(
            json.dumps({"run_id": "synthetic", "status": "succeeded", "models": []}),
            encoding="utf-8",
        )
        derived = run / "derived" / "synthetic-derived"
        (derived / "speaker").mkdir(parents=True)
        sha = hashlib.sha256(segments_path.read_bytes()).hexdigest()
        (derived / "speaker" / "proposals.json").write_text(
            json.dumps(cls.proposals(sha)), encoding="utf-8"
        )
        (derived / "manifest.json").write_text(
            json.dumps({"derived_id": "synthetic-derived", "status": "succeeded"}),
            encoding="utf-8",
        )
        return run, derived


def _run(arguments, cwd):
    return subprocess.run(
        [sys.executable, str(SCORER), *arguments],
        cwd=cwd,
        capture_output=True,
        text=True,
        check=False,
    )


class ScoreSpeakerProposalTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.run, self.derived = SyntheticFixture.write(self.root)

    def tearDown(self):
        self.tmp.cleanup()

    def _score(self, *extra):
        output = self.root / "report.json"
        completed = _run(
            [
                "--reference-rttm",
                str(self.root / "reference.rttm"),
                "--run",
                str(self.run),
                "--json",
                str(output),
                *extra,
            ],
            cwd=self.root,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return json.loads(output.read_text(encoding="utf-8")), completed.stdout

    def test_help_exits_zero(self):
        completed = _run(["--help"], cwd=self.root)
        self.assertEqual(completed.returncode, 0)
        self.assertIn("--reference-rttm", completed.stdout)

    def test_mapping_is_maximal_overlap(self):
        report, _ = self._score()
        mapping = report["mapping"]
        self.assertEqual(mapping["mapping"], {"0": "A", "1": "B", "2": "C"})
        self.assertAlmostEqual(mapping["overlap_matrix_s"]["0"]["A"], 19.5)
        self.assertAlmostEqual(mapping["overlap_matrix_s"]["1"]["B"], 19.0)
        self.assertAlmostEqual(mapping["overlap_matrix_s"]["1"]["A"], 1.0)
        self.assertAlmostEqual(mapping["overlap_matrix_s"]["2"]["C"], 10.0)
        self.assertEqual(mapping["hypothesis_purity"], {"0": 1.0, "1": 1.0, "2": 1.0})

    def test_acoustic_only_measurement(self):
        report, markdown = self._score()
        self.assertNotIn("proposal", report)
        segments = report["segments"]
        self.assertEqual(segments["total"], 9)
        self.assertEqual(segments["attributed"], 2)
        self.assertEqual(segments["unattributed"], 7)
        self.assertEqual(
            segments["truth_classes_all"],
            {"clear": 8, "ambiguous": 1, "no_reference_speech": 0},
        )
        self.assertEqual(
            segments["evidence_states_unattributed"],
            {
                "no_candidates": 1,
                "exact_tie": 1,
                "near_tie": 2,
                "lead": 2,
                "dominant_low_coverage": 1,
                "single_candidate": 0,
            },
        )
        attribution = report["acoustic_attribution"]
        self.assertEqual((attribution["strict_correct"], attribution["strict_defined"]), (1, 2))
        top = report["top_ranked_candidate"]["overall"]
        self.assertEqual(top["n"], 5)
        self.assertEqual((top["strict_correct"], top["strict_defined"]), (2, 4))
        self.assertEqual((top["lenient_correct"], top["lenient_defined"]), (2, 4))
        by_state = report["top_ranked_candidate"]["by_evidence_state"]
        self.assertEqual(by_state["dominant_low_coverage"]["strict_correct"], 1)
        self.assertEqual(by_state["near_tie"]["strict_correct"], 1)
        self.assertEqual(by_state["near_tie"]["strict_defined"], 2)
        self.assertEqual(by_state["lead"]["strict_correct"], 0)
        self.assertEqual(by_state["lead"]["strict_defined"], 1)
        self.assertIn("## Acoustic accuracy", markdown)
        # The ambiguous-speaker record, not the overlapping-speech duplicate, decides.
        row = next(r for r in report["ledger"] if r["segment_index"] == 4)
        self.assertEqual(row["top_ranked_candidate"], "0")

    def test_proposal_measurement(self):
        report, markdown = self._score("--proposal", str(self.derived))
        proposal = report["proposal"]
        self.assertEqual(proposal["artifact"]["proposals"], 3)
        self.assertEqual(proposal["artifact"]["declined"], 4)
        self.assertAlmostEqual(proposal["artifact"]["confirmation_coverage"], 3 / 7)
        confirmations = proposal["confirmations"]
        self.assertEqual((confirmations["strict_correct"], confirmations["strict_defined"]), (2, 3))
        self.assertEqual(proposal["confirmations_by_evidence_state"]["near_tie"]["strict_correct"], 1)
        causes = proposal["declines_by_cause"]
        self.assertEqual(set(causes), {
            "no_top_ranked_candidate",
            "model_disagreed_with_top_ranked_candidate",
            "no_acoustic_candidates",
            "model_declined",
        })
        tie = causes["no_top_ranked_candidate"]
        self.assertEqual(tie["justified"], 1)
        self.assertEqual(tie["model_answer"]["strict_correct"], 1)
        self.assertEqual(tie["model_versus_top"]["model_only"], 1)
        disagreed = causes["model_disagreed_with_top_ranked_candidate"]
        self.assertEqual(disagreed["justified"], 1)
        self.assertEqual(disagreed["top_ranked"]["strict_correct"], 0)
        self.assertEqual(disagreed["model_answer"]["strict_correct"], 1)
        self.assertEqual(disagreed["model_versus_top"]["model_only"], 1)
        none = causes["no_acoustic_candidates"]
        self.assertEqual(none["model_answer"]["strict_correct"], 1)
        declined = causes["model_declined"]
        self.assertEqual(declined["justified"], 1)
        self.assertEqual(declined["top_ranked"]["strict_defined"], 0)
        layer = proposal["language_layer"]
        self.assertAlmostEqual(layer["top_ranked_baseline_strict_precision"], 0.5)
        self.assertAlmostEqual(layer["confirmed_strict_precision"], 2 / 3)
        self.assertEqual(layer["confirmed_strict_wrong"], 1)
        unconstrained = layer["unconstrained_model_answers"]
        self.assertEqual((unconstrained["strict_correct"], unconstrained["strict_defined"]), (5, 6))
        self.assertIn("### Declines by cause", markdown)
        self.assertEqual(report["inputs"]["derived"]["derived_id"], "synthetic-derived")

    def test_overcautious_decline_is_named(self):
        artifact = self.derived / "speaker" / "proposals.json"
        document = json.loads(artifact.read_text(encoding="utf-8"))
        # Move the correct confirmation on segment 2 into a model decline.
        confirmed = [p for p in document["proposals"] if p["segment_index"] == 2][0]
        document["proposals"] = [p for p in document["proposals"] if p["segment_index"] != 2]
        confirmed.pop("proposed_speaker")
        confirmed.update(cause="model_declined", top_ranked_candidate="1", reason="unsure")
        document["declined"].append(confirmed)
        artifact.write_text(json.dumps(document), encoding="utf-8")
        report, _ = self._score("--proposal", str(self.derived))
        declined = report["proposal"]["declines_by_cause"]["model_declined"]
        self.assertEqual(declined["n"], 2)
        self.assertEqual(declined["overcautious"], 1)
        self.assertEqual(declined["justified"], 1)

    def test_rejects_a_proposal_made_over_another_transcript(self):
        artifact = self.derived / "speaker" / "proposals.json"
        document = json.loads(artifact.read_text(encoding="utf-8"))
        document["source_segments_sha256"] = "0" * 64
        artifact.write_text(json.dumps(document), encoding="utf-8")
        completed = _run(
            [
                "--reference-rttm",
                str(self.root / "reference.rttm"),
                "--run",
                str(self.run),
                "--proposal",
                str(self.derived),
            ],
            cwd=self.root,
        )
        self.assertEqual(completed.returncode, 2)
        self.assertIn("not made over this run", completed.stderr)

    def test_rejects_a_proposal_that_does_not_confirm_the_top_candidate(self):
        artifact = self.derived / "speaker" / "proposals.json"
        document = json.loads(artifact.read_text(encoding="utf-8"))
        document["proposals"][0]["proposed_speaker"] = "0"
        artifact.write_text(json.dumps(document), encoding="utf-8")
        completed = _run(
            [
                "--reference-rttm",
                str(self.root / "reference.rttm"),
                "--run",
                str(self.run),
                "--proposal",
                str(self.derived),
            ],
            cwd=self.root,
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("does not confirm", completed.stderr)


if __name__ == "__main__":
    unittest.main()
