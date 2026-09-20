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
#include "../src/ordinals.h"

#include <mach-o/loader.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <setjmp.h>
#include <signal.h>
#include <unistd.h>
#include <sys/mman.h>

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

static void test_dylib_kind_names(void) {
    static const char *names[] = { "load", "weak", "reexport", "upward" };
    for (size_t i = 0; i < sizeof names / sizeof names[0]; i++) {
        uint32_t cmd = mo_kind_from_name(names[i]);
        CHECK(cmd != 0, "mo_kind_from_name(%s) returned 0", names[i]);
        CHECK(mo_is_ordinal_lc(cmd), "%s is not ordinal-bearing", names[i]);
        CHECK(mo_kind_name(cmd) && strcmp(mo_kind_name(cmd), names[i]) == 0,
              "%s did not round-trip", names[i]);
    }
    /* Explicit identity checks to catch transposed mappings in MO_KINDS. */
    CHECK(mo_kind_from_name("load")     == LC_LOAD_DYLIB,        "load mismaps");
    CHECK(mo_kind_from_name("weak")     == LC_LOAD_WEAK_DYLIB,   "weak mismaps");
    CHECK(mo_kind_from_name("reexport") == LC_REEXPORT_DYLIB,    "reexport mismaps");
    CHECK(mo_kind_from_name("upward")   == LC_LOAD_UPWARD_DYLIB, "upward mismaps");
    /* Verify mo_is_ordinal_lc accepts exactly these four, and rejects both
     * LC_LAZY_LOAD_DYLIB (policy: mo_map_build refuses it) and LC_ID_DYLIB
     * (policy: it's not a dependency, not addressable by ordinal). */
    CHECK(mo_is_ordinal_lc(LC_LOAD_DYLIB), "LC_LOAD_DYLIB must be ordinal-bearing");
    CHECK(mo_is_ordinal_lc(LC_LOAD_WEAK_DYLIB), "LC_LOAD_WEAK_DYLIB must be ordinal-bearing");
    CHECK(mo_is_ordinal_lc(LC_REEXPORT_DYLIB), "LC_REEXPORT_DYLIB must be ordinal-bearing");
    CHECK(mo_is_ordinal_lc(LC_LOAD_UPWARD_DYLIB), "LC_LOAD_UPWARD_DYLIB must be ordinal-bearing");
    CHECK(!mo_is_ordinal_lc(LC_LAZY_LOAD_DYLIB), "LC_LAZY_LOAD_DYLIB must NOT be ordinal-bearing");
    CHECK(!mo_is_ordinal_lc(LC_ID_DYLIB), "LC_ID_DYLIB must NOT be ordinal-bearing");
    /* mo_map_build refuses an image carrying LC_LAZY_LOAD_DYLIB because its
     * ordinal slotting has never been exercised. Accepting it here would let
     * `dylib retype` emit images this tool's own verbs refuse. */
    CHECK(mo_kind_from_name("lazy") == 0, "lazy was accepted as a kind");
    CHECK(mo_kind_name(LC_LAZY_LOAD_DYLIB) == NULL, "lazy was named");
    CHECK(mo_kind_from_name("") == 0, "empty string was accepted");
    CHECK(mo_kind_from_name("LOAD") == 0, "kind names are not case-folded");
}

/* M-3's own test: `--capabilities`' dylib-kinds line (cli/machorewrite.c) no
 * longer hardcodes its own kinds[] array -- it offers MO_KIND_CANDIDATES
 * (ordinals.h) to mo_kind_name and prints whichever answer non-NULL, so the
 * advertised set can never itself drift from MO_KINDS (ordinals.c) by a
 * stale hand-edited copy. What is STILL two independent implementations in
 * ordinals.c -- MO_KINDS (backing mo_kind_name/mo_kind_from_name) and
 * mo_is_ordinal_lc's own separate cmd==...||cmd==... chain -- is exactly
 * what this walks MO_KIND_CANDIDATES to catch: for every candidate,
 * mo_kind_name answering non-NULL and mo_is_ordinal_lc answering true must
 * agree, or a wrapper reading `--capabilities` and this tool's own
 * load-command rewrite would disagree about which kinds exist. This is the
 * drift M-3 named: a fifth kind added to one of the two ordinals.c
 * accept-lists but not the other would defeat `--capabilities`' whole
 * purpose (telling a wrapper the truth) while the rest of the suite stayed
 * green. */
static void test_capabilities_kinds_track_mo_is_ordinal_lc(void) {
    static const uint32_t candidates[] = { MO_KIND_CANDIDATES };
    for (size_t i = 0; i < sizeof candidates / sizeof candidates[0]; i++) {
        uint32_t cmd = candidates[i];
        int advertised = mo_kind_name(cmd) != NULL;
        int accepted = mo_is_ordinal_lc(cmd) != 0;
        CHECK(advertised == accepted,
              "LC_* 0x%x: mo_kind_name says %s, mo_is_ordinal_lc says %s -- "
              "--capabilities and the load-command rewrite would disagree",
              cmd, advertised ? "yes" : "no", accepted ? "yes" : "no");
    }
}

struct seen { int n; int ord[8]; char sym[8][32]; int weak[8]; };

static void note(const mo_bind_state *st, void *ctx) {
    struct seen *s = ctx;
    if (s->n >= 8) return;
    s->ord[s->n] = st->ordinal;
    s->weak[s->n] = st->weak;
    snprintf(s->sym[s->n], sizeof s->sym[0], "%s", st->symbol ? st->symbol : "");
    s->n++;
}

/* Exercises every DO_BIND-family opcode (DO_BIND, DO_BIND_ADD_ADDR_ULEB,
 * DO_BIND_ULEB_TIMES_SKIPPING_ULEB -- DO_BIND_ADD_ADDR_IMM_SCALED has no
 * operand to hand-encode so it is not additionally exercised here) and
 * every ordinal-setting opcode: SET_DYLIB_ORDINAL_IMM, SET_DYLIB_ORDINAL_ULEB
 * (previously untested), and SET_DYLIB_SPECIAL_IMM for all three defined
 * specials (previously only FLAT was tested -- SELF and EXE were not, so
 * swapping their case labels in ordinals.c passed the whole suite). */
static void test_bind_walk_observes(void) {
    uint8_t stream[] = {
        /* event 0: ordinal 2, weak _NSBeep, via DO_BIND */
        BIND_OPCODE_SET_DYLIB_ORDINAL_IMM | 2,
        BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM | BIND_SYMBOL_FLAGS_WEAK_IMPORT,
        '_','N','S','B','e','e','p','\0',
        BIND_OPCODE_SET_TYPE_IMM | BIND_TYPE_POINTER,
        BIND_OPCODE_DO_BIND,
        /* event 1: FLAT, non-weak _memcpy, via DO_BIND */
        BIND_OPCODE_SET_DYLIB_SPECIAL_IMM | (BIND_SPECIAL_DYLIB_FLAT_LOOKUP & BIND_IMMEDIATE_MASK),
        BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM | 0,
        '_','m','e','m','c','p','y','\0',
        BIND_OPCODE_DO_BIND,
        /* event 2: ULEB ordinal 130, weak _extern, via DO_BIND_ADD_ADDR_ULEB */
        BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB,
        0x82, 0x01,                              /* ULEB128 130 */
        BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM | BIND_SYMBOL_FLAGS_WEAK_IMPORT,
        '_','e','x','t','e','r','n','\0',
        BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB,
        0x00,                                    /* ULEB128 0 */
        /* event 3: SELF, non-weak _self, via DO_BIND_ULEB_TIMES_SKIPPING_ULEB */
        BIND_OPCODE_SET_DYLIB_SPECIAL_IMM | (BIND_SPECIAL_DYLIB_SELF & BIND_IMMEDIATE_MASK),
        BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM | 0,
        '_','s','e','l','f','\0',
        BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB,
        0x01, 0x00,                              /* ULEB128 1, ULEB128 0 */
        /* event 4: EXE, non-weak _exe, via DO_BIND */
        BIND_OPCODE_SET_DYLIB_SPECIAL_IMM | (BIND_SPECIAL_DYLIB_MAIN_EXECUTABLE & BIND_IMMEDIATE_MASK),
        BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM | 0,
        '_','e','x','e','\0',
        BIND_OPCODE_DO_BIND,
        BIND_OPCODE_DONE,
    };
    uint8_t copy[sizeof stream];
    memcpy(copy, stream, sizeof stream);

    /* Not `= {0}`: with -Wextra, that warns -Wmissing-field-initializers
     * for every member after the first (struct seen has four) even though
     * C guarantees all of them zero -- a real warning about a real
     * ambiguity elsewhere would drown in this one repeated everywhere the
     * struct is zeroed. memset says the same thing without the warning. */
    struct seen s;
    memset(&s, 0, sizeof s);
    int rc = mo_bind_walk(copy, (uint32_t)sizeof copy, NULL, 0, "test", NULL,
                          note, &s);
    CHECK(rc == 0, "observe-only walk returned %d", rc);
    CHECK(s.n == 5, "saw %d binds, wanted 5", s.n);
    CHECK(s.ord[0] == 2, "event 0 ordinal %d, wanted 2", s.ord[0]);
    CHECK(strcmp(s.sym[0], "_NSBeep") == 0, "event 0 symbol '%s'", s.sym[0]);
    CHECK(s.weak[0] == 1, "event 0 not reported weak");
    CHECK(s.ord[1] == MO_ORD_FLAT, "event 1 ordinal %d, wanted FLAT", s.ord[1]);
    CHECK(strcmp(s.sym[1], "_memcpy") == 0, "event 1 symbol '%s'", s.sym[1]);
    CHECK(s.weak[1] == 0, "event 1 reported weak");
    CHECK(s.ord[2] == 130, "event 2 ordinal %d, wanted 130 (ULEB)", s.ord[2]);
    CHECK(strcmp(s.sym[2], "_extern") == 0, "event 2 symbol '%s'", s.sym[2]);
    CHECK(s.weak[2] == 1, "event 2 not reported weak");
    CHECK(s.ord[3] == MO_ORD_SELF, "event 3 ordinal %d, wanted SELF", s.ord[3]);
    CHECK(strcmp(s.sym[3], "_self") == 0, "event 3 symbol '%s'", s.sym[3]);
    CHECK(s.weak[3] == 0, "event 3 reported weak");
    CHECK(s.ord[4] == MO_ORD_EXE, "event 4 ordinal %d, wanted EXE", s.ord[4]);
    CHECK(strcmp(s.sym[4], "_exe") == 0, "event 4 symbol '%s'", s.sym[4]);
    CHECK(s.weak[4] == 0, "event 4 reported weak");

    /* Under map == NULL, every ordinal-setting opcode's write (when its
     * guard is bypassed) reconstructs the identical bytes it read -- see
     * ordinals.c's mo_bind_walk, SET_DYLIB_ORDINAL_IMM/_ULEB -- so this
     * memcmp cannot, by construction, catch a write to an unchanged
     * ordinal; it exists to catch a FUTURE change that makes that no
     * longer true. What actually proves no STORE ever executes, including
     * one that would reproduce identical bytes, is
     * test_bind_walk_observe_never_writes_even_under_mprotect below: it
     * runs the same kind of walk over a PROT_READ page, so an unguarded
     * write faults on the instruction, not on the bytes it would produce. */
    CHECK(memcmp(copy, stream, sizeof stream) == 0,
          "observe-only walk modified the stream");
}

/* Coverage for Finding 2's fix: an undefined BIND_OPCODE_SET_DYLIB_SPECIAL_IMM
 * value must report MO_ORD_UNKNOWN, not the raw (sign-extended) special
 * value echoed back -- because MO_ORD_FLAT is itself the integer -3, and an
 * undefined special of -3 (this SDK has no name for it; a newer SDK calls it
 * BIND_SPECIAL_DYLIB_WEAK_LOOKUP) would otherwise be indistinguishable from
 * a real FLAT lookup to any caller comparing against MO_ORD_FLAT. */
static void test_bind_walk_observe_reports_undefined_special_as_unknown(void) {
    uint8_t stream[] = {
        BIND_OPCODE_SET_DYLIB_SPECIAL_IMM | 0x0D,   /* raw -3, sign-extended */
        BIND_OPCODE_DO_BIND,
        BIND_OPCODE_DONE,
    };
    struct seen s;   /* see the other test's own comment on why not `= {0}` */
    memset(&s, 0, sizeof s);
    int rc = mo_bind_observe(stream, (uint32_t)sizeof stream, "test", note, &s);
    CHECK(rc == 0, "observe-only walk returned %d", rc);
    CHECK(s.n == 1, "saw %d binds, wanted 1", s.n);
    CHECK(s.ord[0] == MO_ORD_UNKNOWN,
          "undefined special -3 reported as %d, wanted MO_ORD_UNKNOWN -- it "
          "must not collide with MO_ORD_FLAT, which is also -3", s.ord[0]);
}

/* Coverage for Finding 3's fix: a decoded ULEB ordinal must be bounded
 * against MO_MAX_DYLIBS even in observe mode, where there is no map/nold to
 * check it against -- otherwise an untrusted, arbitrarily large ULEB value
 * becomes an implementation-defined `int` (C99 6.3.1.3p3) instead of a
 * refusal. 1000 (> MO_MAX_DYLIBS == 253) ULEB128-encodes as {0xE8, 0x07}. */
static void test_bind_walk_observe_refuses_out_of_range_uleb_ordinal(void) {
    uint8_t stream[] = {
        BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB,
        0xE8, 0x07,                                 /* ULEB128 1000 */
        BIND_OPCODE_DO_BIND,
        BIND_OPCODE_DONE,
    };
    int rc = mo_bind_observe(stream, (uint32_t)sizeof stream, "test", NULL, NULL);
    CHECK(rc == -1, "observe-only walk accepted an out-of-range ULEB ordinal "
                    "(rc=%d)", rc);
}

/* Coverage for Finding 1's fix: a trailing symbol name that runs off the end
 * of the stream with no NUL must refuse in observe mode, rather than hand
 * the observer a pointer that is not a valid C string -- note()'s own
 * snprintf("%s", ...) is exactly the kind of read that would walk off the
 * end of this buffer if st->symbol were set here. */
static void test_bind_walk_observe_refuses_unterminated_symbol(void) {
    uint8_t stream[] = {
        BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM | 0,
        '_','o','o','p','s',                        /* no trailing NUL */
    };
    int rc = mo_bind_observe(stream, (uint32_t)sizeof stream, "test", NULL, NULL);
    CHECK(rc == -1, "observe-only walk accepted an unterminated symbol name "
                    "(rc=%d)", rc);
}

static sigjmp_buf mo_fault_jmp;
static volatile sig_atomic_t mo_faulted;

static void mo_fault_handler(int sig) {
    (void)sig;
    mo_faulted = 1;
    siglongjmp(mo_fault_jmp, 1);
}

/* Finding 5(b): the mechanism that actually establishes "an observe-only
 * walk writes nothing" -- which test_bind_walk_observes' memcmp cannot, by
 * construction (see its own comment) -- is to make an unguarded write
 * fault on the INSTRUCTION, not on the bytes it would produce. Runs the
 * same kind of stream mo_bind_observe would ever see over a page mapped
 * PROT_READ; any store into it raises SIGSEGV/SIGBUS, caught here and
 * turned into a normal CHECK failure instead of taking down the whole test
 * binary. */
static void test_bind_walk_observe_never_writes_even_under_mprotect(void) {
    long pagesize = sysconf(_SC_PAGESIZE);
    if (pagesize <= 0) pagesize = 4096;
    void *page = mmap(NULL, (size_t)pagesize, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANON, -1, 0);
    if (page == MAP_FAILED) {
        CHECK(0, "mmap failed: %s", strerror(errno));
        return;
    }

    uint8_t stream[] = {
        BIND_OPCODE_SET_DYLIB_ORDINAL_IMM | 2,
        BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM | BIND_SYMBOL_FLAGS_WEAK_IMPORT,
        '_','N','S','B','e','e','p','\0',
        BIND_OPCODE_DO_BIND,
        BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB,
        0x82, 0x01,                              /* ULEB128 130 */
        BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB,
        0x00,                                    /* ULEB128 0 */
        BIND_OPCODE_DONE,
    };
    memcpy(page, stream, sizeof stream);

    if (mprotect(page, (size_t)pagesize, PROT_READ) != 0) {
        CHECK(0, "mprotect(PROT_READ) failed: %s", strerror(errno));
        munmap(page, (size_t)pagesize);
        return;
    }

    struct sigaction sa, old_segv, old_bus;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = mo_fault_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGSEGV, &sa, &old_segv);
    sigaction(SIGBUS, &sa, &old_bus);

    mo_faulted = 0;
    int rc = -99;
    if (sigsetjmp(mo_fault_jmp, 1) == 0) {
        rc = mo_bind_observe((const uint8_t *)page, (uint32_t)sizeof stream,
                             "mprotect-test", NULL, NULL);
    }

    sigaction(SIGSEGV, &old_segv, NULL);
    sigaction(SIGBUS, &old_bus, NULL);
    mprotect(page, (size_t)pagesize, PROT_READ | PROT_WRITE);
    munmap(page, (size_t)pagesize);

    CHECK(!mo_faulted, "observe-only walk faulted writing to a PROT_READ "
                       "page -- it executed a store it must never execute");
    CHECK(rc == 0, "observe-only walk over PROT_READ memory returned %d", rc);
}

int main(void) {
    test_header_pad_is_always_live();
    test_func_start_liveness_follows_the_load_command();
    test_ordinal_liveness_follows_ordinal_carrying_commands();
    test_base_rel_liveness_follows_a_segment_mapping_the_header();
    test_file_off_liveness_follows_linkedit_plain_offset_commands();
    test_names_round_trip();
    test_verify_applies_needs_a_live_relation_AND_a_disturbance();
    test_dylib_kind_names();
    test_capabilities_kinds_track_mo_is_ordinal_lc();
    test_bind_walk_observes();
    test_bind_walk_observe_reports_undefined_special_as_unknown();
    test_bind_walk_observe_refuses_out_of_range_uleb_ordinal();
    test_bind_walk_observe_refuses_unterminated_symbol();
    test_bind_walk_observe_never_writes_even_under_mprotect();

    if (fails) {
        printf("%d failure(s)\n", fails);
        return 1;
    }
    printf("relations_test: 0 failure(s)\n");
    return 0;
}
