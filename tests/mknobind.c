/* mknobind OUT -- write the smallest possible thin 64-bit Mach-O: a bare
 * mach_header_64 with zero load commands.
 *
 * WHY IT EXISTS. `machorewrite imports` on an image with no bind stream at
 * all must be a SUCCESSFUL report of zero rows (header line included), not a
 * refusal -- "no imports" and "refused to look" are one exit code apart and
 * are exactly what a consumer of that output most needs told apart. Proving
 * that needs a fixture with no LC_DYLD_INFO/LC_DYLD_INFO_ONLY command at
 * all, and `load-command delete` has no spelling for one: its KIND
 * vocabulary (src/lc_kinds.c's LC_STRIP_KINDS) is uuid, codesig,
 * source-version, build-version and code-sign-drs -- none of them dyld
 * info -- so there is no statement that strips it from a linked binary.
 *
 * This is the smallest fixture that answers the question instead: ncmds=0,
 * sizeofcmds=0. mi_wrap's own validation (src/image.c's mi_validate) asks
 * for nothing more than "every load command fits inside sizeofcmds", which
 * an empty command list satisfies trivially -- so this is a real, accepted
 * 64-bit Mach-O, just one that happens to declare nothing past its header.
 */
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <mach-o/loader.h>

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: %s OUT\n", argv[0]); return 2; }

    struct mach_header_64 h;
    h.magic = MH_MAGIC_64;
    h.cputype = CPU_TYPE_X86_64;
    h.cpusubtype = CPU_SUBTYPE_X86_64_ALL;
    h.filetype = MH_DYLIB;
    h.ncmds = 0;
    h.sizeofcmds = 0;
    h.flags = 0;
    h.reserved = 0;

    int fd = open(argv[1], O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { perror("open"); return 2; }
    if (write(fd, &h, sizeof h) != (ssize_t)sizeof h) { perror("write"); close(fd); return 2; }
    close(fd);
    return 0;
}
