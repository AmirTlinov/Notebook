#!/usr/bin/env python3
"""Execute small WASM kernels through the pinned AOT cancellation transform."""
from pathlib import Path
import importlib.util
import json
import re
import subprocess
import tempfile

RUNTIME = Path(__file__).resolve().parents[1]
ROOT = RUNTIME.parents[1]
BUILD = ROOT / ".build/typesetter-build"

WAT = r"""(module
  (import "wasi_snapshot_preview1" "tick" (func $tick))
  (memory 1)
  (global $steps (mut i32) (i32.const 0))
  (type $recursive (func (param i32) (result i32)))
  (table 1 funcref)
  (elem (i32.const 0) $recurse)
  (func (export "forward") (param i32) (result i32)
    call $tick
    (block $done
      (block $a
        (block $b
          local.get 0
          br_table $b $a $done)
        br $done))
    i32.const 42)
  (func (export "cycle") (param $limit i32) (result i32)
    (block $done
      (loop $again
        (global.set $steps (i32.add (global.get $steps) (i32.const 1)))
        (br_if $done (i32.eq (global.get $steps) (local.get $limit)))
        br $again))
    global.get $steps)
  (func (export "dispatch") (param $mode i32) (param $limit i32) (result i32)
    (block $done
      (loop $outer
        (loop $inner
          (global.set $steps (i32.add (global.get $steps) (i32.const 1)))
          (br_if $done (i32.eq (global.get $steps) (local.get $limit)))
          local.get $mode
          br_table $inner $outer)))
    global.get $steps)
  (func $recurse (export "recurse") (type $recursive) (param $depth i32) (result i32)
    local.get $depth
    i32.eqz
    if (result i32)
      i32.const 42
    else
      (i32.sub (local.get $depth) (i32.const 1))
      i32.const 0
      call_indirect (type $recursive)
    end)
  (func (export "outside") (result i32)
    (i32.load (i32.const 65536))))
"""

HARNESS = r"""
#include "probe.h"
#include "supervisor.h"
#include "wasm-rt-impl.h"
#include "wasm-rt-exceptions.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static w2c_probe instance;
static struct w2c_wasi__snapshot__preview1 run;
static unsigned polls, stop_at;
void w2c_wasi__snapshot__preview1_tick(struct w2c_wasi__snapshot__preview1 *p) { (void)p; }
void nb_typesetter_poll(struct w2c_wasi__snapshot__preview1 *p) {
  p->poll_count = 1024;
  if (++polls == stop_at) wasm_rt_trap(WASM_RT_TRAP_UNREACHABLE);
}
static void begin(unsigned stop) {
  memset(&instance, 0, sizeof(instance));
  run = (struct w2c_wasi__snapshot__preview1){ .poll_count = 1024 };
  polls = 0; stop_at = stop;
  wasm2c_probe_instantiate(&instance, &run);
}
static void recovery(void) {
  begin(0);
  assert(wasm_rt_impl_try() == WASM_RT_TRAP_NONE);
  assert(w2c_probe_forward(&instance, 2) == 42);
  assert(run.call_stack_depth == 0 && polls == 0);
  wasm2c_probe_free(&instance);
}
static void trap(unsigned operation, wasm_rt_trap_t expected, unsigned stop, unsigned first_poll) {
  begin(stop); run.poll_count = first_poll;
  int reason = wasm_rt_impl_try();
  if (!reason) {
    switch (operation) {
      case 0: w2c_probe_cycle(&instance, 0); break;
      case 1: w2c_probe_dispatch(&instance, 0, 0); break;
      case 2: w2c_probe_dispatch(&instance, 1, 0); break;
      case 3: w2c_probe_recurse(&instance, UINT32_MAX); break;
      case 4: w2c_probe_outside(&instance); break;
      default: abort();
    }
    abort();
  }
  assert(reason == expected);
  if (stop) assert(polls == stop);
  wasm2c_probe_free(&instance);
  recovery();
}
int main(void) {
  wasm_rt_init();
  begin(0);
  assert(wasm_rt_impl_try() == WASM_RT_TRAP_NONE);
  // A forward-only function consumes exactly its entry gate, on every branch.
  for (unsigned i = 0; i < 1024; ++i) assert(w2c_probe_forward(&instance, i % 3) == 42);
  assert(polls == 1 && run.poll_count == 1024 && run.call_stack_depth == 0);
  assert(w2c_probe_cycle(&instance, 17) == 17);
  assert(w2c_probe_dispatch(&instance, 0, 34) == 34);
  assert(w2c_probe_dispatch(&instance, 1, 51) == 51);
  assert(w2c_probe_recurse(&instance, 8) == 42);
  assert(run.call_stack_depth == 0);
  wasm2c_probe_free(&instance);
  for (unsigned i = 0; i < 3; ++i) trap(i, WASM_RT_TRAP_UNREACHABLE, 2, 1024);
  // Exercise cancellation on indirect entries before the separate stack limit.
  trap(3, WASM_RT_TRAP_UNREACHABLE, 1, 8);
  trap(3, WASM_RT_TRAP_EXHAUSTION, 0, 1024);
  trap(4, WASM_RT_TRAP_OOB, 0, 1024);
  wasm_rt_free();
  puts("PASS: forward branches, loops, br_if/br_table, indirect recursion, cancellation, stack/OOB traps, recovery");
}
"""


def run(args, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, timeout=60, **kwargs)


def main():
    pin = json.loads((RUNTIME / "Runtime.lock.json").read_text())["wabt"]["revision"]
    revision = subprocess.check_output(["git", "-C", str(BUILD / "wabt"), "rev-parse", "HEAD"], text=True).strip()
    if revision != pin:
        raise RuntimeError("Prepare the pinned WABT before testing its supervisor")
    wat2wasm, wasm2c = [BUILD / "wabt-build" / name for name in ("wat2wasm", "wasm2c")]
    if not wat2wasm.exists():
        run(["cmake", "--build", BUILD / "wabt-build", "--target", "wat2wasm", "-j", "2"])
    spec = importlib.util.spec_from_file_location("notebook_aot", RUNTIME / "build/generate.py")
    generator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(generator)
    # An unsupported control-flow form must fail before compiling a new kernel.
    for source in (
        "void tail(void) {\n  while (1) {}\n}\n",
        *["void guest(void) {\n  FUNC_PROLOGUE;\n  " + body + "\n  FUNC_EPILOGUE;\n}\n"
          for body in ("while (1) {}", "goto *target;", "goto var_missing;")],
    ):
        try:
            generator.instrument_loops(source)
        except (AssertionError, RuntimeError):
            pass
        else:
            raise AssertionError("Unreviewed control flow was admitted: " + source)
    with tempfile.TemporaryDirectory(prefix="notebook-supervisor-") as directory:
        work = Path(directory)
        (work / "probe.wat").write_text(WAT)
        run([wat2wasm, work / "probe.wat", "-o", work / "probe.wasm"])
        run([wasm2c, work / "probe.wasm", "--no-debug-names", "--num-outputs=2", "-n", "probe", "-o", work / "probe.c"])
        for path in [work / "probe-impl.h", *sorted(work.glob("probe_*.c"))]:
            source = path.read_text()
            if path.suffix == ".h":
                source, count = re.subn(r'#if WASM_RT_STACK_DEPTH_COUNT\n#define FUNC_PROLOGUE.*?\n#endif',
                    lambda _: generator.FUNCTION_PROLOGUE, source, count=1, flags=re.S)
                assert count == 1, "Missing pinned wasm2c function-entry boundary"
                assert not re.search(r'FUNC_PROLOGUE;|\bgoto\b', source)
            else:
                source, _ = generator.instrument_loops(source)
            path.write_text('#include "supervisor.h"\n' + source)
        (work / "harness.c").write_text(HARNESS)
        runtime = BUILD / "wabt/wasm2c"
        binary = work / "test-supervisor"
        run(["clang", "-std=c11", "-O2", "-fno-optimize-sibling-calls", "-frounding-math",
             "-DWASM_RT_MEMCHECK_BOUNDS_CHECK=1", "-DWASM_RT_USE_MMAP=0", "-DWASM_RT_MAX_CALL_STACK_DEPTH=64",
             "-I" + str(runtime), "-I" + str(RUNTIME / "native"), "-I" + str(work),
             *sorted(work.glob("probe_*.c")), work / "harness.c", runtime / "wasm-rt-impl.c",
             runtime / "wasm-rt-mem-impl.c", runtime / "wasm-rt-exceptions-impl.c", "-o", binary])
        # Missing a cycle gate must fail this check, not hang the build.
        subprocess.run([str(binary)], check=True, timeout=5)


if __name__ == "__main__":
    main()
