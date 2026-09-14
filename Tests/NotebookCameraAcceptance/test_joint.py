"""Contracts of the pixel instrument; these are not product acceptance tests."""
import copy
import math
import unittest
import numpy as np
from component_centroid import METHODS, measure_components, relative_errors
from measure_joint import accepted_poses, anchors, associate, calibration
from test_measure import MeasurementTests


def row(red=(0., 0.), green=(0., 0.), shift=0.):
    centers = {'blue': [434.+shift, 1414.], 'orange': [1234.+shift, 1414.],
               'red': [634.+shift+red[0], 1114.+red[1]], 'green': [1034.+shift+green[0], 1114.+green[1]]}
    return {'index': 0, 'status': 'measured', 'motionIntervals': [],
            'eligibleContacts': [3, 4, 5, 8],
            'methods': {method: {'centers': copy.deepcopy(centers), 'errors': relative_errors(centers)} for method in METHODS}}


class JointMeasurementTests(unittest.TestCase):
    def test_component_centroid_reads_actual_pixels_and_preserves_a_known_shift(self):
        measured = measure_components(MeasurementTests().frame(red_offset=4))
        self.assertEqual(measured['status'], 'measured')
        for method in METHODS:
            self.assertAlmostEqual(measured['methods'][method]['errors']['red'][0], 4, places=6)
            self.assertAlmostEqual(measured['methods'][method]['errors']['green'][0], 0, places=6)

    def test_euclidean_diagonal_is_not_a_one_pixel_pass(self):
        measured = row(red=(.9, .9))
        self.assertAlmostEqual(math.hypot(*measured['methods']['chroma4']['errors']['red']), math.sqrt(1.62))
        self.assertGreater(math.hypot(*measured['methods']['chroma4']['errors']['red']), 1)

    def test_contact_association_requires_real_ink_motion_and_unique_direction(self):
        before, after = row(shift=-10), row()
        points = (anchors(after)+.5).tolist()
        outward = {'interval': 3, 'points': points, 'delta': [[10, 0], [10, 0]]}
        returning = {'interval': 4, 'points': points, 'delta': [[-10, 0], [-10, 0]]}
        self.assertEqual(associate(after, before, [outward, returning]), [3])
        self.assertEqual(associate(after, after, [outward]), [])
        duplicate = {**outward, 'interval': 5}
        self.assertEqual(associate(after, before, [outward, duplicate]), [3, 5],
                         'Two candidates remain ambiguous; neither is selected as a successful contact')

    def test_svg_error_does_not_control_contact_association(self):
        before, after = row(shift=-10), row(red=(7, 9), green=(-11, 2))
        pose = {'interval': 8, 'points': (anchors(after)+.5).tolist(), 'delta': [[10, 0], [10, 0]]}
        self.assertEqual(associate(after, before, [pose]), [8])
        self.assertEqual(after['methods']['chroma4']['errors']['red'], [7., 9.])

    def test_calibration_keeps_the_worst_video_at_the_same_ink_pose(self):
        png = row(); png['motionIntervals'] = [1]
        unchanged, displaced = row(), row(green=(3., 4.))
        displaced['index'] = 1
        png.update(witness=17, startedMachNS=1_000_000_000, endedMachNS=2_000_000_000)
        for video in (unchanged, displaced):
            video.update(witness=17, time=1.5)
        report = calibration([png], [unchanged, displaced], {'status': 'bounded', 'lower': 0, 'upper': 0})
        self.assertEqual(report['matchedMotionPNGs'], 1)
        self.assertEqual(report['maximumObservedDeltaPixels'], 5.)
        self.assertEqual(report['pairs'][0]['videoFrames'], [0, 1])

    def test_trace_without_viewport_or_with_only_endpoints_supplies_no_pose_proof(self):
        pose = {'viewportWidth': 834., 'viewportHeight': 1194., 'scale': .5,
                'originX': 417.25, 'originY': 597.25}
        earlier = {**pose, 'originX': 412.25}
        entries = [{'time': time, 'kind': 'pan', 'before': earlier, 'after': pose} for time in (1, 2, 3)]
        intervals = [{'start': 1, 'end': 3, 'kind': 'pan'}]
        result = accepted_poses(entries, intervals, 1668, 2388)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]['time'], 2)
        self.assertTrue(np.allclose(result[0]['points'], anchors(row())+.5))
        del pose['viewportWidth']
        self.assertEqual(accepted_poses(entries, intervals, 1668, 2388), [])


if __name__ == '__main__':
    unittest.main()
