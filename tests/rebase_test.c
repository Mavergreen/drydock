/* tests/rebase_test.c -- hermetic tests for src/rebase.c, against rebase
 * streams assembled here byte by byte. */
#include "rebase.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails = 0;
#define CHECK(cond, msg, ...) do { if (!(cond)) { \
    printf("FAIL: " msg "\n", ##__VA_ARGS__); fails++; } } while (0)

static void test_every_opcode_decodes(void) {
    static const uint8_t s[] = {
        0x11,             /* SET_TYPE_IMM pointer */
        0x22, 0x10,       /* SET_SEGMENT_AND_OFFSET_ULEB seg 2, 0x10 */
        0x52,             /* DO_REBASE_IMM_TIMES 2: 0x10, 0x18 */
        0x30, 0x08,       /* ADD_ADDR_ULEB 8: 0x28 */
        0x42,             /* ADD_ADDR_IMM_SCALED 2: 0x38 */
        0x60, 0x03,       /* DO_REBASE_ULEB_TIMES 3: 0x38, 0x40, 0x48 */
        0x70, 0x10,       /* DO_REBASE_ADD_ADDR_ULEB 16: 0x50, then 0x68 */
        0x80, 0x02, 0x08, /* DO_REBASE_ULEB_TIMES_SKIPPING_ULEB 2, 8: 0x68, 0x78 */
        0x12,             /* SET_TYPE_IMM text absolute32 */
        0x21, 0x00,       /* seg 1, 0 */
        0x51,             /* DO_REBASE_IMM_TIMES 1: 0 */
        0x00,             /* DONE, at byte 18 */
        0xAA,             /* past DONE: never read */
    };
    static const mrb_slot want[] = {
        { 0x10, 2, 1 }, { 0x18, 2, 1 }, { 0x38, 2, 1 }, { 0x40, 2, 1 }, { 0x48, 2, 1 },
        { 0x50, 2, 1 }, { 0x68, 2, 1 }, { 0x78, 2, 1 }, { 0x00, 1, 2 },
    };
    mrb_set set;
    char why[160] = "";
    int rc = mrb_decode(s, sizeof s, 4, &set, why, sizeof why);
    CHECK(rc == MRB_OK, "every opcode: rc %d (%s)", rc, why);
    CHECK(set.n == sizeof want / sizeof want[0], "every opcode: %zu slots, want %zu",
          set.n, sizeof want / sizeof want[0]);
    for (size_t i = 0; i < set.n && i < sizeof want / sizeof want[0]; i++)
        CHECK(set.v[i].seg == want[i].seg && set.v[i].off == want[i].off &&
              set.v[i].type == want[i].type,
              "every opcode: slot %zu is (%u, %#llx, type %u), want (%u, %#llx, type %u)", i,
              set.v[i].seg, (unsigned long long)set.v[i].off, set.v[i].type,
              want[i].seg, (unsigned long long)want[i].off, want[i].type);
    CHECK(set.end == 18, "every opcode: DONE found at %zu, want 18", set.end);
    mrb_free(&set);
}

static void test_a_stream_without_done_ends_at_its_size(void) {
    static const uint8_t s[] = { 0x11, 0x22, 0x00, 0x51 };
    mrb_set set;
    int rc = mrb_decode(s, sizeof s, 4, &set, NULL, 0);
    CHECK(rc == MRB_OK && set.n == 1 && set.end == sizeof s,
          "no DONE: rc %d, %zu slots, end %zu", rc, set.n, set.end);
    mrb_free(&set);
}

static void refused(const uint8_t *s, size_t n, const char *want, const char *label) {
    mrb_set set;
    char why[160] = "";
    int rc = mrb_decode(s, n, 4, &set, why, sizeof why);
    CHECK(rc == MRB_MALFORMED, "%s: rc %d, want MRB_MALFORMED", label, rc);
    CHECK(strstr(why, want) != NULL, "%s: why '%s' lacks '%s'", label, why, want);
    CHECK(set.v == NULL && set.n == 0, "%s: a refusal left slots behind", label);
}

static void test_malformed_streams_are_refused(void) {
    static const uint8_t unknown[] = { 0x11, 0x22, 0x00, 0x90 };
    static const uint8_t noseg[]   = { 0x11, 0x51 };
    static const uint8_t bigseg[]  = { 0x11, 0x24, 0x00, 0x51 };
    static const uint8_t runsoff[] = { 0x11, 0x22, 0x80 };
    static const uint8_t huge[]    = { 0x11, 0x22, 0x00, 0x60, 0x80, 0x80, 0x80, 0x10 };
    static const uint8_t partial[] = { 0x11, 0x22, 0x00, 0x51, 0x90 };
    static const uint8_t past64[]  = { 0x11, 0x22, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80,
                                       0x80, 0x80, 0x02, 0x51 };
    refused(unknown, sizeof unknown, "unknown rebase opcode 0x90", "unknown opcode");
    refused(noseg, sizeof noseg, "before any segment", "a rebase before any segment");
    refused(bigseg, sizeof bigseg, "names segment 4", "a segment the image lacks");
    refused(runsoff, sizeof runsoff, "runs off", "a ULEB off the end");
    refused(huge, sizeof huge, "past 16777216 slots", "a count past the cap");
    refused(partial, sizeof partial, "unknown rebase opcode", "slots decoded before a refusal");
    refused(past64, sizeof past64, "past 64 bits", "a ULEB whose value passes 64 bits");
}

static void test_rebase_type_is_restricted(void) {
    static const uint8_t no_type[] = { 0x22, 0x10, 0x51 };
    refused(no_type, sizeof no_type, "type 0", "a rebase before any SET_TYPE_IMM");
    for (unsigned t = 3; t <= 15; t++) {
        uint8_t s[4];
        char want[16];
        s[0] = (uint8_t)(0x10 | t);
        s[1] = 0x22; s[2] = 0x10; s[3] = 0x51;
        snprintf(want, sizeof want, "type %u", t);
        refused(s, sizeof s, want, "a disallowed rebase type");
    }
}

static void test_slot_cap_boundary_is_exact(void) {
    static const uint8_t at_cap[]   = { 0x11, 0x22, 0x00, 0x60, 0x80, 0x80, 0x80, 0x08 };
    static const uint8_t over_cap[] = { 0x11, 0x22, 0x00, 0x60, 0x81, 0x80, 0x80, 0x08 };
    mrb_set set;
    int rc = mrb_decode(at_cap, sizeof at_cap, 4, &set, NULL, 0);
    CHECK(rc == MRB_OK && set.n == MRB_MAX_SLOTS,
          "slot cap: exactly the cap: rc %d, %zu slots, want %u", rc, set.n, MRB_MAX_SLOTS);
    mrb_free(&set);
    refused(over_cap, sizeof over_cap, "past 16777216 slots", "one slot past the cap");
}

static void test_sort_counts_repeats_and_has_finds(void) {
    static const uint8_t s[] = { 0x11, 0x23, 0x08, 0x51, 0x22, 0x10, 0x52, 0x22, 0x18, 0x51 };
    mrb_set set;
    int rc = mrb_decode(s, sizeof s, 4, &set, NULL, 0);
    CHECK(rc == MRB_OK && set.n == 4, "sort: rc %d, %zu slots", rc, set.n);
    CHECK(mrb_sort(&set) == 1, "sort: (2, 0x18) twice is one repeat");
    CHECK(set.n == 4 && set.v[0].seg == 2 && set.v[0].off == 0x10 && set.v[3].seg == 3,
          "sort: not ordered by segment, then offset");
    CHECK(mrb_has(&set, 2, 0x18) && mrb_has(&set, 3, 0x08), "has: misses a slot it holds");
    CHECK(!mrb_has(&set, 2, 0x08) && !mrb_has(&set, 3, 0x10), "has: finds a slot it lacks");
    mrb_free(&set);
}

/* 1 is REBASE_TYPE_POINTER, 2 is REBASE_TYPE_TEXT_ABSOLUTE32; this file
 * assembles rebase state byte by byte, without mach-o/loader.h. */
static void test_has_type_finds_the_right_type_in_an_equal_range(void) {
    mrb_set set;
    memset(&set, 0, sizeof set);
    CHECK(mrb_add(&set, 2, 1, 0x10) == 0, "has_type: add failed");
    CHECK(mrb_add(&set, 2, 2, 0x10) == 0, "has_type: add failed");
    CHECK(mrb_add(&set, 3, 1, 0x10) == 0, "has_type: add failed");
    mrb_sort(&set);
    CHECK(mrb_has_type(&set, 2, 0x10, 1), "has_type: misses the pointer rebase in an equal range");
    CHECK(mrb_has_type(&set, 2, 0x10, 2), "has_type: misses the abs32 rebase in the same equal range");
    CHECK(!mrb_has_type(&set, 2, 0x10, 3), "has_type: finds a type that is not there");
    CHECK(mrb_has_type(&set, 3, 0x10, 1), "has_type: misses a single-type slot");
    CHECK(!mrb_has_type(&set, 3, 0x10, 2), "has_type: finds a type absent from a single-type slot");
    CHECK(!mrb_has_type(&set, 2, 0x18, 1), "has_type: finds an offset that is not there");
    mrb_free(&set);
}

static void test_encode_pins_its_opcodes(void) {
    mrb_slot two[] = { { 0x10, 2, 1 }, { 0x18, 2, 1 } };
    mrb_slot fifteen[15], sixteen[16];
    static const uint8_t want2[]  = { 0x11, 0x22, 0x10, 0x52 };
    static const uint8_t want15[] = { 0x11, 0x22, 0x00, 0x5f };
    static const uint8_t want16[] = { 0x11, 0x22, 0x00, 0x60, 0x10 };
    mrb_buf b;
    for (int i = 0; i < 16; i++) {
        sixteen[i].seg = 2; sixteen[i].type = 1; sixteen[i].off = 8 * (uint64_t)i;
        if (i < 15) fifteen[i] = sixteen[i];
    }
    memset(&b, 0, sizeof b);
    CHECK(mrb_encode(two, 2, &b) == MRB_OK && b.n == sizeof want2 &&
          memcmp(b.p, want2, sizeof want2) == 0, "encode: two consecutive slots");
    free(b.p);
    memset(&b, 0, sizeof b);
    CHECK(mrb_encode(fifteen, 15, &b) == MRB_OK && b.n == sizeof want15 &&
          memcmp(b.p, want15, sizeof want15) == 0, "encode: fifteen fit the immediate");
    free(b.p);
    memset(&b, 0, sizeof b);
    CHECK(mrb_encode(sixteen, 16, &b) == MRB_OK && b.n == sizeof want16 &&
          memcmp(b.p, want16, sizeof want16) == 0, "encode: sixteen take a ULEB count");
    free(b.p);
}

static void test_encode_round_trips(void) {
    mrb_slot v[40];
    size_t n = 0;
    mrb_buf b;
    mrb_set back;
    uint8_t done = 0;
    for (int i = 0; i < 3; i++) { v[n].seg = 1; v[n].type = 1; v[n].off = 0x40 + 8 * (uint64_t)i; n++; }
    v[n].seg = 2; v[n].type = 1; v[n].off = 0x100; n++;
    for (int i = 0; i < 20; i++) { v[n].seg = 2; v[n].type = 1; v[n].off = 0x1000 + 8 * (uint64_t)i; n++; }
    v[n].seg = 2; v[n].type = 1; v[n].off = 0x20000; n++;
    v[n].seg = 15; v[n].type = 1; v[n].off = 0x8; n++;
    memset(&b, 0, sizeof b);
    CHECK(mrb_encode(v, n, &b) == MRB_OK, "round trip: encode");
    mrb_put(&b, &done, 1);
    int rc = mrb_decode(b.p, b.n, 16, &back, NULL, 0);
    CHECK(rc == MRB_OK && back.n == n, "round trip: rc %d, %zu slots back, want %zu", rc, back.n, n);
    for (size_t i = 0; i < n && i < back.n; i++)
        CHECK(back.v[i].seg == v[i].seg && back.v[i].off == v[i].off && back.v[i].type == 1,
              "round trip: slot %zu came back as (%u, %#llx)", i, back.v[i].seg,
              (unsigned long long)back.v[i].off);
    CHECK(back.end == b.n - 1, "round trip: DONE at %zu, want %zu", back.end, b.n - 1);
    mrb_free(&back);
    free(b.p);
}

static void test_encode_refuses_what_it_cannot_say(void) {
    mrb_slot unsorted[] = { { 0x18, 2, 1 }, { 0x10, 2, 1 } };
    mrb_slot twice[]    = { { 0x10, 2, 1 }, { 0x10, 2, 1 } };
    mrb_slot seg16[]    = { { 0x10, 16, 1 } };
    mrb_slot nonpointer[] = { { 0x10, 2, 2 } };
    mrb_buf b;
    memset(&b, 0, sizeof b);
    CHECK(mrb_encode(unsorted, 2, &b) == MRB_MALFORMED, "encode: unsorted slots accepted");
    CHECK(mrb_encode(twice, 2, &b) == MRB_MALFORMED, "encode: a repeated slot accepted");
    CHECK(mrb_encode(seg16, 1, &b) == MRB_MALFORMED, "encode: segment 16 accepted");
    CHECK(mrb_encode(nonpointer, 1, &b) == MRB_MALFORMED, "encode: a non-pointer type accepted");
    CHECK(b.n == 0, "encode: a refusal wrote %zu bytes", b.n);
    free(b.p);
}

int main(void) {
    test_every_opcode_decodes();
    test_a_stream_without_done_ends_at_its_size();
    test_malformed_streams_are_refused();
    test_rebase_type_is_restricted();
    test_slot_cap_boundary_is_exact();
    test_sort_counts_repeats_and_has_finds();
    test_has_type_finds_the_right_type_in_an_equal_range();
    test_encode_pins_its_opcodes();
    test_encode_round_trips();
    test_encode_refuses_what_it_cannot_say();
    if (fails) {
        printf("%d failure(s)\n", fails);
        return 1;
    }
    printf("rebase_test: 0 failure(s)\n");
    return 0;
}
