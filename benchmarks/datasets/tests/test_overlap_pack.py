from __future__ import annotations

import importlib.util
import copy
import hashlib
import json
import math
import os
import subprocess
import tempfile
import unittest
from unittest import mock
from pathlib import Path

import numpy as np

from benchmarks.scripts.dicow.common.fixtures import (
    CropGeometry,
    FixtureError,
    Interval,
    NORMALIZED_PEAK,
    WINDOW_SAMPLES,
    apply_crop,
    canonical_mix,
    classify_stable_words,
    crop_weights,
    derive_absent_terms,
    enforce_korean_all_or_nothing,
    oracle_activity,
    pad_single,
    quantize_pcm16,
    rank_fleurs_rows,
    require_target_geometry,
    select_fleurs_pairs,
)


ROOT = Path(__file__).resolve().parents[3]
PREPARE_PATH = ROOT / "benchmarks/datasets/prepare-overlap-pack-v1.py"


def load_prepare():
    spec = importlib.util.spec_from_file_location("overlap_prepare_tests", PREPARE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def load_verify():
    path = ROOT / "benchmarks/datasets/verify-overlap-pack-v1.py"
    spec = importlib.util.spec_from_file_location("overlap_verify_tests", path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


class MixerTests(unittest.TestCase):
    def test_fractional_overlap_remainder_is_floored_and_b_is_shifted(self):
        result = canonical_mix(np.array([1000] * 7, dtype=np.int16), np.array([-1000] * 9, dtype=np.int16))
        self.assertEqual(result.overlap_samples, 2)
        self.assertEqual(result.b_start, 5)
        self.assertEqual(result.support_b, Interval(5, 14))

    def test_zero_peak_is_evidence_blocker(self):
        with self.assertRaisesRegex(FixtureError, "zero-peak"):
            canonical_mix(np.zeros(10, dtype=np.int16), np.ones(10, dtype=np.int16))

    def test_conditional_mix_scaling_both_sides(self):
        below = canonical_mix(np.array([1000, -1000] * 50, dtype=np.int16), np.array([-1000, 1000] * 50, dtype=np.int16))
        above = canonical_mix(np.array([1000] * 100, dtype=np.int16), np.array([1000] * 100, dtype=np.int16))
        self.assertEqual(below.mix_gain, 1.0)
        self.assertLess(above.mix_gain, 1.0)
        self.assertAlmostEqual(above.pre_quantization_mix_peak, 0.999)

    def test_peak_normalization_literal_and_paired_amplitude(self):
        result = canonical_mix(np.array([32767] * 100, dtype=np.int16), np.array([1] * 100, dtype=np.int16))
        self.assertAlmostEqual(result.normalization_gain_a * (32767 / 32768), NORMALIZED_PEAK)
        self.assertEqual(result.component_a[0], result.component_a[10])

    def test_ties_to_even_int16(self):
        values = np.array([0.5, 1.5, 2.5, -0.5, -1.5]) / 32768.0
        self.assertEqual(quantize_pcm16(values).tolist(), [0, 2, 2, 0, -2])

    def test_pair_exceeding_window_rejected(self):
        a = np.ones(400_000, dtype=np.int16)
        b = np.ones(400_000, dtype=np.int16)
        with self.assertRaisesRegex(FixtureError, "exceeds"):
            canonical_mix(a, b)

    def test_longest_hike_length_still_fits(self):
        a = np.ones(round(13.815 * 16_000), dtype=np.int16)
        b = np.ones(round(10.08 * 16_000), dtype=np.int16)
        result = canonical_mix(a, b)
        self.assertLessEqual(result.support_b.end, WINDOW_SAMPLES)

    def test_single_padding_rejects_silent_truncation(self):
        self.assertEqual(pad_single(np.ones(9, dtype=np.int16)).shape, (WINDOW_SAMPLES,))
        with self.assertRaises(FixtureError):
            pad_single(np.ones(WINDOW_SAMPLES + 1, dtype=np.int16))


class CropAndSelectionTests(unittest.TestCase):
    def geometry(self, left: int, right: int) -> CropGeometry:
        core = Interval(1000, 1020)
        return CropGeometry(Interval(680, 1340), core, Interval(1000 - left, 1020 + right), left, right)

    def test_context_lengths_and_exact_ramps(self):
        for length in (0, 1, 319, 320):
            with self.subTest(length=length):
                geometry = self.geometry(length, length)
                weights = crop_weights(geometry)
                self.assertEqual(np.count_nonzero(weights[: geometry.crop.start]), 0)
                self.assertTrue(np.all(weights[geometry.core.start : geometry.core.end] == 1.0))
                if length:
                    expected_left = 0.5 - 0.5 * math.cos(math.pi / length)
                    expected_right = 1.0
                    self.assertAlmostEqual(weights[geometry.crop.start], expected_left)
                    self.assertAlmostEqual(weights[geometry.core.end], expected_right)
                    expected_left_vector = 0.5 - 0.5 * np.cos(
                        np.pi * np.arange(1, length + 1, dtype=np.float64) / length
                    )
                    expected_right_vector = 0.5 + 0.5 * np.cos(
                        np.pi * np.arange(length, dtype=np.float64) / length
                    )
                    np.testing.assert_array_equal(weights[geometry.crop.start : geometry.core.start], expected_left_vector)
                    np.testing.assert_array_equal(weights[geometry.core.end : geometry.crop.end], expected_right_vector)

    def test_crop_preserves_target_core_amplitude_and_no_gain(self):
        source = np.zeros(WINDOW_SAMPLES, dtype=np.int16)
        source[990:1040] = 12345
        geometry = self.geometry(10, 20)
        cropped = apply_crop(source, geometry)
        np.testing.assert_array_equal(cropped[1000:1020], source[1000:1020])
        self.assertTrue(np.all(cropped[:990] == 0))

    def test_boundary_crossing_and_unstable_repetition_stay_boundary(self):
        stable = [
            {"text": "non", "start_s": 0.10, "end_s": 0.12},
            {"text": "edge", "start_s": 0.36, "end_s": 0.38},
            {"text": "overlap", "start_s": 0.40, "end_s": 0.45},
        ]
        changed = [dict(item) for item in stable]
        changed[2]["start_s"] = 0.38
        words = classify_stable_words(
            [stable, changed], source_count=16_000, shift=0,
            source_support=Interval(0, 16_000), overlap=Interval(6_000, 10_000),
        )
        self.assertEqual([word.region for word in words], ["N", "boundary", "boundary"])

    def test_stable_o_and_n_define_nonempty_crop(self):
        records = [
            {"text": "non", "start_s": 0.10, "end_s": 0.12},
            {"text": "overlap", "start_s": 0.40, "end_s": 0.45},
        ]
        words = classify_stable_words(
            [records, records], source_count=16_000, shift=0,
            source_support=Interval(0, 16_000), overlap=Interval(6_000, 10_000),
        )
        geometry = require_target_geometry(words, Interval(6_000, 10_000))
        self.assertGreater(geometry.crop.length, geometry.core.length)

    def test_fleurs_rank_is_deterministic(self):
        rows = [{"row_id": str(index), "duration_s": 4 + index / 10} for index in range(9)]
        first = rank_fleurs_rows("en_us", rows)
        second = rank_fleurs_rows("en_us", reversed(rows))
        self.assertEqual([row["row_id"] for row in first], [row["row_id"] for row in second])
        self.assertEqual(len(first), 8)

    def test_fleurs_survivor_is_not_repaired_by_role_swap(self):
        rows = [{"row_id": str(index), "duration_s": 5} for index in range(8)]
        selected, attempts = select_fleurs_pairs(rows, {str(index): index != 1 for index in range(8)})
        self.assertEqual(attempts[0]["a"], "0")
        self.assertEqual(attempts[0]["b"], "1")
        self.assertEqual(selected[0], ("0", "2"))

    def test_fleurs_eight_row_exhaustion(self):
        rows = [{"row_id": str(index), "duration_s": 5} for index in range(8)]
        with self.assertRaisesRegex(FixtureError, "exhausted"):
            select_fleurs_pairs(rows, {str(index): False for index in range(8)})

    def test_absent_terms_are_normalized_and_exactly_eight(self):
        terms = [f"Term {index}" for index in range(10)] + ["present"]
        selected = derive_absent_terms(terms, ["PRESENT"])
        self.assertEqual(len(selected), 8)
        self.assertNotIn("present", selected)

    def test_absent_terms_use_scoring_separator_rules(self):
        terms = ["A-B"] + [f"term-{index}" for index in range(8)]
        selected = derive_absent_terms(terms, ["a b"])
        self.assertNotIn("A-B", selected)

    def test_korean_geometry_is_all_or_nothing(self):
        ids = [f"ko-{index}" for index in range(12)]
        passed = enforce_korean_all_or_nothing({item: True for item in ids}, ids)
        self.assertEqual(len(passed["utility_target_ids"]), 12)
        failed_map = {item: True for item in ids}
        failed_map[ids[5]] = False
        failed = enforce_korean_all_or_nothing(failed_map, ids)
        self.assertEqual(failed["status"], "korean_geometry_unavailable")
        self.assertEqual(failed["utility_target_ids"], [])
        self.assertIsNone(failed["utility_denominator"])


class OrchestrationTests(unittest.TestCase):
    def test_verifier_rejects_lexical_escape_and_symlink(self):
        verify = load_verify()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            pack = root / "pack"
            pack.mkdir()
            private = root / "private.wav"
            private.write_bytes(b"private")
            with self.assertRaisesRegex(verify.VerifyError, "normalized"):
                verify._inside(pack / ".." / "private.wav", pack)
            link = pack / "link.wav"
            link.symlink_to(private)
            with self.assertRaisesRegex(verify.VerifyError, "symlink"):
                verify._inside(link, pack)

    def test_independent_fleurs_parquet_scan_rederives_rank_duration_and_audio(self):
        prepare = load_prepare()
        verify = load_verify()
        import pyarrow as pa
        import pyarrow.parquet as pq

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.parquet"
            eligible_audio = prepare.wav_bytes(np.tile(np.array([1000, -1000], dtype=np.int16), 40_000))
            short_audio = prepare.wav_bytes(np.tile(np.array([1000, -1000], dtype=np.int16), 16_000))
            records = [
                {"id": f"row-{index}", "audio": {"bytes": eligible_audio, "path": None}, "transcription": f"text {index}"}
                for index in range(9)
            ] + [{"id": "short", "audio": {"bytes": short_audio, "path": None}, "transcription": "short"}]
            pq.write_table(pa.Table.from_pylist(records), path)
            rows = verify.scan_fleurs_candidates(
                path, "en_us", "maccheroni-overlap-pack-v1", 8, include_locale=True,
            )
            expected_ids = sorted(
                (f"row-{index}" for index in range(9)),
                key=lambda item: hashlib.sha256(("maccheroni-overlap-pack-v1" + "en_us" + item).encode()).hexdigest(),
            )[:8]
            self.assertEqual([row["row_id"] for row in rows], expected_ids)
            self.assertTrue(all(row["audio_payload"] == eligible_audio for row in rows))

    def test_independent_reference_derivation_rejects_forged_geometry(self):
        prepare = load_prepare()
        verify = load_verify()
        from benchmarks.scripts.dicow.aligner import qwen_reference

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            snapshot = root / "snapshot"
            snapshot.mkdir()
            (snapshot / "config.json").write_text("{}")
            rows = []
            family_ids = (
                [("hike", f"h{index}", "Korean") for index in range(12)]
                + [("fleurs-en", row_id, "English") for row_id in sorted(
                    (f"e{index}" for index in range(8)),
                    key=lambda item: hashlib.sha256(("maccheroni-overlap-pack-v1" + "en_us" + item).encode()).hexdigest(),
                )]
                + [("fleurs-it", row_id, "Italian") for row_id in sorted(
                    (f"i{index}" for index in range(8)),
                    key=lambda item: hashlib.sha256(("maccheroni-overlap-pack-v1" + "it_it" + item).encode()).hexdigest(),
                )]
            )
            for family, row_id, language in family_ids:
                path = root / f"{row_id}.wav"
                path.write_bytes(prepare.wav_bytes(np.array([1000, -1000] * 8000, dtype=np.int16)))
                rows.append({
                    "row_id": row_id, "family": family, "audio_path": str(path),
                    "audio_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                    "source_samples": 64000, "text": "one two", "language": language,
                    "rank": (
                        hashlib.sha256(("maccheroni-overlap-pack-v1" + ("en_us" if family == "fleurs-en" else "it_it") + row_id).encode()).hexdigest()
                        if family != "hike" else None
                    ),
                })
            aligner_manifest = {"model_id": qwen_reference.MODEL_ID, "model_revision": qwen_reference.MODEL_REVISION, "rows": rows}
            aligner_manifest["manifest_sha256"] = qwen_reference.canonical_json_hash(aligner_manifest)
            def generate(audio, text, language):
                return ["one", "two"], [
                    {"text": "one", "start_s": 0.1, "end_s": 0.2},
                    {"text": "two", "start_s": 0.7, "end_s": 0.8},
                ]
            first = qwen_reference.execute_batch(aligner_manifest, snapshot, generate)
            second = copy.deepcopy(first)
            second["process_id"] += 1
            fleurs_rows = {
                "en_us": [row for row in rows if row["family"] == "fleurs-en"],
                "it_it": [row for row in rows if row["family"] == "fleurs-it"],
            }
            candidate_manifests = {}
            for locale, locale_rows in fleurs_rows.items():
                candidate = {
                    "locale": locale,
                    "rows": [
                        {
                            "row_id": row["row_id"], "rank": row["rank"],
                            "audio_sha256": row["audio_sha256"], "source_samples": row["source_samples"],
                            "text": row["text"], "language": row["language"],
                        }
                        for row in locale_rows
                    ],
                }
                candidate["candidate_manifest_sha256"] = qwen_reference.canonical_json_hash(candidate)
                candidate_manifests[locale] = candidate
            source_plan = {"fleurs_rows": fleurs_rows, "fleurs_candidate_manifests": candidate_manifests}
            mixtures = [
                {"window_id": f"hike-{index:02d}", "target_a": f"h{2 * index}", "target_b": f"h{2 * index + 1}"}
                for index in range(6)
            ] + [
                {"window_id": "fleurs-en-00", "target_a": fleurs_rows["en_us"][0]["row_id"], "target_b": fleurs_rows["en_us"][1]["row_id"]},
                {"window_id": "fleurs-en-01", "target_a": fleurs_rows["en_us"][2]["row_id"], "target_b": fleurs_rows["en_us"][3]["row_id"]},
                {"window_id": "fleurs-it-00", "target_a": fleurs_rows["it_it"][0]["row_id"], "target_b": fleurs_rows["it_it"][1]["row_id"]},
                {"window_id": "fleurs-it-01", "target_a": fleurs_rows["it_it"][2]["row_id"], "target_b": fleurs_rows["it_it"][3]["row_id"]},
            ]
            derived = verify.derive_reference_contract(source_plan, mixtures, aligner_manifest, first, second)
            regions = {"geometry": list(derived["geometry"].values())}
            manifest = {"fleurs_selection": derived["fleurs_selection"]}
            verify.verify_frozen_reference_contract(derived, regions, manifest, mixtures)
            forged = copy.deepcopy(regions)
            forged["geometry"][0]["targets"][0]["geometry"]["crop"]["end"] += 1
            with self.assertRaisesRegex(verify.VerifyError, "independently"):
                verify.verify_frozen_reference_contract(derived, forged, manifest, mixtures)

    def test_independent_mapping_rejects_forged_slots(self):
        verify = load_verify()
        labels = ["left", "right"]
        provider = [[1, 1, 0, 0], [0, 0, 1, 1]]
        refs = [[1, 1, 0, 0], [0, 0, 1, 1]]
        from benchmarks.scripts.dicow.diarizer.community1_reference import freeze_mapping
        frozen = freeze_mapping(labels, provider, ["A", "B"], refs)
        verify.verify_frozen_mapping(frozen, labels, provider, ["A", "B"], refs)
        forged = copy.deepcopy(frozen)
        forged["slots"][0]["provider_label"] = "right"
        with self.assertRaisesRegex(verify.VerifyError, "mapping"):
            verify.verify_frozen_mapping(forged, labels, provider, ["A", "B"], refs)

    def test_reads_real_production_hike_selection_object(self):
        prepare = load_prepare()
        path = ROOT / "benchmarks/samples/public/acceptance-pack-v1/prepared/hike-code-switch-v1/selection.json"
        rows = prepare.read_hike_selection(path)
        self.assertEqual(len(rows), 12)
        self.assertEqual(rows[0]["sample_id"], "0c47a000-1772-419a-b7d4-cf9178a90cc0")

    def test_external_acquirer_is_create_only_and_hash_bound(self):
        prepare = load_prepare()
        payload = b"public fixture"
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "source.bin"
            prepare.acquire_public_file(
                "https://example.invalid/source.bin",
                destination,
                len(payload),
                __import__("hashlib").sha256(payload).hexdigest(),
                fetch=lambda _: payload,
            )
            self.assertEqual(destination.read_bytes(), payload)
            with self.assertRaisesRegex(prepare.PrepareError, "overwrite"):
                prepare.acquire_public_file(
                    "https://example.invalid/source.bin", destination, len(payload),
                    __import__("hashlib").sha256(payload).hexdigest(), fetch=lambda _: payload,
                )

    def test_external_acquirer_rejects_unpinned_or_non_https_payload(self):
        prepare = load_prepare()
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(prepare.PrepareError):
                prepare.acquire_public_file("file:///private/audio.wav", Path(directory) / "x", 1, "0" * 64, fetch=lambda _: b"x")
            with self.assertRaisesRegex(prepare.PrepareError, "hash"):
                prepare.acquire_public_file("https://example.invalid/x", Path(directory) / "x", 1, "0" * 64, fetch=lambda _: b"x")

    def test_exact_order_has_two_aligners_and_ten_fresh_community_children(self):
        prepare = load_prepare()
        windows = [f"w{index}" for index in range(10)]
        order = prepare.orchestration_order(windows)
        self.assertEqual(order[2:4], ["aligner:fresh-process-1", "aligner:fresh-process-2"])
        self.assertEqual(len([step for step in order if step.startswith("diarizer:")]), 10)
        self.assertEqual(order[-4:], ["verify:general", "verify:aligner", "verify:community", "publish:canonical-and-fragment"])

    def test_failure_preserves_attempt_but_never_publishes(self):
        prepare = load_prepare()
        events = []
        def execute(step):
            events.append(step)
            if step == "verify:aligner":
                raise RuntimeError("synthetic failure")
        with self.assertRaises(RuntimeError):
            prepare.run_orchestration([f"w{index}" for index in range(10)], execute, lambda: events.append("published"))
        self.assertNotIn("published", events)

    def test_production_build_uses_exact_process_and_verifier_order(self):
        prepare = load_prepare()
        with tempfile.TemporaryDirectory() as directory:
            run_root = Path(directory).resolve()
            (run_root / "task-state").mkdir()
            (run_root / "task-state/T2.json").write_text("{}")
            (run_root / "e0-preflight").mkdir()
            (run_root / "e0-preflight/canonical.json").write_text("{}")
            env_file = run_root / "base.env"
            env_file.write_text("X=1\n")
            events = []
            mixtures = [{"window_id": f"w{index}", "audio_path": f"/private/tmp/w{index}.wav"} for index in range(10)]
            def run(command):
                rendered = " ".join(command)
                if "run-batch" in rendered:
                    events.append("aligner")
                elif "run-one" in rendered:
                    events.append("community")
                elif "verify-overlap" in rendered:
                    events.append("verify-general")
                elif "qwen_reference verify-pack" in rendered:
                    events.append("verify-aligner")
                elif "community1_reference verify-pack" in rendered:
                    events.append("verify-community")
            with mock.patch.dict(prepare.os.environ, {"DICOW_RUN_ROOT": str(run_root)}), \
                 mock.patch.object(prepare, "source_fingerprint", return_value="a" * 64), \
                 mock.patch.object(prepare, "prepare_sources", side_effect=lambda _: events.append("prepare")), \
                 mock.patch.object(prepare, "_find_hf_snapshot", return_value=Path("/private/tmp/snapshot")), \
                 mock.patch.object(prepare, "_run", side_effect=run), \
                 mock.patch.object(prepare, "seal_regions", side_effect=lambda _: events.append("regions") or {"mixtures": mixtures}), \
                 mock.patch.object(prepare, "seal_final", side_effect=lambda _: events.append("final")), \
                 mock.patch.object(prepare, "publish", side_effect=lambda *_, **__: events.append("publish")):
                prepare.build(env_file)
            self.assertEqual(events, ["prepare", "aligner", "aligner", "regions"] + ["community"] * 10 + ["final", "verify-general", "verify-aligner", "verify-community", "publish"])

    def test_publication_rolls_back_if_second_selector_link_fails(self):
        prepare = load_prepare()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            attempt = root / "artifact/attempts/fingerprint"
            attempt.mkdir(parents=True)
            (attempt / "evidence.txt").write_text("sealed")
            run_root = root / "run"
            (run_root / "env.d").mkdir(parents=True)
            real_link = prepare.os.link
            calls = 0
            destinations = []
            def fail_second(source, destination):
                nonlocal calls
                calls += 1
                destinations.append(Path(destination).name)
                if calls == 2:
                    raise OSError("synthetic second-link failure")
                return real_link(source, destination)
            try:
                with mock.patch.object(prepare.os, "link", side_effect=fail_second):
                    with self.assertRaises(OSError):
                        prepare.publish(attempt, root / "artifact", run_root)
                self.assertFalse((root / "artifact/canonical.json").exists())
                self.assertFalse((run_root / "env.d/T10-pack.env").exists())
                self.assertEqual(destinations, ["canonical.json", "T10-pack.env"])
            finally:
                for path in [attempt / "evidence.txt", attempt]:
                    path.chmod(0o644 if path.is_file() else 0o755)

    def test_publication_rolls_back_on_keyboard_interrupt(self):
        prepare = load_prepare()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            attempt = root / "artifact/attempts/fingerprint"
            attempt.mkdir(parents=True)
            (attempt / "evidence.txt").write_text("sealed")
            run_root = root / "run"
            (run_root / "env.d").mkdir(parents=True)
            real_link = prepare.os.link
            calls = 0

            def interrupt_second(source, destination):
                nonlocal calls
                calls += 1
                if calls == 2:
                    raise KeyboardInterrupt()
                return real_link(source, destination)

            try:
                with mock.patch.object(prepare.os, "link", side_effect=interrupt_second):
                    with self.assertRaises(KeyboardInterrupt):
                        prepare.publish(attempt, root / "artifact", run_root)
                self.assertFalse((root / "artifact/canonical.json").exists())
                self.assertFalse((run_root / "env.d/T10-pack.env").exists())
                self.assertEqual(list((root / "artifact").glob(".canonical.*.tmp")), [])
                self.assertEqual(list((run_root / "env.d").glob(".T10-pack.*.tmp")), [])
            finally:
                for current, directories, files in os.walk(root, topdown=False):
                    for name in files:
                        (Path(current) / name).chmod(0o644)
                    for name in directories:
                        (Path(current) / name).chmod(0o755)

    def test_matching_published_attempt_resumes_without_model_work(self):
        prepare = load_prepare()
        for canonical_only in (False, True):
            with self.subTest(canonical_only=canonical_only), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                run_root = root / "run"
                env_file = root / "base.env"
                env_file.write_text("DICOW_RUN_ID=synthetic\n")
                (run_root / "task-state").mkdir(parents=True)
                (run_root / "task-state/T2.json").write_text("{}")
                (run_root / "e0-preflight").mkdir()
                (run_root / "e0-preflight/canonical.json").write_text("{}")
                fingerprint = "a" * 64
                attempt = run_root / "e1-overlap-pack/attempts" / fingerprint
                attempt.mkdir(parents=True)
                (attempt / "evidence.txt").write_text("sealed")
                prepare.publish(attempt, run_root / "e1-overlap-pack", run_root)
                canonical_path = run_root / "e1-overlap-pack/canonical.json"
                canonical_inode = canonical_path.stat().st_ino
                if canonical_only:
                    (run_root / "env.d/T10-pack.env").unlink()
                try:
                    with mock.patch.dict(os.environ, {"DICOW_RUN_ROOT": str(run_root)}), \
                         mock.patch.object(prepare, "source_fingerprint", return_value=fingerprint), \
                         mock.patch.object(prepare, "_run_pack_verifiers") as verifiers, \
                         mock.patch.object(prepare, "prepare_sources") as prepare_sources:
                        self.assertEqual(prepare.build(env_file), attempt)
                    verifiers.assert_called_once_with(env_file, attempt)
                    prepare_sources.assert_not_called()
                    self.assertEqual(canonical_path.stat().st_ino, canonical_inode)
                    self.assertTrue((run_root / "env.d/T10-pack.env").is_file())
                finally:
                    for current, directories, files in os.walk(root, topdown=False):
                        for name in files:
                            (Path(current) / name).chmod(0o644)
                        for name in directories:
                            (Path(current) / name).chmod(0o755)

    def test_published_binding_authenticates_fingerprint_selector_and_fragment(self):
        prepare = load_prepare()
        verify = load_verify()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            run_root = root / "run"
            (run_root / "task-state").mkdir(parents=True)
            (run_root / "task-state/T2.json").write_text("{}")
            (run_root / "e0-preflight").mkdir()
            (run_root / "e0-preflight/canonical.json").write_text("{}")
            env_file = root / "run.env"
            env_file.write_text("DICOW_RUN_ROOT={}\n".format(run_root))
            env_file.chmod(0o444)
            run_manifest = run_root / "run-manifest.json"
            run_manifest.write_text(json.dumps({
                "schema_version": "dicow-run-manifest-v1",
                "base_env": {
                    "path": str(env_file),
                    "sha256": prepare.sha256_file(env_file),
                    "bytes": env_file.stat().st_size,
                    "mode": "0444",
                    "keys": [],
                },
            }))
            run_manifest.chmod(0o444)
            fingerprint = prepare.source_fingerprint(
                prepare._build_inputs(run_root, env_file)
            )
            attempt = run_root / "e1-overlap-pack/attempts" / fingerprint
            attempt.mkdir(parents=True)
            (attempt / "evidence.txt").write_text("sealed")
            prepare.publish(attempt, run_root / "e1-overlap-pack", run_root)
            record = prepare._tree_record(attempt)
            environment = {
                "DICOW_RUN_ROOT": str(run_root),
                "DICOW_PACK_ROOT": str(attempt),
                "DICOW_PACK_ROOT_SHA256": str(record["sha256"]),
                "DICOW_PACK_ROOT_BYTES": str(record["bytes"]),
                "DICOW_PACK_ROOT_MODE": str(record["mode"]),
            }
            fragment = run_root / "env.d/T10-pack.env"
            try:
                with mock.patch.dict(os.environ, environment, clear=False):
                    self.assertEqual(verify.verify_published_binding(attempt)["record"], record)
                    run_manifest.chmod(0o644)
                    run_manifest_value = json.loads(run_manifest.read_text())
                    run_manifest_value["base_env"]["sha256"] = "0" * 64
                    run_manifest.write_text(json.dumps(run_manifest_value))
                    run_manifest.chmod(0o444)
                    with self.assertRaises(verify.VerifyError):
                        verify.verify_published_binding(attempt)
                    run_manifest.chmod(0o644)
                    run_manifest_value["base_env"]["sha256"] = prepare.sha256_file(env_file)
                    run_manifest.write_text(json.dumps(run_manifest_value))
                    run_manifest.chmod(0o444)
                    fragment.chmod(0o644)
                    fragment.write_text(fragment.read_text() + "EXTRA=1\n")
                    with self.assertRaises(verify.VerifyError):
                        verify.verify_published_binding(attempt)
            finally:
                for current, directories, files in os.walk(root, topdown=False):
                    for name in files:
                        (Path(current) / name).chmod(0o644)
                    for name in directories:
                        (Path(current) / name).chmod(0o755)

    def test_synthetic_complete_pack_passes_all_verifiers_and_rejects_corrupt_community_mask(self):
        prepare = load_prepare()
        verify = load_verify()
        from benchmarks.scripts.dicow.aligner import qwen_reference
        from benchmarks.scripts.dicow.common.preflight import artifact_record
        from benchmarks.scripts.dicow.diarizer import community1_reference

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            pack = root / "pack"
            pack.mkdir()
            waveform = np.tile(np.array([1000, -1000], dtype=np.int16), 8000)
            rows = []
            identities = (
                [("hike", f"h{index}", "Korean") for index in range(12)]
                + [("fleurs-en", row_id, "English") for row_id in sorted(
                    (f"e{index}" for index in range(8)),
                    key=lambda item: hashlib.sha256(("maccheroni-overlap-pack-v1" + "en_us" + item).encode()).hexdigest(),
                )]
                + [("fleurs-it", row_id, "Italian") for row_id in sorted(
                    (f"i{index}" for index in range(8)),
                    key=lambda item: hashlib.sha256(("maccheroni-overlap-pack-v1" + "it_it" + item).encode()).hexdigest(),
                )]
            )
            for family, row_id, language in identities:
                audio = pack / "sources" / family / f"{row_id}.wav"
                prepare.write_bytes_new(audio, prepare.wav_bytes(waveform))
                rows.append({
                    "row_id": row_id, "family": family, "audio_path": str(audio),
                    "audio_sha256": prepare.sha256_file(audio),
                    "source_samples": 64000 if family != "hike" else len(waveform),
                    "text": "non overlap", "language": language,
                    "terms": [f"absent-{int(row_id[1:]) % 8}"] if family == "hike" else [],
                    "rank": (
                        hashlib.sha256(("maccheroni-overlap-pack-v1" + ("en_us" if family == "fleurs-en" else "it_it") + row_id).encode()).hexdigest()
                        if family != "hike" else None
                    ),
                })
            ordered = {
                "schema_version": "1.0.0", "model_id": qwen_reference.MODEL_ID,
                "model_revision": qwen_reference.MODEL_REVISION, "rows": rows,
            }
            ordered["manifest_sha256"] = qwen_reference.canonical_json_hash(ordered)
            prepare.write_json_new(pack / "aligner/ordered-manifest.json", ordered)

            snapshot = root / "aligner-snapshot"
            snapshot.mkdir()
            (snapshot / "config.json").write_text("{}")
            def generate(_audio, _text, _language):
                return ["non", "overlap"], [
                    {"text": "non", "start_s": 0.10, "end_s": 0.15},
                    {"text": "overlap", "start_s": 0.70, "end_s": 0.75},
                ]
            first = qwen_reference.execute_batch(ordered, snapshot, generate)
            second = copy.deepcopy(first)
            second["process_id"] += 1
            prepare.write_json_new(pack / "aligner/repetition-1.json", first)
            prepare.write_json_new(pack / "aligner/repetition-2.json", second)

            hike_rows = rows[:12]
            mixtures = []
            row_by_id = {row["row_id"]: row for row in rows}
            for index in range(6):
                a, b = row_by_id[f"h{2 * index}"], row_by_id[f"h{2 * index + 1}"]
                mixed = canonical_mix(waveform, waveform)
                audio = pack / "mixtures" / f"hike-{index:02d}" / "mix.wav"
                prepare.write_bytes_new(audio, prepare.wav_bytes(mixed.mixture))
                mixtures.append(prepare._mix_record(f"hike-{index:02d}", a, b, mixed, audio))
            controls = []
            for index in range(2):
                audio = pack / "sources" / "fleurs-ko-clean" / f"k{index}.wav"
                prepare.write_bytes_new(audio, prepare.wav_bytes(waveform))
                controls.append({
                    "row_id": f"k{index}", "audio_path": str(audio),
                    "audio_sha256": prepare.sha256_file(audio), "source_samples": len(waveform),
                    "text": f"clean reference {index}", "language": "Korean", "rank": str(index),
                })
            absent = {
                "terms": derive_absent_terms(
                    {term for row in hike_rows for term in row["terms"]},
                    [item["text"] for item in controls],
                ),
                "normalized_references": [item["text"] for item in controls],
                "source_ids": [item["row_id"] for item in controls],
            }
            absent["list_sha256"] = qwen_reference.canonical_json_hash(absent)
            acceptance_root = root / "acceptance"
            ami_source = acceptance_root / "sources/ami/IN1009.Mix-Headset.wav"
            ami_window = pad_single(waveform)
            prepare.write_bytes_new(
                ami_source,
                prepare.wav_bytes(np.concatenate((np.zeros(95 * 16_000, dtype=np.int16), ami_window, ami_window))),
            )
            hike_source = acceptance_root / "sources/hike/data/test-00000-of-00001.parquet"
            ami_zip = acceptance_root / "sources/ami/ami_public_manual_1.6.2.zip"
            prepare.write_bytes_new(hike_source, b"synthetic hike source")
            prepare.write_bytes_new(ami_zip, b"synthetic AMI archive")
            public_hashes = {
                str(hike_source): "cc807d5e31c92df85a46445b28df2b239f7fb33943a35502161af61c1ee8b4d0",
                str(ami_source): "7ee90aac9105734ab40d3085dcb4d0ad4ba06adc1c24facb2ad843529b489506",
                str(ami_zip): "b56e5babb2496b8795deeeda7e71178d7fbc9963f94276cf2a3f4b56ebbc9f9d",
            }
            fleurs_sizes = (401_722_686, 806_437_035, 291_159_866)
            fleurs_hashes = {}
            for index, size in enumerate(fleurs_sizes):
                path = root / f"fleurs-{index}.parquet"
                with path.open("wb") as stream:
                    stream.truncate(size)
                fleurs_hashes[str(path)] = hashlib.sha256(f"fleurs-{index}".encode()).hexdigest()
            ami_records = []
            for index, start in enumerate((95, 125)):
                audio = pack / "parity" / f"ami-in1009-{index}.wav"
                prepare.write_bytes_new(audio, prepare.wav_bytes(ami_window))
                ami_records.append({
                    "window_id": f"ami-in1009-{index}", "source_range_s": [start, start + 30],
                    "audio_path": str(audio), "audio_sha256": prepare.sha256_file(audio), "use": "parity-only",
                })
            fleurs_rows_by_locale = {"en_us": rows[12:20], "it_it": rows[20:28]}
            fleurs_candidate_manifests = {}
            for locale, locale_rows in fleurs_rows_by_locale.items():
                candidate = {
                    "locale": locale,
                    "rows": [
                        {
                            "row_id": row["row_id"], "rank": row.get("rank"),
                            "audio_sha256": row["audio_sha256"], "source_samples": row["source_samples"],
                            "text": row["text"], "language": row["language"],
                        }
                        for row in locale_rows
                    ],
                }
                candidate["candidate_manifest_sha256"] = qwen_reference.canonical_json_hash(candidate)
                fleurs_candidate_manifests[locale] = candidate
            source_plan = {
                "schema_version": "1.0.0", "pack_id": "overlap-pack-v1",
                "hike_rows": hike_rows,
                "fleurs_rows": fleurs_rows_by_locale,
                "fleurs_candidate_manifests": fleurs_candidate_manifests,
                "korean_clean_controls": controls, "korean_absent_terms": absent,
                "ami_parity_windows": ami_records,
                "preselected_mixtures": mixtures, "acceptance_root": str(acceptance_root),
                "source_hashes_before": public_hashes,
                "fleurs_source_hashes_before": fleurs_hashes,
            }
            prepare.write_json_new(pack / "source-plan.json", source_plan)
            real_sha256_file = prepare.sha256_file
            def source_sha256(path):
                value = str(path)
                return fleurs_hashes[value] if value in fleurs_hashes else real_sha256_file(Path(path))
            with mock.patch.object(prepare, "_host_source_hashes", return_value=public_hashes), \
                 mock.patch.object(prepare, "sha256_file", side_effect=source_sha256):
                regions = prepare.seal_regions(pack)
            self.assertEqual(len(regions["mixtures"]), 10)
            self.assertEqual(len(regions["singles"]), 22)

            run_root = root / "run"
            e0 = run_root / "e0-preflight"
            t9_attempt = e0 / "attempts" / ("a" * 64 + "-0001")
            t9_attempt.mkdir(parents=True)
            runtime_root = root / "speech-runtime"
            runtime_root.mkdir()
            binary = runtime_root / "speech"
            binary.write_bytes(b"synthetic speech binary")
            binary.chmod(0o555)
            cache_root = root / "speech-cache"
            model_tree = cache_root / "qwen3-speech/models/aufklarer/Pyannote-Community-1-CoreML"
            model_tree.mkdir(parents=True)
            (model_tree / "weights.bin").write_bytes(b"synthetic weights")
            (model_tree / "weights.bin").chmod(0o444)
            model_tree.chmod(0o555)
            (snapshot / "config.json").chmod(0o444)
            snapshot.chmod(0o555)
            sandbox = ROOT / "benchmarks/scripts/dicow/diarizer/deny-network.sb"
            canonical = {
                "schema_version": "dicow-e0-preflight-v1", "run_id": "synthetic-run", "run_root": str(run_root),
                "attempt_fingerprint": "a" * 64,
                "attempt_root": str(t9_attempt), "paths": {"community_snapshot": str(model_tree)},
                "mlx_reused_symbols": [], "mlx_implementation_source": "synthetic",
                "inspection_sha256": "b" * 64, "inspection_outcome": "evidence_blocker",
                "inspection_verdict": "revise", "inspection_blocker": "synthetic",
                "runtime_bindings": {
                    "aligner": {
                        "model_id": qwen_reference.MODEL_ID, "model_revision": qwen_reference.MODEL_REVISION,
                        "snapshot": {"path": str(snapshot), "record": artifact_record(snapshot, immutable=True)},
                    },
                    "community1": {
                        "model_id": community1_reference.EXPECTED_MODEL_ID,
                        "model_revision": community1_reference.EXPECTED_MODEL_REVISION,
                        "binary": {"path": str(binary), "record": artifact_record(binary, immutable=True)},
                        "model_tree": {"path": str(model_tree), "record": artifact_record(model_tree, immutable=True)},
                        "sandbox_profile": {"path": str(sandbox), "record": artifact_record(sandbox)},
                    },
                },
                "resource": {}, "resource_policy": {}, "future_resource_ledger": {}, "host": {}, "acquisitions": {},
                "promotion_records": {}, "promotion_final_paths": {"speech-runtime": str(runtime_root)},
                "promotion_staged_paths": {},
            }
            prepare.write_json_new(e0 / "canonical.json", canonical)
            runtime_env = {"DICOW_RUN_ID": "synthetic-run", "DICOW_RUN_ROOT": str(run_root)}
            with mock.patch.dict(os.environ, runtime_env):
                runtime = community1_reference.verify_runtime(e0)
            stdout = "synthetic log\n" + json.dumps({"segments": [
                {"speaker": "a", "start": 0.0, "end": 1.0},
                {"speaker": "b", "start": 0.6, "end": 1.6},
            ]}) + "\n"
            with mock.patch.dict(os.environ, {"QWEN3_CACHE_DIR": str(cache_root)}):
                for mixture_index, mixture in enumerate(regions["mixtures"]):
                    audio = Path(mixture["audio_path"])
                    process_stdout = 'synthetic log\n{"segments": []}\n' if mixture_index == 0 else stdout
                    evidence = community1_reference.ProcessEvidence(
                        community1_reference.command_for(binary, audio), process_stdout, "", 0, 1.0,
                    )
                    community1_reference.write_process_evidence(
                        pack / "community" / mixture["window_id"], evidence, runtime,
                    )
            prepare.seal_final(pack)
            real_verify_sha256_file = verify.sha256_file
            def verify_sha256(path):
                value = str(path)
                return public_hashes[value] if value in public_hashes else real_verify_sha256_file(Path(path))
            with mock.patch.dict(os.environ, runtime_env), \
                 mock.patch.object(verify, "sha256_file", side_effect=verify_sha256), \
                 mock.patch.object(verify, "verify_hike_inputs", return_value=None), \
                 mock.patch.object(verify, "verify_t9_fleurs_inputs", return_value=None):
                verify.verify_pack(pack)
                qwen_reference.verify_pack(pack, e0)
                community1_reference.verify_pack(pack)
                foreign = pack / "foreign-private.wav"
                foreign.write_bytes(prepare.wav_bytes(waveform))
                with self.assertRaisesRegex(verify.VerifyError, "inventory"):
                    verify.verify_pack(pack)
                foreign.unlink()
                corrupt = pack / "targets/hike-01" / prepare.artifact_id("h2") / "stno-full-community1.f32le"
                payload = bytearray(corrupt.read_bytes())
                payload[0:4] = np.array([1.0], dtype="<f4").tobytes()
                corrupt.write_bytes(payload)
                with self.assertRaises((verify.VerifyError, FixtureError)):
                    verify.verify_pack(pack)
            snapshot.chmod(0o755)
            (snapshot / "config.json").chmod(0o644)
            model_tree.chmod(0o755)
            (model_tree / "weights.bin").chmod(0o644)

    def test_build_script_exposes_only_build_and_verify(self):
        script = (ROOT / "benchmarks/datasets/build-overlap-pack-v1.zsh").read_text()
        self.assertIn("build)", script)
        self.assertIn("verify)", script)
        self.assertNotIn("download)", script)

    def test_fingerprint_covers_build_inputs_locks_launcher_and_acceptance_rules(self):
        prepare = load_prepare()
        required = {
            "benchmarks/datasets/build-overlap-pack-v1.zsh",
            "benchmarks/datasets/acceptance-pack-v1.json",
            "benchmarks/datasets/acceptance_pack.py",
            "benchmarks/scripts/dicow/run_with_env.py",
            "benchmarks/env/dicow-reference/uv.lock",
            "benchmarks/env/dicow-aligner/uv.lock",
        }
        self.assertTrue(required.issubset(set(prepare.FINGERPRINT_INPUTS)))

    def test_declaration_freezes_exact_counts_and_license_boundary(self):
        declaration = json.loads((ROOT / "benchmarks/datasets/overlap-pack-v1.json").read_text())
        self.assertEqual(declaration["selection"]["pair_targets"], 20)
        self.assertEqual(sum(declaration["selection"]["constructed_mixtures"].values()), 10)
        self.assertEqual(sum(item["rows"] for item in declaration["selection"]["aligner_order"]), 28)
        self.assertEqual(declaration["licenses"]["private_audio"], "rejected")


if __name__ == "__main__":
    unittest.main()
