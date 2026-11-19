# platform: host-agnostic -- find, sed, readlink, shasum and sort, as 10.9, current macOS and Linux have them.
# Sourced. tree_digest DIR prints drydock-objc's source-tree digest of DIR, computed independently of it: every
# entry but .git, sorted bytewise, one line each.
tree_digest() {
  (cd "$1" && find . -mindepth 1 -name .git -prune -o -print | sed 's|^\./||' | while IFS= read -r p; do
    if [ -L "$p" ]; then printf 'l %s %s\n' "$p" "$(readlink "$p")"
    elif [ -d "$p" ]; then printf 'd %s\n' "$p"
    else printf 'f %s %s\n' "$p" "$(shasum -a 256 "$p" | cut -c1-64)"; fi
  done | LC_ALL=C sort | shasum -a 256 | cut -c1-64)
}
