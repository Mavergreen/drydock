#!/bin/sh
# compat/drydock-macho-rewrite-compat.sh -- the machinery the historical tools' /bin/sh
# wrappers share. Sourced, never run:
#
#   MW_DIR=... ; . "$MW_DIR/drydock-macho-rewrite-compat.sh"
#
# Each wrapper is then a handful of lines of its own: translate this argv,
# teach the equivalent on stderr, run it, and map the exit code and stdout
# back to what the C tool it replaced would have produced. drydock-macho-rewrite writes an
# OUTPUT rather than rewriting its input, so every wrapper has two more steps
# -- run it into a temp beside the caller's file, then install that temp over
# the file. ALL SIX take those two steps, including patch_macho.sh, whose
# grammar has always named its own output: the temp goes beside that output
# and is installed onto it, which is also how `patch_macho IN IN` keeps
# working now that drydock-macho-rewrite refuses an OUT that is its input. See "the
# install path" below.
#
# WHY THE WRAPPERS ARE NOT SIX COPIES OF THIS. The whole
# old-grammar-to-drydock-macho-rewrite translation lives in ONE file (compat/translate.sh) so that
# "the translation that was tested is literally the translation that ships".
# The same argument applies to everything AROUND the translation -- finding
# drydock-macho-rewrite, printing the teaching message, running what was translated, and the
# pre-checks a wrapper has to make for itself because the command it is about
# to run would report them differently. Those are one implementation here, not
# six.
#
# ---- what lives WHERE, and why -------------------------------------------
#
#   compat/translate.sh      argv -> drydock-macho-rewrite command line(s). Pure text; runs
#                            nothing. Pinned by tests/translate_test.sh.
#   compat/drydock-macho-rewrite-compat.sh  this file: run those command lines safely.
#   compat/<tool>.sh         one per tool: only what that tool's observable
#                            behaviour needs that drydock-macho-rewrite's does not already
#                            give -- its exit-code mapping and its stdout.
#
# Every behavioural difference each wrapper has to close is documented at its
# site: the divergence list at the top of compat/translate.sh, and the
# "DELIBERATE DIVERGENCES FROM <tool>" list each wrapper's own header carries.
# Those lists used to live in cli/drydock-macho-rewrite.c, in cmd_segment, cmd_retag_swift
# and cmd_declassify; the verbs are gone and each wrapper now keeps its own.
#
# ---- how a wrapper finds drydock-macho-rewrite and its two support files ----------------
#
# All four files -- drydock-macho-rewrite, drydock-macho-rewrite-translate.sh, drydock-macho-rewrite-compat.sh and the
# wrapper itself -- are installed FLAT, in the same bin directory, and a
# wrapper looks for the other three next to itself ($0's directory, resolved
# through PATH when $0 has no slash). $DRYDOCK_MACHO_REWRITE_COMPAT_DIR overrides that, which
# is how a build tree or a test harness points at an uninstalled set.
#
# Flat, rather than a libexec/ subdirectory, because of the shape of the one
# production caller: mavericksforever.com/claude/install.sh downloads the
# tools BY NAME into a single directory. A layout that needed a subdirectory
# would need that script changed; a flat one needs only the extra file names.
# (It needs those either way -- a wrapper cannot work without drydock-macho-rewrite present,
# which is a packaging consequence of wrapping at all, not of this layout.)
#
# ---- POSIX sh only -------------------------------------------------------
#
# 10.9's /bin/sh is bash 3.2 in sh mode, which accepts plenty a stricter shell
# does not, so nothing here may rely on that. tests/wrapper_test.sh re-runs
# the wrappers under /bin/ksh for the same reason tests/translate_test.sh
# re-runs the translator under it.
#
# set -u, and deliberately NOT set -e: `set -e` was found silently
# swallowing a real failure at two sites in this repo's shell, so every failure here is checked where it happens. Same choice
# tests/compat-sweep.sh and tests/translate_test.sh made.

set -u

# ---- locate everything ---------------------------------------------------
#
# MW_DIR is set by the wrapper before sourcing this file (it is the only thing
# that cannot be worked out from in here, since $0 is the wrapper either way,
# but the wrapper's own bootstrap is two lines and this keeps them there).
#
# Made ABSOLUTE first. Invoked as `./change_dylib`, $0's directory is ".", and
# this directory goes on PATH below -- so leaving it relative would prepend a
# literal "." to PATH and make every helper this file runs (cp, sed, awk)
# resolve against the working directory at the moment it runs. Resolving it
# once, here, keeps PATH naming one fixed directory: the one the wrapper
# itself came out of.
MW_DIR=$(cd "$MW_DIR" 2>/dev/null && pwd) || {
    printf '%s: cannot resolve my own directory\n' "$0" >&2
    exit 1
}
[ -r "$MW_DIR/drydock-macho-rewrite-translate.sh" ] || {
    printf '%s: cannot find drydock-macho-rewrite-translate.sh in %s -- drydock-macho-rewrite and its two\n' "$0" "$MW_DIR" >&2
    printf '%s: support files must be installed together (or set DRYDOCK_MACHO_REWRITE_COMPAT_DIR)\n' "$0" >&2
    exit 1
}

# PATH, not an absolute program word: the command lines translate.sh emits are
# the ones a human is being taught to type, so they must say `drydock-macho-rewrite` and mean
# the drydock-macho-rewrite that ships alongside this wrapper. Prepending the wrapper's own
# directory is what makes those two the same thing. tests/compat-sweep.sh runs
# the emitted lines the same way, for the same reason.
#
# The taught text is a pinned contract -- tests/known-callers.sh greps stderr
# for it, and tests/wrapper_test.sh pulls a taught block back out of a real
# run's stderr and runs it under `env -i PATH=...` in a new /bin/sh, checking
# it produces the same bytes the wrapper did -- so the word compat/
# translate.sh emits and the binary this finds have to be the same word. Both
# are `drydock-macho-rewrite`; the tool answered to three earlier names before that one,
# and that `env -i` check is what lets it stop answering to them.
if [ -x "$MW_DIR/drydock-macho-rewrite" ]; then
    PATH="$MW_DIR:$PATH"
    export PATH
elif command -v drydock-macho-rewrite >/dev/null 2>&1; then
    # NOT the same hard failure as a missing drydock-macho-rewrite-translate.sh above,
    # because a caller may legitimately have installed drydock-macho-rewrite elsewhere on
    # PATH -- but it is NOT the drydock-macho-rewrite the header comment above promises
    # ("the one that ships alongside this wrapper"), so a version mismatch
    # here would be silent without this line. Warn and proceed rather than
    # refuse: refusing would break that legitimate case outright.
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
# mw_translate TOOL ARG...
#
# Fills MW_CMDS (the emitted command lines, newline-separated) and MW_NCMDS,
# and prints the teaching message. Returns compat/translate.sh's own exit
# code, which the caller forwards:
#
#   0  translated (MW_NCMDS may be 0 -- the old invocation was a no-op)
#   1  the OLD TOOL would have refused this argv; translate.sh has already
#      printed the old tool's own message, so there is nothing to add
#   2  no drydock-macho-rewrite command line means what this argv meant; same
#
# MT_PROG0 is $0 rather than the tool's name, because every usage line these
# tools print names argv[0] -- so `/some/where/change_dylib` with bad
# arguments prints exactly the path it was invoked as, exactly as the C
# binary did.
mw_translate() {
    MW_TOOL=$1
    MT_PROG0=$0
    MW_CMDS=$(mt_translate "$@")
    mw_trc=$?
    unset MT_PROG0
    [ "$mw_trc" -eq 0 ] || return "$mw_trc"
    # COMMANDS, and every one of them is now exactly one line: a drydock-macho-rewrite
    # command is `printf FORMAT | drydock-macho-rewrite FILE OUT` -- the bare form, with the
    # statements in the format rather than in a here-document -- or `mv -f`,
    # the install step mt_install_line appends to the teaching form, which is
    # a command a reader would type too. Both markers are fixed text this file
    # and compat/translate.sh agree on, so neither depends on $DRYDOCK_MACHO_REWRITE: a
    # program word carrying a backslash or a space used to have to reach awk
    # through the environment to be compared correctly, and now it is not
    # compared at all.
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
    # Every line is a whole command now -- the statements ride inside the
    # `printf` format rather than in a here-document whose body and terminator
    # had to start in column one -- so the whole block is indented, and what is
    # shown stays pasteable verbatim.
    printf '%s\n' "$MW_CMDS" | awk '{ print "    " $0 }' >&2
    return 0
}

# ---- run -----------------------------------------------------------------
#
# mw_run -- run the translation, and return its exit code.
#
# THIS DOES NOT LOOP: an old invocation that would have been a sequence of
# drydock-macho-rewrite commands is ONE `printf ... | drydock-macho-rewrite FILE OUT` with the operations
# as statements on stdin, so a translation is at most one command and there is
# no sequence left to step through. (compat/retag_swift_classes.sh is the one
# translation that is still several commands -- one per binary -- and it has
# always run its own lines itself, because it needs each file's own exit code
# and its own stdout, and one code for the whole script is not that.)
#
# `</dev/null` is the stdin the eval'd text starts from, so nothing here can
# eat the caller's own stdin by accident; the pipeline's own `|` is what feeds
# drydock-macho-rewrite, and it overrides that default for the one process that wants input.
mw_run() {
    eval "$MW_CMDS" </dev/null
}

# mw_require_writable FILE
#
# The absent/unwritable pre-check, in the words the C tools produced. Both
# fix_macho and rename_segment open()ed the file O_RDWR before looking at
# anything at all, so an absent or unwritable FILE failed immediately with
# perror("open"): `open: No such file or directory` or `open: Permission
# denied` -- no program name, on stderr, exit 1.
#
# NO drydock-macho-rewrite COMMAND REPRODUCES IT ANY MORE, and that is the point of the
# conversion rather than a gap in it: a verb that writes an output opens FILE
# O_RDONLY, so it has no opinion about whether FILE is writable -- it never
# writes FILE. (`dylib`/`rpath`/`lc`/`segment` used to give this refusal for
# free, from mr_apply_file's own O_RDWR; a script reads FILE O_RDONLY and only
# discovers an unwritable OUT when it writes it.) And
# rename_segment gates on `drydock-macho-rewrite info`, which is O_RDONLY too. So preserving
# the historical refusal is permanently this layer's job, which is why
# mw_prepare calls this before anything runs.
#
# Returns 1 rather than exiting, so the caller keeps the decision. The two
# strings are a contract, not a message: tests/wrapper_test.sh and
# tests/known-callers.sh pin them.
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

# mw_thin_only FILE
#
# Returns 1 when FILE is something the verb this wrapper replaced would have
# refused outright for not being ONE thin 64-bit Mach-O -- a fat container
# above all. The caller then produces its own tool's answer.
#
# WHY THIS EXISTS. `minos`, `declassify` and `retag-swift` all began with
# mi_open, which reads a single thin image and refuses a fat container; so did
# the three C tools they replaced. A SCRIPT does not: `drydock-macho-rewrite FILE OUT` goes
# through mr_process_fat and rewrites every slice. drydock-macho-rewrite gained that
# deliberately, and for someone writing a script by hand it is the better
# answer -- but a compat wrapper may not change WHICH INVOCATIONS SUCCEED, and
# these three did not succeed. Measured against the pre-migration binaries on a
# two-slice x86_64 fat file:
#
#   add_version_min FAT      exit 1, nothing written  ->  would become exit 0,
#                                                         every slice rewritten
#   patch_macho FAT OUT      exit 1, no OUT           ->  would become exit 0,
#                                                         OUT written
#   retag_swift_classes FAT  exit 0, file untouched   ->  would become exit 0
#                                                         with the file RETAGGED
#                                                         and total: still 0
#
# The third is the one that matters most: same exit code, same stdout,
# different bytes on the caller's file.
#
# `drydock-macho-rewrite info` is a bare mi_open, so its verdict IS the old verb's -- which
# is why compat/rename_segment.sh has gated on it since that wrapper was
# written, and why `rename_segment FAT` never drifted. ONLY its EX_REFUSED (1)
# is intercepted: that is mi_open's "not a readable 64-bit Mach-O", covering a
# fat container and a non-Mach-O alike. EX_FAIL (2) -- a directory, an
# unreadable file -- falls through untouched, because drydock-macho-rewrite already gives
# those callers the answer the C tools gave (measured: `add_version_min <dir>`
# exits 2 saying "cannot open or read" on both sides).
mw_thin_only() {
    drydock-macho-rewrite info "$1" >/dev/null 2>&1
    mw_to_rc=$?
    [ "$mw_to_rc" -eq 1 ] && return 1
    return 0
}

# ---- the install path ----------------------------------------------------
#
# drydock-macho-rewrite NEVER WRITES THE FILE IT IS GIVEN: every command is
# `drydock-macho-rewrite FILE OUT`, and it refuses an OUT that is FILE. The historical
# tools DID edit FILE in place, and their callers still expect that, so every
# wrapper reproduces it in the only way that is safe: write a temp beside the
# real target, then mv it over. The five functions below are that
# sequence, shared rather than copied into each wrapper as they arrive:
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
        # REGULAR FILES ONLY. A directory's link count is always greater than
        # one (`.`, its parent's entry, and one per subdirectory), so without
        # this gate `add_version_min somedir` would be refused as a hard-link
        # problem, with a remedy -- break the link -- that means nothing. A
        # directory is not something this check has an opinion about at all:
        # it falls through to drydock-macho-rewrite. Measured (both `macho9 minos d out 10.9`
        # and `macho9 retag-swift d out`): `d: cannot open or read` -- open()
        # O_RDONLY succeeds on a directory, so the failure is mi_open's own
        # read, not an open() rejecting it the way the C tools' open(O_RDWR)
        # did.
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

# mw_retranslate TOOL ARG... -- translate again, this time writing MW_TMPFILE.
# The same argv mw_translate accepted a moment ago, with only the output
# named, so it cannot fail on its own: if it does, the translation depends on
# something it must not, and that is the one difference this can observe --
# it inspects the exit status, not the text.
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
# stdout captured in $MW_T/out, forward that stdout, and return drydock-macho-rewrite's
# status. The capture is what lets a wrapper read something back out of it --
# patch_macho.sh's `^Already patched` check is the one that does.
#
# THERE IS NOTHING LEFT TO FILTER OUT, and that is a consequence of the bare
# form rather than an oversight. This used to drop a "Wrote <temp> (N bytes)"
# line, which `mr_apply_file` printed on STDOUT and which named a file no
# caller has heard of; a script reports its write as "<temp>: written (N
# bytes)" on STDERR instead, beside the rest of its narration, so stdout no
# longer carries the temp's name at all. (The name is on stderr now, where the
# edit path has always put it -- the same stream the deprecation notice above
# it uses.)
#
# The lesson that filter taught outlives it: a needle built from a caller's
# path reaches awk through the ENVIRONMENT, never through `-v`, because
# `awk -v x=VALUE` runs VALUE through the same escape processing a string
# literal gets. Measured, before that was ENVIRON: `change_dylib
# 'back\slash/f'` leaked `Wrote back\slash/.f.drydock-macho-rewrite-compat.NNNNN (8528
# bytes)` onto stdout because the needle awk compared was not the real path.
# No awk in this file takes a caller's text any more -- mw_translate's and
# mw_teach's needles are fixed words -- so the hazard is gone with it.
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
