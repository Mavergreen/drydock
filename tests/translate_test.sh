#!/bin/sh
# tests/translate_test.sh -- one test per translation, asserting the EXACT
# text compat/translate.sh emits: a `printf ... | drydock-macho-rewrite FILE OUT`
# pipeline, statements and quoting included, plus the `mv` install line the
# teaching form ends with.
#
#   sh tests/translate_test.sh <bindir>
#
# Every line compat/translate.sh prints is a CLAIM that an old-grammar
# invocation and a drydock-macho-rewrite one mean the same thing. docs/PROPOSAL.md rejected
# the old spellings as drydock-macho-rewrite synonyms on purpose, "because they would
# advertise an interchangeability that does not exist, on exactly the binaries
# where it does not hold" -- so each claim gets a test, and the test pins the
# whole command line, not just that something was printed. A translation that
# emitted `dylib -append` where `-insert` was meant would still "work" and
# would still be wrong (an appended LC_LOAD_DYLIB gets the highest library
# ordinal; an inserted one gets ordinal 1).
#
# WHAT THIS DOES NOT DO: it never runs drydock-macho-rewrite on a file. Whether the emitted
# commands PRODUCE the same bytes as the old tool is a different question, and
# tests/compat-sweep.sh answers it over 1200 combinations against real
# binaries. This test is about the text.
#
# The bindir is used for exactly one thing: `drydock-macho-rewrite --capabilities`.
# docs/PROPOSAL.md's "Migration" section says that probe exists so the wrapper and the binary need
# not move in lockstep, and the last check below is what actually uses it --
# every verb, op and KIND this translator can emit has to be one this build
# advertises. Hardcoding that agreement instead of checking it is how the
# ops=/kinds= lists in cli/drydock-macho-rewrite.c drifted from their own parsers once already.
set -u

BIN="${1:?usage: translate_test.sh <bindir>}"
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
TR="$ROOT/compat/translate.sh"
[ -r "$TR" ] || { echo "translate_test: $TR missing" >&2; exit 1; }
[ -x "$BIN/drydock-macho-rewrite" ] || { echo "translate_test: $BIN/drydock-macho-rewrite missing" >&2; exit 1; }

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
ok cd-change    "printf 'allow-unmatched\ndylib replace OLD NEW\n' | drydock-macho-rewrite f f.new
mv -f f.new f"        -- change_dylib f -change OLD NEW
ok cd-delete    "printf 'allow-unmatched\ndylib delete P\n' | drydock-macho-rewrite f f.new
mv -f f.new f"               -- change_dylib f -delete P
ok cd-reexport  "printf 'allow-unmatched\ndylib reexport P\n' | drydock-macho-rewrite f f.new
mv -f f.new f"             -- change_dylib f -reexport P
ok cd-add       "printf 'allow-unmatched\ndylib append P\n' | drydock-macho-rewrite f f.new
mv -f f.new f"               -- change_dylib f -add P
ok cd-insert    "printf 'allow-unmatched\ndylib insert P\n' | drydock-macho-rewrite f f.new
mv -f f.new f"               -- change_dylib f -insert P
ok cd-rchange   "printf 'allow-unmatched\nrpath replace OLD NEW\n' | drydock-macho-rewrite f f.new
mv -f f.new f"        -- change_dylib f -change-rpath OLD NEW
ok cd-rdelete   "printf 'allow-unmatched\nrpath delete P\n' | drydock-macho-rewrite f f.new
mv -f f.new f"               -- change_dylib f -delete-rpath P
ok cd-radd      "printf 'allow-unmatched\nrpath append P\n' | drydock-macho-rewrite f f.new
mv -f f.new f"               -- change_dylib f -add-rpath P
ok cd-strip     "printf 'allow-unmatched\nload-command delete uuid\n' | drydock-macho-rewrite f f.new
mv -f f.new f"               -- change_dylib f -strip-lc uuid
ok cd-grow      "printf 'allow-unmatched\ndylib append P\n' | drydock-macho-rewrite f f.new
mv -f f.new f"  -- change_dylib f -grow -add P

# -add is NOT -insert and -insert is NOT -add: an appended LC_LOAD_DYLIB gets
# the highest library ordinal, an inserted one gets ordinal 1. Asserting the
# pair together is what would catch a translation that silently downgraded one
# to the other.
ok cd-add-vs-insert "printf 'allow-unmatched\ndylib append A\ndylib insert B\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -add A -insert B

# Every -strip-lc KIND, since the vocabulary is a table and a table can lose a
# row. These are change_dylib's own five, from src/lc_kinds.c.
ok cd-kind-uuid     "printf 'allow-unmatched\nload-command delete uuid\n' | drydock-macho-rewrite f f.new
mv -f f.new f"           -- change_dylib f -strip-lc uuid
ok cd-kind-codesig  "printf 'allow-unmatched\nload-command delete codesig\n' | drydock-macho-rewrite f f.new
mv -f f.new f"        -- change_dylib f -strip-lc codesig
ok cd-kind-srcver   "printf 'allow-unmatched\nload-command delete source-version\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -strip-lc source-version
ok cd-kind-buildver "printf 'allow-unmatched\nload-command delete build-version\n' | drydock-macho-rewrite f f.new
mv -f f.new f"  -- change_dylib f -strip-lc build-version
ok cd-kind-drs      "printf 'allow-unmatched\nload-command delete code-sign-drs\n' | drydock-macho-rewrite f f.new
mv -f f.new f"  -- change_dylib f -strip-lc code-sign-drs

# Repeats accumulate into ONE command, in the order typed -- not one command
# per operation. Order between statements is meaningful to the rewriter.
ok cd-repeat "printf 'allow-unmatched\ndylib replace A B\ndylib replace C D\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -change A B -change C D
ok cd-strip-repeat "printf 'allow-unmatched\nload-command delete uuid\nload-command delete codesig\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -strip-lc uuid -strip-lc codesig

# ---- change_dylib: several operations, still ONE command -----------------
#
# Whatever an old invocation asks for, it becomes one `printf ... | drydock-macho-rewrite
# FILE OUT` with the operations as statements on stdin -- one read, one pass
# per statement, one write, which is the shape the C tool had and a sequence
# of commands did not. The teaching form's trailing `mv` is the install step
# every in-place tool's form ends with.
#
# The order is load-command, then dylib, then rpath: deleting load commands
# hands header pad back, and the other two consume it. Getting this backwards
# is how a mixed invocation that used to fit stops fitting.
ok cd-mixed-2 "printf 'allow-unmatched\nload-command delete uuid\ndylib replace A B\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -strip-lc uuid -change A B

ok cd-mixed-3 "printf 'allow-unmatched\nload-command delete uuid\ndylib append D\nrpath append R\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -add-rpath R -add D -strip-lc uuid

# The ORDER OF THE FLAGS does not change the order of the statements between
# families -- only the order within each family's own block.
ok cd-mixed-order "printf 'allow-unmatched\nload-command delete codesig\nload-command delete uuid\ndylib replace A B\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -change A B -strip-lc codesig -strip-lc uuid

# -grow is accepted and emits nothing: a statement that outgrows the pad
# grows it with or without it, so the command is the one the same flags
# without -grow produce.
ok cd-grow-mixed "printf 'allow-unmatched\nload-command delete uuid\ndylib replace A B\nrpath append R\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -grow -strip-lc uuid -change A B -add-rpath R
ok cd-nogrow-mixed "printf 'allow-unmatched\nload-command delete uuid\ndylib replace A B\nrpath append R\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -strip-lc uuid -change A B -add-rpath R

# EVERY INSERT IS EMITTED IN REVERSE FLAG ORDER, because each one goes to the
# FRONT of the table: as a batch `-insert A -insert B` leaves A at ordinal 1
# and B at 2, and a sequence reproduces that only by inserting B first. This
# is the assertion that catches the emission getting it the natural way round.
# tests/wrapper_test.sh asserts the resulting ordinals on a real binary.
ok cd-insert-reverse "printf 'allow-unmatched\nload-command delete uuid\ndylib insert B\ndylib insert A\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -insert A -insert B -strip-lc uuid

# ---- conflicts resolve in the order written -----------------------------
#
# Two operations naming the same path apply one after the other, exactly as
# typed. That is the whole rule, and it is the same rule whether the invocation
# touches one family or three.
#
# IT IS A RULING, NOT A REPRODUCTION, and it had to be: the pre-migration
# wrappers did not have one rule. One family emitted a VERB -- one mr_ops,
# applied as a batch, with mr_is_deleted's delete-wins precedence -- and more
# than one emitted a SCRIPT, a sequence. The same conflict got two different
# answers depending on whether an unrelated flag from another family happened
# to be present.
#
# Every assertion below is a shape whose OUTCOME moved, measured against the
# pre-migration binaries. The emitted text is pinned here; the resulting bytes
# are pinned in tests/wrapper_test.sh's "conflicts resolve in the order
# written" block. Each is stated in its NEW form, so the next reader finds a
# decision rather than a surprise.

# A -delete no longer beats a -change written before it: the rename happens,
# then the delete finds nothing. Both orders, because only the first moved.
ok cd-change-then-delete "printf 'allow-unmatched\ndylib replace P Q\ndylib delete P\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -change P Q -delete P
ok cd-delete-then-change "printf 'allow-unmatched\ndylib delete P\ndylib replace P Q\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -delete P -change P Q

# A -reexport and a -change on one path both apply, in order.
ok cd-reexport-then-change "printf 'allow-unmatched\ndylib reexport P\ndylib replace P Q\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -reexport P -change P Q
ok cd-change-then-reexport "printf 'allow-unmatched\ndylib replace P Q\ndylib reexport P\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -change P Q -reexport P
ok cd-reexport-then-delete "printf 'allow-unmatched\ndylib reexport P\ndylib delete P\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -reexport P -delete P

# Two -changes naming the same old path: the first renames it, so the second
# matches nothing. Emitted anyway -- dropping it would be the translator
# deciding, which is the job it no longer has.
ok cd-dup-replace "printf 'allow-unmatched\ndylib replace P Q\ndylib replace P Z\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -change P Q -change P Z
ok fm-dup-replace "printf 'allow-unmatched\ndylib replace P Q\ndylib replace P Z\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- fix_macho f -change P Q -change P Z

# The rpath spellings, which now read exactly like the dylib ones. They did
# not before: the single-family form went through a verb with no delete-wins
# rule while the multi-family form hoisted the delete.
ok cd-rpath-change-then-delete "printf 'allow-unmatched\nrpath replace X Y\nrpath delete X\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -change-rpath X Y -delete-rpath X
ok cd-rpath-delete-then-change "printf 'allow-unmatched\nrpath delete X\nrpath replace X Y\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -delete-rpath X -change-rpath X Y
ok cd-rpath-dup "printf 'allow-unmatched\nrpath replace X Y\nrpath replace X Z\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -change-rpath X Y -change-rpath X Z

# ADDING AN UNRELATED FLAG FROM ANOTHER FAMILY CHANGES NOTHING about how the
# conflict resolves. On the parent it decided everything, because it decided
# which code path ran. These four are the same conflicts as above with a
# -strip-lc in front, and they emit the same statements in the same order.
ok cd-mf-change-then-delete "printf 'allow-unmatched\nload-command delete uuid\ndylib replace P Q\ndylib delete P\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -strip-lc uuid -change P Q -delete P
ok cd-mf-change-then-reexport "printf 'allow-unmatched\nload-command delete uuid\ndylib replace P Q\ndylib reexport P\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -strip-lc uuid -change P Q -reexport P
ok cd-mf-rpath-change-then-delete "printf 'allow-unmatched\nload-command delete uuid\nrpath replace X Y\nrpath delete X\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -strip-lc uuid -change-rpath X Y -delete-rpath X
# ... and a -strip-lc written BETWEEN the two conflicting flags still lands
# first, because a load-command delete hands header pad back and everything
# else may need the room. Flag order governs the conflict, not the emission
# of unrelated families.
ok cd-mf-lc-between "printf 'allow-unmatched\nload-command delete uuid\ndylib replace P Q\ndylib delete P\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -change P Q -strip-lc uuid -delete P

# BOTH FAMILIES CONFLICTING AT ONCE, and the two resolutions do not interact:
# each family's statements come out in its own flag order.
ok cd-mf-both-conflict "printf 'allow-unmatched\ndylib replace A Q\ndylib delete A\nrpath replace X Y\nrpath delete X\n' | drydock-macho-rewrite f f.new
mv -f f.new f" \
    -- change_dylib f -change A Q -delete A -change-rpath X Y -delete-rpath X
# ... and INTERLEAVING the flags across families changes nothing: each family
# keeps the relative order of ITS OWN flags, which is what "the order written"
# means when two families are being written at once.
ok cd-mf-interleaved "printf 'allow-unmatched\ndylib replace A Q\ndylib delete A\nrpath replace X Y\nrpath delete X\n' | drydock-macho-rewrite f f.new
mv -f f.new f" \
    -- change_dylib f -change A Q -change-rpath X Y -delete A -delete-rpath X
# A dylib conflict with an unrelated RPATH operation present -- the other half
# of "an unrelated flag from another family decides nothing", where the flag is
# a real rewrite rather than a -strip-lc.
ok cd-mf-dylib-conflict-rpath-op "printf 'allow-unmatched\ndylib replace A Q\ndylib delete A\nrpath replace X Y\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -change A Q -delete A -change-rpath X Y

# A CHAIN IS JUST A SEQUENCE NOW, and these assertions used to be refusals.
# `-change a b -change b c` renames the a's to b, then those b's to c. No
# emission order reproduces what one batch did with it, which is why it was
# refused while reproduction was the goal; reproduction is not the goal.
ok cd-chain "printf 'allow-unmatched\ndylib replace a b\ndylib replace b c\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -change a b -change b c
ok cd-chain-lc "printf 'allow-unmatched\nload-command delete uuid\ndylib replace a b\ndylib replace b c\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -change a b -change b c -strip-lc uuid
ok cd-chain-3 "printf 'allow-unmatched\ndylib replace a b\ndylib replace b c\ndylib replace c d\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -change a b -change b c -change c d
# A SWAP too: b becomes a, then every a -- including the ones the first
# statement just made -- becomes b.
ok cd-swap "printf 'allow-unmatched\ndylib replace a b\ndylib replace b a\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -change a b -change b a
# An rpath SWAP, which returns the rpath to the name it started with.
ok cd-rpath-swap "printf 'allow-unmatched\nrpath replace a b\nrpath replace b a\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -change-rpath a b -change-rpath b a
# The rpath chain, which is the one the re-review found was STILL refused
# after the previous round.
ok cd-rpath-chain "printf 'allow-unmatched\nrpath replace a b\nrpath replace b c\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -change-rpath a b -change-rpath b c
ok cd-rpath-chain-lc "printf 'allow-unmatched\nload-command delete uuid\nrpath replace a b\nrpath replace b c\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -strip-lc uuid -change-rpath a b -change-rpath b c
# ... and fix_macho's -change, on the same rule.
ok fm-chain "printf 'allow-unmatched\ndylib replace a b\ndylib replace b c\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- fix_macho f -change a b -change b c
ok fm-chain-lc "printf 'allow-unmatched\nload-command delete build-version\ndylib replace a b\ndylib replace b c\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- fix_macho f -change a b -change b c -strip_build_version

# install.sh's production line -- the single most important translation
# here, in the shape mavericksforever.com/claude/install.sh runs it.
ok cd-production "printf 'allow-unmatched\nload-command delete uuid\nload-command delete codesig\ndylib replace /usr/lib/libSystem.B.dylib @loader_path/../S.dylib\ndylib replace /usr/lib/libicucore.A.dylib @loader_path/../I.dylib\ndylib replace /usr/lib/libc++.1.dylib @loader_path/../c++.1.dylib\n' | drydock-macho-rewrite /tmp/c /tmp/c.new
mv -f /tmp/c.new /tmp/c" \
    -- change_dylib /tmp/c -strip-lc uuid -strip-lc codesig \
        -change /usr/lib/libSystem.B.dylib @loader_path/../S.dylib \
        -change /usr/lib/libicucore.A.dylib @loader_path/../I.dylib \
        -change /usr/lib/libc++.1.dylib @loader_path/../c++.1.dylib

# tests/characterize.sh's line, this repo's own CI equivalence gate.
ok cd-characterize "printf 'allow-unmatched\nload-command delete uuid\nload-command delete codesig\ndylib replace /usr/lib/libSystem.B.dylib @loader_path/../S.dylib\n' | drydock-macho-rewrite out out.new
mv -f out.new out" \
    -- change_dylib out -strip-lc uuid -strip-lc codesig \
        -change /usr/lib/libSystem.B.dylib @loader_path/../S.dylib

# `-grow` with no operation at all: change_dylib accepts it (once argc is big
# enough) and changes nothing, so the translation is deliberately EMPTY rather
# than some adjacent command. Empty stdout with exit 0 is the contract for
# "the old invocation was a no-op".
ok cd-grow-only '' -- change_dylib f -grow -grow

# ---- fix_macho ----------------------------------------------------------
ok fm-change   "printf 'allow-unmatched\ndylib replace OLD NEW\n' | drydock-macho-rewrite f f.new
mv -f f.new f"         -- fix_macho f -change OLD NEW
ok fm-stripbv  "printf 'allow-unmatched\nload-command delete build-version\n' | drydock-macho-rewrite f f.new
mv -f f.new f"       -- fix_macho f -strip_build_version
# -rename_seg is accepted by fix_macho's parser and appears NOWHERE in its
# usage text. Enumerating from the parser is what found it.
ok fm-rename   "printf 'allow-unmatched\nsegment rename __DATA __D2\n' | drydock-macho-rewrite f f.new
mv -f f.new f"            -- fix_macho f -rename_seg __DATA __D2
# One rename statement is one pass, so two renames are two statements in the
# one command. Each rename is still its own pass, in argv order.
ok fm-rename-2 "printf 'allow-unmatched\nsegment rename __A __B\nsegment rename __C __D\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- fix_macho f -rename_seg __A __B -rename_seg __C __D
# All three families, in load-command / dylib / segment order.
ok fm-all "printf 'allow-unmatched\nload-command delete build-version\ndylib replace A B\nsegment rename __A __B\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- fix_macho f -change A B -strip_build_version -rename_seg __A __B
# The flag is a boolean, so repeating it is still one load-command delete.
ok fm-stripbv-twice "printf 'allow-unmatched\nload-command delete build-version\n' | drydock-macho-rewrite f f.new
mv -f f.new f" \
    -- fix_macho f -strip_build_version -strip_build_version

# CHAINED -rename_seg TRANSLATES, and these three assertions USED TO BE
# `refuses ... 2 ...`. compat/translate.sh refused the shape while
# compat/fix_macho.c still shipped, because a wrapper had to preserve that
# tool's answer and the two differ: fix_macho gave each segment its FIRST
# matching pair and never revisited it, so `-rename_seg A B -rename_seg B C`
# ended at B, while two drydock-macho-rewrite segment passes chain and end at C. The repo
# owner has since ruled that difference an improvement to ADOPT -- "doing what
# was asked" -- and the C tool is gone, so there is no longer a second answer
# to preserve. These now pin the translation, in the same place they used to
# pin the refusal; compat/translate.sh's -rename_seg arm records the reversal.
ok fm-chain "printf 'allow-unmatched\nsegment rename __DATA __X\nsegment rename __X __Y\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- fix_macho f -rename_seg __DATA __X -rename_seg __X __Y
# A chain of three emits three passes, in argv order -- every link, not just
# the first (which is where the refusal used to trip).
ok fm-chain-3 "printf 'allow-unmatched\nsegment rename __DATA __P\nsegment rename __P __Q\nsegment rename __Q __R\n' | drydock-macho-rewrite f f.new
mv -f f.new f" \
    -- fix_macho f -rename_seg __DATA __P -rename_seg __P __Q -rename_seg __Q __R
# The empty string is a legal NEW -- a segname may be all NULs -- and it stays
# an argument rather than vanishing: mt_quote emits it as '' so the emitted
# line still has four words after the verb. That is what the old chain check's
# own regression case was really about (an empty NEW that field-splitting
# silently dropped), and it is still worth pinning now that the check is gone.
# mt_quote's '' is also exactly what src/script.c's ms_split reads back as an
# empty field, so the statement still has four words.
ok fm-chain-empty "printf 'allow-unmatched\nsegment rename __DATA '\\'''\\''\nsegment rename '\\'''\\'' __Y\n' | drydock-macho-rewrite f f.new
mv -f f.new f" \
    -- fix_macho f -rename_seg __DATA '' -rename_seg '' __Y
# The three shapes that were never affected by that refusal, and are not
# affected by its removal either. Each was measured against the real fix_macho
# on tests/fixture.macho and agreed byte-for-byte with its translation.
#
# NOTE nothing here is refused at all any more, in any family: the -change
# chain check that once watched for this shape (and never watched -rename_seg)
# is gone with the rest of the reproduction machinery. Renames sequence, and
# always did.
ok fm-same-old "printf 'allow-unmatched\nsegment rename __DATA __A\nsegment rename __DATA __B\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- fix_macho f -rename_seg __DATA __A -rename_seg __DATA __B
ok fm-new-eq-earlier-old "printf 'allow-unmatched\nsegment rename __DATA __B\nsegment rename __TEXT __DATA\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- fix_macho f -rename_seg __DATA __B -rename_seg __TEXT __DATA
ok fm-independent "printf 'allow-unmatched\nsegment rename __DATA __A\nsegment rename __TEXT __B\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- fix_macho f -rename_seg __DATA __A -rename_seg __TEXT __B

# ---- the four fixed-arity tools -----------------------------------------
# drydock-macho-rewrite never writes its input, so the teaching form names an output of its
# own and ends with the install step -- two lines, and both of them pinned:
# what a reader is shown has to be the complete equivalent of the old in-place
# edit, not the half of it that rewrites nothing.
ok avm     "printf 'version-min set 10.9\n' | drydock-macho-rewrite f f.new
mv -f f.new f"                               -- add_version_min f
# MT_OUT is how a wrapper names the temp it is going to install: the command
# writes exactly that, and the `mv` disappears because the wrapper does the
# installing itself.
mt_out_got=$( MT_OUT=/tmp/t.tmp /bin/sh "$TR" add_version_min f )
if [ "$mt_out_got" = "printf 'version-min set 10.9\n' | drydock-macho-rewrite f /tmp/t.tmp" ]; then
    pass=$((pass + 1))
else
    printf 'FAIL avm-mt-out: got %s\n' "$mt_out_got" >&2; fail=$((fail + 1))
fi
# patch_macho is the one tool whose grammar always named its own output, so the
# teaching form is the command the user typed -- there is nothing to install.
ok pm      "printf 'fixups set classic\n' | drydock-macho-rewrite in out"        -- patch_macho in out
# ... EXCEPT when IN and OUT are the same file, which patch_macho allowed and
# drydock-macho-rewrite now refuses. The teaching form has to be a pasteable equivalent of
# that in-place conversion, so it names an output of its own and installs it,
# exactly as the five in-place tools' forms do.
ok pm-same "printf 'fixups set classic\n' | drydock-macho-rewrite f f.new
mv -f f.new f"                               -- patch_macho f f
# MT_OUT is how the wrapper names the temp it installs onto the user's OUT --
# for both shapes, since the wrapper installs onto OUT either way.
mt_out_got=$( MT_OUT=/tmp/t.tmp /bin/sh "$TR" patch_macho in out )
if [ "$mt_out_got" = "printf 'fixups set classic\n' | drydock-macho-rewrite in /tmp/t.tmp" ]; then
    pass=$((pass + 1))
else
    printf 'FAIL pm-mt-out: got %s\n' "$mt_out_got" >&2; fail=$((fail + 1))
fi
mt_out_got=$( MT_OUT=/tmp/t.tmp /bin/sh "$TR" patch_macho f f )
if [ "$mt_out_got" = "printf 'fixups set classic\n' | drydock-macho-rewrite f /tmp/t.tmp" ]; then
    pass=$((pass + 1))
else
    printf 'FAIL pm-mt-out-same: got %s\n' "$mt_out_got" >&2; fail=$((fail + 1))
fi
ok rs      "printf 'segment rename __DATA __DATA2\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- rename_segment f __DATA __DATA2
ok rs-16   "printf 'segment rename __DATA 1234567890123456\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- rename_segment f __DATA 1234567890123456
# retag_swift_classes is variadic over FILES; one command names one FILE and
# one OUT, so the translation is a loop, one command per file, in argv order.
# Each file, like add_version_min's, gets its own output and install step.
ok rsc-1 "printf 'swift-abi set legacy\n' | drydock-macho-rewrite a a.new
mv -f a.new a"                                                    -- retag_swift_classes a
ok rsc-3 "printf 'swift-abi set legacy\n' | drydock-macho-rewrite a a.new
mv -f a.new a
printf 'swift-abi set legacy\n' | drydock-macho-rewrite b b.new
mv -f b.new b
printf 'swift-abi set legacy\n' | drydock-macho-rewrite c c.new
mv -f c.new c" -- retag_swift_classes a b c
# MT_OUT names a single output for the whole call, so it only makes sense set
# when retranslating ONE file at a time -- retag_swift_classes.sh's own loop.
rsc_out_got=$( MT_OUT=/tmp/t.tmp /bin/sh "$TR" retag_swift_classes a )
if [ "$rsc_out_got" = "printf 'swift-abi set legacy\n' | drydock-macho-rewrite a /tmp/t.tmp" ]; then
    pass=$((pass + 1))
else
    printf 'FAIL rsc-mt-out: got %s\n' "$rsc_out_got" >&2; fail=$((fail + 1))
fi

# ---- insert_dylib ---------------------------------------------------------
#
# NOT one of the six -- see compat/translate.sh's own "insert_dylib" section.
# An explicit new_binary_path keeps OUT deterministic for the plain mapping
# cases, the same way `pm`'s explicit "in out" above does.
ok id-append "printf 'allow-unmatched\ndylib append P\n' | drydock-macho-rewrite bin out"          -- insert_dylib P bin out
ok id-weak   "printf 'allow-unmatched\ndylib append P\ndylib retype P weak\n' | drydock-macho-rewrite bin out" \
                                                                           -- insert_dylib --weak P bin out
ok id-strip  "printf 'allow-unmatched\ndylib append P\nload-command delete codesig\n' | drydock-macho-rewrite bin out" \
                                                                           -- insert_dylib --strip-codesig P bin out
ok id-nostrip "printf 'allow-unmatched\ndylib append P\n' | drydock-macho-rewrite bin out"         -- insert_dylib --no-strip-codesig P bin out
ok id-weak-strip "printf 'allow-unmatched\ndylib append P\ndylib retype P weak\nload-command delete codesig\n' | drydock-macho-rewrite bin out" \
                                                                           -- insert_dylib --weak --strip-codesig P bin out

# No new_binary_path and no --inplace: the fork's own default, OUT =
# "<binary_path>_patched" -- a file of its own, so (unlike the six in-place
# tools) there is no install line to append.
ok id-default "printf 'allow-unmatched\ndylib append P\n' | drydock-macho-rewrite bin bin_patched" -- insert_dylib P bin

# --inplace: OUT is BIN itself, which drydock-macho-rewrite refuses to write straight
# to -- the same OUT-plus-install treatment patch_macho's `pm-same` gets,
# above.
ok id-inplace "printf 'allow-unmatched\ndylib append P\n' | drydock-macho-rewrite bin bin.new
mv -f bin.new bin" -- insert_dylib --inplace P bin

# MT_OUT is the wrapper's own temp, for both the default-output shape and the
# --inplace one -- same shape MT_OUT always produces, since a wrapper always
# writes its own temp directly and installs it itself, regardless of what OUT
# a teaching form would have shown.
id_out_got=$( MT_OUT=/tmp/t.tmp /bin/sh "$TR" insert_dylib P bin )
if [ "$id_out_got" = "printf 'allow-unmatched\ndylib append P\n' | drydock-macho-rewrite bin /tmp/t.tmp" ]; then
    pass=$((pass + 1))
else
    printf 'FAIL id-mt-out: got %s\n' "$id_out_got" >&2; fail=$((fail + 1))
fi
id_out_got=$( MT_OUT=/tmp/t.tmp /bin/sh "$TR" insert_dylib --inplace P bin )
if [ "$id_out_got" = "printf 'allow-unmatched\ndylib append P\n' | drydock-macho-rewrite bin /tmp/t.tmp" ]; then
    pass=$((pass + 1))
else
    printf 'FAIL id-mt-out-inplace: got %s\n' "$id_out_got" >&2; fail=$((fail + 1))
fi

# mt_id_parse's own validation, refused before any statement is built --
# matching every other tool's usage/bad-arg cases above.
ID_USAGE='usage: insert_dylib [--inplace] [--weak] [--overwrite] [--strip-codesig] [--no-strip-codesig] [--all-yes] dylib_path binary_path [new_binary_path]'
refuses id-usage-0 1 "$ID_USAGE" -- insert_dylib
refuses id-usage-1 1 "$ID_USAGE" -- insert_dylib onlyone
refuses id-usage-4 1 "$ID_USAGE" -- insert_dylib d b n extra
refuses id-mutex 1 'insert_dylib: --strip-codesig and --no-strip-codesig are mutually exclusive' \
    -- insert_dylib --strip-codesig --no-strip-codesig d b
refuses id-unknown 1 'insert_dylib: unknown option --bogus' -- insert_dylib --bogus d b

# ---- allow-unmatched: exactly the three upstreams that exited 0 on a miss -
au_case() {   # au_case NAME want(yes/no) -- TOOL ARG...
    au_name=$1; au_want=$2; shift 3
    au_got=$( /bin/sh "$TR" "$@" 2>"$T/err" ); au_rc=$?
    # An empty translation would pass the "no" half vacuously.
    if [ "$au_rc" -ne 0 ] || [ -z "$au_got" ]; then
        printf 'FAIL %s: produced no translation at all (exit %d, stderr: %s) -- cannot tell whether it asks for allow-unmatched\n' \
            "$au_name" "$au_rc" "$(cat "$T/err")" >&2
        fail=$((fail + 1)); return 0
    fi
    if printf '%s\n' "$au_got" | grep -q 'allow-unmatched'; then au_has=yes; else au_has=no; fi
    if [ "$au_has" = "$au_want" ]; then
        pass=$((pass + 1))
    else
        printf 'FAIL %s: allow-unmatched present=%s, want %s\n  got: %s\n' \
            "$au_name" "$au_has" "$au_want" "$au_got" >&2
        fail=$((fail + 1))
    fi
}

au_case au-change_dylib yes -- change_dylib f -change /nope/libx.dylib /also/nope.dylib
au_case au-fix_macho    yes -- fix_macho f -change /nope/libx.dylib /also/nope.dylib
au_case au-insert_dylib yes -- insert_dylib --strip-codesig /nope/libx.dylib bin out

au_case na-patch_macho         no -- patch_macho in out
au_case na-add_version_min     no -- add_version_min f
au_case na-rename_segment      no -- rename_segment f __DATA __DATB
au_case na-retag_swift_classes no -- retag_swift_classes f

# ---- quoting ------------------------------------------------------------
#
# Each emitted line has to be eval-safe, because that is how a wrapper runs it.
# Quote only what needs quoting, so the common case stays readable. There are
# TWO surfaces now, not one: FILE and OUT are ordinary command arguments, and
# the statements are the `printf` FORMAT -- which printf itself rewrites, so a
# `%` or a `\` in a path has to arrive doubled.
ok q-space "printf 'segment rename __DATA __D2\n' | drydock-macho-rewrite 'a b' 'a b.new'
mv -f 'a b.new' 'a b'"      -- rename_segment 'a b' __DATA __D2
ok q-quote "printf 'fixups set classic\n' | drydock-macho-rewrite 'it'\\''s' out"  -- patch_macho "it's" out
ok q-empty "printf 'segment rename __DATA '\\'''\\''\n' | drydock-macho-rewrite f f.new
mv -f f.new f"            -- rename_segment f __DATA ''
ok q-percent "printf 'allow-unmatched\ndylib append a%%sb\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -add 'a%sb'
ok q-backslash "printf 'allow-unmatched\ndylib append '\\''back\\\\slash/f'\\''\n' | drydock-macho-rewrite f f.new
mv -f f.new f" -- change_dylib f -add 'back\slash/f'

# ... and RUNNING the emitted pipeline really does hand drydock-macho-rewrite the path the
# caller named. `drydock-macho-rewrite` is shadowed by a stub that saves the statement
# it is given on stdin; the statement is then split the way src/script.c's
# ms_split splits it (whitespace separates, '...' is literal), which is the
# equivalence compat/translate.sh's quoting section claims. A `%`, a `\` or a
# `'` that did not survive shows up here as a path that came back different.
q_roundtrip() {   # q_roundtrip NAME PATH
    q_name=$1; q_want=$2
    q_line=$( MT_OUT=/tmp/t.tmp /bin/sh "$TR" change_dylib f -add "$q_want" )
    # platform: POSIX sh accepts no '-' in a function name, so the shadow is a
    # stub on PATH, visible only to this eval's subshell.
    mkdir -p "$T/qstub"
    printf '#!/bin/sh\ncat > "%s/stmt"\n' "$T" > "$T/qstub/drydock-macho-rewrite"
    chmod +x "$T/qstub/drydock-macho-rewrite"
    rm -f "$T/stmt"
    ( PATH="$T/qstub:$PATH"; eval "$q_line" )
    # Line 1 is the directive; the statement under test is line 2.
    q_dir_line=$(sed -n '1p' "$T/stmt")
    set --; eval "set -- $(sed -n '2p' "$T/stmt")"
    q_got=${3:-}
    if [ "$q_got" = "$q_want" ] && [ "$q_dir_line" = allow-unmatched ] \
        && [ "${1:-}" = dylib ] && [ "${2:-}" = append ]; then
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

# ---- a FILE beginning with '-' ------------------------------------------
# drydock-macho-rewrite refuses an OUT beginning with '-', so the teaching
# form names ./-FILE.new.
ok cd-dash-file "printf 'allow-unmatched\ndylib delete P\n' | drydock-macho-rewrite -f ./-f.new
mv -f ./-f.new -f" -- change_dylib -f -delete P

# ---- MT_PROG is recomputed on every call --------------------------------
# One sourced shell translating two tools names each in its usage line.
got=$( MT_SOURCED=1 /bin/sh -c '. "$1"; mt_translate change_dylib x 2>/dev/null; mt_translate patch_macho 2>&1' sh "$TR" )
if [ "$got" = "Usage: patch_macho input output" ]; then
    pass=$((pass + 1))
else
    printf 'FAIL mt-prog-per-call: got %s\n' "$got" >&2; fail=$((fail + 1))
fi

# ---- DRYDOCK_MACHO_REWRITE names the program word ------------------------
got=$( DRYDOCK_MACHO_REWRITE=/opt/bin/drydock-macho-rewrite /bin/sh "$TR" add_version_min f )
if [ "$got" = "printf 'version-min set 10.9\n' | /opt/bin/drydock-macho-rewrite f f.new
mv -f f.new f" ]; then
    pass=$((pass + 1))
else
    printf 'FAIL drydock-macho-rewrite-env: got %s\n' "$got" >&2; fail=$((fail + 1))
fi

# ---- refusals: the old tool's own message, verbatim ---------------------
#
# Every one of these is a case the OLD tool refused. The translation must
# refuse identically, print nothing on stdout, and use the ORIGIN wording --
# for the capacity caps that is deliberate, because cli/drydock-macho-rewrite.c
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

# THIS FILE NOW REFUSES NOTHING OF ITS OWN, and this comment is where six
# `refuses` assertions used to be: a -change chain and a swap, in both
# families, in both wrappers. They existed because a sequence of statements
# gave a different answer than one batch, and while REPRODUCING the batch was
# the goal, emitting the sequence anyway would have been the "plausible-looking
# command that would do something else" this translator exists not to emit.
#
# Reproduction is no longer the goal -- conflicts resolve in the order written
# -- so a chain is simply a sequence and there is nothing to refuse. The
# assertions moved rather than died: they are `ok` cases in the "conflicts
# resolve in the order written" section above, stated in their new form. Every
# refusal left in this file is one the OLD TOOL ITSELF made.
#
# A -change whose NEW is its OWN old was never a chain, and is unaffected.
# And a -change whose NEW is its OWN old is not a chain: no OTHER statement
# rewrites what it produced, so a statement and a batch agree.
ok cd-self-replace "printf 'allow-unmatched\nload-command delete uuid\ndylib replace a a\ndylib replace c d\n' | drydock-macho-rewrite f f.new
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
    'translate.sh: no equivalent -- unknown tool otool (expected one of: change_dylib add_version_min patch_macho rename_segment retag_swift_classes fix_macho insert_dylib)' \
    -- otool -L f

# ---- capacity caps ------------------------------------------------------
#
# Enforced HERE, printing change_dylib's own text, because routing through
# drydock-macho-rewrite would print drydock-macho-rewrite's (which names -append where change_dylib names
# -add). Both cap sites in cli/drydock-macho-rewrite.c carry a comment saying exactly that.
mkcap() { i=0; out=''; while [ $i -lt $2 ]; do out="$out $1"; i=$((i + 1)); done; printf '%s' "$out"; }
# The same, with no separator: N copies of one statement inside a printf
# format, which is what the emitted command carries now.
mkrep() { i=0; out=''; while [ $i -lt $2 ]; do out="$out$1"; i=$((i + 1)); done; printf '%s' "$out"; }

ok cap-strip-16-fits "printf 'allow-unmatched\n$(mkrep 'load-command delete uuid\n' 16)' | drydock-macho-rewrite f f.new
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
# it, so these are that same text. The -rename_seg cap has no drydock-macho-rewrite
# counterpart at all -- a `segment rename` statement is one pair, so nothing
# downstream would ever count them -- which makes this file the only thing
# keeping that refusal alive.
# 32 pairs, 32 statements: every operation is emitted, in the order written.
# What this pins is the ACCEPTANCE at capacity -- `ok` requires exit 0, and the
# 33rd is refused just below. A check one too eager would silently halve what a
# caller can ask for, and would fail here rather than there.
ok fm-cap-change-32-fits "printf 'allow-unmatched\n$(mkrep 'dylib replace A B\n' 32)' | drydock-macho-rewrite f f.new
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
# `drydock-macho-rewrite --capabilities` is the machine-readable probe docs/PROPOSAL.md's
# "Migration" section says exists so the wrapper and the binary need not move
# in lockstep. Use it rather than assuming: every STATEMENT this translator can
# emit must be advertised with the right arity, and every -strip-lc KIND it can
# name must be one this build knows.
#
# THE VERB ROWS ARE GONE, and with them every `ops=`, `kinds=` and `versions=`
# field this block used to read. --capabilities now advertises `verify`,
# `info`, `edit` and the statement rows, and the statement rows are
# what this translator emits -- so the ops= and versions= checks have become
# the stmtcheck rows just below, which asserted the same agreement already.
#
# THE KIND VOCABULARY HAS NO ADVERTISEMENT LEFT. `kinds=` was the only place
# LC_STRIP_KINDS was published, and it lived on the `verb lc` line. So the
# agreement between MT_STRIP_KINDS and what this build accepts is asserted the
# only way still open: by handing drydock-macho-rewrite the statement and reading whether
# ms_parse knew the name. No fixture is needed -- the parse runs before FILE is
# opened, so a kind this build knows fails at the absent file ("cannot open or
# read") and one it does not fails at the parse ("unknown kind"), and the two
# are distinguishable without a Mach-O anywhere.
"$BIN/drydock-macho-rewrite" --capabilities > "$T/caps" 2>/dev/null
kindcheck() {   # kindcheck <kind> -- must be one ms_parse knows
    if printf 'load-command delete %s\n' "$1" \
        | "$BIN/drydock-macho-rewrite" "$T/no-such-fixture" "$T/no-such-out" 2>&1 \
        | grep -q "unknown kind"; then
        printf 'FAIL caps-kind-%s: this build does not accept it in a load-command delete\n' "$1" >&2
        fail=$((fail + 1))
    else
        pass=$((pass + 1))
    fi
}
# Read out of translate.sh itself rather than retyped here: the whole claim is
# that ITS frozen list and THIS build agree, and a second copy in this file
# would let both drift together.
mt_kinds=$(sed -n "s/^MT_STRIP_KINDS='\([^']*\)'.*/\1/p" "$TR")
[ -n "$mt_kinds" ] || { printf 'FAIL caps-kind: no MT_STRIP_KINDS in %s\n' "$TR" >&2; fail=$((fail + 1)); }
for mt_k in $mt_kinds; do kindcheck "$mt_k"; done
# The control, without which the loop above would pass against a parser that
# accepted every name: a kind that is in no table must still be refused.
if printf 'load-command delete not-a-real-kind\n' \
    | "$BIN/drydock-macho-rewrite" "$T/no-such-fixture" "$T/no-such-out" 2>&1 \
    | grep -q "unknown kind"; then
    pass=$((pass + 1))
else
    printf 'FAIL caps-kind-control: a kind in no table was not refused\n' >&2
    fail=$((fail + 1))
fi

# Every STATEMENT this translator can put in an edit script, with its arity.
# A statement drydock-macho-rewrite does not know is a script that fails to parse,
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
    want="printf 'allow-unmatched\nload-command delete uuid\ndylib replace A B\nrpath append R\n' | drydock-macho-rewrite f f.new
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
