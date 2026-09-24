#!/bin/sh
# tests/wrapper_test.sh -- the six /bin/sh wrappers' own behaviour: the
# grammar they translate, the exit codes they map, and the stdout they
# reshape.
#
#   sh tests/wrapper_test.sh <bindir>
#
# WHAT THIS IS FOR, AND WHAT IT IS NOT.
#
#   tests/translate_test.sh   pins the TEXT compat/translate.sh emits, and
#                             never runs drydock-macho-rewrite on a file.
#   tests/known-callers.sh    replays the real callers end to end. That is the
#                             gate; a failure there blocks.
#   this file                 everything BETWEEN those two: each wrapper's
#                             exit-code mapping and its stdout, on the cases
#                             tests/compat-matrix.tsv identified as the ones
#                             where drydock-macho-rewrite and the C tool disagreed. Each
#                             assertion below names the divergence it closes.
#
# Every expected value here was measured against the C binaries built from
# commit 91b30b3 (the last commit carrying all six compat/*.c files) on real
# 10.9 (Darwin 13.4), the same provenance tests/known-callers.sh's digests
# have (tests/README.md's "Not run by ctest" section has the full account).
# compat/README.md records each divergence and the test that holds it.
#
# set -u, not set -e: same reason as every other shell test here.
set -u

BIN="${1:?usage: wrapper_test.sh <bindir>}"
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
FIXTURE="$HERE/fixture.macho"
CC="${CC:-clang}"

pass=0; fail=0
ok()   { echo "PASS $1"; pass=$((pass + 1)); }
bad()  { echo "FAIL $1: $2" >&2; fail=$((fail + 1)); }
skip() { echo "SKIP $1: $2"; }

# ---- the six names the rename must not reach, which is also the preflight --
#
# A TRIPWIRE, not a test of anything new: it passed before the binary was ever
# renamed and it has to keep passing after each rename. These six names
# are a shipped interface -- mavericksforever.com/claude/install.sh fetches
# three of them by name -- and the whole point of the compat layer is that a
# caller who learned it in 2024 still works. The binary, the library, the two
# files the wrappers source and the taught text all changed name; these did
# not.
#
# IT IS THE PREFLIGHT, deliberately, and not a second loop after one. When it
# was added below an existing `[ -x ] || exit 1` loop over the same six names
# in the same directory, a missing wrapper killed the run up there and this
# loop's bad() branch could never fire -- six assertions that could only pass.
# One check, in one place, that names what is missing.
for w in patch_macho change_dylib add_version_min fix_macho rename_segment retag_swift_classes; do
    [ -x "$BIN/$w" ] \
        && ok "wrapper $w still exists under its historical name" \
        || bad "wrapper names" "$w is missing from $BIN after the rename"
done
# drydock-macho-rewrite is not one of the six -- it is the binary they wrap, and its name
# is the one this rename DID change -- so it keeps the bare existence check.
[ -x "$BIN/drydock-macho-rewrite" ] || { echo "wrapper_test: $BIN/drydock-macho-rewrite not found or not executable" >&2; exit 1; }
# Nothing below can say anything useful with a wrapper missing, so stop here
# rather than emit a hundred confusing failures after the real one.
[ "$fail" -eq 0 ] || { echo "wrapper_test: $pass passed, $fail failed" >&2; exit 1; }

T=$(mktemp -d "${TMPDIR:-/tmp}/macho-wrapper-test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

fresh() { cp "$FIXTURE" "$T/f"; }
sha()   { shasum -a 256 < "$1" | cut -d' ' -f1; }
# unpie FILE -- clear MH_PIE, so a header grow refuses FILE ("not PIE").
# platform: MH_PIE is 0x00200000 in the little-endian flags word at offset
# 24, so bit 0x20 of byte 26.
unpie() {
    unpie_b=$(od -An -tu1 -j26 -N1 "$1" | tr -d ' ')
    printf "\\$(printf %o $((unpie_b & ~32)))" | dd of="$1" bs=1 seek=26 conv=notrunc 2>/dev/null
}

# strip_vm FILE -- remove FILE's LC_VERSION_MIN_MACOSX, so add_version_min has
# something to do to it. tests/fixture.macho is a real 10.9 binary and already
# carries one, and a wrapper that installed nothing would pass an "it landed"
# assertion just as well as one that installed correctly. The program that
# does it is tests/strip_version_min.c, shared with tests/cli_test.sh, which
# needs the same fixture for the same reason; built here on first use.
#
# A FAILURE HERE IS LOUD, via bad(), rather than a return code the callers
# below would have to check one by one: a silent strip failure leaves an
# unstripped fixture, against which every "the command is there afterward"
# assertion passes without the wrapper having done anything at all.
strip_vm() {
    [ -x "$T/strip_version_min" ] \
        || "$CC" -O2 -o "$T/strip_version_min" "$HERE/strip_version_min.c" 2>"$T/strip_vm.out" \
        || { bad "strip_vm" "cannot build $HERE/strip_version_min.c: $(cat "$T/strip_vm.out")"; return 1; }
    "$T/strip_version_min" "$1" >"$T/strip_vm.out" 2>&1 \
        || { bad "strip_vm" "$1: $(cat "$T/strip_vm.out")"; return 1; }
    return 0
}

# mkswift_fixture FILE -- write a fresh Mach-O with two Swift class records
# (both on the stable-ABI tag) to FILE, so retag_swift_classes has something
# real to retag. tests/fixture.macho (what `fresh` copies) has ZERO Swift
# class records, so every retag_swift_classes assertion that only ever used
# `fresh` could not tell "retagged for real" from "installed nothing at all"
# -- both print "total: 0". The program is tests/mkswift.c, shared with
# tests/cli_test.sh, which needs the identical fixture for the identical
# reason; built here on first use.
mkswift_fixture() {
    [ -x "$T/mkswift" ] \
        || "$CC" -O2 -o "$T/mkswift" "$HERE/mkswift.c" 2>"$T/mkswift.out" \
        || { bad "mkswift_fixture" "cannot build $HERE/mkswift.c: $(cat "$T/mkswift.out")"; return 1; }
    "$T/mkswift" make "$1" >"$T/mkswift.out" 2>&1 \
        || { bad "mkswift_fixture" "$1: $(cat "$T/mkswift.out")"; return 1; }
    return 0
}

# mkchained_fixture FILE -- write a Mach-O that really uses CHAINED FIXUPS to
# FILE, so patch_macho's CONVERTING path can be reached. `fresh`'s
# tests/fixture.macho is a real 10.9 binary, which predates the format by a
# decade: every patch_macho assertion built on it exercises the PASS-THROUGH,
# where nothing is converted, no `Wrote OUT` line is printed and (for IN == OUT)
# nothing is installed. Three mutations of the converting path -- installing the
# unconverted bytes, deleting the wrapper's own `Wrote OUT (N bytes)` line, and
# skipping the install when IN == OUT -- went unnoticed by every suite in this
# repo while that was the only input available here.
#
# The program is tests/mkchained.c, shared with tests/cli_test.sh exactly the
# way strip_version_min.c and mkswift.c are, and built on first use. It needs
# src/ on the include path (mach_compat.h) as cli_test's build of it does.
mkchained_fixture() {
    [ -x "$T/mkchained" ] \
        || "$CC" -O2 -I "$ROOT/src" -o "$T/mkchained" "$HERE/mkchained.c" 2>"$T/mkchained.out" \
        || { bad "mkchained_fixture" "cannot build $HERE/mkchained.c: $(cat "$T/mkchained.out")"; return 1; }
    "$T/mkchained" make "$1" >"$T/mkchained.out" 2>&1 \
        || { bad "mkchained_fixture" "$1: $(cat "$T/mkchained.out")"; return 1; }
    return 0
}

# firstline_is <file> <exact text> -- string equality, never a regex. The
# usage lines below embed $BIN, a path this test does not choose, and a `grep`
# pattern containing one would treat whatever punctuation the build directory
# happens to have as syntax. The same goes for the bracketed operands in
# retag_swift_classes' usage line.
firstline_is() { [ "$(head -1 "$1")" = "$2" ]; }

# has_line <file> <exact line> -- for the cases where the teaching message
# comes FIRST (it does whenever the translation succeeded and the refusal
# happened afterwards, in the wrapper). -F and -x keep it a whole-line
# string comparison rather than a pattern.
has_line() { grep -qxF "$2" "$1"; }

# run TOOL ARG... -- run a wrapper from inside $T with a RELATIVE path, the
# way tests/compat-sweep.sh and tests/differential.sh do: every one of these
# tools prints the path it was given, so a relative one keeps the expected
# strings short and host-independent. Sets $rc, $T/out and $T/err.
run() {
    tool=$1; shift
    ( cd "$T" && "$BIN/$tool" "$@" ) >"$T/out" 2>"$T/err"
    rc=$?
    return 0
}

# ---- every name is there, and runs --------------------------------------
#
# All six names still install and still run -- and, since fix_macho joined them, all SIX are
# /bin/sh scripts. That last part is the whole point made
# checkable: if any of these six is an executable rather than a script, this
# repo is shipping a second Mach-O rewriting binary again.
for t in patch_macho change_dylib add_version_min rename_segment retag_swift_classes fix_macho; do
    if [ -x "$BIN/$t" ] && head -1 "$BIN/$t" | grep -q '^#!/bin/sh$'; then
        ok "$t: installed, executable, and a /bin/sh script"
    else
        bad "$t" "not an executable /bin/sh script in $BIN"
    fi
done

# ---- POSIX sh, not bash -------------------------------------------------
#
# 10.9's /bin/sh is bash 3.2 in sh mode, which accepts plenty a stricter POSIX
# shell does not. Parse every wrapper under /bin/sh, and re-run one whole
# invocation under ksh -- the same second-shell cross-check
# tests/translate_test.sh does, for the same reason: a bashism should fail
# here, not on somebody's machine.
for f in "$ROOT"/compat/*.sh; do
    if /bin/sh -n "$f" 2>"$T/synerr"; then
        ok "sh -n $(basename "$f")"
    else
        bad "sh -n $(basename "$f")" "$(cat "$T/synerr")"
    fi
done
if [ -x /bin/ksh ]; then
    for f in "$ROOT"/compat/*.sh; do
        /bin/ksh -n "$f" 2>"$T/synerr" \
            && ok "ksh -n $(basename "$f")" \
            || bad "ksh -n $(basename "$f")" "$(cat "$T/synerr")"
    done
    fresh
    ( cd "$T" && /bin/ksh "$BIN/change_dylib" f -strip-lc uuid \
        -change /usr/lib/libSystem.B.dylib '@loader_path/../S.dylib' ) >"$T/out" 2>"$T/err"
    kshrc=$?
    [ "$kshrc" -eq 0 ] \
        && ok "ksh: a whole mixed-family change_dylib run behaves the same" \
        || bad "ksh" "exit $kshrc: $(cat "$T/err")"
else
    skip "the second-shell cross-check" "/bin/ksh is not present on this host"
fi

# ---- a symlinked wrapper, away from its support files -------------------
for w in patch_macho change_dylib add_version_min fix_macho rename_segment \
         retag_swift_classes insert_dylib bake-mavericks-shim; do
    rm -rf "$T/lnk"; mkdir "$T/lnk"; ln -s "$BIN/$w" "$T/lnk/$w"
    rc=0
    ( unset DRYDOCK_MACHO_REWRITE_COMPAT_DIR; "$T/lnk/$w" ) >"$T/out" 2>"$T/err" || rc=$?
    [ "$rc" -eq 1 ] \
        && firstline_is "$T/err" "$T/lnk/$w: cannot find drydock-macho-rewrite-compat.sh in $T/lnk -- drydock-macho-rewrite and its two support" \
        && grep -qF 'set DRYDOCK_MACHO_REWRITE_COMPAT_DIR to where they really are' "$T/err" \
        && ok "$w: a symlink to it elsewhere says to set DRYDOCK_MACHO_REWRITE_COMPAT_DIR (1)" \
        || bad "$w symlinked" "exit $rc: $(cat "$T/err")"
done
rm -rf "$T/lnk"

# ---- a wrapper finds drydock-macho-rewrite next to itself, not on PATH -----------------
#
# The wrappers are meant to be dropped into a directory beside drydock-macho-rewrite, which
# is how install.sh's $MF directory is shaped. Running one with a PATH that
# does NOT contain the bindir is the check that it resolves drydock-macho-rewrite from its
# own location.
fresh
( cd "$T" && PATH=/usr/bin:/bin "$BIN/add_version_min" f ) >"$T/out" 2>"$T/err"
rc=$?
[ "$rc" -eq 0 ] \
    && ok "a wrapper finds drydock-macho-rewrite beside itself with drydock-macho-rewrite absent from PATH" \
    || bad "drydock-macho-rewrite resolution" "exit $rc: $(cat "$T/err")"

# ---- the teaching message is on STDERR, never on stdout -----------------
#
# It is on stderr precisely so stdout stays byte-identical for
# anything reading it, and every known caller redirects stdout to /dev/null.
fresh
run add_version_min f
has_line "$T/err" "    printf 'minos if-absent 10.9\n' | drydock-macho-rewrite f f.new" \
    && ok "teaching message: on stderr" \
    || bad "teaching message" "not on stderr, or it no longer names FILE and OUT: $(cat "$T/err")"
# The teaching form is COMPLETE: drydock-macho-rewrite never writes its input, so the
# equivalent a reader is shown ends with the install step the wrapper does
# for itself. Without it the block would teach a command that leaves FILE
# untouched and a stray f.new beside it.
has_line "$T/err" '    mv -f f.new f' \
    && ok "teaching message: ... and it names the install step too" \
    || bad "teaching message" "no 'mv -f f.new f' line: $(cat "$T/err")"
grep -q 'minos if-absent' "$T/out" \
    && bad "teaching message" "leaked onto stdout: $(cat "$T/out")" \
    || ok "teaching message: not on stdout"

# ---- change_dylib -------------------------------------------------------
#
# ONE emitted command: stdout must be byte-identical to what mr_apply_image
# printed for the C tool, which is the same thing the bare form prints for
# the same file and statements. Asserted by running both and comparing, rather
# than by pinning a transcript that a different fixture would invalidate.
# ONE LINE IS THE WRAPPER'S OWN, and this comparison accounts for it exactly
# rather than loosening: the wrapper -- which installed drydock-macho-rewrite's output over
# FILE -- appends "Updated FILE (N bytes)", which is the line mr_apply_file
# itself printed while the verbs still rewrote FILE. It used to RESHAPE
# drydock-macho-rewrite's own "Wrote OUT (N bytes)"; a script run has no such stdout line
# (it reports "OUT: written (N,NNN bytes)" on stderr), so the wrapper's line is
# APPENDED to drydock-macho-rewrite's stdout instead of substituted into it. Every other
# line, and the resulting bytes, must match.
fresh
run change_dylib f -change /usr/lib/libSystem.B.dylib '@loader_path/../S.dylib'
cdrc=$rc
cp "$T/out" "$T/cd.out"
cdsha=$(sha "$T/f")
fresh
( cd "$T" && printf 'dylib replace /usr/lib/libSystem.B.dylib %s\n' \
    '@loader_path/../S.dylib' | "$BIN/drydock-macho-rewrite" f f.mtout ) >"$T/mt.out" 2>/dev/null
mtsha=$(sha "$T/f.mtout")
{ cat "$T/mt.out"; printf 'Updated f (%s bytes)\n' "$(wc -c < "$T/f.mtout" | tr -d ' ')"; } >"$T/mt.want"
[ "$cdrc" -eq 0 ] && cmp -s "$T/cd.out" "$T/mt.want" && [ "$cdsha" = "$mtsha" ] \
    && ok "change_dylib: a single-family run is byte-identical to drydock-macho-rewrite's, stdout included" \
    || bad "change_dylib single-family" "exit $cdrc; stdout or bytes differ from drydock-macho-rewrite dylib's; wrapper said [$(cat "$T/cd.out")] want [$(cat "$T/mt.want")]"

# MORE THAN ONE FAMILY is ONE `drydock-macho-rewrite edit FILE <temp> -`, and what
# these two assert is that NOTHING IS LEFT beside FILE afterwards and that every
# line drydock-macho-rewrite printed names FILE. Not that no temp is created -- one is, and
# always was: it used to be a copy of FILE that a SEQUENCE of commands was run
# against (`.FILE.macho9-compat.PID`), and it is now the output the one command
# writes and mw_finish installs, under that same name. The difference the first
# assertion is about is that the name must not SURVIVE; the difference the
# second is about is that drydock-macho-rewrite is handed FILE as its input and so labels its
# progress lines with FILE, where the copy-aside sequence labelled them with the
# copy.
# In a directory of its OWN, holding nothing but FILE, so "nothing new
# appeared" is exact: run in $T and a stray left by one of the many earlier
# change_dylib invocations here would already be in the before-listing and
# this would see nothing. Whole-listing equality rather than a search for a
# name -- it is the stronger question, and `grep -vxF` with a multi-line
# pattern list is unusable on this platform's BSD grep 2.5.1, which drops a
# pattern another pattern is a prefix of (so `.` in the list stops `..` from
# matching).
rm -rf "$T/stray"; mkdir "$T/stray"
cp "$FIXTURE" "$T/stray/f"
stray_before=$(ls -a "$T/stray")
( cd "$T/stray" && "$BIN/change_dylib" f -strip-lc uuid \
    -change /usr/lib/libSystem.B.dylib '@loader_path/../S.dylib' ) >"$T/out" 2>"$T/err"
cdmixrc=$?
[ "$cdmixrc" -eq 0 ] && [ "$(ls -a "$T/stray")" = "$stray_before" ] \
    && ok "change_dylib: a multi-family run leaves no stray file beside FILE" \
    || bad "change_dylib multi-family strays" "exit $cdmixrc; the directory holds [$(ls -a "$T/stray" | tr '\n' ' ')], was [$(printf '%s\n' "$stray_before" | tr '\n' ' ')]"
[ -s "$T/out" ] && ! grep -q 'drydock-macho-rewrite-compat' "$T/out" && grep -q '^f: ' "$T/out" \
    && ok "change_dylib: a multi-family run's stdout names FILE, not a copy" \
    || bad "change_dylib multi-family stdout" "stdout: $(cat "$T/out")"
rm -rf "$T/stray"

# A BACKSLASH IN THE PATH. The temp mw_prepare names is derived from the
# caller's own path, so its name is the caller's to choose -- and the filter
# that suppresses drydock-macho-rewrite's "Wrote <temp> (N bytes)" line has to compare against
# that name exactly. It once did not: passing the prefix to awk with `-v` ran it
# through awk's string-escape processing, so for a path containing a backslash
# awk looked for something the line does not start with and the stray line
# reached stdout, naming a temp no caller has heard of and breaking the
# byte-identical claim the assertion above makes. Both wrappers here go through
# the SAME shared mw_run_to_tmp, so one of them would have been enough to catch
# it; both are asserted because both leaked.
rm -rf "$T/bs"; mkdir "$T/bs" "$T/bs/back\slash"
cp "$FIXTURE" "$T/bs/back\slash/f"; cp "$FIXTURE" "$T/bs/back\slash/g"
strip_vm "$T/bs/back\slash/g"
( cd "$T/bs" && "$BIN/change_dylib" 'back\slash/f' -strip-lc uuid ) >"$T/bs.out" 2>"$T/bs.err"
bsrc=$?
[ "$bsrc" -eq 0 ] && ! grep -q '^Wrote ' "$T/bs.out" \
    && has_line "$T/bs.out" 'Updated back\slash/f (8528 bytes)' \
    && ok "change_dylib: a path containing a backslash still suppresses the temp-naming line" \
    || bad "change_dylib backslash path" "exit $bsrc, stdout: $(cat "$T/bs.out")"
( cd "$T/bs" && "$BIN/add_version_min" 'back\slash/g' ) >"$T/bs2.out" 2>"$T/bs2.err"
bsrc2=$?
[ "$bsrc2" -eq 0 ] && ! grep -q '^Wrote ' "$T/bs2.out" \
    && ok "add_version_min: ... and so does every other wrapper on the shared path" \
    || bad "add_version_min backslash path" "exit $bsrc2, stdout: $(cat "$T/bs2.out")"
# The teaching message reaches awk the same way, for command COUNTING and for
# indenting the block, so it is measured on the same path rather than assumed.
grep -qF "    printf 'allow-unmatched\\nload-command delete uuid" "$T/bs.err" \
    && ok "change_dylib: ... and the teaching block is still indented and counted" \
    || bad "change_dylib backslash path" "teaching message: $(cat "$T/bs.err")"
rm -rf "$T/bs"

# EVERY -insert GOES TO THE FRONT, so as ONE batch `-insert A -insert B` leaves
# A at ordinal 1 and B at ordinal 2. Reaching that through a SEQUENCE of
# statements takes emitting them backwards, which is what compat/translate.sh
# does and tests/translate_test.sh pins as text; this is the same claim
# measured on a real binary, through the wrapper, on the path that emits an
# edit script (-strip-lc makes it a second family).
fresh
run change_dylib f -insert /A -insert /B -strip-lc uuid
cdins_rc=$rc
cdins=$( ( cd "$T" && "$BIN/drydock-macho-rewrite" info f ) 2>/dev/null )
[ "$cdins_rc" -eq 0 ] \
    && printf '%s\n' "$cdins" | grep -qxF '  ordinal=1 path=/A' \
    && printf '%s\n' "$cdins" | grep -qxF '  ordinal=2 path=/B' \
    && ok "change_dylib: -insert A -insert B leaves A at ordinal 1 and B at ordinal 2" \
    || bad "change_dylib insert order" "exit $cdins_rc; ordinals: $(printf '%s\n' "$cdins" | sed -n 's/^  \(ordinal=[0-9]* path=.*\)$/\1/p' | tr '\n' ' ')"

# AN UNWRITABLE FILE IS REFUSED, ON BOTH PATHS, WITH THE SAME ANSWER.
# change_dylib open()ed FILE O_RDWR before it looked at anything, so mode 444
# failed immediately having changed nothing. NO drydock-macho-rewrite COMMAND STILL DOES THAT:
# a verb that writes an output opens FILE O_RDONLY, and `drydock-macho-rewrite edit` installs
# by mkstemp+rename beside FILE -- which needs the DIRECTORY writable and never
# consults FILE's mode, so without the wrapper's check a read-only binary is
# silently replaced (exit 0, fresh inode). mw_prepare is that check, on both
# paths. BYTES AND INODE, not just the exit code: a rename-based rewrite
# preserves the mode, so mode alone would not show it happened.
#
# EXIT 1, AND THESE TWO ASSERTIONS USED TO REQUIRE 2. The authority for a
# compat wrapper's failure code is THE C TOOL, not drydock-macho-rewrite's numbering: every
# change_dylib failure row in tests/compat-matrix.tsv -- the frozen measurement
# of the six tools as C binaries -- is a flat 1. The 2 came from a narrow guard
# added while the single-family path still inherited mr_apply_file's own
# open(O_RDWR) failure, i.e. drydock-macho-rewrite's code for an operational failure; that
# guard is gone and mw_prepare, which every other wrapper on this install path
# already uses, answers with the C tool's 1.
for cd_ro_args in "-strip-lc uuid" "-strip-lc uuid -change /usr/lib/libSystem.B.dylib /x/y.dylib"; do
    fresh
    chmod 444 "$T/f"
    cd_ro_sha=$(sha "$T/f"); cd_ro_ino=$(stat -f '%i' "$T/f")
    # shellcheck disable=SC2086
    run change_dylib f $cd_ro_args
    cd_ro_rc=$rc
    chmod 644 "$T/f"
    case $cd_ro_args in *-change*) cd_ro_which="multi-family" ;; *) cd_ro_which="single-family" ;; esac
    [ "$cd_ro_rc" -eq 1 ] && grep -qxF 'open: Permission denied' "$T/err" \
        && [ "$(sha "$T/f")" = "$cd_ro_sha" ] && [ "$(stat -f '%i' "$T/f")" = "$cd_ro_ino" ] \
        && ok "change_dylib: a $cd_ro_which run on an unwritable FILE exits 1 (the C tool's only failure code), saying so, having changed neither its bytes nor its inode" \
        || bad "change_dylib unwritable ($cd_ro_which)" "exit $cd_ro_rc (want 1, the C tool's flat failure code), bytes changed=$([ "$(sha "$T/f")" = "$cd_ro_sha" ] && echo no || echo YES), inode changed=$([ "$(stat -f '%i' "$T/f")" = "$cd_ro_ino" ] && echo no || echo YES), stderr: $(cat "$T/err")"
done

# An ABSENT FILE is refused by the same check, and for the same reason it is
# now 1 rather than 2: that is what the C tool's open() failure exited with.
# The message is the C tool's own perror("open") text, which mw_require_writable
# reproduces -- so a caller cannot tell the two apart, which is the point.
run change_dylib nosuchfile -strip-lc uuid -change A B
[ "$rc" -eq 1 ] && grep -qxF 'open: No such file or directory' "$T/err" \
    && ok "change_dylib: an absent FILE exits 1 with the C tool's own open() message" \
    || bad "change_dylib absent FILE" "exit $rc (want 1), stderr: $(cat "$T/err")"

# THE CLOSING "Updated FILE (N bytes)" LINE, ON BOTH PATHS, AND ONLY WHEN THE
# BYTES CHANGED. The C tool printed it from mr_apply_file, which no longer
# writes FILE, so the wrapper prints it after installing the temp. Both paths
# matter and for different reasons: a single-family run gets it where macho9
# used to print it, and a multi-family `macho9 edit` never printed it at all
# (nothing asserted the line at the time, which is how it went missing).
for cd_up_args in "-strip-lc uuid" "-strip-lc uuid -change /usr/lib/libSystem.B.dylib /x/y.dylib"; do
    fresh
    case $cd_up_args in *-change*) cd_up_which="multi-family" ;; *) cd_up_which="single-family" ;; esac
    # shellcheck disable=SC2086
    run change_dylib f $cd_up_args
    cd_up_rc=$rc
    cd_up_size=$(wc -c < "$T/f" | tr -d ' ')
    [ "$cd_up_rc" -eq 0 ] && has_line "$T/out" "Updated f ($cd_up_size bytes)" \
        && ok "change_dylib: a $cd_up_which run that changed the file ends with the C tool's Updated line" \
        || bad "change_dylib Updated ($cd_up_which)" "exit $cd_up_rc, stdout: $(cat "$T/out")"
done
# NOT PRINTED when nothing changed: the C tool wrote nothing and said nothing
# in that case, and this is what keeps the wrapper from announcing an install
# mw_finish decided against.
fresh
run change_dylib f -change /nope/absent.dylib /also/absent.dylib
[ "$rc" -eq 0 ] && ! grep -q '^Updated ' "$T/out" \
    && ok "change_dylib: a run that changed nothing prints no Updated line" \
    || bad "change_dylib Updated (no-op)" "exit $rc, stdout: $(cat "$T/out")"

# A HARD-LINKED FILE IS REFUSED (1) BY EVERY WRAPPER ON THE INSTALL PATH, which
# for these three is new: their C tools wrote through their own descriptor, so
# every name for the inode saw the change, while installing by mv would leave
# the siblings on the old content. add_version_min's own case is asserted
# above; these are the three whose verbs converted together. Each must refuse
# before running anything, leave BOTH names byte-identical, and leave no temp.
rm -rf "$T/hl"; mkdir "$T/hl"
hl_case() {   # hl_case TOOL ARG...
    hl_tool=$1; shift
    cp "$FIXTURE" "$T/hl/f"; ln "$T/hl/f" "$T/hl/f2"
    hl_sha=$(sha "$T/hl/f")
    hl_rc=0
    ( cd "$T/hl" && "$BIN/$hl_tool" f "$@" ) >"$T/hl.out" 2>"$T/hl.err" || hl_rc=$?
    [ "$hl_rc" -eq 1 ] && grep -q 'hard link' "$T/hl.err" \
        && [ "$(sha "$T/hl/f")" = "$hl_sha" ] && [ "$(sha "$T/hl/f2")" = "$hl_sha" ] \
        && ok "$hl_tool: a hard-linked FILE is refused (1), both names untouched" \
        || bad "$hl_tool hard link" "exit $hl_rc: $(cat "$T/hl.err")"
    ls -a "$T/hl" | grep -q 'drydock-macho-rewrite-compat' \
        && bad "$hl_tool hard link" "a temp file was left beside FILE" \
        || ok "$hl_tool: ... and no temp was left beside it"
    rm -f "$T/hl/f" "$T/hl/f2"
}
hl_case change_dylib -strip-lc uuid
hl_case change_dylib -strip-lc uuid -change /usr/lib/libSystem.B.dylib /x/y.dylib
hl_case fix_macho -change /usr/lib/libSystem.B.dylib /x/y.dylib
hl_case rename_segment __DATA __DATA_HL
rm -rf "$T/hl"

# A RUN drydock-macho-rewrite REFUSES LEAVES NO TEMP BESIDE FILE EITHER. The temp is made by
# the wrapper and written by drydock-macho-rewrite; a refusal means drydock-macho-rewrite never wrote it, and
# the wrapper's EXIT trap is what keeps the name from surviving. Measured in a
# directory of its own so "nothing new appeared" is exact, and with whole-
# listing equality rather than a grep, for the reason the stray-file assertion
# above gives.
rm -rf "$T/refused"; mkdir "$T/refused"
printf 'not a Mach-O at all, not even close\n' >"$T/refused/f"
refused_before=$(ls -a "$T/refused")
refused_rc=0
( cd "$T/refused" && "$BIN/change_dylib" f -strip-lc uuid ) >"$T/ref.out" 2>"$T/ref.err" \
    || refused_rc=$?
[ "$refused_rc" -ne 0 ] && [ "$(ls -a "$T/refused")" = "$refused_before" ] \
    && ok "change_dylib: a run drydock-macho-rewrite refuses leaves no temp beside FILE" \
    || bad "change_dylib refused strays" "exit $refused_rc; the directory holds [$(ls -a "$T/refused" | tr '\n' ' ')]"
rm -rf "$T/refused"

# EXIT CODES ARE FORWARDED, NOT MAPPED. change_dylib is one of only two
# wrappers here that hands the caller drydock-macho-rewrite's own number (compat/README.md,
# "change_dylib: exit codes"); fix_macho, patch_macho and rename_segment all
# collapse every nonzero to one historical code. drydock-macho-rewrite distinguishes a
# considered refusal (EX_REFUSED, 1 -- the image was examined and declined)
# from an operational failure (EX_FAIL, 2 -- the run could not be carried out
# at all), and this wrapper preserves that distinction rather than throwing it
# away. A DIRECTORY as FILE is the input that reaches a 2: mw_prepare's
# hard-link check is for regular files only and `test -w` says a directory is
# writable, so it falls through to drydock-macho-rewrite, whose read of it fails. The first
# assertion is what keeps the others honest -- if drydock-macho-rewrite ever stops
# answering 2 here, they are proving nothing and say so rather than passing
# quietly.
rm -rf "$T/cddir" "$T/cddir.new"; mkdir "$T/cddir"
cd_mt_rc=0
( cd "$T" && printf 'dylib replace /nope /also-nope\n' | "$BIN/drydock-macho-rewrite" cddir cddir.new ) \
    >/dev/null 2>"$T/err" || cd_mt_rc=$?
[ "$cd_mt_rc" -eq 2 ] \
    && ok "change_dylib: drydock-macho-rewrite's own code for this input is 2, an operational failure" \
    || bad "change_dylib exit forwarding" "drydock-macho-rewrite exited $cd_mt_rc, not 2, so the assertions below are proving nothing about forwarding -- find an input that still reaches EX_FAIL, or nothing here pins it at all"
run change_dylib cddir -change /nope /also-nope
[ "$rc" -eq 2 ] \
    && ok "change_dylib: a single-family run forwards drydock-macho-rewrite's own 2 rather than mapping it" \
    || bad "change_dylib exit forwarding (single-family)" "exit $rc, want 2: this wrapper maps nothing, so a caller of the most-called tool here can still tell a run that never happened from an image drydock-macho-rewrite read and declined -- collapsing both to 1 takes that away"
run change_dylib cddir -strip-lc uuid -change /nope /also-nope
[ "$rc" -eq 2 ] \
    && ok "change_dylib: ... and so does a multi-family run, whose code is the bare drydock-macho-rewrite form's own" \
    || bad "change_dylib exit forwarding (multi-family)" "exit $rc, want 2: me_run speaks the same MR_REFUSED/MR_FAIL vocabulary as every verb, so a mixed-family invocation must not be the one shape where the caller loses the distinction"
rm -rf "$T/cddir" "$T/cddir.new"
# THE OTHER HALF: a considered refusal is still the flat 1 the C tool always
# gave. Forwarding is only worth something if the two numbers really differ, so
# both are asserted on the same wrapper rather than one of them assumed.
printf 'not a Mach-O at all, not even close\n' >"$T/notmacho"
run change_dylib notmacho -strip-lc uuid
[ "$rc" -eq 1 ] \
    && ok "change_dylib: a considered refusal is still the flat 1 the C tool always gave" \
    || bad "change_dylib refusal code" "exit $rc, want 1: every change_dylib failure row in tests/compat-matrix.tsv is a 1, so a caller that has branched on 0-or-1 since 2024 must not start seeing a 2 for an image drydock-macho-rewrite simply declined"
rm -f "$T/notmacho"

# A REFUSAL PART WAY THROUGH A MULTI-STATEMENT RUN LEAVES FILE EXACTLY AS IT
# WAS. install.sh's production line is this shape -- two load-command deletes
# AND three dylib replacements in one invocation -- and splitting that one
# atomic rewrite into a SEQUENCE of drydock-macho-rewrite commands once cost two
# tests/compat-sweep.sh rows where the C tool refused having written nothing
# and the sequence refused having already written. It is one `drydock-macho-rewrite edit`
# now: me_run reads the image once, applies every statement in memory,
# verifies, and writes once. The -change below needs far more room than the
# fixture's header pad, and this copy is not PIE so the header cannot grow,
# so the run is refused at statement 2 of 2 -- after statement 1 was applied
# in memory.
rm -rf "$T/cdmid"; mkdir "$T/cdmid"
cp "$FIXTURE" "$T/cdmid/f"
unpie "$T/cdmid/f"
cd_mid_before=$(sha "$T/cdmid/f")
cd_huge="@loader_path/"
i=0
while [ $i -lt 500 ]; do cd_huge="${cd_huge}longlongl"; i=$((i + 1)); done
cd_huge="${cd_huge}.dylib"
cd_mid_rc=0
( cd "$T/cdmid" && "$BIN/change_dylib" f -strip-lc uuid \
    -change /usr/lib/libSystem.B.dylib "$cd_huge" ) \
    >"$T/cdmid.out" 2>"$T/cdmid.err" || cd_mid_rc=$?
[ "$cd_mid_rc" -eq 1 ] && [ "$(sha "$T/cdmid/f")" = "$cd_mid_before" ] \
    && ok "change_dylib: a refusal at a later statement leaves FILE byte-identical, not half-edited" \
    || bad "change_dylib mid-script refusal" "exit $cd_mid_rc and FILE $([ "$(sha "$T/cdmid/f")" = "$cd_mid_before" ] && echo 'is unchanged' || echo 'WAS MODIFIED'): install.sh's production line strips load commands AND rewrites dylib paths in one invocation, so a caller left holding statement 1 of a refused run has a binary nobody asked for; stderr: $(tail -1 "$T/cdmid.err")"
ls -a "$T/cdmid" | grep -q 'drydock-macho-rewrite-compat' \
    && bad "change_dylib mid-script refusal" "a temp was left beside FILE: [$(ls -a "$T/cdmid" | grep 'drydock-macho-rewrite-compat' | tr '\n' ' ')]" \
    || ok "change_dylib: ... and leaves no temp beside it"
# ...and the refusal is reported AS a refusal. The wrapper must stop on
# drydock-macho-rewrite's nonzero rather than fall through to mw_finish, whose mv of a temp
# drydock-macho-rewrite never wrote blames the INSTALL for a refusal that happened
# upstream. Both exit 1, so the diagnostic is the only difference a caller can
# see.
! grep -q 'the rewrite succeeded but installing it failed' "$T/cdmid.err" \
    && ok "change_dylib: ... and says the run was refused, not that installing it failed" \
    || bad "change_dylib mid-script refusal" "a refused run told the caller the rewrite succeeded and the install failed, which sends them looking at directory permissions for a refusal drydock-macho-rewrite made about their image: $(grep 'installing it failed' "$T/cdmid.err")"
rm -rf "$T/cdmid"

# AN INVOCATION THAT ASKS FOR NOTHING. `change_dylib FILE -grow -grow` is
# accepted (once argc is big enough) and names no operation, so
# compat/translate.sh emits no command at all -- tests/translate_test.sh's
# cd-grow-only pins that as text -- and there is no temp for drydock-macho-rewrite to write
# or for mw_finish to install. This wrapper's own guard is what stops there.
# The C tool ran an empty rewrite pass and printed its "header pad ..." and
# "nothing to change." lines (tests/compat-matrix.tsv's two no-command rows),
# so stdout IS a divergence here, recorded in compat/README.md; the exit code
# and the file are not divergences and must not become ones.
rm -rf "$T/cdnop"; mkdir "$T/cdnop"
cp "$FIXTURE" "$T/cdnop/f"
cd_nop_before=$(ls -a "$T/cdnop")
cd_nop_rc=0
( cd "$T/cdnop" && "$BIN/change_dylib" f -grow -grow ) \
    >"$T/cdnop.out" 2>"$T/cdnop.err" || cd_nop_rc=$?
[ "$cd_nop_rc" -eq 0 ] && [ ! -s "$T/cdnop.out" ] \
    && [ "$(sha "$T/cdnop/f")" = "$(sha "$FIXTURE")" ] \
    && [ "$(ls -a "$T/cdnop")" = "$cd_nop_before" ] \
    && ok "change_dylib: an invocation that asks for nothing exits 0, prints nothing, and leaves FILE alone" \
    || bad "change_dylib no-command run" "exit $cd_nop_rc, stdout [$(cat "$T/cdnop.out")], FILE $([ "$(sha "$T/cdnop/f")" = "$(sha "$FIXTURE")" ] && echo unchanged || echo MODIFIED), the directory holds [$(ls -a "$T/cdnop" | tr '\n' ' ')]: with no command emitted there is nothing to run, so falling through here means either a drydock-macho-rewrite invocation the caller never asked for or an install of a temp nothing wrote"
rm -rf "$T/cdnop"

# THE CAPACITY CAPS. Both cap sites in cli/drydock-macho-rewrite.c say the wrapper has to
# enforce them itself and print the ORIGIN wording, because drydock-macho-rewrite names its
# own flags (-append where change_dylib names -add). This is the assertion
# that the message a caller sees is still change_dylib's.
fresh
i=0; add33=''
while [ $i -lt 33 ]; do add33="$add33 -add P"; i=$((i + 1)); done
# shellcheck disable=SC2086
run change_dylib f $add33
[ "$rc" -eq 1 ] && grep -qxF 'too many -add (max 32)' "$T/err" \
    && ok "change_dylib: the -add cap refuses in change_dylib's own words" \
    || bad "change_dylib -add cap" "exit $rc, stderr: $(cat "$T/err")"
[ "$(sha "$T/f")" = "$(sha "$FIXTURE")" ] \
    && ok "change_dylib: the cap refuses before touching the file" \
    || bad "change_dylib -add cap" "the file was modified"

fresh
i=0; strip17=''
while [ $i -lt 17 ]; do strip17="$strip17 -strip-lc uuid"; i=$((i + 1)); done
# shellcheck disable=SC2086
run change_dylib f $strip17
[ "$rc" -eq 1 ] && grep -qxF 'too many -strip-lc (max 16)' "$T/err" \
    && ok "change_dylib: the -strip-lc cap refuses in change_dylib's own words" \
    || bad "change_dylib -strip-lc cap" "exit $rc, stderr: $(cat "$T/err")"

# An unknown flag, and an unknown -strip-lc KIND: the C tool's exact lines.
fresh
run change_dylib f -bogus x
[ "$rc" -eq 1 ] && grep -qxF 'bad arg: -bogus' "$T/err" \
    && ok "change_dylib: an unknown flag refuses in change_dylib's own words" \
    || bad "change_dylib unknown flag" "exit $rc, stderr: $(cat "$T/err")"
fresh
run change_dylib f -strip-lc no-such-kind
[ "$rc" -eq 1 ] && grep -qxF 'unknown -strip-lc kind: no-such-kind' "$T/err" \
    && ok "change_dylib: an unknown KIND refuses in change_dylib's own words" \
    || bad "change_dylib unknown KIND" "exit $rc, stderr: $(cat "$T/err")"

# `change_dylib FILE -grow` is `argc < 4`, so it is a USAGE error even though
# the usage text presents -grow as a standalone flag -- and the usage line
# names argv[0], exactly as the C tool's did.
fresh
run change_dylib f -grow
cd_usage="Usage: $BIN/change_dylib input [-grow] [-change old new] [-delete path] [-reexport path] [-add path] [-insert path] [-strip-lc name] [-change-rpath old new] [-delete-rpath path] [-add-rpath path] ..."
[ "$rc" -eq 1 ] && firstline_is "$T/err" "$cd_usage" \
    && ok "change_dylib: -grow alone is a usage error naming argv[0]" \
    || bad "change_dylib -grow alone" "exit $rc, stderr: $(head -1 "$T/err")"

# ---- patch_macho --------------------------------------------------------
#
# EXIT CODES ARE MAPPED. `drydock-macho-rewrite declassify` returns EX_REFUSED (1) where it
# examined the input and declined, and EX_FAIL (2) for an operational
# failure; patch_macho returned a flat 1 for everything. A caller that
# tested `!= 0` is unaffected either way, but tests/leaf-tool-crashes.sh
# tests for exactly 1. An absent IN is the operational-failure case --
# declassify cannot even open it, so it exits EX_FAIL (2), not EX_REFUSED --
# and is the one here where the mapping actually changes a number.
run patch_macho nosuchfile out
[ "$rc" -eq 1 ] \
    && ok "patch_macho: an absent IN maps drydock-macho-rewrite's EX_FAIL back to a flat 1" \
    || bad "patch_macho absent IN" "exit $rc, want 1"

fresh
printf 'not a mach-o at all\n' > "$T/nm"
run patch_macho nm out
[ "$rc" -eq 1 ] \
    && ok "patch_macho: a non-Mach-O input exits 1, not 2" \
    || bad "patch_macho non-Mach-O" "exit $rc, want 1"

# THE PASS-THROUGH's stdout. drydock-macho-rewrite names the file it wrote even when it only
# copied it; patch_macho never did. The wrapper drops that one line -- and
# only that one, and only on this path.
fresh
run patch_macho f o
[ "$rc" -eq 0 ] && grep -q '^Already patched' "$T/out" && ! grep -q '^Wrote ' "$T/out" \
    && ok "patch_macho: the pass-through prints no 'Wrote ...' line" \
    || bad "patch_macho pass-through" "exit $rc, stdout: $(cat "$T/out")"
cmp -s "$T/f" "$T/o" \
    && ok "patch_macho: the pass-through output is the input, byte for byte" \
    || bad "patch_macho pass-through" "output differs from input"

# THE FOURTH OBSERVABLE: OUT's MODE. patch_macho created OUT with
# open(argv[2], O_WRONLY|O_CREAT|O_TRUNC, 0755); `drydock-macho-rewrite declassify` writes OUT
# through wa_write_new, which gives it the INPUT's mode and always a new inode.
# The wrapper installs drydock-macho-rewrite's output onto OUT with `mv` -- atomic, like every
# other wrapper on the install path -- after chmod'ing it to the mode the C tool
# would have left: `0755 & ~umask` for an OUT that did not exist, and OUT's own
# current mode for one that did (open() changes neither). Every expected mode
# here was measured against the pre-wrapper binary.
#
# WHAT THE ATOMIC INSTALL TRADES AWAY, and it is asserted below rather than
# described: OUT's INODE. `cat TEMP > OUT` kept it (and with it OUT's hard links
# and xattrs); `mv` cannot, so an OUT with other hard links is REFUSED instead of
# silently split -- the one new behaviour, shared with all five other wrappers.
#
# `stat -f` with an explicit format is a machine-readable request, not
# human-readable output being parsed -- same category as this file's
# `od -An -tx1`, and it is BSD stat, which every macOS has.
mode_of() { stat -f '%Lp' "$1"; }
ino_of()  { stat -f '%i' "$1"; }

# 1. a FRESH OUT takes 0755 masked by the umask, not a bare 0755 and not IN's
#    mode (which is what drydock-macho-rewrite alone would give it).
fresh
chmod 640 "$T/f"
rm -f "$T/o"
( cd "$T" && umask 077 && "$BIN/patch_macho" f o ) >/dev/null 2>&1
[ "$(mode_of "$T/o")" = 700 ] \
    && ok "patch_macho: a fresh OUT gets 0755 masked by the umask (0700 under 077)" \
    || bad "patch_macho fresh mode" "mode $(mode_of "$T/o"), want 700"
fresh
chmod 640 "$T/f"
rm -f "$T/o"
( cd "$T" && umask 022 && "$BIN/patch_macho" f o ) >/dev/null 2>&1
[ "$(mode_of "$T/o")" = 755 ] \
    && ok "patch_macho: and 0755 under umask 022, not the input's own mode" \
    || bad "patch_macho fresh mode" "mode $(mode_of "$T/o"), want 755"

# 2. an EXISTING OUT keeps its own mode -- open() did not change one, so the
#    wrapper chmods the temp to it before installing. Its INODE is new: that is
#    the `mv`, and it is what makes OUT wholly old or wholly new rather than
#    half-written.
fresh
: > "$T/o"; chmod 600 "$T/o"; before_ino=$(ino_of "$T/o")
run patch_macho f o
[ "$rc" -eq 0 ] && [ "$(mode_of "$T/o")" = 600 ] \
    && ok "patch_macho: an existing OUT keeps its mode" \
    || bad "patch_macho existing OUT" "exit $rc, mode $(mode_of "$T/o"), want 600"
[ "$(ino_of "$T/o")" != "$before_ino" ] \
    && ok "patch_macho: ... and is installed atomically, so its inode is new" \
    || bad "patch_macho existing OUT" "inode unchanged -- the install was not a rename"

# 3. IN == OUT still converts IN, which the C tool allowed and `drydock-macho-rewrite
#    declassify` now refuses outright: the wrapper is what provides it, running
#    drydock-macho-rewrite into a temp beside OUT so drydock-macho-rewrite itself never sees OUT == IN. This
#    fixture is already converted, so the pass-through's bytes are IN's own and
#    mw_finish installs nothing at all -- mode AND inode survive, exactly as
#    they did when the C tool wrote through the path.
fresh
chmod 640 "$T/f"; before_ino=$(ino_of "$T/f"); before_sha=$(sha "$T/f")
run patch_macho f f
[ "$rc" -eq 0 ] && [ "$(mode_of "$T/f")" = 640 ] && [ "$(sha "$T/f")" = "$before_sha" ] \
    && ok "patch_macho: IN == OUT still converts IN, keeping its mode" \
    || bad "patch_macho IN == OUT" "exit $rc, mode $(mode_of "$T/f"), bytes changed=$([ "$(sha "$T/f")" = "$before_sha" ] && echo no || echo YES)"
[ "$(ino_of "$T/f")" = "$before_ino" ] \
    && ok "patch_macho: ... and an unchanged pass-through installs nothing, so the inode stands" \
    || bad "patch_macho IN == OUT" "the inode changed even though the bytes did not"

# 3b. A HARD-LINKED OUT IS REFUSED (1), both names untouched -- the wrapper's
#     own refusal, before drydock-macho-rewrite runs. The C tool wrote through OUT's path and
#     every link saw the new content; `mv` would leave the siblings on the old
#     content, so this is refused rather than silently split. Same refusal every
#     other wrapper on the install path makes, from the same mw_prepare.
rm -rf "$T/pmhl"; mkdir "$T/pmhl"
cp "$FIXTURE" "$T/pmhl/o"; ln "$T/pmhl/o" "$T/pmhl/o2"
cp "$FIXTURE" "$T/pmhl/in"
pmhl_sha=$(sha "$T/pmhl/o")
pmhl_rc=0
( cd "$T/pmhl" && "$BIN/patch_macho" in o ) >"$T/pmhl.out" 2>"$T/pmhl.err" || pmhl_rc=$?
[ "$pmhl_rc" -eq 1 ] && grep -q 'hard link' "$T/pmhl.err" \
    && [ "$(sha "$T/pmhl/o")" = "$pmhl_sha" ] && [ "$(sha "$T/pmhl/o2")" = "$pmhl_sha" ] \
    && ok "patch_macho: a hard-linked OUT is refused (1), both names untouched" \
    || bad "patch_macho hard-linked OUT" "exit $pmhl_rc: $(cat "$T/pmhl.err")"
ls -a "$T/pmhl" | grep -q 'drydock-macho-rewrite-compat' \
    && bad "patch_macho hard-linked OUT" "a temp file was left beside OUT" \
    || ok "patch_macho: ... and no temp was left beside it"
rm -rf "$T/pmhl"

# 4. an existing OUT that is not writable FAILS, even where the directory is --
#    the C tool's open(O_WRONLY) failed on it, and mw_prepare's pre-check
#    answers for it now, in the words every wrapper's pre-check uses (the C
#    tool's own perror said "create output: Permission denied"; only the label
#    differs). Exit 1 either way, which is all a caller ever saw.
fresh
: > "$T/o"; chmod 444 "$T/o"
run patch_macho f o
[ "$rc" -eq 1 ] && grep -q 'Permission denied' "$T/err" \
    && ok "patch_macho: an unwritable existing OUT fails, as open(O_WRONLY) did" \
    || bad "patch_macho unwritable OUT" "exit $rc (want 1), stderr: $(cat "$T/err")"
[ "$(wc -c < "$T/o" | tr -d ' ')" = 0 ] \
    && ok "patch_macho: ... and the unwritable OUT was not touched" \
    || bad "patch_macho unwritable OUT" "OUT was written anyway"
chmod 644 "$T/o"; rm -f "$T/o"

# 5. a fresh OUT that cannot be created, because its directory is not writable.
#    The temp drydock-macho-rewrite writes lives beside OUT, so drydock-macho-rewrite's own mkstemp is what
#    fails and what reports, and the wrapper maps its EX_FAIL to patch_macho's
#    flat 1. The perror the C tool printed must still be there, EXACTLY ONCE --
#    twice would mean the wrapper ran the conversion a second time -- and no
#    line may come from the SHELL, which is what would show up if the emitted
#    pipeline were not valid text for it. (drydock-macho-rewrite narrates the statement and
#    names the temp it could not write around that perror now; that is its
#    report, not a shell diagnostic.) Re-run under ksh because every wrapper
#    must behave the same under both shells.
fresh
rm -rf "$T/ro"; mkdir "$T/ro"; chmod 555 "$T/ro"
for pm_sh in /bin/sh /bin/ksh; do
    [ -x "$pm_sh" ] || { skip "patch_macho: uncreatable OUT under $pm_sh" "no such shell"; continue; }
    ( cd "$T" && "$pm_sh" "$BIN/patch_macho" f ro/out ) >"$T/out" 2>"$T/err"
    rc=$?
    # The teaching message is two lines; drydock-macho-rewrite's own report is the rest.
    sed '1,2d' "$T/err" > "$T/err.rest"
    [ "$rc" -eq 1 ] \
        && [ "$(grep -c -xF 'mkstemp: Permission denied' "$T/err.rest")" = 1 ] \
        && ! grep -q "$pm_sh" "$T/err.rest" \
        && ok "patch_macho: an uncreatable OUT reports once, and exits 1 ($pm_sh)" \
        || bad "patch_macho uncreatable OUT ($pm_sh)" "exit $rc, stderr after the teaching message: $(cat "$T/err.rest")"
    [ ! -e "$T/ro/out" ] \
        && ok "patch_macho: ... and created nothing ($pm_sh)" \
        || bad "patch_macho uncreatable OUT ($pm_sh)" "OUT exists after a failed run"
done
chmod 755 "$T/ro"; rm -rf "$T/ro"

# The C tools wrote through FILE's own descriptor; an install by mv needs the directory writable.
for ro_case in 'rename_segment 1 ro/f __DATA __DATB' \
               'change_dylib 2 ro/f -change /usr/lib/libSystem.B.dylib /usr/lib/libSystem.C.dylib' \
               'add_version_min 2 ro/f' \
               'fix_macho 1 ro/f -rename_seg __DATA __DATB' \
               'retag_swift_classes 1 ro/f' \
               'patch_macho 1 ro/f ro/f'; do
    set -- $ro_case; ro_tool=$1; ro_want=$2; shift 2
    rm -rf "$T/ro"; mkdir "$T/ro"; cp "$FIXTURE" "$T/ro/f"; chmod 555 "$T/ro"
    ro_before=$(sha "$T/ro/f")
    run "$ro_tool" "$@"
    ro_ls=$(ls -A "$T/ro")
    chmod 755 "$T/ro"
    [ "$rc" -eq "$ro_want" ] && grep -q -xF 'mkstemp: Permission denied' "$T/err" \
        && [ "$(sha "$T/ro/f")" = "$ro_before" ] && [ "$ro_ls" = f ] \
        && ok "$ro_tool: a writable FILE in a read-only directory fails ($ro_want), untouched, no temp left" \
        || bad "$ro_tool read-only directory" "exit $rc (want $ro_want), dir: $ro_ls, stderr: $(cat "$T/err")"
done
rm -rf "$T/ro"

# 5b. AN OUT THAT IS A DIRECTORY is refused, in the C tool's own perror words.
#     Neither layer below would refuse it: drydock-macho-rewrite writes a temp BESIDE OUT and
#     never looks at OUT, and `mv` given a directory destination moves the temp
#     INTO it and succeeds -- exit 0, with `adir/.adir.drydock-macho-rewrite-compat.PID`
#     created and nothing the caller asked for. Measured before these guards
#     existed -- BOTH of them, since either one alone still refuses a directory
#     (the `-e && ! -f` check catches it; what the `-d` check adds is the C
#     tool's own EISDIR wording, which is what this asserts).
fresh
rm -rf "$T/adir"; mkdir "$T/adir"
adir_before=$(ls -a "$T/adir")
run patch_macho f adir
[ "$rc" -eq 1 ] && grep -qxF 'create output: Is a directory' "$T/err" \
    && [ "$(ls -a "$T/adir")" = "$adir_before" ] \
    && ok "patch_macho: an OUT that is a directory is refused (1), as open() did" \
    || bad "patch_macho directory OUT" "exit $rc, stderr: $(cat "$T/err")"
rm -rf "$T/adir"

printf 'not a mach-o at all\n' > "$T/nm"
rm -rf "$T/adir"; mkdir "$T/adir"
run patch_macho nm adir
[ "$rc" -eq 1 ] && grep -qxF 'create output: Is a directory' "$T/err" \
    && ! grep -q 'not a readable 64-bit Mach-O' "$T/err" \
    && ok "patch_macho: with a bad IN and a directory as OUT, the directory is the one named" \
    || bad "patch_macho both bad" "exit $rc, stderr: $(cat "$T/err")"
rm -rf "$T/adir"

rm -f "$T/pmro"; : > "$T/pmro"; chmod 444 "$T/pmro"
run patch_macho nm pmro
[ "$rc" -eq 1 ] && grep -q 'not a readable 64-bit Mach-O' "$T/err" \
    && ! grep -q 'Permission denied' "$T/err" \
    && ok "patch_macho: with a bad IN and an unwritable OUT, IN is the one named" \
    || bad "patch_macho bad IN, unwritable OUT" "exit $rc, stderr: $(cat "$T/err")"
rm -f "$T/pmro" "$T/nm"

# A dangling symlink at OUT is refused; the C tool created the link's target.
fresh
rm -f "$T/pmdangle" "$T/pmnowhere"; ln -s pmnowhere "$T/pmdangle"
run patch_macho f pmdangle
[ "$rc" -eq 1 ] && [ -L "$T/pmdangle" ] && [ ! -e "$T/pmnowhere" ] \
    && ok "patch_macho: a dangling symlink as OUT is refused (1), and its target is not created" \
    || bad "patch_macho dangling OUT" "exit $rc, stderr: $(cat "$T/err")"
rm -f "$T/pmdangle" "$T/pmnowhere"

# The background writer lets a regression that reads the fifo finish, not hang.
fresh
rm -f "$T/pmfifo"; mkfifo "$T/pmfifo"
( : > "$T/pmfifo" ) 2>/dev/null & pm_w=$!
run patch_macho f pmfifo
kill "$pm_w" 2>/dev/null || true; wait "$pm_w" 2>/dev/null || true
[ "$rc" -eq 1 ] && [ -p "$T/pmfifo" ] && grep -qF 'pmfifo is not a regular file' "$T/err" \
    && ok "patch_macho: a fifo as OUT is refused (1), and left a fifo" \
    || bad "patch_macho fifo OUT" "exit $rc, stderr: $(cat "$T/err")"
rm -f "$T/pmfifo"

# 5c. AN OUT WHOSE NAME BEGINS WITH A DASH is still a file name, as it was for
#     the C tool's open(). `drydock-macho-rewrite declassify` refuses such an OUT now
#     (bad_out, since `-flag`-looking positionals are the mistake its own
#     grammar change invites), and the wrapper is unaffected because the OUT it
#     hands drydock-macho-rewrite is the temp -- whose name starts with a dot. Pinned so that
#     refusal cannot migrate down here, where it would break a caller the C tool
#     served.
fresh
rm -f "$T/-dashout"
run patch_macho f -dashout
[ "$rc" -eq 0 ] && cmp -s "$T/f" "$T/-dashout" \
    && ok "patch_macho: an OUT beginning with a dash is a file name, as open() had it" \
    || bad "patch_macho dashed OUT" "exit $rc, stderr: $(cat "$T/err")"
rm -f "$T/-dashout"

# 6. THE INSTALL LEAVES NOTHING BEHIND, on the path that succeeds: the temp
#    beside OUT is mv'd or removed, never left. Measured in a directory of its
#    own, by whole-listing equality, for the reason the change_dylib stray-file
#    assertion above gives.
rm -rf "$T/pmdir"; mkdir "$T/pmdir"
cp "$FIXTURE" "$T/pmdir/in"
pmdir_before=$(ls -a "$T/pmdir")
pmdir_rc=0
( cd "$T/pmdir" && "$BIN/patch_macho" in out ) >"$T/pmdir.out" 2>"$T/pmdir.err" || pmdir_rc=$?
pmdir_want=$(printf '%s\nout\n' "$pmdir_before" | LC_ALL=C sort)
[ "$pmdir_rc" -eq 0 ] && [ "$(ls -a "$T/pmdir" | LC_ALL=C sort)" = "$pmdir_want" ] \
    && ok "patch_macho: a successful run creates OUT and nothing else" \
    || bad "patch_macho strays" "exit $pmdir_rc; the directory holds [$(ls -a "$T/pmdir" | tr '\n' ' ')]"
rm -rf "$T/pmdir"

# ---- patch_macho, THE CONVERTING PATH -----------------------------------
#
# Everything above hands patch_macho tests/fixture.macho, a real 10.9 binary
# that is already converted -- so all of it exercises the PASS-THROUGH, where
# md_declassify copies its input, the wrapper prints no `Wrote OUT` line (the C
# tool printed none either) and, for IN == OUT, mw_finish installs nothing
# because the bytes match. Two things patch_macho exists to do were therefore
# asserted nowhere at all, and each was measured to leave EVERY suite in this
# repo green when deleted: the wrapper's own `Wrote OUT (N bytes)` line, and the
# IN == OUT install. mkchained_fixture is what closes that -- an input that
# really carries chained fixups, on any host, so the conversion runs here on
# 10.9 rather than only where tests/chained-fixups.sh does not SKIP.
#
# The install's own mechanics -- OUT's mode, its new inode, the hard-link
# refusal, no strays -- are the same wrapper code on either path and are already
# covered above (cases 1, 2, 3b and 6, all of which really chmod and mv, since
# case 2's OUT is empty and so differs from what drydock-macho-rewrite wrote). What follows is
# only what the pass-through cannot reach.

# A. THE CONVERTING PATH'S STDOUT. `Wrote OUT (N bytes)` is patch_macho's own
#    closing line, printed by the wrapper: drydock-macho-rewrite's stdout names no file.
mkchained_fixture "$T/cf"
run patch_macho cf cfout
cf_n=$(wc -c < "$T/cfout" 2>/dev/null | tr -d ' ')
[ "$rc" -eq 0 ] \
    && ok "patch_macho: the converting path exits 0" \
    || bad "patch_macho converting" "exit $rc: $(cat "$T/err")"
[ "$(sed -n '$p' "$T/out")" = "Wrote cfout ($cf_n bytes)" ] \
    && ok "patch_macho: ... and its last stdout line names OUT and OUT's size" \
    || bad "patch_macho converting stdout" "last line is [$(sed -n '$p' "$T/out")], want [Wrote cfout ($cf_n bytes)]"
[ "$(grep -c '^Wrote ' "$T/out" | tr -d ' ')" = 1 ] \
    && ok "patch_macho: ... and exactly one 'Wrote ' line" \
    || bad "patch_macho converting stdout" "$(grep -c '^Wrote ' "$T/out") 'Wrote ' lines: $(cat "$T/out")"
grep -q '^Added LC_DYLD_INFO_ONLY:' "$T/out" && ! grep -q '^Already patched' "$T/out" \
    && ok "patch_macho: ... and md_declassify's own lines still come through" \
    || bad "patch_macho converting stdout" "not the converting transcript: $(cat "$T/out")"

# THE DECLARATION SURVIVES. The C tool dropped mkchained's LC_BUILD_VERSION
# (macOS, 12.0, sdk 12.0) and left no version command. As install.sh runs the
# two, add_version_min then appended 10.9, sdk 10.9; now it finds 12.0 present.
[ "$("$BIN/drydock-macho-rewrite" info "$T/cfout" | grep -c '^LC\[[0-9]*\] LC_VERSION_MIN_MACOSX ')" = 1 ] \
    && "$BIN/drydock-macho-rewrite" info "$T/cfout" | grep -qxF '  version=12.0.0 sdk=12.0.0' \
    && ok "patch_macho: ... and OUT keeps the build-version's minimum and sdk as one LC_VERSION_MIN_MACOSX" \
    || bad "patch_macho keeps the declaration" "$("$BIN/drydock-macho-rewrite" info "$T/cfout" | grep -A1 VERSION)"
cp "$T/cfout" "$T/cfpipe"
run add_version_min cfpipe
[ "$rc" -eq 0 ] && "$BIN/drydock-macho-rewrite" info "$T/cfpipe" | grep -qxF '  version=12.0.0 sdk=12.0.0' \
    && ok "patch_macho then add_version_min: the binary declares the build-version's minimum and sdk, not 10.9" \
    || bad "patch_macho then add_version_min" "exit $rc: $("$BIN/drydock-macho-rewrite" info "$T/cfpipe" | grep -A1 VERSION)"

# THE INSTALLED BYTES ARE THE CONVERTED ONES. tests/cli_test.sh compares the two
# FRONT-ENDS' output for the same input (its byte-identity assertion); these two
# are about the INSTALL -- that what lands at OUT is what drydock-macho-rewrite wrote, and is
# not the input copied through. That cli_test assertion was the ONLY thing in the
# repo that noticed a wrapper installing the unconverted bytes, which is a lot to
# rest on one front-end-parity check.
( cd "$T" && printf 'fixups set classic\n' | "$BIN/drydock-macho-rewrite" cf cf.mt ) >/dev/null 2>&1
cmp -s "$T/cfout" "$T/cf.mt" \
    && ok "patch_macho: the bytes installed at OUT are drydock-macho-rewrite's converted output" \
    || bad "patch_macho converting bytes" "OUT differs from drydock-macho-rewrite declassify's output"
! cmp -s "$T/cfout" "$T/cf" \
    && ok "patch_macho: ... and not the input copied through" \
    || bad "patch_macho converting bytes" "OUT is byte-identical to the unconverted input"

# B. IN == OUT ON THE CONVERTING PATH, the historical form the C tool allowed
#    and `drydock-macho-rewrite declassify` now refuses -- so the wrapper is the whole of it.
#    Here the bytes DO change, so mw_finish really installs: the complement of
#    case 3's pass-through, where it must install nothing. A run that skipped the
#    install would leave IN unconverted and pass every other assertion here.
rm -rf "$T/csdir"; mkdir "$T/csdir"
mkchained_fixture "$T/csdir/cs"
# What the conversion of THIS file is, from the other front-end, so the
# comparison below does not lean on two mkchained runs producing equal bytes.
( cd "$T/csdir" && printf 'fixups set classic\n' | "$BIN/drydock-macho-rewrite" cs cs.want ) >/dev/null 2>&1
chmod 640 "$T/csdir/cs"
cs_ino=$(ino_of "$T/csdir/cs")
cs_rc=0
( cd "$T/csdir" && "$BIN/patch_macho" cs cs ) >"$T/cs.out" 2>"$T/cs.err" || cs_rc=$?
cs_n=$(wc -c < "$T/csdir/cs" | tr -d ' ')
[ "$cs_rc" -eq 0 ] && cmp -s "$T/csdir/cs" "$T/csdir/cs.want" \
    && ok "patch_macho: IN == OUT converts IN in place, to drydock-macho-rewrite's own bytes" \
    || bad "patch_macho IN == OUT converting" "exit $cs_rc, or IN was not converted: $(cat "$T/cs.err")"
[ "$(ino_of "$T/csdir/cs")" != "$cs_ino" ] \
    && ok "patch_macho: ... installed by rename, so the inode is new when the bytes change" \
    || bad "patch_macho IN == OUT converting" "the inode stands -- the install did not happen"
[ "$(mode_of "$T/csdir/cs")" = 640 ] \
    && ok "patch_macho: ... and IN keeps its mode across the in-place conversion" \
    || bad "patch_macho IN == OUT converting" "mode $(mode_of "$T/csdir/cs"), want 640"
[ "$(sed -n '$p' "$T/cs.out")" = "Wrote cs ($cs_n bytes)" ] \
    && ok "patch_macho: ... and names the file it wrote, which is IN" \
    || bad "patch_macho IN == OUT converting" "last line is [$(sed -n '$p' "$T/cs.out")]"
ls -a "$T/csdir" | grep -q 'drydock-macho-rewrite-compat' \
    && bad "patch_macho IN == OUT converting" "a temp file was left beside IN" \
    || ok "patch_macho: ... and left no temp beside it"
rm -rf "$T/csdir"

# C. REFUSALS WITH REAL WORK TO DISCARD. The hard-link and unwritable-OUT cases
#    above use a pass-through IN, so no run that actually CONVERTED has ever had
#    its output thrown away. Both refusals are made before drydock-macho-rewrite runs, so what
#    these add is that a converting run cannot sneak past them.
rm -rf "$T/cfhl"; mkdir "$T/cfhl"
mkchained_fixture "$T/cfhl/in"
cp "$FIXTURE" "$T/cfhl/o"; ln "$T/cfhl/o" "$T/cfhl/o2"
cfhl_sha=$(sha "$T/cfhl/o")
cfhl_rc=0
( cd "$T/cfhl" && "$BIN/patch_macho" in o ) >"$T/cfhl.out" 2>"$T/cfhl.err" || cfhl_rc=$?
[ "$cfhl_rc" -eq 1 ] && grep -q 'hard link' "$T/cfhl.err" \
    && [ "$(sha "$T/cfhl/o")" = "$cfhl_sha" ] && [ "$(sha "$T/cfhl/o2")" = "$cfhl_sha" ] \
    && ok "patch_macho: a hard-linked OUT is refused (1) even when IN converts" \
    || bad "patch_macho converting hard link" "exit $cfhl_rc: $(cat "$T/cfhl.err")"
ls -a "$T/cfhl" | grep -q 'drydock-macho-rewrite-compat' \
    && bad "patch_macho converting hard link" "a temp file was left beside OUT" \
    || ok "patch_macho: ... and the discarded conversion left no temp"
rm -rf "$T/cfhl"

mkchained_fixture "$T/cfu_in"
: > "$T/cfu_out"; chmod 444 "$T/cfu_out"
run patch_macho cfu_in cfu_out
[ "$rc" -eq 1 ] && [ "$(wc -c < "$T/cfu_out" | tr -d ' ')" = 0 ] \
    && ok "patch_macho: an unwritable OUT is refused (1), untouched, even when IN converts" \
    || bad "patch_macho converting unwritable OUT" "exit $rc, size $(wc -c < "$T/cfu_out" | tr -d ' ')"
chmod 644 "$T/cfu_out"; rm -f "$T/cfu_out"

# D. AND THE MODE CASES ONCE ON THIS PATH, because a converting run is the one
#    where the temp's own mode (drydock-macho-rewrite gave it IN's) is not already OUT's.
mkchained_fixture "$T/cfm"; chmod 640 "$T/cfm"
rm -f "$T/cfm_out"
( cd "$T" && umask 077 && "$BIN/patch_macho" cfm cfm_out ) >/dev/null 2>&1
[ "$(mode_of "$T/cfm_out")" = 700 ] \
    && ok "patch_macho: a converting run's fresh OUT is 0755 & ~umask too" \
    || bad "patch_macho converting fresh mode" "mode $(mode_of "$T/cfm_out"), want 700"
: > "$T/cfm_out2"; chmod 741 "$T/cfm_out2"; cfm_ino=$(ino_of "$T/cfm_out2")
run patch_macho cfm cfm_out2
[ "$rc" -eq 0 ] && [ "$(mode_of "$T/cfm_out2")" = 741 ] \
    && [ "$(ino_of "$T/cfm_out2")" != "$cfm_ino" ] \
    && ok "patch_macho: a converting run's existing OUT keeps its mode, with a new inode" \
    || bad "patch_macho converting existing mode" "exit $rc, mode $(mode_of "$T/cfm_out2")"

# ---- add_version_min ----------------------------------------------------
#
# THE BYTES ARE THE CONTRACT, and they are asserted against drydock-macho-rewrite's own
# output for the same request -- run both, compare, rather than pin a
# transcript.
#
# STDOUT MOVED, and this pins where it went. add_version_min printed "Added
# LC_VERSION_MIN_MACOSX 10.9 (ncmds=..., sizeofcmds=...)" on stdout; the
# statement reports the append on STDERR, as "      none -> version-min 10.9;
# sdk 10.9 written". The repo owner's ruling of 2026-09-13 is that wrapper TEXT
# may change where bytes and exit codes may not, so both halves are asserted.
fresh
strip_vm "$T/f"
avm_in=$(sha "$T/f")
run add_version_min f
avmrc=$rc
cp "$T/out" "$T/avm.out"
avmsha=$(sha "$T/f")
avm_err_had_append=0
grep -qxF '      none -> version-min 10.9; sdk 10.9 written' "$T/err" && avm_err_had_append=1
fresh
strip_vm "$T/f"
# The oracle is the SAME STATEMENT the wrapper emits, run directly -- not
# `drydock-macho-rewrite minos`, which no longer exists. What this pins is that the
# wrapper installs exactly what drydock-macho-rewrite produced for the request, which is a
# claim about the wrapper and outlives the verbs.
( cd "$T" && printf 'minos if-absent 10.9\n' | "$BIN/drydock-macho-rewrite" f mtout ) \
    >"$T/mt.out" 2>/dev/null
[ "$avmrc" -eq 0 ] && [ "$avmsha" = "$(sha "$T/mtout")" ] \
    && ok "add_version_min: the bytes it installs are drydock-macho-rewrite's own" \
    || bad "add_version_min" "exit $avmrc; the installed bytes differ from drydock-macho-rewrite minos'"
[ "$avmsha" != "$avm_in" ] \
    && ok "add_version_min: ... and it really changed the file it was given" \
    || bad "add_version_min" "the fixture came out unchanged, so nothing above was proved"
[ ! -s "$T/avm.out" ] \
    && ok "add_version_min: stdout is empty -- the append is announced on stderr now" \
    || bad "add_version_min stdout" "expected nothing on stdout; got: $(cat "$T/avm.out")"
[ "$avm_err_had_append" -eq 1 ] \
    && ok "add_version_min: ... and stderr is where the announcement went" \
    || bad "add_version_min stderr" "neither stream announced the appended LC_VERSION_MIN_MACOSX, so a caller reading the run has no way to tell it happened: $(cat "$T/err")"

run add_version_min
[ "$rc" -eq 1 ] && firstline_is "$T/err" "Usage: $BIN/add_version_min binary" \
    && ok "add_version_min: no argument is a usage error naming argv[0]" \
    || bad "add_version_min usage" "exit $rc, stderr: $(head -1 "$T/err")"

# A build-version-only binary ends with ONE version command, keeping the
# build-version's minimum and sdk. The C tool appended LC_VERSION_MIN_MACOSX
# 10.9 beside it: the pair 10.14's dyld and the 10.15+ kernel refuse.
mkminos_run() {
    [ -x "$T/mkminos" ] || "$CC" -O2 -o "$T/mkminos" "$HERE/mkminos.c" 2>"$T/mkminos.out" \
        || { bad "mkminos_run" "cannot build $HERE/mkminos.c: $(cat "$T/mkminos.out")"; return 1; }
    "$T/mkminos" "$@"
}
fresh
mkminos_run bv "$T/f" 1 12.0 12.3 || bad "add_version_min build-version: fixture setup" "mkminos bv failed"
run add_version_min f
[ "$rc" -eq 0 ] && [ "$(mkminos_run show "$T/f")" = "version-min version=12.0.0 sdk=12.3.0" ] \
    && ok "add_version_min: a build-version-only binary ends with one LC_VERSION_MIN_MACOSX, its minimum and sdk kept" \
    || bad "add_version_min build-version" "exit $rc: $(mkminos_run show "$T/f" 2>&1)"
fresh
mkminos_run vmin "$T/f" 10.9 10.9 && mkminos_run add-bv "$T/f" 1 12.0 12.3 \
    || bad "add_version_min both: fixture setup" "mkminos failed"
run add_version_min f
[ "$rc" -eq 0 ] && [ "$(mkminos_run show "$T/f")" = "version-min version=10.9.0 sdk=10.9.0" ] \
    && ok "add_version_min: ... and one carrying both loses the LC_BUILD_VERSION, its version-min unchanged" \
    || bad "add_version_min both" "exit $rc: $(mkminos_run show "$T/f" 2>&1)"
[ ! -s "$T/out" ] \
    && ok "add_version_min: ... and, having changed the file, does not say 'already present'" \
    || bad "add_version_min both stdout" "expected nothing on stdout; got: $(cat "$T/out")"

# A slice that declares a platform other than macOS is refused, untouched,
# where the C tool appended LC_VERSION_MIN_MACOSX (or, beside one, said
# "already present").
fresh
mkminos_run bv "$T/f" 2 12.0 12.3 || bad "add_version_min iOS build-version: fixture setup" "mkminos bv failed"
avm_ios_in=$(sha "$T/f")
run add_version_min f
[ "$rc" -eq 1 ] && [ "$(sha "$T/f")" = "$avm_ios_in" ] \
    && grep -qF "declares platform 2, not macOS; refusing to add a macOS minimum to it" "$T/err" \
    && ok "add_version_min: a binary declaring only platform 2 is refused (1), untouched, saying why" \
    || bad "add_version_min iOS build-version" "exit $rc: $(cat "$T/err")"
fresh
mkminos_run vmin "$T/f" 10.9 10.9 && mkminos_run add-bv "$T/f" 2 12.0 12.3 \
    || bad "add_version_min version-min beside iOS: fixture setup" "mkminos failed"
avm_ios_in=$(sha "$T/f")
run add_version_min f
[ "$rc" -eq 1 ] && [ "$(sha "$T/f")" = "$avm_ios_in" ] \
    && grep -qF "declares platform 2 beside macOS; refusing rather than guess which it is" "$T/err" \
    && ok "add_version_min: ... and one declaring platform 2 beside a version-min is refused (1), untouched, saying why" \
    || bad "add_version_min version-min beside iOS" "exit $rc: $(cat "$T/err")"

mkchained_fixture "$T/pmsim" && mkminos_run bv "$T/pmsim" 7 15.0 15.0 \
    || bad "patch_macho iOS simulator: fixture setup" "mkminos bv failed"
pmsim_in=$(sha "$T/pmsim")
run patch_macho pmsim pmsim
[ "$rc" -eq 1 ] && [ "$(sha "$T/pmsim")" = "$pmsim_in" ] \
    && grep -qF "declares platform 7, not macOS; refusing to add a macOS minimum to it" "$T/err" \
    && ok "patch_macho: a chained binary declaring only platform 7 is refused (1), untouched, saying why" \
    || bad "patch_macho iOS simulator" "exit $rc: $(cat "$T/err")"

# The wrappers keep editing FILE "in place" -- by writing a temp beside the
# real target and mv-ing it over. A symlinked FILE updates its target and
# stays a symlink; a hard-linked FILE is refused; a refusal leaves no temp
# behind; mode and xattrs survive.
cp "$FIXTURE" "$T/w_real"; strip_vm "$T/w_real"
ln -s w_real "$T/w_link"
( cd "$T" && "$BIN/add_version_min" w_link ) >/dev/null 2>"$T/w.err" \
    && ok "wrapper: a symlinked FILE is edited" || bad "wrapper symlink" "$(cat "$T/w.err")"
[ -L "$T/w_link" ] && "$BIN/drydock-macho-rewrite" info "$T/w_real" | grep -q LC_VERSION_MIN_MACOSX \
    && ok "wrapper: ... through the link, which is still a link" || bad "wrapper symlink" "link replaced or target unchanged"

# mw_finish DISCARDS a temp whose bytes already match the target rather than
# mv-ing an identical copy over it -- the C tool wrote nothing when nothing
# changed, and a rename would hand the file a fresh inode (and leave every
# other name for the old one behind). A second run on the file the run above
# just converted is exactly that case, and the INODE is what distinguishes
# "discarded" from "installed an identical copy"; the bytes cannot.
w_ino=$(stat -f %i "$T/w_real")
( cd "$T" && "$BIN/add_version_min" w_link ) >"$T/w2.out" 2>/dev/null
[ "$(stat -f %i "$T/w_real")" = "$w_ino" ] \
    && ok "wrapper: a run that changes nothing discards its temp, keeping the inode" \
    || bad "wrapper no-op run" "the target got a new inode"
grep -qxF 'LC_VERSION_MIN_MACOSX already present; nothing to do.' "$T/w2.out" \
    && ok "wrapper: ... and prints the C tool's 'already present' line" \
    || bad "wrapper no-op run" "stdout: $(cat "$T/w2.out")"

cp "$FIXTURE" "$T/w_h1"; strip_vm "$T/w_h1"; ln "$T/w_h1" "$T/w_h2"
h_before=$(shasum -a 256 < "$T/w_h1")
rc=0; "$BIN/add_version_min" "$T/w_h1" >/dev/null 2>"$T/wh.err" || rc=$?
[ "$rc" -eq 1 ] && [ "$(shasum -a 256 < "$T/w_h1")" = "$h_before" ] \
    && ok "wrapper: a hard-linked FILE is refused (1), untouched" || bad "wrapper hard link" "rc $rc"
grep -q "hard link" "$T/wh.err" && ok "wrapper: ... and says why" || bad "wrapper hard link" "$(cat "$T/wh.err")"
ls -a "$T" | grep -q 'drydock-macho-rewrite-compat' && bad "wrapper" "a temp file was left behind" \
    || ok "wrapper: no temp file left behind"

# A DIRECTORY IS NOT A HARD-LINK PROBLEM. Every directory's link count is
# greater than one (`.`, its parent's entry, one per subdirectory), so a
# link-count check that did not ask whether it was looking at a regular file
# would refuse one as "has N hard links" and offer a remedy -- break the link
# -- that means nothing. mw_prepare checks regular files only, so a directory
# falls through to drydock-macho-rewrite and gets a true answer instead.
mkdir -p "$T/w_dir/sub1" "$T/w_dir/sub2"
rc=0; ( cd "$T" && "$BIN/add_version_min" w_dir ) >/dev/null 2>"$T/wd.err" || rc=$?
grep -q "hard link" "$T/wd.err" \
    && bad "wrapper directory" "diagnosed as a hard-link problem: $(cat "$T/wd.err")" \
    || ok "wrapper: a directory is not diagnosed as a hard-link problem"
[ "$rc" -ne 0 ] \
    && ok "wrapper: ... it is still refused (exit $rc), by drydock-macho-rewrite's own open" \
    || bad "wrapper directory" "exit 0 on a directory"
ls -a "$T" | grep -q 'drydock-macho-rewrite-compat' && bad "wrapper directory" "a temp file was left behind" \
    || ok "wrapper: ... and left no temp beside it"

cp "$FIXTURE" "$T/w_meta"; strip_vm "$T/w_meta"; chmod 0751 "$T/w_meta"
xattr -w com.apple.quarantine "0081;00000000;test;" "$T/w_meta"
"$BIN/add_version_min" "$T/w_meta" >/dev/null 2>&1
[ "$(stat -f %Lp "$T/w_meta")" = 751 ] && xattr -p com.apple.quarantine "$T/w_meta" >/dev/null 2>&1 \
    && ok "wrapper: mode and quarantine survive" || bad "wrapper metadata" "mode $(stat -f %Lp "$T/w_meta")"

# THE SAME METADATA, ON THE MULTI-FAMILY PATH, which is `drydock-macho-rewrite edit` rather
# than a single verb -- and which is where it was being LOST. Every converted
# verb hands wa_write_new both FILE and the temp, so the temp is given FILE's
# mode, owner and extended attributes before mw_finish installs it. `drydock-macho-rewrite
# edit` wrote the temp through wa_write_atomic instead, which copies xattrs from
# the file it is REPLACING -- a temp that does not exist yet, so there was
# nothing to copy and the install handed FILE back without the quarantine (or
# anything else) it arrived with. MODE came through either way, because that
# write took the mode from FILE explicitly, so the mode assertion above could
# not have shown it; the xattr is the one that can. Measured on the value, not
# just its presence: an empty attribute would satisfy `xattr -p` exit status.
cp "$FIXTURE" "$T/w_meta2"; chmod 0751 "$T/w_meta2"
xattr -w com.apple.quarantine "0081;00000000;test;" "$T/w_meta2"
( cd "$T" && "$BIN/change_dylib" w_meta2 -strip-lc uuid \
    -change /usr/lib/libSystem.B.dylib '@loader_path/../S.dylib' ) >/dev/null 2>"$T/w_meta2.err"
w_meta2_rc=$?
[ "$w_meta2_rc" -eq 0 ] && [ "$(stat -f %Lp "$T/w_meta2")" = 751 ] \
    && [ "$(xattr -p com.apple.quarantine "$T/w_meta2" 2>/dev/null)" = "0081;00000000;test;" ] \
    && ok "change_dylib: mode and quarantine survive a MULTI-FAMILY run too" \
    || bad "change_dylib multi-family metadata" "exit $w_meta2_rc, mode $(stat -f %Lp "$T/w_meta2"), quarantine [$(xattr -p com.apple.quarantine "$T/w_meta2" 2>/dev/null)], stderr: $(cat "$T/w_meta2.err")"

# ---- rename_segment -----------------------------------------------------
#
# Three of cmd_segment's divergences, plus the thin-only one.
fresh
run rename_segment f __DATA __DATA_R1
[ "$rc" -eq 0 ] && grep -qxF 'f: renamed 1 segment(s) __DATA -> __DATA_R1' "$T/out" \
    && ok "rename_segment: prints its own one-line message, not mr_apply_file's chatter" \
    || bad "rename_segment message" "exit $rc, stdout: $(cat "$T/out")"
[ "$(wc -l < "$T/out" | tr -d ' ')" = 1 ] \
    && ok "rename_segment: that one line is ALL of stdout" \
    || bad "rename_segment message" "$(wc -l < "$T/out") lines: $(cat "$T/out")"

# Nothing matched: the C tool's silent exit 2, via the info --thin classification.
fresh
before=$(sha "$T/f")
run rename_segment f __NOPE __ALSONOPE
[ "$rc" -eq 2 ] && [ ! -s "$T/out" ] && [ "$(sha "$T/f")" = "$before" ] \
    && ok "rename_segment: nothing matched exits 2, silently, without writing" \
    || bad "rename_segment no match" "exit $rc (want 2), stdout: $(cat "$T/out")"
# stderr is only the teaching block: the tool's refusal must not leak.
cat >"$T/rs_nomatch_expected.err" <<'RSEXPECTED'
rename_segment: deprecated -- drydock-macho-rewrite does this now. The equivalent commands, in this order, are:
    printf 'segment rename __NOPE __ALSONOPE\n' | drydock-macho-rewrite f f.new
    mv -f f.new f
RSEXPECTED
diff -u "$T/rs_nomatch_expected.err" "$T/err" >"$T/rs_nomatch.diff" 2>&1
[ ! -s "$T/rs_nomatch.diff" ] \
    && ok "rename_segment: ...and stderr is exactly the teaching block, never drydock-macho-rewrite's own refusal" \
    || bad "rename_segment no match" "stderr != the teaching-only expectation: $(cat "$T/rs_nomatch.diff")"
# The EXIT trap removes the temp mw_prepare named.
ls -a "$T" | grep -q 'drydock-macho-rewrite-compat' \
    && bad "rename_segment no match" "the unused temp survived" \
    || ok "rename_segment: ... and the temp mw_prepare named is not left behind"

# A stub drydock-macho-rewrite passes `info` to the real binary and answers
# everything else with $MW_STUB_RC/$MW_STUB_ERR, touching $STUBDIR/ran. It is
# reached only as the bare PATH word, so DRYDOCK_MACHO_REWRITE is unset and
# DRYDOCK_MACHO_REWRITE_COMPAT_DIR points at the stub; both are restored below.
MW_HAD_DMR=${DRYDOCK_MACHO_REWRITE+1}
MW_SAVED_DMR=${DRYDOCK_MACHO_REWRITE-}
unset DRYDOCK_MACHO_REWRITE
MW_HAD_CDIR=${DRYDOCK_MACHO_REWRITE_COMPAT_DIR+1}
MW_SAVED_CDIR=${DRYDOCK_MACHO_REWRITE_COMPAT_DIR-}
STUBDIR="$T/stubbin"
mkdir -p "$STUBDIR"
cp "$BIN/drydock-macho-rewrite-compat.sh" "$STUBDIR/drydock-macho-rewrite-compat.sh"
cp "$BIN/drydock-macho-rewrite-translate.sh" "$STUBDIR/drydock-macho-rewrite-translate.sh"
cat >"$STUBDIR/drydock-macho-rewrite" <<STUB
#!/bin/sh
case "\$1" in
    info) exec "$BIN/drydock-macho-rewrite" "\$@" ;;
esac
: >>"$STUBDIR/ran"
printf '%s\n' "\$MW_STUB_ERR" >&2
exit "\$MW_STUB_RC"
STUB
chmod +x "$STUBDIR/drydock-macho-rewrite"
DRYDOCK_MACHO_REWRITE_COMPAT_DIR="$STUBDIR"
export DRYDOCK_MACHO_REWRITE_COMPAT_DIR

# Exit 1 with unfamiliar wording; OLD absent -> still 2.
fresh
before=$(sha "$T/f")
rm -f "$STUBDIR/ran"
MW_STUB_RC=1
MW_STUB_ERR='drydock-macho-rewrite: a completely different refusal, worded on purpose so nothing greps for it'
export MW_STUB_RC MW_STUB_ERR
run rename_segment f __NOPE __ALSONOPE
[ -f "$STUBDIR/ran" ] && [ "$rc" -eq 2 ] && [ ! -s "$T/out" ] \
    && ! grep -qF "$MW_STUB_ERR" "$T/err" && [ "$(sha "$T/f")" = "$before" ] \
    && ok "rename_segment: a fake tool's exit 1 is 'nothing matched' when OLD does not exist, no matter what it says" \
    || bad "rename_segment stub refusal, absent" "stub ran=$([ -f "$STUBDIR/ran" ] && echo yes || echo NO), exit $rc (want 2), stdout: $(cat "$T/out"), stderr: $(cat "$T/err")"

# Exit 1; OLD present -> the refusal is shown, exit 1.
fresh
before=$(sha "$T/f")
rm -f "$STUBDIR/ran"
MW_STUB_RC=1
MW_STUB_ERR='drydock-macho-rewrite: a refusal that has nothing to do with matching'
export MW_STUB_RC MW_STUB_ERR
run rename_segment f __DATA __DATA_STUBX
[ -f "$STUBDIR/ran" ] && [ "$rc" -eq 1 ] && has_line "$T/err" "$MW_STUB_ERR" \
    && [ "$(sha "$T/f")" = "$before" ] \
    && ok "rename_segment: a fake tool's exit 1 is shown, not swallowed, when OLD DOES exist" \
    || bad "rename_segment stub refusal, present" "stub ran=$([ -f "$STUBDIR/ran" ] && echo yes || echo NO), exit $rc (want 1), stderr: $(cat "$T/err")"

# EX_FAIL is never classified: shown, exit 1.
fresh
before=$(sha "$T/f")
rm -f "$STUBDIR/ran"
MW_STUB_RC=2
MW_STUB_ERR='drydock-macho-rewrite: pretend malloc failed'
export MW_STUB_RC MW_STUB_ERR
run rename_segment f __NOPE __ALSONOPE
[ -f "$STUBDIR/ran" ] && [ "$rc" -eq 1 ] && has_line "$T/err" "$MW_STUB_ERR" \
    && [ "$(sha "$T/f")" = "$before" ] \
    && ok "rename_segment: EX_FAIL stays 'everything else' -- shown, and exit 1, not 2" \
    || bad "rename_segment stub EX_FAIL" "stub ran=$([ -f "$STUBDIR/ran" ] && echo yes || echo NO), exit $rc (want 1), stderr: $(cat "$T/err")"

fresh
before=$(sha "$T/f")
rm -f "$STUBDIR/ran"
MW_STUB_RC=0
MW_STUB_ERR=''
export MW_STUB_RC MW_STUB_ERR
run rename_segment f __DATA __DATA_STUBX
[ -f "$STUBDIR/ran" ] && [ "$rc" -eq 1 ] && [ ! -s "$T/out" ] \
    && grep -qF 'did not report what its segment rename matched' "$T/err" \
    && [ "$(sha "$T/f")" = "$before" ] \
    && ok "rename_segment: a tool that exits 0 without naming a rename is a mismatched install: exit 1, loud, file untouched" \
    || bad "rename_segment stub silent 0" "stub ran=$([ -f "$STUBDIR/ran" ] && echo yes || echo NO), exit $rc (want 1), stdout: $(cat "$T/out"), stderr: $(cat "$T/err")"

unset MW_STUB_RC MW_STUB_ERR
if [ -n "$MW_HAD_CDIR" ]; then DRYDOCK_MACHO_REWRITE_COMPAT_DIR=$MW_SAVED_CDIR; export DRYDOCK_MACHO_REWRITE_COMPAT_DIR
else unset DRYDOCK_MACHO_REWRITE_COMPAT_DIR; fi
unset MW_HAD_CDIR MW_SAVED_CDIR
if [ -n "$MW_HAD_DMR" ]; then DRYDOCK_MACHO_REWRITE=$MW_SAVED_DMR; export DRYDOCK_MACHO_REWRITE; fi
unset MW_HAD_DMR MW_SAVED_DMR

# LC_LAZY_LOAD_DYLIB makes mo_map_build refuse a rename of a real segment:
# exit 1, shown. -lazy_library is legacy; SKIP loudly where this host's ld
# won't emit one (as change_dylib_test does).
cat > "$T/rs_has_lc.c" <<'EOF'
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <mach-o/loader.h>
int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: %s file cmd-hex\n", argv[0]); return 2; }
    uint32_t want = (uint32_t)strtoul(argv[2], NULL, 16);
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) { perror("open"); return 2; }
    struct stat st; fstat(fd, &st);
    uint8_t *buf = malloc((size_t)st.st_size);
    if (!buf || read(fd, buf, (size_t)st.st_size) != (ssize_t)st.st_size) {
        fprintf(stderr, "read failed\n"); return 2;
    }
    close(fd);
    struct mach_header_64 *hdr = (struct mach_header_64 *)buf;
    if (hdr->magic != MH_MAGIC_64) { fprintf(stderr, "not a 64-bit Mach-O\n"); return 2; }
    uint8_t *lcp = buf + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        struct load_command *lc = (struct load_command *)lcp;
        if (lc->cmd == want) return 0;
        lcp += lc->cmdsize;
    }
    return 1;
}
EOF
"$CC" -O2 -o "$T/rs_has_lc" "$T/rs_has_lc.c"

cat > "$T/rs_lazy_a.c" <<'EOF'
int rs_lazy_a_sym(void) { return 77; }
EOF
cat > "$T/rs_lazy_main.c" <<'EOF'
int rs_lazy_a_sym(void);
int main(void) { return rs_lazy_a_sym() == 77 ? 0 : 1; }
EOF
"$CC" -dynamiclib -O2 -arch x86_64 -mmacosx-version-min=10.9 \
    -install_name "@loader_path/librs_lazy_a.dylib" \
    "$T/rs_lazy_a.c" -o "$T/librs_lazy_a.dylib"
"$CC" -O2 -arch x86_64 -mmacosx-version-min=10.9 "$T/rs_lazy_main.c" \
    -Xlinker -lazy_library -Xlinker "$T/librs_lazy_a.dylib" -o "$T/rs_lazy_main" \
    2>"$T/rs_lazy_link.err" || true

if [ ! -x "$T/rs_lazy_main" ] || ! "$T/rs_has_lc" "$T/rs_lazy_main" 0x20; then
    skip "rename_segment: LC_LAZY_LOAD_DYLIB classification" \
        "this host's linker did not produce an LC_LAZY_LOAD_DYLIB from -lazy_library ($(head -1 "$T/rs_lazy_link.err" 2>/dev/null || echo "no diagnostic"))"
else
    before=$(sha "$T/rs_lazy_main")
    run rename_segment rs_lazy_main __TEXT __TEXX
    [ "$rc" -eq 1 ] && grep -qi "LC_LAZY_LOAD_DYLIB" "$T/err" \
        && [ "$(sha "$T/rs_lazy_main")" = "$before" ] \
        && ok "rename_segment: LC_LAZY_LOAD_DYLIB is a real refusal (exit 1), shown, once classified 'present'" \
        || bad "rename_segment LC_LAZY_LOAD_DYLIB" "exit $rc (want 1), stderr: $(cat "$T/err")"
    run rename_segment rs_lazy_main __NOPE __X
    [ "$rc" -eq 2 ] && [ ! -s "$T/out" ] && ! grep -qi "LC_LAZY_LOAD_DYLIB" "$T/err" \
        && [ "$(sha "$T/rs_lazy_main")" = "$before" ] \
        && ok "rename_segment: LC_LAZY_LOAD_DYLIB with an absent OLD exits 2, silently, as the C tool did" \
        || bad "rename_segment LC_LAZY_LOAD_DYLIB, absent OLD" "exit $rc (want 2), stdout: $(cat "$T/out"), stderr: $(cat "$T/err")"
fi

# A rename to the SAME name still MATCHED, so it is exit 0 with a count of 1 --
# not exit 2. This is what rules out implementing "nothing matched" as
# "the bytes did not change".
fresh
run rename_segment f __DATA __DATA
[ "$rc" -eq 0 ] && grep -qxF 'f: renamed 1 segment(s) __DATA -> __DATA' "$T/out" \
    && ok "rename_segment: renaming a segment to its own name is a match, not 'nothing to do'" \
    || bad "rename_segment same name" "exit $rc, stdout: $(cat "$T/out")"

# THE MATCH COUNT MUST COME FROM THE MATCHER, not from a printed name. These
# two shapes are why: mseg_rename_lc matches with strncmp over the 16-byte
# segname field, which is neither NUL-terminated nor free of whitespace, so a
# wrapper that recovered the count by reading names back out of `drydock-macho-rewrite info`
# got both wrong -- it exited 2 and left the file alone where the C tool
# renamed and exited 0. Both were measured against the pre-wrapper binary
# before this wrapper was changed to take the count from the rewriter's own
# per-rename line, `  Rename segment: OLD -> NEW`.
#
# The odd segnames are made with `drydock-macho-rewrite segment` itself, which is how they are
# reachable in the first place; both are legal in a char[16] field. That verb
# writes an OUT rather than the file it is given, so each of these
# fixture-preparation runs installs its own result, the same way the wrappers
# under test do.
fresh
( cd "$T" && printf 'segment rename __DATA 1234567890123456\n' | "$BIN/drydock-macho-rewrite" f f.seg \
    && mv -f f.seg f ) >/dev/null 2>&1
before=$(sha "$T/f")
run rename_segment f 12345678901234567 __X
[ "$rc" -eq 0 ] && grep -qxF 'f: renamed 1 segment(s) 12345678901234567 -> __X' "$T/out" \
    && [ "$(sha "$T/f")" != "$before" ] \
    && ok "rename_segment: an OLD longer than 16 bytes still matches on its first 16" \
    || bad "rename_segment 17-byte OLD" "exit $rc, stdout: $(cat "$T/out")"

fresh
# The segname is SINGLE-QUOTED inside the statement: src/script.c's ms_split
# splits a statement's words the way a shell does, so an unquoted `A B` is two
# words and `segment rename __DATA A B` is a three-argument statement the
# parser refuses -- leaving the fixture unrenamed and the assertion below
# testing nothing at all (it exited 2 on a file that still said __DATA).
( cd "$T" && printf "segment rename __DATA 'A B'\n" | "$BIN/drydock-macho-rewrite" f f.seg && mv -f f.seg f ) >/dev/null 2>&1
before=$(sha "$T/f")
run rename_segment f 'A B' __Y
[ "$rc" -eq 0 ] && grep -qxF 'f: renamed 1 segment(s) A B -> __Y' "$T/out" \
    && [ "$(sha "$T/f")" != "$before" ] \
    && ok "rename_segment: a segname containing whitespace still matches" \
    || bad "rename_segment whitespace segname" "exit $rc, stdout: $(cat "$T/out")"

# The count itself, and that it is the count and not a constant: rename a
# segment name the image carries TWICE (which is what this tool produces --
# see src/segname.h on __DATA_CONST -> __DATA leaving two __DATAs).
fresh
( cd "$T" && printf 'segment rename __TEXT __DUP\n' | "$BIN/drydock-macho-rewrite" f f.seg && mv -f f.seg f ) >/dev/null 2>&1
( cd "$T" && printf 'segment rename __DATA __DUP\n' | "$BIN/drydock-macho-rewrite" f f.seg && mv -f f.seg f ) >/dev/null 2>&1
run rename_segment f __DUP __ONE
[ "$rc" -eq 0 ] && grep -qxF 'f: renamed 2 segment(s) __DUP -> __ONE' "$T/out" \
    && ok "rename_segment: reports the real match count, not 1" \
    || bad "rename_segment count" "exit $rc, stdout: $(cat "$T/out")"

# ...and the line that count is COUNTED from is one this build really prints.
# Asserted against drydock-macho-rewrite directly, on a rename that matches.
fresh
( cd "$T" && "$BIN/drydock-macho-rewrite" f f.seg <<'RSCAP'
segment rename __DATA __CAPCHK
RSCAP
) >"$T/cap.out" 2>/dev/null
grep -qxF '  Rename segment: __DATA -> __CAPCHK' "$T/cap.out" \
    && ok "capabilities: this build names each segment it renames, which is where the count comes from" \
    || bad "capabilities" "no '  Rename segment: OLD -> NEW' line, so rename_segment would exit 1 on every rename, installing nothing: $(cat "$T/cap.out")"

# THIN ONLY. rename_segment ran mi_open, which refuses a fat container;
# `drydock-macho-rewrite segment` goes through mr_apply_file, which handles one. Without the
# wrapper's gate this would rename inside a fat file the C tool refused --
# and most of /System/Library/Frameworks is fat.
FAT=''
for f in /usr/lib/libSystem.B.dylib /usr/lib/libc++.1.dylib /bin/ls; do
    [ -r "$f" ] || continue
    case $(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' ') in
        cafebabe|bebafeca) FAT=$f; break ;;
    esac
done
if [ -n "$FAT" ]; then
    cp "$FAT" "$T/fat"; chmod u+w "$T/fat"
    before=$(sha "$T/fat")
    run rename_segment fat __DATA __DATA_R9
    [ "$rc" -eq 1 ] && has_line "$T/err" 'fat: not a readable 64-bit Mach-O' \
        && [ "$(sha "$T/fat")" = "$before" ] \
        && ok "rename_segment: a fat container is refused, as it always was" \
        || bad "rename_segment fat" "exit $rc, stderr: $(head -1 "$T/err")"
else
    skip "rename_segment: fat container" "no fat Mach-O found on this host"
fi

# mg_plausible, from the caller's side. That gate can reject an image for
# something the rewrite did not do -- it re-decides a property of the INPUT --
# and rename_segment never had such a gate at all. drydock-macho-rewrite now runs it only
# where the run disturbed what it checks (src/relations.h's
# mrel_verify_applies), and a segment rename disturbs nothing; this is the same
# property seen through the wrapper, which is where a caller sees it.
#
# The input is tests/mkimplausible.c's committed fixture, built here. The
# fixture is refused on its merits.
"$CC" -O2 -Wall -Wextra -I "$ROOT/src" -o "$T/mkimplausible" "$HERE/mkimplausible.c"
"$T/mkimplausible" "$T/imp"

# The pass below is narrow, not a hole: the gate still refuses THIS FIXTURE
# for an operation that genuinely disturbs the base-relative values it checks.
# `fixups set classic` is that operation -- it rebuilds __LINKEDIT's opcode
# streams and writes the resolved image base into the __DATA slot the chain
# pointed at -- and it reaches the fixture through `drydock-macho-rewrite edit`, the one
# front-end that offers it. A build whose gate had simply been deleted would
# let this through, and then the rename below would prove nothing.
#
# `lc -delete uuid` USED to stand here and no longer can: it frees header pad
# and repacks the command region, moving no base-relative value, so the derived
# applicability skips the gate for it. That was always true of the operation;
# the assertion passed because the gate ran unconditionally, not because the
# premise held.
printf 'fixups set classic\n' >"$T/imp.edits"
( cd "$T" && "$BIN/drydock-macho-rewrite" imp imp.fx <imp.edits ) >/dev/null 2>"$T/imperr"
[ $? -ne 0 ] && grep -q 'implausible' "$T/imperr" \
    && ok "rename_segment: the fixture really is one the gate rejects for an operation that disturbs it" \
    || bad "rename_segment mg_plausible" "fixups set classic was not refused: $(cat "$T/imperr")"

cp "$T/imp" "$T/v"
before=$(sha "$T/v")
run rename_segment v __DATA __DATA_R9
[ "$rc" -eq 0 ] && grep -qxF 'v: renamed 1 segment(s) __DATA -> __DATA_R9' "$T/out" \
    && [ "$(sha "$T/v")" != "$before" ] \
    && ok "rename_segment: renames a binary mg_plausible rejects for other operations" \
    || bad "rename_segment mg_plausible" "exit $rc: $(cat "$T/err")"

# The NEW-name length check and the arity check happen before any I/O, in
# rename_segment's own words -- both come from compat/translate.sh.
fresh
run rename_segment f __DATA 12345678901234567
[ "$rc" -eq 1 ] && firstline_is "$T/err" 'new segment name longer than 16 bytes' \
    && ok "rename_segment: a 17-byte NEW name is refused before any I/O" \
    || bad "rename_segment long name" "exit $rc, stderr: $(head -1 "$T/err")"
fresh
run rename_segment f __DATA
[ "$rc" -eq 1 ] && firstline_is "$T/err" "Usage: $BIN/rename_segment binary OLDNAME NEWNAME" \
    && ok "rename_segment: wrong arity is a usage error naming argv[0]" \
    || bad "rename_segment arity" "exit $rc, stderr: $(head -1 "$T/err")"

# An absent file fails before anything else, as the C tool's early O_RDWR did.
run rename_segment nosuchfile __DATA __X
[ "$rc" -eq 1 ] \
    && ok "rename_segment: an absent file exits 1" \
    || bad "rename_segment absent" "exit $rc, want 1"

# ---- retag_swift_classes ------------------------------------------------
#
# The variadic one. Its two messages and its had_error exit are rebuilt by the
# wrapper, because a single-file verb has nothing to say about a total and
# prints its per-file line even for a count of zero.
fresh
run retag_swift_classes f
[ "$rc" -eq 0 ] && grep -qxF 'total: 0 class record(s) retagged' "$T/out" \
    && ok "retag_swift_classes: prints the total line the single-file verb has no notion of" \
    || bad "retag_swift_classes total" "exit $rc, stdout: $(cat "$T/out")"
grep -q ': retagged 0 class record(s)' "$T/out" \
    && bad "retag_swift_classes" "printed a per-file line for a zero count, which the C tool did not" \
    || ok "retag_swift_classes: no per-file line for a zero count, as before"

# A NON-Mach-O argument was a silent skip: no message, no error flag, and the
# loop kept going. drydock-macho-rewrite refuses it with EX_REFUSED and says so, so the
# wrapper has to swallow both. Three rows of tests/compat-matrix.tsv are this
# case.
fresh
printf 'not a mach-o at all\n' > "$T/nm"
run retag_swift_classes f nm f
[ "$rc" -eq 0 ] && grep -qxF 'total: 0 class record(s) retagged' "$T/out" \
    && ok "retag_swift_classes: a non-Mach-O argument is skipped, and the loop continues" \
    || bad "retag_swift_classes skip" "exit $rc, stdout: $(cat "$T/out")"
grep -q 'not a readable 64-bit Mach-O' "$T/err" \
    && bad "retag_swift_classes skip" "drydock-macho-rewrite's refusal for the skipped file leaked to stderr" \
    || ok "retag_swift_classes: the skip is silent, as it always was"

# A REAL failure (an absent path) sets had_error, prints the underlying
# diagnostic, and still prints the total. tests/leaf-tool-crashes.sh asserts
# the exit code of this exact shape.
fresh
run retag_swift_classes f nosuchfile
[ "$rc" -eq 1 ] && grep -qxF 'total: 0 class record(s) retagged' "$T/out" \
    && ok "retag_swift_classes: an absent path exits 1 and still prints the total" \
    || bad "retag_swift_classes error" "exit $rc, stdout: $(cat "$T/out")"
grep -q 'No such file or directory' "$T/err" \
    && ok "retag_swift_classes: the underlying diagnostic still reaches stderr" \
    || bad "retag_swift_classes error" "stderr: $(cat "$T/err")"

run retag_swift_classes
[ "$rc" -eq 1 ] && firstline_is "$T/err" "Usage: $BIN/retag_swift_classes binary [binary ...]" \
    && ok "retag_swift_classes: no argument is a usage error naming argv[0]" \
    || bad "retag_swift_classes usage" "exit $rc, stderr: $(head -1 "$T/err")"

# EVERY assertion above ran on `f` (tests/fixture.macho), which has ZERO Swift
# class records -- so "total: 0" is the only total ever asserted, the
# per-file line is only ever asserted ABSENT, and no assertion above ever
# observed an INSTALL happen at all. A wrapper whose mw_finish discarded
# every temp instead of installing it -- printing every line above
# correctly, having modified not one binary -- would pass every one of them
# unchanged. mkswift_fixture (tests/mkswift.c, shared with cli_test.sh) gives
# this suite a binary with real Swift class records, closing that gap.

# A nonzero-count binary really gets retagged: bytes change, the per-file
# line is printed with the real count, and it sums into total.
mkswift_fixture "$T/rsc1"
rsc1_before=$(sha "$T/rsc1")
run retag_swift_classes rsc1
[ "$rc" -eq 0 ] && grep -qxF 'rsc1: retagged 2 class record(s)' "$T/out" \
    && grep -qxF 'total: 2 class record(s) retagged' "$T/out" \
    && ok "retag_swift_classes: a nonzero-count binary prints its own line and the right total" \
    || bad "retag_swift_classes nonzero" "exit $rc, stdout: $(cat "$T/out")"
[ "$(sha "$T/rsc1")" != "$rsc1_before" ] \
    && ok "retag_swift_classes: ... and its bytes really changed (this was not a discarded no-op)" \
    || bad "retag_swift_classes nonzero" "rsc1's bytes did not change"

# A mixed run good/hard-linked/good: the hard-linked argument is refused (the
# new divergence installing via mv introduces -- the C tool wrote
# through the open fd regardless of hard links; this wrapper installs via mv,
# which cannot update every name for an inode at once), the loop keeps going,
# exit is 1, stdout is the two good binaries' lines plus the REDUCED total,
# and the hard-linked target -- and its link, same inode -- are untouched.
mkswift_fixture "$T/rsc_g1"
mkswift_fixture "$T/rsc_h1"; ln "$T/rsc_h1" "$T/rsc_h2"
mkswift_fixture "$T/rsc_g2"
rsc_h1_before=$(sha "$T/rsc_h1"); rsc_h1_ino=$(stat -f %i "$T/rsc_h1")
run retag_swift_classes rsc_g1 rsc_h1 rsc_g2
[ "$rc" -eq 1 ] && grep -qxF 'rsc_g1: retagged 2 class record(s)' "$T/out" \
    && grep -qxF 'rsc_g2: retagged 2 class record(s)' "$T/out" \
    && grep -qxF 'total: 4 class record(s) retagged' "$T/out" \
    && ! grep -q 'rsc_h1' "$T/out" \
    && ok "retag_swift_classes: good/hardlinked/good -- exit 1, the two good lines, and the reduced total" \
    || bad "retag_swift_classes hardlink mix" "exit $rc, stdout: $(cat "$T/out")"
grep -q 'hard link' "$T/err" \
    && ok "retag_swift_classes: ... and says why the hard-linked one was skipped" \
    || bad "retag_swift_classes hardlink mix" "no hard-link explanation on stderr: $(cat "$T/err")"
[ "$(sha "$T/rsc_h1")" = "$rsc_h1_before" ] && [ "$(stat -f %i "$T/rsc_h1")" = "$rsc_h1_ino" ] \
    && [ "$(sha "$T/rsc_h2")" = "$rsc_h1_before" ] \
    && ok "retag_swift_classes: ... the hard-linked target AND its link are untouched" \
    || bad "retag_swift_classes hardlink mix" "rsc_h1 or rsc_h2 changed"

# A mixed run good/unwritable/good: same shape, a different wrapper-level
# refusal (mw_require_writable, same words change_dylib's own guard uses).
mkswift_fixture "$T/rsc_g3"
mkswift_fixture "$T/rsc_u"; chmod 444 "$T/rsc_u"
mkswift_fixture "$T/rsc_g4"
rsc_u_before=$(sha "$T/rsc_u")
run retag_swift_classes rsc_g3 rsc_u rsc_g4
chmod 644 "$T/rsc_u"
[ "$rc" -eq 1 ] && grep -qxF 'rsc_g3: retagged 2 class record(s)' "$T/out" \
    && grep -qxF 'rsc_g4: retagged 2 class record(s)' "$T/out" \
    && grep -qxF 'total: 4 class record(s) retagged' "$T/out" \
    && ! grep -q 'rsc_u' "$T/out" \
    && ok "retag_swift_classes: good/unwritable/good -- exit 1, the two good lines, and the reduced total" \
    || bad "retag_swift_classes unwritable mix" "exit $rc, stdout: $(cat "$T/out")"
[ "$(sha "$T/rsc_u")" = "$rsc_u_before" ] \
    && ok "retag_swift_classes: ... the unwritable one is untouched" \
    || bad "retag_swift_classes unwritable mix" "rsc_u changed"

# No `.*.drydock-macho-rewrite-compat.$$` temp survives either mid-loop refusal above.
ls -a "$T" | grep -q 'drydock-macho-rewrite-compat' && bad "retag_swift_classes" "a temp file was left behind" \
    || ok "retag_swift_classes: no temp file left behind after a mid-loop refusal"

# A 0-count binary AMONG nonzero ones: mw_finish discards its temp rather
# than installing an identical copy, so its INODE (not just its bytes, which
# cannot tell the two apart) is unchanged -- while the good binaries around
# it still count. `f` (tests/fixture.macho) has zero Swift class records.
fresh
mkswift_fixture "$T/rsc_g5"
mkswift_fixture "$T/rsc_g6"
f_ino=$(stat -f %i "$T/f"); f_before=$(sha "$T/f")
run retag_swift_classes rsc_g5 f rsc_g6
[ "$rc" -eq 0 ] && grep -qxF 'total: 4 class record(s) retagged' "$T/out" \
    && ! grep -q '^f: retagged' "$T/out" \
    && ok "retag_swift_classes: a 0-count binary among nonzero ones prints no line of its own, and the total excludes it" \
    || bad "retag_swift_classes 0-count mix" "exit $rc, stdout: $(cat "$T/out")"
[ "$(stat -f %i "$T/f")" = "$f_ino" ] && [ "$(sha "$T/f")" = "$f_before" ] \
    && ok "retag_swift_classes: ... and its INODE is unchanged (discarded, not reinstalled)" \
    || bad "retag_swift_classes 0-count mix" "f's inode or bytes changed on a 0-count run"

# A symlinked argument stays a symlink; its target is what actually changes.
mkswift_fixture "$T/rsc_real"
ln -s rsc_real "$T/rsc_link"
rsc_real_before=$(sha "$T/rsc_real")
run retag_swift_classes rsc_link
[ "$rc" -eq 0 ] && grep -qxF 'rsc_link: retagged 2 class record(s)' "$T/out" \
    && ok "retag_swift_classes: a symlinked argument is retagged through the link" \
    || bad "retag_swift_classes symlink" "exit $rc, stdout: $(cat "$T/out")"
[ -L "$T/rsc_link" ] \
    && ok "retag_swift_classes: ... which is still a symlink afterward" \
    || bad "retag_swift_classes symlink" "rsc_link is no longer a symlink"
[ "$(sha "$T/rsc_real")" != "$rsc_real_before" ] \
    && ok "retag_swift_classes: ... and its target is what actually got the new bytes" \
    || bad "retag_swift_classes symlink" "rsc_real's bytes did not change"

# MEASURED against the mutation this suite exists to catch: with
# drydock-macho-rewrite-compat.sh's mw_finish changed to discard every temp unconditionally
# (install NOTHING, as if nothing ever differed), stdout is untouched --
# rsc1 still prints "rsc1: retagged 2 class record(s)" and "total: 2 ..." --
# so the two assertions above that check ONLY stdout or an untouched-file's
# bytes would still pass. What actually fails: "... its bytes really changed"
# (rsc1) and "... its target is what actually got the new bytes" (rsc_real),
# because those are the two that check a byte or an inode that was supposed
# to MOVE, not stay put. Not left staged here as a live test, because that
# would mean shipping a second, deliberately-broken copy of mw_finish just to
# exercise it.

# ---- fix_macho ----------------------------------------------------------
#
# The last tool to become a wrapper, and the only one whose wrapper does NOT
# close its divergences: the repo owner ruled five of them improvements to
# ADOPT. compat/README.md's "fix_macho: the adopted divergences" table states
# all five with their reasons, and names the assertion holding each. This
# block asserts each of the three flags it accepts, a fat container (its
# headline capability, and the one thing change_dylib could not do), and the
# two adopted changes that used to be REFUSALS -- a longer replacement path
# and a chained -rename_seg. Both of those were measured against the
# pre-wrapper C binary and recorded in tests/compat-matrix.tsv as differences;
# they are now the expected behaviour, and these are the assertions that say
# so out loud. The fifth adopted change -- -change no longer rewriting a
# dylib's own LC_ID_DYLIB -- has its own assertion further down.

# -change, the flag with the most reach. Byte-identical to the same operation
# through drydock-macho-rewrite itself, which is the same shape the change_dylib block above
# asserts and for the same reason: one emitted command is one mr_apply_file
# pass over the same file with the same ops.
fresh
run fix_macho f -change /usr/lib/libSystem.B.dylib '@loader_path/../S.dylib'
fmrc=$rc
cp "$T/out" "$T/fm.out"
fmsha=$(sha "$T/f")
fresh
( cd "$T" && printf 'dylib replace /usr/lib/libSystem.B.dylib %s\n' \
    '@loader_path/../S.dylib' | "$BIN/drydock-macho-rewrite" f f.mtout ) >"$T/mt.out" 2>/dev/null
# The same appended wrapper line the change_dylib block above explains.
{ cat "$T/mt.out"; printf 'Updated f (%s bytes)\n' "$(wc -c < "$T/f.mtout" | tr -d ' ')"; } >"$T/mt.want"
[ "$fmrc" -eq 0 ] && cmp -s "$T/fm.out" "$T/mt.want" && [ "$fmsha" = "$(sha "$T/f.mtout")" ] \
    && ok "fix_macho: -change is byte-identical to a dylib replace statement, stdout included" \
    || bad "fix_macho -change" "exit $fmrc; stdout or bytes differ from the statement's"

# -rename_seg, which fix_macho's own usage line never mentioned even though
# its parser always accepted it. One `drydock-macho-rewrite segment` pass per pair.
fresh
before=$(sha "$T/f")
run fix_macho f -rename_seg __DATA __DATA_F1
[ "$rc" -eq 0 ] && [ "$(sha "$T/f")" != "$before" ] \
    && ( cd "$T" && "$BIN/drydock-macho-rewrite" info f ) 2>/dev/null | grep -q '__DATA_F1' \
    && ok "fix_macho: -rename_seg renames the segment" \
    || bad "fix_macho -rename_seg" "exit $rc: $(cat "$T/err")"

# -strip_build_version. tests/fixture.macho is a real 10.9 binary and carries
# no LC_BUILD_VERSION (the load command postdates it by four years), so this
# asserts the OTHER half, which is the half a caller depends on: the emitted
# command is the right one, the operation that matched nothing SAYS SO on
# stderr -- drydock-macho-rewrite's report, which is what replaced fix_macho's
# "No changes needed: F" -- and the exit code is still 0.
#
# A GATE: fix_macho exited 0 on a miss, so its translation must open with
# allow-unmatched; a 1 here means the directive went missing.
fresh
before=$(sha "$T/f")
run fix_macho f -strip_build_version
[ "$rc" -eq 0 ] && [ "$(sha "$T/f")" = "$before" ] \
    && ok "fix_macho: -strip_build_version with nothing to strip exits 0, having written nothing" \
    || bad "fix_macho -strip_build_version" "exit $rc (want 0), file changed=$([ "$(sha "$T/f")" = "$before" ] && echo no || echo YES)"
# `drydock-macho-rewrite:`, the tool's own name: the unmatched report names operations in
# drydock-macho-rewrite's grammar (src/rewrite.c's mr_report_unmatched says why), so the
# prefix moved with the binary. The diagnostic and the taught line below it
# now agree.
#
# NOTHING DIGESTS THIS. tests/EXPECTED and tests/known-callers.sh's sha256s
# hash converted FILE BYTES, with every tool's stdout and stderr sent to
# /dev/null, so renaming every emitted string moved neither.
has_line "$T/err" 'drydock-macho-rewrite: no load command of kind build-version to delete' \
    && ok "fix_macho: an operation that matched nothing says so on stderr" \
    || bad "fix_macho unmatched report" "stderr: $(cat "$T/err")"
has_line "$T/err" "    printf 'allow-unmatched\\nload-command delete build-version\\n' | drydock-macho-rewrite f f.new" \
    && ok "fix_macho: -strip_build_version translates to load-command delete build-version" \
    || bad "fix_macho -strip_build_version translation" "stderr: $(cat "$T/err")"

# THE FIFTH DIVERGENCE: -change AIMED AT THIS DYLIB'S OWN INSTALL NAME.
# compat/fix_macho.c's match block opened on `mo_is_ordinal_lc(lc->cmd) ||
# lc->cmd == LC_ID_DYLIB` and then ran the changes[] comparison loop with NO
# LC_ID_DYLIB exclusion -- so `-change <this dylib's own install name> NEW`
# rewrote the dylib's identity, even though the file's own comment claimed
# "nothing in changes is ever meant to match it". src/rewrite.c enforces that
# comment as code now (`if (lc->cmd != LC_ID_DYLIB) { /* never rewrite this
# dylib's own identity */`), matching what install_name_tool does: -id, never
# -change, is the flag that ever touches LC_ID_DYLIB. The repo owner ruled
# this the fifth divergence to ADOPT; compat/README.md's divergence table
# states it, with its reasons and the measurement behind it.
#
# tests/fixture.macho is an EXECUTABLE and carries no LC_ID_DYLIB at all, so
# this needs its own fixture: a tiny dylib, built here the same way
# tests/change_dylib_test.sh builds its dylib fixtures (`$CC -dynamiclib
# -install_name ...`), with its own install name AND a real dependency, so
# one run asserts both halves at once -- the guard holds on the identity,
# and a -change aimed at a real dependency in the SAME invocation still
# lands, so this pins the guard rather than "fix_macho does nothing to
# dylibs".
fm_id="@loader_path/libfmid.dylib"
"$CC" -dynamiclib -O2 -mmacosx-version-min=10.9 -install_name "$fm_id" \
    -x c - -o "$T/libfmid.dylib" <<'EOF'
int fmid_dummy(void) { return 0; }
EOF
run fix_macho libfmid.dylib -change "$fm_id" '@loader_path/OTHER.dylib' \
    -change /usr/lib/libSystem.B.dylib '@loader_path/../S.dylib'
if [ "$rc" -eq 0 ] \
    && has_line "$T/err" "drydock-macho-rewrite: $fm_id matched nothing" \
    && LC_ALL=C grep -q -- "$fm_id" "$T/libfmid.dylib" \
    && ! LC_ALL=C grep -q -- '@loader_path/OTHER.dylib' "$T/libfmid.dylib" \
    && LC_ALL=C grep -q -- '@loader_path/../S.dylib' "$T/libfmid.dylib"; then
    ok "fix_macho: -change at a dylib's own install name leaves LC_ID_DYLIB unchanged, reported unmatched, while a real dependency's -change in the same run still lands"
else
    bad "fix_macho -change own id" "exit $rc; stderr: $(cat "$T/err")"
fi

# ADOPTED CHANGE 1: A REPLACEMENT PATH LONGER THAN THE EXISTING COMMAND.
# compat/fix_macho.c wrote the new path INTO the existing LC_LOAD_DYLIB and
# refused when it did not fit ("new path '...' too long (320 > 32)", exit 1,
# file untouched -- a measured row of tests/compat-matrix.tsv). `drydock-macho-rewrite dylib
# -replace` resizes the command into header pad the image already has, so this
# now succeeds, with no header grow: the fixture's pad holds it.
fresh
fm_long="@loader_path/"
i=0
while [ $i -lt 30 ]; do fm_long="${fm_long}longlongl"; i=$((i + 1)); done
fm_long="${fm_long}.dylib"
run fix_macho f -change /usr/lib/libSystem.B.dylib "$fm_long"
# A raw byte search over the rewritten file, NOT `otool -L`: tests/README.md's
# second lesson. grep's own "Binary file matches" chatter is irrelevant under
# -q, which reports only through its exit status.
if [ "$rc" -eq 0 ] && LC_ALL=C grep -q -- "$fm_long" "$T/f"; then
    ok "fix_macho: a longer replacement path is now rewritten into header pad, not refused"
else
    bad "fix_macho long path" "exit $rc (want 0); the 289-byte replacement did not land: $(cat "$T/err")"
fi

# ADOPTED CHANGE 2: A CHAINED -rename_seg NOW CHAINS. fix_macho applied every
# pair in ONE pass and gave each segment its FIRST match, so `-rename_seg
# __DATA __X -rename_seg __X __Y` ended at __X and the second pair never
# fired. Two `drydock-macho-rewrite segment` passes chain, so it ends at __Y. Asserted on
# BOTH names: __Y present is the new behaviour, __X absent is what rules out
# the old one still happening.
fresh
run fix_macho f -rename_seg __DATA __X -rename_seg __X __Y
fm_names=$( ( cd "$T" && "$BIN/drydock-macho-rewrite" info f ) 2>/dev/null )
if [ "$rc" -eq 0 ] \
    && printf '%s\n' "$fm_names" | grep -q 'segname=__Y' \
    && ! printf '%s\n' "$fm_names" | grep -q 'segname=__X'; then
    ok "fix_macho: a chained -rename_seg now produces the SECOND name, not the first"
else
    bad "fix_macho chained rename" "exit $rc; segnames: $(printf '%s\n' "$fm_names" | sed -n 's/.*\(segname=__[XY]\).*/\1/p' | tr '\n' ' ')"
fi

# A FAT CONTAINER. This is fix_macho's headline capability -- it is the reason
# the tool existed alongside change_dylib, which understood only thin files
# until the shared rewriter gave both the same fat loop.
#
# The container is BUILT HERE, in shell, from tests/fixture.macho rather than
# found by scanning the host. tests/README.md records why: a test that scanned
# for a suitable binary shipped zero coverage on the cross runner. The bytes
# are the on-disk fat convention (big-endian fat_header/fat_arch), written by
# construction, not by detection -- the same choice tests/change_dylib_test.sh
# made when it built makefat instead of calling lipo.
fm_be32() {
    printf '%b' "$(printf '\\0%o\\0%o\\0%o\\0%o' \
        $((($1 >> 24) & 255)) $((($1 >> 16) & 255)) $((($1 >> 8) & 255)) $(($1 & 255)))"
}
# fm_mkfat OUT SLICE0 CPUTYPE0 [SLICE1 CPUTYPE1] -- slices at 4096-aligned
# offsets, in the order given.
fm_mkfat() {
    fm_out=$1 fm_s0=$2 fm_ct0=$3 fm_s1=${4:-} fm_ct1=${5:-}
    fm_z0=$(wc -c < "$fm_s0" | tr -d ' ')
    fm_n=1; [ -n "$fm_s1" ] && fm_n=2
    fm_o0=4096
    {
        printf '%b' '\0312\0376\0272\0276'     # FAT_MAGIC, big-endian on disk
        fm_be32 "$fm_n"
        fm_be32 "$fm_ct0"; fm_be32 3; fm_be32 "$fm_o0"; fm_be32 "$fm_z0"; fm_be32 12
        if [ "$fm_n" -eq 2 ]; then
            fm_z1=$(wc -c < "$fm_s1" | tr -d ' ')
            fm_o1=$(( (fm_o0 + fm_z0 + 4095) / 4096 * 4096 ))
            fm_be32 "$fm_ct1"; fm_be32 3; fm_be32 "$fm_o1"; fm_be32 "$fm_z1"; fm_be32 12
        fi
        dd if=/dev/zero bs=1 count=$(( fm_o0 - 8 - 20 * fm_n )) 2>/dev/null
        cat "$fm_s0"
        if [ "$fm_n" -eq 2 ]; then
            dd if=/dev/zero bs=1 count=$(( fm_o1 - fm_o0 - fm_z0 )) 2>/dev/null
            cat "$fm_s1"
        fi
    } > "$fm_out"
}
# 0x01000007 is CPU_TYPE_X86_64, which is what tests/fixture.macho really is.
fm_mkfat "$T/fat1" "$FIXTURE" 16777223
case $(od -An -tx1 -N4 "$T/fat1" | tr -d ' ') in
    cafebabe) ok "fix_macho: the hand-built fat container really is one" ;;
    *) bad "fix_macho fat fixture" "magic is $(od -An -tx1 -N4 "$T/fat1" | tr -d ' '), not cafebabe" ;;
esac
cp "$T/fat1" "$T/fatf"
run fix_macho fatf -change /usr/lib/libSystem.B.dylib '@loader_path/../S.dylib'
if [ "$rc" -eq 0 ] && LC_ALL=C grep -q -- '@loader_path/../S.dylib' "$T/fatf" \
    && ! grep -q 'matched nothing' "$T/err"; then
    ok "fix_macho: rewrites inside a fat container, which is why this tool existed"
else
    bad "fix_macho fat" "exit $rc: $(cat "$T/err")"
fi

# A SLICE THAT IS NOT A 64-BIT MACH-O IS LEFT ALONE, and the rest of the file
# is still rewritten. This is NOT one of the five adopted changes: fix_macho
# printed "  Skipping arch N" and carried on, and the script path does the same
# thing with a different message -- "slice i386: 32-bit; passed through
# unchanged", on stderr, naming the architecture rather than an index.
# Measured, not assumed -- the fat divergence was first described as
# "refuses the whole file", which is true only of a slice that IS a 64-bit
# Mach-O whose edit failed, not of a slice that simply is not one. Asserting
# the SKIP is what keeps that distinction from being quietly widened later.
#
# 0x00000007 is CPU_TYPE_I386; the slice's bytes are filler, not a Mach-O.
dd if=/dev/zero bs=1 count=4096 2>/dev/null | tr '\000' 'Z' > "$T/junkslice"
fm_mkfat "$T/fat2" "$FIXTURE" 16777223 "$T/junkslice" 7
cp "$T/fat2" "$T/fatg"
run fix_macho fatg -change /usr/lib/libSystem.B.dylib '@loader_path/../S.dylib'
if [ "$rc" -eq 0 ] && has_line "$T/err" 'slice i386: 32-bit; passed through unchanged' \
    && LC_ALL=C grep -q -- '@loader_path/../S.dylib' "$T/fatg"; then
    ok "fix_macho: a non-64-bit slice is left unchanged and the other slice is still rewritten"
else
    bad "fix_macho fat skip" "exit $rc; stdout: $(cat "$T/out"); stderr: $(cat "$T/err")"
fi

# A 16-character NEW of 32 bytes. In a UTF-8 locale ${#3} counts characters,
# so translate.sh lets it through and mseg_name_fits refuses it; in the C
# locale translate.sh refuses it itself. Exit 1 and FILE untouched either way.
fm_mb=$(printf '\303\251%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16)
for fm_loc in en_US.UTF-8 C; do
    fresh
    fm_mb_before=$(sha "$T/f")
    case $fm_loc in
        C) fm_mb_want='new segment name longer than 16 bytes: ' ;;
        *) fm_mb_want='longer than the 16 bytes a segname field holds' ;;
    esac
    rc=0
    ( cd "$T" && LC_ALL=$fm_loc "$BIN/fix_macho" f -rename_seg __DATA "$fm_mb" ) \
        >"$T/out" 2>"$T/err" || rc=$?
    [ "$rc" -eq 1 ] && [ "$(sha "$T/f")" = "$fm_mb_before" ] \
        && grep -qF -- "$fm_mb_want" "$T/err" \
        && ok "fix_macho: a 16-character NEW of 32 bytes is refused (1), file untouched, under LC_ALL=$fm_loc" \
        || bad "fix_macho multibyte NEW ($fm_loc)" "exit $rc: $(tail -1 "$T/err")"
done

# THE CAPACITY CAPS, in fix_macho's own words. Both moved into
# compat/translate.sh when compat/fix_macho.c retired, and the -rename_seg one
# has no drydock-macho-rewrite counterpart at all -- each pair is its own `drydock-macho-rewrite segment`
# invocation, so nothing downstream would ever count them. This is the
# assertion that the message a caller sees is still fix_macho's.
fresh
i=0; fm_chg33=''
while [ $i -lt 33 ]; do fm_chg33="$fm_chg33 -change A B"; i=$((i + 1)); done
# shellcheck disable=SC2086
run fix_macho f $fm_chg33
[ "$rc" -eq 1 ] && grep -qxF 'too many -change (max 32)' "$T/err" \
    && [ "$(sha "$T/f")" = "$(sha "$FIXTURE")" ] \
    && ok "fix_macho: the -change cap refuses in fix_macho's own words, before touching the file" \
    || bad "fix_macho -change cap" "exit $rc, stderr: $(cat "$T/err")"

fresh
i=0; fm_seg17=''
while [ $i -lt 17 ]; do fm_seg17="$fm_seg17 -rename_seg __A __B"; i=$((i + 1)); done
# shellcheck disable=SC2086
run fix_macho f $fm_seg17
[ "$rc" -eq 1 ] && grep -qxF 'too many -rename_seg (max 16)' "$T/err" \
    && [ "$(sha "$T/f")" = "$(sha "$FIXTURE")" ] \
    && ok "fix_macho: the -rename_seg cap refuses, and nothing downstream would have" \
    || bad "fix_macho -rename_seg cap" "exit $rc, stderr: $(cat "$T/err")"

# Usage and refusals, in fix_macho's own words, naming argv[0] where it did.
run fix_macho f
[ "$rc" -eq 1 ] && firstline_is "$T/err" "Usage: $BIN/fix_macho <file> [-change old new] [-strip_build_version]" \
    && ok "fix_macho: too few arguments is a usage error naming argv[0]" \
    || bad "fix_macho usage" "exit $rc, stderr: $(head -1 "$T/err")"
fresh
run fix_macho f -nope
[ "$rc" -eq 1 ] && grep -qxF 'Unknown option: -nope' "$T/err" \
    && ok "fix_macho: an unknown flag refuses in fix_macho's own words" \
    || bad "fix_macho unknown flag" "exit $rc, stderr: $(cat "$T/err")"
fresh
run fix_macho f -rename_seg __DATA 12345678901234567
[ "$rc" -eq 1 ] && grep -qxF 'new segment name longer than 16 bytes: 12345678901234567' "$T/err" \
    && ok "fix_macho: a 17-byte NEW segment name is refused before any I/O" \
    || bad "fix_macho long segname" "exit $rc, stderr: $(head -1 "$T/err")"

# An absent file, and an unwritable one: fix_macho opened O_RDWR before it
# looked at anything, so both failed immediately with perror("open"). An
# invocation that emits one of mr_apply_file's verbs gets that from its own
# O_RDWR; one that emits `drydock-macho-rewrite edit` does not, because me_run reads the
# image O_RDONLY and only finds out it cannot write at the END of the run --
# which is why the wrapper checks for itself, and why both cases below are
# MULTI-command.
#
# BOTH CASES DISCRIMINATE NOW, and the unwritable one more sharply than
# before. Remove the wrapper's check and the absent file reports drydock-macho-rewrite's
# "drydock-macho-rewrite edit: nosuchfile: cannot open or read" instead of fix_macho's own
# words; the unwritable one SUCCEEDS -- measured -- because drydock-macho-rewrite edit
# writes the wrapper's temp (not FILE) via wa_write_new, and mw_finish's mv
# lands that temp on FILE, which needs the DIRECTORY to be writable and not
# the file, so a mode-444 binary is replaced (new inode, mode 444 carried
# over from FILE's own stat) and the run exits 0 where fix_macho's O_RDWR
# refused. The check below is the only thing standing between a caller and
# that silent rewrite. Each was mutation-tested.
run fix_macho nosuchfile -strip_build_version -change A B
[ "$rc" -eq 1 ] && has_line "$T/err" 'open: No such file or directory' \
    && ok "fix_macho: an absent file fails immediately, in fix_macho's own words" \
    || bad "fix_macho absent" "exit $rc, stderr: $(cat "$T/err")"
fresh
chmod 444 "$T/f"
before=$(sha "$T/f")
run fix_macho f -strip_build_version -change A B
fm_ro_rc=$rc
chmod 644 "$T/f"
[ "$fm_ro_rc" -eq 1 ] && has_line "$T/err" 'open: Permission denied' \
    && [ "$(sha "$T/f")" = "$before" ] \
    && ok "fix_macho: an unwritable file fails before the multi-command rewrite runs" \
    || bad "fix_macho unwritable" "exit $fm_ro_rc, stderr: $(cat "$T/err")"

# THE EXIT-CODE FOLD. fix_macho had two exit codes, 0 and 1; drydock-macho-rewrite has a
# third -- EX_FAIL, 2, for an operational failure rather than a considered
# refusal -- and compat/fix_macho.sh folds every nonzero to 1. A DIRECTORY as
# FILE is the input that reaches it: mw_prepare's hard-link check is for
# regular files only, so a directory falls through to drydock-macho-rewrite, whose read of
# it fails with 2. The first assertion is what keeps the second honest -- if
# drydock-macho-rewrite ever stops answering 2 here, the fold below is proving nothing and
# says so rather than passing quietly.
rm -rf "$T/fmdir"; mkdir "$T/fmdir"
fm_mt_rc=0
( cd "$T" && printf 'dylib replace /nope /also-nope\n' | "$BIN/drydock-macho-rewrite" fmdir fmdir.new ) \
    >/dev/null 2>"$T/err" || fm_mt_rc=$?
[ "$fm_mt_rc" -eq 2 ] \
    && ok "fix_macho: drydock-macho-rewrite's own code for this input is 2, the code fix_macho never had" \
    || bad "fix_macho exit fold" "drydock-macho-rewrite exited $fm_mt_rc, not 2, so nothing below tests the fold -- find an input that still reaches EX_FAIL, or this assertion is the only thing left pinning the fold at all"
run fix_macho fmdir -change /nope /also-nope
[ "$rc" -eq 1 ] \
    && ok "fix_macho: every nonzero drydock-macho-rewrite exit is folded to 1, the only failure code fix_macho ever had" \
    || bad "fix_macho exit fold" "exit $rc: a caller that learned this grammar in 2024 branches on 0-or-1, so forwarding drydock-macho-rewrite's 2 invents a third outcome for a grammar that has two"
rm -rf "$T/fmdir" "$T/fmdir.new"

# A REFUSAL PART WAY THROUGH A MULTI-STATEMENT RUN LEAVES FILE EXACTLY AS IT
# WAS. Two families, so one `drydock-macho-rewrite edit`: me_run reads the image once,
# applies every statement in memory, verifies, and writes once. The -change
# below needs far more room than the fixture's header pad, and this copy is
# not PIE so the header cannot grow, so the run is refused at statement 2 of
# 2 -- after statement 1 was applied in memory.
fresh
unpie "$T/f"
fm_before=$(sha "$T/f")
fm_huge="@loader_path/"
i=0
while [ $i -lt 500 ]; do fm_huge="${fm_huge}longlongl"; i=$((i + 1)); done
fm_huge="${fm_huge}.dylib"
run fix_macho f -strip_build_version -change /usr/lib/libSystem.B.dylib "$fm_huge"
[ "$rc" -eq 1 ] && [ "$(sha "$T/f")" = "$fm_before" ] \
    && ok "fix_macho: a refusal at a later statement leaves FILE byte-identical, not half-edited" \
    || bad "fix_macho mid-script refusal" "exit $rc and FILE $([ "$(sha "$T/f")" = "$fm_before" ] && echo 'is unchanged' || echo 'WAS MODIFIED'): a caller whose file is left carrying statement 1 of a refused run has a binary nobody asked for; stderr: $(tail -1 "$T/err")"
ls -a "$T" | grep -q 'drydock-macho-rewrite-compat' \
    && bad "fix_macho mid-script refusal" "a temp was left beside FILE: [$(ls -a "$T" | grep 'drydock-macho-rewrite-compat' | tr '\n' ' ')]" \
    || ok "fix_macho: ... and leaves no temp beside it"
# ...and the refusal is reported as a refusal. The wrapper must stop on
# drydock-macho-rewrite's nonzero rather than fall through to mw_finish, whose mv of a
# temp drydock-macho-rewrite never wrote would blame the INSTALL for a refusal that
# happened upstream. Both paths exit 1, so the diagnostic is the only
# difference a caller can see.
! grep -q 'the rewrite succeeded but installing it failed' "$T/err" \
    && ok "fix_macho: ... and says the run was refused, not that installing it failed" \
    || bad "fix_macho mid-script refusal" "a refused run told the caller the rewrite succeeded and the install failed, which sends them looking at directory permissions for a refusal drydock-macho-rewrite made about their image: $(grep 'installing it failed' "$T/err")"

# The grow is library code, so the refusal a user sees names no program.
grep -q '^ERROR: executable is not PIE (flags=0x' "$T/err" \
    && ! grep -q '^macho_grow: ' "$T/err" \
    && ok "fix_macho: ... and the grow's own refusal begins 'ERROR: ', naming no program" \
    || bad "fix_macho mid-script refusal" "the grow's refusal is not program-neutral: $(grep 'not PIE' "$T/err")"

# ADOPTED CHANGE 6: THE SAME -change ON A PIE COPY GROWS THE HEADER. fix_macho
# had no -grow and refused; the wrapper lowers the image base to make room,
# and says so on stderr.
fresh
run fix_macho f -change /usr/lib/libSystem.B.dylib "$fm_huge"
[ "$rc" -eq 0 ] && grep -q '^f: grew the header pad by ' "$T/err" \
    && LC_ALL=C grep -q -- "$fm_huge" "$T/f" \
    && ok "fix_macho: a replacement the pad cannot hold grows the header, announced (0)" \
    || bad "fix_macho grow" "exit $rc (want 0, announced, the path in FILE): $(cut -c1-300 "$T/err")"

# THE INSTALL IS A RENAME, not a write through FILE. drydock-macho-rewrite writes a temp
# beside FILE and mw_finish mv's it over, which is what makes FILE wholly old
# or wholly new; fix_macho lseek'd to 0 and wrote over itself, so a kill
# mid-write left a corrupt binary. The INODE is what tells the two apart --
# the bytes cannot.
fresh
fm_ino=$(stat -f %i "$T/f")
run fix_macho f -change /usr/lib/libSystem.B.dylib '@loader_path/../S.dylib'
[ "$rc" -eq 0 ] && [ "$(sha "$T/f")" != "$(sha "$FIXTURE")" ] \
    && [ "$(stat -f %i "$T/f")" != "$fm_ino" ] \
    && ok "fix_macho: a changed run installs by rename, so FILE gets a new inode" \
    || bad "fix_macho install by rename" "exit $rc, inode $fm_ino -> $(stat -f %i "$T/f"): the same inode means something wrote over the caller's file in place, so an interrupted run can leave a half-written binary -- the failure these tools exist to prevent"

# ---- hostile argv shapes -----------------------------------------------
#
# A path with a SPACE, a path with a LEADING DASH, and an EMPTY string. All
# three are shapes the wrappers were fixed for -- translate.sh's mt_quote does
# the quoting, for the verb form and for the edit script's statements alike
# (src/script.c's ms_split reads a statement's words by a shell's rules, which
# is why one quoting serves both) -- and none of them was covered, so the
# fixes could have regressed silently. The reviewer verified all three against
# the pre-wrapper binaries; these keep them verified.

# A SPACE in the file name, on the mixed-family path -- the one that emits
# `drydock-macho-rewrite edit FILE <temp> -`, so the path is quoted into an edit command line
# rather than a verb's. Asserted by comparing against the same operations on
# an ordinarily-named copy.
fresh
cp "$FIXTURE" "$T/has space"
( cd "$T" && "$BIN/change_dylib" "has space" -strip-lc uuid \
    -change /usr/lib/libSystem.B.dylib '@loader_path/../S.dylib' ) >/dev/null 2>"$T/err"
rc=$?
( cd "$T" && "$BIN/change_dylib" f -strip-lc uuid \
    -change /usr/lib/libSystem.B.dylib '@loader_path/../S.dylib' ) >/dev/null 2>&1
[ "$rc" -eq 0 ] && cmp -s "$T/has space" "$T/f" \
    && ok "change_dylib: a file name with a space rewrites identically" \
    || bad "change_dylib spaced path" "exit $rc: $(cat "$T/err")"
rm -f "$T/has space"

# A LEADING DASH. Every one of these tools took argv[1] as a path
# unconditionally, so `-dashy` is a file name, not an option.
fresh
cp "$FIXTURE" "$T/-dashy"
before=$(sha "$T/-dashy")
( cd "$T" && "$BIN/change_dylib" -dashy -strip-lc uuid ) >/dev/null 2>"$T/err"
rc=$?
[ "$rc" -eq 0 ] && [ "$(sha "$T/-dashy")" != "$before" ] \
    && ok "change_dylib: a file name starting with a dash is a file name" \
    || bad "change_dylib leading dash" "exit $rc: $(cat "$T/err")"
# ...and on the mixed-family path, where the name reaches `drydock-macho-rewrite edit` as its
# FILE positional. That is its own guard: `edit` is the one verb with flags to
# scan past, and cli/drydock-macho-rewrite.c's parser takes a single-dash token as a file name
# for exactly this reason -- rejecting it made this case fail the moment the
# wrappers started emitting `edit`. Compared against the SAME operations on an
# ordinarily-named copy, so both sides are rewritten here rather than relying
# on whatever $T/f happens to hold.
fresh
cp "$FIXTURE" "$T/-dashy"
( cd "$T" && "$BIN/change_dylib" -dashy -strip-lc uuid \
    -change /usr/lib/libSystem.B.dylib '@loader_path/../S.dylib' ) >/dev/null 2>"$T/err"
rc=$?
( cd "$T" && "$BIN/change_dylib" f -strip-lc uuid \
    -change /usr/lib/libSystem.B.dylib '@loader_path/../S.dylib' ) >/dev/null 2>&1
[ "$rc" -eq 0 ] && cmp -s "$T/-dashy" "$T/f" \
    && ok "change_dylib: and on the multi-command path, where it reaches drydock-macho-rewrite as a positional" \
    || bad "change_dylib leading dash, mixed" "exit $rc: $(cat "$T/err")"
rm -f "$T/-dashy"

# The same leading-dash shape for fix_macho, on its single-command path --
# one -change, so one `drydock-macho-rewrite dylib` line. What is at stake: FILE reaches
# cmd_dylib_or_rpath as argv[2], read positionally, never scanned for a
# leading dash the way an option would be -- so `$1` passing through
# mt_translate unexamined is the guard this pins, same file-not-option
# question as change_dylib's case above. -change, not -strip_build_version,
# because tests/fixture.macho carries no LC_BUILD_VERSION to strip (see
# below) and a no-op would not tell the dash apart from a typo.
fresh
cp "$FIXTURE" "$T/-dashy"
before=$(sha "$T/-dashy")
run fix_macho -dashy -change /usr/lib/libSystem.B.dylib '@loader_path/../S.dylib'
[ "$rc" -eq 0 ] && [ "$(sha "$T/-dashy")" != "$before" ] \
    && ok "fix_macho: a file name starting with a dash is a file name" \
    || bad "fix_macho leading dash" "exit $rc: $(cat "$T/err")"
rm -f "$T/-dashy"

# THE TAUGHT BLOCK ITSELF MUST BE PASTEABLE, not just descriptive
# (compat/translate.sh's "reads as a pasteable equivalent" claim). For a
# leading-dash FILE with no directory part, FILE.new begins with '-' too, and
# drydock-macho-rewrite deliberately refuses an OUT spelled that way -- so before
# mt_out_for/mt_install_line learned to write OUT as ./FILE.new here, the
# printed macho9 line looked right but failed the moment it was copied and
# run on its own, even though the wrapper's own real run (its temp is always
# dot-prefixed, mw_prepare) went through fine. Pin it end to end: run the
# wrapper for real in one directory, pull the taught block back out of its
# stderr and run it verbatim in a second, identically-seeded directory, and
# compare the two results byte-for-byte.
#
# A GENUINELY FRESH ENVIRONMENT, via `env -i` into a new /bin/sh, not an
# `eval` in a subshell that inherits this script's. What is being claimed is
# that a reader can paste the block somewhere else and have it work, so the
# test must not lend it anything of ours -- and `env -i PATH=...` is the only
# form that proves the taught program word resolves to the binary shipped
# beside the wrapper rather than to something this process happened to have.
# It is also the contract that used to need a `macho9` symlink beside
# `drydock-macho-rewrite` to hold, so it is the check that the symlink's deletion rested
# on. /usr/bin and /bin are on the PATH for `mv`, which the install line the
# block ends with needs.
fresh
mkdir "$T/wrap" "$T/taught"
cp "$FIXTURE" "$T/wrap/-dashy"
cp "$FIXTURE" "$T/taught/-dashy"
( cd "$T/wrap" && "$BIN/change_dylib" -dashy -change /usr/lib/libSystem.B.dylib '@loader_path/../S.dylib' ) \
    >/dev/null 2>"$T/err"
rc=$?
taught=$(awk '/^    /{sub(/^    /, ""); print}' "$T/err")
( cd "$T/taught" && env -i PATH="$BIN:/usr/bin:/bin" /bin/sh -c "$taught" ) >/dev/null 2>"$T/err2"
rc2=$?
[ "$rc" -eq 0 ] && [ "$rc2" -eq 0 ] && [ -n "$taught" ] \
    && cmp -s "$T/wrap/-dashy" "$T/taught/-dashy" \
    && ok "change_dylib: the taught block for a leading-dash FILE runs verbatim and matches the wrapper" \
    || bad "change_dylib leading-dash taught block" \
        "wrapper rc $rc, taught rc $rc2, taught: [$taught], stderr2: $(cat "$T/err2")"
rm -rf "$T/wrap" "$T/taught"

# An EMPTY NEW segment name: legal (a segname may be all NULs) and matched by
# tests/compat-matrix.tsv's `rename_segment f __DATA ''` row, whose C-side
# output was "f: renamed 1 segment(s) __DATA -> " with the trailing space.
fresh
run rename_segment f __DATA ''
[ "$rc" -eq 0 ] && grep -qxF 'f: renamed 1 segment(s) __DATA -> ' "$T/out" \
    && ok "rename_segment: an empty NEW name is accepted, and printed as empty" \
    || bad "rename_segment empty NEW" "exit $rc, stdout: [$(cat "$T/out")]"

# An EMPTY file name reaches open() as "" and fails there, on both sides.
run change_dylib '' -strip-lc uuid
[ "$rc" -ne 0 ] \
    && ok "change_dylib: an empty file name fails rather than acting on something else" \
    || bad "change_dylib empty path" "exit 0"

# A SPACE in a retag_swift_classes argument, which is variadic -- so the space
# must not split one file into two.
fresh
cp "$FIXTURE" "$T/two words"
( cd "$T" && "$BIN/retag_swift_classes" "two words" f ) >"$T/out" 2>"$T/err"
rc=$?
[ "$rc" -eq 0 ] && grep -qxF 'total: 0 class record(s) retagged' "$T/out" \
    && [ "$(wc -l < "$T/out" | tr -d ' ')" = 1 ] \
    && ok "retag_swift_classes: a spaced argument stays one file" \
    || bad "retag_swift_classes spaced path" "exit $rc, stdout: $(cat "$T/out")"
rm -f "$T/two words"

# ---- conflicts resolve in the order written ------------------------------
#
# Two operations naming the same path apply one after the other, exactly as
# typed -- the same rule whether the invocation touches one family or three.
#
# THIS IS A RULING, AND THE SHAPES BELOW ARE THE ONES IT MOVED. The
# pre-migration wrappers had no single rule to preserve: one family emitted a
# VERB (one mr_ops, applied as a batch, with mr_is_deleted's delete-wins
# precedence) and more than one emitted a SCRIPT (a sequence), so the same
# conflict got two different answers depending on whether an unrelated flag
# from another family happened to be present.
#
# Each assertion states the NEW answer, measured against the pre-migration
# binaries (commit 18ad6f0, built in a throwaway worktree) so that what moved
# is on the record. The oracle is `drydock-macho-rewrite info`, a read-only query, never a
# verb: these have to outlive the verbs.
SYSLIB=/usr/lib/libSystem.B.dylib
ABSENT=/absent/p.dylib

# 1. A -delete written AFTER a -change no longer wins. The rename happens
#    first, so the delete matches nothing and the dylib survives under its new
#    name. The parent deleted it -- as a batch when one family was present
#    (mr_is_deleted) and as a hoisted statement when several were, which is the
#    one thing both of its paths agreed on.
#    On a dylib nothing binds to, since deleting a bound one is refused first.
for cd_extra in '' '-strip-lc uuid'; do
    cd_label='one family'; [ -n "$cd_extra" ] && cd_label='several families'
    fresh
    run change_dylib f -add "$ABSENT"
    run change_dylib f $cd_extra -change "$ABSENT" /also/absent.dylib -delete "$ABSENT"
    cd_info=$( "$BIN/drydock-macho-rewrite" info "$T/f" 2>/dev/null )
    [ "$rc" -eq 0 ] && printf '%s\n' "$cd_info" | grep -q 'path=/also/absent.dylib' \
        && ! printf '%s\n' "$cd_info" | grep -q "path=$ABSENT" \
        && ok "change_dylib: -change then -delete renames, and the delete finds nothing ($cd_label)" \
        || bad "change_dylib order, change-then-delete ($cd_label)" "exit $rc; the dylib was DELETED, which is the old batch's delete-wins rule surviving in the emitter -- and it makes an unrelated flag from another family change the answer again"
    # ... and written the other way round the delete still goes first, so the
    #     dylib really is gone. Unchanged from the parent, and asserted so the
    #     rule above cannot be mistaken for "-delete never wins".
    fresh
    run change_dylib f -add "$ABSENT"
    run change_dylib f $cd_extra -delete "$ABSENT" -change "$ABSENT" /also/absent.dylib
    cd_info=$( "$BIN/drydock-macho-rewrite" info "$T/f" 2>/dev/null )
    [ "$rc" -eq 0 ] && ! printf '%s\n' "$cd_info" | grep -q "path=$ABSENT" \
        && ! printf '%s\n' "$cd_info" | grep -q 'path=/also/absent.dylib' \
        && ok "change_dylib: ... and -delete then -change deletes ($cd_label)" \
        || bad "change_dylib order, delete-then-change ($cd_label)" "exit $rc; the first flag written did not win"
done

# 2. A -reexport and a -change on one path BOTH apply, in order. The parent
#    applied one and shadowed the other -- which one depended on the order AND
#    on whether another family was present.
fresh
run change_dylib f -reexport "$SYSLIB" -change "$SYSLIB" /usr/lib/replaced.dylib
cd_info=$( "$BIN/drydock-macho-rewrite" info "$T/f" 2>/dev/null )
[ "$rc" -eq 0 ] && printf '%s\n' "$cd_info" | grep -q 'LC_REEXPORT_DYLIB' \
    && printf '%s\n' "$cd_info" | grep -q 'path=/usr/lib/replaced.dylib' \
    && ok "change_dylib: -reexport then -change reexports AND renames" \
    || bad "change_dylib reexport then change" "exit $rc; one of the two operations was dropped, which is the old shadowing rule: $(printf '%s\n' "$cd_info" | grep -i 'reexport\|libSystem\|replaced')"
fresh
run change_dylib f -strip-lc uuid -change "$SYSLIB" /usr/lib/replaced.dylib -reexport "$SYSLIB"
cd_info=$( "$BIN/drydock-macho-rewrite" info "$T/f" 2>/dev/null )
[ "$rc" -eq 0 ] && ! printf '%s\n' "$cd_info" | grep -q 'LC_REEXPORT_DYLIB' \
    && printf '%s\n' "$cd_info" | grep -q 'path=/usr/lib/replaced.dylib' \
    && ok "change_dylib: -change then -reexport renames, and the reexport then matches nothing" \
    || bad "change_dylib change then reexport" "exit $rc; the reexport acted on a path the rename had already moved"

# 3. The rpath spellings resolve the same way, and an unrelated family changes
#    nothing. The parent's multi-family path hoisted the rpath delete, giving
#    LC_RPATH a delete-wins rule that its own one-pass code never had.
for rp_extra in '' '-strip-lc uuid'; do
    rp_label='one family'; [ -n "$rp_extra" ] && rp_label='several families'
    fresh
    run change_dylib f -add-rpath /r/one
    run change_dylib f $rp_extra -change-rpath /r/one /r/two -delete-rpath /r/one
    [ "$rc" -eq 0 ] && "$BIN/drydock-macho-rewrite" info "$T/f" 2>/dev/null | grep -q 'rpath=/r/two' \
        && ok "change_dylib: -change-rpath then -delete-rpath renames ($rp_label)" \
        || bad "change_dylib rpath order ($rp_label)" "exit $rc; the rpath was DELETED -- a binary that should now look for its libraries at /r/two has no rpath at all"
    fresh
    run change_dylib f -add-rpath /r/one
    run change_dylib f $rp_extra -delete-rpath /r/one -change-rpath /r/one /r/two
    [ "$rc" -eq 0 ] && ! "$BIN/drydock-macho-rewrite" info "$T/f" 2>/dev/null | grep -q 'rpath=/r/' \
        && ok "change_dylib: ... and -delete-rpath then -change-rpath deletes ($rp_label)" \
        || bad "change_dylib rpath order ($rp_label)" "exit $rc; the first flag written did not win"
done

# 4. A CHAIN TRANSLATES AND RUNS. It used to be REFUSED -- exit 1, nothing
#    written -- whenever more than one family was present, and after the
#    previous round whenever it appeared at all. Now `-change a b -change b c`
#    renames the a's to b and then those b's to c, which is what was asked for
#    in the order it was asked.
fresh
run change_dylib f -strip-lc uuid -change "$SYSLIB" /usr/lib/mid.dylib -change /usr/lib/mid.dylib /usr/lib/end.dylib
cd_info=$( "$BIN/drydock-macho-rewrite" info "$T/f" 2>/dev/null )
[ "$rc" -eq 0 ] && printf '%s\n' "$cd_info" | grep -q 'path=/usr/lib/end.dylib' \
    && ! printf '%s\n' "$cd_info" | grep -q 'path=/usr/lib/mid.dylib' \
    && ok "change_dylib: a -change chain lands on the LAST name, instead of being refused" \
    || bad "change_dylib chain" "exit $rc; a chain is a capability again -- exit 1 here means the refusal came back, and a stop at the middle name means the statements are not running in order"
# The rpath chain, which the previous round left refused even after the dylib
# one was fixed.
fresh
run change_dylib f -add-rpath /r/one
run change_dylib f -strip-lc uuid -change-rpath /r/one /r/mid -change-rpath /r/mid /r/end
[ "$rc" -eq 0 ] && "$BIN/drydock-macho-rewrite" info "$T/f" 2>/dev/null | grep -q 'rpath=/r/end' \
    && ok "change_dylib: an rpath chain lands on the last name too" \
    || bad "change_dylib rpath chain" "exit $rc; the rpath chain is still refused or still stops at the middle name"
# fix_macho's -change, same rule, and its chain was refused too.
fresh
run fix_macho f -strip_build_version -change "$SYSLIB" /usr/lib/mid.dylib -change /usr/lib/mid.dylib /usr/lib/end.dylib
[ "$rc" -eq 0 ] && "$BIN/drydock-macho-rewrite" info "$T/f" 2>/dev/null | grep -q 'path=/usr/lib/end.dylib' \
    && ok "fix_macho: a -change chain lands on the last name" \
    || bad "fix_macho chain" "exit $rc; fix_macho's chain did not run through"
# A SWAP runs too, and lands where a sequence lands: b becomes a, then every a
# -- including the ones the first statement just made -- becomes b.
fresh
swap_before=$(sha "$T/f")
run change_dylib f -change "$SYSLIB" /usr/lib/swapped.dylib -change /usr/lib/swapped.dylib "$SYSLIB"
[ "$rc" -eq 0 ] && [ "$(sha "$T/f")" = "$swap_before" ] \
    && ok "change_dylib: a swap renames and renames back, leaving the file as it was" \
    || bad "change_dylib swap" "exit $rc; a swap should run both statements in order and land back on the original name"

# ---- the three tools whose verbs were THIN-ONLY --------------------------
#
# `minos`, `declassify` and `retag-swift` all began with mi_open, which refuses
# a fat container; so did the C tools. A script goes through mr_process_fat and
# rewrites EVERY SLICE. drydock-macho-rewrite gained that deliberately and keeps it -- but a
# compat wrapper may not change which invocations succeed, so mw_thin_only
# (compat/drydock-macho-rewrite-compat.sh) puts these three back where they were. Each
# assertion below is the measured pre-migration answer.
fm_mkfat "$T/fatthin" "$FIXTURE" 16777223 "$FIXTURE" 16777223

cp "$T/fatthin" "$T/f"; fat_before=$(sha "$T/f")
run add_version_min f
[ "$rc" -eq 1 ] && [ "$(sha "$T/f")" = "$fat_before" ] \
    && has_line "$T/err" 'f: not a readable 64-bit Mach-O' \
    && ok "add_version_min: a fat container is refused, untouched, as mv_add_version_min's own mi_open did" \
    || bad "add_version_min fat" "exit $rc (want 1), changed=$([ "$(sha "$T/f")" = "$fat_before" ] && echo no || echo YES); a caller that branched on this exit code now gets a rewritten fat binary instead of a refusal: $(cat "$T/err")"

cp "$T/fatthin" "$T/f"; rm -f "$T/fatout"
run patch_macho f fatout
[ "$rc" -eq 1 ] && [ ! -e "$T/fatout" ] \
    && ok "patch_macho: a fat container is refused and no output is created" \
    || bad "patch_macho fat" "exit $rc (want 1), output present=$([ -e "$T/fatout" ] && echo yes || echo no); install.sh's wrapper runs this first and aborts on nonzero, so a 0 here changes what the whole pipeline does"

mkswift_fixture "$T/sw1"
fm_mkfat "$T/fatswift" "$T/sw1" 16777223 "$T/sw1" 16777223
cp "$T/fatswift" "$T/f"; fat_before=$(sha "$T/f")
run retag_swift_classes f
[ "$rc" -eq 0 ] && [ "$(sha "$T/f")" = "$fat_before" ] \
    && has_line "$T/out" 'total: 0 class record(s) retagged' \
    && ok "retag_swift_classes: a fat container is the benign skip it always was, and the file is untouched" \
    || bad "retag_swift_classes fat" "exit $rc, changed=$([ "$(sha "$T/f")" = "$fat_before" ] && echo no || echo YES); this is the SILENT one -- same exit code, same 'total: 0' line, and the caller's binary rewritten underneath it"

# A chained Swift binary: drydock-macho-rewrite refuses swift-abi set legacy on
# it (1), and this wrapper's exit-1 arm is its silent skip, so the caller gets
# what the C tool gave -- exit 0, total 0, the file untouched.
[ -x "$T/mkchained" ] || "$CC" -O2 -I "$ROOT/src" -o "$T/mkchained" "$HERE/mkchained.c" \
    || bad "retag_swift_classes chained: fixture setup" "cannot build $HERE/mkchained.c"
"$T/mkchained" make-swift "$T/f" || bad "retag_swift_classes chained: fixture setup" "make-swift failed"
ch_before=$(sha "$T/f")
run retag_swift_classes f
[ "$rc" -eq 0 ] && [ "$(sha "$T/f")" = "$ch_before" ] \
    && has_line "$T/out" 'total: 0 class record(s) retagged' \
    && ok "retag_swift_classes: a chained Swift binary is the C tool's silent zero, untouched" \
    || bad "retag_swift_classes chained" "exit $rc: $(cat "$T/out") $(cat "$T/err")"

# WHY THE COUNT IS SUMMED. drydock-macho-rewrite reports what it retagged once per SLICE,
# so a fat argument yields one line per slice. Read as a single number that is
# "2\n2", which `[ "$mw_n" -gt 0 ]` rejects outright. Asserted against drydock-macho-rewrite
# directly, because mw_thin_only means this wrapper no longer feeds it a fat
# file -- the arithmetic still has to be right, and this is what says why.
rt_lines=$( printf 'swift-abi set legacy\n' \
    | "$BIN/drydock-macho-rewrite" "$T/fatswift" "$T/fatswift.out" 2>&1 >/dev/null \
    | grep -c 'retagged' )
[ "$rt_lines" -eq 2 ] \
    && ok "drydock-macho-rewrite reports a retag once per slice, which is why the wrapper SUMS the count" \
    || bad "retag count per slice" "$rt_lines 'retagged' lines for a two-slice fat file, want 2; if this is now 1 the sum is pointless, and if it is more than one line the wrapper's count must add them up rather than read them as one number"

# ---- the gate is `info --thin`, not plain `info` -------------------------
#
# The thin-only gate is info --thin: a fat container is still refused, asserted on each wrapper's exit and file.
fm_mkfat "$T/gatefat" "$FIXTURE" 16777223 "$FIXTURE" 16777223
for gate_tool in patch_macho add_version_min rename_segment retag_swift_classes; do
    # fatswift has records to retag, so a broken gate would change its bytes.
    case $gate_tool in
        retag_swift_classes) cp "$T/fatswift" "$T/gf" ;;
        *)                   cp "$T/gatefat" "$T/gf" ;;
    esac
    gate_before=$(sha "$T/gf")
    rm -f "$T/gfout"
    case $gate_tool in
        rename_segment)      run rename_segment gf __DATA __DATB; gate_want=1 ;;
        patch_macho)         run patch_macho gf gfout;            gate_want=1 ;;
        # The gate's refusal is retag's benign skip: exit 0, file untouched.
        retag_swift_classes) run retag_swift_classes gf;          gate_want=0 ;;
        *)                   run "$gate_tool" gf;                 gate_want=1 ;;
    esac
    [ "$rc" -eq "$gate_want" ] \
        && ok "$gate_tool: a fat container is still refused ($gate_want)" \
        || bad "$gate_tool fat gate" "exited $rc, not $gate_want: $(cat "$T/err")"
    [ "$(sha "$T/gf")" = "$gate_before" ] \
        && ok "$gate_tool: the refused fat container is untouched" \
        || bad "$gate_tool fat gate" "the input changed"
done

# EX_FAIL still falls through, which is what makes `add_version_min <dir>`
# exit 2 on both sides. A directory is the measurement mw_thin_only's own
# comment names.
run add_version_min "$T"
[ "$rc" -eq 2 ] && ok "mw_thin_only: EX_FAIL (2) still falls through" \
    || bad "mw_thin_only EX_FAIL" "a directory did not exit 2, got $rc"

# ---- insert_dylib's prompts fire on a fat binary --------------------------
#
# Prompt 2 on a fat binary: tested through the no-tty refusal, which prints
# the prompt text to stderr (the prompt itself goes to fd 3). idnotty is
# insert_dylib_test's notty.c in miniature.
cat >"$T/idnotty.c" <<'EOF'
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    setsid();
    execvp(argv[1], argv + 1);
    return 127;
}
EOF
"$CC" -O2 -o "$T/idnotty" "$T/idnotty.c" 2>"$T/idnotty_build.err"
if [ ! -x "$T/idnotty" ]; then
    skip "insert_dylib fat prompt" "cannot build the notty helper: $(cat "$T/idnotty_build.err")"
elif [ ! -x "$BIN/insert_dylib" ]; then
    skip "insert_dylib fat prompt" "$BIN/insert_dylib is not installed"
else
    id_have=/usr/lib/libdrydock_slice2_only.dylib
    printf 'dylib append %s\n' "$id_have" | "$BIN/drydock-macho-rewrite" "$FIXTURE" "$T/idslice2" >/dev/null 2>&1
    fm_mkfat "$T/idfat" "$FIXTURE" 16777223 "$T/idslice2" 16777223
    "$BIN/drydock-macho-rewrite" info "$T/idfat" >"$T/idfat.info" 2>/dev/null
    id_s1=$(awk '/^slice /{n++} n==1' "$T/idfat.info" | grep -cF "path=$id_have")
    id_s2=$(awk '/^slice /{n++} n==2' "$T/idfat.info" | grep -cF "path=$id_have")
    if [ "$id_s1" -ne 0 ] || [ "$id_s2" -ne 1 ]; then
        bad "insert_dylib fat prompt" "wanted $id_have named by slice 2 only, got slice 1: $id_s1, slice 2: $id_s2; this proves nothing"
    else
        # --no-strip-codesig keeps prompt 1 out of the way, so prompt 2 is
        # the only one this run can reach.
        ( cd "$T" && "$T/idnotty" "$BIN/insert_dylib" --no-strip-codesig \
            "$id_have" idfat idfat.out </dev/null ) >"$T/id.out" 2>"$T/id.err"
        rc=$?
        if [ "$rc" -eq 1 ] && grep -qF 'already contains a load command for that dylib' "$T/id.err"; then
            ok "insert_dylib: the duplicate-dylib prompt fires on a fat binary whose second slice alone names the dylib"
        else
            bad "insert_dylib fat prompt" "exit $rc (want 1, refused with no tty to ask on): $(cat "$T/id.err")"
        fi
    fi
fi

# ---- the emitted grammar is one this build actually has -----------------
#
# Same check tests/translate_test.sh makes of the translator, made here of the
# wrappers: every STATEMENT a wrapper can reach must be one this drydock-macho-rewrite
# advertises, with the arity the emitted script uses. Hardcoding that agreement
# is how the ops=/kinds= lists in cli/drydock-macho-rewrite.c drifted from their own parsers
# once already. A statement this build does not know is worse than a missing
# verb: the script fails to parse AFTER the wrapper has already told the caller
# what it was about to run.
"$BIN/drydock-macho-rewrite" --capabilities > "$T/caps" 2>/dev/null
for st in 'fixups set 1' 'minos if-absent 1' 'swift-abi set 1' 'segment rename 2' \
          'load-command delete 1' 'dylib replace 2' 'dylib delete 1' 'dylib reexport 1' \
          'dylib append 1' 'dylib insert 1' 'rpath replace 2' 'rpath delete 1' \
          'rpath append 1'; do
    grep -qxF "statement $st" "$T/caps" \
        && ok "capabilities: this build advertises the $st statement" \
        || bad "capabilities" "'$st' is not advertised, but a wrapper emits it -- a caller would get a parse error after being told the command was about to run"
done

echo "wrapper_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
