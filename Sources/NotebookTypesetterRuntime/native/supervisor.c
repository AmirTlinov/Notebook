#include "engine.h"
#include "image.h"
#include "wasm-rt-impl.h"
#include "wasm-rt-exceptions.h"
#include <stdlib.h>
#include <pthread.h>
#include <string.h>
#include "supervisor.h"

struct w2c_env { wasm_rt_memory_t memory; };
struct w2c_wasi__snapshot__preview1 { void *context; wasm_rt_memory_t *memory; };
static _Thread_local void *current_context;
_Thread_local uintptr_t nb_typesetter_stack_floor;
_Thread_local uint32_t nb_typesetter_poll_count;
extern int nb_typesetter_should_stop(void *);
wasm_rt_memory_t* w2c_env_memory(struct w2c_env *env) { return &env->memory; }
void nb_typesetter_poll(void) {
  nb_typesetter_poll_count = 1024;
  if (nb_typesetter_should_stop(current_context)) wasm_rt_trap(WASM_RT_TRAP_UNREACHABLE);
}
// Memory is one zero-filled host mapping. Growth changes only its admitted
// extent, never calls realloc and never reserves more than the fixed capacity.
uint64_t wasm_rt_grow_memory(wasm_rt_memory_t *m, uint64_t pages) {
  if (pages > m->max_pages - m->pages) return UINT64_MAX;
  uint64_t old = m->pages;
  m->pages += pages; m->size = m->pages * m->page_size; m->data_end = m->data + m->size;
  return old;
}
int nb_engine_run(void *context, uint8_t *bytes, size_t capacity, size_t *used, int operation) {
  int format = operation == 1, image = operation == 2;
  if (capacity != (format ? 512u : 320u)*1024*1024 || current_context) return -1;
  uint32_t minimum = image ? wasm2c_notebook__image_min_env_memory : wasm2c_notebook_min_env_memory;
  struct w2c_env env = { .memory = { .data = bytes, .data_end = bytes+minimum*65536,
    .page_size = 65536, .pages = minimum, .max_pages = capacity/65536,
    .size = minimum*65536, .is64 = false } };
  struct w2c_wasi__snapshot__preview1 wasi = {context, &env.memory};
  void *instance = calloc(1, image ? sizeof(w2c_notebook__image) : sizeof(w2c_notebook));
  if (!instance) return -2;
  current_context = context; nb_typesetter_poll_count = 1024;
  nb_typesetter_stack_floor = (uintptr_t)pthread_get_stackaddr_np(pthread_self()) - pthread_get_stacksize_np(pthread_self()) + 128*1024;
  wasm_rt_init();
  int trap = wasm_rt_impl_try(), result;
  if (trap) result = -100 - trap;
  else {
    if (image) {
      wasm2c_notebook__image_instantiate(instance, &env, &wasi);
      result = w2c_notebook__image_notebook_image_compile(instance);
    } else {
    wasm2c_notebook_instantiate(instance, &env, &wasi);
    result = format ? w2c_notebook_tectonic_generate_format(instance) : w2c_notebook_tectonic_compile_defaults(instance);
    }
  }
  *used = env.memory.size;
  if (image) wasm2c_notebook__image_free(instance); else wasm2c_notebook_free(instance);
  free(instance);
  current_context = NULL;
  return result;
}
