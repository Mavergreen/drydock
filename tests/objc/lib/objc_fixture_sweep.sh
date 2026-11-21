# platform: macOS-only -- the caller's pinned-SDK fxcc and clang22's $AR
# spec: tests/objc/fixtures/sweep-table.S header -- fixture_sweep DIR: an image whose undecodable-bytes sweep
#       names a lazy pointer from bytes its archive member's assembler fixed. The caller defines fxcc, FX and fail.
#       It leaves DIR/root/bin/sweep, its link map DIR/sweep.map, and DIR/obj/libsweep.a, a copy of the archive
#       the map names at DIR/link/libsweep.a, which is gone, as rustc's temporary copy is. SWEEP_WINDOW is the
#       table's address (_sweep_fn + 1), SWEEP_TARGET the lazy pointer it names (rel32, tail 0).
fixture_sweep() {
  D=$1; shift
  mkdir -p "$D/root/bin" "$D/obj" "$D/link"
  fxcc -O1 -c "$FX/sweep-main.c" -o "$D/obj/main.o"
  _sweep_link 0 "$D/sweep0.map"
  SWEEP_WINDOW=$(printf '0x%x' $(($(_sweep_addr "$D/sweep0.map" __text _sweep_fn) + 1)))
  SWEEP_TARGET=$(_sweep_addr "$D/sweep0.map" __la_symbol_ptr _method_getName)
  [ -n "$SWEEP_TARGET" ] && [ "$SWEEP_WINDOW" != 0x1 ] || fail "the sweep fixture's first link has no _sweep_fn or lazy pointer"
  _sweep_link "$((SWEEP_TARGET - SWEEP_WINDOW - 4))" "$D/sweep.map"
  # The table's value moves nothing: the second link is laid out as the first.
  cmp -s "$D/sweep0.map" "$D/sweep.map" || fail "the sweep fixture's layout moved between links"
  cp "$D/link/libsweep.a" "$D/obj/libsweep.a"
  rm -rf "$D/link"
}
# _sweep_link VALUE MAP: the archive at $D/link with SWEEP_VALUE=VALUE, and the image linked against it.
_sweep_link() {
  fxcc -c -DSWEEP_VALUE="$1" "$FX/sweep-table.S" -o "$D/obj/sweep.o"
  rm -f "$D/link/libsweep.a"
  "$AR" rc "$D/link/libsweep.a" "$D/obj/sweep.o"
  fxcc "$D/obj/main.o" "$D/link/libsweep.a" -lobjc -Xlinker -map -Xlinker "$2" -o "$D/root/bin/sweep"
}
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
