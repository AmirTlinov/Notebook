"""Lossless Simulator display samples alongside real gestures; never an FPS counter."""
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import threading
import time
import ctypes


def mach_nanos():
    library = ctypes.CDLL(None)
    class Timebase(ctypes.Structure):
        _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]
    info = Timebase()
    library.mach_timebase_info(ctypes.byref(info))
    library.mach_absolute_time.restype = ctypes.c_uint64
    return library.mach_absolute_time()*info.numer//info.denom


class SimulatorPixelSamples:
    """A bounded serial screenshot reader; it neither moves nor queries app UI."""

    def __init__(self, device, directory, interval=0.05, timeout=10,
                 maximum_bytes=1024 * 1024 * 1024, maximum_samples=6000):
        if not 0 <= interval <= 1 or timeout <= 0 or maximum_bytes <= 0 or maximum_samples <= 0:
            raise ValueError('Invalid capture bounds')
        self.device, self.directory = device, Path(directory)
        self.interval, self.timeout = interval, timeout
        self.maximum_bytes, self.maximum_samples = maximum_bytes, maximum_samples
        self.finished = threading.Event()
        self.thread = None
        self.samples = []
        self.stop_reason = None

    def start(self):
        if self.thread is not None:
            raise RuntimeError('A sample recorder starts exactly once')
        self.directory.mkdir(parents=True, exist_ok=False)
        self.thread = threading.Thread(target=self._run, name='notebook-simulator-pixels', daemon=True)
        self.thread.start()

    def _run(self):
        total_bytes = 0
        try:
            with (self.directory / 'samples.jsonl').open('w') as journal:
                while not self.finished.is_set():
                    if len(self.samples) >= self.maximum_samples or total_bytes >= self.maximum_bytes:
                        self.stop_reason = 'sample_or_byte_limit'
                        return
                    path = self.directory / ('frame-%06d.png' % len(self.samples))
                    entry = {'index': len(self.samples), 'file': path.name,
                             'startedAt': time.time(), 'startedMonotonicNS': time.monotonic_ns(), 'startedMachNS': mach_nanos()}
                    try:
                        result = subprocess.run(['xcrun', 'simctl', 'io', self.device,
                                                 'screenshot', '--type=png', str(path)],
                                                capture_output=True, timeout=self.timeout)
                        entry.update(endedAt=time.time(), endedMonotonicNS=time.monotonic_ns(), endedMachNS=mach_nanos())
                        if result.returncode:
                            raise RuntimeError(result.stderr.decode(errors='replace')[:2000])
                        raw = path.read_bytes()
                        if raw[:8] != b'\x89PNG\r\n\x1a\n' or raw[12:16] != b'IHDR':
                            raise RuntimeError('Simulator returned no complete PNG header')
                        width, height = struct.unpack('>II', raw[16:24])
                        entry.update(status='captured', width=width, height=height, bytes=len(raw),
                                     sha256=hashlib.sha256(raw).hexdigest())
                        total_bytes += len(raw)
                    except Exception as error:
                        entry.setdefault('endedAt', time.time())
                        entry.setdefault('endedMonotonicNS', time.monotonic_ns())
                        entry.setdefault('endedMachNS', mach_nanos())
                        entry.update(status='capture_error', error=str(error))
                    self.samples.append(entry)
                    journal.write(json.dumps(entry, sort_keys=True) + '\n')
                    journal.flush()
                    self.finished.wait(self.interval)
            self.stop_reason = 'scenario_finished'
        except Exception as error:
            self.stop_reason = 'recorder_error: ' + str(error)

    def stop(self):
        if self.thread is None:
            return
        self.finished.set()
        self.thread.join(self.timeout + 5)
        if self.thread.is_alive():
            raise RuntimeError('Bounded Simulator screenshot reader failed to stop')
        manifest = {'format': 2, 'device': self.device, 'commonClock': 'mach_absolute_ns',
                    'kind': 'Original simctl Simulator display PNG; no view/cache/native geometry substitute',
                    'timing': 'Capture instant lies within each startedAt/endedAt interval; gaps are not observed frames',
                    'isFPSMeasurement': False, 'minimumIdleSeconds': self.interval,
                    'maximumBytes': self.maximum_bytes, 'maximumSamples': self.maximum_samples,
                    'stopReason': self.stop_reason, 'samples': self.samples,
                    'instrumentSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
        (self.directory / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')

