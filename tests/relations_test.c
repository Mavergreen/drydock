/*
 * tests/relations_test.c — hermetic tests for src/relations.c.
 *
 * Images are built by hand with mi_wrap (same reasoning as linkedit_test), so
 * this is host-agnostic. What is under test is mrel_live: which relations a
 * given image actually has, which is the applicability half of the design.
 *
 * Build: clang -O2 -Wall -Isrc -o /tmp/reltest tests/relations_test.c \
 *   src/relations.c src/image.c src/ordinals.c && /tmp/reltest
 */
#include "relations.h"
#include "../src/image.h"

#include <mach-o/loader.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static int fails = 0;
#define CHECK(cond, msg, ...) do { if (!(cond)) { \
    printf("FAIL: " msg "\n", ##__VA_ARGS__); fails++; } } while (0)

#define REL_BUF_SIZE 4096

/* Appends one load command's worth of zeroed bytes and returns a pointer to
 * it; advances *lcp and bumps hdr->ncmds/sizeofcmds. Same idiom as
 * tests/linkedit_test.c's append_lc. `size` must already be a multiple of 8. */
static void *append_lc(struct mach_header_64 *hdr, uint8_t **lcp, uint32_t cmd, uint32_t size) {
    struct load_command *lc = (struct load_command *)*lcp;
    lc->cmd = cmd;
    lc->cmdsize = size;
    hdr->ncmds++;
    hdr->sizeofcmds += size;
    *lcp += size;
    return lc;
}

/* A bare 64-bit Mach-O header with zero load commands: the smallest thing
 * mi_wrap will validate. Every relations test builds on this. */
static void build_minimal_image(uint8_t *buf, size_t size, mi_image *im) {
    memset(buf, 0, size);
    struct mach_header_64 *hdr = (struct mach_header_64 *)buf;
    hdr->magic = MH_MAGIC_64;
    hdr->filetype = MH_EXECUTE;
    int wr = mi_wrap(buf, size, im);
    CHECK(wr == 0, "build_minimal_image: a bare header validates via mi_wrap (got %d)", wr);
}

/* Appends an LC_FUNCTION_STARTS with the given datasize and re-wraps `im`
 * over the mutated buffer -- mi_wrap must be re-run after any change to
 * ncmds/sizeofcmds, since it is what mi_each_lc's bounds checking trusts. */
static void add_function_starts(uint8_t *buf, mi_image *im, uint32_t datasize) {
    struct mach_header_64 *hdr = (struct mach_header_64 *)buf;
    uint8_t *lcp = buf + sizeof(*hdr) + hdr->sizeofcmds;
    struct linkedit_data_command *d = (struct linkedit_data_command *)
        append_lc(hdr, &lcp, LC_FUNCTION_STARTS, sizeof(struct linkedit_data_command));
    d->dataoff = 0x1000;
    d->datasize = datasize;
    int wr = mi_wrap(buf, REL_BUF_SIZE, im);
    CHECK(wr == 0, "add_function_starts: image still validates after appending (got %d)", wr);
}

/* Appends an LC_LOAD_DYLIB naming `path`, padded to an 8-byte cmdsize the
 * way a real linker would, and re-wraps `im`. */
static void add_load_dylib(uint8_t *buf, mi_image *im, const char *path) {
    struct mach_header_64 *hdr = (struct mach_header_64 *)buf;
    uint8_t *lcp = buf + sizeof(*hdr) + hdr->sizeofcmds;
    size_t namelen = strlen(path) + 1;
    uint32_t hdrsize = (uint32_t)sizeof(struct dylib_command);
    uint32_t cmdsize = (uint32_t)((hdrsize + namelen + 7) & ~(size_t)7);
    struct dylib_command *d = (struct dylib_command *)
        append_lc(hdr, &lcp, LC_LOAD_DYLIB, cmdsize);
    d->dylib.name.offset = hdrsize;
    d->dylib.timestamp = 0;
    d->dylib.current_version = 0;
    d->dylib.compatibility_version = 0;
    memcpy((uint8_t *)d + hdrsize, path, namelen);
    int wr = mi_wrap(buf, REL_BUF_SIZE, im);
    CHECK(wr == 0, "add_load_dylib: image still validates after appending (got %d)", wr);
}

static void test_header_pad_is_always_live(void) {
    /* Every Mach-O has a sizeofcmds and a first section, so the header-pad
     * relation is live in every image. If this ever returns 0 the derivation
     * silently stops guarding growth. */
    uint8_t buf[REL_BUF_SIZE]; mi_image im;
    build_minimal_image(buf, sizeof buf, &im);
    CHECK((mrel_live(&im) & MREL_HEADER_PAD) != 0, "header pad is live in a minimal image");
}

static void test_func_start_liveness_follows_the_load_command(void) {
    uint8_t buf[REL_BUF_SIZE]; mi_image im;
    build_minimal_image(buf, sizeof buf, &im);
    CHECK((mrel_live(&im) & MREL_FUNC_START) == 0,
          "no LC_FUNCTION_STARTS -> the func-start relation is NOT live");
    add_function_starts(buf, &im, 0x10);
    CHECK((mrel_live(&im) & MREL_FUNC_START) != 0,
          "with LC_FUNCTION_STARTS -> it IS live");
}

static void test_ordinal_liveness_follows_ordinal_carrying_commands(void) {
    uint8_t buf[REL_BUF_SIZE]; mi_image im;
    build_minimal_image(buf, sizeof buf, &im);
    CHECK((mrel_live(&im) & MREL_ORDINAL) == 0,
          "no dylib commands -> the ordinal relation is NOT live");
    add_load_dylib(buf, &im, "/usr/lib/libSystem.B.dylib");
    CHECK((mrel_live(&im) & MREL_ORDINAL) != 0,
          "one LC_LOAD_DYLIB -> it IS live");
}

static void test_names_round_trip(void) {
    CHECK(strcmp(mrel_name(MREL_ORDINAL), "library ordinal") == 0, "ordinal name");
    CHECK(mrel_name(1u << 20) == NULL, "an unknown bit has no name");
}

static void test_verify_applies_needs_a_live_relation_AND_a_disturbance(void) {
    /* Both operands, separately. A run that disturbed nothing has nothing to
     * re-check however live the relation is; a disturbance of the image base
     * has nothing to check in an image that declares no function starts. The
     * two are pinned apart because collapsing them into one bit is the bug
     * that would make this gate never fire. */
    uint8_t buf[REL_BUF_SIZE]; mi_image im;
    build_minimal_image(buf, sizeof buf, &im);
    add_function_starts(buf, &im, 0x10);
    CHECK(mrel_verify_applies(&im, MREL_BASE_REL) != 0,
          "live func-starts + a disturbed image base -> the gate applies");
    CHECK(mrel_verify_applies(&im, 0) == 0,
          "live func-starts + nothing disturbed -> nothing to check");
    CHECK(mrel_verify_applies(&im, MREL_HEADER_PAD) == 0,
          "a disturbed header pad alone moves no base-relative value");
    CHECK(mrel_verify_applies(&im, MREL_ORDINAL | MREL_HEADER_PAD) == 0,
          "ordinals and pad together still move no base-relative value");
    CHECK(mrel_verify_applies(&im, MREL_FILE_OFF | MREL_BASE_REL | MREL_HEADER_PAD) != 0,
          "fixups set classic's own mask -> the gate applies");

    build_minimal_image(buf, sizeof buf, &im);   /* no LC_FUNCTION_STARTS */
    CHECK(mrel_verify_applies(&im, MREL_BASE_REL) == 0,
          "no LC_FUNCTION_STARTS -> nothing to check even after a re-base");
}

int main(void) {
    test_header_pad_is_always_live();
    test_func_start_liveness_follows_the_load_command();
    test_ordinal_liveness_follows_ordinal_carrying_commands();
    test_names_round_trip();
    test_verify_applies_needs_a_live_relation_AND_a_disturbance();

    if (fails) {
        printf("%d failure(s)\n", fails);
        return 1;
    }
    printf("relations_test: 0 failure(s)\n");
    return 0;
}
