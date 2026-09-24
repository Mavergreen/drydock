#!/bin/sh
# tests/leaf-tool-crashes.sh — regression coverage for two heap-overflow
# crashes a code review found in add_version_min and retag_swift_classes
# after they were converted onto src/image.h.
#
# mi_open validates every LOAD COMMAND (magic, cmdsize bounds/alignment,
# LC_SEGMENT_64/nsects agreement) but nothing about a SECTION's file range,
# and nothing about an address later derived from one -- that was never its
# job (see image.h's own file header: "what is in here?", nothing about
# what a section's bytes point at). Every fixture below is built to pass
# mi_open cleanly while still containing an out-of-bounds reference, or a
# missing bound, that a tool used to trust:
#
#   nosect.macho       filetype 0, one LC_SEGMENT_64/__DATA, nsects=0; 104
#                      bytes -- no section anywhere has a nonzero file
#                      offset, so add_version_min's "is there room before the
#                      first section" check never found a bound and wrote
#                      LC_VERSION_MIN_MACOSX 16 bytes past a buffer whose
#                      allocation was exactly file-sized. The load-command
#                      rewriter (`macho9 dylib`) had the same blind spot: it
#                      took 4096 as the first-section offset of an image with
#                      no section data, and its commit cleared the pad up to
#                      4096, past the end of this 104-byte buffer.
#   oobsection.macho   filetype 0, one LC_SEGMENT_64/__DATA with one section,
#                      __objc_classlist, whose offset/size (0x7000/0x8000)
#                      point entirely past this 184-byte file --
#                      retag_swift_classes indexed the class list at that
#                      offset directly, with no check against the file's
#                      actual size. `macho9 dylib` cleared its load-command
#                      area up to that same 0x7000, and `macho9 info`
#                      measured a pad against it.
#   sectionless.macho  a PIE MH_EXECUTE of 8192 bytes: one LC_SEGMENT_64/__TEXT
#                      covering the file, nsects=0, and an LC_UUID. No
#                      section data, like nosect, but here the assumed 4096
#                      lay inside the buffer: no crash, but the rewriters'
#                      commit zeroed real data up to it.
#
# nosect and oobsection fail `drydock-macho-rewrite verify` (no segment maps the header);
# sectionless passes it, so nothing upstream of the tools stops them.
#
# An `oobgrow.macho` stood beside these: the same out-of-bounds section offset
# in an image `drydock-macho-rewrite grow FILE OUT N` accepted until it used it, where
# `fsize - insert` wrapped and the tool died of SIGSEGV. The verb is gone, and
# no script can force that grow (mg_ensure_pad grows only when the load
# commands actually need the room, which on that image they never do). The
# regression moved to where the bug always was, in the library:
# tests/grow_test.c's test_grow_refuses_a_section_past_the_image calls
# mg_grow_header directly, and reverting mg_grow_header's `insert > fsize`
# guard was measured to kill it with the same SIGSEGV this file used to catch.
#
# Host-portability: every fixture is hand-built byte-for-byte (no compiler
# invoked to produce Mach-O structure, just a throwaway C helper -- same
# idiom as change_dylib_test.sh's ordinal_of.c/has_lc.c -- writing the struct
# layout directly), so this asks the same question on every host regardless
# of toolchain version; see tests/README.md.
#
#   sh tests/leaf-tool-crashes.sh <bindir>
set -eu
BIN="${1:?usage: leaf-tool-crashes.sh <bindir>}"
[ -x "$BIN/add_version_min" ] || { echo "leaf-tool-crashes: $BIN/add_version_min not found" >&2; exit 1; }
[ -x "$BIN/retag_swift_classes" ] || { echo "leaf-tool-crashes: $BIN/retag_swift_classes not found" >&2; exit 1; }
[ -x "$BIN/patch_macho" ] || { echo "leaf-tool-crashes: $BIN/patch_macho not found" >&2; exit 1; }
[ -x "$BIN/drydock-macho-rewrite" ] || { echo "leaf-tool-crashes: $BIN/drydock-macho-rewrite not found" >&2; exit 1; }

CC="${CC:-clang}"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_DIR="$SCRIPT_DIR/../src"
T="${TMPDIR:-/tmp}/leaf-tool-crashes.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

fails=0
ok()   { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fails=$((fails + 1)); }
skip() { echo "SKIP $1: $2"; }

# `set -e` means any bare command that exits nonzero kills the WHOLE script
# immediately, mid-run, with no summary and a FAIL count of zero -- see
# tests/cli_test.sh:133-145 for the pattern and the incident that motivated
# it. reached_end is set to 1 only at the very end, right before the summary
# line, so an EXIT trap firing while it is still 0 means the script did NOT
# reach its own summary.
reached_end=0
trap 'rc=$?; rm -rf "$T"; if [ "$reached_end" -eq 0 ]; then
    echo "leaf-tool-crashes: FATAL -- aborted early (a command exited $rc under set -e); the suite did NOT run to completion, and everything after the last PASS/FAIL/SKIP line above never ran" >&2
fi' EXIT

cat > "$T/mkfixture.c" <<'EOF'
/* Writes one of two tiny, deliberately malformed-past-load-commands Mach-O
 * fixtures. Byte layout only -- see leaf-tool-crashes.sh for what each is
 * shaped to trigger. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <mach-o/loader.h>

/* segname/sectname are char[16], NOT required to be NUL-terminated -- a
 * 16-character name fills the field completely, with no room for a
 * terminator (src/image.c's name_eq comment, and now tests/README.md's
 * host-portability section, explain why the real tools compare these
 * fields with strncmp rather than strcmp/strlen). strcpy'ing a 16-character
 * name into one of these fields writes a 17th byte -- the NUL -- past the
 * field, into whatever struct member follows. 10.9's clang lets that
 * happen silently; a modern clang's _FORTIFY_SOURCE turns strcpy into
 * __strcpy_chk, which detects the overflow and aborts (SIGTRAP) before this
 * helper ever gets to write the fixture file, failing this test on the
 * cross runner while it passes natively. memcpy with an explicit,
 * field-width-capped length has no such trap: it is also just the CORRECT
 * operation for a fixed-width, not-necessarily-terminated field. */
static void set_name16(char *field, const char *name) {
    size_t len = strlen(name);
    if (len > 16) len = 16;
    memset(field, 0, 16);
    memcpy(field, name, len);
}

/* `sectionless OUT N`: an N-byte PIE executable whose one LC_SEGMENT_64,
 * __TEXT, covers the whole file (fileoff 0, filesize = vmsize = N) and has
 * no sections, followed by an LC_UUID so that `lc -delete uuid` has
 * something to delete. Every byte from offset 200 on is 0xAB, so anything a
 * tool clears or overwrites past the load commands (which end at 128) shows. */
static int write_sectionless(const char *out, size_t n) {
    uint8_t *b = (uint8_t *)calloc(1, n);
    if (!b) { perror("calloc"); return 1; }
    struct mach_header_64 *h = (struct mach_header_64 *)b;
    h->magic = MH_MAGIC_64;
    h->cputype = CPU_TYPE_X86_64;
    h->filetype = MH_EXECUTE;
    h->flags = MH_PIE;
    struct segment_command_64 *s = (struct segment_command_64 *)(b + sizeof *h);
    s->cmd = LC_SEGMENT_64;
    s->cmdsize = sizeof *s;
    set_name16(s->segname, "__TEXT");
    s->fileoff = 0;
    s->filesize = n;
    s->vmsize = n;
    s->nsects = 0;
    struct uuid_command *u = (struct uuid_command *)((uint8_t *)s + s->cmdsize);
    u->cmd = LC_UUID;
    u->cmdsize = sizeof *u;
    memset(u->uuid, 0x5A, sizeof u->uuid);
    h->ncmds = 2;
    h->sizeofcmds = s->cmdsize + u->cmdsize;
    for (size_t i = 200; i < n; i++) b[i] = 0xAB;
    FILE *f = fopen(out, "wb");
    if (!f) { perror("fopen"); free(b); return 1; }
    if (fwrite(b, 1, n, f) != n) { perror("fwrite"); fclose(f); free(b); return 1; }
    fclose(f);
    free(b);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 4 && strcmp(argv[1], "sectionless") == 0) {
        long n = atol(argv[3]);
        if (n < 256) { fprintf(stderr, "sectionless: N must be at least 256\n"); return 1; }
        return write_sectionless(argv[2], (size_t)n);
    }
    if (argc != 3) {
        fprintf(stderr, "usage: %s nosect|oobsection out | %s sectionless out N\n",
                argv[0], argv[0]);
        return 1;
    }

    static uint8_t buf[512];
    memset(buf, 0, sizeof buf);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    h->magic = MH_MAGIC_64;
    h->ncmds = 1;
    struct segment_command_64 *seg = (struct segment_command_64 *)(buf + sizeof *h);
    seg->cmd = LC_SEGMENT_64;
    set_name16(seg->segname, "__DATA");

    size_t fsize;
    if (strcmp(argv[1], "nosect") == 0) {
        seg->cmdsize = sizeof(*seg);
        seg->nsects = 0;
        h->sizeofcmds = seg->cmdsize;
        fsize = sizeof(*h) + seg->cmdsize;
    } else if (strcmp(argv[1], "oobsection") == 0) {
        seg->cmdsize = sizeof(*seg) + sizeof(struct section_64);
        seg->nsects = 1;
        h->sizeofcmds = seg->cmdsize;
        struct section_64 *s = (struct section_64 *)((uint8_t *)seg + sizeof *seg);
        /* "__objc_classlist" is exactly 16 characters -- the case that
         * actually exposed this: strcpy's 17th byte (the NUL) had nowhere
         * to go but into s->segname, the very next field. */
        set_name16(s->sectname, "__objc_classlist");
        set_name16(s->segname, "__DATA");
        s->offset = 0x7000;
        s->size   = 0x8000;
        fsize = sizeof(*h) + seg->cmdsize;
    } else {
        fprintf(stderr, "unknown kind: %s\n", argv[1]);
        return 1;
    }

    FILE *f = fopen(argv[2], "wb");
    if (!f) { perror("fopen"); return 1; }
    if (fwrite(buf, 1, fsize, f) != fsize) { perror("fwrite"); fclose(f); return 1; }
    fclose(f);
    return 0;
}
EOF
"$CC" -O2 -o "$T/mkfixture" "$T/mkfixture.c"

"$T/mkfixture" nosect "$T/nosect.macho"
"$T/mkfixture" oobsection "$T/oobsection.macho"

# --- add_version_min -------------------------------------------------------
cp "$T/nosect.macho" "$T/av.macho"
rc=0
"$BIN/add_version_min" "$T/av.macho" >"$T/av.out" 2>"$T/av.err" || rc=$?
if [ "$rc" -gt 127 ]; then
    bad "add_version_min: nosect fixture" "killed by a signal (exit $rc) -- the heap overflow this fixture exists to catch"
elif [ "$rc" -eq 1 ] && grep -q "no room for LC_VERSION_MIN_MACOSX" "$T/av.err"; then
    ok "add_version_min: refuses (not crashes) a file with no sectioned segment"
else
    bad "add_version_min: nosect fixture" "expected exit 1 + 'no room' message, got exit $rc: $(cat "$T/av.err")"
fi
grep -qF "av.macho: no section data bounds the header pad; refusing rather than guess where it ends" "$T/av.err" \
    && ok "add_version_min: ... and says why, naming the file" \
    || bad "add_version_min: nosect fixture" "no labelled reason for the refusal: $(cat "$T/av.err")"

if [ -f /usr/lib/libgmalloc.dylib ]; then
    cp "$T/nosect.macho" "$T/av_gm.macho"
    rc=0
    DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib \
        "$BIN/add_version_min" "$T/av_gm.macho" >"$T/av_gm.out" 2>"$T/av_gm.err" || rc=$?
    if [ "$rc" -gt 127 ]; then
        bad "add_version_min: nosect fixture (libgmalloc)" "killed by a signal (exit $rc) under libgmalloc -- the heap overflow this fixture exists to catch"
    else
        ok "add_version_min: nosect fixture (libgmalloc): completed without crashing (exit $rc)"
    fi
else
    skip "add_version_min: nosect fixture (libgmalloc)" "no /usr/lib/libgmalloc.dylib on this host"
fi

# --- a dylib append statement ------------------------------------------------------------
# The same fixture reached the load-command rewriter's commit, whose memset
# cleared the pad up to the first section's offset -- taken to be 4096 when
# there is no section data at all, in a 104-byte buffer. With no section data
# there is no pad boundary to find, so it must refuse before it looks for
# one, and leave the file as it was.
rewrite_refusal="no section data bounds the header pad; refusing to rewrite its load commands"
sha_of() { md5 -q "$1" 2>/dev/null || md5sum "$1" | awk '{print $1}'; }

# mt_append GMALLOC FILE OUT  -- `dylib append /x` through the only mutating
# interface there is. It was
# `drydock-macho-rewrite dylib FILE OUT -append /x`; the fixtures, the
# refusals and every assertion below are unchanged, because the crash these
# cases exist to catch is in the rewriter, not in how it was asked for.
#
# GMALLOC is passed as an argument rather than set as a `VAR=val cmd` prefix on
# a shell FUNCTION, which is not required to be a one-command assignment in
# POSIX sh and leaks into the rest of the loop on some shells. The subshell
# keeps it to the one process it is meant for.
mt_append() {
    mt_gm=$1; mt_file=$2; mt_out=$3
    printf 'dylib append /x\n' | (
        [ -n "$mt_gm" ] && { DYLD_INSERT_LIBRARIES=$mt_gm; export DYLD_INSERT_LIBRARIES; }
        exec "$BIN/drydock-macho-rewrite" "$mt_file" "$mt_out"
    )
}
for gm in "" /usr/lib/libgmalloc.dylib; do
    what="dylib append: nosect fixture${gm:+ (libgmalloc)}"
    if [ -n "$gm" ] && [ ! -f "$gm" ]; then
        skip "$what" "no $gm on this host"
        continue
    fi
    cp "$T/nosect.macho" "$T/dy.macho"
    rm -f "$T/dy.out.macho"
    before=$(sha_of "$T/dy.macho")
    rc=0
    if [ -n "$gm" ]; then
        mt_append "$gm" "$T/dy.macho" "$T/dy.out.macho" \
            >"$T/dy.out" 2>"$T/dy.err" || rc=$?
    else
        mt_append "" "$T/dy.macho" "$T/dy.out.macho" \
            >"$T/dy.out" 2>"$T/dy.err" || rc=$?
    fi
    if [ "$rc" -gt 127 ]; then
        bad "$what" "killed by a signal (exit $rc) -- the heap overflow this fixture exists to catch"
    elif [ "$rc" -eq 1 ] && grep -qF "$rewrite_refusal" "$T/dy.err"; then
        ok "$what: refuses (1), naming the missing section data"
    else
        bad "$what" "expected exit 1 + '$rewrite_refusal', got exit $rc: $(cat "$T/dy.err")"
    fi
    [ "$(sha_of "$T/dy.macho")" = "$before" ] \
        && ok "$what: leaves the file unchanged" \
        || bad "$what" "the refused run modified the file"
    [ ! -e "$T/dy.out.macho" ] \
        && ok "$what: writes no output either" \
        || bad "$what" "a refused run left an output behind"
done

# --- a sectionless image with 4096 inside it ---------------------------------
# An 8192-byte PIE executable whose one __TEXT segment has no sections, plus
# an LC_UUID, with 0xAB in every byte from 200 on. No section has file data,
# so nothing in the file says where the header pad ends. mg_first_sect_off
# used to answer 4096 anyway, and here 4096 lies inside the buffer, so no
# bounds check caught it: `macho9 dylib F -append /x` exited 0 having zeroed
# bytes 200..4095, with or without MACHO_NO_VERIFY, because mg_plausible
# accepts this image. Each verb below must refuse (1), saying so, and leave
# every byte as it was.
#
# The load-command rewriters (dylib, rpath, lc, segment, and edit's statements
# for them) are held to mr_process_thin's own message, not merely to "no
# section data": mg_ensure_pad refuses the same image in its own words, so
# a dylib append would still be refused, by mg_ensure_pad, if mr_process_thin
# stopped checking.
#
# `drydock-macho-rewrite grow <copy> OUT 4096` was held here to mg_grow_header's own
# wording ("refusing to grow it"). The verb is gone and no script forces a
# grow, so that case is now tests/grow_test.c's
# test_grow_refuses_an_image_with_no_section_data, which calls mg_grow_header
# on a sectionless image and asserts the same refusal, the same untouched
# bytes, and the same words. Measured: disabling mg_grow_header's
# MG_NO_SECTION_DATA refusal fails that test and the case here identically.
"$T/mkfixture" sectionless "$T/sectionless.macho" 8192
# sectionless_script NEEDLE STATEMENT...
#   -- runs the bare `drydock-macho-rewrite <copy> OUT` form with each argument as one
#      line of the script on stdin, and asserts five facts. The load-command
#      rewrites below were `drydock-macho-rewrite dylib|rpath|lc|segment <copy> OUT ...`
#      until the verbs went, and the last of them was `drydock-macho-rewrite edit <copy>
#      OUT SCRIPT`, which was this same script read from a file; the fixture,
#      the refusal and every assertion are unchanged, because what must not
#      crash is mr_process_thin, not the spelling that reaches it.
#
#      The OUT is removed beforehand and must still be absent afterwards: a
#      refusal writes nothing, which is a second fact worth having here -- the
#      input being untouched is no longer the whole of it.
sectionless_script() {
    needle="$1"; shift
    sl_desc="$*"
    for gm in "" /usr/lib/libgmalloc.dylib; do
        what="drydock-macho-rewrite $sl_desc: sectionless 8192-byte image${gm:+ (libgmalloc)}"
        if [ -n "$gm" ] && [ ! -f "$gm" ]; then
            skip "$what" "no $gm on this host"
            continue
        fi
        cp "$T/sectionless.macho" "$T/sl.macho"
        rm -f "$T/sl.out.macho"
        rc=0
        printf '%s\n' "$@" | (
            [ -n "$gm" ] && { DYLD_INSERT_LIBRARIES=$gm; export DYLD_INSERT_LIBRARIES; }
            exec "$BIN/drydock-macho-rewrite" "$T/sl.macho" "$T/sl.out.macho"
        ) >"$T/sl.out" 2>"$T/sl.err" || rc=$?
        if [ "$rc" -eq 1 ] && grep -qF "$needle" "$T/sl.err"; then
            ok "$what: refuses (1), naming the missing section data"
        else
            bad "$what" "expected exit 1 + '$needle', got exit $rc: $(cat "$T/sl.err")"
        fi
        if cmp -s "$T/sectionless.macho" "$T/sl.macho"; then
            ok "$what: leaves the file byte-identical"
        else
            bad "$what" "the file changed: $(cmp -l "$T/sectionless.macho" "$T/sl.macho" | wc -l | tr -d ' ') byte(s) differ"
        fi
        [ ! -e "$T/sl.out.macho" ] \
            && ok "$what: writes no output either" \
            || bad "$what" "a refused run left an output behind"
    done
}
sectionless_script "$rewrite_refusal" 'dylib append /x'
sectionless_script "$rewrite_refusal" 'rpath append /x'
sectionless_script "$rewrite_refusal" 'load-command delete uuid'
sectionless_script "$rewrite_refusal" 'segment rename __TEXT __TEXX'

info_rc=0
"$BIN/drydock-macho-rewrite" info "$T/sectionless.macho" >"$T/sl_info.out" 2>&1 || info_rc=$?
if [ "$info_rc" -eq 0 ] && grep -q "^header pad: unknown (no section data bounds it)$" "$T/sl_info.out"; then
    ok "drydock-macho-rewrite info: sectionless image: the header pad is reported unknown, not a number"
else
    bad "drydock-macho-rewrite info: sectionless image" "expected exit 0 + 'header pad: unknown', got exit $info_rc: $(cat "$T/sl_info.out")"
fi

# --- a dylib append statement, and info: a first section past the end of the image --------
# mr_process_thin's commit memset clears the load-command area up to the first
# section's file offset. On oobsection.macho that offset is 0x7000 and the file
# is 184 bytes, so trusting it clears roughly 28 KB past the buffer (SIGSEGV
# under libgmalloc). It must refuse (1) before
# anything uses the offset, and leave the file as it was. `drydock-macho-rewrite info` must
# not report a pad measured against that offset either.
for gm in "" /usr/lib/libgmalloc.dylib; do
    what="dylib append: oobsection fixture${gm:+ (libgmalloc)}"
    if [ -n "$gm" ] && [ ! -f "$gm" ]; then
        skip "$what" "no $gm on this host"
        continue
    fi
    cp "$T/oobsection.macho" "$T/od.macho"
    rm -f "$T/od.out.macho"
    rc=0
    if [ -n "$gm" ]; then
        mt_append "$gm" "$T/od.macho" "$T/od.out.macho" \
            >"$T/od.out" 2>"$T/od.err" || rc=$?
    else
        mt_append "" "$T/od.macho" "$T/od.out.macho" \
            >"$T/od.out" 2>"$T/od.err" || rc=$?
    fi
    if [ "$rc" -gt 127 ]; then
        bad "$what" "killed by a signal (exit $rc) -- the out-of-bounds clear this fixture exists to catch"
    elif [ "$rc" -eq 1 ] && grep -qF "lies past the end of the image" "$T/od.err"; then
        ok "$what: refuses (1), naming the section past the end of the image"
    else
        bad "$what" "expected exit 1 + 'lies past the end of the image', got exit $rc: $(cat "$T/od.err")"
    fi
    if cmp -s "$T/oobsection.macho" "$T/od.macho"; then
        ok "$what: leaves the file byte-identical"
    else
        bad "$what" "the file changed"
    fi
    [ ! -e "$T/od.out.macho" ] \
        && ok "$what: writes no output either" \
        || bad "$what" "a refused run left an output behind"
done

info_rc=0
"$BIN/drydock-macho-rewrite" info "$T/oobsection.macho" >"$T/oi.out" 2>&1 || info_rc=$?
if [ "$info_rc" -eq 0 ] && grep -q "^header pad: unknown (the first section lies past the end of the image)$" "$T/oi.out"; then
    ok "drydock-macho-rewrite info: oobsection fixture: the header pad is reported unknown, not a number"
else
    bad "drydock-macho-rewrite info: oobsection fixture" "expected exit 0 + 'header pad: unknown', got exit $info_rc: $(cat "$T/oi.out")"
fi

# --- retag_swift_classes ----------------------------------------------------
cp "$T/oobsection.macho" "$T/rt.macho"
rc=0
"$BIN/retag_swift_classes" "$T/rt.macho" >"$T/rt.out" 2>"$T/rt.err" || rc=$?
if [ "$rc" -gt 127 ]; then
    bad "retag_swift_classes: oobsection fixture" "killed by a signal (exit $rc) -- the heap overflow this fixture exists to catch"
elif [ "$rc" -eq 0 ] && grep -q "^total: 0 class record(s) retagged$" "$T/rt.out"; then
    ok "retag_swift_classes: refuses (not crashes) an out-of-bounds section range"
else
    bad "retag_swift_classes: oobsection fixture" "expected exit 0 + 'total: 0' output, got exit $rc: $(cat "$T/rt.out") $(cat "$T/rt.err")"
fi

if [ -f /usr/lib/libgmalloc.dylib ]; then
    cp "$T/oobsection.macho" "$T/rt_gm.macho"
    rc=0
    DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib \
        "$BIN/retag_swift_classes" "$T/rt_gm.macho" >"$T/rt_gm.out" 2>"$T/rt_gm.err" || rc=$?
    if [ "$rc" -gt 127 ]; then
        bad "retag_swift_classes: oobsection fixture (libgmalloc)" "killed by a signal (exit $rc) under libgmalloc -- the heap overflow this fixture exists to catch"
    else
        ok "retag_swift_classes: oobsection fixture (libgmalloc): completed without crashing (exit $rc)"
    fi
else
    skip "retag_swift_classes: oobsection fixture (libgmalloc)" "no /usr/lib/libgmalloc.dylib on this host"
fi

# process()'s return value used to be computed and discarded in main(): a
# failed open/stat/write (already reported via perror/fprintf) was silently
# indistinguishable from "0 classes found", so this exited 0 even though it
# had just printed an error. A nonexistent path is the simplest repro of a
# real process() failure (open() fails, `perror` fires) that doesn't need a
# fixture at all.
rc=0
"$BIN/retag_swift_classes" "$T/no-such-file.macho" >"$T/rt_missing.out" 2>"$T/rt_missing.err" || rc=$?
if [ "$rc" -eq 1 ]; then
    ok "retag_swift_classes: a real failure (nonexistent path) exits nonzero, not silently 0"
else
    bad "retag_swift_classes: nonexistent path" "expected exit 1, got exit $rc: $(cat "$T/rt_missing.out") $(cat "$T/rt_missing.err")"
fi

# --- patch_macho: pm_collect_ctx's to_remove[] must refuse, not overflow ----
#
# Moving patch_macho.c's collecting walk into an mi_each_lc callback
# put its fixed-size `to_remove[]` array (originally sized [4]) into the
# SAME context struct as `int n_remove`, with n_remove declared immediately
# after the array -- same layout hazard as segs[32]/nsegs just above it in
# that struct, but without the matching `>= 32` style bound. With the array
# at its original size [4], a 5th push (any mix of LC_DYLD_EXPORTS_TRIE/
# LC_DYLD_CHAINED_FIXUPS/LC_BUILD_VERSION -- this fixture uses LC_BUILD_
# VERSION because it is trivial to repeat N times) wrote to_remove[4], one
# element past the array, landing on n_remove itself; every push after that
# walked further off the struct into main()'s locals. A malformed/
# pathological input the tool had declined cleanly went from a clean
# refusal to a crash mid-run in a tool install.sh points at user binaries.
#
# The array was then enlarged from [4] to [16] (see the comment above struct
# md_collect_ctx in src/declassify.c): review found that [4] left ZERO margin
# on a real, legitimate input -- a zippered (Mac Catalyst) binary carries two
# LC_BUILD_VERSION commands plus at most one each of LC_DYLD_EXPORTS_TRIE/
# LC_DYLD_CHAINED_FIXUPS, for 1+1+2 = 4, exactly the old cap. This fixture's
# N values target the CURRENT [16] boundary, not the original [4] one the
# bug was found at, so the test keeps testing the actual edge rather than an
# arbitrary interior point.
#
# N=15/N=16 stay at-or-under the cap and must still succeed structurally
# (this fixture has no chained fixups, so patch_macho's own "No chained
# fixups found" refusal fires afterward -- exit 1, but a CLEAN one, not a
# crash). N=17/N=18 sit one and two past the cap: pre-the-[4]-fix, values in
# this shape corrupted n_remove into something that still looked like a
# small int (free() on a bogus pointer -> exit 134, "pointer being freed was
# not allocated") or into something that didn't (-> exit 139, SIGSEGV);
# post-fix, every N at or past the cap must refuse cleanly (exit 1, naming
# the overflow) with the file left untouched, exactly like segs[32]'s
# existing refusal just above.
cat > "$T/mkmanylc.c" <<'EOF'
/* Writes a Mach-O with N x LC_BUILD_VERSION load commands (ntools=0, so each
 * is a fixed 24 bytes -- already 8-aligned, satisfying mi_validate's cmdsize
 * alignment check) and nothing else. No LC_SEGMENT_64 at all: patch_macho's
 * mi_find_segment(&im, "__TEXT") lookup tolerates that (returns NULL,
 * image_base_vmaddr stays 0), so this exercises pm_collect_lc's to_remove[]
 * pushes in isolation, the same way leaf-tool-crashes' other fixtures target
 * one specific hazard each. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <mach-o/loader.h>
#include "mach_compat.h"   /* LC_BUILD_VERSION: not in the 10.9 SDK's own headers */

struct bvc { uint32_t cmd, cmdsize, platform, minos, sdk, ntools; };

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: %s N out\n", argv[0]); return 1; }
    int n = atoi(argv[1]);
    if (n < 1 || n > 64) { fprintf(stderr, "N out of range\n"); return 1; }

    size_t fsize = sizeof(struct mach_header_64) + (size_t)n * sizeof(struct bvc);
    uint8_t *buf = calloc(1, fsize);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    h->magic = MH_MAGIC_64;
    h->ncmds = (uint32_t)n;
    h->sizeofcmds = (uint32_t)(n * sizeof(struct bvc));

    struct bvc *c = (struct bvc *)(buf + sizeof(*h));
    for (int i = 0; i < n; i++) {
        c[i].cmd = LC_BUILD_VERSION;
        c[i].cmdsize = sizeof(struct bvc);
    }

    FILE *f = fopen(argv[2], "wb");
    if (!f) { perror("fopen"); return 1; }
    if (fwrite(buf, 1, fsize, f) != fsize) { perror("fwrite"); fclose(f); return 1; }
    fclose(f);
    return 0;
}
EOF
"$CC" -O2 -I "$SRC_DIR" -o "$T/mkmanylc" "$T/mkmanylc.c"

pm_manylc_case() {
    n="$1"; expect="$2"   # expect: "clean" (refuses/errors without crashing) or "cap" (refuses, names the cap)
    "$T/mkmanylc" "$n" "$T/manylc_$n.macho"
    before_md5=$(md5 -q "$T/manylc_$n.macho" 2>/dev/null || md5sum "$T/manylc_$n.macho" | awk '{print $1}')
    rc=0
    "$BIN/patch_macho" "$T/manylc_$n.macho" "$T/manylc_${n}_out.macho" \
        >"$T/manylc_$n.out" 2>"$T/manylc_$n.err" || rc=$?
    after_md5=$(md5 -q "$T/manylc_$n.macho" 2>/dev/null || md5sum "$T/manylc_$n.macho" | awk '{print $1}')

    if [ "$rc" -gt 127 ]; then
        bad "patch_macho: N=$n LC_BUILD_VERSION" "killed by a signal (exit $rc) -- the to_remove[] overflow this fixture exists to catch"
        return
    fi
    if [ "$expect" = "cap" ]; then
        if [ "$rc" -eq 1 ] && grep -q "more than 16 load commands to strip" "$T/manylc_$n.err"; then
            ok "patch_macho: N=$n LC_BUILD_VERSION refuses, naming the to_remove[] cap"
        else
            bad "patch_macho: N=$n LC_BUILD_VERSION" "expected exit 1 + cap message, got exit $rc: $(cat "$T/manylc_$n.err")"
        fi
        [ "$before_md5" = "$after_md5" ] \
            && ok "patch_macho: N=$n LC_BUILD_VERSION leaves the input untouched on refusal" \
            || bad "patch_macho: N=$n LC_BUILD_VERSION" "input was modified despite the refusal"
    else
        [ "$rc" -eq 1 ] \
            && ok "patch_macho: N=$n LC_BUILD_VERSION completes without crashing (exit $rc, under the cap)" \
            || bad "patch_macho: N=$n LC_BUILD_VERSION" "expected a clean exit 1 (no chained fixups), got exit $rc: $(cat "$T/manylc_$n.err")"
    fi
}

pm_manylc_case 15 clean
pm_manylc_case 16 clean
pm_manylc_case 17 cap
pm_manylc_case 18 cap

if [ -f /usr/lib/libgmalloc.dylib ]; then
    for n in 17 18; do
        "$T/mkmanylc" "$n" "$T/manylc_gm_$n.macho"
        rc=0
        DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib \
            "$BIN/patch_macho" "$T/manylc_gm_$n.macho" "$T/manylc_gm_${n}_out.macho" \
            >"$T/manylc_gm_$n.out" 2>"$T/manylc_gm_$n.err" || rc=$?
        if [ "$rc" -gt 127 ]; then
            bad "patch_macho: N=$n LC_BUILD_VERSION (libgmalloc)" "killed by a signal (exit $rc) under libgmalloc"
        else
            ok "patch_macho: N=$n LC_BUILD_VERSION (libgmalloc): completed without crashing (exit $rc)"
        fi
    done
else
    skip "patch_macho: N=17/18 LC_BUILD_VERSION (libgmalloc)" "no /usr/lib/libgmalloc.dylib on this host"
fi

reached_end=1
echo "leaf-tool-crashes: $fails failure(s)"
[ "$fails" -eq 0 ]
