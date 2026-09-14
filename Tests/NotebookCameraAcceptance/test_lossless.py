"""Contract checks for the evidence recorder, never a substitute for Simulator pixels."""
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from lossless import SimulatorPixelSamples
from measure_lossless import gesture_intervals, sample_timing


class RecorderTests(unittest.TestCase):
    def test_slow_capture_intervals_do_not_claim_continuous_observation(self):
        timing = sample_timing([
            {'index': 0, 'status': 'captured', 'startedAt': 0, 'endedAt': 1},
            {'index': 1, 'status': 'capture_error', 'startedAt': 1.05, 'endedAt': 2.05},
            {'index': 2, 'status': 'captured', 'startedAt': 2.1, 'endedAt': 3.1},
        ])
        self.assertEqual(timing['maximumCaptureDurationSeconds'], 1)
        self.assertEqual(timing['largestPossibleGapBetweenObservedFramesSeconds'], 3.1)
        self.assertEqual(timing['gapBounds'], [
            {'earlier': 0, 'later': 2, 'minimumSeconds': 1.1, 'maximumSeconds': 3.1}])

    def test_capture_error_is_retained_with_its_timing_instead_of_a_zero_error_image(self):
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root) / 'samples'
            recorder = SimulatorPixelSamples('device', directory, interval=0, maximum_samples=1)
            with patch('lossless.subprocess.run', return_value=subprocess.CompletedProcess([], 1, b'', b'capture failed')):
                recorder.start()
                recorder.thread.join(2)
                recorder.stop()
            result = json.loads((directory / 'manifest.json').read_text())
            self.assertEqual(result['samples'][0]['status'], 'capture_error')
            self.assertGreaterEqual(result['samples'][0]['endedAt'], result['samples'][0]['startedAt'])
            self.assertEqual(result['stopReason'], 'sample_or_byte_limit')
            self.assertFalse(result['isFPSMeasurement'])

    def test_byte_limit_finishes_after_the_admitted_original_sample(self):
        raw = b'\x89PNG\r\n\x1a\n' + struct.pack('>I', 13) + b'IHDR' + struct.pack('>II', 1640, 2360)
        def capture(argv, **_):
            Path(argv[-1]).write_bytes(raw)
            return subprocess.CompletedProcess(argv, 0, b'', b'')
        with tempfile.TemporaryDirectory() as root:
            recorder = SimulatorPixelSamples('device', Path(root) / 'samples', interval=0, maximum_bytes=len(raw))
            with patch('lossless.subprocess.run', side_effect=capture):
                recorder.start()
                recorder.thread.join(2)
                recorder.stop()
            self.assertEqual(len(recorder.samples), 1)
            self.assertEqual(recorder.samples[0]['width'], 1640)
            self.assertEqual(recorder.samples[0]['height'], 2360)
            self.assertEqual(recorder.stop_reason, 'sample_or_byte_limit')

    def test_camera_intervals_require_real_beginnings_and_close_before_the_next_pan(self):
        trace = [
            {'kind': 'pan', 'time': 1, 'before': 0, 'after': 1},
            {'kind': 'pan', 'time': 1.2, 'before': 1, 'after': 2},
            {'kind': 'camera', 'phase': 'began', 'time': 2},
            {'kind': 'camera', 'phase': 'changed', 'time': 2.1},
            {'kind': 'camera', 'phase': 'ended', 'time': 2.8},
            {'kind': 'camera', 'phase': 'ended', 'time': 3},
            {'kind': 'pan', 'time': 4, 'before': 0, 'after': 0},
        ]
        intervals = gesture_intervals(trace)
        self.assertEqual(len(intervals), 2)
        self.assertEqual((intervals[0]['start'], intervals[0]['end']), (1, 1.2))
        self.assertEqual((intervals[1]['start'], intervals[1]['end']), (2, 2.8))
        self.assertTrue(intervals[1]['endedNormally'])


if __name__ == '__main__':
    unittest.main()
