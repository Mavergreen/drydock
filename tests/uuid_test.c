/*
 * tests/uuid_test.c — hermetic tests for src/uuid.c: the UUID that
 * `uuid set stamped` gives an image, and how `info` recognizes one.
 *
 * Ground truth is computed independently of src/uuid.c (Python's hashlib over
 * the same input: the old UUID followed by "drydock-stamp", SHA-256, first 16
 * bytes, marker and version over bytes 0-3, RFC 4122 version 4 and variant
 * bits set), so a change to the derivation fails here rather than passing
 * against itself.
 */
#include "uuid.h"
#include <stdio.h>
#include <string.h>

static int fails = 0;
#define CHECK(cond, msg, ...) do { if (!(cond)) { \
    printf("FAIL: " msg "\n", ##__VA_ARGS__); fails++; } } while (0)

static const uint8_t old_uuid[16] = {
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
    0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f };
static const uint8_t stamped_0_5[16] = {
    0xdd, 0x0c, 0x00, 0x05, 0x0f, 0x08, 0x41, 0xf7,
    0x86, 0xbc, 0x46, 0x6e, 0xef, 0xdf, 0x3d, 0x0f };
static const uint8_t restamped_0_5[16] = {
    0xdd, 0x0c, 0x00, 0x05, 0xb6, 0xf3, 0x4b, 0x2d,
    0x91, 0x1b, 0xdd, 0xea, 0xe8, 0xbd, 0x24, 0x33 };

static void test_stamp_is_the_independent_derivation(void) {
    uint8_t out[16];
    muu_stamp(old_uuid, 0, 5, out);
    CHECK(memcmp(out, stamped_0_5, 16) == 0,
          "stamp: SHA-256 of the old UUID and \"drydock-stamp\", marker DD0C, version 0.5, v4 bits");
}

static void test_stamp_in_place(void) {
    uint8_t u[16];
    memcpy(u, old_uuid, 16);
    muu_stamp(u, 0, 5, u);
    CHECK(memcmp(u, stamped_0_5, 16) == 0, "stamp: `out` may be `old`");
}

static void test_restamp_is_a_new_uuid(void) {
    uint8_t out[16];
    muu_stamp(stamped_0_5, 0, 5, out);
    CHECK(memcmp(out, restamped_0_5, 16) == 0,
          "stamp: a stamped UUID stamps again to a different one, since a second run changed the contents too");
}

static void test_version_lands_in_bytes_2_and_3(void) {
    uint8_t out[16];
    muu_stamp(old_uuid, 1, 12, out);
    CHECK(out[0] == 0xdd && out[1] == 0x0c && out[2] == 1 && out[3] == 12,
          "stamp: version 1.12 is DD0C010C (got %02X%02X%02X%02X)", out[0], out[1], out[2], out[3]);
    CHECK(memcmp(out + 4, stamped_0_5 + 4, 12) == 0,
          "stamp: the version changes only bytes 2 and 3");
}

static void test_recognizes_a_stamp(void) {
    unsigned major = 99, minor = 99;
    CHECK(muu_stamped_by(stamped_0_5, &major, &minor) == 1 && major == 0 && minor == 5,
          "stamped_by: DD0C0005-... is drydock 0.5 (got %u.%u)", major, minor);
}

static void test_ignores_an_ordinary_uuid(void) {
    unsigned major = 99, minor = 99;
    CHECK(muu_stamped_by(old_uuid, &major, &minor) == 0, "stamped_by: an unstamped UUID is not a stamp");
    uint8_t marker_only[16];
    memcpy(marker_only, stamped_0_5, 16);
    marker_only[6] = 0x10;   /* version 1: a time-based UUID can start DD0C by chance */
    CHECK(muu_stamped_by(marker_only, &major, &minor) == 0,
          "stamped_by: the marker without version 4 and RFC 4122's variant is not a stamp");
}

static void test_formats_like_uuidgen(void) {
    char s[MUU_STRLEN];
    muu_format(stamped_0_5, s);
    CHECK(strcmp(s, "DD0C0005-0F08-41F7-86BC-466EEFDF3D0F") == 0, "format: got %s", s);
}

int main(void) {
    test_stamp_is_the_independent_derivation();
    test_stamp_in_place();
    test_restamp_is_a_new_uuid();
    test_version_lands_in_bytes_2_and_3();
    test_recognizes_a_stamp();
    test_ignores_an_ordinary_uuid();
    test_formats_like_uuidgen();
    printf("uuid_test: %d failure(s)\n", fails);
    return fails ? 1 : 0;
}
