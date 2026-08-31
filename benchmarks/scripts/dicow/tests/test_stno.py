from __future__ import annotations

import unittest

import numpy as np

from benchmarks.scripts.dicow.common.fixtures import FRAME_COUNT, Interval, oracle_activity
from benchmarks.scripts.dicow.common.stno import (
    clean_target_stno,
    crop_k_frames,
    decode_reference,
    encode_reference,
    reference_to_runtime,
    runtime_to_reference,
    target_stno,
)


class ActivityAndSTNOTests(unittest.TestCase):
    def test_frame_centers_immediately_before_and_at_support_ends(self):
        activity = oracle_activity((Interval(160, 480),))
        self.assertEqual(activity[0, 0], 1)
        self.assertEqual(activity[0, 1], 0)  # center 480 is outside [160,480)
        before = oracle_activity((Interval(161, 481),))
        self.assertEqual(before[0, 0], 0)
        self.assertEqual(before[0, 1], 1)

    def test_half_open_overlap_membership(self):
        activity = np.zeros((2, FRAME_COUNT), dtype=np.uint8)
        activity[0, 3:6] = 1
        activity[1, 5:8] = 1
        mask = target_stno(activity, 0)
        self.assertEqual(mask[:, 4].tolist(), [0, 1, 0, 0])
        self.assertEqual(mask[:, 5].tolist(), [0, 0, 0, 1])
        self.assertEqual(mask[:, 6].tolist(), [0, 0, 1, 0])

    def test_outside_k_discards_target_non_target_and_overlap_bits(self):
        activity = np.ones((2, FRAME_COUNT), dtype=np.uint8)
        frames = np.zeros(FRAME_COUNT, dtype=np.uint8)
        frames[10] = 1
        mask = target_stno(activity, 0, frames)
        self.assertTrue(np.all(mask[:, 0] == [1, 0, 0, 0]))
        self.assertTrue(np.all(mask[:, 10] == [0, 0, 0, 1]))

    def test_crop_edge_frame_uses_interval_intersection(self):
        frames = crop_k_frames(Interval(320, 321))
        self.assertEqual(frames[0], 0)
        self.assertEqual(frames[1], 1)
        self.assertEqual(frames[2], 0)

    def test_clean_crop_ignores_foreign_activity(self):
        target = np.zeros(FRAME_COUNT, dtype=np.uint8)
        target[8] = 1
        frames = np.zeros(FRAME_COUNT, dtype=np.uint8)
        frames[7:10] = 1
        mask = clean_target_stno(target, frames)
        self.assertTrue(np.all(mask[2:] == 0))
        self.assertEqual(mask[:, 8].tolist(), [0, 1, 0, 0])

    def test_empty_region_is_all_silence(self):
        activity = np.ones((3, FRAME_COUNT), dtype=np.uint8)
        mask = target_stno(activity, 1, np.zeros(FRAME_COUNT, dtype=np.uint8))
        self.assertTrue(np.all(mask[0] == 1))
        self.assertTrue(np.all(mask[1:] == 0))

    def test_little_endian_round_trip_and_single_transpose(self):
        activity = np.zeros((1, FRAME_COUNT), dtype=np.uint8)
        activity[0, 2] = 1
        mask = target_stno(activity, 0)
        payload = encode_reference(mask)
        self.assertEqual(len(payload), 4 * FRAME_COUNT * 4)
        np.testing.assert_array_equal(decode_reference(payload), mask)
        batch = mask[None, :, :]
        runtime = reference_to_runtime(batch)
        self.assertEqual(runtime.shape, (1, 1500, 4))
        np.testing.assert_array_equal(runtime_to_reference(runtime), batch)


if __name__ == "__main__":
    unittest.main()
