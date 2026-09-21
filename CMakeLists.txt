cmake_minimum_required(VERSION 3.16)

# These tools RUN on 10.9 -- they are the thing being ported, not a cross-built
# artifact -- so the deployment target and architecture are the product, not a
# packaging detail.
set(CMAKE_OSX_DEPLOYMENT_TARGET 10.9 CACHE STRING "runs on 10.9")
set(CMAKE_OSX_ARCHITECTURES x86_64 CACHE STRING "Intel-only (10.9)")

# Versioning: this repo is its OWN upstream -- but not in mavericks-ed25519's
# sense. ed25519 is a PORT: date-versioned, `<date>-mavericks.N`, where the
# -mavericks.N counts this family's repackagings of someone else's ed25519
# release. This repo has no someone-else -- the thing it exists to port is
# itself -- so there is no external upstream to repackage and no -mavericks.N
# axis to carry. The right analogue is mavericks-porthole: a self-upstream repo
# drops the -mavericks suffix and versions itself directly. UPSTREAM_VERSION
# stays as the family's usual file, holding this repo's own version, bumped by
# hand; no Renovate customManager watches it, because nothing external releases
# and bumps it.
#
# Semver (X.Y.Z), not a date: this product's user-visible surface is a CLI
# grammar that consumers probe -- `--capabilities` exists precisely so a wrapper
# and the tool need not move in lockstep -- and that grammar is about to change
# materially. A date says when; semver says whether your script still runs.
#
# Read from the file rather than duplicated here: the conventions gate requires a
# computable version, and two declarations would be one too many.
file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/UPSTREAM_VERSION" MAVERICKS_VERSION LIMIT_COUNT 1)
string(REGEX MATCH "^[0-9]+\\.[0-9]+\\.[0-9]+" MAVERICKS_VERSION_NUMERIC "${MAVERICKS_VERSION}")

project(MachOTools VERSION ${MAVERICKS_VERSION_NUMERIC} LANGUAGES C)

# MavericksShipyard, not MavericksSharedCMake: shipyard ships
# MavericksShipyardConfig.cmake, and the family is mid-rename (six local repos
# still ask for the old name, six for the new). New repos take the new one.
find_package(MavericksShipyard REQUIRED)
include(Mavericks)             # AppleClang gate + build conventions
include(MavericksMode)         # native-on-10.9 vs cross-on-modern
include(MavericksCompatGuard)  # assert every shipped binary is 10.9-safe

mavericks_build_mode(MAVERICKS_MODE)
mavericks_require_expected_mode("${MAVERICKS_MODE}")
message(STATUS "macho-tools ${MAVERICKS_VERSION}: build mode ${MAVERICKS_MODE}")

# Cross builds compile against the PINNED 10.9 SDK, not the host's. Building
# with a modern SDK and only -mmacosx-version-min=10.9 is weaker: the compiler
# would happily accept declarations 10.9's headers never had, and the first
# symptom would be a link or load failure on the target. Native builds already
# have the right headers, so they need nothing.
if(MAVERICKS_MODE STREQUAL "cross")
  mavericks_fetch_sdk(MAVERICKS_SDK)
  set(CMAKE_OSX_SYSROOT "${MAVERICKS_SDK}" CACHE PATH "pinned 10.9 SDK" FORCE)
  message(STATUS "macho-tools: cross build against ${MAVERICKS_SDK}")
endif()

# No -std=: src/declassify.c (patch_macho's conversion) assigns to an anonymous struct, which clang rejects under -std=c11 and accepts
# in its default gnu dialect. Verified across all six.
set(CMAKE_C_STANDARD_REQUIRED OFF)

# The toolkit library the seven rewriters were converged onto (docs/PROPOSAL.md
# "Shape").
#
# Target name is machorewritecore, not machorewrite, so it does not collide with
# the `machorewrite` CLI executable's target. It is deliberately NOT linked
# into every tool: only what actually includes a header from src/ links it, so
# a tool that gains a dependency does so visibly, in this file.
add_library(machorewritecore STATIC src/uleb.c src/image.c src/ordinals.c src/fat.c src/trie.c src/lc_kinds.c src/atomic_write.c src/linkedit.c src/grow.c src/rewrite.c src/version_min.c src/segname.c src/swift_retag.c src/declassify.c src/script.c src/edit.c src/arch_names.c src/relations.c src/imports.c)
target_include_directories(machorewritecore PUBLIC src)
target_compile_options(machorewritecore PRIVATE -O2 -Wall)

# ALL SIX historical tools are now /bin/sh WRAPPERS around machorewrite. Each keeps its original installed name, because
# mavericksforever.com/claude/install.sh fetches patch_macho, change_dylib and
# add_version_min BY THOSE NAMES -- the wrappers are drop-in, and
# compat/<tool>.sh's own header says how each one maps that tool's grammar,
# its exit codes and its stdout onto machorewrite's.
#
# fix_macho was the holdout: it could not be wrapped while a wrapper had to
# PRESERVE its behaviour, because `machorewrite dylib` rewrites a longer path using
# header pad where fix_macho refused outright, and a chained -rename_seg
# chains where fix_macho's single pass did not. The repo owner ruled those --
# and three more -- improvements to ADOPT deliberately, which is what made
# this possible; compat/README.md's "fix_macho: the adopted divergences" table
# states all five with their reasons and the test holding each.
#
# So machorewrite is now the ONLY Mach-O rewriting binary this repo builds or
# installs, and compat/ contains no C at all. MACHO_TOOLS is deliberately
# still here, empty: it is the list a future compiled compat tool would join,
# and its emptiness is the measurable form of "the goal is met".
#
# insert_dylib is the ONE NAME below that is not one of the six: it wraps a
# grammar this repo never shipped (Wowfunhappy/insert_dylib), staged the same
# way for the same reason -- convenience, not compatibility debt.
# compat/insert_dylib.sh's own header says more.
set(MACHO_WRAPPERS
  patch_macho
  change_dylib
  add_version_min
  rename_segment
  retag_swift_classes
  fix_macho
  insert_dylib)

set(MACHO_TOOLS)

foreach(tool IN LISTS MACHO_TOOLS)
  add_executable(${tool} compat/${tool}.c)
  target_compile_options(${tool} PRIVATE -O2 -Wall)
  target_link_libraries(${tool} PRIVATE machorewritecore)
  # The compat guard is the in-CI equivalence proof: no 10.9 runner validates
  # these, so the build fails if a binary declares a floor above 10.9 or links a
  # symbol 10.9 lacks. It matters more here than in most of the family, because
  # these tools are themselves what makes other binaries loadable on 10.9.
  mavericks_assert_binary_compatible(${tool})
endforeach()

# The CLI: everything it does delegates in-process to machorewritecore. The
# rewrites once ran as SUBPROCESSES (change_dylib / add_version_min next to
# machorewrite), which made machorewrite depend at runtime on the very binaries
# it is meant to replace; now the callers share the code instead. Kept
# out of the ${tool}.c-named foreach above because its source lives in cli/. No
# root include path is needed: every header it includes now lives in src/,
# reached via machorewritecore's PUBLIC src include (below), same as every other tool.
add_executable(machorewrite cli/machorewrite.c)
target_compile_options(machorewrite PRIVATE -O2 -Wall)
target_link_libraries(machorewrite PRIVATE machorewritecore)
mavericks_assert_binary_compatible(machorewrite)

# Stage the wrappers and the two files they source NEXT TO machorewrite in the build
# tree, under their installed names, so ctest exercises exactly the layout
# that ships -- a wrapper looks for machorewrite, machorewrite-compat.sh and
# machorewrite-translate.sh in its own directory. $<TARGET_FILE_DIR:machorewrite> rather
# than CMAKE_CURRENT_BINARY_DIR so this holds for a multi-config generator
# too, and a plain ALL target rather than OUTPUT rules because a generator
# expression in an OUTPUT needs CMake 3.20 and this project asks for 3.16.
# copy_if_different keeps the per-build cost to eight stat calls (six
# wrappers plus the two files they source).
#
# translate.sh is the one file renamed on the way out: a bin directory full of
# tools should not gain a file called `translate.sh`. Nothing else about it
# changes, and compat/machorewrite-compat.sh is what knows the installed name.
add_custom_target(compat_wrappers ALL
  COMMENT "staging the compat wrappers next to machorewrite")
add_dependencies(compat_wrappers machorewrite)
foreach(tool IN LISTS MACHO_WRAPPERS)
  add_custom_command(TARGET compat_wrappers POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${CMAKE_CURRENT_SOURCE_DIR}/compat/${tool}.sh"
            "$<TARGET_FILE_DIR:machorewrite>/${tool}")
endforeach()
add_custom_command(TARGET compat_wrappers POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
          "${CMAKE_CURRENT_SOURCE_DIR}/compat/machorewrite-compat.sh"
          "$<TARGET_FILE_DIR:machorewrite>/machorewrite-compat.sh")
add_custom_command(TARGET compat_wrappers POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
          "${CMAKE_CURRENT_SOURCE_DIR}/compat/translate.sh"
          "$<TARGET_FILE_DIR:machorewrite>/machorewrite-translate.sh")

# ${MACHO_TOOLS} is empty now that fix_macho is a wrapper, so this installs
# machorewrite and nothing else. It is left expanded rather than deleted for the
# same reason the empty list above is: a future compiled compat tool joins
# that list and needs no change here.
install(TARGETS ${MACHO_TOOLS} machorewrite RUNTIME DESTINATION bin)

# The wrappers install under the historical binaries' exact names, into the
# same directory as machorewrite -- that co-location is how each one finds machorewrite
# and its two support files at run time.
foreach(tool IN LISTS MACHO_WRAPPERS)
  install(PROGRAMS "compat/${tool}.sh" DESTINATION bin RENAME "${tool}")
endforeach()
install(PROGRAMS "compat/machorewrite-compat.sh" DESTINATION bin)
install(PROGRAMS "compat/translate.sh" DESTINATION bin RENAME machorewrite-translate.sh)

enable_testing()

# Hermetic: the grow, every base-relative re-baser, mg_verify and mg_plausible,
# against synthetic images built in memory. -Wno-unused-function because
# src/grow.h declares helpers this translation unit does not all call.
add_executable(grow_test tests/grow_test.c)
# -Wall deploys lesson nine's detection net (tests/README.md): a
# -Wfortify-source "will always overflow" diagnostic on a strcpy into a
# char[16] segname/sectname fires here at COMPILE time, on any host, well
# before a modern-clang runner would abort at RUNTIME building the same
# fixture -- and this file holds the fixture builders. It was missing
# -Wall entirely (silent since c06bdce first added this target); adding it
# used to produce exactly one warning, unrelated to this file: a `static`
# mg_trie_scan defined inside header-only macho_grow.h, included into
# multiple translation units, tripped -Wunneeded-internal-declaration. Task
# 3's move to src/grow.c gave every one of these functions external linkage,
# which is exactly what that warning was asking for -- it is gone now, not
# suppressed. -Wno-unused-function stays: src/grow.h declares helpers this
# translation unit does not all use.
target_compile_options(grow_test PRIVATE -O2 -Wall -Wno-unused-function)
target_link_libraries(grow_test PRIVATE machorewritecore)
add_test(NAME grow_test COMMAND grow_test)

# Reads tests/fixture.macho, a real 10.9-built executable, so the walk is
# exercised against a binary a linker actually emitted rather than one this test
# invented. WORKING_DIRECTORY is the source dir because the fixture path is
# relative. (change_dylib_test.sh, below, needs no WORKING_DIRECTORY of its
# own: it `cd`s to its own directory itself, the way every sh-based test here
# does.)
add_executable(image_test tests/image_test.c)
target_compile_options(image_test PRIVATE -O2 -Wall)
target_link_libraries(image_test PRIVATE machorewritecore)
add_test(NAME image_test COMMAND image_test
  WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}")

# Hermetic tests for src/trie.c's export-trie rebuild: decode,
# shift, re-serialize, all against hand-built and hand-computed trie byte
# buffers -- no fixture file needed, same reasoning as grow_test.
add_executable(trie_test tests/trie_test.c)
target_compile_options(trie_test PRIVATE -O2 -Wall)
target_link_libraries(trie_test PRIVATE machorewritecore)
add_test(NAME trie_test COMMAND trie_test)

# Hermetic tests for src/script.c's tokenizer: hand-written script text and
# the field vector it must produce, so no fixture file is needed -- same
# reasoning as trie_test. The quoting cases are exactly the shapes
# compat/translate.sh's mt_quote emits, so the generator and the parser cannot
# drift.
add_executable(script_test tests/script_test.c)
target_compile_options(script_test PRIVATE -O2 -Wall -Wextra)
target_link_libraries(script_test PRIVATE machorewritecore)
add_test(NAME script_test COMMAND script_test)
# test_error_message_quoting_survives_the_free (a use-after-free regression
# test) does not reliably fail on a plain run -- libc's allocator
# typically leaves a freed block's bytes untouched until reused, so the
# use-after-free read often still returns the original text by luck.
# MallocScribble=1 overwrites every freed block with 0x55 on free, so ctest
# actually exercises the regression this test exists to catch.
set_tests_properties(script_test PROPERTIES ENVIRONMENT MallocScribble=1)

# Hermetic tests for src/arch_names.c and src/fat.c's mfat_rewrite: fat
# containers built in the test from plain-byte slices, so no fixture file is
# needed. MallocScribble for the same reason as script_test: mfat_rewrite
# frees every split buffer on every path, and a use-after-free there reads
# garbage rather than crashing unless freed memory is scribbled.
add_executable(fat_test tests/fat_test.c)
target_compile_options(fat_test PRIVATE -O2 -Wall -Wextra)
target_link_libraries(fat_test PRIVATE machorewritecore)
add_test(NAME fat_test COMMAND fat_test)
set_tests_properties(fat_test PROPERTIES ENVIRONMENT MallocScribble=1)

# Hermetic tests for src/edit.c's execution model -- statements apply in
# order, a failure part-way writes nothing, a dry run writes nothing but still
# verifies -- against a synthetic image built by hand, same reasoning as
# linkedit_test. It writes that image into a mkdtemp directory because me_run
# takes a path. MallocScribble=1 for the reason script_test has it, applied to
# this module's own hazard: the image buffer is reallocated between
# statements (allow-grow's header grow, `fixups set classic`'s room to
# append), and a pointer kept across one would still read the old bytes by
# luck on a plain run.
add_executable(edit_test tests/edit_test.c)
target_compile_options(edit_test PRIVATE -O2 -Wall -Wextra)
target_link_libraries(edit_test PRIVATE machorewritecore)
add_test(NAME edit_test COMMAND edit_test)
set_tests_properties(edit_test PROPERTIES ENVIRONMENT MallocScribble=1)

# Hermetic tests for src/linkedit.c's ml_bump_all: a synthetic
# image built by hand via mi_wrap, so no fixture file is needed -- same
# reasoning as trie_test.
add_executable(linkedit_test tests/linkedit_test.c)
target_compile_options(linkedit_test PRIVATE -O2 -Wall -Wextra)
target_link_libraries(linkedit_test PRIVATE machorewritecore)
add_test(NAME linkedit_test COMMAND linkedit_test)

# Hermetic tests for src/relations.c: hand-built images, no fixture file, so
# liveness never depends on what the host linker emits -- the dependence that
# made cli_test's build-version fixtures pass here and fail on the cross runner.
add_executable(relations_test tests/relations_test.c)
target_compile_options(relations_test PRIVATE -O2 -Wall -Wextra)
target_link_libraries(relations_test PRIVATE machorewritecore)
add_test(NAME relations_test COMMAND relations_test)

# Hermetic tests for src/atomic_write.c's wa_write_new, in a scratch
# directory under $TMPDIR: it never writes its input, it writes its output
# whole or not at all, and the output carries the input's metadata.
# MallocScribble for the same reason as script_test: wa_write_new and its
# helpers free the temp-path and xattr buffers on every path, and a
# use-after-free there reads garbage rather than crashing unless freed
# memory is scribbled.
add_executable(atomic_write_test tests/atomic_write_test.c)
target_compile_options(atomic_write_test PRIVATE -O2 -Wall -Wextra)
target_link_libraries(atomic_write_test PRIVATE machorewritecore)
add_test(NAME atomic_write_test COMMAND atomic_write_test)
set_tests_properties(atomic_write_test PROPERTIES ENVIRONMENT MallocScribble=1)

# Fixture helpers, not tests: build and inspect a fat container without
# system lipo, whose accepted architectures are not the suites' to pin.
# Built beside machorewrite so every CLI suite finds them in the directory it is
# already given.
add_executable(makefat tests/makefat.c)
add_executable(fatcheck tests/fatcheck.c)
target_compile_options(makefat PRIVATE -O2 -Wall -Wextra)
target_compile_options(fatcheck PRIVATE -O2 -Wall -Wextra)

# Builds real dylibs, rewrites a real executable, and RUNS it -- a wrong library
# ordinal shows up as a dyld failure rather than a silent mis-binding. Now
# matches chained-fixups.sh/characterize.sh/cli_test.sh/leaf-tool-crashes.sh:
# passed the bindir so it runs the change_dylib and fix_macho wrappers CMake
# actually staged (and the machorewrite under them), instead of compiling its own
# copies from a hand-enumerated source list that had to be kept in sync with
# machorewritecore by hand -- it still builds machorewrite from source, deriving
# the list from a glob, and copies the two wrappers beside it, when run
# standalone with no bindir argument.
add_test(NAME change_dylib_test
  COMMAND sh "${CMAKE_CURRENT_SOURCE_DIR}/tests/change_dylib_test.sh" "$<TARGET_FILE_DIR:machorewrite>")

# Build equivalence. The tool binaries can never match across a 2014 clang and a
# 2026 one, so comparing them is the wrong invariant. These tools are
# deterministic file transformers, so pin what they PRODUCE: run the pipeline
# over a committed fixture and compare the digest. Native-on-10.9 and
# cross-from-a-modern-host must agree, which is the equivalence claim made
# checkable rather than asserted.
# Covers patch_macho's chained-fixups conversion, which the characterization
# above cannot: its fixture is 10.9-built and has no chained fixups to convert.
# SKIPs (77) on hosts that cannot emit them -- 10.9 included -- so it is real
# coverage on a modern host and an honest no-op on the target.
add_test(NAME chained_fixups
  COMMAND sh "${CMAKE_CURRENT_SOURCE_DIR}/tests/chained-fixups.sh" "$<TARGET_FILE_DIR:machorewrite>")
set_tests_properties(chained_fixups PROPERTIES SKIP_RETURN_CODE 77)

add_test(NAME characterize
  COMMAND sh "${CMAKE_CURRENT_SOURCE_DIR}/tests/characterize.sh" "$<TARGET_FILE_DIR:machorewrite>" check)

# machorewrite's own CLI: --capabilities plus each verb it implements. Builds its own
# fixtures (FIXTURE_FLAGS = -mmacosx-version-min=10.9, same reasoning as
# change_dylib_test.sh) rather than reading tests/fixture.macho, so no
# WORKING_DIRECTORY is needed -- everything it needs is the bindir, passed the
# same way chained_fixups passes patch_macho's.
add_test(NAME cli_test
  COMMAND sh "${CMAKE_CURRENT_SOURCE_DIR}/tests/cli_test.sh" "$<TARGET_FILE_DIR:machorewrite>")

# compat/translate.sh: one assertion per translation from an old tool's grammar
# to machorewrite's, pinning the EXACT emitted command line. Text only -- it never
# runs machorewrite on a file; whether the emitted commands produce the same BYTES is
# tests/compat-sweep.sh's job, and that one is run by hand (it needs both
# families of binaries and takes minutes), with its result committed as
# tests/compat-matrix.tsv. The bindir is here for one thing: the last block
# checks every verb/op/KIND the translator can emit against
# `machorewrite --capabilities`, rather than assuming they agree.
add_test(NAME translate_test
  COMMAND sh "${CMAKE_CURRENT_SOURCE_DIR}/tests/translate_test.sh" "$<TARGET_FILE_DIR:machorewrite>")

# The six /bin/sh wrappers' own behaviour: the grammar each translates, the
# exit codes it maps back to the C tool's, and the stdout it reshapes. Sits
# between translate_test (which pins the emitted TEXT and never runs machorewrite on
# a file) and known_callers (which replays the real callers end to end); every
# assertion in it names the divergence it closes, from the list at the top of
# compat/translate.sh or from cli/machorewrite.c's own "DELIBERATE DIVERGENCES"
# blocks. Also parses every wrapper under /bin/sh AND /bin/ksh, the same
# second-shell cross-check translate_test does.
add_test(NAME wrapper_test
  COMMAND sh "${CMAKE_CURRENT_SOURCE_DIR}/tests/wrapper_test.sh" "$<TARGET_FILE_DIR:machorewrite>")

# THE GATE for the wrappers: every known caller of the six historical tools,
# replayed end to end against them. A wrapper that passes the test suite but
# breaks a real caller is a failure, so the argument sweep is discovery and
# these replays are decisive. Each pipeline's result is pinned to the SHA-256
# the C binaries built from commit 91b30b3 (the last commit carrying all six
# compat/*.c files) produced from tests/fixture.macho on real 10.9, the same
# device tests/EXPECTED uses.
add_test(NAME known_callers
  COMMAND sh "${CMAKE_CURRENT_SOURCE_DIR}/tests/known-callers.sh" "$<TARGET_FILE_DIR:machorewrite>")

# compat/insert_dylib.sh's own suite: the seventh wrapper's grammar, its five
# prompts (--all-yes and the no-tty refusal), and the divergences declared in
# compat/README.md's insert_dylib table. Deliberately NOT part of
# tests/compat-sweep.sh or tests/known-callers.sh -- see this test file's own
# header for why (no known caller to replay, and the sweep's matrix is frozen
# for the six historical tools).
add_test(NAME insert_dylib_test
  COMMAND sh "${CMAKE_CURRENT_SOURCE_DIR}/tests/insert_dylib_test.sh" "$<TARGET_FILE_DIR:machorewrite>")
# A modest ceiling, not ctest's 1500s default: this is the one test in the
# suite that opens /dev/tty through a detached (setsid'd) child expecting a
# refusal, never a read. If the setsid detachment and the /dev/tty-has-no-
# controlling-terminal assumption both broke at once, insert_dylib would
# block on a read nobody answers, and only the default timeout would
# eventually stop it -- 25 minutes of a hung CI run for what should be a
# few seconds of real work building fixtures and running the wrapper.
set_tests_properties(insert_dylib_test PROPERTIES TIMEOUT 120)

# Regression coverage for two heap-overflow crashes a code review found in
# add_version_min and retag_swift_classes after they were converted onto
# src/image.h -- mi_open validates load commands, not section file ranges or
# addresses derived from them, so a fixture can pass mi_open cleanly and
# still contain an out-of-bounds reference. See the script's own header for
# what each fixture is shaped to trigger.
add_test(NAME leaf_tool_crashes
  COMMAND sh "${CMAKE_CURRENT_SOURCE_DIR}/tests/leaf-tool-crashes.sh" "$<TARGET_FILE_DIR:machorewrite>")

# src/live.h -- the header-only, malloc-free query surface for
# avxemu (docs/PROPOSAL.md's "Shape": "live.h is deliberately a header, not
# part of the library"). Deliberately NOT linked against machorewritecore: live.h
# is standalone by design (see its own top comment), and this test proves
# that by needing nothing but -I src. Queries run against this test binary's
# OWN loaded image via _dyld_get_image_header/_dyld_get_image_vmaddr_slide,
# same reasoning as image_test reading a real linker-built fixture instead
# of a synthetic one. WORKING_DIRECTORY is the source dir because the test
# shells out to `cc -c tests/live_probe.c` and `nm` on the result to prove
# a TU that includes only live.h stays free of malloc/free/stdio -- the
# constraint pin `tests/README.md` calls for, wired
# into CI rather than left as an unchecked comment.
add_executable(live_test tests/live_test.c)
target_compile_options(live_test PRIVATE -O2 -Wall -Wextra)
target_include_directories(live_test PRIVATE src)
add_test(NAME live_test COMMAND live_test
  WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}")
