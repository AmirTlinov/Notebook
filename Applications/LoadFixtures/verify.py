#!/usr/bin/env python3
"""Verify each original and the bounded manifest, without loading decoded rasters."""
import collections
import hashlib
import json
import pathlib
import sys


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        while block := stream.read(1024 * 1024):
            result.update(block)
    return result.hexdigest()


def verify(root):
    root = root.resolve(strict=True)
    manifest = json.loads((root / 'manifest.json').read_text())
    assert manifest['format'] == 1
    assert 1 <= manifest['itemCount'] <= 100000
    records_path = root / 'items.jsonl'
    assert digest(records_path) == manifest['recordsSHA256']
    kinds = collections.Counter()
    complexity = collections.Counter()
    identifiers, hashes, paths = set(), set(), set()
    total_bytes = pixels = pages = unknown = 0
    formats, orientations = set(), set()
    with records_path.open() as stream:
        for ordinal, line in enumerate(stream):
            item = json.loads(line)
            assert item['ordinal'] == ordinal
            assert item['itemID'] not in identifiers
            identifiers.add(item['itemID'])
            source = item['source']
            path = root / source['path']
            assert path.resolve(strict=True).is_relative_to(root / 'originals')
            assert not path.is_symlink()
            assert source['path'] not in paths
            paths.add(source['path'])
            actual_hash = digest(path)
            assert actual_hash == source['sha256']
            assert actual_hash not in hashes, 'Copies of one original are not unique sources'
            hashes.add(actual_hash)
            assert path.stat().st_size == source['bytes'] > 0
            total_bytes += source['bytes']
            pixels += source.get('pixelWidth', 0) * source.get('pixelHeight', 0)
            pages += source.get('pages', 0)
            unknown += 'pages' not in source
            kinds[item['kind']] += 1
            formats.add(source['format'])
            if 'orientation' in source:
                orientations.add(source['orientation'])
            if item['kind'] == 'notebook':
                leaves = json.loads(path.read_text())
                assert len(leaves) == source['pages'] == 4
                samples = 0
                stroke_ids = set()
                for leaf in leaves:
                    assert leaf['width'] == 834 and leaf['height'] == 1194
                    for stroke in leaf['strokes']:
                        assert stroke['id'] not in stroke_ids
                        stroke_ids.add(stroke['id'])
                        assert stroke['tool'] in ('pen', 'eraser')
                        previous = -1
                        for sample in stroke['samples']:
                            assert 0 <= sample['x'] <= leaf['width']
                            assert 0 <= sample['y'] <= leaf['height']
                            assert 0 <= sample['force'] <= 1 and sample['width'] > 0
                            assert sample['timeOffset'] > previous
                            previous = sample['timeOffset']
                            samples += 1
                assert samples == source['complexity']['inkSamples']
            complexity.update(source['complexity'])
            for arrangement in ('sparse', 'dense', 'overlap'):
                assert set(item[arrangement]) == {'x', 'y'}
            if ordinal >= 24:
                assert item['sparse']['x'] >= 100000 and item['sparse']['y'] >= 100000
    assert len(identifiers) == len(hashes) == manifest['uniqueSources'] == manifest['itemCount']
    assert dict(kinds) == manifest['countsByKind']
    assert total_bytes == manifest['totalBytes']
    assert pixels == manifest['totalPixels']
    assert pages == manifest['knownPageCount']
    assert unknown == manifest['unpaginatedDocuments'] == kinds['document']
    assert dict(complexity) == manifest['complexity']
    assert len(list((root / 'originals').iterdir())) == manifest['itemCount']
    result = dict(itemCount=manifest['itemCount'], seed=manifest['seed'], uniqueSources=len(hashes),
                  bytes=total_bytes, knownPages=pages, unpaginatedDocuments=unknown, pixels=pixels,
                  formats=sorted(formats), imageOrientations=sorted(orientations),
                  generatorSHA256=manifest['generatorSHA256'], recordsSHA256=manifest['recordsSHA256'])
    print(json.dumps(result, sort_keys=True))
    return result


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: verify.py <completed workload directory>')
    verify(pathlib.Path(sys.argv[1]))
