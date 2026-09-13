#!/bin/sh
# change_dylib -- a /bin/sh wrapper around machotool's `lc`, `dylib` and
# `rpath`, or one `machotool edit FILE OUT -` when the invocation touches more
# than one of those families. The tool with the most callers; every one of them
# is replayed end to end by tests/known-callers.sh.
#
#   change_dylib input [-grow] [-change old new] [-delete path]
#                 [-reexport path] [-add path] [-insert path]
#                 [-strip-lc name] [-change-rpath old new]
#                 [-delete-rpath path] [-add-rpath path] ...
#
# spec: compat/translate.sh holds the grammar -- which verb each flag becomes,
# the statement order inside one `machotool edit`, the two capacity caps, and
# every refusal made before any I/O. compat/README.md's "change_dylib" tables
# hold every way this behaves differently from the C tool it replaced, each row
# naming the test that holds it.

MW_SELF=$(command -v "$0" 2>/dev/null) || MW_SELF=$0
MW_DIR=${MACHOTOOL_COMPAT_DIR:-$(dirname "$MW_SELF")}
# platform: a symlink to this wrapper on PATH makes MW_DIR the SYMLINK's
# directory, not the one holding machotool -- which is why
# MACHOTOOL_COMPAT_DIR exists. Checked before sourcing so the message is this
# one rather than the shell's own from the `.` below.
[ -r "$MW_DIR/machotool-compat.sh" ] || {
    printf '%s: cannot find machotool-compat.sh in %s -- machotool and its two support\n' "$0" "$MW_DIR" >&2
    printf '%s: files must sit beside this wrapper; a symlink to it resolves to the\n' "$0" >&2
    printf '%s: SYMLINK directory, so set MACHOTOOL_COMPAT_DIR to where they really are\n' "$0" >&2
    exit 1
}
. "$MW_DIR/machotool-compat.sh"

mw_translate change_dylib "$@" || exit $?

mw_prepare "$1" || exit 1

# spec: an invocation naming no operation emits no command, so there is nothing
# to run and no temp to install (compat/README.md, "change_dylib: stdout").
[ "$MW_NCMDS" -eq 0 ] && exit 0

mw_retranslate change_dylib "$@" || exit 1
mw_run_to_tmp
mw_rc=$?
# spec: forwarded, never mapped -- machotool's 1-vs-2 is the caller's to see
# (compat/README.md, "change_dylib: exit codes").
[ "$mw_rc" -eq 0 ] || exit "$mw_rc"
mw_finish || exit 1
# spec: the C tool's closing line, in its own words, only when the bytes
# changed (compat/README.md, "change_dylib: stdout").
[ "$MW_CHANGED" -eq 1 ] \
    && printf 'Updated %s (%s bytes)\n' "$1" "$(wc -c < "$MW_TARGET" | tr -d ' ')"
exit 0
