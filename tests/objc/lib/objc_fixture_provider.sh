# platform: macOS-only -- libtool and the caller's pinned-SDK cc
# spec: tests/fixtures/objc-api/provider-register.c header -- the fixture Objective-C provider, shared by
#       objc-provider-test.sh and objc-guard-test.sh; tests/lib/ is not itself run, since
#       run-repo-tests.sh takes top-level tests only. The caller defines cc (the pinned-SDK compiler),
#       sha (a file's SHA-256), SDK, FX (tests/fixtures/objc-api) and T (its scratch directory).
# spec: tests/fixtures/objc-api/provider-register.c header -- fixture_prefix DIR [CC-FLAGS]: the fixture provider at
#       DIR, built with CC-FLAGS and declared as Recaulk's build declares its own.
fixture_prefix() {
  P=$1; shift
  mkdir -p "$P/lib" "$P/share/recaulk" "$P.objects"
  for m in provider-register provider-impl; do
    cc -Os -fPIC -Wall "$@" -c "$FX/$m.c" -o "$P.objects/$m.o"
  done
  /usr/bin/libtool -static -o "$P/lib/libfixture-objc.a" "$P.objects/provider-impl.o" "$P.objects/provider-register.o" 2>/dev/null
  printf '%s  provider-register.c\n%s  provider-impl.c\n' "$(sha "$FX/provider-register.c")" "$(sha "$FX/provider-impl.c")" >"$T/fixture-receipt"
  declare_prefix "$P" "$T/fixture-receipt"
}
# spec: tests/fixtures/objc-api/provider-register.c header -- declare_prefix DIR RECEIPT: the declaration of DIR's archive,
#       whose prepared source RECEIPT (`SHA256  LABEL` lines) lists.
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
    }
  ],
  "build" : {
    "archive_path" : "lib/libfixture-objc.a",
    "archive_sha256" : "$(sha "$P/lib/libfixture-objc.a")",
    "architecture" : "x86_64",
    "artifact_role" : "shipping",
    "minimum_macos" : "10.9",
    "sdk_settings_sha256" : "$(sha "$SDK/SDKSettings.plist")",
    "compiler_identity" : "$(/usr/bin/clang --version 2>&1 | head -1)",
    "source_inputs_receipt" : "$(sed 's/$/\\n/' "$2" | tr -d '\n')",
    "source_inputs_sha256" : "$(sha "$2")"
  }
}
EOF
}
