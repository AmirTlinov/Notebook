"""Independent connected-component centroids on actual RGB display pixels.

The binary detector locates a marker only. Its full-resolution component and
antialiased boundary determine the continuous RGB/chromatic first moment.
"""
import numpy as np
from measure import components, locate, mask

COLORS = {'red': np.array([237., 18., 32.]), 'green': np.array([23., 192., 68.]),
          'blue': np.array([5., 64., 255.]), 'orange': np.array([255., 128., 0.])}
METHODS = tuple(mode + str(padding) for mode in ('rgb', 'chroma') for padding in (2, 4, 6))


def component_bounds(pixels, seed, color):
    x, y = map(round, seed)
    left, top = max(0, x - 64), max(0, y - 64)
    candidates = components(mask(pixels[top:y+65, left:x+65], color))
    if not candidates:
        raise ValueError('No connected marker component: ' + color)
    box = min(candidates, key=lambda b: ((b[0]+b[2])/2+left-seed[0])**2
              + ((b[1]+b[3])/2+top-seed[1])**2)
    return [box[0]+left, box[1]+top, box[2]+left+1, box[3]+top+1]


def center(pixels, box, color, chroma, padding):
    left, top, right, bottom = box
    left, top = max(0, left-padding), max(0, top-padding)
    right, bottom = min(pixels.shape[1], right+padding), min(pixels.shape[0], bottom+padding)
    region = pixels[top:bottom, left:right, :3].astype(float)
    edge = np.concatenate([region[0], region[-1], region[:, 0], region[:, -1]])
    background, foreground = np.median(edge, axis=0), COLORS[color]
    if chroma:
        region -= region.mean(axis=-1, keepdims=True)
        background = background-background.mean()
        foreground = foreground-foreground.mean()
    vector = foreground-background
    weights = np.maximum(0, (region-background) @ vector / (vector @ vector))
    total = weights.sum()
    if not np.isfinite(total) or total <= 0:
        raise ValueError('Marker has no measurable contrast: ' + color)
    yy, xx = np.indices(weights.shape)
    return [float((xx*weights).sum()/total+left), float((yy*weights).sum()/total+top)]


def relative_errors(centers):
    blue, orange = np.array(centers['blue']), np.array(centers['orange'])
    density = (orange[0]-blue[0])/800
    return {color: (np.array(centers[color])-np.array([blue[0]+distance*density,
                   (blue[1]+orange[1])/2-300*density])).tolist()
            for color, distance in [('red', 200), ('green', 600)]}


def measure_components(pixels):
    seed = locate(pixels)
    if seed['status'] != 'measured':
        return seed
    boxes = {color: component_bounds(pixels, [seed[color+'X'], seed[color+'Y']], color) for color in COLORS}
    methods = {}
    for chroma in (False, True):
        for padding in (2, 4, 6):
            centers = {color: center(pixels, boxes[color], color, chroma, padding) for color in COLORS}
            methods[('chroma' if chroma else 'rgb')+str(padding)] = {
                'centers': centers, 'errors': relative_errors(centers)}
    return {'status': 'measured', 'bounds': boxes, 'methods': methods}
