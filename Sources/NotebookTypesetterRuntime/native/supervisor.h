#pragma once
#include <stdint.h>
void nb_typesetter_poll(void);
extern _Thread_local uint32_t nb_typesetter_poll_count;
#define NOTEBOOK_POLL() do { if (--nb_typesetter_poll_count == 0) nb_typesetter_poll(); } while (0)

extern _Thread_local uintptr_t nb_typesetter_stack_floor;
#define NOTEBOOK_STACK_CHECK() do { if ((uintptr_t)__builtin_frame_address(0) <= nb_typesetter_stack_floor) wasm_rt_trap(WASM_RT_TRAP_EXHAUSTION); } while (0)
