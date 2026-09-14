#!/bin/sh
# tests/translate_test.sh -- one test per translation, asserting the EXACT
# text compat/translate.sh emits: a `printf ... | machotool FILE OUT`
# pipeline, statements and quoting included, plus the `mv` install line the
# teaching form ends with.
#
#   sh tests/translate_test.sh <bindir>
#
# Every line compat/translate.sh prints is a CLAIM that an old-grammar
# invocation and a machotool one mean the same thing. docs/PROPOSAL.md rejected
# the old spellings as machotool synonyms on purpose, "because they would
# advertise an interchangeability that does not exist, on exactly the binaries
# where it does not hold" -- so each claim gets a test, and the test pins the
# whole command line, not just that something was printed. A translation that
# emitted `dylib -append` where `-insert` was meant would still "work" and
# would still be wrong (an appended LC_LOAD_DYLIB gets the highest library
# ordinal; an inserted one gets ordinal 1).
#
# WHAT THIS DOES NOT DO: it never runs machotool on a file. Whether the emitted
# commands PRODUCE the same bytes as the old tool is a different question, and
# tests/compat-sweep.sh answers it over 1200 combinations against real
# binaries. This test is about the text.
#
# The bindir is used for exactly one thing: `machotool --capabilities`. The spec's
# "Migration" section says that probe exists so the wrapper and the binary need
# not move in lockstep, and the last check below is what actually uses it --
# every verb, op and KIND this translator can emit has to be one this build
# advertises. Hardcoding that agreement instead of checking it is how the
# ops=/kinds= lists in cli/machotool.c drifted from their own parsers once already.
set -u

BIN="${1:?usage: translate_test.sh <bindir>}"
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
TR="$ROOT/compat/translate.sh"
[ -r "$TR" ] || { echo "translate_test: $TR missing" >&2; exit 1; }
[ -x "$BIN/machotool" ] || { echo "translate_test: $BIN/machotool missing" >&2; exit 1; }

T=$(mktemp -d "${TMPDIR:-/tmp}/macho-translate-test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

pass=0; fail=0

# ok <name> <expected-stdout> -- TOOL ARG...
#
# Runs the translator as a separate process, exactly as a caller would, and
# compares its whole stdout against the expected text (empty means "no lines").
# Exit status must be 0.
ok() {
    name=$1; want=$2; shift 3   # the third argument is the literal --
    got=$( /bin/sh "$TR" "$@" 2>"$T/err" ); rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'FAIL %s: exit %d, expected 0\n  stderr: %s\n' "$name" "$rc" "$(cat "$T/err")" >&2
        fail=$((fail + 1)); return 0
    fi
    if [ "$got" != "$want" ]; then
        printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$name" "$want" "$got" >&2
        fail=$((fail + 1)); return 0
    fi
    pass=$((pass + 1))
}

# refuses <name> <expected exit> <expected first stderr line> -- TOOL ARG...
#
# The old tool refused this argv, so the translation must refuse it too, with
# the ORIGIN tool's own message and nothing at all on stdout -- never a
# plausible-looking command that would do something adjacent.
refuses() {
    name=$1; wantrc=$2; wantmsg=$3; shift 4
    got=$( MT_PROG0="$1" /bin/sh "$TR" "$@" 2>"$T/err" ); rc=$?
    msg=$(head -1 "$T/err")
    bad=''
    [ "$rc" = "$wantrc" ] || bad="exit $rc (want $wantrc)"
    [ -z "$got" ] || bad="$bad; stdout not empty: $got"
    [ "$msg" = "$wantmsg" ] || bad="$bad; stderr first line: $msg"
    if [ -n "$bad" ]; then
        printf 'FAIL %s: %s\n' "$name" "$bad" >&2
        fail=$((fail + 1)); return 0
    fi
    pass=$((pass + 1))
}

# ---- change_dylib: one assertion per flag -------------------------------
#
# All ten flags its parser accepts, each alone. `-grow` cannot appear alone
# (see the usage-error section below), so it is asserted with the smallest
# operation that lets it through.
ok cd-change    "printf 'dylib replace OLD NEW\n' | machotool f f.new
mv -f f.new f"        -- change_dylib f -change OLD NEW
ok cd-delete    "printf 'dylib delete P\n' | machotool f f.new
mv -f f.new f"               -- change_dylib f -delete P
ok cd-reexport  "printf 'dylib reexport P\n' | machotool f f.new
mv -f f.new f"             -- change_dylib f -reexport P
ok cd-add       "printf 'dylib append P\n' | machotool f f.new
mv -f f.new f"               -- change_dylib f -add P
ok cd-insert    "printf 'dylib insert P\n' | machotool f f.new
mv -f f.new f"               -- change_dylib f -insert P
ok cd-rchange   "printf 'rpath replace OLD NEW\n' | machotool f f.new
mv -f f.new f"        -- change_dylib f -change-rpath OLD NEW
ok cd-rdelete   "printf 'rpath delete P\n' | machotool f f.new
mv -f f.new f"               -- change_dylib f -delete-rpath P
ok cd-radd      "printf 'rpath append P\n' | machotool f f.new
mv -f f.new f"               -- change_dylib f -add-rpath P
ok cd-strip     "printf 'load-command delete uuid\n' | machotool f f.new
mv -f f.new f"               -- change_dylib f -strip-lc uuid
ok cd-grow      "printf 'allow-grow\ndylib append P\n' | machotool f f.new
mv -f f.new f"  -- change_dylib f -grow -add P

# -add is NOT -insert and -insert is NOT -add: an appended LC_LOAD_DYLIB gets
# the highest library ordinal, an inserted one gets ordinal 1. Asserting the
# pair together is what would catch a translation that silently downgraded one
# to the other.
ok cd-add-vs-insert "printf 'dylib append A\ndylib insert B\n' | machotool f f.new
mv -f f.new f" -- change_dylib f -add A -insert B

# Every -strip-lc KIND, since the vocabulary is a table and a table can lose a
# row. These are change_dylib's own five, from src/lc_kinds.c.
ok cd-kind-uuid     "printf 'load-command delete uuid\n' | machotool f f.new
mv -f f.new f"           -- change_dylib f -strip-lc uuid
ok cd-kind-codesig  "printf 'load-command delete codesig\n' | machotool f f.new
mv -f f.new f"        -- change_dylib f -strip-lc codesig
ok cd-kind-srcver   "printf 'load-command delete source-version\n' | machotool f f.new
mv -f f.new f" -- change_dylib f -strip-lc source-version
ok cd-kind-buildver "printf 'load-command delete build-version\n' | machotool f f.new
mv -f f.new f"  -- change_dylib f -strip-lc build-version
ok cd-kind-drs      "printf 'load-command delete code-sign-drs\n' | machotool f f.new
mv -f f.new f"  -- change_dylib f -strip-lc code-sign-drs

# Repeats accumulate into ONE command, in the order typed -- not one command
# per operation. Order between statements is meaningful to the rewriter.
ok cd-repeat "printf 'dylib replace A B\ndylib replace C D\n' | machotool f f.new
mv -f f.new f" -- change_dylib f -change A B -change C D
ok cd-strip-repeat "printf 'load-command delete uuid\nload-command delete codesig\n' | machotool f f.new
mv -f f.new f" -- change_dylib f -strip-lc uuid -strip-lc codesig

# ---- change_dylib: several operations, still ONE command -----------------
#
# Whatever an old invocation asks for, it becomes one `printf ... | machotool
# FILE OUT` with the operations as statements on stdin -- one read, one pass
# per statement, one write, which is the shape the C tool had and a sequence
# of commands did not. The teaching form's trailing `mv` is the install step
# every in-place tool's form ends with.
#
# The order is load-command, then dylib, then rpath: deleting load commands
# hands header pad back, and the other two consume it. Getting this backwards
# is how a mixed invocation that used to fit stops fitting.
ok cd-mixed-2 "printf 'load-command delete uuid\ndylib replace A B\n' | machotool f f.new
mv -f f.new f" -- change_dylib f -strip-lc uuid -change A B

ok cd-mixed-3 "printf 'load-command delete uuid\ndylib append D\nrpath append R\n' | machotool f f.new
mv -f f.new f" -- change_dylib f -add-rpath R -add D -strip-lc uuid

# The ORDER OF THE FLAGS does not change the order of the statements between
# families -- only the order within each family's own block.
ok cd-mixed-order "printf 'load-command delete codesig\nload-command delete uuid\ndylib replace A B\n' | machotool f f.new
mv -f f.new f" -- change_dylib f -change A B -strip-lc codesig -strip-lc uuid

# -grow becomes the `allow-grow` DIRECTIVE, which must precede every
# operation (src/script.c refuses one that does not). Like the --allow-grow it
# replaces, it reaches dylib and rpath and not the load-command deletes:
# src/edit.c sets ops.allow_grow only for the statements that can outgrow the
# pad, and deleting load commands can only shrink the table.
ok cd-grow-mixed "printf 'allow-grow\nload-command delete uuid\ndylib replace A B\nrpath append R\n' | machotool f f.new
mv -f f.new f" -- change_dylib f -grow -strip-lc uuid -change A B -add-rpath R

# EVERY INSERT IS EMITTED IN REVERSE FLAG ORDER, because each one goes to the
# FRONT of the table: as a batch `-insert A -insert B` leaves A at ordinal 1
# and B at 2, and a sequence reproduces that only by inserting B first. This
# is the assertion that catches the emission getting it the natural way round.
# tests/wrapper_test.sh asserts the resulting ordinals on a real binary.
ok cd-insert-reverse "printf 'load-command delete uuid\ndylib insert B\ndylib insert A\n' | machotool f f.new
mv -f f.new f" -- change_dylib f -insert A -insert B -strip-lc uuid

# A -delete AND a -change NAMING THE SAME PATH is the shape the two application
# models disagree about: change_dylib applied its whole family as a set, where
# mr_is_deleted (src/rewrite.c) made the delete win whatever the order. The
# emission reproduces that by ORDER -- the delete first, so the replace then
# finds nothing -- which is why the delete bucket is emitted ahead of the
# replace bucket even when the flags were typed the other way round.
ok cd-delete-beats-change "printf 'dylib delete P\ndylib replace P Q\n' | machotool f f.new
mv -f f.new f" -- change_dylib f -change P Q -delete P

# install.sh's production line -- the single most important translation in
# this task, quoted from the plan's Task 0 evidence.
ok cd-production "printf 'load-command delete uuid\nload-command delete codesig\ndylib replace /usr/lib/libSystem.B.dylib @loader_path/../S.dylib\ndylib replace /usr/lib/libicucore.A.dylib @loader_path/../I.dylib\ndylib replace /usr/lib/libc++.1.dylib @loader_path/../c++.1.dylib\n' | machotool /tmp/c /tmp/c.new
mv -f /tmp/c.new /tmp/c" \
    -- change_dylib /tmp/c -strip-lc uuid -strip-lc codesig \
        -change /usr/lib/libSystem.B.dylib @loader_path/../S.dylib \
        -change /usr/lib/libicucore.A.dylib @loader_path/../I.dylib \
        -change /usr/lib/libc++.1.dylib @loader_path/../c++.1.dylib

# tests/characterize.sh's line, this repo's own CI equivalence gate.
ok cd-characterize "printf 'load-command delete uuid\nload-command delete codesig\ndylib replace /usr/lib/libSystem.B.dylib @loader_path/../S.dylib\n' | machotool out out.new
mv -f out.new out" \
    -- change_dylib out -strip-lc uuid -strip-lc codesig \
        -change /usr/lib/libSystem.B.dylib @loader_path/../S.dylib

# `-grow` with no operation at all: change_dylib accepts it (once argc is big
# enough) and changes nothing, so the translation is deliberately EMPTY rather
# than some adjacent command. Empty stdout with exit 0 is the contract for
# "the old invocation was a no-op".
ok cd-grow-only '' -- change_dylib f -grow -grow

# ---- fix_macho ----------------------------------------------------------
ok fm-change   "printf 'dylib replace OLD NEW\n' | machotool f f.new
mv -f f.new f"         -- fix_macho f -change OLD NEW
ok fm-stripbv  "printf 'load-command delete build-version\n' | machotool f f.new
mv -f f.new f"       -- fix_macho f -strip_build_version
# -rename_seg is accepted by fix_macho's parser and appears NOWHERE in its
# usage text. Enumerating from the parser is what found it.
ok fm-rename   "printf 'segment rename __DATA __D2\n' | machotool f f.new
mv -f f.new f"            -- fix_macho f -rename_seg __DATA __D2
# One rename statement is one pass, so two renames are two statements in the
# one command. Each rename is still its own pass, in argv order.
ok fm-rename-2 "printf 'segment rename __A __B\nsegment rename __C __D\n' | machotool f f.new
mv -f f.new f" -- fix_macho f -rename_seg __A __B -rename_seg __C __D
# All three families, in load-command / dylib / segment order. No allow-grow
# anywhere: fix_macho has no -grow and never enlarges a header.
ok fm-all "printf 'load-command delete build-version\ndylib replace A B\nsegment rename __A __B\n' | machotool f f.new
mv -f f.new f" -- fix_macho f -change A B -strip_build_version -rename_seg __A __B
# The flag is a boolean, so repeating it is still one load-command delete.
ok fm-stripbv-twice "printf 'load-command delete build-version\n' | machotool f f.new
mv -f f.new f" \
    -- fix_macho f -strip_build_version -strip_build_version

# CHAINED -rename_seg TRANSLATES, and these three assertions USED TO BE
# `refuses ... 2 ...`. compat/translate.sh refused the shape while
# compat/fix_macho.c still shipped, because a wrapper had to preserve that
# tool's answer and the two differ: fix_macho gave each segment its FIRST
# matching pair and never revisited it, so `-rename_seg A B -rename_seg B C`
# ended at B, while two machotool segment passes chain and end at C. The repo
# owner has since ruled that difference an improvement to ADOPT -- "doing what
# was asked" -- and the C tool is gone, so there is no longer a second answer
# to preserve. These now pin the translation, in the same place they used to
# pin the refusal; compat/translate.sh's -rename_seg arm records the reversal.
ok fm-chain "printf 'segment rename __DATA __X\nsegment rename __X __Y\n' | machotool f f.new
mv -f f.new f" -- fix_macho f -rename_seg __DATA __X -rename_seg __X __Y
# A chain of three emits three passes, in argv order -- every link, not just
# the first (which is where the refusal used to trip).
ok fm-chain-3 "printf 'segment rename __DATA __P\nsegment rename __P __Q\nsegment rename __Q __R\n' | machotool f f.new
mv -f f.new f" \
    -- fix_macho f -rename_seg __DATA __P -rename_seg __P __Q -rename_seg __Q __R
# The empty string is a legal NEW -- a segname may be all NULs -- and it stays
# an argument rather than vanishing: mt_quote emits it as '' so the emitted
# line still has four words after the verb. That is what the old chain check's
# own regression case was really about (an empty NEW that field-splitting
# silently dropped), and it is still worth pinning now that the check is gone.
# mt_quote's '' is also exactly what src/script.c's ms_split reads back as an
# empty field, so the statement still has four words.
ok fm-chain-empty "printf 'segment rename __DATA '\\'''\\''\nsegment rename '\\'''\\'' __Y\n' | machotool f f.new
mv -f f.new f" \
    -- fix_macho f -rename_seg __DATA '' -rename_seg '' __Y
# The three shapes that were never affected by that refusal, and are not
# affected by its removal either. Each was measured against the real fix_macho
# on tests/fixture.macho and agreed byte-for-byte with its translation.
#
# NOTE none of these three is refused by mt_chain_check, which watches -change
# and not -rename_seg: a rename statement and a `machotool segment` pass are the
# same single operation, so sequencing them is the adopted behaviour rather
# than a shape with no equivalent.
ok fm-same-old "printf 'segment rename __DATA __A\nsegment rename __DATA __B\n' | machotool f f.new
mv -f f.new f" -- fix_macho f -rename_seg __DATA __A -rename_seg __DATA __B
ok fm-new-eq-earlier-old "printf 'segment rename __DATA __B\nsegment rename __TEXT __DATA\n' | machotool f f.new
mv -f f.new f" -- fix_macho f -rename_seg __DATA __B -rename_seg __TEXT __DATA
ok fm-independent "printf 'segment rename __DATA __A\nsegment rename __TEXT __B\n' | machotool f f.new
mv -f f.new f" -- fix_macho f -rename_seg __DATA __A -rename_seg __TEXT __B

# ---- the four fixed-arity tools -----------------------------------------
# machotool never writes its input, so the teaching form names an output of its
# own and ends with the install step -- two lines, and both of them pinned:
# what a reader is shown has to be the complete equivalent of the old in-place
# edit, not the half of it that rewrites nothing.
ok avm     "printf 'version-min set 10.9\n' | machotool f f.new
mv -f f.new f"                               -- add_version_min f
# MT_OUT is how a wrapper names the temp it is going to install: the command
# writes exactly that, and the `mv` disappears because the wrapper does the
# installing itself.
mt_out_got=$( MT_OUT=/tmp/t.tmp /bin/sh "$TR" add_version_min f )
if [ "$mt_out_got" = "printf 'version-min set 10.9\n' | machotool f /tmp/t.tmp" ]; then
    pass=$((pass + 1))
else
    printf 'FAIL avm-mt-out: got %s\n' "$mt_out_got" >&2; fail=$((fail + 1))
fi
# patch_macho is the one tool whose grammar always named its own output, so the
# teaching form is the command the user typed -- there is nothing to install.
ok pm      "printf 'fixups set classic\n' | machotool in out"        -- patch_macho in out
# ... EXCEPT when IN and OUT are the same file, which patch_macho allowed and
# machotool now refuses. The teaching form has to be a pasteable equivalent of
# that in-place conversion, so it names an output of its own and installs it,
# exactly as the five in-place tools' forms do.
ok pm-same "printf 'fixups set classic\n' | machotool f f.new
mv -f f.new f"                               -- patch_macho f f
# MT_OUT is how the wrapper names the temp it installs onto the user's OUT --
# for both shapes, since the wrapper installs onto OUT either way.
mt_out_got=$( MT_OUT=/tmp/t.tmp /bin/sh "$TR" patch_macho in out )
if [ "$mt_out_got" = "printf 'fixups set classic\n' | machotool in /tmp/t.tmp" ]; then
    pass=$((pass + 1))
else
    printf 'FAIL pm-mt-out: got %s\n' "$mt_out_got" >&2; fail=$((fail + 1))
fi
mt_out_got=$( MT_OUT=/tmp/t.tmp /bin/sh "$TR" patch_macho f f )
if [ "$mt_out_got" = "printf 'fixups set classic\n' | machotool f /tmp/t.tmp" ]; then
    pass=$((pass + 1))
else
    printf 'FAIL pm-mt-out-same: got %s\n' "$mt_out_got" >&2; fail=$((fail + 1))
fi
ok rs      "printf 'segment rename __DATA __DATA2\n' | machotool f f.new
mv -f f.new f" -- rename_segment f __DATA __DATA2
ok rs-16   "printf 'segment rename __DATA 1234567890123456\n' | machotool f f.new
mv -f f.new f" -- rename_segment f __DATA 1234567890123456
# retag_swift_classes is variadic over FILES; one command names one FILE and
# one OUT, so the translation is a loop, one command per file, in argv order.
# Each file, like add_version_min's, gets its own output and install step.
ok rsc-1 "printf 'swift-abi set legacy\n' | machotool a a.new
mv -f a.new a"                                                    -- retag_swift_classes a
ok rsc-3 "printf 'swift-abi set legacy\n' | machotool a a.new
mv -f a.new a
printf 'swift-abi set legacy\n' | machotool b b.new
mv -f b.new b
printf 'swift-abi set legacy\n' | machotool c c.new
mv -f c.new c" -- retag_swift_classes a b c
# MT_OUT names a single output for the whole call, so it only makes sense set
# when retranslating ONE file at a time -- retag_swift_classes.sh's own loop.
rsc_out_got=$( MT_OUT=/tmp/t.tmp /bin/sh "$TR" retag_swift_classes a )
if [ "$rsc_out_got" = "printf 'swift-abi set legacy\n' | machotool a /tmp/t.tmp" ]; then
    pass=$((pass + 1))
else
    printf 'FAIL rsc-mt-out: got %s\n' "$rsc_out_got" >&2; fail=$((fail + 1))
fi

# ---- quoting ------------------------------------------------------------
#
# Each emitted line has to be eval-safe, because that is how a wrapper runs it.
# Quote only what needs quoting, so the common case stays readable. There are
# TWO surfaces now, not one: FILE and OUT are ordinary command arguments, and
# the statements are the `printf` FORMAT -- which printf itself rewrites, so a
# `%` or a `\` in a path has to arrive doubled.
ok q-space "printf 'segment rename __DATA __D2\n' | machotool 'a b' 'a b.new'
mv -f 'a b.new' 'a b'"      -- rename_segment 'a b' __DATA __D2
ok q-quote "printf 'fixups set classic\n' | machotool 'it'\\''s' out"  -- patch_macho "it's" out
ok q-empty "printf 'segment rename __DATA '\\'''\\''\n' | machotool f f.new
mv -f f.new f"            -- rename_segment f __DATA ''
ok q-percent "printf 'dylib append a%%sb\n' | machotool f f.new
mv -f f.new f" -- change_dylib f -add 'a%sb'
ok q-backslash "printf 'dylib append '\\''back\\\\slash/f'\\''\n' | machotool f f.new
mv -f f.new f" -- change_dylib f -add 'back\slash/f'

# ... and RUNNING the emitted pipeline really does hand machotool the path the
# caller named. `machotool` is shadowed by a function that saves the statement
# it is given on stdin; the statement is then split the way src/script.c's
# ms_split splits it (whitespace separates, '...' is literal), which is the
# equivalence compat/translate.sh's quoting section claims. A `%`, a `\` or a
# `'` that did not survive shows up here as a path that came back different.
q_roundtrip() {   # q_roundtrip NAME PATH
    q_name=$1; q_want=$2
    q_line=$( MT_OUT=/tmp/t.tmp /bin/sh "$TR" change_dylib f -add "$q_want" )
    # Defined fresh each time, and removed after, so nothing else in this file
    # can pick it up by accident. It runs in the pipeline's subshell, so the
    # statement comes back through a file rather than through a variable.
    machotool() { cat > "$T/stmt"; }
    rm -f "$T/stmt"
    eval "$q_line"
    unset -f machotool
    set --; eval "set -- $(cat "$T/stmt")"
    q_got=${3:-}
    if [ "$q_got" = "$q_want" ] && [ "${1:-}" = dylib ] && [ "${2:-}" = append ]; then
        pass=$((pass + 1))
    else
        printf 'FAIL %s: emitted [%s]; a caller running it appends [%s], not [%s]\n' \
            "$q_name" "$q_line" "$q_got" "$q_want" >&2
        fail=$((fail + 1))
    fi
}
q_roundtrip q-rt-plain     /usr/lib/libSystem.B.dylib
q_roundtrip q-rt-percent   'a%sb'
q_roundtrip q-rt-backslash 'back\slash/f'
q_roundtrip q-rt-quote     "it's"
q_roundtrip q-rt-space     'p q'
q_roundtrip q-rt-empty     ''

# ---- MACHOTOOL names the program word --------------------------------------
got=$( MACHOTOOL=/opt/bin/machotool /bin/sh "$TR" add_version_min f )
if [ "$got" = "printf 'version-min set 10.9\n' | /opt/bin/machotool f f.new
mv -f f.new f" ]; then
    pass=$((pass + 1))
else
    printf 'FAIL machotool-env: got %s\n' "$got" >&2; fail=$((fail + 1))
fi

# ---- refusals: the old tool's own message, verbatim ---------------------
#
# Every one of these is a case the OLD tool refused. The translation must
# refuse identically, print nothing on stdout, and use the ORIGIN wording --
# for the capacity caps that is a controller ruling, because cli/machotool.c
# deliberately prints different text there so the new grammar never leaks the
# old flag spellings.
CD_USAGE='Usage: change_dylib input [-grow] [-change old new] [-delete path] [-reexport path] [-add path] [-insert path] [-strip-lc name] [-change-rpath old new] [-delete-rpath path] [-add-rpath path] ...'

# `argc < 4`: change_dylib's usage text presents -grow as a standalone option,
# but its parser never gets to see it. Parser wins.
refuses cd-usage-grow  1 "$CD_USAGE" -- change_dylib f -grow
refuses cd-usage-bare  1 "$CD_USAGE" -- change_dylib f
refuses cd-usage-none  1 "$CD_USAGE" -- change_dylib

# The `i + N < argc` guards name the FLAG, not the missing operand.
refuses cd-short-change 1 'bad arg: -change'       -- change_dylib f -change OLD
refuses cd-short-add    1 'bad arg: -add'          -- change_dylib f -grow -add
refuses cd-short-strip  1 'bad arg: -strip-lc'     -- change_dylib f -grow -strip-lc
refuses cd-short-rchange 1 'bad arg: -change-rpath' -- change_dylib f -change-rpath OLD
refuses cd-bad-arg      1 'bad arg: -nope'         -- change_dylib f -nope x
refuses cd-bad-kind     1 'unknown -strip-lc kind: nope' -- change_dylib f -strip-lc nope

# THE ONE REFUSAL THIS FILE MAKES OF ITS OWN. A batch gave every -change the
# ORIGINAL paths to compare against, so `-change a b -change b c` rewrote the
# a's to b and the original b's to c and never revisited what the first pair
# produced; a sequence of statements rewrites those too and lands on c. No
# emission order fixes it, so the translation says so instead of emitting
# something adjacent.
refuses cd-chain 1 '-change a b and -change b c chain: run them as separate invocations' \
    -- change_dylib f -change a b -change b c -strip-lc uuid
# A SWAP is the same defect: b becomes a, and then every a (including the ones
# the first statement just made) becomes b.
refuses cd-chain-swap 1 '-change a b and -change b a chain: run them as separate invocations' \
    -- change_dylib f -change a b -change b a -strip-lc uuid
# The rpath family gets the same check, naming ITS flag -- the user typed
# -change-rpath, and a message naming -change would name a flag they did not.
refuses cd-chain-rpath 1 '-change-rpath a b and -change-rpath b c chain: run them as separate invocations' \
    -- change_dylib f -change-rpath a b -change-rpath b c -strip-lc uuid
# fix_macho's -change, on the same path, for the same reason.
refuses fm-chain-change 1 '-change a b and -change b c chain: run them as separate invocations' \
    -- fix_macho f -change a b -change b c -strip_build_version
# THE SAME CHAIN WITH ONE FAMILY IS NOW REFUSED TOO, and these two assertions
# USED TO BE `ok ... machotool dylib f f.new -replace a b -replace b c`. A
# single-family invocation used to emit that family's VERB, whose batch WAS the
# C tool's own semantics -- so there was nothing to reproduce and nothing to
# refuse. There is no verb to emit any more: every invocation is a sequence of
# statements, so the one shape a sequence cannot reproduce is refused wherever
# it appears. This is the one outcome that moved in this change: an invocation
# that used to be translated now exits 1 with this message, which is the honest
# answer -- the alternative was emitting a sequence that produces different
# bytes, silently.
refuses cd-chain-one-family 1 '-change a b and -change b c chain: run them as separate invocations' \
    -- change_dylib f -change a b -change b c
refuses fm-chain-one-family 1 '-change a b and -change b c chain: run them as separate invocations' \
    -- fix_macho f -change a b -change b c
# And a -change whose NEW is its OWN old is not a chain: no OTHER statement
# rewrites what it produced, so a statement and a batch agree.
ok cd-self-replace "printf 'load-command delete uuid\ndylib replace a a\ndylib replace c d\n' | machotool f f.new
mv -f f.new f" -- change_dylib f -change a a -change c d -strip-lc uuid

refuses fm-usage        1 'Usage: fix_macho <file> [-change old new] [-strip_build_version]' -- fix_macho f
refuses fm-unknown      1 'Unknown option: -nope'  -- fix_macho f -nope
refuses fm-short-change 1 'Unknown option: -change' -- fix_macho f -change OLD
refuses fm-long-seg     1 'new segment name longer than 16 bytes: 12345678901234567' \
    -- fix_macho f -rename_seg __DATA 12345678901234567

refuses avm-usage-0 1 'Usage: add_version_min binary' -- add_version_min
refuses avm-usage-2 1 'Usage: add_version_min binary' -- add_version_min a b
refuses pm-usage-1  1 'Usage: patch_macho input output' -- patch_macho a
refuses pm-usage-3  1 'Usage: patch_macho input output' -- patch_macho a b c
refuses rs-usage-2  1 'Usage: rename_segment binary OLDNAME NEWNAME' -- rename_segment a b
refuses rs-usage-4  1 'Usage: rename_segment binary OLDNAME NEWNAME' -- rename_segment a b c d
refuses rs-long     1 'new segment name longer than 16 bytes' -- rename_segment f __DATA 12345678901234567
refuses rsc-usage-0 1 'Usage: retag_swift_classes binary [binary ...]' -- retag_swift_classes

# A tool this file has never heard of gets a clear "no equivalent" and a
# nonzero exit -- never a guess.
refuses unknown-tool 2 \
    'translate.sh: no equivalent -- unknown tool otool (expected one of: change_dylib add_version_min patch_macho rename_segment retag_swift_classes fix_macho)' \
    -- otool -L f

# ---- capacity caps ------------------------------------------------------
#
# Enforced HERE, printing change_dylib's own text, because routing through
# machotool would print machotool's (which names -append where change_dylib names
# -add). Both cap sites in cli/machotool.c carry a comment saying exactly that.
mkcap() { i=0; out=''; while [ $i -lt $2 ]; do out="$out $1"; i=$((i + 1)); done; printf '%s' "$out"; }
# The same, with no separator: N copies of one statement inside a printf
# format, which is what the emitted command carries now.
mkrep() { i=0; out=''; while [ $i -lt $2 ]; do out="$out$1"; i=$((i + 1)); done; printf '%s' "$out"; }

ok cap-strip-16-fits "printf '$(mkrep 'load-command delete uuid\n' 16)' | machotool f f.new
mv -f f.new f" -- change_dylib f $(mkcap '-strip-lc uuid' 16)
refuses cap-strip-17 1 'too many -strip-lc (max 16)' -- change_dylib f $(mkcap '-strip-lc uuid' 17)
refuses cap-add-33   1 'too many -add (max 32)'      -- change_dylib f $(mkcap '-add P' 33)
refuses cap-ins-33   1 'too many -insert (max 32)'   -- change_dylib f $(mkcap '-insert P' 33)
refuses cap-chg-33   1 'too many -change (max 32)'   -- change_dylib f $(mkcap '-change A B' 33)
refuses cap-radd-33  1 'too many -add-rpath (max 32)' -- change_dylib f $(mkcap '-add-rpath P' 33)
# -change, -delete and -reexport SHARE one 32-entry array, so 16 of one plus 17
# of another overflows although neither reaches 32 alone. The message names the
# flag that overflowed, which here is -delete.
refuses cap-shared 1 'too many -delete (max 32)' \
    -- change_dylib f $(mkcap '-change A B' 16) $(mkcap '-delete P' 17)

# fix_macho's two caps, which came here when compat/fix_macho.c retired. Its
# FM_ROOM printed change_dylib's exact wording with fix_macho's flag names in
# it, so these are that same text. The -rename_seg cap has no machotool
# counterpart at all -- a `segment rename` statement is one pair, so nothing
# downstream would ever count them -- which makes this file the only thing
# keeping that refusal alive.
ok fm-cap-change-32-fits "printf '$(mkrep 'dylib replace A B\n' 32)' | machotool f f.new
mv -f f.new f" \
    -- fix_macho f $(mkcap '-change A B' 32)
refuses fm-cap-change-33 1 'too many -change (max 32)' -- fix_macho f $(mkcap '-change A B' 33)
refuses fm-cap-rename-17 1 'too many -rename_seg (max 16)' \
    -- fix_macho f $(mkcap '-rename_seg __A __B' 17)
# At capacity must still be accepted -- a check one too eager would silently
# halve what a caller can ask for. 16 pairs is 16 emitted `segment rename`
# statements, counted inside the one command's printf format rather than as
# lines of their own.
fm_16=$( /bin/sh "$TR" fix_macho f $(mkcap '-rename_seg __A __B' 16) 2>"$T/err" )
fm_16_n=$(printf '%s\n' "$fm_16" | sed -n 1p \
    | awk '{ n = gsub(/segment rename __A __B\\n/, ""); print n }')
if [ "$fm_16_n" = 16 ]; then
    pass=$((pass + 1))
else
    printf 'FAIL fm-cap-rename-16-fits: %s statements, want 16 (stderr: %s)\n' \
        "$fm_16_n" "$(cat "$T/err")" >&2
    fail=$((fail + 1))
fi

# ---- the emitted grammar is one this build actually has -----------------
#
# `machotool --capabilities` is the machine-readable probe docs/PROPOSAL.md's
# "Migration" section says exists so the wrapper and the binary need not move
# in lockstep. Use it rather than assuming: every STATEMENT this translator can
# emit must be advertised with the right arity, and every -strip-lc KIND it can
# name must be one this build knows. The verb rows are still checked below
# because kinds= is where the KIND vocabulary is published today; the
# statement rows are what the emitted commands actually use.
"$BIN/machotool" --capabilities > "$T/caps" 2>/dev/null
capcheck() {   # capcheck <verb> <attr-prefix> <value>...
    v=$1; attr=$2; shift 2
    line=$(grep "^verb $v" "$T/caps")
    if [ -z "$line" ]; then
        printf 'FAIL caps-%s: this build does not advertise the verb\n' "$v" >&2
        fail=$((fail + 1)); return 0
    fi
    for want in "$@"; do
        vals=$(printf '%s\n' "$line" | tr ' ' '\n' | sed -n "s/^$attr=//p" | tr ',' '\n')
        if printf '%s\n' "$vals" | grep -qx "$want"; then
            pass=$((pass + 1))
        else
            printf 'FAIL caps-%s: %s=%s not advertised (line: %s)\n' "$v" "$attr" "$want" "$line" >&2
            fail=$((fail + 1))
        fi
    done
}
for v in declassify minos segment retag-swift lc dylib rpath edit; do
    if grep -q "^verb $v" "$T/caps"; then
        pass=$((pass + 1))
    else
        printf 'FAIL caps-verb-%s: not advertised by this build\n' "$v" >&2
        fail=$((fail + 1))
    fi
done
capcheck dylib ops replace delete append insert reexport
capcheck rpath ops replace delete append
capcheck lc    ops delete
capcheck lc    kinds uuid codesig source-version build-version code-sign-drs
capcheck minos versions 10.9

# Every STATEMENT this translator can put in an edit script, with its arity --
# the same agreement the verb checks above make, for the other half of what is
# emitted. A statement machotool does not know is a script that fails to parse,
# which is a worse failure than a verb that does not exist: it happens after
# the wrapper has already told the caller what it was about to run.
stmtcheck() {   # stmtcheck <kind> <op> <nargs>
    if grep -qxF "statement $1 $2 $3" "$T/caps"; then
        pass=$((pass + 1))
    else
        printf 'FAIL caps-statement-%s-%s: this build does not advertise it taking %s argument(s)\n' \
            "$1" "$2" "$3" >&2
        fail=$((fail + 1))
    fi
}
stmtcheck load-command delete 1
stmtcheck version-min set 1
stmtcheck swift-abi set 1
stmtcheck fixups set 1
stmtcheck dylib replace 2
stmtcheck dylib delete 1
stmtcheck dylib reexport 1
stmtcheck dylib append 1
stmtcheck dylib insert 1
stmtcheck rpath replace 2
stmtcheck rpath delete 1
stmtcheck rpath append 1
stmtcheck segment rename 2

# ---- POSIX sh, not bash -------------------------------------------------
#
# These wrappers run on 10.9, whose /bin/sh is bash 3.2 in sh mode -- which
# still accepts plenty that a stricter POSIX shell does not. Re-run one
# translation under ksh, which is present on 10.9 too and does not share
# bash's extensions, so a bashism that slips in fails here rather than on
# somebody's machine.
if [ -x /bin/ksh ]; then
    got=$( /bin/ksh "$TR" change_dylib f -strip-lc uuid -change A B -add-rpath R 2>&1 )
    want="printf 'load-command delete uuid\ndylib replace A B\nrpath append R\n' | machotool f f.new
mv -f f.new f"
    if [ "$got" = "$want" ]; then
        pass=$((pass + 1))
    else
        printf 'FAIL ksh: translate.sh does not run the same under ksh\n  got: %s\n' "$got" >&2
        fail=$((fail + 1))
    fi
else
    # SAY SO. A silently-absent check reads as a passing one: the total just
    # drops by one and nothing tells you which shell went unexercised.
    echo "translate_test: SKIP the second-shell cross-check -- /bin/ksh is not present on this host"
fi

echo "translate_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
