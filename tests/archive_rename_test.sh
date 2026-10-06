#!/bin/sh
# tests/archive_rename_test.sh -- `symbol rename OLD NEW` across a static
# archive made by this host's libtool, ar and ranlib: linked and run, the
# rebuilt index compared with ranlib's, and the archive-scope refusals.
#
#   sh tests/archive_rename_test.sh <bindir>
#
# Exits 77 where this host has no libtool. The bitcode and universal cases
# print a SKIP line and go on where the compiler cannot make their fixture;
# the moved-__data case skips its link, and its archive form, where this
# host's ld or libtool refuses that object.
set -u

BIN="${1:?usage: archive_rename_test.sh <bindir>}"
DMR="$BIN/drydock-macho-rewrite"
[ -x "$DMR" ] || { echo "archive_rename_test: $DMR not found or not executable" >&2; exit 1; }
command -v libtool >/dev/null 2>&1 && command -v ranlib >/dev/null 2>&1 \
    || { echo "SKIP: archive_rename_test: no libtool or ranlib on this host"; exit 77; }
CC="${CC:-clang}"
FIXTURE_FLAGS="-arch x86_64 -mmacosx-version-min=10.9"
ZERO_AR_DATE=1
export ZERO_AR_DATE

T=$(mktemp -d "${TMPDIR:-/tmp}/archive_rename_test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

REFUSED=$("$DMR" --capabilities | sed -n 's/^exitcodes .*refused=\([0-9]*\).*/\1/p')
[ -n "$REFUSED" ] || { echo "archive_rename_test: no refused= in --capabilities' exitcodes line" >&2; exit 1; }

src() { cat >"$T/$1.c"; "$CC" $FIXTURE_FLAGS -c -o "$T/$1.o" "$T/$1.c" || exit 1; }
lib() { out=$1; shift; rm -f "$out"; libtool -static -o "$out" "$@" || exit 1; }

# append ARCHIVE NAME FILE -- FILE as a member the way 10.9's libtool lays one
# out (a #1/N name, '\n' padding inside the size to an 8-byte end), written
# by hand: modern ranlib drops a non-Mach-O member, and ar q runs ranlib.
append() {
    a_len=$(wc -c <"$1" | tr -d ' ') d_len=$(wc -c <"$3" | tr -d ' ')
    [ $((a_len % 8)) -eq 0 ] || { echo "archive_rename_test: $1 does not end 8-aligned" >&2; exit 1; }
    a_n=$(( (${#2} + 7) / 8 * 8 + 4 ))
    a_pad=$(( (8 - (60 + a_n + d_len) % 8) % 8 ))
    {
        printf '%-16s%-12s%-6s%-6s%-8s%-10s`\n' "#1/$a_n" 0 0 0 100644 $((a_n + d_len + a_pad))
        printf '%s' "$2"
        i=${#2}; while [ $i -lt $a_n ]; do printf '\000'; i=$((i + 1)); done
        cat "$3"
        i=0; while [ $i -lt $a_pad ]; do printf '\n'; i=$((i + 1)); done
    } >>"$1"
}

run() {
    run_in=$1 run_out=$2; shift 2
    rm -f "$run_out"
    run_rc=0
    printf '%s\n' "$@" | "$DMR" "$run_in" "$run_out" >"$T/run.out" 2>"$T/run.err" || run_rc=$?
}
said() { grep -qF -- "$1" "$T/run.err"; }
member_has() { ar p "$1" "$2" >"$T/member.o" && nm -p "$T/member.o" | awk -v s="$3" -v t="$4" '$NF == s && $(NF-1) == t { f = 1 } END { exit !f }'; }
member_lacks() { ar p "$1" "$2" >"$T/member.o" && ! nm -p "$T/member.o" | awk -v s="$3" '$NF == s { f = 1 } END { exit !f }'; }

# index ARCHIVE MODE -- the first member, a 32-bit __.SYMDEF*, one decimal
# byte per line ("bytes", MASKed when set), "names" with each entry's offset,
# or "padding": the offset of the string pool's last byte, if it is padding.
index() {
    od -An -v -tu1 "$1" | awk -v mode="$2" -v mask="${MASK:-0}" '
        { for (i = 1; i <= NF; i++) b[n++] = $i }
        function le(o) { return b[o] + 256 * (b[o+1] + 256 * (b[o+2] + 256 * b[o+3])) }
        function str(o,   s) { s = ""; while (b[o] != 0) s = s sprintf("%c", b[o++]); return s }
        END {
            if (str(8) !~ /^#1\//) { print "no #1/N index header"; exit 1 }
            nl = 0; for (i = 11; b[i] >= 48 && b[i] <= 57; i++) nl = nl * 10 + b[i] - 48
            sz = 0; for (i = 56; b[i] >= 48 && b[i] <= 57; i++) sz = sz * 10 + b[i] - 48
            if (str(68) !~ /^__\.SYMDEF/) { print "first member is not an index"; exit 1 }
            body = 68 + nl; nb = le(body); pool = body + 8 + nb; strsize = le(body + 4 + nb)
            used = 0
            for (e = 0; e < nb / 8; e++) {
                x = le(body + 4 + 8 * e)
                if (mode == "names") print str(pool + x), le(body + 8 + 8 * e)
                end = pool + x + length(str(pool + x)) + 1
                if (end - pool > used) used = end - pool
            }
            if (mode == "padding") { if (used < strsize) print pool + strsize - 1; exit 0 }
            if (mode != "bytes") exit 0
            for (i = 8; i < 68 + sz; i++) {
                if (mask && ((i >= 24 && i < 36) || (i >= pool + used && i < pool + strsize))) print "masked"
                else print b[i]
            }
        }'
}

# ---- fixtures ----------------------------------------------------------------
src impl <<'EOF'
int foo(void) { return 42; }
EOF
src other <<'EOF'
int foo(void);
int other(void) { return foo() + 100; }
EOF
src helper <<'EOF'
int helper(void) { return 5; }
EOF
src stub <<'EOF'
int foo(void) { extern int impl_foo(void); return impl_foo() + 1; }
EOF
src main <<'EOF'
#include <stdio.h>
int foo(void); int other(void);
int main(void) { printf("%d %d\n", foo(), other()); return 0; }
EOF
printf 'abcde' >"$T/odd.txt"
mkdir "$T/in" "$T/out"
# libt.a, objects only, is the one linked: modern ld64 refuses an archive
# holding a member that is not Mach-O. libtx.a adds the odd-size text member,
# with helper.o after it, both appended by hand; it is checked, never linked.
lib "$T/in/libt.a" "$T/impl.o" "$T/other.o" "$T/helper.o"
[ "$(ar t "$T/in/libt.a" | tr '\n' ' ')" = "__.SYMDEF SORTED impl.o other.o helper.o " ] \
    || { echo "archive_rename_test: unexpected fixture layout: $(ar t "$T/in/libt.a")" >&2; exit 1; }
lib "$T/in/libtx.a" "$T/impl.o" "$T/other.o"
append "$T/in/libtx.a" odd.txt "$T/odd.txt"
append "$T/in/libtx.a" helper.o "$T/helper.o"
[ "$(ar t "$T/in/libtx.a" | tr '\n' ' ')" = "__.SYMDEF SORTED impl.o other.o odd.txt helper.o " ] \
    || { echo "archive_rename_test: unexpected fixture layout: $(ar t "$T/in/libtx.a")" >&2; exit 1; }

# ---- forwarding through an archive ------------------------------------------
run "$T/in/libt.a" "$T/out/libt.a" 'symbol rename _foo _impl_foo'
[ "$run_rc" -eq 0 ] && ok "forwarding: rename exits 0" || bad "forwarding" "rc $run_rc: $(cat "$T/run.err")"
said "      impl.o: 1 entry" && said "      other.o: 1 entry" && said "symbol rename _foo -> _impl_foo: 2 entries" \
    && ok "forwarding: one line per changed member, then the total" || bad "forwarding report" "$(cat "$T/run.err")"
member_has "$T/out/libt.a" impl.o _impl_foo T && member_lacks "$T/out/libt.a" impl.o _foo \
    && ok "forwarding: impl.o defines _impl_foo and has no _foo" || bad "forwarding impl.o" "$(nm -p "$T/member.o")"
member_has "$T/out/libt.a" other.o _impl_foo U && member_lacks "$T/out/libt.a" other.o _foo \
    && ok "forwarding: other.o's undefined reference is renamed too" || bad "forwarding other.o" "$(nm -p "$T/member.o")"
if "$CC" $FIXTURE_FLAGS -o "$T/fwd" "$T/main.o" "$T/stub.o" -L"$T/out" -lt >"$T/link.err" 2>&1; then
    [ "$("$T/fwd")" = "43 142" ] && ok "forwarding: links with -lt and prints the stub's 43" \
        || bad "forwarding run" "printed $("$T/fwd")"
else
    bad "forwarding link" "$(cat "$T/link.err")"
fi

# ---- the same rename beside a text member -----------------------------------
run "$T/in/libtx.a" "$T/out/libtx.a" 'symbol rename _foo _impl_foo'
[ "$run_rc" -eq 0 ] && said "symbol rename _foo -> _impl_foo: 2 entries" \
    && ok "text member: rename exits 0 and counts 2 entries" || bad "text member" "rc $run_rc: $(cat "$T/run.err")"
if said "helper.o:" || said "odd.txt:"; then bad "text member report" "names an unchanged member: $(cat "$T/run.err")"
else ok "text member: unchanged members are not reported"; fi
for m in odd.txt helper.o; do
    ar p "$T/in/libtx.a" $m >"$T/m_in" && ar p "$T/out/libtx.a" $m >"$T/m_out" && cmp -s "$T/m_in" "$T/m_out" \
        && ok "text member: $m is byte-identical, padding included" || bad "text member $m" "the unchanged member changed"
done
[ "$(ar p "$T/out/libtx.a" odd.txt | od -An -c | tr -d ' ')" = 'abcde\n\n\n' ] \
    && ok "text member: odd.txt keeps its newline padding" || bad "text member padding" "$(ar p "$T/out/libtx.a" odd.txt | od -c)"
# helper.o is last and odd.txt is 80 bytes (as append lays them out), so the
# headers sit where these say.
h_len=$(wc -c <"$T/helper.o" | tr -d ' ')
helper_at=$(($(wc -c <"$T/out/libtx.a") - 72 - h_len - (8 - (72 + h_len) % 8) % 8))
odd_at=$((helper_at - 80))
[ "$(tail -c +$((odd_at + 1)) "$T/out/libtx.a" | head -c 5)" = '#1/12' ] \
    && [ "$(tail -c +$((helper_at + 73)) "$T/out/libtx.a" | head -c 4 | od -An -tx1 | tr -d ' ')" = cffaedfe ] \
    && ok "text member: odd.txt's header, and helper.o's after it, are where their sizes put them" \
    || bad "text member offsets" "odd.txt at $odd_at, helper.o at $helper_at"
offsets=$(index "$T/out/libtx.a" names | awk '{ printf "%s@%s ", $1, $2 }')
first=$(($(index "$T/out/libtx.a" bytes | wc -l) + 8))
[ "$offsets" = "_helper@$helper_at _impl_foo@$first _other@$((first + 60 + 12 + $(ar p "$T/out/libtx.a" impl.o | wc -c))) " ] \
    && ok "text member: the index points _helper past odd.txt, at helper.o's header" \
    || bad "text member index" "$offsets (helper.o at $helper_at, impl.o at $first)"

# ---- the rebuilt index is ranlib's ------------------------------------------
# 10.9's ranlib leaves the index string pool's padding uninitialised, so there
# the date and that padding are masked; elsewhere the comparison is strict.
names=$(index "$T/out/libt.a" names | awk '{ printf "%s ", $1 }')
[ "$names" = "_helper _impl_foo _other " ] \
    && ok "index: names _impl_foo, not _foo, sorted" || bad "index names" "$names"
MASK=0
[ "$(uname -s)" = Darwin ] && [ "$(uname -r | cut -d. -f1)" = 13 ] && MASK=1
like_ranlib() {   # like_ranlib ARCHIVE LABEL
    cp "$1" "$T/ranlibbed.a"
    ranlib "$T/ranlibbed.a" 2>"$T/ranlib.err" || { bad "$2" "ranlib failed: $(cat "$T/ranlib.err")"; return; }
    if [ "$(ar t "$1")" != "$(ar t "$T/ranlibbed.a")" ]; then
        echo "SKIP $2: this ranlib drops a member: $(ar t "$T/ranlibbed.a" | tr '\n' ' ')"
        return
    fi
    index "$1" bytes >"$T/idx_ours" && index "$T/ranlibbed.a" bytes >"$T/idx_ranlib" \
        || bad "$2" "cannot read an index: $(cat "$T/idx_ours" "$T/idx_ranlib")"
    if cmp -s "$T/idx_ours" "$T/idx_ranlib"; then
        ok "$2: the index is byte-identical to ranlib's $( [ $MASK = 1 ] && echo '(date and string padding masked)' || echo '(strict)')"
    else
        bad "$2" "the index differs from ranlib's: $(diff "$T/idx_ours" "$T/idx_ranlib" | head -5 | tr '\n' ' ')"
    fi
    n=$(($(wc -l <"$T/idx_ours") + 9))
    tail -c +$n "$1" >"$T/rest_ours"; tail -c +$n "$T/ranlibbed.a" >"$T/rest_ranlib"
    cmp -s "$T/rest_ours" "$T/rest_ranlib" && ok "$2: ranlib moves no member" || bad "$2" "ranlib re-laid out the members"
}
like_ranlib "$T/out/libt.a" "index"
like_ranlib "$T/out/libtx.a" "index beside a text member"

# ---- OLD only referenced, never defined -------------------------------------
lib "$T/in/libu.a" "$T/other.o" "$T/helper.o"
run "$T/in/libu.a" "$T/out/libu.a" 'symbol rename _foo _impl_foo'
[ "$run_rc" -eq 0 ] && said "      other.o: 1 entry" && said "symbol rename _foo -> _impl_foo: 1 entry" \
    && ! said "matched nothing" \
    && ok "undefined only: renamed, counted, and not \"matched nothing\"" || bad "undefined only" "rc $run_rc: $(cat "$T/run.err")"
member_has "$T/out/libu.a" other.o _impl_foo U \
    && ok "undefined only: other.o references _impl_foo" || bad "undefined only nm" "$(nm -p "$T/member.o")"

# ---- an archive with no index, odd member padded outside its size -----------
rm -f "$T/in/libn.a"
(cd "$T" && ar rcS "$T/in/libn.a" odd.txt impl.o) || exit 1
run "$T/in/libn.a" "$T/out/libn.a" 'symbol rename _foo _impl_foo'
[ "$run_rc" -eq 0 ] && member_has "$T/out/libn.a" impl.o _impl_foo T \
    && ok "no index: impl.o renamed" || bad "no index" "rc $run_rc: $(cat "$T/run.err")"
[ "$(ar t "$T/out/libn.a" | tr '\n' ' ')" = "odd.txt impl.o " ] \
    && ok "no index: none is added" || bad "no index" "$(ar t "$T/out/libn.a")"

# ---- an object padded inside its size, where the layout is not 8-aligned ----
cp "$T/impl.o" "$T/padded.o"
printf '\n\n\n\n' >>"$T/padded.o"
rm -f "$T/in/libp.a"
(cd "$T" && ar rcS "$T/in/libp.a" odd.txt padded.o helper.o) || exit 1
run "$T/in/libp.a" "$T/out/libp.a" 'symbol rename _helper _h2'
ar p "$T/out/libp.a" padded.o >"$T/m_out"
[ "$run_rc" -eq 0 ] && cmp -s "$T/padded.o" "$T/m_out" \
    && ok "padded: an untouched object keeps its padding" || bad "padded untouched" "rc $run_rc: $(cat "$T/run.err")"
run "$T/in/libp.a" "$T/out/libp.a" 'symbol rename _foo _impl_foo'
[ "$run_rc" -eq 0 ] && member_has "$T/out/libp.a" padded.o _impl_foo T \
    && ok "padded: a renamed object is cut back to its string table first" || bad "padded renamed" "rc $run_rc: $(cat "$T/run.err")"

# ---- a section that lives past the string table, among zero bytes ----------
# The zeros look like padding, but __data claims them: appending NEW there
# would change z[0].
cat >"$T/zdata.c" <<'EOF'
int z[16] = {0};
int foo(void) { return 42; }
EOF
"$CC" $FIXTURE_FLAGS -fno-zero-initialized-in-bss -c -o "$T/zdata.o" "$T/zdata.c" || exit 1
cat >"$T/movedata.c" <<'EOF'
#include <mach-o/loader.h>
#include <stdio.h>
#include <string.h>
static unsigned char b[1 << 20];
int main(int argc, char **argv) {
    FILE *f = fopen(argv[1], "rb");
    size_t n = fread(b, 1, sizeof b / 2, f);
    struct mach_header_64 *h = (struct mach_header_64 *)b;
    unsigned char *p = b + sizeof *h;
    struct section_64 *data = NULL;
    struct symtab_command *st = NULL;
    fclose(f);
    for (uint32_t i = 0; i < h->ncmds; p += ((struct load_command *)p)->cmdsize, i++) {
        struct load_command *lc = (struct load_command *)p;
        if (lc->cmd == LC_SYMTAB) st = (struct symtab_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *sg = (struct segment_command_64 *)p;
            struct section_64 *s = (struct section_64 *)(sg + 1);
            for (uint32_t j = 0; j < sg->nsects; j++)
                if (strcmp(s[j].sectname, "__data") == 0) data = &s[j];
        }
    }
    if (!data || !st || st->stroff + st->strsize != n || data->size > sizeof b / 2) return 1;
    data->offset = (uint32_t)n;
    n += data->size;
    f = fopen(argv[2], "wb");
    return !f || fwrite(b, 1, n, f) != n || fclose(f) != 0;
}
EOF
"$CC" -o "$T/movedata" "$T/movedata.c" || exit 1
"$T/movedata" "$T/zdata.o" "$T/zd.o" || { echo "archive_rename_test: cannot move zdata.o's __data" >&2; exit 1; }
cat >"$T/zmain.c" <<'EOF'
#include <stdio.h>
extern int z[16];
int main(void) { printf("%d\n", z[0]); return 0; }
EOF
"$CC" $FIXTURE_FLAGS -c -o "$T/zmain.o" "$T/zmain.c" || exit 1
# The precondition, where this host's ld accepts the object: it links, and
# reads z[0] as 0. macos-26's ld refuses it ("LINKEDIT overlap").
if "$CC" $FIXTURE_FLAGS -o "$T/zrun" "$T/zmain.o" "$T/zd.o" >"$T/link.err" 2>&1; then
    [ "$("$T/zrun")" = 0 ] && ok "moved __data: the hand-moved object links and prints 0" \
        || bad "moved __data" "the fixture links but prints $("$T/zrun")"
else
    echo "SKIP moved __data link: this host's linker refuses the fixture: $(grep -m1 . "$T/link.err")"
fi
run "$T/zd.o" "$T/x.o" 'symbol rename _foo _impl_foo'
[ "$run_rc" -eq "$REFUSED" ] && [ ! -e "$T/x.o" ] && said "the string table is not the last thing in the file" \
    && ok "refused: a thin object whose __data lies past its string table" || bad "moved __data thin" "rc $run_rc: $(cat "$T/run.err")"
rm -f "$T/in/libzd.a"
if libtool -static -o "$T/in/libzd.a" "$T/zd.o" >"$T/libtool.err" 2>&1; then
    run "$T/in/libzd.a" "$T/x.a" 'symbol rename _foo _impl_foo'
    if [ "$run_rc" -eq "$REFUSED" ] && [ ! -e "$T/x.a" ] \
        && said "member zd.o: symbol rename _foo _impl_foo: the string table is not the last thing in the file"; then
        ok "refused: a member whose __data lies past its string table"
    else
        bad "moved __data in an archive" "rc $run_rc (want $REFUSED): $(cat "$T/run.err")"
    fi
else
    echo "SKIP moved __data in an archive: this host's libtool refuses the fixture: $(grep -m1 . "$T/libtool.err")"
fi
lib "$T/in/libz.a" "$T/zdata.o"
run "$T/in/libz.a" "$T/out/libz.a" 'symbol rename _foo _impl_foo'
[ "$run_rc" -eq 0 ] && member_has "$T/out/libz.a" zdata.o _impl_foo T \
    && ok "moved __data: the unmoved object renames in an archive" || bad "unmoved __data" "rc $run_rc: $(cat "$T/run.err")"

refused() {
    if [ "$run_rc" -eq "$REFUSED" ] && said "$2" && [ ! -e "$run_out" ]; then
        ok "refused: $1"
    else
        bad "refused: $1" "rc $run_rc (want $REFUSED), out $( [ -e "$run_out" ] && echo written || echo absent): $(cat "$T/run.err")"
    fi
}
left="$T/x.a not written; $T/in"

src implfoo <<'EOF'
int impl_foo(void) { return 1; }
EOF
lib "$T/in/libd.a" "$T/impl.o" "$T/implfoo.o"
run "$T/in/libd.a" "$T/x.a" 'symbol rename _foo _impl_foo'
refused "NEW defined in two members" "after the rename, _impl_foo is defined in both impl.o and implfoo.o"
said "$left/libd.a left unmodified" && ok "refused: two definers says what it left" || bad "two definers" "$(cat "$T/run.err")"

lib "$T/in/libr.a" "$T/implfoo.o" "$T/other.o"
run "$T/in/libr.a" "$T/out/libr.a" 'symbol rename _foo _impl_foo'
[ "$run_rc" -eq 0 ] && ok "a reference beside NEW's one definition is fine" || bad "reference beside NEW" "rc $run_rc: $(cat "$T/run.err")"

src both <<'EOF'
int foo(void) { return 1; }
int bar(void) { return 2; }
EOF
lib "$T/in/libb.a" "$T/helper.o" "$T/both.o"
run "$T/in/libb.a" "$T/x.a" 'symbol rename _foo _bar'
refused "NEW and OLD in one member" "member both.o: symbol rename _foo _bar: a symbol is already named _bar"

run "$T/in/libt.a" "$T/x.a" 'symbol rename _nosuch _other'
refused "OLD in no member" "symbol rename _nosuch _other matched nothing (no symbol is named _nosuch)"

pad=$(index "$T/in/libt.a" padding)
[ -n "$pad" ] || { echo "archive_rename_test: the fixture's index has no string padding" >&2; exit 1; }
cp "$T/in/libt.a" "$T/in/libj.a"
printf 'J' | dd of="$T/in/libj.a" bs=1 seek="$pad" conv=notrunc 2>/dev/null
cmp -s "$T/in/libt.a" "$T/in/libj.a" && { echo "archive_rename_test: the junk byte did not land" >&2; exit 1; }
run "$T/in/libj.a" "$T/x.a" 'allow-unmatched' 'symbol rename _nosuch _other'
[ "$run_rc" -eq 0 ] && cmp -s "$T/in/libj.a" "$T/x.a" \
    && ok "allow-unmatched: junk in the index's padding is kept, as 10.9's ranlib leaves it" \
    || bad "allow-unmatched junk" "rc $run_rc: $(cat "$T/run.err")"
run "$T/in/libt.a" "$T/x.a" 'allow-unmatched' 'symbol rename _nosuch _other'
[ "$run_rc" -eq 0 ] && said "symbol rename _nosuch _other matched nothing" && cmp -s "$T/in/libt.a" "$T/x.a" \
    && ok "allow-unmatched: reported, exit 0, OUT byte-identical to IN" \
    || bad "allow-unmatched" "rc $run_rc: $(cat "$T/run.err")"

run "$T/in/libt.a" "$T/x.a" 'rpath append /x'
refused "rpath append on an archive" \
    "\`rpath append\` is for linked images; a relocatable object or archive takes only \`symbol rename\`"

run "$T/in/libt.a" "$T/x.a" 'arch x86_64h' 'symbol rename _foo _impl_foo'
refused "a member of an arch the script does not select" "member impl.o is x86_64, which the script's arch directives do not name"

head -c 1000 "$T/in/libt.a" >"$T/in/trunc.a"
run "$T/in/trunc.a" "$T/x.a" 'symbol rename _foo _impl_foo'
refused "truncated archive" "$T/in/trunc.a: not a readable archive ("
said "$left/trunc.a left unmodified" && ok "refused: truncated says what it left" || bad "truncated" "$(cat "$T/run.err")"

if "$CC" -arch x86_64 -flto -c -o "$T/bc.o" "$T/impl.c" 2>"$T/bc.err" \
    && [ "$(od -An -tx1 -N4 "$T/bc.o" | tr -d ' ')" = dec0170b ] \
    && (cd "$T" && libtool -static -o "$T/in/libbc.a" helper.o bc.o) 2>>"$T/bc.err"; then
    run "$T/in/libbc.a" "$T/x.a" 'symbol rename _foo _impl_foo'
    refused "a bitcode member" "member bc.o is LLVM bitcode"
else
    echo "SKIP bitcode: cannot build an archive with a bitcode member: $(head -1 "$T/bc.err")"
fi

# The second arch is arm64 where the compiler targets it (CI), else i386 (10.9).
second=
for a in "arm64 -mmacosx-version-min=11.0" "i386 -mmacosx-version-min=10.9"; do
    if "$CC" -arch $a -c -o "$T/second.o" "$T/helper.c" 2>>"$T/second.err"; then second=${a%% *}; break; fi
done
if [ -n "$second" ]; then
    lib "$T/in/libsecond.a" "$T/second.o"
    lipo -create -output "$T/in/fat.a" "$T/in/libt.a" "$T/in/libsecond.a" || exit 1
    run "$T/in/fat.a" "$T/x.a" 'symbol rename _foo _impl_foo'
    refused "a universal archive (x86_64 and $second)" \
        "$T/in/fat.a is a universal archive; thin it with lipo first; $left/fat.a left unmodified"
else
    echo "SKIP universal: $CC builds neither an arm64 nor an i386 object: $(head -1 "$T/second.err")"
fi

# A 32-bit object's mach_header (MH_MAGIC, x86, MH_OBJECT, no load commands),
# written by hand: modern compilers cannot build i386.
printf '\316\372\355\376\007\000\000\000\003\000\000\000\001\000\000\000' >"$T/i386.o"
printf '\000\000\000\000\000\000\000\000\000\000\000\000' >>"$T/i386.o"
[ "$(od -An -tx1 -N4 "$T/i386.o" | tr -d ' ')" = cefaedfe ] && [ "$(wc -c <"$T/i386.o" | tr -d ' ')" = 28 ] \
    || { echo "archive_rename_test: the hand-written 32-bit header is wrong" >&2; exit 1; }
cp "$T/in/libt.a" "$T/in/lib32.a"
append "$T/in/lib32.a" i386.o "$T/i386.o"
[ "$(ar t "$T/in/lib32.a" | tail -1)" = i386.o ] || { echo "archive_rename_test: i386.o was not appended" >&2; exit 1; }
run "$T/in/lib32.a" "$T/x.a" 'symbol rename _foo _impl_foo'
refused "a 32-bit member" "member i386.o is a 32-bit Mach-O"

[ "$fail" -eq 0 ]
