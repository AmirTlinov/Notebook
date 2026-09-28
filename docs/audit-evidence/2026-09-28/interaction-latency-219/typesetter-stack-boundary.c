// One boundary check against the generated production function macros.
// WASI cancellation itself is covered by the app's cancellation/recovery test.
#include "engine-impl.h"
#include "wasm-rt-impl.h"
#include "wasm-rt-exceptions.h"
#include <stdio.h>

static struct w2c_wasi__snapshot__preview1 execution;
static w2c_notebook module;
static volatile uint32_t deepest;
static uint32_t polls;

// This harness has no Rust/WASI state; keep the exact production poll cadence
// while testing the generated stack boundaries and the real C trap target.
void nb_typesetter_poll(struct w2c_wasi__snapshot__preview1 *run) {
  assert(run == &execution);
  run->poll_count = 1024;
  ++polls;
}

__attribute__((noinline))
static void nested_guest(w2c_notebook *instance, uint32_t remaining) {
  FUNC_PROLOGUE;
  if (execution.call_stack_depth > deepest) deepest = execution.call_stack_depth;
  if (remaining) nested_guest(instance, remaining - 1);
  FUNC_EPILOGUE;
}

static int invoke(uint32_t remaining, uintptr_t floor) {
  execution = (struct w2c_wasi__snapshot__preview1) {
    .stack_floor = floor, .poll_count = 1024, .call_stack_depth = 0,
  };
  module.w2c_wasi__snapshot__preview1_instance = &execution;
  deepest = 0; polls = 0;
  int trap = wasm_rt_impl_try();
  if (!trap) nested_guest(&module, remaining);
  return trap;
}

int main(void) {
  wasm_rt_init();
  assert(invoke(WASM_RT_MAX_CALL_STACK_DEPTH - 1, 0) == WASM_RT_TRAP_NONE);
  assert(deepest == WASM_RT_MAX_CALL_STACK_DEPTH && execution.call_stack_depth == 0);
  assert(polls == WASM_RT_MAX_CALL_STACK_DEPTH / 1024);
  assert(invoke(WASM_RT_MAX_CALL_STACK_DEPTH, 0) == WASM_RT_TRAP_EXHAUSTION);
  assert(deepest == WASM_RT_MAX_CALL_STACK_DEPTH);
  assert(invoke(0, UINTPTR_MAX) == WASM_RT_TRAP_EXHAUSTION);
  assert(deepest == 0);
  assert(invoke(WASM_RT_MAX_CALL_STACK_DEPTH - 1, 0) == WASM_RT_TRAP_NONE);
  assert(deepest == WASM_RT_MAX_CALL_STACK_DEPTH && execution.call_stack_depth == 0);
  wasm_rt_free();
  puts("PASS: depth limit, native floor, balanced exits, trap recovery");
}
