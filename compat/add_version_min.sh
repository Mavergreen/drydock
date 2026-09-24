#!/bin/sh
# add_version_min -- a /bin/sh wrapper around `drydock-macho-rewrite FILE OUT` with one
# `minos if-absent 10.9` statement on its stdin.
#
#   add_version_min binary
#
# compat/README.md's "add_version_min" section lists how it differs from the
# C tool, and the test for each.

MW_SELF=$(command -v "$0" 2>/dev/null) || MW_SELF=$0
MW_DIR=${DRYDOCK_MACHO_REWRITE_COMPAT_DIR:-$(dirname "$MW_SELF")}
[ -r "$MW_DIR/drydock-macho-rewrite-compat.sh" ] || {
    printf '%s: cannot find drydock-macho-rewrite-compat.sh in %s -- drydock-macho-rewrite and its two support\n' "$0" "$MW_DIR" >&2
    printf '%s: files must sit beside this wrapper; a symlink to it resolves to the\n' "$0" >&2
    printf '%s: SYMLINK directory, so set DRYDOCK_MACHO_REWRITE_COMPAT_DIR to where they really are\n' "$0" >&2
    exit 1
}
. "$MW_DIR/drydock-macho-rewrite-compat.sh"

mw_translate add_version_min "$@" || exit $?
mw_prepare "$1" || exit 1
if ! mw_thin_only "$1"; then
    printf '%s: not a readable 64-bit Mach-O\n' "$1" >&2
    exit 1
fi
mw_retranslate add_version_min "$@" || exit 1
mw_run_to_tmp
mw_rc=$?
[ "$mw_rc" -eq 0 ] || exit "$mw_rc"
mw_finish || exit 1
[ "$MW_CHANGED" -eq 1 ] || printf 'LC_VERSION_MIN_MACOSX already present; nothing to do.\n'
exit 0
