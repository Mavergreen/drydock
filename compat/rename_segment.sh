#!/bin/sh
# rename_segment -- a /bin/sh wrapper around `drydock-macho-rewrite FILE OUT` with one
# `segment rename OLD NEW` statement on its stdin.
#
#   rename_segment binary OLDNAME NEWNAME
#
# WHAT THIS REPLACED. compat/rename_segment.c was this tool's argument
# grammar, a thin-only mi_open + lseek/write driver, its exit 2 when nothing
# matched, and its one message, over its own mi_each_lc loop calling
# mseg_rename_lc (src/segname.h) on every matching command -- the same
# per-command function a `segment rename` statement calls, once per command,
# from inside mr_apply_file's own load-command walk. (rename_segment.c's own image-wide
# loop, mseg_rename_image, was deleted along with rename_segment.c itself:
# nothing else ever called it.) The rename itself is therefore the same code
# either way.
#
# Why the tool exists at all (10.9's libobjc looks for __objc_* sections in
# __DATA, and Xcode 10+ linkers put them in __DATA_CONST) is written down in
# src/segname.h's header, which outlives the C front-end this replaces.
#
# GRAMMAR. `rename_segment FILE OLD NEW` -> `printf 'segment rename OLD NEW\n'
# | drydock-macho-rewrite FILE OUT`.
# `argc != 4` and a NEW longer than the 16 bytes a segname field holds are
# both refused before any I/O, by compat/translate.sh, in rename_segment's own
# words.
#
# FIVE DELIBERATE DIVERGENCES a wrapper has to account for -- the list
# cli/drydock-macho-rewrite.c's cmd_segment carried until that verb was deleted -- plus a
# note on a sixth that used to be on it and no longer is (mg_plausible, below).
# They are the `segment rename` statement's divergences: the statement reaches
# the rename through the same code. The first of the five -- that the rewrite
# reads FILE and writes OUT rather than rewriting FILE -- is closed by "the
# in-place edit" at the end of this header; the rest are numbered below.
#
#   1. EXIT 2 WHEN NOTHING MATCHED, and 2. THE ONE-LINE MESSAGE. Both need the
#      same number: how many LC_SEGMENT_64s the rename actually matched.
#      rename_segment got it from mseg_rename_image's return value; this
#      wrapper COUNTS the rewriter's own per-rename line,
#
#          "  Rename segment: <OLD> -> <NEW>"
#
#      one per segment renamed, printed from inside the load-command walk
#      (src/rewrite.c). It used to read a summary the `segment` VERB printed
#      (`machotool segment: renamed=<N>`); a script prints no summary, and the
#      per-rename line is what both forms have always had in common.
#
#      A run that matches nothing prints none of them and refuses instead --
#      an unmatched `segment rename` is EX_REFUSED by default. So does a run
#      that refuses for a reason that has nothing to do with matching (the
#      fourth divergence below, LC_LAZY_LOAD_DYLIB, is the one this file has
#      measured): both look identical from drydock-macho-rewrite's exit code
#      alone, so EX_REFUSED by itself is not the zero-case verdict. Telling
#      the two apart is a CLASSIFICATION step (see EXIT CODES, below): it
#      asks `drydock-macho-rewrite info --thin FILE` whether a segment named
#      OLD exists at all, using the tool's own match rule -- src/segname.c's
#      mseg_rename_lc: `strncmp(segname, oldname, MSEG_NAME_MAX)`,
#      MSEG_NAME_MAX 16 (src/segname.h) -- rather than assuming EX_REFUSED
#      always means "nothing matched". Absent -> the old grammar's exit 2,
#      silently. Present -> the refusal is about something else, and is
#      shown.
#
#      No digest protects the per-rename line: tests/EXPECTED and
#      tests/known-callers.sh's sha256s hash converted file bytes with the
#      tools' output sent to /dev/null. What pins it is two readers, in two
#      files: the grep below (production code, this file, the only thing
#      this wrapper still reads that string for) and tests/wrapper_test.sh's
#      "capabilities" assertion, which proves the build really emits it -- a
#      build that stopped would make this wrapper report 0 renames and exit
#      2 on a file it had just rewritten.
#
#      drydock-macho-rewrite's own stdout is otherwise SUPPRESSED and this wrapper prints
#      rename_segment's single line with that count, byte-identical to the C
#      tool's.
#
#      IT IS NOT DERIVED FROM `drydock-macho-rewrite info`. An earlier version of this wrapper
#      counted "  segname=NAME ..." lines out of that dump with awk, and it was
#      wrong twice over, both cases reachable and both measured: mseg_rename_lc
#      matches with strncmp over the 16-byte segname field, so an OLD LONGER
#      than 16 bytes whose first 16 match is a match the field-splitting count
#      missed, and a segname CONTAINING WHITESPACE (legal, and producible with
#      a `segment rename __TEXT 'A B'` statement, ms_split quoting the name)
#      split across awk fields and missed too.
#      Both made this wrapper exit 2, leaving the file untouched, where the C
#      tool renamed and exited 0. tests/wrapper_test.sh pins both.
#
#      That was tests/README.md's second lesson -- never parse human-readable
#      output as an oracle -- applied to `drydock-macho-rewrite info` instead of to `otool`.
#      The count now comes from the code that did the matching. THE
#      CLASSIFICATION ABOVE reads the same dump, but not with awk and not by
#      counting: a single fixed-string grep for the WHOLE line
#      `  segname=<OLD, cut to 16 bytes> vmaddr=` (cli/drydock-macho-rewrite.c's
#      info_cb prints `  segname=%.16s vmaddr=...`), with OLD cut to 16
#      bytes first, the same way the C truncates segname before either side
#      of the comparison exists. Neither of the two awk bugs above can recur
#      here: there is no field to split, and OLD is truncated before the
#      grep runs, not left for a delimiter to cut wrong.
#   3. THIN ONLY. rename_segment ran mi_open, which fails on a fat container,
#      and printed "%s: not a readable 64-bit Mach-O" (exit 1). `drydock-macho-rewrite
#      segment` goes through mr_apply_file, which HANDLES fat containers --
#      so it would rename inside a fat file that rename_segment refused
#      outright. `drydock-macho-rewrite info --thin` refuses a fat container
#      in exactly rename_segment's sense -- that is the reason the flag
#      exists, not an incidental side effect of a bare mi_open -- so gating
#      on its EXIT STATUS reproduces the old refusal. Its output is not
#      read: the exit status is the whole signal, which is the difference
#      between using a machine-readable result and parsing a human-readable
#      one. This matters in practice: most binaries under
#      /System/Library/Frameworks are fat, so without the gate
#      tests/differential.sh would show this wrapper rewriting files the C
#      tool would not have.
#
#   4. LC_LAZY_LOAD_DYLIB, NOT CLOSED, and the one real gap this wrapper
#      ships with. mr_apply_file builds the library-ordinal map
#      (mo_map_build, src/ordinals.c) up front, before it looks at what the
#      operations actually are, and that builder REFUSES any image carrying
#      an LC_LAZY_LOAD_DYLIB -- "it carries an ordinal like LC_LOAD_DYLIB
#      does, but this codebase has never exercised renumbering it". A
#      segment rename touches no ordinal at all, so the refusal cannot be
#      protecting anything here; it is simply on the path. rename_segment,
#      which never went near mr_apply_file at all, renamed such a binary
#      happily.
#
#      MEASURED, on /usr/lib/libxcselect.dylib -- the one file in
#      tests/differential.sh's corpus that carries one:
#
#        compat/rename_segment.c (pre-wrapper)  renamed it, exit 0
#        a `segment rename` statement           refuses, exit 1
#        a `load-command delete` statement      refuses too, with the SAME message
#        change_dylib (pre-wrapper)             refuses too, with the SAME message
#
#      The last two lines are the point: this is NOT rename-specific and NOT
#      something these wrappers introduced. mo_map_build has refused this
#      file for every operation, through every front-end, for as long as the
#      shared rewriter has existed. What changed is only that the rename now
#      travels through that rewriter.
#
#      RENAME_SEGMENT ITSELF, asked to rename a segment on such a binary,
#      classifies the refusal the way EXIT CODES (below) describes: it asks
#      `drydock-macho-rewrite info --thin` whether OLD names a real segment.
#      On /usr/lib/libxcselect.dylib, `rename_segment x __TEXT __TEXX` (a
#      segment that really exists) is classified "present" and exits 1 with
#      drydock-macho-rewrite's own LC_LAZY_LOAD_DYLIB refusal shown -- the
#      pre-wrapper shape, restored. A name libxcselect.dylib does NOT carry,
#      on the same binary, is classified "absent" and exits 2 SILENTLY,
#      exactly like an ordinary miss -- even though the true reason
#      mo_map_build refused is this divergence, not the name. The
#      classification only ever asks "does OLD exist", never "why did
#      drydock-macho-rewrite refuse", so this one case is indistinguishable
#      from a real miss in the wrapper's own output. Accepted rather than
#      closed, for the same reason the gap above is: fixing it needs
#      drydock-macho-rewrite to stop building the ordinal map for an
#      operation that cannot renumber, which is that same unfixed gap.
#
#      It is the same SHAPE as the mg_plausible gate described below -- an
#      offset-related gate running on an operation set that cannot move
#      offsets -- but a different call site, so it does not fall out of
#      that fix. The smallest fix would be to skip building the ordinal map
#      when nothing in the operation set can renumber, which is a change to
#      drydock-macho-rewrite, not to this wrapper. Reported rather than made.
#
# mg_plausible USED TO BE a fifth divergence and no longer is: mr_apply_file
# used to run it before writing, on every operation, and refuse if it failed;
# rename_segment had no such gate. NOT reproduced HERE, because it is no
# longer a divergence: src/rewrite.c now runs that gate only when the run
# disturbed the base-relative values it checks (src/relations.h), and says at
# the site why that is a statement about what mg_plausible checks (an OFFSET
# question) rather than a concession. A rename writes characters into
# segname/sectname and moves nothing, so the gate could only ever re-decide a
# property the input already had.
#
# This wrapper therefore sets NO environment variable and switches nothing
# off. What reaches the gate is decided by the image and the operation, never
# by anything a caller can pass.
#
# EXIT CODES. 0 renamed, 2 nothing matched, 1 everything else -- the three
# rename_segment had. EX_FAIL (2, an operational failure) always was
# "everything else": it becomes this wrapper's 1, shown on stderr, whatever
# this build's `segment rename` was never specified to produce lands here
# too.
#
# EX_REFUSED (1) IS NOT, BY ITSELF, "nothing matched" -- a `segment rename`
# statement also refuses this way for a reason that has nothing to do with
# matching (the fourth divergence above, LC_LAZY_LOAD_DYLIB), and the two
# are the same number from drydock-macho-rewrite's own exit alone. So an
# EX_REFUSED is CLASSIFIED: `drydock-macho-rewrite info --thin FILE` is
# asked whether a segment named OLD exists, with the same match rule
# mseg_rename_lc uses (`strncmp(segname, oldname, 16)`, src/segname.c) --
# OLD cut to 16 bytes, matched against info's own `  segname=%.16s vmaddr=`
# line, whole-line and fixed-string. Absent -> this wrapper's old exit 2,
# silently, matching the old grammar's own silence with the file untouched.
# Present -> the refusal really is about something else, and is shown, same
# as the pre-wrapper C tool would have shown whatever refused IT. If the
# classification query itself fails (`info --thin` exits nonzero), that is
# an operational failure of its own, distinct from either answer: shown, and
# this wrapper exits 1.
#
# The one case this cannot tell apart from a real miss: a refusal for a
# reason unrelated to matching (LC_LAZY_LOAD_DYLIB) COMBINED with an OLD
# that also happens not to exist. The classification only asks "does OLD
# exist", never "why did drydock-macho-rewrite refuse", so that combination
# is reported as exit 2, silently -- the fourth divergence's own note above
# has the measured case and why it is accepted rather than closed.
#
# THE IN-PLACE EDIT. rename_segment rewrote the binary it was given; `drydock-macho-rewrite
# segment FILE OUT OLD NEW` does not write the file it is given. So this
# wrapper takes the shared install path around its existing flow: mw_prepare
# names a temp beside the file FILE really is, mw_retranslate re-emits the
# command with that temp as OUT, and mw_finish mv's the temp over the target
# -- but only once drydock-macho-rewrite's own exit said something was
# renamed (a 0 exit, not EX_REFUSED), since the old grammar reported
# "nothing matched" as exit 2 with the file untouched.
# drydock-macho-rewrite-compat.sh's "the install path" section has the reasoning for each
# step.
#
# THE WRITABILITY CHECK comes with mw_prepare. rename_segment opened the file
# O_RDWR before it looked at it, so an unwritable (or absent) file failed
# immediately, with no analysis and no write. drydock-macho-rewrite opens FILE
# O_RDONLY now and has no opinion about whether FILE is writable, and the
# install by mv needs only the DIRECTORY writable -- so without this check the
# wrapper would rewrite files the C tool refused. `test -w` is not
# open(O_RDWR): it consults the real uid and does not see ACLs, so it can
# disagree at the edges. It agrees on the two cases that actually reach a
# caller (absent, and mode-denied), and both sides exit 1 either way.
#
# A HARD-LINKED FILE IS NOW REFUSED (exit 1), the one behaviour here the C tool
# did not have: it wrote through its own descriptor, so every link saw the
# rename, while an install by mv would leave the others on the old content.
# Every wrapper on this install path makes the same trade. And the temp needs
# the DIRECTORY writable, where the C tool needed only FILE itself to be, so a
# writable binary in a read-only directory now fails with FILE untouched.

MW_SELF=$(command -v "$0" 2>/dev/null) || MW_SELF=$0
MW_DIR=${DRYDOCK_MACHO_REWRITE_COMPAT_DIR:-$(dirname "$MW_SELF")}
# Checked here, before sourcing, so a missing support file gets this message
# rather than the shell's own "No such file or directory" from the `.` below.
# The case that actually reaches it: a SYMLINK to this wrapper placed on PATH.
# $0 resolves to the symlink, so MW_DIR is the symlink's directory, not the
# one holding drydock-macho-rewrite -- which is why DRYDOCK_MACHO_REWRITE_COMPAT_DIR exists.
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

# THIN ONLY: `drydock-macho-rewrite info --thin` refuses a fat container,
# which is the gate rename_segment itself had -- plain `info` reports one
# instead of refusing it, which is why the flag exists. Only the exit status
# is used; the output is discarded, deliberately (see the FOURTH DIVERGENCE
# note above). Before the retranslate, so a fat FILE is refused without
# drydock-macho-rewrite ever being asked to write a temp for it.
if ! drydock-macho-rewrite info --thin "$mw_file" >/dev/null 2>&1; then
    printf '%s: not a readable 64-bit Mach-O\n' "$mw_file" >&2
    exit 1
fi

mw_retranslate rename_segment "$@" || exit 1

mw_run >"$MW_T/segout" 2>&1
mw_rc=$?

if [ "$mw_rc" -eq 1 ]; then
    # EX_REFUSED alone does not say WHY: a `segment rename` also refuses
    # this way when the image carries LC_LAZY_LOAD_DYLIB (the FOURTH
    # DIVERGENCE above), which has nothing to do with matching. Classify it
    # by asking whether OLD names a real segment, with the tool's own match
    # rule -- src/segname.c's mseg_rename_lc: strncmp(segname, oldname, 16),
    # MSEG_NAME_MAX in src/segname.h -- rather than trusting EX_REFUSED to
    # mean "nothing matched" on its own.
    mw_old16=$(printf '%s' "$mw_old" | LC_ALL=C cut -c1-16)
    if drydock-macho-rewrite info --thin "$mw_file" >"$MW_T/seginfo" 2>&1; then
        # info's own line is `  segname=%.16s vmaddr=...` (cli/drydock-macho-rewrite.c's
        # info_cb) -- whole-line-prefix, fixed-string, against OLD cut to
        # the same 16 bytes the C compares, so neither of the two awk bugs
        # the header above measured (a long OLD, a segname with whitespace)
        # can recur here.
        if LC_ALL=C grep -q -F -- "  segname=$mw_old16 vmaddr=" "$MW_T/seginfo"; then
            # OLD exists: the refusal is about something else. Show it, the
            # same shape "everything else" always had here.
            cat "$MW_T/segout" >&2
            exit 1
        fi
        # OLD does not exist: the old grammar's exit 2, silently. A refusal
        # writes no temp mw_finish would install, and mw_cleanup's EXIT trap
        # removes whatever drydock-macho-rewrite did leave behind either way.
        exit 2
    fi
    # The classification query itself failed -- an operational failure of
    # its own, not an answer either way.
    cat "$MW_T/seginfo" >&2
    exit 1
fi

# EX_FAIL (2, an operational failure), or any exit this build's `segment
# rename` statement was never specified to produce, is shown on stderr,
# wrapper exit 1 -- the "everything else" this wrapper always had.
[ "$mw_rc" -eq 0 ] || { cat "$MW_T/segout" >&2; exit 1; }

# THE MATCH COUNT, for the report line below. Counted from the renames
# themselves: the `segment` VERB used to close with `machotool segment:
# renamed=N` and this read that number; a script prints no such summary, so
# the count comes from the one line the rewriter emits per segment it
# actually renames (src/rewrite.c's "  Rename segment: OLD -> NEW", on
# stdout, inside the loop over load commands -- so a fat container
# contributes one per slice, exactly as the summary's own sum did).
# Whole-line and FIXED-string, so an OLD or NEW carrying a regular-expression
# metacharacter counts as itself.
mw_n=$(grep -c -x -F -- "  Rename segment: $mw_old -> $mw_new" "$MW_T/segout") || mw_n=0
if [ "$mw_n" -eq 0 ]; then
    # A 0 exit always matched something -- MS_SEGMENT's own unmatched case
    # is exactly the EX_REFUSED handled above -- so a 0 exit with nothing to
    # count means this build's rewriter no longer prints the per-rename
    # line this wrapper reads, not that the rename found nothing. Fail
    # loudly rather than report a rename that did not happen: a build whose
    # segment rename says nothing at all is a mismatched install, not a file
    # this tool should report on.
    printf '%s: %s: this drydock-macho-rewrite did not report what its segment rename matched\n' \
        "$MW_TOOL" "$mw_file" >&2
    cat "$MW_T/segout" >&2
    exit 1
fi

mw_finish || exit 1

printf '%s: renamed %d segment(s) %s -> %s\n' "$mw_file" "$mw_n" "$mw_old" "$mw_new"
exit 0
