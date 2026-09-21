/* mknobind OUT [-special] -- write a thin 64-bit Mach-O with no load
 * commands at all (the default), or one whose bind stream binds against
 * every special ordinal this build assigns a meaning to (-special).
 *
 * WHY THE DEFAULT MODE EXISTS. `drydock-macho-rewrite imports` on an image with no
 * bind stream at all must be a SUCCESSFUL report of zero rows (header line
 * included), not a refusal -- "no imports" and "refused to look" are one
 * exit code apart and are exactly what a consumer of that output most needs
 * told apart. Proving that needs a fixture with no LC_DYLD_INFO/
 * LC_DYLD_INFO_ONLY command at all, and `load-command delete` has no
 * spelling for one: its KIND vocabulary (src/lc_kinds.c's LC_STRIP_KINDS) is
 * uuid, codesig, source-version, build-version and code-sign-drs -- none of
 * them dyld info -- so there is no statement that strips it from a linked
 * binary. This is the smallest fixture that answers the question instead:
 * ncmds=0, sizeofcmds=0. mi_wrap's own validation (src/image.c's
 * mi_validate) asks for nothing more than "every load command fits inside
 * sizeofcmds", which an empty command list satisfies trivially -- so this is
 * a real, accepted 64-bit Mach-O, just one that happens to declare nothing
 * past its header.
 *
 * WHY -special EXISTS. self/exe/flat/unknown are each printed by their own
 * arm of cli/drydock-macho-rewrite.c's imports_row switch, and nothing a linker
 * produces reliably exercises all four on every host -- BIND_SPECIAL_DYLIB_
 * FLAT_LOOKUP only shows up in a flat-namespace or `-undefined
 * dynamic_lookup` link, which is exactly the kind of host/linker-version
 * dependence tests/README.md's host-portability section warns against, and
 * MO_ORD_UNKNOWN (a raw SET_DYLIB_SPECIAL_IMM value no real linker ever
 * emits, by construction -- see ordinals.h's own comment on it) is not
 * reachable from a linker at all. So -special hand-encodes one BIND opcode
 * stream, byte by byte, binding one distinctly-named symbol against each of
 * BIND_SPECIAL_DYLIB_SELF (0), BIND_SPECIAL_DYLIB_MAIN_EXECUTABLE (-1),
 * BIND_SPECIAL_DYLIB_FLAT_LOOKUP (-2), and one 4-bit signed immediate (-3)
 * outside all three -- the same "not one of the values this module assigns
 * a meaning to" case ordinals.c's MO_ORD_UNKNOWN exists to name rather than
 * misreport. No segment/symbol table is needed: mo_bind_walk's decode never
 * looks at either to recognise a DO_BIND-family opcode.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <mach-o/loader.h>

int main(int argc, char **argv) {
    int special = 0;
    if (argc == 3 && strcmp(argv[2], "-special") == 0) special = 1;
    else if (argc != 2) { fprintf(stderr, "usage: %s OUT [-special]\n", argv[0]); return 2; }

    uint8_t *buf;
    size_t fsize;

    if (!special) {
        struct mach_header_64 h;
        memset(&h, 0, sizeof h);
        h.magic = MH_MAGIC_64;
        h.cputype = CPU_TYPE_X86_64;
        h.cpusubtype = CPU_SUBTYPE_X86_64_ALL;
        h.filetype = MH_DYLIB;

        fsize = sizeof h;
        buf = (uint8_t *)malloc(fsize);
        if (!buf) { fprintf(stderr, "out of memory\n"); return 2; }
        memcpy(buf, &h, sizeof h);
    } else {
        /* One BIND stream, four binds: SET_DYLIB_SPECIAL_IMM(v), then a
         * trailing-flags symbol name unique to that ordinal, SET_TYPE_IMM
         * (pointer), DO_BIND. No SET_SEGMENT_AND_OFFSET_ULEB/ADD_ADDR: the
         * decode (ordinals.c's mo_bind_walk) never requires one before a
         * DO_BIND-family opcode fires the observer. imm is the 4-bit
         * two's-complement encoding of v: 0x0=0, 0xF=-1, 0xE=-2, 0xD=-3. */
        static const uint8_t bind[] = {
            0x30,                                       /* SPECIAL_IMM(0)  = self */
            0x40, '_','s','e','l','f','_','s','y','m',0, /* trailing flags + name */
            0x51,                                        /* SET_TYPE_IMM(1) */
            0x90,                                        /* DO_BIND */
            0x3F,                                       /* SPECIAL_IMM(-1) = exe */
            0x40, '_','e','x','e','_','s','y','m',0,
            0x51,
            0x90,
            0x3E,                                       /* SPECIAL_IMM(-2) = flat */
            0x40, '_','f','l','a','t','_','s','y','m',0,
            0x51,
            0x90,
            0x3D,                                       /* SPECIAL_IMM(-3) = unknown */
            0x40, '_','u','n','k','_','s','y','m',0,
            0x51,
            0x90,
            0x00,                                        /* DONE */
        };

        struct mach_header_64 h;
        memset(&h, 0, sizeof h);
        h.magic = MH_MAGIC_64;
        h.cputype = CPU_TYPE_X86_64;
        h.cpusubtype = CPU_SUBTYPE_X86_64_ALL;
        h.filetype = MH_DYLIB;
        h.ncmds = 1;
        h.sizeofcmds = (uint32_t)sizeof(struct dyld_info_command);
        h.flags = MH_TWOLEVEL;

        struct dyld_info_command di;
        memset(&di, 0, sizeof di);
        di.cmd = LC_DYLD_INFO_ONLY;
        di.cmdsize = (uint32_t)sizeof di;
        di.bind_off = (uint32_t)(sizeof h + sizeof di);
        di.bind_size = (uint32_t)sizeof bind;

        fsize = (size_t)di.bind_off + di.bind_size;
        buf = (uint8_t *)calloc(1, fsize);
        if (!buf) { fprintf(stderr, "out of memory\n"); return 2; }
        memcpy(buf, &h, sizeof h);
        memcpy(buf + sizeof h, &di, sizeof di);
        memcpy(buf + di.bind_off, bind, sizeof bind);
    }

    int fd = open(argv[1], O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { perror("open"); free(buf); return 2; }
    if (write(fd, buf, fsize) != (ssize_t)fsize) { perror("write"); close(fd); free(buf); return 2; }
    close(fd);
    free(buf);
    return 0;
}
