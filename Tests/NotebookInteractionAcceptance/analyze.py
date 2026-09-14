"""Join reviewed real control pixels to native contacts; no DOM/FPS substitution.

A reviewed binding names the last actual frame still showing the old count and
first actual frame showing the next count, plus a non-animated count-only ROI.
Both images and hashes are verified. The result is an interval: sparse frames
can prove an upper bound, but cannot manufacture an exact latency or a failure.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import math
from pathlib import Path
from PIL import Image, ImageChops


class Unmeasured(ValueError): pass


def require(condition, reason):
    if not condition: raise Unmeasured(reason)


def records(path):
    data = Path(path).read_bytes()
    require(data and data.endswith(b'\n'), 'Journal is empty or has an unfinished final record')
    values = [json.loads(line) for line in data.splitlines()]
    require(not any(v.get('kind') == 'truncated' for v in values), 'Native journal exceeded its budget')
    require([v.get('sequence') for v in values] == list(range(1, len(values)+1)), 'Journal sequence has a gap or duplicate')
    return values


def clock_bounds(value):
    require(value['name'] == 'mach_absolute_time', 'Unknown clock domain')
    factor = value['numer']/value['denom']/1e9
    before, after, uptime = int(value['machBefore'])*factor, int(value['machAfter'])*factor, value['systemUptimeSeconds']
    require(0 <= after-before <= .001, 'Clock calibration bracket exceeds 1 ms')
    require(math.isfinite(uptime), 'Invalid uptime calibration')
    return factor, (before-uptime, after-uptime)


def frame_image(directory, value):
    require(value.get('status') == 0 and value.get('sampleValid') is True, 'Frame is not a complete valid screen sample')
    name = value.get('png', '')
    require(Path(name).name == name and name.endswith('.png'), 'Invalid frame artifact path')
    path = directory/name
    require(hashlib.sha256(path.read_bytes()).hexdigest() == value['pngSHA256'], 'PNG bytes do not match capture journal')
    image = Image.open(path).convert('RGB')
    require(image.size == (value['width'], value['height']), 'PNG dimensions do not match capture journal')
    return image


def analyze(native_path, capture_directory, review):
    native = records(native_path); directory = Path(capture_directory)
    capture = json.loads((directory/'capture.json').read_text()); frames = records(directory/'frames.ndjson')
    require(not any(v.get('observation', {}).get('stage') == 'truncated' for v in native), 'DOM observer exceeded its budget')
    identities = [v for v in native if v['kind'] == 'identity']
    require(len(identities) == 1, 'Exactly one native launch identity is required')
    identity = identities[0]
    require(capture['status'] == 'captured_unassessed' and not capture['result'].get('error'), 'Capture failed or is incomplete')
    require(not capture['result'].get('budgetExceeded'), 'Capture budget exceeded')
    require(capture['screenCapturePreflight'] is True and capture['permissionRequested'] is False, 'Unexpected capture permission path')
    require(capture['audio'] is False and capture['microphone'] is False, 'Only screen capture is in scope')
    require(capture['simulatorBundleID'] == 'com.apple.iphonesimulator', 'The captured owner is not Simulator')
    require(identity['bundleID'] == 'com.amirtlinov.notebook.acceptance', 'The native journal is not the isolated app')
    session = identity['sessionID'].lower()
    require(capture['sessionID'].lower() == session == review['sessionID'].lower(), 'Sessions differ')
    require(all(v.get('sessionID', '').lower() == session for v in native+frames), 'Mixed session records')
    require(review.get('reviewer') and review.get('uiEvidence'), 'Independent visible state and UI identity review is required')
    require(review.get('simulatorUDID', '').lower() == identity['simulatorUDID'].lower()
            and identity['simulatorUDID'] != 'unavailable', 'Simulator device binding is unavailable or differs')
    factor, offset = clock_bounds(identity['clock'])
    host_factor, host_offset = clock_bounds(capture['startClock']); end_factor, end_offset = clock_bounds(capture['endClock'])
    require(factor == host_factor == end_factor, 'Native/host mach timebases differ')
    require(max(abs(a-b) for a in offset for b in host_offset+end_offset) <= .001,
            'Native UITouch uptime and host mach clocks are not demonstrably aligned within 1 ms')
    ui_ready = json.loads((directory.parent/'ui-ready.json').read_text())
    ui_ended = json.loads((directory.parent/'ui-ended.json').read_text())
    require(ui_ready['sessionID'].lower() == session == ui_ended['sessionID'].lower(), 'UI run session differs')
    require(ui_ready['identity'] == ui_ended['identity'], 'App process changed during actual taps')
    require(ui_ready['identity']['pid'] == identity['pid']
            and ui_ready['identity']['executablePath'] == identity['executablePath'], 'UI/native process identities differ')
    require(len(ui_ended['steps']) == 10 and all(s['after'] == s['before']+1 for s in ui_ended['steps']),
            'UI did not observe exactly ten one-count real tap outcomes')
    frame_by_seq = {f['sequence']: f for f in frames}
    seen = set(); outcomes = []
    for binding in review['bindings']:
        contact = binding['contactID']; require(contact not in seen, 'One contact was bound twice'); seen.add(contact)
        touches = [v for v in native if v['kind'] == 'contact' and v['contactID'] == contact]
        require([v['phase'] for v in touches] == ['began','ended'], 'Touch is missing, cancelled or has an ambiguous lifetime')
        began, ended = touches
        token = binding['loadToken']
        require(all(t.get('runtime', {}).get('loadToken') == token and t['runtime']['ready'] is True for t in touches),
                'The touched runtime was not ready or changed identity')
        require(began['touchUptimeSeconds'] <= ended['touchUptimeSeconds'], 'Touch timestamps run backwards')
        clicks = [v for v in native if v['kind'] == 'dom' and v['runtime']['loadToken'] == token
                  and v['observation'].get('stage') == 'trusted_event' and v['observation'].get('name') == 'click'
                  and v['sequence'] == binding['nativeClickSequence']]
        require(len(clicks) == 1 and clicks[0]['readyAtReceipt'] is True, 'The reviewed trusted click is missing or not ready')
        click = clicks[0]
        # Native and WebKit touch IDs are different APIs. Match only a single
        # contact in the same immutable runtime; never guess between fingers.
        ended_s = ended['touchUptimeSeconds'] + offset[0]
        began_s = began['touchUptimeSeconds'] + offset[0]
        click_s = int(click['receiptMach'])*factor
        require(ended_s-.001 <= click_s <= ended_s+1, 'Click receipt is not within this touch release interval')
        competing = [v for v in native if v['kind'] == 'contact' and v['phase'] == 'began'
            and v.get('runtime', {}).get('loadToken') == token and v['contactID'] != contact
            and began_s <= v['touchUptimeSeconds']+offset[0] <= click_s]
        require(not competing, 'Several contacts could own this click')
        dom = [v for v in native if v['kind'] == 'dom' and v['runtime']['loadToken'] == token
            and v['observation'].get('stage') == 'dom_observable_change'
            and (v['observation'].get('precedingEvent') or {}).get('eventID') == click['observation']['eventID']]
        expected_before, expected_after = binding['beforeText'], binding['afterText']
        require(any(any(o.get('selector') == binding['selector'] and o.get('text') == expected_after
                       for o in v['observation'].get('observables', [])) for v in dom),
                'The real DOM outcome does not corroborate the reviewed changed pixels')
        before, after = (frame_by_seq[binding[k]] for k in ('lastOldFrame', 'firstNewFrame'))
        require(before['sequence'] < after['sequence'], 'Displayed frame order is invalid')
        require(binding.get('reviewedBeforeText') == expected_before and binding.get('reviewedAfterText') == expected_after,
                'Reviewed visible state does not match the outcome')
        image_before, image_after = frame_image(directory, before), frame_image(directory, after)
        require(image_before.size == image_after.size, 'Window geometry changed during the comparison')
        roi = tuple(binding['countROI']); require(len(roi) == 4 and all(isinstance(x, int) for x in roi), 'ROI must use integer pixels')
        require(0 <= roi[0] < roi[2] <= image_before.width and 0 <= roi[1] < roi[3] <= image_before.height, 'ROI is outside the actual frame')
        require(ImageChops.difference(image_before.crop(roi), image_after.crop(roi)).getbbox() is not None,
                'The reviewed output pixels did not change')
        old_s, new_s = int(before['displayMach'])*factor, int(after['displayMach'])*factor
        require(began_s <= new_s and new_s >= old_s, 'Visible outcome predates its contact or frames run backwards')
        require(new_s <= int(after['receivedMach'])*factor, 'Frame display timestamp follows receipt')
        # Upper bound includes clock uncertainty; lower bound comes from the
        # latest real reviewed old-state frame, never an interpolated frame.
        lower = max(0, old_s-(ended['touchUptimeSeconds']+offset[1]))*1000
        upper = (new_s-(ended['touchUptimeSeconds']+offset[0]))*1000
        require(upper >= -.001, 'Click outcome is already visible before release')
        verdict = 'pass' if upper <= 100 else ('fail' if lower > 100 else 'inconclusive')
        start_lower = max(0, old_s-(began['touchUptimeSeconds']+offset[1]))*1000
        start_upper = (new_s-(began['touchUptimeSeconds']+offset[0]))*1000
        start_verdict = 'pass' if start_upper <= 100 else ('fail' if start_lower > 100 else 'inconclusive')
        outcomes.append({'contactID': contact, 'loadToken': token, 'releaseToVisibleMs': {'lower': lower,'upper':upper},
            'touchStartToVisibleUpperMs': start_upper,
            'touchStartToVisibleMs': {'lower':start_lower,'upper':start_upper}, 'touchStartToCountVerdict':start_verdict,
            'observedTouchHoldMs':(ended['touchUptimeSeconds']-began['touchUptimeSeconds'])*1000,
            'releaseToDOMReceiptUpperMs': (click_s-(ended['touchUptimeSeconds']+offset[0]))*1000,
            'lastOldPNG': before['png'], 'firstNewPNG': after['png'],
            'reviewedFrameGapMs': (new_s-old_s)*1000, 'verdict': verdict})
    require(len(outcomes) >= 10, 'Ten distinct ready-control transitions are required')
    return {'format':1, 'scope':'Simulator ready click release to actual window-server displayed state',
            'thresholdMs':100, 'fpsMeasured':False, 'physicalIPadMeasured':False,
            'verdict':'pass' if all(o['verdict']=='pass' for o in outcomes) else
                ('fail' if any(o['verdict']=='fail' for o in outcomes) else 'inconclusive'),
            'observations':outcomes, 'reviewer':review['reviewer'], 'uiEvidence':review['uiEvidence']}


def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--native',type=Path,required=True)
    parser.add_argument('--capture',type=Path,required=True);parser.add_argument('--review',type=Path,required=True)
    args=parser.parse_args()
    try: result=analyze(args.native,args.capture,json.loads(args.review.read_text()))
    except (Unmeasured,KeyError,ValueError,OSError,TypeError,IndexError) as error: result={'verdict':'unmeasured','reason':str(error)}
    print(json.dumps(result,indent=2,ensure_ascii=False))
    return 0 if result['verdict']=='pass' else 1

if __name__=='__main__':raise SystemExit(main())
