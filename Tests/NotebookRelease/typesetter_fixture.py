"""Tiny deterministic packaging bytes; never executable or typography evidence."""
from pathlib import Path
import hashlib, json
FILES = {'texlive.zip': b'fixture distribution', 'latex.fmt': b'fixture format',
         'fonts.tsv': b'fixture fonts', 'notebook-markup.js': b'fixture markup',
         'revision.txt': b'fixture-typesetter\n', 'licenses/NOTICE': b'fixture public notice'}
IDENTITY = 'fixture-typesetter'
def pin(data): return {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
LOCK = {'distribution': pin(FILES['texlive.zip']), 'kernels': {name: pin(FILES[name]) for name in ['latex.fmt', 'fonts.tsv']}}
def stage(root):
    root = Path(root)
    for name, data in FILES.items():
        path = root/name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data)
    (root/'manifest.json').write_text(json.dumps({'format': 1, 'inputSHA256': IDENTITY,
        'files': {name: pin(data) for name, data in FILES.items()}}))
    return root
