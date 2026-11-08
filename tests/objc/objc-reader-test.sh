#!/bin/sh
# platform: macOS-only -- links x86_64 fixtures against the pinned 10.9 SDK, then reads their bytes
# spec: tools/objc-compat/macho-reader.c header -- the real reader over real fixture bytes, on
#       either host arch; every unsupported shape is cannot-measure.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
FX="$HERE/fixtures/objc-api"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-reader-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; [ ! -f "$T/out" ] || tail -20 "$T/out" >&2; exit 1; }

sh "$ROOT/scripts/objc-compat-build.sh" --reader-driver "$T/reader" || fail "reader harness did not build"
SDK=$(sh "$ROOT/scripts/fetch_sdk.sh" --arch x86_64)
# platform: env -i keeps CPATH and SDKROOT from steering the fixtures away from the pinned SDK.
cc() { env -i PATH=/usr/bin:/bin /usr/bin/clang -arch x86_64 -isysroot "$SDK" -mmacosx-version-min=10.9 -O1 "$@"; }
read_artifact() { rc=0; "$T/reader" --artifact "$1" >"$T/out" 2>"$T/err" || rc=$?; }
# spec: tools/objc-compat/macho-reader.c header -- has KIND COL=VALUE...: some evidence row of KIND matches every column (1-based after "evidence").
has() {
  kind=$1; shift
  awk -F '\t' -v kind="$kind" -v want="$*" '
    BEGIN { n = split(want, w, " ") }
    $1 == "evidence" && $2 == kind {
      ok = 1
      for (i = 1; i <= n; i++) { split(w[i], kv, "="); if ($(kv[1] + 1) != kv[2]) ok = 0 }
      if (ok) found = 1
    }
    END { exit !found }' "$T/out" || fail "no $kind evidence with $*"
}
count() { awk -F '\t' -v k="$1" '$1 == "evidence" && $2 == k' "$T/out" | wc -l | tr -d ' '; }
measured() { [ "$rc" = 0 ] && ! grep '^error' "$T/out" >/dev/null || fail "$1: expected measured (exit 0, no errors), got $rc"; }
refused() {
  [ "$rc" = 4 ] || fail "$1: expected cannot-measure exit 4, got $rc"
  grep "^error	$2	" "$T/out" >/dev/null || fail "$1: expected error $2"
}
# spec: tools/objc-compat/macho-reader.c header -- Columns: 1 kind 2 slice 3 address 4 target 5 owner 6 method-kind 7 selector 8 name 9 symbol.
OPEN='openURLs:withApplicationAtURL:options:configuration:error:'

# spec: tools/objc-compat/macho-reader.c header -- Conventional metadata: class, metaclass, category, selector/class/super references and sends.
# platform: ARC at compile time only. An ARC link below a 10.11 floor makes current clang drivers add
#           libarclite_macosx.a, which current CommandLineTools no longer ship; the 10.9 driver adds none.
#           -lobjc reproduces the runtime link -fobjc-arc implied, so the linked bytes are unchanged.
cc -fobjc-arc -c "$FX/conventional.m" -o "$T/conventional.o"
cc "$T/conventional.o" -o "$T/conventional" -framework AppKit -framework Foundation -lobjc
read_artifact "$T/conventional"
measured conventional
has class 5=NSObject 8=Probe
has method 5=Probe 6=+ 7=probe
has method 5=Probe 6=- 7=launch:
has method 5=Probe 6=- 7=init
has category 5=NSWorkspace 8=MavergreenProbe
has method 5=NSWorkspace 6=- 7=mavergreenProbe 8=MavergreenProbe
has selref 7="$OPEN"
has classref 8=NSWorkspace
slot=$(awk -F '\t' -v s="$OPEN" '$2 == "selref" && $8 == s {print $4}' "$T/out")
has metadata-use 4="$slot" 8=__objc_selrefs
has metadata-use 8=__objc_superrefs
has dispatch-call 8=objc_msgSendSuper2
has dispatch-call 8=objc_msgSend
! awk -F '\t' '$2 == "method" && $8 == "'"$OPEN"'"' "$T/out" | grep . >/dev/null ||
  fail 'a declared-only later method became an implementation'

# spec: tools/objc-compat/macho-reader.c header -- objc2 0.6: caches named by their v0 statics, literals from the fetch site, real consumers.
cc "$FX/objc2-pattern.c" -o "$T/objc2" -lobjc -Wl,-U,_objc_alloc -Wl,-U,_NSSelectorFromString -Wl,-U,_fixture_nsstring
read_artifact "$T/objc2"
measured objc2
has sel-cache 7="$OPEN"
cache=$(awk -F '\t' -v s="$OPEN" '$2 == "sel-cache" && $8 == s {print $4}' "$T/out")
has cache-fetch 4="$cache" 7="$OPEN"
has cache-use 4="$cache"
has sel-cache 7=sharedWorkspace
has class-cache 8=NSWorkspace
has sel-cache 7=stringWithUTF8String:
has sel-cache 7=errorWithDomain:code:userInfo:
has sel-register 7=stringWithUTF8String: 8=objc2::runtime::Sel::register_unchecked
has sel-register 7=isVoiceOverEnabled 8=NSSelectorFromString
has class-lookup 5=NSString 8=objc_getClass
has dispatch-call 8=objc_alloc
[ "$(count sel-cache)" = 4 ] && [ "$(count class-cache)" = 1 ] || fail 'cache statics miscounted'
[ "$(count dispatch-call)" -ge 4 ] || fail 'objc_msgSend sends lost'
awk -F '\t' '$2 == "sel-cache" && $8 == "-"' "$T/out" | grep . >/dev/null && fail 'a cache without its selector'
grep -F 'accessibilityDisplayShouldReduceMotion' "$T/out" >/dev/null && fail 'incidental prose became a producer'
grep -F 'isVoiceOverEnabledNSString' "$T/out" >/dev/null && fail 'packed bytes read past their length'

# spec: tools/objc-compat/macho-reader.c header -- Dispatch operands: columns 10 function, 11 receiver, 12 selector, 13 first argument, each "form:0xref:text".
send() {
  awk -F '\t' -v fn="$1" -v r="$2" -v s="$3" -v g="${4:-*}" '
    function norm(v,   i, rest) { i = index(v, ":"); rest = substr(v, i + 1); return substr(v, 1, i - 1) ":" substr(rest, index(rest, ":") + 1) }
    $1 == "evidence" && $2 == "dispatch-call" && $11 == fn && norm($12) == r && norm($13) == s && (g == "*" || norm($14) == g) {found = 1}
    END { exit !found }' "$T/out" || fail "no send in $1 with $2 $3 ${4:-}"
}
sends_of() { awk -F '\t' -v s="$1" '$1 == "evidence" && $2 == "dispatch-call" { i = index($13, ":"); r = substr($13, i + 1); if (substr($13, 1, i - 1) ":" substr(r, index(r, ":") + 1) == s) print }' "$T/out"; }
closure_fixture() {
  cc -DOPEN_FORM="$1" "$FX/closure.c" -o "$2" -lobjc -Wl,-U,_objc_alloc -Wl,-U,_NSSelectorFromString -Wl,-U,_fixture_nsstring \
    -Wl,-U,_fixture_use -Wl,-U,_objc_retainAutoreleasedReturnValue -Wl,-U,_objc_release
}
closure_fixture 0 "$T/closure"
read_artifact "$T/closure"
measured closure
send _voiceover_guarded class-cache:NSWorkspace sel-cache:sharedWorkspace
send _voiceover_guarded result:- sel-cache:respondsToSelector: sel-nsstring:isVoiceOverEnabled
send _voiceover_guarded result:- sel-cache:isVoiceOverEnabled
send _voiceover_unguarded result:- sel-cache:isVoiceOverEnabled
[ "$(sends_of sel-cache:isVoiceOverEnabled | cut -f4 | sort -u | wc -l | tr -d ' ')" = 2 ] ||
  fail 'a second caller of a shared selector cache did not get its own dispatch site'
send _empty_options class-cache:NSDictionary sel-cache:new
[ "$(sends_of sel-cache:new | wc -l | tr -d ' ')" = 1 ] && [ -z "$(sends_of sel-cache:init)" ] ||
  fail 'a compared-only selector cache (new_fail/init_fail) became a send'
awk -F '\t' '$2 == "cache-use" && $11 == "_is_plain_init"' "$T/out" | grep . >/dev/null || fail 'the compared init cache use vanished'
send _enumerate_items class-cache:NSPasteboard sel-cache:generalPasteboard
send _enumerate_items result:- sel-cache:pasteboardItems
send _enumerate_items result:- sel-cache:countByEnumeratingWithState:objects:count:
send _string_from class-cache:NSString none:-
send _string_from result:- sel-cache:initWithBytes:length:encoding:
send _null_error class-literal:NSString sel-cache:stringWithUTF8String:
send _null_error class-literal:NSError sel-cache:errorWithDomain:code:userInfo:
send _class_description class-cache:NSDictionary sel-cache:description
send _items_of argument:- sel-cache:pasteboardItems
# platform: the open forms are still measured inventories; their unknowns are operands, not errors.
for form in 3:_iter_next:unknown:-:sel-cache:countByEnumeratingWithState:objects:count: 4:_computed_send:argument:-:argument:- \
            5:_escaped_spill:unknown:-:sel-cache:description; do
  n=${form%%:*}; rest=${form#*:}; fn=${rest%%:*}; rest=${rest#*:}
  recv=${rest%%:*}:$(printf '%s' "${rest#*:}" | cut -d: -f1); sel=$(printf '%s' "${rest#*:}" | cut -d: -f2-)
  closure_fixture "$n" "$T/open$n"
  read_artifact "$T/open$n"
  measured "open form $n"
  send "$fn" "$recv" "$sel"
done

# spec: tools/objc-compat/macho-reader.c header -- A measured image without Objective-C: success with no observations at all.
cc "$FX/plain.c" -o "$T/plain"
read_artifact "$T/plain"
measured plain
grep '^evidence' "$T/out" >/dev/null && fail 'plain C image invented Objective-C evidence'

# spec: tools/objc-compat/macho-reader.c header -- The x86_64 slice of a fat file reads exactly like the thin image.
lipo -create "$T/objc2" -output "$T/fat"
read_artifact "$T/fat"
measured fat
grep '^evidence' "$T/out" >"$T/fat.ev"
"$T/reader" --artifact "$T/objc2" | grep '^evidence' >"$T/thin.ev"
cmp -s "$T/fat.ev" "$T/thin.ev" || fail 'fat x86_64 slice reads differently from the thin image'

# spec: tools/objc-compat/macho-reader.c header -- Unsupported shapes are cannot-measure, never an empty success.
head -c 4096 "$T/conventional" >"$T/truncated"
read_artifact "$T/truncated"; refused truncated malformed-macho
printf 'not a Mach-O\n' >"$T/text"
read_artifact "$T/text"; refused text malformed-macho
read_artifact "$T/missing"; refused missing unreadable-artifact
read_artifact "$T"; refused directory unreadable-artifact
# platform: rewrite the one fat_arch cputype to arm64 (0x0100000c, big-endian at offset 8):
#           a universal file with no x86_64 slice has nothing this reader may measure.
cp "$T/fat" "$T/noslice"
printf '\001\000\000\014' | dd of="$T/noslice" bs=1 seek=8 conv=notrunc 2>/dev/null
read_artifact "$T/noslice"; refused noslice no-x86_64-slice
cp "$T/objc2" "$T/stripped"; chmod u+w "$T/stripped"; strip "$T/stripped"
read_artifact "$T/stripped"; refused stripped computed-selector-producer
# spec: tools/objc-compat/macho-reader.c header -- a call that makes a class at run time (objc_allocateClassPair) is runtime-class-creation.
for form in 1:computed-selector-producer 2:computed-class-producer 3:unclassified-objc-runtime-import \
            4:indirect-objc-entry 5:computed-selector-producer 6:runtime-class-creation; do
  n=${form%%:*}
  cc -DFORM="$n" "$FX/unsupported.c" -o "$T/unsupported$n" -lobjc -Wl,-U,_NSSelectorFromString
  read_artifact "$T/unsupported$n"; refused "unsupported form $n" "${form#*:}"
done

# spec: tools/objc-compat/macho-reader.c header -- A GOT-loaded entry point held in a register and only ever called through
#       (modern -Os codegen: tests/fixtures/objc-api/hoisted-entry.S), copied to a register only jumped through, past a
#       call that never returns, or spilled to a frame slot no escaped frame address reaches and reloaded only to be called
#       through (clang -O0), is followed, each call its own send. A copy passed as an argument, a path where it holds
#       something else, a slot whose address escapes, that another path overwrites or that is read some other way, or a
#       store to a global or through another register is cannot-measure.
for n in 0 1 10; do
  cc -DFORM="$n" "$FX/hoisted-entry.S" -o "$T/hoisted$n" -lobjc
  read_artifact "$T/hoisted$n"
  measured "hoisted entry point form $n"
  [ "$(count dispatch-call)" = 5 ] || fail "hoisted entry point form $n: $(count dispatch-call) sends, want 5"
  send _main classref:NSObject selref:description
  send _main classref:NSObject selref:hash
  [ "$(awk -F '\t' '$2 == "dispatch-call" {print $4}' "$T/out" | sort -u | wc -l | tr -d ' ')" = 5 ] || fail "hoisted entry point form $n: sends share a site"
done
for n in 2 3 4 5 6 7 8 9 11; do
  cc -DFORM="$n" "$FX/hoisted-entry.S" -o "$T/hoisted$n" -lobjc
  read_artifact "$T/hoisted$n"; refused "hoisted entry point form $n" indirect-objc-entry
done
# spec: tools/objc-compat/macho-reader.c header -- A landing pad the function's LSDA lists starts with the callee-saved registers,
#       frame slots and escapes of every call its call-site ranges cover (clang -O2 @try/@catch:
#       tests/fixtures/objc-api/landing-pad-entry.S), in both call-site encodings: an entry point held across the throwing
#       call is followed into the pad and where the pad rejoins; another value at that call, or a copy passed as an
#       argument in the pad, is cannot-measure.
for e in 1 3; do
  for n in 0 1; do
    cc -DFORM="$n" -DCSENC="$e" "$FX/landing-pad-entry.S" -o "$T/pad$e$n" -lobjc
    read_artifact "$T/pad$e$n"
    measured "landing pad form $n, call-site encoding $e"
    [ "$(count dispatch-call)" = 3 ] || fail "landing pad form $n, call-site encoding $e: $(count dispatch-call) sends, want 3"
    [ "$(sends_of selref:description | wc -l | tr -d ' ')" = 2 ] || fail "landing pad form $n, call-site encoding $e: the pad's own send is missing"
    send _main classref:NSObject selref:hash
  done
  for n in 2 3; do
    cc -DFORM="$n" -DCSENC="$e" "$FX/landing-pad-entry.S" -o "$T/pad$e$n" -lobjc
    read_artifact "$T/pad$e$n"; refused "landing pad form $n, call-site encoding $e" indirect-objc-entry
  done
done

# spec: tools/objc-compat/macho-reader.c header -- An inline jump table in __text that no data-in-code entry marks (Apple clang 6
#       -O0: tests/fixtures/objc-api/jump-table-entry.S) is data, and each case starts from the state at its jmp: an entry
#       point held in a register or spilled across the switch is followed into every case. A table its bound does not
#       match is not taken apart: its cases stay reached only indirectly, cannot-measure.
for n in 0 1; do
  cc -DFORM="$n" "$FX/jump-table-entry.S" -o "$T/table$n" -lobjc
  read_artifact "$T/table$n"
  measured "jump table form $n"
  [ "$(count dispatch-call)" = 4 ] || fail "jump table form $n: $(count dispatch-call) sends, want 4"
  [ "$(sends_of selref:hash | wc -l | tr -d ' ')" = 2 ] || fail "jump table form $n: the cases' sends are missing"
  grep '^limit	undecoded-bytes	0$' "$T/out" >/dev/null || fail "jump table form $n: the table was decoded as code"
done
cc -DFORM=2 "$FX/jump-table-entry.S" -o "$T/table2" -lobjc
read_artifact "$T/table2"; refused 'jump table form 2' indirect-objc-entry

# spec: tools/objc-compat/macho-reader.c header -- A selector reference spilled to a frame slot is followed to its reload
#       when the one store reaching every path is still there: the frame's escaped addresses are only an enumeration
#       state and buffer given to countByEnumeratingWithState:objects:count:, whose extents do not reach the slot
#       (Apple clang 21 -Os for-in loops: tests/fixtures/objc-api/spilled-selector.S). The slot's own address escaping,
#       a write that reaches it, another value on some path, any other escape of a frame address, or a stack write
#       through an rsp of unknown offset leaves the selector unknown -- in a provider body, cannot-measure.
unknown_sels() { awk -F '\t' '$2 == "dispatch-call" && $13 ~ /^unknown:/' "$T/out" | wc -l | tr -d ' '; }
cc -DFORM=0 "$FX/spilled-selector.S" -o "$T/spill0" -framework Foundation -lobjc
read_artifact "$T/spill0"
measured 'spilled selectors'
[ "$(count dispatch-call)" = 30 ] || fail "spilled selectors: $(count dispatch-call) sends, want 30"
[ "$(unknown_sels)" = 0 ] || fail "spilled selectors: $(unknown_sels) sends without their selector"
for sel in isFileURL addObject: absoluteString descriptorWithDescriptorType:data: numberOfItems insertDescriptor:atIndex: \
           descriptorWithString: appleEventWithEventClass:eventID:targetDescriptor:returnID:transactionID: setParamDescriptor:forKeyword:; do
  [ -n "$(sends_of "selref:$sel" | awk -F '\t' '$11 == "_url_events"')" ] || fail "spilled selectors: no _url_events send of $sel"
done
for form in 1:2 2:1 3:1 4:5 5:5 6:0; do
  n=${form%%:*} want=${form#*:}
  cc -DFORM="$n" "$FX/spilled-selector.S" -o "$T/spill$n" -framework Foundation -lobjc
  read_artifact "$T/spill$n"
  measured "spilled selectors form $n"
  [ "$(unknown_sels)" = "$want" ] || fail "spilled selectors form $n: $(unknown_sels) sends without their selector, want $want"
done
# spec: tools/objc-compat/macho-reader.c header -- A conventional frame is one where rbp is written only by its prologue and
#       restore: a bit test (bt) writes no register and keeps it; bts/btr on rbp do not. Clang 21 -Os code for Recaulk's
#       note_recent_files (tests/fixtures/objc-api/recents-loop.S) opens with one and calls through registers.
unknown_in() { awk -F '\t' -v fn="$1" '$2 == "dispatch-call" && $11 == fn && $13 ~ /^unknown:/' "$T/out" | wc -l | tr -d ' '; }
for form in 0:0 1:2 2:2; do
  n=${form%%:*} want=${form#*:}
  cc -DFORM="$n" "$FX/recents-loop.S" -o "$T/recents$n" -framework Foundation -framework CoreServices -lobjc
  read_artifact "$T/recents$n"
  measured "recents loop form $n"
  [ "$(unknown_in _note_recent_files)" = "$want" ] || fail "recents loop form $n: $(unknown_in _note_recent_files) sends without their selector, want $want"
done
read_artifact "$T/recents0"
for sel in isFileURL addObject:; do
  [ -n "$(sends_of "selref:$sel" | awk -F '\t' '$11 == "_note_recent_files"')" ] || fail "recents loop: no send of $sel"
done
# spec: tools/objc-compat/macho-reader.c header -- After a frame address escapes to a callee outside the enumeration contract,
#       a spilled selector's slot that lies wholly below the lowest such address stays known: the callee is assumed never
#       to write below what it was given, as for every other slot. An address derived from an escaped one, or one that
#       escapes other than to a call, keeps no slot (Recaulk workspace.m:129: tests/fixtures/objc-api/escaped-frame-slot.S).
for form in 0:0 1:2 2:1 3:2 4:2; do
  n=${form%%:*} want=${form#*:}
  cc -DFORM="$n" "$FX/escaped-frame-slot.S" -o "$T/escaped$n" -framework Foundation -lobjc
  read_artifact "$T/escaped$n"
  measured "escaped frame slot form $n"
  [ "$(unknown_in _target_loop)" = "$want" ] || fail "escaped frame slot form $n: $(unknown_in _target_loop) sends without their selector, want $want"
done
read_artifact "$T/escaped0"
for sel in objectAtIndex: setAttributeDescriptor:forKeyword:; do
  [ -n "$(sends_of "selref:$sel" | awk -F '\t' '$11 == "_target_loop"')" ] || fail "escaped frame slot: no send of $sel"
done
read_artifact "$T/escaped2"
[ -n "$(sends_of "selref:setAttributeDescriptor:forKeyword:" | awk -F '\t' '$11 == "_target_loop"')" ] ||
  fail 'escaped frame slot form 2: the slot below the escaped address lost its selector'
# spec: tools/objc-compat/macho-reader.c "Merged calls" -- a call a compiler merged from the sends of several paths is read
#       once per incoming path, when its block is entered by direct edges only and every path names its selector and
#       its receiver: one dispatch row per path, with that path's operands and, in column 16, the address of the
#       predecessor's last instruction (tests/fixtures/objc-api/merged-send.S). A path whose selector the reader does
#       not model keeps the one row with the meet's operands, its selector unknown; a call measured once has "-" there.
at() { b=$(nm "$art" | awk -v f="$1" '$3 == f {print $1}'); printf '0x%x' $((0x$b + $2)); }   # at FUNCTION OFFSET
# spec: tools/objc-compat/macho-reader.c "Merged calls" -- rows_at ADDRESS: "receiver selector incoming" of each dispatch row at ADDRESS.
rows_at() { awk -F '\t' -v a="$1" '$2 == "dispatch-call" && $4 == a {print $12, $13, $16}' "$T/out"; }
# spec: tools/objc-compat/macho-reader.c "Merged calls" -- row_is ADDRESS N PATTERN...: exactly N rows at ADDRESS, and each PATTERN (a shell pattern) matches one of them.
row_is() {
  ra=$1 rn=$2; shift 2
  rows_at "$ra" >"$T/rows"
  [ "$(grep -c . "$T/rows")" = "$rn" ] || fail "$art: $(grep -c . "$T/rows") dispatch rows at $ra, want $rn: $(cat "$T/rows")"
  for pat in "$@"; do
    hit=0
    while IFS= read -r line; do case "$line" in $pat) hit=1 ;; esac; done <"$T/rows"
    [ "$hit" = 1 ] || fail "$art: no dispatch row at $ra like '$pat': $(cat "$T/rows")"
  done
}
for n in 0 1 2 3; do
  art="$T/merged$n"
  cc -DFORM="$n" "$FX/merged-send.S" -o "$art" -framework Foundation -lobjc
  read_artifact "$art"
  measured "merged send form $n"
  case $n in
    0) row_is "$(at _merged 0x2e)" 2 "classref:*:NSArray selref:*:array $(at _merged 0x1b)" \
                                     "classref:*:NSArray selref:*:arrayWithObject: $(at _merged 0x24)"
       row_is "$(at _merged 0x3e)" 1 "result:$(at _merged 0x2e):- selref:*:count -" ;;
    1) row_is "$(at _merged 0x2e)" 1 "classref:*:NSArray unknown:* -" ;;
    2) row_is "$(at _merged 0x2e)" 2 "classref:*:NSArray selref:*:array $(at _merged 0x1b)" \
                                     "classref:*:NSDictionary selref:*:dictionary $(at _merged 0x24)" ;;
    3) row_is "$(at _merged 0x41)" 2 "result:$(at _merged 0x1b):- selref:*:count $(at _merged 0x21)" \
                                     "result:$(at _merged 0x31):- selref:*:count $(at _merged 0x31)" ;;
  esac
done
# spec: tests/fixtures/objc-api/open-urls-merge.S header -- open_urls_with_ops: the spilled selectors of lines 88, 63 and 65 are
#       followed; line 97's merged send is two, +[NSMutableDictionary dictionary] from +0x76e and -autorelease of the
#       mutableCopy result from +0x333; line 125's reload past escapes to callees, of frame addresses all above its slot, is
#       setAttributeDescriptor:forKeyword:, and no send is unknown but the merged one's own.
art="$T/openmerge"
cc "$FX/open-urls-merge.S" -o "$art" -framework AppKit -framework Foundation -lobjc
read_artifact "$art"
measured 'open_urls_with_ops'
for o in 0x254:isFileURL 0x566:raise:format: 0x6c6:raise:format:; do
  row_is "$(at _open_urls_with_ops "${o%%:*}")" 1 "* selref:*:${o#*:} -"
done
row_is "$(at _open_urls_with_ops 0x778)" 2 \
  "classref:*:NSMutableDictionary selref:*:dictionary $(at _open_urls_with_ops 0x76e)" \
  "result:$(at _open_urls_with_ops 0x323):- selref:*:autorelease $(at _open_urls_with_ops 0x333)"
row_is "$(at _open_urls_with_ops 0xa36)" 1 "* selref:*:setAttributeDescriptor:forKeyword: -"
[ "$(unknown_in _open_urls_with_ops)" = 0 ] || fail "open_urls_with_ops: $(unknown_in _open_urls_with_ops) sends without their selector, want 0"

# spec: scripts/objc-compat-build.sh header -- The analyzer needs neither the Command Line Tools nor git: it compiles with the
#       pinned clang22 package (components/objc-reference-clang/version) and takes Drydock from the pinned commit's tarball,
#       verified against ARCHIVE_SHA256 and extracted fresh and privately for every build, so a stale or edited tree is
#       never compiled. A 10.9 host without them is simulated: PATH holds only a wrapper directory whose git, clang, cc, ld,
#       xcrun and friends are stubs that record a call and fail, and, where sandbox-exec works, the real ones (and the
#       Command Line Tools and Xcode trees) cannot be executed at all. A missing prerequisite is cannot-measure, never a skip.
PIN="$ROOT/components/objc-reader-drydock/version"
DIGEST=$(sed -n 's/^DIGEST=//p' "$PIN")
ARCHIVE_SHA=$(sed -n 's/^ARCHIVE_SHA256=//p' "$PIN")
printf '%s\n' "$ARCHIVE_SHA" | grep -Eq '^[0-9a-f]{64}$' || fail 'the Drydock pin has no ARCHIVE_SHA256'
NOCL="$T/nocl"
mkdir -p "$NOCL/bin"
DENY='git clang clang++ cc c++ gcc g++ cpp ld as xcrun xcodebuild xcode-select make libtool lipo otool nm strip ar ranlib'
for d in /bin /usr/bin /usr/sbin; do
  for f in "$d"/*; do
    n=${f##*/}
    case " $DENY " in *" $n "*) continue ;; esac
    # platform: an exec stub, not a symlink: 10.9's shasum is a perl-version dispatcher that finds
    #           shasum5.16 beside its own $0.
    [ -e "$NOCL/bin/$n" ] || { printf '#!/bin/sh\nexec %s "$@"\n' "$f" >"$NOCL/bin/$n"; chmod +x "$NOCL/bin/$n"; }
  done
done
for n in $DENY; do
  printf '#!/bin/sh\necho "$0 $*" >>"%s"\nexit 127\n' "$NOCL/used" >"$NOCL/bin/$n"
  chmod +x "$NOCL/bin/$n"
done
PROFILE='(version 1)(allow default)(deny process-exec (literal "/usr/bin/git") (literal "/usr/bin/clang") (literal "/usr/bin/cc")
  (literal "/usr/bin/ld") (literal "/usr/bin/xcrun") (literal "/usr/bin/make") (subpath "/Library/Developer/CommandLineTools")
  (subpath "/Applications/Xcode.app"))'
# platform: sandbox-exec cannot nest inside another sandbox; then the PATH wrapper alone stands for the bare host.
if command -v sandbox-exec >/dev/null 2>&1 && sandbox-exec -p "$PROFILE" /bin/sh -c ':' 2>/dev/null; then
  bare() { sandbox-exec -p "$PROFILE" /usr/bin/env PATH="$NOCL/bin" "$@"; }
  how='PATH wrapper and sandbox'
else
  bare() { /usr/bin/env PATH="$NOCL/bin" "$@"; }
  how='PATH wrapper'
fi
# platform: MAVERGREEN_OBJC_COMPAT_CACHE is fresh, so this builds rather than reuses an analyzer; the extracted toolchain
#           under MAVERICKS_BUILD_ROOT is reused (2 GB, extracted once by objc-binding-test or the first build).
rc=0; bare MAVERGREEN_OBJC_COMPAT_CACHE="$NOCL/cache" sh "$ROOT/scripts/objc-compat-build.sh" --reader-driver "$NOCL/reader" 2>"$NOCL/err" || rc=$?
[ "$rc" = 0 ] && [ -x "$NOCL/reader" ] || { cat "$NOCL/err" >&2; fail "no-CLT build ($how): exit $rc"; }
[ ! -s "$NOCL/used" ] || fail "no-CLT build ($how) ran $(sort -u "$NOCL/used" | tr '\n' ' ')"
grep -F "toolchain clang22" "$NOCL/err" >/dev/null || fail "no-CLT build did not name the pinned toolchain: $(tail -1 "$NOCL/err")"
"$NOCL/reader" --artifact "$T/conventional" | grep '^evidence' >"$NOCL/conventional.ev"
"$T/reader" --artifact "$T/conventional" | grep '^evidence' >"$T/conventional.ev"
cmp -s "$NOCL/conventional.ev" "$T/conventional.ev" || fail 'the no-CLT reader reads differently'
id() { sed -n 's/.* source \([0-9a-f]*\) .*/\1/p' "$1" | tail -1; }
SRCKEY=$(id "$NOCL/err")
# spec: scripts/objc-compat-build.sh header -- each missing or failing prerequisite: exit 4, no output, the reason said.
prereq() {   # prereq LABEL PATTERN ENV...: the build with ENV fails 4 and says PATTERN
  label=$1 pat=$2; shift 2
  rm -f "$T/pre"; rc=0
  bare MAVERGREEN_OBJC_COMPAT_CACHE="$T/pre-cache" "$@" sh "$ROOT/scripts/objc-compat-build.sh" --reader-driver "$T/pre" 2>"$T/err" || rc=$?
  [ "$rc" = 4 ] && [ ! -e "$T/pre" ] || fail "$label: exit $rc, want 4 and no output"
  grep -E "$pat" "$T/err" >/dev/null || fail "$label: does not say '$pat': $(cat "$T/err")"
}
prereq 'a named toolchain that is not there' 'no bin/clang' MAVERGREEN_OBJC_CLANG_PREFIX="$T/no-clang"
mkdir -p "$T/no-releases"
prereq 'a toolchain that cannot be fetched' 'pinned toolchain' MAVERGREEN_OBJC_CLANG_PREFIX= MAVERICKS_BUILD_ROOT="$T/fresh-root" MAVERGREEN_RELEASES="file://$T/no-releases" \
  MAVERGREEN_PKG_CACHE="$T/no-pkgs"
mkdir -p "$T/sc" "$T/no-codeload"
src_cache=${MAVERICKS_SOURCE_CACHE:-$HOME/Library/Caches/mavericks-sources}
[ -f "$src_cache/drydock-$DIGEST.tar.gz" ] || fail "the verified Drydock tarball is not in $src_cache"
cp "$src_cache/drydock-$DIGEST.tar.gz" "$T/sc/" && printf 'x' | dd of="$T/sc/drydock-$DIGEST.tar.gz" bs=1 seek=100 conv=notrunc 2>/dev/null
prereq 'a Drydock tarball that is not the pinned one' 'Drydock' MAVERICKS_SOURCE_CACHE="$T/sc" MAVERICKS_CODELOAD="file://$T/no-codeload"
prereq 'no Drydock tarball to be had' 'Drydock' MAVERICKS_SOURCE_CACHE="$T/sc-empty" MAVERICKS_CODELOAD="file://$T/no-codeload"
prereq 'the retired source override' 'retired' MAVERGREEN_OBJC_READER_SRC="$T/dd"
prereq 'the retired repository override' 'retired' MAVERGREEN_OBJC_READER_DRYDOCK_REPO="$T/dd"
# spec: scripts/objc-compat-build.sh header -- a tree left where the git-era cache kept it, edited, is never read.
mkdir -p "$T/stale/src/drydock-$DIGEST/src"
printf '#error stale\n' >"$T/stale/src/drydock-$DIGEST/src/image.h"
PREFIX=$(sed -n 's/.* toolchain clang22[^ ]* [^ ]* at \([^,]*\),.*/\1/p' "$NOCL/err" | tail -1)
[ -x "$PREFIX/bin/clang" ] || fail "the build did not say where its toolchain is: $(tail -1 "$NOCL/err")"
rc=0; bare MAVERICKS_BUILD_ROOT="$T/stale" MAVERGREEN_OBJC_CLANG_PREFIX="$PREFIX" sh "$ROOT/scripts/objc-compat-build.sh" --reader-driver "$T/stale-reader" 2>"$T/err" || rc=$?
[ "$rc" = 0 ] || fail "a stale tree in the old cache place broke the build: $(tail -3 "$T/err")"
[ "$(id "$T/err")" = "$SRCKEY" ] || fail 'a stale tree in the old cache place changed the source identity'
[ -z "$(ls -A "$T/stale/src" | grep -v "^drydock-$DIGEST\$")" ] || fail "a build left its private Drydock tree behind: $(ls "$T/stale/src")"
echo "objc-reader: the analyzer builds with neither the Command Line Tools nor git ($how)"

# spec: tools/objc-compat/macho-reader.c header -- The real defective artifact, when the caller supplies it (never fetched, modified or run).
if [ -n "${MAVERGREEN_OBJC_CODEX_ARTIFACT:-}" ]; then
  sum=$(shasum -a 256 "$MAVERGREEN_OBJC_CODEX_ARTIFACT" | cut -d' ' -f1)
  [ "$sum" = 1d056b0d4ada3d74b4c0f4c5450bc06856bfdbc504320fa430a4249f640f6c40 ] || fail "unexpected Codex artifact $sum"
  read_artifact "$MAVERGREEN_OBJC_CODEX_ARTIFACT"
  measured codex-0.165.0
  [ "$(count sel-cache)" = 47 ] && [ "$(count class-cache)" = 11 ] || fail 'Codex cache statics miscounted'
  awk -F '\t' '($2 == "sel-cache" && $8 == "-") || ($2 == "class-cache" && $9 == "-")' "$T/out" | grep . >/dev/null &&
    fail 'a Codex cache without its name'
  has sel-cache 7="$OPEN"
  has sel-register 7=isVoiceOverEnabled 8=NSSelectorFromString
  has sel-register 7=accessibilityDisplayShouldReduceMotion 8=NSSelectorFromString
  # spec: tools/objc-compat/macho-reader.c header -- Task 1 Step 3 inventory: every send's selector from a named cache; receivers by measured form.
  [ "$(count sel-register)" = 4 ] && [ "$(count class-lookup)" = 2 ] && [ "$(count cache-fetch)" = 106 ] &&
    [ "$(count cache-use)" = 124 ] || fail 'Codex producer inventory changed'
  forms=$(awk -F '\t' '$2 == "dispatch-call" { split($12, r, ":"); split($13, s, ":"); print $9, r[1], s[1] }' "$T/out" | sort | uniq -c |
          awk '{ printf "%s %s %s %s;", $2, $3, $4, $1 }')
  [ "$forms" = 'objc_alloc class-cache none 6;objc_msgSend argument sel-cache 8;objc_msgSend class-cache sel-cache 13;objc_msgSend class-literal sel-cache 2;objc_msgSend result sel-cache 27;objc_msgSend unknown sel-cache 31;' ] ||
    fail "Codex dispatch operand forms changed: $forms"
  awk -F '\t' '$2 == "dispatch-call" && $13 ~ /^sel-cache:/ && $13 ~ /:-$/' "$T/out" | grep . >/dev/null && fail 'a Codex send with an unnamed selector cache'
  fed=$(awk -F '\t' '$2 == "dispatch-call" && $9 == "objc_msgSend" { split($13, s, ":"); print s[2] }' "$T/out" | sort -u | wc -l | tr -d ' ')
  [ "$fed" = 46 ] || fail "$fed selector caches feed sends, want 46 of 47"
  [ -z "$(sends_of sel-cache:init)" ] && [ "$(sends_of sel-cache:new | wc -l | tr -d ' ')" = 1 ] || fail 'Codex init/new sends changed'
  send __RNvNtNtCs2ucXwfqiSr7_5objc215___macro_helpers10null_error17create_null_error class-literal:NSString sel-cache:stringWithUTF8String:
  send __RNvNtNtCs2ucXwfqiSr7_5objc215___macro_helpers10null_error17create_null_error class-literal:NSError sel-cache:errorWithDomain:code:userInfo: result:-
  [ "$(sends_of sel-cache:respondsToSelector: | awk -F '\t' '{ print $14 }' | sed 's/:0x[0-9a-f]*:/:/' | sort | tr '\n' ' ')" = \
    'sel-nsstring:accessibilityDisplayShouldReduceMotion sel-nsstring:isVoiceOverEnabled ' ] || fail 'guard queries are not the respondsToSelector: arguments'
  echo "objc-reader: real Codex 0.165.0 artifact read ($(count cache-fetch) fetch sites, $(count cache-use) cache uses, $(count dispatch-call) dispatch calls)"
fi
echo 'objc-reader: conventional, objc2, plain, fat and cannot-measure fixtures pass'
