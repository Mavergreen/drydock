#!/bin/sh
# change_dylib -- a /bin/sh wrapper around one `drydock-macho-rewrite FILE OUT`, with
# every operation the invocation asks for as a statement on its stdin. The
# tool with the most callers; every one of them is replayed end to end by
# tests/known-callers.sh.
#
#   change_dylib input [-grow] [-change old new] [-delete path]
#                 [-reexport path] [-add path] [-insert path]
#                 [-strip-lc name] [-change-rpath old new]
#                 [-delete-rpath path] [-add-rpath path] ...
#
# spec: compat/translate.sh holds the grammar -- which statement each flag
# becomes, the order they are emitted in, the two capacity caps, and every
# refusal made before any I/O. compat/README.md's "change_dylib" tables
# hold every way this behaves differently from the C tool it replaced, each row
# naming the test that holds it.

MW_SELF=$(command -v "$0" 2>/dev/null) || MW_SELF=$0
MW_DIR=${DRYDOCK_MACHO_REWRITE_COMPAT_DIR:-$(dirname "$MW_SELF")}
# platform: a symlink to this wrapper on PATH makes MW_DIR the SYMLINK's
# directory, not the one holding drydock-macho-rewrite -- which is why
# DRYDOCK_MACHO_REWRITE_COMPAT_DIR exists. Checked before sourcing so the message is this
# one rather than the shell's own from the `.` below.
[ -r "$MW_DIR/drydock-macho-rewrite-compat.sh" ] || {
    printf '%s: cannot find drydock-macho-rewrite-compat.sh in %s -- drydock-macho-rewrite and its two support\n' "$0" "$MW_DIR" >&2
    printf '%s: files must sit beside this wrapper; a symlink to it resolves to the\n' "$0" >&2
    printf '%s: SYMLINK directory, so set DRYDOCK_MACHO_REWRITE_COMPAT_DIR to where they really are\n' "$0" >&2
    exit 1
}
. "$MW_DIR/drydock-macho-rewrite-compat.sh"

mw_translate change_dylib "$@" || exit $?

mw_prepare "$1" || exit 1

# spec: an invocation naming no operation emits no command, so there is nothing
# to run and no temp to install (compat/README.md, "change_dylib: stdout").
[ "$MW_NCMDS" -eq 0 ] && exit 0

mw_retranslate change_dylib "$@" || exit 1
mw_run_to_tmp
mw_rc=$?
# spec: forwarded, never mapped -- drydock-macho-rewrite's 1-vs-2 is the caller's to see
# (compat/README.md, "change_dylib: exit codes").
[ "$mw_rc" -eq 0 ] || exit "$mw_rc"
mw_finish || exit 1
# spec: the C tool's closing line, in its own words, only when the bytes
# changed (compat/README.md, "change_dylib: stdout").
[ "$MW_CHANGED" -eq 1 ] \
    && printf 'Updated %s (%s bytes)\n' "$1" "$(wc -c < "$MW_TARGET" | tr -d ' ')"
exit 0
