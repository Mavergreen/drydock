#ifndef MACHOTOOL_EDIT_H
#define MACHOTOOL_EDIT_H
/*
 * me_ -- applying an edit script (src/script.h) to one Mach-O: read the image
 * once, apply each statement in order to the in-memory buffer, verify the
 * result, and write it once.
 *
 * This module lowers and sequences; it performs no operation itself. Each
 * statement becomes a call to the one implementation of that operation --
 * src/rewrite.h's mr_apply_image for load-command/segment/dylib/rpath,
 * src/version_min.h, src/swift_retag.h and src/declassify.h's in-memory
 * cores for the other three -- the same code each CLI verb reaches.
 */
#include <stdio.h>

#include "script.h"

typedef struct {
    FILE *log;            /* where the report goes; stderr in the CLI, and
                           * stderr when NULL */
} me_opts;

/* Applies `s` to `path`, verifies, and writes the result once, as `out`.
 * `path` is only read. Returns 0 on success, MR_REFUSED (1) when a statement
 * or the verify declined on purpose, or MR_FAIL (2) for an operational
 * failure (a syscall, a malloc). On any non-zero return NOTHING has been
 * written: `path` is as it was and so is `out`, which usually does not exist.
 *
 * `out` is REQUIRED, and may not be `path` -- the same file named twice is
 * MR_FAIL, before anything is read, and so is a NULL `out`. A symlink or hard
 * link to `path` is caught too (wa_is_input, src/atomic_write.h).
 *
 * NOT MR_ERROR: that is (-1), private to src/rewrite.c, and it is
 * mr_fat_slice's per-slice status, not an exit code.
 *
 * INPUT. A thin 64-bit Mach-O, or a fat (universal) file, which is edited
 * slice by slice and kept whole. Anything else is refused; an input that
 * cannot be opened or read at all is MR_FAIL. Beyond its statements the
 * script may carry directives -- `arch`, `allow-grow`, `fatal-warnings` --
 * which select slices, permit header growth, and turn an unmatched statement
 * into a refusal of the whole run; src/script.h defines them.
 *
 * REPORT, to o->log. A refusal that has read the image names both files and
 * what became of each; one that never got that far says only what it can.
 * tests/cli_test.sh's "edit refusal inventory" block exercises this claim
 * (it says itself which sites it cannot reach, and why). me_run flushes
 * stdout before each line it writes, so its lines land after any stdout line
 * printed before them; an operation's own stderr message, written while it
 * runs, is not ordered this way.
 *
 * me_run calls each operation's in-memory core, not its CLI verb, so an edit
 * run's stdout carries the lines those cores print. Those that name a file
 * name PATH, the input, even when `out` is given.
 *
 * A statement that succeeds logs, indented beneath its statement line, the
 * work it did beyond what it names -- every figure one the operation computed
 * while doing the work, never a second look at the image. `target 10.9` logs
 * its expansion that way, each derived line followed by the finding that
 * produced it:
 *
 *       target 10.9
 *         fixups set classic  (LC_DYLD_CHAINED_FIXUPS present)
 *         version-min set 10.9  (no LC_VERSION_MIN_MACOSX)
 *
 * -- or "nothing to do: this binary already targets 10.9" when the expansion
 * is empty. The expansion never derives `dylib` or `rpath` work, and
 * `fixups set classic` comes first within it.
 * spec: src/grow.h -- growth refuses an image that still has chained fixups,
 * which is what fixes that order.
 */
int me_run(const char *path, const char *out, const ms_script *s,
           const me_opts *o);

#endif /* MACHOTOOL_EDIT_H */
