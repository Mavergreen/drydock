#!/bin/sh
# bake-mavericks-shim -- make a binary that needs
#
#     DYLD_FORCE_FLAT_NAMESPACE=1 DYLD_INSERT_LIBRARIES=SHIM ./binary
#
# into one that needs neither, by loading SHIM itself and binding to it every
# import SHIM exports:
#
#     bake-mavericks-shim INPUT [OUTPUT] [--shim PATH]
#
# OUTPUT defaults to INPUT.selfcontained, SHIM to
# /usr/local/lib/libMavericksLegacySystem.B.dylib.
#
# THE DESIGN IS WOWFUNHAPPY'S: his bake-mavericks-shim.py strips the code
# signature, adds the shim as LC_LOAD_DYLIB, and points exactly the imports
# whose symbol the shim exports at the shim's ordinal. This wrapper keeps his
# command line and his summary, and does the work as ONE edit script:
#
#     fixups set classic            only if INPUT has chained fixups
#     load-command delete codesig   only if INPUT is signed
#     dylib append SHIM             unless INPUT already loads it
#     import redirect SYMBOL LIBRARY SHIM
#                                   one per import `imports` reports whose
#                                   symbol `exports SHIM` lists, whatever
#                                   library it came from
#
# NO KNOWN CALLERS: like compat/insert_dylib.sh, this wraps a tool this repo
# never shipped, so tests/known-callers.sh has nothing to replay for it.
#
# DECLARED DIVERGENCES from the Python: see compat/README.md's
# bake-mavericks-shim table, which names the test pinning each one.

MW_SELF=$(command -v "$0" 2>/dev/null) || MW_SELF=$0
MW_DIR=${DRYDOCK_MACHO_REWRITE_COMPAT_DIR:-$(dirname "$MW_SELF")}
# platform: a symlink to this wrapper on PATH makes MW_DIR the SYMLINK's
# directory, not the one holding drydock-macho-rewrite; see compat/insert_dylib.sh.
[ -r "$MW_DIR/drydock-macho-rewrite-compat.sh" ] || {
    printf '%s: cannot find drydock-macho-rewrite-compat.sh in %s -- drydock-macho-rewrite and its two support\n' "$0" "$MW_DIR" >&2
    printf '%s: files must sit beside this wrapper; a symlink to it resolves to the\n' "$0" >&2
    printf '%s: SYMLINK directory, so set DRYDOCK_MACHO_REWRITE_COMPAT_DIR to where they really are\n' "$0" >&2
    exit 1
}
. "$MW_DIR/drydock-macho-rewrite-compat.sh"

MW_TOOL=bake-mavericks-shim
bk_shim=/usr/local/lib/libMavericksLegacySystem.B.dylib

bk_usage() {
    printf 'usage: %s [-h] [--shim SHIM] input [output]\n' "$MW_TOOL"
}
bk_die() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}
bk_bad_args() {
    bk_usage >&2
    printf '%s: error: %s\n' "$MW_TOOL" "$1" >&2
    exit 2
}

bk_in='' bk_out='' bk_npos=0
while [ "$#" -gt 0 ]; do
    case $1 in
        -h|--help)
            bk_usage
            printf '\nBake the Mavericks legacy shim into a modern Mach-O binary so it runs with no\n'
            printf 'wrapper and no DYLD_* environment variables.\n'
            exit 0 ;;
        --shim)
            [ "$#" -ge 2 ] || bk_bad_args "argument --shim: expected one argument"
            bk_shim=$2; shift 2; continue ;;
        --shim=*)
            bk_shim=${1#--shim=}; shift; continue ;;
        --)
            shift
            for bk_a in "$@"; do
                bk_npos=$((bk_npos + 1))
                case $bk_npos in 1) bk_in=$bk_a ;; 2) bk_out=$bk_a ;; esac
            done
            break ;;
        -?*)
            bk_bad_args "unrecognized arguments: $1" ;;
    esac
    bk_npos=$((bk_npos + 1))
    case $bk_npos in 1) bk_in=$1 ;; 2) bk_out=$1 ;; esac
    shift
done
[ "$bk_npos" -ge 1 ] || bk_bad_args "the following arguments are required: input"
[ "$bk_npos" -le 2 ] || bk_bad_args "unrecognized arguments"

[ -e "$bk_in" ] || bk_die "input not found: $bk_in"
[ -e "$bk_shim" ] || bk_die "shim not found: $bk_shim"
[ -n "$bk_out" ] || bk_out="$bk_in.selfcontained"

# spec: compat/README.md "bake-mavericks-shim" -- is there a signature, is the
# shim loaded: no query answers either across a fat file's slices, so a trial
# run under fatal-warnings does, by whether its one statement matched.
bk_matches() {
    printf 'fatal-warnings\n%s\n' "$2" | drydock-macho-rewrite "$1" "$MW_T/probe" >/dev/null 2>&1
    bk_m=$?
    rm -f "$MW_T/probe"
    return "$bk_m"
}

drydock-macho-rewrite exports "$bk_shim" >"$MW_T/exports.tsv" 2>"$MW_T/err" || {
    cat "$MW_T/err" >&2
    bk_die "cannot read the shim's exports: $bk_shim"
}
awk -F'\t' 'NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next } { print $c["symbol"] }' \
    "$MW_T/exports.tsv" | sort -u >"$MW_T/exports"
printf 'shim exports %d symbols (%s)\n' "$(wc -l <"$MW_T/exports" | tr -d ' ')" "$bk_shim"

bk_script=''
bk_query=$bk_in
if ! drydock-macho-rewrite imports "$bk_in" >"$MW_T/imports.tsv" 2>"$MW_T/err"; then
    # spec: compat/README.md "bake-mavericks-shim" -- chained fixups, converted.
    if printf 'fixups set classic\n' | drydock-macho-rewrite "$bk_in" "$MW_T/classic" >/dev/null 2>&1 &&
       drydock-macho-rewrite imports "$MW_T/classic" >"$MW_T/imports.tsv" 2>/dev/null; then
        bk_script='fixups set classic
'
        bk_query=$MW_T/classic
    else
        cat "$MW_T/err" >&2
        bk_die "cannot read the imports of $bk_in"
    fi
fi

if bk_matches "$bk_query" 'load-command delete codesig'; then
    bk_script="${bk_script}load-command delete codesig
"
    printf 'code signature: stripped\n'
else
    printf 'code signature: none present\n'
fi

bk_q_shim=$(mt_quote "$bk_shim")
if bk_matches "$bk_query" "dylib retype $bk_q_shim load"; then
    bk_added='(already present, reused)'
else
    bk_script="${bk_script}dylib append $bk_q_shim
"
    bk_added='(newly added)'
fi

# platform: `awk -v` escape-processes what it assigns, so the shim's path
# reaches awk through the environment (compat/drydock-macho-rewrite-compat.sh,
# mw_run_to_tmp, has the measurement).
BK_SHIM=$bk_shim
export BK_SHIM
awk -F'\t' 'NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
    $c["stream"] != "weak" && $c["install_name"] != "-" && $c["install_name"] != ENVIRON["BK_SHIM"] {
        print $c["symbol"] "\t" $c["install_name"] }' "$MW_T/imports.tsv" | sort -u >"$MW_T/binds"
awk -F'\t' 'NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
    $c["stream"] == "weak" { print $c["symbol"] }' "$MW_T/imports.tsv" | sort -u >"$MW_T/weak"

awk -F'\t' 'NR == FNR { want[$0] = 1; next } ($1 in want)' "$MW_T/exports" "$MW_T/binds" >"$MW_T/moves"
[ -s "$MW_T/moves" ] ||
    bk_die "none of the binary's imports are provided by the shim -- wrong shim, or nothing to do"

bk_hits=$(awk 'NR == FNR { want[$0] = 1; next } ($0 in want)' "$MW_T/exports" "$MW_T/weak" | awk '
    { s = s (NR > 1 ? ", " : "") $0 } END { print s }')
[ -n "$bk_hits" ] &&
    printf 'WARNING: these shim symbols appear in the weak-bind table and were NOT redirected:\n  %s\n' "$bk_hits" >&2

while IFS='	' read -r bk_sym bk_lib; do
    bk_script="${bk_script}import redirect $(mt_quote "$bk_sym") $(mt_quote "$bk_lib") $bk_q_shim
"
done <"$MW_T/moves"

mw_prepare "$bk_out" new-ok || exit 1
printf '%s' "$bk_script" | drydock-macho-rewrite "$bk_in" "$MW_TMPFILE" >/dev/null 2>"$MW_T/err"
bk_rc=$?
cat "$MW_T/err" >&2
# spec: compat/README.md "bake-mavericks-shim" -- exit codes are forwarded.
[ "$bk_rc" -eq 0 ] || exit "$bk_rc"

bk_ord=$(drydock-macho-rewrite imports "$MW_TMPFILE" 2>/dev/null | awk -F'\t' '
    NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
    $c["install_name"] == ENVIRON["BK_SHIM"] { print $c["ordinal"]; exit }')
printf 'shim linked as ordinal %s %s\n' "$bk_ord" "$bk_added"

bk_place=''
grep -q '^      bind stream grew from' "$MW_T/err" &&
    bk_place='regular table relocated to the end of __LINKEDIT'
grep -q '^      bind stream rewritten in place' "$MW_T/err" && [ -z "$bk_place" ] &&
    bk_place='regular table in place'
if grep -q '^      redirected .* lazy [1-9]' "$MW_T/err"; then
    [ -n "$bk_place" ] && bk_place="$bk_place; "
    bk_place="${bk_place}lazy table rewritten in place"
fi
cut -f1 "$MW_T/moves" | sort -u >"$MW_T/moved"
printf 'redirected %d imports to the shim; bind data: %s:\n' \
    "$(wc -l <"$MW_T/moved" | tr -d ' ')" "$bk_place"
sed 's/^/    /' "$MW_T/moved"

mw_finish || exit 1
chmod 755 "$bk_out" || exit 1
printf '\nwrote self-contained binary: %s\n' "$bk_out"
printf 'verify with:  %s --version   (from any directory, no env vars)\n' "$bk_out"
exit 0
