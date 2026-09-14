"""Time/identity contracts for the instrument; no camera or display-performance claims."""
import unittest
import numpy as np
from temporal_provenance import (run_tag, checksum, decode_witness, origin_bounds,
                                 eligible_contacts, possible_same_cohort)
from measure_joint import calibration, associate
from test_joint import row


class TemporalProvenanceTests(unittest.TestCase):
    def test_visual_strip_requires_the_run_identity_and_checksum(self):
        tag = run_tag('fcaf38dd-004b-4314-b400-fe394cbba037')
        payload = tag.to_bytes(4, 'big')+(12345).to_bytes(3, 'big')
        data = b'\xa5'+payload+bytes([checksum(payload)])
        image = np.full((400, 1640, 3), 127, dtype=np.uint8)
        for i in range(72):
            value = 255 if data[i//8] & (1 << (7-i%8)) else 0
            image[168:180, 532+i*8:540+i*8] = value
        self.assertEqual(decode_witness(image, 2, tag), 12345)
        self.assertIsNone(decode_witness(image, 2, tag+1))
        image[168:180, 532+71*8:540+71*8] = 255-image[168:180, 532+71*8:540+71*8]
        self.assertIsNone(decode_witness(image, 2, tag))

    def test_origin_uses_all_conservative_constraints_without_best_fit(self):
        video = [{'time': float(i), 'witness': i} for i in range(1, 5)]
        png = [{'index': 1, 'witness': 2, 'startedMachNS': 102_100_000_000, 'endedMachNS': 102_200_000_000},
               {'index': 2, 'witness': 3, 'startedMachNS': 103_000_000_000, 'endedMachNS': 103_100_000_000}]
        result = origin_bounds(png, video)
        self.assertEqual(result['status'], 'bounded')
        self.assertAlmostEqual(result['lower'], 99.1)
        self.assertAlmostEqual(result['upper'], 101.1)
        png[1].update(startedMachNS=203_000_000_000, endedMachNS=203_100_000_000)
        self.assertEqual(origin_bounds(png, video)['status'], 'inconsistent')

    def test_missing_origin_and_reappearing_cohort_are_not_silently_aligned(self):
        self.assertEqual(origin_bounds([], [])['status'], 'unavailable')
        png = [{'index': 1, 'witness': 2, 'startedMachNS': 1, 'endedMachNS': 2}]
        video = [{'time': 1, 'witness': 1}, {'time': 2, 'witness': 2}, {'time': 3, 'witness': 1}]
        self.assertEqual(origin_bounds(png, video)['status'], 'inconsistent')

    def test_reused_geometric_pose_cannot_assign_a_different_cycle(self):
        origin = {'status': 'bounded', 'lower': 100, 'upper': 100.02}
        intervals = [{'start': 101, 'end': 101.04}, {'start': 701, 'end': 702}]
        before, after = row(shift=-10), row()
        after.update(time=1, eligibleContacts=eligible_contacts({'time': 1}, intervals, origin))
        points = np.array([after['methods']['chroma4']['centers'][c] for c in ('blue', 'orange')])+.5
        poses = [{'interval': i, 'points': points.tolist(), 'delta': [[10, 0], [10, 0]]} for i in range(2)]
        self.assertEqual(associate(after, before, poses), [0])
        after['eligibleContacts'] = eligible_contacts(after, intervals, {'status': 'unavailable'})
        self.assertEqual(associate(after, before, poses), [])
        self.assertEqual(eligible_contacts({'time': 1}, intervals, {**origin, 'upper': 100.05}), [])

    def test_calibration_keeps_all_same_cohort_candidates_but_rejects_other_cycles(self):
        png = row(); png.update(witness=17, startedMachNS=101_000_000_000, endedMachNS=101_100_000_000)
        matched, same_cohort_variation, other_cycle = row(), row(green=(3, 4)), row(green=(30, 40))
        for i, video in enumerate((matched, same_cohort_variation, other_cycle)):
            video.update(index=i, witness=17 if i < 2 else 18, time=1.04 if i < 2 else 101.04)
        origin = {'status': 'bounded', 'lower': 100, 'upper': 100.02}
        report = calibration([png], [matched, same_cohort_variation, other_cycle], origin)
        self.assertEqual(report['pairs'][0]['videoFrames'], [0, 1])
        self.assertEqual(report['maximumObservedDeltaPixels'], 5)
        self.assertFalse(report['codecCalibrationCertified'])
        self.assertFalse(possible_same_cohort(png, {**other_cycle, 'witness': 17}, origin))


if __name__ == '__main__':
    unittest.main()
