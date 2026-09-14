"""Decoder integrity tests; synthetic videos do not establish product pixel accuracy."""
import copy
from fractions import Fraction
import hashlib
import io
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

import numpy as np
from native_video import NativeVideo, decode_records, validate_packet_inventory


def record(value):
    raw = json.dumps(value).encode()
    return struct.pack('>I', len(raw))+raw


def protocol(frame_change=None, end_change=None, payload=None):
    header = {'kind': 'header', 'protocol': 1, 'width': 2, 'height': 1, 'pixelFormat': 'BGRA'}
    frame = {'kind': 'frame', 'index': 0, 'ptsValue': 3, 'ptsTimescale': 10,
             'width': 2, 'height': 1, 'bytesPerRow': 12, 'payloadBytes': 12, 'pixelFormat': 'BGRA'}
    frame.update(frame_change or {})
    end = {'kind': 'end', 'frames': 1, 'status': 'completed'}
    end.update(end_change or {})
    # Two coloured pixels and four padding bytes; padding must not become pixels.
    raw = bytes([11, 22, 33, 255, 44, 55, 66, 255, 90, 91, 92, 93]) if payload is None else payload
    return b'NBAVR001'+record(header)+record(frame)+raw+record(end)


class NativeVideoTests(unittest.TestCase):
    probe = {'streams': [{'width': 2, 'height': 1, 'time_base': '1/600'}], 'frames': [{'pts': 180}]}

    def test_preserves_fractional_pts_and_only_reorders_channels_without_row_padding(self):
        metadata = {}
        frames = list(decode_records(io.BytesIO(protocol()), self.probe, metadata))
        self.assertEqual(frames[0][0], {'index': 0, 'time': .3, 'ptsValue': 3, 'ptsTimescale': 10})
        np.testing.assert_array_equal(frames[0][1], [[[33, 22, 11], [66, 55, 44]]])
        self.assertEqual(metadata['completion']['frames'], 1)

    def test_rejects_pts_mismatch_missing_frames_truncation_and_extra_output(self):
        invalid = [protocol(frame_change={'ptsValue': 4}), protocol(frame_change={'index': 1}),
                   protocol(frame_change={'bytesPerRow': 4}), protocol()[:-2], protocol()+b'x',
                   protocol(end_change={'frames': 2}), protocol(end_change={'status': 'failed'})]
        for raw in invalid:
            with self.subTest(length=len(raw)):
                with self.assertRaises((ValueError, json.JSONDecodeError)):
                    list(decode_records(io.BytesIO(raw), self.probe, {}))

    def test_container_trailing_discard_does_not_hide_an_in_range_missing_frame(self):
        probe = {'streams': [{'nb_frames': '3', 'start_pts': 0, 'duration_ts': 20}],
                 'frames': [{'pts': 0}, {'pts': 10}]}
        packets = [{'pts': 0, 'flags': 'K__'}, {'pts': 10, 'flags': '___'}, {'pts': 20, 'flags': '_D_'}]
        receipt = validate_packet_inventory(probe, packets)
        self.assertEqual(receipt['encodedPackets'], 3)
        self.assertEqual(receipt['decodedFrames'], 2)
        self.assertEqual(receipt['excludedTrailingDiscardPackets'], [packets[-1]])
        # Reject unexplained loss, even one sample, and reject a discard inside
        # the presentation interval. Container counts still have to be exact.
        invalid = [packets[:-1], [*packets[:-1], {'pts': 20, 'flags': '___'}],
                   [*packets[:-1], {'pts': 19, 'flags': '_D_'}],
                   [packets[0], {'pts': 11, 'flags': '___'}, packets[-1]]]
        for candidate in invalid:
            with self.subTest(packets=candidate), self.assertRaises(ValueError):
                validate_packet_inventory(probe, candidate)
        with self.assertRaises(ValueError):
            validate_packet_inventory({**probe, 'frames': [*probe['frames'], {'pts': 15}]}, packets)

    def test_compiled_native_decoder_preserves_all_real_encoded_frames_and_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            video = root/'fixture.mp4'
            colors = [(220, 20, 30), (20, 220, 30), (20, 30, 220)]
            source = np.array([np.full((48, 64, 3), color, dtype=np.uint8) for color in colors])
            command = ['ffmpeg', '-v', 'error', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', '64x48',
                '-framerate', '2', '-i', 'pipe:0', '-frames:v', '3', '-vf', 'scale=out_color_matrix=bt709',
                '-c:v', 'libx264', '-crf', '10', '-pix_fmt', 'yuv420p', '-colorspace', 'bt709',
                '-color_primaries', 'bt709', '-color_trc', 'iec61966-2-1', str(video)]
            subprocess.run(command, input=source.tobytes(), check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            original = hashlib.sha256(video.read_bytes()).hexdigest()
            decoder = NativeVideo(video, root)
            frames = list(decoder.frames())
            self.assertEqual(len(frames), 3)
            self.assertEqual([Fraction(r['ptsValue'], r['ptsTimescale']) for r, _ in frames],
                             [Fraction(0), Fraction(1, 2), Fraction(1)])
            self.assertEqual([int(np.argmax(pixels[24, 32])) for _, pixels in frames], [0, 1, 2])
            self.assertEqual(hashlib.sha256(video.read_bytes()).hexdigest(), original)
            receipt = json.loads((root/'native-decoder/receipt.json').read_text())
            self.assertTrue(receipt['completed'])
            self.assertEqual(receipt['decodedFrames'], receipt['independentlyInventoriedFrames'])
            self.assertEqual(receipt['packetInventory']['encodedPackets'], 3)
            self.assertEqual(receipt['packetInventory']['excludedTrailingDiscardPackets'], [])
            self.assertEqual(receipt['videoSHA256'], original)
            self.assertEqual(len(receipt['decoderBinarySHA256']), 64)
            self.assertIn('Apple Swift', receipt['compilerVersion'])
            metadata = json.loads((root/'native-decoder/frames.json').read_text())
            self.assertEqual(len(metadata), 3)
            self.assertEqual(metadata[0]['colorMetadata']['yCbCrMatrix'], 'ITU_R_709_2')


if __name__ == '__main__':
    unittest.main()
