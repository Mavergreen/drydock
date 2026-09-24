/* tests/mkminos.c -- write or read the minimum OS version a Mach-O declares,
 * by direct structure surgery, so no test certifies its premise with the tool
 * under test.
 *
 *   mkminos none FILE                       remove every LC_VERSION_MIN_MACOSX
 *                                           and LC_BUILD_VERSION
 *   mkminos vmin FILE VERSION SDK           ... then append LC_VERSION_MIN_MACOSX
 *   mkminos bv FILE PLATFORM MINOS SDK      ... then append LC_BUILD_VERSION, no tools
 *   mkminos add-bv FILE PLATFORM MINOS SDK  append LC_BUILD_VERSION, removing nothing
 *   mkminos show FILE                       one line per such command, or "none"
 *
 * Versions are X.Y or X.Y.Z. FILE is edited in place. Exit 0, or 2 on any
 * error, including a header pad too short for the appended command. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <mach-o/loader.h>

#ifndef LC_BUILD_VERSION
#define LC_BUILD_VERSION 0x32
#endif

static uint8_t *buf;
static size_t size;

static int load(const char *path) {
    struct stat st;
    int fd = open(path, O_RDONLY);
    if (fd < 0 || fstat(fd, &st) != 0) { perror(path); return -1; }
    size = (size_t)st.st_size;
    buf = malloc(size);
    if (!buf || read(fd, buf, size) != (ssize_t)size) {
        fprintf(stderr, "%s: read failed\n", path); close(fd); return -1;
    }
    close(fd);
    if (size < sizeof(struct mach_header_64) ||
        ((struct mach_header_64 *)buf)->magic != MH_MAGIC_64) {
        fprintf(stderr, "%s: not a 64-bit Mach-O\n", path); return -1;
    }
    return 0;
}

static int save(const char *path) {
    int fd = open(path, O_WRONLY | O_TRUNC);
    if (fd < 0 || write(fd, buf, size) != (ssize_t)size) { perror(path); return -1; }
    close(fd);
    return 0;
}

static int version(const char *s, uint32_t *out) {
    unsigned x = 0, y = 0, z = 0;
    if (sscanf(s, "%u.%u.%u", &x, &y, &z) < 2 || x > 0xffff || y > 0xff || z > 0xff) {
        fprintf(stderr, "bad version '%s'\n", s); return -1;
    }
    *out = x << 16 | y << 8 | z;
    return 0;
}

static void strip_all(void) {
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    uint8_t *p = buf + sizeof *h;
    uint32_t end = (uint32_t)sizeof *h + h->sizeofcmds, i = 0;
    while (i < h->ncmds) {
        struct load_command *lc = (struct load_command *)p;
        uint32_t sz = lc->cmdsize;
        if (lc->cmd == LC_VERSION_MIN_MACOSX || lc->cmd == LC_BUILD_VERSION) {
            memmove(p, p + sz, end - (uint32_t)(p - buf) - sz);
            memset(buf + end - sz, 0, sz);
            end -= sz; h->ncmds--; h->sizeofcmds -= sz;
            continue;
        }
        p += sz; i++;
    }
}

static uint32_t pad_end(void) {
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    uint8_t *p = buf + sizeof *h;
    uint32_t lo = (uint32_t)size;
    for (uint32_t i = 0; i < h->ncmds; i++) {
        struct load_command *lc = (struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *sg = (struct segment_command_64 *)lc;
            struct section_64 *sc = (struct section_64 *)(sg + 1);
            for (uint32_t k = 0; k < sg->nsects; k++)
                if (sc[k].offset && sc[k].offset < lo) lo = sc[k].offset;
        }
        p += lc->cmdsize;
    }
    return lo;
}

static int append(const uint32_t *words, uint32_t n) {
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    uint32_t end = (uint32_t)sizeof *h + h->sizeofcmds;
    if (end + n * 4 > pad_end()) { fprintf(stderr, "no room in the header pad\n"); return -1; }
    memcpy(buf + end, words, n * 4);
    h->ncmds++; h->sizeofcmds += n * 4;
    return 0;
}

static void put_version(const char *key, uint32_t v) {
    printf(" %s=%u.%u.%u", key, v >> 16, (v >> 8) & 0xff, v & 0xff);
}

static void show(void) {
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    uint8_t *p = buf + sizeof *h;
    int any = 0;
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        const uint32_t *w = (const uint32_t *)p;
        if (lc->cmd == LC_VERSION_MIN_MACOSX) {
            printf("version-min"); put_version("version", w[2]); put_version("sdk", w[3]);
            printf("\n"); any = 1;
        } else if (lc->cmd == LC_BUILD_VERSION) {
            printf("build-version platform=%u", w[2]);
            put_version("minos", w[3]); put_version("sdk", w[4]);
            printf("\n"); any = 1;
        }
        p += lc->cmdsize;
    }
    if (!any) printf("none\n");
}

int main(int argc, char **argv) {
    uint32_t v, s;
    if (argc < 3) goto usage;
    if (load(argv[2]) != 0) return 2;
    if (strcmp(argv[1], "show") == 0 && argc == 3) { show(); return 0; }
    if (strcmp(argv[1], "none") == 0 && argc == 3) { strip_all(); return save(argv[2]) ? 2 : 0; }
    if (strcmp(argv[1], "vmin") == 0 && argc == 5) {
        if (version(argv[3], &v) || version(argv[4], &s)) return 2;
        uint32_t w[4] = { LC_VERSION_MIN_MACOSX, 16, v, s };
        strip_all();
        return append(w, 4) || save(argv[2]) ? 2 : 0;
    }
    if (strcmp(argv[1], "bv") == 0 && argc == 6) {
        uint32_t plat = (uint32_t)strtoul(argv[3], NULL, 10);
        if (version(argv[4], &v) || version(argv[5], &s)) return 2;
        uint32_t w[6] = { LC_BUILD_VERSION, 24, plat, v, s, 0 };
        strip_all();
        return append(w, 6) || save(argv[2]) ? 2 : 0;
    }
    if (strcmp(argv[1], "add-bv") == 0 && argc == 6) {
        uint32_t plat = (uint32_t)strtoul(argv[3], NULL, 10);
        if (version(argv[4], &v) || version(argv[5], &s)) return 2;
        uint32_t w[6] = { LC_BUILD_VERSION, 24, plat, v, s, 0 };
        return append(w, 6) || save(argv[2]) ? 2 : 0;
    }
usage:
    fprintf(stderr, "usage: mkminos none|show FILE | vmin FILE VERSION SDK"
                    " | bv|add-bv FILE PLATFORM MINOS SDK\n");
    return 2;
}
