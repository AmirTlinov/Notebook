#!/usr/bin/env python3
"""Compare every video frame and original PNG; preserve uncertain coverage/calibration."""
import argparse
import hashlib
import json
from fractions import Fraction
from pathlib import Path

import numpy as np
from PIL import Image
from component_centroid import measure_components, METHODS
from measure_lossless import gesture_intervals
from native_video import NativeVideo
from temporal_provenance import decode_witness, run_tag, origin_bounds, eligible_contacts, possible_same_cohort

PRIMARY = 'chroma4'
ANCHOR_MATCH_PIXELS = 0.125
POSE_MATCH_PIXELS = 0.25
MINIMUM_MOVEMENT_PIXELS = 0.2


def anchors(row):
    centers = row['methods'][PRIMARY]['centers']
    return np.array([centers['blue'], centers['orange']])


def errors(row):
    return np.array([row['methods'][PRIMARY]['errors'][c] for c in ('red', 'green')])


def method_spread(row):
    primary = errors(row)
    return max(float(np.linalg.norm(np.array([row['methods'][m]['errors'][c]
                 for c in ('red', 'green')])-primary, axis=1).max()) for m in METHODS)


def accepted_poses(trace, intervals, width, height):
    """Only associates frames to contacts; never supplies SVG/WK expectations."""
    result = []
    def points(pose):
        needed = {'viewportWidth', 'viewportHeight', 'scale', 'originX', 'originY'}
        if not needed <= pose.keys():
            return None
        scale = width/pose['viewportWidth']
        if abs(height-pose['viewportHeight']*scale) > 0.001:
            return None
        # Image centroids use zero-indexed samples; native points name pixel
        # boundaries. Pixel (x,y) has its physical centre at (x+.5,y+.5).
        return np.array([[pose['originX']+x*pose['scale'],
                          pose['originY']+220*pose['scale']] for x in (-400, 400)])*scale
    for index, interval in enumerate(intervals):
        for entry in trace:
            if not interval['start'] < entry['time'] < interval['end']:
                continue
            if entry.get('kind') not in ('pan', 'camera'):
                continue
            if entry.get('kind') == 'camera' and entry.get('phase') != 'changed':
                continue
            before, after = points(entry.get('before', {})), points(entry.get('after', {}))
            if before is None or after is None:
                continue
            delta = after-before
            if np.linalg.norm(delta) <= MINIMUM_MOVEMENT_PIXELS:
                continue
            result.append({'interval': index, 'time': entry['time'],
                           'points': after.tolist(), 'delta': delta.tolist()})
    return result


def associate(row, previous, poses):
    if previous is None or row['status'] != 'measured' or previous['status'] != 'measured' or not poses or not row.get('eligibleContacts'):
        return []
    current = anchors(row)+0.5
    delta = anchors(row)-anchors(previous)
    length = float(np.linalg.norm(delta))
    if length <= MINIMUM_MOVEMENT_PIXELS:
        return []
    positions = np.array([pose['points'] for pose in poses])
    directions = np.array([pose['delta'] for pose in poses])
    match = (np.linalg.norm(positions-current, axis=2).max(axis=1) <= POSE_MATCH_PIXELS) & np.array([pose['interval'] in row['eligibleContacts'] for pose in poses])
    cosine = (directions*delta).sum(axis=(1, 2))/(np.linalg.norm(directions, axis=(1, 2))*length)
    # Reversing along the same path is another contact. Do not arbitrarily pick
    # a matching position, nor count an unchanged encoded frame as movement.
    return sorted({pose['interval'] for pose, valid in zip(poses, match & (cosine >= 0.8)) if valid})


def calibration(png_rows, video_rows, origin):
    videos = [row for row in video_rows if row['status'] == 'measured']
    if not videos:
        return {'matchedPNGs': 0, 'matchedMotionPNGs': 0, 'maximumObservedDeltaPixels': None, 'pairs': []}
    video_anchors = np.array([anchors(row) for row in videos])
    pairs = []
    for png in png_rows:
        if png['status'] != 'measured':
            continue
        delta = np.linalg.norm(video_anchors-anchors(png), axis=2).max(axis=1)
        indices = np.flatnonzero((delta <= ANCHOR_MATCH_PIXELS) & np.array([possible_same_cohort(png, row, origin) for row in videos]))
        if not len(indices):
            continue
        # Every matching video frame participates, including source publication
        # at the same camera pose. Selecting the most favourable frame is invalid.
        discrepancy = max(float(np.linalg.norm(errors(videos[i])-errors(png), axis=1).max()) for i in indices)
        pairs.append({'png': png['index'], 'motion': bool(png.get('motionIntervals')),
                      'videoFrames': [videos[i]['index'] for i in indices],
                      'maximumAnchorDifferencePixels': float(delta[indices].max()),
                      'maximumRelativeDifferencePixels': discrepancy})
    return {'matchedPNGs': len(pairs), 'matchedMotionPNGs': sum(p['motion'] for p in pairs),
            'maximumObservedDeltaPixels': max((p['maximumRelativeDifferencePixels'] for p in pairs), default=None),
            'pairs': pairs,
            'pairing': 'All compatible same-witness and bounded-time candidates; no same-GPU-frame identity',
            'codecCalibrationCertified': False,
            'meaning': 'Observed cohort variability includes rendering and codec effects; not an isolated codec error bound'}


def run(directory, output):
    directory, output = directory.resolve(), output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    instruments = ['measure_joint.py', 'component_centroid.py', 'measure.py', 'measure_lossless.py',
                   'native_video.py', 'NativeVideoDecoder.swift', 'temporal_provenance.py']
    hashes = {}
    for name in instruments:
        raw = Path(__file__).with_name(name).read_bytes()
        (output/name).write_bytes(raw); hashes[name] = hashlib.sha256(raw).hexdigest()
    recording = json.loads((directory/'recording.json').read_text())
    manifest = json.loads((directory/'lossless/manifest.json').read_text())
    trace = json.loads((directory/'camera-input-trace.json').read_text())
    witnessed = recording.get('temporalWitness', {}).get('enabled') is True
    common_clock = witnessed and all('machNanos' in r for r in trace if r.get('kind') in ('pan', 'camera'))
    if common_clock:
        trace = [{**r, 'time': r['machNanos']/1e9} if 'machNanos' in r else r for r in trace]
    intervals = gesture_intervals(trace)
    viewport = next((r['after']['viewportWidth'] for r in trace if r.get('after', {}).get('viewportWidth')), None)
    tag = run_tag(recording['runID'])
    png_rows = []
    for sample in manifest['samples']:
        row = {key: sample[key] for key in ('index', 'file', 'startedAt', 'endedAt', 'status')}
        for key in ('startedMachNS', 'endedMachNS'):
            if key in sample:
                row[key] = sample[key]
        start = sample.get('startedMachNS', 0)/1e9 if common_clock else sample['startedAt']
        end = sample.get('endedMachNS', 0)/1e9 if common_clock else sample['endedAt']
        row['motionIntervals'] = [i for i, interval in enumerate(intervals) if interval['start'] <= start and end <= interval['end']]
        if sample['status'] == 'captured':
            path = directory/'lossless'/sample['file']; raw = path.read_bytes()
            if hashlib.sha256(raw).hexdigest() != sample['sha256']:
                raise ValueError('Modified original PNG: ' + str(path))
            with Image.open(path) as image:
                image.load()
                if image.size != (sample['width'], sample['height']):
                    raise ValueError('Modified original PNG geometry: ' + str(path))
                row['dimensions'] = list(image.size)
                pixels = np.asarray(image.convert('RGB'))
                row.update(measure_components(pixels))
                row['witness'] = decode_witness(pixels, image.width/viewport, tag) if common_clock and viewport else None
        png_rows.append(row)
    checkpoints = []
    for test in json.loads((directory/'attachments/manifest.json').read_text()):
        for item in test['attachments']:
            name = item.get('suggestedHumanReadableName', '').split('_')[0]
            if name.startswith('camera-settled-') or name == 'camera-finish':
                path = directory/'attachments'/item['exportedFileName']
                checkpoints.append({'index': name, 'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                                    **measure_components(np.asarray(Image.open(path).convert('RGB')))})
    video = directory/'simulator.mp4'
    decoder = NativeVideo(video, output)
    width, height = decoder.width, decoder.height
    poses = accepted_poses(trace, intervals, width, height)
    (output/'native-association-poses.json').write_text(json.dumps(poses, indent=2)+'\n')
    video_rows, previous, worst_pixels, worst_value = [], None, None, -1
    for frame, pixels in decoder.frames():
        row = {**frame, **measure_components(pixels)}
        row['witness'] = decode_witness(pixels, width/viewport, tag) if common_clock and viewport else None
        if row['status'] == 'measured':
            maximum = float(np.linalg.norm(errors(row), axis=1).max())
            if maximum > worst_value:
                worst_value, worst_pixels = maximum, pixels.copy()
        video_rows.append(row); previous = row
    if worst_pixels is not None:
        Image.fromarray(worst_pixels).save(output/'worst-decoded-video-frame.png')
    origin = origin_bounds(png_rows, video_rows, float(Fraction(decoder.probe['streams'][0]['time_base']))) if common_clock else {'status': 'unavailable', 'reason': 'Recording has no visual witness/common native Mach clock'}
    previous = None
    for row in video_rows:
        row['eligibleContacts'] = eligible_contacts(row, intervals, origin)
        candidates = associate(row, previous, poses)
        row['candidateContacts'] = candidates
        row['contact'] = candidates[0] if len(candidates) == 1 else None
        previous = row
    matched = calibration(png_rows, video_rows, origin)
    (output/'temporal-provenance.json').write_text(json.dumps(origin, indent=2)+'\n')
    for i, interval in enumerate(intervals):
        interval['losslessSamples'] = [r['index'] for r in png_rows if r['status'] == 'measured' and i in r['motionIntervals']]
        interval['videoFrames'] = [r['index'] for r in video_rows if r['contact'] == i]
    required = {'camera-settled-'+str(i) for i in range(10)} | {'camera-finish'}
    ui = json.loads((directory/'summary.json').read_text())
    png_measured = [r for r in png_rows if r['status'] == 'measured']
    video_measured = [r for r in video_rows if r['status'] == 'measured']
    completed = ui.get('passedTests') == 1 and ui.get('failedTests') == 0 and ui.get('skippedTests') == 0
    first, last = (video_measured[0]['index'], video_measured[-1]['index']) if video_measured else (0, -1)
    missing = longest = 0
    for row in video_rows[first:last+1]:
        missing = missing+1 if row['status'] != 'measured' else 0
        longest = max(longest, missing)
    coverage = (origin.get('status') == 'bounded' and completed and required <= {r['index'] for r in checkpoints if r['status'] == 'measured'}
        and len(png_measured) >= 200 and sum(bool(r['motionIntervals']) for r in png_measured) >= 60
        and manifest['stopReason'] == 'scenario_finished' and longest <= 3
        and all(r.get('dimensions') == [width, height] for r in png_rows if r['status'] != 'capture_error')
        and sum(i['kind'] == 'pinch' and i.get('endedNormally') for i in intervals) == 20
        and all(i['losslessSamples'] or i['videoFrames'] for i in intervals if i['end']-i['start'] > 0.12))
    observed = [*png_measured, *video_measured, *(r for r in checkpoints if r['status'] == 'measured')]
    maxima = {c: max((float(np.linalg.norm(errors(r)[i])) for r in observed), default=None) for i, c in enumerate(('red', 'green'))}
    spread = max((method_spread(r) for r in observed), default=None)
    adequate = matched['matchedPNGs'] >= 100 and matched['matchedMotionPNGs'] >= 60
    # The matching tolerance is an explicit extra calibration allowance; it
    # never changes the one-pixel requirement on the displayed material.
    uncertainty = (matched['maximumObservedDeltaPixels'] + 2*ANCHOR_MATCH_PIXELS + spread
                   if adequate and spread is not None else None)
    upper = {c: (v+uncertainty if v is not None and uncertainty is not None else None) for c, v in maxima.items()}
    lower = {c: (max(0, v-uncertainty) if v is not None and uncertainty is not None else None) for c, v in maxima.items()}
    candidate = coverage and matched.get('codecCalibrationCertified', False) and uncertainty is not None and all(v <= 1 for v in upper.values())
    summary = {'format': 1, 'source': str(directory), 'productionSourceSHA256': recording['productionSourceSHA256'],
        'harnessSHA256': recording['harnessSHA256'], 'instruments': hashes, 'nativeDecoder': decoder.summary(), 'thresholdEuclideanDevicePixels': 1,
        'videoSHA256': hashlib.sha256(video.read_bytes()).hexdigest(), 'videoFrames': len(video_rows),
        'measuredVideoFrames': len(video_measured), 'longestMissingVideoRun': longest,
        'measuredPNGs': len(png_measured), 'PNGsWhollyInsideActualContact': sum(bool(r['motionIntervals']) for r in png_measured),
        'combinedContactCoverage': coverage, 'clock': 'mach_absolute_ns' if common_clock else 'legacy_wall_time',
        'temporalProvenance': {k: v for k, v in origin.items() if k != 'constraints'}, 'contacts': intervals, 'maxima': maxima,
        'calibration': {k: v for k, v in matched.items() if k != 'pairs'}, 'maximumMethodSpreadPixels': spread,
        'empiricalUncertaintyPixels': uncertainty, 'observedUpperBounds': upper, 'observedLowerBounds': lower,
        'readyForIndependentPixelReview': candidate,
        'verdict': 'fail' if any(v is not None and v > 1 for v in lower.values()) else 'inconclusive',
        'limitations': 'All encoded video frames are inspected, not all GPU display frames. Native pose values only associate ink observations with contacts; error uses observed pixels. Empirical codec calibration and sufficient margin require independent review before PASS. No FPS or hardware claim.'}
    for name, value in [('summary', summary), ('png-samples', png_rows), ('video-frames', video_rows),
                        ('checkpoints', checkpoints), ('calibration-pairs', matched['pairs'])]:
        (output/(name+'.json')).write_text(json.dumps(value, indent=2)+'\n')
    print(json.dumps({k: v for k, v in summary.items() if k != 'contacts'}, indent=2))
    return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = run(args.run, args.output)
    raise SystemExit(1 if result['verdict'] == 'fail' else 0)
