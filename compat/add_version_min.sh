#!/bin/sh
# add_version_min -- a /bin/sh wrapper around `drydock-macho-rewrite FILE OUT` with one
# `minos if-absent 10.9` statement on its stdin.
#
#   add_version_min binary
#
# GRAMMAR. `add_version_min FILE` -> `printf 'minos if-absent 10.9\n' |
# drydock-macho-rewrite FILE OUT`: declare 10.9 where nothing is declared, and
# leave a declared minimum as it is, as the C tool did. compat/README.md's
# "add_version_min" section has where the two differ.
#
# THE IN-PLACE EDIT. add_version_min rewrote FILE; drydock-macho-rewrite does not write
# the file it is given. So this wrapper does what the old tool looked
# like it did, safely: mw_prepare names a temp beside the file FILE really is
# (following symlinks, refusing an unwritable FILE or one with other hard
# links), mw_retranslate re-emits the command with that temp as OUT,
# mw_run_to_tmp runs it, and mw_finish mv's the temp over the target -- or
# discards it when the bytes did not change, since the C tool wrote nothing in
# that case. drydock-macho-rewrite-compat.sh's "the install path" section has the reasoning
# for each step; all of it is shared, none of it is this wrapper's own.
#
# ONE CONSEQUENCE WORTH NAMING: creating a temp beside FILE and renaming it
# needs the DIRECTORY writable, where the C tool needed only FILE itself to be
# -- it opened FILE O_RDWR and wrote through that descriptor, never creating a
# second name. So a writable binary inside a read-only directory, which
# add_version_min patched, now fails: `mkstemp: Permission denied`, exit 2,
# from drydock-macho-rewrite's own write of the temp, with FILE untouched. compat/
# README.md's "change_dylib: the in-place edit" table records the same shape
# for the same reason (the mirror-image case, an unwritable FILE in a writable
# directory, is what mw_prepare's writability check exists to keep refusing).
#
# EXIT CODES. drydock-macho-rewrite's, forwarded unchanged: 0, 1 for a
# considered refusal, 2 for an operational failure, where the C tool exited a
# flat 1 for both (compat/README.md's "drop-in" section names it). The
# wrapper's own refusals -- an absent or unwritable FILE (`open: ...`, the C
# tool's own words), a hard-linked FILE, and a failed install -- exit 1.
#
# STDOUT. The C tool printed "LC_VERSION_MIN_MACOSX already present; nothing
# to do." or "Added LC_VERSION_MIN_MACOSX 10.9 (...)". This wrapper prints the
# first when the run changed nothing; the second became the statement's report
# on stderr.
#
# STDERR. The statement's diagnostics and report, after the teaching message.

MW_SELF=$(command -v "$0" 2>/dev/null) || MW_SELF=$0
MW_DIR=${DRYDOCK_MACHO_REWRITE_COMPAT_DIR:-$(dirname "$MW_SELF")}
# Checked here, before sourcing, so a missing support file gets this message
# rather than the shell's own "No such file or directory" from the `.` below.
# The case that actually reaches it: a SYMLINK to this wrapper placed on PATH.
# $0 resolves to the symlink, so MW_DIR is the symlink's directory, not the
# one holding drydock-macho-rewrite -- which is why DRYDOCK_MACHO_REWRITE_COMPAT_DIR exists.
[ -r "$MW_DIR/drydock-macho-rewrite-compat.sh" ] || {
    printf '%s: cannot find drydock-macho-rewrite-compat.sh in %s -- drydock-macho-rewrite and its two support\n' "$0" "$MW_DIR" >&2
    printf '%s: files must sit beside this wrapper; a symlink to it resolves to the\n' "$0" >&2
    printf '%s: SYMLINK directory, so set DRYDOCK_MACHO_REWRITE_COMPAT_DIR to where they really are\n' "$0" >&2
    exit 1
}
. "$MW_DIR/drydock-macho-rewrite-compat.sh"

mw_translate add_version_min "$@" || exit $?
mw_prepare "$1" || exit 1
# THIN ONLY, as the C tool was; the message is the one it printed, naming FILE.
if ! mw_thin_only "$1"; then
    printf '%s: not a readable 64-bit Mach-O\n' "$1" >&2
    exit 1
fi
mw_retranslate add_version_min "$@" || exit 1
mw_run_to_tmp
mw_rc=$?
[ "$mw_rc" -eq 0 ] || exit "$mw_rc"
mw_finish || exit 1
[ "$MW_CHANGED" -eq 1 ] || printf 'LC_VERSION_MIN_MACOSX already present; nothing to do.\n'
exit 0
