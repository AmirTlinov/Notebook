from pathlib import Path
import re, subprocess
import sys
root=Path(sys.argv[1]); out=root/'aot'; out.mkdir(parents=True,exist_ok=True)
for wasm, module, stem in [(root/'tectonic.wasm', 'notebook', 'engine'), (root/'image.wasm', 'notebook_image', 'image')]:
 subprocess.run([str(root/'wabt-build/wasm2c'),str(wasm),'--no-debug-names','--num-outputs=6','-n',module,'-o',str(out/(stem+'.c'))],check=True)
for p in list(out.glob('engine_*.c'))+list(out.glob('engine*-impl.h'))+list(out.glob('image_*.c'))+list(out.glob('image*-impl.h')):
 s=p.read_text()
 s=s.replace('  FUNC_PROLOGUE;', '  FUNC_PROLOGUE; NOTEBOOK_STACK_CHECK(); NOTEBOOK_POLL();')
 s,n=re.subn(r'(^[ \t]*var_[A-Za-z0-9_]+:;?)',r'\1 NOTEBOOK_POLL();',s,flags=re.M)
 # Branches can only target the generated labels, all of which are polled.
 targets=set(re.findall(r'goto (var_[A-Za-z0-9_]+);',s))
 labels=set(re.findall(r'(var_[A-Za-z0-9_]+):;? NOTEBOOK_POLL\(\);',s))
 assert targets <= labels,(p,targets-labels)
 p.write_text('#include "supervisor.h"\n'+s)
 print(p,n)
h=(out/'engine.h').read_text()+(out/'image.h').read_text();c=['#include "engine.h"','#include "wasm-rt-impl.h"','struct w2c_wasi__snapshot__preview1 { void *context; wasm_rt_memory_t *memory; };']
r=['use super::NativeState;','use std::{future::Future, pin::pin, task::{Context, Poll, Waker}};','use wasi_common::snapshots::preview_1::wasi_snapshot_preview1 as wasi;']
for ret,name,params in sorted(set(re.findall(r'(u32|void) w2c_wasi__snapshot__preview1_(\w+)\(struct w2c_wasi__snapshot__preview1\*(.*?)\);',h))):
 types=params.lstrip(', ').split(', ') if params else []
 names=[f'a{i}' for i in range(len(types))]
 cparams=', '.join(f'{t} {n}' for t,n in zip(types,names)); cargs=', '.join(names)
 externargs=', '.join('uint64_t' if t=='u64' else 'uint32_t' for t in types)
 c += [f'extern uint32_t nb_wasi_{name}(void *, uint8_t *, size_t'+(', '+externargs if externargs else '')+');',
 f'{ret} w2c_wasi__snapshot__preview1_{name}(struct w2c_wasi__snapshot__preview1 *w'+(', '+cparams if cparams else '')+') {',
 f'  uint32_t result = nb_wasi_{name}(w->context, w->memory->data, w->memory->size'+(', '+cargs if cargs else '')+');',
 '  if (result == UINT32_MAX) wasm_rt_trap(WASM_RT_TRAP_UNREACHABLE);',
 '  return'+(' result' if ret=='u32' else '')+';','}']
 rparams=', '.join(f'{n}: {"u64" if t=="u64" else "u32"}' for t,n in zip(types,names))
 rargs=', '.join(f'{n} as {"i64" if t=="u64" else "i32"}' for t,n in zip(types,names))
 r += ['#[unsafe(no_mangle)]',f'pub unsafe extern "C" fn nb_wasi_{name}(state: *mut NativeState, bytes: *mut u8, len: usize'+(', '+rparams if rparams else '')+') -> u32 {',
 '  let state = unsafe { &mut *state };',
 '  if state.check() { return u32::MAX; }',
 '  let mut memory = wiggle::GuestMemory::Unshared(unsafe { std::slice::from_raw_parts_mut(bytes, len) });',
 f'  let future = wasi::{name}(&mut state.wasi, &mut memory'+(', '+rargs if rargs else '')+');',
 '  match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {',
 '    Poll::Ready(Ok(result)) => '+('result as u32' if ret=='u32' else '{ let _ = result; 0 }')+',',
 '    Poll::Ready(Err(error)) => { state.failure = Some(error.to_string()); u32::MAX },',
 '    Poll::Pending => { state.failure = Some("Blocking WASI operation denied".into()); u32::MAX },','  }','}']
(out/'wasi.c').write_text('\n'.join(c)+'\n')
generated = ('// Generated from the pinned engine WASI imports by prepare_notebook_typesetter.py.\n'+'\n'.join(r)+'\n')

expected=Path(__file__).resolve().parents[1]/'src/wasi.rs'
if expected.read_text() != generated:
 raise RuntimeError('WASI imports differ from the reviewed bridge; regenerate and review src/wasi.rs before preparing a release')
