#!/bin/sh
# insert_dylib -- a /bin/sh wrapper presenting Wowfunhappy/insert_dylib's
# command line (commit bd221b8) over `dylib append`/`dylib retype`, and,
# when asked, `load-command delete codesig`.
#
#   insert_dylib [flags] dylib_path binary_path [new_binary_path]
#
# NO KNOWN CALLERS: unlike the six historical tools compat/ wraps, this repo
# never shipped insert_dylib, so tests/known-callers.sh has nothing to replay
# here and stays silent for this tool on purpose, not by oversight.
#
# THE SIX FLAGS. compat/translate.sh's mt_tr_insert_dylib carries the exact
# statement mapping (its own "insert_dylib" section); --inplace, --overwrite
# and --all-yes never become a statement there -- they choose OUT (mt_id_out)
# and, down here, whether a prompt is asked at all and how it answers.
#
# FIVE PROMPTS, READ FROM /dev/tty, NEVER FROM STDIN -- stdin is the
# statement channel to drydock-macho-rewrite, the same channel every other wrapper
# here uses it for. See each PROMPT N below for what it asks and why;
# id_confirm is where --all-yes and "no /dev/tty to ask on" are decided.
#
# DECLARED DIVERGENCES from the fork: see compat/README.md's insert_dylib
# table, which names the test pinning each one.

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

MW_TOOL=insert_dylib

# Parsed once, here, with the SAME parser compat/translate.sh's
# mt_tr_insert_dylib uses (mt_id_parse; sourced in already by
# drydock-macho-rewrite-compat.sh above) -- one argv walk, not two silently drifting
# apart. What this wrapper needs that a pure translation cannot give it: the
# positionals and flags, ahead of the file inspection the prompts below do.
mt_id_parse "$@" || exit 1
id_all_yes=$MT_ID_ALLYES

# 32-BIT INPUT: refused here, by name, rather than through mi_open's generic
# "not a readable 64-bit Mach-O" (which says "64", never "32"), so a caller
# grepping the reason finds one. A declared divergence from the fork; see
# compat/README.md's insert_dylib table.
case $(od -An -tx1 -N4 -- "$MT_ID_BIN" 2>/dev/null | tr -d ' \n') in
feedface|cefaedfe)
    printf '%s: %s: 32-bit Mach-O input is refused; this toolkit is 64-bit only, deliberately, everywhere (docs/prior-art.md)\n' \
        "$MW_TOOL" "$MT_ID_BIN" >&2
    exit 1
    ;;
esac

id_no_tty_refuse() {
    printf '%s: %s\n' "$MW_TOOL" "$1" >&2
    printf '%s: no /dev/tty to ask on, and --all-yes was not given -- refusing rather than blocking a build script forever\n' "$MW_TOOL" >&2
    exit 1
}

# id_confirm PROMPT -- ask PROMPT on /dev/tty (never stdin -- see the header
# above) and return 0 for yes, 1 for no. --all-yes answers yes without ever
# touching a terminal, which is also what lets this run with no controlling
# terminal at all.
id_confirm() {
    [ -n "$id_all_yes" ] && return 0
    if { exec 3<> /dev/tty; } 2>/dev/null; then
        printf '%s [y/N] ' "$1" >&3
        IFS= read -r id_ans <&3
        id_rc=$?
        exec 3<&- 3>&-
        [ "$id_rc" -eq 0 ] || id_no_tty_refuse "$1"
        case $id_ans in [Yy]*) return 0 ;; *) return 1 ;; esac
    fi
    id_no_tty_refuse "$1"
}

# PROMPT 1. Only when the caller left the codesig question open, and only
# when the binary actually has one to remove -- the fork does not ask about
# a load command that is not there. MT_ID_EFFSTRIP is what turns a "yes"
# here (or --all-yes) into the same outcome an explicit --strip-codesig
# would have gotten.
MT_ID_EFFSTRIP=$MT_ID_STRIP
if [ -z "$MT_ID_STRIP" ] && [ -z "$MT_ID_NOSTRIP" ]; then
    if drydock-macho-rewrite info "$MT_ID_BIN" 2>/dev/null | grep -q '^LC\[[0-9]*\] LC_CODE_SIGNATURE '; then
        id_confirm "LC_CODE_SIGNATURE load command found. Remove it?" && MT_ID_EFFSTRIP=1
    fi
fi

# PROMPT 2. `drydock-macho-rewrite info`'s "  ordinal=N path=PATH" lines are the same
# ones every other wrapper here already reads (compat/change_dylib.sh's
# insert-order assertion, for one); sed strips the fixed "  ordinal=N path="
# prefix so what is left is compared with grep -F, never a regex built from
# the caller's own path.
drydock-macho-rewrite info "$MT_ID_BIN" 2>/dev/null \
    | sed -n 's/^  ordinal=[0-9]* path=//p' >"$MW_T/id_paths"
if grep -qxF -- "$MT_ID_DYLIB" "$MW_T/id_paths"; then
    id_confirm "Binary already contains a load command for that dylib. Continue anyway?" || {
        printf '%s: refused: %s already names %s\n' "$MW_TOOL" "$MT_ID_BIN" "$MT_ID_DYLIB" >&2
        exit 1
    }
fi

# PROMPT 3 ("it doesn't seem like there is enough empty space") is not
# reproduced as its own check -- `dylib append`'s own header-pad refusal,
# forwarded through drydock-macho-rewrite's exit code below, already says no to the
# same question a hand-rolled space estimate would ask a second time.

# PROMPT 4. OUT already exists (suppressed by --overwrite). --inplace's OUT
# is always the input, which always exists, so --inplace needs one of
# --overwrite or a yes here on every run.
MT_ID_OUT_PATH=$(mt_id_out)
if [ -z "$MT_ID_OVERWRITE" ] && [ -e "$MT_ID_OUT_PATH" ]; then
    id_confirm "$MT_ID_OUT_PATH already exists. Overwrite it?" || {
        printf '%s: refused: %s already exists\n' "$MW_TOOL" "$MT_ID_OUT_PATH" >&2
        exit 1
    }
fi

# PROMPT 5. A check on the STRING the caller passed as dylib_path, not on
# anything the target binary carries -- it does not have to exist for
# `dylib append` to name it.
if [ ! -e "$MT_ID_DYLIB" ]; then
    id_confirm "The provided dylib path doesn't exist. Continue anyway?" || {
        printf '%s: refused: %s does not exist\n' "$MW_TOOL" "$MT_ID_DYLIB" >&2
        exit 1
    }
fi

# The ambiguity is resolved now (MT_ID_EFFSTRIP), so compat/translate.sh
# never has to open a tty or read a file itself: it only ever sees an
# explicit --strip-codesig or --no-strip-codesig from here on.
set -- "$MT_ID_DYLIB" "$MT_ID_BIN"
[ -n "$MT_ID_NEWOUT" ] && set -- "$@" "$MT_ID_NEWOUT"
[ -n "$MT_ID_WEAK" ] && set -- --weak "$@"
[ -n "$MT_ID_INPLACE" ] && set -- --inplace "$@"
if [ -n "$MT_ID_EFFSTRIP" ]; then
    set -- --strip-codesig "$@"
else
    set -- --no-strip-codesig "$@"
fi

mw_translate insert_dylib "$@" || exit $?

if [ "$MT_ID_OUT_PATH" = "$MT_ID_BIN" ]; then
    mw_prepare "$MT_ID_BIN" || exit 1
else
    mw_prepare "$MT_ID_OUT_PATH" new-ok || exit 1
fi
mw_retranslate insert_dylib "$@" || exit 1

mw_run_to_tmp
mw_rc=$?
# Forwarded, never mapped -- the same choice compat/change_dylib.sh makes,
# and for the same reason (compat/README.md, "insert_dylib: exit codes").
[ "$mw_rc" -eq 0 ] || exit "$mw_rc"
mw_finish || exit 1
exit 0
