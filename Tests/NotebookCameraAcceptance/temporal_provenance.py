"""Conservative visual-cohort timing; never infer an origin by nearest/best pose fit."""
import numpy as np


def run_tag(run):
    result = 2166136261
    for byte in run.lower().encode():
        result = ((result ^ byte)*16777619) & 0xffffffff
    return result


def checksum(data):
    value = 0
    for byte in data:
        value ^= byte
        for _ in range(8):
            value = ((value << 1) ^ (7 if value & 128 else 0)) & 255
    return value


def decode_witness(pixels, scale, expected_tag):
    """Read the fixed test-only 72-cell strip, including preamble/run tag/CRC."""
    left = pixels.shape[1]/2 - 144*scale
    bits = []
    for index in range(72):
        x = int(round(left+(index*4+2)*scale))
        y = int(round(87*scale))
        if x < 1 or y < 1 or x+1 >= pixels.shape[1] or y+1 >= pixels.shape[0]:
            return None
        value = float(np.median(pixels[y-1:y+2, x-1:x+2, :3]))
        if 65 <= value <= 190:
            return None
        bits.append(int(value > 190))
    raw = bytes(sum(bits[i+j] << (7-j) for j in range(8)) for i in range(0, 72, 8))
    if raw[0] != 0xa5 or checksum(raw[1:8]) != raw[8] or int.from_bytes(raw[1:5], 'big') != expected_tag:
        return None
    return int.from_bytes(raw[5:8], 'big')


def origin_bounds(pngs, videos, pts_tick=0):
    """Intersect every observed cohort constraint. A CPU paint tick is not a display time."""
    observed = [r for r in videos if r.get('witness') is not None]
    if not observed or not any(r.get('startedMachNS') is not None for r in pngs):
        return {'status': 'unavailable', 'reason': 'No captured visual witness and common Mach clock'}
    if any(b['witness'] < a['witness'] for a, b in zip(observed, observed[1:])):
        return {'status': 'inconsistent', 'reason': 'Observed witness sequence regressed'}
    groups = []
    for row in observed:
        if not groups or groups[-1]['sequence'] != row['witness']:
            groups.append({'sequence': row['witness'], 'firstPTS': row['time'], 'lastPTS': row['time']})
        else:
            groups[-1]['lastPTS'] = row['time']
    indexed = {r['sequence']: i for i, r in enumerate(groups)}
    constraints = []
    for png in pngs:
        i = indexed.get(png.get('witness'))
        if i is None or i == 0 or i == len(groups)-1 or 'startedMachNS' not in png or 'endedMachNS' not in png:
            continue
        # Unique monotonic cohorts cannot reappear. The screenshot instant is
        # after the previous observed cohort and before the next observed one;
        # these are conservative neighbours, not claimed adjacent GPU frames.
        lower = png['startedMachNS']/1e9 - groups[i+1]['firstPTS'] - pts_tick
        upper = png['endedMachNS']/1e9 - groups[i-1]['lastPTS'] + pts_tick
        constraints.append({'png': png['index'], 'witness': png['witness'], 'lower': lower, 'upper': upper})
    if not constraints:
        return {'status': 'unavailable', 'reason': 'No screenshot cohort has both observed video neighbours'}
    lower, upper = max(r['lower'] for r in constraints), min(r['upper'] for r in constraints)
    if lower > upper:
        return {'status': 'inconsistent', 'reason': 'All observed clock-origin constraints have empty intersection',
                'lower': lower, 'upper': upper, 'constraints': constraints}
    return {'status': 'bounded', 'clock': 'mach_absolute_ns', 'lower': lower, 'upper': upper,
            'widthSeconds': upper-lower, 'ptsQuantizationSeconds': pts_tick, 'constraints': constraints,
            'meaning': 'All compatible origins; no best-fit offset and no GPU-frame identity'}


def eligible_contacts(row, intervals, origin):
    if origin.get('status') != 'bounded':
        return []
    tick = origin.get('ptsQuantizationSeconds', 0)
    lower, upper = row['time']+origin['lower']-tick, row['time']+origin['upper']+tick
    return [i for i, interval in enumerate(intervals) if interval['start'] <= lower and upper <= interval['end']]


def possible_same_cohort(png, video, origin):
    if origin.get('status') != 'bounded' or png.get('witness') is None or png.get('witness') != video.get('witness'):
        return False
    if 'startedMachNS' not in png or 'endedMachNS' not in png:
        return False
    tick = origin.get('ptsQuantizationSeconds', 0)
    return (video['time']+origin['lower']-tick <= png['endedMachNS']/1e9
            and png['startedMachNS']/1e9 <= video['time']+origin['upper']+tick)
