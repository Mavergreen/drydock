#!/bin/sh
# tests/raise_runs_test.sh -- raised copies of 10.9's own libraries, loaded by
# 10.9's own programs, must do what the originals do.
#
#   sh tests/raise_runs_test.sh <bindir>
#
# Each library is copied, raised (LC_RPATHs past its pad, then deleted again),
# and put alone in a directory that DYLD_LIBRARY_PATH or DYLD_FRAMEWORK_PATH
# names (DYLD_INSERT_LIBRARIES for libgmalloc). Its program's stdout, stderr
# and exit status must equal its run against the original, and
# DYLD_PRINT_LIBRARIES must name the raised copy: dyld would otherwise take
# the shared cache's.
#
# Local only: it SKIPs, saying why, anywhere but Mac OS X 10.9.
set -u

BIN="${1:?usage: raise_runs_test.sh <bindir>}"
DMR="$BIN/drydock-macho-rewrite"
RC="$BIN/raise_corpus"
for x in "$DMR" "$RC"; do
    [ -x "$x" ] || { echo "raise_runs_test: $x not found or not executable" >&2; exit 1; }
done
case $(sw_vers -productVersion 2>/dev/null) in
    10.9|10.9.*) ;;
    *) echo "SKIP: these are 10.9's libraries and programs; this is not 10.9"; exit 77 ;;
esac
CXX=${CXX:-clang++}

T=$(mktemp -d "${TMPDIR:-/tmp}/raise-runs.XXXXXX") || exit 1
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT INT TERM

fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

mkdir "$T/in"
printf '<?xml version="1.0"?>\n<r><a x="1">one</a><b>two</b></r>\n' >"$T/in/doc.xml"
cat >"$T/in/p.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>k</key><array><integer>1</integer><string>s</string><real>2.5</real></array><key>t</key><true/></dict></plist>
EOF
awk 'BEGIN { for (i = 1; i <= 20000; i++) print i }' >"$T/in/nums"
cat >"$T/in/x.cc" <<'EOF'
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>
struct G { ~G() { std::puts("static destructor ran"); } } g;
int main() {
    std::vector<std::string> v;
    for (int i = 0; i < 3; i++) v.push_back(std::to_string(i * 7));
    try { throw std::runtime_error(std::string("thrown across ") + "libc++: " + v.back()); }
    catch (const std::exception &e) { std::printf("caught: %s\n", e.what()); }
    try { v.at(9); } catch (const std::out_of_range &) { std::puts("out_of_range caught"); }
    return 0;
}
EOF
"$CXX" -arch x86_64 -mmacosx-version-min=10.9 -stdlib=libc++ -O1 "$T/in/x.cc" -o "$T/in/xx" ||
    { echo "raise_runs_test: could not build the C++ driver" >&2; exit 1; }

# raise SRC DEST: a raised copy of SRC's x86_64 slice at DEST.
fill=$(printf '%0890d' 0)
raise() {
    mkdir -p "$(dirname "$2")"
    rm -f "$T/r.in" "$2"
    "$RC" thin "$1" "$T/r.in" || { bad "$1" "no x86_64 slice"; return 1; }
    info=$("$DMR" info "$T/r.in" 2>/dev/null)
    pad=$(printf '%s\n' "$info" | awk '/^header pad: / { print $3; exit }')
    n=$(( ${pad:-0} / 900 + 2 ))
    {
        printf '%s\n' "$info" | grep -q ' LC_CODE_SIGNATURE ' && echo 'load-command delete codesig'
        i=0; while [ "$i" -lt "$n" ]; do echo "rpath append /nonexistent/raise-$i/$fill"; i=$((i + 1)); done
        i=0; while [ "$i" -lt "$n" ]; do echo "rpath delete /nonexistent/raise-$i/$fill"; i=$((i + 1)); done
    } >"$T/edits"
    rc=0; "$DMR" "$T/r.in" "$2" <"$T/edits" >/dev/null 2>"$T/r.err" || rc=$?
    if [ "$rc" -eq 0 ] && grep -q "^$T/r.in: grew the header pad by .*; contents raised by 0x[0-9a-f]*; new UUID" "$T/r.err" &&
       "$DMR" verify "$2" >/dev/null 2>&1; then
        ok "$1: raised, announced and verified"
    else
        bad "$1" "exit $rc: $(grep -v '^  ' "$T/r.err" | head -3 | cut -c1-300)"
        return 1
    fi
}

# same NAME VAR DIR LOADED -- CMD...: CMD against the originals, then with
# VAR=DIR; the two runs' stdout, stderr and exit status must agree, and dyld
# must say it loaded LOADED. With $orig set, the first run has VAR=$orig. A
# process id is not output.
orig=
same() {
    name=$1 var=$2 dir=$3 loaded=$4; shift 5
    orc=0; grc=0
    if [ -n "$orig" ]; then
        env "$var=$orig" "$@" >"$T/$name.out" 2>"$T/$name.e" || orc=$?
    else
        "$@" >"$T/$name.out" 2>"$T/$name.e" || orc=$?
    fi
    env "$var=$dir" DYLD_PRINT_LIBRARIES=1 "$@" >"$T/$name.rout" 2>"$T/$name.re" || grc=$?
    pid='s/^\(GuardMalloc\[[^]]*-\)[0-9]*\]/\1PID]/'
    sed "$pid" "$T/$name.e" >"$T/$name.err"
    sed "/^dyld: loaded: /d; $pid" "$T/$name.re" >"$T/$name.rerr"
    if [ "$orc" -eq "$grc" ] && cmp -s "$T/$name.out" "$T/$name.rout" && cmp -s "$T/$name.err" "$T/$name.rerr"; then
        ok "$name: runs as against the original (exit $grc, $(wc -c <"$T/$name.rout" | tr -d ' ') bytes out)"
    else
        bad "$name" "exit $orc -> $grc; stdout $(cmp "$T/$name.out" "$T/$name.rout" 2>&1 | head -1); stderr $(diff "$T/$name.err" "$T/$name.rerr" | head -3 | tr '\n' ' ')"
    fi
    grep -qxF "dyld: loaded: $loaded" "$T/$name.re" &&
        ok "$name: ... and dyld loaded the raised copy" ||
        bad "$name" "dyld did not say it loaded $loaded"
}

L=$T/lib F=$T/fw
/usr/bin/gzip -9 -n -c "$T/in/nums" >"$T/in/nums.gz"
/usr/bin/bzip2 -9 -c "$T/in/nums" >"$T/in/nums.bz2"
(cd "$T/in" && /usr/bin/tar -cf "$T/in/in.tar" doc.xml nums)
if raise /usr/lib/libz.1.dylib "$L/z/libz.1.dylib"; then
    same gzip DYLD_LIBRARY_PATH "$L/z" "$L/z/libz.1.dylib" -- /usr/bin/gzip -9 -n -c "$T/in/nums"
    same gunzip DYLD_LIBRARY_PATH "$L/z" "$L/z/libz.1.dylib" -- /usr/bin/gzip -d -c "$T/in/nums.gz"
    cmp -s "$T/gunzip.rout" "$T/in/nums" && ok "gunzip: ... and the round trip gives back its input" ||
        bad "gunzip" "the round trip did not give back its input"
fi
raise /usr/lib/libxml2.2.dylib "$L/xml2/libxml2.2.dylib" &&
    same xmllint DYLD_LIBRARY_PATH "$L/xml2" "$L/xml2/libxml2.2.dylib" -- \
        /usr/bin/xmllint --format "$T/in/doc.xml"
raise /usr/lib/libsqlite3.dylib "$L/sqlite3/libsqlite3.dylib" &&
    same sqlite3 DYLD_LIBRARY_PATH "$L/sqlite3" "$L/sqlite3/libsqlite3.dylib" -- /usr/bin/sqlite3 :memory: \
        "create table t(x); insert into t values (6),(7); select sqlite_version(), x, (select sum(x) from t) from t;"
raise /usr/lib/libcurl.4.dylib "$L/curl/libcurl.4.dylib" &&
    same curl DYLD_LIBRARY_PATH "$L/curl" "$L/curl/libcurl.4.dylib" -- /usr/bin/curl -s "file://$T/in/doc.xml"
raise /usr/lib/libc++.1.dylib "$L/cxx/libc++.1.dylib" &&
    same c++ DYLD_LIBRARY_PATH "$L/cxx" "$L/cxx/libc++.1.dylib" -- "$T/in/xx"
CFV=CoreFoundation.framework/Versions/A/CoreFoundation
FV=Foundation.framework/Versions/C/Foundation
if raise "/System/Library/Frameworks/$CFV" "$F/$CFV" && raise "/System/Library/Frameworks/$FV" "$F/$FV"; then
    same plutil-xml DYLD_FRAMEWORK_PATH "$F" "$F/$CFV" -- /usr/bin/plutil -convert xml1 -o - "$T/in/p.plist"
    same plutil-json DYLD_FRAMEWORK_PATH "$F" "$F/$FV" -- /usr/bin/plutil -convert json -o - "$T/in/p.plist"
fi
if raise /usr/lib/libarchive.2.dylib "$L/archive/libarchive.2.dylib"; then
    same tar DYLD_LIBRARY_PATH "$L/archive" "$L/archive/libarchive.2.dylib" -- /usr/bin/tar -cf - -C "$T/in" doc.xml nums
    same untar DYLD_LIBRARY_PATH "$L/archive" "$L/archive/libarchive.2.dylib" -- /usr/bin/tar -xOf "$T/in/in.tar" nums
    cmp -s "$T/untar.rout" "$T/in/nums" && ok "untar: ... and the round trip gives back its input" ||
        bad "untar" "the round trip did not give back its input"
fi
if raise /usr/lib/libbz2.1.0.dylib "$L/bz2/libbz2.1.0.dylib"; then
    same bzip2 DYLD_LIBRARY_PATH "$L/bz2" "$L/bz2/libbz2.1.0.dylib" -- /usr/bin/bzip2 -9 -c "$T/in/nums"
    same bunzip2 DYLD_LIBRARY_PATH "$L/bz2" "$L/bz2/libbz2.1.0.dylib" -- /usr/bin/bzip2 -d -c "$T/in/nums.bz2"
    cmp -s "$T/bunzip2.rout" "$T/in/nums" && ok "bunzip2: ... and the round trip gives back its input" ||
        bad "bunzip2" "the round trip did not give back its input"
fi
if raise /usr/lib/libgmalloc.B.dylib "$L/gmalloc/libgmalloc.dylib"; then
    orig=/usr/lib/libgmalloc.B.dylib
    same gmalloc DYLD_INSERT_LIBRARIES "$L/gmalloc/libgmalloc.dylib" "$L/gmalloc/libgmalloc.dylib" -- \
        /usr/bin/sort -n -r "$T/in/nums"
    orig=
fi

# The positive control: with the library's directory not named, dyld does not
# load the copy, and the check above says so.
env DYLD_LIBRARY_PATH="$T/nowhere" DYLD_PRINT_LIBRARIES=1 /usr/bin/gzip -c "$T/in/doc.xml" >/dev/null 2>"$T/ctl"
if grep -qxF "dyld: loaded: $L/z/libz.1.dylib" "$T/ctl"; then
    bad "the positive control" "dyld named the raised libz with its directory not on DYLD_LIBRARY_PATH"
elif grep -qxF "dyld: loaded: /usr/lib/libz.1.dylib" "$T/ctl"; then
    ok "the positive control: without its directory, dyld loads /usr/lib's libz, not the copy"
else
    bad "the positive control" "dyld named no libz at all: $(head -3 "$T/ctl" | tr '\n' ' ')"
fi

[ "$fail" -eq 0 ] || { echo "raise_runs_test: $fail failure(s)"; exit 1; }
echo "raise_runs_test: all passed"
