# platform: macOS-only -- finds the codesign_allocate codesign itself would run: the developer tools xcode-select names.
# Sourced. codesign_allocate_path prints its path, or returns 1 where there is none, as on the 10.9 guest, whose
# /usr/bin/codesign_allocate is only a Command Line Tools stub.
codesign_allocate_path() {
    _ca_dev=$(xcode-select -p 2>/dev/null) && [ -n "$_ca_dev" ] || return 1
    for _ca in "$_ca_dev/usr/bin/codesign_allocate" "$_ca_dev/Toolchains/XcodeDefault.xctoolchain/usr/bin/codesign_allocate"; do
        [ -x "$_ca" ] && { printf '%s\n' "$_ca"; return 0; }
    done
    return 1
}
