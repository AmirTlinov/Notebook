"""Per-launch Simulator xctrace attach, gated by actual application identity.

This module collects traces; it never certifies FPS or absence of hangs merely
because a trace exists. The ordinary UI runner owns app launch and all gestures.
"""
from pathlib import Path
import ctypes
import json
import os
import plistlib
import select
import signal
import struct
import subprocess
import threading
import time
import uuid
import xml.etree.ElementTree as ET


class TraceError(RuntimeError):
    pass


class TraceStartNotification:
    """Own xctrace's documented recording-start notification, not its log prose."""
    def __init__(self):
        self.name = 'com.amirtlinov.notebook.trace-start.' + str(uuid.uuid4())
        self._library = ctypes.CDLL('/usr/lib/system/libsystem_notify.dylib')
        self._library.notify_register_file_descriptor.argtypes = [ctypes.c_char_p,
            ctypes.POINTER(ctypes.c_int), ctypes.c_int, ctypes.POINTER(ctypes.c_int)]
        self._library.notify_register_file_descriptor.restype = ctypes.c_uint32
        self._library.notify_cancel.argtypes = [ctypes.c_int]
        self._library.notify_cancel.restype = ctypes.c_uint32
        fd, token = ctypes.c_int(-1), ctypes.c_int(-1)
        status = self._library.notify_register_file_descriptor(
            self.name.encode(), ctypes.byref(fd), 0, ctypes.byref(token))
        if status:
            raise TraceError('Could not register trace-start notification: ' + str(status))
        self._fd, self._token = fd.value, token.value

    def __enter__(self):
        return self

    def __exit__(self, kind, error, traceback):
        try:
            self.close()
        except TraceError as cleanup:
            if error is None:
                raise
            if hasattr(error, 'add_note'):
                error.add_note(str(cleanup))

    def wait(self, timeout):
        if self._token is None:
            raise TraceError('Trace-start notification is already closed')
        if not select.select([self._fd], [], [], timeout)[0]:
            return False
        data = os.read(self._fd, 4)
        if len(data) != 4 or struct.unpack('!I', data)[0] != self._token:
            raise TraceError('Trace-start notification token does not match its owner')
        return True

    def close(self):
        if self._token is not None:
            token, self._token = self._token, None
            # notify_cancel owns closing the descriptor it allocated.
            status = self._library.notify_cancel(token)
            if status:
                raise TraceError('Could not cancel trace-start notification: ' + str(status))


def canonical_uuid(value):
    return str(uuid.UUID(str(value))).upper()


def macho_uuid(path):
    """Read the exact thin arm64 simulator executable's LC_UUID, bounded."""
    with Path(path).open('rb') as stream:
        header = stream.read(32)
        if len(header) != 32 or struct.unpack_from('<I', header)[0] != 0xfeedfacf:
            raise TraceError('Expected a thin little-endian Mach-O 64 executable')
        count, length = struct.unpack_from('<II', header, 16)
        if count > 4096 or length > 1_048_576:
            raise TraceError('Mach-O command inventory exceeds the bounded identity reader')
        commands = stream.read(length)
    if len(commands) != length:
        raise TraceError('Truncated Mach-O load commands')
    offset = 0
    for _ in range(count):
        if offset + 8 > length:
            raise TraceError('Truncated Mach-O command')
        kind, size = struct.unpack_from('<II', commands, offset)
        if size < 8 or offset + size > length:
            raise TraceError('Invalid Mach-O command length')
        if kind == 0x1b:
            if size < 24:
                raise TraceError('Truncated LC_UUID')
            return str(uuid.UUID(bytes=commands[offset+8:offset+24])).upper()
        offset += size
    raise TraceError('Executable has no LC_UUID')


def write_json(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    try:
        with temporary.open('x') as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write('\n')
        temporary.chmod(0o600)
        # Hard-link publication refuses to overwrite a prior acknowledgement.
        os.link(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def read_json(path):
    path = Path(path)
    if path.stat().st_size > 16384:
        raise TraceError('Oversized trace handshake message')
    return json.loads(path.read_text())


def validate_toc(path, identity, simulator_udid):
    tree = ET.parse(path)
    devices = tree.findall('.//target/device')
    if not any(node.get('uuid', '').upper() == simulator_udid.upper() for node in devices):
        raise TraceError('Trace did not record the requested Simulator device')
    if not any(node.get('pid') == str(identity['pid']) for node in tree.findall('.//process')):
        raise TraceError('Trace contains no inventory of the actual launched PID')
    tables = tree.findall('.//table')
    profiles = [node for node in tables if node.get('schema') == 'time-profile']
    hangs = [node for node in tables if node.get('schema') == 'potential-hangs']
    if hangs and any(node.get('hangs-threshold') not in (None, '100') for node in hangs):
        raise TraceError('Recorded Hangs table does not use the required 100 ms threshold')
    return {'schemas': sorted({node.get('schema') for node in tables if node.get('schema')}),
            'assessment': 'captured_unassessed', 'requestedHangThresholdMS': 100,
            'instrumentSchemaRecognized': bool(profiles and hangs),
            'recordedHangThresholdMS': 100 if hangs and all(node.get('hangs-threshold') == '100' for node in hangs) else None,
            'mainThreadCoverageVerified': False, 'droppedFramesMeasured': False}


class TraceHandshake:
    def __init__(self, *, session_id, control_directory, evidence_directory, simulator_udid,
                 expected_bundle_id, expected_executable_uuid, segment_time_limit_seconds=660):
        self.session = canonical_uuid(session_id)
        self.control = Path(control_directory).absolute()
        self.evidence = Path(evidence_directory).absolute()
        self.udid = canonical_uuid(simulator_udid)
        self.bundle = expected_bundle_id
        self.binary_uuid = canonical_uuid(expected_executable_uuid)
        if expected_bundle_id != 'com.amirtlinov.notebook.acceptance':
            raise TraceError('System trace handshake targets only the private acceptance bundle')
        if not 1 <= segment_time_limit_seconds <= 3600:
            raise TraceError('Trace duration must be between one second and one hour')
        self.duration = segment_time_limit_seconds
        self._stop = threading.Event()
        self._cancel = threading.Event()
        self._thread = None
        self._failure = None
        self._cleanup_errors = []
        self._seen = set()
        self._process = None
        self._segments = []

    @property
    def environment(self):
        return {'NOTEBOOK_TRACE_SESSION_ID': self.session,
                'NOTEBOOK_TRACE_CONTROL_DIRECTORY': str(self.control)}

    def start(self):
        if self._thread is not None:
            raise TraceError('Trace coordinator already started')
        self.control.mkdir(parents=True, mode=0o700, exist_ok=False)
        self.evidence.mkdir(parents=True, mode=0o700, exist_ok=False)
        raw = subprocess.check_output(['xcrun', 'xctrace', 'record', '--template', 'Time Profiler',
                                       '--show-recording-options'], timeout=20)
        defaults = json.loads(raw)
        write_json(self.evidence/'trace-options-defaults.json', defaults)
        if not isinstance(defaults.get('Hangs'), dict) or 'hangsThreshold' not in defaults['Hangs']:
            raise TraceError('Installed Time Profiler provides no Hangs threshold option')
        defaults['Hangs']['hangsThreshold'] = 100
        write_json(self.evidence/'trace-options.json', defaults)
        self._thread = threading.Thread(target=self._run, name='NotebookSystemTrace', daemon=True)
        self._thread.start()
        return self

    def finish(self):
        self._stop.set()
        self._join()
        if self._failure:
            raise TraceError(str(self._failure)) from self._failure
        if not self._segments:
            raise TraceError('No application process completed an attached trace')
        return list(self._segments)

    def cancel(self):
        self._cancel.set()
        self._stop.set()
        self._join()
        # Cancellation is expected when the UI scenario already failed. A
        # recorder/receipt cleanup failure is not: forward it to the outer
        # cleanup owner without substituting the cancelled trace for that UI error.
        if self._cleanup_errors:
            details = '; '.join(item['stage']+': '+item['type']+': '+item['message']
                                for item in self._cleanup_errors)
            raise TraceError('Owned trace cleanup failed: '+details)

    def _join(self):
        if self._thread:
            self._thread.join(timeout=85)
            if self._thread.is_alive():
                raise TraceError('Owned trace coordinator did not terminate within its cleanup deadline')

    def _message(self, ready, status, error=None):
        value = dict(ready, status=status, uptime=time.monotonic(), error=error)
        segment = canonical_uuid(ready['segmentID'])
        write_json(self.control/(segment+'.'+status+'.json'), value)

    def _cleanup_failure(self, stage, error, *, primary=None, segment=None):
        detail = {'stage': stage, 'type': type(error).__name__, 'message': str(error)}
        if segment is not None:
            detail['segmentID'] = segment
        self._cleanup_errors.append(detail)
        if primary is not None and hasattr(primary, 'add_note'):
            primary.add_note('Cleanup '+stage+': '+type(error).__name__+': '+str(error))

    def _validate_message(self, value, *, expected=None, status='ready'):
        if value.get('format') != 1 or canonical_uuid(value.get('sessionID')) != self.session or value.get('status') != status:
            raise TraceError('Trace message does not match the active session or lifecycle state')
        if value['segmentID'] != canonical_uuid(value['segmentID']):
            raise TraceError('Trace segment ID must be a canonical UUID')
        identity = value['identity']
        if (identity.get('format') != 1 or canonical_uuid(identity.get('sessionID')) != self.session
            or identity.get('bundleID') != self.bundle or type(identity.get('pid')) is not int or identity['pid'] <= 1
            or canonical_uuid(identity.get('executableUUID')) != self.binary_uuid):
            raise TraceError('The app identity does not match the accepted build and bundle')
        canonical_uuid(identity['launchID'])
        if expected and (identity != expected['identity'] or value['segmentID'] != expected['segmentID']):
            raise TraceError('The process identity changed within a trace segment')
        return identity

    def _process_identity(self, identity):
        path = Path(identity['executablePath']).resolve(strict=True)
        marker = '/CoreSimulator/Devices/'+self.udid+'/data/Containers/Bundle/Application/'
        if marker.lower() not in str(path).lower():
            raise TraceError('The app executable is outside the requested Simulator bundle container')
        with (path.parent/'Info.plist').open('rb') as stream:
            info = plistlib.load(stream)
        if info.get('CFBundleIdentifier') != self.bundle or info.get('CFBundleExecutable') != path.name:
            raise TraceError('Installed executable does not belong to the expected bundle')
        if macho_uuid(path) != self.binary_uuid:
            raise TraceError('Loaded process and installed Release Mach-O UUID differ')
        pid = str(identity['pid'])
        actual_path = subprocess.check_output(['ps', '-p', pid, '-o', 'comm='], timeout=5).decode().strip()
        start = subprocess.check_output(['ps', '-p', pid, '-o', 'lstart='], timeout=5).decode().strip()
        if not actual_path or Path(actual_path).resolve() != path or not start:
            raise TraceError('The target PID disappeared or no longer owns the expected executable')
        return {'pid': identity['pid'], 'path': str(path), 'processStart': start}

    def _run(self):
        try:
            while not self._cancel.is_set():
                pending = sorted(path for path in self.control.glob('*.ready.json') if path.name not in self._seen)
                if not pending:
                    if self._stop.wait(.05):
                        break
                    continue
                if len(self._seen) >= 16:
                    raise TraceError('More than sixteen process trace segments requested')
                for path in pending:
                    self._seen.add(path.name)
                    ready = read_json(path)
                    try:
                        identity = self._validate_message(ready)
                        if path.name != ready['segmentID']+'.ready.json':
                            raise TraceError('Segment filename and identity disagree')
                        self._record(ready, identity)
                    except BaseException as error:
                        try:
                            self._message(ready, 'failed', str(error))
                        except BaseException as cleanup:
                            self._cleanup_failure('failed-acknowledgement', cleanup, primary=error)
                        raise
        except BaseException as error:
            self._failure = error
        finally:
            failed = self._failure is not None or self._cancel.is_set() or not self._segments
            try:
                write_json(self.evidence/'session.json', {'sessionID': self.session,
                    'segments': self._segments, 'cancelled': self._cancel.is_set(),
                    'status': 'failed' if failed else 'captured',
                    'error': str(self._failure) if self._failure else None,
                    'primaryError': {'type': type(self._failure).__name__, 'message': str(self._failure)}
                        if self._failure else None,
                    'cleanupErrors': self._cleanup_errors,
                    'assessment': 'failed' if failed else 'captured_unassessed', 'droppedFramesMeasured': False})
            except BaseException as cleanup:
                self._cleanup_failure('session-receipt', cleanup, primary=self._failure)
                if self._failure is None:
                    self._failure = cleanup

    def _record(self, ready, identity):
        directory = self.evidence/ready['segmentID']
        directory.mkdir(mode=0o700)
        before = self._process_identity(identity)
        write_json(directory/'identity-before.json', dict(before, app=identity))
        with TraceStartNotification() as notification:
            self._capture(directory, ready, identity, before, notification)

    def _capture(self, directory, ready, identity, before, notification):
        command = ['xcrun', 'xctrace', 'record', '--template', 'Time Profiler', '--device', self.udid,
                   '--attach', str(identity['pid']), '--recording-options', str(self.evidence/'trace-options.json'),
                   '--time-limit', str(self.duration)+'s', '--run-name', ready['segmentID'],
                   '--notify-tracing-started', notification.name,
                   '--output', str(directory/'system.trace')]
        write_json(directory/'command.json', command)
        log_path = directory/'trace.log'
        with log_path.open('wb') as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            self._process = process
            primary_error = None
            try:
                deadline = time.monotonic()+20
                while True:
                    self._check(process, deadline)
                    self._check_liveness(identity['pid'])
                    if notification.wait(.1):
                        break
                self._check(process, deadline)
                notification.close()
                if self._process_identity(identity) != before:
                    raise TraceError('Target process changed at tracing start')
                started = time.monotonic()
                self._message(ready, 'started')
                end_path = self.control/(ready['segmentID']+'.end.json')
                deadline = started+self.duration
                while not end_path.exists():
                    self._check(process, deadline)
                    if self._stop.is_set():
                        raise TraceError('UI runner ended without closing its current trace segment')
                    self._check_liveness(identity['pid'])
                    self._cancel.wait(.2)
                self._check(process, deadline)
                ended = read_json(end_path)
                self._validate_message(ended, expected=ready, status='end')
                after = self._process_identity(identity)
                if after != before:
                    raise TraceError('Target process changed before workload completion')
                write_json(directory/'identity-after.json', dict(after, app=identity))
                write_json(directory/'workload.json', {'ready': ready, 'startedAt': started, 'ended': ended,
                    'startNotification': notification.name})
            except BaseException as error:
                primary_error = error
                raise
            finally:
                try:
                    code = self._stop_process(process)
                except BaseException as cleanup:
                    self._cleanup_failure('recording.stop', cleanup, primary=primary_error, segment=ready['segmentID'])
                    if primary_error is None:
                        raise
                finally:
                    self._process = None
        if code not in (0, -signal.SIGINT):
            raise TraceError('System trace ended with code '+str(code))
        if self._process_identity(identity) != before:
            raise TraceError('Target identity changed while finalizing its trace')
        try:
            with (directory/'export.log').open('wb') as export_log:
                subprocess.run(['xcrun', 'xctrace', 'export', '--input', str(directory/'system.trace'),
                            '--toc', '--output', str(directory/'toc.xml')], check=True,
                           stdout=export_log, stderr=subprocess.STDOUT, timeout=30)
            assessment = validate_toc(directory/'toc.xml', identity, self.udid)
        except (subprocess.SubprocessError, ET.ParseError, TraceError) as error:
            write_json(directory/'capture.json', {'assessment': 'captured_unassessed', 'exportError': str(error),
                'mainThreadCoverageVerified': False, 'droppedFramesMeasured': False})
            raise TraceError('Recorded trace could not be validated: '+str(error)) from error
        write_json(directory/'capture.json', assessment)
        self._segments.append({'segmentID': ready['segmentID'], 'launchID': identity['launchID'],
                               'pid': identity['pid'], 'evidence': str(directory), **assessment})
        self._message(ready, 'closed')

    def _check(self, process, deadline):
        if self._cancel.is_set():
            raise TraceError('System trace cancelled')
        if process.poll() is not None:
            raise TraceError('System trace exited before the acknowledged workload completed')
        if time.monotonic() >= deadline:
            raise TraceError('System trace exceeded its lifecycle deadline')

    @staticmethod
    def _check_liveness(pid):
        try:
            os.kill(pid, 0)
        except OSError as error:
            raise TraceError('Target process is no longer alive') from error

    @staticmethod
    def _stop_process(process):
        if process.poll() is None:
            process.send_signal(signal.SIGINT)
        try:
            return process.wait(timeout=35)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
            raise TraceError('Owned system trace failed to finish after SIGINT')
