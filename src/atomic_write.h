/* atomic_write.h -- write a rewriting verb's result to OUT without ever
 * touching, or leaving half-written, either FILE (the input) or OUT.
 *
 * Extracted from change_dylib.c, where this logic first shipped. Every Mach-O
 * rewriting verb reads FILE and writes its result to a separate OUT, with no
 * hard-link fallback: a hard link to FILE is exactly the case wa_is_input
 * refuses (it is FILE by another name), and a hard link that OUT already has
 * under some other name is just another name for OUT, unaffected by replacing
 * OUT via rename. drydock-resources convert replaces nibs in place, through
 * wa_stage and wa_commit.
 */

#ifndef DRYDOCK_ATOMIC_WRITE_H
#define DRYDOCK_ATOMIC_WRITE_H

#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>

/* wa_write_new's two failure codes. */
#define WA_IS_INPUT 1   /* `out` is `in`; nothing written */
#define WA_FAILED   2   /* an I/O or allocation failure; the reason is on stderr */

/* 1 if `out` names the same file as `in` -- the same path once both are
 * resolved, or, when `out` exists, the same device and inode, which catches a
 * symlink to `in` and a hard link to it -- else 0. For a caller that wants to
 * refuse before doing any work; wa_write_new checks again at the write. */
int wa_is_input(const char *in, const char *out);

/* Write `size` bytes of `buf` as the file `out`, never touching `in`.
 * Returns WA_IS_INPUT, writing nothing, when wa_is_input(in, out). Otherwise
 * writes a temp file in `out`'s resolved directory -- a symlink at `out` is
 * followed to its target, not replaced -- gives it `in`'s mode, `in`'s owner
 * (best-effort: needs privilege) and every extended attribute `in` carries,
 * fsyncs it, and renames it onto `out`. So `out` is either what it was or the
 * whole new content, never a partial file. Returns 0, WA_IS_INPUT, or
 * WA_FAILED with the reason on stderr; on any non-zero return `out` is as it
 * was and no temp file remains. */
int wa_write_new(const char *in, const char *out, const uint8_t *buf, size_t size);

/* Replacing a file in place, in two steps, so a caller replacing many can
 * stage them all before it renames any. wa_stage writes `size` bytes of `buf`
 * to a temp file in `path`'s resolved directory with `path`'s mode, owner
 * (best-effort) and extended attributes -- or, when `path` does not exist yet,
 * the mode a new file gets under the umask -- and fsyncs it: 0, or WA_FAILED
 * with the reason on stderr and nothing left behind. wa_commit renames the
 * temp onto `path` (0, or WA_FAILED with the temp removed); wa_abort removes
 * it. Either one ends the staging. */
struct wa_staged { char *tmp, *target; };
int  wa_stage(const char *path, const uint8_t *buf, size_t size, struct wa_staged *out);
int  wa_commit(struct wa_staged *s);
void wa_abort(struct wa_staged *s);
/* wa_stage then wa_commit: `path` is either what it was or the whole new
 * content. 0, or WA_FAILED. */
int  wa_replace(const char *path, const uint8_t *buf, size_t size);

#endif /* DRYDOCK_ATOMIC_WRITE_H */
