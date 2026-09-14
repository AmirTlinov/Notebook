"""Unit proof for the measuring instrument, not visual acceptance of Notebook."""
import unittest
import numpy as np
from measure import locate


class MeasurementTests(unittest.TestCase):
    def frame(self, red_offset=0):
        image = np.full((2388, 1668, 3), 255, dtype=np.uint8)
        for x, y, color in [(434, 1414, (5, 64, 255)), (1234, 1414, (255, 128, 0)),
                             (634 + red_offset, 1114, (237, 18, 32)), (1034, 1114, (23, 192, 68))]:
            image[y - 4:y + 5, x - 16:x + 17] = color
            image[y - 16:y + 17, x - 4:x + 5] = color
        return image

    def test_exact_projection_has_no_measured_relative_displacement(self):
        result = locate(self.frame())
        self.assertEqual(result['status'], 'measured')
        for key in ['redErrorX', 'redErrorY', 'greenErrorX', 'greenErrorY']:
            self.assertEqual(result[key], 0)

    def test_svg_displacement_is_measured_independently_from_camera_anchors(self):
        result = locate(self.frame(red_offset=4))
        self.assertEqual(result['redErrorX'], 4)
        self.assertEqual(result['redErrorY'], 0)
        self.assertEqual(result['greenErrorX'], 0)
        self.assertEqual(result['greenErrorY'], 0)

    def test_missing_pixels_are_not_counted_as_zero_error(self):
        result = locate(np.full((2388, 1668, 3), 255, dtype=np.uint8))
        self.assertEqual(result['status'], 'missing_or_ambiguous_ink')
        self.assertNotIn('redErrorX', result)

    def test_an_orange_ink_anchor_cannot_replace_a_still_pending_red_source(self):
        image = self.frame()
        image[1090:1140, 610:660] = 255
        result = locate(image)
        self.assertEqual(result['status'], 'missing_red')
        self.assertNotIn('redErrorX', result)


if __name__ == '__main__':
    unittest.main()
