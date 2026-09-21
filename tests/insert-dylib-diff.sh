#!/bin/sh
# tests/insert-dylib-diff.sh -- run compat/insert_dylib.sh against a real build
# of the fork it presents an interface for, over real Mach-O binaries, and
# prove the interface claim rather than asserting it.
#
#   sh tests/insert-dylib-diff.sh <fork-insert_dylib> <new-insert_dylib> [corpus-root...]
#
# THE PIN. This wrapper's grammar is copied from Wowfunhappy/insert_dylib at
# one exact commit -- moving it is a deliberate act, not a `git pull`: re-read
# main.c's option table and its default-output-path arithmetic first, because
# both compat/translate.sh's mt_id_out and this script's own case list are
# built from reading that commit, not from "whatever main.c says today".
FORK_COMMIT=bd221b8   # "Fixes for some executables"
#
#   git clone https://github.com/Wowfunhappy/insert_dylib /tmp/idl
#   git -C /tmp/idl checkout $FORK_COMMIT
#   clang -O2 -Wall /tmp/idl/insert_dylib/main.c -o /tmp/idl/build/insert_dylib
#   sh tests/insert-dylib-diff.sh /tmp/idl/build/insert_dylib build-native/insert_dylib /Applications
#
# The Xcode project builds too, but the source is one translation unit with no
# project-specific dependency, so a direct `clang` compile is far more likely
# to work on an old host than an old .xcodeproj is -- confirmed on this
# machine, a real 10.9.5 install.
#
# WHY THIS IS NOT A ctest, for the same reason tests/differential.sh (its
# model) is not: it needs a clone-and-build of a third-party project plus a
# corpus of real Mach-O binaries, and CI has neither.
#
# WHAT IT COMPARES -- interface behaviour ONLY: exit code, stdout SHAPE
# (empty vs non-empty, never text -- these are two independently written
# programs that will never share a vocabulary), WHICH output path each side
# actually wrote to, and whether every file either side wrote parses as a
# valid Mach-O (`drydock-macho-rewrite verify`). It does NOT compare output bytes.
# docs/prior-art.md records four checks this side makes that the fork does
# not (LC_FUNCTION_STARTS' leading delta, LC_DATA_IN_CODE contents,
# __TEXT,__unwind_info, and post-transform mg_verify/mg_plausible), and the
# fork proceeds past an unknown load command where this refuses; the fork's
# own README also says its header-expansion path "has not been verified
# beyond (1) it passes Claude's own tests and (2) it works with Momiji".
# Pinning bytes to that would adopt an unverified reference and discard
# checks this side already makes. Do not add a byte comparison here.
#
# STDERR IS RECORDED, NOT COUNTED. compat/README.md says it outright:
# "Stderr is where the wrappers deliberately differ: each one prints the
# drydock-macho-rewrite equivalent of the invocation it just received." This wrapper
# prints that teaching block on every successful translation, so a stderr
# comparison would differ on every single row for a reason that has nothing
# to do with correctness. The report shows both sides' stderr byte counts for
# a human to skim; only exit code, stdout shape, output path and Mach-O
# validity count toward PASS/FAIL, the same "read the report by category"
# split differential.sh's own header asks for.
#
# --all-yes IS ALWAYS PASSED, ON BOTH SIDES, AND IS NOT SWEPT. The fork's
# ask() reads a line from stdin (fgets) and treats EOF as "no" -- it will not
# hang under `</dev/null`, but it WILL silently answer "no" to a prompt this
# sweep never intends to ask. This wrapper's prompts read /dev/tty, never
# stdin, and refuse outright with no controlling terminal. Comparing the two
# prompt engines against each other is a different question than this script
# asks, and it already has an answer: tests/insert_dylib_test.sh's notty
# cases. Driving either program past a real prompt is out of scope here.
#
# 32-BIT THIN INPUT IS SKIPPED, ON PURPOSE. compat/README.md's insert_dylib
# table already declares this refused-here/handled-there divergence, and
# tests/insert_dylib_test.sh's "32-bit refused" case already pins it on a
# hand-built fixture. Sweeping it over a whole corpus would repeat the same
# already-known result on every 32-bit file found and crowd out anything new.
#
# --inplace PLUS AN EXPLICIT 3rd POSITIONAL IS A DECLARED DIVERGENCE, NOT A
# SWEPT COMPARISON. This wrapper refuses that
# combination outright (compat/translate.sh's mt_id_parse) rather than match
# the fork's silent "--inplace wins" choice -- compat/README.md's table has
# the reasoning. Comparing FORK against NEW for it, the way every other case
# here does, would report this EXPECTED divergence as an unexplained
# "outpath"/"exit" difference on every single corpus file, forever --
# exactly the noise this script exists to cut through. So
# idd_declared_inplace_newout, below, checks NEW against the one shape it is
# now contractually required to have (refuse, name both, touch nothing) and
# logs FORK's own behaviour without counting it as a difference; only a
# REGRESSION in NEW's refusal counts.
set -u

FORK="${1:?usage: insert-dylib-diff.sh <fork-insert_dylib> <new-insert_dylib> [corpus-root...]}"
NEWBIN="${2:?usage: insert-dylib-diff.sh <fork-insert_dylib> <new-insert_dylib> [corpus-root...]}"
shift 2
if [ "$#" -gt 0 ]; then
    ROOTS="$*"
else
    ROOTS="/usr/lib /usr/bin /bin /sbin /usr/sbin /System/Library/Frameworks"
fi
MAX="${INSERT_DYLIB_DIFF_MAX:-40}"
SCAN="${INSERT_DYLIB_DIFF_SCAN:-4000}"

[ -x "$FORK" ] || { echo "insert-dylib-diff: $FORK not found or not executable" >&2; exit 1; }
[ -x "$NEWBIN" ] || { echo "insert-dylib-diff: $NEWBIN not found or not executable" >&2; exit 1; }
# This script cannot itself confirm $FORK was really built from FORK_COMMIT --
# it only received a path -- so the pin's one live use is naming it in every
# run's own output, not silently trusting the caller built the right thing.
echo "insert-dylib-diff: comparing against \$FORK, which THE PIN above says must be built from commit $FORK_COMMIT"
# ABSOLUTE, both of them: every comparison below cd's into a per-side sandbox
# first (so "f" and "out" are relative names identical on both sides, the
# same reason tests/differential.sh gives for doing this), which breaks any
# relative $1/$2 the caller gave on the command line.
case $FORK in /*) ;; *) FORK="$(pwd)/$FORK" ;; esac
case $NEWBIN in /*) ;; *) NEWBIN="$(pwd)/$NEWBIN" ;; esac
NEWDIR=$(dirname "$NEWBIN")
[ -x "$NEWDIR/drydock-macho-rewrite" ] || {
    echo "insert-dylib-diff: $NEWDIR/drydock-macho-rewrite not found -- the wrapper needs it beside it, and so does this script's verify step" >&2
    exit 1
}
MR="$NEWDIR/drydock-macho-rewrite"

T=$(mktemp -d "${TMPDIR:-/tmp}/insert-dylib-diff.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/A" "$T/B"

DYLIB=/usr/lib/libinsertdylibdiff.dylib

sha() { shasum -a 256 < "$1" | cut -d' ' -f1; }

# idd_valid FILE -- true if FILE parses as a valid Mach-O. `drydock-macho-rewrite
# verify` is a single-thin-image reader (mi_open): it refuses ANY fat
# container outright, by design, the same way `info` does -- not a verdict
# on that container's slices. A fat FILE is therefore treated as "not
# checked" here (returns true) rather than "invalid": this script has no
# per-slice extractor, and reporting mi_open's blanket fat refusal as an
# insert_dylib finding would be reporting a fact about `verify`, not about
# either program's output. A THIN file -- what most of this sweep produces,
# since neither side's transform changes a container's own fat-ness -- gets
# the real check.
idd_valid() {
    case $(od -An -tx1 -N4 -- "$1" 2>/dev/null | tr -d ' ') in
        cafebabe|bebafeca) return 0 ;;
    esac
    "$MR" verify "$1" >/dev/null 2>&1
}

# ---- corpus -------------------------------------------------------------
# Same technique as tests/differential.sh, and the same reason: od's four
# bytes are the file's own byte order, never a human-readable tool's text.
echo "insert-dylib-diff: walking $ROOTS"
find $ROOTS -type f 2>/dev/null > "$T/allfiles" || true
nall=$(wc -l < "$T/allfiles" | tr -d ' ')
[ "$nall" -gt 0 ] || { echo "insert-dylib-diff: no files found under $ROOTS" >&2; exit 1; }
stride=$((nall / SCAN)); [ "$stride" -lt 1 ] && stride=1
awk -v s="$stride" 'NR % s == 0' "$T/allfiles" > "$T/candidates"

: > "$T/corpus"; : > "$T/skipped32"
nswept=0
while IFS= read -r f; do
    [ -r "$f" ] || continue
    magic=$(od -An -tx1 -N4 -- "$f" 2>/dev/null | tr -d ' ')
    case $magic in
        feedfacf|cffaedfe|cafebabe|bebafeca)
            [ "$nswept" -lt "$MAX" ] || continue
            echo "$f" >> "$T/corpus"
            nswept=$((nswept + 1))
            ;;
        feedface|cefaedfe)
            echo "$f" >> "$T/skipped32"
            ;;
    esac
done < "$T/candidates"
ncorpus=$(wc -l < "$T/corpus" | tr -d ' ')
nskip32=$(wc -l < "$T/skipped32" | tr -d ' ')
[ "$ncorpus" -gt 0 ] || { echo "insert-dylib-diff: no thin-64-bit or fat Mach-O found under $ROOTS" >&2; exit 1; }
echo "insert-dylib-diff: $nall files under the roots, 1 in $stride examined ($(wc -l < "$T/candidates" | tr -d ' '))"
echo "insert-dylib-diff: sweeping $ncorpus (max $MAX); skipped $nskip32 32-bit thin file(s) (declared divergence, not swept)"

# ---- comparison -----------------------------------------------------------
total=0; diffs=0; declared=0; stderr_disagreed=0
REPORT="$T/report"; : > "$REPORT"
DECLARED_REPORT="$T/declared"; : > "$DECLARED_REPORT"

# idd_state SIDE BEFORE-HASH -- what SIDE actually wrote, read back off disk
# rather than assumed from either program's own grammar: "f" (the bin
# positional) is reported changed/unchanged by hash, and each of the other
# candidate names is reported written when it exists at all. This is what
# lets case 9 below (--inplace with a 3rd positional) show the two sides
# disagreeing on WHICH file got the edit without this script having to hard-
# code either program's idea of the right answer.
idd_state() {
    d="$T/$1"; before=$2
    st="f:unchanged"
    [ "$(sha "$d/f" 2>/dev/null)" = "$before" ] || st="f:changed"
    for cand in out f_patched; do
        [ -e "$d/$cand" ] && st="$st $cand:written"
    done
    printf '%s' "$st"
}

# idd_case LABEL PREOUT(0|1) ARG... -- ARG... is everything after --all-yes:
# the flags, DYLIB, and "f" plus (for a 3-positional case) "out". PREOUT=1
# pre-creates "out" on both sides first, so --overwrite's own case really
# exercises suppressing that prompt rather than never reaching it.
idd_case() {
    label=$1; preout=$2; shift 2
    total=$((total + 1))
    rm -rf "$T/A" "$T/B"; mkdir -p "$T/A" "$T/B"
    cp "$SRC" "$T/A/f"; cp "$SRC" "$T/B/f"
    [ "$preout" -eq 1 ] && { : > "$T/A/out"; : > "$T/B/out"; }
    before=$(sha "$SRC")
    ( cd "$T/A" && "$FORK" --all-yes "$@" ) </dev/null >"$T/a.out" 2>"$T/a.err"; arc=$?
    ( cd "$T/B" && "$NEWBIN" --all-yes "$@" ) </dev/null >"$T/b.out" 2>"$T/b.err"; brc=$?
    a_state=$(idd_state A "$before")
    b_state=$(idd_state B "$before")

    bad=""
    [ "$arc" != "$brc" ] && bad="$bad exit($arc/$brc)"
    a_ss=empty; [ -s "$T/a.out" ] && a_ss=nonempty
    b_ss=empty; [ -s "$T/b.out" ] && b_ss=nonempty
    [ "$a_ss" != "$b_ss" ] && bad="$bad stdout-shape(fork=$a_ss new=$b_ss)"
    [ "$a_state" != "$b_state" ] && bad="$bad outpath(fork=[$a_state] new=[$b_state])"
    for cand in f out f_patched; do
        af="$T/A/$cand"; bf="$T/B/$cand"
        [ -e "$af" ] && { idd_valid "$af" || bad="$bad fork-$cand-not-valid-macho"; }
        [ -e "$bf" ] && { idd_valid "$bf" || bad="$bad new-$cand-not-valid-macho"; }
    done

    a_es=$(wc -c < "$T/a.err" | tr -d ' '); b_es=$(wc -c < "$T/b.err" | tr -d ' ')
    [ "$a_es" = 0 ] && [ "$b_es" != 0 ] && stderr_disagreed=$((stderr_disagreed + 1))

    if [ -n "$bad" ]; then
        diffs=$((diffs + 1))
        { echo "=== $SRC :: $label ->$bad"
          echo "    fork: rc=$arc stdout=$a_ss stderr=${a_es}b state=[$a_state]"
          echo "    new:  rc=$brc stdout=$b_ss stderr=${b_es}b state=[$b_state]"
          echo "    fork stderr:"; sed 's/^/      /' "$T/a.err" | head -5
          echo "    new stderr:"; sed 's/^/      /' "$T/b.err" | head -5
        } >> "$REPORT"
    fi
}

# idd_declared_inplace_newout -- --inplace plus an explicit 3rd positional.
# compat/README.md's insert_dylib table now DECLARES this one: the fork
# silently picks BIN and never reads the 3rd positional at all, and this
# wrapper REFUSES the combination outright (compat/translate.sh's
# mt_id_parse) rather than match that. Running it through idd_case above
# would flag it as an unexplained "outpath"/"exit" difference on every
# corpus file forever, drowning out anything genuinely new under a result
# this differential already knows the answer to. So this checks NEW against
# the one shape it is now contractually required to have -- refuse, name
# both `--inplace` and the path, touch nothing -- and logs FORK's own
# behaviour for a human to skim without counting it as a difference. If NEW
# ever stops refusing this, that IS news, and it counts as a real diff.
idd_declared_inplace_newout() {
    total=$((total + 1))
    rm -rf "$T/A" "$T/B"; mkdir -p "$T/A" "$T/B"
    cp "$SRC" "$T/A/f"; cp "$SRC" "$T/B/f"
    before=$(sha "$SRC")
    ( cd "$T/A" && "$FORK" --all-yes --inplace "$DYLIB" f out ) </dev/null >"$T/a.out" 2>"$T/a.err"; arc=$?
    ( cd "$T/B" && "$NEWBIN" --all-yes --inplace "$DYLIB" f out ) </dev/null >"$T/b.out" 2>"$T/b.err"; brc=$?
    a_state=$(idd_state A "$before")
    b_state=$(idd_state B "$before")

    bad=""
    [ "$brc" -eq 1 ] || bad="$bad new-did-not-refuse(rc=$brc)"
    grep -q -- '--inplace' "$T/b.err" || bad="$bad new-refusal-does-not-name---inplace"
    grep -q 'out' "$T/b.err" || bad="$bad new-refusal-does-not-name-the-path"
    [ "$b_state" = "f:unchanged" ] || bad="$bad new-wrote-something(state=[$b_state])"

    if [ -n "$bad" ]; then
        diffs=$((diffs + 1))
        { echo "=== $SRC :: --inplace + new_binary_path (declared, but NEW regressed) ->$bad"
          echo "    new: rc=$brc state=[$b_state]"; sed 's/^/      /' "$T/b.err" | head -5
        } >> "$REPORT"
    else
        declared=$((declared + 1))
        echo "=== $SRC :: --inplace + new_binary_path -- fork=[rc=$arc state=$a_state] new=[refused, as declared]" \
            >> "$DECLARED_REPORT"
    fi
}

while IFS= read -r SRC; do
    [ -r "$SRC" ] || continue
    idd_case "plain, 2-positional"                        0 "$DYLIB" f
    idd_case "plain, 3-positional"                        0 "$DYLIB" f out
    idd_case "--weak, 3-positional"                       0 --weak "$DYLIB" f out
    idd_case "--strip-codesig, 3-positional"               0 --strip-codesig "$DYLIB" f out
    idd_case "--no-strip-codesig, 3-positional"            0 --no-strip-codesig "$DYLIB" f out
    idd_case "--overwrite, 3-positional (out pre-exists)"  1 --overwrite "$DYLIB" f out
    idd_case "--inplace, 2-positional"                     0 --inplace "$DYLIB" f
    idd_case "--inplace --weak, 2-positional"              0 --inplace --weak "$DYLIB" f
    idd_declared_inplace_newout
done < "$T/corpus"

echo "insert-dylib-diff: comparisons=$total differing=$diffs declared=$declared" \
     "(stderr non-empty on new but empty on fork in $stderr_disagreed case(s) -- expected, see this script's header; not counted above)"
[ "$declared" -gt 0 ] && echo "insert-dylib-diff: $declared case(s) matched the declared --inplace+new_binary_path divergence (compat/README.md); not counted as differing"
if [ "$diffs" -ne 0 ]; then
    echo "insert-dylib-diff: FOUND $diffs interface difference(s):" >&2
    cat "$REPORT" >&2
    echo "insert-dylib-diff: check each against compat/README.md's insert_dylib divergence table." >&2
    echo "insert-dylib-diff: a difference already named there is expected. One that is NOT named there is a finding -- report it; do not add it to the table just to go green." >&2
    exit 1
fi
echo "insert-dylib-diff: OK -- no interface difference outside what compat/README.md already declares"
