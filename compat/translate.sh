#!/bin/sh
# compat/translate.sh -- turn an OLD-grammar invocation into the machotool
# command line(s) it is equivalent to, and PRINT them. Nothing here opens,
# reads, executes or rewrites anything: this file is a pure function from one
# argv to a list of command lines.
#
#   sh compat/translate.sh TOOL ARG...        print the equivalent, exit 0
#   MT_SOURCED=1 . compat/translate.sh        load mt_translate() and helpers
#
# TOOL is one of the six historical binaries: change_dylib, add_version_min,
# patch_macho, rename_segment, retag_swift_classes, fix_macho. ARG... is that
# tool's own argv[1..], verbatim.
#
# WHY THIS IS NOT A RENAME. docs/PROPOSAL.md rejected `-add_rpath`, bare
# `-rpath`, `-change` and `-add` as machotool synonyms on purpose, because they
# "would advertise an interchangeability that does not exist, on exactly the
# binaries where it does not hold." So every line this file emits is a CLAIM
# that two spellings mean the same thing, and tests/translate_test.sh asserts
# each claim's exact text. It lives here, in shell, and NOT inside machotool:
# machotool must not learn the grammar it deliberately refused (controller ruling
# L). Task 2's wrappers source this file, so the translation that was tested is
# literally the translation that ships.
#
# ---- output contract -----------------------------------------------------
#
#   * Zero or more COMMANDS on stdout, as `eval`-safe shell text, ONE PER
#     LINE. A machotool command is always the same shape -- the BARE FORM,
#     which is the only way machotool modifies a binary:
#
#         printf '<statement>\n<statement>\n' | machotool FILE OUT
#
#     -- and the only other command this file emits is `mv -f`. Arguments are
#     single-quoted only when they contain something outside
#     [A-Za-z0-9_@%+=:,./-], so the common case stays readable and the hostile
#     case stays correct; inside the printf FORMAT, `%` and `\` are doubled as
#     well (mt_emit says why). NO VERB IS EMITTED, by any tool here: the verbs
#     are a second way of asking for the same rewrites, with set semantics
#     where a script has sequence semantics, and this file speaks only the one
#     that survives.
#     spec: docs/superpowers/specs/2026-09-14-script-is-the-only-interface-design.md
#   * EVERY COMMAND HERE NAMES AN OUTPUT of its own, because machotool never
#     writes the file it is given. Which output depends on who is reading:
#     with MT_OUT set (a wrapper, naming the temp it will install) the emitted
#     command writes exactly that and nothing follows it; without it -- the
#     teaching form a human sees -- the output is FILE.new and the command is
#     followed by `mv -f FILE.new FILE`, so what is shown is a pasteable
#     equivalent of the old in-place edit rather than half of one.
#     mt_out_for and mt_install_line are that fork, in one place.
#     `patch_macho` is the one tool whose own grammar named an output, so its
#     teaching form is the command the caller typed -- except when IN and OUT
#     are the same file, which machotool refuses and which therefore gets the
#     OUT-plus-install treatment like the other five.
#   * Every tool here but retag_swift_classes emits AT MOST ONE MACHOTOOL
#     COMMAND, however many operations the old invocation asked for: they all
#     become statements in that one command. (The teaching form's trailing
#     `mv -f` is not one of them; a wrapper sets MT_OUT, which suppresses it,
#     and installs the temp itself.) So there is no sequence to run and
#     nothing to stop part way through -- machotool-compat.sh's mw_run
#     evaluates what is printed and returns its exit code.
#     (retag_swift_classes is variadic over FILES and emits one command per
#     file, because one command names one FILE and one OUT; its wrapper runs
#     those itself, because it needs each file's own exit code and stdout.)
#     The ORDER of the statements matters -- see "ordering" below.
#   * Exit 0 with ZERO lines means "this old invocation was a no-op on the
#     file; there is no machotool command to run." (change_dylib accepts
#     `-grow` with no operations; it prints its header-pad line and changes
#     nothing.) It is NOT an error, and it is deliberately not translated as
#     some adjacent command that would do something.
#   * Exit 2 means NO EQUIVALENT: this argv is one the old tool accepted but
#     that no machotool command line means the same thing as. Today there is
#     exactly one -- an unknown TOOL name. (There were two: fix_macho's
#     chained -rename_seg was the other, until the ruling recorded at
#     mt_tr_fix_macho's -rename_seg arm made chaining a behaviour to ADOPT
#     rather than to preserve.) Nothing goes to stdout; emitting a
#     plausible-looking command that would do something else is exactly what
#     the plan forbids.
#   * Exit 1 means REFUSED, with a message on stderr and nothing on stdout, so
#     a wrapper can refuse by just forwarding this exit code and never runs a
#     half-translated command. Almost every case is one the OLD TOOL ITSELF
#     would have refused -- a usage error, an unknown flag, an unknown
#     -strip-lc kind, a capacity cap, an over-long segment name -- and carries
#     the origin tool's exact message. There is ONE refusal of this file's
#     own, which the old tools accepted: a -change chain, refused by
#     mt_chain_check, whose comment has the reasoning. It applies to EVERY
#     invocation now -- it used to skip the single-family case, which emitted
#     that family's verb and got the old tool's batch semantics for free. It
#     exits 1 rather than 2 because 1 is the only failure code change_dylib
#     and fix_macho ever had, and 2 would invent a third outcome for a
#     two-outcome grammar. Both wrappers forward a translation's code raw --
#     fix_macho.sh's fold of every nonzero to 1 applies to mw_run's code, not
#     to this one -- so whatever this returns is what the caller sees.
#
# The one exception to "the old tool's message" is $MT_PROG, which stands in
# for argv[0] in a usage line; mt_translate defaults it to the tool's own name.
#
# CAPACITY CAPS ARE THIS FILE'S JOB, not machotool's. cli/machotool.c caps at exactly
# the same numbers (MR_MAX_OPS=32 shared by -change/-delete/-reexport, and
# separately by -add, -insert, -add-rpath, and -change-rpath/-delete-rpath;
# MR_MAX_STRIP=16 for -strip-lc) but prints DIFFERENT text on purpose, so that
# the new grammar never leaks the old flag spellings -- both cap sites in
# cli/machotool.c carry a comment saying so and telling whoever writes the wrapper
# to enforce the caps here and print the origin text. That is what mt_room does.
#
# fix_macho's two caps come here for a second reason as well: its -rename_seg
# array has NO machotool counterpart at all (a `segment rename` statement is
# one pair, so nothing downstream counts them), and its
# `changes[32]` / `renames[16]` were the same unbounded fixed-size arrays
# docs/PROPOSAL.md records smashing the stack in change_dylib -- "Repeated
# options wrote past their fixed-size arrays; 33 -change flags smashed the
# stack -- fixed, PR #9",
# a fix that only ever covered change_dylib. compat/fix_macho.c grew a bounds
# check of its own before it was retired; mt_room below is where that check
# lives now, in fix_macho's own words, so retiring the C file did not take the
# refusal with it.
#
# ---- the grammar mapping -------------------------------------------------
#
# Each row gives the STATEMENT an old flag becomes. Whatever an invocation
# asks for, the statements go into ONE `printf ... | machotool FILE OUT`.
#
#   change_dylib FILE ...       statement
#     -change O N                 dylib replace O N
#     -delete P                   dylib delete P
#     -reexport P                 dylib reexport P
#     -add P                      dylib append P
#     -insert P                   dylib insert P
#     -change-rpath O N           rpath replace O N
#     -delete-rpath P             rpath delete P
#     -add-rpath P                rpath append P
#     -strip-lc KIND              load-command delete KIND
#     -grow                       allow-grow (a directive, ahead of the rest)
#
#   fix_macho FILE ...
#     -change O N                 dylib replace O N
#     -strip_build_version        load-command delete build-version
#     -rename_seg O N             segment rename O N
#
#   add_version_min FILE          version-min set 10.9
#   patch_macho IN OUT            fixups set classic     (into OUT)
#     (IN and OUT the same)       fixups set classic     (into OUT.new, then mv)
#   rename_segment FILE O N       segment rename O N
#   retag_swift_classes F1 F2 F3  swift-abi set legacy, once per file
#
# ---- ordering, and the one command an old invocation becomes -------------
#
# change_dylib and fix_macho each applied EVERY operation in ONE pass over the
# load-command table, and wrote ONCE. One machotool command is one read, one
# pass per statement over an image held in memory, and one write -- the same
# shape, so a whole invocation is one command. The order emitted is:
#
#   1. load-command delete  -- deleting load commands SHRINKS the table and
#                  hands header pad back. Anything that needs room must run
#                  after it.
#   2. dylib    -- library ordinals are the delicate part (a wrong ordinal is
#                  a dyld failure, not a silent mis-bind), so they are settled
#                  while the image is closest to the one the old tool saw.
#   3. rpath    -- LC_RPATH carries no ordinal, so it is the safest to move
#                  last. Between 2 and 3 the order is a free choice; it is
#                  fixed here so the emitted text is deterministic.
#   4. segment  -- fix_macho only. A rename changes no sizes, so it cannot
#                  compete for header pad with anything above.
#
# WITHIN a family, a batch and a sequence are not automatically the same
# thing, and mt_tr_change_dylib's emission comment says exactly which order
# makes them agree and which single shape it refuses because no order can.
#
# ---- divergences a wrapper must still handle itself ----------------------
#
# These are behavioural, not expressibility: the translation exists, but the
# emitted commands do not by themselves reproduce the old observable. Each is
# documented at its site in cli/machotool.c, and each is a row in
# tests/compat-matrix.tsv.
#
#   rename_segment exits 2 when nothing matched; a `segment rename` statement
#     exits 0 (mr_apply_file's "nothing to change."). The emitted command
#     CANNOT carry that distinction -- reproducing it needs an out-of-band
#     check, which compat/rename_segment.sh makes, not this file.
#   a `segment rename` statement prints header-pad chatter that rename_segment
#     has neither of, handles a fat container that rename_segment refused
#     outright, and -- like every mr_apply_file caller -- refuses a binary
#     carrying LC_LAZY_LOAD_DYLIB that rename_segment, which never built an
#     ordinal map, renamed without complaint. It does NOT additionally run
#     mg_plausible: src/rewrite.c runs that gate only when the run disturbed
#     the base-relative values it checks, and a rename disturbs none, so it is
#     no longer one of this statement's divergences from rename_segment.
#   a `swift-abi set legacy` statement refuses (exit 1) a non-Mach-O argument
#     that retag_swift_classes skipped silently.
#   a `fixups set classic` statement uses exit 2 (EX_FAIL) for an operational failure where
#     patch_macho returns its same flat 1 -- a considered refusal, unlike
#     that case, now exits 1 on both sides, by coincidence, not construction
#     -- writes atomically, gives OUT the INPUT's mode where the C tool used a
#     fixed 0755, refuses an OUT that is IN where the C tool converted in
#     place, and names the file it wrote even on the pass-through.
#   fix_macho is the one tool whose divergences are NOT closed by its wrapper,
#     because the repo owner ruled them improvements to ADOPT: a longer
#     replacement path is now rewritten using header pad instead of refused, a
#     chained -rename_seg now chains, the write-back is atomic, a fat slice
#     machotool cannot handle refuses the whole file instead of being skipped,
#     and a -change aimed at the dylib's own install name now matches nothing
#     instead of rewriting LC_ID_DYLIB. compat/README.md's "fix_macho: the
#     adopted divergences" table states all five with their reasons and the
#     test holding each; this file simply translates, as it does for every
#     other tool.
#
# This file refuses exactly one shape of its own: a -change chain
# (mt_chain_check, whose comment has the reasoning). There used to be a second
# -- `fix_macho -rename_seg A B -rename_seg B C` -- and mt_tr_fix_macho's
# -rename_seg arm records why it existed and what reversed it. The two are not
# the same question: successive rename statements chain, which is the behaviour
# that was adopted, while a -change chain is a shape the OLD tool's single
# batch applied and no sequence reproduces.

# ---- quoting -------------------------------------------------------------
#
# One argument, quoted only if it needs it. The safe set is the usual
# shell-quoting one; note that a path containing a NEWLINE cannot survive the
# command substitution mt_qargs is used through, and nothing in these tools'
# grammar has ever accepted one.
#
# THE SAME QUOTING SERVES THE EDIT SCRIPT, because ms_split (src/script.c)
# reads a statement's words by the same rules a shell does: whitespace
# separates, `'...'` is literal, `"..."` and `\` escape, and an unquoted `#`
# begins a comment. Every one of those characters is outside the safe set
# above, so anything that could be read as syntax is already inside single
# quotes by the time the parser sees it. The one shape the two disagree on is
# a path carrying a control byte other than tab: a shell passes it through and
# ms_parse refuses the line ("control character"). No tool in this grammar has
# ever been handed one.
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

# The output a translated command writes. A wrapper sets MT_OUT to its temp
# file. Without it -- the teaching form, printed on stderr and by
# `sh translate.sh` -- the output is FILE.new, and the caller appends
# mt_install_line, because a converted verb does not write its input and
# replacing FILE is therefore a second step a reader has to be shown.
#
# THE TEACHING FORM IS THE STRAIGHTFORWARD EQUIVALENT, NOT THE WRAPPER'S OWN
# SEQUENCE. Pasted, `mv -f FILE.new FILE` replaces FILE -- so if FILE is a
# symlink it becomes a regular file, which is the answer `mv` gives and the
# one a reader typing this would get. A wrapper does something narrower: it
# resolves FILE through its symlinks first (mw_resolve, machotool-compat.sh) and
# installs onto the target, so the link survives and everything else pointing
# through it sees the new content. Teaching the resolve step would be teaching
# the wrapper's implementation rather than the command a human wants.
#
# A FILE whose own name begins with `-` and has no directory part (`sub/-d`
# is unaffected -- its `.new` name starts with `s`) makes FILE.new begin with
# `-` too, and machotool refuses an OUT spelled that way, naming `./OUT` as the
# remedy (cli/machotool.c). So mt_new_name gives the teaching form that name
# directly, keeping the printed machotool line and the `mv -f` line that follows
# it both runnable pasted verbatim; a wrapper never sees this, because
# MT_OUT is always its own dot-prefixed temp (mw_prepare, machotool-compat.sh).
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
#   mt_emit FILE OUT        statements on this function's stdin
#
# Prints ONE command: `printf FORMAT | machotool FILE OUT`, the bare form, with
# the statements on stdin. That is the only way machotool modifies a binary, so
# it is the only thing this file emits -- one shape for all six tools, however
# many statements the old invocation is worth.
#
# THE STATEMENTS ARE THE printf FORMAT, not its operands, so that the common
# case reads as the one-line pipeline a human would type. A format string is
# rewritten by printf itself, which the statements must survive: `%` starts a
# conversion and `\` starts an escape, so both are DOUBLED here. Neither is
# quoted by mt_quote (`%` is inside its safe set; `\` puts the word in single
# quotes but stays one backslash there), so neither would survive on its own --
# `printf 'dylib replace a%sb c'` prints an empty conversion and
# `printf 'dylib append a\tb'` prints a tab where a caller named a backslash.
# Doubling is what the emitted line needs; the single quotes mt_quote puts
# around the whole format are what the SHELL needs. Measured both ways in
# tests/translate_test.sh's quoting section.
mt_emit() {
    mt_em_fmt=''
    while IFS= read -r mt_em_l; do
        [ -n "$mt_em_l" ] || continue
        mt_em_fmt="$mt_em_fmt$(printf '%s' "$mt_em_l" | sed -e 's/\\/\\\\/g' -e 's/%/%%/g')\\n"
    done
    printf 'printf %s | %s%s\n' "$(mt_quote "$mt_em_fmt")" "$(mt_pre_word)" \
        "$(mt_qargs "$1" "$2")"
}

# ---- one family's change group, as the one-pass rewriter applied it -------
#
# A "change group" is the operations that act on load commands the walk
# ALREADY FINDS: for dylib that is -change/-delete/-reexport, for rpath
# -change-rpath/-delete-rpath. (-add/-insert/-add-rpath are not in it: those
# arrays are applied after the walk, which is why their statements are emitted
# after this group's.) The old tools handed the whole group to one pass, and
# src/rewrite.c decided per load command which ONE entry of it applied. This
# reproduces that decision by choosing which statements to emit.
#
#   mt_group_stmts <delete-wins 1|0> <records>
#
# <records> is three lines per operation, in flag order: `del` or `act`, then
# the RAW old path, then the statement text. Three lines rather than one
# delimited line because a path may contain a tab and may not contain a
# newline (see the quoting section), so newline is the only separator that is
# safe here -- the same reason and the same shape as mt_chain_check's pairs.
#
# TWO RULES, AND THEY ARE NOT THE SAME FOR THE TWO FAMILIES:
#
#   1. FIRST ENTRY NAMING A PATH WINS; the rest are shadowed. mr_build_lcs_lc
#      sets `matched` to the first entry naming the path and never revisits it
#      (src/rewrite.c, the "No break" loop -- it keeps scanning to COUNT hits,
#      but `if (matched < 0) matched = c`). So a shadowed entry did nothing at
#      all, and emitting it as a statement would make it do something: measured
#      against the pre-migration binaries, `-reexport P -change P Q` left
#      LC_REEXPORT_DYLIB still naming P, while reexport-then-replace as two
#      statements lands on Q. Dropping the shadowed entry is what reproduces
#      the batch; no emission ORDER does.
#
#   2. A -delete BEATS a conflicting entry whatever the order -- FOR DYLIB
#      ONLY. mr_is_deleted (src/rewrite.c:56) scans `n_dylib_changes` and
#      nothing else, so LC_RPATH never had that precedence: its match loop
#      `break`s on the first entry, full stop. Measured: `change_dylib
#      -change-rpath X Y -delete-rpath X` RENAMES on the C tools and on this
#      translation, and hoisting rpath deletes the way dylib's are would delete
#      it instead -- a precedence rpath never had. The <delete-wins> argument
#      is that asymmetry, and it is 1 for dylib and 0 for rpath because the C
#      code is written that way, not because the two families differ in
#      principle.
mt_group_stmts() {
    mt_gs_win=$1
    mt_gs_recs=$2
    mt_gs_claimed=''
    if [ "$mt_gs_win" = 1 ]; then
        while IFS= read -r mt_gs_k && IFS= read -r mt_gs_p && IFS= read -r mt_gs_s; do
            [ "$mt_gs_k" = del ] || continue
            mt_claimed "$mt_gs_p" "$mt_gs_claimed" && continue
            mt_gs_claimed="$mt_gs_claimed:$mt_gs_p
"
            printf '%s\n' "$mt_gs_s"
        done <<MT_GS_DELETES
$mt_gs_recs
MT_GS_DELETES
    fi
    while IFS= read -r mt_gs_k && IFS= read -r mt_gs_p && IFS= read -r mt_gs_s; do
        mt_claimed "$mt_gs_p" "$mt_gs_claimed" && continue
        mt_gs_claimed="$mt_gs_claimed:$mt_gs_p
"
        printf '%s\n' "$mt_gs_s"
    done <<MT_GS_REST
$mt_gs_recs
MT_GS_REST
}

# Has this path already had its one statement emitted? The stored entries carry
# a leading `:` so that the EMPTY path -- which `change_dylib f -change '' X`
# really can name -- is distinguishable from the blank line every accumulated
# list ends with.
mt_claimed() {
    while IFS= read -r mt_cl_e; do
        [ "$mt_cl_e" = ":$1" ] && return 0
    done <<MT_CLAIMED
$2
MT_CLAIMED
    return 1
}

# The origin tool's own diagnostic, on stderr, and a nonzero return.
mt_die() {
    printf '%s\n' "$1" >&2
    return 1
}

# change_dylib's CD_ROOM: refuse BEFORE the write that would overflow, naming
# the flag that overflowed, in change_dylib's exact words.
#   mt_room <current count> <max> <flag spelling>
mt_room() {
    [ "$1" -eq "$2" ] || return 0
    printf 'too many %s (max %d)\n' "$3" "$2" >&2
    return 1
}

# THE ONE SHAPE A SEQUENCE CANNOT REPRODUCE.
#
#   mt_chain_check <flag spelling> <pairs>
#
# <pairs> is every replacement this family collected, OLD and NEW on
# alternating lines, in flag order. Refuses when one pair's NEW is another
# pair's OLD -- a chain (`-change a b -change b c`) or a swap (`-change a b
# -change b a`).
#
# WHY. The old tools apply a whole family's operations as ONE batch against
# the original image: every command is compared against the paths the image
# had, so `-change a b -change b c` rewrites the a's to b and the ORIGINAL b's
# to c, and the b's the first pair just produced are not revisited. An edit
# script applies its statements in sequence, each seeing what the one before
# left, so `dylib replace a b` followed by `dylib replace b c` rewrites the
# new b's as well and lands on c. No emission order fixes it: reversing the
# two just moves which pair is over-applied.
#
# So this is the one place the translation has no equivalent to emit, and it
# says so rather than emitting something adjacent. It is checked ONLY on the
# edit-script path: a single-family invocation still uses the verb, whose
# batch is the old tool's own semantics.
mt_chain_check() {
    mt_cc_i=0
    while IFS= read -r mt_cc_o1 && IFS= read -r mt_cc_n1; do
        mt_cc_i=$((mt_cc_i + 1))
        mt_cc_j=0
        while IFS= read -r mt_cc_o2 && IFS= read -r mt_cc_n2; do
            mt_cc_j=$((mt_cc_j + 1))
            [ "$mt_cc_i" -ne "$mt_cc_j" ] || continue
            [ "$mt_cc_n1" = "$mt_cc_o2" ] || continue
            mt_die "$1 $mt_cc_o1 $mt_cc_n1 and $1 $mt_cc_n1 $mt_cc_n2 chain: run them as separate invocations"
            return 1
        done <<MT_CHAIN_INNER
$2
MT_CHAIN_INNER
    done <<MT_CHAIN_OUTER
$2
MT_CHAIN_OUTER
    return 0
}

# Caps, from src/rewrite.h. -change/-delete/-reexport SHARE one array of 32,
# as do -change-rpath/-delete-rpath; -add, -insert and -add-rpath each get
# their own 32; -strip-lc gets 16.
MT_MAX_OPS=32
MT_MAX_STRIP=16
# fix_macho's own second array, from compat/fix_macho.c's FM_MAX_RENAMES. No
# shared header has an opinion about segment renames -- machotool never sees more
# than one at a time -- so this 16 is fix_macho's alone and lives here.
MT_MAX_RENAMES=16

# change_dylib's -strip-lc vocabulary, from src/lc_kinds.c. This is the OLD
# tool's table, frozen: it is what change_dylib accepted, and reproducing its
# refusal is the point. What THIS build of machotool accepts is a separate
# question, answered by `machotool --capabilities` (kinds=...) -- and
# tests/translate_test.sh asserts the two agree rather than assuming it.
MT_STRIP_KINDS='uuid codesig source-version build-version code-sign-drs'

# What a reproduced usage line prints where the C tool printed argv[0].
# mt_translate resets this to the tool's own name on every call; the default
# here only matters if a caller reaches one of the mt_tr_* functions directly,
# and exists so `set -u` cannot turn that into a shell error instead of a
# usage line.
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
    # `argc < 4` in change_dylib.c -- program name plus fewer than three
    # arguments. So `change_dylib FILE -grow` is a USAGE ERROR even though the
    # usage text presents -grow as an optional standalone flag.
    [ $# -ge 3 ] || { mt_cd_usage; return 1; }

    mt_file=$1; shift
    # The operations as statements, bucketed by kind so the emission can order
    # them (see the emission comment below).
    mt_st_lc='' mt_st_dydel='' mt_st_dyrepl='' mt_st_dyapp='' mt_st_dyins=''
    mt_st_rpapp=''
    # The two CHANGE GROUPS -- the operations the load-command walk itself
    # applied -- as mt_group_stmts' three-lines-per-record lists, in flag
    # order. Everything else is a plain statement bucket, because nothing in
    # it can shadow anything else.
    mt_dy_recs='' mt_rp_recs=''
    # Every replacement's OLD and NEW, on alternating lines, for mt_chain_check.
    mt_pairs_dy='' mt_pairs_rp=''
    mt_nchanges=0 mt_nadds=0 mt_ninserts=0
    mt_nrchanges=0 mt_nradds=0 mt_nstrip=0
    mt_grow=''

    while [ $# -gt 0 ]; do
        case $1 in
        -grow)
            mt_grow=1; shift ;;
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
            # PREPENDED, not appended: see the emission comment below. Every
            # insert goes to the front of the table, so a sequence has to run
            # them backwards to leave them in the order the batch would.
            mt_st_dyins="$(printf 'dylib insert%s' "$(mt_qargs "$2")")
$mt_st_dyins"
            shift 2 ;;
        -change)
            [ $# -ge 3 ] || { mt_die "bad arg: $1"; return 1; }
            mt_room "$mt_nchanges" "$MT_MAX_OPS" -change || return 1
            mt_nchanges=$((mt_nchanges + 1))
            mt_dy_recs="${mt_dy_recs}act
$2
$(printf 'dylib replace%s' "$(mt_qargs "$2" "$3")")
"
            mt_pairs_dy="$mt_pairs_dy$2
$3
"
            shift 3 ;;
        -delete)
            [ $# -ge 2 ] || { mt_die "bad arg: $1"; return 1; }
            mt_room "$mt_nchanges" "$MT_MAX_OPS" -delete || return 1
            mt_nchanges=$((mt_nchanges + 1))
            mt_dy_recs="${mt_dy_recs}del
$2
$(printf 'dylib delete%s' "$(mt_qargs "$2")")
"
            shift 2 ;;
        -reexport)
            [ $# -ge 2 ] || { mt_die "bad arg: $1"; return 1; }
            mt_room "$mt_nchanges" "$MT_MAX_OPS" -reexport || return 1
            mt_nchanges=$((mt_nchanges + 1))
            # `act`, not `del`: a reexport REWRITES the command in place
            # (new_path "" keeps the path, cmd becomes LC_REEXPORT_DYLIB), so
            # mr_is_deleted never sees it and it wins or loses against a
            # -change on the same path purely by which came first.
            mt_dy_recs="${mt_dy_recs}act
$2
$(printf 'dylib reexport%s' "$(mt_qargs "$2")")
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
            mt_rp_recs="${mt_rp_recs}act
$2
$(printf 'rpath replace%s' "$(mt_qargs "$2" "$3")")
"
            mt_pairs_rp="$mt_pairs_rp$2
$3
"
            shift 3 ;;
        -delete-rpath)
            [ $# -ge 2 ] || { mt_die "bad arg: $1"; return 1; }
            mt_room "$mt_nrchanges" "$MT_MAX_OPS" -delete-rpath || return 1
            mt_nrchanges=$((mt_nrchanges + 1))
            # `del`, but mt_group_stmts is called with delete-wins OFF for
            # this family: the tag is what the operation IS, not what
            # precedence it gets.
            mt_rp_recs="${mt_rp_recs}del
$2
$(printf 'rpath delete%s' "$(mt_qargs "$2")")
"
            shift 2 ;;
        *)
            mt_die "bad arg: $1"; return 1 ;;
        esac
    done

    # ONE COMMAND: the bare form, with every operation as a statement.
    #
    # WHY THIS ORDER. change_dylib applied a whole family's operations as a
    # BATCH against the original image; a script applies statements in
    # SEQUENCE, each seeing what the one before left. They agree when the
    # statements are emitted like this:
    #
    #   1. every `load-command delete` first, because deleting commands hands
    #      header pad back and everything else may need the room;
    #   2. each family's CHANGE GROUP, chosen by mt_group_stmts -- whose
    #      header has the two rules (first entry naming a path wins, and a
    #      -delete beats a conflict for dylib but NOT for rpath) and the
    #      measurements behind them;
    #   3. that family's appends, which the batch applied after the walk;
    #   4. then its inserts IN REVERSE FLAG ORDER. That reversal is the one
    #      that is not obvious: each insert goes to the FRONT of the table, so
    #      as a batch `-insert A -insert B` leaves A at ordinal 1 and B at 2,
    #      and a sequence reproduces that only by inserting B and then A.
    #
    # dylib before rpath: library ordinals are the delicate part, so they are
    # settled while the image is closest to the one the old tool saw.
    #
    # And one shape no order or choice reproduces -- a -change whose NEW is
    # another -change's OLD -- which mt_chain_check refuses. IT RUNS ON EVERY
    # INVOCATION, not only a multi-family one: the single-family form used to
    # emit that family's VERB, whose batch was the C tool's own semantics and
    # so had nothing to reproduce. There is no verb to emit any more, so there
    # is no invocation left where the shape is safe.
    mt_chain_check -change "$mt_pairs_dy" || return 1
    mt_chain_check -change-rpath "$mt_pairs_rp" || return 1

    mt_body=$({
        printf '%s' "$mt_st_lc"
        mt_group_stmts 1 "$mt_dy_recs"
        printf '%s%s' "$mt_st_dyapp" "$mt_st_dyins"
        mt_group_stmts 0 "$mt_rp_recs"
        printf '%s' "$mt_st_rpapp"
    })
    # `change_dylib FILE -grow -grow` asks for nothing, so nothing is emitted
    # -- not even `allow-grow`, which permits a growth no statement would
    # request. (A single `-grow` never gets this far: the `[ $# -ge 3 ]` usage
    # check above refuses it.) An install line with no command ahead of it
    # would name an output nothing wrote, so it goes too.
    [ -n "$mt_body" ] || return 0
    # -grow becomes the `allow-grow` DIRECTIVE, which must precede every
    # statement. Like the --allow-grow it replaces it reaches dylib and rpath
    # and not the load-command deletes: src/edit.c sets ops.allow_grow only for
    # the statements that can outgrow the pad, and deleting load commands can
    # only shrink the table.
    [ -n "$mt_grow" ] && mt_body="allow-grow
$mt_body"
    mt_emit "$mt_file" "$(mt_out_for "$mt_file")" <<MT_CD_BODY
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
    # The operations as statements, and every -change's OLD and NEW on
    # alternating lines for mt_chain_check -- see mt_tr_change_dylib, which
    # collects both for the same reason.
    mt_st_lc='' mt_st_seg='' mt_pairs_dy=''
    # The dylib change group, as mt_group_stmts' records. fix_macho's only
    # member of it is -change, so nothing here can be shadowed by a -delete --
    # but it goes through the same chooser as change_dylib's, so a duplicate
    # `-change P Q -change P Z` resolves to the first pair on both sides, which
    # is what the one pass did.
    mt_dy_recs=''
    mt_nchanges=0 mt_nrenames=0

    while [ $# -gt 0 ]; do
        case $1 in
        -change)
            # fix_macho's own condition is `i + 2 < argc`, so a trailing
            # `-change OLD` with no NEW falls through to "Unknown option:
            # -change" -- naming the flag, not the missing operand.
            [ $# -ge 3 ] || { mt_die "Unknown option: $1"; return 1; }
            # fix_macho's FM_MAX_CHANGES was change_dylib's own MR_MAX_OPS, and
            # its FM_ROOM printed change_dylib's exact "too many %s (max %d)" --
            # so mt_room's text is already fix_macho's text, with fix_macho's
            # flag spelling in it.
            mt_room "$mt_nchanges" "$MT_MAX_OPS" -change || return 1
            mt_nchanges=$((mt_nchanges + 1))
            mt_dy_recs="${mt_dy_recs}act
$2
$(printf 'dylib replace%s' "$(mt_qargs "$2" "$3")")
"
            mt_pairs_dy="$mt_pairs_dy$2
$3
"
            shift 3 ;;
        -strip_build_version)
            # Only ever one LC kind, and fix_macho's flag is a boolean, so a
            # repeat adds nothing. Emitting `-delete build-version` twice
            # would be a different command for the same intent -- so both
            # forms below ASSIGN rather than append.
            mt_st_lc='load-command delete build-version
'
            shift ;;
        -rename_seg)
            [ $# -ge 3 ] || { mt_die "Unknown option: $1"; return 1; }
            # Same 16-byte segname limit fix_macho checks here, before any
            # I/O, in its own words (which differ from rename_segment's).
            # `${#3}` counts CHARACTERS, not bytes -- fix_macho's strlen()
            # counted bytes. A 16-character multibyte NEW segname whose
            # encoding runs longer than 16 bytes passes this check where
            # fix_macho refused it. Both paths still end at fix_macho.sh
            # exiting 1: machotool's mseg_name_fits (src/segname.c), called from
            # cmd_segment (cli/machotool.c), catches the over-length name
            # downstream and returns EX_REFUSED, which fix_macho.sh maps to 1
            # like every other nonzero machotool exit -- with different text
            # than either shell message above. No code change follows from
            # this -- the observable exit code is the same either way, only
            # the wording differs earlier.
            [ "${#3}" -le 16 ] || { mt_die "new segment name longer than 16 bytes: $3"; return 1; }
            # fix_macho's renames[] held 16, and its FM_ROOM refused the 17th
            # in these same words. Nothing downstream counts these -- each
            # pair becomes its own `segment rename` statement, so machotool
            # sees one rename at a time and has no cap of its own to hit.
            # Enforcing it here is the only thing keeping that refusal alive.
            mt_room "$mt_nrenames" "$MT_MAX_RENAMES" -rename_seg || return 1
            mt_nrenames=$((mt_nrenames + 1))
            # A CHAINED RENAME (`-rename_seg A B -rename_seg B C`) USED TO
            # REFUSE HERE, with exit 2, via a helper called mt_fm_chain. That
            # refusal was DELIBERATE, not an oversight, and it was right at the
            # time: while compat/fix_macho.c still shipped, a wrapper had to
            # PRESERVE its behaviour, and the two answers differ -- fix_macho
            # applies every pair in ONE pass and gives each segment its FIRST
            # match, so the second pair never fires and it produces B, while
            # separate `macho9 segment` passes chain and produce C. Measured on
            # tests/fixture.macho with the real binaries: different bytes, both
            # exiting 0. Emitting the sequence anyway would have been exactly
            # the "plausible-looking command that would do something else" the
            # retirement plan forbids, so it refused instead.
            #
            # WHAT REVERSED IT: the repo owner's ruling, recorded in
            # docs/superpowers/plans/2026-09-10-report-what-macho9-did.md ("The
            # decision this plan rests on"), that fix_macho's divergences from
            # the shared drivers are improvements to ADOPT deliberately rather
            # than behaviour to preserve -- chaining is listed there as "doing
            # what was asked". compat/fix_macho.c is gone; there is no longer a
            # behaviour on the other side to preserve, so refusing a shape the
            # surviving implementation handles correctly would be the wrong
            # answer. compat/README.md's divergence table states the change as
            # row 2 of the five adopted ones.
            mt_st_seg="$mt_st_seg$(printf 'segment rename%s' "$(mt_qargs "$2" "$3")")
"
            shift 3 ;;
        *)
            mt_die "Unknown option: $1"; return 1 ;;
        esac
    done

    # No allow-grow: fix_macho had no -grow and never enlarged a header, so
    # nothing in its grammar can ask for one. A `dylib replace` statement
    # without it still resizes a command into EXISTING header pad, which
    # fix_macho refused ("new path ... too long") -- the first of the five
    # adopted changes compat/README.md's table lists. Growing the header
    # outright is a further step, and this translation still does not take it.
    #
    # lc, then dylib, then segment -- mt_tr_change_dylib's emission comment has
    # the reasoning for the first two, and a rename goes last because it
    # changes no sizes and so competes for header pad with nothing. Renames
    # stay in FLAG ORDER: unlike an insert, one rename statement is one
    # operation, so a sequence of them is already what the -rename_seg arm
    # above says this tool now does.
    mt_chain_check -change "$mt_pairs_dy" || return 1
    # Unconditional, unlike change_dylib's: every fix_macho argv that reaches
    # here carries at least one operation (the usage check above rejects a
    # bare FILE), so the body is never empty.
    mt_emit "$mt_file" "$(mt_out_for "$mt_file")" <<MT_FM_BODY
$(printf '%s' "$mt_st_lc"; mt_group_stmts 1 "$mt_dy_recs"; printf '%s' "$mt_st_seg")
MT_FM_BODY
    mt_install_line "$mt_file"
    return 0
}

# ---- the four fixed-arity tools -----------------------------------------
mt_tr_add_version_min() {
    # `argc != 2`. The 10.9 floor is hardcoded in add_version_min itself
    # (mv_add_version_min), which is why the version appears here and not in
    # the old argv.
    [ $# -eq 1 ] || { printf 'Usage: %s binary\n' "$MT_PROG" >&2; return 1; }
    mt_emit "$1" "$(mt_out_for "$1")" <<'MT_AVM_BODY'
version-min set 10.9
MT_AVM_BODY
    mt_install_line "$1"
}

mt_tr_patch_macho() {
    # `argc != 3`.
    [ $# -eq 2 ] || { printf 'Usage: %s input output\n' "$MT_PROG" >&2; return 1; }
    # THE ONE TOOL WHOSE GRAMMAR ALREADY NAMED ITS OUTPUT, so the teaching form
    # is the command the caller typed: there is no in-place edit to show an
    # install step for. The exception is IN and OUT being the same file, which
    # patch_macho allowed and machotool now refuses, as it does for every
    # rewrite -- so that form gets the same OUT-plus-install treatment
    # the five in-place tools get, and reads as a pasteable equivalent instead
    # of a command that would be refused. Compared AS STRINGS, because that is
    # all this file can do: it opens nothing, so "the same file by another name"
    # (a symlink, a hard link, `./f` for `f`) is not a question it can ask --
    # machotool answers that one at the write, and the wrapper never asks it at
    # all, since it always names a temp of its own.
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
    # `argc < 2`. This is the one tool whose grammar is variadic over FILES
    # rather than over flags, and one command names one FILE and one OUT -- so
    # the translation is a loop, one command per file, in argv order. MT_OUT
    # is a single output for the whole call, so it only makes sense set when a
    # wrapper is retranslating ONE file at a time (compat/retag_swift_classes.sh
    # does); the teaching form (no MT_OUT) is over every file at once and gives
    # each its own FILE.new and install line, same as mt_out_for/mt_install_line
    # do for every other tool here.
    [ $# -ge 1 ] || { printf 'Usage: %s binary [binary ...]\n' "$MT_PROG" >&2; return 1; }
    for mt_f in "$@"; do
        mt_emit "$mt_f" "$(mt_out_for "$mt_f")" <<'MT_RSC_BODY'
swift-abi set legacy
MT_RSC_BODY
        mt_install_line "$mt_f"
    done
}

# The machotool program word, quoted, with mt_qargs' leading space trimmed.
mt_pre_word() {
    mt_p="$(mt_qargs "${MACHOTOOL:-machotool}")"
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
    # MT_PROG is recomputed on EVERY call, so a long-lived shell that sources
    # this file once and translates many invocations cannot leak one tool's
    # name into another's usage line. A wrapper that wants its own $0 there
    # presets MT_PROG0 instead.
    MT_PROG=${MT_PROG0:-$mt_tool}
    case $mt_tool in
        change_dylib)         mt_tr_change_dylib "$@" ;;
        add_version_min)      mt_tr_add_version_min "$@" ;;
        patch_macho)          mt_tr_patch_macho "$@" ;;
        rename_segment)       mt_tr_rename_segment "$@" ;;
        retag_swift_classes)  mt_tr_retag_swift_classes "$@" ;;
        fix_macho)            mt_tr_fix_macho "$@" ;;
        *)
            # Not one of the six. There is deliberately no fallback and no
            # guess: emitting a plausible-looking machotool line for a tool this
            # file has never heard of is the one failure mode the plan names
            # outright.
            printf 'translate.sh: no equivalent -- unknown tool %s (expected one of: change_dylib add_version_min patch_macho rename_segment retag_swift_classes fix_macho)\n' "$mt_tool" >&2
            return 2 ;;
    esac
}

# Run directly, unless sourced with MT_SOURCED set (which is how Task 2's
# wrappers pull the functions in without triggering a translation).
if [ -z "${MT_SOURCED:-}" ]; then
    mt_translate "$@"
    exit $?
fi
