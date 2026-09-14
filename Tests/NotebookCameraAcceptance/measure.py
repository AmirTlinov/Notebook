#!/usr/bin/env python3
"""Measure every decoded Simulator frame against native ink anchors; requires numpy and ffmpeg."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import re

import numpy as np
from native_video import NativeVideo


def mask(rgb, color, tolerance=0):
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    if color == 'red': return (r > 180-tolerance) & (g < 130+tolerance) & (b < 140+tolerance) & (b.astype(np.int16) + 8 > g)
    if color == 'green': return (r < 90+tolerance) & (g > 130-tolerance) & (b < 110+tolerance)
    if color == 'blue': return (r < 75+tolerance) & (g < 150+tolerance) & (b > 180-tolerance)
    if color == 'orange': return (r > 210-tolerance) & (g > 100-tolerance) & (g < 175+tolerance) & (b < 65+tolerance)
    raise ValueError(color)


def components(binary):
    ys, xs = np.nonzero(binary)
    remaining = set(zip(xs.tolist(), ys.tolist()))
    result = []
    while remaining:
        origin = remaining.pop()
        queue = [origin]; points = [origin]
        while queue:
            x, y = queue.pop()
            for offset in ((-1, 0), (1, 0), (0, -1), (0, 1)):
                p = (x + offset[0], y + offset[1])
                if p in remaining:
                    remaining.remove(p); queue.append(p); points.append(p)
        if len(points) >= 3:
            xx, yy = zip(*points)
            result.append((min(xx), min(yy), max(xx), max(yy)))
    return result


def candidates(rgb, color):
    # A coarse locator narrows pixel reads, not frame sampling. Every returned
    # centroid uses every original device pixel in its full-resolution region.
    height, width = rgb.shape[:2]
    found = []
    for left, top, right, bottom in components(mask(rgb[::4, ::4], color)):
        left, top = max(0, left * 4 - 5), max(0, top * 4 - 5)
        right, bottom = min(width, right * 4 + 9), min(height, bottom * 4 + 9)
        yy, xx = np.nonzero(mask(rgb[top:bottom, left:right], color))
        if len(xx) < 45: continue
        w, h = int(xx.max() - xx.min() + 1), int(yy.max() - yy.min() + 1)
        cx, cy = float(xx.mean() + left), float(yy.mean() + top)
        # Fixture crosses remain inside this camera window for the prescribed
        # gestures. Menus/privacy dots outside the scene are not landmarks.
        if 12 <= w <= 110 and 12 <= h <= 110 and 0.65 <= w / h <= 1.5 and height * 0.23 < cy < height * 0.88:
            centers = [(cx, cy)]
            for tolerance in [-16, 16]:
                yv, xv = np.nonzero(mask(rgb[top:bottom, left:right], color, tolerance))
                if len(xv): centers.append((float(xv.mean() + left), float(yv.mean() + top)))
            # Sensitivity to edge inclusion exposes antialiasing/compression
            # uncertainty. It never expands the accepted one-pixel limit.
            ux = max(abs(x-cx) for x, _ in centers)
            uy = max(abs(y-cy) for _, y in centers)
            found.append((cx, cy, len(xx), ux, uy))
    return found


def locate(rgb):
    colors = {key: candidates(rgb, key) for key in ['blue', 'orange', 'red', 'green']}
    pairs = [(a, b) for a in colors['blue'] for b in colors['orange']
             if abs(a[1] - b[1]) <= 2 and 150 < b[0] - a[0] < rgb.shape[1] * 0.8]
    if len(pairs) != 1:
        return {'status': 'missing_or_ambiguous_ink', 'candidates': {key: len(value) for key, value in colors.items()}}
    blue, orange = pairs[0]
    density = (orange[0] - blue[0]) / 800
    result = {'status': 'measured', 'blueX': blue[0], 'blueY': blue[1],
              'orangeX': orange[0], 'orangeY': orange[1], 'pixelsPerWorldPoint': density}
    for color, distance in [('red', 200), ('green', 600)]:
        expected = (blue[0] + distance * density, (blue[1] + orange[1]) / 2 - 300 * density)
        values = sorted(colors[color], key=lambda p: (p[0] - expected[0]) ** 2 + (p[1] - expected[1]) ** 2)
        if not values:
            result['status'] = 'missing_' + color
            continue
        chosen = values[0]
        result.update({color + 'X': chosen[0], color + 'Y': chosen[1],
                       color + 'ExpectedX': expected[0], color + 'ExpectedY': expected[1],
                       color + 'ErrorX': chosen[0] - expected[0], color + 'ErrorY': chosen[1] - expected[1],
                       color + 'UncertaintyX': chosen[3] + (1-distance/800)*blue[3] + distance/800*orange[3],
                       color + 'UncertaintyY': chosen[4] + (blue[4]+orange[4])/2 + 300/800*(blue[3]+orange[3])})
    return result


def measure(args):
    instrument = Path(__file__).read_bytes()
    video = args.video.resolve()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    (out / 'measurement.py').write_bytes(instrument)
    decoder = NativeVideo(video, out)
    width, height = decoder.width, decoder.height
    rows = []; previous = None; worst = None; worst_error = -1.0
    for metadata, frame in decoder.frames():
        row = {'frame': metadata['index'], **{k: metadata[k] for k in ('time', 'ptsValue', 'ptsTimescale')}, **locate(frame)}
        row['moving'] = False
        if row['status'] == 'measured':
            if previous is not None:
                # Moving material while ink stalls is precisely a relative
                # camera fault; it must not be labelled stationary.
                row['moving'] = max(abs(row[k] - previous[k]) for k in
                                    ('blueX', 'blueY', 'orangeX', 'orangeY', 'redX', 'redY', 'greenX', 'greenY')) > 0.2
            previous = row
            error = max(abs(row[k]) for k in ['redErrorX', 'redErrorY', 'greenErrorX', 'greenErrorY'])
            if error > worst_error:
                worst_error = error; worst = frame.copy()
        else:
            previous = None
        rows.append(row)
    fields = ['frame', 'time', 'status', 'moving', 'blueX', 'blueY', 'orangeX', 'orangeY', 'pixelsPerWorldPoint']
    fields += [color + suffix for color in ['red', 'green'] for suffix in ['X', 'Y', 'ExpectedX', 'ExpectedY', 'ErrorX', 'ErrorY', 'UncertaintyX', 'UncertaintyY']]
    with (out / 'frames.csv').open('w') as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction='ignore')
        writer.writeheader(); writer.writerows(rows)
    measured = [row for row in rows if row['status'] == 'measured']
    moving = [row for row in measured if row['moving']]
    first = measured[0]['frame'] if measured else 0
    last = measured[-1]['frame'] if measured else -1
    gaps = [row for row in rows[first:last + 1] if row['status'] != 'measured']
    longest = 0; current = 0
    for row in rows[first:last + 1]:
        current = current + 1 if row['status'] != 'measured' else 0
        longest = max(longest, current)
    statistics = {}
    for color in ['red', 'green']:
        for label, subset in [('all', measured), ('motion', moving)]:
            errors = [max(abs(row[color + 'ErrorX']), abs(row[color + 'ErrorY'])) for row in subset]
            upper = [max(abs(row[color+'Error'+axis])+row[color+'Uncertainty'+axis] for axis in 'XY') for row in subset]
            lower = [max(max(0, abs(row[color+'Error'+axis])-row[color+'Uncertainty'+axis]) for axis in 'XY') for row in subset]
            statistics[color + '_' + label] = {'frames': len(errors), 'p95DevicePixels': float(np.percentile(errors, 95)) if errors else None,
                                               'maxDevicePixels': max(errors) if errors else None,
                                               'maxUpperDevicePixels': max(upper) if upper else None,
                                               'maxLowerDevicePixels': max(lower) if lower else None}
    # The recording alone cannot prove all ten gestures finished: a failed
    # runner may leave a perfectly measurable prefix. Each actual XCUITest
    # settled/finish PNG is an independent pixel checkpoint.
    runner_file = video.parent / 'summary.json'
    runner = json.loads(runner_file.read_text()) if runner_file.exists() else {}
    manifest_file = video.parent / 'attachments/manifest.json'
    checkpoints = {}
    if manifest_file.exists():
        from PIL import Image
        manifest = json.loads(manifest_file.read_text())
        for test in manifest:
            for attachment in test.get('attachments', []):
                name = attachment.get('suggestedHumanReadableName', '')
                match = re.match(r'^(camera-settled-\d+|camera-finish)_', name)
                if not match: continue
                file = manifest_file.parent / attachment['exportedFileName']
                checkpoints[match[1]] = {'path': str(file), **locate(np.array(Image.open(file).convert('RGB')))}
    required = {'camera-settled-'+str(i) for i in range(10)} | {'camera-finish'}
    runner_completed = runner.get('passedTests') == 1 and runner.get('failedTests') == 0 and runner.get('skippedTests') == 0
    complete_scenario = runner_completed and required <= checkpoints.keys() and all(checkpoints[k]['status'] == 'measured' for k in required)
    sufficient = complete_scenario and len(measured) >= 200 and len(moving) >= 60 and longest <= 3
    checkpoint_upper = [abs(v[c+'Error'+a])+v[c+'Uncertainty'+a] for v in checkpoints.values()
                        if v['status'] == 'measured' for c in ['red', 'green'] for a in 'XY']
    checkpoint_lower = [max(0, abs(v[c+'Error'+a])-v[c+'Uncertainty'+a]) for v in checkpoints.values()
                        if v['status'] == 'measured' for c in ['red', 'green'] for a in 'XY']
    within = sufficient and all(v['maxUpperDevicePixels'] <= args.threshold for v in statistics.values()) and max(checkpoint_upper) <= args.threshold
    # One unambiguous observed violation disproves the limit; complete coverage
    # is required to accept it, not to retain an already visible counterexample.
    outside = any(v['maxLowerDevicePixels'] is not None and v['maxLowerDevicePixels'] > args.threshold
                  for v in statistics.values()) or any(v > args.threshold for v in checkpoint_lower)
    summary = {'format': 1, 'video': str(video), 'width': width, 'height': height,
               'measurementSHA256': hashlib.sha256(instrument).hexdigest(), 'nativeDecoder': decoder.summary(),
               'completedTenGestureScenario': runner_completed, 'completePixelCoverage': sufficient,
               'pixelCheckpoints': checkpoints,
               'framesDecoded': len(rows), 'framesMeasured': len(measured), 'motionFramesMeasured': len(moving),
               'firstMeasuredFrame': first, 'lastMeasuredFrame': last, 'missingFramesBetweenMeasurements': len(gaps),
               'longestMissingRun': longest, 'thresholdDevicePixels': args.threshold, 'errors': statistics,
               'evidence': 'Every decoded Simulator display frame; source is simctl recordVideo, no UIView geometry or Mac PNG',
               'uncertainty': 'Centroid sensitivity to +/-16 RGB threshold; ambiguous boundary remains inconclusive',
               'verdict': 'pass' if within else 'fail' if outside else 'inconclusive', 'passed': within}
    (out / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
    if worst is not None:
        from PIL import Image
        Image.fromarray(worst).save(out / 'worst-frame.png')
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0 if summary['passed'] else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--video', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parsed = parser.parse_args()
    parsed.threshold = 1
    raise SystemExit(measure(parsed))
