#!/bin/sh
# platform: host-agnostic -- a directory of symlinks, made with ln -s.
#   usage: tool-dir.sh FARM TOOLDIR HELPER...
#          Makes FARM the bindir the suite is handed when DRYDOCK_TOOL_DIR is set: every entry of TOOLDIR (the
#          installed tools), plus each HELPER, a build-only fixture program the suites expect beside them.
set -u
FARM=${1:?usage: tool-dir.sh FARM TOOLDIR HELPER...}
TOOLDIR=${2:?usage: tool-dir.sh FARM TOOLDIR HELPER...}
shift 2
[ -x "$TOOLDIR/drydock-macho-rewrite" ] || { echo "tool-dir: $TOOLDIR has no drydock-macho-rewrite" >&2; exit 1; }
rm -rf "$FARM" && mkdir -p "$FARM" || exit 1
for f in "$TOOLDIR"/*; do ln -s "$f" "$FARM/${f##*/}" || exit 1; done
for h in "$@"; do
  [ -e "$FARM/${h##*/}" ] && { echo "tool-dir: $TOOLDIR already has ${h##*/}, so the build's would not be used" >&2; exit 1; }
  ln -s "$h" "$FARM/${h##*/}" || exit 1
done
echo "tool-dir: $FARM holds $TOOLDIR's tools and this build's $(for h in "$@"; do printf '%s ' "${h##*/}"; done)"
