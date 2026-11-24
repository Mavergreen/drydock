#!/bin/sh
# platform: macOS-only -- reads OS X 10.9's own framework binaries, so it refuses every other host
#   usage: resources-keys.sh LABEL=NIB...
#          Writes keys-10.9.tsv on stdout: one row per class and key the seeding nibs carry, as
#          CLASS<TAB>KEY<TAB>STATUS<TAB>PROVENANCE, sorted bytewise. STATUS is "ignored" for keys 10.9 has no use
#          for (IB-only keys, NIBArchive-only keys, the V2 constraint duplicates, the NSControl keys 10.9 reads
#          from the cell), else "read" when the key string is in AppKit, Foundation, CoreFoundation or
#          PreferencePanes. PROVENANCE is the reason and the seeds (s1,s2,...) that carried the key. A key that is
#          neither is left out, so drydock-resources check reports it, and is listed on stderr.
#          LABEL names a seed and its version, e.g. macFUSE-5.5.0/MFPreferencePane.nib; the header records each
#          seed's label and sha256. NIB is a NIBArchive or keyed nib file, or a nib directory. DRYDOCK_RESOURCES
#          names the drydock-resources to dump with (default: the one on PATH). Exit 0; 1 not OS X 10.9, or a
#          nib or framework that cannot be read; 2 usage.
set -u
LC_ALL=C; export LC_ALL
me=resources-keys.sh
version=${DRYDOCK_RESOURCES_KEYS_TEST_HOST_VERSION:-$(sw_vers -productVersion 2>/dev/null)}
case "$version" in
  10.9|10.9.*) ;;
  *) echo "$me: needs OS X 10.9's frameworks, and this host is ${version:-not OS X}" >&2; exit 1 ;;
esac
[ $# -ge 1 ] || { echo "usage: $me LABEL=NIB..." >&2; exit 2; }
for a in "$@"; do
  case "$a" in ?*=?*) ;; *) echo "usage: $me LABEL=NIB... ('$a' has no LABEL=)" >&2; exit 2 ;; esac
done
R=${DRYDOCK_RESOURCES:-drydock-resources}
T=$(mktemp -d "${TMPDIR:-/tmp}/resources-keys.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT

: > "$T/strings"
for fw in AppKit Foundation CoreFoundation PreferencePanes; do
  bin=/System/Library/Frameworks/$fw.framework/$fw
  [ -r "$bin" ] || { echo "$me: cannot read $bin" >&2; exit 1; }
  strings -a "$bin" | sed "s/\$/	$fw/" >> "$T/strings" || { echo "$me: strings $bin failed" >&2; exit 1; }
done
sort -t '	' -k1,1 -k2,2 "$T/strings" | awk -F '\t' '!seen[$1]++' > "$T/found"

: > "$T/pairs"
: > "$T/seeds"
i=0
for a in "$@"; do
  i=$((i + 1))
  label=${a%%=*} nib=${a#*=}
  file=$nib
  [ -d "$nib" ] && file=$nib/keyedobjects.nib
  sum=$(shasum -a 256 "$file" 2>/dev/null | cut -d' ' -f1)
  [ -n "$sum" ] || { echo "$me: cannot read $file" >&2; exit 1; }
  printf '# seed s%d %s sha256 %s\n' "$i" "$label" "$sum" >> "$T/seeds"
  "$R" dump "$nib" > "$T/dump" 2>"$T/err" || { echo "$me: $nib: $(cat "$T/err")" >&2; exit 1; }
  awk -v seed="s$i" '
    /^@[0-9]+ / { cls = $2; skip = ($3 == "bare") || (substr(cls, 1, 1) == "\""); next }
    /^  [^ ]/ && !skip {
      key = $1
      if (substr(key, 1, 1) == "\"") { print "quoted key skipped: " cls " " key > "/dev/stderr"; next }
      print cls "\t" key "\t" seed
    }' "$T/dump" >> "$T/pairs"
done

sort -u "$T/pairs" | sort -t '	' -k1,1 -k2,2 -k3.2n | awk -F '\t' -v found="$T/found" '
  BEGIN {
    while ((getline line < found) > 0) { split(line, f, "\t"); fw[f[1]] = f[2] }
    split("UINibEncoderEmptyKey NSInlinedValue", a, " "); for (k in a) why[a[k]] = "nibarchive-only"
    split("NSConstantV2 NSFirstAttributeV2 NSSecondAttributeV2", a, " "); for (k in a) why[a[k]] = "v2-duplicate"
    split("NSControlSize NSControlContinuous NSControlRefusesFirstResponder NSControlUsesSingleLineMode " \
          "NSControlTextAlignment NSControlLineBreakMode NSControlWritingDirection NSControlSendActionMask " \
          "NSControlBorderShape", a, " ")
    for (k in a) why[a[k]] = "read-from-cell"
  }
  {
    id = $1 "\t" $2
    if (!(id in seeds)) { order[++n] = id; seeds[id] = $3 } else seeds[id] = seeds[id] "," $3
  }
  END {
    for (i = 1; i <= n; i++) {
      id = order[i]; split(id, p, "\t"); key = p[2]
      if (key in why) print id "\tignored\t" why[key] ":" seeds[id]
      else if (key in fw) print id "\tread\t" fw[key] ":" seeds[id]
      else if (substr(key, 1, 2) == "IB") print id "\tignored\tib-only:" seeds[id]
      else print "not in 10.9: " p[1] " " key > "/dev/stderr"
    }
  }' > "$T/rows"

echo "# resources-keys 1"
echo "# class	key	status	provenance (reason:seeds), from scripts/resources-keys.sh on OS X $version"
cat "$T/seeds"
sort "$T/rows"
