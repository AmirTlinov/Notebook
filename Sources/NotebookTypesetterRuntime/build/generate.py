from pathlib import Path
import re, subprocess
import sys

FUNCTION_PROLOGUE = r'''#define FUNC_PROLOGUE \
  struct w2c_wasi__snapshot__preview1 *const notebook_run = instance->w2c_wasi__snapshot__preview1_instance; \
  NOTEBOOK_ENTER(notebook_run); NOTEBOOK_POLL(notebook_run)
#define FUNC_EPILOGUE NOTEBOOK_LEAVE(notebook_run)'''


def instrument_loops(source):
    """Pinned wasm2c emits cycles as direct goto; every cycle has a back edge.

    Function entry polls cover recursion. Back-edge targets cover intra-function
    cycles, including multiple-entry loops. Forward-only block exits need no poll.
    Reject a new control-flow form instead of silently losing cancellation.
    """
    if not __debug__:
        raise RuntimeError("Typesetter generation requires enabled validation")
    # Mask C comments/literals without changing offsets or line boundaries.
    literals = r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\''
    code = re.sub(literals, lambda m: re.sub(r'[^\n]', ' ', m[0]), source, flags=re.S)
    assert not re.search(r'\b(?:for|while|do)\b|RETURN_CALL|TAIL_CALL|wasm_rt_(?:throw|load_exception|set_unwind_target)', code), 'unreviewed control flow'
    functions = re.compile(r'(?m)^(?:\w+[ \t*]+)+(\w+)\([^;{}]*\)\s*\{(?P<body>.*?)^\}', re.S)
    insertions = []
    prologues = 0
    resolved_gotos = 0
    for function in functions.finditer(code):
        body = function['body']
        if 'FUNC_PROLOGUE;' not in body:
            assert not re.search(r'\bgoto\b', body), ('non-guest goto', function[1])
            continue
        assert body.count('FUNC_PROLOGUE;') == body.count('FUNC_EPILOGUE;') == 1, function[1]
        prologues += 1
        labels = list(re.finditer(r'(?m)^[ \t]*(var_\w+):;?', body))
        locations = {m[1]: m.start() for m in labels}
        assert len(labels) == len(locations), ('duplicate label', function[1])
        # A label with an unfamiliar spelling is an unreviewed generator form.
        named = re.findall(r'(?m)^[ \t]*(\w+):', body)
        assert set(named) <= set(locations) | {'default'}, ('unknown label', function[1])
        jumps = list(re.finditer(r'\bgoto\s+(var_\w+)\s*;', body))
        assert len(jumps) == len(re.findall(r'\bgoto\b', body)), ('indirect goto', function[1])
        assert all(m[1] in locations for m in jumps), ('foreign target', function[1])
        resolved_gotos += len(jumps)
        backwards = {m[1] for m in jumps if locations[m[1]] < m.start()}
        insertions.extend(function.start('body') + m.end() for m in labels if m[1] in backwards)
    assert prologues == code.count('FUNC_PROLOGUE;'), 'unparsed guest function'
    assert resolved_gotos == len(re.findall(r'\bgoto\b', code)), 'unparsed goto'
    parts = []
    start = 0
    for offset in insertions:
        parts.extend((source[start:offset], ' NOTEBOOK_POLL(notebook_run);'))
        start = offset
    parts.append(source[start:])
    return ''.join(parts), len(insertions)


def main():
    root=Path(sys.argv[1]); out=root/'aot'; out.mkdir(parents=True,exist_ok=True)
    for wasm, module, stem in [(root/'tectonic.wasm', 'notebook', 'engine'), (root/'image.wasm', 'notebook_image', 'image')]:
        subprocess.run([str(root/'wabt-build/wasm2c'),str(wasm),'--no-debug-names','--num-outputs=6','-n',module,'-o',str(out/(stem+'.c'))],check=True)
    for p in list(out.glob('engine_*.c'))+list(out.glob('engine*-impl.h'))+list(out.glob('image_*.c'))+list(out.glob('image*-impl.h')):
        s=p.read_text()
        if p.name.endswith('-impl.h'):
            # The pinned kernels have no internal exception unwinding. Every normal
            # function exit decrements this run's depth; a trap ends and discards the run.

            s,count=re.subn(r'#if WASM_RT_STACK_DEPTH_COUNT\n#define FUNC_PROLOGUE.*?\n#endif',lambda _:FUNCTION_PROLOGUE,s,count=1,flags=re.S)
            assert count==1,(p,'missing generated function boundary')
            assert not re.search(r'FUNC_PROLOGUE;|\bgoto\b',s),(p,'unexpected guest body in header')
            n=0
        else:
            s,n=instrument_loops(s)
        assert not re.search(r'\bwasm_rt_(saved_)?call_stack_depth\b',s),(p,'unowned generated stack counter')
        p.write_text('#include "supervisor.h"\n'+s)
        print(p,n)
    h=(out/'engine.h').read_text()+(out/'image.h').read_text();c=['#include "engine.h"','#include "wasm-rt-impl.h"','#include "supervisor.h"']
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

if __name__ == "__main__":
    main()
