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
#      per-rename line is what both forms have always had in common. A run
#      that renames nothing prints none of them and refuses instead -- an
#      unmatched `segment rename` is EX_REFUSED by default (Task 7's flip),
#      and THAT EXIT CODE is what the zero case is checked against now, not
#      the wording of the "matched nothing" line drydock-macho-rewrite still
#      prints alongside it (`drydock-macho-rewrite: segment <OLD> matched
#      nothing`, src/edit.c). A rephrasing of that line cannot move this
#      wrapper's verdict any more; tests/wrapper_test.sh proves it with a
#      stub drydock-macho-rewrite that exits 1 with different wording.
#
#      No digest protects the per-rename line: tests/EXPECTED and
#      tests/known-callers.sh's sha256s hash converted file bytes with the
#      tools' output sent to /dev/null. What pins it is four greps in four
#      files, and they are the whole list:
#
#        * the one grep below, the ONLY ONE THAT IS NOT A TEST -- production
#          code a caller depends on for the count (this file used to carry a
#          second one, checking the zero case against the "matched nothing"
#          wording; Task 9 deleted it, once the exit code above made it
#          redundant);
#        * compat/patch_macho.sh's `^Already patched` grep, production code
#          too, though that line comes from md_declassify rather than from any
#          verb, so it did not move with this one;
#        * tests/wrapper_test.sh's two unmatched-report assertions, which
#          match whole lines beginning `drydock-macho-rewrite: `; and
#        * tests/cli_test.sh's `^drydock-macho-rewrite edit: ` prefix check.
#
#      Each of the four carries this same list, so the set is findable from
#      any one of them, and all four have to move with the strings they read.
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
#      The count now comes from the code that did the matching.
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
# rename_segment had. Since Task 9, drydock-macho-rewrite's own exit code IS
# what "nothing matched" is decided from, on purpose: EX_REFUSED (1) is a
# considered refusal, and a `segment rename` statement refuses this way for
# exactly one reason -- MS_SEGMENT's own unmatched case (src/edit.c) -- so
# that number becomes this wrapper's exit 2, silently, matching the old
# grammar's own exit 2 with the file untouched. Every OTHER nonzero --
# EX_FAIL (2, an operational failure), or anything this build's `segment
# rename` was never specified to produce -- becomes this wrapper's 1, shown
# on stderr, which is what "everything else" always meant here. The two
# tool exit codes therefore map to two DIFFERENT wrapper exit codes on
# purpose: EX_REFUSED (1) to this wrapper's 2, EX_FAIL (2) to this wrapper's
# 1, and nothing folds them together.
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

# NOTHING MATCHED: the old grammar's exit 2, and nothing is installed. An
# unmatched `segment rename` is EX_REFUSED (1) by default now (Task 7's flip
# made an unmatched operation fatal), so THAT number is the verdict -- it is
# no longer recovered by grepping stderr for drydock-macho-rewrite's exact
# "segment X matched nothing" wording, which made this wrapper depend on how
# a human-readable line was phrased. Nothing is shown to the caller for it
# either, matching the old grammar's own silence in this case: a refusal
# writes no temp mw_finish would install, and mw_cleanup's EXIT trap removes
# whatever drydock-macho-rewrite did leave behind either way.
[ "$mw_rc" -eq 1 ] && exit 2

# EVERYTHING ELSE -- EX_FAIL (2, an operational failure), or any exit this
# build's `segment rename` statement was never specified to produce -- is
# unchanged from before this task: shown on stderr, wrapper exit 1. This is
# also what keeps EX_FAIL and EX_REFUSED from folding into the same number by
# accident: only a 1 above becomes this wrapper's silent 2; everything else
# lands here instead.
[ "$mw_rc" -eq 0 ] || { cat "$MW_T/segout" >&2; exit 1; }

# THE MATCH COUNT, for the report line below -- not, any more, for the
# verdict above. Counted from the renames themselves: the `segment` VERB
# used to close with `machotool segment: renamed=N` and this read that number;
# a script prints no such summary, so the count comes from the one line the
# rewriter emits per segment it actually renames (src/rewrite.c's
# "  Rename segment: OLD -> NEW", on stdout, inside the loop over load
# commands -- so a fat container contributes one per slice, exactly as the
# summary's own sum did). Whole-line and FIXED-string, so an OLD or NEW
# carrying a regular-expression metacharacter counts as itself. A 0 exit from
# drydock-macho-rewrite always matched something (MS_SEGMENT's own unmatched
# case is exactly the EX_REFUSED above), so mw_n here is never 0.
mw_n=$(grep -c -x -F -- "  Rename segment: $mw_old -> $mw_new" "$MW_T/segout") || mw_n=0

mw_finish || exit 1

printf '%s: renamed %d segment(s) %s -> %s\n' "$mw_file" "$mw_n" "$mw_old" "$mw_new"
exit 0
