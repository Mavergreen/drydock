#ifndef MACHOREWRITE_SCRIPT_H
#define MACHOREWRITE_SCRIPT_H

#include <stddef.h>

/* Splits ONE line into fields using shell word rules, in place.
 *
 * The rules are chosen to agree exactly with compat/translate.sh's mt_quote,
 * which is the generator for these scripts: it emits a bare word only when
 * every character is in [A-Za-z0-9_@%+=:,./-], and otherwise single-quotes
 * the whole word with each ' written as '\''. So an unquoted '#' can mean
 * "comment" without ever eating a real path -- mt_quote never emits one.
 *
 *   - fields separate on unquoted space or tab
 *   - '...'  literal; no escapes inside (mt_quote's '\'' works because the
 *            quote closes, \' is a literal quote outside quotes, and the
 *            next ' reopens)
 *   - "..."  backslash escapes \" \\ \$ \` ; any other backslash is literal
 *   - \x     outside quotes: literal x
 *   - #      unquoted, at the start of a field: comment to end of line
 *
 * `line` is modified: each returned field is NUL-terminated in place.
 * Returns the field count, 0 for a blank or comment-only line, or -1 with
 * `err` set on a quoting error or on more than `max` fields. Overflow is an
 * error rather than truncation: silently dropping an operand is the
 * silent-success class this toolkit exists to eliminate. */
int ms_split(char *line, char **argv, int max, char *err, size_t errsz);

/* The statement vocabulary an edit script's operation lines are drawn from.
 * See src/script.c's MS_TABLE for the kind/op pairs actually accepted --
 * these enums just name the values ms_parse fills into an ms_stmt, and the
 * values a `switch` on .kind/.op matches against.
 *
 * MS_TARGET is the one whose meaning depends on the binary: `target 10.9`
 * expands, where it is written, into the statements THIS image needs. Its
 * second field is a profile name rather than a verb, which is why the op
 * enum has one entry that is not a verb -- occupying the same slot means the
 * table matches it, counts its operands and advertises it exactly as it does
 * every other statement. */
enum { MS_LOAD_COMMAND, MS_SEGMENT, MS_VERSION_MIN, MS_SWIFT_ABI,
       MS_FIXUPS, MS_DYLIB, MS_RPATH, MS_TARGET };
enum { MS_DELETE, MS_RENAME, MS_SET, MS_REPLACE, MS_APPEND,
       MS_INSERT, MS_REEXPORT, MS_PROFILE_10_9, MS_RETYPE };

/* One operation line from an edit script. `a`/`.b` (NULL when the
 * statement's arity doesn't use them) point into the owning ms_script's
 * `text`, not into separately allocated storage. `line` is the 1-based
 * source line, for diagnostics raised later (e.g. by whatever applies the
 * script) that still need to name where a statement came from. */
typedef struct { int kind, op; const char *a, *b; int line; } ms_stmt;

/* A parsed edit script: every operation line (not directive lines -- those
 * only set the three fields below) in source order. Every directive --
 * `allow-grow`, `fatal-warnings`, `arch NAME` -- is repeatable and must
 * precede every operation, `target` included: it is a statement, and the
 * directives govern what its expansion may do. A script may name at most one
 * `target`; a second is a parse error. */
typedef struct {
    ms_stmt *stmts;
    int      n;
    int      allow_grow;
    int      fatal_warnings;
    unsigned arch_mask;   /* bit r set when an `arch` directive named row r of
                           * src/arch_names.h's table; 0 when the script names
                           * no arch, which means every 64-bit slice */
    char    *text;      /* owns every operand's storage */
} ms_script;

/* Parses a whole edit script from `buf`/`len` (need not be NUL-terminated;
 * a final line with no trailing newline is fine, and there is no fixed cap
 * on the number of statements -- the array is sized from the script itself).
 * Every byte in [0, len) must be either tab, newline, or NOT an ASCII
 * control character -- so a NUL or a CR (or any other C0 control byte, or
 * DEL) is refused, not silently folded into an operand, while a byte 0x80
 * and above (part of UTF-8, say) is fine.
 *
 * On success, returns 0, fills `*out`, and the caller must eventually call
 * ms_free(out). On error, returns -1 and (if `err` and `errsz` are
 * non-zero) sets `err` to a message. On a PARSE error -- the script itself
 * is malformed -- that message names the offending 1-based source line as
 * "line N"; an allocation failure has no line to name, and says so instead.
 * Either way, ms_parse has already freed everything it allocated and zeroed
 * `*out` -- so ms_free(out) is not necessary after a failed ms_parse, though
 * it remains safe (a no-op) if called anyway. */
int ms_parse(const char *buf, size_t len, ms_script *out, char *err, size_t errsz);

/* Frees an ms_script filled by a successful ms_parse. Safe to call on an
 * ms_script that is all-zero (never parsed, or left by a failed ms_parse --
 * see ms_parse's own comment). */
void ms_free(ms_script *s);

/* Names an MS_* kind/op constant for diagnostics, e.g. ms_kind_name(MS_DYLIB)
 * -> "dylib". Returns "unknown" for a value outside the table -- defensive
 * only, since every kind/op a caller has came from this table in the first
 * place (either MS_TABLE's own constants, or an ms_stmt ms_parse filled). */
const char *ms_kind_name(int kind);
const char *ms_op_name(int op);

/* Which verb grammar OFFERED a row's operation. `machotool dylib` and
 * `machotool rpath` took their operations from the SAME table an edit
 * script's statements come from -- `dylib -insert P` and `dylib insert P`
 * were one operation with two spellings -- so each row says which of the two
 * verbs could spell it, and a row neither offered (every statement that is
 * not a dylib or rpath operation) carries 0 and a NULL flag.
 *
 * BOTH VERBS ARE GONE, and with them every reader of this mask that decided
 * anything: ms_table_row still fills it, and its one production caller
 * (--capabilities) ignores it now that `ops=` and `flags=` are no longer
 * advertised. The column is left in place rather than torn out with the
 * verbs, and ms_mode_op/ms_verb_op's own note at the foot of this file says
 * what that costs. */
enum { MS_MODE_DYLIB = 1u << 0, MS_MODE_RPATH = 1u << 1 };

/* Enumerates the statement table row by row (0-based `i`), for a caller like
 * --capabilities that must generate its advertised vocabulary from the same
 * data ms_parse matches statements against, rather than maintaining a
 * second, hand-copied list that can drift out of agreement with this one.
 * Fills every out-parameter and returns 1 for a valid row index; returns 0
 * once `i` is past the last row, so a caller can loop
 * `for (i = 0; ms_table_row(i, &k, &o, &n, &f, &m, &d); i++)`.
 *
 * `*flag` is the verb spelling ("-replace") or NULL for a row no verb
 * offered; `*modes` is an MS_MODE_* mask, 0 when `*flag` is NULL; neither is
 * read by any production caller now (see MS_MODE_* above). `*disturbs` is the
 * row's MREL_* mask (src/relations.h) -- see ms_disturbs. */
int ms_table_row(int i, const char **kind, const char **op, int *nargs,
                 const char **flag, unsigned *modes, unsigned *disturbs);

/* Which referents this operation disturbs, as an MREL_* mask
 * (src/relations.h): what a run of it leaves pointing at the wrong thing, so
 * a caller can derive which repairs and which checks a run needs instead of
 * hand-writing a condition per site.
 *
 * A kind/op pair this table does not carry disturbs EVERYTHING (~0u). That
 * is the safe direction and it is deliberate: an unknown operation that
 * answered 0 would silently switch off every check that consults this, which
 * is the failure this column exists to prevent.
 *
 * spec: docs/superpowers/specs/2026-09-10-relations-and-verb-lowering-design.md's
 * Decision 2 -- "disturbs" means the referent CHANGES such that references to
 * it go stale, not that bytes were written near it. */
unsigned ms_disturbs(int kind, int op);

/* Did row `i` declare its disturbs mask, rather than inherit a zero nobody
 * chose? "Nothing" is a real and common answer -- five of the rows -- so it
 * has to be SPELLED, and a row that spells nothing at all must be
 * distinguishable from one that spells MREL_NONE. The table makes skipping
 * it a compile error (see MS_TABLE_ROWS in src/script.c); this is how a test
 * can state that from outside. Returns 0 for a row index past the end. */
int ms_row_disturbs_declared(int i);

/* ms_mode_op and ms_verb_op used to live here: the i-th operation a verb
 * offered in --capabilities' "ops=" order, and the lookup from a verb flag
 * ("-reexport") to its MS_* op. Both existed only to serve the seven mutating
 * verbs. The verbs are gone, "ops=" is no longer advertised, and no flag is
 * parsed anywhere, so they went too rather than stay as production code that
 * only a test called.
 * spec: docs/superpowers/specs/2026-09-14-script-is-the-only-interface-design.md
 * The table's flag/modes/ops_ord columns outlive them and are now read only by
 * ms_table_row. */

#endif
