# Semantic Objective-C SDK declarations (schema 1)

Generate declarations with a supplied libclang toolchain and pinned SDK:

```sh
sh scripts/objc-sdk-inventory.sh --clang-prefix "$CLANG_PREFIX" \
  --sdk "$SDKROOT" \
  --header "$SDKROOT/System/Library/Frameworks/AppKit.framework/Headers/AppKit.h"
```

Repeat `--header` to import additional files. Headers must be readable files, not framework
include spellings. The wrapper builds a temporary host executable below `MAVERICKS_BUILD_ROOT`
(default `${TMPDIR:-/tmp}/mm-build`) and removes it on exit. Its native compiler is
`/usr/bin/clang`, linked to the explicitly supplied prefix's libclang. The host build uses
shipyard's pinned host SDK: 10.9 for x86_64; 11.3 for arm64. The *parsed* target is always
x86_64-apple-macos10.9, including when running natively on Apple Silicon. Ambient compiler include
paths, `SDKROOT` and `CCC_OVERRIDE_OPTIONS` are cleared; they cannot silently change the measurement.

`tests/objc-sdk-inventory-test.sh` extracts the host package pinned by
`components/objc-reference-clang/version`, verifies its published checksums through
`fetch_product_pkg.sh --asset mavericks-clang-22-{native,cross}-VERSION.pkg`, and never installs it globally. An explicitly supplied
`MAVERGREEN_OBJC_CLANG_PREFIX` overrides extraction. A missing toolchain is a failure, not a skip.
The producer source and wrapper ship for explicit reference generation; libclang and a compiled
producer do not ship or become catalog-consumer runtime dependencies.

## Output

Success: exit 0, bytewise sorted, exact-duplicate-deduplicated TSV on stdout; no header row.
Version, SDK path and diagnostics go to stderr. So does one `objc-sdk-inventory: resource-header PATH` line per
compiler resource header the parse included (PATH relative to the resource directory), which
`scripts/objc-reference-set.sh` digests as the extractor identity. Usage errors exit 2. Cannot-measure exits 4,
including unreadable inputs, incomplete SDK/resource directories, parser errors and failures to
resolve category ownership or method encodings. All declarations are accumulated and validated
before any facts are emitted. A valid non-Objective-C header emits an empty successful result;
a failed parse never does. Consumers must check the exit status, including for output I/O failures.

The eleven columns are:

1. `record`: `class`, `category`, `method`, `property-get`, `property-set`, `protocol`,
   `protocol-method`, `protocol-property-get`, `protocol-property-set`, `conformance`, or
   `protocol-inherits`.
2. `framework`: innermost declaring `.framework` in the source path; `-` outside frameworks.
3. `owner`: class or protocol name. Category members use their semantic owning class, not the
   category's name or a coincidentally equal selector on another class.
4. `member_kind`: `+` for class methods/accessors; `-` for instance methods and non-method facts.
5. `name`: selector; superclass for `class` (`-` for roots); category name for `category`
   (`(extension)` for unnamed categories); referenced protocol for conformance/inheritance;
   `-` for protocol declarations.
6. `encoding`: libclang's x86_64 Objective-C method encoding, or `-` when not measured. Property
   declarations retain distinct accessor facts with unmeasured encodings, even when libclang
   also exposes corresponding implicit method declarations with measured encodings.
7. `introduced`: macOS version returned by libclang, or `-` when unmeasured.
8. `deprecated`: macOS deprecation version returned by libclang, or `-` when unmeasured. `-`
   does not establish that a declaration lacks an unversioned deprecation annotation.
9. `unavailable`: `1` for unconditional or macOS unavailability; `0` otherwise. Neither value
   attests that a declaration is implemented by an OS runtime.
10. `source`: canonical SDK-relative path plus physical line number; explicit headers outside
    the SDK use `input/<1-based-header-argument-index>:<line>`. No machine-specific absolute
    paths enter the TSV. A declaration outside both the SDK and the explicit header list fails
    measurement; supply such a dependency explicitly rather than silently importing host APIs.
11. `container`: `interface`, `category:<name>`, `protocol`, `protocol:optional`,
    `protocol:required`, or `-` for declaration facts without a member container. This retains
    category membership and required/optional protocol membership independently of API identity.

Class and member rows remain distinct. libclang's platform availability API can return an
owner's availability on its members and categories: these are semantic availability facts, not
a claim that each member has a physically written attribute. An inherited method is not copied
onto every subclass; the superclass relation is the evidence for later inheritance resolution.
Forward class/protocol references are not emitted as class/protocol declarations. Protocol
inheritance/conformance and protocol accessor facts are never implementation evidence.

## Limits

This is a declaration producer, not a runtime inventory, receiver resolver or artifact gate.
A later reference consumer must bind SDK archive/extractor identities to the catalog, combine it
with runtime/provider evidence, and evaluate coverage. A string match or declaration is not proof
that a binary sends a message, nor that a receiver implements it. No release policy is activated
by this tool.
