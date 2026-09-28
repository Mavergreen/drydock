#!/bin/sh
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
# Fixtures are x86_64 with a 10.9 floor, which runs on 10.9 and under Rosetta.
# Where C++ or Objective-C cannot be built, those parts are skipped, saying so.
set -u

BIN="${1:?usage: raise_rich_test.sh <bindir>}"
BIN=$(cd "$BIN" && pwd)
DMR="$BIN/drydock-macho-rewrite"
[ -x "$DMR" ] || { echo "raise_rich_test: $DMR not found or not executable" >&2; exit 1; }
CC="${CC:-clang}"
CXX="${CXX:-clang++}"
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
    printf("gap: start %s, end %s, %ld bytes, values %d %d %d\n",
           gap_ptrs[0] == (char *)gap_first ? "names its first variable" : "MISSES its first variable",
           gap_ptrs[1] > (char *)&gap_last ? "lies past its last" : "FALLS SHORT of its last",
           (long)(gap_ptrs[1] - gap_ptrs[0]), gap_first[0], gap_first[3], gap_last);
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
cat >stabs.c <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
int main(int argc, char **argv) {
    FILE *f = argc == 2 ? fopen(argv[1], "rb") : NULL;
    if (!f) return 2;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    uint8_t *b = malloc((size_t)n);
    fseek(f, 0, SEEK_SET);
    if (!b || fread(b, 1, (size_t)n, f) != (size_t)n) return 2;
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
"$CC" -O2 -o stabs stabs.c || { echo "raise_rich_test: could not build the stab reader" >&2; exit 1; }

# ---- build ------------------------------------------------------------------
build() { "$@" >build.log 2>&1 || { echo "raise_rich_test: $*" >&2; cat build.log >&2; exit 1; }; }
build "$CC" $FF -g -O2 -c rich.c -o rich.o
build "$CC" $FF -g -O2 -DRICH_BUNDLE -c rich.c -o rich_bundle.o
build "$CC" $FF -g -O2 -c gap.c -o gap.o
objs= libs= defs= link=$CC
if "$CXX" $FF -stdlib=libc++ -g -O2 -c rich_cxx.cc -o rich_cxx.o >cxx.log 2>&1 &&
   "$CXX" $FF -stdlib=libc++ -O2 -c driver_cxx.cc -o driver_cxx.o >>cxx.log 2>&1; then
    objs="rich_cxx.o" defs="-DRICH_CXX" link=$CXX libs="-stdlib=libc++"
else
    skip "c++" "$CXX cannot build x86_64 C++ for 10.9 here, so the exceptions and vtables go untested: $(head -3 cxx.log | tr '\n' ' ')"
fi
if "$CC" $FF -g -O2 -c rich_objc.m -o rich_objc.o >objc.log 2>&1; then
    objs="$objs rich_objc.o" defs="$defs -DRICH_OBJC" libs="$libs -framework Foundation -lobjc"
else
    skip "objc" "$CC cannot build x86_64 Objective-C for 10.9 here, so the class, category, +load and literals go untested: $(head -3 objc.log | tr '\n' ' ')"
fi
mkdir g0
build "$link" $FF -dynamiclib -install_name @rpath/librich.dylib -Wl,-init,_rich_init \
    rich.o $objs $libs -o g0/librich.dylib
build "$link" $FF -bundle rich_bundle.o $objs $libs -o g0/rich.bundle
build "$CC" $FF -dynamiclib -install_name @rpath/libgap.dylib -Wl,-segaddr,__GAP,0x100000 gap.o -o g0/libgap.dylib
cx=
[ -z "$defs" ] || [ "$link" = "$CC" ] || cx=driver_cxx.o
build "$CC" $FF $defs -DLINKED -O2 -c driver.c -o drive.o
build "$CC" $FF $defs -O2 -c driver.c -o load.o
build "$link" $FF -Wl,-rpath,@loader_path/. drive.o $cx g0/librich.dylib $libs -o g0/drive
build "$link" $FF load.o $cx $libs -o g0/load

# ---- the fixtures are what they say ------------------------------------------
"$DMR" exports g0/librich.dylib >exports.tsv
for k in stub-resolver absolute thread-local; do
    awk -F'\t' -v k="$k" '$3 == k { f = 1 } END { exit !f }' exports.tsv &&
        ok "librich.dylib exports a $k symbol" || bad "fixture" "librich.dylib has no $k export"
done
"$DMR" info g0/librich.dylib | grep -q '^LC\[[0-9]*\] 0x0000001a ' &&
    ok "librich.dylib has an LC_ROUTINES_64" || bad "fixture" "librich.dylib has no LC_ROUTINES_64"
"$DMR" info g0/libgap.dylib | awk '/segname=__GAP / { print; exit }' | grep -q 'vmaddr=0x100000 ' &&
    ok "libgap.dylib's __GAP lies past a gap in vm" || bad "fixture" "libgap.dylib has no __GAP at 0x100000"
./stabs g0/librich.dylib >stabs.g0
for ty in 36 46 38 100 102; do   # N_FUN N_BNSYM N_STSYM N_SO N_OSO
    awk -v t="$ty" '$1 == t { f = 1 } END { exit !f }' stabs.g0 ||
        bad "fixture" "librich.dylib has no stab of type $ty"
done

# ---- raise -------------------------------------------------------------------
fill=$(printf '%0890d' 0)
# raise PAGES IN OUT: IN raised by PAGES pages at OUT; 1 takes 900-byte
# LC_RPATHs past the pad, 2 takes one longer than the pad and a page. Each is
# deleted again.
raise() {
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
    rc=0; "$DMR" "$2" "$3" <raise.edits >/dev/null 2>raise.err || rc=$?
    g=$(printf '0x%x' $(( $1 * 4096 )))
    if [ "$rc" -eq 0 ] && grep -q "^$2: grew the header pad by .*; contents raised by $g; new UUID" raise.err &&
       "$DMR" verify "$3" >/dev/null 2>&1; then
        ok "$3: raised by $g, announced and verified"
    else
        bad "$3" "exit $rc: $(grep -v '^  ' raise.err | head -3 | cut -c1-300)"
    fi
}
for p in 1 2; do
    mkdir "g$p"
    cp g0/drive g0/load "g$p/"
    for f in librich.dylib rich.bundle libgap.dylib; do raise "$p" "g0/$f" "g$p/$f"; done
done

# ---- the stabs ---------------------------------------------------------------
for p in 1 2; do
    ./stabs "g$p/librich.dylib" >"stabs.g$p"
    paste stabs.g0 "stabs.g$p" | awk -F'\t' -v G=$(( p * 4096 )) '
        { t = $1 + 0; named = $4 != "="
          moves = t == 46 || t == 38 || t == 40 || t == 68 || (t == 36 && named) ||
                  ((t == 100 || t == 132) && $2 != 0)
          if (NF != 8 || $1 != $5 || $2 != $6 || $4 != $8) { print "a stab changed its type or section: " $0; bad++; next }
          want = moves && $3 != 0 ? $3 + G : $3
          if ($7 != want) { print "stab " NR " (" $0 ") should hold " want; bad++ }
          if (moves && $3 != 0) moved++; else if ($3 != 0) kept++ }
        END { printf "%d moved, %d kept\n", moved, kept; exit bad > 0 || moved == 0 || kept == 0 }' \
        >"stabs.cmp$p" 2>&1
    rc=$?
    n0=$(wc -l <stabs.g0) n1=$(wc -l <"stabs.g$p")
    [ "$rc" -eq 0 ] && [ "$n0" -eq "$n1" ] &&
        ok "g$p: the stabs that hold an address moved by $(( p * 4096 )), the rest stayed ($(tail -1 "stabs.cmp$p"))" ||
        bad "g$p: stabs" "$n0 -> $n1 stabs; $(head -5 "stabs.cmp$p" | tr '\n' ' ')"
done

# ---- run ---------------------------------------------------------------------
# platform: a host that kills a modified signed binary kills a raised copy the
# same way; the probe below perturbs an unraised copy of the driver to tell.
enforced=0
if "$DMR" info g0/drive | grep -q ' LC_CODE_SIGNATURE '; then
    end=$("$DMR" info g0/drive | sed -n 's/^header pad: .*LC end=\([0-9]*\),.*/\1/p')
    cp g0/drive probe
    printf '\377' | dd of=probe bs=1 seek="${end:-0}" conv=notrunc 2>/dev/null
    (cd g0 && ../probe) >/dev/null 2>&1
    [ $? -eq 137 ] && enforced=1
fi
if [ "$enforced" -eq 1 ]; then
    skip "run" "this host SIGKILLs a signed binary modified after signing, so the raised copies are not run here; they are on 10.9"
else
    run() {   # run DIR NAME CMD...: CMD in DIR; its output and exit status in DIR/out.NAME
        d=$1 n=$2; shift 2
        rc=0; (cd "$d" && "$@") >"$d/out.$n" 2>&1 || rc=$?
        echo "exit $rc" >>"$d/out.$n"
    }
    for d in g0 g1 g2; do
        run "$d" drive ./drive
        run "$d" dylib ./load ./librich.dylib
        run "$d" bundle ./load ./rich.bundle
        run "$d" gap ./load ./libgap.dylib gap_report
    done
    for n in drive dylib bundle gap; do
        if grep -q -E 'WRONG|MISSES|ANOTHER|NOT |FALLS SHORT|dlopen:|nothing thrown' "g0/out.$n" ||
           ! grep -q '^exit 0$' "g0/out.$n"; then
            bad "$n" "the original does not pass its own checks: $(tr '\n' ' ' <"g0/out.$n")"
        else
            ok "$n: the original passes its own checks ($(wc -l <"g0/out.$n" | tr -d ' ') lines)"
        fi
        for p in 1 2; do
            cmp -s "g0/out.$n" "g$p/out.$n" && ok "$n: raised by $p page(s), it does what the original does" ||
                bad "$n: raised by $p page(s)" "$(diff "g0/out.$n" "g$p/out.$n" | head -6 | tr '\n' ' ')"
        done
    done
    DYLD_PRINT_LIBRARIES=1 g1/drive 2>&1 >/dev/null | grep -q "g1/.*librich\.dylib" &&
        ok "drive: ... and the library it loaded is the raised copy beside it" ||
        bad "drive" "dyld did not say it loaded g1's librich.dylib"
    for n in drive dylib; do
        grep -q '^constructor 1, -init 1, zero-fill 2$' "g0/out.$n" &&
            grep -q '^resolver: resolved to its implementation$' "g0/out.$n" &&
            grep -q '^thread-local: this thread 6, the other 15$' "g0/out.$n" ||
            bad "$n" "the original's constructor, -init, resolver or thread-local variable did not work"
    done
    grep -q "^c++: caught across: " g0/out.drive || [ -z "$cx" ] ||
        bad "c++" "the driver did not catch what the dylib threw"
    grep -q "^objc: +load 1" g0/out.drive || ! printf '%s' "$defs" | grep -q RICH_OBJC ||
        bad "objc" "+load did not run"
fi

[ "$fail" -eq 0 ] || { echo "raise_rich_test: $fail failure(s)"; exit 1; }
echo "raise_rich_test: all passed"
