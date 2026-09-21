#!/bin/sh
# fix_macho -- a /bin/sh wrapper around one `drydock-macho-rewrite FILE OUT`, with every
# operation the invocation asks for as a statement on its stdin.
#
#   fix_macho <file> [-change old new] [-strip_build_version]
#             [-rename_seg old new] ...
#
# spec: compat/translate.sh holds the grammar -- which statement each flag
# becomes, the order they are emitted in, the two capacity caps, and every
# refusal made before any I/O. compat/README.md's "fix_macho: the adopted divergences" table holds
# every way this behaves differently from the C tool it replaced, each row
# naming the test that holds it. This is the one wrapper of the six that does
# NOT close its tool's divergences: five of them were ruled improvements to
# adopt.

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

mw_translate fix_macho "$@" || exit $?

mw_file=$1

mw_prepare "$mw_file" || exit 1
mw_retranslate fix_macho "$@" || exit 1

mw_run_to_tmp
mw_frc=$?
# spec: fix_macho had 0 and 1, so every nonzero folds to 1 (compat/README.md,
# "`fix_macho`: exit codes"). mw_frc, not mw_rc, which drydock-macho-rewrite-compat.sh owns.
[ "$mw_frc" -eq 0 ] || exit 1
mw_finish || exit 1
# spec: this line, not fix_macho's "File updated: F" (compat/README.md,
# "`fix_macho`: stdout is not reproduced").
[ "$MW_CHANGED" -eq 1 ] \
    && printf 'Updated %s (%s bytes)\n' "$mw_file" "$(wc -c < "$MW_TARGET" | tr -d ' ')"
exit 0
