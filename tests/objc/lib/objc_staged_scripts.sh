# platform: host-agnostic
# Sourced by objc-binding, objc-reference-set, objc-sdk-inventory and objc-sdk-signatures; needs ROOT (this
# checkout) and SHIPYARD_SCRIPTS (build/msc.sh).
# spec: scripts/objc-reference-set.sh and scripts/objc-sdk-inventory.sh came from shipyard. The reference manifest
#       records objc-sdk-inventory.sh's SHA-256 (wrapper_sha256), so editing either means regenerating the reference
#       set. .superpowers/plans/2026-11-09-objc-compiled-reader.md (Tasks 1-2) edits both for --function-output and
#       regenerates the manifest. Both reach shipyard's
#       fetch_sdk.sh and sdk-pins.sh through their own directory, and tools/ and components/ through its parent, as
#       they did in shipyard. stage_objc_scripts DIR lays that tree out at DIR: DIR/scripts holds a link to every
#       entry of $SHIPYARD_SCRIPTS (fetch_sdk.sh and sdk-pins.sh, and what they source: mavericks_fetch.sh, ...)
#       and copies of the two scripts; DIR/tools and DIR/components link to this checkout's. It prints DIR/scripts.
stage_objc_scripts() {
  _st=$1
  mkdir -p "$_st/scripts" || return 1
  for _e in "$SHIPYARD_SCRIPTS"/*; do ln -s "$_e" "$_st/scripts/${_e##*/}" || return 1; done
  for _s in objc-reference-set.sh objc-sdk-inventory.sh; do
    rm -f "$_st/scripts/$_s"
    cp "$ROOT/scripts/$_s" "$_st/scripts/$_s" || return 1
  done
  ln -s "$ROOT/tools" "$_st/tools" && ln -s "$ROOT/components" "$_st/components" || return 1
  printf '%s\n' "$_st/scripts"
}
