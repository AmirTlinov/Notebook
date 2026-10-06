"""Local verified-archive I/O benchmark; no Apple signature or executable is run."""
import hashlib,json,os,sys,tempfile,time
from pathlib import Path
from unittest.mock import patch
source=Path(sys.argv[1]).resolve(); archives=Path(sys.argv[2]).resolve()
sys.path.insert(0,str(source/'Applications'));import prepare_notebook_codex as c
r=c.admitted_runtime('arm64',source/'Applications/NotebookCodexRuntime.lock.json')
original_hash=c.payload_digest;original_copy=c.copy_exact
stats={};results=[]
def hashed(stream):
 stats['payloadSHABytes']+=os.fstat(stream.fileno()).st_size
 stats['payloadSHAFiles']+=1
 return original_hash(stream)
def copied(stream,output,size):
 original_copy(stream,output,size);stats['payloadCopyBytes']+=size
class Archive:
 def __init__(self,path): self.stream=path.open('rb')
 def __enter__(self):return self
 def __exit__(self,*args):self.stream.close()
 def read(self,size):
  block=self.stream.read(size);stats['archiveReadHashCopyBytes']+=len(block);return block
def read(url,timeout):
 stats['archiveOpens']+=1
 role=next(name for name,value in r['archives'].items() if value['url']==url)
 return Archive(archives/(role+'.tar.gz'))
def payload_only(stage,runtime):
 return {'status':'payload-only','stage':str(stage.resolve()),'identity':c.check_payload(stage,runtime)}
with tempfile.TemporaryDirectory(prefix='nb30-benchmark-') as temporary:
 cache=Path(temporary)/'cache'
 with patch.object(c.urllib.request,'urlopen',read),patch.object(c,'payload_digest',hashed),patch.object(c,'copy_exact',copied),patch.object(c,'check_stage',payload_only):
  for phase in ('cold-local-archives','reuse-1','reuse-2','reuse-3'):
   stats={name:0 for name in ('payloadSHABytes','payloadSHAFiles','payloadCopyBytes','archiveReadHashCopyBytes','archiveOpens')}
   begin=time.perf_counter();report=c.prepare(cache,r);elapsed=time.perf_counter()-begin
   results.append({'phase':phase,'seconds':round(elapsed,6),**stats})
print(json.dumps({'scope':'Linux payload admission only, local archives; includes cold extraction and fsync; warm OS page cache; no network timing or native performance claim',
 'manifestSHA256':c.identity(r)['manifestSHA256'],'payloadBytes':sum(e.get('bytes',0) for e in r['entries']),
 'nativeChecks':'Apple codesign, actual Codex/Node execution, Xcode sandbox and final signed app not run',
 'results':results},indent=2))
