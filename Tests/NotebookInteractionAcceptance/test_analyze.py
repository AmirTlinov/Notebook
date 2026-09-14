"""Synthetic CPU contracts only: these fixtures are not Simulator evidence."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from PIL import Image
from analyze import analyze, clock_bounds, Unmeasured


class EvidenceContracts(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.capture=self.root/'capture';self.capture.mkdir()
        self.native=[];self.frames=[];self.bindings=[]
        self.session='00000000-0000-4000-8000-000000000001'
        self.clock={'name':'mach_absolute_time','numer':1,'denom':1,'machBefore':'1000000000',
                    'machAfter':'1000000100','systemUptimeSeconds':1.00000005}
        self.append({'kind':'identity','pid':123,'bundleID':'com.amirtlinov.notebook.acceptance',
            'simulatorUDID':'SYNTHETIC-SIMULATOR','executablePath':'/synthetic/Notebook.app/Notebook','clock':self.clock})
        self.metadata={'status':'captured_unassessed','result':{'error':None},'screenCapturePreflight':True,
            'permissionRequested':False,'audio':False,'microphone':False,'simulatorBundleID':'com.apple.iphonesimulator',
            'sessionID':self.session,'startClock':self.clock,'endClock':self.clock}
        self.review={'sessionID':self.session,'simulatorUDID':'SYNTHETIC-SIMULATOR',
            'reviewer':'synthetic CPU fixture','uiEvidence':'synthetic-only','bindings':self.bindings}
        identity={'pid':123,'executablePath':'/synthetic/Notebook.app/Notebook'}
        (self.root/'ui-ready.json').write_text(json.dumps({'sessionID':self.session,'identity':identity}))
        (self.root/'ui-ended.json').write_text(json.dumps({'sessionID':self.session,'identity':identity,
            'steps':[{'before':i,'after':i+1} for i in range(10)]}))
        for i in range(10):self.transition(i)

    def append(self,value):
        value=dict(value,sequence=len(self.native)+1,sessionID=self.session);self.native.append(value);return value

    def frame(self,seconds,color):
        sequence=len(self.frames)+1;name=f'frame-{sequence:06}.png';path=self.capture/name
        Image.new('RGB',(8,8),color).save(path)
        value={'sequence':sequence,'sessionID':self.session,'status':0,'sampleValid':True,'width':8,'height':8,
            'png':name,'pngSHA256':hashlib.sha256(path.read_bytes()).hexdigest(),
            'displayMach':str(round(seconds*1e9)),'receivedMach':str(round((seconds+.001)*1e9))}
        self.frames.append(value);return sequence

    def transition(self,i):
        t=2+i;runtime={'loadToken':'token','elementID':'acceptance-controls','ready':True}
        for phase,seconds in [('began',t),('ended',t+.03)]:
            self.append({'kind':'contact','contactID':str(i),'phase':phase,'touchUptimeSeconds':seconds,'runtime':runtime})
        click=self.append({'kind':'dom','runtime':runtime,'readyAtReceipt':True,'receiptMach':str(round((t+.04)*1e9)),
            'observation':{'stage':'trusted_event','name':'click','eventID':i}})
        self.append({'kind':'dom','runtime':runtime,'observation':{'stage':'dom_observable_change',
            'precedingEvent':{'eventID':i},'observables':[{'selector':'#count','text':str(i+1)}]}})
        before,after=self.frame(t+.02,'white'),self.frame(t+.05,'black')
        self.bindings.append({'contactID':str(i),'loadToken':'token','nativeClickSequence':click['sequence'],
            'selector':'#count','beforeText':str(i),'afterText':str(i+1),'reviewedBeforeText':str(i),
            'reviewedAfterText':str(i+1),'lastOldFrame':before,'firstNewFrame':after,'countROI':[0,0,8,8]})

    def run_analysis(self):
        native=self.root/'native.ndjson';native.write_text(''.join(json.dumps(v)+'\n' for v in self.native))
        (self.capture/'frames.ndjson').write_text(''.join(json.dumps(v)+'\n' for v in self.frames))
        (self.capture/'capture.json').write_text(json.dumps(self.metadata))
        return analyze(native,self.capture,self.review)

    def test_ten_real_endpoints_required_and_separate_hold_from_release(self):
        result=self.run_analysis();self.assertEqual(result['verdict'],'pass');self.assertFalse(result['fpsMeasured'])
        first=result['observations'][0]
        self.assertAlmostEqual(first['releaseToVisibleMs']['upper'],20.00005,places=4)
        self.assertAlmostEqual(first['touchStartToVisibleUpperMs'],50.00005,places=4)

    def test_sparse_capture_cannot_prove_failure(self):
        self.frames[1]['displayMach']='2250000000';self.frames[1]['receivedMach']='2251000000'
        self.assertEqual(self.run_analysis()['observations'][0]['verdict'],'inconclusive')

    def test_reviewed_old_pixels_after_threshold_prove_slow_response(self):
        self.frames[0]['displayMach']='2200000000';self.frames[0]['receivedMach']='2201000000'
        self.frames[1]['displayMach']='2250000000';self.frames[1]['receivedMach']='2251000000'
        self.assertEqual(self.run_analysis()['verdict'],'fail')

    def test_missing_dom_outcome_is_not_zero_latency(self):
        self.native[4]['observation']['observables']=[]
        with self.assertRaisesRegex(Unmeasured,'DOM outcome'):self.run_analysis()

    def test_changed_png_hash_is_rejected(self):
        self.frames[1]['pngSHA256']='0'*64
        with self.assertRaisesRegex(Unmeasured,'PNG bytes'):self.run_analysis()

    def test_multiple_contacts_are_not_guessed_from_coordinates(self):
        value=copy.deepcopy(self.native[1]);value.update(contactID='other',touchUptimeSeconds=2.01)
        self.append(value)
        with self.assertRaisesRegex(Unmeasured,'Several contacts'):self.run_analysis()

    def test_clock_calibration_must_fit_bound(self):
        self.clock['machAfter']='1003000000'
        with self.assertRaisesRegex(Unmeasured,'calibration'):self.run_analysis()

    def test_process_relaunch_invalidates_capture_join(self):
        p=self.root/'ui-ended.json';value=json.loads(p.read_text());value['identity']['pid']=999;p.write_text(json.dumps(value))
        with self.assertRaisesRegex(Unmeasured,'process changed'):self.run_analysis()

    def test_budget_exhaustion_never_passes(self):
        self.metadata['result']['budgetExceeded']=True
        with self.assertRaisesRegex(Unmeasured,'budget'):self.run_analysis()

    def test_suspended_or_other_incomplete_samples_cannot_supply_visible_endpoints(self):
        # A timestamp and even a supplied PNG cannot turn a suspended/idle
        # callback into a complete WindowServer presentation sample.
        for status in (1, 2, 3, 4, 5, -1):
            with self.subTest(status=status):
                self.frames[1]['status']=status
                with self.assertRaisesRegex(Unmeasured,'complete valid screen sample'):
                    self.run_analysis()

    def test_invalid_sample_cannot_supply_a_visible_endpoint(self):
        self.frames[1]['sampleValid']=False
        with self.assertRaisesRegex(Unmeasured,'complete valid screen sample'):
            self.run_analysis()

    def test_nine_transitions_are_incomplete(self):
        self.bindings.pop()
        with self.assertRaisesRegex(Unmeasured,'Ten distinct'):self.run_analysis()

    def test_same_pixels_cannot_be_presented_as_a_change(self):
        self.frames[1].update(png=self.frames[0]['png'],pngSHA256=self.frames[0]['pngSHA256'])
        with self.assertRaisesRegex(Unmeasured,'pixels did not change'):self.run_analysis()

if __name__=='__main__':unittest.main()
