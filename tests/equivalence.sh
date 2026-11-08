#!/bin/sh
# platform: macOS-only -- builds its Mach-O inputs with a Mac's clang, ar and libtool
#   usage: equivalence.sh inputs DIR                 build the Mach-O inputs into DIR (needs a Mac's clang, ar and libtool)
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

user_source() {
  cat <<'EOF'
extern int foo(int);
int qux(int x) { return foo(x) + 3; }
EOF
}

build_inputs() {
  dir=$1
  [ ! -e "$dir" ] || fail "$dir already exists"
  mkdir -p "$dir"
  cp "$HERE/fixture.macho" "$dir/fixture.macho"
  impl_source > "$dir/impl.c"
  user_source > "$dir/user.c"
  for s in impl user; do
    clang -arch x86_64 -mmacosx-version-min=10.9 -O2 -c "$dir/$s.c" -o "$dir/$s.o" || fail "cannot compile $s.c"
  done
  clang -arch x86_64 -mmacosx-version-min=10.9 -O2 -dynamiclib -install_name @rpath/libimpl.dylib \
    "$dir/impl.c" -o "$dir/libimpl.dylib" || fail "cannot link libimpl.dylib"
  clang -arch x86_64 -arch arm64 -mmacosx-version-min=11.0 -O2 -c "$dir/impl.c" -o "$dir/impl-fat.o" \
    || fail "cannot compile a universal impl.o"
  (cd "$dir" && ar rcs libimpl-ar.a impl.o user.o) || fail "ar failed"
  (cd "$dir" && /usr/bin/libtool -static -o libimpl-libtool.a impl.o user.o) || fail "libtool failed"
  rm -f "$dir/impl.c" "$dir/user.c"
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
  for input in fixture.macho libimpl.dylib impl.o impl-fat.o user.o libimpl-ar.a libimpl-libtool.a; do
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
  [ "$n" -ge 21 ] || fail "only $n outputs compared"
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
