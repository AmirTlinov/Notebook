/* Run by rebuild-tectonic.py against the pinned, patched guest C owners.
 * The compile-only memcmp alias counts actual key comparisons, never guest code.
 */
#include "dpx-dpxutil.h"
#include "dpx-fontmap.h"
#include "dpx-dpxconf.h"
#include "dpx-fontmap.c"
#include <setjmp.h>

static uint64_t comparisons;
static int destroyed, expecting_overflow;
static jmp_buf overflow;
struct _dpx_conf dpx_conf;

int
fontmap_test_memcmp(const void *left, const void *right, size_t count)
{
    const unsigned char *a = left, *b = right;
    comparisons++;
    for (size_t i = 0; i < count; i++) {
        if (a[i] != b[i])
            return a[i] < b[i] ? -1 : 1;
    }
    return 0;
}

void *new(uint32_t size)
{
    void *result = malloc(size);
    assert(result);
    return result;
}

_Noreturn int _tt_abort(const char *format, ...)
{
    if (expecting_overflow)
        longjmp(overflow, 1);
    fputs(format, stderr);
    abort();
}

void dpx_warning(const char *format, ...) { fputs(format, stderr); abort(); }
void dpx_message(const char *format, ...) { (void) format; }

/* The real font-map owner expands and owns these aliases; only SFD file IO is
 * substituted, so the regression needs no distribution download or global cache. */
char **sfd_get_subfont_ids(const char *name, int *count)
{
    static char *ids[] = {"00", "01"};
    assert(!strcmp(name, "test"));
    *count = 2;
    return ids;
}
void release_sfd_record(void) {}

static int *value(int number)
{
    int *result = new(sizeof(*result));
    *result = number;
    return result;
}

static void release_value(void *pointer)
{
    destroyed++;
    free(pointer);
}

int main(void)
{
    struct ht_table duplicates;
    struct ht_iter iterator;
    const char binary_key[] = {'a', 0, (char) 0xff};
    ht_init_table(&duplicates, release_value);
    for (int i = 1; i <= 3; i++)
        ht_append_table(&duplicates, binary_key, sizeof(binary_key), value(i));
    void *first = ht_lookup_table(&duplicates, binary_key, sizeof(binary_key));
    ht_reserve_table(&duplicates, 4096);
    assert(ht_lookup_table(&duplicates, binary_key, sizeof(binary_key)) == first);
    assert(ht_set_iter(&duplicates, &iterator) == 0);
    int count = 0;
    do {
        assert(*(int *) ht_iter_getval(&iterator) == ++count);
    } while (ht_iter_next(&iterator) >= 0);
    ht_clear_iter(&iterator);
    assert(count == 3);
    ht_insert_table(&duplicates, binary_key, sizeof(binary_key), value(4));
    assert(destroyed == 1 && ht_table_size(&duplicates) == 3);
    assert(*(int *) ht_lookup_table(&duplicates, binary_key, sizeof(binary_key)) == 4);
    assert(ht_remove_table(&duplicates, binary_key, sizeof(binary_key)));
    assert(*(int *) ht_lookup_table(&duplicates, binary_key, sizeof(binary_key)) == 2);
    expecting_overflow = 1;
    if (!setjmp(overflow)) {
        ht_reserve_table(&duplicates, INT_MAX);
        abort();
    }
    expecting_overflow = 0;
    assert(ht_table_size(&duplicates) == 2);
    ht_clear_table(&duplicates);
    assert(destroyed == 4 && ht_table_size(&duplicates) == 0);
    assert(ht_set_iter(&duplicates, &iterator) == -1);
    ht_clear_table(&duplicates);
    ht_init_table(&duplicates, release_value);
    ht_clear_table(&duplicates);

    pdf_init_fontmaps();
    fontmap_rec record;
    pdf_init_fontmap_record(&record);
    record.map_name = "template";
    record.font_name = "first";
    comparisons = 0;
    fontmap_rec *retained = NULL;
    for (int i = 0; i < 100000; i++) {
        char key[32];
        snprintf(key, sizeof(key), "font-%08d", i);
        record.opt.index = i;
        assert(pdf_append_fontmap_record(key, &record) == 0);
        if (i == 0)
            retained = pdf_lookup_fontmap_record(key);
    }
    uint64_t insertion_comparisons = comparisons;
    assert(insertion_comparisons < 1000000);
    assert(pdf_lookup_fontmap_record("font-00000000") == retained);
    assert(ht_table_size(fontmap) == 100000);
    uint64_t sum = 0;
    count = 0;
    assert(ht_set_iter(fontmap, &iterator) == 0);
    do {
        fontmap_rec *item = ht_iter_getval(&iterator);
        sum += item->opt.index;
        count++;
    } while (ht_iter_next(&iterator) >= 0);
    ht_clear_iter(&iterator);
    assert(count == 100000 && sum == UINT64_C(4999950000));
    for (int i = 0; i < 100000; i++) {
        char key[32];
        snprintf(key, sizeof(key), "font-%08d", i);
        assert(pdf_lookup_fontmap_record(key)->opt.index == (uint32_t) i);
        if (i % 2 == 0) {
            assert(pdf_remove_fontmap_record(key) == 0);
            assert(!pdf_lookup_fontmap_record(key));
        }
    }
    retained = pdf_lookup_fontmap_record("font-00000001");
    record.font_name = "second";
    assert(pdf_append_fontmap_record("font-00000001", &record) == 0);
    assert(pdf_lookup_fontmap_record("font-00000001") == retained);
    assert(!strcmp(retained->font_name, "first"));
    assert(pdf_insert_fontmap_record("font-00000001", &record));
    assert(!strcmp(pdf_lookup_fontmap_record("font-00000001")->font_name, "second"));

    assert(pdf_append_fontmap_record("family@test@suffix", &record) == 0);
    fontmap_rec *alias = pdf_lookup_fontmap_record("family00suffix");
    assert(alias && !strcmp(alias->map_name, "family@test@suffix"));
    assert(!strcmp(alias->charmap.subfont_id, "00"));
    assert(pdf_append_fontmap_record("family@test@suffix", &record) == 0);
    assert(pdf_lookup_fontmap_record("family00suffix") == alias);
    assert(pdf_insert_fontmap_record("family@test@suffix", &record));
    assert(pdf_lookup_fontmap_record("family01suffix"));
    assert(pdf_remove_fontmap_record("family@test@suffix") == 0);
    assert(!pdf_lookup_fontmap_record("family00suffix"));
    assert(!pdf_lookup_fontmap_record("family01suffix"));
    assert(!pdf_lookup_fontmap_record("family@test@suffix"));
    pdf_close_fontmaps();
    pdf_close_fontmaps();
    pdf_init_fontmaps();
    assert(!pdf_lookup_fontmap_record("font-00000001"));
    pdf_close_fontmaps();
    printf("{\"case\":\"fontmap-100000\",\"passed\":true,\"insertionComparisons\":%" PRIu64 "}\n", insertion_comparisons);
    return 0;
}
