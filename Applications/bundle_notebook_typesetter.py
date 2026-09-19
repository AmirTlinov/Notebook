#!/usr/bin/env python3
"""Copy only declared immutable resources into Xcode's literal output paths."""
import hashlib,json,os
from pathlib import Path
stage=Path(os.environ['NOTEBOOK_TYPESETTER_RUNTIME'])
destination=Path(os.environ['TARGET_BUILD_DIR'])/os.environ['UNLOCALIZED_RESOURCES_FOLDER_PATH']/'NotebookTypesetter'
manifest=json.loads((stage/'manifest.json').read_text())
for relative,expected in manifest['files'].items():
 if not relative.startswith('Resources/'):continue
 name=Path(relative).relative_to('Resources')
 if '..' in name.parts:raise RuntimeError('Resource path escapes bundle')
 source=stage/relative;target=destination/name
 target.parent.mkdir(parents=True,exist_ok=True)
 digest=hashlib.sha256();count=0
 with source.open('rb') as reader,target.open('wb') as writer:
  for data in iter(lambda:reader.read(1024*1024),b''):
   count+=len(data);digest.update(data);writer.write(data)
 if count!=expected['bytes'] or digest.hexdigest()!=expected['sha256']:raise RuntimeError('Typesetter resource identity changed: '+relative)

resources={str(Path(path).relative_to('Resources')):value for path,value in manifest['files'].items() if path.startswith('Resources/')}
(destination/'manifest.json').write_text(json.dumps({'format':1,'inputSHA256':manifest['inputSHA256'],'files':resources},sort_keys=True)+'\n')
