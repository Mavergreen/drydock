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
 *   old:  mr_is_rename_only(ops) -- nonzero means "skip the gate". `ops` is
 *         the mr_ops the shape's statements lower to, built here the way
 *         cli/machotool.c's three mr_ops-building verbs build theirs (cmd_lc
 *         at :666, cmd_dylib_or_rpath at :751, cmd_segment at :945 -- the only
 *         three call sites of mr_apply_file, :719, :876 and :962).
 *
 *   new:  !mrel_verify_applies(slice, disturbed) -- nonzero means "skip".
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
 * is NOT enough and the two `target` rows are what prove it: `target 10.9`
 * declares MREL_NONE, and a harness fed the declaration alone would assert a
 * skip that the real run must not take.
 *
 * THE "old" COLUMN HAS THREE STATES. mr_is_rename_only takes an mr_ops, and
 * only load-command/segment/dylib/rpath work lowers to one. `swift-abi set`,
 * `version-min set`, `fixups set classic` and `target 10.9` never build an
 * mr_ops at all, so for those shapes there is no predicate to differ from and
 * OLD_NA says so. Calling mr_is_rename_only on a zeroed mr_ops and reporting
 * the answer as "old" is the one way this table could lie -- it would return
 * "runs" for a gate that never ran -- so which shapes are OLD_NA is DERIVED
 * from the parsed script (lower_to_ops below), not taken on trust from the row.
 *
 * RELATIONS ARE EVALUATED PER SLICE (Decision 6), so the fat block at the end
 * asserts per slice rather than once for the container -- on a container whose
 * two slices must get DIFFERENT answers from the same run, which is the only
 * shape of fixture a container-level implementation cannot fake.
 *
 * Build: ctest runs it as rename_only_differential. By hand, compile with
 * -Isrc together with every .c file under src/.
 */
#include "edit.h"
#include "image.h"
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
#define OLD_NA    2   /* no mr_ops exists for this shape */

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
    { "lc delete + dylib delete",      OLD_RUNS,  1 },  /* the union still moves no offset */
    { "segment rename + dylib append", OLD_RUNS,  1 },  /* not rename-only, so old ran */
    { "dylib append that GREW the pad", OLD_RUNS, 0 },  /* a grow disturbs the base */

    /* --- shapes no verb lowers to an mr_ops: "old" is not a thing --------- */
    { "swift-abi set alone",           OLD_NA,    1 },  /* cmd_retag_swift: no mr_ops */
    { "version-min set alone",         OLD_NA,    1 },  /* cmd_minos: no mr_ops */
    { "version-min set that GREW",     OLD_NA,    0 },  /* allow-grow reaches minos */
    { "fixups set classic",            OLD_NA,    0 },  /* cmd_declassify: no mr_ops */
    { "target 10.9 (nothing to do)",   OLD_NA,    1 },  /* empty expansion */
    { "target 10.9 (derives fixups)",  OLD_NA,    0 },  /* the expansion disturbs the base */
};
#define N_EXPECTED ((int)(sizeof EXPECTED / sizeof EXPECTED[0]))

/* ---- the shapes themselves ---------------------------------------------
 *
 * One row per EXPECTED row, in the same order, checked by name. `script` is
 * the edit script the shape IS -- the one input from which both columns are
 * derived, the ops included, so a row cannot describe one operation set to
 * mr_is_rename_only and another to the derivation.
 *
 * `ops_fingerprint` is the mr_ops that script must lower to, written out by
 * hand: without it, an ops builder that did nothing at all would still get
 * "runs" out of mr_is_rename_only (a zeroed mr_ops has no rename in it) and
 * thirteen of the fourteen defined rows would pass over an ops that described
 * nothing. NULL means "this shape builds no mr_ops", which is what makes the
 * row OLD_NA -- and that is cross-checked against the parsed script too.
 *
 * `grows` and `derives` are the run's own observations, asserted rather than
 * assumed: a positive control on the report reader for the three rows where it
 * must fire, and a negative control on the seventeen where it must not. */
enum { F_PLAIN, F_DYLD_INFO, F_ALREADY_109, F_GROWABLE, F_CHAINED };

static const struct {
    const char *shape;
    int         fixture;
    const char *script;
    const char *ops_fingerprint;
    int         grows;    /* the report must say the header grew */
    int         derives;  /* the report must show >= 1 derived statement */
} SHAPES[] = {
  { "segment rename alone", F_PLAIN,
    "segment rename __DATA __DATA_R9\n", "rename", 0, 0 },
  { "load-command delete alone", F_PLAIN,
    "load-command delete uuid\n", "strip_cmds=1", 0, 0 },
  { "dylib reexport alone", F_PLAIN,
    "dylib reexport /usr/lib/libSystem.B.dylib\n", "dylib_changes=1", 0, 0 },
  { "dylib append alone", F_PLAIN,
    "dylib append /usr/lib/libappended.dylib\n", "dylib_appends=1", 0, 0 },
  { "dylib replace alone", F_PLAIN,
    "dylib replace /usr/lib/libSystem.B.dylib /usr/lib/libOther.dylib\n",
    "dylib_changes=1", 0, 0 },
  { "dylib insert alone", F_PLAIN,
    "dylib insert /usr/lib/libinserted.dylib\n", "dylib_inserts=1", 0, 0 },
  { "dylib delete alone", F_PLAIN,
    "dylib delete /usr/lib/libSystem.B.dylib\n", "dylib_changes=1", 0, 0 },
  { "rpath append alone", F_PLAIN,
    "rpath append @loader_path/../appended\n", "rpath_appends=1", 0, 0 },
  { "rpath insert alone", F_PLAIN,
    "rpath insert @loader_path/../inserted\n", "rpath_inserts=1", 0, 0 },
  { "rpath replace alone", F_PLAIN,
    "rpath replace @loader_path/../lib @loader_path/../other\n",
    "rpath_changes=1", 0, 0 },
  { "rpath delete alone", F_PLAIN,
    "rpath delete @loader_path/../lib\n", "rpath_changes=1", 0, 0 },
  { "lc delete + dylib delete", F_PLAIN,
    "load-command delete uuid\ndylib delete /usr/lib/libSystem.B.dylib\n",
    "dylib_changes=1,strip_cmds=1", 0, 0 },
  { "segment rename + dylib append", F_PLAIN,
    "segment rename __DATA __DATA_R9\ndylib append /usr/lib/libappended.dylib\n",
    "rename,dylib_appends=1", 0, 0 },
  /* A path long enough that the new LC_LOAD_DYLIB cannot fit the growable
   * fixture's deliberately tiny header pad, so the run really grows. */
  { "dylib append that GREW the pad", F_GROWABLE,
    "allow-grow\ndylib append /usr/lib/"
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd.dylib\n",
    "dylib_appends=1,allow-grow", 1, 0 },

  { "swift-abi set alone", F_PLAIN, "swift-abi set legacy\n", NULL, 0, 0 },
  { "version-min set alone", F_PLAIN, "version-min set 10.9\n", NULL, 0, 0 },
  { "version-min set that GREW", F_GROWABLE,
    "allow-grow\nversion-min set 10.9\n", NULL, 1, 0 },
  { "fixups set classic", F_DYLD_INFO, "fixups set classic\n", NULL, 0, 0 },
  { "target 10.9 (nothing to do)", F_ALREADY_109, "target 10.9\n", NULL, 0, 0 },
  { "target 10.9 (derives fixups)", F_CHAINED, "target 10.9\n", NULL, 0, 1 },
};

/* ---- fixtures -----------------------------------------------------------
 *
 * Hand-built, for the reason tests/relations_test.c gives: liveness must not
 * depend on what the host linker chose to emit. Every fixture here has a LIVE
 * MREL_FUNC_START -- an LC_FUNCTION_STARTS with a blob that decodes -- and a
 * segment mapping the header. That is not decoration: with no function starts
 * mrel_verify_applies answers "skip" for every run, every `new_skips` in the
 * table reads 1 whatever the derivation does, and the six rows that carry the
 * design's real content become unfalsifiable. run_shape asserts the liveness
 * per shape so a fixture that quietly lost it cannot pass as a skip. */

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
#define P_NO_FUNCS    4   /* NO LC_FUNCTION_STARTS: the fat block's other slice */

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
 * section at 0x400, __DATA with two (the second an __init_offsets whose entry
 * names 0x400), __LINKEDIT, LC_UUID, and an LC_FUNCTION_STARTS declaring the
 * single function start base + 0x400 -- so the image is plausible and
 * MREL_FUNC_START is live. */
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

    struct segment_command_64 *data = put_seg(p, "__DATA", TEXT_VMADDR + DATA_OFF, DATA_SIZE,
                                              DATA_OFF, DATA_SIZE, 2);
    put_sect(data, 0, "__data", "__DATA", TEXT_VMADDR + DATA_OFF, 8, DATA_OFF, 0);
    put_sect(data, 1, "__init_offsets", "__DATA", TEXT_VMADDR + DATA_OFF + 0x800, 4,
             DATA_OFF + 0x800, S_INIT_FUNC_OFFSETS);
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
 * into. It carries an LC_FUNCTION_STARTS for this file's own reason (see the
 * fixtures comment): without one the two GREW rows could not tell a derivation
 * that reads the grow from one that ignores it. */
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

    /* One function start, at the section. ULEB128 of 0x428 is 0xa8 0x08; the
     * grow lowers the base, widening this leading delta, which mg_grow_header
     * refuses if it would need another byte -- two bytes cover up to 0x3fff. */
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
 * that derived statement is the only way a `target` line reaches MREL_BASE_REL.
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
    case F_ALREADY_109: return build_plain(P_VERSION_MIN, len);
    case F_GROWABLE:    return build_growable(len);
    case F_CHAINED:     return build_chained(len);
    default:            return NULL;
    }
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

/* What a run REPORTED it did, beyond what the script declared.
 *
 * A derived statement's report line is `me_log_derived`'s: four spaces, the
 * kind, the op, its operands, then the finding in parentheses. Mapping those
 * two words back through ms_table_row is what keeps this file from naming a
 * disturbs mask of its own -- there is one table, and this reads it. */
typedef struct { unsigned mask; int derived; int grew; } observed;

static observed observe(const char *report) {
    observed o = { MREL_NONE, 0, 0 };
    const char *line = report;

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
            int i, nargs;
            unsigned modes, disturbs;
            for (i = 0; ms_table_row(i, &kind, &op, &nargs, &flag, &modes, &disturbs); i++) {
                size_t kl = strlen(kind), ol = strlen(op);
                if (4 + kl + 1 + ol > len) continue;
                if (strncmp(line + 4, kind, kl) != 0 || line[4 + kl] != ' ') continue;
                if (strncmp(line + 4 + kl + 1, op, ol) != 0) continue;
                o.mask |= disturbs;
                o.derived++;
                break;
            }
        }
        if (!end) break;
        line = end + 1;
    }
    return o;
}

/* ---- the mr_ops a shape's statements lower to -------------------------- */

/* Storage for one shape's mr_ops and everything it points at. */
typedef struct {
    mr_ops   ops;
    mr_change dylib[MR_MAX_OPS], rpath[MR_MAX_OPS];
    const char *appends[MR_MAX_OPS], *inserts[MR_MAX_OPS];
    const char *rappends[MR_MAX_OPS], *rinserts[MR_MAX_OPS];
    uint32_t strip[MR_MAX_STRIP];
    int      renamed;
    mr_renumbering renum;
} shape_ops;

/* Lowers `s` the way the three mr_ops-building verbs do: cmd_lc fills
 * strip_cmds, cmd_dylib_or_rpath fills the four dylib and three rpath arrays
 * (a delete is a change with new_path NULL, a reexport one with ""), and
 * cmd_segment fills segment_rename_old/new and hands over the renamed count.
 * Returns 1 if any statement lowered to an mr_ops field -- which is exactly
 * what "this shape has an `old` answer at all" means -- and 0 if none did.
 *
 * Statement kinds no verb lowers to an mr_ops (version-min, swift-abi,
 * fixups, target) are counted, deliberately, as lowering to NOTHING: that is
 * the fact the OLD_NA rows rest on, and it is read off the script here rather
 * than trusted from the table. */
static int lower_to_ops(const ms_script *s, shape_ops *o) {
    memset(o, 0, sizeof *o);
    o->ops.dylib_changes = o->dylib;
    o->ops.dylib_appends = o->appends;
    o->ops.dylib_inserts = o->inserts;
    o->ops.rpath_changes = o->rpath;
    o->ops.rpath_appends = o->rappends;
    o->ops.rpath_inserts = o->rinserts;
    o->ops.strip_cmds = o->strip;
    o->ops.renumbering = &o->renum;
    o->ops.allow_grow = s->allow_grow;
    o->ops.fatal_unmatched = s->fatal_warnings;

    int any = 0;
    for (int i = 0; i < s->n; i++) {
        const ms_stmt *st = &s->stmts[i];
        if (st->kind == MS_LOAD_COMMAND && st->op == MS_DELETE) {
            /* The LC_* value is ml_kind_lookup's job in the real cmd_lc; which
             * command it is does not reach mr_is_rename_only, only the count
             * does, so the harness names it by the one it strips: LC_UUID. */
            o->strip[o->ops.n_strip_cmds++] = LC_UUID;
        } else if (st->kind == MS_SEGMENT && st->op == MS_RENAME) {
            o->ops.segment_rename_old = st->a;
            o->ops.segment_rename_new = st->b;
            o->ops.segment_renamed = &o->renamed;
        } else if (st->kind == MS_DYLIB || st->kind == MS_RPATH) {
            int rp = (st->kind == MS_RPATH);
            mr_change *ch = rp ? o->rpath : o->dylib;
            int *nch = rp ? &o->ops.n_rpath_changes : &o->ops.n_dylib_changes;
            switch (st->op) {
            case MS_APPEND:
                if (rp) o->rappends[o->ops.n_rpath_appends++] = st->a;
                else    o->appends[o->ops.n_dylib_appends++] = st->a;
                break;
            case MS_INSERT:
                if (rp) o->rinserts[o->ops.n_rpath_inserts++] = st->a;
                else    o->inserts[o->ops.n_dylib_inserts++] = st->a;
                break;
            case MS_REPLACE:
                ch[*nch].old_path = st->a; ch[*nch].new_path = st->b;
                ch[(*nch)++].reexport = 0;
                break;
            case MS_DELETE:
                ch[*nch].old_path = st->a; ch[*nch].new_path = NULL;
                ch[(*nch)++].reexport = 0;
                break;
            case MS_REEXPORT:
                ch[*nch].old_path = st->a; ch[*nch].new_path = "";
                ch[(*nch)++].reexport = 1;
                break;
            default: continue;
            }
        } else {
            continue;   /* version-min, swift-abi, fixups, target: no mr_ops */
        }
        any = 1;
    }
    return any;
}

/* The mr_ops as a string: only what is set, in a fixed order, so a row can
 * state the operation set it means and a builder that built something else is
 * caught by name rather than by an exit code. */
static void render_ops(const shape_ops *o, char *out, size_t outsz) {
    const mr_ops *p = &o->ops;
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

/* ---- one shape ---------------------------------------------------------- */

static const char *old_name(int v) {
    return v == OLD_RUNS ? "runs" : v == OLD_SKIPS ? "skips" : "not applicable (no mr_ops)";
}

static void run_shape(int row) {
    const char *shape = EXPECTED[row].shape;
    char in[512], out[512], rep[512], fp[256];
    size_t len = 0;

    CHECK(strcmp(SHAPES[row].shape, shape) == 0,
          "shape table row %d is '%s' but the expected-difference list row %d is '%s' -- "
          "the two lists have drifted, so the harness is not testing the shapes the "
          "design enumerated", row, SHAPES[row].shape, row, shape);
    if (strcmp(SHAPES[row].shape, shape) != 0) return;

    snprintf(in,  sizeof in,  "%s/in.%d", g_dir, row);
    snprintf(out, sizeof out, "%s/out.%d", g_dir, row);
    snprintf(rep, sizeof rep, "%s/report.%d", g_dir, row);

    uint8_t *img = build_fixture(SHAPES[row].fixture, &len);
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

    /* ---- new: what the run DID, not only what it declared --------------- */
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
    CHECK((ob.derived > 0) == (SHAPES[row].derives != 0),
          "%s: the report shows %d derived statement(s) and the shape says it %s derive. "
          "A `target` line declares MREL_NONE and disturbs only through its expansion, so "
          "an unread expansion is an unnoticed disturbance. Report:\n%s",
          shape, ob.derived, SHAPES[row].derives ? "does" : "does not", text);

    size_t olen = 0;
    uint8_t *obuf = read_file(out, &olen);
    mi_image im;
    int new_skips = -1;
    unsigned live = MREL_NONE;
    if (!obuf || mi_wrap(obuf, olen, &im) != 0) {
        CHECK(0, "%s: the written image will not re-open, so the derivation could not be "
                 "evaluated against what the gate would actually see", shape);
    } else {
        live = mrel_live(&im);
        CHECK((live & MREL_FUNC_START) != 0,
              "%s: the result image has no live LC_FUNCTION_STARTS, so mrel_verify_applies "
              "answers \"skip\" whatever the run disturbed. Every `new: skips` row in this "
              "table would then read as expected while proving nothing -- the fixture, not "
              "the derivation, would be what passed the test", shape);
        new_skips = !mrel_verify_applies(&im, disturbed);
        mi_close(&im);
    }
    free(obuf);
    free(report);

    /* ---- old: the hand-written predicate, on the ops this lowers to ----- */
    shape_ops so;
    int has_ops = lower_to_ops(&script, &so);
    int old = has_ops ? (mr_is_rename_only(&so.ops) ? OLD_SKIPS : OLD_RUNS) : OLD_NA;

    CHECK(has_ops == (SHAPES[row].ops_fingerprint != NULL),
          "%s: the script lowers to %s mr_ops and the shape says %s. Which shapes have an "
          "`old` answer is the whole content of the OLD_NA state: a shape that builds no "
          "mr_ops has no gate to differ from, and reporting one anyway would describe a "
          "check that never ran",
          shape, has_ops ? "an" : "no",
          SHAPES[row].ops_fingerprint ? "it does" : "it does not");

    if (has_ops && SHAPES[row].ops_fingerprint) {
        render_ops(&so, fp, sizeof fp);
        CHECK(strcmp(fp, SHAPES[row].ops_fingerprint) == 0,
              "%s: lowers to mr_ops {%s}, but the shape says {%s}. mr_is_rename_only reads "
              "nothing but these fields, so an ops that does not describe the shape makes "
              "the whole `old` column an answer about some other operation set -- and a "
              "zeroed one would still read as \"runs\" for thirteen of these fourteen rows",
              shape, fp, SHAPES[row].ops_fingerprint);
    }

    CHECK(old == EXPECTED[row].old,
          "%s: mr_is_rename_only %s, and the design's difference list says %s. The old "
          "predicate is still in control of the gate, so a disagreement here means the "
          "list does not describe the code that ships",
          shape, old_name(old), old_name(EXPECTED[row].old));

    CHECK(new_skips == EXPECTED[row].new_skips,
          "%s: the derivation says %s the gate (live=%#x disturbed=%#x, declared %#x plus "
          "%#x observed), and the design's difference list says %s. Do not adjust the list "
          "to match: it is what a reviewer weighed when agreeing to narrow mg_plausible's "
          "reach, and a differential test edited to fit its output is a rubber stamp",
          shape, new_skips ? "skip" : "run",
          live, disturbed, declared, ob.mask,
          EXPECTED[row].new_skips ? "skip" : "run");

    ms_free(&script);
}

/* ---- the fat container: per slice, never per container ------------------ */

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

/* Decision 6: mrel_verify_applies takes a SLICE. The proof that this is not a
 * container-level question is a container whose two slices MUST answer
 * differently -- same file, same run, same disturbance. One slice has a live
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
    slices[0] = a; lens[0] = alen; ct[0] = CPU_TYPE_X86_64; cs[0] = CPU_SUBTYPE_X86_64_ALL;
    slices[1] = b; lens[1] = blen; ct[1] = 0x0100000c;      cs[1] = 0;   /* arm64 */
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
    int narrowed = 0, agreed = 0;
    for (int i = 0; i < N_EXPECTED; i++) {
        if (EXPECTED[i].old == OLD_RUNS && EXPECTED[i].new_skips) narrowed++;
        if (EXPECTED[i].old == OLD_SKIPS && EXPECTED[i].new_skips) agreed++;
    }
    CHECK(narrowed > 0,
          "the difference list has no row where the old predicate ran and the derivation "
          "skips, so it is not describing the narrowing this design exists to make -- and "
          "a harness computing one predicate twice would pass it");
    CHECK(agreed > 0,
          "the difference list has no rename-only row, so nothing holds the design's one "
          "\"unchanged\" promise: that the shape the old predicate already skipped keeps "
          "being skipped");
}

int main(void) {
    if ((int)(sizeof SHAPES / sizeof SHAPES[0]) != N_EXPECTED) {
        printf("FAIL: %d shapes for %d expected-difference rows\n",
               (int)(sizeof SHAPES / sizeof SHAPES[0]), N_EXPECTED);
        return 1;
    }
    fresh_dir();
    check_the_lists_differ();
    for (int i = 0; i < N_EXPECTED; i++) run_shape(i);
    run_fat();
    rm_dir();
    if (fails) {
        printf("rename_only_differential: %d failure(s)\n", fails);
        return 1;
    }
    printf("rename_only_differential: %d shapes compared, plus a fat container per slice\n",
           N_EXPECTED);
    return 0;
}
