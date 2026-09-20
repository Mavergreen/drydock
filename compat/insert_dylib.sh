#!/bin/sh
# insert_dylib -- a /bin/sh wrapper presenting Wowfunhappy/insert_dylib's
# command line (commit bd221b8) over `dylib append`/`dylib retype`, and,
# when asked, `load-command delete codesig`.
#
#   insert_dylib [flags] dylib_path binary_path [new_binary_path]
#
# NO KNOWN CALLERS. Unlike the six historical tools compat/ wraps, this repo
# never shipped insert_dylib, and no caller of it has ever been found; it is
# convenience for someone who already knows this fork's grammar, not
# compatibility debt. tests/known-callers.sh -- the decisive gate for the
# other six -- therefore has nothing to replay here and stays silent for
# this tool on purpose, not by oversight.
#
# THE SIX FLAGS. compat/translate.sh's mt_tr_insert_dylib carries the exact
# statement mapping (its own "insert_dylib" section); --inplace, --overwrite
# and --all-yes never become a statement there -- they choose OUT (mt_id_out)
# and, down here, whether a prompt is asked at all and how it answers.
#
# FIVE PROMPTS, READ FROM /dev/tty, NEVER FROM STDIN -- stdin is the
# statement channel to machorewrite, the same channel every other wrapper
# here uses it for. With --all-yes, none of the five is asked; id_confirm
# answers yes without touching a terminal at all. Without --all-yes, and
# with no /dev/tty to ask on, id_confirm REFUSES, naming --all-yes, rather
# than blocking a build script forever on a read nothing will ever answer.
#   1. LC_CODE_SIGNATURE found -- only when neither --strip-codesig nor
#      --no-strip-codesig was given, and only when the binary actually
#      carries one. Answering yes (or --all-yes) is what turns the ambiguous
#      "neither flag" case into an effective --strip-codesig before
#      compat/translate.sh is ever called (see MT_ID_EFFSTRIP below and that
#      file's own header for why the resolution happens here, not there).
#   2. the binary already names this dylib -- warns about the duplicate
#      `dylib append` is about to add regardless; declining refuses the run.
#   3. NOT reproduced as its own check. `dylib append`'s own header-pad
#      refusal (forwarded below through machorewrite's exit code) already
#      says no to the same question a hand-rolled space estimate would ask a
#      second time, so this wrapper never estimates space itself -- see
#      "DECLARED DIVERGENCES" below.
#   4. OUT already exists (suppressed by --overwrite). --inplace's OUT is
#      always the input, which always exists, so --inplace needs one of
#      --overwrite or a yes here on every run.
#   5. the dylib_path argument does not name a real file on THIS
#      filesystem -- a check on the string the caller passed, not on
#      anything the target binary carries.
#
# DECLARED DIVERGENCES from the fork (compat/README.md's insert_dylib table
# has the full list, each row naming the test that pins it):
#   * 32-bit input is refused outright, below, before machorewrite ever
#     runs -- this toolkit is 64-bit only everywhere, deliberately
#     (docs/prior-art.md), not a gap specific to this one tool.
#   * an image carrying LC_LAZY_LOAD_DYLIB is refused, by `dylib append`
#     itself (src/ordinals.c's mo_map_build), where the fork proceeds.
#   * exit codes are machorewrite's 0/1/2 forwarded verbatim; the fork exits
#     1 for everything. Matches the six historical wrappers' own choice for
#     the same reason: it costs nothing to keep the distinction machorewrite
#     already makes between a considered refusal and an operational failure.
#   * output bytes are not claimed equal to the fork's.
#   * prompt 3 above is not reproduced as its own interactive check.

MW_SELF=$(command -v "$0" 2>/dev/null) || MW_SELF=$0
MW_DIR=${MACHOREWRITE_COMPAT_DIR:-$(dirname "$MW_SELF")}
# platform: a symlink to this wrapper on PATH makes MW_DIR the SYMLINK's
# directory, not the one holding machorewrite -- which is why
# MACHOREWRITE_COMPAT_DIR exists. Checked before sourcing so the message is this
# one rather than the shell's own from the `.` below.
[ -r "$MW_DIR/machorewrite-compat.sh" ] || {
    printf '%s: cannot find machorewrite-compat.sh in %s -- machorewrite and its two support\n' "$0" "$MW_DIR" >&2
    printf '%s: files must sit beside this wrapper; a symlink to it resolves to the\n' "$0" >&2
    printf '%s: SYMLINK directory, so set MACHOREWRITE_COMPAT_DIR to where they really are\n' "$0" >&2
    exit 1
}
. "$MW_DIR/machorewrite-compat.sh"

MW_TOOL=insert_dylib

# Parsed once, here, with the SAME parser compat/translate.sh's
# mt_tr_insert_dylib uses (mt_id_parse; sourced in already by
# machorewrite-compat.sh above) -- one argv walk, not two silently drifting
# apart. What this wrapper needs that a pure translation cannot give it: the
# positionals and flags, ahead of the file inspection the prompts below do.
mt_id_parse "$@" || exit 1
id_all_yes=$MT_ID_ALLYES

# 32-BIT INPUT: refused here, by name, rather than through mi_open's generic
# "not a readable 64-bit Mach-O" (which says "64", never "32"), so a caller
# grepping the reason finds one. See "DECLARED DIVERGENCES" above.
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
    if machorewrite info "$MT_ID_BIN" 2>/dev/null | grep -q '^LC\[[0-9]*\] LC_CODE_SIGNATURE '; then
        id_confirm "LC_CODE_SIGNATURE load command found. Remove it?" && MT_ID_EFFSTRIP=1
    fi
fi

# PROMPT 2. `machorewrite info`'s "  ordinal=N path=PATH" lines are the same
# ones every other wrapper here already reads (compat/change_dylib.sh's
# insert-order assertion, for one); sed strips the fixed "  ordinal=N path="
# prefix so what is left is compared with grep -F, never a regex built from
# the caller's own path.
machorewrite info "$MT_ID_BIN" 2>/dev/null \
    | sed -n 's/^  ordinal=[0-9]* path=//p' >"$MW_T/id_paths"
if grep -qxF -- "$MT_ID_DYLIB" "$MW_T/id_paths"; then
    id_confirm "Binary already contains a load command for that dylib. Continue anyway?" || {
        printf '%s: refused: %s already names %s\n' "$MW_TOOL" "$MT_ID_BIN" "$MT_ID_DYLIB" >&2
        exit 1
    }
fi

# PROMPT 4.
MT_ID_OUT_PATH=$(mt_id_out)
if [ -z "$MT_ID_OVERWRITE" ] && [ -e "$MT_ID_OUT_PATH" ]; then
    id_confirm "$MT_ID_OUT_PATH already exists. Overwrite it?" || {
        printf '%s: refused: %s already exists\n' "$MW_TOOL" "$MT_ID_OUT_PATH" >&2
        exit 1
    }
fi

# PROMPT 5.
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
