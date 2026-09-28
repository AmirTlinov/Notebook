#pragma once
#include "wasm-rt.h"
#include <stdint.h>

// One synchronous execution owns its imported memory, cancellation cadence and
// both stack limits. Guest code cannot address or replace this host instance.
struct w2c_wasi__snapshot__preview1 {
  void *context;
  wasm_rt_memory_t *memory;
  uintptr_t stack_floor;
  uint32_t poll_count;
  uint32_t call_stack_depth;
};
void nb_typesetter_poll(struct w2c_wasi__snapshot__preview1 *run);
#define NOTEBOOK_POLL(run) do { if (--(run)->poll_count == 0) nb_typesetter_poll(run); } while (0)
#define NOTEBOOK_ENTER(run) do { \
  if (++(run)->call_stack_depth > WASM_RT_MAX_CALL_STACK_DEPTH \
      || (uintptr_t)__builtin_frame_address(0) <= (run)->stack_floor) \
    wasm_rt_trap(WASM_RT_TRAP_EXHAUSTION); \
} while (0)
#define NOTEBOOK_LEAVE(run) (--(run)->call_stack_depth)
