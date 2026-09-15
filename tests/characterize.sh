#!/bin/sh
# Characterization: run the whole pipeline over a committed fixture and hash the
# result. The tools are deterministic file transformers, so the OUTPUT is the
# invariant worth pinning -- not the tool binaries, which can never match across
# a 2014 clang and a 2026 one.
#
#   sh tests/characterize.sh <bindir>        print the digest
#   sh tests/characterize.sh <bindir> check  compare against tests/EXPECTED
#
# This is what makes "native on 10.9" and "cross from a modern host"
# comparable: build both ways, run this, and the digests must match. A
# cross-built tool is x86_64 with a 10.9 floor, which still runs on a modern
# host (a deployment target is a floor, not a ceiling), so CI can execute it.
set -e
BIN="${1:?usage: characterize.sh <bindir> [check]}"
MODE="${2:-print}"
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d /tmp/macho-characterize.XXXXXX)
trap 'rm -rf "$T"' EXIT INT TERM

# `set -e` means any bare command above that exits nonzero kills the whole
# script immediately, before the digest is ever computed or compared --
# exiting nonzero with no OK/MISMATCH line at all. This says so loudly rather
# than leaving that silent; see tests/cli_test.sh:133-145 for the pattern and
# the incident that motivated it.
reached_end=0
trap 'rc=$?; rm -rf "$T"; if [ "$reached_end" -eq 0 ]; then
    echo "characterize: FATAL -- aborted early (a command exited $rc under set -e); the suite did NOT run to completion, and the digest was never computed or compared" >&2
fi' EXIT

cp "$HERE/fixture.macho" "$T/in"
"$BIN/patch_macho"     "$T/in" "$T/out" >/dev/null
"$BIN/add_version_min" "$T/out"         >/dev/null
"$BIN/change_dylib"    "$T/out" -strip-lc uuid -strip-lc codesig \
    -change "/usr/lib/libSystem.B.dylib" "@loader_path/../S.dylib" >/dev/null
# NOT "$BIN/rename_segment" here: a one-argument call the tool needs three to
# do anything with, swallowed by `|| true`, so it has never once exercised
# rename_segment -- dead weight, not coverage. Not fixed into a real
# three-argument call either, because that WOULD change $T/out and move this
# digest, and tests/EXPECTED is a characterization reference that is never
# edited (see this file's own header).

reached_end=1
DIGEST=$(shasum -a 256 < "$T/out" | cut -d' ' -f1)
if [ "$MODE" = check ]; then
    WANT=$(cat "$HERE/EXPECTED")
    if [ "$DIGEST" = "$WANT" ]; then
        echo "characterize: OK ($DIGEST)"
    else
        echo "characterize: MISMATCH" >&2
        echo "  expected $WANT" >&2
        echo "  got      $DIGEST" >&2
        echo "  The pipeline's output changed. Either a tool's behaviour changed" >&2
        echo "  (update EXPECTED deliberately, in the same commit) or this build" >&2
        echo "  is not equivalent to the reference one." >&2
        exit 1
    fi
else
    echo "$DIGEST"
fi
