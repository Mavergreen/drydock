#!/bin/sh
# retag_swift_classes -- a /bin/sh wrapper around `drydock-macho-rewrite FILE OUT` with one
# `swift-abi set legacy` statement on its stdin, once per argument.
#
#   retag_swift_classes binary [binary ...]
#
# compat/README.md's "retag_swift_classes" section maps each argument's
# outcome to its exit code and stdout, and names the test for each.

MW_SELF=$(command -v "$0" 2>/dev/null) || MW_SELF=$0
MW_DIR=${DRYDOCK_MACHO_REWRITE_COMPAT_DIR:-$(dirname "$MW_SELF")}
[ -r "$MW_DIR/drydock-macho-rewrite-compat.sh" ] || {
    printf '%s: cannot find drydock-macho-rewrite-compat.sh in %s -- drydock-macho-rewrite and its two support\n' "$0" "$MW_DIR" >&2
    printf '%s: files must sit beside this wrapper; a symlink to it resolves to the\n' "$0" >&2
    printf '%s: SYMLINK directory, so set DRYDOCK_MACHO_REWRITE_COMPAT_DIR to where they really are\n' "$0" >&2
    exit 1
}
. "$MW_DIR/drydock-macho-rewrite-compat.sh"

mw_translate retag_swift_classes "$@" || exit $?

mw_total=0
mw_had_error=0
for mw_f in "$@"; do
    mw_prepare "$mw_f" || { mw_had_error=1; continue; }
    if ! mw_thin_only "$mw_f"; then
        rm -f -- "$MW_TMPFILE"; MW_TMPFILE=''
        continue
    fi
    mw_retranslate retag_swift_classes "$mw_f" || {
        mw_had_error=1
        rm -f -- "$MW_TMPFILE"; MW_TMPFILE=''
        continue
    }
    eval "$MW_CMDS" </dev/null >"$MW_T/out" 2>"$MW_T/err"
    mw_rc=$?
    case $mw_rc in
    0)
        mw_n=$(sed -n 's/^  *retagged \([0-9][0-9]*\) class records*$/\1/p' "$MW_T/err" \
            | awk '{ n += $1 } END { print n + 0 }')
        cat "$MW_T/err" >&2
        if mw_finish; then
            if [ "$mw_n" -gt 0 ]; then
                printf '%s: retagged %d class record(s)\n' "$mw_f" "$mw_n"
                mw_total=$((mw_total + mw_n))
            fi
        else
            mw_had_error=1
        fi
        ;;
    1)
        rm -f -- "$MW_TMPFILE"; MW_TMPFILE=''
        ;;
    *)
        cat "$MW_T/err" >&2
        mw_had_error=1
        rm -f -- "$MW_TMPFILE"; MW_TMPFILE=''
        ;;
    esac
done

printf 'total: %d class record(s) retagged\n' "$mw_total"
[ "$mw_had_error" -eq 0 ] || exit 1
exit 0
