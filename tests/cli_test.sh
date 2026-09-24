#!/bin/sh
# tests/cli_test.sh — exercises the drydock-macho-rewrite CLI itself: --capabilities, the
# three read-only verbs (verify, info, imports), and the bare `FILE OUT` form
# that is the only way to change a binary.
#
# THE NINE MUTATING VERBS ARE GONE (declassify, segment, retag-swift, minos,
# lc, dylib, rpath, grow, edit). For the first seven, every assertion that used to
# run one runs its statement equivalent instead, keeping its own question and
# its own FAIL message: the property under test was always the REWRITE, never
# the spelling that reached it. The equivalence was proved byte for byte before
# those verbs were deleted.
#
# `grow FILE OUT N` had no statement equivalent and was deleted outright, so
# its section here is gone rather than converted. What that section proved
# about mg_grow_header -- that it refuses an image with no section data, and
# one whose first section lies past the end of the file, rather than wrapping
# `fsize - insert` and dying of SIGSEGV -- is proved hermetically now, in
# tests/grow_test.c, which calls mg_grow_header directly.
#
# Of the CLI-shaped facts that went with the verb, only ONE is asserted here of
# the bare form and of `edit`: that OUT is not FILE. The other two are not, and
# saying so is the point of this paragraph -- an earlier draft claimed all three
# were, which is the kind of claim this suite exists to stop anyone making.
#   - a symlinked OUT is followed: survives only through the wrapper, at
#     tests/change_dylib_test.sh:1116-1128. Nothing in this file covers it.
#   - N=0 is refused: has no successor and can have none. `grow N` was the only
#     form taking a byte count; no statement does.
#
# What this does NOT re-prove: change_dylib_test.sh already runs real dylib
# renumbering, insert/delete ordinal correctness, and header-growth end to
# end, through change_dylib. The statements here call the very same
# code -- src/edit.c into src/rewrite.c and src/version_min.c, which is all
# change_dylib and add_version_min are too (see cli/drydock-macho-rewrite.c's file
# header) -- so this asserts the TRANSLATION and DISPATCH are correct, one
# exemplar op per statement kind, not the underlying rewrite a second time.
#
# Host-portability, per the task's own hard-won rules:
#   - every fixture is built with -mmacosx-version-min=10.9, so a modern
#     linker's LC_DYLD_CHAINED_FIXUPS default can't sneak in and ask a
#     different question on the cross runner than it asks natively here.
#   - nothing here parses otool/nm text. Facts about a binary come either
#     from `drydock-macho-rewrite info`'s own stable output, or from a tiny C reader built
#     alongside the fixtures (same trick change_dylib_test.sh's ordinal_of.c
#     uses), never from a format Apple's tools are free to reformat.
set -eu
BIN="${1:?usage: cli_test.sh <bindir>}"
DRYDOCK_MACHO_REWRITE="$BIN/drydock-macho-rewrite"
[ -x "$DRYDOCK_MACHO_REWRITE" ] || { echo "cli_test: $DRYDOCK_MACHO_REWRITE not found or not executable" >&2; exit 1; }
[ -x "$BIN/makefat" ] && [ -x "$BIN/fatcheck" ] || { echo "cli_test: need makefat and fatcheck in $BIN" >&2; exit 1; }
# drydock-macho-rewrite needs NOTHING else in $BIN: the rewriting verbs used to run
# change_dylib/add_version_min as subprocesses found next to it, and this
# script used to refuse to start without them. The "drydock-macho-rewrite alone in an empty
# directory" assertions below are what replaced that requirement -- they check
# the property the requirement existed for, from the outside, instead of
# taking it on trust.

CC="${CC:-clang}"
# This script's own directory, for the fixture-builder C sources that live
# beside it (tests/strip_version_min.c).
HERE=$(cd "$(dirname "$0")" && pwd)
# platform: x86_64, which is what this toolkit targets, on every host: a
# modern runner's clang builds arm64 by default, whose 16 KB pages the header
# grow refuses.
FIXTURE_FLAGS="-arch x86_64 -mmacosx-version-min=10.9"
T="${TMPDIR:-/tmp}/cli_test.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

fails=0
ok()   { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fails=$((fails + 1)); }
# Not a failure: the assertion could not be exercised on this host. Printed
# loudly and distinctly from PASS/FAIL, per-assertion, rather than silently
# omitted -- a silent skip is how coverage rots. Does not touch $fails.
skip() { echo "SKIP $1: $2"; }
# A file's content digest, for "untouched"/"unchanged" assertions -- the same
# shasum invocation already used a few times below, named once so the `edit`
# section (which needs it three times) doesn't repeat the pipeline.
sha()  { shasum -a 256 < "$1" | cut -d' ' -f1; }
# unpie FILE -- clear MH_PIE, so a header grow refuses FILE ("not PIE").
# platform: MH_PIE is 0x00200000 in the little-endian flags word at offset
# 24, so bit 0x20 of byte 26.
unpie() {
    unpie_b=$(od -An -tu1 -j26 -N1 "$1" | tr -d ' ')
    printf "\\$(printf %o $((unpie_b & ~32)))" | dd of="$1" bs=1 seek=26 conv=notrunc 2>/dev/null
}

# mts FILE STATEMENT...  -- run the bare `drydock-macho-rewrite FILE OUT` form and leave
# its result AT FILE, with each argument written as one line of the script on
# stdin. This is what every assertion that used to name a mutating verb runs
# now, and it is the ONLY route to a rewrite there is: `mts "$f" 'dylib replace
# A B'` is what `machotool dylib "$f" -replace A B` used to be.
#
# WHY A HELPER AT ALL: drydock-macho-rewrite takes `FILE OUT` and never writes FILE, but
# most of the assertions below were written when the rewriting verbs rewrote
# FILE, and they are about the REWRITE -- which load command moved, which
# ordinal was renumbered, what the run printed, what it refused -- not about
# which path the bytes land in. So they keep asking their own question, of a
# file this helper puts the result back into: run with a temp beside FILE as
# OUT, then mv the temp over FILE, which is precisely the two steps the compat
# wrappers take (compat/drydock-macho-rewrite-compat.sh's install path).
#
# WHAT THIS DOES NOT HIDE: that FILE is never written by drydock-macho-rewrite itself is
# asserted directly in "the mutating form never writes its input" below --
# against FILE's bytes AND its inode, with no helper in the way. This one is an
# ergonomic for everything else, not a stand-in for that.
#
# A directive is just another line: a leading argument such as
# `allow-unmatched` becomes a directive line -- which is why the arguments
# stay in the order they were given.
#
# printf '%s\n' over the argument list rather than a heredoc per call site: the
# statements are then visible ON the call line, next to the assertion that reads
# their effect, which a heredoc twelve lines further down is not.
#
# BOTH STREAMS ARE FILTERED, and they stay separate. A script run reports on
# stderr ("<OUT>: written (N,NNN bytes)") where the verbs reported on stdout
# ("Wrote <OUT> (N bytes)"); each names the temp, which no assertion here asked
# about, so each is dropped from the stream it arrives on. Callers that redirect
# only one of the two still see the other unchanged. Each filter passes its
# prefix through the ENVIRONMENT, not `awk -v`: that escape-processes what it
# assigns, so a $T containing a backslash would leave the line unsuppressed.
# compat/drydock-macho-rewrite-compat.sh's mw_run_to_tmp, which this mirrors, has the
# measurement.
mts() {
    mts_file=$1; shift
    mts_tmp="$mts_file.mtip"
    rm -f "$mts_tmp"
    mts_rc=0
    printf '%s\n' "$@" | "$DRYDOCK_MACHO_REWRITE" "$mts_file" "$mts_tmp" \
        >"$T/mts.out" 2>"$T/mts.err" || mts_rc=$?
    MTIP_PREFIX="Wrote $mts_tmp (" awk 'index($0, ENVIRON["MTIP_PREFIX"]) != 1' "$T/mts.out"
    MTIP_PREFIX="$mts_tmp: written (" awk 'index($0, ENVIRON["MTIP_PREFIX"]) != 1' "$T/mts.err" >&2
    if [ "$mts_rc" -eq 0 ]; then
        mv -f "$mts_tmp" "$mts_file" || return 2
    else
        rm -f "$mts_tmp"
    fi
    return "$mts_rc"
}

# `set -e` means any bare command that exits nonzero kills the WHOLE script
# immediately -- which has already happened for real (a helper's exit
# convention bug took every verb's tests after it down silently, with only
# a generic CTest error to show for it: twenty-plus assertions never ran,
# and nothing said so). This does not remove `set -e` -- the fix stays
# targeted -- but an early death is no longer silent: reached_end is set to
# 1 only at the very end, right before the summary line, so an EXIT trap
# firing while it is still 0 means the script did NOT reach its own
# summary, and says so loudly, with the exit code that killed it.
reached_end=0
trap 'rc=$?; if [ "$reached_end" -eq 0 ]; then
    echo "cli_test: FATAL -- aborted early (a command exited $rc under set -e); the suite did NOT run to completion, and everything after the last PASS/FAIL/SKIP line above never ran" >&2
fi' EXIT

# --- fixtures --------------------------------------------------------------
cat > "$T/a.c" <<'EOF'
int a_sym(void) { return 11; }
EOF
cat > "$T/main.c" <<'EOF'
#include <stdio.h>
int a_sym(void);
int main(void) { return a_sym() == 11 ? 0 : 1; }
EOF
"$CC" -dynamiclib -O2 $FIXTURE_FLAGS -install_name "@loader_path/liba.dylib" \
    "$T/a.c" -o "$T/liba.dylib"

build_main() {
    # $2 (optional): an extra -Xlinker -rpath search path baked in at link time.
    if [ -n "${2:-}" ]; then
        "$CC" -O2 $FIXTURE_FLAGS -Xlinker -rpath -Xlinker "$2" \
            "$T/main.c" "$T/liba.dylib" -o "$1"
    else
        "$CC" -O2 $FIXTURE_FLAGS "$T/main.c" "$T/liba.dylib" -o "$1"
    fi
}

# Two dylibs ahead of the libSystem clang appends, in THIS link order:
# libb (ordinal 1), which nothing binds to, then liba (ordinal 2), which
# main's a_sym binds to; libSystem is 3. Both halves of that are needed by
# the `edit` follow-up assertions below. Nothing may bind to libb,
# or `dylib delete` refuses it outright. And libb must come BEFORE a dylib
# with binds, or deleting it renumbers nothing and every count it reports is
# a vacuous zero. libb gets no -install_name, so its install name is the path
# it was linked from, "$T/libb.dylib" -- the path a script names to delete it.
# The linker keeps an unreferenced dylib unless told to dead-strip them.
cat > "$T/b.c" <<'EOF'
int b_sym(void) { return 22; }
EOF
"$CC" -dynamiclib -O2 $FIXTURE_FLAGS "$T/b.c" -o "$T/libb.dylib"
# A third dylib, bound to, for proving the reported counts follow the input.
cat > "$T/c.c" <<'EOF'
int c_sym(void) { return 33; }
EOF
"$CC" -dynamiclib -O2 $FIXTURE_FLAGS -install_name "@loader_path/libc3.dylib" \
    "$T/c.c" -o "$T/libc3.dylib"
cat > "$T/main3.c" <<'EOF'
int a_sym(void);
int c_sym(void);
int main(void) { return a_sym() == 11 && c_sym() == 33 ? 0 : 1; }
EOF

# The ordinals above are the premise, so check them rather than trust the
# linker: `drydock-macho-rewrite info`'s own stable output, as the header says.
fixture_ordinals() {
    fo_info=$("$DRYDOCK_MACHO_REWRITE" info "$1")
    shift
    for fo_want in "$@"; do
        echo "$fo_info" | grep -qF "$fo_want" \
            || bad "fixture setup" "expected '$fo_want' in: $fo_info"
    done
}
build_main_two_dylibs() {
    "$CC" -O2 $FIXTURE_FLAGS "$T/main.c" "$T/libb.dylib" "$T/liba.dylib" -o "$1"
    fixture_ordinals "$1" "ordinal=1 path=$T/libb.dylib" \
        "ordinal=2 path=@loader_path/liba.dylib" "ordinal=3 path=/usr/lib/libSystem.B.dylib"
}
# The same, with a third dylib that main also binds to after liba:
# libb=1, liba=2, libc3=3, libSystem=4.
build_main_three_dylibs() {
    "$CC" -O2 $FIXTURE_FLAGS "$T/main3.c" "$T/libb.dylib" "$T/liba.dylib" \
        "$T/libc3.dylib" -o "$1"
    fixture_ordinals "$1" "ordinal=1 path=$T/libb.dylib" \
        "ordinal=2 path=@loader_path/liba.dylib" "ordinal=3 path=@loader_path/libc3.dylib" \
        "ordinal=4 path=/usr/lib/libSystem.B.dylib"
}

# A fixture GUARANTEED not to carry LC_BUILD_VERSION, on any host.
#
# The three "-delete build-version is a miss" assertions below used to build
# a plain build_main fixture and rely on a comment claiming "-mmacosx-version
# -min=10.9 clang never emits build-version (confirmed empirically)". That
# was confirmed on 10.9 only, and it is FALSE on the cross/CI runner, whose
# modern linker emits LC_BUILD_VERSION anyway: the delete then SUCCEEDS, no
# miss is reported, and all three assertions fail. Green on the target,
# red on the runner -- the same host-toolchain dependence that bit the
# rpath -insert headerpad fixture.
#
# So stop asserting what a linker emits and MAKE the premise true: strip the
# kind first, unconditionally. A no-op where it was already absent.
#
# This uses drydock-macho-rewrite to set up a drydock-macho-rewrite test, which is circular only in
# appearance: if the strip silently did nothing, the delete under test would
# FIND build-version and report no miss, and the assertions fail loudly. The
# setup cannot mask the defect it is setting up for.
build_main_without_build_version() {
    build_main "$1"
    mts "$1" "load-command delete build-version" >/dev/null 2>&1 || true
    # Assert the precondition rather than trusting the strip. otool, not
    # drydock-macho-rewrite, so a drydock-macho-rewrite defect cannot certify its own setup. Without this
    # the test would pass on 10.9 for the OLD reason (the linker never
    # emitted it) and silently stop testing anything the day it does.
    if otool -l "$1" 2>/dev/null | grep -q LC_BUILD_VERSION; then
        bad "fixture setup" "build_main_without_build_version left LC_BUILD_VERSION in $1"
    fi
}

# ---------------------------------------------------------------------------
# Host capability: can this host run a Mach-O binary that was modified
# in-place after being signed at link time, AT ALL?
#
# This must be established WITHOUT running drydock-macho-rewrite on the probe binary. The
# `lc` "still runs" assertions below rewrite a fixture with drydock-macho-rewrite and
# then run it; if this host's kernel kills any modified binary, that proves
# nothing about drydock-macho-rewrite -- but if the probe used to detect that ALSO goes
# through drydock-macho-rewrite, a real drydock-macho-rewrite regression that corrupts its output looks
# IDENTICAL to a host that kills modified binaries: same symptom (the child
# doesn't run), same wrong conclusion ("host policy, not a drydock-macho-rewrite defect"),
# and a genuine defect ships as a green, honest-looking SKIP. That is worse
# than no check at all.
#
# So this probe never calls drydock-macho-rewrite. It builds a plain fixture, flips ONE
# byte inside the existing header pad (unused space between the end of the
# load commands and the first section's file data -- computed here by an
# independent read, not by calling into drydock-macho-rewrite/image.h, for the same
# non-circularity reason tests/strip_version_min.c is self-contained) via a
# throwaway C program, and tries to run the result. If the kernel/dyld kills
# THAT, this host enforces code-signing on any post-link modification,
# unconditionally of what changed or which tool changed it -- an honest,
# independently-established fact the `lc` sections can trust. If it
# still runs, this host does NOT enforce that, and a failure to run
# drydock-macho-rewrite's OWN rewritten fixture later is no longer explainable by host
# policy -- it must be treated as a real defect (FAIL), not silently
# skipped.
cat > "$T/perturb_pad.c" <<'EOF'
/* Flip one byte inside a Mach-O's header pad (the unused space between the
 * end of the load commands and the first section's file data) -- content
 * no code path reads, so this is semantically inert, but it still changes
 * the file's bytes, which is all a code-signature hash cares about.
 * Exit 0 = flipped one byte, 4 = no pad available, 2 = error. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <mach-o/loader.h>

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: %s FILE\n", argv[0]); return 2; }
    int fd = open(argv[1], O_RDWR);
    if (fd < 0) { perror("open"); return 2; }
    struct stat st;
    if (fstat(fd, &st) != 0) { perror("fstat"); close(fd); return 2; }
    size_t size = (size_t)st.st_size;
    uint8_t *buf = malloc(size);
    if (!buf || read(fd, buf, size) != (ssize_t)size) {
        fprintf(stderr, "read failed\n"); close(fd); return 2;
    }
    struct mach_header_64 *hdr = (struct mach_header_64 *)buf;
    if (hdr->magic != MH_MAGIC_64) { fprintf(stderr, "not a 64-bit Mach-O\n"); return 2; }

    uint32_t first_sect_off = UINT32_MAX;
    uint8_t *lcp = buf + sizeof(*hdr);
    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        struct load_command *lc = (struct load_command *)lcp;
        if (lc->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *seg = (struct segment_command_64 *)lcp;
            struct section_64 *sect = (struct section_64 *)(lcp + sizeof(*seg));
            for (uint32_t j = 0; j < seg->nsects; j++)
                if (sect[j].offset && sect[j].offset < first_sect_off)
                    first_sect_off = sect[j].offset;
        }
        lcp += lc->cmdsize;
    }
    uint32_t lc_end = (uint32_t)sizeof(*hdr) + hdr->sizeofcmds;
    if (first_sect_off == UINT32_MAX || first_sect_off <= lc_end) {
        fprintf(stderr, "no header pad available to perturb\n");
        return 4;
    }
    buf[lc_end] ^= 0xFF;   /* the first pad byte; never read by any load command */

    lseek(fd, 0, SEEK_SET);
    if (write(fd, buf, size) != (ssize_t)size) { perror("write"); return 2; }
    close(fd);
    return 0;
}
EOF
"$CC" -O2 -o "$T/perturb_pad" "$T/perturb_pad.c"

build_main "$T/signing_probe"
if "$T/perturb_pad" "$T/signing_probe" >"$T/perturb.out" 2>&1; then
    if (cd "$T" && ./signing_probe) >"$T/signing_probe.out" 2>&1; then
        signing_probe_rc=0
    else
        signing_probe_rc=$?
    fi
else
    signing_probe_rc=$?   # 4 = no pad (fixture too tight -- treat as "can't determine")
fi
if [ "$signing_probe_rc" -eq 0 ]; then
    signing_enforced=0
    ok "host probe: a trivially-perturbed binary still runs (drydock-macho-rewrite-independent)"
elif [ "$signing_probe_rc" -eq 137 ]; then
    signing_enforced=1
    ok "host probe: a trivially-perturbed binary is SIGKILLed (137) -- code-signing enforcement, independent of drydock-macho-rewrite"
else
    # Neither a clean run nor the specific signal we know how to explain.
    # Per the coordinator: do not guess. Anything unrecognized here means the
    # `lc` sections below cannot trust EITHER conclusion, so they must not
    # silently skip. That is fully achieved by leaving signing_enforced at 0:
    # the `lc` sections below gate their run-assertions on
    # `signing_enforced -eq 1` (skip only when enforcement is POSITIVELY
    # confirmed), so 0 here already means "treat as real, don't skip" for
    # this unrecognized case exactly as it does for the confirmed-unenforced
    # one -- a separate signing_probe_unknown flag was tracked alongside this
    # for a time but nothing downstream ever read it (confirmed: no other
    # reference to it in this file), so it added a state without adding
    # behavior. Removed rather than left to imply a distinction that wasn't
    # there.
    signing_enforced=0
    bad "host probe" "unrecognized outcome (exit $signing_probe_rc: $(head -1 "$T/signing_probe.out" 2>/dev/null || cat "$T/perturb.out" 2>/dev/null || echo 'no output')) -- cannot determine whether this host enforces code-signing on modified binaries; treating those run-assertions as real rather than risking a masked defect"
fi

# A "is this host Darwin 13" probe stood here, read by exactly one assertion:
# the `grow` section's "does the grown binary still run". mg_grow_header's
# image-base-lowering trick is only promised to load on the product's target
# platform, so that assertion was hard there and a SKIP elsewhere. The verb is
# gone and nothing else asked the question, so the probe went with it rather
# than sit here computing an answer no assertion reads.

# ============================================================================
# --capabilities
# ============================================================================
caps=$("$DRYDOCK_MACHO_REWRITE" --capabilities) || bad "capabilities: exit" "nonzero"
case "$caps" in
    "format 1"*) ok "capabilities: starts with format line" ;;
    *) bad "capabilities: format line" "got: $(echo "$caps" | head -1)" ;;
esac
# exitcodes documents EX_REFUSED (see cli/drydock-macho-rewrite.c) so a caller can tell
# "drydock-macho-rewrite examined FILE and declined" apart from "drydock-macho-rewrite itself failed"
# without scraping stderr text. Assert the line exists, names refused=1,
# and that a real refusal (verify on a non-Mach-O file) actually exits with
# that code -- not just some nonzero value. The corrected scheme is 0 ok, 1
# refused, 2 error -- backwards from what shipped, and deliberately so:
# diff/grep/cmp all reserve 2 for "something went wrong" and 1 for "a
# normal, expected, non-success answer". Nothing outside this repo had ever
# run the compat wrappers, so this was the last chance to fix it.
echo "$caps" | grep -q "^exitcodes ok=0 refused=1 failed=2$" \
    && ok "capabilities: exitcodes line documents refused=1" \
    || bad "capabilities: exitcodes line" "missing or wrong: $(echo "$caps" | grep '^exitcodes')"
echo 'not a mach-o' > "$T/not-a-macho-in-cli-test"
rc=0
"$DRYDOCK_MACHO_REWRITE" verify "$T/not-a-macho-in-cli-test" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] \
    && ok "capabilities: a real refusal (verify on a non-Mach-O) actually exits 1" \
    || bad "capabilities: exitcodes vs reality" "verify on a non-Mach-O exited $rc, not the documented 1"

# "output positional=2 never-writes-input" is the shape the mutating form's
# positionals take: a wrapper checks for this line rather than assume it.
echo "$caps" | grep -qx "output positional=2 never-writes-input" \
    && ok "capabilities: output line documents FILE OUT, never-writes-input" \
    || bad "capabilities: output line" "missing or wrong: $(echo "$caps" | grep '^output')"

# THE MUTATING FORM MUST BE ADVERTISED, and there is exactly one line that can
# do it. While `verb edit` stood here, --capabilities listed every `statement`
# a wrapper could send and no way to send one: the bare form appeared nowhere,
# so the interface the design calls the only mutating one was the one a
# machine-readable caller could not discover. Whole-line equality, because the
# grammar (`bare`, no verb word) and where the script comes from (`stdin`) are
# both part of the claim -- and because "no flags" is asserted by the absence
# of a flags= field, which only whole-line equality can see.
echo "$caps" | grep -qxF "mutate bare script=stdin" \
    && ok "capabilities: the bare FILE OUT form is advertised, taking its script on stdin" \
    || bad "capabilities: mutate line" "the only mutating form is not advertised: $(echo "$caps" | grep '^mutate')"

for v in verify info imports exports; do
    if echo "$caps" | grep -q "^verb $v"; then
        ok "capabilities: advertises $v"
    else
        bad "capabilities: $v" "not listed"
    fi
done
# AND THE NINE THAT ARE GONE MUST NOT BE ADVERTISED. print_capabilities' own
# contract is "never advertise one that errors out", and each of these now
# errors out -- `drydock-macho-rewrite dylib f o` is the bare form over a file named
# `dylib`, not a verb. A stale line here would send a wrapper at a verb this
# build has no arm for. `grow` is on this list for the same reason as the
# other seven, though unlike them it had no statement form to be sent to
# instead: it is simply gone. `edit` is on it because the bare form IS `edit`
# now -- the `mutate` line above is what a wrapper reads in its place.
caps_stale=0
for v in declassify segment retag-swift minos lc dylib rpath grow edit; do
    if echo "$caps" | grep -q "^verb $v"; then
        bad "capabilities: $v" "still advertised, but the verb is gone"
        caps_stale=1
    fi
done
[ "$caps_stale" -eq 0 ] && ok "capabilities: none of the nine deleted verbs is still advertised"
# usage() is the other place a caller reads about what this build can do, and
# the bare `FILE OUT` form is the whole mutating surface now -- a usage line
# that named only the read-only queries would leave a caller with no way in.
"$DRYDOCK_MACHO_REWRITE" >/dev/null 2>"$T/usage.err" || true
grep -q "FILE OUT" "$T/usage.err" \
    && ok "usage: the bare FILE OUT form is listed" \
    || bad "usage: bare form" "not mentioned at all: $(cat "$T/usage.err")"
grep -q "stdin" "$T/usage.err" \
    && ok "usage: says the statements come from stdin" \
    || bad "usage: stdin" "the bare form is listed without saying where the statements come from: $(cat "$T/usage.err")"
usage_stale=0
for v in declassify segment retag-swift minos grow edit; do
    grep -qE "^ +[^ ]+ $v " "$T/usage.err" && { bad "usage: $v" "still listed, but the verb is gone"; usage_stale=1; }
done
[ "$usage_stale" -eq 0 ] && ok "usage: none of the deleted verbs is still listed"
# ... and the remedy for a script that lives in a file is named, since deleting
# the `edit` verb is only free if the usage text says what replaced it.
grep -q "FILE OUT < script" "$T/usage.err" \
    && ok "usage: says how to run a script that lives in a file" \
    || bad "usage: script file" "no redirection example: $(cat "$T/usage.err")"
# `rpath insert` IS implemented; capabilities must claim it. A wrapper has
# no other way to learn this build can place a search path FIRST, which
# docs/PROPOSAL.md calls a new capability change_dylib never had. It was the
# `verb rpath ops=` line that carried this; the statement row carries it now.
if echo "$caps" | grep -qxF "statement rpath insert 1"; then
    ok "capabilities: rpath insert advertised"
else
    bad "capabilities: rpath insert" "implemented but not advertised: $(echo "$caps" | grep '^statement rpath')"
fi
# WHICH OPS EACH KIND OFFERS, which the two `verb <kind> ops=` lines used to
# state and the statement rows state now. The claim is the same one, in the
# spelling that survived: dylib offers all six, rpath four, and rpath does NOT
# offer reexport or retype (LC_RPATH has one kind, so there is nothing to
# promote it to, or retype it as). Both lists come from ONE table
# (src/script.c's MS_TABLE, which absorbed cli/drydock-macho-rewrite.c's DYLIB_OPS), so
# neither can advertise an op the parser refuses.
caps_dylib_ops=$(echo "$caps" | sed -n 's/^statement dylib \([a-z-]*\) [0-9]*$/\1/p' | sort | tr '\n' ',')
caps_rpath_ops=$(echo "$caps" | sed -n 's/^statement rpath \([a-z-]*\) [0-9]*$/\1/p' | sort | tr '\n' ',')
[ "$caps_dylib_ops" = "append,delete,insert,reexport,replace,retype," ] \
    && ok "capabilities: dylib advertises all six ops" \
    || bad "capabilities ops" "dylib ops moved: $caps_dylib_ops"
[ "$caps_rpath_ops" = "append,delete,insert,replace," ] \
    && ok "capabilities: rpath advertises four ops, and still omits reexport" \
    || bad "capabilities ops" "rpath ops moved: $caps_rpath_ops"

# --capabilities' statement lines are generated from MS_TABLE;
# tests/script_test.c checks the table itself.
n_statements=$(echo "$caps" | grep -c '^statement ' || true)
n_unique=$(echo "$caps" | grep '^statement ' | sort -u | wc -l | tr -d ' ')
[ "$n_statements" -eq 18 ] && [ "$n_unique" -eq 18 ] \
    && ok "capabilities: exactly 18 unique statement lines" \
    || bad "capabilities statement count" "got $n_statements line(s), $n_unique unique: $(echo "$caps" | grep '^statement')"
if echo "$caps" | grep -qxF "statement minos at-most 1"; then
    if echo "$caps" | grep -qxF "statement minos set 1"; then
        bad "capabilities statements" "minos set is advertised"
    else
        ok "capabilities: minos set is not advertised"
    fi
    echo "$caps" | grep -qxF "statement version-min set 1" \
        && bad "capabilities statements" "version-min set is advertised" \
        || ok "capabilities: version-min set is not advertised"
else
    bad "capabilities statements" "no minos at-most line, so the absent minos set and version-min set prove nothing"
fi
for caps_minos in 'at-most' 'if-absent'; do
    echo "$caps" | grep -qxF "statement minos $caps_minos 1" \
        && ok "capabilities: minos $caps_minos is advertised" \
        || bad "capabilities statements" "no 'statement minos $caps_minos 1': $(echo "$caps" | grep '^statement minos')"
done
# The profile vocabulary is advertised from that same table, so a wrapper can
# see which targets this build knows rather than guess. `target 10.9 0`: no
# operands after the profile.
echo "$caps" | grep -qxF "statement target 10.9 0" \
    && ok "capabilities: the target profile is advertised" \
    || bad "capabilities statements" "no 'statement target 10.9 0' line: $(echo "$caps" | grep '^statement')"
echo "$caps" | grep -q "statement dylib replace 2" \
    && ok "capabilities: statement table is advertised" \
    || bad "capabilities statements" "no 'statement dylib replace 2' line: $(echo "$caps" | grep '^statement')"
echo "$caps" | grep -qxF "statement dylib retype 2" \
    && ok "capabilities: dylib retype statement is advertised" \
    || bad "capabilities: dylib retype" "no 'statement dylib retype 2' line: $(echo "$caps" | grep '^statement dylib retype')"
echo "$caps" | grep -qxF "dylib-kinds load weak reexport upward" \
    && ok "capabilities: retype kinds are advertised" \
    || bad "capabilities: retype kinds" "no 'dylib-kinds load weak reexport upward' line: $(echo "$caps" | grep '^dylib-kinds')"
! grep -q 'lazy' "$T/caps" || bad "capabilities kinds" "advertises lazy as a kind"
ok "capabilities: retype kinds do not advertise lazy"

# Directives are not advertised, so only `info`'s real `--thin` flag may
# carry `flags=`. A wrapper cannot probe for allow-unmatched; its behaviour is
# asserted per statement below.
stray_flags=$(echo "$caps" | grep 'flags=' | grep -vxF 'verb info flags=--thin' || true)
[ -z "$stray_flags" ] \
    && ok "capabilities: the only flags= field advertised is info's --thin" \
    || bad "capabilities: flags=" "an unexpected flags= field survived the verb collapse: $stray_flags"

# ---- info --thin ---------------------------------------------------------
echo "$caps" | grep -qxF "verb info flags=--thin" \
    && ok "capabilities: info advertises --thin" \
    || bad "capabilities: info flags" "no 'verb info flags=--thin' line: $(echo "$caps" | grep '^verb info')"

"$DRYDOCK_MACHO_REWRITE" info --thin "$T/signing_probe" >"$T/thin.out" 2>"$T/thin.err" \
    && ok "info --thin: accepted on a thin Mach-O" \
    || bad "info --thin" "exited nonzero on a thin file: $(cat "$T/thin.err")"

"$DRYDOCK_MACHO_REWRITE" info "$T/signing_probe" >"$T/nothin.out" 2>/dev/null
cmp -s "$T/thin.out" "$T/nothin.out" \
    && ok "info --thin: identical output to plain info on a thin file" \
    || bad "info --thin output" "differs from plain info: $(diff "$T/nothin.out" "$T/thin.out" | head -5)"

rc=0; "$DRYDOCK_MACHO_REWRITE" info --thin >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok "info --thin: --thin with no FILE is a usage error (2)" \
    || bad "info --thin usage" "--thin with no FILE did not exit 2"
cp "$T/signing_probe" "$T/--thin"
rc=0; ( cd "$T" && "$DRYDOCK_MACHO_REWRITE" info ./--thin ) >"$T/dashthin.out" 2>"$T/dashthin.err" || rc=$?
[ "$rc" -eq 0 ] && grep -q '^\./--thin: [0-9]* bytes, ' "$T/dashthin.out" \
    && ok "info: a FILE named --thin is read as ./--thin" \
    || bad "info ./--thin" "exit $rc, stdout: $(head -1 "$T/dashthin.out"), stderr: $(cat "$T/dashthin.err")"

# ----------------------------------------------------------------------------
# capabilities vocabulary must match what the parsers actually accept.
#
# --capabilities' statement rows and the ms_parse that decides what a real
# script accepts are built from ONE table (MS_TABLE in src/script.c) precisely
# so they cannot say different things -- before this they were three
# hand-copied lists (change_dylib's strippable[], drydock-macho-rewrite's own LC_KINDS[],
# and a hardcoded "kinds=..." string) that a review found had already drifted
# apart in spirit even where the values still matched by luck. This does not
# re-derive the table (it can't see the C source); it drives drydock-macho-rewrite itself
# with every name --capabilities claims and confirms none of them is refused
# as unrecognized -- which is exactly what would happen if a row were ever
# added to (or dropped from) one list and not the other.
#
# THE KIND VOCABULARY IS NO LONGER ADVERTISED. `kinds=` lived on the `verb lc`
# line and went with it; `statement load-command delete 1` gives the operand
# count, not which names are legal. So this sweeps the vocabulary drydock-macho-rewrite is
# KNOWN to accept -- LC_STRIP_KINDS (src/lc_kinds.c), the same list compat's
# MT_STRIP_KINDS freezes -- rather than a list read back out of --capabilities,
# and the bogus-kind case below is what keeps that from passing vacuously.
build_main "$T/vocab_fixture"
vocab_kind_fail=0
for kind in uuid codesig source-version build-version code-sign-drs; do
    mts "$T/vocab_fixture" "load-command delete $kind" >"$T/vocab_kind.out" 2>&1 || true
    if grep -qi "unknown KIND" "$T/vocab_kind.out"; then
        bad "capabilities vocab: kind '$kind'" "refused as unknown by load-command delete: $(cat "$T/vocab_kind.out")"
        vocab_kind_fail=1
    fi
done
[ "$vocab_kind_fail" -eq 0 ] && ok "capabilities vocab: every LC_STRIP_KINDS kind is accepted by load-command delete"
# And the inverse: a KIND that is plainly not real must still be refused --
# otherwise this check could trivially "pass" by the parser accepting everything.
mts "$T/vocab_fixture" "load-command delete not-a-real-kind" >"$T/vocab_bogus.out" 2>&1 \
    && bad "capabilities vocab: bogus kind" "load-command delete accepted a KIND that isn't in any table" \
    || { grep -qi "unknown KIND" "$T/vocab_bogus.out" \
         && ok "capabilities vocab: an unadvertised kind is refused as unknown" \
         || bad "capabilities vocab: bogus kind" "refused, but not with 'unknown KIND': $(cat "$T/vocab_bogus.out")"; }

# Same idea for the dylib/rpath statement rows: every op --capabilities
# advertises for a kind must be recognized by ms_parse (never "unknown"), and
# rpath must still refuse an op that belongs to dylib's vocabulary but not its
# own (reexport: LC_RPATH has only one kind, so MS_TABLE in src/script.c
# carries no rpath row for it).
vocab_ops_fail=0
check_ops_accepted() {
    # $1=kind (dylib|rpath)  $2=ops, space-separated, from the statement rows
    verb="$1"
    for op in $2; do
        case "$op" in
            replace) mts "$T/vocab_fixture" "$verb replace /no/such/old /no/such/new" \
                         >"$T/vocab_op.out" 2>&1 || true ;;
            retype)  mts "$T/vocab_fixture" "$verb retype /no/such/path weak" \
                         >"$T/vocab_op.out" 2>&1 || true ;;
            *)       mts "$T/vocab_fixture" "$verb $op /no/such/path" \
                         >"$T/vocab_op.out" 2>&1 || true ;;
        esac
        if grep -qi "unknown" "$T/vocab_op.out"; then
            bad "capabilities vocab: $verb $op" "advertised but the parser called it unknown: $(cat "$T/vocab_op.out")"
            vocab_ops_fail=1
        fi
    done
}
dylib_ops=$(echo "$caps" | sed -n 's/^statement dylib \([a-z-]*\) [0-9]*$/\1/p' | tr '\n' ' ')
rpath_ops=$(echo "$caps" | sed -n 's/^statement rpath \([a-z-]*\) [0-9]*$/\1/p' | tr '\n' ' ')
[ -n "$dylib_ops" ] && [ -n "$rpath_ops" ] || bad "capabilities vocab" "no dylib or rpath statement rows"
check_ops_accepted dylib "$dylib_ops"
check_ops_accepted rpath "$rpath_ops"
[ "$vocab_ops_fail" -eq 0 ] && ok "capabilities vocab: every advertised dylib/rpath op is accepted by ms_parse"
# And the PARSER's half of that claim: an op dylib offers and rpath does not
# must be refused for rpath, not quietly accepted and applied to an LC_RPATH.
# What a user loses if it is accepted is a promoted rpath, which means nothing
# -- there is no LC_REEXPORT_RPATH for it to become.
mts "$T/vocab_fixture" "rpath reexport /no/such/path" >"$T/vocab_rpath_reexport.out" 2>&1 \
    && bad "capabilities vocab: rpath reexport" "accepted an op only dylib offers" \
    || { grep -q "unknown statement 'rpath reexport'" "$T/vocab_rpath_reexport.out" \
         && ok "capabilities vocab: rpath refuses reexport, the op it does not offer" \
         || bad "capabilities vocab: rpath -reexport" "refused, but not as unknown: $(cat "$T/vocab_rpath_reexport.out")"; }

# ============================================================================
# `fixups set classic`: chained fixups -> LC_DYLD_INFO_ONLY
#
# The conversion lives in src/declassify.c (lifted out of
# compat/patch_macho.c's main, before that file became a shell wrapper); this
# statement is the only C front-end over it now, and the `patch_macho` name
# reaches it through compat/patch_macho.sh. It was the `declassify` VERB until
# the verbs went; every assertion below is the one that verb had, asking its
# own question of the statement that replaced it. What is asserted here is the OBSERVABLE result -- the two
# quadwords in __DATA the conversion rewrites, which load commands survived,
# where the new LC_DYLD_INFO_ONLY points, and how far __LINKEDIT now reaches --
# not "it exited 0".
#
# THE FIXTURE IS HAND-BUILT, and it has to be: chained fixups are a 2021
# format, 10.9's linker predates them by a decade, and tests/chained-fixups.sh
# (which asks the HOST linker for one) therefore SKIPs entirely on the machine
# this toolkit is actually for. A fixture written byte by byte asks the same
# question on every host -- the reasoning tests/README.md's host-portability
# section gives, and the idiom leaf-tool-crashes.sh's mkfixture.c and
# tests/mkswift.c already use.
#
# The program is tests/mkchained.c, a FILE rather than a here-document because
# tests/wrapper_test.sh needs exactly the same fixture for exactly the same
# reason -- `patch_macho`'s converting path -- and one copy of it is enough.
# Same arrangement as tests/strip_version_min.c and tests/mkswift.c.
SRC_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../src" && pwd)
"$CC" -O2 -I "$SRC_DIR" -o "$T/mkchained" "$HERE/mkchained.c"
"$T/mkchained" make "$T/chained.in"

# dcl IN OUT  -- exactly what `drydock-macho-rewrite declassify IN OUT` was, in the only
# spelling left. Named so the assertions below read as they always did. No
# output filtering: unlike mts, every one of these names its own OUT and reads
# the streams directly, which is the point of several of them.
dcl() { printf 'fixups set classic\n' | "$DRYDOCK_MACHO_REWRITE" "$@"; }

# What the fixture is, before anything touches it. If this ever stops holding,
# every assertion below is asking the wrong question and would "pass" for the
# wrong reason -- so it is checked, not assumed.
chk=$("$T/mkchained" check "$T/chained.in")
if echo "$chk" | grep -q "^chained=1" && echo "$chk" | grep -q "^dyldinfo=0"; then
    ok "declassify: fixture really uses chained fixups and has no LC_DYLD_INFO_ONLY"
else
    bad "declassify: fixture" "not the shape this suite expects: $(echo "$chk" | tr '\n' ' ')"
fi

dcl "$T/chained.in" "$T/chained.out" >"$T/dcl.out" 2>"$T/dcl.err" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && ok "declassify: converts a chained-fixups binary (exit 0)" \
    || bad "declassify: exit code" "exited $rc on a chained-fixups binary: $(cat "$T/dcl.err")"

# The conversion's whole job, read back out of the output file's bytes.
#   slot0  a REBASE of base-relative 0x1000 in a __TEXT based at 0x100000000,
#          so the classic rebase (which adds the slide, not slide+base) has to
#          find the absolute 0x100001000 already in the slot;
#   slot1  a BIND, which must be zeroed for dyld to fill in;
#   the three modern load commands must be gone, LC_DYLD_INFO_ONLY present,
#   and __LINKEDIT must now cover the appended opcode streams -- otherwise dyld
#   would not read the very bytes the new command points at.
dcl_out=$("$T/mkchained" check "$T/chained.out")
dcl_val() { echo "$dcl_out" | sed -n "s/^$1=//p"; }
dcl_fail=0
dcl_expect() {
    got=$(dcl_val "$1")
    [ "$got" = "$2" ] || { bad "declassify: $1" "expected $2, got '$got'"; dcl_fail=1; }
}
dcl_expect slot0 0x100001000
dcl_expect slot1 0x0
dcl_expect chained 0
dcl_expect trie 0
dcl_expect buildver 0
dcl_expect dyldinfo 1
dcl_expect bindsym _mkchained_sym
# The three bind opcodes, read back as bytes: SET_TYPE_IMM|POINTER (0x51),
# SET_DYLIB_ORDINAL_IMM|1 (0x11), SET_SYMBOL_TRAILING_FLAGS_IMM with no flags
# (0x40). mkchained prints them; nothing asserted them until now, which left
# "the bind was translated" resting on the symbol name alone. It is also the
# baseline the weak-ordinal case below is a deviation from.
dcl_expect bindops 51,11,40
[ "$dcl_fail" -eq 0 ] && ok "declassify: rebase rewritten, bind zeroed and named, modern commands stripped"

# __LINKEDIT has to end exactly where the file now does: the conversion
# appends the rebase/bind streams past its old end and extends it to cover
# them. This is one of the two sanctioned exceptions to "never move a byte",
# so it gets its own assertion rather than riding along with the others.
le=$(dcl_val linkedit); le_off=${le%%+*}; le_size=${le##*+}
osize=$(dcl_val size)
if [ "$((le_off + le_size))" -eq "$osize" ]; then
    ok "declassify: __LINKEDIT extended to cover the appended opcode streams"
else
    bad "declassify: __LINKEDIT" "ends at $((le_off + le_size)), file is $osize bytes"
fi
rebase=$(dcl_val rebase); bind=$(dcl_val bind)
if [ "${rebase##*+}" -gt 0 ] && [ "${bind##*+}" -gt 0 ]; then
    ok "declassify: LC_DYLD_INFO_ONLY points at non-empty rebase and bind streams"
else
    bad "declassify: LC_DYLD_INFO_ONLY" "empty stream(s): rebase=$rebase bind=$bind"
fi

# THE -3 WEAK-LOOKUP REMAP, which nothing in this repo asserted and which
# fails at LOAD TIME on the real product when it is wrong: a bind whose library
# ordinal is -3 (BIND_SPECIAL_DYLIB_WEAK_LOOKUP, emitted by every modern
# toolchain) is rejected by 10.9's dyld with "bad special ordinal". The
# conversion has to rewrite it as flat lookup (-2) plus the weak-import flag,
# and the rewrite is visible in the opcodes: 0x3e is
# SET_DYLIB_SPECIAL_IMM|(-2 & 0x0F) where the plain fixture has 0x11
# (SET_DYLIB_ORDINAL_IMM|1), and 0x41 is SET_SYMBOL_TRAILING_FLAGS_IMM with
# BIND_SYMBOL_FLAGS_WEAK_IMPORT where the plain fixture has 0x40.
"$T/mkchained" make-weak "$T/weak.in"
dcl "$T/weak.in" "$T/weak.out" >/dev/null 2>"$T/weak.err" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
    dcl_out=$("$T/mkchained" check "$T/weak.out")
    dcl_fail=0
    dcl_expect bindops 51,3e,41
    dcl_expect bindsym _mkchained_sym
    dcl_expect slot1 0x0
    [ "$dcl_fail" -eq 0 ] && ok "declassify: a -3 weak-lookup ordinal becomes flat lookup + weak-import"
else
    bad "declassify: weak ordinal" "exited $rc: $(cat "$T/weak.err")"
fi

# THE OPCODE BUFFER'S BOUND. The conversion emits into two fixed 1MB buffers
# (declassify.h's LIMITS). A binary with more fixups than that used to walk
# straight off the end of the allocation -- ~5 bytes per rebase, so about 200k
# fixups reaches it, which a large modern binary genuinely carries. This
# fixture is a 2MB __DATA that is one 262k-link rebase chain: the conversion
# must REFUSE it, say so, and write nothing.
"$T/mkchained" make-big "$T/big.in"
rm -f "$T/big.out"
dcl "$T/big.in" "$T/big.out" >/dev/null 2>"$T/big.err" && rc=0 || rc=$?
[ "$rc" -eq 1 ] && ok "declassify: refuses a binary with more fixups than the opcode buffer holds" \
    || bad "declassify: opcode overflow" "expected EX_REFUSED (1), got $rc: $(cat "$T/big.err")"
grep -q "opcode buffer" "$T/big.err" \
    && ok "declassify: names the opcode buffer as the reason" \
    || bad "declassify: opcode overflow" "no reason on stderr: $(cat "$T/big.err")"
[ -e "$T/big.out" ] && bad "declassify: opcode overflow" "wrote an output for an input it refused" \
    || ok "declassify: an over-large input produces no output file"
if [ -x "$BIN/patch_macho" ]; then
    rm -f "$T/big.pm"
    "$BIN/patch_macho" "$T/big.in" "$T/big.pm" >/dev/null 2>&1 && rc=0 || rc=$?
    [ "$rc" -eq 1 ] && ok "declassify: patch_macho refuses the same over-large input with its flat 1" \
        || bad "declassify: opcode overflow (patch_macho)" "expected 1, got $rc"
fi

# THE HEADER PAD'S BOUND. The new LC_DYLD_INFO_ONLY goes after the load
# commands and must end before the first section's file data. With no section
# data (make-nosect) there is no such bound, and the conversion used to assume
# 4096; with the first section past the end of the file (make-sectpast) the
# bound lies outside the image. Either way it must refuse, say why, and write
# nothing.
for dcl_mode in nosect sectpast; do
    "$T/mkchained" make-$dcl_mode "$T/$dcl_mode.in"
    rm -f "$T/$dcl_mode.out"
    dcl "$T/$dcl_mode.in" "$T/$dcl_mode.out" >/dev/null 2>"$T/$dcl_mode.err" \
        && rc=0 || rc=$?
    case $dcl_mode in
        nosect)   dcl_why="no section data bounds the header pad" ;;
        sectpast) dcl_why="lies past the end of the image" ;;
    esac
    [ "$rc" -eq 1 ] && grep -q "$dcl_why" "$T/$dcl_mode.err" \
        && ok "declassify: $dcl_mode: refuses (1), saying '$dcl_why'" \
        || bad "declassify: $dcl_mode" "expected 1 + '$dcl_why', got $rc: $(cat "$T/$dcl_mode.err")"
    [ -e "$T/$dcl_mode.out" ] && bad "declassify: $dcl_mode" "wrote an output for an input it refused" \
        || ok "declassify: $dcl_mode: produces no output file"
done

for dcl_mode in badord; do
    "$T/mkchained" make-$dcl_mode "$T/$dcl_mode.in"
    rm -f "$T/$dcl_mode.out" "$T/$dcl_mode.pm"
    dcl "$T/$dcl_mode.in" "$T/$dcl_mode.out" >/dev/null 2>"$T/$dcl_mode.err" \
        && rc=0 || rc=$?
    [ "$rc" -eq 1 ] && grep -q "verifying the conversion" "$T/$dcl_mode.err" \
        && ok "declassify: $dcl_mode: a wrong conversion is refused (1) by its own check" \
        || bad "declassify: $dcl_mode" "expected 1 + 'verifying the conversion', got $rc: $(cat "$T/$dcl_mode.err")"
    [ -e "$T/$dcl_mode.out" ] && bad "declassify: $dcl_mode" "wrote an output for an input it refused" \
        || ok "declassify: $dcl_mode: produces no output file"
    if [ -x "$BIN/patch_macho" ]; then
        "$BIN/patch_macho" "$T/$dcl_mode.in" "$T/$dcl_mode.pm" >/dev/null 2>&1 && rc=0 || rc=$?
        [ "$rc" -eq 1 ] && [ ! -e "$T/$dcl_mode.pm" ] \
            && ok "declassify: $dcl_mode: patch_macho refuses it too, writing nothing" \
            || bad "declassify: $dcl_mode (patch_macho)" "expected 1 and no output, got $rc"
    fi
done

# HIGH8: a DYLD_CHAINED_PTR_64_OFFSET rebase whose high8 byte is nonzero
# (0x5A, packed at raw bits [43:36] -- platform:
# https://github.com/apple-oss-distributions/dyld/blob/main/include/mach-o/fixup-chains.h,
# struct dyld_chained_ptr_64_rebase). This must now CONVERT, not refuse: it
# used to trip md_verify's own (correct) decode of the same raw value, because
# the conversion's decode used the wrong widths. The converted slot is checked
# for the right VALUE, not just a non-refusal: TEXT_VMADDR + REBASE_TARGET
# with 0x5A or'd into the top byte.
"$T/mkchained" make-high8 "$T/high8.in"
rm -f "$T/high8.out" "$T/high8.pm"
dcl "$T/high8.in" "$T/high8.out" >/dev/null 2>"$T/high8.err" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && ok "declassify: high8: a nonzero high8 byte converts (0) instead of being refused" \
    || bad "declassify: high8" "expected 0, got $rc: $(cat "$T/high8.err")"
if [ "$rc" -eq 0 ]; then
    dcl_out=$("$T/mkchained" check "$T/high8.out")
    dcl_fail=0
    dcl_expect slot0 0x5a00000100001000
    [ "$dcl_fail" -eq 0 ] && ok "declassify: high8: the converted slot carries image_base+target with high8 in the top byte"
fi
if [ -x "$BIN/patch_macho" ]; then
    "$BIN/patch_macho" "$T/high8.in" "$T/high8.pm" >/dev/null 2>&1 && rc=0 || rc=$?
    [ "$rc" -eq 0 ] && cmp -s "$T/high8.out" "$T/high8.pm" \
        && ok "declassify: high8: patch_macho converts the same bytes" \
        || bad "declassify: high8 (patch_macho)" "expected 0 and byte-identical output, got $rc"
fi

"$T/mkchained" make-lcfirst "$T/lcfirst.in"
dcl "$T/lcfirst.in" "$T/lcfirst.out" >/dev/null 2>"$T/lcfirst.err" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [ "$("$T/mkchained" check "$T/lcfirst.out")" = "$("$T/mkchained" check "$T/chained.out")" ]; then
    ok "declassify: a stripped command before a segment does not shift the segment it rewrites"
else
    bad "declassify: lcfirst" "expected 0 and the plain fixture's result, got $rc: $(cat "$T/lcfirst.err")"
fi

# BYTE-IDENTITY WITH patch_macho, the strongest available proof that lifting
# the conversion into src/declassify.c did not change it: the two front-ends
# are handed the same buffer by md_declassify and must write the same bytes.
# Not a hard requirement of THIS script (drydock-macho-rewrite stands alone, and $BIN need
# not hold anything else), so its absence is a SKIP, not a failure.
if [ -x "$BIN/patch_macho" ]; then
    "$BIN/patch_macho" "$T/chained.in" "$T/chained.pm" >/dev/null 2>&1
    if cmp -s "$T/chained.out" "$T/chained.pm"; then
        ok "declassify: byte-identical to patch_macho's output"
    else
        bad "declassify: byte-identity" "drydock-macho-rewrite and patch_macho produced different bytes"
    fi
    # patch_macho returns a flat 1 for everything that goes wrong; this verb
    # distinguishes "examined it and declined" (EX_REFUSED=1) from an
    # operational failure (EX_FAIL=2). For THIS refusal the two numbers
    # happen to agree (both 1) -- that is a coincidence of the corrected
    # numbering, not a design goal -- but a wrapper that must look like
    # patch_macho still has real mapping work to do for the EX_FAIL=2 case,
    # where the numbers diverge; compat/README.md's "patch_macho" section
    # covers both.
    "$BIN/patch_macho" "$T/not-a-macho-in-cli-test" "$T/nope_pm" >/dev/null 2>&1 && pm_rc=0 || pm_rc=$?
    [ "$pm_rc" -eq 1 ] && ok "declassify: patch_macho's flat 1 and this verb's EX_REFUSED agree on this refusal" \
        || bad "declassify: patch_macho exit" "expected the historical flat 1, got $pm_rc"
else
    skip "declassify: byte-identity with patch_macho" "no patch_macho in $BIN"
fi

# IDEMPOTENCY, which install.sh's wrapper depends on: running the conversion
# over an already-converted binary passes it through unchanged instead of
# failing on the fixups that are no longer there.
dcl "$T/chained.out" "$T/chained.again" >"$T/again.out" 2>"$T/again.err" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
    if cmp -s "$T/chained.out" "$T/chained.again"; then
        ok "declassify: an already-converted binary passes through byte-for-byte"
    else
        bad "declassify: idempotency" "a second conversion changed the bytes"
    fi
    grep -q "Already patched" "$T/again.out" \
        && ok "declassify: says it passed through" \
        || bad "declassify: pass-through message" "no 'Already patched' line: $(cat "$T/again.out")"
else
    bad "declassify: idempotency" "exited $rc on an already-converted binary: $(cat "$T/again.err")"
fi

# IN AND OUT MAY NO LONGER BE THE SAME PATH. This verb used to allow it (the
# whole image is in memory before a byte is written, so it worked), and now
# refuses it UP FRONT -- before any read -- because drydock-macho-rewrite never writes its
# input. The same four facts every other converted verb is held to: refused
# with 2, IN untouched in bytes AND inode, the refusal is the up-front one, and
# a symlink to IN is caught too. `patch_macho IN IN` still converts IN: its
# wrapper runs this verb into a temp beside OUT and installs that.
cp "$T/chained.in" "$T/inplace"
dcl_sha=$(sha "$T/inplace"); dcl_ino=$(stat -f %i "$T/inplace")
rc=0
dcl "$T/inplace" "$T/inplace" >/dev/null 2>"$T/inplace.err" || rc=$?
[ "$rc" -eq 2 ] && [ "$(sha "$T/inplace")" = "$dcl_sha" ] \
    && [ "$(stat -f %i "$T/inplace")" = "$dcl_ino" ] \
    && ok "declassify: an OUT that is IN is refused (2), IN untouched" \
    || bad "declassify: OUT=IN" "rc $rc, or IN changed"
grep -q "never writes its input" "$T/inplace.err" \
    && ok "declassify: ... refused up front, before any work" \
    || bad "declassify: OUT=IN" "not the up-front refusal: $(cat "$T/inplace.err")"
rm -f "$T/inplace_link"; ln -s "$T/inplace" "$T/inplace_link"
rc=0
dcl "$T/inplace" "$T/inplace_link" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok "declassify: an OUT that is a symlink to IN is refused (2)" \
    || bad "declassify: OUT=link" "rc $rc"

# OUT TAKES IN'S MODE, not the fixed 0755 this verb's own open() used to ask
# for: wa_write_new copies the input's, like every other converted verb. The C
# tool's 0755-masked-by-umask is now compat/patch_macho.sh's to restore, and
# tests/wrapper_test.sh is where that is asserted.
chmod 640 "$T/inplace"
rm -f "$T/dcl_mode_out"
rc=0
dcl "$T/inplace" "$T/dcl_mode_out" >/dev/null 2>"$T/dcl_mode.err" || rc=$?
[ "$rc" -eq 0 ] && [ "$(stat -f %Lp "$T/dcl_mode_out")" = 640 ] \
    && ok "declassify: OUT is created with IN's mode" \
    || bad "declassify: OUT mode" "rc $rc, mode $(stat -f %Lp "$T/dcl_mode_out" 2>/dev/null): $(cat "$T/dcl_mode.err")"

# Refusals. Each is a decision drydock-macho-rewrite made about the INPUT, so each is
# EX_REFUSED (1), never EX_FAIL (2), which means "something went wrong running
# drydock-macho-rewrite" -- that distinction is what --capabilities' exitcodes line promises.
dcl "$T/not-a-macho-in-cli-test" "$T/nope" >/dev/null 2>"$T/nm.err" && rc=0 || rc=$?
[ "$rc" -eq 1 ] && ok "declassify: refuses a non-Mach-O with EX_REFUSED" \
    || bad "declassify: non-Mach-O" "expected 1, got $rc"
[ -e "$T/nope" ] && bad "declassify: non-Mach-O" "wrote an output file for an input it refused" \
    || ok "declassify: a refused input produces no output file"

# A 64-bit Mach-O with NEITHER chained fixups NOR LC_DYLD_INFO_ONLY -- a plain
# object file is exactly that -- is not idempotent-pass-through material and
# not convertible either. It must say so and refuse, not quietly copy.
"$CC" -c -O2 $FIXTURE_FLAGS "$T/main.c" -o "$T/plain.o"
dcl "$T/plain.o" "$T/plain.out" >/dev/null 2>"$T/plain.err" && rc=0 || rc=$?
[ "$rc" -eq 1 ] && ok "declassify: refuses a Mach-O with no chained fixups and no LC_DYLD_INFO_ONLY" \
    || bad "declassify: no fixups" "expected 1, got $rc"
grep -q "No chained fixups found" "$T/plain.err" \
    && ok "declassify: says why it refused" \
    || bad "declassify: no fixups" "no reason on stderr: $(cat "$T/plain.err")"

# An OUT that cannot be written is an OPERATIONAL failure, not a refusal: the
# input was fine and drydock-macho-rewrite declined nothing. It must exit 2 (EX_FAIL), and
# this is the assertion that keeps EX_REFUSED from decaying into "any nonzero".
dcl "$T/chained.in" "$T/no/such/dir/out" >/dev/null 2>"$T/unwritable.err" && rc=0 || rc=$?
[ "$rc" -eq 2 ] && ok "declassify: an unwritable OUT is a failure (2), not a refusal (1)" \
    || bad "declassify: unwritable OUT" "expected 2, got $rc"

# ============================================================================
# drydock-macho-rewrite stands alone
#
# The rewriting verbs used to fork and exec change_dylib/add_version_min,
# located next to drydock-macho-rewrite on disk, and --capabilities hid those four verbs
# whenever the sibling was missing. Both are gone: the rewrite is linked in
# (src/rewrite.c, src/version_min.c). That is the whole point of the
# extraction -- it is what lets change_dylib become a wrapper AROUND drydock-macho-rewrite
# without a cycle -- so prove it from the outside rather than by reading the
# source: copy ONLY drydock-macho-rewrite into an empty directory and make it do real work
# there. A regression that restored the subprocess would fail here even
# though every other assertion in this file, run from a full bindir, would
# still pass. The statements are what run now; the subprocess they would
# restore is the same one.
# ============================================================================
mkdir -p "$T/alone"
cp "$DRYDOCK_MACHO_REWRITE" "$T/alone/drydock-macho-rewrite"
alone_caps=$("$T/alone/drydock-macho-rewrite" --capabilities)
alone_missing=""
for v in verify info imports; do
    echo "$alone_caps" | grep -q "^verb $v" || alone_missing="$alone_missing $v"
done
echo "$alone_caps" | grep -qxF "mutate bare script=stdin" \
    || alone_missing="$alone_missing 'mutate bare script=stdin'"
for s in 'dylib append 1' 'load-command delete 1' 'minos if-absent 1' 'segment rename 2' 'swift-abi set 1' 'fixups set 1'; do
    echo "$alone_caps" | grep -qxF "statement $s" || alone_missing="$alone_missing '$s'"
done
[ -z "$alone_missing" ] && ok "alone: --capabilities still advertises everything with no sibling present" \
    || bad "alone: capabilities" "missing when drydock-macho-rewrite stands alone:$alone_missing"

build_main "$T/alone/fixture"
if printf 'dylib append @loader_path/libalone.dylib\n' \
        | "$T/alone/drydock-macho-rewrite" "$T/alone/fixture" "$T/alone/fixture.out" \
        >"$T/alone_dylib.out" 2>&1; then
    ok "alone: dylib append works with no change_dylib anywhere near drydock-macho-rewrite"
else
    bad "alone: dylib append" "$(cat "$T/alone_dylib.out")"
fi
"$T/alone/drydock-macho-rewrite" info "$T/alone/fixture.out" | grep -qF "path=@loader_path/libalone.dylib" \
    && ok "alone: the append really landed in the output" \
    || bad "alone: dylib append result" "new dependency not in info output"

if printf 'load-command delete uuid\n' \
        | "$T/alone/drydock-macho-rewrite" "$T/alone/fixture.out" "$T/alone/fixture.out2" \
        >"$T/alone_lc.out" 2>&1; then
    ok "alone: load-command delete works with no change_dylib anywhere near drydock-macho-rewrite"
else
    bad "alone: load-command delete" "$(cat "$T/alone_lc.out")"
fi

if printf 'minos if-absent 10.9\n' \
        | "$T/alone/drydock-macho-rewrite" "$T/alone/fixture" "$T/alone/fixture.minos" \
        >"$T/alone_minos.out" 2>&1; then
    ok "alone: minos if-absent works with no add_version_min anywhere near drydock-macho-rewrite"
else
    bad "alone: minos if-absent" "$(cat "$T/alone_minos.out")"
fi
if grep -q "^      .*version-min " "$T/alone_minos.out"; then
    ok "alone: minos if-absent reached its core in-process (said what it did)"
else
    bad "alone: minos if-absent output" "exited 0 but reported no version-min: $(cat "$T/alone_minos.out")"
fi
"$T/alone/drydock-macho-rewrite" info "$T/alone/fixture.minos" | grep -q "LC_VERSION_MIN_MACOSX" \
    && ok "alone: the output carries LC_VERSION_MIN_MACOSX afterward" \
    || bad "alone: minos if-absent result" "no LC_VERSION_MIN_MACOSX in info output after minos if-absent"

# ============================================================================
# verify
# ============================================================================
build_main "$T/verify_ok"
if "$DRYDOCK_MACHO_REWRITE" verify "$T/verify_ok" >"$T/verify_ok.out"; then
    ok "verify: accepts a real binary"
else
    bad "verify: real binary" "refused: $(cat "$T/verify_ok.out")"
fi
# `: OK` and not `OK`: cmd_verify's verdict line is "<path>: OK", and a bare
# two-character substring would also be satisfied by a path, a diagnostic or a
# future line that happens to contain them. Paired with the exit-status check
# above it could not silently pass today, but the tighter pattern costs
# nothing and is what every other verify assertion in this file uses.
grep -q ': OK' "$T/verify_ok.out" && ok "verify: reports OK" || bad "verify: OK text" "missing"

echo 'not a mach-o' > "$T/verify_bad"
if "$DRYDOCK_MACHO_REWRITE" verify "$T/verify_bad" >/dev/null 2>&1; then
    bad "verify: garbage file" "should have been refused"
else
    ok "verify: refuses a non-Mach-O file"
fi

# A dylib links at image base 0, and mg_plausible used to read that 0 as
# mi_text_base's "no segment maps the header" sentinel and refuse before
# checking anything -- so the gate refused every dylib on the machine for a
# reason that had nothing to do with plausibility. The tell was
# `FAILED (see above)` with nothing above it: no entry was ever checked.
# Built here, not found on the host: a test that scans /usr/lib for a
# suitable dylib skips itself away on the cross runner, where those dylibs
# live in the dyld shared cache. FIXTURE_FLAGS for the usual reason, and no
# -headerpad is needed because neither assertion below grows the header.
"$CC" -dynamiclib -O2 $FIXTURE_FLAGS -install_name "@loader_path/fixture.dylib" \
    "$T/a.c" -o "$T/fixture.dylib"
if "$DRYDOCK_MACHO_REWRITE" verify "$T/fixture.dylib" >"$T/dylibverify.out" 2>&1; then
    ok "verify: a dylib gets a real verdict"
else
    bad "verify: a dylib gets a real verdict" "refused: $(cat "$T/dylibverify.out")"
fi
grep -q ': OK' "$T/dylibverify.out" && ok "verify: and says OK" \
    || bad "verify: and says OK" "missing: $(cat "$T/dylibverify.out")"
if grep -q "FAILED (see above)" "$T/dylibverify.out"; then
    bad "verify: not the contentless failure" \
        "the precondition bail is back: $(cat "$T/dylibverify.out")"
else
    ok "verify: not the contentless failure"
fi

# The gate refusing every dylib meant no dylib could be rewritten at all:
# mr_process_thin gates on mg_plausible, so drydock-macho-rewrite dylib/rpath/lc -- and
# change_dylib, which is the same code -- refused every dylib outright.
cp "$T/fixture.dylib" "$T/dylibrw"
if mts "$T/dylibrw" "load-command delete uuid" >"$T/dylibrw.out" 2>&1; then
    ok "lc -delete: a dylib is rewritable"
else
    bad "lc -delete: a dylib is rewritable" "refused: $(cat "$T/dylibrw.out")"
fi

# ============================================================================
# info
# ============================================================================
build_main "$T/info_fixture"
info_out=$("$DRYDOCK_MACHO_REWRITE" info "$T/info_fixture") || bad "info: exit" "nonzero"
echo "$info_out" | grep -q "LC_SEGMENT_64" && ok "info: shows LC_SEGMENT_64" \
    || bad "info: segments" "not found in output"
echo "$info_out" | grep -q "segname=__TEXT" && ok "info: shows __TEXT segment" \
    || bad "info: __TEXT" "not found in output"
echo "$info_out" | grep -q "ordinal=1 path=.*liba.dylib" && ok "info: shows liba as ordinal 1" \
    || bad "info: ordinal" "not found in output: $info_out"
echo "$info_out" | grep -q "header pad:" && ok "info: shows header pad line" \
    || bad "info: header pad" "not found in output"

# ============================================================================
# imports
# ============================================================================
# TSV output: a header row, then one row per (dylib, symbol) pair. Columns
# may be APPENDED, but never reordered, renamed or removed -- a consumer
# selects a column BY NAME, which is why the symbol assertion below reads it
# by awk-ing the header row for its position instead of a fixed field number.
build_main "$T/imp_in"
rc=0
"$DRYDOCK_MACHO_REWRITE" imports "$T/imp_in" >"$T/imp.out" 2>"$T/imp.err" || rc=$?
[ "$rc" -eq 0 ] && ok "imports: succeeds on a real binary" \
    || bad "imports: real binary" "exited $rc: $(cat "$T/imp.err")"

# `stream` was appended after the first six, which is the only change the
# header may ever see.
imp_header=$(printf 'arch\tordinal\tkind\tinstall_name\tsymbol\tweak\tstream')
head -1 "$T/imp.out" | grep -qxF "$imp_header" \
    && ok "imports: header row names the seven columns, in order" \
    || bad "imports: header row" "changed: $(head -1 "$T/imp.out")"

# A VALUE assertion, not a shape assertion: this tool's whole job is mapping
# symbol -> install_name (plus kind/weak), and a shape-only check ("some
# symbol was present") cannot tell a correct mapping from a scrambled one --
# it still passes if the wrong install_name, the wrong kind, or a wrong
# ordinal is reported for the right symbol. Read entirely BY COLUMN NAME
# (the header row parsed into `c[]`, same device tests/cli_test.sh's `info`
# assertions use for `ordinal=1 path=.*liba.dylib` 15 lines above the
# original of this section), so a future column reorder still finds the
# right field instead of silently comparing the wrong one.
#
# The ordinal each row is checked against is DERIVED from `drydock-macho-rewrite
# info`'s own dylib table below, not a literal -- an exact ordinal is a HOST
# FACT (this host's linker may place an extra load command, e.g. a
# stack-check symbol's own dylib, ahead of libSystem, shifting every ordinal
# after it), and CI's cross linker is not this host's. What is NOT a host
# fact is that liba.dylib and libSystem.B.dylib get two DIFFERENT ordinals
# from the very same info dump imports itself is checked against, so BOTH
# rows are still checked, not just _a_sym's: a bug that resolves every row's
# install_name against liba.dylib's ordinal unconditionally (rather than each
# row's own ordinal) fails dyld_stub_binder's check even though a_ord and
# sys_ord are read off this host, because the two derived ordinals can never
# be equal to each other.
info_out=$("$DRYDOCK_MACHO_REWRITE" info "$T/imp_in" 2>/dev/null)
a_ord=$(printf '%s\n' "$info_out" | sed -n 's/^  ordinal=\([0-9]*\) path=@loader_path\/liba\.dylib$/\1/p' | head -1)
sys_ord=$(printf '%s\n' "$info_out" | sed -n 's/^  ordinal=\([0-9]*\) path=\/usr\/lib\/libSystem\.B\.dylib$/\1/p' | head -1)
[ -n "$a_ord" ] && [ -n "$sys_ord" ] && [ "$a_ord" != "$sys_ord" ] \
    && ok "imports: info's own dylib table gives liba.dylib and libSystem distinct ordinals" \
    || bad "imports: precondition" "could not derive two distinct ordinals from info: $info_out"

awk -F'\t' -v a_ord="$a_ord" -v sys_ord="$sys_ord" '
    NR==1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
    $c["symbol"] == "_a_sym" && $c["install_name"] == "@loader_path/liba.dylib" &&
    $c["kind"] == "load" && $c["ordinal"] == a_ord && $c["weak"] == "0" &&
    $c["stream"] == "lazy" { f1 = 1 }
    $c["symbol"] == "dyld_stub_binder" && $c["install_name"] == "/usr/lib/libSystem.B.dylib" &&
    $c["kind"] == "load" && $c["ordinal"] == sys_ord && $c["weak"] == "0" &&
    $c["stream"] == "bind" { f2 = 1 }
    END { exit !(f1 && f2) }
' "$T/imp.out" \
    && ok "imports: _a_sym and dyld_stub_binder each map to their OWN dylib, kind and ordinal" \
    || bad "imports: symbol-to-dylib mapping" "no matching rows: $(cat "$T/imp.out")"

# AT LEAST two rows, not EXACTLY two: a_sym (bound lazily, through a stub --
# the `stream` check above) and libSystem's dyld_stub_binder (bound eagerly:
# it is what every stub helper calls) are the two THIS test relies on and checks by value above;
# a cross linker is free to add a bind this host's does not (another stub, a
# second libSystem symbol) without that being wrong. An exact count is a HOST
# FACT the same way an exact ordinal is. What still catches "the last row is
# silently dropped" or "one of the three bind streams is never walked" is the
# value check above: either failure mode removes one of the two specific
# rows it requires, regardless of how many OTHER rows are present.
imp_rows=$(awk -F'\t' 'NR>1' "$T/imp.out" | wc -l | tr -d ' ')
[ "$imp_rows" -ge 2 ] && ok "imports: reports at least the two binds this fixture makes" \
    || bad "imports: row count" "wanted >= 2 data rows, got $imp_rows: $(cat "$T/imp.out")"

awk -F'\t' 'NR==1{n=NF} NF!=n{print NR; exit 1}' "$T/imp.out" >/dev/null \
    && ok "imports: every data row has the header's field count" \
    || bad "imports: ragged row" "a row's field count differs from the header's"

"$DRYDOCK_MACHO_REWRITE" imports "$T/imp_in" >"$T/imp2.out" 2>/dev/null
cmp -s "$T/imp.out" "$T/imp2.out" \
    && ok "imports: deterministic -- same input, same bytes" \
    || bad "imports: deterministic" "two runs on the same input differ"

# TAB/NEWLINE in an attacker-controlled field (install_name here; a symbol
# name in the bind stream is the same hazard, checked the same way, in
# src/imports.c) is refused, not escaped or emitted ragged -- see
# cli/drydock-macho-rewrite.c's comment beside the header-row's append-only rule for
# the reasoning. This is also the ragged-row check above's first POSITIVE
# control: without this fixture, that check has never had a ragged row to
# catch and passes vacuously on every clean fixture.
#
# GUARDED, not asserted outright, and under `set -eu`: a TAB in an
# -install_name is asking THIS HOST'S ld to do something no real build ever
# does, and whether it accepts the byte, rejects it, warns-to-error on it, or
# silently normalises it is a fact about that linker, not about
# `drydock-macho-rewrite imports`. A bare failing `"$CC"` here would kill the whole
# suite under `set -eu`; asserting the refusal without checking the byte
# survived would pass vacuously (or fail for the wrong reason) if this
# host's linker declined to carry it through. So: build under `if`, not
# top-level, and read the result back with `drydock-macho-rewrite info` (which -- like
# `imports` before this fixture ever reaches it -- prints load-command paths
# raw, with no TAB handling of its own to interfere) to CONFIRM the byte
# really made it into imp_tab's own LC_LOAD_DYLIB before trusting anything
# about a refusal of it. Anything short of that confirmation SKIPs, loudly,
# naming why -- never a silent pass.
tab_build_ok=1
if ! "$CC" -dynamiclib -O2 $FIXTURE_FLAGS -install_name "$(printf 'a\tb')" \
        "$T/a.c" -o "$T/libtab.dylib" 2>"$T/libtab_build.err"; then
    tab_build_ok=0
fi
if [ "$tab_build_ok" -eq 1 ] \
    && ! "$CC" -O2 $FIXTURE_FLAGS "$T/main.c" "$T/libtab.dylib" -o "$T/imp_tab" \
        2>"$T/imp_tab_build.err"; then
    tab_build_ok=0
fi
tab_present=0
if [ "$tab_build_ok" -eq 1 ] \
    && "$DRYDOCK_MACHO_REWRITE" info "$T/imp_tab" 2>/dev/null | grep -qF "$(printf 'a\tb')"; then
    tab_present=1
fi
if [ "$tab_present" -eq 0 ]; then
    skip "imports: refuses an install_name carrying a TAB" \
        "this host's linker did not carry a TAB through into imp_tab's own LC_LOAD_DYLIB (confirmed via 'drydock-macho-rewrite info', not assumed): $(cat "$T/libtab_build.err" "$T/imp_tab_build.err" 2>/dev/null)"
    skip "imports: ... and prints nothing on stdout, not a partial row" "see above"
    skip "imports: ... naming the field and the offending byte" "see above"
else
    rc=0
    "$DRYDOCK_MACHO_REWRITE" imports "$T/imp_tab" >"$T/imp_tab.out" 2>"$T/imp_tab.err" || rc=$?
    [ "$rc" -eq 1 ] && ok "imports: refuses an install_name carrying a TAB (exit 1)" \
        || bad "imports: TAB injection" "expected 1, got $rc: $(cat "$T/imp_tab.err")"
    [ ! -s "$T/imp_tab.out" ] \
        && ok "imports: ... and prints nothing on stdout, not a partial row" \
        || bad "imports: TAB injection stdout" "expected empty, got: $(cat "$T/imp_tab.out")"
    grep -q 'install_name' "$T/imp_tab.err" && grep -q '0x09' "$T/imp_tab.err" \
        && ok "imports: ... naming the field and the offending byte" \
        || bad "imports: TAB injection message" "missing field/byte: $(cat "$T/imp_tab.err")"
fi

rc=0
"$DRYDOCK_MACHO_REWRITE" imports "$T/not-a-macho-in-cli-test" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] && ok "imports: refuses a non-Mach-O (exit 1)" \
    || bad "imports: non-Mach-O" "expected 1, got $rc"

"$T/mkchained" make "$T/imp_chained"
rc=0
"$DRYDOCK_MACHO_REWRITE" imports "$T/imp_chained" >/dev/null 2>"$T/imp_chained.err" || rc=$?
[ "$rc" -eq 1 ] && ok "imports: refuses a chained-fixups image (exit 1)" \
    || bad "imports: chained" "expected 1, got $rc: $(cat "$T/imp_chained.err")"
grep -q 'fixups set' "$T/imp_chained.err" \
    && ok "imports: ... and the refusal names the remedy" \
    || bad "imports: chained remedy" "no 'fixups set' in: $(cat "$T/imp_chained.err")"

# An image with NO bind stream at all -- not even an LC_DYLD_INFO(_ONLY)
# command -- is a SUCCESSFUL report of ZERO rows, header line included, and
# is one exit code away from "refused to look": that is the distinction a
# consumer of this output most needs told apart. `load-command delete` has no
# spelling for LC_DYLD_INFO (its KIND vocabulary is uuid/codesig/
# source-version/build-version/code-sign-drs -- src/lc_kinds.c), so the
# fixture is hand-built in C, beside tests/mkimplausible.c: the smallest
# possible thin 64-bit Mach-O is a bare mach_header_64 with zero load
# commands, which mi_wrap's own validation accepts outright.
"$CC" -O2 -I "$SRC_DIR" -o "$T/mknobind" "$HERE/mknobind.c"
"$T/mknobind" "$T/imp_nobind"
rc=0
"$DRYDOCK_MACHO_REWRITE" imports "$T/imp_nobind" >"$T/imp_nobind.out" 2>"$T/imp_nobind.err" || rc=$?
[ "$rc" -eq 0 ] && ok "imports: an image with no bind stream succeeds (exit 0)" \
    || bad "imports: no bind stream" "expected 0, got $rc: $(cat "$T/imp_nobind.err")"
imp_nb_lines=$(wc -l < "$T/imp_nobind.out" | tr -d ' ')
[ "$imp_nb_lines" = 1 ] && ok "imports: ... reporting the header alone (zero rows)" \
    || bad "imports: no bind stream lines" "wanted 1 line (header only), got $imp_nb_lines"

# Every special ordinal this build assigns a meaning to -- self/exe/flat, and
# MO_ORD_UNKNOWN, the one a raw SET_DYLIB_SPECIAL_IMM value outside all three
# maps to rather than being misreported as one of them. None of the four is
# reliably reachable from a linker on every host (tests/mknobind.c's own
# comment on -special says why), so the fixture is hand-built, the same
# device as the no-bind-stream fixture just above.
"$T/mknobind" "$T/imp_special" -special
rc=0
"$DRYDOCK_MACHO_REWRITE" imports "$T/imp_special" >"$T/imp_special.out" 2>"$T/imp_special.err" || rc=$?
[ "$rc" -eq 0 ] && ok "imports: a special-ordinal fixture succeeds" \
    || bad "imports: special ordinals" "expected 0, got $rc: $(cat "$T/imp_special.err")"
awk -F'\t' '
    NR==1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
    { got[$c["symbol"]] = $c["ordinal"]; kind[$c["symbol"]] = $c["kind"];
      name[$c["symbol"]] = $c["install_name"] }
    END {
        ok = 1
        if (got["_self_sym"] != "self")    ok = 0
        if (got["_exe_sym"]  != "exe")     ok = 0
        if (got["_flat_sym"] != "flat")    ok = 0
        if (got["_unk_sym"]  != "unknown") ok = 0
        for (s in kind) if (kind[s] != "-" || name[s] != "-") ok = 0
        exit !ok
    }
' "$T/imp_special.out" \
    && ok "imports: self/exe/flat/unknown each print their own ordinal name" \
    || bad "imports: special ordinals" "wrong mapping: $(cat "$T/imp_special.out")"

# A fat container reports every 64-bit slice, and the arch column tells them
# apart -- the two fat_arch entries are labelled x86_64 and arm64 (the same
# device the fat_edit fixture above uses: the label is the fat_arch table's
# own cputype/cpusubtype, independent of what the wrapped slice's own
# mach_header actually says).
"$BIN/makefat" "$T/imp_fat" "$T/imp_in" 0x1000007 3 12 "$T/imp_in" 0x100000c 0 12
rc=0
"$DRYDOCK_MACHO_REWRITE" imports "$T/imp_fat" >"$T/imp_fat.out" 2>"$T/imp_fat.err" || rc=$?
[ "$rc" -eq 0 ] && ok "imports: a fat container reports (exit 0)" \
    || bad "imports: fat" "expected 0, got $rc: $(cat "$T/imp_fat.err")"
imp_narch=$(awk -F'\t' 'NR>1{print $1}' "$T/imp_fat.out" | sort -u | wc -l | tr -d ' ')
[ "$imp_narch" -eq 2 ] && ok "imports: ... and the arch column names BOTH slices" \
    || bad "imports: fat arch" "wanted 2 distinct arch names, got $imp_narch: $(cat "$T/imp_fat.out")"
imp_fat_rows=$(awk -F'\t' 'NR>1' "$T/imp_fat.out" | wc -l | tr -d ' ')
imp_thin_rows=$(awk -F'\t' 'NR>1' "$T/imp.out" | wc -l | tr -d ' ')
[ "$imp_fat_rows" -eq $((imp_thin_rows * 2)) ] \
    && ok "imports: ... reporting BOTH slices' rows, not just the first" \
    || bad "imports: fat row count" "wanted $((imp_thin_rows * 2)) ($imp_thin_rows x2 slices), got $imp_fat_rows"

# One clean slice, one chained-fixups slice: the whole report refuses (see
# src/imports.h's own comment on mimp_report for why a fat container with
# one bad slice refuses rather than silently reporting the good one), and
# -- the one property the two-pass design exists for -- stdout carries
# NOTHING, not even the clean slice's own rows or the header line, even
# though that slice was fully validated before the chained slice was ever
# reached.
"$BIN/makefat" "$T/imp_fatchained" "$T/imp_in" 0x1000007 3 12 "$T/imp_chained" 0x100000c 0 12
rc=0
"$DRYDOCK_MACHO_REWRITE" imports "$T/imp_fatchained" >"$T/imp_fatchained.out" 2>"$T/imp_fatchained.err" || rc=$?
[ "$rc" -eq 1 ] && ok "imports: a fat container with one chained slice refuses the WHOLE report" \
    || bad "imports: fat+chained" "expected 1, got $rc: $(cat "$T/imp_fatchained.err")"
[ ! -s "$T/imp_fatchained.out" ] \
    && ok "imports: ... stdout is EMPTY, not the clean slice's rows" \
    || bad "imports: fat+chained stdout" "expected empty, got: $(cat "$T/imp_fatchained.out")"

# ============================================================================
# minos if-absent
# ============================================================================
"$CC" -O2 -o "$T/strip_version_min" "$HERE/strip_version_min.c"

"$CC" -O2 -o "$T/mkminos" "$HERE/mkminos.c"

build_main "$T/info_bv"
"$T/mkminos" bv "$T/info_bv" 1 12.0 12.3 || bad "info build-version: fixture setup" "mkminos bv failed"
[ "$("$T/mkminos" show "$T/info_bv")" = "build-version platform=1 minos=12.0.0 sdk=12.3.0" ] \
    || bad "info build-version: fixture setup" "got: $("$T/mkminos" show "$T/info_bv")"
rc=0; "$DRYDOCK_MACHO_REWRITE" info "$T/info_bv" >"$T/info_bv.txt" 2>&1 || rc=$?
[ "$rc" -eq 0 ] && grep -q '^LC\[[0-9]*\] LC_BUILD_VERSION cmdsize=24$' "$T/info_bv.txt" \
    && ok "info: the fixture's LC_BUILD_VERSION is listed" \
    || bad "info build-version" "rc $rc, no LC_BUILD_VERSION line: $(cat "$T/info_bv.txt")"
grep -qxF "  platform=1 minos=12.0.0 sdk=12.3.0" "$T/info_bv.txt" \
    && ok "info: LC_BUILD_VERSION's platform, minos and sdk are printed beneath it" \
    || bad "info build-version" "no platform/minos/sdk line: $(grep -A1 LC_BUILD_VERSION "$T/info_bv.txt")"
build_main "$T/info_vm"
"$T/mkminos" vmin "$T/info_vm" 10.12 10.13 || bad "info version-min: fixture setup" "mkminos vmin failed"
rc=0; "$DRYDOCK_MACHO_REWRITE" info "$T/info_vm" >"$T/info_vm.txt" 2>&1 || rc=$?
[ "$rc" -eq 0 ] && grep -qxF "  version=10.12.0 sdk=10.13.0" "$T/info_vm.txt" \
    && ok "info: the version-min line agrees with mkminos" \
    || bad "info version-min" "rc $rc: $(grep -A1 LC_VERSION_MIN_MACOSX "$T/info_vm.txt")"

build_main "$T/minos_fixture"
# A BARE invocation here would let `set -e` kill the WHOLE script the
# instant this ever exits nonzero -- which used to happen legitimately
# (before the exit-0-on-"already absent" fix above) and took every later
# verb's tests down with it, silently, with only a generic CTest error to
# show for it. Wrapped in `if` so a genuine failure is reported as ONE
# assertion (via bad(), below) and the suite keeps running.
if "$T/strip_version_min" "$T/minos_fixture" >"$T/strip_version_min.out"; then
    strip_rc=0
else
    strip_rc=$?
fi
if [ "$strip_rc" -ne 0 ]; then
    bad "minos if-absent: fixture setup" "strip_version_min exited $strip_rc: $(cat "$T/strip_version_min.out")"
fi
# The premise is only that LC_VERSION_MIN_MACOSX, the command minos if-absent
# adds, is absent; a modern linker's LC_BUILD_VERSION may stay.
before_minos=$("$DRYDOCK_MACHO_REWRITE" info "$T/minos_fixture")
if echo "$before_minos" | grep -q "LC_VERSION_MIN_MACOSX"; then
    bad "minos if-absent: fixture setup" "fixture still carries LC_VERSION_MIN_MACOSX"
else
    ok "minos if-absent: the fixture has no LC_VERSION_MIN_MACOSX before"
fi

printf 'minos if-absent 10.9\n' | "$DRYDOCK_MACHO_REWRITE" "$T/minos_fixture" "$T/minos_out" \
    >"$T/minos.out" 2>&1 || bad "minos if-absent: appends when absent" "$(cat "$T/minos.out")"
minos_info=$("$DRYDOCK_MACHO_REWRITE" info "$T/minos_out")
echo "$minos_info" | grep -q "LC_VERSION_MIN_MACOSX" && ok "minos if-absent: appends when absent" \
    || bad "minos if-absent: appends when absent" "not found in info output"
# Running it again, on the output above, which has the command, must not error.
if printf 'minos if-absent 10.9\n' | "$DRYDOCK_MACHO_REWRITE" "$T/minos_out" "$T/minos_out2" >/dev/null 2>&1; then
    ok "minos if-absent: leaves a present one alone, exit 0"
else
    bad "minos if-absent: leaves a present one alone" "errored on a file that already has one"
fi

# version-min never writes its input: FILE OUT, and an OUT that is FILE is refused.
build_main "$T/mo_in"; "$T/strip_version_min" "$T/mo_in" >/dev/null
mo_before=$(sha "$T/mo_in"); mo_ino=$(stat -f %i "$T/mo_in")
printf 'minos if-absent 10.9\n' | "$DRYDOCK_MACHO_REWRITE" "$T/mo_in" "$T/mo_out" >"$T/mo.out" 2>"$T/mo.err" \
    && ok "minos if-absent FILE OUT: succeeds" || bad "minos if-absent FILE OUT" "$(cat "$T/mo.err")"
[ "$(sha "$T/mo_in")" = "$mo_before" ] && [ "$(stat -f %i "$T/mo_in")" = "$mo_ino" ] \
    && ok "minos if-absent FILE OUT: FILE is untouched" || bad "minos if-absent FILE OUT" "FILE changed"
"$DRYDOCK_MACHO_REWRITE" info "$T/mo_out" | grep -q LC_VERSION_MIN_MACOSX \
    && ok "minos if-absent FILE OUT: OUT has the command" || bad "minos if-absent FILE OUT" "OUT lacks it"
# The verb said `Wrote OUT (N bytes)` on STDOUT; a script run says
# `OUT: written (N,NNN bytes)` on STDERR. Same claim -- it names the file it
# wrote -- in the stream and wording me_run uses.
grep -q "^$T/mo_out: written (" "$T/mo.err" \
    && ok "minos if-absent FILE OUT: says what it wrote" || bad "minos if-absent FILE OUT" "no written line: $(cat "$T/mo.err")"
rc=0; printf 'minos if-absent 10.9\n' | "$DRYDOCK_MACHO_REWRITE" "$T/mo_in" "$T/mo_in" >/dev/null 2>"$T/mo_same.err" || rc=$?
[ "$rc" -eq 2 ] && [ "$(sha "$T/mo_in")" = "$mo_before" ] \
    && ok "minos if-absent: OUT that is FILE is refused (2), FILE untouched" || bad "minos if-absent OUT=FILE" "rc $rc"
grep -q "never writes its input" "$T/mo_same.err" \
    && ok "minos if-absent: ... refused up front, before any work" \
    || bad "minos if-absent OUT=FILE" "not the up-front refusal: $(cat "$T/mo_same.err")"
ln -s "$T/mo_in" "$T/mo_link"
rc=0; printf 'minos if-absent 10.9\n' | "$DRYDOCK_MACHO_REWRITE" "$T/mo_in" "$T/mo_link" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok "minos if-absent: OUT that is a symlink to FILE is refused (2)" || bad "minos if-absent OUT=link" "rc $rc"
# A missing OUT is still a usage error, and still 2 -- `drydock-macho-rewrite FILE` alone
# matches no verb and is not the two-positional bare form, so it falls through
# to usage(). The verb reached the same place from its own argc check.
rc=0; printf 'minos if-absent 10.9\n' | "$DRYDOCK_MACHO_REWRITE" "$T/mo_in" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok "minos if-absent: a missing OUT is a usage error (2)" || bad "minos if-absent no OUT" "rc $rc"

# ============================================================================
# minos at-most, minos if-absent
# ============================================================================
# mn_setup FILE MODE ARG... -- one mkminos surgery on FILE.
mn_setup() { mn_f=$1; shift; mn_m=$1; shift; "$T/mkminos" "$mn_m" "$mn_f" "$@"; }
# statement | mkminos setup | mkminos show afterwards | the report line
while IFS='|' read -r mn_st mn_how mn_want mn_line; do
    build_main "$T/mn"
    mn_setup "$T/mn" $mn_how || bad "minos $mn_st: fixture setup" "mkminos $mn_how failed"
    rc=0; printf 'minos %s\n' "$mn_st" | "$DRYDOCK_MACHO_REWRITE" "$T/mn" "$T/mn.out" \
        >/dev/null 2>"$T/mn.err" || rc=$?
    [ "$rc" -eq 0 ] && [ "$("$T/mkminos" show "$T/mn.out")" = "$mn_want" ] \
        && ok "minos $mn_st on '$mn_how': the image ends as $mn_want" \
        || bad "minos $mn_st ($mn_how)" "rc $rc: $("$T/mkminos" show "$T/mn.out" 2>&1); $(cat "$T/mn.err")"
    grep -qxF "      $mn_line" "$T/mn.err" \
        && ok "minos $mn_st on '$mn_how': ... and the report says '$mn_line'" \
        || bad "minos $mn_st ($mn_how)" "no report line: $(cat "$T/mn.err")"
done <<'EOF'
at-most 10.9|vmin 10.12 10.13|version-min version=10.9.0 sdk=10.13.0|version-min 10.12 -> 10.9; sdk 10.13 kept
at-most 10.9|vmin 10.7 10.9|version-min version=10.7.0 sdk=10.9.0|version-min 10.7, at or below 10.9: kept; sdk 10.9 kept
at-most 10.9|bv 1 12.0 12.3|version-min version=10.9.0 sdk=12.3.0|build-version 12.0 -> version-min 10.9; sdk 12.3 carried over
at-most 10.9|bv 1 10.7 10.10|version-min version=10.7.0 sdk=10.10.0|build-version 10.7 -> version-min 10.7; sdk 10.10 carried over
at-most 10.9|none|version-min version=10.9.0 sdk=10.9.0|none -> version-min 10.9; sdk 10.9 written
if-absent 10.9|vmin 10.12 10.13|version-min version=10.12.0 sdk=10.13.0|version-min 10.12 kept (declared); sdk 10.13 kept
if-absent 10.9|vmin 10.7 10.9|version-min version=10.7.0 sdk=10.9.0|version-min 10.7, at or below 10.9: kept; sdk 10.9 kept
if-absent 10.9|bv 1 12.0 12.3|version-min version=12.0.0 sdk=12.3.0|build-version 12.0 -> version-min 12.0; sdk 12.3 carried over
if-absent 10.9|bv 1 10.7 10.10|version-min version=10.7.0 sdk=10.10.0|build-version 10.7 -> version-min 10.7; sdk 10.10 carried over
if-absent 10.9|none|version-min version=10.9.0 sdk=10.9.0|none -> version-min 10.9; sdk 10.9 written
EOF

# A zippered slice carries two LC_BUILD_VERSIONs; either statement leaves one
# LC_VERSION_MIN_MACOSX and neither of them.
build_main "$T/mn_zip"
"$T/mkminos" bv "$T/mn_zip" 1 12.0 12.3 && "$T/mkminos" add-bv "$T/mn_zip" 6 13.0 13.0 \
    || bad "minos zippered: fixture setup" "mkminos failed"
[ "$("$T/mkminos" show "$T/mn_zip")" = "build-version platform=1 minos=12.0.0 sdk=12.3.0
build-version platform=6 minos=13.0.0 sdk=13.0.0" ] \
    || bad "minos zippered: fixture setup" "not macOS + Mac Catalyst: $("$T/mkminos" show "$T/mn_zip")"
for mn_st in 'at-most 10.9' 'if-absent 10.9'; do
    case $mn_st in
        at-*) mn_want='version-min version=10.9.0 sdk=12.3.0' ;;
        *)    mn_want='version-min version=12.0.0 sdk=12.3.0' ;;
    esac
    rc=0; printf 'minos %s\n' "$mn_st" | "$DRYDOCK_MACHO_REWRITE" "$T/mn_zip" "$T/mn_zip.out" \
        >/dev/null 2>"$T/mn.err" || rc=$?
    [ "$rc" -eq 0 ] && [ "$("$T/mkminos" show "$T/mn_zip.out")" = "$mn_want" ] \
        && ok "minos $mn_st: a zippered slice ends with one LC_VERSION_MIN_MACOSX and no LC_BUILD_VERSION" \
        || bad "minos $mn_st (zippered)" "rc $rc: $("$T/mkminos" show "$T/mn_zip.out" 2>&1)"
    grep -q '^      build-version 12\.0 -> .*; Mac Catalyst build-version removed$' "$T/mn.err" \
        && ok "minos $mn_st: ... and the report names the Mac Catalyst command it removed" \
        || bad "minos $mn_st (zippered)" "no removal named: $(cat "$T/mn.err")"
done

# A slice that already holds one version-min at or below VERSION, and nothing
# else, is written byte for byte.
build_main "$T/mn_same"
"$T/mkminos" vmin "$T/mn_same" 10.9 10.9 || bad "minos unchanged: fixture setup" "mkminos vmin failed"
for mn_st in 'minos at-most 10.9' 'minos if-absent 10.9' 'target 10.9'; do
    rc=0; printf '%s\n' "$mn_st" | "$DRYDOCK_MACHO_REWRITE" "$T/mn_same" "$T/mn_same.out" \
        >/dev/null 2>"$T/mn.err" || rc=$?
    [ "$rc" -eq 0 ] && cmp -s "$T/mn_same" "$T/mn_same.out" \
        && ok "$mn_st: a slice already at version-min 10.9 is written byte for byte" \
        || bad "$mn_st (unchanged)" "rc $rc, or the bytes changed: $(cat "$T/mn.err")"
    grep -qxF "$T/mn_same: this run disturbed nothing, so there is nothing to re-check" "$T/mn.err" \
        && ! grep -q 'disturbed sizeofcmds' "$T/mn.err" \
        && ok "$mn_st: ... and the run reports that it disturbed nothing" \
        || bad "$mn_st (unchanged)" "not reported as disturbing nothing: $(cat "$T/mn.err")"
done
grep -qxF '    nothing to do: this binary already targets 10.9' "$T/mn.err" \
    && ok "target 10.9: ... and says there is nothing to do" \
    || bad "target 10.9 (unchanged)" "no 'nothing to do': $(cat "$T/mn.err")"
build_main "$T/mn_low"
"$T/mkminos" vmin "$T/mn_low" 10.12 10.13 || bad "minos lowered: fixture setup" "mkminos vmin failed"
rc=0; printf 'minos at-most 10.9\n' | "$DRYDOCK_MACHO_REWRITE" "$T/mn_low" "$T/mn_low.out" \
    >/dev/null 2>"$T/mn.err" || rc=$?
[ "$rc" -eq 0 ] && grep -qxF "$T/mn_low: this run disturbed sizeofcmds; none of that is re-checked" "$T/mn.err" \
    && ok "minos at-most 10.9: a run that lowers the minimum reports that it disturbed sizeofcmds" \
    || bad "minos at-most 10.9 (lowered)" "rc $rc: $(cat "$T/mn.err")"

# A slice that declares only a non-macOS platform is refused, not a miss:
# allow-unmatched does not cover it.
build_main "$T/mn_ios"
"$T/mkminos" bv "$T/mn_ios" 2 12.0 12.3 || bad "minos iOS: fixture setup" "mkminos bv failed"
mn_before=$(sha "$T/mn_ios")
for mn_script in 'minos at-most 10.9' 'allow-unmatched
minos if-absent 10.9'; do
    rm -f "$T/mn_ios.out"
    rc=0; printf '%s\n' "$mn_script" | "$DRYDOCK_MACHO_REWRITE" "$T/mn_ios" "$T/mn_ios.out" \
        >/dev/null 2>"$T/mn.err" || rc=$?
    [ "$rc" -eq 1 ] && [ ! -e "$T/mn_ios.out" ] && [ "$(sha "$T/mn_ios")" = "$mn_before" ] \
        && grep -qF "declares platform 2, not macOS; refusing to add a macOS minimum to it" "$T/mn.err" \
        && ok "minos: an iOS-only slice is refused (1), nothing written ($(echo "$mn_script" | tr '\n' ' '))" \
        || bad "minos (iOS)" "rc $rc: $(cat "$T/mn.err")"
done

rm -f "$T/mn_bad.out"
rc=0; printf 'minos at-most 10.x\n' | "$DRYDOCK_MACHO_REWRITE" "$T/mn_same" "$T/mn_bad.out" \
    >/dev/null 2>"$T/mn.err" || rc=$?
[ "$rc" -eq 2 ] && [ ! -e "$T/mn_bad.out" ] && grep -q "minos at-most: '10.x' is not a version" "$T/mn.err" \
    && ok "minos at-most: a malformed version is a parse error (2), nothing written" \
    || bad "minos at-most (bad version)" "rc $rc: $(cat "$T/mn.err")"

# ============================================================================
# fixups set classic keeps the declaration
# ============================================================================
# mkchained's LC_BUILD_VERSION is macOS, minos 12.0, sdk 12.0. The conversion
# keeps it as one LC_VERSION_MIN_MACOSX, just before the LC_DYLD_INFO_ONLY it
# adds: mkminos reads the values, info the order.
fk_order() { "$DRYDOCK_MACHO_REWRITE" info "$1" | sed -n 's/^LC\[[0-9]*\] //p' | tail -2; }
fk_run() { rm -f "$2"; rc=0; printf 'fixups set classic\n' | "$DRYDOCK_MACHO_REWRITE" "$1" "$2" \
    >/dev/null 2>"$T/fk.err" || rc=$?; }
"$T/mkchained" make "$T/fk_in"
fk_run "$T/fk_in" "$T/fk_out"
[ "$rc" -eq 0 ] && [ "$("$T/mkminos" show "$T/fk_out")" = "version-min version=12.0.0 sdk=12.0.0" ] \
    && ok "fixups set classic: a macOS LC_BUILD_VERSION is kept as LC_VERSION_MIN_MACOSX, minimum and sdk" \
    || bad "fixups keeps (values)" "rc $rc: $("$T/mkminos" show "$T/fk_out" 2>&1); $(cat "$T/fk.err")"
[ "$(fk_order "$T/fk_out")" = "LC_VERSION_MIN_MACOSX cmdsize=16
LC_DYLD_INFO_ONLY cmdsize=48" ] \
    && ok "fixups set classic: ... placed directly before the LC_DYLD_INFO_ONLY it adds" \
    || bad "fixups keeps (order)" "last two commands: $(fk_order "$T/fk_out")"
grep -qxF "      chained fixups -> LC_DYLD_INFO_ONLY; LC_BUILD_VERSION 12.0 (sdk 12.0) kept as LC_VERSION_MIN_MACOSX" \
    "$T/fk.err" \
    && ok "fixups set classic: ... and its report line says what it kept" \
    || bad "fixups keeps (report)" "$(cat "$T/fk.err")"

"$T/mkchained" make "$T/fk_vm"
"$T/mkminos" vmin "$T/fk_vm" 10.9 10.9 && "$T/mkminos" add-bv "$T/fk_vm" 1 12.0 12.0 \
    || bad "fixups keeps: fixture setup" "mkminos failed"
fk_run "$T/fk_vm" "$T/fk_vm.out"
[ "$rc" -eq 0 ] && [ "$("$T/mkminos" show "$T/fk_vm.out")" = "version-min version=10.9.0 sdk=10.9.0" ] \
    && ok "fixups set classic: an image that already has LC_VERSION_MIN_MACOSX gets no second one" \
    || bad "fixups keeps (has version-min)" "rc $rc: $("$T/mkminos" show "$T/fk_vm.out" 2>&1)"
grep -qxF "      chained fixups -> LC_DYLD_INFO_ONLY" "$T/fk.err" \
    && ok "fixups set classic: ... and its report line keeps nothing" \
    || bad "fixups keeps (has version-min)" "$(cat "$T/fk.err")"

"$T/mkchained" make "$T/fk_cat"
"$T/mkminos" add-bv "$T/fk_cat" 6 13.0 13.0 || bad "fixups keeps: fixture setup" "mkminos add-bv failed"
fk_run "$T/fk_cat" "$T/fk_cat.out"
[ "$rc" -eq 0 ] && [ "$("$T/mkminos" show "$T/fk_cat.out")" = "version-min version=12.0.0 sdk=12.0.0" ] \
    && ok "fixups set classic: a Mac Catalyst LC_BUILD_VERSION is stripped; only the macOS one is kept" \
    || bad "fixups keeps (Mac Catalyst)" "rc $rc: $("$T/mkminos" show "$T/fk_cat.out" 2>&1)"

"$T/mkchained" make "$T/fk_two"
"$T/mkminos" add-bv "$T/fk_two" 1 13.0 13.0 || bad "fixups keeps: fixture setup" "mkminos add-bv failed"
fk_run "$T/fk_two" "$T/fk_two.out"
[ "$rc" -eq 1 ] && [ ! -e "$T/fk_two.out" ] && grep -qF "2 macOS LC_BUILD_VERSION commands" "$T/fk.err" \
    && ok "fixups set classic: two macOS LC_BUILD_VERSIONs are refused (1), nothing written" \
    || bad "fixups keeps (two)" "rc $rc: $(cat "$T/fk.err")"

# FIXUPS THEN MINOS, OR MINOS THEN FIXUPS: THE SAME BYTES, with the stripped
# commands first, and with only 8 bytes of header pad.
for fo_mode in make make-lcfirst make-tight; do
    "$T/mkchained" "$fo_mode" "$T/fo_in"
    [ "$fo_mode" != make-tight ] \
        || "$DRYDOCK_MACHO_REWRITE" info "$T/fo_in" | grep -q '^header pad: 8 bytes available' \
        || bad "fixups/minos order: fixture setup" "make-tight's pad is not 8 bytes"
    rm -f "$T/fo_fm" "$T/fo_mf"
    rc=0
    printf 'fixups set classic\nminos at-most 10.9\n' | "$DRYDOCK_MACHO_REWRITE" "$T/fo_in" "$T/fo_fm" \
        >/dev/null 2>"$T/fo.err" || rc=$?
    printf 'minos at-most 10.9\nfixups set classic\n' | "$DRYDOCK_MACHO_REWRITE" "$T/fo_in" "$T/fo_mf" \
        >/dev/null 2>>"$T/fo.err" || rc=$?
    [ "$rc" -eq 0 ] && [ "$("$T/mkminos" show "$T/fo_fm")" = "version-min version=10.9.0 sdk=12.0.0" ] \
        && cmp -s "$T/fo_fm" "$T/fo_mf" \
        && ok "fixups and minos at-most, in either order, write the same bytes ($fo_mode)" \
        || bad "fixups/minos order ($fo_mode)" "rc $rc: $("$T/mkminos" show "$T/fo_fm" 2>&1) vs $("$T/mkminos" show "$T/fo_mf" 2>&1): $(cat "$T/fo.err")"
done

"$T/mkchained" make-tight7 "$T/fk_t7"
"$DRYDOCK_MACHO_REWRITE" info "$T/fk_t7" | grep -q '^header pad: 7 bytes available' \
    || bad "fixups keeps: fixture setup" "make-tight7's pad is not 7 bytes"
fk_run "$T/fk_t7" "$T/fk_t7.out"
[ "$rc" -eq 1 ] && [ ! -e "$T/fk_t7.out" ] && grep -qF "need 64 bytes, have 63" "$T/fk.err" \
    && ok "fixups set classic: 7 bytes of pad cannot hold the kept command too; refused (1), nothing written" \
    || bad "fixups keeps (7 bytes of pad)" "rc $rc: $(cat "$T/fk.err")"

"$T/mkchained" make "$T/fk_sim"; "$T/mkchained" make "$T/fk_simmac"
"$T/mkminos" bv "$T/fk_sim" 7 15.0 15.0 && "$T/mkminos" add-bv "$T/fk_simmac" 7 15.0 15.0 \
    || bad "fixups foreign platform: fixture setup" "mkminos failed"
for fk_case in 'fk_sim|declares platform 7, not macOS; refusing to add a macOS minimum to it' \
               'fk_simmac|declares platform 7 beside macOS; refusing rather than guess which it is'; do
    fk_f=${fk_case%%|*}; fk_why=${fk_case#*|}; fk_before=$(sha "$T/$fk_f")
    for fk_script in 'fixups set classic' 'target 10.9' 'fixups set classic\nminos at-most 10.9' \
                     'minos at-most 10.9\nfixups set classic'; do
        rm -f "$T/$fk_f.out"
        rc=0; printf '%b\n' "$fk_script" | "$DRYDOCK_MACHO_REWRITE" "$T/$fk_f" "$T/$fk_f.out" \
            >/dev/null 2>"$T/fk.err" || rc=$?
        [ "$rc" -eq 1 ] && [ ! -e "$T/$fk_f.out" ] && [ "$(sha "$T/$fk_f")" = "$fk_before" ] \
            && grep -qF "$fk_why" "$T/fk.err" \
            && ok "$(printf '%s' "$fk_script" | sed 's/\\n/, then /') on $fk_f: refused (1), nothing written: $fk_why" \
            || bad "fixups foreign platform ($fk_f: $fk_script)" "rc $rc: $(cat "$T/fk.err")"
    done
done

# ============================================================================
# lc -delete
# ============================================================================
build_main "$T/lc_fixture"
before_info=$("$DRYDOCK_MACHO_REWRITE" info "$T/lc_fixture")
echo "$before_info" | grep -q "LC_UUID" && ok "lc: fixture has LC_UUID before" \
    || bad "lc: precondition" "fixture has no LC_UUID to delete"
mts "$T/lc_fixture" "load-command delete uuid" >"$T/lc.out" || bad "lc: exit" "$(cat "$T/lc.out")"
after_info=$("$DRYDOCK_MACHO_REWRITE" info "$T/lc_fixture")
if echo "$after_info" | grep -q "LC_UUID"; then
    bad "lc: delete uuid" "LC_UUID still present"
else
    ok "lc: delete uuid removed it"
fi
# Whether a binary that's had its LC_UUID deleted can still be EXECUTED
# turns on TWO independent host facts, not on drydock-macho-rewrite: (a) kernel
# code-signing enforcement, killing ANY binary modified since it was
# signed -- see $signing_enforced, established above without ever running
# drydock-macho-rewrite; (b) modern dyld separately refusing to load an image with no
# LC_UUID at all ("missing LC_UUID load command"), which 10.9's dyld does
# not require. These showed up as genuinely different failure modes on the
# cross runner that motivated this (grow got SIGKILLed outright; this got
# far enough for dyld itself to abort on the missing UUID).
#
# signing_enforced already answers (a) honestly. For (b), run lc_fixture
# for real and read its OWN failure, rather than inferring it from a
# separate drydock-macho-rewrite-produced probe (the same masking risk as grow's old
# probe): only a failure whose message literally names the missing-LC_UUID
# refusal is treated as (b) and skipped; anything else, with signing
# already ruled out, is a real defect and FAILS.
if [ "$signing_enforced" -eq 1 ]; then
    skip "lc: binary still runs after uuid deletion" \
        "this host SIGKILLs any binary modified since it was signed at link time (established independently of drydock-macho-rewrite by the host probe above); a host policy, not a drydock-macho-rewrite defect, and exercised for real on 10.9"
else
    if (cd "$T" && ./lc_fixture) >"$T/lc_fixture_run.out" 2>&1; then
        ok "lc: binary still runs after uuid deletion"
    else
        lc_run_rc=$?
        if grep -qi "missing LC_UUID" "$T/lc_fixture_run.out" 2>/dev/null; then
            skip "lc: binary still runs after uuid deletion" \
                "modern dyld refuses to load any image with no LC_UUID at all ('missing LC_UUID load command'); 10.9's dyld has no such requirement. Code-signing enforcement was independently ruled out above (a trivially-perturbed binary DID run on this host), so this is dyld's own content-driven refusal, not a masked drydock-macho-rewrite defect"
        else
            bad "lc: run" "binary failed to execute after uuid deletion (exit $lc_run_rc: $(head -1 "$T/lc_fixture_run.out" 2>/dev/null || echo 'no output')), this host DOES run a trivially-perturbed binary fine (see host probe above), and dyld did not report its missing-LC_UUID message -- code-signing and the known dyld requirement are both ruled out, so this looks like a real drydock-macho-rewrite defect"
        fi
    fi
fi
# Unknown KIND is refused at PARSE time, before the rewriter is ever called --
# so a bad KIND never reaches (or is diagnosed by) code shared with
# change_dylib. cmd_lc used to make this check itself, against the same
# LC_STRIP_KINDS table ms_parse consults; the wording is ms_parse's now, and it
# names the statement and the line as every parse error does.
if mts "$T/lc_fixture" "load-command delete bogus-kind" >/dev/null 2>"$T/lc_bad.err"; then
    bad "lc: bad kind" "should be refused"
else
    ok "lc: unknown KIND refused"
fi
grep -q "load-command delete: unknown kind 'bogus-kind'" "$T/lc_bad.err" && ok "lc: bad kind message" \
    || bad "lc: bad kind message" "missing \"load-command delete: unknown kind 'bogus-kind'\": $(cat "$T/lc_bad.err")"
# lc -delete naming a KIND the file does not carry: the strip-cmds twin of
# the dylib -replace miss report above. The absence is MADE true by
# build_main_without_build_version rather than assumed from what the host's
# linker happens to emit -- see that helper for why the old assumption was
# false on the cross runner. So this is a guaranteed miss, not a maybe.
build_main_without_build_version "$T/lc_miss_fixture"
mts "$T/lc_miss_fixture" allow-unmatched "load-command delete build-version" \
    >"$T/lc_miss.out" 2>"$T/lc_miss.err" && lc_miss_rc=0 || lc_miss_rc=$?
[ "$lc_miss_rc" -eq 0 ] && ok "lc: allow-unmatched over an absent kind still exits 0" \
    || bad "lc: -delete of an absent kind" "expected 0, got $lc_miss_rc: $(cat "$T/lc_miss.err")"
grep -q "no load command of kind build-version to delete" "$T/lc_miss.err" \
    && ok "lc: names the kind that matched nothing" \
    || bad "lc: -delete of an absent kind" "expected the 'no load command of kind build-version to delete' message on stderr, got: $(cat "$T/lc_miss.err")"

# A duplicated delete for a kind the file DOES carry ("uuid" -- every build
# has one).
#
# THE TWO MODELS PART COMPANY HERE, and this assertion had to change its
# expectation, not just its spelling. As ONE verb invocation the two -delete
# flags were one pass over the load commands, and the second had to be credited
# with the match the first made or it would be reported as a false miss. As TWO
# STATEMENTS they are two passes: the first really strips the LC_UUID and the
# second really finds nothing, so the miss is REAL and saying so is correct --
# the sequential model has no shadowing to forgive. What survives unchanged is
# the property the old assertion existed to protect: the run still SUCCEEDS,
# and the LC_UUID is gone.
build_main "$T/lc_dup_fixture"
mts "$T/lc_dup_fixture" allow-unmatched "load-command delete uuid" "load-command delete uuid" \
    >/dev/null 2>"$T/lc_dup.err" || bad "lc: duplicate delete uuid" "$(cat "$T/lc_dup.err")"
"$DRYDOCK_MACHO_REWRITE" info "$T/lc_dup_fixture" | grep -q LC_UUID \
    && bad "lc: duplicate delete uuid" "LC_UUID survived two deletes: $(cat "$T/lc_dup.err")" \
    || ok "lc: a duplicate delete still strips the uuid and still exits 0"
grep -q "no load command of kind uuid to delete" "$T/lc_dup.err" \
    && ok "lc: the second delete reports its real miss -- one statement per pass, nothing shadowed" \
    || bad "lc: duplicate delete uuid" "the second delete found nothing but did not say so: $(cat "$T/lc_dup.err")"

# ============================================================================
# load-command delete of an unmatched KIND: the same "matched nothing" report
# as `load-command delete build-version` above (the fixture is stripped of it
# first, not assumed to lack it), refused by default instead of just a
# stderr note. EX_REFUSED (1), the same code a deliberate refusal uses
# elsewhere (cmd_verify), because mr_apply_image returns MR_REFUSED for this
# and MR_REFUSED is defined (src/rewrite.h) to equal EX_REFUSED.
# ============================================================================
build_main_without_build_version "$T/lc_fw_fixture"
mts "$T/lc_fw_fixture" "load-command delete build-version" \
    >/dev/null 2>"$T/lc_fw.err" && lc_fw_rc=0 || lc_fw_rc=$?
[ "$lc_fw_rc" -eq 1 ] && ok "lc: an unmatched KIND refuses by default (EX_REFUSED)" \
    || bad "lc: unmatched refusal" "expected exit 1, got $lc_fw_rc: $(cat "$T/lc_fw.err")"
grep -q "no load command of kind build-version to delete" "$T/lc_fw.err" \
    && ok "lc: the refusal still names the KIND that matched nothing" \
    || bad "lc: unmatched refusal message" "expected 'no load command of kind build-version to delete', got: $(cat "$T/lc_fw.err")"
# allow-unmatched lets the identical script succeed -- so the directive is
# what changed the answer, not something else about this fixture.
build_main_without_build_version "$T/lc_fw_lax_fixture"
mts "$T/lc_fw_lax_fixture" allow-unmatched "load-command delete build-version" \
    >/dev/null 2>/dev/null && lc_fw_lax_rc=0 || lc_fw_lax_rc=$?
[ "$lc_fw_lax_rc" -eq 0 ] && ok "lc: allow-unmatched lets the same unmatched KIND succeed" \
    || bad "lc: allow-unmatched" "expected 0, got $lc_fw_lax_rc"

# ============================================================================
# A directive alone, with no statement after it: a well-formed request to copy
# FILE to OUT -- exit 0, OUT written, nothing changed. There is no verb left
# whose usage could leak, which is why the third assertion survives from when
# there was: whatever this prints, it must not be change_dylib's spellings.
# ============================================================================
build_main "$T/dylib_noop_fixture"
dylib_noop_before=$(sha "$T/dylib_noop_fixture")
if mts "$T/dylib_noop_fixture" allow-unmatched >/dev/null 2>"$T/dylib_noop.err"; then
    ok "a directive alone: with no statement it is a well-formed script (exit 0)"
else
    bad "a directive alone" "a directive-only script was refused: $(cat "$T/dylib_noop.err")"
fi
[ "$(sha "$T/dylib_noop_fixture")" = "$dylib_noop_before" ] \
    && ok "a directive alone: ... and changed nothing, OUT being a copy of FILE" \
    || bad "a directive alone" "a script with no statement changed the bytes"
if grep -qE -- "-strip-lc|-add-rpath" "$T/dylib_noop.err"; then
    bad "a directive alone" "leaked change_dylib's usage (-strip-lc/-add-rpath) in: $(cat "$T/dylib_noop.err")"
else
    ok "a directive alone does not leak change_dylib's spellings"
fi

mts "$T/dylib_noop_fixture" fatal-warnings "load-command delete uuid" \
    >/dev/null 2>"$T/fw_gone.err" && fw_gone_rc=0 || fw_gone_rc=$?
[ "$fw_gone_rc" -eq 2 ] && ok "fatal-warnings: refused as an unknown statement (2)" \
    || bad "fatal-warnings gone" "expected exit 2, got $fw_gone_rc: $(cat "$T/fw_gone.err")"
grep -qF "unknown statement 'fatal-warnings'" "$T/fw_gone.err" \
    && ok "fatal-warnings: ... named exactly that" \
    || bad "fatal-warnings gone message" "expected \"unknown statement 'fatal-warnings'\", got: $(cat "$T/fw_gone.err")"

# ============================================================================
# dylib -replace  (and a replacement long enough to force a real header grow)
# ============================================================================
build_main "$T/dylib_fixture"
newpath="@loader_path/renamed-liba.dylib"
mts "$T/dylib_fixture" "dylib replace @loader_path/liba.dylib $newpath" \
    >"$T/dylib.out" || bad "dylib: -replace exit" "$(cat "$T/dylib.out")"
dylib_info=$("$DRYDOCK_MACHO_REWRITE" info "$T/dylib_fixture")
echo "$dylib_info" | grep -q "path=$newpath" && ok "dylib: -replace changed the path" \
    || bad "dylib: -replace" "new path not found in info output"

# A path long enough to overflow the header pad on any plausible linker
# default (10.9's leaves thousands of bytes): the header grows, with no
# directive asked for, and the grow is announced on stderr.
build_main "$T/dylib_grow_fixture"
longpath="@loader_path/$(printf 'x%.0s' $(seq 1 3500)).dylib"
rc=0
mts "$T/dylib_grow_fixture" "dylib replace @loader_path/liba.dylib $longpath" \
    >/dev/null 2>"$T/dylib_grow.err" || rc=$?
[ "$rc" -eq 0 ] && ok "dylib: a replacement that overflows the pad grows the header (exit 0)" \
    || bad "dylib: long path" "expected exit 0, got $rc: $(cat "$T/dylib_grow.err")"
grep -q "^$T/dylib_grow_fixture: grew the header pad by [0-9]* bytes ([0-9]* -> [0-9]* available); image base 0x[0-9a-f]* -> 0x[0-9a-f]*\$" "$T/dylib_grow.err" \
    && ok "dylib: ... and says so on stderr, naming the input" \
    || bad "dylib: grow announced" "$(cut -c1-200 "$T/dylib_grow.err")"
grown_info=$("$DRYDOCK_MACHO_REWRITE" info "$T/dylib_grow_fixture")
echo "$grown_info" | grep -qF "path=$longpath" && ok "dylib: ... and the result has the long path" \
    || bad "dylib: grown result" "long path not found"

# ============================================================================
# dylib: pinning the MR_REFUSED/MR_FAIL split (rewrite.h) through mr_apply_file
# and mi_open, which reaching this verb from drydock-macho-rewrite's own EX_REFUSED/EX_FAIL
# checks never exercised. Without these, reverting the reclassification in
# src/rewrite.c leaves this whole suite green -- confirmed by temporarily
# reverting the 64-bit-fat classification below and watching this section's
# own assertion catch it, then reverting the mutation.
# ============================================================================

# A non-Mach-O file: mi_open reads it fine (no I/O failure at all) and
# mi_validate declines it -- MI_NOT_MACHO, forwarded as MR_REFUSED, EX_REFUSED.
echo 'not a mach-o, just bytes' > "$T/dylib_notmacho"
rc=0
mts "$T/dylib_notmacho" "dylib replace /usr/lib/libSystem.B.dylib /tmp/x.dylib" \
    >/dev/null 2>"$T/dylib_notmacho.err" || rc=$?
[ "$rc" -eq 1 ] && ok "dylib: a non-Mach-O file is refused (EX_REFUSED)" \
    || bad "dylib: non-Mach-O" "expected exit 1, got $rc: $(cat "$T/dylib_notmacho.err")"

# A file too short to hold even a magic number. mr_apply_file had TWO size
# refusals and they were different claims: a 25-byte file is long enough
# to peek a magic and reaches mi_open, which declines it; 2 bytes was refused
# by mr_apply_file's own `st.st_size < 4` check, before the peek, with its own
# "too small to be a Mach-O" wording.
#
# THE SCRIPT PATH DOES NOT REACH THAT BRANCH. me_run opens FILE itself and
# hands mi_open a buffer, so both sizes come back from the one
# "not a readable 64-bit Mach-O" refusal. What this assertion exists to pin --
# that a file we sized and declined is a considered REFUSAL (1), never an
# operational failure (2) -- is unchanged and is what the exit code below
# asserts. The distinct wording is not reachable from any surviving front-end;
# mr_apply_file still carries it for its own callers.
rc=0
printf 'ab' > "$T/dylib_tiny"
mts "$T/dylib_tiny" "dylib replace /usr/lib/libSystem.B.dylib /tmp/x.dylib" \
    >/dev/null 2>"$T/dylib_tiny.err" || rc=$?
[ "$rc" -eq 1 ] \
    && ok "dylib: a file too small to hold a magic number is refused (1), not failed (2)" \
    || bad "dylib: 2-byte input" "exit $rc, want 1 -- a file we sized and declined is a considered refusal, not an operational failure; a caller that sees 2 will retry or report a broken environment instead of telling the user their input is not a Mach-O. Got: $(cat "$T/dylib_tiny.err")"
grep -q "not a readable 64-bit Mach-O" "$T/dylib_tiny.err" \
    && ok "dylib: ... and says the file is not a Mach-O, not that it failed" \
    || bad "dylib: 2-byte message" "expected 'not a readable 64-bit Mach-O': $(cat "$T/dylib_tiny.err")"

# An absent file: mr_apply_file's own open() fails before mi_open is ever
# reached -- a genuine syscall failure, MR_FAIL, EX_FAIL.
rc=0
mts "$T/no-such-file-for-dylib" "dylib replace /usr/lib/libSystem.B.dylib /tmp/x.dylib" \
    >/dev/null 2>"$T/dylib_absent.err" || rc=$?
[ "$rc" -eq 2 ] && ok "dylib: an absent file is a failure, not a refusal (EX_FAIL)" \
    || bad "dylib: absent file" "expected exit 2, got $rc: $(cat "$T/dylib_absent.err")"

# A 64-bit fat container (fat_arch_64 -- FAT_MAGIC_64/FAT_CIGAM_64, arm64e/
# watchOS-style wide offsets). mr_apply_file recognizes this from the first
# 4 bytes alone, before any further read, so the fixture needs nothing past
# that magic to exercise the check -- cheap to build: FAT_MAGIC_64 is
# 0xcafebabf (src/mach_compat.h), and on this host's native byte order that
# is the 4 bytes 0277 0272 0376 0312 (octal), file-order low-to-high.
printf '%b' '\0277\0272\0376\0312' > "$T/dylib_fat64"
rc=0
mts "$T/dylib_fat64" "dylib replace /usr/lib/libSystem.B.dylib /tmp/x.dylib" \
    >/dev/null 2>"$T/dylib_fat64.err" || rc=$?
[ "$rc" -eq 1 ] && ok "dylib: a 64-bit fat container is refused, not merely failed (EX_REFUSED)" \
    || bad "dylib: 64-bit fat" "expected exit 1, got $rc: $(cat "$T/dylib_fat64.err")"
grep -q "fat_arch_64" "$T/dylib_fat64.err" \
    && ok "dylib: names the 64-bit fat container as the reason" \
    || bad "dylib: 64-bit fat message" "no mention of fat_arch_64: $(cat "$T/dylib_fat64.err")"

# ============================================================================
# dylib -replace naming a path the image does not have matched nothing, and
# the tool used to say so NOWHERE: stdout reported only the -replace that DID
# fire, and the exit code was 0. Ask for two, get one, no way to tell -- the
# silent partial success docs/PROPOSAL.md's "verify" section exists to rule
# out ("Every defect found in this code has been a silent success.").
#
# The report has to land on stderr, not stdout: the compat/ wrappers need
# stdout byte-identical to the tools they replaced (tests/known-callers.sh,
# tests/wrapper_test.sh), so anything new has to go where those gates don't
# look.
# ============================================================================
build_main "$T/unmatched_fixture"
unmatched_out=$(mts "$T/unmatched_fixture" allow-unmatched \
        "dylib replace /usr/lib/libSystem.B.dylib /tmp/new.dylib" \
        "dylib replace /nope/absent.dylib /also/absent.dylib" \
        2>"$T/unmatched.err") && unmatched_rc=0 || unmatched_rc=$?
[ "$unmatched_rc" -eq 0 ] && ok "dylib: allow-unmatched still exits 0 despite the miss" \
    || bad "dylib: unmatched replace exit" "expected 0, got $unmatched_rc: $(cat "$T/unmatched.err")"
grep -qF "/nope/absent.dylib matched nothing" "$T/unmatched.err" \
    && ok "dylib: names the replace that matched nothing" \
    || bad "dylib: unmatched replace" "expected '/nope/absent.dylib matched nothing' on stderr, got: $(cat "$T/unmatched.err")"
grep -q "matched nothing" "$T/unmatched.err" && ok "dylib: says it matched nothing" \
    || bad "dylib: unmatched replace message" "expected 'matched nothing' on stderr, got: $(cat "$T/unmatched.err")"
if echo "$unmatched_out" | grep -q "matched nothing"; then
    bad "dylib: unmatched replace" "'matched nothing' leaked onto stdout: $unmatched_out"
else
    ok "dylib: the unmatched report is not on stdout"
fi
echo "$unmatched_out" | grep -qF "libSystem.B.dylib -> /tmp/new.dylib" \
    && ok "dylib: the replace that DID match is still reported" \
    || bad "dylib: matched replace" "expected 'libSystem.B.dylib -> /tmp/new.dylib' on stdout, got: $unmatched_out"

# THE SAME INVERSION, FOR delete -- which nothing asserted until now, and which
# a review found by inventing a mutant that survived every suite. Counting a
# dylib hit only when new_path != NULL leaves `replace` correct and makes every
# successful DELETE report itself as a miss: ctest, all six shell suites and the
# characterize digest stay green while `dylib delete P` prints "P matched
# nothing" for a P it just removed. By default that miss becomes a
# refusal, so the tool declines work it actually did and writes no OUT.
# The block above says a hit/miss inversion "has to be checked for directly,
# not just inferred from the positive cases passing". It said that of replace
# and then did not do it for delete.
# The deleted path must be one NOTHING BINDS TO: drydock-macho-rewrite refuses to delete a
# dylib a symbol still binds to, so using libSystem here would test the bind
# guard and never reach the hit/miss report at all -- green for the wrong
# reason, in a test written to catch exactly that.
build_main "$T/del_hit_fixture"
mts "$T/del_hit_fixture" "dylib append /tmp/del_hit_unbound.dylib" >/dev/null 2>&1
mts "$T/del_hit_fixture" "dylib delete /tmp/del_hit_unbound.dylib" \
    >/dev/null 2>"$T/del_hit.err" && del_hit_rc=0 || del_hit_rc=$?
[ "$del_hit_rc" -eq 0 ] \
    && ok "dylib: a delete that matched exits 0" \
    || bad "dylib: matched delete exit" "expected 0, got $del_hit_rc: $(cat "$T/del_hit.err")"
if grep -q "matched nothing" "$T/del_hit.err"; then
    bad "dylib: matched delete reported as a miss"         "a delete that REMOVED a command reported it matched nothing -- by default that refuses work the tool actually did: $(cat "$T/del_hit.err")"
else
    ok "dylib: a delete that matched is not reported as a miss"
fi
# The inverse of the two checks above: an implementation that reported EVERY
# operation as a miss (hit and miss inverted) would still pass every
# assertion so far -- inverting hit/miss is exactly the failure this feature
# exists to prevent, so it has to be checked for directly, not just inferred
# from the positive cases passing. The MATCHED path is named on stderr now --
# me_run echoes every statement there before running it -- so the pattern has
# to be the miss report itself, not the bare path, or this would fire on the
# echo.
if grep -qF "/usr/lib/libSystem.B.dylib matched nothing" "$T/unmatched.err"; then
    bad "dylib: matched replace" "the replace that DID match was reported as a miss: $(cat "$T/unmatched.err")"
else
    ok "dylib: the replace that matched is NOT reported as a miss"
fi

# THE ONE DELIBERATE BEHAVIOUR CHANGE OF THIS WHOLE DESIGN, asserted in its new
# meaning. `replace P X` then `delete P` on the same path.
#
# AS ONE VERB INVOCATION the -delete won, whatever the argument order, because
# mr_is_deleted scanned every change first (src/rewrite.c) -- so both operations
# matched the SAME load command and neither could be reported as a miss.
#
# AS TWO STATEMENTS they are two passes in the order written: the replace
# renames P to X, and the delete then looks for P and correctly finds nothing.
# The dependency SURVIVES, under its new name. That is the more honest reading
# of what was asked -- a caller who wrote a rename and then a delete of the old
# name has described a rename -- and the repo owner authorised it in advance.
# The order-independence given up was a rule that had to be documented to be
# predicted.
build_main "$T/dylib_conflict_fixture"
conflict_path="@loader_path/libconflict.dylib"
conflict_new="/also/absent.dylib"
mts "$T/dylib_conflict_fixture" "dylib append $conflict_path" \
    >/dev/null 2>&1 || bad "dylib: conflict fixture setup" "append of $conflict_path failed"
mts "$T/dylib_conflict_fixture" allow-unmatched \
        "dylib replace $conflict_path $conflict_new" \
        "dylib delete $conflict_path" \
        >"$T/conflict.out" 2>"$T/conflict.err" && conflict_rc=0 || conflict_rc=$?
[ "$conflict_rc" -eq 0 ] && ok "dylib: allow-unmatched, replace then delete on the same path still exits 0" \
    || bad "dylib: replace+delete same path" "expected 0, got $conflict_rc: $(cat "$T/conflict.err")"
conflict_info=$("$DRYDOCK_MACHO_REWRITE" info "$T/dylib_conflict_fixture")
if echo "$conflict_info" | grep -qF "path=$conflict_new"; then
    ok "dylib: replace+delete same path: the REPLACE won and the delete matched nothing"
else
    bad "dylib: replace+delete same path" "expected the replace to win ($conflict_new present), got: $conflict_info"
fi
if echo "$conflict_info" | grep -qF "path=$conflict_path"; then
    bad "dylib: replace+delete same path" "the old path survived the replace: $conflict_info"
else
    ok "dylib: replace+delete same path: the old path is gone, renamed rather than removed"
fi
# And the delete's miss is REPORTED, not swallowed. Under the set model this
# would have been a false miss and mr_is_deleted existed to prevent it; under
# the sequence model it is a true one, and saying so is the whole reason a
# caller can tell what happened.
grep -qF "$conflict_path matched nothing" "$T/conflict.err" \
    && ok "dylib: replace+delete same path: the delete's real miss is reported" \
    || bad "dylib: replace+delete same path" "the delete found nothing but did not say so: $(cat "$T/conflict.err")"

# ============================================================================
# dylib unmatched by default: turns the "matched nothing" report just above
# from a stderr note into a refusal. Two -replace ops, one of which matches
# and one of which cannot -- so this also proves that a refused run WRITES
# NOTHING, even though the rewrite itself succeeded: the verdict is decided
# before mr_apply_file's wa_write_new, so OUT is never created and the op that
# DID match lands nowhere.
#
# THIS ASSERTION USED TO SAY THE OPPOSITE. While the verb rewrote FILE, the
# write came last and was conditional on something having changed, so a mixed
# run wrote FILE and then refused; only an all-miss run (below) wrote nothing.
# A verb that writes OUT unconditionally cannot keep that order without
# leaving an output behind on a refusal, which is precisely what "refused"
# must not mean -- so the verdict moved ahead of the write, and both cases now
# give the same answer. Run WITHOUT mtip: whether OUT exists is the point.
# ============================================================================
build_main "$T/dylib_fw_fixture"
cp "$T/dylib_fw_fixture" "$T/dylib_fw_before"
rm -f "$T/dylib_fw_out"
printf 'dylib replace @loader_path/liba.dylib @loader_path/renamed-fw.dylib\ndylib replace /nope/absent-fw.dylib /also/absent-fw.dylib\n' \
    | "$DRYDOCK_MACHO_REWRITE" "$T/dylib_fw_fixture" "$T/dylib_fw_out" \
        >"$T/dylib_fw.out" 2>"$T/dylib_fw.err" && dylib_fw_rc=0 || dylib_fw_rc=$?
[ "$dylib_fw_rc" -eq 1 ] && ok "dylib: an unmatched op refuses by default (EX_REFUSED)" \
    || bad "dylib: unmatched refusal" "expected exit 1, got $dylib_fw_rc: $(cat "$T/dylib_fw.err")"
grep -qF "/nope/absent-fw.dylib matched nothing" "$T/dylib_fw.err" \
    && ok "dylib: the refusal still names the op that matched nothing" \
    || bad "dylib: unmatched refusal message" "expected '/nope/absent-fw.dylib matched nothing' on stderr, got: $(cat "$T/dylib_fw.err")"
[ ! -e "$T/dylib_fw_out" ] \
    && ok "dylib: the refusal wrote no OUT, though one statement did match" \
    || bad "dylib: unmatched refusal wrote OUT" "a refused run left $T/dylib_fw_out behind: $("$DRYDOCK_MACHO_REWRITE" info "$T/dylib_fw_out")"
cmp -s "$T/dylib_fw_fixture" "$T/dylib_fw_before" \
    && ok "dylib: the refusal left FILE byte-for-byte untouched" \
    || bad "dylib: unmatched refusal touched FILE" "FILE changed under a form that only reads it"
# allow-unmatched lets the identical script succeed -- so the directive is
# what changed the answer, not something else about this fixture.
build_main "$T/dylib_fw_lax_fixture"
mts "$T/dylib_fw_lax_fixture" allow-unmatched \
        "dylib replace @loader_path/liba.dylib @loader_path/renamed-fw-lax.dylib" \
        "dylib replace /nope/absent-fw.dylib /also/absent-fw.dylib" \
        >/dev/null 2>/dev/null && dylib_fw_lax_rc=0 || dylib_fw_lax_rc=$?
[ "$dylib_fw_lax_rc" -eq 0 ] && ok "dylib: allow-unmatched lets the same unmatched op succeed" \
    || bad "dylib: allow-unmatched" "expected 0, got $dylib_fw_lax_rc"

# EVERY operation matches nothing, not just one of several -- the case that
# used to be the only one where an unmatched refusal wrote nothing, because
# mr_process_thin's "nothing to change" early return left *out_modified at 0
# and the conditional write never ran. It is no longer the special case: the
# assertion above now says the same thing about a run where one operation
# DID match. Kept, because the two reach the refusal by different routes and
# both must end with no OUT.
build_main "$T/dylib_fw_allmiss_fixture"
cp "$T/dylib_fw_allmiss_fixture" "$T/dylib_fw_allmiss_before"
rm -f "$T/dylib_fw_allmiss_out"
printf 'dylib replace /nope/absent-fw-allmiss.dylib /also/absent-fw-allmiss.dylib\n' \
    | "$DRYDOCK_MACHO_REWRITE" "$T/dylib_fw_allmiss_fixture" "$T/dylib_fw_allmiss_out" \
        >/dev/null 2>"$T/dylib_fw_allmiss.err" && dylib_fw_allmiss_rc=0 || dylib_fw_allmiss_rc=$?
[ "$dylib_fw_allmiss_rc" -eq 1 ] && ok "dylib: refuses by default when EVERY op matched nothing" \
    || bad "dylib: unmatched refusal (all miss)" "expected exit 1, got $dylib_fw_allmiss_rc: $(cat "$T/dylib_fw_allmiss.err")"
[ ! -e "$T/dylib_fw_allmiss_out" ] \
    && ok "dylib: the refusal wrote no OUT when nothing at all matched" \
    || bad "dylib: unmatched refusal (all miss)" "a refused run left an OUT behind"
cmp -s "$T/dylib_fw_allmiss_fixture" "$T/dylib_fw_allmiss_before" \
    && ok "dylib: the refusal left the file byte-for-byte untouched when nothing at all matched" \
    || bad "dylib: unmatched refusal (all miss)" "the file was modified despite every operation matching nothing"

# ============================================================================
# dylib -append / -insert / -delete / -reexport
#
# -replace and the long-path grow (above) exercise only two of change_dylib's
# translation targets. The mapping itself -- drydock-macho-rewrite's flag to change_dylib's
# -- is the only new logic dylib/rpath add, so every op needs its own
# observable check, not just an exit code: a swapped mapping (say -append
# landing on change_dylib's -insert) would ship silently and INVERT dylib
# initialization order, which is the whole reason -insert exists (see
# docs/PROPOSAL.md "Why these names"). None of these dylibs need to exist on
# disk -- only the load-command rewrite is being checked here, via `drydock-macho-rewrite
# info`, never by running the binary.
# ============================================================================
spare="@loader_path/libspare.dylib"

# -append places the new dependency LAST -- after every existing one,
# INCLUDING the implicit libSystem.B.dylib the linker adds on its own, which
# is why this checks "highest ordinal in the file" rather than a hardcoded
# number (build_main's plain main.c still needs libSystem for _start/crt,
# so liba=1, libSystem=2, and spare correctly lands at 3, not 2).
build_main "$T/dylib_append_fixture"
before_append_info=$("$DRYDOCK_MACHO_REWRITE" info "$T/dylib_append_fixture")
last_ordinal_before=$(echo "$before_append_info" | grep -o "ordinal=[0-9]*" | sed 's/ordinal=//' | sort -n | tail -1)
mts "$T/dylib_append_fixture" "dylib append $spare" \
    >"$T/dylib_append.out" || bad "dylib: -append exit" "$(cat "$T/dylib_append.out")"
append_info=$("$DRYDOCK_MACHO_REWRITE" info "$T/dylib_append_fixture")
expect_ordinal=$((last_ordinal_before + 1))
echo "$append_info" | grep -qF "ordinal=$expect_ordinal path=$spare" \
    && ok "dylib: -append put the new dep last (ordinal $expect_ordinal)" \
    || bad "dylib: -append" "expected ordinal=$expect_ordinal path=$spare in: $append_info"
echo "$append_info" | grep -qF "ordinal=1 path=@loader_path/liba.dylib" && ok "dylib: -append left liba at ordinal 1" \
    || bad "dylib: -append (liba)" "expected liba still at ordinal 1 in: $append_info"

# -insert places the new dependency FIRST (ordinal 1), pushing liba to 2 --
# the mapping that specifically must not become -append, since load order is
# dyld INITIALIZATION order (docs/PROPOSAL.md).
build_main "$T/dylib_insert_fixture"
mts "$T/dylib_insert_fixture" "dylib insert $spare" \
    >"$T/dylib_insert.out" || bad "dylib: -insert exit" "$(cat "$T/dylib_insert.out")"
insert_info=$("$DRYDOCK_MACHO_REWRITE" info "$T/dylib_insert_fixture")
echo "$insert_info" | grep -qF "ordinal=1 path=$spare" && ok "dylib: -insert put the new dep at ordinal 1 (first)" \
    || bad "dylib: -insert" "expected ordinal=1 path=$spare in: $insert_info"
echo "$insert_info" | grep -qF "ordinal=2 path=@loader_path/liba.dylib" && ok "dylib: -insert renumbered liba to ordinal 2" \
    || bad "dylib: -insert (liba)" "expected liba renumbered to ordinal 2 in: $insert_info"

# -delete removes the dependency and renumbers survivors; reuses the
# -append fixture above (liba=1, spare=2) so deleting the UNUSED spare
# (never called, so nothing binds to it -- change_dylib refuses a -delete
# that would orphan a bound symbol) proves removal without disturbing liba.
mts "$T/dylib_append_fixture" "dylib delete $spare" \
    >"$T/dylib_delete.out" || bad "dylib: -delete exit" "$(cat "$T/dylib_delete.out")"
delete_info=$("$DRYDOCK_MACHO_REWRITE" info "$T/dylib_append_fixture")
if echo "$delete_info" | grep -qF "path=$spare"; then
    bad "dylib: -delete" "spare still present in: $delete_info"
else
    ok "dylib: -delete removed the spare dependency"
fi
echo "$delete_info" | grep -qF "ordinal=1 path=@loader_path/liba.dylib" && ok "dylib: -delete left liba at ordinal 1" \
    || bad "dylib: -delete (liba)" "expected liba still at ordinal 1 in: $delete_info"

# -reexport promotes LC_LOAD_DYLIB -> LC_REEXPORT_DYLIB for an EXISTING
# dependency; check the load-command KIND changed, not just that the path
# is still there (it would be, for -replace too).
build_main "$T/dylib_reexport_fixture"
mts "$T/dylib_reexport_fixture" "dylib reexport @loader_path/liba.dylib" \
    >"$T/dylib_reexport.out" || bad "dylib: -reexport exit" "$(cat "$T/dylib_reexport.out")"
reexport_info=$("$DRYDOCK_MACHO_REWRITE" info "$T/dylib_reexport_fixture")
echo "$reexport_info" | grep -A1 "LC_REEXPORT_DYLIB" | grep -qF "path=@loader_path/liba.dylib" \
    && ok "dylib: -reexport promoted liba to LC_REEXPORT_DYLIB" \
    || bad "dylib: -reexport" "no LC_REEXPORT_DYLIB naming liba in: $reexport_info"

# `dylib retype PATH KIND` rewrites an EXISTING dependency's load-command KIND
# to any of the four ordinal-bearing kinds (src/ordinals.c's table), not just
# LC_REEXPORT_DYLIB -- -reexport above is now one case it subsumes. The byte
# count never moves: only cmd changes, never cmdsize or the path.
#
# dylib_kind_of FILE PATH -- the LC[N] kind name on the line immediately
# above the `ordinal=N path=PATH` line in `drydock-macho-rewrite info`'s output. Used
# below to DERIVE the round-trip fixture's starting kind rather than assume
# it: this repo lost a day of red CI to a test that pinned a host- or
# fixture-fact nobody derived (see this file's own header).
dylib_kind_of() {
    "$DRYDOCK_MACHO_REWRITE" info "$1" | awk -v want="path=$2" '
        /^LC\[/ { kind = $2 }
        index($0, want) { print kind; exit }
    '
}
retype_lc_for() {
    case "$1" in
        load)     echo LC_LOAD_DYLIB ;;
        weak)     echo LC_LOAD_WEAK_DYLIB ;;
        reexport) echo LC_REEXPORT_DYLIB ;;
        upward)   echo LC_LOAD_UPWARD_DYLIB ;;
    esac
}
# dylib_cmdsize_of FILE PATH -- the NUMBER after `cmdsize=` on the same LC[N]
# line dylib_kind_of reads the kind from. "Size-neutral" is the central claim
# of `dylib retype` (only cmd changes; new_path is always "", so write_size
# never differs from cmdsize) -- total file byte count, `verify` passing, and
# a sha256 round trip are all indirect signals of that, none of them a direct
# assertion that THIS load command's cmdsize held still. This is that direct
# assertion.
dylib_cmdsize_of() {
    "$DRYDOCK_MACHO_REWRITE" info "$1" | awk -v want="path=$2" '
        /^LC\[/ { cmdsize = $0; sub(/.*cmdsize=/, "", cmdsize); cmdsize += 0 }
        index($0, want) { print cmdsize; exit }
    '
}

for k in weak reexport upward load; do
    build_main "$T/dylib_retype_fixture.$k"
    before_sz=$(wc -c < "$T/dylib_retype_fixture.$k")
    before_cmdsize=$(dylib_cmdsize_of "$T/dylib_retype_fixture.$k" "@loader_path/liba.dylib")
    mts "$T/dylib_retype_fixture.$k" "dylib retype @loader_path/liba.dylib $k" \
        >"$T/dylib_retype.$k.out" || bad "dylib: retype to $k exit" "$(cat "$T/dylib_retype.$k.out")"
    after_sz=$(wc -c < "$T/dylib_retype_fixture.$k")
    [ "$before_sz" = "$after_sz" ] \
        || bad "dylib: retype to $k" "changed the file size: $before_sz -> $after_sz"
    after_cmdsize=$(dylib_cmdsize_of "$T/dylib_retype_fixture.$k" "@loader_path/liba.dylib")
    [ "$before_cmdsize" = "$after_cmdsize" ] \
        || bad "dylib: retype to $k" "changed liba's own cmdsize: $before_cmdsize -> $after_cmdsize"
    "$DRYDOCK_MACHO_REWRITE" verify "$T/dylib_retype_fixture.$k" >/dev/null 2>&1 \
        || bad "dylib: retype to $k" "the result fails drydock-macho-rewrite verify"
    want_lc=$(retype_lc_for "$k")
    retype_info=$("$DRYDOCK_MACHO_REWRITE" info "$T/dylib_retype_fixture.$k")
    echo "$retype_info" | grep -A1 "$want_lc" | grep -qF "path=@loader_path/liba.dylib" \
        && ok "dylib: retype to $k produced $want_lc naming liba, cmdsize unchanged ($before_cmdsize)" \
        || bad "dylib: retype to $k" "no $want_lc naming liba in: $retype_info"
done

# GAP 2: the per-kind loop above cannot observe a build that
# skips the retype write specifically when the TARGET is `load`, because
# build_main's fixture already starts as LC_LOAD_DYLIB -- declining to write
# is unobservable when the bytes it would write are the bytes already there.
# Retype to weak FIRST, so the load command starts as LC_LOAD_WEAK_DYLIB, then
# retype that same command to load and confirm it really becomes
# LC_LOAD_DYLIB: that makes the write observable regardless of what the
# fixture started as.
build_main "$T/dylib_retype_to_load_fixture"
mts "$T/dylib_retype_to_load_fixture" "dylib retype @loader_path/liba.dylib weak" \
    >"$T/dylib_retype_to_load_pre.out" \
    || bad "dylib: retype to load from a non-load kind (setup: to weak)" "$(cat "$T/dylib_retype_to_load_pre.out")"
mts "$T/dylib_retype_to_load_fixture" "dylib retype @loader_path/liba.dylib load" \
    >"$T/dylib_retype_to_load.out" \
    || bad "dylib: retype to load from a non-load kind exit" "$(cat "$T/dylib_retype_to_load.out")"
to_load_info=$("$DRYDOCK_MACHO_REWRITE" info "$T/dylib_retype_to_load_fixture")
echo "$to_load_info" | grep -A1 "LC_LOAD_DYLIB" | grep -qF "path=@loader_path/liba.dylib" \
    && ok "dylib: retype to load from weak actually rewrites cmd (not skipped because target is load)" \
    || bad "dylib: retype to load from weak" "liba is not LC_LOAD_DYLIB after retyping from weak: $to_load_info"

# Round trip: retype to weak, then back to the fixture's OWN starting kind
# (derived, per above), reproduces the original bytes byte for byte.
build_main "$T/dylib_retype_rt_fixture"
start_kind=$(dylib_kind_of "$T/dylib_retype_rt_fixture" "@loader_path/liba.dylib")
case "$start_kind" in
    LC_LOAD_DYLIB|LC_LOAD_WEAK_DYLIB|LC_REEXPORT_DYLIB|LC_LOAD_UPWARD_DYLIB) : ;;
    *) bad "dylib: retype round trip" "could not derive liba's starting kind (got '$start_kind')" ;;
esac
start_kind_word=weak
[ "$start_kind" = LC_LOAD_DYLIB ] && start_kind_word=load
[ "$start_kind" = LC_LOAD_WEAK_DYLIB ] && start_kind_word=weak
[ "$start_kind" = LC_REEXPORT_DYLIB ] && start_kind_word=reexport
[ "$start_kind" = LC_LOAD_UPWARD_DYLIB ] && start_kind_word=upward
cp "$T/dylib_retype_rt_fixture" "$T/dylib_retype_rt_fixture.orig"
mts "$T/dylib_retype_rt_fixture" "dylib retype @loader_path/liba.dylib weak" \
    >"$T/dylib_retype_rt1.out" || bad "dylib: retype round trip (to weak)" "$(cat "$T/dylib_retype_rt1.out")"
mts "$T/dylib_retype_rt_fixture" "dylib retype @loader_path/liba.dylib $start_kind_word" \
    >"$T/dylib_retype_rt2.out" || bad "dylib: retype round trip (back to $start_kind_word)" "$(cat "$T/dylib_retype_rt2.out")"
[ "$(sha "$T/dylib_retype_rt_fixture.orig")" = "$(sha "$T/dylib_retype_rt_fixture")" ] \
    && ok "dylib: retype weak then back to $start_kind_word ($start_kind) round-trips to the original bytes" \
    || bad "dylib: retype round trip" "retype to weak then back to $start_kind_word did not reproduce the original bytes"

# `dylib reexport PATH` and `dylib retype PATH reexport` must agree byte for
# byte -- retype subsumes reexport, it does not reimplement it.
# ONE link, then a copy. Linking twice would compare two different binaries:
# this host's ld is byte-deterministic across invocations, so that passed here,
# and macos-26's is not, so it failed in CI on the first push.
build_main "$T/dylib_retype_eq_a"
cp "$T/dylib_retype_eq_a" "$T/dylib_retype_eq_b"
mts "$T/dylib_retype_eq_a" "dylib reexport @loader_path/liba.dylib" \
    >"$T/dylib_retype_eq_a.out" || bad "dylib: reexport (for retype comparison)" "$(cat "$T/dylib_retype_eq_a.out")"
mts "$T/dylib_retype_eq_b" "dylib retype @loader_path/liba.dylib reexport" \
    >"$T/dylib_retype_eq_b.out" || bad "dylib: retype ... reexport (for comparison)" "$(cat "$T/dylib_retype_eq_b.out")"
[ "$(sha "$T/dylib_retype_eq_a")" = "$(sha "$T/dylib_retype_eq_b")" ] \
    && ok "dylib: reexport and retype ... reexport agree byte for byte" \
    || bad "dylib: reexport vs retype reexport" "the two routes produced different bytes"

# A PATH that is not present is a miss, reported on stderr
# (src/rewrite.c's mr_report_unmatched), not a silent success.
build_main "$T/dylib_retype_miss_fixture"
printf 'dylib retype /nope.dylib weak\n' \
    | "$DRYDOCK_MACHO_REWRITE" "$T/dylib_retype_miss_fixture" "$T/dylib_retype_miss.out" \
    >/dev/null 2>"$T/dylib_retype_miss.err" || true
grep -q 'matched nothing' "$T/dylib_retype_miss.err" \
    && ok "dylib: retype of an absent path reports a miss" \
    || bad "dylib: retype miss" "no 'matched nothing' on stderr: $(cat "$T/dylib_retype_miss.err")"

# ============================================================================
# rpath -append
# ============================================================================
build_main "$T/rpath_fixture" "/tmp/cli_test_original_rpath"
before_rp=$("$DRYDOCK_MACHO_REWRITE" info "$T/rpath_fixture")
echo "$before_rp" | grep -q "rpath=/tmp/cli_test_original_rpath" && ok "rpath: fixture has original rpath" \
    || bad "rpath: precondition" "original rpath missing from info output"
mts "$T/rpath_fixture" "rpath append /tmp/cli_test_appended_rpath" \
    >"$T/rpath.out" || bad "rpath: -append exit" "$(cat "$T/rpath.out")"
after_rp=$("$DRYDOCK_MACHO_REWRITE" info "$T/rpath_fixture")
echo "$after_rp" | grep -q "rpath=/tmp/cli_test_original_rpath" && \
echo "$after_rp" | grep -q "rpath=/tmp/cli_test_appended_rpath" && \
    ok "rpath: -append kept the original and added the new one" || \
    bad "rpath: -append" "expected both rpaths in: $after_rp"

# -replace rewrites a search path in place; -delete removes one outright --
# neither was exercised above (only -append was), and each maps to a
# distinct change_dylib flag (-change-rpath / -delete-rpath) that a swapped
# mapping could silently confuse with the dylib family's -change/-delete.
build_main "$T/rpath_replace_fixture" "/tmp/cli_test_replace_before"
mts "$T/rpath_replace_fixture" "rpath replace /tmp/cli_test_replace_before /tmp/cli_test_replace_after" \
    >"$T/rpath_replace.out" || bad "rpath: -replace exit" "$(cat "$T/rpath_replace.out")"
replace_info=$("$DRYDOCK_MACHO_REWRITE" info "$T/rpath_replace_fixture")
if echo "$replace_info" | grep -q "rpath=/tmp/cli_test_replace_before"; then
    bad "rpath: -replace" "old rpath still present in: $replace_info"
else
    ok "rpath: -replace removed the old search path"
fi
echo "$replace_info" | grep -q "rpath=/tmp/cli_test_replace_after" && ok "rpath: -replace added the new search path" \
    || bad "rpath: -replace (new)" "new rpath not found in: $replace_info"

build_main "$T/rpath_delete_fixture" "/tmp/cli_test_delete_me"
mts "$T/rpath_delete_fixture" "rpath delete /tmp/cli_test_delete_me" \
    >"$T/rpath_delete.out" || bad "rpath: -delete exit" "$(cat "$T/rpath_delete.out")"
delete_rp_info=$("$DRYDOCK_MACHO_REWRITE" info "$T/rpath_delete_fixture")
if echo "$delete_rp_info" | grep -q "^  rpath="; then
    bad "rpath: -delete" "an rpath is still present in: $delete_rp_info"
else
    ok "rpath: -delete removed the search path"
fi

# rpath -replace naming a search path the file does not have: the rpath twin
# of the dylib -replace miss report above.
build_main "$T/rpath_miss_fixture" "/tmp/cli_test_rpath_present"
mts "$T/rpath_miss_fixture" allow-unmatched "rpath replace /tmp/cli_test_rpath_absent /tmp/cli_test_rpath_new" \
    >"$T/rpath_miss.out" 2>"$T/rpath_miss.err" && rpath_miss_rc=0 || rpath_miss_rc=$?
[ "$rpath_miss_rc" -eq 0 ] && ok "rpath: allow-unmatched -replace still exits 0" \
    || bad "rpath: unmatched -replace" "expected 0, got $rpath_miss_rc: $(cat "$T/rpath_miss.err")"
grep -q "rpath /tmp/cli_test_rpath_absent matched nothing" "$T/rpath_miss.err" \
    && ok "rpath: names the -replace that matched nothing" \
    || bad "rpath: unmatched -replace" "expected 'rpath /tmp/cli_test_rpath_absent matched nothing' on stderr, got: $(cat "$T/rpath_miss.err")"
rpath_miss_info=$("$DRYDOCK_MACHO_REWRITE" info "$T/rpath_miss_fixture")
echo "$rpath_miss_info" | grep -q "rpath=/tmp/cli_test_rpath_present" \
    && ok "rpath: an untouched rpath is left alone by the unmatched -replace" \
    || bad "rpath: unmatched -replace" "the ORIGINAL rpath disappeared: $rpath_miss_info"

# rpath unmatched by default: the same miss report just above, turned into a
# refusal, the rpath twin of the dylib unmatched-by-default block above.
build_main "$T/rpath_fw_fixture" "/tmp/cli_test_rpath_fw_present"
mts "$T/rpath_fw_fixture" \
        "rpath replace /tmp/cli_test_rpath_fw_absent /tmp/cli_test_rpath_fw_new" \
        >/dev/null 2>"$T/rpath_fw.err" && rpath_fw_rc=0 || rpath_fw_rc=$?
[ "$rpath_fw_rc" -eq 1 ] && ok "rpath: an unmatched op refuses by default (EX_REFUSED)" \
    || bad "rpath: unmatched refusal" "expected exit 1, got $rpath_fw_rc: $(cat "$T/rpath_fw.err")"
grep -q "rpath /tmp/cli_test_rpath_fw_absent matched nothing" "$T/rpath_fw.err" \
    && ok "rpath: the refusal still names the op that matched nothing" \
    || bad "rpath: unmatched refusal message" "expected the miss message on stderr, got: $(cat "$T/rpath_fw.err")"
# allow-unmatched lets the identical invocation succeed.
build_main "$T/rpath_fw_lax_fixture" "/tmp/cli_test_rpath_fw_lax_present"
mts "$T/rpath_fw_lax_fixture" allow-unmatched \
        "rpath replace /tmp/cli_test_rpath_fw_absent /tmp/cli_test_rpath_fw_new" \
        >/dev/null 2>/dev/null && rpath_fw_lax_rc=0 || rpath_fw_lax_rc=$?
[ "$rpath_fw_lax_rc" -eq 0 ] && ok "rpath: allow-unmatched lets the same unmatched op succeed" \
    || bad "rpath: allow-unmatched" "expected 0, got $rpath_fw_lax_rc"

# ============================================================================
# rpath -insert: the search path lands FIRST, not last
# ============================================================================
# THE ONLY THING WORTH ASSERTING HERE IS ORDER. dyld takes the first rpath
# that resolves, so an -insert whose result merely CONTAINS the new path is
# indistinguishable from an -append that silently stood in for it -- which is
# exactly the wrong answer this operation exists to rule out
# (docs/PROPOSAL.md: "flipping their order flips which one loads"). Every
# assertion below therefore compares POSITIONS in `drydock-macho-rewrite info`'s rpath list,
# never mere presence.
#
# `grep -n` over info's own stable "  rpath=" lines gives those positions
# without parsing otool.
rpath_positions() { "$DRYDOCK_MACHO_REWRITE" info "$1" | grep -n "^  rpath=" | sed 's/:.*rpath=/ /'; }
rpath_first() { rpath_positions "$1" | head -1 | sed 's/^[0-9]* //'; }
rpath_last()  { rpath_positions "$1" | tail -1 | sed 's/^[0-9]* //'; }

# Two rpaths baked in at link time, so "first" is a real position among
# several rather than the only one there is.
"$CC" -O2 $FIXTURE_FLAGS \
    -Xlinker -rpath -Xlinker "/tmp/cli_test_ins_existing_one" \
    -Xlinker -rpath -Xlinker "/tmp/cli_test_ins_existing_two" \
    "$T/main.c" "$T/liba.dylib" -o "$T/rpath_insert_fixture"
[ "$(rpath_first "$T/rpath_insert_fixture")" = "/tmp/cli_test_ins_existing_one" ] \
    && ok "rpath -insert: fixture starts with the linker's first rpath" \
    || bad "rpath -insert: precondition" "expected /tmp/cli_test_ins_existing_one first, got: $(rpath_positions "$T/rpath_insert_fixture")"

mts "$T/rpath_insert_fixture" "rpath insert /tmp/cli_test_inserted_rpath" \
    >"$T/rpath_insert.out" 2>&1 || bad "rpath: -insert exit" "$(cat "$T/rpath_insert.out")"
[ "$(rpath_first "$T/rpath_insert_fixture")" = "/tmp/cli_test_inserted_rpath" ] \
    && ok "rpath: -insert put the new search path FIRST" \
    || bad "rpath: -insert" "inserted path is not first: $(rpath_positions "$T/rpath_insert_fixture")"
# ...and did not eat either existing one, in either order.
ins_all=$(rpath_positions "$T/rpath_insert_fixture" | sed 's/^[0-9]* //' | tr '\n' ' ')
[ "$ins_all" = "/tmp/cli_test_inserted_rpath /tmp/cli_test_ins_existing_one /tmp/cli_test_ins_existing_two " ] \
    && ok "rpath: -insert kept both existing search paths, in their original order, behind it" \
    || bad "rpath: -insert order" "unexpected rpath order: $ins_all"

# THE ASSERTION THAT MAKES THE ONE ABOVE MEAN SOMETHING: -append on the SAME
# fixture must put its path LAST. If -insert were quietly implemented as
# -append, this pair could not both hold -- and the "first" assertion alone
# would pass against a fixture whose new path happened to sort first.
"$CC" -O2 $FIXTURE_FLAGS \
    -Xlinker -rpath -Xlinker "/tmp/cli_test_ins_existing_one" \
    -Xlinker -rpath -Xlinker "/tmp/cli_test_ins_existing_two" \
    "$T/main.c" "$T/liba.dylib" -o "$T/rpath_append_cmp_fixture"
mts "$T/rpath_append_cmp_fixture" "rpath append /tmp/cli_test_inserted_rpath" \
    >"$T/rpath_append_cmp.out" 2>&1 || bad "rpath: -append (comparison) exit" "$(cat "$T/rpath_append_cmp.out")"
[ "$(rpath_last "$T/rpath_append_cmp_fixture")" = "/tmp/cli_test_inserted_rpath" ] \
    && [ "$(rpath_first "$T/rpath_append_cmp_fixture")" = "/tmp/cli_test_ins_existing_one" ] \
    && ok "rpath: -append put the very same path LAST -- so -insert is not -append in disguise" \
    || bad "rpath: -append vs -insert" "append did not land last: $(rpath_positions "$T/rpath_append_cmp_fixture")"

# An image with NO existing rpath still honours -insert; there is simply
# nothing to be in front of. Combined with an -append in the same run, the
# inserted one must still come out first -- the case where a naive
# implementation that emits inserts after appends gets it backwards.
#
# Built with an explicit -headerpad MINIMUM rather than through build_main,
# because the default pad is a property of the LINKER, not of this test: 10.9's
# leaves ~3.1KB, while the modern cross runner's leaves 56 bytes, and this case
# adds two whole LC_RPATHs where the rest of the rpath cases only rewrite
# existing ones. It failed on the cross runner alone for exactly that reason
# ("new LCs (1432 bytes) don't fit in header pad (56 avail)"), which is
# tests/README.md's host-portability lesson arriving in a new place.
#
# -headerpad sets a FLOOR, so this is a no-op wherever the default already
# exceeds it -- measured on this 10.9 host: 0x800 changed nothing, 0x2000 moved
# the pad from 3128 to 11320. The value is deliberately well clear of what two
# rpaths need. It must NOT go into FIXTURE_FLAGS: the long-path grow case above
# depends on a 3500-character path overflowing whatever pad the linker left, so
# padding every fixture would silently stop that case from growing.
"$CC" -O2 $FIXTURE_FLAGS -Wl,-headerpad,0x2000 \
    "$T/main.c" "$T/liba.dylib" -o "$T/rpath_insert_empty"
"$DRYDOCK_MACHO_REWRITE" info "$T/rpath_insert_empty" | grep -q "^  rpath=" \
    && bad "rpath -insert: empty precondition" "fixture unexpectedly already has an rpath" \
    || ok "rpath -insert: empty-case fixture has no rpath to start with"
mts "$T/rpath_insert_empty" "rpath insert /tmp/cli_test_empty_ins" "rpath append /tmp/cli_test_empty_app" \
    >"$T/rpath_insert_empty.out" 2>&1 || bad "rpath: -insert (no existing) exit" "$(cat "$T/rpath_insert_empty.out")"
empty_all=$(rpath_positions "$T/rpath_insert_empty" | sed 's/^[0-9]* //' | tr '\n' ' ')
[ "$empty_all" = "/tmp/cli_test_empty_ins /tmp/cli_test_empty_app " ] \
    && ok "rpath: -insert lands before -append even in an image that had no rpaths" \
    || bad "rpath: -insert (no existing)" "unexpected order: $empty_all"

# The rewritten binary still runs: an LC_RPATH inserted in the wrong place, or
# one that desynchronized the load-command table, shows up here as a dyld
# failure rather than as a passing byte comparison.
if [ "$signing_enforced" -eq 1 ]; then
    skip "rpath: -insert result still runs" \
        "this host SIGKILLs any binary modified since it was signed at link time (established independently of drydock-macho-rewrite by the host probe above)"
elif (cd "$T" && ./rpath_insert_fixture) >"$T/rpath_insert_run.out" 2>&1; then
    ok "rpath: -insert result still runs"
else
    bad "rpath: -insert result" "the binary no longer runs: $(cat "$T/rpath_insert_run.out")"
fi

# ============================================================================
# segment: rename every matching LC_SEGMENT_64, and its sections' copy
# ============================================================================
# `drydock-macho-rewrite info` prints a segment's segname but NOT the copy of that name each
# section_64 carries, and the section copies are half of what this verb must
# change (getsectiondata matches on the section's copy -- see
# src/segname.h's header comment). segread below is a purpose-built
# reader for exactly that, in the same spirit as change_dylib_test.sh's
# ordinal_of/fatcheck: nothing here parses otool.
#
# It doubles as the fat-container half of this section. Building the fat file
# by hand rather than with lipo is change_dylib_test.sh's rule and its reason:
# what lipo will accept is not this suite's to pin. Slice 0 is the real
# 64-bit binary; slice 1 is a non-Mach-O blob that mr_apply_file must pass
# through byte for byte -- which is also the "only SOME slices match" case.
cat > "$T/segread.c" <<'EOF'
/* segread <mode> <file> [args]
 *
 *   segs  FILE          print "SEG <segname>" and "SECT <segname>/<sectname>"
 *                       for every LC_SEGMENT_64, in load order
 *   wrap  OUT THIN BLOB [CT1]
 *                       build a classic (32-bit fat_arch) fat container:
 *                       slice 0 = THIN, slice 1 = BLOB. CT1 is slice 1's
 *                       cputype and defaults to 7 (CPU_TYPE_X86). It does
 *                       NOT decide whether the rewriter skips the slice --
 *                       the slice's own bytes do -- it decides the
 *                       "arch N (cputype 0x...)" label the refusal names,
 *                       so pass 16777223 (CPU_TYPE_X86_64) when BLOB really
 *                       is a 64-bit Mach-O and the label should say so.
 *   dump  FILE IDX OUT  write fat slice IDX to OUT
 *
 * Names are char[16] and need not be NUL-terminated; printed with %.16s and
 * compared nowhere, so a 16-byte name comes out whole. Big-endian fat header
 * fields are written/read by hand -- FAT_MAGIC on disk is always big-endian.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>

static uint32_t be32(uint32_t v) {
    return ((v & 0xffu) << 24) | ((v & 0xff00u) << 8) |
           ((v & 0xff0000u) >> 8) | ((v >> 24) & 0xffu);
}

static uint8_t *slurp(const char *path, size_t *n) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(2); }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc((size_t)sz);
    if (!b || fread(b, 1, (size_t)sz, f) != (size_t)sz) { fprintf(stderr, "read %s\n", path); exit(2); }
    fclose(f);
    *n = (size_t)sz;
    return b;
}

static void spit(const char *path, const uint8_t *b, size_t n) {
    FILE *f = fopen(path, "wb");
    if (!f) { perror(path); exit(2); }
    if (fwrite(b, 1, n, f) != n) { perror("fwrite"); exit(2); }
    fclose(f);
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: segread segs|wrap|dump ...\n"); return 2; }

    if (strcmp(argv[1], "segs") == 0) {
        size_t n; uint8_t *b = slurp(argv[2], &n);
        const struct mach_header_64 *h = (const struct mach_header_64 *)b;
        if (n < sizeof *h || h->magic != MH_MAGIC_64) { fprintf(stderr, "not a thin 64-bit Mach-O\n"); return 2; }
        const uint8_t *p = b + sizeof *h;
        for (uint32_t i = 0; i < h->ncmds; i++) {
            const struct load_command *lc = (const struct load_command *)p;
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
                printf("SEG %.16s\n", sg->segname);
                const struct section_64 *sc = (const struct section_64 *)(sg + 1);
                for (uint32_t k = 0; k < sg->nsects; k++)
                    printf("SECT %.16s/%.16s\n", sc[k].segname, sc[k].sectname);
            }
            p += lc->cmdsize;
        }
        return 0;
    }

    if (strcmp(argv[1], "wrap") == 0) {
        if (argc != 5 && argc != 6) { fprintf(stderr, "usage: segread wrap OUT THIN BLOB [CT1]\n"); return 2; }
        uint32_t ct1 = (argc == 6) ? (uint32_t)strtoul(argv[5], NULL, 0) : 7u;
        size_t tn, bn;
        uint8_t *tb = slurp(argv[3], &tn), *bb = slurp(argv[4], &bn);
        const struct mach_header_64 *h = (const struct mach_header_64 *)tb;
        if (tn < sizeof *h || h->magic != MH_MAGIC_64) { fprintf(stderr, "slice 0 is not a thin 64-bit Mach-O\n"); return 2; }
        uint32_t align = 12;                       /* 4096, what real fat files use */
        uint32_t hdrlen = (uint32_t)(sizeof(struct fat_header) + 2 * sizeof(struct fat_arch));
        uint32_t off0 = (hdrlen + 4095u) & ~4095u;
        uint32_t off1 = (uint32_t)((off0 + tn + 4095u) & ~4095u);
        size_t total = off1 + bn;
        uint8_t *out = calloc(1, total);
        struct fat_header *fh = (struct fat_header *)out;
        fh->magic = be32(FAT_MAGIC);
        fh->nfat_arch = be32(2);
        struct fat_arch *ar = (struct fat_arch *)(out + sizeof *fh);
        ar[0].cputype = be32((uint32_t)h->cputype);
        ar[0].cpusubtype = be32((uint32_t)h->cpusubtype);
        ar[0].offset = be32(off0); ar[0].size = be32((uint32_t)tn); ar[0].align = be32(align);
        ar[1].cputype = be32(ct1); /* default CPU_TYPE_X86: a slice this rewriter skips */
        ar[1].cpusubtype = be32(3);
        ar[1].offset = be32(off1); ar[1].size = be32((uint32_t)bn); ar[1].align = be32(align);
        memcpy(out + off0, tb, tn);
        memcpy(out + off1, bb, bn);
        spit(argv[2], out, total);
        return 0;
    }

    if (strcmp(argv[1], "dump") == 0) {
        if (argc != 5) { fprintf(stderr, "usage: segread dump FILE IDX OUT\n"); return 2; }
        size_t n; uint8_t *b = slurp(argv[2], &n);
        const struct fat_header *fh = (const struct fat_header *)b;
        if (n < sizeof *fh || be32(fh->magic) != FAT_MAGIC) { fprintf(stderr, "not a fat file\n"); return 2; }
        uint32_t narch = be32(fh->nfat_arch);
        uint32_t idx = (uint32_t)strtoul(argv[3], NULL, 10);
        if (idx >= narch) { fprintf(stderr, "slice %u of %u\n", idx, narch); return 2; }
        const struct fat_arch *ar = (const struct fat_arch *)(b + sizeof *fh);
        uint32_t off = be32(ar[idx].offset), sz = be32(ar[idx].size);
        if ((size_t)off + sz > n) { fprintf(stderr, "slice out of bounds\n"); return 2; }
        spit(argv[4], b + off, sz);
        return 0;
    }

    fprintf(stderr, "unknown mode: %s\n", argv[1]);
    return 2;
}
EOF
"$CC" -O2 -o "$T/segread" "$T/segread.c"

# A fixture with a real __DATA segment whose sections therefore carry
# "__DATA" in their own segname fields. It is built to have MORE THAN ONE
# such section -- an initialised global (__data), a zero-initialised one
# (__bss/__common) and a call through libSystem (__la_symbol_ptr) -- because
# the rename has to walk every section of the matched segment, and a
# single-section fixture cannot tell "renames the sections" from "renames the
# first section".
cat > "$T/segmain.c" <<'EOF'
#include <string.h>
int g_counter = 7;
int g_zero;
char g_buf[64];
int main(void) {
    g_counter++;
    memset(g_buf, 'x', sizeof g_buf);
    g_zero = g_buf[0] == 'x';
    return (g_counter == 8 && g_zero) ? 0 : 1;
}
EOF
"$CC" -O2 $FIXTURE_FLAGS "$T/segmain.c" -o "$T/segment_fixture"
"$T/segread" segs "$T/segment_fixture" > "$T/segs_before"
grep -q "^SEG __DATA$" "$T/segs_before" && grep -q "^SECT __DATA/" "$T/segs_before" \
    && ok "segment: fixture has a __DATA segment whose sections name it" \
    || bad "segment: precondition" "no __DATA segment/section in: $(cat "$T/segs_before")"

# ---- info: section names --------------------------------------------------
# info: sectname lines, four spaces deep, read before the rename below mutates the fixture.
"$DRYDOCK_MACHO_REWRITE" info "$T/segment_fixture" >"$T/sect.out" 2>/dev/null

# Cross-checked against segread, never against otool, and never against a
# hand-written list: the two readers must agree on names AND on count.
"$T/segread" segs "$T/segment_fixture" | sed -n 's|^SECT [^/]*/||p' | sort >"$T/sect.want"
sed -n 's/^    sectname=//p' "$T/sect.out" | sort >"$T/sect.got"
cmp -s "$T/sect.want" "$T/sect.got" \
    && ok "info: sectname lines match segread, name for name" \
    || bad "info sectname" "differs: $(diff "$T/sect.want" "$T/sect.got" | head -5)"

[ -s "$T/sect.want" ] \
    && ok "info: the fixture really has sections to print" \
    || bad "info sectname" "the fixture has no sections; this assertion proves nothing"

# A 16-byte section name has no NUL, so %s would overrun. segment_16_fixture's
# long name is on the segment, not a section.
cat > "$T/sect16main.c" <<'EOF'
__attribute__((section("__DATA,ABCDEFGHIJKLMNOP"))) int g_sect16 = 1;
int main(void) { return g_sect16 == 1 ? 0 : 1; }
EOF
"$CC" -O2 $FIXTURE_FLAGS "$T/sect16main.c" -o "$T/sect16_fixture"
"$DRYDOCK_MACHO_REWRITE" info "$T/sect16_fixture" 2>/dev/null \
    | grep -qx '    sectname=ABCDEFGHIJKLMNOP' \
    && ok "info: a 16-byte sectname prints whole, with nothing after it" \
    || bad "info sectname 16" "expected the exact line '    sectname=ABCDEFGHIJKLMNOP': $("$DRYDOCK_MACHO_REWRITE" info "$T/sect16_fixture" 2>/dev/null | grep '^    sectname=')"

# ---- info: fat containers -------------------------------------------------
echo 'not a mach-o, just bytes' > "$T/notmacho"

# Two slices, same cputype: a real fat file never repeats an arch, but info must still read one.
"$T/segread" wrap "$T/info_fat" "$T/segment_fixture" "$T/segment_fixture" 16777223

rc=0; "$DRYDOCK_MACHO_REWRITE" info "$T/info_fat" >"$T/fat.out" 2>"$T/fat.err" || rc=$?
[ "$rc" -eq 0 ] && ok "info: a fat container is read, not refused" \
    || bad "info fat" "exited $rc: $(cat "$T/fat.err")"

[ "$(grep -c '^slice ' "$T/fat.out")" -eq 2 ] \
    && ok "info fat: one slice header per 64-bit slice" \
    || bad "info fat" "wanted 2 slice headers, got $(grep -c '^slice ' "$T/fat.out"): $(grep '^slice ' "$T/fat.out")"

# Each slice's body is the thin body. Compare slice 0's load commands with
# what info prints for that same slice standing alone.
"$T/segread" dump "$T/info_fat" 0 "$T/info_fat_s0"
"$DRYDOCK_MACHO_REWRITE" info "$T/info_fat_s0" 2>/dev/null | grep '^LC\[' >"$T/fat.thin.lc"
awk '/^slice /{n++} n==1' "$T/fat.out" | grep '^LC\[' >"$T/fat.s0.lc"
# Positive control: cmp of two EMPTY files also succeeds, which would make
# the match below pass vacuously if either extraction came up empty.
[ -s "$T/fat.s0.lc" ] \
    && ok "info fat: slice 0's LC lines were actually captured (positive control)" \
    || bad "info fat slice body" "empty extract -- the cmp below would pass vacuously: $(cat "$T/fat.out")"
cmp -s "$T/fat.thin.lc" "$T/fat.s0.lc" \
    && ok "info fat: a slice's load commands match the same slice read alone" \
    || bad "info fat slice body" "$(diff "$T/fat.thin.lc" "$T/fat.s0.lc" | head -5)"

# Every detection, on a fat file.
fat_sects=$(awk '/^slice /{n++} /^    sectname=/{c[n]++} END{print c[1]+0, c[2]+0}' "$T/fat.out")
echo "$fat_sects" | awk '{exit !($1 > 0 && $1 == $2)}' \
    && ok "info fat: section names are printed per slice" \
    || bad "info fat" "sectname lines per slice: $fat_sects (want two equal, nonzero counts)"
[ "$(grep -c '^swift-abi: ' "$T/fat.out")" -eq 2 ] \
    && ok "info fat: a swift-abi line per slice" \
    || bad "info fat" "wanted 2 swift-abi lines, got $(grep -c '^swift-abi: ' "$T/fat.out")"

rc=0; "$DRYDOCK_MACHO_REWRITE" info --thin "$T/info_fat" >"$T/fatthin.out" 2>"$T/fatthin.err" || rc=$?
[ "$rc" -eq 1 ] && ok "info --thin: a fat container is refused (1)" \
    || bad "info --thin fat" "did not exit 1 (got $rc)"
[ ! -s "$T/fatthin.out" ] \
    && ok "info --thin: a refused fat container prints nothing to stdout" \
    || bad "info --thin fat" "unexpected stdout: $(cat "$T/fatthin.out")"
[ "$(cat "$T/fatthin.err")" = "drydock-macho-rewrite info: $T/info_fat: not a readable 64-bit Mach-O" ] \
    && ok "info --thin: the refusal keeps mi_open's wording, byte for byte" \
    || bad "info --thin fat" "wrong message: $(cat "$T/fatthin.err")"

# A non-Mach-O slice is named and passed over, in me_run_fat's words -- not a
# second vocabulary for the same fact.
"$T/segread" wrap "$T/info_fat32" "$T/segment_fixture" "$T/notmacho" 7
rc=0; "$DRYDOCK_MACHO_REWRITE" info "$T/info_fat32" >"$T/fat32.out" 2>"$T/fat32.err" || rc=$?
[ "$rc" -eq 0 ] && ok "info fat: a container with a 32-bit slice is read (0)" \
    || bad "info fat 32-bit" "exited $rc: $(cat "$T/fat32.err")"
grep -q '^slice .*: 32-bit; passed through unchanged$' "$T/fat32.out" \
    && ok "info fat: a 32-bit slice reuses me_run_fat's wording" \
    || bad "info fat 32-bit" "got: $(grep '^slice ' "$T/fat32.out")"
[ "$(grep -c '^slice x86_64: ' "$T/fat32.out")" -eq 1 ] \
    && awk '/^slice /{n++} n==1' "$T/fat32.out" | grep -q '^LC\[' \
    && ok "info fat: the x86_64 slice beside a 32-bit one is still printed in full" \
    || bad "info fat 32-bit" "wanted one x86_64 slice with LC lines: $(cat "$T/fat32.out")"

printf '\312\376\272\276\000\000\000\000' >"$T/info_fat0"
rc=0; "$DRYDOCK_MACHO_REWRITE" info "$T/info_fat0" >"$T/fat0.out" 2>"$T/fat0.err" || rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$T/fat0.out")" = "$T/info_fat0: 8 bytes, 0 slices" ] \
    && ok "info fat: a fat header with no slices is reported as 0 slices (0)" \
    || bad "info fat 0 slices" "exit $rc, stdout: $(cat "$T/fat0.out"), stderr: $(cat "$T/fat0.err")"

# Tagged 64-bit but not a Mach-O: the other wording, chosen by the ABI bit alone.
"$T/segread" wrap "$T/info_fat64bad" "$T/segment_fixture" "$T/notmacho" 16777223
"$DRYDOCK_MACHO_REWRITE" info "$T/info_fat64bad" 2>/dev/null | grep -q '^slice .*: not a 64-bit Mach-O; passed through unchanged$' \
    && ok "info fat: a 64-bit-tagged non-Mach-O slice reuses me_run_fat's other wording" \
    || bad "info fat 64-bit non-macho" "got: $("$DRYDOCK_MACHO_REWRITE" info "$T/info_fat64bad" 2>/dev/null | grep '^slice ')"

rc=0; "$DRYDOCK_MACHO_REWRITE" info "$T/signing_probe" >"$T/thinagain.out" 2>"$T/thinagain.err" || rc=$?
[ "$rc" -eq 0 ] && ok "info: a thin file is still accepted" \
    || bad "info thin" "exited $rc: $(cat "$T/thinagain.err")"
grep -qE '^[^:]+: [0-9]+ bytes, [0-9]+ load commands, filetype=[0-9]+$' "$T/thinagain.out" \
    && ok "info: a thin file still prints its own header line" \
    || bad "info thin" "no thin header line in: $(cat "$T/thinagain.out")"
grep -q '^slice ' "$T/thinagain.out" \
    && bad "info thin" "a thin file grew a slice header" \
    || ok "info: a thin file still prints no slice header"

rc=0; "$DRYDOCK_MACHO_REWRITE" info "$T/notmacho" >"$T/nm.out" 2>"$T/nm.err" || rc=$?
[ "$rc" -eq 1 ] && ok "info notmacho: refused (1)" \
    || bad "info notmacho" "did not exit 1 (got $rc)"
[ ! -s "$T/nm.out" ] && ok "info notmacho: nothing to stdout" \
    || bad "info notmacho" "unexpected stdout: $(cat "$T/nm.out")"
[ "$(cat "$T/nm.err")" = "drydock-macho-rewrite info: $T/notmacho: not a readable 64-bit Mach-O" ] \
    && ok "info notmacho: keeps mi_open's wording, byte for byte" \
    || bad "info notmacho" "wrong message: $(cat "$T/nm.err")"

rc=0; "$DRYDOCK_MACHO_REWRITE" info --thin "$T/notmacho" >"$T/nmthin.out" 2>"$T/nmthin.err" || rc=$?
[ "$rc" -eq 1 ] && ok "info --thin notmacho: refused (1)" \
    || bad "info --thin notmacho" "did not exit 1 (got $rc)"
[ ! -s "$T/nmthin.out" ] && ok "info --thin notmacho: nothing to stdout" \
    || bad "info --thin notmacho" "unexpected stdout: $(cat "$T/nmthin.out")"
[ "$(cat "$T/nmthin.err")" = "drydock-macho-rewrite info: $T/notmacho: not a readable 64-bit Mach-O" ] \
    && ok "info --thin notmacho: keeps mi_open's wording, byte for byte" \
    || bad "info --thin notmacho" "wrong message: $(cat "$T/nmthin.err")"

mts "$T/segment_fixture" "segment rename __DATA __DATA_R9" \
    >"$T/segment.out" 2>&1 || bad "segment: exit" "$(cat "$T/segment.out")"
"$T/segread" segs "$T/segment_fixture" > "$T/segs_after"
grep -q "^SEG __DATA$" "$T/segs_after" \
    && bad "segment: the segment itself" "a segment is still named __DATA: $(cat "$T/segs_after")" \
    || ok "segment: renamed the LC_SEGMENT_64 itself"
grep -q "^SEG __DATA_R9$" "$T/segs_after" \
    && ok "segment: the new name is what landed" \
    || bad "segment: new name" "no __DATA_R9 segment in: $(cat "$T/segs_after")"
# The half `drydock-macho-rewrite info` cannot see: every section's own copy of the name.
if grep -q "^SECT __DATA/" "$T/segs_after"; then
    bad "segment: section segnames" "a section still names __DATA: $(cat "$T/segs_after")"
else
    ok "segment: renamed each section's copy of the segment name too"
fi
# `|| true`: grep -c exits 1 when the count is 0, and a bare command exiting
# nonzero under this script's `set -e` would kill the whole suite (see the
# reached_end guard at the top). 0 is a legitimate -- indeed the interesting
# -- answer here, so it must reach the comparison rather than the trap.
nsect_before=$(grep -c "^SECT __DATA/" "$T/segs_before" || true)
nsect_after=$(grep -c "^SECT __DATA_R9/" "$T/segs_after" || true)
[ "$nsect_before" -gt 0 ] && [ "$nsect_before" -eq "$nsect_after" ] \
    && ok "segment: all $nsect_before section(s) moved to the new name, none lost" \
    || bad "segment: section count" "$nsect_before sections named __DATA before, $nsect_after named __DATA_R9 after"
# Nothing else moved: __TEXT and its sections are untouched.
grep -q "^SEG __TEXT$" "$T/segs_after" && grep -q "^SECT __TEXT/__text$" "$T/segs_after" \
    && ok "segment: left every non-matching segment alone" \
    || bad "segment: collateral" "__TEXT changed: $(cat "$T/segs_after")"
if [ "$signing_enforced" -eq 1 ]; then
    skip "segment: the renamed binary still runs" \
        "this host SIGKILLs any binary modified since it was signed at link time (established independently of drydock-macho-rewrite by the host probe above)"
elif (cd "$T" && ./segment_fixture) >"$T/segment_run.out" 2>&1; then
    ok "segment: the renamed binary still runs"
else
    bad "segment: result" "the renamed binary no longer runs: $(cat "$T/segment_run.out")"
fi

# A NEW name of exactly 16 bytes fills the field with no room for a
# terminator -- the boundary rename_segment has always accepted, and the one a
# strcpy-based implementation gets wrong by writing a 17th byte.
"$CC" -O2 $FIXTURE_FLAGS "$T/segmain.c" -o "$T/segment_16_fixture"
mts "$T/segment_16_fixture" "segment rename __DATA ABCDEFGHIJKLMNOP" \
    >"$T/segment16.out" 2>&1 || bad "segment: 16-byte name exit" "$(cat "$T/segment16.out")"
"$T/segread" segs "$T/segment_16_fixture" | grep -q "^SEG ABCDEFGHIJKLMNOP$" \
    && ok "segment: accepts a NEW name of exactly 16 bytes and writes it whole" \
    || bad "segment: 16-byte name" "got: $("$T/segread" segs "$T/segment_16_fixture")"
# 17 is one too many, and must be refused before any I/O.
"$CC" -O2 $FIXTURE_FLAGS "$T/segmain.c" -o "$T/segment_17_fixture"
cp "$T/segment_17_fixture" "$T/segment_17_before"
rc=0
mts "$T/segment_17_fixture" "segment rename __DATA ABCDEFGHIJKLMNOPQ" \
    >"$T/segment17.out" 2>&1 || rc=$?
[ "$rc" -eq 1 ] && ok "segment: refuses a 17-byte NEW name with the documented refusal code" \
    || bad "segment: 17-byte name" "expected exit 1, got $rc: $(cat "$T/segment17.out")"
cmp -s "$T/segment_17_fixture" "$T/segment_17_before" \
    && ok "segment: a refused rename left the file byte-for-byte unchanged" \
    || bad "segment: 17-byte name" "the file was modified despite the refusal"

# A segment name nothing matches refuses by default -- and leaves the file
# alone.
"$CC" -O2 $FIXTURE_FLAGS "$T/segmain.c" -o "$T/segment_nomatch_fixture"
cp "$T/segment_nomatch_fixture" "$T/segment_nomatch_before"
rc=0
mts "$T/segment_nomatch_fixture" "segment rename __NOSUCHSEG __OTHER" \
    >"$T/segment_nomatch.out" 2>&1 || rc=$?
[ "$rc" -eq 1 ] && ok "segment: a rename that matches nothing refuses by default (EX_REFUSED)" \
    || bad "segment: no-match exit" "expected exit 1, got $rc: $(cat "$T/segment_nomatch.out")"
grep -q "segment __NOSUCHSEG matched nothing" "$T/segment_nomatch.out" \
    && ok "segment: the refusal names the segment that matched nothing" \
    || bad "segment: no-match message" "expected 'segment __NOSUCHSEG matched nothing', got: $(cat "$T/segment_nomatch.out")"
cmp -s "$T/segment_nomatch_fixture" "$T/segment_nomatch_before" \
    && ok "segment: a rename that matched nothing did not touch the file" \
    || bad "segment: no-match" "the file changed although no segment matched"
# allow-unmatched lets the identical rename succeed, still reporting the miss.
"$CC" -O2 $FIXTURE_FLAGS "$T/segmain.c" -o "$T/segment_nomatch_lax_fixture"
mts "$T/segment_nomatch_lax_fixture" allow-unmatched "segment rename __NOSUCHSEG __OTHER" \
    >/dev/null 2>"$T/segment_nomatch_lax.err" && seg_nomatch_lax_rc=0 || seg_nomatch_lax_rc=$?
[ "$seg_nomatch_lax_rc" -eq 0 ] && ok "segment: allow-unmatched lets a rename that matches nothing succeed" \
    || bad "segment: no-match (allow-unmatched)" "expected 0, got $seg_nomatch_lax_rc: $(cat "$T/segment_nomatch_lax.err")"
grep -q "segment __NOSUCHSEG matched nothing" "$T/segment_nomatch_lax.err" \
    && ok "segment: ... and the miss is still reported" \
    || bad "segment: no-match (allow-unmatched) message" "expected 'segment __NOSUCHSEG matched nothing', got: $(cat "$T/segment_nomatch_lax.err")"

# --- segment on a FAT container --------------------------------------------
# The case that matters for the wrappers: fix_macho's -rename_seg is
# fat-capable and folds into this verb, so this verb has to be too. The
# non-Mach-O second slice must come back byte for byte.
"$CC" -O2 $FIXTURE_FLAGS "$T/segmain.c" -o "$T/segment_fat_slice"
printf 'not a mach-o at all, just bytes to be preserved verbatim.\n' > "$T/segment_fat_blob"
"$T/segread" wrap "$T/segment_fat" "$T/segment_fat_slice" "$T/segment_fat_blob"
mts "$T/segment_fat" "segment rename __DATA __DATA_R9" \
    >"$T/segment_fat.out" 2>&1 || bad "segment: fat exit" "$(cat "$T/segment_fat.out")"
"$T/segread" dump "$T/segment_fat" 0 "$T/segment_fat_slice0"
"$T/segread" segs "$T/segment_fat_slice0" > "$T/segs_fat"
grep -q "^SEG __DATA_R9$" "$T/segs_fat" && ! grep -q "^SEG __DATA$" "$T/segs_fat" \
    && ok "segment: renamed the 64-bit slice of a fat container" \
    || bad "segment: fat slice 0" "expected __DATA_R9 and no __DATA in: $(cat "$T/segs_fat")"
grep -q "^SECT __DATA/" "$T/segs_fat" \
    && bad "segment: fat slice 0 sections" "a section still names __DATA: $(cat "$T/segs_fat")" \
    || ok "segment: renamed the fat slice's section segnames too"
"$T/segread" dump "$T/segment_fat" 1 "$T/segment_fat_blob_after"
cmp -s "$T/segment_fat_blob" "$T/segment_fat_blob_after" \
    && ok "segment: passed the non-Mach-O fat slice through byte for byte" \
    || bad "segment: fat slice 1" "the slice this rewriter cannot read was modified"

# ---- segment does NOT meet the mg_plausible gate ---------------------------
#
# mr_apply_file's last gate before writing (src/rewrite.c) asks whether the
# image's initializers and compact-unwind entries still name functions
# LC_FUNCTION_STARTS knows about. That is an OFFSET question about
# base-relative values, so mr_process_thin runs it only when the run disturbed
# them (src/relations.h's mrel_verify_applies). A segment rename disturbs
# nothing -- it writes characters into segname/sectname fields -- so it skips
# the gate, and these are the assertions that it really does, and that an
# operation which DOES disturb those values still meets it.
#
# The input is tests/mkimplausible.c's committed, hand-built fixture, not a
# scan of /usr/lib. An earlier version did scan for a dylib the gate refused,
# and SKIPped when it found nothing -- which passes on 10.9 and covers nothing
# on the cross runner, where those dylibs live only in the shared cache. Those
# refusals were also not the heuristic getting real dylibs wrong: it never ran
# on them (see mkimplausible.c's header), so the scan would come up empty
# today. The fixture trips the gate on its merits; its header says how.
"$CC" -O2 -Wall -Wextra -I "$SRC_DIR" -o "$T/mkimplausible" "$SRC_DIR/../tests/mkimplausible.c"
"$T/mkimplausible" "$T/implausible"

# `|| true`: a refusal is the expected outcome and this suite runs under set -e.
"$DRYDOCK_MACHO_REWRITE" verify "$T/implausible" >/dev/null 2>"$T/imp_verify.err" || true
grep -q 'implausible' "$T/imp_verify.err" \
    && ok "segment: the fixture really is one mg_plausible rejects" \
    || bad "segment: mg_plausible fixture" "drydock-macho-rewrite verify did not call it implausible: $(cat "$T/imp_verify.err")"

# `fixups set classic` genuinely disturbs the relation the gate checks --
# unlike `lc -delete`, which only frees header pad and repacks the command
# region without moving any base-relative content (mr_build_lcs's own
# behavior; see tests/mkimplausible.c's header for why that made the OLD
# version of this assertion's label an overstatement it happened to pass
# anyway). This fixture carries a real, if minimal, LC_DYLD_CHAINED_FIXUPS:
# one rebase link in __DATA. Converting it strips that command, rebuilds
# __LINKEDIT's rebase/bind opcode streams from scratch, and writes the
# resolved image base into the __DATA slot the chain pointed at -- content a
# rename or a header-pad free never touches. So it is refused, with the
# input left alone, and the skip below is narrow, not a hole.
cp "$T/implausible" "$T/imp_fx"
imp_before=$(shasum -a 256 < "$T/imp_fx" | cut -d' ' -f1)
if mts "$T/imp_fx" "fixups set classic" >/dev/null 2>"$T/imp_fx.err"; then
    bad "segment: mg_plausible scope" "fixups set classic was NOT refused, so the gate is gone"
else
    grep -q 'implausible' "$T/imp_fx.err" \
        && ok "segment: an operation that genuinely disturbs the relation still meets the gate" \
        || bad "segment: mg_plausible scope" "fixups set classic refused for another reason: $(cat "$T/imp_fx.err")"
fi
[ "$(shasum -a 256 < "$T/imp_fx" | cut -d' ' -f1)" = "$imp_before" ] \
    && ok "segment: that refusal left the input untouched" \
    || bad "segment: mg_plausible scope" "the refused input was modified"

# ---- ...and the narrowing really happened, at the VERB ---------------------
#
# The other half of "narrow, not a hole", and the half that would otherwise go
# unasserted: the same fixture, the same gate, an operation that disturbs
# NOTHING the gate checks -- and it goes through. `lc -delete uuid` frees
# header pad and repacks the command region; no base-relative value moves, so
# mrel_verify_applies says there is nothing to re-check and the rewrite is not
# refused for a property of its INPUT that it did not create.
#
# This is the assertion that fails if the derivation is thrown away and the
# gate goes back to running on every rewrite -- which is exactly what it looked
# like before the derivation, and exactly what a reviewer restoring "safety" would do.
# Its partner above (fixups set classic, refused) fails if the gate is deleted
# instead. Neither alone pins the rule; the pair does.
cp "$T/implausible" "$T/imp_lc"
if mts "$T/imp_lc" "load-command delete uuid" >/dev/null 2>"$T/imp_lc.err"; then
    ok "lc -delete: an operation that disturbs nothing the gate checks is not refused for its input"
else
    bad "segment: mg_plausible scope" \
        "lc -delete uuid was refused, so the gate still runs on operations with nothing to check: $(cat "$T/imp_lc.err")"
fi
# ...and it really did the edit, rather than passing by doing nothing.
"$DRYDOCK_MACHO_REWRITE" info "$T/imp_lc" 2>/dev/null | grep -q 'LC_UUID' \
    && bad "segment: mg_plausible scope" "lc -delete uuid exited 0 but the LC_UUID is still there" \
    || ok "lc -delete: and the command really is gone from the rewritten fixture"

# ---- and the same gate sees what a statement EXPANDED into -----------------
#
# `target 10.9` is the one statement whose meaning depends on the binary, so
# its row declares MREL_NONE -- nothing OF ITS OWN (src/script.c's table).
# Against this fixture it expands into `fixups set classic`, which declares
# plenty. A gate reading only the script's declared masks, statement by parsed
# statement, would therefore skip the verify on exactly the run that most
# needs it, and this file would be converted and written with an initializer
# naming no function start. What decides is what the run DID, accumulated as
# the statements (and their expansions) run, so the refusal below names the
# final verify and not the conversion.
cp "$T/implausible" "$T/imp_tgt"
if mts "$T/imp_tgt" "target 10.9" >/dev/null 2>"$T/imp_tgt.err"; then
    bad "edit: expansion is accumulated" \
        "target 10.9 lowered a fixups conversion and skipped the verify it most needs"
else
    grep -q 'refused at verification' "$T/imp_tgt.err" \
        && ok "edit: a statement's expansion decides the verify, not its declared mask" \
        || bad "edit: expansion is accumulated" \
               "target 10.9 refused for another reason: $(cat "$T/imp_tgt.err")"
fi

# ---- and when the gate does NOT apply, the report says what the run did ----
#
# With the verify conditional, "why was my file not verified?" is a question an
# operator can now reasonably ask, so the line that reports the skip names the
# relations the run disturbed (src/relations.h's mrel_name). It is a report
# line, so it goes to stderr with the rest of them and stdout is untouched --
# which is what the second assertion pins.
cp "$T/implausible" "$T/imp_say"
mts "$T/imp_say" "load-command delete uuid" >"$T/imp_say.out" 2>"$T/imp_say.err"
grep -q 'this run disturbed sizeofcmds; none of that is re-checked' "$T/imp_say.err" \
    && ok "edit: the skip line names what the run disturbed" \
    || bad "edit: the skip line names what the run disturbed" \
           "stderr does not name the relation: $(cat "$T/imp_say.err")"
grep -q 're-checked' "$T/imp_say.out" \
    && bad "edit: the skip line is a report line" "it landed on stdout" \
    || ok "edit: ...on stderr, where the rest of the report goes"

# ---- an EMPTY LC_FUNCTION_STARTS is "nothing to check", not a refusal ------
#
# The same fixture with three bytes changed: its 8-byte LC_FUNCTION_STARTS
# blob is all zeros, so it declares no function starts. That is the shape a
# dylib with NO CODE has -- a stub written to satisfy a link is the everyday
# example; the one instance on this host is libswiftObjectiveC.dylib, which
# is neither stock 10.9 nor a shipped product (tests/mkimplausible.c has the
# measured provenance note) -- and it is the same fact about an image as
# carrying no LC_FUNCTION_STARTS at all, which mg_plausible has always
# accepted. It folded the two apart for a while -- ns == 0 fell into a
# composite `ns <= 0 ||` refusal -- which refused
# that dylib with a contentless `FAILED (see above)` from verify and, through
# the rewrite path, with a message about base-relative offsets naming no known
# function when the image had no function starts for anything to name.
"$T/mkimplausible" "$T/emptystarts" -empty-starts
if "$DRYDOCK_MACHO_REWRITE" verify "$T/emptystarts" >"$T/es_verify.out" 2>&1; then
    ok "verify: an image declaring no function starts is accepted"
else
    bad "verify: empty LC_FUNCTION_STARTS" \
        "refused an image with nothing to check against: $(cat "$T/es_verify.out")"
fi
grep -q ': OK' "$T/es_verify.out" && ok "verify: and says OK about it" \
    || bad "verify: empty LC_FUNCTION_STARTS" "no OK verdict: $(cat "$T/es_verify.out")"

# ...and it is rewritable, which is the half the rewrite path got wrong: the
# gate sits in mr_process_thin, so a refusal here refused the operation too.
cp "$T/emptystarts" "$T/es_lc"
if mts "$T/es_lc" "load-command delete uuid" >/dev/null 2>"$T/es_lc.err"; then
    ok "lc -delete: an image declaring no function starts is rewritable"
else
    bad "lc -delete: empty LC_FUNCTION_STARTS" "refused: $(cat "$T/es_lc.err")"
fi

# ...while its twin, differing only in those three bytes, is still refused --
# so the acceptance above is about declaring no function starts, not about the
# gate having stopped asking.
cmp -s "$T/implausible" "$T/emptystarts" \
    && bad "verify: empty LC_FUNCTION_STARTS" "the two fixtures are identical; the flag did nothing" \
    || ok "verify: the accepted and refused fixtures really are different files"

# ...and a rename of the very same file goes through, and really renames.
cp "$T/implausible" "$T/imp_seg"
if mts "$T/imp_seg" "segment rename __DATA __DATA_R9" >/dev/null 2>"$T/imp_seg.err"; then
    "$T/segread" segs "$T/imp_seg" > "$T/imp_segs"
    grep -q "^SEG __DATA_R9$" "$T/imp_segs" && ! grep -q "^SEG __DATA$" "$T/imp_segs" \
        && ok "segment: renames a binary mg_plausible rejects for other operations" \
        || bad "segment: mg_plausible scope" "exited 0 but did not rename: $(cat "$T/imp_segs")"
    grep -q "^SECT __DATA/" "$T/imp_segs" \
        && bad "segment: mg_plausible scope" "a section still names __DATA" \
        || ok "segment: and renames that binary's section segnames too"
else
    bad "segment: mg_plausible scope" "refused the fixture: $(cat "$T/imp_seg.err")"
fi

# ---- MR_ERROR: one bad slice refuses the WHOLE fat file --------------------
#
# mr_process_fat (src/rewrite.c) splits per-slice failure in two: MR_SKIP for
# a slice that is not a 64-bit Mach-O -- left alone, other slices still
# rewritten, exit 0 -- and MR_ERROR for a slice that IS one and whose edit was
# refused, which aborts the whole file. Only MR_ERROR is a divergence from the
# tool this replaced (compat/README.md's fix_macho divergence 4, stated there
# most emphatically: fix_macho printed "Skipping arch %u" for BOTH and exited
# 0, having shipped a partially converted universal binary as a success).
#
# The asymmetry used to run the wrong way: MR_SKIP had an assertion (through
# the fat wrap just above and through fix_macho in wrapper_test.sh) and
# MR_ERROR had none, because building a hermetic bad slice looked like it
# needed a scan of the host. It does not: it needs a slice that IS a 64-bit
# Mach-O and whose edit is refused, while the OTHER slice's edit succeeds --
# so that a rewriter which wrote what it had would leave exactly the
# inconsistent file the message names.
#
# WHAT MAKES ONE SLICE REFUSE, and why it is no longer mg_plausible. This
# block used to run `lc -delete uuid` and rely on the implausible fixture
# meeting the gate. It no longer does: `load-command delete` frees header pad
# and moves no base-relative value, so the derived applicability
# (src/relations.h) skips the gate for it, the slice's edit succeeds, and
# there is no MR_ERROR to propagate. Nor can any verb make THIS fixture meet
# that gate: only a header grow disturbs the base-relative values, and
# mkimplausible builds an MH_DYLIB, which mg_grow_header refuses to grow at
# all (it has no __PAGEZERO to lower the base into).
#
# So the per-slice refusal is now the header-pad one: a dylib path whose load
# command fits ONE slice's header pad and not the OTHER's. One slice is
# edited, the other is refused, and the assertions below are unchanged in what
# they claim.
#
# WHICH SLICE PLAYS WHICH PART IS DERIVED, NOT ASSUMED, and so is the length.
# Every property this block claims is role-symmetric -- one slice is edited,
# the other refused, the whole file is refused, the refused slice is named,
# nothing is written -- so the test only has to KNOW which is which. The
# roomier of the two measured pads becomes slice 0 (edited) and the tighter
# becomes slice 1 (refused), and the path's load command is sized to fall
# between them.
#
# platform: one slice is compiled by $CC for the HOST, so its pad is the host
# toolchain's to decide: 2816 bytes on x86_64 against the fixture's 480, and
# 48 bytes on the Apple Silicon runner against that same 480. Not merely a
# different size -- an INVERSION, in which "fits the compiled slice and not
# the fixture" is impossible for any path length at all. A hardcoded 505-byte
# path made the compiled slice refuse FIRST there, and every assertion below
# passed while covering nothing about the second slice.
mrerr_pad() {
    "$DRYDOCK_MACHO_REWRITE" info "$1" \
        | sed -n 's/^header pad: \([0-9][0-9]*\) bytes available.*/\1/p'
}
# What appending PATH costs: sizeof(struct dylib_command) + strlen + NUL,
# rounded up to 8 -- src/rewrite.c's mr_emit_dylib_lc, which is what
# mg_ensure_pad then compares against the pad.
mrerr_lc_cost() { echo $(( ((24 + $1 + 1 + 7) / 8) * 8 )); }
mrerr_pad_compiled=$(mrerr_pad "$T/segment_fat_slice")
mrerr_pad_fixture=$(mrerr_pad "$T/implausible")
if [ -z "$mrerr_pad_compiled" ] || [ -z "$mrerr_pad_fixture" ]; then
    bad "lc: MR_ERROR pads" "drydock-macho-rewrite info reported no header pad for one of the two slices"
    mrerr_pad_compiled=0; mrerr_pad_fixture=0
fi
if [ "$mrerr_pad_compiled" -gt "$mrerr_pad_fixture" ]; then
    mrerr_edited="$T/segment_fat_slice"; mrerr_refused="$T/implausible"
    mrerr_pad_hi=$mrerr_pad_compiled;    mrerr_pad_lo=$mrerr_pad_fixture
else
    mrerr_edited="$T/implausible";       mrerr_refused="$T/segment_fat_slice"
    mrerr_pad_hi=$mrerr_pad_fixture;     mrerr_pad_lo=$mrerr_pad_compiled
fi
# The tighter slice must refuse for want of room rather than grow: a copy of
# it with MH_PIE cleared cannot grow, and its pad is the same.
cp "$mrerr_refused" "$T/mrerr_refused"
unpie "$T/mrerr_refused"
mrerr_refused="$T/mrerr_refused"
# The shortest path whose cost clears the tighter pad, whatever it is:
# cost(pad - 16) is at least pad + 9 and at most pad + 16, and a path is at
# least one character long.
long_len=$((mrerr_pad_lo - 16))
[ "$long_len" -ge 1 ] || long_len=1
long_cost=$(mrerr_lc_cost "$long_len")
[ "$long_cost" -gt "$mrerr_pad_lo" ] && [ "$long_cost" -le "$mrerr_pad_hi" ] \
    && ok "lc: MR_ERROR asymmetry: a $long_cost-byte load command fits the ${mrerr_pad_hi}-byte pad of $(basename "$mrerr_edited") and not the ${mrerr_pad_lo}-byte pad of $(basename "$mrerr_refused")" \
    || bad "lc: MR_ERROR asymmetry" \
           "no dylib path separates a ${mrerr_pad_hi}-byte pad from a ${mrerr_pad_lo}-byte one (tried $long_len bytes, costing $long_cost)"
if [ "$long_len" -ge 8 ]; then
    long_dylib="/$(printf 'a%.0s' $(seq 1 $((long_len - 7)))).dylib"
else
    # Every path of 1 to 7 characters costs the same 32 bytes, so the shortest
    # one stands in for all of them and long_cost above is still exact.
    long_dylib=/a
fi
"$T/segread" wrap "$T/mrerr_fat" "$mrerr_edited" "$mrerr_refused" 16777223
# WHICH NAME the refused slice goes by is the tool's answer, not a literal:
# ask the container itself, through the one message that lists every slice's
# name in table order (tests/edit_test.c pins its wording). i386 is an arch
# neither slice can be -- both are 64-bit Mach-Os, and slice 1 is declared
# x86_64 by the wrap. The refused one is slice 1, the second name.
mrerr_have=$(printf 'arch i386\ndylib append %s\n' "$long_dylib" \
    | "$DRYDOCK_MACHO_REWRITE" "$T/mrerr_fat" "$T/mrerr_probe" 2>&1 || :)
mrerr_slice1=$(printf '%s\n' "$mrerr_have" \
    | sed -n 's/.*(it has: [^,]*, *\([^)]*\)).*/\1/p')
[ -n "$mrerr_slice1" ] \
    && ok "lc: MR_ERROR slice 1 is the container's own $mrerr_slice1 slice" \
    || bad "lc: MR_ERROR slice label" "could not read slice 1's name back: $mrerr_have"
mrerr_before=$(shasum -a 256 < "$T/mrerr_fat" | cut -d' ' -f1)
if mts "$T/mrerr_fat" "dylib append $long_dylib" >"$T/mrerr.out" 2>"$T/mrerr.err"; then
    bad "lc: MR_ERROR fat slice" "exited 0; a partial rewrite was reported as success"
else
    ok "lc: a fat slice whose edit is refused refuses the whole file (nonzero exit)"
fi
# THE WORDING IS me_run_fat'S, NOT mr_process_fat'S, and that is the one thing
# this block had to change. The script path has its own per-slice driver
# (src/edit.c's me_fat_slice / me_statements): it labels a slice by ARCH NAME
# ("slice x86_64") where mr_process_fat labelled it by index and cputype
# ("arch 1 (cputype 0x1000007)"), and it reports the abort as "refused at
# statement N ... in slice NAME" rather than mr_process_fat's
# "refusing the whole fat file -- a partial rewrite would leave its slices
# inconsistent". Neither string is reachable from any surviving front-end.
# WHAT IS CLAIMED IS UNCHANGED: the whole file is refused, the slice is named,
# the slice's own reason is still on stderr, and nothing is written.
grep -q 'drydock-macho-rewrite edit: refused at statement' "$T/mrerr.err" \
    && ok "lc: and says so, naming the statement the whole file was refused at" \
    || bad "lc: MR_ERROR message" "expected me_run_fat's refusal, got: $(cat "$T/mrerr.err")"
grep -q "in slice $mrerr_slice1" "$T/mrerr.err" \
    && ok "lc: and names which slice it was" \
    || bad "lc: MR_ERROR slice label" "expected 'in slice $mrerr_slice1', got: $(cat "$T/mrerr.err")"
grep -q "don't fit in header pad" "$T/mrerr.err" \
    && ok "lc: and the underlying per-slice refusal is still on stderr too" \
    || bad "lc: MR_ERROR per-slice reason" "the slice's own refusal was swallowed: $(cat "$T/mrerr.err")"
# The premise the asymmetry rests on: slice 0 really could take this append.
# Without it the run would refuse at slice 0 and every assertion above would
# pass while covering nothing about the SECOND slice. Asserted against the
# very bytes the wrap used for slice 0, not against a container that merely
# resembles it.
cp "$mrerr_edited" "$T/mrok"
if mts "$T/mrok" "dylib append $long_dylib" >"$T/mrok.out" 2>"$T/mrok.err"; then
    ok "lc: and slice 0's own bytes really could take that append, so slice 1 is what refused"
else
    bad "lc: MR_ERROR premise" "slice 0 refused it too: $(cat "$T/mrok.err")"
fi
# The whole point of refusing: slice 0 WAS editable, so an abort that wrote
# anything would leave exactly the inconsistent file the message names.
[ "$(shasum -a 256 < "$T/mrerr_fat" | cut -d' ' -f1)" = "$mrerr_before" ] \
    && ok "lc: and left the fat file byte-for-byte unchanged, slice 0 included" \
    || bad "lc: MR_ERROR atomicity" "the refused fat file was modified"
# ---- A SLICE IS WHAT ITS BYTES ARE, NOT WHAT ITS fat_arch SAYS -------------
#
# The two fat loops in this repo have to answer "is this slice a 64-bit
# Mach-O?" the same way. src/rewrite.c's asks the slice's own bytes
# (mr_process_thin returns MR_SKIP for exactly `mi_wrap(...) != 0`);
# src/edit.c's me_run_fat asked the fat_arch's DECLARED cputype, and every
# compat wrapper moved from the first loop to the second. A container whose
# fat_arch disagrees with its slice was therefore processed by one and skipped
# by the other -- measured through change_dylib and fix_macho as a silent
# installed-bytes change in one direction (exit 0 -> 0) and a NEW REFUSAL in
# the other (exit 0 -> 1). Both shapes are asserted here, in the direction the
# unified classification gives.
#
# Reachable, if narrowly: lipo never emits a container whose fat_arch cputype
# and slice magic disagree, a truncated or hand-built one can, and nothing in
# compat/ intercepts change_dylib or fix_macho before they reach this code.
#
# SHAPE ONE: declared 32-bit over a slice that IS a 64-bit Mach-O. The very
# same two slices as mrerr_fat above, in the same derived roles -- only
# ar[1].cputype differs, i386 instead of x86_64 -- so the outcome must be the
# same one: slice 1 is a 64-bit Mach-O that cannot take the append, and the
# whole file is refused. A build that read the declaration would pass slice 1
# through and exit 0. The roles have to be the derived ones here too: with
# the roomier slice in slot 1 this refuses at slice 0 instead, and both
# assertions below pass without slice 1's declaration ever being tested.
"$T/segread" wrap "$T/fatdecl32" "$mrerr_edited" "$mrerr_refused" 7
fatdecl32_before=$(shasum -a 256 < "$T/fatdecl32" | cut -d' ' -f1)
if mts "$T/fatdecl32" "dylib append $long_dylib" >"$T/fatdecl32.out" 2>"$T/fatdecl32.err"; then
    bad "fat: declared 32-bit over a 64-bit slice" \
        "exit 0 -- the slice was passed through on its fat_arch's word, so the same container is edited or skipped depending on which cputype it happens to declare: $(cat "$T/fatdecl32.err")"
else
    ok "fat: a slice declared 32-bit is still read as the 64-bit Mach-O it is"
fi
[ "$(shasum -a 256 < "$T/fatdecl32" | cut -d' ' -f1)" = "$fatdecl32_before" ] \
    && ok "fat: ... and that refusal left the container byte-for-byte unchanged" \
    || bad "fat: declared 32-bit over a 64-bit slice" "the refused fat file was modified"
grep -q "don't fit in header pad" "$T/fatdecl32.err" \
    && ok "fat: ... refused for the slice's own reason, not for its declaration" \
    || bad "fat: declared 32-bit over a 64-bit slice" \
           "refused, but not by editing slice 1: $(cat "$T/fatdecl32.err")"

# SHAPE TWO: declared 64-bit over a slice that is NOT a Mach-O at all. This is
# the direction that acquired a new refusal: the run must pass that slice
# through and SUCCEED, rewriting the slice it does understand -- which is what
# `fix_macho` has always done ("Skipping arch %u") and what src/rewrite.c's
# loop does today.
dd if=/dev/zero bs=1 count=4096 2>/dev/null | tr '\000' 'Z' > "$T/notmacho"
"$T/segread" wrap "$T/fatdecl64" "$T/segment_fat_slice" "$T/notmacho" 16777223
if mts "$T/fatdecl64" 'dylib append /fatdecl64.dylib' >"$T/fatdecl64.out" 2>"$T/fatdecl64.err"; then
    ok "fat: a slice declared 64-bit that is not a Mach-O is passed through, not refused"
else
    bad "fat: declared 64-bit over a non-Mach-O slice" \
        "the whole run was refused on a container the pre-script tool rewrote and exited 0 on: $(cat "$T/fatdecl64.err")"
fi
grep -q 'slice x86_64: not a 64-bit Mach-O; passed through unchanged' "$T/fatdecl64.err" \
    && ok "fat: ... and the report says why, without calling it 32-bit" \
    || bad "fat: declared 64-bit over a non-Mach-O slice" \
           "no pass-through line naming the real reason: $(cat "$T/fatdecl64.err")"
"$T/segread" dump "$T/fatdecl64" 0 "$T/fatdecl64_s0"
"$DRYDOCK_MACHO_REWRITE" info "$T/fatdecl64_s0" | grep -qF "path=/fatdecl64.dylib" \
    && ok "fat: ... and the slice it DID understand was rewritten" \
    || bad "fat: declared 64-bit over a non-Mach-O slice" "slice 0 did not get the append"
"$T/segread" dump "$T/fatdecl64" 1 "$T/fatdecl64_s1"
cmp -s "$T/fatdecl64_s1" "$T/notmacho" \
    && ok "fat: ... and the passed-through slice is byte-identical" \
    || bad "fat: declared 64-bit over a non-Mach-O slice" "the passed-through slice changed"

# The other half of the same rule: a slice that is neither -- declared i386 AND
# not a Mach-O -- is passed through as "32-bit", because that is what it is.
"$T/segread" wrap "$T/fatskip" "$T/segment_fat_slice" "$T/notmacho" 7
if mts "$T/fatskip" 'dylib append /fatskip.dylib' >"$T/fatskip.out" 2>"$T/fatskip.err"; then
    grep -q 'slice i386: 32-bit; passed through unchanged' "$T/fatskip.err" \
        && ok "fat: a 32-bit slice that is not a Mach-O is passed through, and said to be 32-bit" \
        || bad "fat: 32-bit non-Mach-O slice" "succeeded, but not by passing the slice through: $(cat "$T/fatskip.err")"
else
    bad "fat: 32-bit non-Mach-O slice" "a 32-bit slice was not passed through: $(cat "$T/fatskip.err")"
fi

# SHAPE THREE: declared 64-bit over a slice whose bytes are a REAL 32-BIT
# MACH-O -- MH_MAGIC, a well-formed 32-bit header, just not a 64-bit one.
#
# WHY THIS IS NOT SHAPE TWO AGAIN. "Declared 64-bit, bytes are not a 64-bit
# Mach-O" is a direction, not a shape, and it has more members than one: a
# 32-bit Mach-O, a non-Mach-O blob (shape two), a truncated slice, an
# MH_MAGIC_64 header whose load commands do not fit, a zero-length slice. They
# agree in outcome and they do NOT agree in what a wrong implementation gets
# right. An implementation that answers "is this a 64-bit Mach-O?" by looking
# at the DECLARED cputype and then excusing itself for one magic value -- the
# half-revert that is one edit away from me_slice_is_64 -- passes shape two,
# because a blob of 'Z' has no Mach-O magic at all, and fails here. Measured:
# with that half-revert in place this container goes back to a whole-file
# refusal (exit 1, nothing written) while the shape-two assertions above stay
# green. The remaining three members (truncated, bad load commands, size 0) are
# left uncovered on purpose: each is refused by mi_wrap for the SAME reason a
# non-Mach-O is -- it is not a 64-bit Mach-O image -- and no reachable
# implementation of this predicate distinguishes them from shape two while
# distinguishing this one.
#
# Built by hand rather than with `clang -arch i386`, which a modern toolchain
# may no longer support at all -- change_dylib_test.sh's mkslice32.c is the
# same fixture, built the same way, for the same reason.
cat > "$T/mk32.c" <<'EOF'
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <mach-o/loader.h>
int main(int argc, char **argv) {
    uint8_t buf[4096];
    (void)argc;
    memset(buf, 0x5A, sizeof buf);   /* distinctive, so a corrupting bug shows */
    struct mach_header *h = (struct mach_header *)buf;
    h->magic = MH_MAGIC;             /* 0xfeedface: a 32-bit Mach-O, not a blob */
    h->cputype = CPU_TYPE_I386;
    h->cpusubtype = CPU_SUBTYPE_I386_ALL;
    h->filetype = MH_EXECUTE;
    h->ncmds = 0;
    h->sizeofcmds = 0;
    h->flags = 0;
    FILE *f = fopen(argv[1], "wb");
    if (!f) { perror(argv[1]); return 2; }
    fwrite(buf, 1, sizeof buf, f);
    fclose(f);
    return 0;
}
EOF
"$CC" -O2 -o "$T/mk32" "$T/mk32.c"
"$T/mk32" "$T/slice32"
# makefat rather than segread wrap, because this one needs slice 1's
# cpusubtype too: declared arm64 (0x100000c/0), so the pass-through line names
# a DIFFERENT arch from slice 0's and cannot be satisfied by slice 0's label.
"$BIN/makefat" "$T/fat32as64" "$T/segment_fat_slice" 0x1000007 3 12 "$T/slice32" 0x100000c 0 12
if mts "$T/fat32as64" 'dylib append /fat32as64.dylib' >"$T/fat32as64.out" 2>"$T/fat32as64.err"; then
    ok "fat: a slice declared 64-bit whose bytes are a 32-bit Mach-O is passed through, not refused"
else
    bad "fat: declared 64-bit over a 32-bit Mach-O slice" \
        "the whole run was refused on a container whose only unreadable slice must be passed through: $(cat "$T/fat32as64.err")"
fi
grep -q 'slice arm64: not a 64-bit Mach-O; passed through unchanged' "$T/fat32as64.err" \
    && ok "fat: ... and the report names that slice and says why, without calling it 32-bit" \
    || bad "fat: declared 64-bit over a 32-bit Mach-O slice" \
           "no pass-through line naming the arm64 slice: $(cat "$T/fat32as64.err")"
"$BIN/fatcheck" dump "$T/fat32as64" 1 "$T/fat32as64_s1"
cmp -s "$T/fat32as64_s1" "$T/slice32" \
    && ok "fat: ... and the passed-through 32-bit Mach-O is byte-identical in OUT" \
    || bad "fat: declared 64-bit over a 32-bit Mach-O slice" "the passed-through slice changed"
# The premise: exit 0 above is a real rewrite, not a run that did nothing.
"$BIN/fatcheck" dump "$T/fat32as64" 0 "$T/fat32as64_s0"
"$DRYDOCK_MACHO_REWRITE" info "$T/fat32as64_s0" | grep -qF "path=/fat32as64.dylib" \
    && ok "fat: ... and the slice it DID understand was rewritten" \
    || bad "fat: declared 64-bit over a 32-bit Mach-O slice" "slice 0 did not get the append"

# ---- AND THE SAME QUESTION UNDER AN `arch` DIRECTIVE ----------------------
#
# Everything above drives the no-directive path, where me_run_fat decides per
# slice. `arch NAME` runs a SECOND decision over the same predicate -- the loop
# that refuses a named arch the container lacks, or has but cannot edit -- and
# nothing asserted that half at all. Both directions below, because the two
# questions "which ARCH is this slice?" and "are its bytes a 64-bit Mach-O?"
# have different answers here and the code has to keep them apart: the DECLARED
# cputype says which arch a slice is (cpusubtype lives nowhere else), the bytes
# say whether statements may apply to it.
#
# DIRECTION A: `arch i386` naming a slice the fat table declares i386 whose
# bytes are a 64-bit Mach-O. `arch i386` is the RIGHT name for that slice --
# i386 is what the container calls it -- and its bytes are editable, so it is
# edited and the report calls it what the table calls it. A build that took the
# declaration for the answer refuses the whole run instead.
"$BIN/makefat" "$T/fatarch32" "$T/segment_fat_slice" 0x1000007 3 12 "$T/segment_fat_slice" 7 3 12
if mts "$T/fatarch32" 'arch i386' 'dylib append /fatarch32.dylib' \
        >"$T/fatarch32.out" 2>"$T/fatarch32.err"; then
    ok "fat: arch i386 over a slice declared i386 whose bytes are a 64-bit Mach-O edits it"
else
    bad "fat: arch over a declared-32-bit 64-bit slice" \
        "refused a slice the container calls i386 and whose bytes are editable: $(cat "$T/fatarch32.err")"
fi
grep -q '^slice i386:$' "$T/fatarch32.err" \
    && ok "fat: ... and the report labels it by the arch the container declares, i386" \
    || bad "fat: arch over a declared-32-bit 64-bit slice" \
           "no 'slice i386:' heading: $(cat "$T/fatarch32.err")"
"$BIN/fatcheck" dump "$T/fatarch32" 1 "$T/fatarch32_s1"
"$DRYDOCK_MACHO_REWRITE" info "$T/fatarch32_s1" | grep -qF "path=/fatarch32.dylib" \
    && ok "fat: ... and that slice really carries the append" \
    || bad "fat: arch over a declared-32-bit 64-bit slice" "slice 1 did not get the append"
grep -q 'slice x86_64: not selected by arch; passed through unchanged' "$T/fatarch32.err" \
    && ok "fat: ... and the slice arch did not name was passed through, not edited" \
    || bad "fat: arch over a declared-32-bit 64-bit slice" \
           "slice 0 was not passed through as unselected: $(cat "$T/fatarch32.err")"

# DIRECTION B: `arch arm64` naming a slice the table declares arm64 whose bytes
# are not a 64-bit Mach-O. The arch EXISTS, so this is not the "no arm64 slice"
# refusal; it is the one at src/edit.c's arch loop, and its wording is the
# distinction this whole section rests on -- "is not a 64-bit Mach-O" for a
# slice declared 64-bit, never "is 32-bit", which would describe the
# declaration this code deliberately does not trust. Until now that string
# appeared in no test.
"$BIN/makefat" "$T/fatarchnm" "$T/segment_fat_slice" 0x1000007 3 12 "$T/notmacho" 0x100000c 0 12
fatarchnm_before=$(sha "$T/fatarchnm")
if mts "$T/fatarchnm" 'arch arm64' 'dylib append /fatarchnm.dylib' \
        >"$T/fatarchnm.out" 2>"$T/fatarchnm.err"; then
    bad "fat: arch naming a slice that is not a 64-bit Mach-O" \
        "exited 0 -- a named arch whose bytes cannot take statements was silently skipped: $(cat "$T/fatarchnm.err")"
else
    ok "fat: arch arm64 naming a slice whose bytes are not a 64-bit Mach-O is refused"
fi
grep -q "arm64 slice is not a 64-bit Mach-O, and statements apply only to 64-bit slices" \
        "$T/fatarchnm.err" \
    && ok "fat: ... and the refusal names the slice and its real reason, not '32-bit'" \
    || bad "fat: arch naming a slice that is not a 64-bit Mach-O" \
           "not the arch-loop refusal: $(cat "$T/fatarchnm.err")"
[ "$(sha "$T/fatarchnm")" = "$fatarchnm_before" ] \
    && ok "fat: ... and that refusal left the container byte-for-byte unchanged" \
    || bad "fat: arch naming a slice that is not a 64-bit Mach-O" "the refused fat file was modified"

# ============================================================================
# the mutating form never writes its input
# ============================================================================
#
# dylib, rpath, load-command and segment statements all reach mr_apply_image,
# under a driver that reads FILE and writes OUT. The same five facts, per
# statement kind, with no mts helper in the way: the run succeeds, FILE is
# untouched in BYTES and INODE, OUT carries the change, the report names what
# was written, and an OUT that is FILE -- or a symlink to FILE, or missing
# altogether -- is refused with 2 before any work.
#
# nwi runs the four every statement shares; the change OUT is supposed to carry
# is kind-specific, so each kind's own check for that follows. It was
# `nwi VERB ARG...` while the verbs existed; it is `nwi TAG STATEMENT` now, the
# tag naming the fixture and the assertions the way the verb word used to.
nwi() {   # TAG then the one statement to run
    nwi_tag=$1; nwi_stmt=$2
    nwi_in="$T/nwi_$nwi_tag"
    nwi_out="$T/nwi_${nwi_tag}_out"
    build_main "$nwi_in"
    nwi_sha=$(sha "$nwi_in"); nwi_ino=$(stat -f %i "$nwi_in")
    rm -f "$nwi_out"
    printf '%s\n' "$nwi_stmt" | "$DRYDOCK_MACHO_REWRITE" "$nwi_in" "$nwi_out" >"$T/nwi.out" 2>"$T/nwi.err" \
        && ok "$nwi_tag FILE OUT: succeeds" \
        || bad "$nwi_tag FILE OUT" "$(cat "$T/nwi.err")"
    [ "$(sha "$nwi_in")" = "$nwi_sha" ] && [ "$(stat -f %i "$nwi_in")" = "$nwi_ino" ] \
        && ok "$nwi_tag FILE OUT: FILE is untouched, bytes and inode" \
        || bad "$nwi_tag FILE OUT" "FILE changed"
    # The verbs said `Wrote OUT (N bytes)` on stdout; me_run says
    # `OUT: written (N,NNN bytes)` on stderr. Same claim, me_run's stream.
    grep -q "^$nwi_out: written (" "$T/nwi.err" \
        && ok "$nwi_tag FILE OUT: says what it wrote" \
        || bad "$nwi_tag FILE OUT" "no written line: $(cat "$T/nwi.err")"
    rc=0
    printf '%s\n' "$nwi_stmt" | "$DRYDOCK_MACHO_REWRITE" "$nwi_in" "$nwi_in" >/dev/null 2>"$T/nwi_same.err" || rc=$?
    [ "$rc" -eq 2 ] && [ "$(sha "$nwi_in")" = "$nwi_sha" ] \
        && ok "$nwi_tag: OUT that is FILE is refused (2), FILE untouched" \
        || bad "$nwi_tag OUT=FILE" "rc $rc"
    grep -q "never writes its input" "$T/nwi_same.err" \
        && ok "$nwi_tag: ... refused up front, before any work" \
        || bad "$nwi_tag OUT=FILE" "not the up-front refusal: $(cat "$T/nwi_same.err")"
    rm -f "$T/nwi_link"; ln -s "$nwi_in" "$T/nwi_link"
    rc=0
    printf '%s\n' "$nwi_stmt" | "$DRYDOCK_MACHO_REWRITE" "$nwi_in" "$T/nwi_link" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] && ok "$nwi_tag: OUT that is a symlink to FILE is refused (2)" \
        || bad "$nwi_tag OUT=link" "rc $rc"
    rc=0
    printf '%s\n' "$nwi_stmt" | "$DRYDOCK_MACHO_REWRITE" "$nwi_in" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] && ok "$nwi_tag: a missing OUT is an error (2)" \
        || bad "$nwi_tag no OUT" "rc $rc"
}
nwi dylib "dylib append /nwi/appended.dylib"
"$DRYDOCK_MACHO_REWRITE" info "$T/nwi_dylib_out" | grep -qF "path=/nwi/appended.dylib" \
    && ok "dylib FILE OUT: OUT carries the appended dependency" \
    || bad "dylib FILE OUT" "OUT lacks the appended dependency"
nwi rpath "rpath append /nwi/appended/rpath"
"$DRYDOCK_MACHO_REWRITE" info "$T/nwi_rpath_out" | grep -qF "/nwi/appended/rpath" \
    && ok "rpath FILE OUT: OUT carries the appended rpath" \
    || bad "rpath FILE OUT" "OUT lacks the appended rpath"
nwi lc "load-command delete uuid"
"$DRYDOCK_MACHO_REWRITE" info "$T/nwi_lc_out" | grep -q "LC_UUID" \
    && bad "lc FILE OUT" "OUT still has LC_UUID" \
    || ok "lc FILE OUT: OUT has lost its LC_UUID"
nwi segment "segment rename __DATA __DATA_NWI"
"$DRYDOCK_MACHO_REWRITE" info "$T/nwi_segment_out" | grep -q "segname=__DATA_NWI" \
    && ok "segment FILE OUT: OUT carries the renamed segment" \
    || bad "segment FILE OUT" "OUT lacks the renamed segment"

# AN OUT THAT BEGINS WITH '-' IS REFUSED, not created. `dylib FILE
# --some-flag -append /x` was the flag-first habit from before these forms took
# an output, and nothing here treats a positional as a flag -- so without the
# check it creates a regular file called "--some-flag" and exits 0, doing
# something the caller did not ask for. There is one form left that takes an
# OUT, and it gets that answer from bad_out.
#
# stdin is /dev/null below, so a run that got past bad_out would parse an empty
# script and SUCCEED, writing the very file this refuses to create: bad_out
# firing before the script is read is exactly what makes the assertion mean
# something.
#
# ONE DASH, not two: cmd_script rejects a `--`-prefixed token as an unknown
# flag BEFORE bad_out is reached (see its own comment, which states that order
# deliberately), so a double-dash OUT would be asserting about the flag check
# rather than about bad_out -- which the `--output` case in the mutating-form
# section below does instead. `grow`, `edit` and the six other verbs that took
# an OUT were here until those verbs were deleted.
nwid_run() {   # LABEL, the OUT word, then the whole argv after $DRYDOCK_MACHO_REWRITE
    nwid_label=$1; nwid_out=$2; shift 2
    build_main "$T/nwid"
    rm -f -- "$T/$nwid_out"
    rc=0
    # Run IN $T with a bare OUT word, because that is the shape of the mistake:
    # a flag-looking OUT is relative to the caller's directory, and a test that
    # spelled it "$T/-nwid-flag" would be asserting about a path that does not
    # begin with '-' at all. The `cd` is also what keeps the file the check
    # exists to prevent out of the source tree when the check is not there.
    ( cd "$T" && "$DRYDOCK_MACHO_REWRITE" "$@" </dev/null ) >/dev/null 2>"$T/nwid.err" || rc=$?
    [ "$rc" -eq 2 ] && [ ! -e "$T/$nwid_out" ] \
        && grep -q "which begins with '-'" "$T/nwid.err" \
        && ok "$nwid_label: an OUT beginning with '-' is refused (2), not created" \
        || bad "$nwid_label OUT=-flag" "rc $rc, exists=$([ -e "$T/$nwid_out" ] && echo YES || echo no), stderr: $(cat "$T/nwid.err")"
}
nwid_run "bare form" -nwid-flag nwid -nwid-flag
# ... and the remedy the message names really does work, so the refusal is not
# a wall in front of a legal path.
build_main "$T/nwid2"
( cd "$T" && printf 'load-command delete uuid\n' | "$DRYDOCK_MACHO_REWRITE" nwid2 ./-nwid-out ) \
    >/dev/null 2>"$T/nwid2.err" \
    && [ -e "$T/-nwid-out" ] \
    && ok "bare form: ... and './-name', the remedy the message names, writes that file" \
    || bad "bare form OUT=./-name" "$(cat "$T/nwid2.err")"

# A 0 EXIT MUST LEAVE OUT THERE, even when there was nothing to change: OUT is
# the answer, so a caller that got exit 0 and no OUT would have been told the
# work succeeded and handed nothing. Nothing matches here, so without
# allow-unmatched the run would refuse; with it, OUT still has to be
# a byte-for-byte copy of FILE.
build_main "$T/nwi_noop"
rm -f "$T/nwi_noop_out"
printf 'allow-unmatched\ndylib delete /not/linked/at/all.dylib\n' \
    | "$DRYDOCK_MACHO_REWRITE" "$T/nwi_noop" "$T/nwi_noop_out" \
    >"$T/nwi_noop.out" 2>"$T/nwi_noop.err" && nwi_noop_rc=0 || nwi_noop_rc=$?
[ "$nwi_noop_rc" -eq 0 ] \
    && ok "dylib: allow-unmatched with nothing to change still exits 0" \
    || bad "dylib nothing-to-change" "exit $nwi_noop_rc: $(cat "$T/nwi_noop.err")"
cmp -s "$T/nwi_noop" "$T/nwi_noop_out" \
    && ok "dylib: ... and OUT is there, byte-identical to FILE" \
    || bad "dylib nothing-to-change" "OUT is missing or differs from FILE"

# ============================================================================
# retag-swift: the is-Swift tag moves from the stable-ABI bit to the legacy one
# ============================================================================
# The fixture builder is tests/mkswift.c, shared with tests/wrapper_test.sh
# exactly the way tests/strip_version_min.c is -- both suites need a binary
# with real Swift class records to retag, not fixture.macho's usual zero.
"$CC" -O2 -o "$T/mkswift" "$HERE/mkswift.c"
"$T/mkswift" make "$T/swift_fixture"

# ---- info: the Swift stable-ABI tag ---------------------------------------
# info: the swift-abi line, printed in both states.
"$DRYDOCK_MACHO_REWRITE" info "$T/signing_probe" 2>/dev/null | grep -q '^swift-abi: ' \
    && ok "info: a swift-abi line is always printed" \
    || bad "info swift-abi" "no swift-abi line on the plain fixture"

"$DRYDOCK_MACHO_REWRITE" info "$T/signing_probe" 2>/dev/null \
    | grep -qxF 'swift-abi: no class records carry the stable-ABI tag' \
    && ok "info: an untagged image says so" \
    || bad "info swift-abi" "wrong wording: $("$DRYDOCK_MACHO_REWRITE" info "$T/signing_probe" 2>/dev/null | grep '^swift-abi:')"

# No SKIP: mkswift builds this fixture on every host.
"$DRYDOCK_MACHO_REWRITE" info "$T/swift_fixture" 2>/dev/null \
    | grep -qxF 'swift-abi: class records carry the stable-ABI tag' \
    && ok "info: a tagged image says so" \
    || bad "info swift-abi tagged" "wrong wording: $("$DRYDOCK_MACHO_REWRITE" info "$T/swift_fixture" 2>/dev/null | grep '^swift-abi:')"

cp "$T/swift_fixture" "$T/swift_retagged"
mts "$T/swift_retagged" "swift-abi set legacy" >/dev/null 2>&1 \
    || bad "info swift-abi retag" "swift-abi set legacy failed on swift_retagged"
"$DRYDOCK_MACHO_REWRITE" info "$T/swift_retagged" 2>/dev/null \
    | grep -qxF 'swift-abi: no class records carry the stable-ABI tag' \
    && ok "info: the tag is gone after swift-abi set legacy" \
    || bad "info swift-abi after retag" "still reports tagged records"

# ON A CHAINED IMAGE THE CLASS-RECORD POINTERS ARE CHAIN LINKS, which the
# walk cannot follow: info says so, and swift-abi set legacy refuses rather
# than answer "nothing to retag" about records it never read.
"$T/mkchained" make-swift "$T/swift_chained"
[ "$("$T/mkchained" tags "$T/swift_chained")" = "class 2
meta 2" ] || bad "swift-abi chained: fixture setup" \
    "not both on the stable-ABI tag: $("$T/mkchained" tags "$T/swift_chained")"
"$DRYDOCK_MACHO_REWRITE" info "$T/swift_chained" 2>/dev/null \
    | grep -qxF 'swift-abi: unknown (pointers are chained; fixups set classic first)' \
    && ok "info: on a chained image the swift-abi line says unknown, and why" \
    || bad "info swift-abi chained" "got: $("$DRYDOCK_MACHO_REWRITE" info "$T/swift_chained" 2>/dev/null | grep '^swift-abi:')"
"$T/mkchained" make "$T/c_chained"
"$DRYDOCK_MACHO_REWRITE" info "$T/c_chained" 2>/dev/null \
    | grep -qxF 'swift-abi: unknown (pointers are chained; fixups set classic first)' \
    && ok "info: ... on any chained image, Swift or not" \
    || bad "info swift-abi chained" "got: $("$DRYDOCK_MACHO_REWRITE" info "$T/c_chained" 2>/dev/null | grep '^swift-abi:')"
swc_before=$(sha "$T/swift_chained")
rm -f "$T/swift_chained.out"
rc=0; printf 'swift-abi set legacy\n' | "$DRYDOCK_MACHO_REWRITE" "$T/swift_chained" "$T/swift_chained.out" \
    >/dev/null 2>"$T/swc.err" || rc=$?
[ "$rc" -eq 1 ] && [ ! -e "$T/swift_chained.out" ] && [ "$(sha "$T/swift_chained")" = "$swc_before" ] \
    && ok "swift-abi set legacy: a chained image is refused (1), nothing written" \
    || bad "swift-abi chained" "expected 1 and no OUT, got $rc: $(cat "$T/swc.err")"
grep -q 'pointers are chained; write .fixups set classic. before .swift-abi set legacy.' "$T/swc.err" \
    && ok "swift-abi set legacy: ... and the refusal names the fix" \
    || bad "swift-abi chained" "no fix named: $(cat "$T/swc.err")"
rc=0; printf 'fixups set classic\nswift-abi set legacy\n' \
    | "$DRYDOCK_MACHO_REWRITE" "$T/swift_chained" "$T/swift_chained.out" >/dev/null 2>"$T/swc.err" || rc=$?
[ "$rc" -eq 0 ] && grep -qxF "      retagged 2 class records" "$T/swc.err" \
    && [ "$("$T/mkchained" tags "$T/swift_chained.out")" = "class 1
meta 1" ] \
    && ok "swift-abi set legacy: after fixups set classic the same records are retagged" \
    || bad "swift-abi chained, fixups first" "rc $rc: $(cat "$T/swc.err")"

tags_before=$("$T/mkswift" tags "$T/swift_fixture")
[ "$tags_before" = "class 2 0x1000009c2
meta 2 0x1000009c2" ] \
    && ok "retag-swift: fixture starts with both records on the stable-ABI bit" \
    || bad "retag-swift: precondition" "unexpected starting tags: $tags_before"

swift_fixture_before=$(sha "$T/swift_fixture")
printf 'swift-abi set legacy\n' | "$DRYDOCK_MACHO_REWRITE" "$T/swift_fixture" "$T/swift_out1" \
    >"$T/retag.out" 2>&1 \
    || bad "retag-swift: exit" "$(cat "$T/retag.out")"
[ "$(sha "$T/swift_fixture")" = "$swift_fixture_before" ] \
    && ok "retag-swift: FILE is untouched" || bad "retag-swift" "FILE changed"
tags_after=$("$T/mkswift" tags "$T/swift_out1")
[ "$tags_after" = "class 1 0x1000009c1
meta 1 0x1000009c1" ] \
    && ok "retag-swift: moved both tags to the legacy bit, leaving every other bit alone" \
    || bad "retag-swift" "expected both records tagged 1 with 0x...9c1, got: $tags_after"
# Both halves of the pair: the class AND the metaclass its isa points at. The
# count in the message is how we know the metaclass was reached at all.
# cmd_retag_swift printed "retagged N class record(s)"; the statement's own
# report is "retagged N class records", and it is the statement report that
# carries the count now.
grep -q "retagged 2 class records" "$T/retag.out" \
    && ok "retag-swift: reported both the class and its metaclass" \
    || bad "retag-swift: count" "expected 2 records, got: $(cat "$T/retag.out")"

# Idempotent: retagging the already-retagged OUT finds nothing on the stable
# bit, says so, and does not flip anything back. The verb said
# "retagged 0 class record(s)"; the statement says "nothing to retag", which is
# the same claim about the same zero.
swift_out1_before=$(sha "$T/swift_out1")
printf 'swift-abi set legacy\n' | "$DRYDOCK_MACHO_REWRITE" "$T/swift_out1" "$T/swift_out2" \
    >"$T/retag2.out" 2>&1 \
    || bad "retag-swift: second run exit" "$(cat "$T/retag2.out")"
grep -q "nothing to retag" "$T/retag2.out" \
    && ok "retag-swift: a second run retags nothing" \
    || bad "retag-swift: idempotence" "expected 'nothing to retag', got: $(cat "$T/retag2.out")"
[ "$(sha "$T/swift_out1")" = "$swift_out1_before" ] \
    && ok "retag-swift: a run with nothing to do left FILE untouched" \
    || bad "retag-swift: idempotence" "FILE changed on a no-op run"
cmp -s "$T/swift_out1" "$T/swift_out2" \
    && ok "retag-swift: a no-op run's OUT still carries the same bytes" \
    || bad "retag-swift: idempotence" "OUT differs from FILE on a no-op run"

# The statement is fat-capable: me_run_fat rewrites each 64-bit slice it
# understands and passes the rest through, so a container retag_swift_classes
# refused is accepted. The wrappers keep that refusal (mw_thin_only).
#
# The container is built HERE, out of the very fixture the assertions above
# just retagged successfully, rather than borrowed from the `segment` section
# ~150 lines up. Two reasons: a borrowed fixture means deleting or renaming
# that section silently breaks a retag-swift assertion, and wrapping THIS
# fixture makes the pair a control -- the same bytes retag thin and fat, so the
# result is provably about the content, not the container. The one thing still
# shared is the segread helper that assembles it, and that dependency is
# checked rather than assumed.
if [ ! -x "$T/segread" ]; then
    bad "retag-swift: fat" "the segread helper (built in the segment section above) is missing, so the fat assertions could not be built"
else
    printf 'not a mach-o at all, just bytes.\n' > "$T/retag_fat_blob"
    "$T/segread" wrap "$T/retag_fat" "$T/swift_fixture" "$T/retag_fat_blob"
    rc=0
    printf 'swift-abi set legacy\n' | "$DRYDOCK_MACHO_REWRITE" "$T/retag_fat" "$T/retag_fat_out" \
        >"$T/retag_fat.out" 2>"$T/retag_fat.err" || rc=$?
    [ "$rc" -eq 0 ] && ok "retag-swift: a fat container is rewritten, not refused as it was at the verb" \
        || bad "retag-swift: fat" "expected exit 0, got $rc: $(cat "$T/retag_fat.out") $(cat "$T/retag_fat.err")"
    [ -e "$T/retag_fat_out" ] \
        && ok "retag-swift: ... and OUT is written" \
        || bad "retag-swift: fat" "no OUT was written"
    grep -q "retagged 2 class records" "$T/retag_fat.err" \
        && ok "retag-swift: the Swift slice really was retagged inside the container" \
        || bad "retag-swift: fat message" "no retag report on stderr: $(cat "$T/retag_fat.err")"
    grep -q "passed through unchanged" "$T/retag_fat.err" \
        && ok "retag-swift: and the slice it does not understand is passed through, not rewritten" \
        || bad "retag-swift: fat passthrough" "no pass-through report on stderr: $(cat "$T/retag_fat.err")"
    # The control: the same class records, thin, are reachable too. Without this
    # the assertions above would also pass against an implementation that only
    # worked inside a container.
    cp "$T/swift_fixture" "$T/retag_thin_control"
    rc=0
    printf 'swift-abi set legacy\n' | "$DRYDOCK_MACHO_REWRITE" "$T/retag_thin_control" "$T/retag_thin_control_out" \
        >"$T/retag_thin_control.out" 2>&1 || rc=$?
    [ "$rc" -eq 0 ] \
        && ok "retag-swift: the same bytes, thin, are accepted too" \
        || bad "retag-swift: thin control" "expected exit 0, got $rc: $(cat "$T/retag_thin_control.out")"
fi

# A path that cannot even be opened must be EX_FAIL (2) -- a
# genuine operational failure, NOT the EX_REFUSED an unreadable-input case
# gets, and certainly not 0.
rc=0
printf 'swift-abi set legacy\n' | "$DRYDOCK_MACHO_REWRITE" "$T/no-such-file-for-retag" "$T/retag_missing_out" \
    >"$T/retag_missing.out" 2>"$T/retag_missing.err" || rc=$?
[ "$rc" -eq 2 ] \
    && ok "retag-swift: an unopenable path is a failure (2), not a refusal (1) and not silent success" \
    || bad "retag-swift: missing path" "expected exit 2, got $rc: $(cat "$T/retag_missing.out") $(cat "$T/retag_missing.err")"
# An unopenable path must SAY so, on stderr.
[ -s "$T/retag_missing.err" ] \
    && ok "retag-swift: an unopenable path prints something rather than failing silently" \
    || bad "retag-swift: missing path stderr" "exit 2 but stderr was empty"

# retag-swift never writes its input: FILE OUT, and an OUT that is FILE is
# refused. Any 64-bit Mach-O fixture does, whether or not it carries a Swift
# class to retag -- OUT is written either way.
build_main "$T/rs_in"
rs_before=$(sha "$T/rs_in"); rs_ino=$(stat -f %i "$T/rs_in")
printf 'swift-abi set legacy\n' | "$DRYDOCK_MACHO_REWRITE" "$T/rs_in" "$T/rs_out" >"$T/rs.out" 2>"$T/rs.err" \
    && ok "retag-swift FILE OUT: succeeds" || bad "retag-swift FILE OUT" "$(cat "$T/rs.err")"
[ "$(sha "$T/rs_in")" = "$rs_before" ] && [ "$(stat -f %i "$T/rs_in")" = "$rs_ino" ] \
    && ok "retag-swift FILE OUT: FILE is untouched" || bad "retag-swift FILE OUT" "FILE changed"
[ -e "$T/rs_out" ] \
    && ok "retag-swift FILE OUT: OUT was written" || bad "retag-swift FILE OUT" "OUT is missing"
grep -q "^$T/rs_out: written (" "$T/rs.err" \
    && ok "retag-swift FILE OUT: says what it wrote" || bad "retag-swift FILE OUT" "no written line: $(cat "$T/rs.err")"
rc=0; printf 'swift-abi set legacy\n' | "$DRYDOCK_MACHO_REWRITE" "$T/rs_in" "$T/rs_in" >/dev/null 2>"$T/rs_same.err" || rc=$?
[ "$rc" -eq 2 ] && [ "$(sha "$T/rs_in")" = "$rs_before" ] \
    && ok "retag-swift: OUT that is FILE is refused (2), FILE untouched" || bad "retag-swift OUT=FILE" "rc $rc"
grep -q "never writes its input" "$T/rs_same.err" \
    && ok "retag-swift: ... refused up front, before any work" \
    || bad "retag-swift OUT=FILE" "not the up-front refusal: $(cat "$T/rs_same.err")"
rc=0; printf 'swift-abi set legacy\n' | "$DRYDOCK_MACHO_REWRITE" "$T/rs_in" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok "retag-swift: a missing OUT is a usage error (2)" || bad "retag-swift no OUT" "rc $rc"

# mi_open's MI_IO_ERROR branch, through verify and declassify on an absent path.
rc=0
"$DRYDOCK_MACHO_REWRITE" verify "$T/no-such-file-for-verify" >"$T/verify_missing.out" 2>"$T/verify_missing.err" || rc=$?
[ "$rc" -eq 2 ] && [ -s "$T/verify_missing.err" ] \
    && ok "verify: an absent file is a failure (2), not a refusal, and says something" \
    || bad "verify: missing path" "expected exit 2 with nonempty stderr, got $rc: $(cat "$T/verify_missing.err")"

rc=0
dcl "$T/no-such-file-for-declassify" "$T/declassify_missing.out" \
    >/dev/null 2>"$T/declassify_missing.err" || rc=$?
[ "$rc" -eq 2 ] && [ -s "$T/declassify_missing.err" ] \
    && ok "declassify: an absent IN is a failure (2), not a refusal, and says something" \
    || bad "declassify: missing IN" "expected exit 2 with nonempty stderr, got $rc: $(cat "$T/declassify_missing.err")"
[ -e "$T/declassify_missing.out" ] \
    && bad "declassify: missing IN" "wrote an output file for an IN it could not even open" \
    || ok "declassify: an absent IN produces no output file"

# ============================================================================
# the mutating form: parses the script on stdin and applies it through me_run
# in one pass -- the shapes the grammar has, plus the property the whole design
# exists for (a parse error costs nothing: the file is never opened for
# writing).
#
# THERE IS NO `edit` VERB. `drydock-macho-rewrite edit FILE OUT SCRIPT` was a second
# mutating spelling of this one: `edit` stopped being a verb name and became
# the tool itself. A script that lives in a file is
# `drydock-macho-rewrite FILE OUT < script`, which is the shell's job. Every case below
# that used to be typed with the verb word is typed with the redirection now;
# the ones that only asserted about the verb's own argument scanner (a SCRIPT
# positional, a SCRIPT path that cannot be read, three positionals versus four)
# went with it, and `edit` is asserted absent beside the other eight above.
# ============================================================================

# the production case -- what install.sh does with three tools and
# three full writes of a 208MB binary, in one write. build_main's fixture
# records the install name literally as "@loader_path/liba.dylib"
# (see build_main above), not a path under $T, so the script names that
# install name directly rather than substituting one in -- the same 23
# bytes both before and after, so the replacement fits without growth.
build_main "$T/edit_fixture"
cat >"$T/prod.edits" <<'EOF'
# a comment, and a blank line follow

load-command  delete   uuid
dylib         replace  @loader_path/liba.dylib  @loader_path/../S.dylib
EOF
edit_fixture_before=$(sha "$T/edit_fixture"); edit_fixture_ino=$(stat -f %i "$T/edit_fixture")
rm -f "$T/edit_fixture_out"
"$DRYDOCK_MACHO_REWRITE" "$T/edit_fixture" "$T/edit_fixture_out" <"$T/prod.edits" \
    >"$T/edit.out" 2>"$T/edit.err" && edit_rc=0 || edit_rc=$?
[ "$edit_rc" -eq 0 ] && ok "edit: the production script succeeds" \
    || bad "edit" "expected 0, got $edit_rc: $(cat "$T/edit.err")"
[ "$(sha "$T/edit_fixture")" = "$edit_fixture_before" ] \
    && [ "$(stat -f %i "$T/edit_fixture")" = "$edit_fixture_ino" ] \
    && ok "edit FILE OUT: FILE is untouched, bytes and inode" \
    || bad "edit FILE OUT" "FILE changed"
otool -l "$T/edit_fixture_out" 2>/dev/null | grep -q LC_UUID \
    && bad "edit" "LC_UUID survived the edit script" \
    || ok "edit: applied the load-command delete"
otool -L "$T/edit_fixture_out" 2>/dev/null | grep -q "@loader_path/../S.dylib" \
    && ok "edit: applied the dylib replace" \
    || bad "edit" "the dylib replace did not land: $(otool -L "$T/edit_fixture_out")"

# AN OUT THAT IS FILE IS REFUSED BEFORE THE SCRIPT IS EVEN READ -- bad_out,
# before stdin is touched. stdin here is /dev/null, so a run that got as far as
# reading it would parse an empty script and succeed: the answer must be the
# refusal about OUT.
rc=0
"$DRYDOCK_MACHO_REWRITE" "$T/edit_fixture" "$T/edit_fixture" </dev/null \
    >/dev/null 2>"$T/edit_same.err" || rc=$?
[ "$rc" -eq 2 ] && [ "$(sha "$T/edit_fixture")" = "$edit_fixture_before" ] \
    && ok "edit: OUT that is FILE is refused (2), FILE untouched" \
    || bad "edit OUT=FILE" "rc $rc"
grep -q "never writes its input" "$T/edit_same.err" \
    && ok "edit: ... refused up front, before the script is read" \
    || bad "edit OUT=FILE" "not the up-front refusal: $(cat "$T/edit_same.err")"
rm -f "$T/edit_link"; ln -s "$T/edit_fixture" "$T/edit_link"
rc=0
"$DRYDOCK_MACHO_REWRITE" "$T/edit_fixture" "$T/edit_link" <"$T/prod.edits" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok "edit: OUT that is a symlink to FILE is refused (2)" \
    || bad "edit OUT=link" "rc $rc"

# --dry-run, --output AND --verbose ARE GONE, all unknown flags now (2) --
# refused BY NAME rather than opened as a file, which is what the '--' check in
# cmd_script is for. A scratch OUT is the same run, so there is nothing
# --dry-run said that this does not. Both positions, because either one is a
# place the old habit could put a flag.
rc=0
"$DRYDOCK_MACHO_REWRITE" --dry-run "$T/edit_dry_out" </dev/null \
    >/dev/null 2>"$T/edit_dry.err" || rc=$?
[ "$rc" -eq 2 ] && [ ! -e "$T/edit_dry_out" ] \
    && grep -q "unknown flag '--dry-run'" "$T/edit_dry.err" \
    && ok "edit: --dry-run in FILE's place is an unknown flag (2), and writes no OUT" \
    || bad "edit --dry-run gone" "expected 2 and no OUT, got $rc: $(cat "$T/edit_dry.err")"
rc=0
"$DRYDOCK_MACHO_REWRITE" "$T/edit_fixture" --output </dev/null \
    >/dev/null 2>"$T/edit_output.err" || rc=$?
[ "$rc" -eq 2 ] && [ ! -e "$T/edit_fixture--output" ] \
    && grep -q "unknown flag '--output'" "$T/edit_output.err" \
    && ok "edit: --output in OUT's place is an unknown flag (2), and nothing is written" \
    || bad "edit --output gone" "expected 2, got $rc: $(cat "$T/edit_output.err")"

# A 0 EXIT LEAVES OUT THERE, even when no statement changed anything: OUT is
# the answer, so exit 0 with no OUT would hand a caller nothing.
# allow-unmatched, or this miss would refuse.
build_main "$T/edit_noop"
printf 'allow-unmatched\ndylib delete /not/linked/at/all.dylib\n' >"$T/noop.edits"
rm -f "$T/edit_noop_out"
"$DRYDOCK_MACHO_REWRITE" "$T/edit_noop" "$T/edit_noop_out" <"$T/noop.edits" \
    >/dev/null 2>"$T/edit_noop.err" && edit_noop_rc=0 || edit_noop_rc=$?
[ "$edit_noop_rc" -eq 0 ] && ok "edit: allow-unmatched over a script that changed nothing still exits 0" \
    || bad "edit nothing-to-change" "exit $edit_noop_rc: $(cat "$T/edit_noop.err")"
cmp -s "$T/edit_noop" "$T/edit_noop_out" \
    && ok "edit: ... and OUT is there, byte-identical to FILE" \
    || bad "edit nothing-to-change" "OUT is missing or differs from FILE"

# A REFUSED RUN WRITES NOTHING AT ALL: not FILE, which `edit` never writes,
# and not OUT, which may never have existed. An operation that matches
# nothing is refused by default -- the cheapest way to reach a refusal after
# the image has already been read.
build_main "$T/edit_ref"
ref_before=$(sha "$T/edit_ref")
printf 'dylib delete /definitely/not/linked.dylib\n' >"$T/ref.edits"
rm -f "$T/edit_ref_out"
"$DRYDOCK_MACHO_REWRITE" "$T/edit_ref" "$T/edit_ref_out" <"$T/ref.edits" \
    >/dev/null 2>"$T/edit_ref.err" && ref_rc=0 || ref_rc=$?
[ "$ref_rc" -eq 1 ] \
    && ok "edit: an unmatched operation is refused by default (1)" \
    || bad "edit refusal" "expected 1, got $ref_rc: $(cat "$T/edit_ref.err")"
[ "$(sha "$T/edit_ref")" = "$ref_before" ] && [ ! -e "$T/edit_ref_out" ] \
    && ok "edit: ... and the refused run left FILE unchanged and wrote no OUT" \
    || bad "edit refusal" "the refused run modified FILE, or created OUT"
grep -qF "$T/edit_ref_out not written; $T/edit_ref left unmodified" "$T/edit_ref.err" \
    && ok "edit: ... and the refusal says OUT was not written and FILE is unmodified" \
    || bad "edit refusal" "not that wording: $(cat "$T/edit_ref.err")"

# ---- edit refusal inventory ------------------------------------------------
#
# Which refusals name both files is a property worth pinning rather than
# describing: the prose version of this was wrong twice, first as an absolute
# and then as a narrower claim that still missed two sites. A refusal that has
# read the image says what became of OUT and of PATH; one that never got that
# far says only what it can.
#
# Not exercised here, and not reachable from a deterministic shell test: the
# fat path's own two "cannot open or read" sites (me_run_fat's open() and its
# read()) fire only on a TOCTOU race between me_magic's open of PATH and
# me_run_fat's separate one, and "out of memory reading %s's arch table" needs
# OOM injection. All three say only what they can, same as the sites below --
# this block just cannot force them to fire.
ri_both() {   # $1 = label, $2 = stderr file -- must name both files
    if grep -q 'not written;' "$2" && grep -q 'left unmodified' "$2"; then
        ok "refusal inventory: $1 names both files"
    else
        bad "refusal inventory: $1" \
            "a refusal that read the image must say what became of BOTH files -- a user who sees only 'OUT not written' cannot tell whether their input survived. Got: $(cat "$2")"
    fi
}
ri_neither() {  # $1 = label, $2 = stderr file -- must NOT claim anything of PATH
    if grep -q 'left unmodified' "$2"; then
        bad "refusal inventory: $1" \
            "this refusal fires before PATH was ever read -- claiming PATH is 'left unmodified' is a claim the tool never checked and cannot support. Got: $(cat "$2")"
    else
        ok "refusal inventory: $1 says only what it can"
    fi
}

build_main "$T/ri_in"
printf 'load-command delete uuid\n' >"$T/ri.edits"

# The one pre-read refusal the CLI can actually produce. (The other --
# me_run's NULL-`out` guard, "no output file was named" -- is unreachable from
# here: cmd_edit rejects two positionals with a usage message first, so that
# guard is tests/edit_test.c's to cover, and is already covered there.)
"$DRYDOCK_MACHO_REWRITE" "$T/ri_in" "$T/ri_in" <"$T/ri.edits" >/dev/null 2>"$T/ri2.err" || :
ri_neither "OUT is PATH" "$T/ri2.err"

# The ones where PATH's bytes never resolved into an image this tool parses.
"$DRYDOCK_MACHO_REWRITE" "$T/nosuchfile" "$T/ri.out" <"$T/ri.edits" >/dev/null 2>"$T/ri3.err" || :
ri_neither "cannot open or read" "$T/ri3.err"
printf 'not a mach-o at all, not even close\n' >"$T/ri_text"
"$DRYDOCK_MACHO_REWRITE" "$T/ri_text" "$T/ri.out" <"$T/ri.edits" >/dev/null 2>"$T/ri4.err" || :
ri_neither "not a readable 64-bit Mach-O" "$T/ri4.err"

# Everything that got as far as an image names both. A fat64 container is
# refused by its magic before mi_open, and still names both -- four bytes of
# FAT_MAGIC_64 is the whole fixture, as the "64-bit fat container" block
# further up this file already does it.
printf '%b' '\0277\0272\0376\0312' > "$T/ri_fat64"
rm -f "$T/ri.out"
"$DRYDOCK_MACHO_REWRITE" "$T/ri_fat64" "$T/ri.out" <"$T/ri.edits" >/dev/null 2>"$T/ri5.err" || :
ri_both "fat_arch_64 container" "$T/ri5.err"

# A statement's own refusal.
printf 'load-command delete uuid\n' >"$T/ri_fw.edits"
printf 'load-command delete uuid\n' | "$DRYDOCK_MACHO_REWRITE" "$T/ri_in" "$T/ri_nouuid" >/dev/null 2>&1
rm -f "$T/ri.out"
"$DRYDOCK_MACHO_REWRITE" "$T/ri_nouuid" "$T/ri.out" <"$T/ri_fw.edits" >/dev/null 2>"$T/ri6.err" || :
ri_both "a statement that matched nothing, refused by default" "$T/ri6.err"
[ ! -e "$T/ri.out" ] \
    && ok "refusal inventory: and every one of them wrote no OUT" \
    || bad "refusal inventory" "OUT exists after a refusal"

# An arch directive naming a slice a thin file does not have: FIXTURE_FLAGS
# pins x86_64 on every host, so the fixture never has an arm64 slice.
printf 'arch arm64\nload-command delete uuid\n' >"$T/ri_arch.edits"
rm -f "$T/ri.out"
"$DRYDOCK_MACHO_REWRITE" "$T/ri_in" "$T/ri.out" <"$T/ri_arch.edits" >/dev/null 2>"$T/ri7.err" || :
ri_both "an arch directive the file cannot satisfy" "$T/ri7.err"

# ---- the bare form: FILE OUT, statements on stdin ---------------------------
#
# A PIPE, not a redirection, so this is not the same shape as every other case
# in this file: a generated script needs no temp file, and a pipe is not
# seekable. `drydock-macho-rewrite edit FILE OUT -` was the other way to say this until
# the verb went; there is no second spelling left to compare against, so what is
# asserted is the thing itself.
build_main "$T/bare_in"
printf 'load-command delete uuid\n' >"$T/bare.edits"
rm -f "$T/bare_via_bare"
bare_vb=0
printf 'load-command delete uuid\n' | "$DRYDOCK_MACHO_REWRITE" "$T/bare_in" "$T/bare_via_bare" \
    >/dev/null 2>"$T/bare_vb.err" || bare_vb=$?
[ "$bare_vb" -eq 0 ] && ok "bare form: FILE OUT with the statements piped in succeeds" \
    || bad "bare form" "exited $bare_vb: $(cat "$T/bare_vb.err")"
# ... and the work happened. A run that IGNORED stdin would also exit 0 and
# leave a faithful copy of FILE; this is the assertion that the statements
# piped in were actually read and applied.
otool -l "$T/bare_via_bare" 2>/dev/null | grep -q LC_UUID \
    && bad "bare form" "the statements piped in were not applied -- OUT still has the LC_UUID the script deletes, so a caller got an unchanged copy of FILE and an exit 0 saying it worked" \
    || ok "bare form: the statements on stdin are read and applied"

# A script that will not parse costs nothing: nonzero, no OUT, and the
# diagnostic names stdin as where it came from.
printf 'frobnicate everything\n' >"$T/bare_bad.edits"
rm -f "$T/bare_bad_b"
bare_fb=0
"$DRYDOCK_MACHO_REWRITE" "$T/bare_in" "$T/bare_bad_b" <"$T/bare_bad.edits" \
    >/dev/null 2>"$T/bare_fb.err" || bare_fb=$?
[ "$bare_fb" -ne 0 ] && grep -q "drydock-macho-rewrite edit: stdin:" "$T/bare_fb.err" \
    && ok "bare form: a script that will not parse fails, naming stdin" \
    || bad "bare form parse error" "exited $bare_fb and said '$(cat "$T/bare_fb.err")'"
[ ! -e "$T/bare_bad_b" ] \
    && ok "bare form: ... and the refused run wrote no OUT" \
    || bad "bare form parse error" "an OUT appeared despite a script that never parsed"

# A VERB ALWAYS WINS over a file of the same name. The bare form is reached
# only after every verb arm has declined, so `drydock-macho-rewrite info f` stays the info
# query even with a file named `info` sitting in the working directory. A FILE
# really named like a verb is spelled `./info` -- the same remedy bad_out
# already names for an OUT beginning with '-'.
#
# TWO NAMES ARE SHADOWED NOW, not eleven. `minos`, `segment`, `retag-swift`,
# `lc`, `dylib`, `rpath`, `declassify`, `grow` and `edit` were verbs and
# shadowed a file of the same name; they are ordinary words again, so
# `drydock-macho-rewrite dylib out` reads a file called `dylib`. Nothing is lost --
# there is no verb behind those names for a caller to be denied -- and what
# this loop guards is the two that ARE still verbs.
mkdir -p "$T/shadow"
build_main "$T/shadow/fixture"
bare_shadowed=""
for bare_v in verify info; do
    rm -f "$T/shadow/$bare_v" "$T/shadow/shadow_out"
    cp "$T/shadow/fixture" "$T/shadow/$bare_v"
    ( cd "$T/shadow" \
        && printf 'load-command delete uuid\n' | "$DRYDOCK_MACHO_REWRITE" "$bare_v" shadow_out ) \
        >/dev/null 2>&1 || :
    [ -e "$T/shadow/shadow_out" ] && bare_shadowed="$bare_shadowed $bare_v"
    rm -f "$T/shadow/$bare_v"
done
[ -z "$bare_shadowed" ] \
    && ok "bare form: no verb is shadowed by a file of the same name" \
    || bad "bare form shadows a verb" "a caller who typed$bare_shadowed got an edit of a like-named file in the working directory instead of the verb they asked for"
# ... and the remedy the comment above names really does work, so a file named
# like a verb is reachable rather than unusable.
rm -f "$T/shadow/info" "$T/shadow/remedy_out"
cp "$T/shadow/fixture" "$T/shadow/info"
bare_remedy=0
( cd "$T/shadow" \
    && printf 'load-command delete uuid\n' | "$DRYDOCK_MACHO_REWRITE" ./info remedy_out ) \
    >/dev/null 2>"$T/bare_remedy.err" || bare_remedy=$?
[ "$bare_remedy" -eq 0 ] && [ -e "$T/shadow/remedy_out" ] \
    && ok "bare form: ... and './info' edits the file that is named like a verb" \
    || bad "bare form ./NAME" "a file named like a verb cannot be edited at all: exit $bare_remedy, $(cat "$T/bare_remedy.err")"

# THE BARE FORM IS EXACTLY TWO WORDS. A third is still the unknown-verb
# answer, so a caller who typed one more word hears about it instead of having
# it silently dropped.
rm -f "$T/bare_extra_out"
bare_extra=0
"$DRYDOCK_MACHO_REWRITE" "$T/bare_in" "$T/bare_extra_out" extra </dev/null \
    >/dev/null 2>"$T/bare_extra.err" || bare_extra=$?
[ "$bare_extra" -eq 2 ] && [ ! -e "$T/bare_extra_out" ] \
    && ok "bare form: FILE OUT EXTRA is still a usage error (2), and writes no OUT" \
    || bad "bare form extra word" "expected 2 and no OUT, got $bare_extra: $(cat "$T/bare_extra.err")"

# A parse error is reported BEFORE anything is written, and names the line.
# This is what makes a typo in statement 9 of 9 cost nothing.
build_main "$T/edit_bad"
bad_before=$(sha "$T/edit_bad")
printf 'load-command delete uuid\nfrobnicate everything\n' \
    >"$T/bad.edits"
rm -f "$T/edit_bad_out"
"$DRYDOCK_MACHO_REWRITE" "$T/edit_bad" "$T/edit_bad_out" <"$T/bad.edits" \
    >/dev/null 2>"$T/editbad.err" && editbad_rc=0 || editbad_rc=$?
[ "$editbad_rc" -eq 2 ] && ok "edit: a parse error is an error (2), not a refusal" \
    || bad "edit parse error" "expected 2, got $editbad_rc"
grep -q "line 2" "$T/editbad.err" && ok "edit: names the offending line" \
    || bad "edit parse error" "no line number: $(cat "$T/editbad.err")"
[ "$(sha "$T/edit_bad")" = "$bad_before" ] && [ ! -e "$T/edit_bad_out" ] \
    && ok "edit: a parse error left FILE untouched and wrote no OUT" \
    || bad "edit parse error" "the file was modified, or an OUT appeared, despite a parse error"
# `drydock-macho-rewrite edit: `: every one of src/edit.c's me_say format strings names
# the tool, as every other verb's diagnostics do.
grep -q "^drydock-macho-rewrite edit: " "$T/editbad.err" \
    && ok "edit: parse error is prefixed like every other verb's diagnostics" \
    || bad "edit parse error" "no 'drydock-macho-rewrite edit: ' prefix: $(cat "$T/editbad.err")"

# Too few positionals is EX_FAIL (2) -- never a crash, never silently
# accepted. There is no verb word to get wrong any more, so anything that is
# not exactly two positionals falls off the end of main's dispatch and is
# reported as an unknown verb. (Too MANY is asserted above, with the rest of
# the bare form's shape.)
build_main "$T/edit_usage"
rc=0
"$DRYDOCK_MACHO_REWRITE" "$T/edit_usage" </dev/null >/dev/null 2>"$T/edit_usage2.err" || rc=$?
[ "$rc" -eq 2 ] && ok "edit: one positional is a usage error (2)" \
    || bad "edit usage" "one positional: expected 2, got $rc"
# A FILE WHOSE NAME STARTS WITH A DASH IS A FILE NAME. Only a double dash is
# refused here: the historical tools open()ed whatever argv[1] was, so a
# single-dash token in FILE's place is a path, not a typo'd flag. The compat
# wrappers reach this, and tests/wrapper_test.sh pins `change_dylib -dashy ...`
# for that reason. OUT is the one positional that refuses a leading dash
# (above), because a mistaken OUT is a file this tool CREATES.
build_main "$T/-edit_dashy"
rc=0
(cd "$T" && "$DRYDOCK_MACHO_REWRITE" -edit_dashy "$T/edit_dashy_out" <"$T/prod.edits") \
    >/dev/null 2>"$T/edit_dash.err" || rc=$?
[ "$rc" -eq 0 ] \
    && ok "edit: a FILE whose name starts with a dash is a file name, not a flag" \
    || bad "edit dash FILE" "expected 0, got $rc: $(head -1 "$T/edit_dash.err")"

# The report must carry the FOLLOW-UP work, not just the statement. A dylib
# delete renumbers every surviving ordinal in the nlist entries AND in the
# SET_DYLIB_ORDINAL* opcodes; PROPOSAL defect #2 was exactly that work not
# happening, and it surfaced as "dyld: library ordinal (4) too big" at
# runtime rather than as anything the tool said. So the log is the only
# place a user can see it.
build_main_two_dylibs "$T/edit_verb"
printf 'dylib delete %s\n' "$T/libb.dylib" >"$T/verb.edits"
"$DRYDOCK_MACHO_REWRITE" "$T/edit_verb" "$T/edit_verb_out" <"$T/verb.edits" \
    >/dev/null 2>"$T/verb.err" || bad "edit report" "$(cat "$T/verb.err")"
grep -q "dylib delete" "$T/verb.err" \
    && ok "edit: names the statement" \
    || bad "edit report" "no statement line: $(cat "$T/verb.err")"
grep -q "renumbered" "$T/verb.err" \
    && ok "edit: reports the ordinal renumbering it did unasked" \
    || bad "edit report" "no renumbering report: $(cat "$T/verb.err")"
grep -q "nlist" "$T/verb.err" \
    && ok "edit: counts the nlist entries it touched" \
    || bad "edit report" "no nlist count: $(cat "$T/verb.err")"
grep -q "SET_DYLIB_ORDINAL" "$T/verb.err" \
    && ok "edit: counts the opcodes it rewrote" \
    || bad "edit report" "no opcode count: $(cat "$T/verb.err")"

# What was removed and where every survivor went, which build_main_two_dylibs
# fixed (and checked): libb was 1, liba 2, libSystem 3.
grep -qF "      removed LC_LOAD_DYLIB (was ordinal 1)" "$T/verb.err" \
    && ok "edit: names the removed command and its ordinal" \
    || bad "edit report" "no 'removed LC_LOAD_DYLIB (was ordinal 1)': $(cat "$T/verb.err")"
grep -qF "      renumbered 2 surviving ordinals: 2->1, 3->2" "$T/verb.err" \
    && ok "edit: lists the renumbering map" \
    || bad "edit report" "no '2->1, 3->2' map: $(cat "$T/verb.err")"

# The counts, as numbers. A "nlist" line saying 0 would satisfy the greps
# above, so these read the figures back: liba's a_sym and libSystem's
# dyld_stub_binder are both undefined symbols whose ordinal moved, and each
# is bound through a SET_DYLIB_ORDINAL opcode. So neither figure can be 0.
vb_nlist() { sed -n 's/^          \([0-9][0-9]*\) nlist entr[a-z]* updated$/\1/p' "$1"; }
vb_ops() { sed -n 's/^          \([0-9][0-9]*\) SET_DYLIB_ORDINAL opcodes\{0,1\} updated.*/\1/p' "$1"; }
nl2=$(vb_nlist "$T/verb.err"); op2=$(vb_ops "$T/verb.err")
[ -n "$nl2" ] && [ "$nl2" -gt 0 ] \
    && ok "edit: a delete that moved bound ordinals counts nlist entries > 0 ($nl2)" \
    || bad "edit report" "nlist count '$nl2' should be > 0: $(cat "$T/verb.err")"
[ -n "$op2" ] && [ "$op2" -gt 0 ] \
    && ok "edit: ... and SET_DYLIB_ORDINAL opcodes > 0 ($op2)" \
    || bad "edit report" "opcode count '$op2' should be > 0: $(cat "$T/verb.err")"

# A count that does not move when the input does is not a count. The same
# delete on a fixture with one more bound dylib after libb (libc3, whose
# c_sym main also calls) renumbers one more ordinal, one more undefined
# symbol, and one more ordinal opcode.
build_main_three_dylibs "$T/edit_verb3"
"$DRYDOCK_MACHO_REWRITE" "$T/edit_verb3" "$T/edit_verb3_out" <"$T/verb.edits" \
    >/dev/null 2>"$T/verb3.err" || bad "edit report (3 dylibs)" "$(cat "$T/verb3.err")"
grep -qF "      renumbered 3 surviving ordinals: 2->1, 3->2, 4->3" "$T/verb3.err" \
    && ok "edit: a third dylib adds its ordinal to the map" \
    || bad "edit report (3 dylibs)" "no '2->1, 3->2, 4->3' map: $(cat "$T/verb3.err")"
nl3=$(vb_nlist "$T/verb3.err"); op3=$(vb_ops "$T/verb3.err")
[ -n "$nl3" ] && [ "$nl3" -gt "${nl2:-0}" ] \
    && ok "edit: the nlist count follows the input ($nl2 -> $nl3)" \
    || bad "edit report (3 dylibs)" "nlist count '$nl3' not above '$nl2': $(cat "$T/verb3.err")"
[ -n "$op3" ] && [ "$op3" -gt "${op2:-0}" ] \
    && ok "edit: the opcode count follows the input ($op2 -> $op3)" \
    || bad "edit report (3 dylibs)" "opcode count '$op3' not above '$op2': $(cat "$T/verb3.err")"

# dylib insert carries the same follow-up: the new command takes ordinal 1
# and every existing one moves up (build_main: liba=1, libSystem=2). A short
# path, so the new 48-byte command fits even the 56-byte header pad the
# modern cross runner's linker leaves (see the rpath -insert fixture above).
build_main "$T/edit_verb_ins"
printf 'dylib insert @loader_path/libn.dylib\n' >"$T/verb_ins.edits"
"$DRYDOCK_MACHO_REWRITE" "$T/edit_verb_ins" "$T/edit_verb_ins_out" <"$T/verb_ins.edits" \
    >/dev/null 2>"$T/verb_ins.err" || bad "edit report (insert)" "$(cat "$T/verb_ins.err")"
grep -qF "      inserted LC_LOAD_DYLIB as ordinal 1" "$T/verb_ins.err" \
    && ok "edit: names the inserted command and its ordinal" \
    || bad "edit report (insert)" "no 'inserted ... as ordinal 1': $(cat "$T/verb_ins.err")"
grep -qF "      renumbered 2 existing ordinals: 1->2, 2->3" "$T/verb_ins.err" \
    && ok "edit: an insert reports the ordinals it pushed up" \
    || bad "edit report (insert)" "no '1->2, 2->3' map: $(cat "$T/verb_ins.err")"
nli=$(vb_nlist "$T/verb_ins.err"); opi=$(vb_ops "$T/verb_ins.err")
[ -n "$nli" ] && [ "$nli" -gt 0 ] && [ -n "$opi" ] && [ "$opi" -gt 0 ] \
    && ok "edit: an insert counts the nlist entries and opcodes it moved ($nli, $opi)" \
    || bad "edit report (insert)" "counts '$nli'/'$opi' should be > 0: $(cat "$T/verb_ins.err")"

# A replace keeps its command's position and ordinal, so it carries no
# follow-up and must not claim one.
build_main "$T/edit_verb_rep"
printf 'dylib replace @loader_path/liba.dylib @loader_path/libz.dylib\n' >"$T/verb_rep.edits"
"$DRYDOCK_MACHO_REWRITE" "$T/edit_verb_rep" "$T/edit_verb_rep_out" <"$T/verb_rep.edits" \
    >/dev/null 2>"$T/verb_rep.err" || bad "edit report (replace)" "$(cat "$T/verb_rep.err")"
grep -q "renumbered" "$T/verb_rep.err" \
    && bad "edit report (replace)" "a replace reported a renumbering: $(cat "$T/verb_rep.err")" \
    || ok "edit: a replace reports no renumbering"

# fixups set classic rebuilds __LINKEDIT's opcode streams wholesale. On an
# image that is already classic (build_main's, linked for 10.9) it passes
# through, and says so rather than staying silent.
build_main "$T/edit_verb_fx"
printf 'fixups set classic\n' >"$T/verb_fx.edits"
"$DRYDOCK_MACHO_REWRITE" "$T/edit_verb_fx" "$T/edit_verb_fx_out" <"$T/verb_fx.edits" \
    >/dev/null 2>"$T/verb_fx.err" || bad "edit report (fixups)" "$(cat "$T/verb_fx.err")"
grep -qF "      already classic (LC_DYLD_INFO_ONLY, no chained fixups): passed through unchanged" \
    "$T/verb_fx.err" \
    && ok "edit: fixups on a classic image reports the pass-through" \
    || bad "edit report (fixups)" "no pass-through report: $(cat "$T/verb_fx.err")"
# ... and on mkchained's hand-built chained-fixups image (declassify's
# fixture, above: one rebase, one bind, and LC_DYLD_CHAINED_FIXUPS,
# LC_DYLD_EXPORTS_TRIE and LC_BUILD_VERSION to strip) it converts, and the
# report carries the conversion's own figures.
"$T/mkchained" make "$T/edit_verb_chained"
"$DRYDOCK_MACHO_REWRITE" "$T/edit_verb_chained" "$T/edit_verb_chained_out" <"$T/verb_fx.edits" \
    >/dev/null 2>"$T/verb_cf.err" || bad "edit report (chained)" "$(cat "$T/verb_cf.err")"
grep -qF "      chained fixups -> LC_DYLD_INFO_ONLY" "$T/verb_cf.err" \
    && ok "edit: fixups on a chained image reports the conversion" \
    || bad "edit report (chained)" "no conversion line: $(cat "$T/verb_cf.err")"
grep -qF "      1 rebase and 1 bind emitted" "$T/verb_cf.err" \
    && ok "edit: reports the rebases and binds the conversion emitted" \
    || bad "edit report (chained)" "no '1 rebase and 1 bind': $(cat "$T/verb_cf.err")"
grep -qF "      stripped LC_DYLD_CHAINED_FIXUPS, LC_DYLD_EXPORTS_TRIE, LC_BUILD_VERSION" \
    "$T/verb_cf.err" \
    && ok "edit: names the commands the conversion stripped, in load order" \
    || bad "edit report (chained)" "no stripped list: $(cat "$T/verb_cf.err")"
grep -q "^      __LINKEDIT extended by [1-9][0-9,]* bytes" "$T/verb_cf.err" \
    && ok "edit: reports extending __LINKEDIT" \
    || bad "edit report (chained)" "no __LINKEDIT line: $(cat "$T/verb_cf.err")"

# swift-abi set legacy reports its retag count: mkswift's fixture has one
# class and its metaclass on the stable-ABI bit, and build_main's has none.
"$T/mkswift" make "$T/edit_verb_swift"
printf 'swift-abi set legacy\n' >"$T/verb_sw.edits"
"$DRYDOCK_MACHO_REWRITE" "$T/edit_verb_swift" "$T/edit_verb_swift_out" <"$T/verb_sw.edits" \
    >/dev/null 2>"$T/verb_sw.err" || bad "edit report (swift-abi)" "$(cat "$T/verb_sw.err")"
grep -qF "      retagged 2 class records" "$T/verb_sw.err" \
    && ok "edit: swift-abi reports the class records it retagged" \
    || bad "edit report (swift-abi)" "no 'retagged 2 class records': $(cat "$T/verb_sw.err")"
build_main "$T/edit_verb_noswift"
"$DRYDOCK_MACHO_REWRITE" "$T/edit_verb_noswift" "$T/edit_verb_noswift_out" <"$T/verb_sw.edits" \
    >/dev/null 2>"$T/verb_nosw.err" || bad "edit report (swift-abi)" "$(cat "$T/verb_nosw.err")"
grep -qF "      nothing to retag" "$T/verb_nosw.err" \
    && ok "edit: swift-abi with no Swift classes says nothing to retag" \
    || bad "edit report (swift-abi)" "no 'nothing to retag': $(cat "$T/verb_nosw.err")"

# THERE IS NO QUIET MODE, so there is no flag. A tool whose job is to make
# edits nobody can see afterwards should not have an option to say nothing
# about them. Anyone who wants silence has 2>/dev/null, which needs no flag
# of ours.
build_main "$T/noverb"
printf 'load-command delete uuid\n' >"$T/nv.edits"
rm -f "$T/noverb_out"
nv_rc=0
"$DRYDOCK_MACHO_REWRITE" --verbose "$T/noverb_out" <"$T/nv.edits" \
    >/dev/null 2>"$T/nv.err" || nv_rc=$?
# EX_FAIL (2) and no OUT, the same pair the --dry-run and --output cases above
# check: "it exited non-zero" would also be satisfied by a build that refused
# the flag with the wrong code, or that refused it only after creating OUT.
[ "$nv_rc" -eq 2 ] && [ ! -e "$T/noverb_out" ] \
    && ok "edit: --verbose is an unknown flag now (2), and writes no OUT" \
    || bad "no quiet mode" "expected 2 and no OUT, got $nv_rc: $(cat "$T/nv.err")"
grep -q "unknown flag '--verbose'" "$T/nv.err" \
    && ok "edit: ... and says which flag it did not recognize" \
    || bad "no quiet mode" "the refusal does not name --verbose: $(cat "$T/nv.err")"

# And the report happens anyway, with no flag asked for.
build_main "$T/noverb2"
rm -f "$T/noverb2_out"
"$DRYDOCK_MACHO_REWRITE" "$T/noverb2" "$T/noverb2_out" <"$T/nv.edits" \
    >"$T/nv2.out" 2>"$T/nv2.err" || bad "no quiet mode" "$(cat "$T/nv2.err")"
grep -q "load-command delete" "$T/nv2.err" \
    && ok "edit: reports without being asked" \
    || bad "no quiet mode" "no report on stderr: $(cat "$T/nv2.err")"
# AND IT GOES TO STDERR, which is what makes the report unconditional safe:
# stdout belongs to the operations' own progress lines, and the six compat
# wrappers' stdout is a byte-identical contract with the C tools they replaced.
# So this checks that no report line is on stdout, rather than that stdout is
# empty -- `load-command delete uuid` reaches mr_apply_image, which has always
# printed its own "header pad" and "updated" lines there.
grep -q "load-command delete" "$T/nv2.out" \
    && bad "no quiet mode" "the statement echo went to stdout: $(cat "$T/nv2.out")" \
    || ok "edit: the statement echo is on stderr, not stdout"
grep -q "written (" "$T/nv2.out" \
    && bad "no quiet mode" "the written line went to stdout: $(cat "$T/nv2.out")" \
    || ok "edit: the written line is on stderr, so a wrapper's stdout is untouched"

# AND NO VERB'S OWN POST-WRITE LINE IS ON IT EITHER. me_run calls each
# operation's in-memory core, not its CLI verb, so an edit run shows what the
# cores print and none of what a verb prints after its own write. That
# division is load-bearing rather than cosmetic: `edit`'s single write happens
# after the last statement and the final verify, so a verb's "I wrote it" line
# appearing mid-script would name a write that has not happened and may never
# happen -- the run can still be refused two statements later.
#
# The four runs below cover every core an edit statement can reach, so the
# absence greps are not vacuous for want of a code path: mr_apply_image
# (load-command/dylib), mv_declare_minos, mswift_retag_image and
# md_declassify_buf.
build_main "$T/vonly_lc"
printf 'load-command delete uuid\ndylib append /x\n' >"$T/vonly_lc.edits"
"$DRYDOCK_MACHO_REWRITE" "$T/vonly_lc" "$T/vonly_lc.out" <"$T/vonly_lc.edits" \
    >"$T/vonly.out" 2>"$T/vonly.err" || bad "edit verb-only lines" "lc/dylib run: $(cat "$T/vonly.err")"
build_main "$T/vonly_vm"; "$T/strip_version_min" "$T/vonly_vm" >/dev/null
printf 'minos if-absent 10.9\n' >"$T/vonly_vm.edits"
"$DRYDOCK_MACHO_REWRITE" "$T/vonly_vm" "$T/vonly_vm.out" <"$T/vonly_vm.edits" \
    >>"$T/vonly.out" 2>"$T/vonly.err" || bad "edit verb-only lines" "minos run: $(cat "$T/vonly.err")"
"$T/mkswift" make "$T/vonly_sw"
printf 'swift-abi set legacy\n' >"$T/vonly_sw.edits"
"$DRYDOCK_MACHO_REWRITE" "$T/vonly_sw" "$T/vonly_sw.out" <"$T/vonly_sw.edits" \
    >>"$T/vonly.out" 2>"$T/vonly.err" || bad "edit verb-only lines" "swift-abi run: $(cat "$T/vonly.err")"
"$T/mkchained" make "$T/vonly_fx"
printf 'fixups set classic\n' >"$T/vonly_fx.edits"
"$DRYDOCK_MACHO_REWRITE" "$T/vonly_fx" "$T/vonly_fx.out" <"$T/vonly_fx.edits" \
    >>"$T/vonly.out" 2>"$T/vonly.err" || bad "edit verb-only lines" "fixups run: $(cat "$T/vonly.err")"

# The positive control, so "no verb line on stdout" cannot pass because stdout
# was empty: the cores DO print there, and two of their lines prove it.
grep -q ": header pad [0-9]* bytes available" "$T/vonly.out" \
    && grep -q "^Chained fixups: off=" "$T/vonly.out" \
    && ok "edit: the cores' own stdout lines are present, so the absence greps below mean something" \
    || bad "edit verb-only lines" "no core stdout line -- the four runs printed nothing to stdout, so nothing below is being tested: $(cat "$T/vonly.out")"

# Each string is one a VERB prints and a core does not. "Wrote OUT (N bytes)"
# is src/rewrite.c's (dylib/rpath/lc), src/version_min.c's (minos) and
# cli/drydock-macho-rewrite.c's (retag-swift, declassify); "Added LC_VERSION_MIN_MACOSX"
# is minos's alone; "class record(s)" is retag-swift's, and the parentheses are
# what separate it from the edit report's own "retagged N class records" --
# which is on stderr, and which the swift-abi case above pins.
#
# Deliberately NOT in this list: "updated (sizeofcmds=...)", which IS a core
# line (mr_apply_image's) and belongs on edit's stdout.
for vonly_s in 'Wrote ' 'Added LC_VERSION_MIN_MACOSX' 'class record(s)'; do
    grep -qF "$vonly_s" "$T/vonly.out" \
        && bad "edit verb-only lines" \
            "edit: a verb-only line leaked onto edit's stdout -- edit calls the cores directly and must never print a verb's post-write line. Found '$vonly_s' in: $(cat "$T/vonly.out")" \
        || ok "edit: no verb's '$vonly_s' line on stdout"
done

# Statements run one at a time, so each `dylib insert` goes to the front of
# the image the statement before it left: two insert lines land in the
# REVERSE of the order written. The README and src/edit.h disclose that; this
# pins it. Two 32-byte commands overflow the 56-byte pad the modern cross
# runner's linker leaves (as the `edit` insert case above notes), so the run
# frees LC_UUID's 24 bytes first.
#
# THIS USED TO BE HALF OF A PAIR. `drydock-macho-rewrite dylib -insert A -insert B` was one
# pass over one ops array and kept its order -- A at ordinal 1, B at 2 -- and
# the second half of this block ran it beside the script form to show the two
# models disagreeing. There is no second model left to compare against, and no
# way to ask for the set semantics at all, so that half is gone rather than
# rewritten into a duplicate of this one. The reversal below is now simply what
# two inserts do.
build_main "$T/edit_ins2"
printf 'load-command delete uuid\ndylib insert /A\ndylib insert /B\n' >"$T/ins2.edits"
"$DRYDOCK_MACHO_REWRITE" "$T/edit_ins2" "$T/edit_ins2_out" <"$T/ins2.edits" >/dev/null 2>"$T/ins2.err" \
    || bad "edit: two inserts" "$(cat "$T/ins2.err")"
ins2=$("$DRYDOCK_MACHO_REWRITE" info "$T/edit_ins2_out")
echo "$ins2" | grep -qxF "  ordinal=1 path=/B" && echo "$ins2" | grep -qxF "  ordinal=2 path=/A" \
    && ok "edit: two dylib insert lines leave the second at ordinal 1 and the first at 2" \
    || bad "edit: two inserts" "expected /B at 1 and /A at 2: $(echo "$ins2" | grep 'ordinal=')"
# The bare form gives the identical answer, which is the claim that matters now
# that it is the only mutating interface: two statements, two passes, whichever
# way they arrive.
build_main "$T/cli_ins2"
mts "$T/cli_ins2" "load-command delete uuid" "dylib insert /A" "dylib insert /B" \
    >/dev/null 2>"$T/cli_ins2.err" || bad "dylib: two inserts" "$(cat "$T/cli_ins2.err")"
cins2=$("$DRYDOCK_MACHO_REWRITE" info "$T/cli_ins2")
echo "$cins2" | grep -qxF "  ordinal=1 path=/B" && echo "$cins2" | grep -qxF "  ordinal=2 path=/A" \
    && ok "bare form: two dylib insert lines reverse the same way the edit verb's do" \
    || bad "dylib: two inserts" "expected /B at 1 and /A at 2: $(echo "$cins2" | grep 'ordinal=')"

# A header grow through a script, on the riskiest path it has: the grow
# reallocates the image partway through the script, and the NEXT statement
# must run against the reallocated buffer. build_main's fixture is
# MH_EXECUTE and PIE, the one shape mg_grow_header grows. The appended path
# is sized from the fixture's own pad as `drydock-macho-rewrite info` reports it, not
# hard-coded, because each host's linker leaves a different pad: an
# LC_LOAD_DYLIB is 24 bytes plus the path and its NUL, so a path longer
# than the pad cannot fit in it. Messages are cut short because the path is
# thousands of bytes long.
build_main "$T/edit_grow"
grow_pad=$("$DRYDOCK_MACHO_REWRITE" info "$T/edit_grow" \
    | sed -n 's/^header pad: \([0-9][0-9]*\) bytes available.*/\1/p')
if [ -z "$grow_pad" ]; then
    bad "edit grow: fixture setup" "drydock-macho-rewrite info reported no header pad"
    grow_pad=0
fi
grow_path="/$(printf "%${grow_pad}s" '' | tr ' ' x)"
printf 'dylib append %s\nload-command delete uuid\n' "$grow_path" >"$T/grow.edits"
grow_before=$(sha "$T/edit_grow")
rm -f "$T/edit_grow_out"
rc=0
"$DRYDOCK_MACHO_REWRITE" "$T/edit_grow" "$T/edit_grow_out" <"$T/grow.edits" \
    >/dev/null 2>"$T/grow.err" || rc=$?
[ "$rc" -eq 0 ] \
    && ok "edit: a dylib append that overflows the ${grow_pad}-byte pad grows the header, asked for by nothing (0)" \
    || bad "edit grow" "expected 0, got $rc: $(cut -c1-160 "$T/grow.err")"
grep -q "^$T/edit_grow: grew the header pad by [0-9]* bytes ($grow_pad -> [0-9]* available); image base 0x[0-9a-f]* -> 0x[0-9a-f]*\$" "$T/grow.err" \
    && ok "edit: ... announcing it on stderr: by how much, the pad before and after, the image base before and after" \
    || bad "edit grow" "no announcement: $(cut -c1-300 "$T/grow.err")"
[ "$(sha "$T/edit_grow")" = "$grow_before" ] \
    && ok "edit: ... and FILE is as it was" \
    || bad "edit grow" "the run modified FILE"
grow_info=$("$DRYDOCK_MACHO_REWRITE" info "$T/edit_grow_out")
echo "$grow_info" | grep -qF "path=$grow_path" \
    && ok "edit grow: the appended dylib is in the written image" \
    || bad "edit grow" "the appended dylib is not in the image"
echo "$grow_info" | grep -q "LC_UUID" \
    && bad "edit grow" "LC_UUID survived: the statement after the grow did not apply" \
    || ok "edit grow: the statement after the grow applied to the grown image"
"$DRYDOCK_MACHO_REWRITE" verify "$T/edit_grow_out" >/dev/null 2>"$T/grow_verify.err" \
    && ok "edit grow: the result passes drydock-macho-rewrite verify" \
    || bad "edit grow" "verify refused the result: $(cat "$T/grow_verify.err")"

# minos if-absent on a short pad. LC_VERSION_MIN_MACOSX needs 16 bytes of
# header pad, and build_main's pad is far larger, so a fixture that is
# genuinely short has to be made: strip any LC_VERSION_MIN_MACOSX the
# linker emitted (strip_version_min, above), then fill the pad with a dylib
# append whose LC_LOAD_DYLIB is the largest multiple of 8 that fits. An
# LC_LOAD_DYLIB is 24 bytes plus the path and its NUL, rounded up to 8, so a
# path of C-25 bytes makes a command of exactly C, leaving pad % 8 bytes --
# fewer than 16. Sized from `drydock-macho-rewrite info`, not hard-coded, because each
# host's linker leaves a different pad.
vm_pad_of() {
    "$DRYDOCK_MACHO_REWRITE" info "$1" | sed -n 's/^header pad: \([0-9][0-9]*\) bytes available.*/\1/p'
}
build_main "$T/vm_tight"
"$T/strip_version_min" "$T/vm_tight" >/dev/null \
    || bad "version-min grow: fixture setup" "strip_version_min failed"
vm_pad=$(vm_pad_of "$T/vm_tight")
if [ -z "$vm_pad" ] || [ "$vm_pad" -lt 32 ]; then
    bad "version-min grow: fixture setup" "pad '$vm_pad' too small to size a filler"
    vm_pad=32
fi
vm_cmd=$((vm_pad - vm_pad % 8))
vm_fill="/$(printf "%$((vm_cmd - 26))s" '' | tr ' ' v)"
mts "$T/vm_tight" "dylib append $vm_fill" >/dev/null 2>"$T/vm_fill.err" \
    || bad "version-min grow: fixture setup" "filler append failed: $(cut -c1-160 "$T/vm_fill.err")"
vm_left=$(vm_pad_of "$T/vm_tight")
[ -n "$vm_left" ] && [ "$vm_left" -lt 16 ] \
    && ok "version-min grow: fixture has ${vm_left} bytes of pad, fewer than the 16 needed" \
    || bad "version-min grow: fixture setup" "expected fewer than 16 bytes of pad, got '$vm_left'"

cp "$T/vm_tight" "$T/vm_e"
vm_before=$(sha "$T/vm_e"); vm_ino=$(stat -f %i "$T/vm_e")
rm -f "$T/vm_e_out"
rc=0
printf 'minos if-absent 10.9\n' | "$DRYDOCK_MACHO_REWRITE" "$T/vm_e" "$T/vm_e_out" \
    >"$T/vm.out" 2>"$T/vm.err" || rc=$?
[ "$rc" -eq 0 ] && ok "minos if-absent: a short pad grows the header and succeeds (0)" \
    || bad "version-min grow" "expected 0, got $rc: $(cat "$T/vm.err")"
[ "$(sha "$T/vm_e")" = "$vm_before" ] && [ "$(stat -f %i "$T/vm_e")" = "$vm_ino" ] \
    && ok "minos if-absent: ... FILE is as it was" \
    || bad "version-min grow" "the run modified FILE"
# Labelled with the INPUT's path -- the operations run against an image in
# memory and know nothing about OUT -- and printed once, however many lines
# the run reports.
vm_grows=$(grep -c "^$T/vm_e: grew the header pad by [0-9]* bytes ($vm_left -> [0-9]* available); image base 0x[0-9a-f]* -> 0x[0-9a-f]*\$" "$T/vm.err" || true)
[ "$vm_grows" -eq 1 ] \
    && ok "minos if-absent: ... stderr announces the grow exactly once, naming the input" \
    || bad "version-min grow" "expected 1 announcement, saw $vm_grows: $(cat "$T/vm.err")"
grep -q "grew" "$T/vm.out" \
    && bad "version-min grow" "the announcement reached stdout: $(cat "$T/vm.out")" \
    || ok "minos if-absent: ... and not on stdout"
"$DRYDOCK_MACHO_REWRITE" info "$T/vm_e_out" | grep -q "LC_VERSION_MIN_MACOSX" \
    && ok "minos if-absent: LC_VERSION_MIN_MACOSX is in the written image" \
    || bad "version-min grow" "no LC_VERSION_MIN_MACOSX after the grow"
"$DRYDOCK_MACHO_REWRITE" verify "$T/vm_e_out" >/dev/null 2>"$T/vm_verify.err" \
    && ok "minos if-absent: the grown image passes drydock-macho-rewrite verify" \
    || bad "version-min grow" "verify refused: $(cat "$T/vm_verify.err")"

# An extra token after OUT is still a usage error (2). It was `minos`'s own
# argc check; it is the bare form's, which takes exactly FILE and OUT and
# matches no verb here, so main() falls through to usage().
rc=0
printf 'minos if-absent 10.9\n' | "$DRYDOCK_MACHO_REWRITE" "$T/vm_e" "$T/vm_m_out" --bogus >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok "minos if-absent: an extra token after OUT is a usage error (2)" \
    || bad "minos if-absent" "an extra token after OUT: expected 2, got $rc"

# The historical add_version_min never grew and refused a short pad ("no room
# for LC_VERSION_MIN_MACOSX"); its wrapper grows it, announced.
# spec: compat/README.md "What drop-in means here, precisely".
cp "$T/vm_tight" "$T/vm_w"
rc=0
"$BIN/add_version_min" "$T/vm_w" >/dev/null 2>"$T/vm_w.err" || rc=$?
[ "$rc" -eq 0 ] && grep -q ": grew the header pad by " "$T/vm_w.err" \
    && ok "add_version_min: a short pad is grown, announced, where the original refused (0)" \
    || bad "add_version_min" "expected 0 and an announced grow, got $rc: $(cat "$T/vm_w.err")"
"$DRYDOCK_MACHO_REWRITE" info "$T/vm_w" | grep -q "LC_VERSION_MIN_MACOSX" \
    && ok "add_version_min: ... and the file now carries LC_VERSION_MIN_MACOSX" \
    || bad "add_version_min" "no LC_VERSION_MIN_MACOSX after the grow"

# ============================================================================
# target 10.9 -- the one statement whose meaning depends on the binary
# ============================================================================
# `target 10.9` expands, in place, into the statements the binary actually
# needs. Detection is EXACT in every case -- a load command is present or it
# is not, a section name begins with __objc_ or it does not, a tag bit is set
# or it is not -- so these assertions pin behaviour, not a heuristic's mood.
#
# EVERY FIXTURE BELOW IS BUILT SO ITS CONDITION IS TRUE BY CONSTRUCTION, and
# the premise is then read back with otool rather than with drydock-macho-rewrite. Hoping
# the host linker emits the shape a test needs is exactly what made three
# assertions in this file pass here and fail on the cross runner, whose modern
# linker emits LC_BUILD_VERSION where 10.9's does not
# (build_main_without_build_version, above, is the fix that episode produced).
# Where a fixture is set up with drydock-macho-rewrite itself, that is circular only in
# appearance: the otool check right after is what certifies the premise, and a
# setup that silently did nothing would make the assertion fail loudly rather
# than pass for the wrong reason.
printf 'target 10.9\n' >"$T/tgt.edits"
# FILE OUT SCRIPT with a scratch OUT: a real run, write included, which is
# what this verb offers in place of a prediction.
tgt_run() {
    rm -f "$2"
    "$DRYDOCK_MACHO_REWRITE" "$1" "$2" <"${3:-$T/tgt.edits}" \
        >"$T/tgt.out" 2>"$T/tgt.err"
}

build_main "$T/tgt_plain"
tgt_run "$T/tgt_plain" "$T/tgt_plain.out" || bad "target" "$(cat "$T/tgt.err")"
# The profile line is named in the report whatever the binary turns out to
# need.
grep -qF "  target 10.9" "$T/tgt.err" \
    && ok "target: the report names the profile line" \
    || bad "target" "no target line in the report: $(cat "$T/tgt.err")"

# AN EMPTY EXPANSION IS AN ANSWER, and it is the profile's whole point: "this
# binary already targets 10.9 correctly" is correct for a profile, unlike for
# an explicit operation, so the run says so and exits 0 rather than reporting
# nothing (which would be indistinguishable from the line having done
# nothing at all).
#
# The fixture needs each of the four steps to change nothing on any host,
# which no plain build_main can promise: strip LC_BUILD_VERSION and add
# LC_VERSION_MIN_MACOSX, each already otool-certified by the helper that does
# it. The other three -- chained fixups, a __DATA_CONST, Swift class records
# -- no linker on any host this repo supports can emit at all.
build_main_without_build_version "$T/tgt_empty"
mts "$T/tgt_empty" "minos if-absent 10.9" >/dev/null 2>"$T/tgt_empty_minos.err" \
    || bad "target: fixture setup" "minos if-absent failed: $(cat "$T/tgt_empty_minos.err")"
otool -l "$T/tgt_empty" 2>/dev/null | grep -q LC_VERSION_MIN_MACOSX \
    || bad "target: fixture setup" "tgt_empty has no LC_VERSION_MIN_MACOSX"
tgt_run "$T/tgt_empty" "$T/tgt_empty.out" && tgt_empty_rc=0 || tgt_empty_rc=$?
[ "$tgt_empty_rc" -eq 0 ] && [ -e "$T/tgt_empty.out" ] \
    && ok "target: a binary that needs nothing is a successful run (0), with OUT written" \
    || bad "target (empty)" "exit $tgt_empty_rc: $(cat "$T/tgt.err")"
grep -qF "    nothing to do: this binary already targets 10.9" "$T/tgt.err" \
    && ok "target: ... and the report says so rather than saying nothing" \
    || bad "target (empty)" "no 'nothing to do' line: $(cat "$T/tgt.err")"

# ROW 1: LC_DYLD_CHAINED_FIXUPS present -> fixups set classic, first.
# ROW 2: always -> minos at-most 10.9, which leaves no LC_BUILD_VERSION, so
# load-command delete build-version is never derived.
# mkchained's hand-built image carries both by construction (10.9's linker
# predates chained fixups by a decade, so no host can be asked for one).
# The premise is read by mkchained's own `check`, not by otool: chained
# fixups, the exports trie and LC_BUILD_VERSION all postdate 10.9, and 10.9's
# otool prints them as "Unknown load command", so an otool grep for those
# names could only ever hold on the cross runner. A reader built beside the
# fixture asks the same question on every host -- the reason tests/README.md's
# host-portability section gives for these readers existing -- and it is still
# not drydock-macho-rewrite, so it cannot certify its own setup.
"$T/mkchained" make "$T/tgt_chained"
tgt_pre=$("$T/mkchained" check "$T/tgt_chained")
echo "$tgt_pre" | grep -q "^chained=1" && echo "$tgt_pre" | grep -q "^buildver=1" \
    || bad "target: fixture setup" "tgt_chained lacks chained fixups or build-version: $(echo "$tgt_pre" | tr '\n' ' ')"
tgt_run "$T/tgt_chained" "$T/tgt_chained.out" || bad "target (chained)" "$(cat "$T/tgt.err")"
grep -qF "    fixups set classic  (LC_DYLD_CHAINED_FIXUPS present)" "$T/tgt.err" \
    && ok "target: chained fixups expand to fixups set classic" \
    || bad "target (chained)" "no fixups line: $(cat "$T/tgt.err")"
if grep -qxF "    minos at-most 10.9  (always)" "$T/tgt.err"; then
    if grep -q "^    load-command delete build-version" "$T/tgt.err"; then
        bad "target (chained)" "derived load-command delete build-version: $(cat "$T/tgt.err")"
    else
        ok "target: minos at-most 10.9 is derived, and load-command delete build-version never is"
    fi
else
    bad "target (chained)" "no minos at-most line: $(cat "$T/tgt.err")"
fi
# The expansion RAN, it was not merely reported: the output is classic.
tgt_chk=$("$T/mkchained" check "$T/tgt_chained.out")
echo "$tgt_chk" | grep -q "^chained=0" && echo "$tgt_chk" | grep -q "^dyldinfo=1" \
    && echo "$tgt_chk" | grep -q "^buildver=0" \
    && ok "target: ... and the written image is classic, with no LC_BUILD_VERSION" \
    || bad "target (chained)" "not converted: $(echo "$tgt_chk" | tr '\n' ' ')"
"$DRYDOCK_MACHO_REWRITE" verify "$T/tgt_chained.out" >/dev/null 2>"$T/tgt_v.err" \
    && ok "target: ... and the result passes drydock-macho-rewrite verify" \
    || bad "target (chained)" "verify refused: $(cat "$T/tgt_v.err")"

# An image that declares nothing gets version-min 10.9, sdk 10.9.
build_main "$T/tgt_novm"
"$T/mkminos" none "$T/tgt_novm" || bad "target: fixture setup" "mkminos none failed"
tgt_run "$T/tgt_novm" "$T/tgt_novm.out" || bad "target (none declared)" "$(cat "$T/tgt.err")"
grep -A1 -xF '    minos at-most 10.9  (always)' "$T/tgt.err" \
    | grep -qxF '      none -> version-min 10.9; sdk 10.9 written' \
    && ok "target: an image declaring nothing gets version-min 10.9, sdk 10.9, and says so" \
    || bad "target (none declared)" "$(cat "$T/tgt.err")"
[ "$("$T/mkminos" show "$T/tgt_novm.out")" = "version-min version=10.9.0 sdk=10.9.0" ] \
    && ok "target: ... and the written image declares it" \
    || bad "target (none declared)" "$("$T/mkminos" show "$T/tgt_novm.out" 2>&1)"

# ROW 3: __DATA_CONST carrying __objc_* sections -> segment rename. No host
# linker here emits __DATA_CONST either (Xcode 10 and later do), so the
# fixture is mkswift's __DATA image with its segment renamed the other way --
# and otool, not drydock-macho-rewrite, says the premise held.
"$T/mkswift" make "$T/tgt_dc"
mts "$T/tgt_dc" "segment rename __DATA __DATA_CONST" >/dev/null 2>"$T/tgt_seg.err" \
    || bad "target: fixture setup" "segment rename failed: $(cat "$T/tgt_seg.err")"
otool -l "$T/tgt_dc" 2>/dev/null | grep -q "segname __DATA_CONST" \
    && otool -l "$T/tgt_dc" 2>/dev/null | grep -q "sectname __objc_classlist" \
    || bad "target: fixture setup" "tgt_dc is not a __DATA_CONST carrying __objc_ sections"
tgt_run "$T/tgt_dc" "$T/tgt_dc.out" || bad "target (__DATA_CONST)" "$(cat "$T/tgt.err")"
grep -qF "    segment rename __DATA_CONST __DATA  (__DATA_CONST carries __objc_ sections)" \
    "$T/tgt.err" \
    && ok "target: a __DATA_CONST carrying __objc_ sections expands to the rename" \
    || bad "target (__DATA_CONST)" "no segment rename line: $(cat "$T/tgt.err")"
otool -l "$T/tgt_dc.out" 2>/dev/null | grep -q "segname __DATA_CONST" \
    && bad "target (__DATA_CONST)" "__DATA_CONST survived the expansion" \
    || ok "target: ... and the written image has no __DATA_CONST left"
# The inverse: the same fixture before the rename has its __objc_ sections in
# __DATA already, so there is nothing to rename.
"$T/mkswift" make "$T/tgt_nodc"
if otool -l "$T/tgt_nodc" 2>/dev/null | grep -q "segname __DATA_CONST"; then
    bad "target: fixture setup" "tgt_nodc unexpectedly has a __DATA_CONST"
fi
tgt_run "$T/tgt_nodc" "$T/tgt_nodc.out" || bad "target (no __DATA_CONST)" "$(cat "$T/tgt.err")"
if grep -qF "  target 10.9" "$T/tgt.err" && ! grep -q "segment rename" "$T/tgt.err"; then
    ok "target: an image with no __DATA_CONST derives no segment rename"
else
    bad "target (no __DATA_CONST)" "expected a report with no segment rename line: $(cat "$T/tgt.err")"
fi

# ROW 4: class records carrying the stable-ABI Swift tag -> swift-abi set
# legacy. mkswift's records carry tag bit 1 (value 2) by construction, and
# mkswift's own reader -- not drydock-macho-rewrite -- says so, before and after. The same
# fixture as the row above, run again so this row stands on its own.
tgt_tags=$("$T/mkswift" tags "$T/tgt_nodc")
tgt_run "$T/tgt_nodc" "$T/tgt_nodc.out" || bad "target (swift)" "$(cat "$T/tgt.err")"
echo "$tgt_tags" | grep -qx "class 2 0x1000009c2" \
    && ok "target: fixture setup: the Swift fixture carries the stable-ABI tag" \
    || bad "target: fixture setup" "not the stable-ABI tag: $tgt_tags"
grep -qF "    swift-abi set legacy  (class records carry the stable-ABI Swift tag)" "$T/tgt.err" \
    && ok "target: the stable-ABI Swift tag expands to swift-abi set legacy" \
    || bad "target (swift)" "no swift-abi line: $(cat "$T/tgt.err")"
"$T/mkswift" tags "$T/tgt_nodc.out" | grep -qx "class 1 0x1000009c1" \
    && ok "target: ... and the written image's records carry the legacy tag" \
    || bad "target (swift)" "not retagged: $("$T/mkswift" tags "$T/tgt_nodc.out")"
# The inverse: build_main's fixture has no Objective-C at all.
tgt_run "$T/tgt_plain" "$T/tgt_plain.out" || bad "target (no swift)" "$(cat "$T/tgt.err")"
if grep -qF "  target 10.9" "$T/tgt.err" && ! grep -q "swift-abi set" "$T/tgt.err"; then
    ok "target: an image with no Swift class records derives no swift-abi"
else
    bad "target (no swift)" "expected a report with no swift-abi line: $(cat "$T/tgt.err")"
fi

# IT EXPANDS WHERE IT IS WRITTEN. Position is not cosmetic: fixups set
# classic rewrites __LINKEDIT, which changes the header pad available to
# every dylib replace after it, and this tool does not reorder statements --
# the script is the plan. So the expansion has to land at the target line's
# own position, which the report's order is what shows.
#
# mkchained has no LC_UUID, so allow-unmatched keeps the run finishing.
tgt_at() { grep -n "$2" "$1" | head -1 | cut -d: -f1; }
printf 'allow-unmatched\nload-command delete uuid\ntarget 10.9\n' >"$T/tgt_after.edits"
printf 'allow-unmatched\ntarget 10.9\nload-command delete uuid\n' >"$T/tgt_before.edits"
"$T/mkchained" make "$T/tgt_pos1"
"$T/mkchained" make "$T/tgt_pos2"
tgt_run "$T/tgt_pos1" "$T/tgt_pos1.out" "$T/tgt_after.edits" \
    || bad "target (position)" "$(cat "$T/tgt.err")"
tgt_uuid=$(tgt_at "$T/tgt.err" "^  load-command delete uuid$")
tgt_fx=$(tgt_at "$T/tgt.err" "^    fixups set classic")
[ -n "$tgt_uuid" ] && [ -n "$tgt_fx" ] && [ "$tgt_uuid" -lt "$tgt_fx" ] \
    && ok "target: written last, its expansion is reported last" \
    || bad "target (position)" "uuid at '$tgt_uuid', expansion at '$tgt_fx': $(cat "$T/tgt.err")"
tgt_run "$T/tgt_pos2" "$T/tgt_pos2.out" "$T/tgt_before.edits" \
    || bad "target (position)" "$(cat "$T/tgt.err")"
tgt_uuid=$(tgt_at "$T/tgt.err" "^  load-command delete uuid$")
tgt_fx=$(tgt_at "$T/tgt.err" "^    fixups set classic")
[ -n "$tgt_uuid" ] && [ -n "$tgt_fx" ] && [ "$tgt_fx" -lt "$tgt_uuid" ] \
    && ok "target: written first, its expansion is reported first" \
    || bad "target (position)" "expansion at '$tgt_fx', uuid at '$tgt_uuid': $(cat "$T/tgt.err")"

# THE DECLARED MINIMUM, through the derived minos at-most 10.9; mkminos writes
# and reads each premise.
tgt_minos() { grep -A1 -xF '    minos at-most 10.9  (always)' "$T/tgt.err" | sed -n 2p; }

# The reproduction: this host's own toolchain, asked for 10.12.
printf 'int main(void){return 0;}\n' >"$T/min1012.c"
"$CC" -arch x86_64 -mmacosx-version-min=10.12 "$T/min1012.c" -o "$T/tgt_1012" \
    || bad "target: fixture setup" "could not build for 10.12"
case $("$T/mkminos" show "$T/tgt_1012" || true) in
    *version=10.12.0*|*minos=10.12.0*) ;;
    *) bad "target: fixture setup" "tgt_1012 does not declare 10.12: $("$T/mkminos" show "$T/tgt_1012" || true)" ;;
esac
tgt_run "$T/tgt_1012" "$T/tgt_1012.out" || bad "target (10.12 build)" "$(cat "$T/tgt.err")"
if grep -qF "  target 10.9" "$T/tgt.err"; then
    if grep -q "nothing to do" "$T/tgt.err"; then
        bad "target (10.12 build)" "said nothing to do for a binary declaring 10.12: $(cat "$T/tgt.err")"
    else
        ok "target: a binary declaring 10.12 is never 'nothing to do'"
    fi
else
    bad "target (10.12 build)" "no report, so the absent 'nothing to do' proves nothing: $(cat "$T/tgt.err")"
fi
"$T/mkminos" show "$T/tgt_1012.out" | grep -q '^version-min version=10\.9\.0 ' \
    && ok "target: ... and the written binary declares 10.9" \
    || bad "target (10.12 build)" "$("$T/mkminos" show "$T/tgt_1012.out" 2>&1)"

build_main "$T/tgt_vm12"
"$T/mkminos" vmin "$T/tgt_vm12" 10.12 10.13 || bad "target: fixture setup" "mkminos vmin failed"
tgt_run "$T/tgt_vm12" "$T/tgt_vm12.out" || bad "target (version-min 10.12)" "$(cat "$T/tgt.err")"
[ "$(tgt_minos)" = "      version-min 10.12 -> 10.9; sdk 10.13 kept" ] \
    && [ "$("$T/mkminos" show "$T/tgt_vm12.out")" = "version-min version=10.9.0 sdk=10.13.0" ] \
    && ok "target: a version-min above 10.9 is lowered, its sdk kept, and the report says so" \
    || bad "target (version-min 10.12)" "report '$(tgt_minos)': $("$T/mkminos" show "$T/tgt_vm12.out" 2>&1)"

for tgt_low in 10.8 10.9 10.9.5; do
    build_main "$T/tgt_low"
    "$T/mkminos" vmin "$T/tgt_low" "$tgt_low" 10.9 || bad "target: fixture setup" "mkminos vmin $tgt_low failed"
    tgt_run "$T/tgt_low" "$T/tgt_low.out" || bad "target (version-min $tgt_low)" "$(cat "$T/tgt.err")"
    [ "$(tgt_minos)" = "      version-min $tgt_low, at or below 10.9: kept; sdk 10.9 kept" ] \
        && ok "target: version-min $tgt_low is at or below 10.9, and the report says so" \
        || bad "target (version-min $tgt_low)" "report '$(tgt_minos)'"
    grep -qxF "    nothing to do: this binary already targets 10.9" "$T/tgt.err" \
        && cmp -s "$T/tgt_low" "$T/tgt_low.out" \
        && ok "target: ... nothing to do, and the image is written byte for byte" \
        || bad "target (version-min $tgt_low)" "$(cat "$T/tgt.err")"
done

build_main "$T/tgt_bv12"
"$T/mkminos" bv "$T/tgt_bv12" 1 12.0 12.3 || bad "target: fixture setup" "mkminos bv failed"
tgt_run "$T/tgt_bv12" "$T/tgt_bv12.out" || bad "target (build-version 12.0)" "$(cat "$T/tgt.err")"
[ "$(tgt_minos)" = "      build-version 12.0 -> version-min 10.9; sdk 12.3 carried over" ] \
    && [ "$("$T/mkminos" show "$T/tgt_bv12.out")" = "version-min version=10.9.0 sdk=12.3.0" ] \
    && ok "target: build-version 12.0 becomes version-min 10.9, sdk 12.3 carried over, and says so" \
    || bad "target (build-version 12.0)" "report '$(tgt_minos)': $("$T/mkminos" show "$T/tgt_bv12.out" 2>&1)"
if [ -n "$(tgt_minos)" ]; then
    if grep -q "^    load-command delete build-version" "$T/tgt.err"; then
        bad "target (build-version 12.0)" "derived load-command delete build-version: $(cat "$T/tgt.err")"
    else
        ok "target: ... with no load-command delete build-version derived"
    fi
else
    bad "target (build-version 12.0)" "no minos report, so the absent delete proves nothing"
fi

build_main "$T/tgt_bv0"
"$T/mkminos" bv "$T/tgt_bv0" 1 12.0 0.0 || bad "target: fixture setup" "mkminos bv failed"
tgt_run "$T/tgt_bv0" "$T/tgt_bv0.out" || bad "target (build-version sdk 0)" "$(cat "$T/tgt.err")"
[ "$(tgt_minos)" = "      build-version 12.0 -> version-min 10.9; sdk 0.0 carried over" ] \
    && [ "$("$T/mkminos" show "$T/tgt_bv0.out")" = "version-min version=10.9.0 sdk=0.0.0" ] \
    && ok "target: a build-version sdk of 0.0 is carried over too" \
    || bad "target (build-version sdk 0)" "report '$(tgt_minos)': $("$T/mkminos" show "$T/tgt_bv0.out" 2>&1)"

for tgt_bvlow in 10.7 10.9 10.9.5; do
    case $tgt_bvlow in 10.9.5) tgt_want=10.9.5 ;; *) tgt_want=$tgt_bvlow.0 ;; esac
    build_main "$T/tgt_bvlow"
    "$T/mkminos" bv "$T/tgt_bvlow" 1 "$tgt_bvlow" 10.10 || bad "target: fixture setup" "mkminos bv $tgt_bvlow failed"
    tgt_run "$T/tgt_bvlow" "$T/tgt_bvlow.out" || bad "target (build-version $tgt_bvlow)" "$(cat "$T/tgt.err")"
    [ "$(tgt_minos)" = "      build-version $tgt_bvlow -> version-min $tgt_bvlow; sdk 10.10 carried over" ] \
        && [ "$("$T/mkminos" show "$T/tgt_bvlow.out")" = "version-min version=$tgt_want sdk=10.10.0" ] \
        && ok "target: build-version $tgt_bvlow is carried over as version-min $tgt_bvlow" \
        || bad "target (build-version $tgt_bvlow)" "report '$(tgt_minos)': $("$T/mkminos" show "$T/tgt_bvlow.out" 2>&1)"
done

"$T/mkchained" make "$T/tgt_chmin"
tgt_run "$T/tgt_chmin" "$T/tgt_chmin.out" || bad "target (chained minimum)" "$(cat "$T/tgt.err")"
grep -qxF "      chained fixups -> LC_DYLD_INFO_ONLY; LC_BUILD_VERSION 12.0 (sdk 12.0) kept as LC_VERSION_MIN_MACOSX" \
    "$T/tgt.err" \
    && [ "$(tgt_minos)" = "      version-min 12.0 -> 10.9; sdk 12.0 kept" ] \
    && ok "target: a chained image's build-version is kept by fixups, then lowered by minos" \
    || bad "target (chained minimum)" "$(cat "$T/tgt.err")"
"$T/mkminos" show "$T/tgt_chmin.out" | grep -qxF "version-min version=10.9.0 sdk=12.0.0" \
    && ok "target: ... and the chained image's sdk 12.0 survives the conversion" \
    || bad "target (chained minimum)" "$("$T/mkminos" show "$T/tgt_chmin.out" 2>&1)"
tgt_first=$(grep '^    [a-z]' "$T/tgt.err" | head -1)
[ "$tgt_first" = "    fixups set classic  (LC_DYLD_CHAINED_FIXUPS present)" ] \
    && ok "target: ... and fixups set classic is the first derived line" \
    || bad "target (chained minimum)" "first derived line: '$tgt_first'"

# THE SWIFT TAG IS READ AFTER fixups set classic. On a chained image the class
# records' pointers are chain links until the conversion lowers them.
"$T/mkchained" make-swift "$T/tgt_chsw"
tgt_run "$T/tgt_chsw" "$T/tgt_chsw.out" || bad "target (chained Swift)" "$(cat "$T/tgt.err")"
grep -qxF "    swift-abi set legacy  (class records carry the stable-ABI Swift tag)" "$T/tgt.err" \
    && [ "$("$T/mkchained" tags "$T/tgt_chsw.out")" = "class 1
meta 1" ] \
    && ok "target: a chained Swift image is retagged, detected after fixups set classic" \
    || bad "target (chained Swift)" "tags $("$T/mkchained" tags "$T/tgt_chsw.out" | tr '\n' ' '): $(cat "$T/tgt.err")"

"$T/mkchained" make-swiftdc "$T/tgt_all"
tgt_run "$T/tgt_all" "$T/tgt_all.out" || bad "target (all four)" "$(cat "$T/tgt.err")"
tgt_o1=$(tgt_at "$T/tgt.err" "^    fixups set classic  ")
tgt_o2=$(tgt_at "$T/tgt.err" "^    minos at-most 10.9  ")
tgt_o3=$(tgt_at "$T/tgt.err" "^    segment rename __DATA_CONST __DATA  ")
tgt_o4=$(tgt_at "$T/tgt.err" "^    swift-abi set legacy  ")
[ -n "$tgt_o1" ] && [ -n "$tgt_o2" ] && [ -n "$tgt_o3" ] && [ -n "$tgt_o4" ] \
    && [ "$tgt_o1" -lt "$tgt_o2" ] && [ "$tgt_o2" -lt "$tgt_o3" ] && [ "$tgt_o3" -lt "$tgt_o4" ] \
    && ok "target: the four lines are derived in the edit script's order, minos at-most second" \
    || bad "target (all four)" "order '$tgt_o1' '$tgt_o2' '$tgt_o3' '$tgt_o4': $(cat "$T/tgt.err")"

# THE PUBLISHED EDIT SCRIPT. README.md prints target 10.9's expansion as a script;
# run by hand it must write target's own bytes, thin and fat. The thin image
# needs all four lines; the fat one adds a plain chained slice, where the
# rename and the retag are no-ops.
printf 'fixups set classic\nminos at-most 10.9\nsegment rename __DATA_CONST __DATA\nswift-abi set legacy\n' \
    >"$T/tgt_script.edits"
rc=0; "$DRYDOCK_MACHO_REWRITE" "$T/tgt_all" "$T/tgt_all.hand" <"$T/tgt_script.edits" \
    >/dev/null 2>"$T/tgt_script.err" || rc=$?
[ "$rc" -eq 0 ] && cmp -s "$T/tgt_all.hand" "$T/tgt_all.out" && ! cmp -s "$T/tgt_all" "$T/tgt_all.out" \
    && ok "target: the published edit script, run by hand, writes target's own bytes (thin)" \
    || bad "target (edit script, thin)" "rc $rc, or the bytes differ: $(cat "$T/tgt_script.err")"
"$T/mkchained" make "$T/script_s1"
"$BIN/makefat" "$T/script_fat" "$T/tgt_all" 0x1000007 3 12 "$T/script_s1" 0x100000c 0 12
tgt_run "$T/script_fat" "$T/script_fat.out" || bad "target (edit script, fat)" "$(cat "$T/tgt.err")"
rc=0; "$DRYDOCK_MACHO_REWRITE" "$T/script_fat" "$T/script_fat.hand" <"$T/tgt_script.edits" \
    >/dev/null 2>"$T/tgt_script.err" || rc=$?
[ "$rc" -eq 0 ] && cmp -s "$T/script_fat.hand" "$T/script_fat.out" \
    && ! cmp -s "$T/script_fat" "$T/script_fat.out" \
    && ok "target: ... and on a fat file" \
    || bad "target (edit script, fat)" "rc $rc, or the bytes differ: $(cat "$T/tgt_script.err")"

# TARGET NEVER COUNTS AS UNMATCHED: each conditional line is derived only where
# it has work, and minos cannot miss, so nothing is reported unmatched.
printf 'target 10.9\n' >"$T/tgt_fw.edits"
"$T/mkchained" make "$T/tgt_fw"
tgt_run "$T/tgt_fw" "$T/tgt_fw.out" "$T/tgt_fw.edits" && tgt_fw_rc=0 || tgt_fw_rc=$?
[ "$tgt_fw_rc" -eq 0 ] && [ -e "$T/tgt_fw.out" ] \
    && ok "target: it does not refuse by default" \
    || bad "target (unmatched)" "exit $tgt_fw_rc: $(cat "$T/tgt.err")"
grep -q "matched nothing" "$T/tgt.err" \
    && bad "target (unmatched)" "reported a derived statement as unmatched: $(cat "$T/tgt.err")" \
    || ok "target: ... and nothing is reported as having matched nothing"

# THE OTHER SIDE OF THAT, WHICH IS NOT SPECIAL-CASED: writing `target 10.9`
# AND an explicit statement it would have derived makes the explicit one
# redundant, and it refuses by default. Same script as above with one line
# added -- the expansion leaves no LC_BUILD_VERSION, so by
# the time the EXPLICIT `load-command delete build-version` runs there is
# nothing of that kind left. A statement somebody wrote that matched nothing
# is a miss, and by default a refusal. Both halves are documented rather
# than smoothed over, so both halves are pinned.
printf 'target 10.9\nload-command delete build-version\n' >"$T/tgt_redundant.edits"
"$T/mkchained" make "$T/tgt_redundant"
tgt_red_before=$(sha "$T/tgt_redundant")
tgt_run "$T/tgt_redundant" "$T/tgt_redundant.out" "$T/tgt_redundant.edits" \
    && tgt_red_rc=0 || tgt_red_rc=$?
[ "$tgt_red_rc" -eq 1 ] && [ ! -e "$T/tgt_redundant.out" ] \
    && [ "$(sha "$T/tgt_redundant")" = "$tgt_red_before" ] \
    && ok "target: an explicit statement the expansion already did is redundant, and refuses it by default (1)" \
    || bad "target (redundant)" "expected 1 and no OUT, got $tgt_red_rc: $(cat "$T/tgt.err")"
grep -q "no load command of kind build-version to delete" "$T/tgt.err" \
    && ok "target: ... and the miss reported is the explicit statement's, not the derived one's" \
    || bad "target (redundant)" "no miss reported for the explicit statement: $(cat "$T/tgt.err")"
# With allow-unmatched the same script is a report and not a refusal, which
# is what makes the line above the default's doing rather than target's.
printf 'allow-unmatched\ntarget 10.9\nload-command delete build-version\n' >"$T/tgt_redlax.edits"
"$T/mkchained" make "$T/tgt_redlax"
tgt_run "$T/tgt_redlax" "$T/tgt_redlax.out" "$T/tgt_redlax.edits" \
    && tgt_redlax_rc=0 || tgt_redlax_rc=$?
[ "$tgt_redlax_rc" -eq 0 ] && [ -e "$T/tgt_redlax.out" ] \
    && ok "target: ... and with allow-unmatched the same redundancy is only reported" \
    || bad "target (redundant)" "expected 0 and an OUT, got $tgt_redlax_rc: $(cat "$T/tgt.err")"

# A DERIVED STATEMENT GETS THE ANSWER THE EXPLICIT ONE GETS, and its refusal
# is reported against the line the operator actually wrote. The fixture has
# no LC_VERSION_MIN_MACOSX and a pad too short for one, so the derived
# `minos at-most 10.9` grows the header, as the explicit statement does;
# with the PIE flag cleared the same fixture cannot grow, and is refused.
#
# NOT $T/vm_tight, though it is the same shape: this needs LC_BUILD_VERSION
# ABSENT too. On a host whose linker emits one, minos at-most would convert
# it, freeing at least 24 bytes -- more than the 16 LC_VERSION_MIN_MACOSX
# needs -- so the run would succeed and this assertion would fail there and
# pass here. Same trap, same fix: make the premise true
# (build_main_without_build_version) rather than assume it.
build_main_without_build_version "$T/tgt_tight"
"$T/strip_version_min" "$T/tgt_tight" >/dev/null \
    || bad "target: fixture setup" "strip_version_min failed on tgt_tight"
tgt_pad=$(vm_pad_of "$T/tgt_tight")
if [ -z "$tgt_pad" ] || [ "$tgt_pad" -lt 32 ]; then
    bad "target: fixture setup" "pad '$tgt_pad' too small to size a filler"
    tgt_pad=32
fi
tgt_cmd=$((tgt_pad - tgt_pad % 8))
tgt_fill="/$(printf "%$((tgt_cmd - 26))s" '' | tr ' ' t)"
mts "$T/tgt_tight" "dylib append $tgt_fill" >/dev/null 2>"$T/tgt_fill.err" \
    || bad "target: fixture setup" "filler append failed: $(cut -c1-160 "$T/tgt_fill.err")"
tgt_left=$(vm_pad_of "$T/tgt_tight")
[ -n "$tgt_left" ] && [ "$tgt_left" -lt 16 ] \
    && ok "target: fixture setup: ${tgt_left} bytes of pad, fewer than the 16 version-min needs" \
    || bad "target: fixture setup" "expected fewer than 16 bytes of pad, got '$tgt_left'"
cp "$T/tgt_tight" "$T/tgt_nopie"
tgt_run "$T/tgt_tight" "$T/tgt_tight.out" \
    || bad "target (grow)" "expected 0: $(cat "$T/tgt.err")"
otool -l "$T/tgt_tight.out" 2>/dev/null | grep -q LC_VERSION_MIN_MACOSX \
    && grep -q "^$T/tgt_tight: grew the header pad by " "$T/tgt.err" \
    && ok "target: a derived statement grows the header, announced, and lands" \
    || bad "target (grow)" "no announced grow, or no LC_VERSION_MIN_MACOSX: $(cat "$T/tgt.err")"
unpie "$T/tgt_nopie"
tgt_before_sha=$(sha "$T/tgt_nopie")
tgt_run "$T/tgt_nopie" "$T/tgt_nopie.out" && tgt_nopie_rc=0 || tgt_nopie_rc=$?
[ "$tgt_nopie_rc" -eq 1 ] && [ ! -e "$T/tgt_nopie.out" ] \
    && [ "$(sha "$T/tgt_nopie")" = "$tgt_before_sha" ] \
    && grep -q "not PIE" "$T/tgt.err" \
    && ok "target: a derived statement that cannot grow a non-PIE image is refused (1)" \
    || bad "target (no grow)" "expected 1, 'not PIE' and no OUT, got $tgt_nopie_rc: $(cat "$T/tgt.err")"
grep -qF "drydock-macho-rewrite edit: refused at statement 1 of 1 (line 1);" "$T/tgt.err" \
    && ok "target: ... and the refusal names the target line, not a line nobody wrote" \
    || bad "target (no grow)" "not that wording: $(cat "$T/tgt.err")"

# ONE TARGET PER SCRIPT, AND AN UNKNOWN ONE IS A REFUSAL -- both at parse
# time, so nothing is read and nothing is written.
printf 'target 10.9\ntarget 10.9\n' >"$T/tgt_two.edits"
rm -f "$T/tgt_two.out"
rc=0
"$DRYDOCK_MACHO_REWRITE" "$T/tgt_plain" "$T/tgt_two.out" <"$T/tgt_two.edits" \
    >/dev/null 2>"$T/tgt_two.err" || rc=$?
[ "$rc" -eq 2 ] && [ ! -e "$T/tgt_two.out" ] && grep -q "line 2" "$T/tgt_two.err" \
    && ok "target: a second target is a parse error (2) naming its line" \
    || bad "target (two)" "expected 2 and 'line 2', got $rc: $(cat "$T/tgt_two.err")"
printf 'target 10.10\n' >"$T/tgt_unknown.edits"
rm -f "$T/tgt_unknown.out"
rc=0
"$DRYDOCK_MACHO_REWRITE" "$T/tgt_plain" "$T/tgt_unknown.out" <"$T/tgt_unknown.edits" \
    >/dev/null 2>"$T/tgt_unknown.err" || rc=$?
[ "$rc" -eq 2 ] && [ ! -e "$T/tgt_unknown.out" ] \
    && grep -q "10.10" "$T/tgt_unknown.err" && grep -q "10.9" "$T/tgt_unknown.err" \
    && ok "target: an unknown target errors (2) rather than silently doing 10.9's work" \
    || bad "target (unknown)" "expected 2 naming 10.10 and 10.9, got $rc: $(cat "$T/tgt_unknown.err")"

# ============================================================================
# edit on a fat file, end to end
# ============================================================================
# edit on a fat file, end to end: two build_main executables in one
# container, the second labelled arm64 in its fat_arch entry (edit names a
# slice by that entry). A dylib append on the x86_64 slice alone grows it by a
# page, so the arm64 slice after it has to move -- the one consequence a
# passed-through slice can have, and the report must say so. The appended
# path is sized from the slice's own pad, not hard-coded, because each
# host's linker leaves a different pad.
build_main "$T/fat_s0"
build_main "$T/fat_s1"
"$BIN/makefat" "$T/fat_edit" "$T/fat_s0" 0x1000007 3 12 "$T/fat_s1" 0x100000c 0 12
fat_pad=$("$DRYDOCK_MACHO_REWRITE" info "$T/fat_s0" | sed -n 's/^header pad: \([0-9][0-9]*\) bytes available.*/\1/p')
[ -n "$fat_pad" ] || { bad "edit fat: fixture setup" "no header pad reported"; fat_pad=0; }
fat_path="/$(printf "%${fat_pad}s" '' | tr ' ' f)"
printf 'arch x86_64\ndylib append %s\n' "$fat_path" >"$T/fat.edits"
rc=0
"$DRYDOCK_MACHO_REWRITE" "$T/fat_edit" "$T/fat_edit_out" <"$T/fat.edits" \
    >/dev/null 2>"$T/fat.err" || rc=$?
[ "$rc" -eq 0 ] && ok "edit: a fat file's x86_64 slice is edited, growing it" \
    || bad "edit fat" "expected 0, got $rc: $(cut -c1-200 "$T/fat.err")"
grep -q "slice arm64: not selected by arch; passed through unchanged" "$T/fat.err" \
    && ok "edit: the report accounts for the unselected arm64 slice" \
    || bad "edit fat" "no pass-through line: $(cut -c1-300 "$T/fat.err")"
grep -q "slice arm64: moved from offset" "$T/fat.err" \
    && ok "edit: the report says the arm64 slice moved when the x86_64 slice grew" \
    || bad "edit fat" "no moved line: $(cut -c1-300 "$T/fat.err")"
"$BIN/fatcheck" dump "$T/fat_edit_out" 0 "$T/fat_out0"
"$BIN/fatcheck" dump "$T/fat_edit_out" 1 "$T/fat_out1"
"$DRYDOCK_MACHO_REWRITE" info "$T/fat_out0" | grep -qF "path=$fat_path" \
    && ok "edit: the x86_64 slice carries the appended dylib" \
    || bad "edit fat" "the appended dylib is not in slice 0"
"$DRYDOCK_MACHO_REWRITE" verify "$T/fat_out0" >/dev/null 2>"$T/fat_v.err" \
    && ok "edit: the grown x86_64 slice passes drydock-macho-rewrite verify" \
    || bad "edit fat" "verify refused slice 0: $(cat "$T/fat_v.err")"
cmp -s "$T/fat_out1" "$T/fat_s1" \
    && ok "edit: the arm64 slice is byte-identical, though it moved" \
    || bad "edit fat" "the arm64 slice changed"

# target 10.9 IS DETECTED PER SLICE, which is the whole of what "its meaning
# depends on the binary" means for a fat file: one container, two slices, one
# `target 10.9` line, and two different expansions. The second slice is
# mkchained's chained-fixups image, labelled arm64 in its fat_arch entry the
# way fat_s1 is above -- so exactly one slice has chained fixups, and exactly
# one `fixups set classic` may be derived across the whole run.
"$T/mkchained" make "$T/fat_tgt1"
"$BIN/makefat" "$T/fat_tgt" "$T/tgt_plain" 0x1000007 3 12 "$T/fat_tgt1" 0x100000c 0 12
rm -f "$T/fat_tgt.out"
rc=0
"$DRYDOCK_MACHO_REWRITE" "$T/fat_tgt" "$T/fat_tgt.out" <"$T/tgt.edits" \
    >/dev/null 2>"$T/fat_tgt.err" || rc=$?
[ "$rc" -eq 0 ] && ok "target: a fat file's slices are each expanded" \
    || bad "target fat" "expected 0, got $rc: $(cat "$T/fat_tgt.err")"
fat_tgt_n=$(grep -c "^  target 10.9$" "$T/fat_tgt.err" || true)
fat_tgt_fx=$(grep -c "^    fixups set classic" "$T/fat_tgt.err" || true)
[ "$fat_tgt_n" -eq 2 ] && [ "$fat_tgt_fx" -eq 1 ] \
    && ok "target: ... the same line in both slices, expanding differently in each" \
    || bad "target fat" "expected 2 target lines and 1 fixups line, got $fat_tgt_n and $fat_tgt_fx: $(cat "$T/fat_tgt.err")"
fat_tgt_min=$(grep -c "^    minos at-most 10.9  (always)$" "$T/fat_tgt.err" || true)
[ "$fat_tgt_min" -eq 2 ] && ok "target: ... and each slice derives its own minos at-most 10.9" \
    || bad "target fat" "expected 2 minos lines, got $fat_tgt_min: $(cat "$T/fat_tgt.err")"

printf 'arch amd64\nload-command delete uuid\n' >"$T/fat_bad.edits"
rc=0
"$DRYDOCK_MACHO_REWRITE" "$T/fat_edit" "$T/fat_edit_out" <"$T/fat_bad.edits" \
    >/dev/null 2>"$T/fat_bad.err" || rc=$?
[ "$rc" -eq 2 ] && ok "edit: an unknown arch name is a parse error (2)" \
    || bad "edit fat" "arch amd64: expected 2, got $rc: $(cat "$T/fat_bad.err")"

reached_end=1
echo "cli_test: $fails failure(s)"
[ "$fails" -eq 0 ]
