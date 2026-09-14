#!/bin/sh
# tests/verb_script_equivalence.sh -- the gate that licenses deleting the verbs.
#
# machotool has two ways to modify a binary with DIFFERENT semantics: a CLI of
# verbs (a set of operations applied in one pass) and a script of statements
# (a sequence, one operation per pass). The plan removes the verbs. A verb may
# be removed only once its script form is proved to produce byte-identical
# output on a fixture the verb ACTUALLY CHANGES -- a pair that agrees because
# both sides no-opped licenses nothing, so every pair below asserts the change
# happened before it asserts the two forms agree.
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
# Same reasoning as cli_test.sh and change_dylib_test.sh: a modern linker
# defaults to LC_DYLD_CHAINED_FIXUPS, which would ask a different question on a
# modern host than on 10.9. Pinning the deployment target gets the classic
# LC_DYLD_INFO_ONLY form on either.
FIXTURE_FLAGS="-mmacosx-version-min=10.9"
T="${TMPDIR:-/tmp}/verb_script_equivalence.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

fails=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fails=$((fails + 1)); }

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
# An LC_RPATH is baked in so the rpath fixture has one before the append, and
# the appended one lands after a real entry rather than into an empty list.
"$CC" -O2 $FIXTURE_FLAGS -Xlinker -rpath -Xlinker /tmp/seed \
    "$T/main.c" "$T/liba.dylib" -o "$T/main"

# declassify needs chained fixups, which no linker on any host this repo
# supports will emit for a 10.9 target; retag-swift needs real Swift class
# records. Both fixtures are laid out by hand, by the builders cli_test.sh and
# wrapper_test.sh already share.
"$CC" -O2 -I "$SRC_DIR" -o "$T/mkchained" "$HERE/mkchained.c"
"$CC" -O2 -o "$T/mkswift" "$HERE/mkswift.c"
"$CC" -O2 -o "$T/strip_version_min" "$HERE/strip_version_min.c"
"$T/mkchained" make "$T/chained.in"
"$T/mkswift" make "$T/swift.in"
# minos on a binary that already carries LC_VERSION_MIN_MACOSX changes nothing,
# so strip it first -- otherwise both forms no-op and the pair proves nothing.
cp "$T/main" "$T/minos.in"
"$T/strip_version_min" "$T/minos.in" >/dev/null

# --- the seven pairs -------------------------------------------------------
#
# pair NAME INPUT STATEMENT -- VERB ARG...
#
# Runs the verb form and the script form of the same request against the same
# input and asserts three things: the verb really changed the input, the two
# forms exited the same way, and they produced the same bytes.
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
        bad "$p_name: fixture" "the verb produced bytes identical to its input -- this fixture does not exercise the verb, so an agreement between the two forms here would only mean both did nothing"
        return 0
    fi
    ok "$p_name: the fixture is one the verb really rewrites"

    if [ "$p_vrc" -ne "$p_src" ]; then
        bad "$p_name: exit code" "verb exited $p_vrc, script exited $p_src -- a caller migrated from the verb to the statement would see a different success/failure for the same request"
        return 0
    fi
    ok "$p_name: verb and statement agree on exit status ($p_vrc)"

    if cmp -s "$p_verb_out" "$p_script_out"; then
        ok "$p_name: verb and statement produce byte-identical output"
    else
        bad "$p_name: bytes" "the verb and its statement produced DIFFERENT files from the same input -- deleting this verb would silently change what users' binaries become"
    fi
}

pair declassify "$T/chained.in" 'fixups set classic' \
    -- declassify "$T/chained.in" "$T/declassify.verb"
pair segment "$T/main" 'segment rename __DATA __DATA_R9' \
    -- segment "$T/main" "$T/segment.verb" __DATA __DATA_R9
pair retag-swift "$T/swift.in" 'swift-abi set legacy' \
    -- retag-swift "$T/swift.in" "$T/retag-swift.verb"
pair minos "$T/minos.in" 'version-min set 10.9' \
    -- minos "$T/minos.in" "$T/minos.verb" 10.9
pair lc "$T/main" 'load-command delete uuid' \
    -- lc "$T/main" "$T/lc.verb" -delete uuid
pair dylib "$T/main" 'dylib append /tmp/x.dylib' \
    -- dylib "$T/main" "$T/dylib.verb" -append /tmp/x.dylib
pair rpath "$T/main" 'rpath append /tmp/r' \
    -- rpath "$T/main" "$T/rpath.verb" -append /tmp/r

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
# This one names two kinds that are both present, so both operations really act.
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

# --- multi-operation, same path: THE one authorised divergence -------------
#
# Asserted in its BEFORE state, so Task 5 has to change this deliberately
# rather than meet it as a red suite. Set semantics: a -delete beats a
# conflicting -replace for the same path whatever the order (mr_is_deleted,
# src/rewrite.c). Sequence semantics: the replace happens, then the delete
# matches nothing.
P=/absent/p.dylib
printf 'dylib append %s\n' "$P" | "$MACHOTOOL" "$T/main" "$T/conf_in" >/dev/null 2>&1 || true
"$MACHOTOOL" info "$T/conf_in" 2>/dev/null | grep -q "path=$P" \
    && ok "same-path: the fixture carries an appended dylib nothing binds to" \
    || bad "same-path: fixture" "$P is not in the fixture, so neither form has anything to conflict over"

cvrc=0
"$MACHOTOOL" dylib "$T/conf_in" "$T/conf_verb" -replace "$P" /also/absent.dylib -delete "$P" >"$T/conf_verb.out" 2>&1 || cvrc=$?
printf 'dylib replace %s /also/absent.dylib\ndylib delete %s\n' "$P" "$P" >"$T/conf.edits"
csrc=0
"$MACHOTOOL" "$T/conf_in" "$T/conf_script" <"$T/conf.edits" >"$T/conf_script.out" 2>&1 || csrc=$?
# Both forms ACCEPT this request today; only their answers differ. Checked
# first, because a form that refuses writes no output, and "the path is not in
# a file that does not exist" would otherwise read as a successful delete and
# pin the divergence vacuously.
[ "$cvrc" -eq 0 ] && [ -f "$T/conf_verb" ] \
    && ok "same-path: the verb form accepts replace+delete of one path and writes an output" \
    || bad "same-path: verb" "exited $cvrc, output present=$([ -f "$T/conf_verb" ] && echo yes || echo no) -- a caller who asks the verb for both operations on one path gets a refusal instead of a rewritten binary: $(cat "$T/conf_verb.out")"
[ "$csrc" -eq 0 ] && [ -f "$T/conf_script" ] \
    && ok "same-path: the script form accepts the two statements and writes an output" \
    || bad "same-path: script" "exited $csrc, output present=$([ -f "$T/conf_script" ] && echo yes || echo no) -- a caller migrating these two operations to statements gets a refusal instead of a rewritten binary: $(cat "$T/conf_script.out")"

"$MACHOTOOL" info "$T/conf_verb"   2>/dev/null | grep -q 'also/absent' && vk=kept || vk=deleted
"$MACHOTOOL" info "$T/conf_script" 2>/dev/null | grep -q 'also/absent' && sk=kept || sk=deleted
[ "$vk" = deleted ] && [ "$sk" = kept ] \
    && ok "same-path: replace+delete of one path -- the verb deletes, the script renames" \
    || bad "same-path" "expected verb=deleted script=kept (the divergence this plan authorises), got verb=$vk script=$sk -- if the VERB now keeps the path, the set model's delete-wins rule has changed under a suite that does not test it; if the SCRIPT now deletes, the sequential model has acquired conflict resolution it is supposed to be free of"

reached_end=1
echo "verb_script_equivalence: $fails failure(s)"
[ "$fails" -eq 0 ]
