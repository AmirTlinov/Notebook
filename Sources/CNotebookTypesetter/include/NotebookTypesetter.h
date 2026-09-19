#ifndef NOTEBOOK_TYPESETTER_H
#define NOTEBOOK_TYPESETTER_H
#include <stdint.h>
#include <stddef.h>
typedef struct NBTypesetter NBTypesetter;
typedef struct NBTypesetterCancel NBTypesetterCancel;
typedef struct NBTypesetterOutput NBTypesetterOutput;
typedef struct { const char *name; const uint8_t *bytes; size_t count; } NBTypesetterAsset;
NBTypesetter *nb_typesetter_create(const char *bundle, const char *format, const char *fonts);
void nb_typesetter_destroy(NBTypesetter *);
NBTypesetterCancel *nb_typesetter_cancel_create(void);
void nb_typesetter_cancel(NBTypesetterCancel *);
void nb_typesetter_cancel_destroy(NBTypesetterCancel *);
NBTypesetterOutput *nb_typesetter_compile(const NBTypesetter *, const uint8_t *source, size_t count,
 const NBTypesetterAsset *assets, size_t asset_count, uint64_t epoch, uint64_t timeout_ms, const NBTypesetterCancel *);
NBTypesetterOutput *nb_typesetter_svg(const NBTypesetter *, const uint8_t *, size_t, uint64_t, const NBTypesetterCancel *);
// Bytes are borrowed until output_destroy: 0 PDF, 1 SyncTeX, 2 log, 3 error.
const uint8_t *nb_typesetter_output_bytes(const NBTypesetterOutput *, uint32_t kind, size_t *count);
size_t nb_typesetter_output_memory(const NBTypesetterOutput *);
void nb_typesetter_output_destroy(NBTypesetterOutput *);
int nb_typesetter_inflate(const uint8_t *, size_t, uint8_t *, size_t *);
#endif
