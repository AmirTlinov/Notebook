#ifndef NOTEBOOK_QUICKJS_H
#define NOTEBOOK_QUICKJS_H
#include <stddef.h>
#include <stdint.h>

typedef struct NQRuntime NQRuntime;
typedef void (*NQHostCall)(void *opaque, uint64_t call_id, const char *method, const char *json);
NQRuntime *nq_create(size_t heap_bytes, size_t stack_bytes, double cpu_seconds, NQHostCall host, void *opaque);
void nq_destroy(NQRuntime *runtime);
void nq_cancel(NQRuntime *runtime);
void nq_set_result_limit(NQRuntime *runtime, size_t bytes);
int nq_bootstrap(NQRuntime *runtime, const char *source);
int nq_start(NQRuntime *runtime, const char *source, const char *arguments_json);
int nq_resolve(NQRuntime *runtime, uint64_t call_id, const char *json, int rejected);
/* 0 pending, 1 fulfilled and all host effects drained, -1 failed. */
int nq_pump(NQRuntime *runtime);
char *nq_result(NQRuntime *runtime);
char *nq_error(NQRuntime *runtime);
void nq_free_string(char *value);
size_t nq_pending(NQRuntime *runtime);
#endif
