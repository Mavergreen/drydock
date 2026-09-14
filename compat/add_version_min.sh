#!/bin/sh
# add_version_min -- a /bin/sh wrapper around `machotool FILE OUT` with one
# `version-min set 10.9` statement on its stdin.
#
#   add_version_min binary
#
# WHAT THIS REPLACED. compat/add_version_min.c was eighteen lines: an argc
# check and a call to mv_add_version_min (src/version_min.h). The
# `version-min set` statement calls that same function, so the only thing this
# wrapper has to reshape is WHERE THE RESULT LANDS.
#
# GRAMMAR. `add_version_min FILE` -> `printf 'version-min set 10.9\n' |
# machotool FILE OUT`. The version is spelled out because the C tool hardcoded
# 10.9 (mv_add_version_min only knows that floor); ms_parse accepts no other,
# which is why the translation can name it literally rather than passing
# something through.
#
# THE IN-PLACE EDIT. add_version_min rewrote FILE; machotool does not write
# the file it is given. So this wrapper does what the old tool looked
# like it did, safely: mw_prepare names a temp beside the file FILE really is
# (following symlinks, refusing an unwritable FILE or one with other hard
# links), mw_retranslate re-emits the command with that temp as OUT,
# mw_run_to_tmp runs it, and mw_finish mv's the temp over the target -- or
# discards it when the bytes did not change, since the C tool wrote nothing in
# that case. machotool-compat.sh's "the install path" section has the reasoning
# for each step; all of it is shared, none of it is this wrapper's own.
#
# ONE CONSEQUENCE WORTH NAMING: creating a temp beside FILE and renaming it
# needs the DIRECTORY writable, where the C tool needed only FILE itself to be
# -- it opened FILE O_RDWR and wrote through that descriptor, never creating a
# second name. So a writable binary inside a read-only directory, which
# add_version_min patched, now fails: `mkstemp: Permission denied`, exit 2,
# from machotool's own write of the temp, with FILE untouched. compat/
# README.md's "change_dylib: the in-place edit" table records the same shape
# for the same reason (the mirror-image case, an unwritable FILE in a writable
# directory, is what mw_prepare's writability check exists to keep refusing).
#
# EXIT CODES. machotool's, forwarded unchanged, with the wrapper's own refusals
# at 1. The old C tool returned mv_add_version_min's own 0/1 (0 ok, 1 the flat
# "something went wrong" that function had no finer answer than); this wrapper
# forwards the SAME function's return today too, but its vocabulary is no
# longer that flat 0/1 (src/rewrite.h): 0 ok, MR_REFUSED (1) for a considered
# refusal -- "not a readable 64-bit Mach-O" (including mi_open's own
# MI_NOT_MACHO) or "no room for LC_VERSION_MIN_MACOSX" -- or MR_FAIL (2) for a
# genuine open/fstat failure, mi_open's own I/O errors (a second, independent
# open of the same path, which can fail on its own even though this function's
# own earlier open succeeded), or a failure to write OUT. A considered refusal
# still exits 1 here, matching the C tool by coincidence, not construction; an
# operational failure now exits 2, where the C tool always exited a flat 1
# -- see compat/README.md's "drop-in" section for this as a named
# exception. The two exit codes the COMMAND has of its own are unreachable
# from here: EX_FAIL=2 for a script that does not parse, since the one
# statement is emitted by compat/translate.sh rather than typed, and EX_FAIL=2
# for an OUT that is FILE, since mw_prepare names a temp that is neither. The wrapper's OWN refusals -- an absent or
# unwritable FILE (`open: ...`, mw_require_writable's words, which are the C
# tool's own open() failing), a hard-linked FILE, and a failed install -- all
# exit 1, the only failure code this tool ever had.
#
# STDOUT -- ONE OF THE C TOOL'S TWO LINES, and this is the one place the
# wrapper's text is not what it was. mv_add_version_min printed either
# "LC_VERSION_MIN_MACOSX already present; nothing to do." or "Added
# LC_VERSION_MIN_MACOSX 10.9 (ncmds=..., sizeofcmds=...)". The first still
# comes through on stdout, from the same printf inside the same function. The
# second does NOT: that line belongs to the `minos` VERB, which a script does
# not call, and a `version-min set 10.9` statement announces its append on
# STDERR instead -- "      appended LC_VERSION_MIN_MACOSX 10.9" (src/edit.c).
# Nothing reads it: tests/known-callers.sh's evidence is that every caller
# sends stdout to /dev/null and branches on the exit code, and the repo owner
# ruled on 2026-09-13 that wrapper text may change where bytes and exit codes
# may not. tests/wrapper_test.sh's add_version_min block asserts both halves --
# stdout empty on an append, the announcement present on stderr -- so the move
# is pinned rather than merely tolerated.
#
# STDERR. mv_add_version_min's own diagnostics, the statement report above,
# and the teaching message this wrapper prints ahead of both.

MW_SELF=$(command -v "$0" 2>/dev/null) || MW_SELF=$0
MW_DIR=${MACHOTOOL_COMPAT_DIR:-$(dirname "$MW_SELF")}
# Checked here, before sourcing, so a missing support file gets this message
# rather than the shell's own "No such file or directory" from the `.` below.
# The case that actually reaches it: a SYMLINK to this wrapper placed on PATH.
# $0 resolves to the symlink, so MW_DIR is the symlink's directory, not the
# one holding machotool -- which is why MACHOTOOL_COMPAT_DIR exists.
[ -r "$MW_DIR/machotool-compat.sh" ] || {
    printf '%s: cannot find machotool-compat.sh in %s -- machotool and its two support\n' "$0" "$MW_DIR" >&2
    printf '%s: files must sit beside this wrapper; a symlink to it resolves to the\n' "$0" >&2
    printf '%s: SYMLINK directory, so set MACHOTOOL_COMPAT_DIR to where they really are\n' "$0" >&2
    exit 1
}
. "$MW_DIR/machotool-compat.sh"

mw_translate add_version_min "$@" || exit $?
mw_prepare "$1" || exit 1
mw_retranslate add_version_min "$@" || exit 1
mw_run_to_tmp
mw_rc=$?
[ "$mw_rc" -eq 0 ] || exit "$mw_rc"
mw_finish || exit 1
exit 0
