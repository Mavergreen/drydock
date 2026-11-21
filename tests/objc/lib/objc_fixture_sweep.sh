# platform: macOS-only -- the caller's pinned-SDK fxcc and clang22's $AR
# spec: tests/objc/fixtures/sweep-table.S header -- fixture_sweep DIR [VARIANT]: an image whose undecodable-bytes
#       sweep names a lazy pointer from bytes its archive member's assembler fixed, or with VARIANT (straddle, reloc,
#       same, relax) one of sweep-table.S's variants. The caller defines fxcc, FX and fail. It leaves
#       DIR/root/bin/sweep, its link map DIR/sweep.map, and DIR/obj/libsweep.a, a copy of the archive the map names
#       at DIR/link/libsweep.a, which is gone, as rustc's temporary copy is. SWEEP_WINDOW is the refused window's
#       address, SWEEP_TARGET what it names.
fixture_sweep() {
  D=$1; SWEEP_ASFLAGS=; SWEEP_LDFLAGS=
  mkdir -p "$D/root/bin" "$D/obj" "$D/link"
  fxcc -O1 -c "$FX/sweep-main.c" -o "$D/obj/main.o"
  case ${2:-} in
    '' | straddle)
      [ -z "${2:-}" ] || { SWEEP_ASFLAGS=-DSWEEP_STRADDLE; SWEEP_LDFLAGS='-Xlinker -no_function_starts'; }
      _sweep_link 0 "$D/sweep0.map"
      SWEEP_WINDOW=$(printf '0x%x' $(($(_sweep_addr "$D/sweep0.map" __text _sweep_fn) + 1)))
      SWEEP_TARGET=$(_sweep_addr "$D/sweep0.map" __la_symbol_ptr _method_getName)
      [ -n "$SWEEP_TARGET" ] && [ "$SWEEP_WINDOW" != 0x1 ] || fail "the sweep fixture's first link has no _sweep_fn or lazy pointer"
      _sweep_link "$((SWEEP_TARGET - SWEEP_WINDOW - 4))" "$D/sweep.map"
      # The table's value moves nothing: the second link is laid out as the first.
      cmp -s "$D/sweep0.map" "$D/sweep.map" || fail "the sweep fixture's layout moved between links" ;;
    reloc)
      SWEEP_ASFLAGS=-DSWEEP_RELOC; _sweep_link 0 "$D/sweep.map"
      SWEEP_WINDOW=$(printf '0x%x' $(($(_sweep_addr "$D/sweep.map" __text _sweep_fn) + 1)))
      SWEEP_TARGET=$(_sweep_addr "$D/sweep.map" __got 'non-lazy-pointer-to-local: _method_getName') ;;
    same)
      SWEEP_ASFLAGS=-DSWEEP_SAME; _sweep_link 0 "$D/sweep.map"
      SWEEP_WINDOW=$(printf '0x%x' $(($(_sweep_addr "$D/sweep.map" __text _sweep_fn) + 1)))
      SWEEP_TARGET=$(_sweep_addr "$D/sweep.map" __text __RNvMNtNtCs2ucXwfqiSr7_5objc215___macro_helpers5cacheNtB2_9CachedSel5fetch)
      [ "$((SWEEP_TARGET))" = "$((SWEEP_WINDOW + 4 + 11))" ] || fail "the same-section fixture's table does not name its fetch function" ;;
    relax)
      SWEEP_ASFLAGS=-DSWEEP_RELAX; _sweep_link 0 "$D/sweep.map"
      SWEEP_WINDOW=$(printf '0x%x' $(($(_sweep_addr "$D/sweep.map" __text _sweep_fn) + 2)))
      SWEEP_TARGET=$(_sweep_addr "$D/sweep.map" __stubs _method_getName)
      [ "$((SWEEP_TARGET))" = "$((SWEEP_WINDOW - 2 + 0x10594))" ] || fail "the relax fixture's stub is not where its window names"
      [ "$(_sweep_bytes "$D/root/bin/sweep" "$((SWEEP_WINDOW - 0x100000000))" 2)" = 8d05 ] || fail 'lld did not relax the GOT load to a leaq'
      [ "$(_sweep_bytes "$D/obj/sweep.o" "$(($("$OTOOL" -l "$D/obj/sweep.o" | awk '$1 == "offset" { print $2; exit }') + 2))" 2)" = 8b05 ] ||
        fail 'the relax fixture object does not hold a movq' ;;
    *) fail "no sweep fixture variant $2" ;;
  esac
  [ -n "$SWEEP_TARGET" ] || fail "the sweep fixture ${2:-} has no target"
  cp "$D/link/libsweep.a" "$D/obj/libsweep.a"
  rm -rf "$D/link"
}
# _sweep_link VALUE MAP: the archive at $D/link with SWEEP_VALUE=VALUE, and the image linked against it.
_sweep_link() {
  fxcc -c $SWEEP_ASFLAGS -DSWEEP_VALUE="$1" "$FX/sweep-table.S" -o "$D/obj/sweep.o"
  rm -f "$D/link/libsweep.a"
  "$AR" rc "$D/link/libsweep.a" "$D/obj/sweep.o"
  fxcc "$D/obj/main.o" "$D/link/libsweep.a" -lobjc $SWEEP_LDFLAGS -Xlinker -map -Xlinker "$2" -o "$D/root/bin/sweep"
}
# _sweep_bytes FILE OFFSET N: N bytes of FILE at OFFSET, as lowercase hex.
_sweep_bytes() { od -An -tx1 -j "$2" -N "$3" "$1" | tr -d ' \n'; }
# _sweep_addr MAP SECTION NAME: the address of the atom NAME the map places in SECTION, as 0x hex.
_sweep_addr() {
  _sect=$(awk -v sect="$2" '/^# Sections:/ { p = 1; next } /^# [A-Z].*:$/ { p = 0 } /^#/ { next } p && $4 == sect { print $1, $2 }' "$1")
  [ -n "$_sect" ] || return 0
  _lo=${_sect% *}; _hi=$((_lo + ${_sect#* }))
  awk -v name="$3" '/^# Symbols:/ { p = 1; next } /^# [A-Z].*:$/ { p = 0 } /^#/ { next } p { a = $1; sub(/^[^]]*\] /, ""); if ($0 == name) print a }' "$1" |
    while read -r _a; do
      if [ $((_a)) -ge $((_lo)) ] && [ $((_a)) -lt "$_hi" ]; then printf '0x%x\n' $((_a)); break; fi
    done
}
