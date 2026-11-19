#!/bin/sh
# platform: macOS-only -- builds its Mach-O inputs with clang22 and its llvm-ar and llvm-libtool-darwin
#   usage: equivalence.sh inputs DIR                 build the Mach-O inputs into DIR (needs clang22)
#          equivalence.sh produce BINDIR INPUTS OUT  run BINDIR's drydock-macho-rewrite and wrappers over INPUTS, into OUT
#          equivalence.sh compare A B                every output in A is byte-identical to its namesake in B
set -eu
usage='usage: equivalence.sh inputs DIR | produce BINDIR INPUTS OUT | compare A B'
HERE=$(cd "$(dirname "$0")" && pwd)
fail() { echo "equivalence: $*" >&2; exit 1; }
sha() { shasum -a 256 < "$1" | cut -d' ' -f1; }

impl_source() {
  cat <<'EOF'
int foo(int x) { return x + 1; }
int bar(int x) { return foo(x) * 2; }
int baz(void) { return 7; }
EOF
}

chained_source() {
  cat <<'EOF'
#include <stdlib.h>
int g = 5;
int *rebased = &g;
void *(*bound)(size_t) = malloc;
int get(void) { return *rebased; }
EOF
}

user_source() {
  cat <<'EOF'
extern int foo(int);
int qux(int x) { return foo(x) + 3; }
EOF
}

# has_lc FILE CMD: FILE is a thin 64-bit Mach-O carrying load command CMD, walked from its header, not read from otool
has_lc() {
  u32() { od -An -tu4 -j "$2" -N 4 "$1" | tr -d ' '; }
  [ "$(u32 "$1" 0)" = $((0xfeedfacf)) ] || return 1
  n=$(u32 "$1" 16) off=32 i=0
  while [ "$i" -lt "$n" ]; do
    [ "$(u32 "$1" "$off")" = $(($2)) ] && return 0
    off=$((off + $(u32 "$1" $((off + 4))))) i=$((i + 1))
  done
  return 1
}
LC_DYLD_CHAINED_FIXUPS=0x80000034

build_inputs() {
  dir=$1
  [ ! -e "$dir" ] || fail "$dir already exists"
  ROOT=$(cd "$HERE/.." && pwd)
  . "$ROOT/tests/lib/toolchain.sh"
  mkdir -p "$dir"
  cp "$HERE/fixture.macho" "$dir/fixture.macho"
  impl_source > "$dir/impl.c"
  chained_source > "$dir/chained.c"
  user_source > "$dir/user.c"
  for s in impl user; do
    "$CC" -arch x86_64 -mmacosx-version-min=10.9 -O2 -c "$dir/$s.c" -o "$dir/$s.o" || fail "cannot compile $s.c"
  done
  "$CC" -arch x86_64 -mmacosx-version-min=10.9 -O2 -dynamiclib -install_name @rpath/libimpl.dylib \
    "$dir/impl.c" -o "$dir/libimpl.dylib" || fail "cannot link libimpl.dylib"
  "$CC_ARM64" -arch x86_64 -O2 -c "$dir/impl.c" -o "$dir/impl-fat.o" \
    || fail "cannot compile a universal impl.o"
  for a in x86_64 arm64; do
    case $a in x86_64) cc=$CC ;; arm64) cc=$CC_ARM64 ;; esac
    "$cc" -mmacosx-version-min=12.0 -Wl,-fixup_chains -O2 -dynamiclib -install_name @rpath/libchained.dylib \
      "$dir/chained.c" -o "$dir/chained-$a.dylib" || fail "cannot link chained-$a.dylib"
    has_lc "$dir/chained-$a.dylib" "$LC_DYLD_CHAINED_FIXUPS" \
      || fail "chained-$a.dylib carries no LC_DYLD_CHAINED_FIXUPS, so its rows would compare classic fixups"
  done
  ! has_lc "$dir/libimpl.dylib" "$LC_DYLD_CHAINED_FIXUPS" || fail "has_lc finds LC_DYLD_CHAINED_FIXUPS in a classic dylib"
  (cd "$dir" && "$AR" rcs libimpl-ar.a impl.o user.o) || fail "ar failed"
  (cd "$dir" && "$LIBTOOL" -static -o libimpl-libtool.a impl.o user.o) || fail "libtool failed"
  rm -f "$dir/impl.c" "$dir/user.c" "$dir/chained.c"
}

recaulk_script() {
  echo allow-unmatched
  for n in foo bar; do
    printf 'symbol rename _%s ___recaulk_impl_%s\n' "$n" "$n"
    printf 'symbol rename _%s.eh ___recaulk_impl_%s.eh\n' "$n" "$n"
  done
}

edit() {
  name=$1 input=$2
  printf '%s\n' "$3" > "$work/$name.script"
  rc=0
  (cd "$work" && "$bin/drydock-macho-rewrite" "$input" "$name.out" <"$name.script" >/dev/null 2>"$name.err") || rc=$?
  [ "$rc" -eq 0 ] || { cat "$work/$name.err" >&2; fail "$name: drydock-macho-rewrite exited $rc"; }
  ! cmp -s "$work/$input" "$work/$name.out" || fail "$name: the output is the input unchanged, which proves nothing"
  cp "$work/$name.out" "$out/$name"
  cases=$((cases + 1))
}

read_verb() {
  name=$1 verb=$2 input=$3
  rc=0
  (cd "$work" && "$bin/drydock-macho-rewrite" "$verb" "$input" >"$name.txt" 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || fail "$name: drydock-macho-rewrite $verb exited $rc"
  [ -s "$work/$name.txt" ] || fail "$name: drydock-macho-rewrite $verb printed nothing"
  cp "$work/$name.txt" "$out/$name"
  cases=$((cases + 1))
}

pipeline() {
  name=$1; shift
  cp "$work/fixture.macho" "$work/$name.in"
  (cd "$work" && "$bin/patch_macho" "$name.in" "$name.out" >/dev/null 2>&1) || fail "$name: patch_macho failed"
  (cd "$work" && "$bin/add_version_min" "$name.out" >/dev/null 2>&1) || fail "$name: add_version_min failed"
  (cd "$work" && "$bin/change_dylib" "$name.out" "$@" >/dev/null 2>&1) || fail "$name: change_dylib failed"
  ! cmp -s "$work/fixture.macho" "$work/$name.out" || fail "$name: the output is the input unchanged, which proves nothing"
  cp "$work/$name.out" "$out/$name"
  cases=$((cases + 1))
}

produce() {
  bin=$1 in=$2 out=$3
  [ -x "$bin/drydock-macho-rewrite" ] || fail "no $bin/drydock-macho-rewrite"
  [ -d "$in" ] || fail "no inputs at $in"
  [ ! -e "$out" ] || fail "$out already exists"
  for input in fixture.macho libimpl.dylib impl.o impl-fat.o user.o chained-x86_64.dylib chained-arm64.dylib libimpl-ar.a libimpl-libtool.a; do
    [ -f "$in/$input" ] || fail "no $input in $in"
  done
  bin=$(cd "$bin" && pwd)
  mkdir -p "$out"
  out=$(cd "$out" && pwd)
  work=$(mktemp -d "${TMPDIR:-/tmp}/equivalence.XXXXXX")
  trap 'rm -rf "$work"' EXIT
  cp "$in"/* "$work/"
  sha "$bin/drydock-macho-rewrite" > "$out/drydock.sha256"
  cases=0

  pipeline pipeline-installsh -strip-lc uuid -strip-lc codesig \
    -change /usr/lib/libSystem.B.dylib @loader_path/../S.dylib \
    -change /usr/lib/libicucore.A.dylib @loader_path/../I.dylib \
    -change /usr/lib/libc++.1.dylib @loader_path/../c++.1.dylib
  pipeline pipeline-insert -strip-lc uuid -strip-lc codesig \
    -change /usr/lib/libSystem.B.dylib @loader_path/../S.dylib \
    -insert @loader_path/libavxemu.dylib

  edit rpath-raise fixture.macho "rpath append @loader_path/$(printf '%03000d' 0)"
  edit rpath-append fixture.macho 'rpath append @executable_path/../lib'
  edit dylib-insert fixture.macho "$(printf 'dylib insert @loader_path/libx.dylib\nload-command delete uuid')"
  edit dylib-replace fixture.macho 'dylib replace /usr/lib/libSystem.B.dylib /usr/lib/libSystem.C.dylib'
  edit segment-rename fixture.macho 'segment rename __DATA __DATB'
  for v in info imports exports verify; do read_verb "fixture-$v" "$v" fixture.macho; done
  edit dylib-raise libimpl.dylib "rpath append @loader_path/$(printf '%04000d' 0)"
  for v in info exports verify; do read_verb "dylib-raise-$v" "$v" dylib-raise.out; done

  for a in x86_64 arm64; do
    edit chained-$a chained-$a.dylib 'fixups set classic'
    read_verb chained-$a-verify verify chained-$a.out
  done

  rs=$(recaulk_script)
  edit recaulk-impl.o impl.o "$rs"
  edit recaulk-user.o user.o "$rs"
  edit recaulk-impl-fat.o impl-fat.o "$rs"
  read_verb impl-fat-info info impl-fat.o
  edit recaulk-libimpl-ar.a libimpl-ar.a "$rs"
  edit recaulk-libimpl-libtool.a libimpl-libtool.a "$rs"

  echo "equivalence: $cases outputs of $bin/drydock-macho-rewrite ($(cat "$out/drydock.sha256")) in $out"
}

compare() {
  a=$1 b=$2
  [ -d "$a" ] && [ -d "$b" ] || fail "compare needs two output directories"
  a=$(cd "$a" && pwd) b=$(cd "$b" && pwd)
  [ "$a" != "$b" ] || fail "$a is compared with itself"
  [ -s "$a/drydock.sha256" ] && [ -s "$b/drydock.sha256" ] || fail "an output directory does not say which drydock-macho-rewrite made it"
  [ "$(cat "$a/drydock.sha256")" != "$(cat "$b/drydock.sha256")" ] \
    || fail "$a and $b were made by the same drydock-macho-rewrite binary"
  la=$(cd "$a" && ls | LC_ALL=C sort) lb=$(cd "$b" && ls | LC_ALL=C sort)
  [ "$la" = "$lb" ] || fail "the two directories hold different outputs: [$(echo $la)] and [$(echo $lb)]"
  n=0 bad=0
  for f in $la; do
    [ "$f" = drydock.sha256 ] && continue
    n=$((n + 1))
    if cmp "$a/$f" "$b/$f"; then
      echo "same $f $(sha "$a/$f")"
    else
      echo "DIFFERENT $f" >&2
      bad=$((bad + 1))
    fi
  done
  [ "$n" -ge 25 ] || fail "only $n outputs compared"
  [ "$bad" -eq 0 ] || fail "$bad of $n outputs differ between $a and $b"
  echo "equivalence: all $n outputs byte-identical ($a, $b)"
}

[ $# -ge 1 ] || { echo "$usage" >&2; exit 2; }
cmd=$1; shift
case "$cmd" in
  inputs) [ $# -eq 1 ] || { echo "$usage" >&2; exit 2; }; build_inputs "$1" ;;
  produce) [ $# -eq 3 ] || { echo "$usage" >&2; exit 2; }; produce "$1" "$2" "$3" ;;
  compare) [ $# -eq 2 ] || { echo "$usage" >&2; exit 2; }; compare "$1" "$2" ;;
  *) echo "$usage" >&2; exit 2 ;;
esac
