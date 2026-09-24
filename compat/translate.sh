#!/bin/sh
# compat/translate.sh -- print the drydock-macho-rewrite command line(s) an
# old-grammar invocation is equivalent to. Pure text: it opens, reads and
# runs nothing.
#
#   sh compat/translate.sh TOOL ARG...        print the equivalent, exit 0
#   MT_SOURCED=1 . compat/translate.sh        load mt_translate() and helpers
#
# Exit 0: the commands, one per line, none for a no-op. Exit 1: refused, with
# the old tool's own message on stderr wherever it refused too. Exit 2: no
# equivalent (no TOOL, or an unknown one). tests/translate_test.sh checks each
# case's exit code and whole stdout; compat/README.md tables the statements.

# ---- quoting -------------------------------------------------------------
#
# One argument, quoted only if it needs it. ms_split (src/script.c) reads a
# statement's words by shell rules, so the same quoting serves the script.
mt_quote() {
    case $1 in
        '') printf "''" ;;
        *[!A-Za-z0-9_@%+=:,./-]*)
            printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
        *) printf '%s' "$1" ;;
    esac
}

# Every argument, quoted, each preceded by one space -- so a caller can append
# the result to a partially built command line without tracking separators.
mt_qargs() {
    for mt_a in "$@"; do
        printf ' '
        mt_quote "$mt_a"
    done
}

# The output a translated command writes: MT_OUT (a wrapper's temp), or for
# the teaching form FILE.new, followed by mt_install_line's `mv -f`. A bare
# FILE beginning with `-` gets `./-FILE.new`, since drydock-macho-rewrite
# refuses an OUT beginning with `-`.
mt_new_name() {
    case $1 in
        -*) printf './%s.new' "$1" ;;
        *)  printf '%s.new' "$1" ;;
    esac
}
mt_out_for() {
    if [ -n "${MT_OUT:-}" ]; then printf '%s' "$MT_OUT"; else mt_new_name "$1"; fi
}
mt_install_line() {
    [ -n "${MT_OUT:-}" ] || printf 'mv -f%s\n' "$(mt_qargs "$(mt_new_name "$1")" "$1")"
}

# ---- the one command shape ----------------------------------------------
#
# mt_emit FILE OUT, statements on stdin -- print one
# `printf FORMAT | drydock-macho-rewrite FILE OUT`. The statements are the
# FORMAT, so `%` and `\` are doubled; mt_quote's single quotes are what the
# shell needs.
mt_emit() {
    mt_em_fmt=''
    while IFS= read -r mt_em_l; do
        [ -n "$mt_em_l" ] || continue
        mt_em_fmt="$mt_em_fmt$(printf '%s' "$mt_em_l" | sed -e 's/\\/\\\\/g' -e 's/%/%%/g')\\n"
    done
    printf 'printf %s | %s%s\n' "$(mt_quote "$mt_em_fmt")" "$(mt_pre_word)" \
        "$(mt_qargs "$1" "$2")"
}

# The origin tool's own diagnostic, on stderr, and a nonzero return.
mt_die() {
    printf '%s\n' "$1" >&2
    return 1
}

# mt_room COUNT MAX FLAG -- refuse the one past MAX, in change_dylib's words.
mt_room() {
    [ "$1" -eq "$2" ] || return 0
    printf 'too many %s (max %d)\n' "$3" "$2" >&2
    return 1
}

# The old tools' caps: -change/-delete/-reexport share 32, as do
# -change-rpath/-delete-rpath; -add, -insert and -add-rpath get 32 each;
# -strip-lc 16; fix_macho's -change 32 and -rename_seg 16. Nothing downstream
# counts operations, so these are the only enforcement.
MT_MAX_OPS=32
MT_MAX_STRIP=16
MT_MAX_RENAMES=16

# change_dylib's -strip-lc vocabulary, frozen. tests/translate_test.sh checks
# it against what `drydock-macho-rewrite --capabilities` advertises.
MT_STRIP_KINDS='uuid codesig source-version build-version code-sign-drs'

# The C tool's argv[0] in a usage line; mt_translate sets it on every call.
MT_PROG=${MT_PROG:-translate.sh}

# ---- change_dylib --------------------------------------------------------
mt_cd_usage() {
    printf 'Usage: %s input [-grow] [-change old new] [-delete path] [-reexport path] [-add path] [-insert path] [-strip-lc name] [-change-rpath old new] [-delete-rpath path] [-add-rpath path] ...\n' "$MT_PROG" >&2
    printf '  -strip-lc kinds:' >&2
    for mt_k in $MT_STRIP_KINDS; do printf ' %s' "$mt_k" >&2; done
    printf '\n' >&2
    return 1
}

mt_tr_change_dylib() {
    # change_dylib's `argc < 4`: `change_dylib FILE -grow` is a usage error.
    [ $# -ge 3 ] || { mt_cd_usage; return 1; }

    mt_file=$1; shift
    # The operations as statements, bucketed by kind for the emission order.
    mt_st_lc='' mt_st_dydel='' mt_st_dyrepl='' mt_st_dyapp='' mt_st_dyins=''
    mt_st_rpapp=''
    # -change/-delete/-reexport and their rpath spellings, in flag order.
    mt_st_dychg='' mt_st_rpchg=''
    mt_nchanges=0 mt_nadds=0 mt_ninserts=0
    mt_nrchanges=0 mt_nradds=0 mt_nstrip=0

    while [ $# -gt 0 ]; do
        case $1 in
        -grow)
            # spec: compat/README.md "change_dylib: header growth" -- accepted, and
            # asks for nothing: a statement that outgrows the pad grows it.
            shift ;;
        -strip-lc)
            [ $# -ge 2 ] || { mt_die "bad arg: $1"; return 1; }
            mt_found=0
            for mt_k in $MT_STRIP_KINDS; do
                [ "$2" = "$mt_k" ] && { mt_found=1; break; }
            done
            [ "$mt_found" -eq 1 ] || { mt_die "unknown -strip-lc kind: $2"; return 1; }
            mt_room "$mt_nstrip" "$MT_MAX_STRIP" -strip-lc || return 1
            mt_nstrip=$((mt_nstrip + 1))
            mt_st_lc="$mt_st_lc$(printf 'load-command delete%s' "$(mt_qargs "$2")")
"
            shift 2 ;;
        -add)
            [ $# -ge 2 ] || { mt_die "bad arg: $1"; return 1; }
            mt_room "$mt_nadds" "$MT_MAX_OPS" -add || return 1
            mt_nadds=$((mt_nadds + 1))
            mt_st_dyapp="$mt_st_dyapp$(printf 'dylib append%s' "$(mt_qargs "$2")")
"
            shift 2 ;;
        -insert)
            [ $# -ge 2 ] || { mt_die "bad arg: $1"; return 1; }
            mt_room "$mt_ninserts" "$MT_MAX_OPS" -insert || return 1
            mt_ninserts=$((mt_ninserts + 1))
            # Prepended: inserts run in reverse (see the emission order below).
            mt_st_dyins="$(printf 'dylib insert%s' "$(mt_qargs "$2")")
$mt_st_dyins"
            shift 2 ;;
        -change)
            [ $# -ge 3 ] || { mt_die "bad arg: $1"; return 1; }
            mt_room "$mt_nchanges" "$MT_MAX_OPS" -change || return 1
            mt_nchanges=$((mt_nchanges + 1))
            mt_st_dychg="$mt_st_dychg$(printf 'dylib replace%s' "$(mt_qargs "$2" "$3")")
"
            shift 3 ;;
        -delete)
            [ $# -ge 2 ] || { mt_die "bad arg: $1"; return 1; }
            mt_room "$mt_nchanges" "$MT_MAX_OPS" -delete || return 1
            mt_nchanges=$((mt_nchanges + 1))
            mt_st_dychg="$mt_st_dychg$(printf 'dylib delete%s' "$(mt_qargs "$2")")
"
            shift 2 ;;
        -reexport)
            [ $# -ge 2 ] || { mt_die "bad arg: $1"; return 1; }
            mt_room "$mt_nchanges" "$MT_MAX_OPS" -reexport || return 1
            mt_nchanges=$((mt_nchanges + 1))
            mt_st_dychg="$mt_st_dychg$(printf 'dylib reexport%s' "$(mt_qargs "$2")")
"
            shift 2 ;;
        -add-rpath)
            [ $# -ge 2 ] || { mt_die "bad arg: $1"; return 1; }
            mt_room "$mt_nradds" "$MT_MAX_OPS" -add-rpath || return 1
            mt_nradds=$((mt_nradds + 1))
            mt_st_rpapp="$mt_st_rpapp$(printf 'rpath append%s' "$(mt_qargs "$2")")
"
            shift 2 ;;
        -change-rpath)
            [ $# -ge 3 ] || { mt_die "bad arg: $1"; return 1; }
            mt_room "$mt_nrchanges" "$MT_MAX_OPS" -change-rpath || return 1
            mt_nrchanges=$((mt_nrchanges + 1))
            mt_st_rpchg="$mt_st_rpchg$(printf 'rpath replace%s' "$(mt_qargs "$2" "$3")")
"
            shift 3 ;;
        -delete-rpath)
            [ $# -ge 2 ] || { mt_die "bad arg: $1"; return 1; }
            mt_room "$mt_nrchanges" "$MT_MAX_OPS" -delete-rpath || return 1
            mt_nrchanges=$((mt_nrchanges + 1))
            mt_st_rpchg="$mt_st_rpchg$(printf 'rpath delete%s' "$(mt_qargs "$2")")
"
            shift 2 ;;
        *)
            mt_die "bad arg: $1"; return 1 ;;
        esac
    done

    # ONE COMMAND: the bare form, with every operation as a statement.
    #
    # CONFLICTS RESOLVE IN THE ORDER WRITTEN. Two operations naming the same
    # path apply one after the other, exactly as typed, and the second sees
    # what the first left. That is the whole rule, and it is the same rule
    # whether the invocation touches one family or three.
    #
    # The remaining order is about what the statements DO, not about resolving
    # conflicts between them:
    #
    #   1. every `load-command delete` first, because deleting commands hands
    #      header pad back and everything else may need the room;
    #   2. each family's walk operations, in flag order;
    #   3. that family's appends, which add a command the walk operations
    #      above were written about the absence of;
    #   4. then its inserts IN REVERSE FLAG ORDER, because each insert goes to
    #      the FRONT of the table: `-insert A -insert B` leaves A at ordinal 1
    #      and B at 2, which a sequence reaches by inserting B and then A.
    #      tests/wrapper_test.sh asserts those ordinals on a real binary.
    #
    # dylib before rpath so the emitted text is deterministic; LC_RPATH carries
    # no ordinal, so nothing depends on which side of it the dylib work falls.
    mt_body=$({
        printf '%s%s%s%s%s%s' "$mt_st_lc" "$mt_st_dychg" "$mt_st_dyapp" \
            "$mt_st_dyins" "$mt_st_rpchg" "$mt_st_rpapp"
    })
    # `change_dylib FILE -grow -grow` asks for nothing: no command, no install.
    [ -n "$mt_body" ] || return 0
    # allow-unmatched: change_dylib exited 0 on a miss (compat/README.md).
    mt_emit "$mt_file" "$(mt_out_for "$mt_file")" <<MT_CD_BODY
allow-unmatched
$mt_body
MT_CD_BODY
    mt_install_line "$mt_file"
    return 0
}

# ---- fix_macho -----------------------------------------------------------
mt_fm_usage() {
    printf 'Usage: %s <file> [-change old new] [-strip_build_version]\n' "$MT_PROG" >&2
    return 1
}

mt_tr_fix_macho() {
    # `argc < 3`: program name plus fewer than two arguments.
    [ $# -ge 2 ] || { mt_fm_usage; return 1; }

    mt_file=$1; shift
    # The operations as statements, in the order the flags were written --
    # see mt_tr_change_dylib's emission comment for the rule.
    mt_st_lc='' mt_st_seg='' mt_st_dychg=''
    mt_nchanges=0 mt_nrenames=0

    while [ $# -gt 0 ]; do
        case $1 in
        -change)
            [ $# -ge 3 ] || { mt_die "Unknown option: $1"; return 1; }
            mt_room "$mt_nchanges" "$MT_MAX_OPS" -change || return 1
            mt_nchanges=$((mt_nchanges + 1))
            mt_st_dychg="$mt_st_dychg$(printf 'dylib replace%s' "$(mt_qargs "$2" "$3")")
"
            shift 3 ;;
        -strip_build_version)
            # A boolean flag: a repeat assigns rather than appends.
            mt_st_lc='load-command delete build-version
'
            shift ;;
        -rename_seg)
            [ $# -ge 3 ] || { mt_die "Unknown option: $1"; return 1; }
            # fix_macho's 16-byte segname limit, in its words. ${#3} counts
            # characters, not bytes: a longer multibyte name is refused
            # downstream by mseg_name_fits instead.
            [ "${#3}" -le 16 ] || { mt_die "new segment name longer than 16 bytes: $3"; return 1; }
            mt_room "$mt_nrenames" "$MT_MAX_RENAMES" -rename_seg || return 1
            mt_nrenames=$((mt_nrenames + 1))
            mt_st_seg="$mt_st_seg$(printf 'segment rename%s' "$(mt_qargs "$2" "$3")")
"
            shift 3 ;;
        *)
            mt_die "Unknown option: $1"; return 1 ;;
        esac
    done

    # lc, then dylib, then segment: a rename changes no sizes, so it goes last.
    # allow-unmatched: fix_macho exited 0 on a miss (compat/README.md).
    mt_emit "$mt_file" "$(mt_out_for "$mt_file")" <<MT_FM_BODY
allow-unmatched
$mt_st_lc$mt_st_dychg$mt_st_seg
MT_FM_BODY
    mt_install_line "$mt_file"
    return 0
}

# ---- the four fixed-arity tools -----------------------------------------
mt_tr_add_version_min() {
    # `argc != 2`; the C tool took no version, and 10.9 was its floor.
    [ $# -eq 1 ] || { printf 'Usage: %s binary\n' "$MT_PROG" >&2; return 1; }
    mt_emit "$1" "$(mt_out_for "$1")" <<'MT_AVM_BODY'
minos if-absent 10.9
MT_AVM_BODY
    mt_install_line "$1"
}

mt_tr_patch_macho() {
    # `argc != 3`.
    [ $# -eq 2 ] || { printf 'Usage: %s input output\n' "$MT_PROG" >&2; return 1; }
    # patch_macho's grammar names its output, so the teaching form is the
    # command as typed -- unless IN and OUT are the same string, which
    # drydock-macho-rewrite refuses; that form gets OUT.new and an install.
    if [ -z "${MT_OUT:-}" ] && [ "$1" != "$2" ]; then
        mt_emit "$1" "$2" <<'MT_PM_BODY'
fixups set classic
MT_PM_BODY
        return 0
    fi
    mt_emit "$1" "$(mt_out_for "$2")" <<'MT_PM_BODY'
fixups set classic
MT_PM_BODY
    mt_install_line "$2"
}

mt_tr_rename_segment() {
    # `argc != 4`, then the 16-byte segname check, in rename_segment's words.
    [ $# -eq 3 ] || { printf 'Usage: %s binary OLDNAME NEWNAME\n' "$MT_PROG" >&2; return 1; }
    [ "${#3}" -le 16 ] || { mt_die 'new segment name longer than 16 bytes'; return 1; }
    mt_emit "$1" "$(mt_out_for "$1")" <<MT_RS_BODY
segment rename$(mt_qargs "$2" "$3")
MT_RS_BODY
    mt_install_line "$1"
}

mt_tr_retag_swift_classes() {
    # `argc < 2`. Variadic over FILES: one command per file, in argv order.
    # MT_OUT names one output, so a wrapper sets it only per file.
    [ $# -ge 1 ] || { printf 'Usage: %s binary [binary ...]\n' "$MT_PROG" >&2; return 1; }
    for mt_f in "$@"; do
        mt_emit "$mt_f" "$(mt_out_for "$mt_f")" <<'MT_RSC_BODY'
swift-abi set legacy
MT_RSC_BODY
        mt_install_line "$mt_f"
    done
}

# ---- insert_dylib ---------------------------------------------------------
#
# Not one of the six: the grammar of Wowfunhappy/insert_dylib at bd221b8.
#
#   insert_dylib [flags] dylib_path binary_path [new_binary_path]
#     (no flags)          dylib append DYLIB
#     --weak              dylib append DYLIB, dylib retype DYLIB weak
#     --strip-codesig     also: load-command delete codesig
#     --no-strip-codesig  (nothing extra; the wrapper never asks about it)
#
# --inplace, --overwrite and --all-yes choose OUT (mt_id_out) and, in the
# wrapper, how a prompt is answered; none becomes a statement.
mt_id_usage() {
    printf 'usage: %s [--inplace] [--weak] [--overwrite] [--strip-codesig] [--no-strip-codesig] [--all-yes] dylib_path binary_path [new_binary_path]\n' "$MT_PROG" >&2
    return 1
}

# mt_id_parse ARG... -- sets MT_ID_DYLIB, MT_ID_BIN, MT_ID_NEWOUT (may be
# empty) and MT_ID_INPLACE/MT_ID_WEAK/MT_ID_OVERWRITE/MT_ID_ALLYES/
# MT_ID_STRIP/MT_ID_NOSTRIP (each '' or 1). compat/insert_dylib.sh calls it
# too, to learn DYLIB, BIN and OUT.
mt_id_parse() {
    MT_ID_DYLIB='' MT_ID_BIN='' MT_ID_NEWOUT=''
    MT_ID_INPLACE='' MT_ID_WEAK='' MT_ID_OVERWRITE=''
    MT_ID_ALLYES='' MT_ID_STRIP='' MT_ID_NOSTRIP=''
    mt_id_n=0
    for mt_id_a in "$@"; do
        case $mt_id_a in
        --inplace)          MT_ID_INPLACE=1 ;;
        --weak)              MT_ID_WEAK=1 ;;
        --overwrite)         MT_ID_OVERWRITE=1 ;;
        --strip-codesig)     MT_ID_STRIP=1 ;;
        --no-strip-codesig)  MT_ID_NOSTRIP=1 ;;
        --all-yes)           MT_ID_ALLYES=1 ;;
        --*)
            mt_die "insert_dylib: unknown option $mt_id_a"; return 1 ;;
        *)
            mt_id_n=$((mt_id_n + 1))
            case $mt_id_n in
            1) MT_ID_DYLIB=$mt_id_a ;;
            2) MT_ID_BIN=$mt_id_a ;;
            3) MT_ID_NEWOUT=$mt_id_a ;;
            *) mt_id_usage; return 1 ;;
            esac ;;
        esac
    done
    [ "$mt_id_n" -ge 2 ] || { mt_id_usage; return 1; }
    if [ -n "$MT_ID_STRIP" ] && [ -n "$MT_ID_NOSTRIP" ]; then
        mt_die "insert_dylib: --strip-codesig and --no-strip-codesig are mutually exclusive"
        return 1
    fi
    # The fork silently ignores new_binary_path under --inplace and overwrites
    # BIN; refused instead (compat/README.md's insert_dylib table).
    if [ -n "$MT_ID_INPLACE" ] && [ -n "$MT_ID_NEWOUT" ]; then
        mt_die "insert_dylib: --inplace and new_binary_path $MT_ID_NEWOUT are mutually exclusive"
        return 1
    fi
    return 0
}

# mt_id_out -- OUT as the fork's source at bd221b8 names it: new_binary_path,
# else BIN under --inplace, else "<BIN>_patched" (appended; the fork's README
# says "prepended", which is wrong).
mt_id_out() {
    if [ -n "$MT_ID_NEWOUT" ]; then
        printf '%s' "$MT_ID_NEWOUT"
    elif [ -n "$MT_ID_INPLACE" ]; then
        printf '%s' "$MT_ID_BIN"
    else
        printf '%s_patched' "$MT_ID_BIN"
    fi
}

mt_tr_insert_dylib() {
    mt_id_parse "$@" || return 1
    mt_out=$(mt_id_out)

    # allow-unmatched: --strip-codesig on an unsigned binary exited 0 upstream (compat/README.md).
    mt_body="allow-unmatched
dylib append$(mt_qargs "$MT_ID_DYLIB")
"
    [ -n "$MT_ID_WEAK" ] && mt_body="$mt_body$(printf 'dylib retype%s' "$(mt_qargs "$MT_ID_DYLIB" weak)")
"
    [ -n "$MT_ID_STRIP" ] && mt_body="$mt_body$(printf 'load-command delete%s' "$(mt_qargs codesig)")
"

    # Same fork as mt_tr_patch_macho: OUT is named unless it is BIN itself.
    if [ -z "${MT_OUT:-}" ] && [ "$mt_out" != "$MT_ID_BIN" ]; then
        mt_emit "$MT_ID_BIN" "$mt_out" <<MT_ID_BODY
$mt_body
MT_ID_BODY
        return 0
    fi
    mt_emit "$MT_ID_BIN" "$(mt_out_for "$MT_ID_BIN")" <<MT_ID_BODY
$mt_body
MT_ID_BODY
    mt_install_line "$MT_ID_BIN"
    return 0
}

# The drydock-macho-rewrite program word, quoted, with mt_qargs' leading space trimmed.
mt_pre_word() {
    mt_p="$(mt_qargs "${DRYDOCK_MACHO_REWRITE:-drydock-macho-rewrite}")"
    printf '%s' "${mt_p# }"
}

# ---- dispatcher ----------------------------------------------------------
#
# mt_translate TOOL ARG...
#
# TOOL is the historical binary's name. The usage lines print MT_PROG where the
# C tools printed argv[0]; it is set to TOOL on every call, and a wrapper that
# wants its own $0 there instead presets MT_PROG0.
mt_translate() {
    [ $# -ge 1 ] || { printf 'usage: translate.sh TOOL ARG...\n' >&2; return 2; }
    mt_tool=$1; shift
    MT_PROG=${MT_PROG0:-$mt_tool}
    case $mt_tool in
        change_dylib)         mt_tr_change_dylib "$@" ;;
        add_version_min)      mt_tr_add_version_min "$@" ;;
        patch_macho)          mt_tr_patch_macho "$@" ;;
        rename_segment)       mt_tr_rename_segment "$@" ;;
        retag_swift_classes)  mt_tr_retag_swift_classes "$@" ;;
        fix_macho)            mt_tr_fix_macho "$@" ;;
        insert_dylib)         mt_tr_insert_dylib "$@" ;;
        *)
            # No fallback: a guessed command line for a tool this file does
            # not know is the failure it exists to rule out.
            printf 'translate.sh: no equivalent -- unknown tool %s (expected one of: change_dylib add_version_min patch_macho rename_segment retag_swift_classes fix_macho insert_dylib)\n' "$mt_tool" >&2
            return 2 ;;
    esac
}

# Run directly, unless sourced with MT_SOURCED set (which is how the
# wrappers pull the functions in without triggering a translation).
if [ -z "${MT_SOURCED:-}" ]; then
    mt_translate "$@"
    exit $?
fi
