/*
 * tests/edit_test.c — hermetic tests for src/edit.c's me_run.
 *
 * The image is built here by hand (same reasoning as linkedit_test), so this
 * is host-agnostic. What is under test is the EXECUTION MODEL, not the
 * individual operations: statements apply in order, and a failure part-way
 * writes nothing.
 *
 * me_run READS FILE AND WRITES OUT; it never writes the file it is given, so
 * every run here names an OUT beside the input and reads the result back from
 * OUT. Each test writes its image into a fresh mkdtemp directory and inspects
 * the directory afterwards as well as the file: "wrote nothing" has to mean the
 * input unchanged, no OUT created, and no temp file left behind by a write that
 * was started and abandoned.
 *
 * The image is tests/mkimplausible.c's shape: __TEXT with one section at
 * 0x400, __DATA with two sections (the second an __init_offsets whose one
 * entry names an initializer), __LINKEDIT, an LC_UUID, and an
 * LC_FUNCTION_STARTS declaring the single function start base + 0x400. With
 * the initializer naming 0x400 the image is plausible; naming 0x999 it is
 * the implausible twin, which mg_plausible refuses. One test adds an empty
 * LC_DYLD_INFO_ONLY, which makes the image one `fixups set classic` passes
 * through as already converted.
 *
 * Build: ctest runs it as edit_test. By hand, compile this file with -Isrc
 * together with every .c file under src/ -- me_run reaches most of them.
 */
#include "edit.h"
#include "image.h"
#include "relations.h"
#include "rewrite.h"
#include "script.h"
#include "mach_compat.h"
#include "version_min.h"

#include <mach-o/loader.h>
#include <mach-o/fat.h>
#include <libkern/OSByteOrder.h>
#include <assert.h>
#include <dirent.h>
#include <errno.h>
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

#define TEXT_VMADDR 0x100000000ULL
#define SECT_OFF    0x400        /* the one address LC_FUNCTION_STARTS names */
#define DATA_OFF    0x1000
#define DATA_SIZE   0x1000
#define LE_OFF      0x2000
#define LE_SIZE     0x1000
#define INIT_OFF    (DATA_OFF + 0x800)
#define FS_SIZE     8
#define IMG_SIZE    (LE_OFF + LE_SIZE)

#define IMPLAUSIBLE 1   /* the initializer names no function start */
#define DYLD_INFO   2   /* carry an (empty) LC_DYLD_INFO_ONLY: already classic */
#define NO_UUID     4   /* leave out LC_UUID */
#define VMIN_1012    8    /* LC_VERSION_MIN_MACOSX 10.12, sdk 10.13 */
#define BUILDVER_12  16   /* macOS LC_BUILD_VERSION, minos 12.0, sdk 12.3 */
#define BUILDVER_IOS 32   /* the same LC_BUILD_VERSION, for iOS (platform 2) */
#define CATALYST     64   /* a Mac Catalyst LC_BUILD_VERSION (platform 6), minos 13.0, sdk 13.0 */
#define SECOND_VMIN 128   /* a second LC_VERSION_MIN_MACOSX, 10.12, sdk 10.13 */

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
    s->nsects = nsects;
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

static uint8_t *build_image(int flags) {
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
    put_sect(data, 1, "__init_offsets", "__DATA", TEXT_VMADDR + INIT_OFF, 4,
             INIT_OFF, S_INIT_FUNC_OFFSETS);
    p += data->cmdsize; ncmds++;

    struct segment_command_64 *le = put_seg(p, "__LINKEDIT", TEXT_VMADDR + LE_OFF, LE_SIZE,
                                            LE_OFF, LE_SIZE, 0);
    p += le->cmdsize; ncmds++;

    if (!(flags & NO_UUID)) {
        struct uuid_command *uu = (struct uuid_command *)p;
        uu->cmd = LC_UUID; uu->cmdsize = sizeof *uu;
        memset(uu->uuid, 0xab, sizeof uu->uuid);
        p += uu->cmdsize; ncmds++;
    }

    struct linkedit_data_command *fs = (struct linkedit_data_command *)p;
    fs->cmd = LC_FUNCTION_STARTS; fs->cmdsize = sizeof *fs;
    fs->dataoff = LE_OFF; fs->datasize = FS_SIZE;
    p += fs->cmdsize; ncmds++;

    if (flags & DYLD_INFO) {
        struct dyld_info_command *di = (struct dyld_info_command *)p;
        di->cmd = LC_DYLD_INFO_ONLY; di->cmdsize = sizeof *di;
        p += di->cmdsize; ncmds++;
    }

    if (flags & VMIN_1012) {
        struct version_min_command *vm = (struct version_min_command *)p;
        vm->cmd = LC_VERSION_MIN_MACOSX; vm->cmdsize = sizeof *vm;
        vm->version = 0x000A0C00; vm->sdk = 0x000A0D00;
        p += vm->cmdsize; ncmds++;
    }
    if (flags & (BUILDVER_12 | BUILDVER_IOS)) {
        struct mc_build_version *bv = (struct mc_build_version *)p;
        bv->cmd = LC_BUILD_VERSION; bv->cmdsize = sizeof *bv;
        bv->platform = (flags & BUILDVER_IOS) ? 2 : 1;
        bv->minos = 0x000C0000; bv->sdk = 0x000C0300; bv->ntools = 0;
        p += bv->cmdsize; ncmds++;
    }

    if (flags & CATALYST) {
        struct mc_build_version *bv = (struct mc_build_version *)p;
        bv->cmd = LC_BUILD_VERSION; bv->cmdsize = sizeof *bv;
        bv->platform = MV_PLATFORM_MACCATALYST;
        bv->minos = 0x000D0000; bv->sdk = 0x000D0000; bv->ntools = 0;
        p += bv->cmdsize; ncmds++;
    }
    if (flags & SECOND_VMIN) {
        struct version_min_command *vm = (struct version_min_command *)p;
        vm->cmd = LC_VERSION_MIN_MACOSX; vm->cmdsize = sizeof *vm;
        vm->version = 0x000A0C00; vm->sdk = 0x000A0D00;
        p += vm->cmdsize; ncmds++;
    }

    h->ncmds = ncmds;
    h->sizeofcmds = (uint32_t)(p - (buf + sizeof *h));

    /* One function start at base + 0x400 (ULEB128 0x400 is 0x80 0x08). */
    buf[LE_OFF] = 0x80; buf[LE_OFF + 1] = 0x08;

    uint32_t init = (flags & IMPLAUSIBLE) ? 0x999u : SECT_OFF;
    memcpy(buf + INIT_OFF, &init, sizeof init);
    return buf;
}

/* A minimal MH_EXECUTE/MH_PIE image mg_grow_header (src/grow.c) can actually
 * grow: a __PAGEZERO donating vm space, and a __TEXT segment mapping the
 * header (fileoff 0) whose one section starts at GROWIMG_SECTOFF -- a small
 * enough header pad that appending a modest dylib path has to grow it to
 * fit. No LC_FUNCTION_STARTS: with none present mg_plausible (and
 * mg_grow_header's own leading-delta check) have nothing base-relative to
 * verify, so this image is plausible as soon as it has a segment mapping
 * the header. Used only by the fat-reassembly-refusal test below, to make a
 * slice that `edit` can genuinely grow. */
#define GROWIMG_SIZE    0x2000
#define GROWIMG_SECTOFF 0x200
/* The same image with NO pad at all: its one section starts exactly where the
 * load commands end, so appending anything at all has to grow the header. */
#define GROWIMG_NO_PAD 0

static uint8_t *build_growable_image_at(uint32_t sectoff, int func_starts) {
    uint8_t *buf = (uint8_t *)calloc(1, GROWIMG_SIZE);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    h->magic = MH_MAGIC_64;
    h->cputype = CPU_TYPE_X86_64;
    h->cpusubtype = CPU_SUBTYPE_X86_64_ALL;
    h->filetype = MH_EXECUTE;
    h->flags = MH_PIE;

    struct segment_command_64 *pz = (struct segment_command_64 *)(buf + sizeof *h);
    pz->cmd = LC_SEGMENT_64;
    pz->cmdsize = sizeof *pz;
    set16(pz->segname, "__PAGEZERO");
    pz->vmsize = 0x100000000ull;   /* room to lower the base into */

    struct segment_command_64 *tx = (struct segment_command_64 *)((uint8_t *)pz + pz->cmdsize);
    tx->cmd = LC_SEGMENT_64;
    tx->cmdsize = sizeof *tx + sizeof(struct section_64);
    set16(tx->segname, "__TEXT");
    tx->vmaddr = 0x100000000ull;
    tx->vmsize = GROWIMG_SIZE;
    tx->fileoff = 0;
    tx->filesize = GROWIMG_SIZE;
    tx->nsects = 1;
    struct section_64 *sc = (struct section_64 *)(tx + 1);
    set16(sc->sectname, "__text");
    set16(sc->segname, "__TEXT");
    sc->addr = tx->vmaddr + sectoff;
    sc->size = 4;
    sc->offset = sectoff;

    h->ncmds = 2;
    h->sizeofcmds = (uint32_t)(pz->cmdsize + tx->cmdsize);

    /* Optional, and the whole reason it is optional: with an
     * LC_FUNCTION_STARTS the relation mg_plausible checks is LIVE in this
     * image, so a run that re-bases it has something to re-check. The blob
     * names one function start at base + 0x400, which the grow re-bases along
     * with everything else; there is no __init_offsets section, so nothing
     * base-relative has to name it and the image stays plausible either way. */
    if (func_starts) {
        struct linkedit_data_command *fs =
            (struct linkedit_data_command *)((uint8_t *)tx + tx->cmdsize);
        fs->cmd = LC_FUNCTION_STARTS; fs->cmdsize = sizeof *fs;
        fs->dataoff = GROWIMG_SIZE - 0x100; fs->datasize = 8;
        buf[fs->dataoff] = 0x80; buf[fs->dataoff + 1] = 0x08;
        h->ncmds = 3;
        h->sizeofcmds += fs->cmdsize;
    }

    /* GROWIMG_NO_PAD: the section starts exactly where the load commands end,
     * whatever they turned out to be, so appending anything at all has to
     * grow. Written here rather than as a constant because the constant would
     * have to be recomputed by hand every time a command is added above. */
    if (sectoff == GROWIMG_NO_PAD) {
        sc->offset = (uint32_t)(sizeof *h + h->sizeofcmds);
        sc->addr = tx->vmaddr + sc->offset;
    }
    return buf;
}

static uint8_t *build_growable_image(void) {
    return build_growable_image_at(GROWIMG_SECTOFF, 0);
}

/* ---- file and directory helpers ---------------------------------------- */

static char g_dir[256];

static void fresh_dir(void) {
    const char *tmp = getenv("TMPDIR");
    snprintf(g_dir, sizeof g_dir, "%s/edit_test.XXXXXX", (tmp && *tmp) ? tmp : "/tmp");
    if (!mkdtemp(g_dir)) { perror("mkdtemp"); exit(2); }
}

static void in_dir(char *out, size_t outsz, const char *name) {
    snprintf(out, outsz, "%s/%s", g_dir, name);
}

static void write_file(const char *path, const uint8_t *buf, size_t len, mode_t mode) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, mode);
    if (fd < 0 || write(fd, buf, len) != (ssize_t)len) { perror(path); exit(2); }
    close(fd);
    chmod(path, mode);
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
    *len = (size_t)st.st_size;
    return buf;
}

/* FNV-1a, 64-bit: the "hash taken up front". A byte-for-byte comparison is
 * made as well; the hash is what a reader can check at a glance in a FAIL
 * line. */
static uint64_t fnv1a(const uint8_t *p, size_t n) {
    uint64_t h = 0xcbf29ce484222325ULL;
    for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 0x100000001b3ULL; }
    return h;
}

static int dir_entries(void) {
    DIR *d = opendir(g_dir);
    int n = 0;
    struct dirent *e;
    if (!d) { perror(g_dir); exit(2); }
    while ((e = readdir(d)) != NULL)
        if (strcmp(e->d_name, ".") != 0 && strcmp(e->d_name, "..") != 0) n++;
    closedir(d);
    return n;
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

/* Everything "left untouched" means, taken before a run and compared after. */
typedef struct {
    uint8_t *bytes;
    size_t   len;
    uint64_t hash;
    ino_t    ino;
    int      entries;
} snap;

static snap take(const char *path) {
    snap s;
    struct stat st;
    s.bytes = read_file(path, &s.len);
    s.hash = fnv1a(s.bytes, s.len);
    stat(path, &st);
    s.ino = st.st_ino;
    s.entries = dir_entries();
    return s;
}

static void check_untouched(const char *what, const char *path, snap *before) {
    size_t len = 0;
    uint8_t *now = read_file(path, &len);
    struct stat st;
    CHECK(now != NULL, "%s: %s still exists", what, path);
    if (now) {
        uint64_t h = fnv1a(now, len);
        CHECK(h == before->hash, "%s: hash changed (%016llx -> %016llx)", what,
              (unsigned long long)before->hash, (unsigned long long)h);
        CHECK(len == before->len && memcmp(now, before->bytes, len) == 0,
              "%s: bytes changed (%zu -> %zu bytes)", what, before->len, len);
    }
    CHECK(stat(path, &st) == 0 && st.st_ino == before->ino,
          "%s: inode changed, so the file was replaced", what);
    CHECK(dir_entries() == before->entries,
          "%s: directory has %d entries, had %d -- a temp or output file was left",
          what, dir_entries(), before->entries);
    free(now);
    free(before->bytes);
}

/* ---- fat containers ----------------------------------------------------- */

/* A fat container of n slices, each at a 0x1000-aligned offset in the order
 * given, big-endian as every real fat file is. ct/cs label the fat_arch
 * entry; edit names a slice by its fat_arch entry, so an x86_64 image can
 * stand in for arm64 without its own header saying so.
 *
 * n is at most 8 -- the callers here pass 2 or 3 -- because the offsets are
 * held in a fixed array. */
static uint8_t *build_fat(int n, uint8_t *const *slice, const size_t *len,
                          const uint32_t *ct, const uint32_t *cs, size_t *outlen) {
    size_t off[8], total = 0x1000;
    assert(n > 0 && n <= (int)(sizeof off / sizeof *off));
    for (int i = 0; i < n; i++) { off[i] = total; total += (len[i] + 0xfff) & ~(size_t)0xfff; }
    uint8_t *buf = (uint8_t *)calloc(1, total);
    struct fat_header *fh = (struct fat_header *)buf;
    fh->magic = OSSwapHostToBigInt32(FAT_MAGIC);
    fh->nfat_arch = OSSwapHostToBigInt32((uint32_t)n);
    struct fat_arch *fa = (struct fat_arch *)(fh + 1);
    for (int i = 0; i < n; i++) {
        fa[i].cputype = (cpu_type_t)OSSwapHostToBigInt32(ct[i]);
        fa[i].cpusubtype = (cpu_subtype_t)OSSwapHostToBigInt32(cs[i]);
        fa[i].offset = OSSwapHostToBigInt32((uint32_t)off[i]);
        fa[i].size = OSSwapHostToBigInt32((uint32_t)len[i]);
        fa[i].align = OSSwapHostToBigInt32(12);
        memcpy(buf + off[i], slice[i], len[i]);
    }
    *outlen = total;
    return buf;
}

/* A 32-bit slice: just enough header to be one. */
static uint8_t *build_i386_stub(size_t *len) {
    *len = 0x1000;
    uint8_t *b = (uint8_t *)calloc(1, *len);
    struct mach_header *h = (struct mach_header *)b;
    h->magic = MH_MAGIC; h->cputype = CPU_TYPE_I386; h->cpusubtype = CPU_SUBTYPE_I386_ALL;
    h->filetype = MH_DYLIB;
    return b;
}

/* Copy slice `idx` of the fat file at `path` into its own file at `out`. */
static void slice_to_file(const char *path, int idx, const char *out) {
    size_t len;
    uint8_t *b = read_file(path, &len);
    const struct fat_arch *fa = (const struct fat_arch *)(b + sizeof(struct fat_header));
    uint32_t off = OSSwapBigToHostInt32(fa[idx].offset), sz = OSSwapBigToHostInt32(fa[idx].size);
    write_file(out, b + off, sz, 0644);
    free(b);
}

/* The standard two- or three-slice fixture: x86_64, arm64 (the same image,
 * relabelled), and optionally an i386 stub. flags0/flags1 go to build_image. */
static void write_fat(const char *path, int flags0, int flags1, int with_i386) {
    uint8_t *s[3]; size_t l[3];
    uint32_t ct[3] = { (uint32_t)CPU_TYPE_X86_64, (uint32_t)CPU_TYPE_ARM64, (uint32_t)CPU_TYPE_I386 };
    uint32_t cs[3] = { (uint32_t)CPU_SUBTYPE_X86_64_ALL, (uint32_t)CPU_SUBTYPE_ARM64_ALL,
                       (uint32_t)CPU_SUBTYPE_I386_ALL };
    s[0] = build_image(flags0); l[0] = IMG_SIZE;
    s[1] = build_image(flags1); l[1] = IMG_SIZE;
    int n = 2;
    if (with_i386) { s[2] = build_i386_stub(&l[2]); n = 3; }
    size_t flen;
    uint8_t *fat = build_fat(n, s, l, ct, cs, &flen);
    write_file(path, fat, flen, 0755);
    for (int i = 0; i < n; i++) free(s[i]);
    free(fat);
}

/* ---- image inspection -------------------------------------------------- */

struct find_ctx { uint32_t cmd; int n; const char *name; };

static int find_cb(const struct load_command *lc, void *ctx_) {
    struct find_ctx *c = ctx_;
    if (lc->cmd != c->cmd) return 0;
    if (c->name) {
        const struct dylib_command *dc = (const struct dylib_command *)lc;
        if (strcmp((const char *)lc + dc->dylib.name.offset, c->name) != 0) return 0;
    }
    c->n++;
    return 0;
}

/* How many load commands of kind `cmd` (and, for a dylib command, naming
 * `name`) the file at `path` has; -1 if it is not a valid image. */
static int count_lc(const char *path, uint32_t cmd, const char *name) {
    size_t len = 0;
    uint8_t *buf = read_file(path, &len);
    mi_image im;
    struct find_ctx c = { cmd, 0, name };
    if (!buf) return -1;
    if (mi_wrap(buf, len, &im) != 0) { free(buf); return -1; }
    mi_each_lc(&im, find_cb, &c);
    free(buf);
    return c.n;
}

struct word_ctx { uint32_t cmd, field, value; int n; };

static int word_cb(const struct load_command *lc, void *ctx_) {
    struct word_ctx *c = ctx_;
    if (lc->cmd == c->cmd && c->n++ == 0) c->value = ((const uint32_t *)lc)[c->field];
    return 0;
}

/* Word `field` (cmd is word 0) of the first `cmd` load command in the file at
 * `path`; 0 when there is none. */
static uint32_t lc_word(const char *path, uint32_t cmd, uint32_t field) {
    size_t len = 0;
    uint8_t *buf = read_file(path, &len);
    mi_image im;
    struct word_ctx c = { cmd, field, 0, 0 };
    if (!buf) return 0;
    if (mi_wrap(buf, len, &im) == 0) mi_each_lc(&im, word_cb, &c);
    free(buf);
    return c.value;
}

/* Set word `field` (cmd is word 0) of the nth (0-based) `cmd` load command of
 * a build_image buffer. */
static void poke_lc(uint8_t *img, uint32_t cmd, int nth, uint32_t field, uint32_t value) {
    struct mach_header_64 *h = (struct mach_header_64 *)img;
    uint8_t *p = img + sizeof *h;
    for (uint32_t i = 0; i < h->ncmds; i++) {
        struct load_command *lc = (struct load_command *)p;
        if (lc->cmd == cmd && nth-- == 0) { ((uint32_t *)p)[field] = value; return; }
        p += lc->cmdsize;
    }
    assert(!"poke_lc: no such command");
}

static int same_file(const char *a, const char *b) {
    size_t la = 0, lb = 0;
    uint8_t *x = read_file(a, &la), *y = read_file(b, &lb);
    int same = x && y && la == lb && memcmp(x, y, la) == 0;
    free(x);
    free(y);
    return same;
}

static int has_segment(const char *path, const char *seg, const char *sect_segname) {
    size_t len = 0;
    uint8_t *buf = read_file(path, &len);
    mi_image im;
    int ok = 0;
    if (!buf) return 0;
    if (mi_wrap(buf, len, &im) == 0) {
        struct segment_command_64 *s = mi_find_segment(&im, seg);
        if (s) {
            ok = 1;
            /* Each section repeats its segment's name; a rename must reach it. */
            if (sect_segname) {
                struct section_64 *sc = (struct section_64 *)(s + 1);
                for (uint32_t i = 0; i < s->nsects; i++)
                    if (strncmp(sc[i].segname, sect_segname, 16) != 0) ok = 0;
            }
        }
    }
    free(buf);
    return ok;
}

/* ---- running a script --------------------------------------------------- */

static char g_log[8192];

/* Parse `text` and run it, reading `path` and writing `out`; the report lands
 * in g_log. There is no quiet mode to select, so there is no parameter for
 * one: every run reports. */
static int run(const char *path, const char *out, const char *text) {
    ms_script s;
    char err[256];
    if (ms_parse(text, strlen(text), &s, err, sizeof err) != 0) {
        printf("FAIL: test script does not parse: %s\n", err);
        fails++;
        return -99;
    }
    FILE *log = tmpfile();
    me_opts o;
    memset(&o, 0, sizeof o);
    o.log = log;
    int rc = me_run(path, out, &s, &o);
    fflush(log);
    rewind(log);
    size_t n = fread(g_log, 1, sizeof g_log - 1, log);
    g_log[n] = '\0';
    fclose(log);
    ms_free(&s);
    return rc;
}

/* ---- the tests ----------------------------------------------------------- */

static void test_statements_apply_in_order(void) {
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "img");
    in_dir(out, sizeof out, "img.out");
    uint8_t *img = build_image(0);
    write_file(path, img, IMG_SIZE, 0755);
    free(img);

    snap before = take(path);
    before.entries++;   /* OUT is the one expected newcomer */
    int rc = run(path, out,
                 "load-command delete uuid\n"
                 "segment rename __DATA __DATX\n");
    CHECK(rc == 0, "in order: a script that succeeds returns 0 (got %d; log: %s)", rc, g_log);
    check_untouched("in order: the input", path, &before);
    CHECK(count_lc(out, LC_UUID, NULL) == 0, "in order: LC_UUID was deleted");
    CHECK(has_segment(out, "__DATX", "__DATX"),
          "in order: __DATA was renamed, its sections' copy of the name too");
    CHECK(!has_segment(out, "__DATA", NULL), "in order: no __DATA segment remains");

    const char *first = strstr(g_log, "  load-command delete uuid\n");
    const char *second = strstr(g_log, "  segment rename __DATA __DATX\n");
    /* This script disturbs only the header pad, so the final verify has
     * nothing to re-decide and says so instead of claiming it verified. */
    const char *checked = strstr(g_log, ": this run disturbed sizeofcmds; "
                                        "none of that is re-checked\n");
    const char *written = strstr(g_log, ": written (");
    CHECK(first && second && first < second,
          "in order: the log names the statements in script order (log: %s)", g_log);
    CHECK(second && checked && second < checked,
          "in order: the verify decision is reported after the last statement (log: %s)", g_log);
    CHECK(checked && written && checked < written,
          "in order: the write is reported after that decision (log: %s)", g_log);
    CHECK(strstr(g_log, ": verified\n") == NULL,
          "in order: the log does not claim a verify that did not run (log: %s)", g_log);
    rm_dir();
}

/* THE PROPERTY THE WHOLE DESIGN EXISTS TO BUY. The first statement succeeds
 * and changes the in-memory image; the second is refused on its own merits (a
 * load command too long for the header pad of an image that cannot grow). Nothing may
 * reach the disk: not the input, not an OUT created, not a temp file
 * abandoned. The input is compared by hash, byte for byte, and by inode,
 * because a rename-based write would keep the bytes of a successful rewrite
 * but never the inode. */
static void test_a_failure_part_way_writes_nothing(void) {
    fresh_dir();
    char path[512], out[512], script[1024];
    in_dir(path, sizeof path, "img");
    in_dir(out, sizeof out, "img.out");
    uint8_t *img = build_image(0);
    write_file(path, img, IMG_SIZE, 0755);
    free(img);

    /* 600 bytes of path: well past the ~500 bytes of header pad. */
    char longpath[640];
    memset(longpath, 'x', sizeof longpath);
    longpath[0] = '/';
    longpath[600] = '\0';
    /* Statement 2 is on source line 4: the refusal must name both. */
    snprintf(script, sizeof script,
             "# harmless first\n"
             "load-command delete uuid\n"
             "\n"
             "dylib append %s\n", longpath);

    snap before = take(path);
    int rc = run(path, out, script);
    CHECK(rc == MR_REFUSED, "part-way: a refused second statement returns MR_REFUSED (got %d)", rc);
    check_untouched("part-way", path, &before);
    CHECK(access(out, F_OK) != 0 && errno == ENOENT,
          "part-way: %s was not created", out);
    CHECK(strstr(g_log, "  load-command delete uuid\n") != NULL,
          "part-way: the first statement did run before the refusal (log: %s)", g_log);
    CHECK(strstr(g_log, "refused at statement 2 of 2 (line 4)") != NULL,
          "part-way: the refusal names statement 2 of 2 and its source line (log: %s)", g_log);
    CHECK(strstr(g_log, "written (") == NULL,
          "part-way: nothing claims a write happened (log: %s)", g_log);
    /* The refusal says both halves of what it left behind, rather than calling
     * a file that was never there "left unmodified". */
    {
        char want[1200], wrong[1200];
        snprintf(want, sizeof want, "; %s not written; %s left unmodified\n", out, path);
        snprintf(wrong, sizeof wrong, "%s left unmodified", out);
        CHECK(strstr(g_log, want) != NULL,
              "part-way: the refusal says OUT was not written and FILE was "
              "left unmodified (log: %s)", g_log);
        CHECK(strstr(g_log, wrong) == NULL,
              "part-way: the refusal does not call OUT unmodified (log: %s)", g_log);
    }

    rm_dir();
}

/* OUT MAY NOT BE THE INPUT, and me_run answers that itself rather than leaving
 * it to the write: the CLI refuses it up front too (bad_out, cli/drydock-macho-rewrite.c),
 * but me_run is reachable from elsewhere and this is the property the whole
 * conversion is for. MR_FAIL, not MR_REFUSED: naming the same file twice is a
 * mistake about the command, not a considered verdict about the image. */
static void test_out_that_is_the_input_is_refused(void) {
    fresh_dir();
    char path[512];
    in_dir(path, sizeof path, "img");
    uint8_t *img = build_image(0);
    write_file(path, img, IMG_SIZE, 0755);
    free(img);

    snap before = take(path);
    int rc = run(path, path, "load-command delete uuid\n");
    CHECK(rc == MR_FAIL, "out is the input: MR_FAIL (got %d; log: %s)", rc, g_log);
    check_untouched("out is the input", path, &before);
    CHECK(strstr(g_log, "never writes its input") != NULL,
          "out is the input: the message says so (log: %s)", g_log);
    CHECK(strstr(g_log, "written (") == NULL,
          "out is the input: nothing claims a write happened (log: %s)", g_log);

    /* And no `out` at all is the same answer: there is no "write it back"
     * fallback left for a NULL to mean. Only reachable from inside this repo --
     * cli/drydock-macho-rewrite.c's parser requires the positional -- which is why it is
     * checked here. */
    before = take(path);
    rc = run(path, NULL, "load-command delete uuid\n");
    CHECK(rc == MR_FAIL, "no out: MR_FAIL (got %d; log: %s)", rc, g_log);
    check_untouched("no out", path, &before);
    CHECK(strstr(g_log, "no output file was named") != NULL,
          "no out: the message says so (log: %s)", g_log);
    rm_dir();
}

/* A script with no statements -- only directives, comments or blank lines --
 * disturbs nothing, so there is nothing for the final verify to re-decide and
 * it does not run. `edit` is not a linter: `drydock-macho-rewrite verify` is the command
 * that judges an image the caller did not ask to change. The fixture is the
 * IMPLAUSIBLE one precisely so that a gate which DID run would refuse, making
 * this test fail rather than pass vacuously. */
static void test_an_empty_script_disturbs_nothing_and_is_passed_through(void) {
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "img");
    in_dir(out, sizeof out, "img.out");
    uint8_t *img = build_image(IMPLAUSIBLE);
    write_file(path, img, IMG_SIZE, 0755);
    free(img);

    snap before = take(path);
    before.entries++;   /* OUT is the one expected newcomer */
    int rc = run(path, out, "# nothing but a comment\nallow-unmatched\n");
    CHECK(rc == 0, "empty script: a script that disturbs nothing is not verified and "
          "not refused (got %d; log: %s)", rc, g_log);
    check_untouched("empty script: the input", path, &before);
    CHECK(strstr(g_log, "refused at verification") == NULL,
          "empty script: nothing was refused at verification (log: %s)", g_log);
    CHECK(strstr(g_log, "of 0") == NULL,
          "empty script: nothing counts statement 0 of 0 (log: %s)", g_log);
    /* The one run with an EMPTY list to report, which is why it is worded
     * without one instead of trailing off after "disturbed". */
    CHECK(strstr(g_log, ": this run disturbed nothing, so there is nothing to "
                        "re-check\n") != NULL,
          "empty script: the skip line reads as English with nothing to name "
          "(log: %s)", g_log);
    {
        size_t a = 0, b = 0;
        uint8_t *in = read_file(path, &a), *o = read_file(out, &b);
        CHECK(in && o && a == b && memcmp(in, o, a) == 0,
              "empty script: OUT is byte-identical to the input");
        free(in); free(o);
    }
    rm_dir();
}

/* The final verify has no escape hatch, and that is unchanged. What narrowed
 * is only WHICH runs it applies to: a run that disturbed nothing it checks
 * has nothing to re-decide. MACHO_NO_VERIFY still cannot suppress a verify
 * that applies, and there is no other input a caller can supply that can --
 * the applicability is computed from the image and the operations
 * (mrel_verify_applies). Both halves are pinned here, because the first
 * without the second would be satisfied by a gate that never runs.
 *
 * `fixups set classic` is the operation: on an already-classic image it is a
 * pass-through that changes no byte (see the size assertion in
 * test_the_file_level_operations_run_in_memory), yet it DECLARES
 * MREL_FILE_OFF|MREL_BASE_REL|MREL_HEADER_PAD, because a disturbs mask is a
 * conservative declaration about an operation and not an observation about
 * this image. So the gate applies, and refuses. */
static void test_the_final_verify_ignores_MACHO_NO_VERIFY(void) {
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "img");
    in_dir(out, sizeof out, "img.out");
    /* DYLD_INFO so the conversion has something already lowered and passes;
     * IMPLAUSIBLE so the only thing that can refuse is me_run's own verify. */
    uint8_t *img = build_image(IMPLAUSIBLE | DYLD_INFO);
    write_file(path, img, IMG_SIZE, 0755);
    free(img);

    setenv("MACHO_NO_VERIFY", "1", 1);
    snap before = take(path);
    int rc = run(path, out, "fixups set classic\n");
    unsetenv("MACHO_NO_VERIFY");
    CHECK(rc == MR_REFUSED, "no escape hatch: MACHO_NO_VERIFY=1 does not skip a verify "
          "that applies (got %d; log: %s)", rc, g_log);
    check_untouched("no escape hatch", path, &before);
    CHECK(access(out, F_OK) != 0, "no escape hatch: %s was not created", out);
    CHECK(strstr(g_log, "verified\n") == NULL,
          "no escape hatch: the log does not claim the image verified (log: %s)", g_log);
    CHECK(strstr(g_log, "refused at verification") != NULL,
          "no escape hatch: the refusal names verification (log: %s)", g_log);

    /* And the other half: the skip is determined by the image and the
     * operations, so MACHO_NO_VERIFY changes NOTHING in either direction. The
     * same fixture, a statement that disturbs nothing, run both ways: same
     * exit code, same OUT, both times. A caller-controlled escape hatch would
     * show up here as a difference. */
    rc = run(path, out, "segment rename __DATA __DATX\n");
    CHECK(rc == 0, "derived skip: a run that disturbs nothing it checks is not "
          "verified and not refused (got %d; log: %s)", rc, g_log);
    CHECK(access(out, F_OK) == 0, "derived skip: OUT was written");
    unlink(out);
    setenv("MACHO_NO_VERIFY", "1", 1);
    int rc2 = run(path, out, "segment rename __DATA __DATX\n");
    unsetenv("MACHO_NO_VERIFY");
    CHECK(rc2 == rc, "not caller-determined: MACHO_NO_VERIFY changes nothing about the "
          "skip (got %d, then %d)", rc, rc2);
    rm_dir();
}

/* Sequential, not batched: a statement sees what the one before it did. In
 * one batched operation set the replace could never match the command the
 * append creates, and a replace that matched nothing refuses the run. */
static void test_later_statements_see_earlier_ones(void) {
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "img");
    in_dir(out, sizeof out, "img.out");
    uint8_t *img = build_image(0);
    write_file(path, img, IMG_SIZE, 0755);
    free(img);

    int rc = run(path, out,
                 "dylib append /usr/lib/libfoo.dylib\n"
                 "dylib replace /usr/lib/libfoo.dylib /usr/lib/libbar.dylib\n");
    CHECK(rc == 0, "sequential: the replace matched the appended dylib (got %d)", rc);
    CHECK(count_lc(out, LC_LOAD_DYLIB, "/usr/lib/libbar.dylib") == 1,
          "sequential: the result loads libbar");
    CHECK(count_lc(out, LC_LOAD_DYLIB, "/usr/lib/libfoo.dylib") == 0,
          "sequential: nothing still loads libfoo");
    rm_dir();
}

/* `dylib retype PATH KIND` rewrites an existing dependency's load-command
 * KIND to any of the four ordinal-bearing kinds (src/ordinals.h), not just
 * LC_REEXPORT_DYLIB (`dylib reexport`, which is now one case it subsumes).
 * One run per kind, each starting from the same freshly-appended
 * LC_LOAD_DYLIB: a KIND that ms_parse accepts but edit.c's lowering left at
 * retype_to==0 would show up here as libfoo still LC_LOAD_DYLIB, not the
 * kind asked for. */
static void test_dylib_retype_rewrites_the_load_command_kind(void) {
    static const struct { const char *word; uint32_t cmd; } KINDS[] = {
        { "weak",     LC_LOAD_WEAK_DYLIB },
        { "reexport", LC_REEXPORT_DYLIB },
        { "upward",   LC_LOAD_UPWARD_DYLIB },
        { "load",     LC_LOAD_DYLIB },
    };
    for (size_t i = 0; i < sizeof KINDS / sizeof KINDS[0]; i++) {
        fresh_dir();
        char path[512], out[512], script[256];
        in_dir(path, sizeof path, "img");
        in_dir(out, sizeof out, "img.out");
        uint8_t *img = build_image(0);
        write_file(path, img, IMG_SIZE, 0755);
        free(img);

        snprintf(script, sizeof script,
                 "dylib append /usr/lib/libfoo.dylib\n"
                 "dylib retype /usr/lib/libfoo.dylib %s\n", KINDS[i].word);
        int rc = run(path, out, script);
        CHECK(rc == 0, "retype to %s: run succeeds (got %d; log: %s)",
              KINDS[i].word, rc, g_log);
        CHECK(count_lc(out, KINDS[i].cmd, "/usr/lib/libfoo.dylib") == 1,
              "retype to %s: libfoo is now load-command kind %u", KINDS[i].word,
              (unsigned)KINDS[i].cmd);
        if (KINDS[i].cmd != LC_LOAD_DYLIB)
            CHECK(count_lc(out, LC_LOAD_DYLIB, "/usr/lib/libfoo.dylib") == 0,
                  "retype to %s: libfoo is no longer LC_LOAD_DYLIB", KINDS[i].word);
        rm_dir();
    }
}

/* An operation that matched nothing is a refusal by default, and a report
 * under allow-unmatched. */
static void test_an_unmatched_operation_refuses_by_default(void) {
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "img");
    in_dir(out, sizeof out, "img.out");
    uint8_t *img = build_image(0);
    write_file(path, img, IMG_SIZE, 0755);
    free(img);

    snap before = take(path);
    int rc = run(path, out,
                 "load-command delete uuid\n"
                 "dylib delete /definitely/not/linked.dylib\n");
    CHECK(rc == MR_REFUSED, "by default: an unmatched operation refuses (got %d)", rc);
    check_untouched("by default", path, &before);
    CHECK(access(out, F_OK) != 0, "by default: %s was not created", out);

    rc = run(path, out,
             "allow-unmatched\n"
             "load-command delete uuid\n"
             "dylib delete /definitely/not/linked.dylib\n");
    CHECK(rc == 0, "allow-unmatched: the run continues and succeeds (got %d)", rc);
    CHECK(count_lc(out, LC_UUID, NULL) == 0,
          "allow-unmatched: the statements that matched were applied");
    rm_dir();
}

/* A segment rename that renames nothing is a miss too. It has no hit count
 * for the dylib/rpath/lc report to read, so it needs its own, and by default
 * it must refuse the run -- after an earlier statement has already changed
 * the in-memory image, and without writing it. */
static void test_an_unmatched_segment_rename_refuses_by_default(void) {
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "img");
    in_dir(out, sizeof out, "img.out");
    uint8_t *img = build_image(0);
    write_file(path, img, IMG_SIZE, 0755);
    free(img);

    snap before = take(path);
    int rc = run(path, out,
                 "load-command delete uuid\n"
                 "segment rename __NOPE __X\n");
    CHECK(rc == MR_REFUSED, "by default: a rename that matched nothing refuses (got %d)", rc);
    check_untouched("by default, rename", path, &before);
    CHECK(access(out, F_OK) != 0, "by default, rename: %s was not created", out);
    CHECK(strstr(g_log, "refused at statement 2 of 2 (line 2)") != NULL,
          "by default: the refusal names the rename (log: %s)", g_log);

    rc = run(path, out,
             "allow-unmatched\n"
             "load-command delete uuid\n"
             "segment rename __NOPE __X\n");
    CHECK(rc == 0, "allow-unmatched: an unmatched rename is reported and the run "
          "succeeds (got %d)", rc);
    CHECK(count_lc(out, LC_UUID, NULL) == 0,
          "allow-unmatched: the statement before the rename was applied");
    CHECK(has_segment(out, "__DATA", NULL) && !has_segment(out, "__X", NULL),
          "allow-unmatched: no segment was renamed");
    rm_dir();
}

/* version-min, swift-abi and fixups were reachable only through file-level
 * entry points; each must run against the in-memory image. */
static void test_the_file_level_operations_run_in_memory(void) {
    fresh_dir();
    char path[512], out[512], out2[512];
    in_dir(path, sizeof path, "img");
    in_dir(out, sizeof out, "img.out");
    in_dir(out2, sizeof out2, "img.out2");
    uint8_t *img = build_image(DYLD_INFO);
    write_file(path, img, IMG_SIZE, 0755);

    int rc = run(path, out,
                 "fixups set classic\n"
                 "version-min set 10.9\n"
                 "swift-abi set legacy\n");
    CHECK(rc == 0, "in memory: an already-classic image passes fixups set classic, "
          "then gains a version-min (got %d; log: %s)", rc, g_log);
    CHECK(count_lc(out, LC_VERSION_MIN_MACOSX, NULL) == 1,
          "in memory: LC_VERSION_MIN_MACOSX was appended");
    /* The append is the one trace the statement leaves, so the report says
     * so, beneath the statement. */
    {
        const char *stmt = strstr(g_log, "  version-min set 10.9\n");
        const char *app = strstr(g_log, "\n      appended LC_VERSION_MIN_MACOSX 10.9\n");
        const char *next = strstr(g_log, "  swift-abi set legacy\n");
        CHECK(stmt && app && next && stmt < app && app < next,
              "in memory: the report logs the version-min append beneath its statement "
              "(log: %s)", g_log);
    }
    /* Run again over the result, which already has one: nothing appended,
     * nothing claimed. */
    rc = run(out, out2, "version-min set 10.9\n");
    CHECK(rc == 0, "in memory: version-min set on an image that has one succeeds (got %d)", rc);
    CHECK(count_lc(out2, LC_VERSION_MIN_MACOSX, NULL) == 1,
          "in memory: a second version-min set appends no second command");
    CHECK(strstr(g_log, "appended") == NULL,
          "in memory: the report claims no append when there was none (log: %s)", g_log);
    {
        size_t len = 0;
        uint8_t *now = read_file(out, &len);
        CHECK(now && len == IMG_SIZE,
              "in memory: a pass-through fixups statement leaves the size alone (got %zu)", len);
        free(now);
    }
    free(img);

    /* No chained fixups and no LC_DYLD_INFO_ONLY: there is nothing to lower
     * and nothing already lowered, which the conversion refuses. */
    img = build_image(0);
    write_file(path, img, IMG_SIZE, 0755);
    free(img);
    snap before = take(path);
    rc = run(path, out, "version-min set 10.9\nfixups set classic\n");
    CHECK(rc == MR_REFUSED, "in memory: fixups set classic with nothing to lower refuses (got %d)", rc);
    check_untouched("fixups refused", path, &before);
    rm_dir();
}

/* OUT is a NEW file, given the input's mode, and a successful run always
 * produces it -- even one whose statements changed nothing, which is why the
 * script here is a delete that matches. */
static void test_out_takes_the_inputs_mode(void) {
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "img");
    in_dir(out, sizeof out, "img.out");
    uint8_t *img = build_image(0);
    write_file(path, img, IMG_SIZE, 0751);
    free(img);

    snap before = take(path);
    before.entries++;   /* OUT is the one expected newcomer */
    int rc = run(path, out, "load-command delete uuid\n");
    CHECK(rc == 0, "OUT: returns 0 (got %d)", rc);
    check_untouched("OUT: the input", path, &before);
    CHECK(count_lc(out, LC_UUID, NULL) == 0, "OUT: the edit landed in the output");
    struct stat st;
    CHECK(stat(out, &st) == 0 && (st.st_mode & 07777) == 0751,
          "OUT: the output takes the input's mode (got %o)", (unsigned)(st.st_mode & 07777));
    rm_dir();
}

/* A thin 64-bit Mach-O and a 32-bit-header fat container are accepted; a
 * 64-bit-header fat container is refused, saying why; so is anything else; an
 * input that cannot be read is an error, not a refusal. */
static void test_what_edit_accepts(void) {
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "fat64");
    in_dir(out, sizeof out, "out");

    /* A fat_arch_64 container, which this tool does not read. */
    size_t fatlen = 0x1000;
    uint8_t *fat = (uint8_t *)calloc(1, fatlen);
    struct fat_header *fh = (struct fat_header *)fat;
    fh->magic = OSSwapHostToBigInt32(FAT_MAGIC_64);
    fh->nfat_arch = OSSwapHostToBigInt32(0);
    write_file(path, fat, fatlen, 0755);
    free(fat);

    snap before = take(path);
    int rc = run(path, out, "load-command delete uuid\n");
    CHECK(rc == MR_REFUSED, "accepts: a 64-bit fat input is refused (got %d)", rc);
    check_untouched("fat64 input", path, &before);
    CHECK(strstr(g_log, "64-bit fat") != NULL,
          "accepts: the refusal says the container is 64-bit fat (log: %s)", g_log);

    in_dir(path, sizeof path, "text");
    write_file(path, (const uint8_t *)"not a Mach-O at all\n", 20, 0644);
    before = take(path);
    rc = run(path, out, "load-command delete uuid\n");
    CHECK(rc == MR_REFUSED, "thin only: a non-Mach-O is refused (got %d)", rc);
    check_untouched("non-Mach-O input", path, &before);

    in_dir(path, sizeof path, "absent");
    int entries = dir_entries();
    rc = run(path, out, "load-command delete uuid\n");
    CHECK(rc == MR_FAIL, "thin only: an absent input is an error, MR_FAIL (got %d)", rc);
    CHECK(access(path, F_OK) != 0 && access(out, F_OK) != 0 && dir_entries() == entries,
          "thin only: neither the input nor OUT was created for an absent input");
    rm_dir();
}

static void test_fat_every_64bit_slice_by_default(void) {
    fresh_dir();
    char path[512], out[512], s0[512], s1[512], s2[512];
    in_dir(path, sizeof path, "fat"); in_dir(out, sizeof out, "fat.out");
    in_dir(s0, sizeof s0, "s0");
    in_dir(s1, sizeof s1, "s1"); in_dir(s2, sizeof s2, "s2");
    write_fat(path, 0, 0, 1);
    size_t stub_len; uint8_t *stub = build_i386_stub(&stub_len);
    int rc = run(path, out, "load-command delete uuid\n");
    CHECK(rc == 0, "fat, no arch: succeeds (got %d; log: %s)", rc, g_log);
    slice_to_file(out, 0, s0); slice_to_file(out, 1, s1); slice_to_file(out, 2, s2);
    CHECK(count_lc(s0, LC_UUID, NULL) == 0, "fat, no arch: the x86_64 slice lost LC_UUID");
    CHECK(count_lc(s1, LC_UUID, NULL) == 0, "fat, no arch: the arm64 slice lost LC_UUID");
    size_t l2; uint8_t *b2 = read_file(s2, &l2);
    CHECK(l2 == stub_len && memcmp(b2, stub, l2) == 0, "fat, no arch: the i386 slice is byte-identical");
    free(b2); free(stub);
    rm_dir();
}

static void test_fat_arch_selects_named_slices(void) {
    fresh_dir();
    char path[512], out[512], s0[512], s1[512], orig1[512];
    in_dir(path, sizeof path, "fat"); in_dir(out, sizeof out, "fat.out");
    in_dir(s0, sizeof s0, "s0");
    in_dir(s1, sizeof s1, "s1"); in_dir(orig1, sizeof orig1, "orig1");
    write_fat(path, 0, 0, 0);
    slice_to_file(path, 1, orig1);
    int rc = run(path, out, "arch x86_64\nload-command delete uuid\n");
    CHECK(rc == 0, "fat, arch x86_64: succeeds (got %d; log: %s)", rc, g_log);
    slice_to_file(out, 0, s0); slice_to_file(out, 1, s1);
    CHECK(count_lc(s0, LC_UUID, NULL) == 0, "fat, arch x86_64: the named slice was edited");
    size_t la, lb; uint8_t *a = read_file(orig1, &la), *b = read_file(s1, &lb);
    CHECK(la == lb && memcmp(a, b, la) == 0, "fat, arch x86_64: the arm64 slice is byte-identical");
    free(a); free(b);
    rm_dir();
}

static void test_arch_on_a_thin_file(void) {
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "thin");
    in_dir(out, sizeof out, "thin.out");
    uint8_t *img = build_image(0);
    write_file(path, img, IMG_SIZE, 0755);
    free(img);
    int rc = run(path, out, "arch x86_64\nload-command delete uuid\n");
    CHECK(rc == 0, "thin, arch x86_64: runs on an x86_64 image (got %d; log: %s)", rc, g_log);
    /* Not just "returned 0": a match must let the statements RUN. */
    CHECK(count_lc(out, LC_UUID, NULL) == 0,
          "thin, arch x86_64: the statements ran on the named image");
    img = build_image(0);
    write_file(path, img, IMG_SIZE, 0755);
    free(img);
    snap before = take(path);
    rc = run(path, out, "arch arm64\nload-command delete uuid\n");
    CHECK(rc == MR_REFUSED, "thin, arch arm64: an x86_64 image is refused (got %d)", rc);
    check_untouched("thin, arch arm64", path, &before);
    CHECK(strstr(g_log, "x86_64") != NULL, "thin, arch arm64: the refusal names the image's arch (log: %s)", g_log);
    rm_dir();
}

static void test_fat_missing_or_32bit_arch_is_refused(void) {
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "fat");
    in_dir(out, sizeof out, "fat.out");
    write_fat(path, 0, 0, 1);
    snap before = take(path);
    int rc = run(path, out, "arch arm64e\nload-command delete uuid\n");
    CHECK(rc == MR_REFUSED, "fat, arch arm64e: a slice the file lacks is refused (got %d)", rc);
    check_untouched("fat, missing arch", path, &before);
    CHECK(strstr(g_log, "x86_64, arm64, i386") != NULL,
          "fat, missing arch: the refusal lists the file's slices (log: %s)", g_log);
    before = take(path);
    rc = run(path, out, "arch i386\nload-command delete uuid\n");
    CHECK(rc == MR_REFUSED, "fat, arch i386: naming a 32-bit slice is refused (got %d)", rc);
    check_untouched("fat, 32-bit arch", path, &before);
    CHECK(strstr(g_log, "32-bit") != NULL, "fat, arch i386: the refusal says 32-bit (log: %s)", g_log);
    rm_dir();
}

/* Two missing arch names in one script must both be reported, not just the
 * first: the validation loop used to stop scanning as soon as one offender
 * set rc, so a script naming two missing arches got only one refusal line,
 * and the user learned about the second only after fixing the first. */
static void test_fat_two_missing_arch_names_are_both_reported(void) {
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "fat");
    in_dir(out, sizeof out, "fat.out");
    uint8_t *s[1]; size_t l[1];
    uint32_t ct[1] = { (uint32_t)CPU_TYPE_X86_64 };
    uint32_t cs[1] = { (uint32_t)CPU_SUBTYPE_X86_64_ALL };
    s[0] = build_image(0); l[0] = IMG_SIZE;
    size_t flen;
    uint8_t *fat = build_fat(1, s, l, ct, cs, &flen);
    write_file(path, fat, flen, 0755);
    free(s[0]); free(fat);

    snap before = take(path);
    int rc = run(path, out, "arch arm64\narch i386\nload-command delete uuid\n");
    CHECK(rc == MR_REFUSED, "fat, two missing arches: refused (got %d)", rc);
    check_untouched("fat, two missing arches", path, &before);
    CHECK(strstr(g_log, "has no arm64 slice (it has: x86_64)") != NULL,
          "fat, two missing arches: arm64's own refusal line appears (log: %s)", g_log);
    CHECK(strstr(g_log, "has no i386 slice (it has: x86_64)") != NULL,
          "fat, two missing arches: i386's own refusal line ALSO appears, not just the "
          "first offender (log: %s)", g_log);
    rm_dir();
}

static void test_fat_unmatched_counts_a_match_in_any_slice(void) {
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "fat");
    in_dir(out, sizeof out, "fat.out");
    write_fat(path, 0, NO_UUID, 0);   /* only the x86_64 slice has LC_UUID */
    int rc = run(path, out, "load-command delete uuid\n");
    CHECK(rc == 0, "fat, unmatched: a match in one slice is not a miss (got %d; log: %s)", rc, g_log);
    /* The same, with the miss FIRST: the verdict has to wait for the last
     * selected slice. Deciding in each slice would refuse this one and not
     * the case above, where the counts a later slice reads already carry an
     * earlier slice's match. */
    write_fat(path, NO_UUID, 0, 0);   /* only the arm64 slice has LC_UUID */
    rc = run(path, out, "load-command delete uuid\n");
    CHECK(rc == 0, "fat, unmatched: a match in a LATER slice is not a miss "
          "(got %d; log: %s)", rc, g_log);
    write_fat(path, NO_UUID, NO_UUID, 0);   /* neither has it */
    snap before = take(path);
    rc = run(path, out, "load-command delete uuid\n");
    CHECK(rc == MR_REFUSED, "fat, unmatched: matching in no slice refuses (got %d)", rc);
    check_untouched("fat, miss everywhere", path, &before);
    CHECK(strstr(g_log, "matched nothing in any selected slice") != NULL,
          "fat, unmatched: the refusal says it matched in no slice (log: %s)", g_log);
    rm_dir();
}

/* Anything refusing in any slice refuses the whole run, and nothing is
 * written. Two refusals reach that by different routes:
 *
 *   a statement the REWRITE itself refuses in the second slice -- here a
 *   `dylib append` whose load command does not fit that slice's header pad --
 *   so the statement fails and the refusal names the statement and the slice
 *   it was running in;
 *
 *   `fixups set classic` declares that it disturbs the base-relative values
 *   the verify checks, so that slice's own final verification applies; on an
 *   already-classic slice the statement itself passes, so every statement
 *   succeeds and what refuses is the SLICE's own final verification.
 *
 * Both must leave the container byte-identical.
 *
 * THE FIRST HALF USED TO BE `load-command delete uuid` over an IMPLAUSIBLE
 * arm64 slice, refused inside the rewrite's own plausibility gate. It no
 * longer is: that gate now runs only when the run disturbed the base-relative
 * values it checks (src/relations.h), and a load-command delete disturbs the
 * header pad and nothing else, so the statement SUCCEEDS on an implausible
 * slice. The property being pinned was never about mg_plausible -- it is that
 * a statement refused in a later slice aborts the whole run and says where --
 * so the operation moves to one that still refuses there, and only there. */
static void test_fat_a_refusal_in_the_second_slice_writes_nothing(void) {
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "fat");
    in_dir(out, sizeof out, "fat.out");

    /* Slice 0 has 496 bytes of header pad; slice 1 (labelled arm64) has NONE,
     * its one section starting exactly where its load commands end, and is a
     * dylib, which cannot grow. So one `dylib append` fits the first and
     * cannot fit the second, and the refusal that follows is the second
     * slice's alone. */
    uint8_t *s[2]; size_t l[2];
    uint32_t ct[2] = { (uint32_t)CPU_TYPE_X86_64, (uint32_t)CPU_TYPE_ARM64 };
    uint32_t cs[2] = { (uint32_t)CPU_SUBTYPE_X86_64_ALL, (uint32_t)CPU_SUBTYPE_ARM64_ALL };
    size_t flen;
    s[0] = build_image(0);                             l[0] = IMG_SIZE;
    s[1] = build_growable_image_at(GROWIMG_NO_PAD, 1); l[1] = GROWIMG_SIZE;
    ((struct mach_header_64 *)s[1])->filetype = MH_DYLIB;
    uint8_t *fat = build_fat(2, s, l, ct, cs, &flen);
    write_file(path, fat, flen, 0755);
    free(s[0]); free(s[1]); free(fat);

    snap before = take(path);
    int rc = run(path, out, "dylib append /usr/lib/libx.dylib\n");
    CHECK(rc == MR_REFUSED, "fat: a statement refused in the second slice refuses the "
          "run (got %d; log: %s)", rc, g_log);
    check_untouched("fat, second slice refused", path, &before);
    CHECK(strstr(g_log, "in slice arm64") != NULL,
          "fat: the refusal names the slice the statement was running in (log: %s)", g_log);
    /* The premise, not a restatement of it: slice 0 really could take this
     * append. Without that, a run refusing at slice 0 would satisfy the exit
     * code above while covering nothing about a LATER slice. */
    CHECK(strstr(g_log, "slice x86_64:") != NULL && strstr(g_log, "in slice x86_64") == NULL,
          "fat: the first slice ran the statement and did not refuse it (log: %s)", g_log);

    /* Reaching the SLICE's own final verification needs a statement that
     * disturbs something that verify checks: `fixups set classic` declares
     * MREL_BASE_REL, a rename declares nothing. Slice 0 is already classic and
     * plausible, so it passes; slice 1 is already classic and IMPLAUSIBLE, so
     * every statement succeeds and what refuses is that slice's own verify. */
    write_fat(path, DYLD_INFO, IMPLAUSIBLE | DYLD_INFO, 0);
    before = take(path);
    rc = run(path, out, "fixups set classic\n");
    CHECK(rc == MR_REFUSED, "fat: the second slice's own verification refuses the run "
          "(got %d; log: %s)", rc, g_log);
    check_untouched("fat, second slice failed verification", path, &before);
    CHECK(strstr(g_log, "refused at verification of slice arm64") != NULL,
          "fat: the refusal names verification and the slice (log: %s)", g_log);
    rm_dir();
}

/* THE COVERAGE GAP: src/edit.c's mapping of mfat_rewrite's own
 * MFAT_MALFORMED/MFAT_IO_ERROR to MR_REFUSED/MR_FAIL, with the "could not
 * lay out ...'s slices again" message, and the re-parse of the reassembled
 * container right after. Every other fat refusal test above is a SLICE
 * refusing itself (a statement, or that slice's own verify); this is the
 * one where every slice's own work succeeds and the CONTAINER-level
 * reassembly is what refuses -- fat_test.c covers that refusal inside
 * mfat_rewrite itself, but nothing exercises edit.c's translation of it.
 *
 * The fixture is fat_test's non-ascending-overlap shape (slice 0 at the
 * higher file offset, slice 1 at the lower), reused here with two real
 * Mach-O slices -- so `edit` actually reaches reassembly -- instead of
 * fat_test's hand-built non-Mach-O bytes. Slice 1 (x86_64-labeled, the low
 * one) is the growable image just above, placed with no gap below slice 0
 * (arm64-labeled, untouched): growing slice 1 at all runs it into slice 0,
 * which mfat_rewrite refuses rather than guess a different layout. */
static void test_fat_reassembly_refusal_leaves_the_file_untouched(void) {
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "fat");
    in_dir(out, sizeof out, "fat.out");

    uint8_t *hi = build_image(0);           /* untouched; any valid slice will do */
    uint8_t *lo = build_growable_image();   /* the one the script grows */
    size_t hi_len = IMG_SIZE, lo_len = GROWIMG_SIZE;
    uint32_t lo_off = 0x1000;
    uint32_t hi_off = lo_off + (uint32_t)((lo_len + 0xfff) & ~(size_t)0xfff);
    size_t total = hi_off + hi_len;
    uint8_t *fat = (uint8_t *)calloc(1, total);
    struct fat_header *fh = (struct fat_header *)fat;
    fh->magic = OSSwapHostToBigInt32(FAT_MAGIC);
    fh->nfat_arch = OSSwapHostToBigInt32(2);
    struct fat_arch *fa = (struct fat_arch *)(fh + 1);
    fa[0].cputype = (cpu_type_t)OSSwapHostToBigInt32((uint32_t)CPU_TYPE_ARM64);
    fa[0].cpusubtype = (cpu_subtype_t)OSSwapHostToBigInt32((uint32_t)CPU_SUBTYPE_ARM64_ALL);
    fa[0].offset = OSSwapHostToBigInt32(hi_off);
    fa[0].size = OSSwapHostToBigInt32((uint32_t)hi_len);
    fa[0].align = OSSwapHostToBigInt32(12);
    fa[1].cputype = (cpu_type_t)OSSwapHostToBigInt32((uint32_t)CPU_TYPE_X86_64);
    fa[1].cpusubtype = (cpu_subtype_t)OSSwapHostToBigInt32((uint32_t)CPU_SUBTYPE_X86_64_ALL);
    fa[1].offset = OSSwapHostToBigInt32(lo_off);
    fa[1].size = OSSwapHostToBigInt32((uint32_t)lo_len);
    fa[1].align = OSSwapHostToBigInt32(12);
    memcpy(fat + hi_off, hi, hi_len);
    memcpy(fat + lo_off, lo, lo_len);
    write_file(path, fat, total, 0755);
    free(hi); free(lo); free(fat);

    /* 300 bytes of path: comfortably past the growable slice's small header
     * pad (GROWIMG_SECTOFF minus its fixed load commands), so the append
     * grows it by a page -- which the fixed slice right above it, with no
     * gap, has no room for. */
    char longpath[320];
    memset(longpath, 'x', sizeof longpath);
    longpath[0] = '/';
    longpath[300] = '\0';
    char script[512];
    snprintf(script, sizeof script, "arch x86_64\ndylib append %s\n", longpath);

    snap before = take(path);
    int rc = run(path, out, script);
    CHECK(rc == MR_REFUSED, "fat reassembly: a non-ascending grow that would overlap is "
          "refused (got %d; log: %s)", rc, g_log);
    check_untouched("fat reassembly", path, &before);
    CHECK(strstr(g_log, "could not lay out") != NULL,
          "fat reassembly: the \"could not lay out\" line is produced (log: %s)", g_log);
    CHECK(strstr(g_log, "left unmodified") != NULL,
          "fat reassembly: the line says PATH was left unmodified (log: %s)", g_log);
    rm_dir();
}

/* Without `arch`, the default selection is every 64-bit slice -- and a
 * container that has none leaves the script nothing to apply to. Only
 * reachable without `arch`: a named row has already been proved present and
 * 64-bit by the time this check runs. */
static void test_fat_with_no_64bit_slice_is_refused(void) {
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "fat32");
    in_dir(out, sizeof out, "fat32.out");
    uint8_t *s[2]; size_t l[2];
    uint32_t ct[2] = { (uint32_t)CPU_TYPE_I386, (uint32_t)CPU_TYPE_I386 };
    uint32_t cs[2] = { (uint32_t)CPU_SUBTYPE_I386_ALL, (uint32_t)CPU_SUBTYPE_I386_ALL };
    size_t flen;
    uint8_t *fat;
    s[0] = build_i386_stub(&l[0]);
    s[1] = build_i386_stub(&l[1]);
    fat = build_fat(2, s, l, ct, cs, &flen);
    write_file(path, fat, flen, 0755);
    free(s[0]); free(s[1]); free(fat);

    snap before = take(path);
    int rc = run(path, out, "load-command delete uuid\n");
    CHECK(rc == MR_REFUSED, "fat, all 32-bit: a container with no 64-bit slice is "
          "refused (got %d)", rc);
    check_untouched("fat, all 32-bit", path, &before);
    CHECK(strstr(g_log, "has no 64-bit slice to edit (it has: i386, i386)") != NULL,
          "fat, all 32-bit: the refusal says so and lists the slices (log: %s)", g_log);
    rm_dir();
}

static void test_fat_report_accounts_for_every_slice(void) {
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "fat");
    in_dir(out, sizeof out, "fat.out");
    write_fat(path, 0, 0, 1);
    int rc = run(path, out, "arch x86_64\nload-command delete uuid\n");
    CHECK(rc == 0, "fat, report: succeeds (got %d)", rc);
    CHECK(strstr(g_log, "slice x86_64:\n") != NULL, "fat, report: the edited slice's header (log: %s)", g_log);
    CHECK(strstr(g_log, "slice x86_64: this run disturbed sizeofcmds; "
                        "none of that is re-checked") != NULL,
          "fat, report: the edited slice reports its verify decision (log: %s)", g_log);
    CHECK(strstr(g_log, "slice arm64: not selected by arch; passed through unchanged") != NULL,
          "fat, report: the unselected slice is accounted for (log: %s)", g_log);
    CHECK(strstr(g_log, "slice i386: 32-bit; passed through unchanged") != NULL,
          "fat, report: the 32-bit slice is accounted for (log: %s)", g_log);
    rm_dir();
}

/* A fat run writes OUT and leaves the container it read alone, exactly as a
 * thin one does: the write happens once, to the whole container, after every
 * selected slice has verified. */
static void test_fat_writes_out_and_not_the_input(void) {
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "fat");
    in_dir(out, sizeof out, "fat.out");
    write_fat(path, 0, 0, 0);
    snap before = take(path);
    before.entries++;   /* OUT is the one expected newcomer */
    int rc = run(path, out, "load-command delete uuid\n");
    CHECK(rc == 0, "fat, OUT: succeeds (got %d; log: %s)", rc, g_log);
    check_untouched("fat, OUT: the input", path, &before);
    {
        char s0[512];
        in_dir(s0, sizeof s0, "s0");
        slice_to_file(out, 0, s0);
        CHECK(count_lc(s0, LC_UUID, NULL) == 0, "fat, OUT: the edit landed in OUT's slices");
    }
    rm_dir();
}

/* RELATIONS ARE PER SLICE, so the accumulator is too. A slice that
 * disturbed nothing the verify checks skips its own verify whatever its
 * NEIGHBOURS did -- which one accumulator shared across the container would
 * get wrong, and would get wrong silently, since the shared answer is the
 * conservative one and every existing assertion would stay green.
 *
 * The two slices run the same statement and disturb different things, which
 * only the OBSERVED half can produce: slice 0 has no header pad at all, so
 * `version-min set 10.9` must grow it -- a grow re-bases
 * every base-relative value (MREL_BASE_REL) -- while slice 1 has 496 bytes
 * spare and the same statement only repacks its header (MREL_HEADER_PAD).
 * Slice 1 is the IMPLAUSIBLE image, so a gate that applied there would refuse
 * the whole run: with the accumulator shared, slice 0's grow decides slice 1's
 * verify and this run exits 1 having written nothing.
 *
 * The same fixture pins the OBSERVED half of the accumulator, which nothing
 * else can: slice 0 carries an LC_FUNCTION_STARTS, so its own gate applies and
 * it reports "verified" -- and the only thing that made it apply is the grow,
 * since `version-min set 10.9` DECLARES only MREL_HEADER_PAD. An accumulator
 * that read declared masks alone would report the skip line for slice 0 too,
 * and would skip the verify after every header grow there is. */
static void test_fat_a_slice_skips_its_verify_on_its_own_terms(void) {
    fresh_dir();
    char path[512], out[512], s0[512];
    in_dir(path, sizeof path, "fat");
    in_dir(out, sizeof out, "fat.out");
    in_dir(s0, sizeof s0, "s0");

    uint8_t *s[2]; size_t l[2];
    uint32_t ct[2] = { (uint32_t)CPU_TYPE_X86_64, (uint32_t)CPU_TYPE_ARM64 };
    uint32_t cs[2] = { (uint32_t)CPU_SUBTYPE_X86_64_ALL, (uint32_t)CPU_SUBTYPE_ARM64_ALL };
    size_t flen;
    s[0] = build_growable_image_at(GROWIMG_NO_PAD, 1); l[0] = GROWIMG_SIZE;
    s[1] = build_image(IMPLAUSIBLE);                   l[1] = IMG_SIZE;
    uint8_t *fat = build_fat(2, s, l, ct, cs, &flen);
    write_file(path, fat, flen, 0755);
    free(s[0]); free(s[1]); free(fat);

    int rc = run(path, out, "version-min set 10.9\n");
    CHECK(rc == 0, "per slice: a slice that disturbed nothing it checks is not refused "
          "for what another slice did (got %d; log: %s)", rc, g_log);
    CHECK(strstr(g_log, "slice arm64: this run disturbed sizeofcmds; "
                        "none of that is re-checked") != NULL,
          "per slice: the untouched-relation slice skipped its own verify (log: %s)", g_log);
    CHECK(strstr(g_log, "slice x86_64: verified") != NULL,
          "observed, not declared: the slice whose header grew was verified, though "
          "its statement declares only the header pad (log: %s)", g_log);
    /* The premise, not a restatement of it: slice 0 really did grow, so there
     * really was a disturbance for a shared accumulator to leak. */
    if (rc == 0) {
        size_t grown = 0;
        slice_to_file(out, 0, s0);
        uint8_t *g = read_file(s0, &grown);
        CHECK(g && grown > GROWIMG_SIZE,
              "per slice: slice 0 grew its header pad, so there was something to leak "
              "(%zu bytes, was %u)", grown, (unsigned)GROWIMG_SIZE);
        free(g);
    }
    rm_dir();
}

/* The skip line has to answer "why was my file not verified?" on its own, so
 * it NAMES what the run disturbed, in src/relations.h's words (mrel_name).
 * Asserting the whole line, not that some line was printed: a report that
 * named the wrong relation, or dropped a name from the list, would read just
 * as plausibly as the right one to whoever is holding the failure.
 *
 * `dylib delete` is the fixture-independent way to reach a two-name list: it
 * declares MREL_ORDINAL | MREL_HEADER_PAD and no base-relative movement, so
 * the gate still does not apply, and it names the bit order too -- the list
 * runs low bit first, whatever order the statements were written in. It
 * matches nothing in this image, which is exactly the point: what a statement
 * DECLARES is disturbed is what the report has to say -- so the script says
 * allow-unmatched, or the miss would refuse the run before the report. */
static void test_the_skip_line_names_what_the_run_disturbed(void) {
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "img");
    in_dir(out, sizeof out, "img.out");
    uint8_t *img = build_image(0);
    write_file(path, img, IMG_SIZE, 0755);
    free(img);

    int rc = run(path, out, "allow-unmatched\ndylib delete /x.dylib\nload-command delete uuid\n");
    CHECK(rc == 0, "skip line: the run succeeds (got %d; log: %s)", rc, g_log);
    CHECK(strstr(g_log, ": this run disturbed library ordinal, sizeofcmds; "
                        "none of that is re-checked\n") != NULL,
          "skip line: it names every relation the run disturbed, low bit first "
          "(log: %s)", g_log);
    rm_dir();
}

static void test_minos_set_rewrites_the_declared_minimum_in_place(void) {
    fresh_dir();
    char path[512], o1[512], o2[512], o3[512], o4[512], o5[512];
    in_dir(path, sizeof path, "img");
    in_dir(o1, sizeof o1, "o1"); in_dir(o2, sizeof o2, "o2");
    in_dir(o3, sizeof o3, "o3"); in_dir(o4, sizeof o4, "o4");
    in_dir(o5, sizeof o5, "o5");

    uint8_t *img = build_image(VMIN_1012);
    write_file(path, img, IMG_SIZE, 0755);
    int rc = run(path, o1, "minos set 10.9\n");
    CHECK(rc == 0, "minos set: a 10.12 version-min is lowered (got %d; log: %s)", rc, g_log);
    CHECK(lc_word(o1, LC_VERSION_MIN_MACOSX, 2) == 0x000A0900,
          "minos set: version is 10.9 (got 0x%08x)", lc_word(o1, LC_VERSION_MIN_MACOSX, 2));
    CHECK(lc_word(o1, LC_VERSION_MIN_MACOSX, 3) == 0x000A0D00,
          "minos set: sdk is still 10.13 (got 0x%08x)", lc_word(o1, LC_VERSION_MIN_MACOSX, 3));
    {
        size_t len = 0, diff = 0;
        uint8_t *now = read_file(o1, &len);
        for (size_t i = 0; now && i < len && i < IMG_SIZE; i++) diff += now[i] != img[i];
        CHECK(now && len == IMG_SIZE && diff == 1,
              "minos set: in place, one byte changed (size %zu, %zu differ)", len, diff);
        free(now);
    }
    CHECK(strstr(g_log, "  minos set 10.9\n      version-min 10.12 -> 10.9\n") != NULL,
          "minos set: the report says old -> new beneath the statement (log: %s)", g_log);
    rc = run(o1, o5, "minos set 10.9\n");
    CHECK(rc == 0 && strstr(g_log, "      version-min 10.9 -> 10.9\n") != NULL,
          "minos set: run again on its own output, an equal value has matched (got %d; log: %s)",
          rc, g_log);
    {
        size_t l1 = 0, l5 = 0;
        uint8_t *b1 = read_file(o1, &l1), *b5 = read_file(o5, &l5);
        CHECK(b1 && b5 && l1 == l5 && memcmp(b1, b5, l1) == 0,
              "minos set: run again on its own output, the file is unchanged");
        free(b1); free(b5);
    }
    rc = run(path, o2, "minos set 10.13\n");
    CHECK(rc == 0 && lc_word(o2, LC_VERSION_MIN_MACOSX, 2) == 0x000A0D00,
          "minos set: an explicit statement may raise (got %d; log: %s)", rc, g_log);
    free(img);

    img = build_image(BUILDVER_12);
    write_file(path, img, IMG_SIZE, 0755);
    rc = run(path, o3, "minos set 10.9\n");
    CHECK(rc == 0, "minos set: a macOS build-version is lowered (got %d; log: %s)", rc, g_log);
    CHECK(lc_word(o3, LC_BUILD_VERSION, 3) == 0x000A0900 &&
          lc_word(o3, LC_BUILD_VERSION, 4) == 0x000C0300 &&
          lc_word(o3, LC_BUILD_VERSION, 2) == 1,
          "minos set: build-version minos is 10.9; sdk and platform untouched");
    CHECK(count_lc(o3, LC_VERSION_MIN_MACOSX, NULL) == 0,
          "minos set: appends no LC_VERSION_MIN_MACOSX");
    CHECK(strstr(g_log, "      build-version minos 12.0 -> 10.9\n") != NULL,
          "minos set: the build-version report line (log: %s)", g_log);
    free(img);

    img = build_image(VMIN_1012 | BUILDVER_12);
    write_file(path, img, IMG_SIZE, 0755);
    rc = run(path, o4, "minos set 10.9\n");
    CHECK(rc == 0 && lc_word(o4, LC_VERSION_MIN_MACOSX, 2) == 0x000A0900 &&
          lc_word(o4, LC_BUILD_VERSION, 3) == 0x000A0900,
          "minos set: both declarations are lowered (got %d; log: %s)", rc, g_log);
    free(img);
    rm_dir();
}

static void test_minos_set_with_nothing_declared_is_a_miss(void) {
    fresh_dir();
    char path[512], out[512], out2[512];
    in_dir(path, sizeof path, "img");
    in_dir(out, sizeof out, "img.out");
    in_dir(out2, sizeof out2, "img.out2");

    uint8_t *img = build_image(0);
    write_file(path, img, IMG_SIZE, 0755);
    free(img);
    snap before = take(path);
    int rc = run(path, out, "minos set 10.9\n");
    CHECK(rc == MR_REFUSED, "minos set: nothing declared refuses by default (got %d)", rc);
    check_untouched("minos set miss", path, &before);
    CHECK(strstr(g_log, "      no LC_VERSION_MIN_MACOSX or macOS LC_BUILD_VERSION to set\n") != NULL,
          "minos set: the report says there was nothing to set (log: %s)", g_log);
    rc = run(path, out, "allow-unmatched\nminos set 10.9\n");
    CHECK(rc == 0 && count_lc(out, LC_VERSION_MIN_MACOSX, NULL) == 0 &&
          count_lc(out, LC_BUILD_VERSION, NULL) == 0,
          "minos set: allowed to miss, it still appends nothing (got %d)", rc);

    img = build_image(BUILDVER_IOS);
    write_file(path, img, IMG_SIZE, 0755);
    free(img);
    before = take(path);
    rc = run(path, out2, "minos set 10.9\n");
    CHECK(rc == MR_REFUSED, "minos set: an iOS build-version is not a macOS minimum (got %d)", rc);
    check_untouched("minos set on iOS build-version", path, &before);
    rm_dir();
}

static void test_target_with_both_commands_lets_version_min_decide(void) {
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "img");
    in_dir(out, sizeof out, "img.out");
    uint8_t *img = build_image(VMIN_1012 | BUILDVER_12);
    write_file(path, img, IMG_SIZE, 0755);
    free(img);
    int rc = run(path, out, "target 10.9\n");
    CHECK(rc == 0, "target, both commands: runs (got %d; log: %s)", rc, g_log);
    CHECK(strstr(g_log, "    minimum: version-min 10.12 -> 10.9; sdk 10.13 untouched\n") != NULL,
          "target, both commands: the version-min decides the minimum line (log: %s)", g_log);
    CHECK(count_lc(out, LC_BUILD_VERSION, NULL) == 0 &&
          lc_word(out, LC_VERSION_MIN_MACOSX, 2) == 0x000A0900 &&
          lc_word(out, LC_VERSION_MIN_MACOSX, 3) == 0x000A0D00,
          "target, both commands: build-version deleted, version-min 10.9 with sdk 10.13 kept");
    rm_dir();
}

static void test_mv_format_version_drops_a_zero_patch(void) {
    char b[16];
    mv_format_version(0x000A0C00, b);
    CHECK(strcmp(b, "10.12") == 0, "0x000A0C00 formats as 10.12 (got %s)", b);
    mv_format_version(0x000A0905, b);
    CHECK(strcmp(b, "10.9.5") == 0, "0x000A0905 formats as 10.9.5 (got %s)", b);
    mv_format_version(0x000B0000, b);
    CHECK(strcmp(b, "11.0") == 0, "0x000B0000 formats as 11.0 (got %s)", b);
}

static void test_fat_minos_set_matches_in_any_slice(void) {
    fresh_dir();
    char path[512], out[512], s1[512];
    in_dir(path, sizeof path, "fat");
    in_dir(out, sizeof out, "fat.out");
    in_dir(s1, sizeof s1, "s1");
    write_fat(path, 0, VMIN_1012, 0);   /* only the second slice declares one */
    int rc = run(path, out, "minos set 10.9\n");
    CHECK(rc == 0, "fat, minos set: a declaration in a later slice is a match (got %d; log: %s)",
          rc, g_log);
    if (rc == 0) {
        slice_to_file(out, 1, s1);
        CHECK(lc_word(s1, LC_VERSION_MIN_MACOSX, 2) == 0x000A0900,
              "fat, minos set: the second slice was lowered");
    }
    write_fat(path, 0, 0, 0);
    snap before = take(path);
    rc = run(path, out, "minos set 10.9\n");
    CHECK(rc == MR_REFUSED, "fat, minos set: declared in no slice refuses (got %d)", rc);
    check_untouched("fat, minos set miss everywhere", path, &before);
    CHECK(strstr(g_log, "matched nothing in any selected slice") != NULL,
          "fat, minos set: the refusal says no slice matched (log: %s)", g_log);
    rm_dir();
}

static void test_minos_decides_the_minimum_per_rule(void) {
    static const struct {
        const char *script; int flags; uint32_t poke_cmd, poke_field, poke_value;
        uint32_t want_version, want_sdk; const char *line;
    } rows[] = {
        { "minos at-most 10.9\n", VMIN_1012, 0, 0, 0, 0x000A0900, 0x000A0D00,
          "  minos at-most 10.9\n      version-min 10.12 -> 10.9; sdk 10.13 kept\n" },
        { "minos at-most 10.9\n", VMIN_1012, LC_VERSION_MIN_MACOSX, 2, 0x000A0700,
          0x000A0700, 0x000A0D00, "      version-min 10.7, at or below 10.9: kept; sdk 10.13 kept\n" },
        { "minos at-most 10.9\n", VMIN_1012, LC_VERSION_MIN_MACOSX, 2, 0x000A0905,
          0x000A0905, 0x000A0D00, "      version-min 10.9.5, at or below 10.9: kept; sdk 10.13 kept\n" },
        { "minos at-most 10.9.3\n", VMIN_1012, LC_VERSION_MIN_MACOSX, 2, 0x000A0905,
          0x000A0903, 0x000A0D00, "      version-min 10.9.5 -> 10.9.3; sdk 10.13 kept\n" },
        { "minos at-most 10.9\n", BUILDVER_12, 0, 0, 0, 0x000A0900, 0x000C0300,
          "      build-version 12.0 -> version-min 10.9; sdk 12.3 carried over\n" },
        { "minos at-most 10.9\n", BUILDVER_12, LC_BUILD_VERSION, 3, 0x000A0700,
          0x000A0700, 0x000C0300, "      build-version 10.7 -> version-min 10.7; sdk 12.3 carried over\n" },
        { "minos at-most 10.9\n", 0, 0, 0, 0, 0x000A0900, 0x000A0900,
          "      none -> version-min 10.9; sdk 10.9 written\n" },
        { "minos at-most 10.7\n", 0, 0, 0, 0, 0x000A0700, 0x000A0900,
          "      none -> version-min 10.7; sdk 10.9 written\n" },
        { "minos if-absent 10.9\n", VMIN_1012, 0, 0, 0, 0x000A0C00, 0x000A0D00,
          "      version-min 10.12 kept (declared); sdk 10.13 kept\n" },
        { "minos if-absent 10.9\n", VMIN_1012, LC_VERSION_MIN_MACOSX, 2, 0x000A0700,
          0x000A0700, 0x000A0D00, "      version-min 10.7, at or below 10.9: kept; sdk 10.13 kept\n" },
        { "minos if-absent 10.9\n", BUILDVER_12, 0, 0, 0, 0x000C0000, 0x000C0300,
          "      build-version 12.0 -> version-min 12.0; sdk 12.3 carried over\n" },
        { "minos if-absent 10.9\n", BUILDVER_12, LC_BUILD_VERSION, 3, 0x000A0700,
          0x000A0700, 0x000C0300, "      build-version 10.7 -> version-min 10.7; sdk 12.3 carried over\n" },
        { "minos if-absent 10.9\n", 0, 0, 0, 0, 0x000A0900, 0x000A0900,
          "      none -> version-min 10.9; sdk 10.9 written\n" },
        { "minos at-most 10.9\n", VMIN_1012 | BUILDVER_12, 0, 0, 0, 0x000A0900, 0x000A0D00,
          "      version-min 10.12 -> 10.9; sdk 10.13 kept; build-version 12.0 removed\n" },
        { "minos at-most 10.9\n", BUILDVER_12 | CATALYST, 0, 0, 0, 0x000A0900, 0x000C0300,
          "      build-version 12.0 -> version-min 10.9; sdk 12.3 carried over; "
          "Mac Catalyst build-version removed\n" },
    };
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "img");
    in_dir(out, sizeof out, "img.out");
    for (size_t i = 0; i < sizeof rows / sizeof *rows; i++) {
        uint8_t *img = build_image(rows[i].flags);
        if (rows[i].poke_cmd) poke_lc(img, rows[i].poke_cmd, 0, rows[i].poke_field, rows[i].poke_value);
        write_file(path, img, IMG_SIZE, 0755);
        free(img);
        int rc = run(path, out, rows[i].script);
        CHECK(rc == 0, "row %zu, %s: runs (got %d; log: %s)", i, rows[i].script, rc, g_log);
        CHECK(count_lc(out, LC_VERSION_MIN_MACOSX, NULL) == 1 &&
              count_lc(out, LC_BUILD_VERSION, NULL) == 0,
              "row %zu: one LC_VERSION_MIN_MACOSX and no LC_BUILD_VERSION after it", i);
        CHECK(lc_word(out, LC_VERSION_MIN_MACOSX, 2) == rows[i].want_version &&
              lc_word(out, LC_VERSION_MIN_MACOSX, 3) == rows[i].want_sdk,
              "row %zu: version-min 0x%08x sdk 0x%08x (got 0x%08x sdk 0x%08x)", i,
              rows[i].want_version, rows[i].want_sdk, lc_word(out, LC_VERSION_MIN_MACOSX, 2),
              lc_word(out, LC_VERSION_MIN_MACOSX, 3));
        CHECK(strstr(g_log, rows[i].line) != NULL,
              "row %zu: the report says %s(log: %s)", i, rows[i].line, g_log);
    }
    rm_dir();
}

static void test_minos_leaves_a_declared_10_9_byte_for_byte(void) {
    fresh_dir();
    char path[512], out[512], out2[512];
    in_dir(path, sizeof path, "img");
    in_dir(out, sizeof out, "img.out");
    in_dir(out2, sizeof out2, "img.out2");
    uint8_t *img = build_image(VMIN_1012);
    poke_lc(img, LC_VERSION_MIN_MACOSX, 0, 2, 0x000A0900);
    write_file(path, img, IMG_SIZE, 0755);
    free(img);
    int rc = run(path, out, "minos at-most 10.9\n");
    CHECK(rc == 0 && same_file(path, out), "at-most leaves a version-min 10.9 byte for byte (got %d)", rc);
    rc = run(path, out, "minos if-absent 10.9\n");
    CHECK(rc == 0 && same_file(path, out), "if-absent does too (got %d)", rc);
    img = build_image(VMIN_1012 | BUILDVER_12);
    write_file(path, img, IMG_SIZE, 0755);
    free(img);
    rc = run(path, out, "minos at-most 10.9\n");
    CHECK(rc == 0 && !same_file(path, out), "at-most lowers and converts that image (got %d)", rc);
    rc = run(out, out2, "minos at-most 10.9\n");
    CHECK(rc == 0 && same_file(out, out2), "run again on its own output it changes nothing (got %d)", rc);
    rm_dir();
}

static void test_minos_refuses_what_is_not_one_macos_declaration(void) {
    static const struct { int flags; uint32_t second_bv_platform; const char *what; } rows[] = {
        { BUILDVER_IOS, 0, "an iOS-only slice" },
        { VMIN_1012 | SECOND_VMIN, 0, "two LC_VERSION_MIN_MACOSX" },
        { BUILDVER_12 | CATALYST, MV_PLATFORM_MACOS, "two macOS LC_BUILD_VERSION" },
        { VMIN_1012 | BUILDVER_IOS, 0, "an iOS LC_BUILD_VERSION beside a macOS version-min" },
    };
    static const char *scripts[] = { "minos at-most 10.9\n", "minos if-absent 10.9\n" };
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "img");
    in_dir(out, sizeof out, "img.out");
    for (size_t i = 0; i < sizeof rows / sizeof *rows; i++) {
        for (size_t j = 0; j < 2; j++) {
            uint8_t *img = build_image(rows[i].flags);
            if (rows[i].second_bv_platform)
                poke_lc(img, LC_BUILD_VERSION, 1, 2, rows[i].second_bv_platform);
            write_file(path, img, IMG_SIZE, 0755);
            free(img);
            snap before = take(path);
            int rc = run(path, out, scripts[j]);
            CHECK(rc == MR_REFUSED, "%s, %s: refused (got %d; log: %s)",
                  rows[i].what, scripts[j], rc, g_log);
            check_untouched(rows[i].what, path, &before);
        }
    }
    rm_dir();
}

static void test_fat_minos_decides_per_slice(void) {
    fresh_dir();
    char path[512], out[512], s0[512], s1[512], in1[512];
    in_dir(path, sizeof path, "fat");
    in_dir(out, sizeof out, "fat.out");
    in_dir(s0, sizeof s0, "s0");
    in_dir(s1, sizeof s1, "s1");
    in_dir(in1, sizeof in1, "in1");
    write_fat(path, VMIN_1012, BUILDVER_12, 0);
    int rc = run(path, out, "minos at-most 10.9\n");
    CHECK(rc == 0, "fat, minos at-most: runs (got %d; log: %s)", rc, g_log);
    slice_to_file(out, 0, s0);
    slice_to_file(out, 1, s1);
    CHECK(lc_word(s0, LC_VERSION_MIN_MACOSX, 2) == 0x000A0900 &&
          lc_word(s0, LC_VERSION_MIN_MACOSX, 3) == 0x000A0D00,
          "fat: slice 0's version-min 10.12 is lowered to 10.9, sdk 10.13 kept");
    CHECK(count_lc(s1, LC_BUILD_VERSION, NULL) == 0 &&
          lc_word(s1, LC_VERSION_MIN_MACOSX, 2) == 0x000A0900 &&
          lc_word(s1, LC_VERSION_MIN_MACOSX, 3) == 0x000C0300,
          "fat: slice 1's build-version 12.0 becomes version-min 10.9, sdk 12.3 carried over");
    rc = run(path, out, "arch x86_64\nminos at-most 10.9\n");
    slice_to_file(path, 1, in1);
    slice_to_file(out, 0, s0);
    slice_to_file(out, 1, s1);
    CHECK(rc == 0 && same_file(in1, s1),
          "fat, arch x86_64: the arm64 slice passes through byte for byte (got %d)", rc);
    CHECK(lc_word(s0, LC_VERSION_MIN_MACOSX, 2) == 0x000A0900,
          "fat, arch x86_64: ... and the x86_64 slice is lowered");
    rm_dir();
}

int main(void) {
    test_statements_apply_in_order();
    test_a_failure_part_way_writes_nothing();
    test_out_that_is_the_input_is_refused();
    test_an_empty_script_disturbs_nothing_and_is_passed_through();
    test_the_final_verify_ignores_MACHO_NO_VERIFY();
    test_later_statements_see_earlier_ones();
    test_dylib_retype_rewrites_the_load_command_kind();
    test_an_unmatched_operation_refuses_by_default();
    test_an_unmatched_segment_rename_refuses_by_default();
    test_the_file_level_operations_run_in_memory();
    test_out_takes_the_inputs_mode();
    test_what_edit_accepts();
    test_fat_every_64bit_slice_by_default();
    test_fat_arch_selects_named_slices();
    test_arch_on_a_thin_file();
    test_fat_missing_or_32bit_arch_is_refused();
    test_fat_two_missing_arch_names_are_both_reported();
    test_fat_unmatched_counts_a_match_in_any_slice();
    test_fat_a_refusal_in_the_second_slice_writes_nothing();
    test_fat_reassembly_refusal_leaves_the_file_untouched();
    test_fat_with_no_64bit_slice_is_refused();
    test_fat_report_accounts_for_every_slice();
    test_fat_writes_out_and_not_the_input();
    test_fat_a_slice_skips_its_verify_on_its_own_terms();
    test_the_skip_line_names_what_the_run_disturbed();
    test_minos_set_rewrites_the_declared_minimum_in_place();
    test_minos_set_with_nothing_declared_is_a_miss();
    test_target_with_both_commands_lets_version_min_decide();
    test_fat_minos_set_matches_in_any_slice();
    test_mv_format_version_drops_a_zero_patch();
    test_minos_decides_the_minimum_per_rule();
    test_minos_leaves_a_declared_10_9_byte_for_byte();
    test_minos_refuses_what_is_not_one_macos_declaration();
    test_fat_minos_decides_per_slice();

    printf("edit_test: %d failure(s)\n", fails);
    return fails ? 1 : 0;
}
