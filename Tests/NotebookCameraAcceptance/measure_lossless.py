#!/usr/bin/env python3
"""Measure original Simulator PNG samples, preserving capture gaps and native gesture coverage."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import re

import numpy as np
from PIL import Image

from measure import locate


def sample_timing(samples):
    captured = [sample for sample in samples if sample['status'] == 'captured']
    durations = [sample['endedAt'] - sample['startedAt'] for sample in captured]
    gaps = [{'earlier': a['index'], 'later': b['index'],
             'minimumSeconds': max(0, b['startedAt'] - a['endedAt']),
             'maximumSeconds': b['endedAt'] - a['startedAt']}
            for a, b in zip(captured, captured[1:])]
    return {'maximumCaptureDurationSeconds': max(durations) if durations else None,
            'p95CaptureDurationSeconds': float(np.percentile(durations, 95)) if durations else None,
            'largestPossibleGapBetweenObservedFramesSeconds': max((gap['maximumSeconds'] for gap in gaps), default=None),
            'gapBounds': gaps,
            'meaning': 'Each request observes one unknown instant inside its interval, not all frames during that interval. Failed requests supply no observed instant.'}


def gesture_intervals(trace):
    """Use actual native events only; these times never predict landmark coordinates."""
    result = []
    pan = []
    pinch = None

    def finish_pan():
        if len(pan) >= 2:
            result.append({'kind': 'pan', 'start': pan[0]['time'], 'end': pan[-1]['time'],
                           'nativeEvents': len(pan)})
        pan.clear()

    for entry in trace:
        kind = entry.get('kind')
        if kind == 'pan' and entry.get('before') != entry.get('after'):
            if pan and entry['time'] - pan[-1]['time'] > 0.25:
                finish_pan()
            pan.append(entry)
        elif kind == 'camera':
            finish_pan()
            if entry.get('phase') == 'began':
                pinch = entry
            elif entry.get('phase') in ('ended', 'cancelled') and pinch is not None:
                result.append({'kind': 'pinch', 'start': pinch['time'], 'end': entry['time'],
                               'endedNormally': entry['phase'] == 'ended'})
                pinch = None
    finish_pan()
    return sorted(result, key=lambda interval: interval['start'])


def measure(directory, output):
    directory, output = directory.resolve(), output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    instrument = Path(__file__).read_bytes()
    locator = Path(__file__).with_name('measure.py').read_bytes()
    (output / 'measurement.py').write_bytes(instrument)
    (output / 'landmark-locator.py').write_bytes(locator)
    manifest = json.loads((directory / 'lossless/manifest.json').read_text())
    trace = json.loads((directory / 'camera-input-trace.json').read_text())
    intervals = gesture_intervals(trace)
    rows = []
    previous = None
    dimensions = set()
    worst = None
    for sample in manifest['samples']:
        row = {key: sample[key] for key in ('index', 'file', 'startedAt', 'endedAt', 'status')}
        row['motionIntervals'] = [index for index, interval in enumerate(intervals)
                                  if sample['startedAt'] >= interval['start'] and sample['endedAt'] <= interval['end']]
        row['observedLandmarkMovement'] = False
        if sample['status'] == 'captured':
            path = directory / 'lossless' / sample['file']
            raw = path.read_bytes()
            if hashlib.sha256(raw).hexdigest() != sample['sha256']:
                raise RuntimeError('Captured PNG changed: ' + str(path))
            with Image.open(path) as image:
                image.load()
                if image.size != (sample['width'], sample['height']):
                    raise RuntimeError('Captured PNG geometry changed: ' + str(path))
                dimensions.add(image.size)
                pixels = np.asarray(image.convert('RGB'))
            row.update(locate(pixels))
            if row['status'] == 'measured':
                if previous is not None:
                    row['observedLandmarkMovement'] = max(abs(row[key] - previous[key]) for key in
                        ('blueX', 'blueY', 'orangeX', 'orangeY', 'redX', 'redY', 'greenX', 'greenY')) > 0.2
                previous = row
                error = max(float(np.hypot(row[color+'ErrorX'], row[color+'ErrorY'])) for color in ('red', 'green'))
                if worst is None or error > worst[0]:
                    worst = (error, path, row['index'])
            else:
                previous = None
        else:
            previous = None
        rows.append(row)
    measured = [row for row in rows if row['status'] == 'measured']
    motion = [row for row in measured if row['motionIntervals']]
    for index, interval in enumerate(intervals):
        interval['capturedInside'] = [row['index'] for row in rows if index in row['motionIntervals']]
        interval['measuredInside'] = [row['index'] for row in measured if index in row['motionIntervals']]
    checkpoints = {}
    attachment_manifest = directory / 'attachments/manifest.json'
    if attachment_manifest.exists():
        for test in json.loads(attachment_manifest.read_text()):
            for entry in test.get('attachments', []):
                name = entry.get('suggestedHumanReadableName', '')
                match = re.match(r'^(camera-settled-\d+|camera-finish)_', name)
                if match:
                    path = attachment_manifest.parent / entry['exportedFileName']
                    checkpoints[match[1]] = {'path': str(path), **locate(np.asarray(Image.open(path).convert('RGB')))}
    required = {'camera-settled-' + str(index) for index in range(10)} | {'camera-finish'}
    runner = json.loads((directory / 'summary.json').read_text())
    runner_complete = runner.get('passedTests') == 1 and runner.get('failedTests') == 0 and runner.get('skippedTests') == 0
    observed = [*measured, *(row for row in checkpoints.values() if row['status'] == 'measured')]
    errors = {}
    for color in ('red', 'green'):
        values = [max(abs(row[color+'Error'+axis]) for axis in 'XY') for row in observed]
        lengths = [float(np.hypot(row[color+'ErrorX'], row[color+'ErrorY'])) for row in observed]
        lower = [max(max(0, abs(row[color+'Error'+axis])-row[color+'Uncertainty'+axis]) for axis in 'XY') for row in observed]
        upper = [max(abs(row[color+'Error'+axis])+row[color+'Uncertainty'+axis] for axis in 'XY') for row in observed]
        length_lower = [float(np.hypot(*(max(0, abs(row[color+'Error'+axis])-row[color+'Uncertainty'+axis])
                         for axis in 'XY'))) for row in observed]
        length_upper = [float(np.hypot(*(abs(row[color+'Error'+axis])+row[color+'Uncertainty'+axis]
                         for axis in 'XY'))) for row in observed]
        errors[color] = {'maxCoordinateDevicePixels': max(values) if values else None,
                         'p95CoordinateDevicePixels': float(np.percentile(values, 95)) if values else None,
                         'maxEuclideanDevicePixels': max(lengths) if lengths else None,
                         'p95EuclideanDevicePixels': float(np.percentile(lengths, 95)) if lengths else None,
                         'maxCoordinateSensitivityLower': max(lower) if lower else None,
                         'maxCoordinateSensitivityUpper': max(upper) if upper else None,
                         'maxEuclideanSensitivityLower': max(length_lower) if length_lower else None,
                         'maxEuclideanSensitivityUpper': max(length_upper) if length_upper else None}
    first, last = (measured[0]['index'], measured[-1]['index']) if measured else (0, -1)
    longest = current = 0
    for row in rows[first:last + 1]:
        current = current + 1 if row['status'] != 'measured' else 0
        longest = max(longest, current)
    significant = [interval for interval in intervals if interval['end'] - interval['start'] >= 0.12]
    scene_complete = runner_complete and required <= checkpoints.keys() and all(checkpoints[key]['status'] == 'measured' for key in required)
    coverage = (scene_complete and len(measured) >= 200 and len(motion) >= 60 and longest <= 3
                and sum(interval['kind'] == 'pinch' and interval.get('endedNormally') for interval in intervals) == 20
                and all(interval['measuredInside'] for interval in significant)
                and len(dimensions) == 1 and manifest['stopReason'] == 'scenario_finished')
    outside = any(value['maxEuclideanSensitivityLower'] is not None and value['maxEuclideanSensitivityLower'] > 1 for value in errors.values())
    within_sensitivity = coverage and all(value['maxEuclideanSensitivityUpper'] <= 1 for value in errors.values())
    # RGB-threshold sensitivity is not a complete antialias calibration. Keep
    # that distinction explicit even when all sampled pixels meet the limit.
    summary = {'format': 1, 'source': str(directory), 'thresholdDevicePixels': 1,
               'thresholdMetric': 'Euclidean distance between the observed and reference points; historical L-infinity is reported separately',
               'measurementSHA256': hashlib.sha256(instrument).hexdigest(),
               'locatorSHA256': hashlib.sha256(locator).hexdigest(),
               'dimensions': sorted(dimensions), 'samples': len(rows), 'measuredSamples': len(measured),
               'samplesWhollyInsideActualGesture': len(motion), 'gestureIntervals': intervals,
               'longestMissingSampleRun': longest, 'sampleTiming': sample_timing(manifest['samples']),
               'completedTenGestureScenario': runner_complete, 'completeSampleCoverage': coverage,
               'pixelCheckpoints': checkpoints, 'errors': errors,
               'sensitivityVerdict': 'pass' if within_sensitivity else 'fail' if outside else 'inconclusive',
               'verdict': 'fail' if outside else 'inconclusive',
               'uncertainty': 'Original detector +/-16 RGB sensitivity only; independent subpixel calibration is required for final acceptance',
               'evidence': 'Unmodified simctl display PNG samples during real XCUITest gestures; no claim about unsampled frames or FPS'}
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    (output / 'samples.json').write_text(json.dumps(rows, indent=2) + '\n')
    if rows:
        keys = sorted(set().union(*(row.keys() for row in rows)))
        with (output / 'samples.csv').open('w') as stream:
            writer = csv.DictWriter(stream, fieldnames=keys)
            writer.writeheader(); writer.writerows(rows)
    if worst:
        (output / 'worst-frame.png').write_bytes(worst[1].read_bytes())
        (output / 'worst-frame.json').write_text(json.dumps({'index': worst[2], 'original': str(worst[1]), 'maxEuclideanDevicePixels': worst[0]}) + '\n')
    printed = {key: value for key, value in summary.items() if key not in ('gestureIntervals', 'pixelCheckpoints')}
    printed['sampleTiming'] = {key: value for key, value in summary['sampleTiming'].items() if key != 'gapBounds'}
    print(json.dumps(printed, indent=2))
    return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    arguments = parser.parse_args()
    result = measure(arguments.run, arguments.output)
    raise SystemExit(0 if result['verdict'] == 'pass' else 1)
