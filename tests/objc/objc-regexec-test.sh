#!/bin/sh
# platform: macOS-only -- links x86_64 table providers against the pinned 10.9 SDK with clang22 and lld, then reads them as bytes
# spec: src/objc/regexec.c header -- the registration executor derives a provider's class_addMethod calls from its
#       code: every path, each add's class, selector, implementation and types, the lookups found on each path, and
#       a named refusal for every limit. Nothing built here is executed.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
# spec: build/msc.sh -- SHIPYARD_SCRIPTS, where shipyard's fetchers are (CTest passes it; a standalone run finds it).
. "$ROOT/build/msc.sh"
. "$ROOT/tests/lib/toolchain.sh"
FX="$HERE/fixtures"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-regexec-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; [ ! -f "$T/out" ] || tail -20 "$T/out" >&2; exit 1; }
pass() { echo "PASS: regexec: $*"; }

[ -x "${DRYDOCK_OBJC_REGEXEC_DRIVER:-}" ] || fail "DRYDOCK_OBJC_REGEXEC_DRIVER names no built objc-regexec-driver"
SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" --arch x86_64)
# platform: env -i keeps CPATH and SDKROOT from steering the fixtures away from the pinned SDK.
fxcc() { env -i PATH=/usr/bin:/bin "$CC" -arch x86_64 -isysroot "$SDK" -mmacosx-version-min=10.9 "$@"; }
printf 'int main(void) { return 0; }\n' >"$T/main.c"
fxcc -O1 -c "$T/main.c" -o "$T/main.o"
ENTRY=_fixture_tabbing_start
# build NAME OPT [-DVARIANT...]: the table provider, ARC as Recaulk's tabbing units, linked with a trivial main.
build() {
  n=$1 o=$2; shift 2
  fxcc "$o" -fobjc-arc -fno-modules -fno-autolink -fPIC -Wall -Wextra -Werror "$@" -c "$FX/table-provider.m" -o "$T/$n.o" ||
    fail "$n: compiling table-provider.m $o $*"
  fxcc "$T/main.o" "$T/$n.o" -lobjc -o "$T/$n" || fail "$n: linking"
}
run() { rc=0; "$DRYDOCK_OBJC_REGEXEC_DRIVER" "$T/$1" "${2:-$ENTRY}" >"$T/out" 2>"$T/err" || rc=$?; }
explored() { [ "$rc" = 0 ] || fail "$1: driver exit $rc: $(cat "$T/out" "$T/err")"; }
refused() {
  [ "$rc" = 1 ] || fail "$1: driver exit $rc, want 1 (refused)"
  grep "^refused $2: " "$T/out" >/dev/null || fail "$1: not refused $2"
}
# The all-miss, all-succeed paths: found 0, null 0, every add ok. Prints each such path's add lines.
all_miss() {
  awk '/^path /{ok=($4 == 0 && $6 == 0); n++; next} /^  add /{ if (ok) { if ($NF != 1) bad[n] = 1; l[n] = l[n] $0 "\n"; g[n] = 1 } }
       END { for (i in g) if (!bad[i]) { c++; out = l[i] } printf "%d\n%s", c, out }' "$T/out"
}
SIX='  add NSWindow|0 tabbingIdentifier _FixtureTab_tabbingIdentifier @16@0:8 1
  add NSWindow|0 setTabbingIdentifier: _FixtureTab_setTabbingIdentifier v24@0:8@16 1
  add NSWindow|0 tabbingMode _FixtureTab_tabbingMode q16@0:8 1
  add NSWindow|0 setTabbingMode: _FixtureTab_setTabbingMode v24@0:8q16 1
  add NSWindow|1 allowsAutomaticWindowTabbing _FixtureTab_allowsAutomaticWindowTabbing c16@0:8 1
  add NSWindow|1 setAllowsAutomaticWindowTabbing: _FixtureTab_setAllowsAutomaticWindowTabbing v20@0:8c16 1'
six() {   # six NAME: exactly one all-miss path, and its adds are the six rows in table order
  got=$(all_miss)
  [ "$got" = "1
$SIX" ] || fail "$1: want one all-miss path with the six adds, got:
$got"
  awk '/^path /{ if ($4 != 0) { print; exit 1 } }' "$T/out" >/dev/null || fail "$1: a path with a found lookup adds"
}

for o in -O0 -O1 -Os -O2 -O3 -Oz; do
  build "plain$o" "$o"; run "plain$o"; explored "plain$o"; six "plain$o"
done
pass '-O0 -O1 -Os -O2 -O3 -Oz each give 6 adds on exactly one all-miss path'
for o in -O0 -O1 -Os -O2 -O3 -Oz; do build "reorder$o" "$o" -DREORDER; run "reorder$o"; explored "reorder$o"; six "reorder$o"; done
pass 'REORDER (fields reordered) gives the same 6 adds at every opt level'

run plain-Os; explored plain-Os
# 2^6 guard outcomes; the all-miss one reaches the add loop, whose 6 adds each fork success/failure; one NULL class.
[ "$(sed -n 's/^paths //p' "$T/out")" = 71 ] || fail "plain: $(head -1 "$T/out"), want paths 71"
nfail=$(awk '/^path /{p=$2} /^  add / && $NF == 0 {f[p]=1} END{for (i in f) c++; print c+0}' "$T/out")
[ "$nfail" = 6 ] || fail "plain: $nfail completed paths with a failed add, want 6"
pass 'fail-forks of class_addMethod complete within budget (6 paths, each ending at its failed add)'
[ "$(sed -n 's/^null-paths //p' "$T/out")" = 1 ] || fail "plain: $(sed -n 2p "$T/out"), want null-paths 1"
awk '/^path /{ if ($6 != 0) exit 1 }' "$T/out" || fail 'plain: a NULL-class path adds'
pass 'objc_getClass forks: one path where it returns NULL, and nothing is added there'
[ "$(sed -n 's/^sites //p' "$T/out" | wc -w | tr -d ' ')" = 1 ] || fail "plain: $(grep '^sites' "$T/out"), want one mutator site"
grep '^reads .*0x' "$T/out" >/dev/null || fail 'plain: no constant reads recorded'
pass 'the one class_addMethod site and the table reads are recorded'
root=$("$NM" "$T/plain-Os" | awk '$3 == "___fixture_objc_activate_table" {print "0x" $1}' | sed 's/0x0*/0x/')
[ -n "$root" ] && grep "^called .*$root\( \|\$\)" "$T/out" >/dev/null || fail "plain: $(grep '^called' "$T/out"), want the root $root"
pass "the constructor's call of the root is recorded (called)"
in_explored() {   # in_explored IMAGE SYMBOL: 0 when SYMBOL's address starts one of the driver's explored functions
  a=$("$NM" "$T/$1" | awk -v s="$2" '$3 == s {print "0x" $1}' | sed 's/0x0*/0x/')
  [ -n "$a" ] || fail "$1: no symbol $2"
  grep "^explored .*$a-" "$T/out" >/dev/null
}
for f in _fixture_tabbing_start ___fixture_objc_activate_table _FixtureTabRegisterTable; do
  in_explored plain-Os "$f" || fail "plain: $f is not an explored function: $(grep '^explored' "$T/out")"
done
for f in _fixture_tabbing_activation_state _FixtureTab_tabbingMode; do
  in_explored plain-Os "$f" && fail "plain: $f, which no path executes, is an explored function"
done
pass 'explored: the functions a path executed in, and none it did not'
escaped_has() {   # escaped_has IMAGE SYMBOL: 0 when SYMBOL's address is among the driver's escaped addresses
  a=$("$NM" "$T/$1" | awk -v s="$2" '$3 == s {print "0x" $1}' | sed 's/0x0*/0x/')
  [ -n "$a" ] || fail "$1: no symbol $2"
  grep "^escaped .*$a@" "$T/out" >/dev/null
}
for f in _state _FixtureTabMethods; do escaped_has plain-Os "$f" && fail "plain: $f escapes: $(grep '^escaped' "$T/out")"; done
build bump -Os -DBUMP; run bump; explored BUMP
escaped_has bump _state || fail "BUMP: the state's address, handed to a summarised helper, is not escaped: $(grep '^escaped' "$T/out")"
build passtab -Os -DPASS_TABLE; run passtab; explored PASS_TABLE
escaped_has passtab _FixtureTabMethods || fail "PASS_TABLE: the table's address is not escaped: $(grep '^escaped' "$T/out")"
pass 'escaped: an image address handed to a call not followed, and none on the plain provider'

build short -Os -DSHORT; run short; explored short
[ "$(all_miss | head -1)" = 1 ] && [ "$(all_miss | grep -c '^  add ')" = 5 ] || fail "SHORT: want one all-miss path with 5 adds, got $(all_miss)"
pass 'SHORT gives 5 adds'
for v in NOGUARD NOPARTIAL; do
  build "$v" -Os "-D$v"; run "$v"; explored "$v"
  awk '/^path /{ if ($4 > 0) f = 1 } END { exit !f }' "$T/out" || fail "$v: no path with a found lookup adds"
  grep '^  found NSWindow|[01] ' "$T/out" >/dev/null || fail "$v: the found lookups are not named"
done
pass 'NOGUARD and NOPARTIAL add on paths with found lookups, which are named'
for v in EXTRA_ROW WRONG_IMP WRONG_TYPES KIND_SWAP; do build "$v" -Os "-D$v"; run "$v"; explored "$v"; done
run EXTRA_ROW; [ "$(all_miss | grep -c '^  add ')" = 7 ] || fail 'EXTRA_ROW: want 7 adds'
run WRONG_IMP; all_miss | grep '^  add NSWindow|0 tabbingMode _FixtureTab_tabbedWindows q16@0:8 1$' >/dev/null || fail 'WRONG_IMP: the add does not name the wrong imp'
run WRONG_TYPES; all_miss | grep '^  add NSWindow|0 tabbingMode _FixtureTab_tabbingMode i16@0:8 1$' >/dev/null || fail 'WRONG_TYPES: the add does not carry the wrong types'
run KIND_SWAP; all_miss | grep '^  add NSWindow|0 setAllowsAutomaticWindowTabbing: ' >/dev/null || fail 'KIND_SWAP: the add is not on the class'
pass 'EXTRA_ROW, WRONG_IMP, WRONG_TYPES and KIND_SWAP derive the adds as compiled'

sites() { sed -n 's/^sites //p' "$T/out" | wc -w | tr -d ' '; }
build via -Os -DVIA_MSGSEND; run via; explored VIA_MSGSEND; six VIA_MSGSEND
[ "$(sites)" = 1 ] || fail "VIA_MSGSEND: $(grep '^sites' "$T/out"), want only the explored class_addMethod site"
pass 'VIA_MSGSEND: an add reached only through objc_msgSend is neither followed nor a recorded site'
build setimp -Os -DSETIMP; run setimp; explored SETIMP
[ "$(sites)" = 2 ] || fail "SETIMP: $(grep '^sites' "$T/out"), want the class_addMethod and method_setImplementation sites"
pass 'SETIMP: method_setImplementation on an explored path is a recorded mutator site'

build indirect -Os -DINDIRECT; run indirect; refused INDIRECT indirect-call
pass 'INDIRECT refuses indirect-call'
build many -Os -DMANY; run many; refused MANY path-budget
pass 'MANY refuses path-budget'
build rtwrite -Os -DRUNTIME_WRITE; run rtwrite; refused RUNTIME_WRITE image-store
pass 'RUNTIME_WRITE refuses image-store'
build escape -O1 -DFRAME_ESCAPE; run escape; explored FRAME_ESCAPE
all_miss | grep '^  add NSWindow|' >/dev/null && fail 'FRAME_ESCAPE: a class held in a frame slot whose address escaped to an import is still named'
all_miss | grep '^  add ?|0 tabbingIdentifier ' >/dev/null || fail 'FRAME_ESCAPE: want the class unnamed'
pass 'a frame address passed to an import invalidates the frame'

fxcc -c "$FX/regexec-avx512.S" -o "$T/avx.o" || fail 'assembling regexec-avx512.S'
fxcc "$T/main.o" "$T/avx.o" -o "$T/avx" || fail 'linking avx'
run avx _avx512_entry; refused avx512 unsupported-instruction
here=$("$NM" "$T/avx" | awk '$3 == "_avx512_here" {print $1}' | sed 's/^0*//')
grep "^refused unsupported-instruction: .*0x$here" "$T/out" >/dev/null || fail "avx512: the refusal does not name 0x$here: $(cat "$T/out")"
pass 'an unsupported instruction refuses naming its address'

fxcc -c "$FX/regexec-limits.S" -o "$T/lim.o" || fail 'assembling regexec-limits.S'
fxcc "$T/main.o" "$T/lim.o" -lobjc -o "$T/lim" || fail 'linking lim'
run lim _lim_unverified; refused lim_unverified unverified-pointer
run lim _lim_store; refused lim_store unknown-store
run lim _lim_foreign; refused lim_foreign foreign-call
run lim _lim_depth; refused lim_depth depth-budget
run lim _lim_loop; refused lim_loop insn-budget
run lim _lim_ret; refused lim_ret indirect-call
run lim _lim_unkload; explored lim_unkload
[ "$(sed -n 's/^paths //p' "$T/out")" = 2 ] || fail "lim_unkload: $(head -1 "$T/out"), want paths 2: a load at an unknown index is unknown"
pass 'an unrebased pointer, an unknown store, a foreign call, the depth and instruction budgets and a forged return each refuse by name, and a load at an unknown index is unknown'

fxcc -c "$FX/regexec-probe.S" -o "$T/probe.o" || fail 'assembling regexec-probe.S'
fxcc "$T/main.o" "$T/probe.o" -lobjc -o "$T/probe" || fail 'linking probe'
run probe _p_xor; explored p_xor
grep '^path .* null 0 ' "$T/out" >/dev/null && grep '^  add NSWindow|0 ' "$T/out" >/dev/null ||
  fail 'p_xor: xor of a class with itself is not zero: the non-NULL path does not reach its add'
pass 'xor of a symbol with itself is zero'
run probe _p_storeread; explored p_storeread
[ "$(sed -n 's/^paths //p' "$T/out")" = 1 ] && grep '^  add ' "$T/out" >/dev/null ||
  fail "p_storeread: want one path, reaching the add (the stored 5 reads back, not the initial 0)"
grep '^stores 0x[0-9a-f]*+4@' "$T/out" >/dev/null || fail 'p_storeread: the store is not recorded'
pass 'a value stored into image data reads back as stored, and the store is recorded'
run probe _p_foreign; refused p_foreign foreign-call
run probe _p_indirect; refused p_indirect indirect-call
pass 'a callee reaching class_addMethod through foreign code or a computed jump is followed, and refuses'
run probe _p_hoist; explored p_hoist
grep '^  add ' "$T/out" >/dev/null || fail 'p_hoist: the add after a call through a hoisted objc_msgSend is not reached'
pass 'a call through an import address loaded from its GOT slot is that import'
run probe _q_addhoist; explored q_addhoist
[ "$(sites)" = 1 ] && grep '^  add ' "$T/out" >/dev/null || fail 'q_addhoist: class_addMethod called through r12 is not an add with its site'
run probe _q_viareg_follow; explored q_viareg_follow
[ "$(sites)" = 1 ] || fail 'q_viareg_follow: a callee calling class_addMethod only through a hoisted GOT load is not followed'
run probe _q_spill; explored q_spill
grep '^  add ' "$T/out" >/dev/null || fail 'q_spill: an import address spilled and reloaded whole is no longer the import'
pass 'class_addMethod through a hoisted or spilled GOT load is an add at its site, and its caller is followed'
run probe _p_selreg; explored p_selreg
one=$("$NM" "$T/probe" | awk '$3 == "_p_selreg_one" {print $1}' | sed 's/^0*//')
sel=$(sed -n 's/^selreg //p' "$T/out")
[ "$(echo $sel | wc -w | tr -d ' ')" = 2 ] || fail "p_selreg: $sel, want two sel_registerName sites"
echo " $sel " | grep " 0x$one:0 " >/dev/null || fail "p_selreg: $sel, want the shared site 0x$one not all literal"
echo "$sel" | tr ' ' '\n' | grep -v "^0x$one:" | grep ':1$' >/dev/null || fail "p_selreg: $sel, want the other site all literal"
run plain-Os; explored plain-Os
[ "$(sed -n 's/^selreg //p' "$T/out" | tr ' ' '\n' | grep -c ':1$')" -ge 1 ] && ! grep '^selreg .*:0' "$T/out" >/dev/null ||
  fail "plain: $(grep '^selreg' "$T/out"), want every sel_registerName site all literal"
pass 'each sel_registerName site records whether every arrival was a literal from the image (selreg)'
for q in _q_arith _q_partial _q_halfspill; do run probe $q; refused $q indirect-call; done
pass 'an import address changed, read in part, or reloaded in part is not that import: indirect-call'
fxcc -c "$FX/regexec-weak.S" -o "$T/weak.o" || fail 'assembling regexec-weak.S'
fxcc "$T/main.o" "$T/weak.o" -lobjc -o "$T/weak" || fail 'linking weak'
run weak _q_weak; explored q_weak
[ "$(sed -n 's/^paths //p' "$T/out")" = 2 ] && [ "$(grep -c '^path ' "$T/out")" = 1 ] ||
  fail "q_weak: want two paths, the add on one: $(cat "$T/out")"
pass 'a weak import tested for NULL is explored both ways'
run probe _p_cbw; explored p_cbw
grep '^  add ' "$T/out" >/dev/null || fail 'p_cbw: cbw did not sign-extend al'
pass 'cbw sign-extends al'
run probe _p_uforks; explored p_uforks
awk '/^path / && $10 >= 1 {f = 1} END {exit !f}' "$T/out" || fail 'p_uforks: the path past a guard on objc_msgSend does not count its unknown fork'
pass 'a path decided by forking on unknown flags says so (uforks)'
run probe _p_trap; explored p_trap
grep '^path .* trapped 1$' "$T/out" >/dev/null || fail 'p_trap: the path ending at ud2 is not marked trapped'
pass 'a path ending at a trap is marked trapped'
run probe _p_clobber; explored p_clobber
grep '^  add ?|0 ' "$T/out" >/dev/null && ! grep '^  add NSWindow' "$T/out" >/dev/null ||
  fail 'p_clobber: rcx kept its class across a summarised callee'
pass 'a summarised callee clobbers the caller-saved registers'
run probe _p_chain; explored p_chain
[ "$(sites)" = 1 ] && grep '^  add ' "$T/out" >/dev/null || fail 'p_chain: a mutator two direct calls down is not followed'
pass 'a mutator two direct calls down is followed'

echo 'objc-regexec: table providers at every opt level, their mutants and every refusal pass'
