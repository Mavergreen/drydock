#!/bin/sh
# platform: host-agnostic -- links x86_64 table providers against the pinned 10.9 SDK with clang22 and lld, then reads them as bytes
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
# build NAME OPT [-DVARIANT...]: the table provider (UNIT another), ARC as Recaulk's tabbing units, linked with a trivial main.
build() {
  n=$1 o=$2 u=${UNIT:-table-provider.m}; shift 2
  fxcc "$o" -fobjc-arc -fno-modules -fno-autolink -fPIC -Wall -Wextra -Werror "$@" -c "$FX/$u" -o "$T/$n.o" ||
    fail "$n: compiling $u $o $*"
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

for o in -O1 -Os -O2; do
  fxcc "$o" -c "$FX/regexec-pusharg.c" -o "$T/pusharg.o" || fail "compiling regexec-pusharg.c $o"
  fxcc "$T/main.o" "$T/pusharg.o" -lobjc -o "$T/pusharg$o" || fail "linking pusharg$o"
  run "pusharg$o" _pusharg_start; explored "pusharg$o"
  awk '/^path / && $10 >= 1 {f = 1} /^path / && $10 == 0 {z = 1} END {exit !(f && !z)}' "$T/out" ||
    fail "pusharg$o: the add after a helper changed a local through a pushed argument is decided: $(grep '^path ' "$T/out")"
done
pass 'a frame address passed as a pushed stack argument to a helper not followed escapes (-O1 -Os -O2)'
for o in -Os -Oz; do
  fxcc "$o" -c "$FX/regexec-sibcall.c" -o "$T/sibcall.o" || fail "compiling regexec-sibcall.c $o"
  fxcc "$T/main.o" "$T/sibcall.o" -lobjc -o "$T/sibcall$o" || fail "linking sibcall$o"
  run "sibcall$o" _sibcall_start; explored "sibcall$o"
  awk '/^path / && $10 >= 1 {f = 1} /^path / && $10 == 0 {z = 1} END {exit !(f && !z)}' "$T/out" ||
    fail "sibcall$o: the add after a helper reached by a tail call changed a local through a forwarded stack argument is decided: $(grep '^path ' "$T/out")"
done
pass 'a frame address forwarded as a stack argument by a tail call to a helper not followed escapes (-Os -Oz)'
# spec: src/objc/regexec.c header -- class_addMethod's failure is a path only where the result is read.
lazy() {   # lazy NAME OPT VARIANT: regexec-lazyadd.c's VARIANT at OPT, run from lazy_start with rdi bound to NSView
  fxcc "$2" "-D$3" -c "$FX/regexec-lazyadd.c" -o "$T/$1.o" || fail "compiling regexec-lazyadd.c $2 -D$3"
  fxcc "$T/main.o" "$T/$1.o" -lobjc -o "$T/$1" || fail "linking $1"
  rc=0; "$DRYDOCK_OBJC_REGEXEC_DRIVER" "$T/$1" _lazy_start NSView >"$T/out" 2>"$T/err" || rc=$?
  explored "$1"
}
added() { grep "^  add $1 .* $2\$" "$T/out" >/dev/null; }   # added CLS|META\ SEL OK: some path adds SEL with OK
npaths() { sed -n 's/^paths //p' "$T/out"; }
for o in -O0 -Os; do
  lazy "ten$o" "$o" TEN
  [ "$(npaths)" = 2 ] && [ "$(grep -c '^  add NSView|0 a[0-9] .* 1$' "$T/out")" = 20 ] && ! added '.*' 0 ||
    fail "ten$o: want two paths of ten succeeded adds: $(grep -E '^(paths|path|  add)' "$T/out")"
  lazy "checked$o" "$o" CHECKED
  awk '/^path /{ if (z && f) ok = 1; z = f = 0 } /^  add NSView\|0 c0 .* 0$/{ z = 1 } /^  add NSView\|0 c1 /{ f = 1 }
       END { exit !(ok || (z && f)) }' "$T/out" || fail "checked$o: no path with the add failed and its fallback added: $(cat "$T/out")"
  lazy "copied$o" "$o" COPIED
  added 'NSView|0 p0' 0 || fail "copied$o: the add whose result a local held has no failed path: $(cat "$T/out")"
  lazy "partial$o" "$o" PARTIAL
  added 'NSView|0 b0' 0 && added 'NSView|0 b0' 1 || fail "partial$o: the add tested in al is not both ways: $(cat "$T/out")"
  lazy "helper$o" "$o" HELPER
  added 'NSView|0 h0' 0 && added 'NSView|0 h0' 1 || fail "helper$o: the add a helper returns is not both ways: $(cat "$T/out")"
  lazy "tail$o" "$o" TAIL
  added 'NSView|0 t0' 0 && added 'NSView|0 t0' 1 || fail "tail$o: the add the entry returns is not both ways: $(cat "$T/out")"
  lazy "null$o" "$o" NULLCLS
  [ "$(npaths)" = 2 ] && added '?|0 n0' 0 && added 'NSView|0 n0' 1 ||
    fail "null$o: want the NULL class's failed add and one succeeded add: $(grep -E '^(paths|path|  add)' "$T/out")"
done
"$(dirname "$NM")/llvm-objdump" -d --no-show-raw-insn --disassemble-symbols=_lazy_start "$T/tail-Os" | grep -E '^ *[0-9a-f]+:[[:space:]]+jmp' >/dev/null ||
  fail "tail-Os: lazy_start does not end in a tail jump: $("$(dirname "$NM")/llvm-objdump" -d --disassemble-symbols=_lazy_start "$T/tail-Os")"
pass 'a failed class_addMethod is a path where its result is read, tested, copied, returned or tail-jumped to, and only there (-O0 -Os)'
fxcc -c "$FX/regexec-lazyadd.S" -o "$T/lazys.o" || fail 'assembling regexec-lazyadd.S'
fxcc "$T/main.o" "$T/lazys.o" -lobjc -o "$T/lazys" || fail 'linking lazys'
runl() { rc=0; "$DRYDOCK_OBJC_REGEXEC_DRIVER" "$T/lazys" "$@" >"$T/out" 2>"$T/err" || rc=$?; }
runl _u_write NSView --max-paths 1; explored u_write
[ "$(npaths)" = 1 ] || fail "u_write: $(head -1 "$T/out"), want one path: rax was written before any read"
for q in cmc ret; do
  here=$("$NM" "$T/lazys" | awk -v s="_u_${q}_here" '$3 == s {print $1}' | sed 's/^0*//')
  runl "_u_$q" NSView --max-paths 1; refused "u_$q" path-budget
  grep "forking at 0x$here\$" "$T/out" >/dev/null || fail "u_$q: the failed add does not fork at 0x$here: $(cat "$T/out")"
done
runl _u_ret NSView; explored u_ret
added 'NSView|0 ?' 0 && added 'NSView|0 ?' 1 || fail "u_ret: the returned add is not both ways: $(cat "$T/out")"
pass 'the failure forks at an instruction the read set does not classify and at a return, not before a write of rax'
fxcc -c "$FX/regexec-launder.S" -o "$T/launder.o" || fail 'assembling regexec-launder.S'
fxcc "$T/main.o" "$T/launder.o" -lobjc -o "$T/launder" || fail 'linking launder'
ls_va=$("$NM" "$T/launder" | awk '$3 == "_ls" {print "0x" $1}' | sed 's/0x0*/0x/')
for q in _l_base _l_shcl _l_sbb _l_setcc _l_ctl _l_overlap _l_dead _l_dead2 _l_impidx; do
  run launder $q; explored $q
  grep -E "^escaped .*($ls_va|0xffffffffffffffff)@" "$T/out" >/dev/null || fail "$q: bits of _ls ($ls_va) reach a helper not followed, not escaped: $(grep '^escaped' "$T/out")"
done
pass 'an image address copied through a shift count, the carry, setcc, a branch, an overlapped or a dead frame cell escapes'
run launder _l_shimm; explored l_shimm
grep '^escaped .*@' "$T/out" >/dev/null && fail "l_shimm: a shift by an immediate takes rcx's provenance: $(grep '^escaped' "$T/out")"
pass 'a shift by an immediate count reads no register'
run launder _l_import; explored l_import
grep '^escaped .*@' "$T/out" >/dev/null && fail "l_import: an imported datum read through its GOT slot carries the dead frame: $(grep '^escaped' "$T/out")"
pass 'an imported datum read at a constant offset from its address is another image'"'"'s memory, not the dead frame'
run launder _l_walk; explored l_walk
[ "$(sed -n 's/^paths //p' "$T/out")" = 1 ] || fail "l_walk: $(head -1 "$T/out"), want paths 1: a row pointer compared to the table's end, or to NULL, is known"
pass 'a walk comparing a row pointer to the table end, testing it non-NULL, is decided'

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

# spec: src/objc/regexec.c header, "Start" -- a root run with its class argument bound, its stores held to its class
#       table, and member IMP addresses followed. tests/objc/fixtures/bridge-provider.m is the root.
for v in plain TABLE_OTHER TABLE_ELSEWHERE IMP_ELSEWHERE UNBOUNDED_SCAN TABLE_DEPENDENT_IMP TABLE_LITERAL TABLE_ESCAPE; do
  d=; [ "$v" = plain ] || d="-D$v"
  UNIT=bridge-provider.m build "bridge-$v" -Os $d
done
runb() { rc=0; i=$1; shift; "$DRYDOCK_OBJC_REGEXEC_DRIVER" "$T/bridge-$i" "$@" >"$T/out" 2>"$T/err" || rc=$?; }
BRIDGE='  add FixtureBridgedView|0 accessibilityAttributeNames _FixtureBridge_attributeNames @16@0:8 1
  add FixtureBridgedView|0 accessibilityAttributeValue: _FixtureBridge_attributeValue @24@0:8@16 1
  add FixtureBridgedView|0 accessibilityIsIgnored _FixtureBridge_isIgnored c16@0:8 1'
runb plain _FixtureBridge FixtureBridgedView; explored 'rdi bound'
got=$(all_miss)
[ "$got" = "1
$BRIDGE" ] || fail "rdi bound: want one all-succeed path with the three adds, got:
$got"
awk '/^path /{ if ($6 != 0) exit 1 }' "$T/out" || fail 'rdi bound: a path tests the bound class NULL'
[ "$(sed -n 's/^null-paths //p' "$T/out")" = 0 ] || fail "rdi bound: $(sed -n 2p "$T/out"), want null-paths 0"
pass 'rdi bound: one all-succeed path adds the three members to the bound class, and none tests it NULL'
runb plain _FixtureBridge; explored 'rdi unbound'
grep '^  add ?|0 accessibilityAttributeNames _FixtureBridge_attributeNames ' "$T/out" >/dev/null &&
  ! grep '^  add FixtureBridgedView' "$T/out" >/dev/null || fail 'rdi unbound: the adds name a class'
pass 'rdi unbound: the adds name no class'
tbl=$("$NM" "$T/bridge-plain" | awk '$3 == "_FixtureBridgeClasses" {print "0x" $1}' | sed 's/0x0*/0x/')
[ -n "$tbl" ] || fail 'bridge: no _FixtureBridgeClasses'
in_tbl() {  # in_tbl LIST: the 0xVA+LEN@0xSITE entries of LIST whose VA lies in the 8-slot class table
  tr ' ' '\n' | sed 's/+.*//' | while read -r va; do [ -n "$va" ] && [ $((va)) -ge $((tbl)) ] && [ $((va)) -lt $((tbl + 64)) ] && echo "$va"; done
}
runb plain _FixtureBridge FixtureBridgedView; explored 'the root without its table'
[ -n "$(sed -n 's/^reads //p' "$T/out" | in_tbl)" ] || fail "the root without its table: no read of the table at $tbl: $(grep '^reads' "$T/out")"
runb plain _FixtureBridge FixtureBridgedView --table _FixtureBridgeClasses; explored "the root's class into its table"
slots=$(for k in 0 1 2 3 4 5 6 7; do printf '0x%x+8\n' $((tbl + 8 * k)); done | sort -u)
[ "$(sed -n 's/^stores //p' "$T/out" | tr ' ' '\n' | sed 's/@.*//' | sort -u)" = "$slots" ] ||
  fail "the root's class into its table: $(grep '^stores' "$T/out"), want an 8-byte store at each of its 8 slots from $tbl"
all_miss | grep -c '^  add ' | grep -x 3 >/dev/null || fail "the root's class into its table: the three adds are gone"
[ "$(all_miss | head -1)" = 9 ] || fail "the root's class into its table: $(all_miss | head -1) all-succeed paths, want 9 (each free slot, and a full table)"
awk '/^path /{ if ($10 != 0 || $12 < 1) exit 1 }' "$T/out" || fail "the root's class into its table: a path guesses, or forks on no table slot: $(grep '^path' "$T/out")"
[ -z "$(sed -n 's/^reads //p' "$T/out" | in_tbl)" ] || fail "the root's class into its table: the table is read as initial values: $(grep '^reads' "$T/out")"
pass "the root's class stored into its class table is allowed, and recorded; the table reads as unknown, its forks no guesses"
runb UNBOUNDED_SCAN _FixtureBridge FixtureBridgedView --table _FixtureBridgeClasses
tblu=$("$NM" "$T/bridge-UNBOUNDED_SCAN" | awk '$3 == "_FixtureBridgeClasses" {print "0x" $1}')
[ -n "$tblu" ] && [ "$rc" = 1 ] && grep -E "^refused (image|unknown)-store: a store to $(printf '0x%x' $((tblu + 64)))," "$T/out" >/dev/null ||
  fail "UNBOUNDED_SCAN: driver exit $rc, want a refused store just past the table: $(head -3 "$T/out")"
runb UNBOUNDED_SCAN _FixtureBridge FixtureBridgedView; explored 'UNBOUNDED_SCAN without --table'
pass 'a slot search the table size does not bound stores past it, refused; without --table, read as zeros, it is explored'
runb TABLE_DEPENDENT_IMP _FixtureBridge FixtureBridgedView --table _FixtureBridgeClasses; explored TABLE_DEPENDENT_IMP
grep '^  add FixtureBridgedView|0 accessibilityAttributeNames _FixtureBridge_isIgnored ' "$T/out" >/dev/null ||
  fail "TABLE_DEPENDENT_IMP: no path adds the IMP the table's slot 1 chooses"
runb TABLE_DEPENDENT_IMP _FixtureBridge FixtureBridgedView; explored 'TABLE_DEPENDENT_IMP without --table'
! grep '^  add FixtureBridgedView|0 accessibilityAttributeNames _FixtureBridge_isIgnored ' "$T/out" >/dev/null ||
  fail "TABLE_DEPENDENT_IMP without --table: slot 1 read as zero still adds isIgnored"
pass 'an add the table decides is explored both ways'
tbll=$("$NM" "$T/bridge-TABLE_LITERAL" | awk '$3 == "_FixtureBridgeClasses" {print "0x" $1}')
runb TABLE_LITERAL _FixtureBridge FixtureBridgedView; explored 'TABLE_LITERAL without --table'
tbl=$tbll; [ -n "$(sed -n 's/^reads //p' "$T/out" | in_tbl)" ] && grep '^selreg .*:1' "$T/out" >/dev/null ||
  fail "TABLE_LITERAL without --table: the table's bytes are no literal read: $(grep -E '^(reads|selreg)' "$T/out")"
runb TABLE_LITERAL _FixtureBridge FixtureBridgedView --table _FixtureBridgeClasses; explored TABLE_LITERAL
[ -z "$(sed -n 's/^reads //p' "$T/out" | in_tbl)" ] || fail "TABLE_LITERAL: the table's bytes are read as a literal: $(grep '^reads' "$T/out")"
grep '^selreg .*:0' "$T/out" >/dev/null || fail "TABLE_LITERAL: every selector registered is a literal: $(grep '^selreg' "$T/out")"
pass "the table's bytes are no C string literal"
for v in TABLE_OTHER TABLE_ELSEWHERE; do
  runb "$v" _FixtureBridge FixtureBridgedView --table _FixtureBridgeClasses; refused "$v" image-store
  grep "not the root's class into its class table" "$T/out" >/dev/null || fail "$v: $(cat "$T/out")"
  runb "$v" _FixtureBridge FixtureBridgedView; explored "$v without --table"
done
pass 'anything else into the table, and the class anywhere else, refuse image-store; without a table both explore'
imp=$("$NM" "$T/bridge-IMP_ELSEWHERE" | awk '$3 == "_FixtureBridge_isIgnored" {print "0x" $1}' | sed 's/0x0*/0x/')
[ -n "$imp" ] || fail 'IMP_ELSEWHERE: no _FixtureBridge_isIgnored'
runb IMP_ELSEWHERE _FixtureBridgeLeak --track _FixtureBridge_isIgnored; explored 'IMP_ELSEWHERE'
grep "^escaped .*$imp@" "$T/out" >/dev/null || fail "IMP_ELSEWHERE: the IMP ($imp) returned from FixtureBridgeLeak is not escaped: $(grep '^escaped' "$T/out")"
for f in _FixtureBridgeLeakMasked _FixtureBridgeLeakSlot; do
  runb IMP_ELSEWHERE $f --track _FixtureBridge_isIgnored; explored "IMP_ELSEWHERE $f"
  grep "^escaped .*$imp@" "$T/out" >/dev/null || fail "IMP_ELSEWHERE: the IMP ($imp), masked, returned from $f is not escaped: $(grep '^escaped' "$T/out")"
done
runb plain _FixtureBridge FixtureBridgedView --table _FixtureBridgeClasses --track _FixtureBridge_isIgnored; explored 'plain root, tracked'
[ "$(grep '^escaped' "$T/out")" = escaped ] || fail "the root: $(grep '^escaped' "$T/out"), want nothing escaped (an IMP is class_addMethod's argument)"
pass 'a tracked IMP returned, as itself or through a lea or a data pointer masked, escapes; handed to class_addMethod it does not'
tble=$("$NM" "$T/bridge-TABLE_ESCAPE" | awk '$3 == "_FixtureBridgeClasses" {print "0x" $1}' | sed 's/0x0*/0x/')
runb TABLE_ESCAPE _FixtureBridge FixtureBridgedView --table _FixtureBridgeClasses --track _FixtureBridge_isIgnored; explored TABLE_ESCAPE
[ -n "$tble" ] && grep "^escaped .*$tble@" "$T/out" >/dev/null ||
  fail "TABLE_ESCAPE: the table ($tble) passed to memset is not escaped: $(grep '^escaped' "$T/out")"
[ "$(grep '^escaped' "$T/out" | tr ' ' '\n' | grep -c '@')" = 1 ] ||
  fail "TABLE_ESCAPE: $(grep '^escaped' "$T/out"), want the table's address alone: its contents are no address"
pass "the class table's address escapes as any writable address does; values loaded from it do not"

echo 'objc-regexec: table providers at every opt level, their mutants and every refusal pass'
