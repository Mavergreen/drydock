#!/bin/sh
# platform: macOS-only -- links an x86_64 fixture against the pinned 10.9 SDK, then reads its method lists
# spec: src/objc/reference.c "argument registers" -- how many argument GPRs a call may use: a send by its
#       selector's declarations (both signature catalogs and the artifact's own method encodings), a C call
#       by the floor function catalog, an encoding by SysV x86_64 classification; -1 means unbounded.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
# spec: build/msc.sh -- SHIPYARD_SCRIPTS, where shipyard's fetchers are (CTest passes it; a standalone run finds it).
. "$ROOT/build/msc.sh"
FX="$HERE/fixtures"
REF="$ROOT/reference/objc"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-arity-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; [ ! -f "$T/err" ] || tail -5 "$T/err" >&2; exit 1; }

D=${DRYDOCK_OBJC_ARITY_DRIVER:-}
[ -x "$D" ] || fail "arity harness: DRYDOCK_OBJC_ARITY_DRIVER names no built objc-arity-driver"
# spec: tests/objc/fixtures/arity-driver.c header -- is NAME WANT ARGS...: the driver, given ARGS and one
#       query (the rest of stdin), prints WANT.
is() {
  name=$1 want=$2; shift 2
  got=$("$D" "$@" 2>"$T/err") || fail "$name: the driver exited $?"
  [ "$got" = "$want" ] || fail "$name: got '$got', want '$want'"
}
q() { printf '%s\n' "$@"; }

# no_colon: no parameters, no lookup -- self and _cmd, plus the hidden result pointer of a _stret send.
q 'sel	count	0' | is no_colon 2 --references "$REF"
q 'sel	count	1' | is no_colon_stret 3 --references "$REF"
q 'sel	count	0' | is no_colon_no_catalog 2
# struct_arg: NSText's -setSelectedRange:(NSRange) -- two INTEGER eightbytes.
q 'sel	setSelectedRange:	0' | is struct_arg 4 --references "$REF"
q 'sel	setSelectedRange:	1' | is struct_arg_stret 5 --references "$REF"
# double_arg: an SSE parameter takes no GPR.
q 'sel	setDoubleValue:	0' | is double_arg 2 --references "$REF"
# variadic and unknown selectors are unbounded.
q 'sel	stringWithFormat:	0' | is variadic -1 --references "$REF"
q 'sel	zzNoSuch:	0' | is unknown_sel -1 --references "$REF"
# Without the catalogs nothing with a parameter is bounded.
q 'sel	setDoubleValue:	0' | is no_catalog -1

# A fake reference directory: one selector declared by two classes in the two catalogs; out-of-range,
# unclassified and variadic rows.
mkdir -p "$T/fake" "$T/floor-only"
row() { printf 'method\t%s\t-\t%s\tother\t-\tfake.h:1\tinterface\t%s\t%s\n' "$1" "$2" "$3" "$4"; }
{ echo '# objc-signatures 2'; row A pair: 1 0; row A nine: 9 0; row A dash: - 0; row A four:a:b:c: 4 0; row A five:a:b:c:d: 5 0; } >"$T/fake/floor-signatures.tsv"
{ echo '# objc-signatures 2'; row B pair: 2 0; row B four:a:b:c: 3 0; row B dash: 1 0; row B vary: 1 1; row C vary: 1 0; } >"$T/fake/newer-signatures.tsv"
{ printf '# objc-functions 1\n'; printf 'nine\t9\t0\t0\tfake.h:2\n'; printf 'six\t6\t0\t0\tfake.h:3\n'; printf 'dash\t-\t0\t0\tfake.h:4\n'; } >"$T/fake/floor-functions.tsv"
{ printf '# objc-functions 1\n'; printf 'builtin\t1\t0\t1\tfake builtin\n'; } >"$T/fake/floor-functions-builtin.tsv"
cp "$T/fake/floor-signatures.tsv" "$T/floor-only/"
# max_over_classes: 1 GPR on A, 2 on B (the other catalog) -- the larger.
q 'sel	pair:	0' | is max_over_classes 4 --references "$T/fake"
q 'sel	four:a:b:c:	0' | is max_six 6 --references "$T/fake"
q 'sel	four:a:b:c:	1' | is over_six_stret -1 --references "$T/fake"
q 'sel	five:a:b:c:d:	0' | is over_six -1 --references "$T/fake"
# gprs_range: a catalog value over six is unbounded, never clamped.
q 'sel	nine:	0' | is gprs_range -1 --references "$T/fake"
q 'fn	_nine' | is gprs_range_fn -1 --references "$T/fake"
q 'fn	_six' | is fn_six 6 --references "$T/fake"
q 'fn	_builtin' | is builtin_fn 1 --references "$T/fake"
# builtin_duplicate: the hand-written catalog never restates a declared function.
mkdir "$T/dup"; cp "$T/fake/"*.tsv "$T/dup/"
printf 'six\t6\t0\t0\tfake builtin\n' >>"$T/dup/floor-functions-builtin.tsv"
rc=0; printf 'fn\t_six\n' | "$D" --references "$T/dup" >"$T/out" 2>"$T/err" || rc=$?
[ "$rc" = 4 ] && grep 'malformed-reference.*six is already catalogued' "$T/err" >/dev/null ||
  fail "builtin_duplicate: a name in both function catalogs loaded ($rc)"
q 'sel	dash:	0' | is unclassified -1 --references "$T/fake"
q 'fn	_dash' | is unclassified_fn -1 --references "$T/fake"
q 'sel	vary:	0' | is variadic_on_one_class -1 --references "$T/fake"
# One catalog alone bounds nothing: its sibling might declare more.
q 'sel	pair:	0' | is one_catalog -1 --references "$T/floor-only"
q 'fn	_six' | is no_fn_catalog -1 --references "$T/floor-only"

# c_fn: the floor function catalog, by the undecorated import symbol; gprs include a hidden result pointer.
q 'fn	___assert_rtn' | is c_fn_assert 4 --references "$REF"
q 'fn	___stack_chk_fail' | is c_fn_stack_chk 0 --references "$REF"
q 'fn	_objc_msgSend' | is c_fn_msgsend -1 --references "$REF"
q 'fn	_NSLog' | is c_fn_variadic -1 --references "$REF"
q 'fn	_zzNoSuchFunction' | is c_fn_unknown -1 --references "$REF"
q 'fn	write' | is c_fn_undecorated -1 --references "$REF"
# c_suffix: an asm label's $SUFFIX is not part of the C name.
q 'fn	_write' | is c_fn_write 3 --references "$REF"
q 'fn	_write$UNIX2003' | is c_suffix 3 --references "$REF"
q 'fn	_realpath$DARWIN_EXTSN' | is c_suffix_extsn 2 --references "$REF"

# rely: the reader measured a send with the entry point left out of its arguments by the selector's bound (index 3,
# rcx, beyond a one-parameter send's rdi, rsi and rdx). A declaration noted later -- a shipped image's method list,
# read after the artifact's code -- that raises the bound past rcx is indirect-objc-entry, reported once.
q 'note	zzOne:	1' 'rely	zzOne:	0	3' 'note	zzOne:	1' | is rely_kept "$(printf '0\n0\n0')"
q 'note	zzOne:	1' 'rely	zzOne:	0	3' 'note	zzOne:	2' 'note	zzOne:	3' | is rely_raised "$(printf '0\n0\n1\n1')"
q 'note	zzOne:	1' 'rely	zzOne:	0	3' 'note	zzOne:	-1' | is rely_unbounded "$(printf '0\n0\n1')"
# rely_stret: a _stret send's hidden result pointer shifts the limit: rcx (3) leaves room for no parameter.
q 'rely	zzOne:	1	3' 'note	zzOne:	1' | is rely_stret "$(printf '0\n1')"
# rely_no_colon: a selector without a colon takes no parameter whatever is declared; nothing is relied on.
q 'rely	zzCount	0	2' 'note	zzCount	4' | is rely_no_colon "$(printf '0\n0')"
rc=0; printf 'note\tzzOne:\t1\nrely\tzzOne:\t0\t3\nnote\tzzOne:\t2\n' | "$D" >"$T/out" 2>"$T/err" || rc=$?
grep -F 'objc entry point in rcx is passed as an argument: a declaration of zzOne: read after this send' "$T/err" >/dev/null ||
  fail 'rely_message: the raised bound is not reported at its send'

# imp: an import's bound only when it binds to the system library its catalogued declaration lives in -- usr/include's
# under /usr/lib/, a framework header's in that framework (a sub-framework's in its umbrella); flat lookup, the main
# executable or any other library may be another function of that name.
q 'imp	_write	/usr/lib/libSystem.B.dylib' | is imp_libsystem 3 --references "$REF"
q 'imp	_write$UNIX2003	/usr/lib/libSystem.B.dylib' | is imp_suffix 3 --references "$REF"
q 'imp	___stack_chk_fail	/usr/lib/libSystem.B.dylib' | is imp_builtin 0 --references "$REF"
q 'imp	_NSBeep	/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit' | is imp_framework 0 --references "$REF"
q 'imp	_AECreateDesc	/System/Library/Frameworks/CoreServices.framework/Versions/A/CoreServices' | is imp_umbrella 4 --references "$REF"
q 'imp	_NSBeep	/usr/lib/libSystem.B.dylib' | is imp_other_system_lib -1 --references "$REF"
q 'imp	_write	@rpath/libelsewhere.dylib' | is imp_other_lib -1 --references "$REF"
q 'imp	_write	/usr/local/lib/libwrite.dylib' | is imp_nonsystem_path -1 --references "$REF"
q 'imp	_write	(flat lookup)' | is imp_flat -1 --references "$REF"
q 'imp	_write	(the main executable)' | is imp_main_executable -1 --references "$REF"

# Encodings: parameter GPRs without self and _cmd.
q 'enc	v32@0:8@16@24' | is enc_ids 2
q 'enc	v40@0:8^S16{_NSRange=QQ}24' | is enc_range 3
q 'enc	v24@0:8d16' | is enc_double 0
q 'enc	v24@0:8c16s20' | is enc_small_ints 2
q 'enc	v30@0:8{?=sss}16@22' | is enc_six_byte_struct 2
q 'enc	v28@0:8{?=ifi}16' | is enc_mixed_eightbytes 2
q 'enc	v32@0:8{?=di}16' | is enc_sse_then_int 1
q 'enc	v32@0:8{?=dd}16' | is enc_sse_struct 0
q 'enc	v40@0:8{?=cd}16[4i]32' | is enc_array_param 2
q 'enc	v24@0:8{?=[2i]}16' | is enc_array_member 1
q 'enc	v48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16' | is enc_big_struct 0
q 'enc	v24@0:8@"NSString"16' | is enc_class_named 1
q 'enc	v40@0:8@?16^?24r*32' | is enc_block_fnptr_cstr 3
q 'enc	{CGRect={CGPoint=dd}{CGSize=dd}}16@0:8' | is enc_struct_result 0
q 'enc	v@:@' | is enc_no_offsets 1
q 'enc	v@:^{x=ii}r*#:' | is enc_no_offsets_scalars 4
q 'enc	v26@0:8{?=s}16@18' | is enc_small_struct_unwidened 2
# Without offsets an aggregate's layout is a guess; offsets are on every argument or none.
q 'enc	v@:{?=ii}' | is enc_no_offsets_struct -1
q 'enc	v@:[4i]' | is enc_no_offsets_array -1
q 'enc	v@:{?=ii}@16' | is enc_some_offsets -1
q 'enc	v24@0:8@' | is enc_last_offset_missing -1
q 'enc	v@0:8@16' | is enc_no_frame -1
q 'enc	v24@8:16@24' | is enc_self_not_first -1
# encoding_unknown: a union, bitfield, long double or anything unrecognised.
q 'enc	v24@0:8{weird=b3}16' | is encoding_unknown -1
q 'enc	v24@0:8(?=id)16' | is enc_union -1
q 'enc	v32@0:8{?=b3i}16' | is enc_bitfield -1
q 'enc	v48@0:8D32' | is enc_long_double -1
q 'enc	v24@0:8{Opaque}16' | is enc_incomplete -1
q 'enc	v28@0:8{_NSRange=QQ}16' | is enc_offset_disagrees -1
q 'enc	v40@0:8{_NSRange=QQ}16@28' | is enc_middle_offset_disagrees -1
q 'enc	v20@0:8i16' | is enc_int 1
q 'enc	i16@0:8' | is enc_none 0
q 'enc	v16:0@8' | is enc_not_a_method -1
q 'enc	v24@0:8{?=QQ' | is enc_truncated -1
q 'enc	v72@0:8q16q24q32q40q48q56q64' | is enc_over_six -1

# own_encoding: the artifact's own method list declares two:args: (v32@0:8@16@24) -- self, _cmd, two ids.
SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" --arch x86_64)
cat >"$T/own.m" <<'EOF'
__attribute__((objc_root_class)) @interface Own @end
@implementation Own
- (void)two:(id)a args:(id)b { (void)a; (void)b; }
+ (void)zzOwnDouble:(double)d { (void)d; }
@end
int main(void) { return 0; }
EOF
# platform: env -i keeps CPATH and SDKROOT from steering the fixture away from the pinned SDK.
env -i PATH=/usr/bin:/bin /usr/bin/clang -arch x86_64 -isysroot "$SDK" -mmacosx-version-min=10.9 -O1 \
  "$T/own.m" -o "$T/own" -lobjc 2>"$T/err" || fail 'the own-encoding fixture did not build'
q 'sel	two:args:	0' | is own_encoding 4 --references "$REF" --artifact "$T/own"
q 'sel	zzOwnDouble:	1' | is own_encoding_stret 3 --references "$REF" --artifact "$T/own"
q 'sel	two:args:	0' | is own_encoding_needs_catalogs -1 --artifact "$T/own"
echo PASS
