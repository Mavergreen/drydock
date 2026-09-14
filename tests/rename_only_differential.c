/*
 * tests/rename_only_differential.c -- the two applicability predicates, run
 * side by side across every operation-set shape the suite exercises.
 *
 * THIS FILE IS THE GATE ON A DELETION. src/rewrite.c's mr_is_rename_only
 * decides, by hand, whether mg_plausible runs; src/relations.h's
 * mrel_verify_applies decides the same thing by derivation over what an
 * operation DECLARES it disturbs. The derived rule deliberately skips checks
 * the hand-written one ran, so "the two agree everywhere" would be an
 * incoherent thing to assert. What is asserted instead is the design's
 * enumerated difference list, as data: a difference ON the list is expected,
 * and a difference anywhere else fails. Only once that holds does the old
 * predicate come out -- and this file goes with it.
 * spec: docs/superpowers/specs/2026-09-10-relations-and-verb-lowering-design.md's
 * Decision 3, whose expected-difference table EXPECTED below transcribes.
 *
 * HOW THE TWO COLUMNS ARE COMPUTED, since neither is a one-liner:
 *
 *   old:  mr_is_rename_only, over the mr_ops of EVERY STATEMENT THE RUN
 *         EXECUTED. src/edit.c's me_apply lowers one statement to one mr_ops
 *         and hands it to mr_apply_image -> mr_process_thin, which is the site
 *         that consults the predicate (src/rewrite.c:943). So a run consults
 *         it once per lowering statement, and the run's answer is: SKIPS if
 *         every lowering statement was rename-only, RUNS if any was not, and
 *         OLD_NA if no statement lowered to an mr_ops at all.
 *
 *   new:  !mrel_verify_applies(slice, disturbed) -- nonzero means "skip".
 *
 * GRANULARITY, stated because the two columns are not taken at the same place
 * and a reader comparing them deserves to know. `old` is per statement, on the
 * image as that statement found it -- exactly where mr_process_thin asks. `new`
 * is taken ONCE, on the finished image, with the mask the whole run
 * accumulated -- which is exactly where Decision 5 puts the derived verdict on
 * the `edit` side (src/edit.c:900's final verify, and :677's per slice). So
 * each column is taken at its own real site; neither is an approximation of
 * its own rule. What is approximate is only the COMPARISON, and only for the
 * four multi-statement rows (11, 12, 20 and 21): there `old` folds several
 * per-statement answers into one and `new` has a single whole-run answer, so
 * the row says "did the gate run at all during this run" on both sides rather
 * than statement by statement. For the other eighteen rows, one statement
 * lowers and the two sites coincide.
 *
 * `disturbed` is WHAT THE RUN DID, not only what the script declared, which
 * the design insists on ("computing applicability from the statement list
 * alone would skip the gate on exactly the runs that most need it"). So every
 * shape here is really RUN, through me_run, with its whole report captured,
 * and `disturbed` is
 *
 *     me_followups(script)            the declared half, and
 *   | every derived statement's mask  what a `target` line expanded into
 *   | MREL_BASE_REL|MREL_FILE_OFF     if the report says the header grew
 *
 * -- the second and third terms read out of the run's own report, mapping each
 * derived statement back through the ONE operation table (ms_table_row), so
 * this file cannot name a disturbs mask the table does not. me_followups alone
 * is NOT enough and the three `target` rows are what prove it: `target 10.9`
 * declares MREL_NONE, and a harness fed the declaration alone would assert a
 * skip that the real run must not take.
 *
 * THE "old" COLUMN HAS THREE STATES. mr_is_rename_only takes an mr_ops, and
 * only load-command/segment/dylib/rpath statements lower to one. `swift-abi
 * set`, `version-min set` and `fixups set classic` never do, so for a run made
 * only of those there is no predicate to differ from and OLD_NA says so.
 * Calling mr_is_rename_only on a zeroed mr_ops and reporting the answer as
 * "old" is the one way this table could lie -- it would return "runs" for a
 * gate that never ran -- so which shapes are OLD_NA is DERIVED, from the
 * statements the run actually executed, `target`'s expansion included. A
 * `target` line is NOT automatically OLD_NA: its expansion can derive a
 * `load-command delete` or a `segment rename`, and both lower.
 *
 * THE LOWERING THIS FILE TRANSCRIBES IS PINNED TO THE ONE THAT SHIPS.
 * lower_one below is a transcription of me_apply's switch, and a transcription
 * drifts. pin_the_lowering reads src/edit.c and asserts which mr_ops field is
 * assigned under which `case`, so a field moved, added or dropped there fails
 * HERE, naming it, instead of leaving this file quietly answering about an
 * mr_ops the shipping code no longer builds.
 *
 * RELATIONS ARE EVALUATED PER SLICE (Decision 6). Two blocks hold that: row 22
 * is a full differential row on a fat container, evaluated and asserted once
 * per slice, and run_fat below is a container whose two slices MUST answer
 * differently, which is the only shape of fixture a container-level
 * implementation cannot fake.
 *
 * Build: ctest runs it as rename_only_differential, from the SOURCE directory
 * (pin_the_lowering reads src/edit.c). By hand, compile with -Isrc together
 * with every .c file under src/, and run it from the repository root.
 */
#include "edit.h"
#include "image.h"
#include "lc_kinds.h"
#include "relations.h"
#include "rewrite.h"
#include "script.h"
#include "mach_compat.h"

#include <mach-o/loader.h>
#include <mach-o/fat.h>
#include <libkern/OSByteOrder.h>
#include <dirent.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int fails = 0;
#define CHECK(cond, msg, ...) do { if (!(cond)) { \
    printf("FAIL: " msg "\n", ##__VA_ARGS__); fails++; } } while (0)

/* ---- the expected-difference list, as data ------------------------------
 *
 * The complete expected-difference list from the design (Decision 3), restated
 * against the DERIVATION rather than against mr_process_thin's gate site.
 *
 * A difference ON this list is expected and asserted. A difference anywhere
 * else FAILS -- that is the whole point of the harness. */
#define OLD_RUNS  0
#define OLD_SKIPS 1
#define OLD_NA    2   /* no statement of this run lowered to an mr_ops */

static const struct { const char *shape; int old; int new_skips; } EXPECTED[] = {
    /* --- shapes a verb lowers to an mr_ops: both columns are defined ------ */
    { "segment rename alone",          OLD_SKIPS, 1 },  /* unchanged */
    { "load-command delete alone",     OLD_RUNS,  1 },  /* narrowed */
    { "dylib reexport alone",          OLD_RUNS,  1 },
    { "dylib append alone",            OLD_RUNS,  1 },
    { "dylib replace alone",           OLD_RUNS,  1 },
    { "dylib insert alone",            OLD_RUNS,  1 },
    { "dylib delete alone",            OLD_RUNS,  1 },
    { "rpath append alone",            OLD_RUNS,  1 },
    { "rpath insert alone",            OLD_RUNS,  1 },
    { "rpath replace alone",           OLD_RUNS,  1 },
    { "rpath delete alone",            OLD_RUNS,  1 },
    /* Rows 11 and 12 are two statements, and NO front-end builds either as one
     * mr_ops: cmd_lc, cmd_segment and cmd_dylib_or_rpath each fill only their
     * own fields, and src/edit.c lowers one statement to one mr_ops. They are
     * here as RUNS of two statements, which is what a script really does, and
     * `old` folds the two per-statement answers -- not as a single operation
     * set anyone can construct. */
    { "lc delete + dylib delete",      OLD_RUNS,  1 },  /* the union still moves no offset */
    { "segment rename + dylib append", OLD_RUNS,  1 },  /* the append is why old ran */
    { "dylib append that GREW the pad", OLD_RUNS, 0 },  /* a grow disturbs the base */

    /* --- shapes no statement lowers to an mr_ops: "old" is not a thing ---- */
    { "swift-abi set alone",           OLD_NA,    1 },  /* mswift_retag_image: no mr_ops */
    { "version-min set alone",         OLD_NA,    1 },  /* mv_add_version_min: no mr_ops */
    { "version-min set that GREW",     OLD_NA,    0 },  /* allow-grow reaches minos */
    { "fixups set classic",            OLD_NA,    0 },  /* md_declassify_buf: no mr_ops */
    /* The liveness half of mrel_verify_applies, pinned OUTSIDE the fat block:
     * the same statement, the same MREL_BASE_REL disturbance, on an image with
     * no LC_FUNCTION_STARTS. The gate has nothing to check, so it must be
     * skipped -- a derivation that consulted only `disturbed` would run it. */
    { "fixups set classic, no function starts", OLD_NA, 1 },
    { "target 10.9 (nothing to do)",   OLD_NA,    1 },  /* empty expansion */
    /* The expansion derives `load-command delete build-version`, which lowers
     * to an mr_ops and DOES reach mr_is_rename_only. A `target` line is not
     * OLD_NA by being a `target` line; it is whatever its expansion lowers. */
    { "target 10.9 (derives fixups)",  OLD_RUNS,  0 },  /* the expansion disturbs the base */
    /* The expansion derives a SEGMENT RENAME and nothing else -- the one shape
     * the old predicate skips, reached through a profile rather than written
     * out. Decision 3's "rename-only: skips -> skips, unchanged" row has to
     * hold here too, or the licence to delete does not cover `target`. */
    { "target 10.9 (derives a rename)", OLD_SKIPS, 1 },
    /* Decision 6 as a DIFFERENTIAL row, not only as a liveness demonstration:
     * the narrowing (old runs, new skips) must hold on a fat container, and
     * per slice. */
    { "load-command delete, fat container", OLD_RUNS, 1 },
};
#define N_EXPECTED ((int)(sizeof EXPECTED / sizeof EXPECTED[0]))

/* ---- the shapes themselves ---------------------------------------------
 *
 * One row per EXPECTED row, in the same order, checked by name. `script` is
 * the edit script the shape IS -- the one input from which both columns are
 * derived, the ops included, so a row cannot describe one operation set to
 * mr_is_rename_only and another to the derivation.
 *
 * `lowering` is what each executed statement must lower to, in execution
 * order, joined by " | ", with "-" for a statement that lowers to no mr_ops
 * and "" for a run that executed no statement at all (an empty `target`
 * expansion). It is written out by hand for two reasons. Without it, an ops builder that
 * did nothing at all would still get "runs" out of mr_is_rename_only (a zeroed
 * mr_ops has no rename in it) and most defined rows would pass over an ops
 * that described nothing. And it is what makes OLD_NA falsifiable: a row
 * claiming "no mr_ops" whose run really lowered one fails here, naming the
 * statement -- which is how row 20's OLD_NA was found to be false.
 *
 * `funcs_live` is whether the RESULT image must still have a live
 * LC_FUNCTION_STARTS. It is asserted in both directions: 1 is the anti-vacuity
 * guard (with no function starts the derivation answers "skip" whatever the
 * run disturbed, and every `new: skips` row would read as expected while
 * proving nothing), and 0 is the liveness pin (the gate must be skipped for
 * lack of anything to check, even though the base WAS disturbed).
 *
 * `grows` and `derives` are the run's own observations, asserted rather than
 * assumed: a positive control on the report reader for the rows where it must
 * fire, and a negative control on every row where it must not. */
enum { F_PLAIN, F_DYLD_INFO, F_NOFUNCS, F_ALREADY_109, F_DATACONST,
       F_GROWABLE, F_CHAINED };

static const struct {
    const char *shape;
    int         fixture;
    int         fat;       /* wrap the fixture in a two-slice container */
    const char *script;
    const char *lowering;
    int         funcs_live;
    int         grows;     /* the report must say the header grew */
    int         derives;   /* the report must show >= 1 derived statement */
} SHAPES[] = {
  { "segment rename alone", F_PLAIN, 0,
    "segment rename __DATA __DATA_R9\n", "rename", 1, 0, 0 },
  { "load-command delete alone", F_PLAIN, 0,
    "load-command delete uuid\n", "strip_cmds=1", 1, 0, 0 },
  { "dylib reexport alone", F_PLAIN, 0,
    "dylib reexport /usr/lib/libSystem.B.dylib\n", "dylib_changes=1", 1, 0, 0 },
  { "dylib append alone", F_PLAIN, 0,
    "dylib append /usr/lib/libappended.dylib\n", "dylib_appends=1", 1, 0, 0 },
  { "dylib replace alone", F_PLAIN, 0,
    "dylib replace /usr/lib/libSystem.B.dylib /usr/lib/libOther.dylib\n",
    "dylib_changes=1", 1, 0, 0 },
  { "dylib insert alone", F_PLAIN, 0,
    "dylib insert /usr/lib/libinserted.dylib\n", "dylib_inserts=1", 1, 0, 0 },
  { "dylib delete alone", F_PLAIN, 0,
    "dylib delete /usr/lib/libSystem.B.dylib\n", "dylib_changes=1", 1, 0, 0 },
  { "rpath append alone", F_PLAIN, 0,
    "rpath append @loader_path/../appended\n", "rpath_appends=1", 1, 0, 0 },
  { "rpath insert alone", F_PLAIN, 0,
    "rpath insert @loader_path/../inserted\n", "rpath_inserts=1", 1, 0, 0 },
  { "rpath replace alone", F_PLAIN, 0,
    "rpath replace @loader_path/../lib @loader_path/../other\n",
    "rpath_changes=1", 1, 0, 0 },
  { "rpath delete alone", F_PLAIN, 0,
    "rpath delete @loader_path/../lib\n", "rpath_changes=1", 1, 0, 0 },
  { "lc delete + dylib delete", F_PLAIN, 0,
    "load-command delete uuid\ndylib delete /usr/lib/libSystem.B.dylib\n",
    "strip_cmds=1 | dylib_changes=1", 1, 0, 0 },
  { "segment rename + dylib append", F_PLAIN, 0,
    "segment rename __DATA __DATA_R9\ndylib append /usr/lib/libappended.dylib\n",
    "rename | dylib_appends=1", 1, 0, 0 },
  /* A path long enough that the new LC_LOAD_DYLIB cannot fit the growable
   * fixture's deliberately tiny header pad, so the run really grows. */
  { "dylib append that GREW the pad", F_GROWABLE, 0,
    "allow-grow\ndylib append /usr/lib/"
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd.dylib\n",
    "dylib_appends=1,allow-grow", 1, 1, 0 },

  { "swift-abi set alone", F_PLAIN, 0, "swift-abi set legacy\n", "-", 1, 0, 0 },
  { "version-min set alone", F_PLAIN, 0, "version-min set 10.9\n", "-", 1, 0, 0 },
  { "version-min set that GREW", F_GROWABLE, 0,
    "allow-grow\nversion-min set 10.9\n", "-", 1, 1, 0 },
  { "fixups set classic", F_DYLD_INFO, 0, "fixups set classic\n", "-", 1, 0, 0 },
  { "fixups set classic, no function starts", F_NOFUNCS, 0,
    "fixups set classic\n", "-", 0, 0, 0 },
  /* "" and not "-": this run executed NO statement at all, the expansion being
   * empty, which is a different fact from one statement that lowered to
   * nothing. Both reach OLD_NA, and the two are worth telling apart -- an
   * expansion that quietly stopped expanding would otherwise read as an
   * expansion that correctly found nothing to do. */
  { "target 10.9 (nothing to do)", F_ALREADY_109, 0, "target 10.9\n", "", 1, 0, 0 },
  /* fixups set classic, load-command delete build-version, version-min set
   * 10.9 -- in that order, which is me_expand_10_9's. */
  { "target 10.9 (derives fixups)", F_CHAINED, 0, "target 10.9\n",
    "- | strip_cmds=1 | -", 1, 0, 1 },
  { "target 10.9 (derives a rename)", F_DATACONST, 0, "target 10.9\n",
    "rename", 1, 0, 1 },
  { "load-command delete, fat container", F_PLAIN, 1,
    "load-command delete uuid\n", "strip_cmds=1", 1, 0, 0 },
};

/* ---- fixtures -----------------------------------------------------------
 *
 * Hand-built, for the reason tests/relations_test.c gives: liveness must not
 * depend on what the host linker chose to emit. Every fixture but F_NOFUNCS
 * has a LIVE MREL_FUNC_START -- an LC_FUNCTION_STARTS with a blob that decodes
 * -- and a segment mapping the header; F_NOFUNCS is the one that deliberately
 * does not, and its row asserts the skip that follows. */

#define TEXT_VMADDR 0x100000000ULL
#define SECT_OFF    0x400        /* the one address LC_FUNCTION_STARTS names */
#define DATA_OFF    0x1000
#define DATA_SIZE   0x1000
#define LE_OFF      0x2000
#define LE_SIZE     0x1000
#define FS_SIZE     8
#define IMG_SIZE    (LE_OFF + LE_SIZE)

/* build_plain's options. */
#define P_DYLD_INFO   1   /* an (empty) LC_DYLD_INFO_ONLY: already classic */
#define P_VERSION_MIN 2   /* an LC_VERSION_MIN_MACOSX: already targets 10.9 */
#define P_NO_FUNCS    4   /* NO LC_FUNCTION_STARTS */
#define P_DATACONST   8   /* the data segment is __DATA_CONST and carries an
                           * __objc_ section: what makes `target 10.9` derive
                           * a segment rename (src/edit.c's me_target_lc) */

static void set16(char *field, const char *name) {
    size_t len = strlen(name);
    if (len > 16) len = 16;
    memset(field, 0, 16);
    memcpy(field, name, len);
}

static struct segment_command_64 *put_seg(uint8_t *p, const char *name, uint64_t vmaddr,
                                          uint64_t vmsize, uint64_t fileoff,
                                          uint64_t filesize, uint32_t nsects) {
    struct segment_command_64 *s = (struct segment_command_64 *)p;
    s->cmd = LC_SEGMENT_64;
    s->cmdsize = (uint32_t)(sizeof *s + nsects * sizeof(struct section_64));
    set16(s->segname, name);
    s->vmaddr = vmaddr; s->vmsize = vmsize;
    s->fileoff = fileoff; s->filesize = filesize;
    s->maxprot = 7; s->initprot = 3;
    s->nsects = nsects; s->flags = 0;
    return s;
}

static void put_sect(struct segment_command_64 *seg, int i, const char *sect,
                     const char *segname, uint64_t addr, uint64_t size,
                     uint32_t offset, uint32_t flags) {
    struct section_64 *s = (struct section_64 *)(seg + 1) + i;
    memset(s, 0, sizeof *s);
    set16(s->sectname, sect);
    set16(s->segname, segname);
    s->addr = addr; s->size = size; s->offset = offset; s->flags = flags;
}

/* An LC_LOAD_DYLIB, laid out the way a linker would: the name after the fixed
 * part, cmdsize rounded up to 8. */
static uint32_t put_dylib(uint8_t *p, const char *path) {
    struct dylib_command *d = (struct dylib_command *)p;
    uint32_t fixed = (uint32_t)sizeof *d;
    size_t n = strlen(path) + 1;
    uint32_t cmdsize = (uint32_t)((fixed + n + 7) & ~(size_t)7);
    memset(p, 0, cmdsize);
    d->cmd = LC_LOAD_DYLIB;
    d->cmdsize = cmdsize;
    d->dylib.name.offset = fixed;
    memcpy(p + fixed, path, n);
    return cmdsize;
}

/* An LC_RPATH, on the same terms. */
static uint32_t put_rpath(uint8_t *p, const char *path) {
    struct rpath_command *r = (struct rpath_command *)p;
    uint32_t fixed = (uint32_t)sizeof *r;
    size_t n = strlen(path) + 1;
    uint32_t cmdsize = (uint32_t)((fixed + n + 7) & ~(size_t)7);
    memset(p, 0, cmdsize);
    r->cmd = LC_RPATH;
    r->cmdsize = cmdsize;
    r->path.offset = fixed;
    memcpy(p + fixed, path, n);
    return cmdsize;
}

#define PLAIN_DYLIB "/usr/lib/libSystem.B.dylib"
#define PLAIN_RPATH "@loader_path/../lib"

/* tests/edit_test.c's image, plus the one LC_LOAD_DYLIB and the one LC_RPATH
 * the dylib and rpath shapes need to have something to match: __TEXT with one
 * section at 0x400, a data segment with two sections (the second an
 * __init_offsets whose entry names 0x400), __LINKEDIT, LC_UUID, and an
 * LC_FUNCTION_STARTS declaring the single function start base + 0x400 -- so
 * the image is plausible and MREL_FUNC_START is live. */
static uint8_t *build_plain(int opt, size_t *outlen) {
    uint8_t *buf = (uint8_t *)calloc(1, IMG_SIZE);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    h->magic = MH_MAGIC_64;
    h->cputype = CPU_TYPE_X86_64;
    h->cpusubtype = CPU_SUBTYPE_X86_64_ALL;
    h->filetype = MH_DYLIB;
    h->flags = MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL;

    uint8_t *p = buf + sizeof *h;
    uint32_t ncmds = 0;

    struct segment_command_64 *text = put_seg(p, "__TEXT", TEXT_VMADDR, 0x1000, 0, 0x1000, 1);
    put_sect(text, 0, "__text", "__TEXT", TEXT_VMADDR + SECT_OFF, 4, SECT_OFF, 0);
    p += text->cmdsize; ncmds++;

    /* The data segment. Named __DATA_CONST and given a third, __objc_ section
     * under P_DATACONST -- the exact pair me_target_lc looks for. The section
     * is __objc_const, not __objc_classlist or __objc_nlclslist, so
     * mswift_stable_tagged_image finds no class-record list and the expansion
     * derives the rename and NOTHING ELSE: that isolation is the row's point. */
    int dc = (opt & P_DATACONST) != 0;
    const char *dname = dc ? "__DATA_CONST" : "__DATA";
    struct segment_command_64 *data = put_seg(p, dname, TEXT_VMADDR + DATA_OFF, DATA_SIZE,
                                              DATA_OFF, DATA_SIZE, dc ? 3 : 2);
    put_sect(data, 0, "__data", dname, TEXT_VMADDR + DATA_OFF, 8, DATA_OFF, 0);
    put_sect(data, 1, "__init_offsets", dname, TEXT_VMADDR + DATA_OFF + 0x800, 4,
             DATA_OFF + 0x800, S_INIT_FUNC_OFFSETS);
    if (dc)
        put_sect(data, 2, "__objc_const", dname, TEXT_VMADDR + DATA_OFF + 0x900, 8,
                 DATA_OFF + 0x900, 0);
    p += data->cmdsize; ncmds++;

    struct segment_command_64 *le = put_seg(p, "__LINKEDIT", TEXT_VMADDR + LE_OFF, LE_SIZE,
                                            LE_OFF, LE_SIZE, 0);
    p += le->cmdsize; ncmds++;

    struct uuid_command *uu = (struct uuid_command *)p;
    uu->cmd = LC_UUID; uu->cmdsize = sizeof *uu;
    memset(uu->uuid, 0xab, sizeof uu->uuid);
    p += uu->cmdsize; ncmds++;

    if (!(opt & P_NO_FUNCS)) {
        struct linkedit_data_command *fs = (struct linkedit_data_command *)p;
        fs->cmd = LC_FUNCTION_STARTS; fs->cmdsize = sizeof *fs;
        fs->dataoff = LE_OFF; fs->datasize = FS_SIZE;
        p += fs->cmdsize; ncmds++;
    }

    p += put_dylib(p, PLAIN_DYLIB); ncmds++;
    p += put_rpath(p, PLAIN_RPATH); ncmds++;

    if (opt & P_DYLD_INFO) {
        struct dyld_info_command *di = (struct dyld_info_command *)p;
        di->cmd = LC_DYLD_INFO_ONLY; di->cmdsize = sizeof *di;
        p += di->cmdsize; ncmds++;
    }
    if (opt & P_VERSION_MIN) {
        struct version_min_command *vm = (struct version_min_command *)p;
        vm->cmd = LC_VERSION_MIN_MACOSX; vm->cmdsize = sizeof *vm;
        vm->version = 0x000A0900; vm->sdk = 0x000A0900;
        p += vm->cmdsize; ncmds++;
    }

    h->ncmds = ncmds;
    h->sizeofcmds = (uint32_t)(p - (buf + sizeof *h));

    /* One function start at base + 0x400 (ULEB128 0x400 is 0x80 0x08), and an
     * initializer naming exactly that address, so the image is plausible. */
    buf[LE_OFF] = 0x80; buf[LE_OFF + 1] = 0x08;
    uint32_t init = SECT_OFF;
    memcpy(buf + DATA_OFF + 0x800, &init, sizeof init);
    *outlen = IMG_SIZE;
    return buf;
}

/* An MH_EXECUTE/MH_PIE image mg_grow_header can grow, whose header pad is
 * EIGHT BYTES: smaller than any load command, so appending anything at all
 * needs allow-grow. A __PAGEZERO donates the vm space the grow lowers the base
 * into. It carries an LC_FUNCTION_STARTS for this file's own reason: without
 * one the two GREW rows could not tell a derivation that reads the grow from
 * one that ignores it. */
#define GROW_SIZE    0x2000
#define GROW_FS_OFF  0x1000

static uint8_t *build_growable(size_t *outlen) {
    uint8_t *buf = (uint8_t *)calloc(1, GROW_SIZE);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    h->magic = MH_MAGIC_64;
    h->cputype = CPU_TYPE_X86_64;
    h->cpusubtype = CPU_SUBTYPE_X86_64_ALL;
    h->filetype = MH_EXECUTE;
    h->flags = MH_PIE;

    uint8_t *p = buf + sizeof *h;
    struct segment_command_64 *pz = put_seg(p, "__PAGEZERO", 0, 0x100000000ULL, 0, 0, 0);
    pz->maxprot = pz->initprot = 0;    /* as tests/edit_test.c's growable image */
    p += pz->cmdsize;

    struct segment_command_64 *tx = put_seg(p, "__TEXT", TEXT_VMADDR, GROW_SIZE,
                                            0, GROW_SIZE, 1);
    tx->maxprot = tx->initprot = 0;
    p += tx->cmdsize;

    struct linkedit_data_command *fs = (struct linkedit_data_command *)p;
    fs->cmd = LC_FUNCTION_STARTS; fs->cmdsize = sizeof *fs;
    fs->dataoff = GROW_FS_OFF; fs->datasize = FS_SIZE;
    p += fs->cmdsize;

    h->ncmds = 3;
    h->sizeofcmds = (uint32_t)(p - (buf + sizeof *h));

    /* The one section starts eight bytes past the end of the load commands:
     * the whole header pad, and too small for any load command. */
    uint32_t sectoff = (uint32_t)(sizeof *h + h->sizeofcmds + 8);
    put_sect(tx, 0, "__text", "__TEXT", TEXT_VMADDR + sectoff, 4, sectoff, 0);

    /* One function start, at the section. The grow lowers the base, widening
     * this leading delta, which mg_grow_header refuses if it would need
     * another byte -- two bytes cover up to 0x3fff. */
    uint32_t delta = sectoff;
    buf[GROW_FS_OFF] = (uint8_t)(0x80 | (delta & 0x7f));
    buf[GROW_FS_OFF + 1] = (uint8_t)(delta >> 7);
    *outlen = GROW_SIZE;
    return buf;
}

/* tests/mkchained.c's image -- three segments, a two-link chain in __DATA, an
 * LC_DYLD_CHAINED_FIXUPS naming a hand-built fixups blob, an
 * LC_DYLD_EXPORTS_TRIE and an LC_BUILD_VERSION -- with an LC_FUNCTION_STARTS
 * added. Copied rather than shared because mkchained.c is a program: only
 * cli_test.sh and wrapper_test.sh can run it, and this is the same bytes with
 * the one command that makes MREL_FUNC_START live. What it is FOR is
 * `target 10.9`'s expansion: LC_DYLD_CHAINED_FIXUPS is what makes the
 * expansion derive `fixups set classic` (src/edit.c's me_expand_10_9), and
 * that derived statement is the only way a `target` line reaches
 * MREL_BASE_REL; LC_BUILD_VERSION is what makes it derive a `load-command
 * delete`, which is the only way it reaches an mr_ops.
 *
 * spec: tests/cli_test.sh's "target: chained fixups expand to fixups set
 * classic" -- the same fixture shape, run through the CLI, which is the
 * evidence that the conversion really completes on these bytes. */
#define CH_TRIE_SIZE   0x10
#define CH_FIXUPS_SIZE 0x100
#define CH_FS_OFF      (LE_OFF + 0x200)

static uint8_t *build_chained(size_t *outlen) {
    size_t fsize = IMG_SIZE;
    uint8_t *buf = (uint8_t *)calloc(1, fsize);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    h->magic = MH_MAGIC_64;
    h->cputype = CPU_TYPE_X86_64;
    h->cpusubtype = CPU_SUBTYPE_X86_64_ALL;
    h->filetype = MH_DYLIB;
    h->flags = MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL;

    uint8_t *p = buf + sizeof *h;
    uint32_t ncmds = 0;

    struct segment_command_64 *text = put_seg(p, "__TEXT", TEXT_VMADDR, 0x1000, 0, 0x1000, 1);
    put_sect(text, 0, "__text", "__TEXT", TEXT_VMADDR + SECT_OFF, 4, SECT_OFF, 0);
    p += text->cmdsize; ncmds++;

    struct segment_command_64 *data = put_seg(p, "__DATA", TEXT_VMADDR + DATA_OFF, DATA_SIZE,
                                              DATA_OFF, DATA_SIZE, 1);
    put_sect(data, 0, "__data", "__DATA", TEXT_VMADDR + DATA_OFF, DATA_SIZE, DATA_OFF, 0);
    p += data->cmdsize; ncmds++;

    struct segment_command_64 *le = put_seg(p, "__LINKEDIT", TEXT_VMADDR + LE_OFF, LE_SIZE,
                                            LE_OFF, LE_SIZE, 0);
    p += le->cmdsize; ncmds++;

    struct linkedit_data_command *cf = (struct linkedit_data_command *)p;
    cf->cmd = LC_DYLD_CHAINED_FIXUPS; cf->cmdsize = sizeof *cf;
    cf->dataoff = LE_OFF; cf->datasize = CH_FIXUPS_SIZE;
    p += cf->cmdsize; ncmds++;

    struct linkedit_data_command *tr = (struct linkedit_data_command *)p;
    tr->cmd = LC_DYLD_EXPORTS_TRIE; tr->cmdsize = sizeof *tr;
    tr->dataoff = LE_OFF + CH_FIXUPS_SIZE; tr->datasize = CH_TRIE_SIZE;
    p += tr->cmdsize; ncmds++;

    struct linkedit_data_command *fs = (struct linkedit_data_command *)p;
    fs->cmd = LC_FUNCTION_STARTS; fs->cmdsize = sizeof *fs;
    fs->dataoff = CH_FS_OFF; fs->datasize = FS_SIZE;
    p += fs->cmdsize; ncmds++;

    /* LC_BUILD_VERSION by hand: 10.9's <mach-o/loader.h> has no
     * build_version_command struct, only the command number mach_compat.h
     * supplies. cmd, cmdsize, platform, minos, sdk, ntools. */
    uint32_t *bv = (uint32_t *)p;
    bv[0] = LC_BUILD_VERSION; bv[1] = 24; bv[2] = 1;
    bv[3] = 0x000C0000; bv[4] = 0x000C0000; bv[5] = 0;
    p += 24; ncmds++;

    h->ncmds = ncmds;
    h->sizeofcmds = (uint32_t)(p - (buf + sizeof *h));

    /* The chain in __DATA. Pointer format 6 (DYLD_CHAINED_PTR_64_OFFSET): bit
     * 63 selects bind over rebase, bits [62:51] are the distance to the next
     * link in 4-byte strides, the low bits a base-relative target (rebase) or
     * an import ordinal (bind). */
    uint64_t *slot = (uint64_t *)(buf + DATA_OFF);
    slot[0] = 0x1000ULL | ((uint64_t)(8 / 4) << 51);
    slot[1] = (1ULL << 63);            /* bind import 0, end of chain */

    /* The fixups blob: header, starts-image, one starts-segment for __DATA
     * (segment index 1), one import, one symbol name. */
    uint8_t *fx = buf + LE_OFF;
    uint32_t *fh = (uint32_t *)fx;
    fh[0] = 0;      /* fixups_version */
    fh[1] = 0x20;   /* starts_offset */
    fh[2] = 0x60;   /* imports_offset */
    fh[3] = 0x80;   /* symbols_offset */
    fh[4] = 1;      /* imports_count */
    fh[5] = 1;      /* imports_format: DYLD_CHAINED_IMPORT */
    fh[6] = 0;      /* symbols_format: uncompressed */

    uint32_t *starts = (uint32_t *)(fx + 0x20);
    starts[0] = 3;      /* seg_count: __TEXT, __DATA, __LINKEDIT */
    starts[1] = 0;      /* __TEXT: no fixups */
    starts[2] = 0x10;   /* __DATA: its starts-segment, relative to starts */
    starts[3] = 0;      /* __LINKEDIT: no fixups */

    uint8_t *ss = fx + 0x30;
    *(uint32_t *)(ss + 0)  = 24;       /* size */
    *(uint16_t *)(ss + 4)  = 0x1000;   /* page_size */
    *(uint16_t *)(ss + 6)  = 6;        /* pointer_format */
    *(uint64_t *)(ss + 8)  = DATA_OFF; /* segment_offset */
    *(uint32_t *)(ss + 16) = 0;        /* max_valid_pointer */
    *(uint16_t *)(ss + 20) = 1;        /* page_count */
    *(uint16_t *)(ss + 22) = 0;        /* page_start[0]: chain at +0 */

    *(uint32_t *)(fx + 0x60) = 1u;     /* import 0, library ordinal 1 */
    memcpy(fx + 0x80, "_diff_sym", sizeof "_diff_sym");

    /* One function start at base + 0x400, as build_plain's. */
    buf[CH_FS_OFF] = 0x80; buf[CH_FS_OFF + 1] = 0x08;
    *outlen = fsize;
    return buf;
}

static uint8_t *build_fixture(int which, size_t *len) {
    switch (which) {
    case F_PLAIN:       return build_plain(0, len);
    case F_DYLD_INFO:   return build_plain(P_DYLD_INFO, len);
    case F_NOFUNCS:     return build_plain(P_DYLD_INFO | P_NO_FUNCS, len);
    case F_ALREADY_109: return build_plain(P_VERSION_MIN, len);
    case F_DATACONST:   return build_plain(P_VERSION_MIN | P_DATACONST, len);
    case F_GROWABLE:    return build_growable(len);
    case F_CHAINED:     return build_chained(len);
    default:            return NULL;
    }
}

/* A fat container of `n` slices at 0x1000-aligned offsets, big-endian as every
 * real one is; ct/cs label the fat_arch entry, which is what `edit` reads, so
 * an x86_64 image can stand in for arm64 without its own header saying so.
 * Same construction as tests/edit_test.c's build_fat. */
static uint8_t *build_fat(int n, uint8_t *const *slice, const size_t *len,
                          const uint32_t *ct, const uint32_t *cs, size_t *outlen) {
    size_t off[4], total = 0x1000;
    for (int i = 0; i < n; i++) { off[i] = total; total += (len[i] + 0xfff) & ~(size_t)0xfff; }
    uint8_t *buf = (uint8_t *)calloc(1, total);
    struct fat_header *fh = (struct fat_header *)buf;
    fh->magic = OSSwapHostToBigInt32(FAT_MAGIC);
    fh->nfat_arch = OSSwapHostToBigInt32((uint32_t)n);
    struct fat_arch *fa = (struct fat_arch *)(fh + 1);
    for (int i = 0; i < n; i++) {
        fa[i].cputype    = (cpu_type_t)OSSwapHostToBigInt32(ct[i]);
        fa[i].cpusubtype = (cpu_subtype_t)OSSwapHostToBigInt32(cs[i]);
        fa[i].offset     = OSSwapHostToBigInt32((uint32_t)off[i]);
        fa[i].size       = OSSwapHostToBigInt32((uint32_t)len[i]);
        fa[i].align      = OSSwapHostToBigInt32(12);
        memcpy(buf + off[i], slice[i], len[i]);
    }
    *outlen = total;
    return buf;
}

/* Two slices of the same fixture, so a shape's `fat` column asks the same
 * question of a container that its thin twin asks of one image. */
static uint8_t *build_fat_fixture(int which, size_t *len) {
    size_t alen = 0, blen = 0;
    uint8_t *a = build_fixture(which, &alen);
    uint8_t *b = build_fixture(which, &blen);
    uint8_t *slices[2]; size_t lens[2];
    uint32_t ct[2], cs[2];
    if (!a || !b) { free(a); free(b); return NULL; }
    slices[0] = a; lens[0] = alen;
    slices[1] = b; lens[1] = blen;
    ct[0] = (uint32_t)CPU_TYPE_X86_64; cs[0] = (uint32_t)CPU_SUBTYPE_X86_64_ALL;
    ct[1] = (uint32_t)CPU_TYPE_ARM64;  cs[1] = 0;
    uint8_t *fat = build_fat(2, slices, lens, ct, cs, len);
    free(a); free(b);
    return fat;
}

/* ---- scratch files and the captured report ----------------------------- */

static char g_dir[256];

static void fresh_dir(void) {
    const char *tmp = getenv("TMPDIR");
    snprintf(g_dir, sizeof g_dir, "%s/rename_only_diff.XXXXXX", (tmp && *tmp) ? tmp : "/tmp");
    if (!mkdtemp(g_dir)) { perror("mkdtemp"); exit(2); }
}

static void rm_dir(void) {
    DIR *d = opendir(g_dir);
    struct dirent *e;
    char p[512];
    if (!d) return;
    while ((e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
        snprintf(p, sizeof p, "%s/%s", g_dir, e->d_name);
        unlink(p);
    }
    closedir(d);
    rmdir(g_dir);
}

static void write_file(const char *path, const uint8_t *buf, size_t len) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0755);
    if (fd < 0 || write(fd, buf, len) != (ssize_t)len) { perror(path); exit(2); }
    close(fd);
}

static uint8_t *read_file(const char *path, size_t *len) {
    struct stat st;
    if (stat(path, &st) != 0) return NULL;
    uint8_t *buf = (uint8_t *)malloc((size_t)st.st_size + 1);
    int fd = open(path, O_RDONLY);
    if (!buf || fd < 0 || read(fd, buf, (size_t)st.st_size) != (ssize_t)st.st_size) {
        perror(path); exit(2);
    }
    close(fd);
    buf[st.st_size] = 0;
    *len = (size_t)st.st_size;
    return buf;
}

/* me_run's report goes to a FILE*, but a grow's and an operation's own lines
 * go to stdout and stderr. All three are part of "what the run did", so both
 * descriptors are redirected into one file and me_opts.log is stdout -- me_say
 * flushes stdout before each line it writes (src/edit.h), so the one stream
 * stays in order. */
static int cap_out = -1, cap_err = -1;

static void cap_begin(const char *path) {
    fflush(stdout); fflush(stderr);
    cap_out = dup(1);
    cap_err = dup(2);
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (cap_out < 0 || cap_err < 0 || fd < 0) { perror("capture"); exit(2); }
    dup2(fd, 1);
    dup2(fd, 2);
    close(fd);
}

static void cap_end(void) {
    fflush(stdout); fflush(stderr);
    dup2(cap_out, 1); close(cap_out); cap_out = -1;
    dup2(cap_err, 2); close(cap_err); cap_err = -1;
}

/* ---- reading the run's own report back --------------------------------- */

/* One statement the run executed: a statement the script wrote, or one a
 * `target` line derived. Operands are copied because a derived statement's
 * come out of the report text, which is freed. */
#define MAX_EXEC  16
#define EXEC_ARG  128
typedef struct { int kind, op; int has_a, has_b; char a[EXEC_ARG], b[EXEC_ARG]; } exec_stmt;

/* What a run REPORTED it did, beyond what the script declared.
 *
 * A derived statement's report line is me_log_derived's: four spaces, the
 * kind, the op, its operands, then the finding in parentheses. Mapping those
 * two words back through ms_table_row is what keeps this file from naming a
 * disturbs mask of its own -- there is one table, and this reads it. The
 * operands are split on single spaces, which is exact for every operand these
 * fixtures produce (no path here contains one) and is the only place this
 * reader could be fooled. */
typedef struct { unsigned mask; int grew; int n; exec_stmt d[MAX_EXEC]; } observed;

/* Copies the `i`-th space-separated word of `text` (length `len`) into `out`.
 * Returns 1 if there was one. */
static int word(const char *text, size_t len, int i, char *out, size_t outsz) {
    size_t p = 0;
    for (;;) {
        while (p < len && text[p] == ' ') p++;
        if (p >= len) return 0;
        size_t s = p;
        while (p < len && text[p] != ' ') p++;
        if (i-- == 0) {
            size_t n = p - s;
            if (n >= outsz) n = outsz - 1;
            memcpy(out, text + s, n);
            out[n] = 0;
            return 1;
        }
    }
}

static observed observe(const char *report) {
    observed o;
    const char *line = report;
    memset(&o, 0, sizeof o);

    if (strstr(report, "growing header...") || strstr(report, "grew header pad:")) {
        /* A grow re-bases the image and bumps every __LINKEDIT file offset --
         * whichever statement asked for it. */
        o.grew = 1;
        o.mask |= MREL_BASE_REL | MREL_FILE_OFF;
    }

    while (*line) {
        const char *end = strchr(line, '\n');
        size_t len = end ? (size_t)(end - line) : strlen(line);
        if (len > 5 && strncmp(line, "    ", 4) == 0 && line[4] != ' ') {
            const char *kind, *op, *flag;
            int i, nargs, kenum = 0, oenum = 0;
            unsigned modes, disturbs;
            for (i = 0; ms_table_row(i, &kind, &op, &nargs, &flag, &modes, &disturbs); i++) {
                size_t kl = strlen(kind), ol = strlen(op);
                if (4 + kl + 1 + ol > len) continue;
                if (strncmp(line + 4, kind, kl) != 0 || line[4 + kl] != ' ') continue;
                if (strncmp(line + 4 + kl + 1, op, ol) != 0) continue;
                o.mask |= disturbs;
                /* The enums, from the same table, by name: ms_kind_name and
                 * ms_op_name are what printed the line, so this reverses
                 * exactly the mapping that produced it rather than a second
                 * copy of it. */
                for (kenum = 0; kenum < 16; kenum++)
                    if (strcmp(ms_kind_name(kenum), kind) == 0) break;
                for (oenum = 0; oenum < 16; oenum++)
                    if (strcmp(ms_op_name(oenum), op) == 0) break;
                if (o.n < MAX_EXEC) {
                    exec_stmt *d = &o.d[o.n++];
                    memset(d, 0, sizeof *d);
                    d->kind = kenum; d->op = oenum;
                    /* The operands lie between the op and the "  (finding)". */
                    size_t s = 4 + kl + 1 + ol;
                    const char *par = strstr(line + s, "  (");
                    size_t alen = par && (size_t)(par - line) <= len
                                ? (size_t)(par - line) - s : len - s;
                    d->has_a = word(line + s, alen, 0, d->a, sizeof d->a);
                    d->has_b = word(line + s, alen, 1, d->b, sizeof d->b);
                }
                break;
            }
        }
        if (!end) break;
        line = end + 1;
    }
    return o;
}

/* ---- the mr_ops one statement lowers to -------------------------------- */

/* Storage for one statement's mr_ops and everything it points at. */
typedef struct {
    mr_ops         ops;
    mr_change      change;
    const char    *one;
    uint32_t       strip;
    int            renamed;
    mr_renumbering renum;
} stmt_ops;

/* A TRANSCRIPTION of src/edit.c's me_apply switch -- the lowering that ships,
 * one statement to one mr_ops -- kept honest by pin_the_lowering below.
 * Returns 1 when this statement lowers to an mr_ops (and so reaches
 * mr_is_rename_only, through mr_apply_image -> mr_process_thin), 0 when it
 * does not: `version-min set`, `swift-abi set` and `fixups set classic` call
 * their own cores directly, and `target` is expanded rather than lowered.
 *
 * The two subtleties are the ones a careless transcription gets wrong, and
 * both are pinned: fatal_unmatched is set for EVERY statement, before the
 * switch, while allow_grow is set ONLY in the dylib/rpath case -- setting it
 * on a segment rename would switch off mr_is_rename_only's own scoping, which
 * me_apply's comment says in so many words. */
static int lower_one(const ms_script *s, const exec_stmt *st, stmt_ops *o) {
    memset(o, 0, sizeof *o);
    o->ops.fatal_unmatched = s->fatal_warnings;

    switch (st->kind) {
    case MS_LOAD_COMMAND:
        if (st->op != MS_DELETE || !st->has_a) return 0;
        if (lc_kind_by_name(st->a, &o->strip) != 0) return 0;
        o->ops.strip_cmds = &o->strip;
        o->ops.n_strip_cmds = 1;
        return 1;

    case MS_SEGMENT:
        o->ops.segment_rename_old = st->has_a ? st->a : NULL;
        o->ops.segment_rename_new = st->has_b ? st->b : NULL;
        o->ops.segment_renamed = &o->renamed;
        return 1;

    case MS_DYLIB:
    case MS_RPATH: {
        int rpath = (st->kind == MS_RPATH);
        o->one = st->a;
        switch (st->op) {
        case MS_REPLACE:  o->change.old_path = st->a; o->change.new_path = st->b; break;
        case MS_DELETE:   o->change.old_path = st->a; o->change.new_path = NULL;  break;
        case MS_REEXPORT: if (rpath) return 0;
                          o->change.old_path = st->a; o->change.new_path = "";
                          o->change.reexport = 1; break;
        case MS_APPEND:
            if (rpath) { o->ops.rpath_appends = &o->one; o->ops.n_rpath_appends = 1; }
            else       { o->ops.dylib_appends = &o->one; o->ops.n_dylib_appends = 1; }
            break;
        case MS_INSERT:
            if (rpath) { o->ops.rpath_inserts = &o->one; o->ops.n_rpath_inserts = 1; }
            else       { o->ops.dylib_inserts = &o->one; o->ops.n_dylib_inserts = 1; }
            break;
        default: return 0;
        }
        if (o->change.old_path) {
            if (rpath) { o->ops.rpath_changes = &o->change; o->ops.n_rpath_changes = 1; }
            else       { o->ops.dylib_changes = &o->change; o->ops.n_dylib_changes = 1; }
        }
        o->ops.allow_grow = s->allow_grow;
        if (!rpath) o->ops.renumbering = &o->renum;
        return 1;
    }

    default:
        return 0;   /* version-min, swift-abi, fixups, target */
    }
}

/* One statement's mr_ops as a string: only what is set, in a fixed order, so a
 * row can state the operation set it means and a lowering that built something
 * else is caught by name rather than by an exit code. */
static void render_ops(const mr_ops *p, char *out, size_t outsz) {
    size_t n = 0;
    out[0] = 0;
    struct { const char *name; int count; } f[] = {
        { "rename",        p->segment_rename_old != NULL },
        { "dylib_changes", p->n_dylib_changes },
        { "dylib_appends", p->n_dylib_appends },
        { "dylib_inserts", p->n_dylib_inserts },
        { "rpath_changes", p->n_rpath_changes },
        { "rpath_appends", p->n_rpath_appends },
        { "rpath_inserts", p->n_rpath_inserts },
        { "strip_cmds",    p->n_strip_cmds },
        { "allow-grow",    p->allow_grow },
    };
    int nf = (int)(sizeof f / sizeof f[0]);
    for (int i = 0; i < nf; i++) {
        if (!f[i].count) continue;
        if (out[0]) n += (size_t)snprintf(out + n, outsz - n, ",");
        /* "rename" and "allow-grow" are present-or-absent; the rest count. */
        if (i == 0 || i == nf - 1) n += (size_t)snprintf(out + n, outsz - n, "%s", f[i].name);
        else n += (size_t)snprintf(out + n, outsz - n, "%s=%d", f[i].name, f[i].count);
        if (n >= outsz) return;
    }
}

/* ---- the transcription, pinned to the lowering that ships --------------- */

/* Which mr_ops field src/edit.c's me_apply assigns under which `case`. This is
 * lower_one's contract, written where a reader of either can check it, and
 * pin_the_lowering reads the shipping file and asserts it.
 *
 * What it rules out is drift, which a differential harness is uniquely bad at
 * noticing on its own: me_apply gains an `ops.allow_grow` under MS_SEGMENT, or
 * lowers a new mr_ops field, or stops lowering one, and this file keeps
 * answering "old" about an mr_ops the shipping code no longer builds -- green
 * either way, which is the exact failure mode this whole item exists to
 * remove. */
static const struct { const char *region; const char *field; } LOWERING[] = {
    { "before the switch, for every statement", "fatal_unmatched" },
    { "case MS_LOAD_COMMAND",  "strip_cmds" },
    { "case MS_LOAD_COMMAND",  "n_strip_cmds" },
    { "case MS_SEGMENT",       "segment_rename_old" },
    { "case MS_SEGMENT",       "segment_rename_new" },
    { "case MS_SEGMENT",       "segment_renamed" },
    { "case MS_DYLIB/MS_RPATH", "rpath_appends" },
    { "case MS_DYLIB/MS_RPATH", "n_rpath_appends" },
    { "case MS_DYLIB/MS_RPATH", "dylib_appends" },
    { "case MS_DYLIB/MS_RPATH", "n_dylib_appends" },
    { "case MS_DYLIB/MS_RPATH", "rpath_inserts" },
    { "case MS_DYLIB/MS_RPATH", "n_rpath_inserts" },
    { "case MS_DYLIB/MS_RPATH", "dylib_inserts" },
    { "case MS_DYLIB/MS_RPATH", "n_dylib_inserts" },
    { "case MS_DYLIB/MS_RPATH", "rpath_changes" },
    { "case MS_DYLIB/MS_RPATH", "n_rpath_changes" },
    { "case MS_DYLIB/MS_RPATH", "dylib_changes" },
    { "case MS_DYLIB/MS_RPATH", "n_dylib_changes" },
    { "case MS_DYLIB/MS_RPATH", "allow_grow" },
    { "case MS_DYLIB/MS_RPATH", "renumbering" },
};
#define N_LOWERING ((int)(sizeof LOWERING / sizeof LOWERING[0]))

/* The `case` labels, in the order me_apply writes them. MS_RPATH falls THROUGH
 * into MS_DYLIB's block and so opens no region of its own; the three after it
 * open regions that must stay empty, which is what the OLD_NA rows rest on. */
static const char *const LOWER_CASES[] = {
    "case MS_LOAD_COMMAND:", "case MS_SEGMENT:", "case MS_DYLIB:",
    "case MS_VERSION_MIN:", "case MS_SWIFT_ABI:", "case MS_FIXUPS:"
};
static const char *const LOWER_REGION[] = {
    "before the switch, for every statement",
    "case MS_LOAD_COMMAND", "case MS_SEGMENT", "case MS_DYLIB/MS_RPATH",
    "case MS_VERSION_MIN", "case MS_SWIFT_ABI", "case MS_FIXUPS"
};
#define N_LOWER_CASES ((int)(sizeof LOWER_CASES / sizeof LOWER_CASES[0]))

static void pin_the_lowering(void) {
    size_t len = 0;
    uint8_t *src = read_file("src/edit.c", &len);
    int seen[N_LOWERING];
    size_t bound[N_LOWER_CASES];
    memset(seen, 0, sizeof seen);

    if (!src) {
        CHECK(0, "src/edit.c could not be read, so the lowering this file transcribes is "
                 "unpinned: me_apply could lower a different mr_ops than lower_one builds "
                 "and every row here would keep passing. Run this test from the repository "
                 "root (ctest does)");
        return;
    }
    const char *text = (const char *)src;
    const char *body = strstr(text, "static int me_apply(");
    const char *end  = body ? strstr(body, "\nunknown:") : NULL;
    if (!body || !end) {
        CHECK(0, "src/edit.c no longer contains a me_apply whose body ends at `unknown:`, "
                 "so this pin cannot find the lowering it exists to check. Re-read me_apply "
                 "and this file's LOWERING table together before changing either");
        free(src);
        return;
    }

    for (int c = 0; c < N_LOWER_CASES; c++) {
        const char *at = strstr(body, LOWER_CASES[c]);
        if (!at || at > end) {
            CHECK(0, "src/edit.c's me_apply has no `%s`, so this pin cannot say which "
                     "region an mr_ops assignment falls in -- and the OLD_NA rows rest on "
                     "the last three regions being empty", LOWER_CASES[c]);
            free(src);
            return;
        }
        bound[c] = (size_t)(at - body);
    }

    for (const char *p = body; (p = strstr(p, "ops.")) != NULL && p < end; ) {
        /* Only an assignment: `ops.field =`, never `==` and never a read. */
        const char *id = p + 4;
        const char *q = id;
        while ((*q >= 'a' && *q <= 'z') || (*q >= 'A' && *q <= 'Z') ||
               (*q >= '0' && *q <= '9') || *q == '_') q++;
        const char *eq = q;
        while (*eq == ' ') eq++;
        if (q == id || *eq != '=' || eq[1] == '=') { p = q; continue; }
        /* `->ops.` and `v->ops.` are not this local; only a bare `ops.` is. */
        if (p > body && (p[-1] == '>' || p[-1] == '_' ||
                         (p[-1] >= 'a' && p[-1] <= 'z'))) { p = q; continue; }

        char field[64];
        size_t fl = (size_t)(q - id);
        if (fl >= sizeof field) fl = sizeof field - 1;
        memcpy(field, id, fl); field[fl] = 0;

        size_t off = (size_t)(p - body);
        int region = 0;
        for (int c = 0; c < N_LOWER_CASES; c++) if (off > bound[c]) region = c + 1;

        int found = -1;
        for (int i = 0; i < N_LOWERING; i++)
            if (strcmp(LOWERING[i].field, field) == 0 &&
                strcmp(LOWERING[i].region, LOWER_REGION[region]) == 0) { found = i; break; }
        CHECK(found >= 0,
              "src/edit.c's me_apply assigns ops.%s under %s, which this file's transcription "
              "(lower_one) does not. The `old` column here is then an answer about an mr_ops "
              "the shipping lowering no longer builds -- it would keep agreeing with the "
              "design's table while describing nothing. Update lower_one and the LOWERING "
              "table together, then re-run", field, LOWER_REGION[region]);
        if (found >= 0) seen[found] = 1;
        p = q;
    }

    for (int i = 0; i < N_LOWERING; i++)
        CHECK(seen[i],
              "src/edit.c's me_apply no longer assigns ops.%s under %s, but this file's "
              "transcription (lower_one) still does. Every `old` answer that depends on that "
              "field is then about an operation set no run builds", LOWERING[i].field,
              LOWERING[i].region);
    free(src);
}

/* ---- one shape ---------------------------------------------------------- */

static const char *old_name(int v) {
    return v == OLD_RUNS ? "runs" : v == OLD_SKIPS ? "skips" : "not applicable (no mr_ops)";
}

/* Evaluates the derivation on one slice of the written result, asserting the
 * liveness the shape declares on the way. `what` names the slice for a FAIL. */
static int new_answer(const char *shape, const char *what, uint8_t *buf, size_t len,
                      unsigned disturbed, int funcs_live, unsigned *out_live) {
    mi_image im;
    if (mi_wrap(buf, len, &im) != 0) {
        CHECK(0, "%s: %s of the written image will not re-open, so the derivation could not "
                 "be evaluated against what the gate would actually see", shape, what);
        return -1;
    }
    unsigned live = mrel_live(&im);
    if (out_live) *out_live = live;
    CHECK(((live & MREL_FUNC_START) != 0) == (funcs_live != 0),
          "%s: %s %s a live LC_FUNCTION_STARTS and the shape says it %s. That bit decides "
          "half of mrel_verify_applies: with it clear the gate is skipped whatever the run "
          "disturbed, so a row that lost it by accident would read as an expected skip while "
          "proving nothing, and a row that gained one would stop testing the liveness half "
          "at all", shape, what, (live & MREL_FUNC_START) ? "has" : "has no",
          funcs_live ? "must" : "must not");
    int skips = !mrel_verify_applies(&im, disturbed);
    mi_close(&im);
    return skips;
}

static void run_shape(int row) {
    const char *shape = EXPECTED[row].shape;
    char in[512], out[512], rep[512], fp[512], seg[128];
    size_t len = 0;

    CHECK(strcmp(SHAPES[row].shape, shape) == 0,
          "shape table row %d is '%s' but the expected-difference list row %d is '%s' -- "
          "the two lists have drifted, so the harness is not testing the shapes the "
          "design enumerated", row, SHAPES[row].shape, row, shape);
    if (strcmp(SHAPES[row].shape, shape) != 0) return;

    snprintf(in,  sizeof in,  "%s/in.%d", g_dir, row);
    snprintf(out, sizeof out, "%s/out.%d", g_dir, row);
    snprintf(rep, sizeof rep, "%s/report.%d", g_dir, row);

    uint8_t *img = SHAPES[row].fat ? build_fat_fixture(SHAPES[row].fixture, &len)
                                   : build_fixture(SHAPES[row].fixture, &len);
    if (!img) { CHECK(0, "%s: no fixture builder", shape); return; }
    write_file(in, img, len);
    free(img);

    ms_script script;
    char err[256] = "";
    if (ms_parse(SHAPES[row].script, strlen(SHAPES[row].script), &script, err, sizeof err) != 0) {
        CHECK(0, "%s: its own script does not parse (%s), so neither column could be "
                 "computed for a shape the design says must be compared", shape, err);
        return;
    }

    /* ---- the run, and what it reported doing ---------------------------- */
    me_opts o;
    o.log = stdout;
    cap_begin(rep);
    int rc = me_run(in, out, &script, &o);
    cap_end();

    size_t replen = 0;
    uint8_t *report = read_file(rep, &replen);
    const char *text = report ? (const char *)report : "";

    CHECK(rc == 0, "%s: the run itself did not succeed (rc %d), so `disturbed` is not an "
                   "observation of anything and the row proves nothing. Report:\n%s",
          shape, rc, text);

    observed ob = observe(text);
    unsigned declared = me_followups(&script);
    unsigned disturbed = declared | ob.mask;

    CHECK(ob.grew == SHAPES[row].grows,
          "%s: the report %s a header grow and the shape says it %s. A grow is what puts "
          "MREL_BASE_REL into `disturbed` without any statement declaring it, so reading it "
          "wrong is how this harness would skip the gate on the runs that most need it. "
          "Report:\n%s",
          shape, ob.grew ? "shows" : "shows no", SHAPES[row].grows ? "does" : "does not", text);
    CHECK((ob.n > 0) == (SHAPES[row].derives != 0),
          "%s: the report shows %d derived statement(s) and the shape says it %s derive. "
          "A `target` line declares MREL_NONE and disturbs only through its expansion, so "
          "an unread expansion is an unnoticed disturbance -- and an unread one that lowers "
          "to an mr_ops is an `old` answer reported as OLD_NA. Report:\n%s",
          shape, ob.n, SHAPES[row].derives ? "does" : "does not", text);

    /* ---- new: the derivation, per slice on a fat input ------------------ */
    size_t olen = 0;
    uint8_t *obuf = read_file(out, &olen);
    unsigned live = MREL_NONE;
    int new_skips = -1;
    if (!obuf) {
        CHECK(0, "%s: nothing was written, so the derivation has no result image to be "
                 "evaluated against", shape);
    } else if (!SHAPES[row].fat) {
        new_skips = new_answer(shape, "the image", obuf, olen, disturbed,
                               SHAPES[row].funcs_live, &live);
    } else {
        /* Decision 6: once per slice, never once for the container. Every
         * slice must give the row's answer, and each is asserted by itself. */
        struct fat_header *fh = (struct fat_header *)obuf;
        uint32_t n = olen >= sizeof *fh ? OSSwapBigToHostInt32(fh->nfat_arch) : 0;
        struct fat_arch *fa = (struct fat_arch *)(fh + 1);
        uint32_t evaluated = 0;
        CHECK(n == 2, "%s: the output container has %u slices, not the 2 that went in",
              shape, n);
        for (uint32_t i = 0; i < n && i < 2; i++) {
            char what[32];
            uint32_t soff = OSSwapBigToHostInt32(fa[i].offset);
            uint32_t ssz  = OSSwapBigToHostInt32(fa[i].size);
            snprintf(what, sizeof what, "slice %u", i);
            if ((size_t)soff + ssz > olen) {
                CHECK(0, "%s: %s lies outside the container", shape, what);
                continue;
            }
            int s = new_answer(shape, what, obuf + soff, ssz, disturbed,
                               SHAPES[row].funcs_live, i == 0 ? &live : NULL);
            CHECK(s == EXPECTED[row].new_skips,
                  "%s: %s says %s the gate and the difference list says %s. Applicability is "
                  "derived per slice (Decision 6), so a container's slices are not allowed to "
                  "inherit an answer -- each one either has something to check or does not",
                  shape, what, s ? "skip" : "run",
                  EXPECTED[row].new_skips ? "skip" : "run");
            if (i == 0) new_skips = s;
            evaluated++;
        }
        CHECK(evaluated == n,
              "%s: %u of the container's %u slices were evaluated. A row that stops at the "
              "first slice tests a container the way a thin file is tested, which is the one "
              "thing Decision 6 says cannot be done -- and it would look green",
              shape, evaluated, n);
    }
    free(obuf);

    /* ---- old: the hand-written predicate, per executed statement -------- */
    exec_stmt exec[MAX_EXEC];
    int nexec = 0;
    for (int i = 0; i < script.n && nexec < MAX_EXEC; i++) {
        const ms_stmt *st = &script.stmts[i];
        if (st->kind == MS_TARGET) {
            /* `target` lowers to nothing itself: what ran is its expansion,
             * which the report named. */
            for (int j = 0; j < ob.n && nexec < MAX_EXEC; j++) exec[nexec++] = ob.d[j];
            continue;
        }
        exec_stmt *e = &exec[nexec++];
        memset(e, 0, sizeof *e);
        e->kind = st->kind; e->op = st->op;
        if (st->a) { e->has_a = 1; snprintf(e->a, sizeof e->a, "%s", st->a); }
        if (st->b) { e->has_b = 1; snprintf(e->b, sizeof e->b, "%s", st->b); }
    }

    int any = 0, all_rename_only = 1;
    fp[0] = 0;
    for (int i = 0; i < nexec; i++) {
        stmt_ops so;
        int has = lower_one(&script, &exec[i], &so);
        if (has) {
            any = 1;
            if (!mr_is_rename_only(&so.ops)) all_rename_only = 0;
            render_ops(&so.ops, seg, sizeof seg);
        } else {
            snprintf(seg, sizeof seg, "-");
        }
        size_t at = strlen(fp);
        snprintf(fp + at, sizeof fp - at, "%s%s", at ? " | " : "", seg);
    }
    int old = !any ? OLD_NA : (all_rename_only ? OLD_SKIPS : OLD_RUNS);

    CHECK(strcmp(fp, SHAPES[row].lowering) == 0,
          "%s: its statements lower to {%s}, but the shape says {%s}. mr_is_rename_only reads "
          "nothing but these fields, so a lowering that does not describe the run makes the "
          "whole `old` column an answer about some other operation set: a lowering that built "
          "nothing would still read as \"runs\" for most of these rows, and a `target` whose "
          "expansion lowers one is not OLD_NA however much the row wants to be",
          shape, fp, SHAPES[row].lowering);

    CHECK(old == EXPECTED[row].old,
          "%s: over the %d statement(s) this run executed, mr_is_rename_only %s, and the "
          "design's difference list says %s. The old predicate is still in control of the "
          "gate, so a disagreement here means the list does not describe the code that ships",
          shape, nexec, old_name(old), old_name(EXPECTED[row].old));

    CHECK(new_skips == EXPECTED[row].new_skips,
          "%s: the derivation says %s the gate (live=%#x disturbed=%#x, declared %#x plus "
          "%#x observed), and the design's difference list says %s. Do not adjust the list "
          "to match: it is what a reviewer weighed when agreeing to narrow mg_plausible's "
          "reach, and a differential test edited to fit its output is a rubber stamp",
          shape, new_skips ? "skip" : "run",
          live, disturbed, declared, ob.mask,
          EXPECTED[row].new_skips ? "skip" : "run");

    free(report);
    ms_free(&script);
}

/* ---- the fat container: per slice, never per container ------------------ */

/* Decision 6: mrel_verify_applies takes a SLICE. Row 22 already runs a whole
 * differential row on a container; this is the other half, the one a row
 * cannot express -- a container whose two slices MUST answer DIFFERENTLY.
 * Same file, same run, same disturbance: one slice has a live
 * LC_FUNCTION_STARTS and the other has none, so the gate applies to the first
 * and has nothing to check on the second. Any implementation that derived one
 * answer for the container would have to get one of the two wrong. */
static void run_fat(void) {
    char in[512], out[512], rep[512];
    size_t alen = 0, blen = 0, flen = 0;
    uint8_t *a = build_plain(P_DYLD_INFO, &alen);                /* funcs live */
    uint8_t *b = build_plain(P_DYLD_INFO | P_NO_FUNCS, &blen);   /* none */
    uint8_t *slices[2]; size_t lens[2];
    uint32_t ct[2], cs[2];
    slices[0] = a; lens[0] = alen; ct[0] = (uint32_t)CPU_TYPE_X86_64;
    cs[0] = (uint32_t)CPU_SUBTYPE_X86_64_ALL;
    slices[1] = b; lens[1] = blen; ct[1] = (uint32_t)CPU_TYPE_ARM64; cs[1] = 0;
    uint8_t *fat = build_fat(2, slices, lens, ct, cs, &flen);
    free(a); free(b);

    snprintf(in,  sizeof in,  "%s/fat.in", g_dir);
    snprintf(out, sizeof out, "%s/fat.out", g_dir);
    snprintf(rep, sizeof rep, "%s/fat.report", g_dir);
    write_file(in, fat, flen);
    free(fat);

    /* `fixups set classic` on a slice that is already classic: a pass-through
     * that still DECLARES MREL_BASE_REL, which is what makes the two slices
     * answer differently for a reason other than "nothing was disturbed". */
    const char *text = "fixups set classic\n";
    ms_script script;
    char err[256] = "";
    if (ms_parse(text, strlen(text), &script, err, sizeof err) != 0) {
        CHECK(0, "fat: script does not parse (%s)", err);
        return;
    }

    me_opts o;
    o.log = stdout;
    cap_begin(rep);
    int rc = me_run(in, out, &script, &o);
    cap_end();

    size_t replen = 0;
    uint8_t *report = read_file(rep, &replen);
    CHECK(rc == 0, "fat: the run did not succeed (rc %d), so there is no per-slice result "
                   "to evaluate. Report:\n%s", rc, report ? (char *)report : "");
    unsigned disturbed = me_followups(&script);
    ms_free(&script);
    free(report);

    size_t olen = 0;
    uint8_t *obuf = read_file(out, &olen);
    if (!obuf || olen < sizeof(struct fat_header)) {
        CHECK(0, "fat: no output container to slice");
        free(obuf);
        return;
    }
    struct fat_header *fh = (struct fat_header *)obuf;
    uint32_t n = OSSwapBigToHostInt32(fh->nfat_arch);
    CHECK(n == 2, "fat: the output has %u slices, not the 2 that went in", n);

    int answer[2] = { -1, -1 };
    struct fat_arch *fa = (struct fat_arch *)(fh + 1);
    for (uint32_t i = 0; i < n && i < 2; i++) {
        uint32_t soff = OSSwapBigToHostInt32(fa[i].offset);
        uint32_t ssz  = OSSwapBigToHostInt32(fa[i].size);
        mi_image im;
        if ((size_t)soff + ssz > olen || mi_wrap(obuf + soff, ssz, &im) != 0) {
            CHECK(0, "fat: slice %u will not re-open, so it has no per-slice answer", i);
            continue;
        }
        answer[i] = !mrel_verify_applies(&im, disturbed);
        CHECK(((mrel_live(&im) & MREL_FUNC_START) != 0) == (i == 0),
              "fat: slice %u's LC_FUNCTION_STARTS liveness is not what the fixture built "
              "(slice 0 has one, slice 1 has none). Without that difference the two slices "
              "cannot disagree and this block cannot tell a per-slice derivation from a "
              "per-container one", i);
        mi_close(&im);
    }
    free(obuf);

    CHECK(answer[0] == 0,
          "fat: slice 0 disturbed the image base and has function starts to check, so its "
          "own verify must RUN; it says %s. A container-level answer would have to take "
          "one slice's word for the other's", answer[0] ? "skip" : "run");
    CHECK(answer[1] == 1,
          "fat: slice 1 has no function starts, so its own verify has nothing to check and "
          "must be SKIPPED; it says %s. This is the half a container-level derivation gets "
          "wrong: a slice would run a check about a relation it does not have",
          answer[1] ? "skip" : "run");
    CHECK(answer[0] != answer[1],
          "fat: both slices of one run answered the same, so this container cannot "
          "distinguish a derivation evaluated per slice (Decision 6) from one evaluated "
          "once for the whole file");
}

/* ---- the harness is not a rubber stamp --------------------------------- */

/* The two columns must not be the same computation twice: the design's whole
 * claim is that the derived rule SKIPS CHECKS THE OLD RULE RAN, and a harness
 * in which no row differed would be asserting the opposite of the design
 * while looking green. */
static void check_the_lists_differ(void) {
    int narrowed = 0, agreed = 0, na = 0;
    for (int i = 0; i < N_EXPECTED; i++) {
        if (EXPECTED[i].old == OLD_RUNS && EXPECTED[i].new_skips) narrowed++;
        if (EXPECTED[i].old == OLD_SKIPS && EXPECTED[i].new_skips) agreed++;
        if (EXPECTED[i].old == OLD_NA) na++;
    }
    CHECK(narrowed > 0,
          "the difference list has no row where the old predicate ran and the derivation "
          "skips, so it is not describing the narrowing this design exists to make -- and "
          "a harness computing one predicate twice would pass it");
    CHECK(agreed > 0,
          "the difference list has no rename-only row, so nothing holds the design's one "
          "\"unchanged\" promise: that the shape the old predicate already skipped keeps "
          "being skipped");
    CHECK(na > 0,
          "the difference list has no OLD_NA row, so nothing holds the third state -- and "
          "a harness that silently answered \"runs\" for a gate that never ran would pass");
}

int main(void) {
    if ((int)(sizeof SHAPES / sizeof SHAPES[0]) != N_EXPECTED) {
        printf("FAIL: %d shapes for %d expected-difference rows\n",
               (int)(sizeof SHAPES / sizeof SHAPES[0]), N_EXPECTED);
        return 1;
    }
    fresh_dir();
    pin_the_lowering();
    check_the_lists_differ();
    for (int i = 0; i < N_EXPECTED; i++) run_shape(i);
    run_fat();
    rm_dir();
    if (fails) {
        printf("rename_only_differential: %d failure(s)\n", fails);
        return 1;
    }
    printf("rename_only_differential: %d shapes compared (one of them fat), plus a fat "
           "container whose slices must disagree\n", N_EXPECTED);
    return 0;
}
