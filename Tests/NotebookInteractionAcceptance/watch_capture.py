"""A bounded capture sidecar. It never launches or controls a UI/Xcode runner."""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import time
import uuid


def main():
    p=argparse.ArgumentParser();p.add_argument('--control',type=Path,required=True)
    p.add_argument('--helper',type=Path,required=True);p.add_argument('--session',required=True)
    p.add_argument('--window-id',type=int,required=True);p.add_argument('--pid',type=int,required=True)
    args=p.parse_args();session=str(uuid.UUID(args.session)).lower();root=args.control.resolve()
    if not root.is_dir() or (root/'capture').exists():raise SystemExit('A new existing control directory without capture output is required')
    receipt={'format':1,'sessionID':session,'status':'waiting_for_actual_ui','measured':False,
        'helperSHA256':hashlib.sha256(args.helper.read_bytes()).hexdigest(),'startedUnix':time.time()}
    def save():
        temporary=root/'capture-coordinator.tmp';temporary.write_text(json.dumps(receipt,indent=2))
        temporary.replace(root/'capture-coordinator.json')
    try:
        save();deadline=time.monotonic()+90
        while not (root/'ui-ready.json').exists():
            if (root/'cancel.json').exists():raise RuntimeError('UI runner cancelled before capture started')
            if time.monotonic()>=deadline:raise RuntimeError('UI readiness handshake timed out; capture not started')
            time.sleep(.1)
        ready=json.loads((root/'ui-ready.json').read_text());identity=ready['identity']
        if (ready['sessionID'].lower()!=session or identity['sessionID'].lower()!=session
            or identity['bundleID']!='com.amirtlinov.notebook.acceptance' or identity['pid']<=0):
            raise RuntimeError('Actual app process identity does not match the measurement session')
        receipt['uiReady']=ready
        command=[str(args.helper.resolve()),'capture',str(args.window_id),str(args.pid),session,str(root/'capture'),'60']
        receipt['command']=command;receipt['status']='capturing';save()
        with (root/'capture-process.stdout.log').open('wb') as out,(root/'capture-process.stderr.log').open('wb') as err:
            result=subprocess.run(command,stdout=out,stderr=err,timeout=75)
        receipt['exitCode']=result.returncode
        if result.returncode:
            try: reason=json.loads((root/'capture-process.stderr.log').read_text()).get('error','Unknown ScreenCaptureKit error')
            except (ValueError,OSError):reason='Read capture-process.stderr.log'
            raise RuntimeError('ScreenCaptureKit capture is unmeasured: '+reason)
        captured=json.loads((root/'capture/capture.json').read_text())
        if captured['status']!='captured_unassessed' or captured.get('result',{}).get('error'):
            raise RuntimeError('Window capture is unmeasured; inspect capture.json')
        ended=json.loads((root/'ui-ended.json').read_text())
        if ended['identity']!=identity or ended['sessionID'].lower()!=session:
            raise RuntimeError('UI process changed before its actual gesture sequence ended')
        receipt['uiEnded']=ended;receipt['status']='captured_unassessed'
    except Exception as error:
        receipt['status']='unmeasured';receipt['error']=str(error)
    finally:
        receipt['finishedUnix']=time.time();save()
    return 0 if receipt['status']=='captured_unassessed' else 1

if __name__=='__main__':raise SystemExit(main())
