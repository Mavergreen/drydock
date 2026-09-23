#!/bin/sh
# compat/drydock-macho-rewrite-compat.sh -- what the historical tools' /bin/sh
# wrappers share. Sourced, never run:
#
#   MW_DIR=... ; . "$MW_DIR/drydock-macho-rewrite-compat.sh"
#
# A wrapper translates its argv (compat/translate.sh), teaches the equivalent
# on stderr, runs it into a temp beside the target, and installs the temp.
# Installed flat, beside drydock-macho-rewrite and
# drydock-macho-rewrite-translate.sh; $DRYDOCK_MACHO_REWRITE_COMPAT_DIR
# overrides where they are looked for.
#
# POSIX sh (10.9's /bin/sh is bash 3.2). set -u, not set -e: every failure is
# checked where it happens.

set -u

# ---- locate everything ---------------------------------------------------
#
# MW_DIR comes from the wrapper. It is made absolute because it goes on PATH:
# a relative "." would resolve every helper against the working directory.
MW_DIR=$(cd "$MW_DIR" 2>/dev/null && pwd) || {
    printf '%s: cannot resolve my own directory\n' "$0" >&2
    exit 1
}
[ -r "$MW_DIR/drydock-macho-rewrite-translate.sh" ] || {
    printf '%s: cannot find drydock-macho-rewrite-translate.sh in %s -- drydock-macho-rewrite and its two\n' "$0" "$MW_DIR" >&2
    printf '%s: support files must be installed together (or set DRYDOCK_MACHO_REWRITE_COMPAT_DIR)\n' "$0" >&2
    exit 1
}

# PATH, not an absolute program word: the taught commands say
# drydock-macho-rewrite and must mean the one beside this wrapper.
# tests/wrapper_test.sh re-runs a taught block under `env -i` to hold that.
if [ -x "$MW_DIR/drydock-macho-rewrite" ]; then
    PATH="$MW_DIR:$PATH"
    export PATH
elif command -v drydock-macho-rewrite >/dev/null 2>&1; then
    # Installed elsewhere on PATH is legitimate, so warn rather than refuse.
    printf '%s: WARNING: drydock-macho-rewrite is not next to me in %s; using whatever\n' "$0" "$MW_DIR" >&2
    printf '%s: "drydock-macho-rewrite" resolves to on PATH instead, which may not be the\n' "$0" >&2
    printf '%s: same build. DRYDOCK_MACHO_REWRITE_COMPAT_DIR must name a directory that\n' "$0" >&2
    printf '%s: already has drydock-macho-rewrite-compat.sh and drydock-macho-rewrite-translate.sh in it\n' "$0" >&2
    printf '%s: (this one does), so silencing this means putting or linking\n' "$0" >&2
    printf '%s: the drydock-macho-rewrite you want right there, not just anywhere on PATH\n' "$0" >&2
else
    printf '%s: drydock-macho-rewrite is not next to me in %s and not on PATH; this tool is a\n' "$0" "$MW_DIR" >&2
    printf '%s: wrapper around it and cannot do anything without it\n' "$0" >&2
    exit 1
fi

MT_SOURCED=1
export MT_SOURCED
. "$MW_DIR/drydock-macho-rewrite-translate.sh"

# A scratch directory for the wrappers that have to capture drydock-macho-rewrite's output in
# order to reshape it. Created once, removed on every exit path.
MW_T=$(mktemp -d "${TMPDIR:-/tmp}/drydock-macho-rewrite-compat.XXXXXX") || {
    printf '%s: cannot create a temporary directory\n' "$0" >&2
    exit 1
}
# A single temporary a wrapper has made BESIDE the caller's file, rather than
# inside MW_T -- so that whatever creates one does not also have to remember
# every exit path. mw_prepare names it, drydock-macho-rewrite writes it, mw_finish installs
# or discards it; empty whenever there is none to remove.
MW_TMPFILE=''
mw_cleanup() {
    rm -rf "$MW_T"
    [ -n "$MW_TMPFILE" ] && rm -f -- "$MW_TMPFILE"
    return 0
}
trap 'mw_cleanup' EXIT
trap 'mw_cleanup; exit 130' INT
trap 'mw_cleanup; exit 143' TERM

MW_TOOL=''
MW_CMDS=''
MW_NCMDS=0
# mw_prepare's answers: the file FILE really is, and whether mw_finish ended
# up installing anything over it.
MW_TARGET=''
MW_CHANGED=0

# ---- translate, and teach ------------------------------------------------
#
# mw_translate TOOL ARG... -- fill MW_CMDS and MW_NCMDS, teach, and return
# compat/translate.sh's own code (0, or 1 or 2 with its message printed) for
# the caller to forward. MT_PROG0=$0, so a usage line names argv[0] as the C
# tools' did.
mw_translate() {
    MW_TOOL=$1
    MT_PROG0=$0
    MW_CMDS=$(mt_translate "$@")
    mw_trc=$?
    unset MT_PROG0
    [ "$mw_trc" -eq 0 ] || return "$mw_trc"
    # Count commands by their fixed first words. Caller text never reaches
    # awk here; any that must goes through ENVIRON, not -v, which runs it
    # through escape processing.
    MW_NCMDS=$(printf '%s\n' "$MW_CMDS" \
        | awk 'index($0, "printf ") == 1 || index($0, "mv -f ") == 1 { n++ } END { print n + 0 }')
    mw_teach
    return 0
}

# The kind form of deprecation, in one function: the caller's script keeps
# working, and the message teaches the new grammar. On STDERR, so stdout stays exactly
# what the C tool printed for anything reading it.
mw_teach() {
    if [ "$MW_NCMDS" -eq 0 ]; then
        printf '%s: deprecated -- drydock-macho-rewrite does this now. This invocation asks for nothing drydock-macho-rewrite would have to do.\n' \
            "$MW_TOOL" >&2
        return 0
    fi
    if [ "$MW_NCMDS" -eq 1 ]; then
        printf '%s: deprecated -- drydock-macho-rewrite does this now. The equivalent command is:\n' "$MW_TOOL" >&2
    else
        printf '%s: deprecated -- drydock-macho-rewrite does this now. The equivalent commands, in this order, are:\n' \
            "$MW_TOOL" >&2
    fi
    # One whole command per line, so indenting keeps it pasteable.
    printf '%s\n' "$MW_CMDS" | awk '{ print "    " $0 }' >&2
    return 0
}

# ---- run -----------------------------------------------------------------
#
# mw_run -- eval the translation: at most one command (retag_swift_classes.sh
# runs its per-file lines itself). </dev/null keeps it off the caller's stdin.
mw_run() {
    eval "$MW_CMDS" </dev/null
}

# mw_require_writable FILE -- the C tools opened FILE O_RDWR first, so an
# absent or unwritable FILE failed with perror("open"). drydock-macho-rewrite
# opens FILE read-only, so only this reproduces that. The two strings are
# pinned by tests/wrapper_test.sh and tests/known-callers.sh.
mw_require_writable() {
    if [ ! -e "$1" ]; then
        printf 'open: No such file or directory\n' >&2
        return 1
    fi
    if [ ! -w "$1" ]; then
        printf 'open: Permission denied\n' >&2
        return 1
    fi
    return 0
}

# mw_thin_only FILE -- return 1 when `info --thin` refuses FILE (EX_REFUSED):
# a fat container, or not a Mach-O. compat/README.md's "Thin only" has what
# each thin-only tool would do without this gate. EX_FAIL (2) falls through,
# so `add_version_min DIR` exits 2 on both sides.
mw_thin_only() {
    drydock-macho-rewrite info --thin "$1" >/dev/null 2>&1
    mw_to_rc=$?
    [ "$mw_to_rc" -eq 1 ] && return 1
    return 0
}

# ---- the install path ----------------------------------------------------
#
# drydock-macho-rewrite never writes the file it is given, and the tools these
# wrappers replace edited FILE in place, so every wrapper writes a temp beside
# the real target and mv's it over:
#
#   mw_prepare FILE       -> MW_TARGET, MW_TMPFILE   (and the refusals)
#   mw_retranslate TOOL ARG...                       -> MW_CMDS naming the temp
#   mw_run_to_tmp                                    -> run it, capture stdout
#   mw_finish                                        -> install, or discard

# mw_resolve PATH -- print the file PATH finally names once every symlink in
# its last component is followed. 10.9's readlink has no -f, so this follows
# one level at a time. The install lands on that file, so a FILE that is a
# symlink stays one.
mw_resolve() {
    mw_p=$1
    mw_hops=0
    while [ -L "$mw_p" ]; do
        mw_hops=$((mw_hops + 1))
        [ "$mw_hops" -le 32 ] || { printf '%s: too many levels of symbolic links\n' "$1" >&2; return 1; }
        mw_l=$(readlink "$mw_p") || return 1
        case $mw_l in
            /*) mw_p=$mw_l ;;
            *)  case $mw_p in */*) mw_p=${mw_p%/*}/$mw_l ;; *) mw_p=$mw_l ;; esac ;;
        esac
    done
    printf '%s\n' "$mw_p"
}

# mw_prepare FILE [new-ok] -- set MW_TARGET to the file FILE really is and
# MW_TMPFILE to a fresh name beside it, for drydock-macho-rewrite to write. Refuses what
# cannot be replaced safely: a FILE this user could not have written (the C
# tools opened it read-write, and mv would otherwise replace it anyway), and
# a FILE with other hard links, which mv would leave on the old content.
# With `new-ok`, a FILE that does not exist yet is fine (patch_macho's OUT).
mw_prepare() {
    if [ "${2:-}" = new-ok ] && [ ! -e "$1" ] && [ ! -L "$1" ]; then
        MW_TARGET=$1
    else
        mw_require_writable "$1" || return 1
        MW_TARGET=$(mw_resolve "$1") || return 1
        # Regular files only: a directory's link count is always above one,
        # and a directory falls through to drydock-macho-rewrite.
        mw_links=1
        if [ -f "$MW_TARGET" ]; then
            mw_links=$(stat -f %l "$MW_TARGET" 2>/dev/null) || mw_links=1
        fi
        if [ "$mw_links" -gt 1 ]; then
            printf '%s: %s has %d hard links; replacing it would leave the others with the old content. Break the link first, or run drydock-macho-rewrite with an explicit output.\n' \
                "$MW_TOOL" "$1" "$mw_links" >&2
            return 1
        fi
    fi
    case $MW_TARGET in
        */*) mw_dirpart=${MW_TARGET%/*}; mw_basepart=${MW_TARGET##*/} ;;
        *)   mw_dirpart=.;               mw_basepart=$MW_TARGET ;;
    esac
    [ -n "$mw_dirpart" ] || mw_dirpart=/
    MW_TMPFILE="$mw_dirpart/.$mw_basepart.drydock-macho-rewrite-compat.$$"
    rm -f -- "$MW_TMPFILE"
    return 0
}

# mw_retranslate TOOL ARG... -- translate again with MW_TMPFILE as the output.
# Re-translating, rather than editing the emitted line, keeps mt_qargs'
# quoting the only thing that parses a file name.
mw_retranslate() {
    MT_PROG0=$0
    MW_CMDS=$(MT_OUT=$MW_TMPFILE mt_translate "$@")
    mw_trc=$?
    unset MT_PROG0
    if [ "$mw_trc" -ne 0 ]; then
        printf '%s: internal error: the translation is not stable under a change of output\n' "$MW_TOOL" >&2
        return 1
    fi
    return 0
}

# mw_run_to_tmp -- run the translation (which writes MW_TMPFILE) with its
# stdout captured in $MW_T/out, forward that stdout, and return
# drydock-macho-rewrite's status. patch_macho.sh reads the capture back.
mw_run_to_tmp() {
    mw_run >"$MW_T/out"
    mw_rc=$?
    cat "$MW_T/out"
    return "$mw_rc"
}

# mw_finish -- after drydock-macho-rewrite wrote MW_TMPFILE: if it differs from MW_TARGET,
# mv it over (atomic: same directory), else discard it -- the C tools wrote
# nothing when nothing changed. Sets MW_CHANGED. Returns 1 only if the mv
# failed, leaving MW_TARGET as it was.
mw_finish() {
    MW_CHANGED=0
    if [ -e "$MW_TARGET" ] && cmp -s -- "$MW_TMPFILE" "$MW_TARGET"; then
        rm -f -- "$MW_TMPFILE"; MW_TMPFILE=''
        return 0
    fi
    if ! mv -f -- "$MW_TMPFILE" "$MW_TARGET"; then
        printf '%s: %s: the rewrite succeeded but installing it failed\n' "$MW_TOOL" "$MW_TARGET" >&2
        rm -f -- "$MW_TMPFILE"; MW_TMPFILE=''
        return 1
    fi
    MW_TMPFILE=''
    MW_CHANGED=1
    return 0
}
