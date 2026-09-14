#include "include/NotebookQuickJS.h"
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wshorten-64-to-32"
#include "quickjs.h"
#pragma clang diagnostic pop
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct NQPending {
  uint64_t id;
  JSValue resolve, reject;
  struct NQPending *next;
} NQPending;
struct NQRuntime {
  JSRuntime *rt;
  JSContext *ctx;
  JSValue result;
  NQHostCall host;
  void *opaque;
  NQPending *pending;
  size_t pending_count;
  size_t result_limit;
  uint64_t next_id;
  atomic_int cancelled;
  double cpu_limit, cpu_used, entered_at;
  char *error;
};
static double thread_time(void) {
  struct timespec value;
  clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value);
  return (double)value.tv_sec + (double)value.tv_nsec / 1e9;
}
static void enter(NQRuntime *n) {
  /* A serial DispatchQueue owns the interpreter, but may resume on another OS
     thread after awaiting the broker. The stack bound belongs to that thread. */
  JS_UpdateStackTop(n->rt);
  n->entered_at = thread_time();
}
static void leave(NQRuntime *n) { n->cpu_used += thread_time() - n->entered_at; n->entered_at = 0; }
static int interrupted(JSRuntime *rt, void *opaque) {
  (void)rt;
  NQRuntime *n = opaque;
  return atomic_load(&n->cancelled) || n->cpu_used + (n->entered_at ? thread_time()-n->entered_at : 0) >= n->cpu_limit;
}
static void save_exception(NQRuntime *n) {
  JSValue error = JS_GetException(n->ctx);
  const char *text = JS_ToCString(n->ctx,error);
  free(n->error); n->error = strdup(text ? text : "JavaScript execution failed");
  if (text) JS_FreeCString(n->ctx,text);
  JS_FreeValue(n->ctx,error);
}
static JSValue host_call(JSContext *ctx, JSValueConst self, int argc, JSValueConst *argv) {
  (void)self;
  NQRuntime *n = JS_GetContextOpaque(ctx);
  if (argc != 2 || n->pending_count >= 4 || atomic_load(&n->cancelled))
    return JS_ThrowInternalError(ctx,"sdk_concurrency_limit: at most four outstanding calls");
  const char *method = JS_ToCString(ctx,argv[0]);
  JSValue encoded = JS_JSONStringify(ctx,argv[1],JS_UNDEFINED,JS_UNDEFINED);
  if (!method || JS_IsException(encoded)) { if (method) JS_FreeCString(ctx,method); return JS_EXCEPTION; }
  size_t length;
  const char *json = JS_ToCStringLen(ctx,&length,encoded);
  if (!json || length > 32*1024*1024 || strlen(method) > 80) {
    if(json) JS_FreeCString(ctx,json); JS_FreeCString(ctx,method); JS_FreeValue(ctx,encoded);
    return JS_ThrowRangeError(ctx,"sdk_input_limit: request exceeds the native 32 MiB frame");
  }
  NQPending *entry = calloc(1,sizeof(*entry));
  if (!entry) { JS_FreeCString(ctx,json); JS_FreeCString(ctx,method); JS_FreeValue(ctx,encoded); return JS_ThrowOutOfMemory(ctx); }
  JSValue callbacks[2];
  JSValue promise = JS_NewPromiseCapability(ctx,callbacks);
  if (JS_IsException(promise)) { free(entry); JS_FreeCString(ctx,json); JS_FreeCString(ctx,method); JS_FreeValue(ctx,encoded); return promise; }
  entry->id = ++n->next_id; entry->resolve = callbacks[0]; entry->reject = callbacks[1];
  entry->next = n->pending; n->pending = entry; n->pending_count++;
  n->host(n->opaque,entry->id,method,json);
  JS_FreeCString(ctx,json); JS_FreeCString(ctx,method); JS_FreeValue(ctx,encoded);
  return promise;
}
NQRuntime *nq_create(size_t heap_bytes, size_t stack_bytes, double cpu_seconds, NQHostCall host, void *opaque) {
  NQRuntime *n = calloc(1,sizeof(*n)); if (!n) return NULL;
  n->rt=JS_NewRuntime(); if (!n->rt) { free(n); return NULL; }
  JS_SetMemoryLimit(n->rt,heap_bytes); JS_SetMaxStackSize(n->rt,stack_bytes);
  n->cpu_limit=cpu_seconds; n->host=host; n->opaque=opaque; n->result=JS_UNDEFINED; n->result_limit=1024*1024;
  atomic_init(&n->cancelled,0); JS_SetInterruptHandler(n->rt,interrupted,n);
  n->ctx=JS_NewContext(n->rt); if (!n->ctx) { JS_FreeRuntime(n->rt); free(n); return NULL; }
  JS_SetContextOpaque(n->ctx,n);
  JSValue global=JS_GetGlobalObject(n->ctx);
  JS_SetPropertyStr(n->ctx,global,"__nbHost",JS_NewCFunction(n->ctx,host_call,"__nbHost",2));
  JS_FreeValue(n->ctx,global);
  /* Atomics.wait is a blocking host wait, not notebook async work. */
  if (nq_bootstrap(n,"delete globalThis.SharedArrayBuffer; delete globalThis.Atomics;")<0) { nq_destroy(n); return NULL; }
  return n;
}
void nq_destroy(NQRuntime *n) {
  if (!n) return;
  NQPending *entry=n->pending;
  while(entry) { NQPending *next=entry->next; JS_FreeValue(n->ctx,entry->resolve); JS_FreeValue(n->ctx,entry->reject); free(entry); entry=next; }
  JS_FreeValue(n->ctx,n->result); JS_FreeContext(n->ctx); JS_FreeRuntime(n->rt); free(n->error); free(n);
}
void nq_cancel(NQRuntime *n) { if(n) atomic_store(&n->cancelled,1); }
void nq_set_result_limit(NQRuntime *n,size_t bytes) { n->result_limit=bytes; }
int nq_bootstrap(NQRuntime *n,const char *source) {
  enter(n); JSValue value=JS_Eval(n->ctx,source,strlen(source),"notebook-sdk.js",JS_EVAL_TYPE_GLOBAL);
  int failed=JS_IsException(value); if(failed) save_exception(n); JS_FreeValue(n->ctx,value); leave(n); return failed?-1:0;
}
int nq_start(NQRuntime *n,const char *source,const char *arguments_json) {
  enter(n);
  JSValue arguments=JS_ParseJSON(n->ctx,arguments_json,strlen(arguments_json),"arguments.json");
  if(JS_IsException(arguments)) { save_exception(n); leave(n); return -1; }
  JSValue global=JS_GetGlobalObject(n->ctx); JS_SetPropertyStr(n->ctx,global,"args",arguments); JS_FreeValue(n->ctx,global);
  const char *prefix="(async function(){'use strict';\n", *suffix="\n}).call(undefined)";
  size_t length=strlen(prefix)+strlen(source)+strlen(suffix);
  char *program=malloc(length+1); if(!program) { leave(n); return -1; }
  strcpy(program,prefix); strcat(program,source); strcat(program,suffix);
  n->result=JS_Eval(n->ctx,program,length,"notebook-user.js",JS_EVAL_TYPE_GLOBAL); free(program);
  int failed=JS_IsException(n->result); if(failed) { save_exception(n); n->result=JS_UNDEFINED; }
  leave(n); return failed?-1:0;
}
int nq_resolve(NQRuntime *n,uint64_t call_id,const char *json,int rejected) {
  NQPending **link=&n->pending;
  while(*link && (*link)->id!=call_id) link=&(*link)->next;
  if(!*link) return -1;
  NQPending *entry=*link; *link=entry->next; n->pending_count--;
  enter(n);
  JSValue value=JS_ParseJSON(n->ctx,json,strlen(json),"host-result.json");
  int failed=JS_IsException(value);
  if(!failed) { JSValue result=JS_Call(n->ctx,rejected?entry->reject:entry->resolve,JS_UNDEFINED,1,&value); failed=JS_IsException(result); JS_FreeValue(n->ctx,result); }
  if(failed) save_exception(n);
  JS_FreeValue(n->ctx,value); JS_FreeValue(n->ctx,entry->resolve); JS_FreeValue(n->ctx,entry->reject); free(entry); leave(n);
  return failed?-1:0;
}
int nq_pump(NQRuntime *n) {
  if(atomic_load(&n->cancelled)) { free(n->error); n->error=strdup("cancelled"); return -1; }
  if(n->error) return -1;
  enter(n);
  for(int i=0;i<256;i++) { JSContext *ctx=NULL; int result=JS_ExecutePendingJob(n->rt,&ctx); if(result<0) { save_exception(n); leave(n); return -1; } if(!result) break; }
  JSPromiseStateEnum state=JS_PromiseState(n->ctx,n->result);
  if(state==JS_PROMISE_REJECTED) {
    JSValue error=JS_PromiseResult(n->ctx,n->result);
    const char *text=JS_ToCString(n->ctx,error); free(n->error); n->error=strdup(text?text:"JavaScript rejected");
    if(text) JS_FreeCString(n->ctx,text); JS_FreeValue(n->ctx,error); leave(n); return -1;
  }
  leave(n); return state==JS_PROMISE_FULFILLED && n->pending_count==0 && !JS_IsJobPending(n->rt) ? 1:0;
}
char *nq_result(NQRuntime *n) {
  enter(n); JSValue value=JS_PromiseResult(n->ctx,n->result);
  if(JS_IsUndefined(value)) { JS_FreeValue(n->ctx,value); leave(n); return strdup("null"); }
  JSValue encoded=JS_JSONStringify(n->ctx,value,JS_UNDEFINED,JS_UNDEFINED);
  if(JS_IsException(encoded)) { save_exception(n); JS_FreeValue(n->ctx,value); leave(n); return NULL; }
  size_t length; const char *text=JS_ToCStringLen(n->ctx,&length,encoded);
  char *result=text && length<=n->result_limit?strdup(text):NULL;
  if(text) JS_FreeCString(n->ctx,text); JS_FreeValue(n->ctx,encoded); JS_FreeValue(n->ctx,value); leave(n); return result;
}
char *nq_error(NQRuntime *n) { return strdup(n->error?n->error:atomic_load(&n->cancelled)?"cancelled":"resource_limit"); }
void nq_free_string(char *value) { free(value); }
size_t nq_pending(NQRuntime *n) { return n->pending_count; }
