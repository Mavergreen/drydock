/* walk.h -- the nibs a bundle carries, and the binaries whose classes they name. */

#ifndef DRYDOCK_RESOURCES_WALK_H
#define DRYDOCK_RESOURCES_WALK_H

#include <stddef.h>

/* relpath: bundle-relative, as reports name it. abspath: the file to read. in_storyboard: inside a .storyboardc.
 * is_variant: abspath is a nib directory's keyedobjects-NNN.nib, the highest-numbered, standing in for a missing
 * keyedobjects.nib. no_nib: abspath is a nib directory with neither, so there is nothing to read. */
typedef struct { char *relpath; char *abspath; int in_storyboard; int is_variant; int no_nib; } RNib;

/* The nibs at arg and the bundle's binaries, both sorted bytewise; symbolic links inside arg are never followed.
 *   - A file is one nib.
 *   - A nib directory is its keyedobjects.nib, or without one its highest-numbered keyedobjects-NNN.nib, or
 *     without either the directory itself, marked no_nib.
 *   - A .storyboardc is the nibs inside it.
 *   - Any other directory is walked for those three.
 * The bundle is arg when it holds Contents/, else the nearest directory above arg that does; relpath is relative
 * to it, or with no bundle to arg (a directory) or arg's own directory. The binaries are the Mach-O files under
 * the bundle's Contents/MacOS and Contents/Frameworks. 0; or 4 with why set (unreadable, a path too long, out of
 * memory) and nothing to free. */
int  rw_walk(const char *arg, RNib **nibs, size_t *n, char ***binaries, size_t *nb, char *why, size_t whysz);
void rw_free(RNib *nibs, size_t n, char **binaries, size_t nb);

#endif
