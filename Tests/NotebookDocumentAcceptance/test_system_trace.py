"""CPU-only lifecycle/identity contracts. Fakes are not Simulator profiling proof."""
from contextlib import ExitStack
from pathlib import Path
import json
import os
import plistlib
import signal
import struct
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch
import uuid

import system_trace as trace

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Applications'))
import notebook_acceptance as acceptance


class Process:
    def __init__(self, command, *, stdout, **kwargs):
        self.command = command
        self.log = Path(stdout.name)
        self.code = None
        self.signals = []

    def poll(self): return self.code
    def send_signal(self, value): self.signals.append(value); self.code = 0
    def wait(self, timeout): return self.code
    def terminate(self): self.code = -15
    def kill(self): self.code = -9


class StartNotification:
    def __init__(self):
        self.name = str(uuid.uuid4())
        self.started = threading.Event()
        self.closed = False
    def __enter__(self): return self
    def __exit__(self, *args): self.close()
    def wait(self, timeout): return self.started.wait(timeout)
    def close(self): self.closed = True


class HandshakeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.session, self.udid, self.binary = (str(uuid.uuid4()).upper() for _ in range(3))
        self.coordinator = trace.TraceHandshake(session_id=self.session, control_directory=self.root/'control',
            evidence_directory=self.root/'evidence', simulator_udid=self.udid,
            expected_bundle_id='com.amirtlinov.notebook.acceptance', expected_executable_uuid=self.binary)
        self.processes = []
        self.notifications = {}
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.object(trace.subprocess, 'check_output', return_value=json.dumps({
            'Hangs': {'hangsThreshold': 250, 'detectPriorityInversions': False},
            'Time Profiler': {'recordWaitingThreads': False}}).encode()))
        self.stack.enter_context(patch.object(trace.subprocess, 'Popen', side_effect=self.spawn))
        self.stack.enter_context(patch.object(trace, 'TraceStartNotification', side_effect=self.notification))
        self.stack.enter_context(patch.object(self.coordinator, '_process_identity', side_effect=lambda value:
            {'pid': value['pid'], 'path': value['executablePath'], 'processStart': value['launchID']}))
        self.stack.enter_context(patch.object(self.coordinator, '_check_liveness'))
        self.stack.enter_context(patch.object(trace.subprocess, 'run', side_effect=self.export))
        self.coordinator.start()
        self.addCleanup(self.stop_coordinator)

    def stop_coordinator(self):
        # Explicit finish/cancel tests already joined and asserted their error.
        # Cleanup owns only a fake recorder that the test left running.
        if self.coordinator._thread.is_alive():
            self.coordinator.cancel()

    def notification(self):
        value = StartNotification(); self.notifications[value.name] = value; return value

    def spawn(self, command, **kwargs):
        value = Process(command, **kwargs)
        value.notification = self.notifications[command[command.index('--notify-tracing-started')+1]]
        self.assertFalse(value.notification.closed)
        self.processes.append(value)
        return value

    def export(self, command, **kwargs):
        path = Path(command[command.index('--output')+1])
        ready = trace.read_json(self.coordinator.control/(path.parent.name+'.ready.json'))
        path.write_text(self.toc(ready['identity']['pid']))

    def toc(self, pid, threshold=100, schema='time-profile', device=None):
        return ('<trace-toc><run><info><target><device uuid="'+(device or self.udid)+'"/></target></info>'
                '<processes><process pid="'+str(pid)+'"/></processes><data><table schema="'+schema+'"/>'
                '<table schema="potential-hangs" hangs-threshold="'+str(threshold)+'"/></data></run></trace-toc>')

    def message(self, pid=7788):
        identity = {'format': 1, 'sessionID': self.session, 'launchID': str(uuid.uuid4()).upper(), 'pid': pid,
            'bundleID': 'com.amirtlinov.notebook.acceptance', 'executableUUID': self.binary,
            'executablePath': '/a/Notebook.app/Notebook', 'reportedUptime': time.monotonic()}
        return {'format': 1, 'sessionID': self.session, 'segmentID': str(uuid.uuid4()).upper(),
                'identity': identity, 'status': 'ready', 'uptime': time.monotonic(), 'error': None}

    def publish(self, value, suffix):
        trace.write_json(self.coordinator.control/(value['segmentID']+'.'+suffix+'.json'), dict(value, status=suffix))

    def wait(self, predicate):
        deadline = time.monotonic()+3
        while time.monotonic() < deadline:
            if predicate(): return
            time.sleep(.01)
        self.fail('Bounded fake lifecycle did not complete')

    def ack(self, value, suffix):
        path=self.coordinator.control/(value['segmentID']+'.'+suffix+'.json')
        self.wait(path.exists);return trace.read_json(path)

    def start_segment(self, value):
        count = len(self.processes)
        self.publish(value, 'ready')
        self.wait(lambda: len(self.processes)>count)
        process = self.processes[-1]
        self.assertFalse((self.coordinator.control/(value['segmentID']+'.started.json')).exists())
        process.notification.started.set()
        self.assertEqual(self.ack(value,'started')['identity'],value['identity'])
        self.assertTrue(process.notification.closed)
        return process

    def test_two_actual_launch_identities_get_separate_attach_segments(self):
        first,second=self.message(7788),self.message(7799)
        for value in [first,second]:
            process=self.start_segment(value)
            self.publish(value,'end')
            self.assertEqual(self.ack(value,'closed')['identity'],value['identity'])
            self.assertEqual(process.signals,[signal.SIGINT])
            self.assertEqual(process.command[process.command.index('--attach')+1],str(value['identity']['pid']))
        segments=self.coordinator.finish()
        self.assertEqual([x['pid'] for x in segments],[7788,7799])
        self.assertTrue(all(not x['droppedFramesMeasured'] and not x['mainThreadCoverageVerified'] for x in segments))
        options=trace.read_json(self.coordinator.evidence/'trace-options.json')
        self.assertEqual(options['Hangs'],{'hangsThreshold':100,'detectPriorityInversions':False})
        self.assertIn('Time Profiler',options)

    def test_process_exit_before_start_notification_never_releases_workload(self):
        value=self.message();self.publish(value,'ready');self.wait(lambda: bool(self.processes))
        self.processes[0].code=1
        self.assertIn('exited',self.ack(value,'failed')['error'])
        self.assertFalse((self.coordinator.control/(value['segmentID']+'.started.json')).exists())
        with self.assertRaises(trace.TraceError):self.coordinator.finish()

    def test_start_deadline_never_releases_workload_or_leaks_owned_recorder(self):
        value=self.message()
        with patch.object(self.coordinator,'_check',side_effect=trace.TraceError('System trace exceeded its lifecycle deadline')):
            self.publish(value,'ready')
            self.assertIn('deadline',self.ack(value,'failed')['error'])
        self.assertFalse((self.coordinator.control/(value['segmentID']+'.started.json')).exists())
        self.assertEqual(self.processes[0].signals,[signal.SIGINT])
        self.assertTrue(self.processes[0].notification.closed)

    def test_log_prose_is_not_a_recording_start_event(self):
        value=self.message(); self.publish(value,'ready'); self.wait(lambda: bool(self.processes))
        process=self.processes[0]
        process.log.write_text('Starting recording with the Time Profiler template.\nRecording started\n')
        time.sleep(.25)
        self.assertFalse((self.coordinator.control/(value['segmentID']+'.started.json')).exists())
        process.notification.started.set()
        self.ack(value,'started'); self.publish(value,'end'); self.ack(value,'closed')

    def test_start_failure_survives_recorder_shutdown_failure_in_ack_and_session(self):
        value=self.message()
        original=trace.TraceError('Recording never started before deadline')
        cleanup=trace.TraceError('Owned recorder failed to stop')
        with patch.object(self.coordinator,'_check',side_effect=original), \
             patch.object(self.coordinator,'_stop_process',side_effect=cleanup):
            self.publish(value,'ready')
            self.assertEqual(self.ack(value,'failed')['error'],str(original))
            with self.assertRaises(trace.TraceError) as failure:self.coordinator.finish()
        self.assertIs(failure.exception.__cause__,original)
        session=trace.read_json(self.coordinator.evidence/'session.json')
        self.assertEqual(session['status'],'failed');self.assertEqual(session['assessment'],'failed')
        self.assertEqual(session['primaryError'],{'type':'TraceError','message':str(original)})
        self.assertEqual(session['cleanupErrors'],[{'stage':'recording.stop','type':'TraceError',
            'message':str(cleanup),'segmentID':value['segmentID']}])
        self.assertEqual(session['segments'],[]);self.assertIsNone(self.coordinator._process)
        for suffix in ['started','closed']:
            self.assertFalse((self.coordinator.control/(value['segmentID']+'.'+suffix+'.json')).exists())

    def test_stop_failure_after_real_start_and_end_cannot_publish_closed_or_capture(self):
        value=self.message();self.start_segment(value)
        cleanup=trace.TraceError('Recorder did not finish after SIGINT')
        with patch.object(self.coordinator,'_stop_process',side_effect=cleanup):
            self.publish(value,'end')
            self.assertEqual(self.ack(value,'failed')['error'],str(cleanup))
            with self.assertRaises(trace.TraceError) as failure:self.coordinator.finish()
        self.assertIs(failure.exception.__cause__,cleanup)
        session=trace.read_json(self.coordinator.evidence/'session.json')
        self.assertEqual(session['status'],'failed');self.assertEqual(session['segments'],[])
        self.assertEqual(session['cleanupErrors'][0]['stage'],'recording.stop')
        self.assertFalse((self.coordinator.control/(value['segmentID']+'.closed.json')).exists())

    def test_failed_ack_write_does_not_replace_original_identity_error(self):
        value=self.message();value['identity']['executableUUID']=str(uuid.uuid4()).upper()
        with patch.object(self.coordinator,'_message',side_effect=OSError('ack volume unavailable')):
            self.publish(value,'ready')
            self.wait(lambda:self.coordinator._failure is not None)
            with self.assertRaisesRegex(trace.TraceError,'accepted build'):self.coordinator.finish()
        session=trace.read_json(self.coordinator.evidence/'session.json')
        self.assertEqual(session['status'],'failed')
        self.assertIn('accepted build',session['primaryError']['message'])
        self.assertEqual(session['cleanupErrors'][0]['stage'],'failed-acknowledgement')
        self.assertEqual(self.processes,[])

    def test_session_write_failure_keeps_primary_in_finish_and_diagnostic_notes(self):
        value=self.message();original=trace.TraceError('Start deadline expired')
        original_write=trace.write_json
        def write(path, data):
            if Path(path).name=='session.json':raise OSError('evidence volume unavailable')
            original_write(path,data)
        with patch.object(self.coordinator,'_check',side_effect=original),patch.object(trace,'write_json',side_effect=write):
            self.publish(value,'ready');self.ack(value,'failed')
            with self.assertRaises(trace.TraceError) as failure:self.coordinator.finish()
        self.assertIs(failure.exception.__cause__,original)
        self.assertEqual(self.coordinator._cleanup_errors[0]['stage'],'session-receipt')
        self.assertFalse((self.coordinator.evidence/'session.json').exists())

    def test_source_identity_change_at_end_cannot_close_old_trace(self):
        value=self.message();process=self.start_segment(value)
        changed=dict(value,identity=dict(value['identity'],launchID=str(uuid.uuid4()).upper()))
        self.publish(changed,'end')
        self.assertIn('identity changed',self.ack(value,'failed')['error'])
        self.assertFalse((self.coordinator.control/(value['segmentID']+'.closed.json')).exists())
        self.assertEqual(process.signals,[signal.SIGINT])

    def test_premature_time_limit_fails_even_after_start_ack(self):
        value=self.message();process=self.start_segment(value);process.code=0
        self.assertIn('exited',self.ack(value,'failed')['error'])
        self.assertFalse((self.coordinator.control/(value['segmentID']+'.closed.json')).exists())

    def test_cancel_stops_only_owned_trace_and_preserves_failure_evidence(self):
        value=self.message();process=self.start_segment(value);self.coordinator.cancel()
        self.assertEqual(process.signals,[signal.SIGINT])
        self.assertIn('cancelled',self.ack(value,'failed')['error'])
        session=trace.read_json(self.coordinator.evidence/'session.json')
        self.assertTrue(session['cancelled'])
        self.assertEqual(session['cleanupErrors'],[])

    def test_cancel_cleanup_failure_reaches_outer_receipt_without_replacing_ui_failure(self):
        value=self.message();self.start_segment(value)
        primary=ValueError('Original UI assertion failed')
        recording=Mock()
        cleanup=trace.TraceError('Owned system trace failed to finish after SIGINT')
        with patch.object(self.coordinator,'_stop_process',side_effect=cleanup):
            acceptance.finalize_ui_attempt(evidence=self.coordinator.evidence,
                scenario={'scenario':'synthetic UI failure'},primary_error=primary,
                trace=self.coordinator,trace_finished=False,recording=recording,
                installed_before=None,simulator='unused')
        recording.stop.assert_called_once_with()
        session=trace.read_json(self.coordinator.evidence/'session.json')
        self.assertEqual(session['primaryError'],{'type':'TraceError','message':'System trace cancelled'})
        self.assertEqual(session['cleanupErrors'],[{'stage':'recording.stop','type':'TraceError',
            'message':str(cleanup),'segmentID':value['segmentID']}])
        receipt=trace.read_json(self.coordinator.evidence/'scenario.json')
        self.assertEqual(receipt['status'],'failed')
        self.assertEqual(receipt['primaryError'],{'type':'ValueError','message':str(primary)})
        self.assertEqual(receipt['cleanupErrors'],[{'stage':'trace.cancel','type':'TraceError',
            'message':'Owned trace cleanup failed: recording.stop: TraceError: '+str(cleanup)}])
        self.assertTrue(any('Cleanup trace.cancel:' in note for note in primary.__notes__))
        self.assertFalse(receipt['systemTraceLifecycleFinished'])
        self.assertIsNone(self.coordinator._process)

    def test_no_handshake_is_not_a_successful_capture(self):
        with self.assertRaisesRegex(trace.TraceError,'No application process'):
            self.coordinator.finish()

    def test_wrong_loaded_binary_is_rejected_before_any_attach(self):
        value=self.message();value['identity']['executableUUID']=str(uuid.uuid4()).upper()
        self.publish(value,'ready')
        self.assertIn('accepted build',self.ack(value,'failed')['error'])
        self.assertEqual(self.processes,[])

    def test_start_notification_from_an_already_exited_process_does_not_release_ui(self):
        value=self.message();self.publish(value,'ready');self.wait(lambda: bool(self.processes))
        self.processes[0].code=0
        self.processes[0].notification.started.set()
        self.ack(value,'failed')
        self.assertFalse((self.coordinator.control/(value['segmentID']+'.started.json')).exists())

    def test_unknown_schema_stays_unassessed_but_wrong_threshold_is_error(self):
        path=self.root/'toc.xml';path.write_text(self.toc(7788,schema='future-profile'))
        result=trace.validate_toc(path,{'pid':7788},self.udid)
        self.assertFalse(result['instrumentSchemaRecognized']);self.assertEqual(result['assessment'],'captured_unassessed')
        path.write_text(self.toc(7788,threshold=250))
        with self.assertRaisesRegex(trace.TraceError,'100 ms'):trace.validate_toc(path,{'pid':7788},self.udid)
        path.write_text(self.toc(7799))
        with self.assertRaisesRegex(trace.TraceError,'PID'):trace.validate_toc(path,{'pid':7788},self.udid)

    def test_immutable_acknowledgement_does_not_overwrite_prior_identity(self):
        path=self.root/'ack.json';trace.write_json(path,{'pid':1})
        with self.assertRaises(FileExistsError):trace.write_json(path,{'pid':2})
        self.assertEqual(trace.read_json(path),{'pid':1})


class NativeNotificationTests(unittest.TestCase):
    def test_only_the_registered_darwin_notification_releases_its_descriptor(self):
        # Public libnotify, not a fake recorder and not Simulator profiling proof.
        with trace.TraceStartNotification() as notification:
            library = notification._library
            library.notify_post.argtypes = [trace.ctypes.c_char_p]
            library.notify_post.restype = trace.ctypes.c_uint32
            self.assertFalse(notification.wait(0))
            self.assertEqual(library.notify_post((notification.name+'.other').encode()), 0)
            self.assertFalse(notification.wait(.02))
            self.assertEqual(library.notify_post(notification.name.encode()), 0)
            self.assertTrue(notification.wait(1))
            self.assertFalse(notification.wait(0))
            fd = notification._fd
        with self.assertRaises(OSError): os.fstat(fd)
        notification.close()
        with self.assertRaisesRegex(trace.TraceError, 'already closed'): notification.wait(0)


class BinaryIdentityTests(unittest.TestCase):
    def test_uuid_comes_from_the_bounded_macho_load_command(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'Notebook';identity=uuid.uuid4()
            header=struct.pack('<8I',0xfeedfacf,0x100000c,0,2,1,24,0,0)
            path.write_bytes(header+struct.pack('<II',0x1b,24)+identity.bytes)
            self.assertEqual(trace.macho_uuid(path),str(identity).upper())
            path.write_bytes(header+struct.pack('<II',0x1b,24)+identity.bytes[:3])
            with self.assertRaisesRegex(trace.TraceError,'Truncated'):trace.macho_uuid(path)
            path.write_bytes(struct.pack('<8I',0xfeedfacf,0,0,0,999999,24,0,0))
            with self.assertRaisesRegex(trace.TraceError,'bounded'):trace.macho_uuid(path)


if __name__=='__main__': unittest.main()
