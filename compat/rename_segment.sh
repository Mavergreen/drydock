#!/bin/sh
# rename_segment -- a /bin/sh wrapper around `drydock-macho-rewrite FILE OUT` with one
# `segment rename OLD NEW` statement on its stdin.
#
#   rename_segment binary OLDNAME NEWNAME
#
# compat/translate.sh holds the grammar; compat/README.md's "rename_segment:
# exit codes" maps each drydock-macho-rewrite exit to this tool's 0, 1 or 2.

MW_SELF=$(command -v "$0" 2>/dev/null) || MW_SELF=$0
MW_DIR=${DRYDOCK_MACHO_REWRITE_COMPAT_DIR:-$(dirname "$MW_SELF")}
[ -r "$MW_DIR/drydock-macho-rewrite-compat.sh" ] || {
    printf '%s: cannot find drydock-macho-rewrite-compat.sh in %s -- drydock-macho-rewrite and its two support\n' "$0" "$MW_DIR" >&2
    printf '%s: files must sit beside this wrapper; a symlink to it resolves to the\n' "$0" >&2
    printf '%s: SYMLINK directory, so set DRYDOCK_MACHO_REWRITE_COMPAT_DIR to where they really are\n' "$0" >&2
    exit 1
}
. "$MW_DIR/drydock-macho-rewrite-compat.sh"

mw_translate rename_segment "$@" || exit $?

mw_file=$1
mw_old=$2
mw_new=$3

mw_prepare "$mw_file" || exit 1

# THIN ONLY: rename_segment refused a fat container; info --thin does too.
if ! drydock-macho-rewrite info --thin "$mw_file" >/dev/null 2>&1; then
    printf '%s: not a readable 64-bit Mach-O\n' "$mw_file" >&2
    exit 1
fi

mw_retranslate rename_segment "$@" || exit 1

mw_run >"$MW_T/segout" 2>&1
mw_rc=$?

if [ "$mw_rc" -eq 1 ]; then
    mw_old16=$(printf '%s' "$mw_old" | LC_ALL=C cut -c1-16)
    if drydock-macho-rewrite info --thin "$mw_file" >"$MW_T/seginfo" 2>&1; then
        if LC_ALL=C grep -q -F -- "  segname=$mw_old16 vmaddr=" "$MW_T/seginfo"; then
            # OLD exists: the refusal is about something else.
            cat "$MW_T/segout" >&2
            exit 1
        fi
        # OLD does not exist: the C tool's exit 2, silently.
        exit 2
    fi
    # The query itself failed.
    cat "$MW_T/seginfo" >&2
    exit 1
fi

[ "$mw_rc" -eq 0 ] || { cat "$MW_T/segout" >&2; exit 1; }

# -x -F so metacharacters in OLD/NEW count as themselves.
mw_n=$(grep -c -x -F -- "  Rename segment: $mw_old -> $mw_new" "$MW_T/segout") || mw_n=0
if [ "$mw_n" -eq 0 ]; then
    printf '%s: %s: this drydock-macho-rewrite did not report what its segment rename matched\n' \
        "$MW_TOOL" "$mw_file" >&2
    cat "$MW_T/segout" >&2
    exit 1
fi

mw_finish || exit 1

printf '%s: renamed %d segment(s) %s -> %s\n' "$mw_file" "$mw_n" "$mw_old" "$mw_new"
exit 0
