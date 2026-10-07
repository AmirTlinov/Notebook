#include <assert.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PRIuZ "zu"
_Noreturn static void _tt_abort(const char *format, ...) { (void)format; abort(); }
// Generated from the patched pinned owner by rebuild-tectonic.py.
#include "format-test-owner.h"

static uint64_t random_state = 1;
static uint64_t next(void) {
    random_state ^= random_state << 13;
    random_state ^= random_state >> 7;
    random_state ^= random_state << 17;
    return random_state;
}

int main(void) {
    _Static_assert(sizeof(memory_word) == 8, "Pinned format word size changed");
    _Static_assert(sizeof(b32x2) == 8, "Pinned hash entry size changed");
    const size_t sizes[] = {1, 2, 4, 8, 16};
    const size_t counts[] = {0, 1, 2, 3, 16, 17, 511, 4099};
    for (size_t si = 0; si < sizeof(sizes) / sizeof(*sizes); ++si)
        for (size_t ci = 0; ci < sizeof(counts) / sizeof(*counts); ++ci)
            for (size_t offset = 0; offset < 16; ++offset) {
                size_t size = sizes[si], count = counts[ci], len = count * size + 32;
                char *actual = malloc(len), *expected = malloc(len), *original = malloc(len);
                assert(actual && expected && original);
                for (size_t i = 0; i < len; ++i) actual[i] = (char)next();
                memcpy(original, actual, len);
                memcpy(expected, actual, len);
                for (size_t item = 0; item < count; ++item)
                    for (size_t byte = 0; byte < size; ++byte)
                        expected[offset + item * size + byte] = original[offset + item * size + size - 1 - byte];
                swap_items(actual + offset, count, size);
                assert(memcmp(actual, expected, len) == 0);
                swap_items(actual + offset, count, size);
                assert(memcmp(actual, original, len) == 0);
                free(actual); free(expected); free(original);
            }
    const size_t runs[] = {0, 1, 2, 3, 5, 65535, 65536, 65537, 1000003};
    for (size_t i = 0; i < sizeof(runs) / sizeof(*runs); ++i)
        for (size_t j = 0; j < 4; ++j) {
            size_t count = runs[i], bytes = (count + 2) * sizeof(memory_word);
            memory_word *actual = malloc(bytes);
            assert(actual);
            memset(actual, 0xA5, bytes);
            uint64_t bits = j == 0 ? 0 : (j == 1 ? UINT64_MAX : next());
            memory_word value;
            memcpy(&value, &bits, sizeof(value));
            repeat_memory_word(actual + 1, count, value);
            uint64_t canary;
            memcpy(&canary, actual, sizeof(canary));
            assert(canary == UINT64_C(0xA5A5A5A5A5A5A5A5));
            memcpy(&canary, actual + count + 1, sizeof(canary));
            assert(canary == UINT64_C(0xA5A5A5A5A5A5A5A5));
            for (size_t n = 0; n < count; ++n) assert(memcmp(actual + n + 1, &value, sizeof(value)) == 0);
            free(actual);
        }
    const int32_t end = EQTB_SIZE + 1;
    assert(literal_run_admitted(1, end - 1));
    assert(!literal_run_admitted(1, end));
    assert(!literal_run_admitted(1, 0));
    assert(!literal_run_admitted(end, 1));
    assert(!literal_run_admitted(end, INT_MAX));
    assert(!literal_run_admitted(1, INT_MAX));
    assert(repeat_run_admitted(1, end - 1));
    assert(repeat_run_admitted(end, 0));
    assert(!repeat_run_admitted(end, 1));
    assert(!repeat_run_admitted(end, INT_MAX));
    assert(!repeat_run_admitted(1, INT_MAX));
    assert(!repeat_run_admitted(1, -1));
    puts("PASS: pinned format word/byte equivalence, unaligned/tail/canary cases and overflow-safe run boundaries");
}
