"""Pinned offline AVFoundation decoder; ffprobe supplies independent frame/PTS inventory."""
from fractions import Fraction
from collections import Counter
import hashlib
import json
from pathlib import Path
import platform
import struct
import subprocess

import numpy as np


def digest(path):
    with Path(path).open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


def read_exact(stream, count):
    data = stream.read(count)
    if len(data) != count:
        raise ValueError('Truncated native decoder output')
    return data


def read_record(stream):
    length = struct.unpack('>I', read_exact(stream, 4))[0]
    if not 0 < length <= 65536:
        raise ValueError('Invalid native decoder record size')
    return json.loads(read_exact(stream, length))


def decode_records(stream, probe, metadata):
    """Reject missing/extra frames, shifted PTS, geometry changes, and partial output."""
    if read_exact(stream, 8) != b'NBAVR001':
        raise ValueError('Unrecognized native decoder protocol')
    header = read_record(stream)
    source = probe['streams'][0]
    width, height = source['width'], source['height']
    if (header.get('kind'), header.get('protocol'), header.get('width'), header.get('height'),
        header.get('pixelFormat')) != ('header', 1, width, height, 'BGRA'):
        raise ValueError('Native decoder header does not match source geometry')
    expected = [Fraction(frame['pts']) * Fraction(source['time_base']) for frame in probe['frames']]
    metadata['header'], metadata['frames'] = header, []
    for index, pts in enumerate(expected):
        row = read_record(stream)
        if row.get('kind') != 'frame' or row.get('index') != index:
            raise ValueError('Missing or reordered native video frame')
        if row.get('ptsTimescale', 0) <= 0 or Fraction(row['ptsValue'], row['ptsTimescale']) != pts:
            raise ValueError('Native video PTS differs from independent ffprobe inventory')
        stride = row.get('bytesPerRow', 0)
        if ((row.get('width'), row.get('height'), row.get('pixelFormat')) != (width, height, 'BGRA')
            or stride < width*4 or stride > width*4+65536 or row.get('payloadBytes') != stride*height):
            raise ValueError('Native video frame has invalid pixel geometry')
        raw = read_exact(stream, stride*height)
        padded = np.frombuffer(raw, np.uint8).reshape(height, stride)
        bgra = padded[:, :width*4].reshape(height, width, 4)
        # Channel order only. No geometric/chroma resampling or colour-space guess.
        rgb = bgra[:, :, [2, 1, 0]]
        metadata['frames'].append(row)
        yield {'index': index, 'time': float(pts), 'ptsValue': row['ptsValue'],
               'ptsTimescale': row['ptsTimescale']}, rgb
    end = read_record(stream)
    if end != {'kind': 'end', 'frames': len(expected), 'status': 'completed'} or stream.read(1):
        raise ValueError('Native decoder did not end with the complete source inventory')
    metadata['completion'] = end


def validate_packet_inventory(probe, packets):
    """Account for every container sample, including explicit trailing discard samples.

    Container nb_frames counts encoded samples. An edit can exclude a final
    sample at the half-open presentation end; neither decoder displays it.
    This is not permission to omit an in-range or unflagged source frame.
    """
    source = probe['streams'][0]
    declared = source.get('nb_frames')
    if declared is not None and int(declared) != len(packets):
        raise ValueError('Container frame count differs from its packet inventory')
    remaining = Counter(int(frame['pts']) for frame in probe['frames'])
    excluded = []
    for packet in packets:
        if 'pts' not in packet:
            raise ValueError('A source packet has no presentation timestamp')
        pts = int(packet['pts'])
        if remaining[pts]:
            remaining[pts] -= 1
            continue
        end = (int(source.get('start_pts', 0)) + int(source['duration_ts'])
               if 'duration_ts' in source else None)
        if 'D' not in packet.get('flags', '') or end is None or pts < end:
            raise ValueError('An undisplayed packet is not an explicit discard outside the presentation end')
        excluded.append(packet)
    if any(remaining.values()):
        raise ValueError('A decoded frame has no corresponding source packet')
    return {'declaredContainerFrames': int(declared) if declared is not None else None,
            'encodedPackets': len(packets), 'decodedFrames': len(probe['frames']),
            'excludedTrailingDiscardPackets': excluded,
            'meaning': 'Every encoded packet is a decoded frame or explicit discard at/after the half-open presentation end'}


class NativeVideo:
    """One immutable source and compiled decoder per measurement output directory."""
    def __init__(self, video, output):
        self.video = Path(video).resolve()
        self.output = Path(output)/'native-decoder'
        self.output.mkdir(exist_ok=False)
        source = Path(__file__).with_name('NativeVideoDecoder.swift')
        copied = self.output/source.name
        copied.write_bytes(source.read_bytes())
        (self.output/'native_video.py').write_bytes(Path(__file__).read_bytes())
        self.binary = self.output/'NativeVideoDecoder'
        def command(args):
            return subprocess.check_output(args, stderr=subprocess.STDOUT).decode().strip()
        compiler = command(['xcrun', '--find', 'swiftc'])
        sdk = command(['xcrun', '--sdk', 'macosx', '--show-sdk-path'])
        build = [compiler, '-swift-version', '6', '-parse-as-library', '-O', '-sdk', sdk,
                 str(copied), '-o', str(self.binary)]
        with (self.output/'build.log').open('wb') as log:
            subprocess.run(build, check=True, stdout=log, stderr=subprocess.STDOUT)
        probe_command = ['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
            'stream=width,height,codec_name,pix_fmt,color_range,color_space,color_transfer,color_primaries,chroma_location,time_base,start_pts,duration_ts,nb_frames:frame=pts,pts_time',
            '-show_frames', '-show_streams', '-of', 'json', str(self.video)]
        self.probe = json.loads(subprocess.check_output(probe_command))
        if len(self.probe.get('streams', [])) != 1 or not self.probe.get('frames'):
            raise ValueError('Source video has no complete independent frame inventory')
        if any('pts' not in frame for frame in self.probe['frames']):
            raise ValueError('A source video frame has no presentation timestamp')
        (self.output/'ffprobe.json').write_text(json.dumps(self.probe, indent=2)+'\n')
        packet_command = ['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_packets', '-of', 'json', str(self.video)]
        packet_raw = subprocess.check_output(packet_command)
        (self.output/'packets.json').write_bytes(packet_raw)
        packet_inventory = validate_packet_inventory(self.probe, json.loads(packet_raw)['packets'])
        self.metadata = {'format': 1, 'video': str(self.video), 'videoSHA256': digest(self.video),
            'decoderSourceSHA256': digest(copied), 'decoderBinarySHA256': digest(self.binary),
            'adapterSHA256': digest(self.output/'native_video.py'),
            'compiler': compiler, 'compilerVersion': command([compiler, '--version']),
            'sdk': sdk, 'sdkVersion': command(['xcrun', '--sdk', 'macosx', '--show-sdk-version']),
            'hostOS': command(['sw_vers']), 'hostArchitecture': platform.machine(),
            'buildCommand': build, 'ffprobeCommand': probe_command,
            'packetCommand': packet_command, 'packetInventorySHA256': digest(self.output/'packets.json'),
            'packetInventory': packet_inventory,
            'ffprobeVersion': command(['ffprobe', '-version']).splitlines()[0],
            'independentlyInventoriedFrames': len(self.probe['frames']),
            'sourceColorMetadata': {k: self.probe['streams'][0].get(k) for k in
                ('codec_name', 'pix_fmt', 'color_range', 'color_space', 'color_transfer', 'color_primaries', 'chroma_location')},
            'completed': False}
        self._write_receipt()

    @property
    def width(self):
        return self.probe['streams'][0]['width']

    @property
    def height(self):
        return self.probe['streams'][0]['height']

    def _write_receipt(self):
        (self.output/'receipt.json').write_text(json.dumps(self.metadata, indent=2)+'\n')

    def frames(self):
        with (self.output/'decode.log').open('wb') as log:
            process = subprocess.Popen([str(self.binary), str(self.video)], stdout=subprocess.PIPE, stderr=log)
            try:
                yield from decode_records(process.stdout, self.probe, self.metadata)
                code = process.wait(timeout=30)
                if code:
                    raise ValueError('Native decoder process failed; see decode.log')
                if digest(self.video) != self.metadata['videoSHA256']:
                    raise ValueError('Source video changed during native decoding')
                frames = self.metadata.pop('frames')
                frame_data = json.dumps(frames, indent=2)+'\n'
                (self.output/'frames.json').write_text(frame_data)
                self.metadata.update(completed=True, decodedFrames=len(frames),
                    frameMetadataSHA256=hashlib.sha256(frame_data.encode()).hexdigest())
            finally:
                process.stdout.close()
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=30)
                self._write_receipt()

    def summary(self):
        return {k: self.metadata[k] for k in ('videoSHA256', 'decoderSourceSHA256', 'decoderBinarySHA256',
            'adapterSHA256', 'compilerVersion', 'sdkVersion', 'sourceColorMetadata', 'packetInventory', 'completed')}
