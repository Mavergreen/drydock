#!/bin/sh
# tests/insert_dylib_test.sh -- compat/insert_dylib.sh's own behaviour: the
# fork's `[flags] dylib_path binary_path [new_binary_path]` grammar
# (Wowfunhappy/insert_dylib, commit bd221b8) translated onto `dylib append`/
# `dylib retype`/`load-command delete codesig`, its five interactive prompts
# (read from /dev/tty, never stdin -- stdin is the statement channel to
# machorewrite), and the divergences compat/README.md's insert_dylib table
# declares.
#
#   sh tests/insert_dylib_test.sh <bindir>
#
# NOT tests/compat-sweep.sh and NOT tests/known-callers.sh. The sweep's
# matrix (tests/compat-matrix.tsv) is a frozen reference for the six
# historical tools, measured against C binaries that no longer exist to
# measure again; regenerating it to admit a seventh tool would destroy what
# it exists to preserve (tests/compat-sweep.sh:23,169). known-callers.sh
# replays REAL callers, and insert_dylib has none -- compat/insert_dylib.sh's
# own header says so. This file is therefore the whole test surface for this
# one wrapper: it plays translate_test's, wrapper_test's and known_callers'
# roles at once, at a scale matching "no known caller" rather than an
# exhaustive sweep.
set -u

BIN="${1:?usage: insert_dylib_test.sh <bindir>}"
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
FIXTURE="$HERE/fixture.macho"
CC="${CC:-clang}"

[ -x "$BIN/insert_dylib" ] || { echo "insert_dylib_test: $BIN/insert_dylib not found or not executable" >&2; exit 1; }
[ -x "$BIN/machorewrite" ] || { echo "insert_dylib_test: $BIN/machorewrite not found or not executable" >&2; exit 1; }

pass=0; fail=0
ok()   { echo "PASS $1"; pass=$((pass + 1)); }
bad()  { echo "FAIL $1: $2" >&2; fail=$((fail + 1)); }
skip() { echo "SKIP $1: $2"; }

T=$(mktemp -d "${TMPDIR:-/tmp}/insert-dylib-test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

sha() { shasum -a 256 < "$1" | cut -d' ' -f1; }

# ---- POSIX sh, not bash, and parses under ksh too (same cross-check every --
# other suite here makes: 10.9's /bin/sh is bash 3.2 in sh mode). -----------
if /bin/sh -n "$ROOT/compat/insert_dylib.sh" 2>"$T/synerr"; then
    ok "sh -n insert_dylib.sh"
else
    bad "sh -n insert_dylib.sh" "$(cat "$T/synerr")"
fi
if [ -x /bin/ksh ]; then
    /bin/ksh -n "$ROOT/compat/insert_dylib.sh" 2>"$T/synerr" \
        && ok "ksh -n insert_dylib.sh" \
        || bad "ksh -n insert_dylib.sh" "$(cat "$T/synerr")"
else
    skip "ksh -n insert_dylib.sh" "/bin/ksh is not present on this host"
fi

# ---- 1. the core act: append, and the output still verifies ---------------
cp "$FIXTURE" "$T/in"
( cd "$T" && "$BIN/insert_dylib" --all-yes /usr/lib/libfoo.dylib in out ) \
    >"$T/1.out" 2>"$T/1.err"
rc=$?
[ "$rc" -eq 0 ] \
    && ok "plain insert: exits 0" \
    || bad "plain insert" "exit $rc: $(cat "$T/1.err")"
"$BIN/machorewrite" verify "$T/out" >/dev/null 2>"$T/1v.err" \
    && ok "plain insert: output verifies" \
    || bad "plain insert" "output does not verify: $(cat "$T/1v.err")"
"$BIN/machorewrite" imports "$T/out" >/dev/null 2>"$T/1i.err" \
    && ok "plain insert: output has readable imports" \
    || bad "plain insert" "imports failed: $(cat "$T/1i.err")"

# ---- 2. --weak really produces LC_LOAD_WEAK_DYLIB --------------------------
# `machorewrite imports` reports the BIND STREAM, not the dylib table, so a
# freshly appended dylib that nothing calls produces ZERO rows -- confirmed
# by hand against tests/fixture.macho, which imports nothing from any
# "libfoo". Observing --weak therefore needs a binary that already imports a
# real symbol from the exact install_name being inserted: built here, from a
# stub .dylib whose install_name IS /usr/lib/libfoo.dylib (the linker
# resolves the symbol from the local file; the install_name baked into the
# executable's LC_LOAD_DYLIB is the one -install_name gave the stub, not the
# stub's real path). `dylib append` then adds a SECOND, duplicate load
# command for the same path, and `dylib retype` retypes every command
# matching that path -- ordinal position, not name, is what the bind stream
# addresses, so the ORIGINAL command (position 1, the one the real bind
# already points at) is retyped to weak right along with the duplicate.
# Measured by hand before writing this: `machorewrite imports` on the result
# shows kind=weak for install_name=/usr/lib/libfoo.dylib.
cat >"$T/foo_stub.c" <<'EOF'
int foo_sym(void) { return 42; }
EOF
cat >"$T/wmain.c" <<'EOF'
int foo_sym(void);
int main(void) { return foo_sym() == 42 ? 0 : 1; }
EOF
"$CC" -dynamiclib -O2 -mmacosx-version-min=10.9 -install_name /usr/lib/libfoo.dylib \
    "$T/foo_stub.c" -o "$T/libfoo_stub.dylib" 2>"$T/wk_build.err" \
    && "$CC" -O2 -mmacosx-version-min=10.9 "$T/wmain.c" "$T/libfoo_stub.dylib" -o "$T/wk_in" 2>>"$T/wk_build.err"
if [ ! -x "$T/wk_in" ]; then
    skip "--weak" "cannot build a fixture that imports from /usr/lib/libfoo.dylib: $(cat "$T/wk_build.err")"
else
    ( cd "$T" && "$BIN/insert_dylib" --all-yes --weak /usr/lib/libfoo.dylib wk_in wk_out ) \
        >"$T/2.out" 2>"$T/2.err"
    rc=$?
    [ "$rc" -eq 0 ] \
        && ok "--weak: exits 0" \
        || bad "--weak" "exit $rc: $(cat "$T/2.err")"
    "$BIN/machorewrite" imports "$T/wk_out" 2>"$T/2i.err" \
        | awk -F'\t' 'NR==1{for(i=1;i<=NF;i++)c[$i]=i}
                      NR>1 && $c["install_name"]=="/usr/lib/libfoo.dylib"{print $c["kind"]}' \
        >"$T/2kinds.txt"
    grep -qx weak "$T/2kinds.txt" \
        && ok "--weak: imports reports a weak dylib command for that install_name" \
        || bad "--weak" "no weak row for /usr/lib/libfoo.dylib; kinds seen: [$(tr '\n' ' ' < "$T/2kinds.txt")], imports stderr: $(cat "$T/2i.err")"
fi

# ---- 3. default output is <binary_path>_patched, APPENDED -----------------
# The fork's own asprintf default. Its README says "prepended"; that is
# wrong, and this is pinned against the source at bd221b8, not the doc.
cp "$FIXTURE" "$T/dflt"
( cd "$T" && "$BIN/insert_dylib" --all-yes /usr/lib/libfoo.dylib dflt ) \
    >"$T/3.out" 2>"$T/3.err"
rc=$?
[ "$rc" -eq 0 ] && [ -f "$T/dflt_patched" ] \
    && ok "default output: <input>_patched exists" \
    || bad "default output" "exit $rc, $T/dflt_patched missing: $(cat "$T/3.err")"
[ -e "$T/dflt.new" ] \
    && bad "default output" "wrote a PREPENDED-style name too -- the README's wrong claim leaked in" \
    || ok "default output: nothing named the README's (wrong) prepended form"

# ---- 4. --inplace writes the input -----------------------------------------
cp "$FIXTURE" "$T/ip"
ip_before=$(sha "$T/ip")
( cd "$T" && "$BIN/insert_dylib" --all-yes --inplace /usr/lib/libfoo.dylib ip ) \
    >"$T/4.out" 2>"$T/4.err"
rc=$?
[ "$rc" -eq 0 ] \
    && ok "--inplace: exits 0" \
    || bad "--inplace" "exit $rc: $(cat "$T/4.err")"
ip_after=$(sha "$T/ip")
[ "$ip_before" != "$ip_after" ] \
    && ok "--inplace: the input file itself changed" \
    || bad "--inplace" "the input file is byte-identical to before"

# ---- 5. no tty and no --all-yes is a refusal, not a hang -------------------
#
# HOW THIS IS TESTED WITHOUT RISKING A HANG. This harness itself may well
# have a controlling terminal (a pty), so simply invoking insert_dylib with
# stdin redirected from /dev/null is NOT enough to make its `exec 3<>/dev/tty`
# fail -- /dev/tty answers "my controlling terminal", which stdin's own
# redirection does not change, and a naive test here would block forever
# waiting for a keystroke nobody is sending. notty.c below detaches the
# child from any controlling terminal with setsid(2) BEFORE it execs
# insert_dylib, so /dev/tty genuinely has nothing to resolve to -- confirmed
# by hand: a tiny probe script prints "TTY-OPENED" run directly in this same
# harness and "NO-TTY" run under notty.
#
# The codesig prompt is the one this reaches: the fixture below is ad-hoc
# signed (LC_CODE_SIGNATURE present), and with neither --strip-codesig nor
# --no-strip-codesig given, that is the first of the five prompts this
# wrapper would have to ask.
cat >"$T/notty.c" <<'EOF'
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    setsid();
    execvp(argv[1], argv + 1);
    return 127;
}
EOF
"$CC" -O2 -o "$T/notty" "$T/notty.c" 2>"$T/notty_build.err"
cp "$FIXTURE" "$T/nt"
if [ ! -x "$T/notty" ]; then
    skip "no tty, no --all-yes" "cannot build tests/notty helper: $(cat "$T/notty_build.err")"
elif ! command -v codesign >/dev/null 2>&1 || ! codesign -s - "$T/nt" >/dev/null 2>&1; then
    # LOUD, not a lone SKIP line ctest's default --output-on-failure hides
    # whenever the run as a whole still passes: this is the suite's ONLY
    # coverage of the codesig prompt actually firing under no-tty, so losing
    # it silently -- e.g. an arm64 CI runner declining ad-hoc codesign of a
    # thin x86_64 fixture -- must not read the same as "everything ran and
    # passed." Not a hard failure either: declining to ad-hoc-sign is a real
    # environment difference, not a bug this suite should be reporting.
    reason="codesign -s - is not available or declined on this host, so the codesig prompt cannot be reached"
    skip "no tty, no --all-yes: refuses (exit 1)" "$reason"
    skip "no tty, no --all-yes: the refusal names why" "$reason"
    skip "no tty, no --all-yes: nothing was written" "$reason"
    echo "insert_dylib_test: SKIPPED the no-tty codesig-prompt case (3 assertions) -- $reason" >&2
else
    ( cd "$T" && "$T/notty" "$BIN/insert_dylib" /usr/lib/libfoo.dylib nt nt_out </dev/null ) \
        >"$T/5.out" 2>"$T/5.err"
    rc=$?
    [ "$rc" -eq 1 ] \
        && ok "no tty, no --all-yes: refuses (exit 1)" \
        || bad "no tty, no --all-yes" "exit $rc (want 1): $(cat "$T/5.err")"
    grep -qi 'tty\|all-yes' "$T/5.err" \
        && ok "no tty, no --all-yes: the refusal names why" \
        || bad "no tty, no --all-yes" "refusal does not say why: $(cat "$T/5.err")"
    [ ! -e "$T/nt_out" ] \
        && ok "no tty, no --all-yes: nothing was written" \
        || bad "no tty, no --all-yes" "wrote $T/nt_out despite refusing"
fi

# AND: the refusal above is really about THIS prompt, not "no tty, ever" --
# --no-strip-codesig takes prompt 1 off the table entirely ("do not emit it,
# and do not prompt"), so the very same no-tty invocation succeeds once that
# is the only prompt in its way. A dylib path that is a REAL file (so prompt
# 5 does not fire) but not already named by "$T/nt"'s own load commands
# (tests/fixture.macho already links /usr/lib/libSystem.B.dylib, so THAT
# path would trigger prompt 2 instead) -- an empty file of this test's own
# making clears both.
#
# DELIBERATELY OUTSIDE the codesign-gated block above: --no-strip-codesig's
# whole point is that it removes the codesig prompt unconditionally, whether
# or not "$T/nt" actually carries a code signature -- this assertion never
# needed `codesign -s -` to succeed, and gating it on that dependency the
# same way as the three above would lose coverage this host's codesign
# cannot affect either way.
: >"$T/fake.dylib"
if [ ! -x "$T/notty" ]; then
    skip "no tty: --no-strip-codesig removes the one prompt in the way, so this succeeds" \
        "cannot build tests/notty helper: $(cat "$T/notty_build.err")"
else
    ( cd "$T" && "$T/notty" "$BIN/insert_dylib" --no-strip-codesig \
        fake.dylib nt nt_out2 </dev/null ) >"$T/5b.out" 2>"$T/5b.err"
    rc=$?
    [ "$rc" -eq 0 ] \
        && ok "no tty: --no-strip-codesig removes the one prompt in the way, so this succeeds" \
        || bad "no tty, --no-strip-codesig" "exit $rc (want 0): $(cat "$T/5b.err")"
fi

# ---- 6. 32-bit input is refused, and says so -------------------------------
# A DECLARED DIVERGENCE from the fork, which handles 32-bit input; this
# toolkit refuses it everywhere, deliberately (docs/prior-art.md).
cat >"$T/mk32.c" <<'EOF'
#include <stdio.h>
#include <string.h>
#include <mach-o/loader.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    unsigned char buf[4096];
    memset(buf, 0, sizeof buf);
    struct mach_header *h = (struct mach_header *)buf;
    h->magic = MH_MAGIC;
    h->cputype = CPU_TYPE_I386;
    h->cpusubtype = CPU_SUBTYPE_I386_ALL;
    h->filetype = MH_EXECUTE;
    h->ncmds = 0;
    h->sizeofcmds = 0;
    h->flags = 0;
    FILE *f = fopen(argv[1], "wb");
    if (!f) return 2;
    fwrite(buf, 1, sizeof buf, f);
    fclose(f);
    return 0;
}
EOF
"$CC" -O2 -o "$T/mk32" "$T/mk32.c" 2>"$T/mk32_build.err"
if [ ! -x "$T/mk32" ]; then
    skip "32-bit refused" "cannot build a 32-bit fixture generator: $(cat "$T/mk32_build.err")"
else
    "$T/mk32" "$T/fixture32.macho"
    ( cd "$T" && "$BIN/insert_dylib" --all-yes /usr/lib/libfoo.dylib fixture32.macho fixture32.out ) \
        >"$T/6.out" 2>"$T/6.err"
    rc=$?
    [ "$rc" -eq 1 ] \
        && ok "32-bit refused: exit 1" \
        || bad "32-bit refused" "exit $rc (want 1): $(cat "$T/6.err")"
    grep -qi '32' "$T/6.err" \
        && ok "32-bit refused: the refusal names the reason" \
        || bad "32-bit refused" "refusal does not name the reason: $(cat "$T/6.err")"
    [ ! -e "$T/fixture32.out" ] \
        && ok "32-bit refused: nothing was written" \
        || bad "32-bit refused" "wrote $T/fixture32.out despite refusing"
fi

# ---- 7. an unknown/unhandled load command is refused, where the fork -------
#         proceeds. A DECLARED DIVERGENCE: LC_LAZY_LOAD_DYLIB (the legacy
# -lazy_library form) carries a library ordinal exactly like LC_LOAD_DYLIB
# does, but src/ordinals.c's mo_map_build has never had its renumbering
# semantics exercised and refuses outright rather than guess -- the same
# refusal compat/change_dylib.sh's own suite pins (tests/change_dylib_test.sh
# case 15). `dylib append` goes through the same mo_map_build, so this
# wrapper inherits the refusal with no code of its own.
#
# HOST PORTABILITY: `-lazy_library` is a legacy ld flag with no portability
# guarantee across linkers, so this reads the fixture's OWN load commands
# with a tiny C helper (never otool/nm text) to confirm LC_LAZY_LOAD_DYLIB
# is really there before asserting anything -- same technique
# tests/change_dylib_test.sh's case 15 uses, for the same reason.
cat >"$T/has_lc.c" <<'EOF'
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <mach-o/loader.h>
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    uint32_t want = (uint32_t)strtoul(argv[2], NULL, 16);
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) return 2;
    struct stat st; fstat(fd, &st);
    uint8_t *buf = malloc((size_t)st.st_size);
    if (!buf || read(fd, buf, (size_t)st.st_size) != (ssize_t)st.st_size) return 2;
    close(fd);
    struct mach_header_64 *hdr = (struct mach_header_64 *)buf;
    if (hdr->magic != MH_MAGIC_64) return 2;
    uint8_t *lcp = buf + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        struct load_command *lc = (struct load_command *)lcp;
        if (lc->cmd == want) return 0;
        lcp += lc->cmdsize;
    }
    return 1;
}
EOF
"$CC" -O2 -o "$T/has_lc" "$T/has_lc.c" 2>"$T/has_lc_build.err"
cat >"$T/lazy_a.c" <<'EOF'
int lazy_a_sym(void) { return 77; }
EOF
cat >"$T/lazy_main.c" <<'EOF'
int lazy_a_sym(void);
int main(void) { return lazy_a_sym() == 77 ? 0 : 1; }
EOF
if [ ! -x "$T/has_lc" ]; then
    skip "unknown load command refused" "cannot build tests/has_lc helper: $(cat "$T/has_lc_build.err")"
else
    "$CC" -dynamiclib -O2 -mmacosx-version-min=10.9 -install_name "@loader_path/liblazy_a.dylib" \
        "$T/lazy_a.c" -o "$T/liblazy_a.dylib" 2>"$T/lazy.err"
    "$CC" -O2 -mmacosx-version-min=10.9 "$T/lazy_main.c" \
        -Xlinker -lazy_library -Xlinker "$T/liblazy_a.dylib" -o "$T/lazy_main" 2>>"$T/lazy.err" || true
    if [ ! -x "$T/lazy_main" ] || ! "$T/has_lc" "$T/lazy_main" 0x20; then
        skip "unknown load command refused" "this host's linker did not produce an LC_LAZY_LOAD_DYLIB from -lazy_library ($(head -1 "$T/lazy.err" 2>/dev/null || echo "no diagnostic"))"
    else
        before=$(sha "$T/lazy_main")
        ( cd "$T" && "$BIN/insert_dylib" --all-yes /usr/lib/libfoo.dylib lazy_main lazy_main.out ) \
            >"$T/7.out" 2>"$T/7.err"
        rc=$?
        [ "$rc" -ne 0 ] \
            && ok "unknown load command (LC_LAZY_LOAD_DYLIB): refuses" \
            || bad "unknown load command" "exited 0 instead of refusing"
        [ "$(sha "$T/lazy_main")" = "$before" ] \
            && ok "unknown load command: input left untouched on refusal" \
            || bad "unknown load command" "input was modified despite the refusal"
    fi
fi

# ---- 8. --overwrite suppresses prompt 4 (OUT already exists) --------------
# Reuses the notty helper built for case 5 above. --no-strip-codesig and a
# local, empty "dylib" keep prompts 1, 2 and 5 out of the way, so prompt 4 is
# the only one either invocation below can reach.
cp "$FIXTURE" "$T/ov"
: >"$T/ov_out"
: >"$T/ov.dylib"
if [ ! -x "$T/notty" ]; then
    skip "--overwrite" "no notty helper (see the no-tty case above)"
else
    ( cd "$T" && "$T/notty" "$BIN/insert_dylib" --no-strip-codesig \
        ov.dylib ov ov_out </dev/null ) >"$T/8a.out" 2>"$T/8a.err"
    rc=$?
    [ "$rc" -eq 1 ] \
        && ok "no --overwrite: an existing OUT refuses (prompt 4, no tty to ask on)" \
        || bad "no --overwrite" "exit $rc (want 1): $(cat "$T/8a.err")"

    ( cd "$T" && "$T/notty" "$BIN/insert_dylib" --no-strip-codesig --overwrite \
        ov.dylib ov ov_out </dev/null ) >"$T/8b.out" 2>"$T/8b.err"
    rc=$?
    [ "$rc" -eq 0 ] \
        && ok "--overwrite: the same existing-OUT case succeeds without asking at all" \
        || bad "--overwrite" "exit $rc (want 0): $(cat "$T/8b.err")"
fi

# ---- 9. prompt 2: the binary already names this dylib ----------------------
# tests/fixture.macho already links /usr/lib/libSystem.B.dylib (confirmed by
# hand: `machorewrite info` shows "ordinal=1 path=/usr/lib/libSystem.B.dylib"),
# so inserting that exact path is the direct way to reach this prompt's
# detect step, not just steer around it. --no-strip-codesig keeps prompt 1
# out of the way; the path is real, so prompt 5 cannot fire either.
cp "$FIXTURE" "$T/dup"
if [ ! -x "$T/notty" ]; then
    skip "prompt 2 (duplicate dylib)" "no notty helper (see the no-tty case above)"
else
    ( cd "$T" && "$T/notty" "$BIN/insert_dylib" --no-strip-codesig \
        /usr/lib/libSystem.B.dylib dup dup_out </dev/null ) >"$T/9.out" 2>"$T/9.err"
    rc=$?
    [ "$rc" -eq 1 ] \
        && ok "prompt 2: a dylib the binary already names refuses (no tty to ask on)" \
        || bad "prompt 2" "exit $rc (want 1): $(cat "$T/9.err")"

    # --all-yes answers yes rather than refusing, and the duplicate is added
    # anyway -- insert_dylib never de-duplicates -- so the binary ends up
    # with TWO load commands naming the same path.
    ( cd "$T" && "$BIN/insert_dylib" --all-yes --no-strip-codesig \
        /usr/lib/libSystem.B.dylib dup dup_out2 ) >"$T/9b.out" 2>"$T/9b.err"
    rc=$?
    [ "$rc" -eq 0 ] \
        && ok "prompt 2: --all-yes proceeds past the duplicate" \
        || bad "prompt 2 --all-yes" "exit $rc (want 0): $(cat "$T/9b.err")"
    got=$("$BIN/machorewrite" info "$T/dup_out2" 2>/dev/null \
        | grep -c 'path=/usr/lib/libSystem\.B\.dylib$')
    [ "$got" -eq 2 ] \
        && ok "prompt 2: the duplicate was really added (two load commands now name it)" \
        || bad "prompt 2 duplicate count" "got $got load command(s) naming it, want 2"
fi

# ---- 10. prompt 5: the dylib path itself does not exist -------------------
# A path this test invents, not steered around: --no-strip-codesig keeps
# prompt 1 out of the way, and nothing in "$FIXTURE" already names it, so
# prompt 2 cannot fire either.
cp "$FIXTURE" "$T/pf"
if [ ! -x "$T/notty" ]; then
    skip "prompt 5 (dylib path absent)" "no notty helper (see the no-tty case above)"
else
    ( cd "$T" && "$T/notty" "$BIN/insert_dylib" --no-strip-codesig \
        /nonexistent/definitely/not/here.dylib pf pf_out </dev/null ) \
        >"$T/10.out" 2>"$T/10.err"
    rc=$?
    [ "$rc" -eq 1 ] \
        && ok "prompt 5: a dylib path that does not exist refuses (no tty to ask on)" \
        || bad "prompt 5" "exit $rc (want 1): $(cat "$T/10.err")"

    ( cd "$T" && "$BIN/insert_dylib" --all-yes --no-strip-codesig \
        /nonexistent/definitely/not/here.dylib pf pf_out2 ) >"$T/10b.out" 2>"$T/10b.err"
    rc=$?
    [ "$rc" -eq 0 ] \
        && ok "prompt 5: --all-yes proceeds despite the path not existing" \
        || bad "prompt 5 --all-yes" "exit $rc (want 0): $(cat "$T/10b.err")"
fi

# ---- 11. --strip-codesig really removes LC_CODE_SIGNATURE -----------------
# Dropping the statement compat/translate.sh emits for --strip-codesig would
# not be caught by any case above: this is the one assertion that reads the
# OUTPUT's own load commands and finds LC_CODE_SIGNATURE gone, not merely
# that the run exited 0.
cp "$FIXTURE" "$T/cs"
if command -v codesign >/dev/null 2>&1 && codesign -s - "$T/cs" >/dev/null 2>&1; then
    ( cd "$T" && "$BIN/insert_dylib" --all-yes --strip-codesig \
        /usr/lib/libfoo.dylib cs cs_out ) >"$T/11.out" 2>"$T/11.err"
    rc=$?
    [ "$rc" -eq 0 ] \
        && ok "--strip-codesig: exits 0" \
        || bad "--strip-codesig" "exit $rc: $(cat "$T/11.err")"
    "$BIN/machorewrite" info "$T/cs_out" 2>/dev/null | grep -q LC_CODE_SIGNATURE \
        && bad "--strip-codesig" "LC_CODE_SIGNATURE is still present in the output" \
        || ok "--strip-codesig: LC_CODE_SIGNATURE is gone from the output"
else
    skip "--strip-codesig" "codesign -s - is not available on this host"
fi

# ---- 12. --weak's two statements run in the right order --------------------
# Section 2's fixture already carried a load command for the path being
# inserted (needed there so `imports` had a real bind to report against),
# which means `dylib retype` would find something to weaken whichever
# statement ran first -- order was never actually observed. Here the path is
# NOT already present in "$FIXTURE": `dylib retype` on a path nothing names
# yet is a silent no-op (`machorewrite: PATH matched nothing`, exit 0 --
# confirmed by hand), so a swapped emission order would still exit 0 and
# still install a binary, just one whose new load command stayed
# LC_LOAD_DYLIB instead of becoming LC_LOAD_WEAK_DYLIB. `machorewrite info`
# names the load-command KIND on its own "LC[n] <NAME> cmdsize=..." line, so
# this reads that rather than the exit code.
cp "$FIXTURE" "$T/ord"
( cd "$T" && "$BIN/insert_dylib" --all-yes --weak --no-strip-codesig \
    /usr/lib/libfoo.dylib ord ord_out ) >"$T/12.out" 2>"$T/12.err"
rc=$?
[ "$rc" -eq 0 ] \
    && ok "--weak order: exits 0" \
    || bad "--weak order" "exit $rc: $(cat "$T/12.err")"
"$BIN/machorewrite" info "$T/ord_out" 2>/dev/null | grep -q LC_LOAD_WEAK_DYLIB \
    && ok "--weak order: append then retype -- the new command is LC_LOAD_WEAK_DYLIB" \
    || bad "--weak order" "no LC_LOAD_WEAK_DYLIB in the output; retype ran before append had anything to retype"

# ---- 13. --inplace plus an explicit new_binary_path: REFUSED -------------
# A DECLARED DIVERGENCE from the fork, this one the other direction from
# case 6 above: the fork does not refuse this combination, it silently picks
# one file to write and ignores the other (--inplace wins; the 3rd
# positional is never even read) -- measured by hand against a real build of
# the fork (tests/insert-dylib-diff.sh's 2026-09-20 run, task-8 report).
# Matching that would mean silently overwriting the caller's input instead
# of the output path they explicitly named, or vice versa: the data-loss
# shape this toolkit refuses rather than guesses through everywhere else.
# compat/translate.sh's mt_id_parse refuses it unconditionally, before any
# prompt -- so --all-yes must NOT make this succeed either.
cp "$FIXTURE" "$T/mx"
mx_before=$(sha "$T/mx")
( cd "$T" && "$BIN/insert_dylib" --all-yes --inplace /usr/lib/libfoo.dylib mx mx_out ) \
    >"$T/13.out" 2>"$T/13.err"
rc=$?
[ "$rc" -eq 1 ] \
    && ok "--inplace + new_binary_path: refuses (exit 1), --all-yes does not override it" \
    || bad "--inplace + new_binary_path" "exit $rc (want 1): $(cat "$T/13.err")"
grep -q -- '--inplace' "$T/13.err" && grep -q 'mx_out' "$T/13.err" \
    && ok "--inplace + new_binary_path: the refusal names both --inplace and the path" \
    || bad "--inplace + new_binary_path" "refusal does not name both: $(cat "$T/13.err")"
[ "$(sha "$T/mx")" = "$mx_before" ] \
    && ok "--inplace + new_binary_path: the input is untouched" \
    || bad "--inplace + new_binary_path" "input was modified despite refusing"
[ ! -e "$T/mx_out" ] \
    && ok "--inplace + new_binary_path: nothing was written to the named path either" \
    || bad "--inplace + new_binary_path" "wrote $T/mx_out despite refusing"

echo "insert_dylib_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
