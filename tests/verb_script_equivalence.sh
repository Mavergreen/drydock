#!/bin/sh
# tests/verb_script_equivalence.sh -- the gate that licenses deleting the verbs.
#
# machotool has two ways to modify a binary with DIFFERENT semantics: a CLI of
# verbs (a set of operations applied in one pass) and a script of statements
# (a sequence, one operation per pass). The plan removes the verbs. A verb may
# be removed only once its script form is proved to produce a byte-identical
# OUTPUT FILE on a fixture the verb ACTUALLY CHANGES -- a pair that agrees
# because both sides no-opped licenses nothing, so every pair below asserts the
# change happened before it asserts the two forms agree.
#
# What is compared is the output FILE and the exit code, not stdout. `segment`
# is the one verb with a stdout contract of its own (`--capabilities` says
# `reports=renamed`), and compat/rename_segment.sh:205-230 reshapes that text
# deliberately; nothing here should be read as a guarantee about it.
#
# EVERY operation and flag `machotool --capabilities` advertises for a deleted
# verb gets its own pair, not one exemplar per verb, and not one exemplar per
# flag NAME either -- that is the same error one level up. The surface is
# 18 operations (dylib 5, rpath 4, lc 5 kinds, and the four verbs that take
# none) and SIX verb-flag combinations, because a flag is parsed and lowered
# per verb: allow-grow on dylib, rpath and minos, fatal-warnings on dylib,
# rpath and lc. All 18 and all 6 have a pair below.
#
# spec: docs/superpowers/specs/2026-09-14-script-is-the-only-interface-design.md
#
# This suite is deleted in the same commit as the verbs it licenses.
#
#   sh tests/verb_script_equivalence.sh <bindir>
set -eu
BIN="${1:?usage: verb_script_equivalence.sh <bindir>}"
MACHOTOOL="$BIN/machotool"
[ -x "$MACHOTOOL" ] || { echo "verb_script_equivalence: $MACHOTOOL not found or not executable" >&2; exit 1; }

CC="${CC:-clang}"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_DIR="$HERE/../src"
# platform: a modern linker defaults to LC_DYLD_CHAINED_FIXUPS, so a fixture
# built for the host would ask a different question on a modern runner than it
# asks on 10.9. Pinning the deployment target gets the classic LC_DYLD_INFO_ONLY
# form on either -- the same reasoning, and the same flag, as cli_test.sh's
# FIXTURE_FLAGS and change_dylib_test.sh's.
FIXTURE_FLAGS="-mmacosx-version-min=10.9"
T="${TMPDIR:-/tmp}/verb_script_equivalence.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

fails=0
ok()   { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fails=$((fails + 1)); }
# Not a failure: the assertion could not be exercised on this host. Printed
# loudly, per-assertion, rather than silently omitted -- cli_test.sh's rule.
skip() { echo "SKIP $1: $2"; }

# An early death under `set -e` is not allowed to look like a clean run.
reached_end=0
trap 'rc=$?; if [ "$reached_end" -eq 0 ]; then
    echo "verb_script_equivalence: FATAL -- aborted early (a command exited $rc under set -e); the suite did NOT run to completion" >&2
fi' EXIT

# --- fixtures --------------------------------------------------------------
cat > "$T/a.c" <<'EOF'
int a_sym(void) { return 11; }
EOF
cat > "$T/main.c" <<'EOF'
int a_sym(void);
int main(void) { return a_sym() == 11 ? 0 : 1; }
EOF
"$CC" -dynamiclib -O2 $FIXTURE_FLAGS -install_name "@loader_path/liba.dylib" \
    "$T/a.c" -o "$T/liba.dylib"
# An LC_RPATH is baked in so every rpath pair has a real entry to act on, and an
# appended one lands after it rather than into an empty list.
"$CC" -O2 $FIXTURE_FLAGS -Xlinker -rpath -Xlinker /tmp/seed \
    "$T/main.c" "$T/liba.dylib" -o "$T/main"

# declassify needs chained fixups, which no linker on any host this repo
# supports will emit for a 10.9 target; retag-swift needs real Swift class
# records. Both fixtures are laid out by hand, by the builders cli_test.sh and
# wrapper_test.sh already share. mkchained's image also carries the
# LC_BUILD_VERSION that `lc -delete build-version` needs and no 10.9-targeted
# link produces.
"$CC" -O2 -I "$SRC_DIR" -o "$T/mkchained" "$HERE/mkchained.c"
"$CC" -O2 -o "$T/mkswift" "$HERE/mkswift.c"
"$CC" -O2 -o "$T/strip_version_min" "$HERE/strip_version_min.c"
"$T/mkchained" make "$T/chained.in"
"$T/mkswift" make "$T/swift.in"
# minos on a binary that already carries LC_VERSION_MIN_MACOSX changes nothing,
# so strip it first -- otherwise both forms no-op and the pair proves nothing.
cp "$T/main" "$T/minos.in"
"$T/strip_version_min" "$T/minos.in" >/dev/null

# A dylib nothing binds to, for the `delete` pairs: `dylib delete` refuses a
# path with binds outright, so the fixture has to carry one that is unreferenced.
printf 'dylib append /unbound/u.dylib\n' \
    | "$MACHOTOOL" "$T/main" "$T/undy" >/dev/null 2>&1 || true

# platform: `lc -delete codesig` needs an LC_CODE_SIGNATURE, which no link
# produces on its own. `codesign -f -s -` (ad-hoc) adds one; where it is
# unavailable or refuses, the codesig pairs SKIP rather than silently pass on a
# fixture with nothing to delete -- the exact vacuity this suite exists to stop.
have_codesig=0
cp "$T/main" "$T/signed"
if codesign -f -s - "$T/signed" >/dev/null 2>&1 \
   && "$MACHOTOOL" info "$T/signed" 2>/dev/null | grep -q LC_CODE_SIGNATURE; then
    have_codesig=1
fi

# A fixture whose header pad is nearly exhausted, so the append below cannot
# fit and MUST grow the image. Without one, an allow-grow pair would pass with
# the flag permitting a growth that never happens. Filled by appending long
# paths -- an append lands in the pad, so this shrinks the pad without changing
# the file's size.
PADLONG=/pad/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
: > "$T/fill.edits"
fill_i=0
while [ "$fill_i" -lt 9 ]; do
    printf 'dylib append %s%d.dylib\n' "$PADLONG" "$fill_i" >>"$T/fill.edits"
    fill_i=$((fill_i + 1))
done
"$MACHOTOOL" "$T/main" "$T/tight" <"$T/fill.edits" >/dev/null 2>&1 || true
# The same treatment for minos, which needs its own base: the pad has to be too
# small for an LC_VERSION_MIN_MACOSX (16 bytes), and the image must not already
# carry one, or both forms no-op whatever the flag says.
#
# The long fills alone leave a pad that still has room, so one more append is
# sized to land the pad at 8 bytes. An appended LC_LOAD_DYLIB costs
# sizeof(struct dylib_command) + the NUL-terminated path rounded up to 8, so a
# path of (cost - 25) bytes costs exactly `cost`. Computed rather than spelled,
# so editing PADLONG above does not silently leave a roomy pad here -- and the
# assertion just below checks the result either way.
"$MACHOTOOL" "$T/minos.in" "$T/mvbase" <"$T/fill.edits" >/dev/null 2>&1 || true
mvbase_pad=$("$MACHOTOOL" info "$T/mvbase" 2>/dev/null | sed -n 's/^header pad: \([0-9]*\) bytes.*/\1/p')
mv_tail_len=$(( ${mvbase_pad:-0} - 8 - 25 ))
mv_tail=/
mv_i=1
while [ "$mv_i" -lt "$mv_tail_len" ]; do mv_tail="${mv_tail}x"; mv_i=$((mv_i + 1)); done
cp "$T/fill.edits" "$T/mvfill.edits"
printf 'dylib append %s\n' "$mv_tail" >>"$T/mvfill.edits"
"$MACHOTOOL" "$T/minos.in" "$T/mvtight" <"$T/mvfill.edits" >/dev/null 2>&1 || true
# The paths the allow-grow pairs append are long for the same reason: what
# matters is not that the pad is small in absolute terms but that it is smaller
# than the command being appended.
GROWDY="$PADLONG/grow-me.dylib"
GROWRP="$PADLONG/grow-rp"
# An appended LC_LOAD_DYLIB is sizeof(struct dylib_command) + the NUL-terminated
# path, rounded up to 8. LC_RPATH's header is smaller, so this bounds both.
grow_need=$(( (24 + ${#GROWDY} + 1 + 7) / 8 * 8 ))
tight_pad=$("$MACHOTOOL" info "$T/tight" 2>/dev/null | sed -n 's/^header pad: \([0-9]*\) bytes.*/\1/p')
[ -n "$tight_pad" ] && [ "$tight_pad" -lt "$grow_need" ] \
    && ok "fixture: the tight-pad image has $tight_pad bytes left and the append needs $grow_need, so it must grow" \
    || bad "fixture: tight pad" "pad is '${tight_pad:-none}' against an append needing $grow_need -- the command would fit, and every allow-grow pair below would pass with the flag permitting a growth that never happens"
# sizeof(struct version_min_command).
mv_need=16
mvtight_pad=$("$MACHOTOOL" info "$T/mvtight" 2>/dev/null | sed -n 's/^header pad: \([0-9]*\) bytes.*/\1/p')
[ -n "$mvtight_pad" ] && [ "$mvtight_pad" -lt "$mv_need" ] \
    && ok "fixture: the minos tight-pad image has $mvtight_pad bytes left and LC_VERSION_MIN_MACOSX needs $mv_need, so it must grow" \
    || bad "fixture: minos tight pad" "pad is '${mvtight_pad:-none}' against a command needing $mv_need -- it would fit, and the minos allow-grow pair below would pass with the flag permitting a growth that never happens"
"$MACHOTOOL" info "$T/mvtight" 2>/dev/null | grep -q LC_VERSION_MIN_MACOSX \
    && bad "fixture: minos tight pad" "the fixture already carries LC_VERSION_MIN_MACOSX, so both forms would no-op and the flag under test would decide nothing" \
    || ok "fixture: the minos tight-pad image has no LC_VERSION_MIN_MACOSX yet"

# --- the pair helpers ------------------------------------------------------
#
# pair NAME INPUT STATEMENTS -- VERB ARG...
#
# Runs the verb form and the script form of the same request against the same
# input and asserts three things: the verb really changed the input, the two
# forms exited the same way, and their OUTPUT FILES are byte-identical. Their
# stdout is captured but not compared -- see the header. The verb's OUT must be
# "$T/NAME.verb".
pair() {
    p_name=$1; p_in=$2; p_stmt=$3
    shift 3
    [ "$1" = "--" ] || { bad "$p_name" "pair(): malformed call, expected -- before the verb"; return 0; }
    shift
    p_verb_out="$T/$p_name.verb"
    p_script_out="$T/$p_name.script"
    rm -f "$p_verb_out" "$p_script_out"

    p_vrc=0
    "$MACHOTOOL" "$@" >"$T/$p_name.verb.out" 2>&1 || p_vrc=$?
    p_src=0
    printf '%s\n' "$p_stmt" \
        | "$MACHOTOOL" "$p_in" "$p_script_out" >"$T/$p_name.script.out" 2>&1 || p_src=$?

    if [ "$p_vrc" -ne 0 ]; then
        bad "$p_name: fixture" "the verb form exited $p_vrc, so this pair cannot prove anything about an input it refuses: $(cat "$T/$p_name.verb.out")"
        return 0
    fi
    if cmp -s "$p_in" "$p_verb_out"; then
        bad "$p_name: fixture" "the verb produced bytes identical to its input -- this fixture does not exercise the operation, so an agreement between the two forms here would only mean both did nothing"
        return 0
    fi
    ok "$p_name: the fixture is one the verb really rewrites"

    if [ "$p_vrc" -ne "$p_src" ]; then
        bad "$p_name: exit code" "verb exited $p_vrc, script exited $p_src -- a caller migrated from the verb to the statement would see a different success/failure for the same request"
        return 0
    fi

    if cmp -s "$p_verb_out" "$p_script_out"; then
        ok "$p_name: verb and statement produce byte-identical output (both exit $p_vrc)"
    else
        bad "$p_name: bytes" "the verb and its statement produced DIFFERENT files from the same input -- deleting this verb would silently change what users' binaries become"
    fi
}

# refusal_pair NAME INPUT STATEMENTS -- VERB ARG...
#
# For the pairs whose point is that both forms REFUSE: same nonzero exit, and
# neither leaves an output behind. A refusal has no bytes to compare, so the
# proof that the refusal is caused by the flag under test -- and not by the
# request itself -- is a separate control pair run without it.
refusal_pair() {
    r_name=$1; r_in=$2; r_stmt=$3
    shift 3
    [ "$1" = "--" ] || { bad "$r_name" "refusal_pair(): malformed call, expected -- before the verb"; return 0; }
    shift
    rm -f "$T/$r_name.verb" "$T/$r_name.script"

    r_vrc=0
    "$MACHOTOOL" "$@" >"$T/$r_name.verb.out" 2>&1 || r_vrc=$?
    r_src=0
    printf '%s\n' "$r_stmt" \
        | "$MACHOTOOL" "$r_in" "$T/$r_name.script" >"$T/$r_name.script.out" 2>&1 || r_src=$?

    [ "$r_vrc" -ne 0 ] && [ "$r_vrc" -eq "$r_src" ] \
        && ok "$r_name: verb and statement both refuse, with the same exit ($r_vrc)" \
        || bad "$r_name: exit code" "verb exited $r_vrc, script exited $r_src -- a caller migrating this request would have a build step start or stop failing"
    [ ! -f "$T/$r_name.verb" ] && [ ! -f "$T/$r_name.script" ] \
        && ok "$r_name: neither form leaves an output behind when it refuses" \
        || bad "$r_name: output" "verb wrote=$([ -f "$T/$r_name.verb" ] && echo yes || echo no) script wrote=$([ -f "$T/$r_name.script" ] && echo yes || echo no) -- a refusal that still writes a file hands the caller a half-rewritten binary"
}

# --- the four single-operation verbs ---------------------------------------
pair declassify "$T/chained.in" 'fixups set classic' \
    -- declassify "$T/chained.in" "$T/declassify.verb"
pair segment "$T/main" 'segment rename __DATA __DATA_R9' \
    -- segment "$T/main" "$T/segment.verb" __DATA __DATA_R9
pair retag-swift "$T/swift.in" 'swift-abi set legacy' \
    -- retag-swift "$T/swift.in" "$T/retag-swift.verb"
pair minos "$T/minos.in" 'version-min set 10.9' \
    -- minos "$T/minos.in" "$T/minos.verb" 10.9

# --- lc: every KIND --capabilities advertises ------------------------------
pair lc-uuid "$T/main" 'load-command delete uuid' \
    -- lc "$T/main" "$T/lc-uuid.verb" -delete uuid
pair lc-source-version "$T/main" 'load-command delete source-version' \
    -- lc "$T/main" "$T/lc-source-version.verb" -delete source-version
pair lc-code-sign-drs "$T/main" 'load-command delete code-sign-drs' \
    -- lc "$T/main" "$T/lc-code-sign-drs.verb" -delete code-sign-drs
pair lc-build-version "$T/chained.in" 'load-command delete build-version' \
    -- lc "$T/chained.in" "$T/lc-build-version.verb" -delete build-version
if [ "$have_codesig" -eq 1 ]; then
    pair lc-codesig "$T/signed" 'load-command delete codesig' \
        -- lc "$T/signed" "$T/lc-codesig.verb" -delete codesig
else
    skip "lc-codesig" "no ad-hoc codesign on this host, so no fixture carries an LC_CODE_SIGNATURE to delete"
fi

# --- dylib: every operation ------------------------------------------------
pair dylib-replace "$T/main" 'dylib replace @loader_path/liba.dylib @loader_path/../L.dylib' \
    -- dylib "$T/main" "$T/dylib-replace.verb" -replace @loader_path/liba.dylib @loader_path/../L.dylib
pair dylib-append "$T/main" 'dylib append /tmp/x.dylib' \
    -- dylib "$T/main" "$T/dylib-append.verb" -append /tmp/x.dylib
pair dylib-insert "$T/main" 'dylib insert /tmp/i.dylib' \
    -- dylib "$T/main" "$T/dylib-insert.verb" -insert /tmp/i.dylib
pair dylib-reexport "$T/main" 'dylib reexport @loader_path/liba.dylib' \
    -- dylib "$T/main" "$T/dylib-reexport.verb" -reexport @loader_path/liba.dylib
pair dylib-delete "$T/undy" 'dylib delete /unbound/u.dylib' \
    -- dylib "$T/undy" "$T/dylib-delete.verb" -delete /unbound/u.dylib

# --- rpath: every operation ------------------------------------------------
pair rpath-replace "$T/main" 'rpath replace /tmp/seed /tmp/seed2' \
    -- rpath "$T/main" "$T/rpath-replace.verb" -replace /tmp/seed /tmp/seed2
pair rpath-append "$T/main" 'rpath append /tmp/r' \
    -- rpath "$T/main" "$T/rpath-append.verb" -append /tmp/r
pair rpath-insert "$T/main" 'rpath insert /tmp/ri' \
    -- rpath "$T/main" "$T/rpath-insert.verb" -insert /tmp/ri
pair rpath-delete "$T/main" 'rpath delete /tmp/seed' \
    -- rpath "$T/main" "$T/rpath-delete.verb" -delete /tmp/seed

# --- --fatal-warnings, on all three verbs that take it ---------------------
#
# The flag turns "that operation matched nothing" from a warning into a
# refusal, so the verb form's --fatal-warnings and the script's fatal-warnings
# directive have to agree about which requests stop being accepted.
refusal_pair dylib-fatal-warnings "$T/main" 'fatal-warnings
dylib replace /nope.dylib /other.dylib' \
    -- dylib "$T/main" "$T/dylib-fatal-warnings.verb" --fatal-warnings -replace /nope.dylib /other.dylib
refusal_pair rpath-fatal-warnings "$T/main" 'fatal-warnings
rpath delete /nope' \
    -- rpath "$T/main" "$T/rpath-fatal-warnings.verb" --fatal-warnings -delete /nope
refusal_pair lc-fatal-warnings "$T/main" 'fatal-warnings
load-command delete codesig' \
    -- lc "$T/main" "$T/lc-fatal-warnings.verb" --fatal-warnings -delete codesig

# The control: the SAME request without the flag is ACCEPTED by both forms,
# and they agree on the bytes. Without this, all three refusal pairs above
# would equally be satisfied by a build that refuses the request whatever the
# flags. This one deliberately does not use pair(): a request that matches
# nothing is supposed to leave the image alone, so pair()'s "the verb really
# rewrote it" precondition is the wrong question here -- what makes this
# control non-vacuous is that the identical request DID refuse just above.
rm -f "$T/fwc.verb" "$T/fwc.script"
fwvrc=0
"$MACHOTOOL" dylib "$T/main" "$T/fwc.verb" -replace /nope.dylib /other.dylib >/dev/null 2>&1 || fwvrc=$?
fwsrc=0
printf 'dylib replace /nope.dylib /other.dylib\n' \
    | "$MACHOTOOL" "$T/main" "$T/fwc.script" >/dev/null 2>&1 || fwsrc=$?
[ "$fwvrc" -eq 0 ] && [ "$fwsrc" -eq 0 ] && [ -f "$T/fwc.verb" ] && [ -f "$T/fwc.script" ] \
    && ok "fatal-warnings control: without the flag both forms ACCEPT the same request and write an output" \
    || bad "fatal-warnings control" "verb exited $fwvrc, script exited $fwsrc -- the refusals above are then caused by the request rather than by the flag, and prove nothing about --fatal-warnings at all"
cmp -s "$T/fwc.verb" "$T/fwc.script" \
    && ok "fatal-warnings control: ... and agree on the bytes" \
    || bad "fatal-warnings control: bytes" "the two forms disagree on an operation that matched nothing -- one of them is touching the image when it should not"

# --- --allow-grow, on both verbs that take it ------------------------------
#
# On the tight-pad fixture the appended command does not fit, so the flag is
# what decides whether the image may grow to hold it. Both directions are
# asserted: refused without it, byte-identical with it.
refusal_pair dylib-no-grow "$T/tight" "dylib append $GROWDY" \
    -- dylib "$T/tight" "$T/dylib-no-grow.verb" -append "$GROWDY"
refusal_pair rpath-no-grow "$T/tight" "rpath append $GROWRP" \
    -- rpath "$T/tight" "$T/rpath-no-grow.verb" -append "$GROWRP"
pair dylib-allow-grow "$T/tight" "allow-grow
dylib append $GROWDY" \
    -- dylib "$T/tight" "$T/dylib-allow-grow.verb" --allow-grow -append "$GROWDY"
pair rpath-allow-grow "$T/tight" "allow-grow
rpath append $GROWRP" \
    -- rpath "$T/tight" "$T/rpath-allow-grow.verb" --allow-grow -append "$GROWRP"
# minos is the third verb --capabilities gives allow-grow to, and the one whose
# two forms do not even share an entry point: the verb calls mv_add_version_min
# (the file path) where the statement calls mv_add_version_min_image (the
# buffer path), so this is the flag row most able to diverge unnoticed.
refusal_pair minos-no-grow "$T/mvtight" 'version-min set 10.9' \
    -- minos "$T/mvtight" "$T/minos-no-grow.verb" 10.9
pair minos-allow-grow "$T/mvtight" 'allow-grow
version-min set 10.9' \
    -- minos "$T/mvtight" "$T/minos-allow-grow.verb" 10.9 --allow-grow
"$MACHOTOOL" info "$T/minos-allow-grow.verb" 2>/dev/null | grep -q LC_VERSION_MIN_MACOSX \
    && ok "minos-allow-grow: the command the flag made room for is really there" \
    || bad "minos-allow-grow" "no LC_VERSION_MIN_MACOSX in the output -- the run grew the image and then did not add the command it grew for, so a 10.9 target would silently not be one"

# ... and the grow really happened, rather than the pad turning out to be
# roomy after all: the output is bigger than the input.
grow_in=$(wc -c <"$T/tight" | tr -d " ")
grow_out=$(wc -c <"$T/dylib-allow-grow.verb" | tr -d " ")
[ "$grow_out" -gt "$grow_in" ] \
    && ok "allow-grow: the image really grew ($grow_in -> $grow_out bytes)" \
    || bad "allow-grow: fixture" "output is $grow_out bytes against an input of $grow_in -- nothing grew, so these pairs prove nothing about the flag"

# --- two inserts: the reversal is load-bearing -----------------------------
#
# Each insert goes to the FRONT, so as a batch `-insert A -insert B` leaves A at
# ordinal 1 and B at 2, and a sequence reproduces that only by inserting B and
# then A. compat/translate.sh emits inserts in reverse flag order for exactly
# this reason; these assertions are what makes that reversal checked rather
# than merely documented.
ins_check() {
    i_name=$1; i_kind=$2; i_a=$3; i_b=$4
    "$MACHOTOOL" "$i_kind" "$T/main" "$T/$i_name.verb" -insert "$i_a" -insert "$i_b" >/dev/null 2>&1 || true
    printf '%s insert %s\n%s insert %s\n' "$i_kind" "$i_b" "$i_kind" "$i_a" \
        | "$MACHOTOOL" "$T/main" "$T/$i_name.rev" >/dev/null 2>&1 || true
    printf '%s insert %s\n%s insert %s\n' "$i_kind" "$i_a" "$i_kind" "$i_b" \
        | "$MACHOTOOL" "$T/main" "$T/$i_name.naive" >/dev/null 2>&1 || true
    [ -f "$T/$i_name.verb" ] && [ -f "$T/$i_name.rev" ] && [ -f "$T/$i_name.naive" ] \
        || { bad "$i_name: fixture" "one of the three runs wrote no output, so nothing below compares anything"; return 0; }
    cmp -s "$T/$i_name.verb" "$T/$i_name.rev" \
        && ok "$i_name: two inserts as one pass equal the two statements IN REVERSE" \
        || bad "$i_name: bytes" "the batch and the reversed statements disagree -- compat/translate.sh emits inserts reversed precisely to reproduce the batch, so every caller inserting two ${i_kind}s would get a different load-command order"
    cmp -s "$T/$i_name.verb" "$T/$i_name.naive" \
        && bad "$i_name: reversal" "the batch ALSO equals the statements in their original order, so this suite cannot tell a correct reversal from no reversal at all -- and neither could a reviewer reading translate.sh's rule as optional" \
        || ok "$i_name: ... and NOT the two statements in flag order, so the reversal is load-bearing"
}
ins_check dylib-two-inserts dylib /tmp/A.dylib /tmp/B.dylib
ins_check rpath-two-inserts rpath /tmp/A /tmp/B

# --- multi-operation, non-overlapping: the two models must agree -----------
#
# tests/characterize.sh:24 drives exactly this shape through the pipeline
# (change_dylib -strip-lc uuid -strip-lc codesig), and its digest is pinned.
# If the set and the sequence ever stop agreeing here, migrating the wrappers
# silently changes what users' binaries become.
mrc=0; "$MACHOTOOL" lc "$T/main" "$T/multi_verb" -delete uuid -delete codesig >"$T/multi_verb.out" 2>&1 || mrc=$?
printf 'load-command delete uuid\nload-command delete codesig\n' >"$T/multi.edits"
msrc=0; "$MACHOTOOL" "$T/main" "$T/multi_script" <"$T/multi.edits" >"$T/multi_script.out" 2>&1 || msrc=$?
[ "$mrc" -eq "$msrc" ] \
    && ok "multi-op: two non-overlapping deletes agree on exit status ($mrc)" \
    || bad "multi-op: exit code" "verb exited $mrc, script exited $msrc -- a caller migrated from the one-pass form to two statements would see a different success/failure"
cmp -s "$T/multi_verb" "$T/multi_script" \
    && ok "multi-op: two non-overlapping deletes agree as a set and as a sequence" \
    || bad "multi-op" "one pass and two statements produced different files -- the pipeline tests/characterize.sh pins runs this exact shape, so the emitted bytes would move"

# The pair above carries a kind this fixture does not have (codesig), so on its
# own it would also pass if the second operation were a no-op in both forms.
# This one names two kinds the INPUT is checked to carry, so both operations
# really act -- checking only what survived in the OUTPUT would be satisfied by
# an input that never had them.
multi2_in=$("$MACHOTOOL" info "$T/main" 2>/dev/null | grep -c 'LC_UUID\|LC_SOURCE_VERSION' || true)
[ "$multi2_in" -eq 2 ] \
    && ok "multi-op: the input carries both load commands this pair deletes" \
    || bad "multi-op: fixture" "the input has $multi2_in of the 2 load commands, so at least one delete has nothing to act on and this pair does not exercise two acting operations in one pass"
"$MACHOTOOL" lc "$T/main" "$T/multi2_verb" -delete uuid -delete source-version >/dev/null 2>&1 || true
printf 'load-command delete uuid\nload-command delete source-version\n' >"$T/multi2.edits"
"$MACHOTOOL" "$T/main" "$T/multi2_script" <"$T/multi2.edits" >/dev/null 2>&1 || true
multi2_left=$("$MACHOTOOL" info "$T/multi2_verb" 2>/dev/null | grep -c 'LC_UUID\|LC_SOURCE_VERSION' || true)
[ "$multi2_left" -eq 0 ] \
    && ok "multi-op: both deletes really removed their load command" \
    || bad "multi-op: fixture" "$multi2_left of the two load commands survived, so this pair does not exercise two acting operations in one pass"
cmp -s "$T/multi2_verb" "$T/multi2_script" \
    && ok "multi-op: two ACTING non-overlapping deletes agree as a set and as a sequence" \
    || bad "multi-op" "one pass and two statements produced different files when both operations acted"

# --- multi-operation, same path: the one shape the two models read apart ---
#
# CURRENT BEHAVIOUR, PINNED TO BE PRESERVED -- not a change in flight.
# compat/translate.sh already emits deletes before replaces, which reproduces
# the batch's precedence by ordering, so no caller's bytes move.
#
# Set semantics: a -delete beats a conflicting -replace for the same path
# whatever the order (mr_is_deleted, src/rewrite.c). Sequence semantics: the
# replace happens first, and the delete then matches nothing.
P=/absent/p.dylib
Q=/also/absent.dylib
printf 'dylib append %s\n' "$P" | "$MACHOTOOL" "$T/main" "$T/conf_in" >/dev/null 2>&1 || true
"$MACHOTOOL" info "$T/conf_in" 2>/dev/null | grep -q "path=$P" \
    && ok "same-path: the fixture carries an appended dylib nothing binds to" \
    || bad "same-path: fixture" "$P is not in the fixture, so neither form has anything to conflict over"

cvrc=0
"$MACHOTOOL" dylib "$T/conf_in" "$T/conf_verb" -replace "$P" "$Q" -delete "$P" >"$T/conf_verb.out" 2>&1 || cvrc=$?
printf 'dylib replace %s %s\ndylib delete %s\n' "$P" "$Q" "$P" >"$T/conf.edits"
csrc=0
"$MACHOTOOL" "$T/conf_in" "$T/conf_script" <"$T/conf.edits" >"$T/conf_script.out" 2>&1 || csrc=$?
# Both forms ACCEPT this request today; only their answers differ. Checked
# first, because a form that refuses writes no output, and "the path is not in
# a file that does not exist" would otherwise read as a successful delete.
[ "$cvrc" -eq 0 ] && [ -f "$T/conf_verb" ] \
    && ok "same-path: the verb form accepts replace+delete of one path and writes an output" \
    || bad "same-path: verb" "exited $cvrc, output present=$([ -f "$T/conf_verb" ] && echo yes || echo no) -- a caller who asks the verb for both operations on one path gets a refusal instead of a rewritten binary: $(cat "$T/conf_verb.out")"
[ "$csrc" -eq 0 ] && [ -f "$T/conf_script" ] \
    && ok "same-path: the script form accepts the two statements and writes an output" \
    || bad "same-path: script" "exited $csrc, output present=$([ -f "$T/conf_script" ] && echo yes || echo no) -- a caller migrating these two operations to statements gets a refusal instead of a rewritten binary: $(cat "$T/conf_script.out")"

# BOTH paths are asserted in BOTH outputs, not just the new one. Asking only
# "is Q absent from the verb's output" is satisfied by a build that ignores
# every operation and copies its input: P would still be there, unnoticed.
has_path() {
    "$MACHOTOOL" info "$1" 2>/dev/null | grep -q "path=$2" && echo yes || echo no
}
vP=$(has_path "$T/conf_verb" "$P");   vQ=$(has_path "$T/conf_verb" "$Q")
sP=$(has_path "$T/conf_script" "$P"); sQ=$(has_path "$T/conf_script" "$Q")
[ "$vP" = no ] && [ "$vQ" = no ] \
    && ok "same-path: the verb DELETES -- neither the old path nor the new one survives" \
    || bad "same-path: verb" "expected both gone (the batch's -delete beating its -replace), got $P present=$vP, $Q present=$vQ -- if the OLD path is still there the verb applied neither operation, and this row has been passing on a build that ignores them both; if the NEW one is there the delete-wins rule has changed"
[ "$sP" = no ] && [ "$sQ" = yes ] \
    && ok "same-path: the script RENAMES -- the old path is gone and the new one is there" \
    || bad "same-path: script" "expected $P gone and $Q present (the replace running first, the delete then matching nothing), got $P present=$sP, $Q present=$sQ -- if the NEW path is missing the sequential model has acquired the conflict resolution it is supposed to be free of; if the OLD one is still there it applied neither statement"

reached_end=1
echo "verb_script_equivalence: $fails failure(s)"
[ "$fails" -eq 0 ]
