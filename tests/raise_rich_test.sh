#!/bin/sh
# platform: macOS-only -- dylibs and bundles linked by ld64.lld here and by ld64-241 once (committed), then run
# tests/raise_rich_test.sh -- a dylib with everything a raise must move, built
# here, raised by one page and by two, and run: every raised copy must do
# what the original does.
#
#   sh tests/raise_rich_test.sh <bindir>
#
# librich.dylib has thread-local variables used from a second thread, C++
# exceptions caught inside it and across it, vtables, an Objective-C class,
# category, +load and literals, a constructor and an -init (LC_ROUTINES_64), a
# switch jump table, &__dso_handle and getsectiondata(&_mh_dylib_header, ...),
# data pointers to both, a stub-and-resolver export, an absolute export,
# dlsym, and -g's stabs. rich.bundle is the same code as an MH_BUNDLE, loaded
# with dlopen (ld links no resolver into a bundle); libgap.dylib has a segment
# past a gap in vm, with pointers to its start and its end.
#
# Each raised copy is driven beside the original: the outputs must be
# identical, and the original's must say every check held. The stabs that
# hold an address (N_BNSYM, named N_FUN, N_STSYM, N_LCSYM, N_SLINE, and
# N_SO/N_SOL in a section) must move by exactly the raise, and the rest stay.
#
# Fixtures are x86_64 with a 10.9 floor, which runs on 10.9.
# Two sets are raised and run: one linked here by ld64.lld, and one ld64-241
# linked once from these sources (tests/data/raise_rich_ld64-241), for what lld
# cannot make: a resolver, an -init, a -segaddr segment, the N_BNSYM stabs. A
# feature a set is named to have and lacks is a failure.
set -u

BIN="${1:?usage: raise_rich_test.sh <bindir>}"
BIN=$(cd "$BIN" && pwd)
DMR="$BIN/drydock-macho-rewrite"
[ -x "$DMR" ] || { echo "raise_rich_test: $DMR not found or not executable" >&2; exit 1; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib/toolchain.sh"
. "$ROOT/tests/lib/exec-arch.sh"
FF="-arch x86_64 -mmacosx-version-min=10.9"

fail=0
ok()   { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fail=$((fail + 1)); }
skip() { echo "SKIP $1: $2"; }

T=$(mktemp -d "${TMPDIR:-/tmp}/raise-rich.XXXXXX") || exit 1
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT INT TERM
cd "$T" || exit 1

cat >rich.c <<'EOF'
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>
#ifdef RICH_BUNDLE
#define HDR _mh_bundle_header
#else
#define HDR _mh_dylib_header
#endif
extern const char __dso_handle;

int rich_data = 7;
static int rich_static = 3;
static int rich_zero;
static int ctor_ran, init_ran;
__attribute__((constructor)) static void rich_ctor(void) { ctor_ran = 1; rich_zero = 2; }
void rich_init(void) { init_ran = 1; }

__thread int rich_tlv = 5;
static void *rich_tlv_thread(void *out) {
    rich_tlv += 10;
    *(int *)out = rich_tlv;
    return NULL;
}

__attribute__((noinline)) int rich_switch(int k, int a) {
    switch (k) {
    case 0: return a + 1;
    case 1: return a * 7;
    case 2: return a ^ 0x55;
    case 3: return a - 19;
    case 4: return a << 3;
    case 5: return a / 3;
    case 6: return a % 11;
    case 7: return ~a;
    default: return -1;
    }
}

const void *const rich_hdr_ptr = &HDR;
const void *const rich_dso_ptr = &__dso_handle;
int (*const rich_fn_ptr)(int, int) = rich_switch;
int *const rich_data_ptr = &rich_data;

int rich_resolved_impl(void) { return 99; }
#ifndef RICH_BUNDLE
__asm__(".text\n"
        ".globl _rich_resolved\n"
        ".symbol_resolver _rich_resolved\n"
        "_rich_resolved:\n"
        "    leaq _rich_resolved_impl(%rip), %rax\n"
        "    ret\n");
#endif
__asm__(".globl _rich_abs\n"
        "_rich_abs = 0x4d2\n");

void rich_report(void) {
    unsigned long size = 0;
    Dl_info info;
    int in_thread = 0;
    pthread_t t;
    const uint8_t *d = getsectiondata(&HDR, "__DATA", "__data", &size);
    dladdr((const void *)rich_report, &info);
    printf("header: magic %#x, %s\n", HDR.magic,
           (const void *)&HDR == info.dli_fbase ? "this image's" : "ANOTHER");
    printf("__dso_handle: %s\n",
           (const void *)&__dso_handle == info.dli_fbase ? "the header" : "NOT THE HEADER");
    printf("data pointers: header %s, __dso_handle %s, function %s, data %s\n",
           rich_hdr_ptr == info.dli_fbase ? "ok" : "WRONG", rich_dso_ptr == info.dli_fbase ? "ok" : "WRONG",
           rich_fn_ptr == rich_switch ? "ok" : "WRONG", rich_data_ptr == &rich_data ? "ok" : "WRONG");
    printf("__data: %s (%lu bytes), rich_data %d, static %d\n",
           d && (const uint8_t *)&rich_data >= d && (const uint8_t *)&rich_data < d + size
               ? "holds rich_data" : "MISSES rich_data",
           size, rich_data, rich_static);
    printf("constructor %d, -init %d, zero-fill %d\n", ctor_ran, init_ran, rich_zero);
    pthread_create(&t, NULL, rich_tlv_thread, &in_thread);
    pthread_join(t, NULL);
    rich_tlv += 1;
    printf("thread-local: this thread %d, the other %d\n", rich_tlv, in_thread);
    printf("switch:");
    for (int k = 0; k < 9; k++) printf(" %d", rich_fn_ptr(k, 100 + k));
    printf("\n");
}
EOF
cat >rich_cxx.cc <<'EOF'
#include <cstdio>
#include <stdexcept>
#include <string>
namespace {
struct Shape {
    virtual ~Shape() {}
    virtual int sides() const = 0;
    virtual const char *name() const { return "shape"; }
};
struct Tri : Shape {
    int sides() const { return 3; }
    const char *name() const { return "triangle"; }
};
struct Square : Shape { int sides() const { return 4; } };
}
extern "C" void rich_cxx_throw(int k) {
    if (k) throw std::out_of_range(std::string("thrown across the image, ") + std::to_string(k));
}
extern "C" void rich_cxx_report(void) {
    Shape *s[2] = { new Tri, new Square };
    int sides = 0;
    for (int i = 0; i < 2; i++) sides += s[i]->sides();
    std::printf("c++: %d sides, %s and %s\n", sides, s[0]->name(), s[1]->name());
    for (int i = 0; i < 2; i++) delete s[i];
    try { rich_cxx_throw(3); }
    catch (const std::exception &e) { std::printf("c++: caught inside: %s\n", e.what()); }
}
EOF
cat >rich_objc.m <<'EOF'
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdio.h>
static int rich_loaded;
@interface RichThing : NSObject
- (NSString *)describe;
@end
@implementation RichThing
+ (void)load { rich_loaded = 1; }
- (NSString *)describe { return @"a thing"; }
@end
@interface RichThing (Extra)
- (NSNumber *)answer;
@end
@implementation RichThing (Extra)
- (NSNumber *)answer { return @42; }
@end
void rich_objc_report(void) {
    @autoreleasepool {
        RichThing *t = [[RichThing alloc] init];
        NSArray *a = @[ @"one", @2, @3.5 ];
        NSDictionary *d = @{ @"k" : @"v" };
        printf("objc: +load %d, %s, answer %d, %lu in the array, k is %s, class %s\n", rich_loaded,
               [[t describe] UTF8String], [[t answer] intValue], (unsigned long)[a count],
               [[d objectForKey:@"k"] UTF8String], class_getName([t class]));
        [t release];
    }
}
EOF
cat >gap.c <<'EOF'
#include <stdio.h>
__attribute__((section("__GAP,__gap"))) int gap_first[4] = { 1, 2, 3, 4 };
__attribute__((section("__GAP,__gap"))) int gap_last = 5;
extern char gap_start __asm("segment$start$__GAP");
extern char gap_end __asm("segment$end$__GAP");
char *const gap_ptrs[2] = { &gap_start, &gap_end };
void gap_report(void) {
    char *const *volatile p = gap_ptrs;
    printf("gap: start %s, end %s, %ld bytes, values %d %d %d\n",
           p[0] == (char *)gap_first ? "names its first variable" : "MISSES its first variable",
           p[1] > (char *)&gap_last ? "lies past its last" : "FALLS SHORT of its last",
           (long)(p[1] - p[0]), gap_first[0], gap_first[3], gap_last);
}
EOF
# drive runs librich.dylib linked; load dlopens the image it is given.
cat >driver.c <<'EOF'
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
void driver_cxx(void (*thrower)(int));
#ifdef LINKED
void rich_report(void);
int rich_resolved(void);
extern char rich_abs;
void rich_cxx_report(void);
void rich_cxx_throw(int);
void rich_objc_report(void);
int main(void) {
    rich_report();
    printf("resolver: %s\n", rich_resolved() == 99 ? "resolved to its implementation" : "NOT RESOLVED");
    printf("absolute: %p, and by dlsym %p\n", (void *)&rich_abs, dlsym(RTLD_DEFAULT, "rich_abs"));
#ifdef RICH_CXX
    rich_cxx_report();
    driver_cxx(rich_cxx_throw);
#endif
#ifdef RICH_OBJC
    rich_objc_report();
#endif
    return 0;
}
#else
static void call(void *h, const char *name) {
    void (*f)(void) = (void (*)(void))dlsym(h, name);
    if (f) f(); else printf("%s: NOT FOUND\n", name);
}
int main(int argc, char **argv) {
    void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!h) { printf("dlopen: %s\n", dlerror()); return 1; }
    if (argc > 2) { call(h, argv[2]); return 0; }
    call(h, "rich_report");
    int (*res)(void) = (int (*)(void))dlsym(h, "rich_resolved");
    printf("resolver: %s\n", !res ? "none" : res() == 99 ? "resolved to its implementation" : "NOT RESOLVED");
    printf("absolute: %p\n", dlsym(h, "rich_abs"));
#ifdef RICH_CXX
    call(h, "rich_cxx_report");
    driver_cxx((void (*)(int))dlsym(h, "rich_cxx_throw"));
#endif
#ifdef RICH_OBJC
    call(h, "rich_objc_report");
#endif
    return 0;
}
#endif
EOF
cat >driver_cxx.cc <<'EOF'
#include <cstdio>
#include <stdexcept>
extern "C" void driver_cxx(void (*thrower)(int)) {
    try { thrower(7); std::puts("c++: nothing thrown"); }
    catch (const std::out_of_range &e) { std::printf("c++: caught across: %s\n", e.what()); }
}
EOF
# stabs FILE: each stab, in order: its type, section, value (decimal) and name.
# stabs FILE SYMBOL: the 8 bytes at SYMBOL's address, then SYMBOL's address,
# in hex.
cat >stabs.c <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
static int word(uint8_t *b, long n, const char *sym) {
    struct mach_header_64 *h = (struct mach_header_64 *)b;
    struct symtab_command *st = NULL;
    uint8_t *p = b + sizeof *h;
    for (uint32_t i = 0; i < h->ncmds; i++, p += ((struct load_command *)p)->cmdsize)
        if (((struct load_command *)p)->cmd == LC_SYMTAB) st = (struct symtab_command *)p;
    if (!st) return 1;
    struct nlist_64 *nl = (struct nlist_64 *)(b + st->symoff);
    for (uint32_t k = 0; k < st->nsyms; k++) {
        if ((nl[k].n_type & (N_STAB | N_TYPE)) != N_SECT || strcmp((char *)b + st->stroff + nl[k].n_un.n_strx, sym))
            continue;
        p = b + sizeof *h;
        for (uint32_t i = 0; i < h->ncmds; i++, p += ((struct load_command *)p)->cmdsize) {
            struct segment_command_64 *s = (struct segment_command_64 *)p;
            if (s->cmd != LC_SEGMENT_64 || nl[k].n_value < s->vmaddr || nl[k].n_value + 8 > s->vmaddr + s->filesize)
                continue;
            uint64_t off = s->fileoff + (nl[k].n_value - s->vmaddr), v;
            if ((long)(off + 8) > n) return 1;
            memcpy(&v, b + off, 8);
            printf("%#llx %#llx\n", (unsigned long long)v, (unsigned long long)nl[k].n_value);
            return 0;
        }
    }
    return 1;
}
int main(int argc, char **argv) {
    FILE *f = argc >= 2 ? fopen(argv[1], "rb") : NULL;
    if (!f) return 2;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    uint8_t *b = malloc((size_t)n);
    fseek(f, 0, SEEK_SET);
    if (!b || fread(b, 1, (size_t)n, f) != (size_t)n) return 2;
    if (argc == 3) return word(b, n, argv[2]);
    struct mach_header_64 *h = (struct mach_header_64 *)b;
    uint8_t *p = b + sizeof *h;
    for (uint32_t i = 0; i < h->ncmds; i++, p += ((struct load_command *)p)->cmdsize) {
        struct symtab_command *st = (struct symtab_command *)p;
        if (st->cmd != LC_SYMTAB) continue;
        struct nlist_64 *nl = (struct nlist_64 *)(b + st->symoff);
        for (uint32_t k = 0; k < st->nsyms; k++)
            if (nl[k].n_type & N_STAB)
                printf("%u\t%u\t%llu\t=%s\n", nl[k].n_type, nl[k].n_sect, (unsigned long long)nl[k].n_value,
                       nl[k].n_un.n_strx ? (char *)b + st->stroff + nl[k].n_un.n_strx : "");
    }
    return 0;
}
EOF
"$HOST_CC" -O2 -o stabs stabs.c || { echo "raise_rich_test: could not build the stab reader" >&2; exit 1; }

# ---- build ------------------------------------------------------------------
build() { "$@" >build.log 2>&1 || { echo "raise_rich_test: $*" >&2; cat build.log >&2; exit 1; }; }
build "$CC" $FF -g -O2 -c rich.c -o rich.o
build "$CC" $FF -g -O2 -DRICH_BUNDLE -c rich.c -o rich_bundle.o
build "$CC" $FF -g -O2 -c gap.c -o gap.o
build "$CXX" $FF -stdlib=libc++ -g -O2 -c rich_cxx.cc -o rich_cxx.o
build "$CXX" $FF -stdlib=libc++ -O2 -c driver_cxx.cc -o driver_cxx.o
build "$CC" $FF -g -O2 -c rich_objc.m -o rich_objc.o
objs="rich_cxx.o rich_objc.o" defs="-DRICH_CXX -DRICH_OBJC" link=$CXX libs="-stdlib=libc++ -framework Foundation -lobjc"
# platform: clang22's config links -headerpad_max_install_names, which pads a
# dylib by 1024 bytes per dependency; past two pages of that, a 2-page raise would
# widen LC_FUNCTION_STARTS' leading ULEB, which drydock refuses (asserted below).
# The raised fixtures link through an --ld-path that drops that one flag, so
# their pads are small, as ld64 inputs' are.
nopad() {   # nopad DRIVER: an --ld-path for DRIVER's own linker, less that flag
    w=ld-nopad.${1##*/}
    l=$("$1" $FF -### -x c /dev/null -o /dev/null 2>&1 | tail -1 | awk '{ print $1 }' | tr -d '"')
    printf '#!/bin/sh\nfor a; do shift; [ "$a" = -headerpad_max_install_names ] || set -- "$@" "$a"; done\nexec "%s" "$@"\n' "$l" >"$w"
    chmod +x "$w"
    echo "--ld-path=$T/$w"
}
build "$CC" $FF $defs -DLINKED -O2 -c driver.c -o drive.o
build "$CC" $FF $defs -O2 -c driver.c -o load.o

# Two sets of fixtures, each raised by one page and by two and run beside its
# original. lld.0 is linked here by ld64.lld. ld64.0 is what ld64-241 linked,
# once, from these same sources (tests/data/raise_rich_ld64-241; the commit
# that added it records the commands): lld cannot make a resolver, an -init,
# a -segaddr segment or the N_BNSYM stabs, and its segment$start$ misses.
mkdir lld.0 ld64.0
build "$link" $FF $(nopad "$link") -dynamiclib -install_name @rpath/librich.dylib -Wl,-init,_rich_init \
    rich.o $objs $libs -o lld.0/librich.dylib
build "$link" $FF $(nopad "$link") -bundle rich_bundle.o $objs $libs -o lld.0/rich.bundle
build "$CC" $FF $(nopad "$CC") -dynamiclib -install_name @rpath/libgap.dylib gap.o -o lld.0/libgap.dylib
cp "$ROOT"/tests/data/raise_rich_ld64-241/* ld64.0/
for s in lld ld64; do
    build "$link" $FF -Wl,-rpath,@loader_path/. drive.o driver_cxx.o $s.0/librich.dylib $libs -o $s.0/drive
    build "$link" $FF load.o driver_cxx.o $libs -o $s.0/load
done

# ---- the fixtures are what they say ------------------------------------------
# feature NAME WHAT CMD...: whether the built fixture has WHAT, by CMD (otool
# or nm, or the export trie, which neither prints); have_NAME says. A set
# expects the features it names, and one it lacks is a failure.
feature() {
    n=$1 w=$2; shift 2
    if "$@" >/dev/null 2>&1; then
        eval "have_$n=1"; ok "$S: the fixture has $w"
    else
        eval "have_$n=0"; bad "$S: the fixture has $w" "it does not"
    fi
}
has() { eval "[ \"\${have_$1:-0}\" -eq 1 ]"; }
expects() { case " $WANT " in *" $1 "*) return 0 ;; esac; return 1; }

fill=$(printf '%0890d' 0)
# raise_edits PAGES IN: raise.edits raises IN by PAGES pages; 1 takes 900-byte
# LC_RPATHs past the pad, 2 takes one longer than the pad and a page. Each is
# deleted again. raise PAGES IN OUT: IN raised by them at OUT.
raise_edits() {
    info=$("$DMR" info "$2")
    pad=$(printf '%s\n' "$info" | awk '/^header pad: / { print $3; exit }')
    {
        printf '%s\n' "$info" | grep -q ' LC_CODE_SIGNATURE ' && echo 'load-command delete codesig'
        if [ "$1" -eq 1 ]; then
            n=$(( ${pad:-0} / 900 + 2 )) i=0
            while [ "$i" -lt "$n" ]; do echo "rpath append /nonexistent/raise-$i/$fill"; i=$((i + 1)); done
            i=0
            while [ "$i" -lt "$n" ]; do echo "rpath delete /nonexistent/raise-$i/$fill"; i=$((i + 1)); done
        else
            long=/nonexistent/$(printf "%0$(( ${pad:-0} + 4200 ))d" 0)
            echo "rpath append $long"
            echo "rpath delete $long"
        fi
    } >raise.edits
}
raise() {
    raise_edits "$1" "$2"
    rc=0; "$DMR" "$2" "$3" <raise.edits >/dev/null 2>raise.err || rc=$?
    g=$(printf '0x%x' $(( $1 * 4096 )))
    if [ "$rc" -eq 0 ] && grep -q "^$2: grew the header pad by .*; contents raised by $g; new UUID" raise.err &&
       "$DMR" verify "$3" >/dev/null 2>&1; then
        ok "$3: raised by $g, announced and verified"
    else
        bad "$3" "exit $rc: $(grep -v '^  ' raise.err | head -3 | cut -c1-300)"
    fi
}

# The same librich linked as clang22 links it, max-install-names pad and all: its
# 2-page raise would widen LC_FUNCTION_STARTS' leading ULEB, which needs a
# __LINKEDIT resize drydock does not do. It refuses loudly and writes nothing.
build "$link" $FF -dynamiclib -install_name @rpath/librich.dylib -Wl,-init,_rich_init \
    rich.o $objs $libs -o padded.dylib
cp padded.dylib padded.orig
raise_edits 2 padded.dylib
rc=0; "$DMR" padded.dylib padded.raised <raise.edits >/dev/null 2>raise.err || rc=$?
[ "$rc" -ne 0 ] && [ ! -e padded.raised ] && cmp -s padded.dylib padded.orig &&
    grep -q 'would widen the LC_FUNCTION_STARTS leading delta .* crosses a ULEB byte boundary.*__LINKEDIT resize is not implemented' raise.err &&
    ok "padded: a 2-page raise of clang22's padded librich is refused (exit $rc), saying why, and nothing is written" ||
    bad "padded: refusal" "exit $rc, output $( [ -e padded.raised ] && echo written || echo absent): $(grep -v '^  ' raise.err | head -3 | cut -c1-300)"

# platform: a host that kills a modified signed binary kills a raised copy the
# same way; the probe below perturbs an unraised copy of the driver to tell.
enforced=0
if can_exec x86_64 && "$DMR" info lld.0/drive | grep -q ' LC_CODE_SIGNATURE '; then
    end=$("$DMR" info lld.0/drive | sed -n 's/^header pad: .*LC end=\([0-9]*\),.*/\1/p')
    cp lld.0/drive probe
    printf '\377' | dd of=probe bs=1 seek="${end:-0}" conv=notrunc 2>/dev/null
    (cd lld.0 && ../probe) >/dev/null 2>&1
    [ $? -eq 137 ] && enforced=1
fi

run() {   # run DIR NAME CMD...: CMD in DIR; its output and exit status in DIR/out.NAME
    d=$1 n=$2; shift 2
    rc=0; (cd "$d" && "$@") >"$d/out.$n" 2>&1 || rc=$?
    echo "exit $rc" >>"$d/out.$n"
}

# suite SET FEATURE...: raise SET.0's fixtures, hold their stabs, run them. gaprun
# also runs libgap.dylib; the features are the ones the set's linker must have made.
suite() {
S=$1; shift; WANT="$*"
for n in resolver absolute tlv init segaddr segstart stab36 stab46 stab38 stab100 stab102; do eval "have_$n=0"; done
broken_drive=0 broken_dylib=0 broken_bundle=0 broken_gap=0
gap=libgap.dylib
d0=$S.0
"$DMR" exports $d0/librich.dylib >exports.tsv
"$OTOOL" -l $d0/librich.dylib >rich.lcs 2>&1
"$NM" -m $d0/librich.dylib >rich.nm 2>&1
expects resolver && feature resolver "a stub-and-resolver export (.symbol_resolver) in librich.dylib's export trie" \
    awk -F'\t' '$3 == "stub-resolver" { f = 1 } END { exit !f }' exports.tsv
expects absolute && feature absolute "an absolute symbol, _rich_abs" grep -q '(absolute) external _rich_abs$' rich.nm
expects tlv && feature tlv "thread-local variables (__thread_vars)" grep -q 'sectname __thread_vars$' rich.lcs
expects init && feature init "an -init initializer (LC_ROUTINES_64)" grep -q 'cmd LC_ROUTINES_64$' rich.lcs
"$OTOOL" -l $d0/libgap.dylib >gap.lcs 2>&1
expects segaddr && feature segaddr "__GAP placed past a gap in vm, at 0x100000 (-segaddr)" sh -c \
    "awk '/segname __GAP\$/ { g = 1 } g && /vmaddr/ { print \$2; exit }' gap.lcs | grep -q '^0x0*100000\$'"
expects segstart && feature segstart "a pointer to segment\$start\$__GAP that names __GAP's first variable" sh -c \
    "[ \"\$(./stabs $d0/libgap.dylib _gap_ptrs | cut -d' ' -f1)\" = \"\$(./stabs $d0/libgap.dylib _gap_first | cut -d' ' -f2)\" ]"
./stabs $d0/librich.dylib >stabs.$S.0
for ty in 36 46 38 100 102; do   # N_FUN N_BNSYM N_STSYM N_SO N_OSO
    expects "stab$ty" && feature "stab$ty" "a stab of type $ty in librich.dylib" awk -v t="$ty" '$1 == t { f = 1 } END { exit !f }' stabs.$S.0
done

# ---- raise ---------------------------------------------------------------
for p in 1 2; do
    mkdir "$S.$p"
    cp $d0/drive $d0/load "$S.$p/"
    for f in librich.dylib rich.bundle $gap; do raise "$p" "$d0/$f" "$S.$p/$f"; done
done

# ---- the stabs -----------------------------------------------------------
for p in 1 2; do
    ./stabs "$S.$p/librich.dylib" >"stabs.$S.$p"
    paste stabs.$S.0 "stabs.$S.$p" | awk -F'\t' -v G=$(( p * 4096 )) '
        { t = $1 + 0; named = $4 != "="
          moves = t == 46 || t == 38 || t == 40 || t == 68 || (t == 36 && named) ||
                  ((t == 100 || t == 132) && $2 != 0)
          if (NF != 8 || $1 != $5 || $2 != $6 || $4 != $8) { print "a stab changed its type or section: " $0; bad++; next }
          want = moves && $3 != 0 ? $3 + G : $3
          if ($7 != want) { print "stab " NR " (" $0 ") should hold " want; bad++ }
          if (moves && $3 != 0) moved++; else if ($3 != 0) kept++ }
        END { printf "%d moved, %d kept\n", moved, kept; exit bad > 0 || moved == 0 || kept == 0 }' \
        >"stabs.cmp.$S.$p" 2>&1
    rc=$?
    n0=$(wc -l <stabs.$S.0) n1=$(wc -l <"stabs.$S.$p")
    [ "$rc" -eq 0 ] && [ "$n0" -eq "$n1" ] &&
        ok "$S.$p: the stabs that hold an address moved by $(( p * 4096 )), the rest stayed ($(tail -1 "stabs.cmp.$S.$p"))" ||
        bad "$S.$p: stabs" "$n0 -> $n1 stabs; $(head -5 "stabs.cmp.$S.$p" | tr '\n' ' ')"
done

# ---- run -----------------------------------------------------------------
if [ "$enforced" -eq 1 ]; then
    skip "$S run" "this host SIGKILLs a signed binary modified after signing, so the raised copies are not run here; they are on 10.9"
elif ! gate_row x86_64 "$S run: the raised copies do what the original does"; then
    :
else
    for d in $S.0 $S.1 $S.2; do
        run "$d" drive ./drive
        run "$d" dylib ./load ./librich.dylib
        run "$d" bundle ./load ./rich.bundle
        expects gaprun && run "$d" gap ./load ./libgap.dylib gap_report
    done
    for n in drive dylib bundle $(expects gaprun && echo gap); do
        # A feature the fixture lacks says so in the original's output too.
        rx='^$'
        has resolver || rx="$rx|^resolver: "
        grep -v -E "$rx" "$S.0/out.$n" >"$S.0/own.$n"
        if ! grep -q '^exit 0$' "$S.0/own.$n" ||
           grep -q -E 'WRONG|MISSES|ANOTHER|NOT |FALLS SHORT|dlopen:|nothing thrown' "$S.0/own.$n"; then
            bad "$S $n: the original passes its own checks" "$(tr '\n' ' ' <"$S.0/out.$n")"
            eval "broken_$n=1"
            continue
        fi
        ok "$S $n: the original passes its own checks ($(wc -l <"$S.0/out.$n" | tr -d ' ') lines)"
        for p in 1 2; do
            cmp -s "$S.0/out.$n" "$S.$p/out.$n" && ok "$S $n: raised by $p page(s), it does what the original does" ||
                bad "$S $n: raised by $p page(s)" "$(diff "$S.0/out.$n" "$S.$p/out.$n" | head -6 | tr '\n' ' ')"
        done
    done
    [ "$broken_drive" -eq 1 ] ||
    { DYLD_PRINT_LIBRARIES=1 $S.1/drive 2>&1 >/dev/null | grep -q "$S.1/.*librich\.dylib" &&
        ok "$S drive: ... and the library it loaded is the raised copy beside it" ||
        bad "$S drive" "dyld did not say it loaded $S.1's librich.dylib"; }
    for n in drive dylib; do
        [ "$(eval "echo \${broken_$n:-0}")" -eq 0 ] || continue
        grep -q '^constructor 1, -init [01], zero-fill 2$' "$S.0/out.$n" &&
            ok "$S $n: the original's constructor ran" || bad "$S $n" "the original's constructor did not run"
        ! has init || { grep -q '^constructor 1, -init 1,' "$S.0/out.$n" &&
            ok "$S $n: the original's -init ran" || bad "$S $n" "the original's -init (LC_ROUTINES_64) did not run"; }
        ! has resolver || { grep -q '^resolver: resolved to its implementation$' "$S.0/out.$n" &&
            ok "$S $n: the original's resolver resolved" || bad "$S $n" "the original's resolver did not resolve"; }
        ! has tlv || { grep -q '^thread-local: this thread 6, the other 15$' "$S.0/out.$n" &&
            ok "$S $n: the original's thread-local variables are per thread" ||
            bad "$S $n" "the original's thread-local variables did not work"; }
    done
    if [ "$broken_drive" -eq 0 ]; then
        grep -q "^c++: caught across: " $S.0/out.drive || bad "c++" "the driver did not catch what the dylib threw"
        grep -q "^objc: +load 1" $S.0/out.drive || bad "objc" "+load did not run"
    fi
fi
}

suite lld absolute tlv gaprun stab36 stab38 stab100 stab102
suite ld64 resolver absolute tlv init segaddr segstart gaprun stab36 stab46 stab38 stab100 stab102

[ "$fail" -eq 0 ] || { echo "raise_rich_test: $fail failure(s)"; exit 1; }
echo "raise_rich_test: all passed"
