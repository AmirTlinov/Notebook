#include "NotebookTypesetter.h"
#include <zlib.h>
#include <stdlib.h>
int nb_typesetter_inflate(const uint8_t *input, size_t count, uint8_t *output, size_t *capacity) {
  if (count > 4*1024*1024 || *capacity > 16*1024*1024) return -1;
  z_stream stream = {0};
  stream.next_in = (Bytef *)input; stream.avail_in = (uInt)count;
  stream.next_out = output; stream.avail_out = (uInt)*capacity;
  if (inflateInit2(&stream, 15+32) != Z_OK) return -1;
  int code = inflate(&stream, Z_FINISH);
  *capacity = stream.total_out;
  int valid = code == Z_STREAM_END && stream.avail_in == 0;
  inflateEnd(&stream); return valid ? 0 : -1;
}
