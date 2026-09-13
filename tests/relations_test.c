/*
 * tests/relations_test.c — hermetic tests for src/relations.c.
 *
 * Images are built by hand with mi_wrap (same reasoning as linkedit_test), so
 * this is host-agnostic. What is under test is mrel_live: which relations a
 * given image actually has, which is the applicability half of the design.
 *
 * What these tests do NOT reach, and why:
 *   - MREL_FILE_OFF is exercised through exactly one member of
 *     linkedit.h's ML_PLAIN_OFFSET_LCS (LC_SYMTAB), not all seven. The
 *     macro's own compile-time coupling (see linkedit.h's top comment) is
 *     what keeps src/grow.c's accept bucket, src/linkedit.c's bump switch,
 *     and this file's derivation naming the SAME set of commands; a member
 *     silently dropped from the macro would still change grow.c's and
 *     linkedit.c's own behaviour, each caught by grow_test.c/linkedit_test.c,
 *     even though this file would not itself notice. One member is enough to
 *     confirm this file's switch reaches the shared macro at all -- which is
 *     the only thing that could vary independently of those other two tests.
 *   - mi_image_base's own segment-selection contract (skipping __PAGEZERO,
 *     preferring the first fileoff-0-with-content segment when several
 *     exist) is NOT re-derived here -- that is mi_image_base's own contract,
 *     already pinned by tests/image_test.c's
 *     test_image_base_separates_not_found_from_a_base_of_zero (which mutates
 *     a real fixture's __TEXT vmaddr to 0 and asserts mi_image_base and
 *     mi_text_base diverge exactly there). This file only needs to prove
 *     that mrel_live consumes mi_image_base's RETURN CODE, not its value --
 *     see test_base_rel_liveness_follows_a_segment_mapping_the_header below.
 *   - Fat containers are out of scope for this file by construction: mrel_live
 *     takes a already-sliced mi_image (see relations.h's own comment on
 *     mrel_live), so there is no fat-specific case for a hand-built THIN
 *     image to exercise.
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

/* Appends an LC_SEGMENT_64 that maps the header -- fileoff 0, filesize > 0,
 * the exact test mi_image_base itself applies (src/image.c:177) -- at
 * vmaddr 0: a dylib-style segment. This is the ONE image in this file where
 * mi_image_base and mi_text_base give different answers for the same bytes:
 * mi_image_base reports "found" (returns 0, *out = 0), while mi_text_base
 * folds that into the identical 0 it returns for "no such segment" -- the
 * exact confusion that once made mg_plausible refuse every dylib on the
 * machine (see src/image.h's own comment on mi_text_base). A segment with a
 * NONZERO vmaddr would not distinguish the two: both functions would then
 * agree the base is that nonzero value, which is why this helper pins
 * vmaddr at 0 rather than any other value. */
static void add_zero_base_segment(uint8_t *buf, mi_image *im) {
    struct mach_header_64 *hdr = (struct mach_header_64 *)buf;
    uint8_t *lcp = buf + sizeof(*hdr) + hdr->sizeofcmds;
    struct segment_command_64 *sg = (struct segment_command_64 *)
        append_lc(hdr, &lcp, LC_SEGMENT_64, sizeof(struct segment_command_64));
    memcpy(sg->segname, "__TEXT", 6);
    sg->vmaddr = 0;
    sg->vmsize = 0x1000;
    sg->fileoff = 0;
    sg->filesize = 0x1000;
    sg->maxprot = 7;
    sg->initprot = 5;
    sg->nsects = 0;
    sg->flags = 0;
    int wr = mi_wrap(buf, REL_BUF_SIZE, im);
    CHECK(wr == 0, "add_zero_base_segment: image still validates after appending (got %d)", wr);
}

/* Appends an LC_SYMTAB -- one member of linkedit.h's ML_PLAIN_OFFSET_LCS,
 * representative of the whole group (see this file's top comment for why
 * one member is enough here). */
static void add_symtab(uint8_t *buf, mi_image *im) {
    struct mach_header_64 *hdr = (struct mach_header_64 *)buf;
    uint8_t *lcp = buf + sizeof(*hdr) + hdr->sizeofcmds;
    struct symtab_command *s = (struct symtab_command *)
        append_lc(hdr, &lcp, LC_SYMTAB, sizeof(struct symtab_command));
    s->symoff = 0x1000;
    s->nsyms = 0;
    s->stroff = 0x2000;
    s->strsize = 0;
    int wr = mi_wrap(buf, REL_BUF_SIZE, im);
    CHECK(wr == 0, "add_symtab: image still validates after appending (got %d)", wr);
}

/* Appends an LC_UUID -- a load command with no __LINKEDIT file-offset
 * footprint at all, and deliberately NOT a member of ML_PLAIN_OFFSET_LCS.
 * Used to pin that MREL_FILE_OFF's condition is not over-broad: a mutation
 * that widened it (e.g. a `default` case that also sets the bit) would show
 * up as this command wrongly turning the relation on. */
static void add_uuid(uint8_t *buf, mi_image *im) {
    struct mach_header_64 *hdr = (struct mach_header_64 *)buf;
    uint8_t *lcp = buf + sizeof(*hdr) + hdr->sizeofcmds;
    struct uuid_command *u = (struct uuid_command *)
        append_lc(hdr, &lcp, LC_UUID, sizeof(struct uuid_command));
    memset(u->uuid, 0xAB, sizeof u->uuid);
    int wr = mi_wrap(buf, REL_BUF_SIZE, im);
    CHECK(wr == 0, "add_uuid: image still validates after appending (got %d)", wr);
}

static void test_header_pad_is_always_live(void) {
    /* Every Mach-O has a sizeofcmds and a first section, so the header-pad
     * relation is live in every image. If this ever returns 0 the derivation
     * silently stops guarding growth. */
    uint8_t buf[REL_BUF_SIZE]; mi_image im;
    build_minimal_image(buf, sizeof buf, &im);
    CHECK((mrel_live(&im) & MREL_HEADER_PAD) != 0,
          "a bare header with zero load commands -> header pad must still be "
          "live, or growth's own guard against overflowing the pad silently "
          "goes dark for every image");
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

/* Critical gap closed: a prior version of this file asserted MREL_BASE_REL
 * only in its ABSENCE (no segment at all). A mutation swapping mrel_live's
 * mi_image_base call for mi_text_base passed every existing test, because no
 * image here ever had a segment mapping the header -- the positive case
 * never ran. This is the positive case, built to be the one image where the
 * two functions disagree; see add_zero_base_segment's own comment. */
static void test_base_rel_liveness_follows_a_segment_mapping_the_header(void) {
    uint8_t buf[REL_BUF_SIZE]; mi_image im;
    build_minimal_image(buf, sizeof buf, &im);
    CHECK((mrel_live(&im) & MREL_BASE_REL) == 0,
          "no segment maps the header -> the base-relative relation is NOT "
          "live -- there is no base to re-base against");
    add_zero_base_segment(buf, &im);
    CHECK((mrel_live(&im) & MREL_BASE_REL) != 0,
          "a segment maps the header, even at vmaddr 0 (a dylib) -> the "
          "base-relative relation IS live; reading this as 'not live' is "
          "the bug that made mg_plausible refuse every dylib on the machine");
}

/* Critical gap closed: a prior version of this file never built an image
 * carrying any ML_PLAIN_OFFSET_LCS member, so deleting the line that sets
 * MREL_FILE_OFF, inverting which case labels set it, or widening it to fire
 * on any command (e.g. a `default` that also sets the bit) all passed with
 * zero failures. */
static void test_file_off_liveness_follows_linkedit_plain_offset_commands(void) {
    uint8_t buf[REL_BUF_SIZE]; mi_image im;

    build_minimal_image(buf, sizeof buf, &im);
    CHECK((mrel_live(&im) & MREL_FILE_OFF) == 0,
          "no __LINKEDIT-plain-offset command -> the file-offset relation "
          "is NOT live");

    add_uuid(buf, &im);
    CHECK((mrel_live(&im) & MREL_FILE_OFF) == 0,
          "an LC_UUID (no __LINKEDIT footprint at all) present -> the "
          "file-offset relation must STILL be NOT live; an over-widened "
          "condition would flip every image's __LINKEDIT-blob check on for "
          "a command that carries no such blob");

    build_minimal_image(buf, sizeof buf, &im);
    add_symtab(buf, &im);
    CHECK((mrel_live(&im) & MREL_FILE_OFF) != 0,
          "one LC_SYMTAB (an ML_PLAIN_OFFSET_LCS member) -> the file-offset "
          "relation IS live, or a grow that bumps its symoff/stroff would "
          "leave nothing marked as needing that bump checked");
}

static void test_names_round_trip(void) {
    CHECK(strcmp(mrel_name(MREL_ORDINAL), "library ordinal") == 0,
          "MREL_ORDINAL's diagnostic name drifted from \"library ordinal\"");
    CHECK(strcmp(mrel_name(MREL_BASE_REL), "base-relative values") == 0,
          "MREL_BASE_REL's diagnostic name drifted from \"base-relative values\"");
    CHECK(strcmp(mrel_name(MREL_FILE_OFF), "file-offset fields") == 0,
          "MREL_FILE_OFF's diagnostic name drifted from \"file-offset fields\"");
    CHECK(strcmp(mrel_name(MREL_FUNC_START), "initializer and unwind targets") == 0,
          "MREL_FUNC_START's diagnostic name drifted from "
          "\"initializer and unwind targets\"");
    CHECK(strcmp(mrel_name(MREL_HEADER_PAD), "sizeofcmds") == 0,
          "MREL_HEADER_PAD's diagnostic name drifted from \"sizeofcmds\"");
    CHECK(mrel_name(1u << 20) == NULL,
          "an unknown bit must return NULL, not a stale or wrong name a "
          "caller's diagnostic would go on to print");
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
    test_base_rel_liveness_follows_a_segment_mapping_the_header();
    test_file_off_liveness_follows_linkedit_plain_offset_commands();
    test_names_round_trip();
    test_verify_applies_needs_a_live_relation_AND_a_disturbance();

    if (fails) {
        printf("%d failure(s)\n", fails);
        return 1;
    }
    printf("relations_test: 0 failure(s)\n");
    return 0;
}
