# platform: host-agnostic -- $LIBTOOL, or llvm-ar where clang22 has none, and the caller's pinned-SDK fxcc
# spec: tests/objc/fixtures/provider-register.c header -- the fixture Objective-C provider, shared by
#       objc-provider-test.sh and objc-guard-test.sh; tests/lib/ is not itself run, since
#       run-repo-tests.sh takes top-level tests only. The caller defines fxcc (the pinned-SDK compiler),
#       sha (a file's SHA-256), SDK, FX (tests/objc/fixtures) and T (its scratch directory).
# platform: clang22's Linux archive has no llvm-libtool-darwin; llvm-ar writes the same Mach-O archive format.
# static_lib OUT OBJECT...: the archive of OBJECTs, by $LIBTOOL where it exists, else by $AR.
static_lib() {
  _out=$1; shift
  rm -f "$_out"
  if [ -x "$LIBTOOL" ]; then "$LIBTOOL" -static -o "$_out" "$@" 2>/dev/null
  else "$AR" --format=darwin rcs "$_out" "$@"; fi
}
# spec: tests/objc/fixtures/provider-register.c header -- fixture_prefix DIR [CC-FLAGS]: the fixture provider at
#       DIR, built with CC-FLAGS and declared as Recaulk's build declares its own.
fixture_prefix() {
  P=$1; shift
  mkdir -p "$P/lib" "$P/share/recaulk" "$P.objects"
  for m in provider-register provider-impl; do
    fxcc -Os -fPIC -Wall "$@" -c "$FX/$m.c" -o "$P.objects/$m.o"
  done
  static_lib "$P/lib/libfixture-objc.a" "$P.objects/provider-impl.o" "$P.objects/provider-register.o"
  printf '%s  provider-register.c\n%s  provider-impl.c\n' "$(sha "$FX/provider-register.c")" "$(sha "$FX/provider-impl.c")" >"$T/fixture-receipt"
  declare_prefix "$P" "$T/fixture-receipt"
}
# spec: tests/objc/fixtures/provider-register.c header -- declare_prefix DIR RECEIPT [EXTRA]: the declaration of DIR's archive,
#       whose prepared source RECEIPT (`SHA256  LABEL` lines) lists;
#       EXTRA, when given, is more provider entries (text starting with a comma) after the fixture's.
declare_prefix() {
  P=$1
  cat >"$P/share/recaulk/objc-providers.json" <<EOF
{
  "schema" : 1,
  "providers" : [
    {
      "provider_id" : "fixture.nsworkspace.open-urls.v1",
      "class" : "NSWorkspace",
      "method_kind" : "-",
      "selector" : "openURLs:withApplicationAtURL:options:configuration:error:",
      "encoding" : "@56@0:8@16@24Q32@40^@48",
      "implementation_symbol" : "__fixture_objc_workspace_open_urls",
      "activation_root" : "__fixture_objc_activate",
      "required_frameworks" : [
        "AppKit",
        "Carbon"
      ],
      "framework_policy" : "strong-linked-before-root"
    }${3:-}
  ],
  "build" : {
    "archive_path" : "lib/libfixture-objc.a",
    "archive_sha256" : "$(sha "$P/lib/libfixture-objc.a")",
    "architecture" : "x86_64",
    "artifact_role" : "shipping",
    "minimum_macos" : "10.9",
    "sdk_settings_sha256" : "$(sha "$SDK/SDKSettings.plist")",
    "compiler_identity" : "$("$CC" --version 2>&1 | head -1)",
    "source_inputs_receipt" : "$(sed 's/$/\\n/' "$2" | tr -d '\n')",
    "source_inputs_sha256" : "$(sha "$2")"
  }
}
EOF
}
