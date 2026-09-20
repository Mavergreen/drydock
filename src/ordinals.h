/* ordinals.h -- the library-ordinal map, shared by the rewriter and the
 * renumberer so they cannot independently disagree about where a dylib
 * landed.
 *
 * In a two-level-namespace image, every undefined symbol records WHICH dylib
 * it comes from as a 1-based index into the LC_LOAD_DYLIB (and weak/reexport/
 * upward) load commands, in load-command order. The index lives in two
 * places: the nlist n_desc of each undefined symbol, and the
 * SET_DYLIB_ORDINAL opcodes of the LC_DYLD_INFO bind/weak/lazy streams.
 * Inserting or deleting one of those load commands shifts every later index,
 * so both places need renumbering -- and whatever decided which load
 * commands survive has to be the SAME decision the renumberer renumbers
 * against.
 *
 * -delete once produced binaries dyld refused to load ("library ordinal (4)
 * too big") because the load-command rewrite and the ordinal renumbering
 * disagreed about which dylib had been removed. Building one mo_map and
 * having every ordinal-writing step apply exactly that map narrows that
 * disagreement to exactly one place it can still happen, no longer two: this
 * header does not decide, on its own, which dylib survives. mo_map_build
 * takes an `is_deleted` callback instead of owning that decision, because the
 * caller's own load-command rewrite has to make the identical call about
 * which commands survive -- mo_map_build cannot make that call FOR the
 * caller without duplicating the caller's own logic, which is the mistake
 * being fixed. A caller keeps the two in lockstep by implementing
 * `is_deleted` as one function and calling that SAME function -- not
 * reimplementing its logic -- everywhere it decides "does this dylib
 * survive?" (change_dylib.c's ord_is_deleted is called from both its own
 * load-command rewrite and from mo_map_build; see change_dylib.c). As a
 * runtime backstop for when a caller gets that wrong anyway, mo_map_validate
 * can compare the map against the load-command table a caller actually
 * emitted and refuse if they disagree -- see its own comment below for what
 * it does and does not catch.
 */

#ifndef MACHOREWRITE_ORDINALS_H
#define MACHOREWRITE_ORDINALS_H

#include <stdint.h>
#include <stddef.h>
#include <mach-o/loader.h>

/* MAX_LIBRARY_ORDINAL: the encoding's own ceiling (mach-o/loader.h). No image
 * can have more ordinal-bearing dylibs than this, so it doubles as the
 * largest map this module will ever build. */
#define MO_MAX_DYLIBS 253   /* MAX_LIBRARY_ORDINAL */

/* old_to_new[old] is the new 1-based ordinal for what used to be library
 * ordinal `old`, or 0 if that dylib was deleted. Index 0 is unused (ordinals
 * are 1-based); valid indices are 1..n. `old_to_new` is caller-owned, sized
 * at least MO_MAX_DYLIBS+1, so a caller can put it on the stack and know
 * exactly how long it needs to stay alive -- this module never allocates.
 *
 * `cmd` is optional and caller-owned the same way (NULL for none): when
 * given, mo_map_build records in cmd[old] the load command kind (LC_LOAD_DYLIB,
 * LC_LOAD_WEAK_DYLIB, ...) it found at old ordinal `old` -- in the same walk
 * that assigns the ordinal, so a report of what was deleted names the command
 * the map actually deleted. */
typedef struct mo_map {
    int *old_to_new;
    int n;
    uint32_t *cmd;
} mo_map;

/* Is `cmd` a load command that consumes a library ordinal? LC_ID_DYLIB is
 * deliberately excluded: it names the image itself and is not addressable by
 * ordinal. Neither is LC_RPATH, which is a search path, not a dependency.
 * Shared here so a caller's load-command walk (deciding what to keep) and
 * mo_map_build's walk (deciding what ordinal it gets) can't drift apart by
 * using two different definitions of "ordinal-bearing". */
int mo_is_ordinal_lc(uint32_t cmd);

/* The four kinds mo_is_ordinal_lc counts, by the name a `dylib retype`
 * statement spells them with. LC_LAZY_LOAD_DYLIB is deliberately absent: see
 * mo_map_build, which refuses an image carrying one. */
uint32_t mo_kind_from_name(const char *name);
const char *mo_kind_name(uint32_t cmd);

/* A dylib_command's dylib.name.offset (equally, an rpath_command's
 * path.offset) is an lc_str: an offset relative to the START of the load
 * command that carries it. Nothing about the format guarantees it lands
 * inside that command -- a malformed or hostile input can set it past
 * cmdsize, making a naive `(char *)lc + offset` point past the command, into
 * whatever follows it (or past the mapped buffer entirely) instead of at a
 * NUL-terminated string. Every reader of one of these names must go through
 * here rather than repeating the check inline: cli/machorewrite.c's info dump,
 * change_dylib.c's build_lcs, and mo_map_build below each used to compute
 * this pointer independently, and only one of the three actually checked.
 * Returns NULL for an out-of-bounds offset; the caller decides whether that
 * means "skip this command" or "refuse the whole operation". */
const char *mo_lc_str_at(const struct load_command *lc, uint32_t offset);

/* Walk the `ncmds` load commands starting right after the mach_header_64 at
 * `buf`, in order, and assign each ordinal-bearing dylib (mo_is_ordinal_lc)
 * its new ordinal: `is_deleted(name, ctx)` true maps it to 0, otherwise it
 * gets the next ordinal after `base` (so -insert, which claims 1..ninserts
 * ahead of the existing dylibs, passes ninserts as `base`). Fills
 * map->old_to_new[1..map->n], map->n itself, and map->cmd[1..map->n] when
 * map->cmd is non-NULL; map->old_to_new must already
 * point at a caller-owned array of at least MO_MAX_DYLIBS+1 ints. *out_nnew
 * receives the highest new ordinal handed out (base + count of survivors),
 * which is also the ordinal ceiling for mo_map_validate. Returns 0, or -1
 * (with a message on stderr) if there are more than MO_MAX_DYLIBS
 * ordinal-bearing dylibs, OR if an LC_LAZY_LOAD_DYLIB (legacy -lazy_library)
 * is present -- it carries a library ordinal like the four kinds
 * mo_is_ordinal_lc() counts, but is deliberately not one of them (untested
 * renumbering semantics), so this refuses rather than silently leaving it
 * out of the map and mis-renumbering everything after it. See mo_map_build's
 * own comment (in ordinals.c) on that check for the reasoning. */
int mo_map_build(const uint8_t *buf, uint32_t ncmds, int base,
                  int (*is_deleted)(const char *name, void *ctx), void *ctx,
                  mo_map *map, int *out_nnew);

/* Count how many of the `ncmds` load commands packed starting at `lcs`
 * satisfy mo_is_ordinal_lc. Unlike mo_map_build's walk, `lcs` is NOT preceded
 * by a mach_header_64 -- it counts a freshly-emitted, headerless table (e.g.
 * build_lcs's own scratch output), which is what lets mo_map_validate check
 * a map against what a caller's rewrite actually produced. */
int mo_count_ordinal_lcs(const uint8_t *lcs, uint32_t ncmds);

/* Check `map` against both its own arithmetic and, if `new_lcs` is given,
 * reality:
 *   - n within [0, MO_MAX_DYLIBS];
 *   - old_to_new[1..n] is 0 (deleted) or DENSE and STRICTLY INCREASING as old
 *     ordinals increase -- survivors must be exactly base+1, base+2, ... in
 *     order, with no gaps, repeats, or reordering. Anything else could not
 *     have come from a single left-to-right renumbering pass, so it can only
 *     mean map and caller disagree about what got deleted, or about order.
 *   - IF new_lcs/new_ncmds are non-NULL: mo_count_ordinal_lcs(new_lcs,
 *     new_ncmds) -- the number of ordinal-bearing load commands the caller
 *     ACTUALLY emitted -- equals (survivors + base + nadds), the number the
 *     map implies. This is the check that catches a map and an emitted
 *     table that independently disagree about which dylib survived: the
 *     historical class of bug, reproduced by a path passed to both -change
 *     and -delete before mo_is_ordinal_lc unification in change_dylib.c. It
 *     does NOT catch every possible disagreement -- e.g. it cannot tell that
 *     the WRONG dylib was kept if the count still comes out right -- so it
 *     is a backstop for a caller whose is_deleted and load-command rewrite
 *     drift apart, not a substitute for keeping them the same function.
 * Returns 0 if all checks that apply hold, -1 (with a message on stderr)
 * otherwise. */
int mo_map_validate(const mo_map *map, int base, int max_new, int nadds,
                     const uint8_t *new_lcs, uint32_t new_ncmds);

/* What one mo_map_apply changed, place by place. Each figure is counted in
 * the walk that makes the change -- the symtab loop for `nlist`, the one
 * opcode walk per stream for the other three -- never by walking again, so
 * a count cannot disagree with the rewrite it describes.
 *
 * "Changed" means the recorded ordinal is now different: an entry or opcode
 * whose dylib kept its ordinal is not counted (for an opcode, even though
 * the walk re-encodes it in place with the same value). The three opcode
 * figures count SET_DYLIB_ORDINAL_IMM and SET_DYLIB_ORDINAL_ULEB together,
 * per stream. */
typedef struct {
    int  flat;   /* 1: a flat-namespace image records no library ordinals,
                  * so nothing was walked and every count is 0 */
    long nlist;  /* undefined/prebound symtab entries whose n_desc changed */
    long bind;   /* SET_DYLIB_ORDINAL_* opcodes changed in the bind stream */
    long weak;   /* ... in the weak-bind stream */
    long lazy;   /* ... in the lazy-bind stream */
} mo_counts;

/* Apply `map` to every place the `size`-byte buffer at `buf` records a
 * library ordinal: the symtab's undefined/prebound symbols, and the
 * LC_DYLD_INFO bind/weak-bind/lazy-bind streams. Must run against the
 * already-committed load-command table, since it reads the LC_SYMTAB and
 * LC_DYLD_INFO offsets straight out of it -- and those offsets/sizes come
 * from the file, not from anything this function derived itself, so `size`
 * is what lets it refuse rather than read or WRITE outside the buffer when
 * one of them is malformed (image.h and fat.h both bound every access they
 * make against a size the caller gives them; this is that same discipline
 * applied here). Refuses (returns -1, with a message on stderr) rather than
 * emit a binary with a dangling or out-of-range ordinal: an unknown bind
 * opcode, a new ordinal that no longer fits the encoding the linker chose, a
 * symbol still bound to a deleted dylib, or a symtab/bind-stream region that
 * does not fit within `size`. `verbose` prints a one-line summary on
 * success, to stdout. `counts`, if non-NULL, receives what changed (see
 * mo_counts) on success and is left alone on a refusal. */
int mo_map_apply(uint8_t *buf, size_t size, const mo_map *map, int verbose,
                 mo_counts *counts);

/* One walk of a bind opcode stream, shared by the renumberer (mo_map_apply,
 * via mo_bind_stream below) and a second consumer that only wants to OBSERVE
 * which ordinal/symbol each DO_BIND-family opcode binds against, without
 * touching the buffer -- e.g. a report of what a binary imports. Decoding
 * bind opcodes correctly (which bytes are operands vs. the next opcode) is
 * exactly the part that must not be duplicated: see this header's own
 * top comment on why one disagreement between two independent walks of the
 * same kind of data is the bug class this module exists to prevent. */
enum { MO_ORD_SELF = -1, MO_ORD_EXE = -2, MO_ORD_FLAT = -3 };

/* The state of one DO_BIND-family opcode, as seen by an observer: the
 * ordinal currently in effect (>= 1, or one of MO_ORD_*, per
 * BIND_OPCODE_SET_DYLIB_ORDINAL_* / BIND_OPCODE_SET_DYLIB_SPECIAL_IMM), the
 * most recently set trailing-flags symbol name (or NULL if none has been
 * set yet in this stream), and that symbol's WEAK_IMPORT flag. */
typedef struct {
    int         ordinal;
    const char *symbol;
    int         weak;
} mo_bind_state;

typedef void (*mo_bind_obs)(const mo_bind_state *st, void *ctx);

/* Walk one bind opcode stream in order, renumbering, observing, or both:
 *   - `map` non-NULL: renumber SET_DYLIB_ORDINAL_* opcodes via `map`/`nold`,
 *     exactly as mo_bind_stream (see mo_map_apply's callers) has always
 *     done; *changed, if non-NULL, is incremented once per ordinal this
 *     walk actually changed.
 *   - `map` NULL: OBSERVE ONLY. The walk writes not a single byte of `base`
 *     -- `nold` and `changed` are ignored -- and the out-of-range check that
 *     an ordinal must be reads `nold` is skipped, since an observe-only walk
 *     has no map to be out of range of.
 *   - `obs` non-NULL: called once per DO_BIND-family opcode (DO_BIND,
 *     DO_BIND_ADD_ADDR_ULEB, DO_BIND_ADD_ADDR_IMM_SCALED,
 *     DO_BIND_ULEB_TIMES_SKIPPING_ULEB) with the mo_bind_state in effect at
 *     that point -- for SET_DYLIB_ORDINAL opcodes, the ordinal AFTER any
 *     renumbering this same walk just applied.
 *   - `obs` NULL: renumber only, as mo_bind_stream always has.
 * Returns 0 on success, -1 on a stream this walk can't safely process
 * (unknown opcode; when renumbering, a new ordinal that no longer fits the
 * encoding) -- see mo_bind_stream's own comment for the reasoning, which
 * this function inherits unchanged. */
int mo_bind_walk(uint8_t *base, uint32_t size, const int *map, int nold,
                 const char *what, long *changed,
                 mo_bind_obs obs, void *ctx);

#endif /* MACHOREWRITE_ORDINALS_H */
