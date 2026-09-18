#include <stdint.h>
char *notebook_typeset_compile(const char *bundle, const char *cache, const char *source, const char *output, uint64_t timeout_ms);
void notebook_typeset_free(char *message);
