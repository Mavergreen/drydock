#!/bin/sh
# patch_macho -- a /bin/sh wrapper around `drydock-macho-rewrite IN OUT` with one
# `fixups set classic` statement on its stdin.
#
#   patch_macho input output
#
# compat/translate.sh holds the grammar; compat/README.md's "patch_macho"
# section holds every difference from the C tool and the test for each.

MW_SELF=$(command -v "$0" 2>/dev/null) || MW_SELF=$0
MW_DIR=${DRYDOCK_MACHO_REWRITE_COMPAT_DIR:-$(dirname "$MW_SELF")}
[ -r "$MW_DIR/drydock-macho-rewrite-compat.sh" ] || {
    printf '%s: cannot find drydock-macho-rewrite-compat.sh in %s -- drydock-macho-rewrite and its two support\n' "$0" "$MW_DIR" >&2
    printf '%s: files must sit beside this wrapper; a symlink to it resolves to the\n' "$0" >&2
    printf '%s: SYMLINK directory, so set DRYDOCK_MACHO_REWRITE_COMPAT_DIR to where they really are\n' "$0" >&2
    exit 1
}
. "$MW_DIR/drydock-macho-rewrite-compat.sh"

mw_translate patch_macho "$@" || exit $?

mw_out=$2

# An existing OUT that is not a regular file is refused here: given a
# directory, mv would move the temp into it and exit 0.
if [ -d "$mw_out" ]; then
    printf 'create output: Is a directory\n' >&2
    exit 1
fi
if [ -e "$mw_out" ] && [ ! -f "$mw_out" ]; then
    printf '%s: %s is not a regular file; refusing to replace it\n' "$MW_TOOL" "$mw_out" >&2
    exit 1
fi

# new-ok: OUT need not exist yet. Thin only, and asked of IN, not OUT.
if ! mw_thin_only "$1"; then
    printf '%s: %s: not a readable 64-bit Mach-O; this tool is thin-only, so that covers a fat container as well as anything that is not a Mach-O at all\n' \
        "$MW_TOOL" "$1" >&2
    exit 1
fi
mw_prepare "$mw_out" new-ok || exit 1
mw_retranslate patch_macho "$@" || exit 1

mw_run_to_tmp
mw_rc=$?
[ "$mw_rc" -eq 0 ] || exit 1

# The mode patch_macho's open(OUT, O_CREAT, 0755) would have left.
if [ -e "$MW_TARGET" ]; then
    # An existing OUT keeps its mode; MW_TARGET is a symlinked OUT's target.
    mw_mode=$(stat -f %Lp "$MW_TARGET")
else
    # A fresh OUT: 0755 & ~umask. The leading 0 makes umask's digits octal.
    mw_umask=$(umask)
    mw_mode=$(printf '%o' "$(( 0755 & ~0$mw_umask ))")
fi
if ! chmod "$mw_mode" "$MW_TMPFILE" 2>/dev/null; then
    printf '%s: WARNING: could not chmod %s to %s; installing it with the mode\n' \
        "$0" "$mw_out" "$mw_mode" >&2
    printf '%s: drydock-macho-rewrite gave it instead, which is the input file mode\n' "$0" >&2
fi

mw_finish || exit 1

# patch_macho named the file it wrote only when it had CONVERTED something.
if ! grep -q '^Already patched' "$MW_T/out"; then
    printf 'Wrote %s (%s bytes)\n' "$mw_out" "$(wc -c < "$mw_out" | tr -d ' ')"
fi
exit 0
