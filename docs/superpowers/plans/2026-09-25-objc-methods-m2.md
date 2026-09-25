# objc-methods M2: `objc-methods set absolute` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A new statement, `objc-methods set absolute`, rewrites every relative Objective-C method list an x86_64 classic image's classes, metaclasses, categories and protocols name into the 24-byte absolute form 10.9's runtime reads, appended past the end of the segment before `__LINKEDIT`, with a rebase for every new pointer, and verifies its own output before handing it back.

**Architecture:** Three layers, each its own reviewer gate. `src/rebase.[ch]` (`mrb_`) decodes all nine classic rebase opcodes and encodes sorted slots. `src/objc_meth.[ch]` (`mml_`, M1's walk) gains a resolver that turns a relative entry into (name string, types string, IMP) under the spec's Decision 3 checks. A new `src/objc_abs.[ch]` (`mma_`) holds the layout (Decision 1: D grows, `__LINKEDIT` moves up, no load command added), the conversion (Decisions 2–3), the verification (Decision 7) and `mma_convert`, which `src/edit.c`'s `me_apply` lowers the new `MS_TABLE_ROWS` row to.

**Tech Stack:** C99 as the 10.9 clang (Apple LLVM 6.0) accepts it; CMake through shipyard; POSIX `sh` suites; the hand-built fixture `tests/relmeth_fixture.h`; for the two local real-binary tasks only, `python3` (`/opt/pkg/bin/python3` on this host).

**Spec:** `docs/superpowers/specs/2026-09-23-objc-method-lists-design.md` (Decision 1 as revised in `1a4a3da`; "The owner's answers (2026-09-25)" is binding). M2 is its "M2" milestone bullets and the M2 rows of its Testing table. M3 and M4 are out of scope.

## Global Constraints

- **Build:** `/usr/local/bin/shipyard-cmake --build /private/tmp/build/schmonz/drydock-native -j`
- **Test:** `unset DRYDOCK_MACHO_REWRITE; /usr/local/bin/shipyard-ctest --test-dir /private/tmp/build/schmonz/drydock-native`. Below, `B=/private/tmp/build/schmonz/drydock-native`; a single C test runs as `"$B/<name>"`, and the CLI suite as `unset DRYDOCK_MACHO_REWRITE; sh tests/cli_test.sh "$B"`, from the repo root.
- **Rebuild check (clock skew here).** Before every build, `pre=$(shasum -a 256 "$B/<target>" 2>/dev/null)`; after it, compare. If the binary you changed did not change, `touch` the edited source and build again; if it still did not change, build with `--clean-first`. A test result against an unchanged binary is not a result.
- **TDD and mutation proof** for every task: the test first, seen failing; then the code; then every row of the task's mutation table, each applied alone, rebuilt (rebuild check), and seen to fail the named test. Apply a mutation only to a saved copy's original: `M=$(mktemp -d); cp FILE "$M/"`, edit, rebuild, run, then `cp "$M/$(basename FILE)" FILE && cmp FILE "$M/$(basename FILE)"`, rebuild. A mutation that no test kills is a finding: add the test that kills it, in the same task.
- **Comments are a last resort:** prefer a test, then the commit message, then a doc, then one inline sentence. No history narration, and no reference to a plan or spec from source (specs and plans are deleted once implemented).
- **Exit codes:** `EX_REFUSED` = 1 (and `MR_REFUSED`), `EX_FAIL` = 2 (and `MR_FAIL`); a parse error is 2. The statement never writes its input, and nothing is written on a refusal.
- **Every grep negative needs a positive control.** In shell suites, `rc=0; cmd || rc=$?`.
- **char[16] names:** print with `%.16s`, compare with `strncmp(..., 16)`.
- **Staging and pushing:** stage explicit paths only (never `git add -A`/`.`); commit on `main`; do not push. Every commit message ends with:
  ```
  Co-Authored-By: <authoring model> <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU
  ```
- **CI runs on macos-26-arm64,** where anything a host-compiled fixture contributes (pad, size, arch) is a host fact. Every fixture here is `tests/relmeth_fixture.h`, hand-built and x86_64; `mkrelmeth` is compiled for the host but writes the same bytes everywhere.
- **From the spec, binding for every task:** x86_64 only; classic fixups only (`LC_DYLD_CHAINED_FIXUPS` refused with "fixups set classic first"; no `LC_DYLD_INFO[_ONLY]` refused); **no load command is added and the header is never grown**; `LC_SEGMENT_SPLIT_INFO` is kept, its offset moved with the rest; an IMP that is not a function start is refused when `LC_FUNCTION_STARTS` is present; the dead relative lists stay where they are; the spelling is `objc-methods set absolute`.
- **Shared files:** the `MS_TABLE_ROWS` row, the kind enum value and the `me_apply` case go **after whatever is currently last** in their lists (`docs/superpowers/plans/2026-09-23-bind-stream-edit.md` also appends). Row counts are "current N → N+1". `README.md` is not touched (M4's last task does that). `src/grow.c` is not edited.

## Review Focus

1. **A `__LINKEDIT` whose vmsize the rewritten rebase stream outgrows** (ReactiveObjC and Squirrel both do) → its vmsize grows to cover its file bytes, and verification accepts exactly that growth. Pinned by Task 4's `test_insert_grows_linkedit_vm_to_cover_its_file_bytes` and Task 6's `__LINKEDIT's geometry` refusals.
2. **The statement run on an image it already converted** (a script that says it twice, or a later `target 10.9`) → "nothing to convert", and the output is byte-identical. Pinned by Task 5's `test_a_converted_image_has_nothing_to_convert`, Task 6's `test_convert_swaps_only_what_verifies` and Task 7's CLI assertion.
3. **An input rebase stream ld64 wrote compactly** (`DO_REBASE_ADD_ADDR_ULEB` between slots, not Drydock's one pointer per opcode) → every old rebase survives into the new stream. Pinned by Task 5's `RMF_COMPACT` variant, run through the oracle test and Task 6's verify-everything test.
4. **An image that is not x86_64** (the arm64 slice of a fat file) → refused with its reason, nothing written. Pinned by Task 5's `poke_arm64` refusal.
5. **Bytes past `__LINKEDIT`'s end** (a padded slice) → refused before anything moves, rather than moved blind. Pinned by Task 4's "bytes past __LINKEDIT" layout refusal.

## Plan decisions at a glance

Each is repeated, with its reason, in the task that makes it.

- Task 1: the real-binary check is a documented local check, recorded in the spec, not a ctest.
- Task 3: the resolver lives in `src/objc_meth.[ch]`; a selector reference with no rebase is refused either way, and the message says "bound to another image" when the bind stream binds it; an `LC_FUNCTION_STARTS` that lists no starts is treated as absent, as `mg_plausible` treats it.
- Task 3–5: the fixture grows to 0x2200 bytes (`__LINKEDIT` 0x200) to hold its new blobs; list A's entries become beta, alpha, so a conversion that sorts is caught.
- Task 4: layout, conversion and verification go in a new `src/objc_abs.[ch]` (`mma_`); their tests stay in `tests/objc_meth_test.c`, as the spec's Testing table says.
- Task 4: `__LINKEDIT`'s vmsize grows to the page-rounded new filesize when that exceeds it; refuse when `__LINKEDIT` does not end the file; refuse when D, its zero fill made file bytes, does not end on a 4096-byte boundary.
- Task 5: the old rebase stream is copied byte for byte up to its `DONE`, then the new opcodes, then `DONE`, zero-padded to 8.
- Task 5: a list is counted under the record of the first slot (in walk order) that names it.
- Task 6: verification compares each entry's three addresses, not string bytes; equal addresses and unchanged bytes below the insertion make the strings equal.
- Task 7: log figures use the report's comma grouping (`4,096`); a third line appears only when zero fill became file bytes; "nothing to convert" when there is nothing.

## File structure

| file | status | responsibility | task |
|---|---|---|---|
| `src/rebase.h`, `src/rebase.c` | new | `mrb_`: decode all nine rebase opcodes into slots; sort, look up; encode sorted slots | 2 |
| `tests/rebase_test.c` | new | hermetic opcode-by-opcode tests | 2 |
| `src/objc_meth.h`, `src/objc_meth.c` | modify | `mml_resolver`, `mml_entry_at`: Decision 3 | 3 |
| `src/objc_abs.h`, `src/objc_abs.c` | new | `mma_`: layout (4), conversion (5), verification and `mma_convert` (6) | 4–6 |
| `tests/relmeth_fixture.h` | modify | new variants (3, 4, 5) and the oracle `rmf_describe` (5) | 3–5 |
| `tests/mkrelmeth.c` | modify | variant names (3, 4), `make A+B`, `entries FILE` (5) | 3–5 |
| `tests/objc_meth_test.c` | modify | resolution, layout, insertion, conversion, verification tests | 3–6 |
| `CMakeLists.txt` | modify | `src/rebase.c` + `rebase_test` (2); `src/objc_abs.c` (4) | 2, 4 |
| `src/script.h`, `src/script.c` | modify | `MS_OBJC_METHODS`, the row, its value check | 7 |
| `src/edit.c` | modify | `me_apply` case and `me_log_objc_methods` | 7 |
| `tests/script_test.c` | modify | row count, disturbs, parse | 7 |
| `tests/cli_test.sh` | modify | statement count; the statement's block (7); the grow composition (8) | 7, 8 |
| `docs/superpowers/specs/2026-09-23-objc-method-lists-design.md` | modify | real-binary results (1, 9) | 1, 9 |

---

### Task 1: Check the three real frameworks against Decision 3 before any code

**Files:**
- Create (scratch, not committed): `$W/objc_methods_probe.py`, where `W=$(mktemp -d)`
- Modify: `docs/superpowers/specs/2026-09-23-objc-method-lists-design.md` — the "**What real binaries on this host settled (2026-09-25).**" list (`:459`–`:477`, ending "extra 6 are lists of protocols nothing adopts.") and the first "**Still to validate:**" bullet (`:481`–`:483`, "that in an app binary (as opposed to the shared cache) `name` is always a selector-reference offset and never direct. M2's first task checks this on the three frameworks above;").

**Interfaces:**
- Consumes: the current `drydock-macho-rewrite` (`fixups set classic`, M1's `info`).
- Produces: nothing later tasks call. Task 9 reuses `objc_methods_probe.py` (its `dump` mode) and this task's lowering commands.

**Plan decision:** a documented local check whose result is committed to the spec, not an opt-in ctest. Why: nothing in `src/` exists yet for a test to exercise, the three files are in one person's `~/Downloads`, and a ctest that SKIPs on every CI run is a permanent line that proves nothing there; the facts are about three fixed files, so they are recorded once, with the files' digests, and Task 9 re-runs the same probe on the finished statement.

The probe is a second reading written apart from `src/`: Decision 3's checks on every relative entry the walk reaches, and Decision 1's refusals. If any check fails on a real framework, the plan's premise is wrong: stop and report to the owner instead of continuing.

- [ ] **Step 1: Build the current tree and lower the three frameworks**

```bash
B=/private/tmp/build/schmonz/drydock-native
/usr/local/bin/shipyard-cmake --build "$B" -j
W=$(mktemp -d); echo "$W"
FW="$HOME/Downloads/OpenCode.app/Contents/Frameworks"
for n in Mantle ReactiveObjC Squirrel; do
    f="$FW/$n.framework/Versions/A/$n"
    rc=0; printf 'fixups set classic\n' | "$B/drydock-macho-rewrite" "$f" "$W/$n.classic" >/dev/null 2>"$W/$n.lower.log" || rc=$?
    echo "$n rc=$rc in=$(shasum -a 256 < "$f" | cut -c1-16) classic=$(shasum -a 256 < "$W/$n.classic" | cut -c1-16)"
    "$B/drydock-macho-rewrite" info "$W/$n.classic" | grep '^objc-methods:'
done
```

Expected (the digests were taken while this plan was written; a different input digest means a different download, so stop and ask):

```
Mantle rc=0 in=3b59fda24c50ec1d classic=140d6ca66370a9ee
objc-methods: 22 relative, 10 absolute
ReactiveObjC rc=0 in=35e4e688c2be2b3d classic=88ad1e59d371824e
objc-methods: 137 relative, 6 absolute
Squirrel rc=0 in=03ef80b1d4cbf4f6 classic=c1ed9c1dc5c322fb
objc-methods: 20 relative, 7 absolute
```

- [ ] **Step 2: Write the probe to `$W/objc_methods_probe.py`**

```python
#!/usr/bin/env python3
"""objc_methods_probe.py -- a second reading of a classic x86_64 image's
Objective-C method lists, written apart from src/, for objc-methods M2.

  check FILE...  every relative entry through spec Decision 3's checks, and
                 the image through Decision 1's refusals; exit 1 on any failure
  dump FILE      one line per method-list slot: its address, the list's form
                 and count, and each entry as (name, types, imp)
"""
import struct, sys

u32 = lambda b, o: struct.unpack_from('<I', b, o)[0]
i32 = lambda b, o: struct.unpack_from('<i', b, o)[0]
u64 = lambda b, o: struct.unpack_from('<Q', b, o)[0]


def uleb(b, p):
    v = s = 0
    while True:
        c = b[p]; p += 1
        v |= (c & 0x7f) << s; s += 7
        if not c & 0x80:
            return v, p


class Image:
    def __init__(self, path):
        self.path, b = path, open(path, 'rb').read()
        self.b, self.segs, self.sects, self.info, self.fstarts = b, [], [], None, None
        if u32(b, 0) != 0xfeedfacf or u32(b, 4) != 0x01000007:
            raise SystemExit('%s: not a thin x86_64 Mach-O' % path)
        p = 32
        for _ in range(u32(b, 16)):
            cmd, size = u32(b, p), u32(b, p + 4)
            if cmd == 0x80000034:
                raise SystemExit('%s: chained fixups; fixups set classic first' % path)
            if cmd == 0x19:
                vm, vms, fo, fsz = struct.unpack_from('<QQQQ', b, p + 24)
                self.segs.append(dict(name=b[p + 8:p + 24].rstrip(b'\0').decode(), vm=vm, vms=vms,
                                      fo=fo, fsz=fsz, prot=u32(b, p + 60)))
                for k in range(u32(b, p + 64)):
                    q = p + 72 + 80 * k
                    addr, sz = struct.unpack_from('<QQ', b, q + 32)
                    self.sects.append(dict(name=b[q:q + 16].rstrip(b'\0').decode(), addr=addr,
                                           size=sz, off=u32(b, q + 48), flags=u32(b, q + 64)))
            elif cmd in (0x22, 0x80000022):
                self.info = struct.unpack_from('<10I', b, p + 8)
            elif cmd == 0x26:
                self.fstarts = struct.unpack_from('<II', b, p + 8)
            p += size

    def off(self, va, n=8):
        for s in self.segs:
            if s['vm'] <= va and va + n <= s['vm'] + s['fsz']:
                return s['fo'] + va - s['vm']
        return None

    def sect(self, va):
        for s in self.sects:
            if s['addr'] <= va < s['addr'] + s['size']:
                return s
        return None

    def cstring(self, va):
        s = self.sect(va)
        if not s or s['flags'] & 0xff != 2 or not s['off']:
            return None
        start = s['off'] + va - s['addr']
        end = self.b.find(b'\0', start, s['off'] + s['size'])
        return None if end < 0 else self.b[start:end].decode('utf-8', 'replace')

    def rebases(self):
        b, out, (q, size) = self.b, set(), self.info[0:2]
        end, seg, o = q + size, 0, 0
        while q < end:
            c = b[q]; q += 1
            op, imm = c & 0xf0, c & 0x0f
            if op == 0x00: break
            elif op == 0x10: pass
            elif op == 0x20: seg = imm; o, q = uleb(b, q)
            elif op == 0x30: d, q = uleb(b, q); o += d
            elif op == 0x40: o += imm * 8
            elif op in (0x50, 0x60):
                n = imm
                if op == 0x60: n, q = uleb(b, q)
                for _ in range(n): out.add(self.segs[seg]['vm'] + o); o += 8
            elif op == 0x70: out.add(self.segs[seg]['vm'] + o); d, q = uleb(b, q); o += d + 8
            elif op == 0x80:
                n, q = uleb(b, q); sk, q = uleb(b, q)
                for _ in range(n): out.add(self.segs[seg]['vm'] + o); o += sk + 8
            else: raise SystemExit('%s: rebase opcode %#x' % (self.path, c))
        return out

    def starts(self):
        if not self.fstarts or not self.fstarts[1]:
            return None
        a = min(s['vm'] for s in self.segs if s['fo'] == 0 and s['fsz'])
        q, end, out = self.fstarts[0], sum(self.fstarts), set()
        while q < end:
            d, q = uleb(self.b, q)
            if not d: break
            a += d; out.add(a)
        return out or None

    def slots(self):
        """(slot address, list address, owner) in the walk's order."""
        seen, out = set(), []
        def lst(va, owner):
            v = u64(self.b, self.off(va))
            if v: out.append((va, v, owner))
        def cls(va, owner):
            if not va or va in seen: return
            seen.add(va)
            isa, data = u64(self.b, self.off(va)), u64(self.b, self.off(va + 32)) & 0x00007ffffffffff8
            if data: lst(data + 32, owner)
            if owner == 'class' and isa: cls(isa, 'metaclass')
        kinds = {'__objc_classlist': 'class', '__objc_nlclslist': 'class', '__objc_catlist': 'category',
                 '__objc_nlcatlist': 'category', '__objc_protolist': 'protocol'}
        for s in self.sects:
            kind = kinds.get(s['name'])
            for i in range(0, s['size'] if kind else 0, 8):
                r = u64(self.b, s['off'] + i)
                if kind == 'class': cls(r, 'class')
                elif r and r not in seen:
                    seen.add(r)
                    for k in ((16, 24) if kind == 'category' else (24, 32, 40, 48)): lst(r + k, kind)
        return out

    def entries(self, lv):
        lo = self.off(lv)
        hdr, n = u32(self.b, lo), u32(self.b, lo + 4)
        for e in range(n):
            if hdr & 0x80000000:
                ea, eo = lv + 8 + 12 * e, lo + 8 + 12 * e
                d0, d1, d2 = i32(self.b, eo), i32(self.b, eo + 4), i32(self.b, eo + 8)
                yield dict(slot=ea + d0, types=ea + 4 + d1, imp=ea + 8 + d2 if d2 else 0)
            else:
                eo = lo + 8 + 24 * e
                yield dict(name=u64(self.b, eo), types=u64(self.b, eo + 8), imp=u64(self.b, eo + 16))


def check(path):
    im, fails = Image(path), []
    if im.info is None:
        raise SystemExit('%s: no LC_DYLD_INFO' % path)
    rb, starts, counts = im.rebases(), im.starts(), dict(rel=0, abs=0, ents=0, rebases=0)
    slots = im.slots()
    for (sva, lv, owner) in slots:
        if sva not in rb: fails.append('slot %#x (%s) carries no rebase' % (sva, owner))
    for lv in sorted({lv for (_, lv, _) in slots}):
        rel = u32(im.b, im.off(lv)) & 0x80000000
        counts['rel' if rel else 'abs'] += 1
        for i, e in enumerate(im.entries(lv) if rel else ()):
            where = 'list %#x entry %d' % (lv, i)
            counts['ents'] += 1
            counts['rebases'] += 3 if e['imp'] else 2
            if e['slot'] & 7: fails.append(where + ': selref not 8-byte aligned')
            if im.off(e['slot']) is None: fails.append(where + ': selref not file-backed'); continue
            if e['slot'] not in rb: fails.append(where + ': selref carries no rebase')
            if im.cstring(u64(im.b, im.off(e['slot']))) is None: fails.append(where + ': name not a C string')
            if im.cstring(e['types']) is None: fails.append(where + ': types not a C string')
            if e['imp']:
                s = im.sect(e['imp'])
                if not s or not s['flags'] & 0x80000400: fails.append(where + ': imp not in code')
                if starts is not None and e['imp'] not in starts: fails.append(where + ': imp not a start')
    d, l = im.segs[-2], im.segs[-1]
    if l['name'] != '__LINKEDIT': fails.append('__LINKEDIT is not the last segment')
    if len(im.segs) - 2 > 15: fails.append('D is segment %d' % (len(im.segs) - 2))
    if not d['prot'] & 2: fails.append('D (%s) is not writable' % d['name'])
    if d['vm'] + d['vms'] != l['vm']: fails.append('D does not end where __LINKEDIT begins in vm')
    if d['fo'] + d['fsz'] != l['fo']: fails.append('D does not end where __LINKEDIT begins in file')
    if l['fo'] + l['fsz'] != len(im.b): fails.append('__LINKEDIT does not end the file')
    print('%s: %d relative, %d absolute; %d entries, %d new rebases; D %s (segment %d); '
          'function starts %s; %s' % (path.split('/')[-1], counts['rel'], counts['abs'], counts['ents'],
                                      counts['rebases'], d['name'], len(im.segs) - 2,
                                      'absent' if starts is None else len(starts),
                                      'all checks pass' if not fails else '%d FAILURES' % len(fails)))
    for f in fails[:20]:
        print('  ' + f)
    return not fails


def dump(path):
    im = Image(path)
    for (sva, lv, owner) in im.slots():
        rel = u32(im.b, im.off(lv)) & 0x80000000
        out = []
        for e in im.entries(lv):
            name = u64(im.b, im.off(e['slot'])) if rel else e['name']
            out.append('%s %s %#x' % (im.cstring(name), im.cstring(e['types']), e['imp']))
        print('%#x %s %s %d: %s' % (sva, owner, 'rel' if rel else 'abs', len(out), '; '.join(out)))


if __name__ == '__main__':
    if len(sys.argv) >= 3 and sys.argv[1] == 'check':
        sys.exit(0 if all([check(p) for p in sys.argv[2:]]) else 1)
    if len(sys.argv) == 3 and sys.argv[1] == 'dump':
        dump(sys.argv[2]); sys.exit(0)
    sys.exit(__doc__)
```

- [ ] **Step 3: Prove the probe can fail (positive controls)**

```bash
cp "$W/Mantle.classic" "$W/ctl.norebase"
off=$(otool -l "$W/ctl.norebase" | awk '/rebase_off/{print $2}')
printf '\000' | dd of="$W/ctl.norebase" bs=1 seek="$off" conv=notrunc 2>/dev/null
cp "$W/Mantle.classic" "$W/ctl.trailing"; printf '\000' >>"$W/ctl.trailing"
rc=0; python3 "$W/objc_methods_probe.py" check "$W/ctl.norebase" "$W/ctl.trailing" >"$W/ctl.out" || rc=$?
echo "rc=$rc"; grep -c 'carries no rebase' "$W/ctl.out"; grep -F '__LINKEDIT does not end the file' "$W/ctl.out"
```

Expected: `rc=1`; a count well above 0 (121 when this was written: a `DONE` at the stream's first byte drops every rebase); and the line `  __LINKEDIT does not end the file`.

| mutation (of the input) | the probe must report |
|---|---|
| `DONE` written over the first rebase opcode | `slot ... carries no rebase` and `selref carries no rebase`, exit 1 |
| one byte appended past `__LINKEDIT` | `__LINKEDIT does not end the file`, exit 1 |

- [ ] **Step 4: Run the probe on the three**

```bash
python3 "$W/objc_methods_probe.py" check "$W/Mantle.classic" "$W/ReactiveObjC.classic" "$W/Squirrel.classic"; echo "rc=$?"
```

Expected, exactly:

```
Mantle.classic: 22 relative, 10 absolute; 89 entries, 267 new rebases; D __DATA (segment 2); function starts absent; all checks pass
ReactiveObjC.classic: 137 relative, 6 absolute; 650 entries, 1950 new rebases; D __DATA (segment 2); function starts absent; all checks pass
Squirrel.classic: 20 relative, 7 absolute; 124 entries, 372 new rebases; D __DATA (segment 2); function starts absent; all checks pass
rc=0
```

Any `FAILURES` line: stop here and report it to the owner with the probe's output. Do not start Task 2.

- [ ] **Step 5: Record the result in the spec**

In the "**What real binaries on this host settled (2026-09-25).**" list, after its last bullet (the one ending "the extra 6 are lists of protocols nothing adopts."), add:

```markdown
- **Every relative entry resolves as Decision 3 requires** (M2's first
  task). A probe written apart from `src/` ran Decision 3's checks and
  Decision 1's refusals on the three frameworks after `fixups set
  classic` (inputs `3b59fda2…`, `35e4e688…`, `03ef80b1…` by SHA-256):
  89, 650 and 124 entries in 22, 137 and 20 relative lists. Every `name`
  is an offset to an 8-byte-aligned, file-backed, rebased selector
  reference holding a C string; every `types` is a C string; every IMP is
  non-zero and in a section of instructions. None carries
  `LC_FUNCTION_STARTS`, so the function-start check does not run on them.
  D is `__DATA`, segment 2, writable, ending where `__LINKEDIT` begins in
  vm and in file, and `__LINKEDIT` ends the file. The conversion adds 267,
  1,950 and 372 rebases. So in these app-side images `name` is never direct.
```

and delete the first "**Still to validate:**" bullet, the one reading "that in an app binary (as opposed to the shared cache) `name` is always a selector-reference offset and never direct. M2's first task checks this on the three frameworks above;".

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs/2026-09-23-objc-method-lists-design.md
git commit -m "docs(spec): every relative entry in the three frameworks resolves

A probe written apart from src/ ran Decision 3's checks and Decision 1's
refusals on Mantle, ReactiveObjC and Squirrel after fixups set classic.
All pass, so M2 builds on a premise real ld64 output keeps.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

Keep `$W` until Task 9, or re-create it then with Step 1 and Step 2.

---

### Task 2: A complete rebase-opcode decoder and an encoder (`src/rebase.[ch]`)

**Files:**
- Create: `src/rebase.h`, `src/rebase.c`, `tests/rebase_test.c`
- Modify: `CMakeLists.txt:66` (the `add_library(drydockcore STATIC ... src/objc_meth.c)` line) and after `:273` (`set_tests_properties(objc_meth_test PROPERTIES ENVIRONMENT MallocScribble=1)`)

**Interfaces:**
- Consumes: `mu_decode`, `mu_minlen`, `mu_encode_fixed` (`src/uleb.h`).
- Produces (Tasks 3, 5, 6 call these):
  - `typedef struct { uint64_t off; uint8_t seg, type; } mrb_slot;`
  - `typedef struct { mrb_slot *v; size_t n, cap; size_t end; } mrb_set;` — `end` is the offset of the stream's `DONE`, or its size.
  - `int mrb_decode(const uint8_t *p, size_t size, int nsegs, mrb_set *out, char *why, size_t whysz);` → `MRB_OK` (0), `MRB_MALFORMED` (-1), `MRB_NOMEM` (-2)
  - `void mrb_free(mrb_set *s);` `int mrb_add(mrb_set *s, uint8_t seg, uint8_t type, uint64_t off);` `size_t mrb_sort(mrb_set *s);` `int mrb_has(const mrb_set *s, uint8_t seg, uint64_t off);`
  - `typedef struct { uint8_t *p; size_t n, cap; int oom; } mrb_buf;` `int mrb_encode(const mrb_slot *v, size_t n, mrb_buf *b);` `void mrb_put(mrb_buf *b, const uint8_t *src, size_t n);`

`md_next_rebase` (`src/declassify.c:267`) reads only the two opcodes its own encoder emits; it is left alone, because `fixups set classic` verifies only its own streams with it.

- [ ] **Step 1: Write the failing test, `tests/rebase_test.c`**

```c
/* tests/rebase_test.c -- hermetic tests for src/rebase.c, against rebase
 * streams assembled here byte by byte. */
#include "rebase.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails = 0;
#define CHECK(cond, msg, ...) do { if (!(cond)) { \
    printf("FAIL: " msg "\n", ##__VA_ARGS__); fails++; } } while (0)

static void test_every_opcode_decodes(void) {
    static const uint8_t s[] = {
        0x11,             /* SET_TYPE_IMM pointer */
        0x22, 0x10,       /* SET_SEGMENT_AND_OFFSET_ULEB seg 2, 0x10 */
        0x52,             /* DO_REBASE_IMM_TIMES 2: 0x10, 0x18 */
        0x30, 0x08,       /* ADD_ADDR_ULEB 8: 0x28 */
        0x42,             /* ADD_ADDR_IMM_SCALED 2: 0x38 */
        0x60, 0x03,       /* DO_REBASE_ULEB_TIMES 3: 0x38, 0x40, 0x48 */
        0x70, 0x10,       /* DO_REBASE_ADD_ADDR_ULEB 16: 0x50, then 0x68 */
        0x80, 0x02, 0x08, /* DO_REBASE_ULEB_TIMES_SKIPPING_ULEB 2, 8: 0x68, 0x78 */
        0x12,             /* SET_TYPE_IMM text absolute32 */
        0x21, 0x00,       /* seg 1, 0 */
        0x51,             /* DO_REBASE_IMM_TIMES 1: 0 */
        0x00,             /* DONE, at byte 18 */
        0xAA,             /* past DONE: never read */
    };
    static const mrb_slot want[] = {
        { 0x10, 2, 1 }, { 0x18, 2, 1 }, { 0x38, 2, 1 }, { 0x40, 2, 1 }, { 0x48, 2, 1 },
        { 0x50, 2, 1 }, { 0x68, 2, 1 }, { 0x78, 2, 1 }, { 0x00, 1, 2 },
    };
    mrb_set set;
    char why[160] = "";
    int rc = mrb_decode(s, sizeof s, 4, &set, why, sizeof why);
    CHECK(rc == MRB_OK, "every opcode: rc %d (%s)", rc, why);
    CHECK(set.n == sizeof want / sizeof want[0], "every opcode: %zu slots, want %zu",
          set.n, sizeof want / sizeof want[0]);
    for (size_t i = 0; i < set.n && i < sizeof want / sizeof want[0]; i++)
        CHECK(set.v[i].seg == want[i].seg && set.v[i].off == want[i].off &&
              set.v[i].type == want[i].type,
              "every opcode: slot %zu is (%u, %#llx, type %u), want (%u, %#llx, type %u)", i,
              set.v[i].seg, (unsigned long long)set.v[i].off, set.v[i].type,
              want[i].seg, (unsigned long long)want[i].off, want[i].type);
    CHECK(set.end == 18, "every opcode: DONE found at %zu, want 18", set.end);
    mrb_free(&set);
}

static void test_a_stream_without_done_ends_at_its_size(void) {
    static const uint8_t s[] = { 0x11, 0x22, 0x00, 0x51 };
    mrb_set set;
    int rc = mrb_decode(s, sizeof s, 4, &set, NULL, 0);
    CHECK(rc == MRB_OK && set.n == 1 && set.end == sizeof s,
          "no DONE: rc %d, %zu slots, end %zu", rc, set.n, set.end);
    mrb_free(&set);
}

static void refused(const uint8_t *s, size_t n, const char *want, const char *label) {
    mrb_set set;
    char why[160] = "";
    int rc = mrb_decode(s, n, 4, &set, why, sizeof why);
    CHECK(rc == MRB_MALFORMED, "%s: rc %d, want MRB_MALFORMED", label, rc);
    CHECK(strstr(why, want) != NULL, "%s: why '%s' lacks '%s'", label, why, want);
    CHECK(set.v == NULL && set.n == 0, "%s: a refusal left slots behind", label);
}

static void test_malformed_streams_are_refused(void) {
    static const uint8_t unknown[] = { 0x11, 0x22, 0x00, 0x90 };
    static const uint8_t noseg[]   = { 0x11, 0x51 };
    static const uint8_t bigseg[]  = { 0x11, 0x25, 0x00, 0x51 };
    static const uint8_t runsoff[] = { 0x11, 0x22, 0x80 };
    static const uint8_t huge[]    = { 0x11, 0x22, 0x00, 0x60, 0x80, 0x80, 0x80, 0x10 };
    static const uint8_t partial[] = { 0x11, 0x22, 0x00, 0x51, 0x90 };
    refused(unknown, sizeof unknown, "unknown rebase opcode 0x90", "unknown opcode");
    refused(noseg, sizeof noseg, "before any segment", "a rebase before any segment");
    refused(bigseg, sizeof bigseg, "names segment 5", "a segment the image lacks");
    refused(runsoff, sizeof runsoff, "runs off", "a ULEB off the end");
    refused(huge, sizeof huge, "past 16777216 slots", "a count past the cap");
    refused(partial, sizeof partial, "unknown rebase opcode", "slots decoded before a refusal");
}

static void test_sort_counts_repeats_and_has_finds(void) {
    static const uint8_t s[] = { 0x11, 0x23, 0x08, 0x51, 0x22, 0x10, 0x52, 0x22, 0x18, 0x51 };
    mrb_set set;
    int rc = mrb_decode(s, sizeof s, 4, &set, NULL, 0);
    CHECK(rc == MRB_OK && set.n == 4, "sort: rc %d, %zu slots", rc, set.n);
    CHECK(mrb_sort(&set) == 1, "sort: (2, 0x18) twice is one repeat");
    CHECK(set.n == 4 && set.v[0].seg == 2 && set.v[0].off == 0x10 && set.v[3].seg == 3,
          "sort: not ordered by segment, then offset");
    CHECK(mrb_has(&set, 2, 0x18) && mrb_has(&set, 3, 0x08), "has: misses a slot it holds");
    CHECK(!mrb_has(&set, 2, 0x08) && !mrb_has(&set, 3, 0x10), "has: finds a slot it lacks");
    mrb_free(&set);
}

static void test_encode_pins_its_opcodes(void) {
    mrb_slot two[] = { { 0x10, 2, 1 }, { 0x18, 2, 1 } };
    mrb_slot fifteen[15], sixteen[16];
    static const uint8_t want2[]  = { 0x11, 0x22, 0x10, 0x52 };
    static const uint8_t want15[] = { 0x11, 0x22, 0x00, 0x5f };
    static const uint8_t want16[] = { 0x11, 0x22, 0x00, 0x60, 0x10 };
    mrb_buf b;
    for (int i = 0; i < 16; i++) {
        sixteen[i].seg = 2; sixteen[i].type = 1; sixteen[i].off = 8 * (uint64_t)i;
        if (i < 15) fifteen[i] = sixteen[i];
    }
    memset(&b, 0, sizeof b);
    CHECK(mrb_encode(two, 2, &b) == MRB_OK && b.n == sizeof want2 &&
          memcmp(b.p, want2, sizeof want2) == 0, "encode: two consecutive slots");
    free(b.p);
    memset(&b, 0, sizeof b);
    CHECK(mrb_encode(fifteen, 15, &b) == MRB_OK && b.n == sizeof want15 &&
          memcmp(b.p, want15, sizeof want15) == 0, "encode: fifteen fit the immediate");
    free(b.p);
    memset(&b, 0, sizeof b);
    CHECK(mrb_encode(sixteen, 16, &b) == MRB_OK && b.n == sizeof want16 &&
          memcmp(b.p, want16, sizeof want16) == 0, "encode: sixteen take a ULEB count");
    free(b.p);
}

static void test_encode_round_trips(void) {
    mrb_slot v[40];
    size_t n = 0;
    mrb_buf b;
    mrb_set back;
    uint8_t done = 0;
    for (int i = 0; i < 3; i++) { v[n].seg = 1; v[n].type = 1; v[n].off = 0x40 + 8 * (uint64_t)i; n++; }
    v[n].seg = 2; v[n].type = 1; v[n].off = 0x100; n++;
    for (int i = 0; i < 20; i++) { v[n].seg = 2; v[n].type = 1; v[n].off = 0x1000 + 8 * (uint64_t)i; n++; }
    v[n].seg = 2; v[n].type = 1; v[n].off = 0x20000; n++;
    v[n].seg = 15; v[n].type = 1; v[n].off = 0x8; n++;
    memset(&b, 0, sizeof b);
    CHECK(mrb_encode(v, n, &b) == MRB_OK, "round trip: encode");
    mrb_put(&b, &done, 1);
    int rc = mrb_decode(b.p, b.n, 16, &back, NULL, 0);
    CHECK(rc == MRB_OK && back.n == n, "round trip: rc %d, %zu slots back, want %zu", rc, back.n, n);
    for (size_t i = 0; i < n && i < back.n; i++)
        CHECK(back.v[i].seg == v[i].seg && back.v[i].off == v[i].off && back.v[i].type == 1,
              "round trip: slot %zu came back as (%u, %#llx)", i, back.v[i].seg,
              (unsigned long long)back.v[i].off);
    CHECK(back.end == b.n - 1, "round trip: DONE at %zu, want %zu", back.end, b.n - 1);
    mrb_free(&back);
    free(b.p);
}

static void test_encode_refuses_what_it_cannot_say(void) {
    mrb_slot unsorted[] = { { 0x18, 2, 1 }, { 0x10, 2, 1 } };
    mrb_slot twice[]    = { { 0x10, 2, 1 }, { 0x10, 2, 1 } };
    mrb_slot seg16[]    = { { 0x10, 16, 1 } };
    mrb_buf b;
    memset(&b, 0, sizeof b);
    CHECK(mrb_encode(unsorted, 2, &b) == MRB_MALFORMED, "encode: unsorted slots accepted");
    CHECK(mrb_encode(twice, 2, &b) == MRB_MALFORMED, "encode: a repeated slot accepted");
    CHECK(mrb_encode(seg16, 1, &b) == MRB_MALFORMED, "encode: segment 16 accepted");
    CHECK(b.n == 0, "encode: a refusal wrote %zu bytes", b.n);
    free(b.p);
}

int main(void) {
    test_every_opcode_decodes();
    test_a_stream_without_done_ends_at_its_size();
    test_malformed_streams_are_refused();
    test_sort_counts_repeats_and_has_finds();
    test_encode_pins_its_opcodes();
    test_encode_round_trips();
    test_encode_refuses_what_it_cannot_say();
    if (fails) {
        printf("%d failure(s)\n", fails);
        return 1;
    }
    printf("rebase_test: 0 failure(s)\n");
    return 0;
}
```

- [ ] **Step 2: Register it and the library source**

In `CMakeLists.txt:66`, change the end of the `add_library` line from `src/exports.c src/objc_meth.c)` to `src/exports.c src/objc_meth.c src/rebase.c)`. After `:273` (`set_tests_properties(objc_meth_test PROPERTIES ENVIRONMENT MallocScribble=1)`) add:

```cmake

# Hermetic tests for src/rebase.c, against rebase streams assembled byte by
# byte.
add_executable(rebase_test tests/rebase_test.c)
target_compile_options(rebase_test PRIVATE -O2 -Wall -Wextra)
target_link_libraries(rebase_test PRIVATE drydockcore)
add_test(NAME rebase_test COMMAND rebase_test)
set_tests_properties(rebase_test PROPERTIES ENVIRONMENT MallocScribble=1)
```

- [ ] **Step 3: Run it to see it fail**

Run: `/usr/local/bin/shipyard-cmake --build "$B" -j`
Expected: the build fails: `src/rebase.c` does not exist (CMake) or `'rebase.h' file not found`.

- [ ] **Step 4: Write `src/rebase.h`**

```c
#ifndef DRYDOCK_REBASE_H
#define DRYDOCK_REBASE_H
/*
 * mrb_ -- the classic rebase opcode stream (LC_DYLD_INFO[_ONLY]'s rebase_off):
 * every one of its nine opcodes decoded into the slots it rebases, and sorted
 * slots encoded back into opcodes dyld has read since 10.6.
 */
#include <stddef.h>
#include <stdint.h>

#define MRB_OK          0
#define MRB_MALFORMED (-1)
#define MRB_NOMEM     (-2)

/* A decode stops after this many slots rather than follow a count from the
 * file into an allocation it cannot make. */
#define MRB_MAX_SLOTS (1u << 24)

typedef struct { uint64_t off; uint8_t seg, type; } mrb_slot;

typedef struct {
    mrb_slot *v;
    size_t    n, cap;
    size_t    end;   /* where the stream's DONE is, or its size when it has none */
} mrb_set;

/* Every slot `p[0, size)` rebases, in stream order, into *out. A segment
 * index of `nsegs` or more, a rebase before any segment is set, a ULEB that
 * runs off the end, an unknown opcode and more than MRB_MAX_SLOTS slots are
 * MRB_MALFORMED with `why` set. On any non-OK return *out is empty. */
int  mrb_decode(const uint8_t *p, size_t size, int nsegs, mrb_set *out,
                char *why, size_t whysz);
void mrb_free(mrb_set *s);

/* Appends one slot. 0, or -1 when out of memory. */
int  mrb_add(mrb_set *s, uint8_t seg, uint8_t type, uint64_t off);

/* Sorts by (seg, off). Returns the number of slots that repeat the slot
 * before them. */
size_t mrb_sort(mrb_set *s);

/* 1 when a sorted `s` holds (seg, off), else 0. */
int mrb_has(const mrb_set *s, uint8_t seg, uint64_t off);

typedef struct { uint8_t *p; size_t n, cap; int oom; } mrb_buf;

/* Appends to `b` the opcodes that rebase `v[0, n)` as pointers:
 * SET_TYPE_IMM(POINTER), then per run of consecutive slots
 * SET_SEGMENT_AND_OFFSET_ULEB and DO_REBASE_IMM_TIMES (up to 15) or
 * DO_REBASE_ULEB_TIMES. No DONE. MRB_MALFORMED when `v` is not strictly
 * increasing by (seg, off) or names a segment above 15; MRB_NOMEM when `b`
 * could not grow. */
int  mrb_encode(const mrb_slot *v, size_t n, mrb_buf *b);
void mrb_put(mrb_buf *b, const uint8_t *src, size_t n);

#endif
```

- [ ] **Step 5: Write `src/rebase.c`**

```c
/* mrb_ -- see rebase.h. */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach-o/loader.h>

#include "rebase.h"
#include "uleb.h"

static int mrb_fail(mrb_set *s, char *why, size_t whysz, int code, const char *fmt, ...)
    __attribute__((format(printf, 5, 6)));
static int mrb_fail(mrb_set *s, char *why, size_t whysz, int code, const char *fmt, ...) {
    va_list ap;
    if (why && whysz) {
        va_start(ap, fmt);
        vsnprintf(why, whysz, fmt, ap);
        va_end(ap);
    }
    mrb_free(s);
    return code;
}

int mrb_add(mrb_set *s, uint8_t seg, uint8_t type, uint64_t off) {
    if (s->n == s->cap) {
        size_t cap = s->cap ? s->cap * 2 : 256;
        mrb_slot *v = realloc(s->v, cap * sizeof *v);
        if (!v) return -1;
        s->v = v;
        s->cap = cap;
    }
    s->v[s->n].seg = seg;
    s->v[s->n].type = type;
    s->v[s->n].off = off;
    s->n++;
    return 0;
}

int mrb_decode(const uint8_t *p, size_t size, int nsegs, mrb_set *out,
               char *why, size_t whysz) {
    const uint8_t *at = p, *end = p + size;
    uint64_t off = 0, count, skip, v;
    uint8_t type = 0;
    int seg = -1;

    memset(out, 0, sizeof *out);
    out->end = size;
    while (at < end) {
        size_t here = (size_t)(at - p);
        uint8_t op = *at & REBASE_OPCODE_MASK, imm = *at & REBASE_IMMEDIATE_MASK;
        int n;
        at++;
        count = 0;
        skip = 0;
        switch (op) {
        case REBASE_OPCODE_DONE:
            out->end = here;
            return MRB_OK;
        case REBASE_OPCODE_SET_TYPE_IMM:
            type = imm;
            continue;
        case REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB:
            if (imm >= nsegs)
                return mrb_fail(out, why, whysz, MRB_MALFORMED,
                                "the rebase at byte %zu names segment %u, and there are %d",
                                here, imm, nsegs);
            seg = imm;
            if (!(n = mu_decode(at, end, &off))) goto runs_off;
            at += n;
            continue;
        case REBASE_OPCODE_ADD_ADDR_ULEB:
            if (!(n = mu_decode(at, end, &v))) goto runs_off;
            at += n;
            off += v;
            continue;
        case REBASE_OPCODE_ADD_ADDR_IMM_SCALED:
            off += (uint64_t)imm * 8;
            continue;
        case REBASE_OPCODE_DO_REBASE_IMM_TIMES:
            count = imm;
            break;
        case REBASE_OPCODE_DO_REBASE_ULEB_TIMES:
            if (!(n = mu_decode(at, end, &count))) goto runs_off;
            at += n;
            break;
        case REBASE_OPCODE_DO_REBASE_ADD_ADDR_ULEB:
            if (!(n = mu_decode(at, end, &skip))) goto runs_off;
            at += n;
            count = 1;
            break;
        case REBASE_OPCODE_DO_REBASE_ULEB_TIMES_SKIPPING_ULEB:
            if (!(n = mu_decode(at, end, &count))) goto runs_off;
            at += n;
            if (!(n = mu_decode(at, end, &skip))) goto runs_off;
            at += n;
            break;
        default:
            return mrb_fail(out, why, whysz, MRB_MALFORMED,
                            "unknown rebase opcode 0x%02x at byte %zu", op, here);
        }
        if (seg < 0)
            return mrb_fail(out, why, whysz, MRB_MALFORMED,
                            "the rebase at byte %zu comes before any segment is set", here);
        if (count > MRB_MAX_SLOTS - out->n)
            return mrb_fail(out, why, whysz, MRB_MALFORMED,
                            "the rebase at byte %zu takes the stream past %u slots",
                            here, MRB_MAX_SLOTS);
        for (uint64_t i = 0; i < count; i++) {
            if (mrb_add(out, (uint8_t)seg, type, off) != 0)
                return mrb_fail(out, why, whysz, MRB_NOMEM, "out of memory");
            off += skip + 8;
        }
        continue;
runs_off:
        return mrb_fail(out, why, whysz, MRB_MALFORMED,
                        "the rebase opcode at byte %zu has a ULEB that runs off the stream", here);
    }
    return MRB_OK;
}

void mrb_free(mrb_set *s) {
    free(s->v);
    s->v = NULL;
    s->n = s->cap = 0;
}

static int mrb_cmp(const void *a_, const void *b_) {
    const mrb_slot *a = a_, *b = b_;
    if (a->seg != b->seg) return a->seg < b->seg ? -1 : 1;
    if (a->off != b->off) return a->off < b->off ? -1 : 1;
    return 0;
}

size_t mrb_sort(mrb_set *s) {
    size_t dups = 0;
    if (s->n) qsort(s->v, s->n, sizeof *s->v, mrb_cmp);
    for (size_t i = 1; i < s->n; i++)
        dups += mrb_cmp(&s->v[i - 1], &s->v[i]) == 0;
    return dups;
}

int mrb_has(const mrb_set *s, uint8_t seg, uint64_t off) {
    mrb_slot key;
    key.seg = seg;
    key.off = off;
    key.type = 0;
    return s->n && bsearch(&key, s->v, s->n, sizeof *s->v, mrb_cmp) != NULL;
}

void mrb_put(mrb_buf *b, const uint8_t *src, size_t n) {
    if (b->oom || n == 0) return;
    if (b->n + n > b->cap) {
        size_t cap = b->cap ? b->cap : 256;
        while (cap < b->n + n) cap *= 2;
        uint8_t *p = realloc(b->p, cap);
        if (!p) { b->oom = 1; return; }
        b->p = p;
        b->cap = cap;
    }
    memcpy(b->p + b->n, src, n);
    b->n += n;
}

static void mrb_put_uleb(mrb_buf *b, uint64_t v) {
    uint8_t enc[10];
    int n = mu_minlen(v);
    mu_encode_fixed(enc, v, n);
    mrb_put(b, enc, (size_t)n);
}

int mrb_encode(const mrb_slot *v, size_t n, mrb_buf *b) {
    uint8_t op = REBASE_OPCODE_SET_TYPE_IMM | REBASE_TYPE_POINTER;
    size_t i = 0;
    for (size_t k = 0; k < n; k++) {
        if (v[k].seg > REBASE_IMMEDIATE_MASK) return MRB_MALFORMED;
        if (k && mrb_cmp(&v[k - 1], &v[k]) >= 0) return MRB_MALFORMED;
    }
    mrb_put(b, &op, 1);
    while (i < n) {
        size_t run = 1;
        while (i + run < n && v[i + run].seg == v[i].seg &&
               v[i + run].off == v[i].off + 8 * run)
            run++;
        op = REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB | v[i].seg;
        mrb_put(b, &op, 1);
        mrb_put_uleb(b, v[i].off);
        if (run <= REBASE_IMMEDIATE_MASK) {
            op = REBASE_OPCODE_DO_REBASE_IMM_TIMES | (uint8_t)run;
            mrb_put(b, &op, 1);
        } else {
            op = REBASE_OPCODE_DO_REBASE_ULEB_TIMES;
            mrb_put(b, &op, 1);
            mrb_put_uleb(b, run);
        }
        i += run;
    }
    return b->oom ? MRB_NOMEM : MRB_OK;
}
```

- [ ] **Step 6: Build and run**

Run: build (rebuild check on `$B/rebase_test`), then `"$B/rebase_test"`.
Expected: `rebase_test: 0 failure(s)`. Then the whole suite (Test command): all pass.

- [ ] **Step 7: Mutation proof** (file `src/rebase.c`; test binary `$B/rebase_test`)

| # | replace | with | must fail |
|---|---|---|---|
| 1 | `off += skip + 8;` | `off += skip;` | `test_every_opcode_decodes` |
| 2 | `off += (uint64_t)imm * 8;` | `off += imm;` | `test_every_opcode_decodes` |
| 3 | `out->end = here;` | `(void)here;` | `test_every_opcode_decodes` ("DONE found at") |
| 4 | `if (seg < 0)` | `if (0)` | `test_malformed_streams_are_refused` ("a rebase before any segment") |
| 5 | `if (imm >= nsegs)` | `if (0)` | `test_malformed_streams_are_refused` ("a segment the image lacks") |
| 6 | in `mrb_fail`, `mrb_free(s);` | `(void)s;` | `test_malformed_streams_are_refused` ("slots decoded before a refusal") |
| 7 | `dups += mrb_cmp(&s->v[i - 1], &s->v[i]) == 0;` | `dups += 0;` | `test_sort_counts_repeats_and_has_finds` |
| 8 | `if (run <= REBASE_IMMEDIATE_MASK) {` | `if (run < REBASE_IMMEDIATE_MASK) {` | `test_encode_pins_its_opcodes` ("fifteen fit the immediate") |
| 9 | `if (k && mrb_cmp(&v[k - 1], &v[k]) >= 0) return MRB_MALFORMED;` | (delete the line) | `test_encode_refuses_what_it_cannot_say` |

- [ ] **Step 8: Commit**

```bash
git add src/rebase.h src/rebase.c tests/rebase_test.c CMakeLists.txt
git commit -m "feat(rebase): decode every classic rebase opcode, encode sorted slots

md_next_rebase reads only the two opcodes fixups set classic emits. The
method-list conversion reads streams ld64 wrote too, and must re-read its
own output, so it needs all nine; and it needs an encoder for the slots
it adds.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 3: Resolve an entry the way Decision 3 says (`mml_resolver`, `mml_entry_at`)

**Files:**
- Modify: `tests/relmeth_fixture.h` (anchors in the edits below; `:18` `#define RMF_SIZE`, `:56` `#define RMF_LINKEDIT_SIZE`, `:60` `#define RMF_CHAINED_BLOB`, `:80`–`:81` `RMF_METAOUT` and `};`, `:151`–`:152` in `rmf_rebase_slots`, `:187` the `rmf_build` comment, `:232`–`:234` list A, `:287`–`:290` the `LC_DYLD_INFO_ONLY` block, `:302`–`:307` the chained block and `return RMF_SIZE;`)
- Modify: `tests/mkrelmeth.c:8-15` (`VARIANTS`)
- Modify: `src/objc_meth.h:10` (`#include "image.h"`), `:41-44` (`mml_walk_image` … `#endif`)
- Modify: `src/objc_meth.c:8-11` (`#include "objc_meth.h"` … `#define MML_MAX_SEGS   64`), end of file (`:276`, the `}` closing `mml_walk_free`)
- Test: `tests/objc_meth_test.c` (before `:198` `int main(void) {`, and in `main` after `:208` `test_every_category_and_protocol_slot_is_read();`)

**Interfaces:**
- Consumes: `mrb_decode`, `mrb_add`, `mrb_sort`, `mrb_has`, `mrb_free`, `mrb_set` (Task 2); `mo_bind_observe`, `mo_bind_state` (`src/ordinals.h:305`); `mg_funcstarts_decode`, `mg_addr_known` (`src/grow.h:140`, `:321`); `mi_image_base` (`src/image.h:171`).
- Produces (Tasks 5 and 6 call these), in `src/objc_meth.h`:
  - `#define MML_MAX_SEGS 64` (moved here from `src/objc_meth.c`)
  - `typedef struct { uint64_t name, types, imp; } mml_entry;`
  - `typedef struct { uint64_t addr, size; uint32_t offset, flags; } mml_sect;`
  - `typedef struct { const mi_image *im; struct { uint64_t vmaddr, vmsize, fileoff, filesize; } segs[MML_MAX_SEGS]; int nsegs; mml_sect *sects; uint32_t nsects; mrb_set rebases, binds; uint64_t *starts; int nstarts; } mml_resolver;`
  - `int mml_resolver_open(const mi_image *im, mml_resolver *r, char *why, size_t whysz);` `void mml_resolver_close(mml_resolver *r);`
  - `int mml_entry_at(const mml_resolver *r, const mml_ref *ref, uint32_t i, mml_entry *e, char *why, size_t whysz);` → `MML_OK` or `MML_MALFORMED`
  - `int mml_seg_of(const mml_resolver *r, uint64_t va, uint64_t len);` `int mml_off_rebased(const mml_resolver *r, uint64_t off);`
- Fixture variant bits added (Tasks 5–7 use them): `RMF_SELBIND` (1<<14), `RMF_FSTARTS` (1<<15), `RMF_FSBAD` (1<<16), `RMF_NOSLOTRB` (1<<17); blobs `RMF_BIND_BLOB` 0x2100, `RMF_FSTARTS_BLOB` 0x2120; `RMF_SIZE` becomes 0x2200 and `RMF_LINKEDIT_SIZE` 0x200.

**Plan decision:** the resolver goes in `src/objc_meth.[ch]`, beside the walk. Why: it reads the same image the walk reads and changes nothing, and it is what "see the lists" needs next; the file that writes (Task 4) stays separate.

**Plan decision:** a selector reference with no rebase is refused either way, and the message says "bound to another image" when the bind stream (not the lazy or weak one) binds it. Why: the spec gives the bind case its own reason ("the name comes from another image"), and a person reading the refusal should see which one they have.

**Plan decision:** an `LC_FUNCTION_STARTS` that decodes to no starts is treated as absent. Why: `mg_plausible` answers that case "nothing to check against" (`src/grow.c`, the `ns == 0` branch), and one image should not get two answers.

**Plan decision:** the fixture grows from 0x2100 to 0x2200 bytes, `__LINKEDIT` from 0x100 to 0x200, to hold this task's bind stream and function starts and Task 4's split info and code signature; and list A's two entries become (beta, alpha). Why: every blob gets its own fixed offset instead of sharing one with the chained blob, and a descending list is what catches a conversion that sorts (Decision 4: order is preserved). M1's tests read counts and headers, never list A's entry order, and still pass.

- [ ] **Step 1: Add the fixture variants**

Apply these edits to `tests/relmeth_fixture.h`, in order:

Edit 1. Replace:

```c
#define RMF_SIZE         0x2100u
```

with:

```c
#define RMF_SIZE         0x2200u
```

Edit 2. Replace:

```c
#define RMF_LINKEDIT_SIZE 0x100u
```

with:

```c
#define RMF_LINKEDIT_SIZE 0x200u
```

Edit 3. Replace:

```c
#define RMF_CHAINED_BLOB 0x20c0u
```

with:

```c
#define RMF_CHAINED_BLOB 0x20c0u
#define RMF_BIND_BLOB    0x2100u
#define RMF_FSTARTS_BLOB 0x2120u
```

Edit 4. Replace:

```c
    RMF_METAOUT  = 1u << 13  /* the class's isa names the address just past the file */
};
```

with:

```c
    RMF_METAOUT  = 1u << 13, /* the class's isa names the address just past the file */
    RMF_SELBIND  = 1u << 14, /* the second selector reference is bound, not rebased */
    RMF_FSTARTS  = 1u << 15, /* LC_FUNCTION_STARTS names all four implementations */
    RMF_FSBAD    = 1u << 16, /* LC_FUNCTION_STARTS leaves out list C's implementation */
    RMF_NOSLOTRB = 1u << 17  /* the class ro's baseMethods slot carries no rebase */
};
```

Edit 5. Replace:

```c
    for (uint32_t i = 0; i < 4; i++) out[n++] = RMF_SELREFS - RMF_DATA + 8 * i;
    out[n++] = RMF_CLASS_RO + 32 - RMF_DATA;
```

with:

```c
    for (uint32_t i = 0; i < 4; i++)
        if (i != 1 || !(v & RMF_SELBIND)) out[n++] = RMF_SELREFS - RMF_DATA + 8 * i;
    if (!(v & RMF_NOSLOTRB)) out[n++] = RMF_CLASS_RO + 32 - RMF_DATA;
```

Edit 6. Replace:

```c
/* Lays the image out in b[0, RMF_SIZE) and returns RMF_SIZE. */
```

with:

```c
/* Binds the second selector reference to _rmf_sel from ordinal 1. */
static inline uint32_t rmf_binds(uint8_t *b) {
    uint32_t at = RMF_BIND_BLOB;
    b[at++] = BIND_OPCODE_SET_DYLIB_ORDINAL_IMM | 1;
    b[at++] = BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM;
    memcpy(b + at, "_rmf_sel", 9);
    at += 9;
    b[at++] = BIND_OPCODE_SET_TYPE_IMM | BIND_TYPE_POINTER;
    b[at++] = BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB | 2;
    at += rmf_uleb(b + at, RMF_SELREFS + 8 - RMF_DATA);
    b[at++] = BIND_OPCODE_DO_BIND;
    b[at++] = BIND_OPCODE_DONE;
    return at - RMF_BIND_BLOB;
}

/* Lays the image out in b[0, RMF_SIZE) and returns RMF_SIZE. */
```

Edit 7. Replace:

```c
    rmf_rel_entry(b, RMF_LIST_A + 8,  RMF_SELREFS + 0, RMF_TEXT + 0);
    rmf_rel_entry(b, RMF_LIST_A + 20, RMF_SELREFS + 8, RMF_TEXT + 4);
```

with:

```c
    /* beta before alpha: descending, so a conversion that sorts is caught */
    rmf_rel_entry(b, RMF_LIST_A + 8,  RMF_SELREFS + 8, RMF_TEXT + 0);
    rmf_rel_entry(b, RMF_LIST_A + 20, RMF_SELREFS + 0, RMF_TEXT + 4);
```

Edit 8. Replace:

```c
        di->rebase_size = (rmf_rebases(b, v) + 7) & ~7u;
    }
```

with:

```c
        di->rebase_size = (rmf_rebases(b, v) + 7) & ~7u;
        if (v & RMF_SELBIND) {
            di->bind_off = RMF_BIND_BLOB;
            di->bind_size = (rmf_binds(b) + 7) & ~7u;
        }
    }
```

Edit 9. Replace:

```c
        cf->datasize = 0x20;
    }
    return RMF_SIZE;
```

with:

```c
        cf->datasize = 0x20;
    }
    if (v & (RMF_FSTARTS | RMF_FSBAD)) {
        static const uint8_t all[] = { 0x80, 0x10, 4, 4, 4, 0 }, bad[] = { 0x80, 0x10, 4, 4, 0 };
        struct linkedit_data_command *fs = rmf_lc(b, &at, LC_FUNCTION_STARTS, sizeof *fs);
        fs->dataoff = RMF_FSTARTS_BLOB;
        fs->datasize = 8;
        if (v & RMF_FSBAD) memcpy(b + RMF_FSTARTS_BLOB, bad, sizeof bad);
        else               memcpy(b + RMF_FSTARTS_BLOB, all, sizeof all);
    }
    return RMF_SIZE;
```

In `tests/mkrelmeth.c`, replace the `VARIANTS` line `{ "metaout", RMF_METAOUT },` (`:14`) with:

```c
    { "metaout", RMF_METAOUT }, { "selbind", RMF_SELBIND }, { "fstarts", RMF_FSTARTS },
    { "fsbad", RMF_FSBAD },     { "noslotrb", RMF_NOSLOTRB },
```

- [ ] **Step 2: Write the failing tests**

In `tests/objc_meth_test.c`, insert before `int main(void) {` (`:198`):

```c
/* ---- resolving entries ------------------------------------------------------ */

/* Builds `variant`, lets `poke` edit it, and opens a walk and a resolver on it. */
typedef struct { mi_image im; mml_walk w; mml_resolver r; int rc; char why[256]; } opened;

static int open_poked(unsigned variant, void (*poke)(uint8_t *), opened *o) {
    memset(o, 0, sizeof *o);
    rmf_build(fx, variant);
    if (poke) poke(fx);
    if (mi_wrap(fx, RMF_SIZE, &o->im) != 0) {
        printf("FAIL: fixture variant %#x does not wrap\n", variant);
        fails++;
        return -1;
    }
    if ((o->rc = mml_walk_image(&o->im, &o->w)) != MML_OK) return -1;
    return o->rc = mml_resolver_open(&o->im, &o->r, o->why, sizeof o->why);
}

static void close_opened(opened *o) {
    mml_walk_free(&o->w);
    mml_resolver_close(&o->r);
}

static const mml_ref *ref_naming(const mml_walk *w, uint32_t list) {
    for (uint32_t i = 0; i < w->n; i++)
        if (w->refs[i].list_va == RMF_VA(list)) return &w->refs[i];
    return NULL;
}

static void check_entry(const opened *o, uint32_t list, uint32_t i, uint32_t name_off,
                        uint64_t imp, const char *label) {
    const mml_ref *ref = ref_naming(&o->w, list);
    mml_entry e;
    char why[256] = "";
    int rc = ref ? mml_entry_at(&o->r, ref, i, &e, why, sizeof why) : -99;
    CHECK(rc == MML_OK, "%s: rc %d (%s)", label, rc, why);
    if (rc == MML_OK)
        CHECK(e.name == RMF_VA(RMF_METHNAME + name_off) && e.types == RMF_VA(RMF_METHTYPE) &&
              e.imp == imp, "%s: (%#llx, %#llx, %#llx); want (%#llx, %#llx, %#llx)", label,
              (unsigned long long)e.name, (unsigned long long)e.types, (unsigned long long)e.imp,
              (unsigned long long)RMF_VA(RMF_METHNAME + name_off),
              (unsigned long long)RMF_VA(RMF_METHTYPE), (unsigned long long)imp);
}

static void test_relative_entries_resolve_through_their_selector_references(void) {
    opened o;
    int rc = open_poked(RMF_PLAIN, NULL, &o);
    CHECK(rc == MML_OK, "resolve plain: rc %d (%s)", rc, o.why);
    if (rc == MML_OK) {
        check_entry(&o, RMF_LIST_A, 0, 0x10, RMF_VA(RMF_TEXT + 0), "list A entry 0 (beta)");
        check_entry(&o, RMF_LIST_A, 1, 0x00, RMF_VA(RMF_TEXT + 4), "list A entry 1 (alpha)");
        check_entry(&o, RMF_LIST_B, 0, 0x20, RMF_VA(RMF_TEXT + 8), "list B entry 0 (gamma)");
        check_entry(&o, RMF_LIST_D, 0, 0x00, 0, "list D entry 0, which has no IMP");
    }
    close_opened(&o);
}

static void test_absolute_entries_are_read_as_they_are(void) {
    opened o;
    int rc = open_poked(RMF_ABSCAT, NULL, &o);
    CHECK(rc == MML_OK, "resolve abscat: rc %d (%s)", rc, o.why);
    if (rc == MML_OK) check_entry(&o, RMF_ABS_C, 0, 0x30, RMF_VA(RMF_TEXT + 12), "absolute list C");
    close_opened(&o);
}

static void test_function_starts_admit_every_imp_they_name(void) {
    opened o;
    int rc = open_poked(RMF_FSTARTS, NULL, &o);
    CHECK(rc == MML_OK && o.r.nstarts == 4, "fstarts: rc %d, %d starts (%s)", rc, o.r.nstarts, o.why);
    if (rc == MML_OK) check_entry(&o, RMF_LIST_C, 0, 0x30, RMF_VA(RMF_TEXT + 12), "fstarts list C");
    close_opened(&o);
}

static void poke_misaligned(uint8_t *b)   { uint32_t d; memcpy(&d, b + RMF_LIST_A + 8, 4); d += 4; memcpy(b + RMF_LIST_A + 8, &d, 4); }
static void poke_selref_const(uint8_t *b) { rmf_put64(b, RMF_SELREFS + 8, RMF_VA(RMF_CLASS_RO)); }
static void poke_types_open(uint8_t *b)   { memset(b + RMF_METHTYPE, 'v', 0x10); }
static void poke_imp_data(uint8_t *b)     {
    rmf_put32(b, RMF_LIST_A + 16, (uint32_t)(int32_t)((int64_t)RMF_METHNAME - (int64_t)(RMF_LIST_A + 16)));
}
static void poke_selref_outside(uint8_t *b) {
    rmf_put32(b, RMF_LIST_A + 8, (uint32_t)(int32_t)((int64_t)RMF_SIZE + 0x1000 - (int64_t)(RMF_LIST_A + 8)));
}

static void refused_entry(unsigned variant, void (*poke)(uint8_t *), uint32_t list, uint32_t i,
                          const char *want, const char *label) {
    opened o;
    mml_entry e;
    char why[256] = "";
    int rc = open_poked(variant, poke, &o);
    const mml_ref *ref = rc == MML_OK ? ref_naming(&o.w, list) : NULL;
    CHECK(ref != NULL, "%s: no list to resolve (rc %d, %s)", label, rc, o.why);
    if (ref) {
        rc = mml_entry_at(&o.r, ref, i, &e, why, sizeof why);
        CHECK(rc == MML_MALFORMED, "%s: rc %d, want MML_MALFORMED", label, rc);
        CHECK(strstr(why, want) != NULL, "%s: why '%s' lacks '%s'", label, why, want);
    }
    close_opened(&o);
}

static void test_entries_that_cannot_be_made_absolute_are_refused(void) {
    refused_entry(RMF_SELBIND, NULL, RMF_LIST_A, 0, "is bound to another image", "a bound selector reference");
    refused_entry(RMF_PLAIN, poke_misaligned, RMF_LIST_A, 0, "not 8-byte aligned", "a misaligned selector reference");
    refused_entry(RMF_PLAIN, poke_selref_outside, RMF_LIST_A, 0, "outside the file", "a selector reference past the file");
    refused_entry(RMF_PLAIN, poke_selref_const, RMF_LIST_A, 0, "is not a C string", "a selector reference into __objc_const");
    refused_entry(RMF_PLAIN, poke_types_open, RMF_LIST_A, 0, "types at", "types with no NUL in their section");
    refused_entry(RMF_PLAIN, poke_imp_data, RMF_LIST_A, 0, "not in a section of instructions", "an IMP into __objc_methname");
    refused_entry(RMF_FSBAD, NULL, RMF_LIST_C, 0, "not one of the 3 function starts", "an IMP that is not a function start");
}

static void poke_unbind(uint8_t *b) { memset(b + RMF_BIND_BLOB, 0, 0x20); }

static void test_selector_references_without_a_rebase_or_bind_are_named_so(void) {
    opened o;
    int rc = open_poked(RMF_NOSLOTRB, NULL, &o);
    CHECK(rc == MML_OK, "noslotrb: rc %d (%s)", rc, o.why);
    CHECK(!mml_off_rebased(&o.r, RMF_CLASS_RO + 32), "noslotrb: the class ro's slot reads as rebased");
    CHECK(mml_off_rebased(&o.r, RMF_META_RO + 32), "noslotrb: the metaclass ro's slot reads as not rebased");
    close_opened(&o);
    refused_entry(RMF_SELBIND, poke_unbind, RMF_LIST_A, 0, "carries no rebase",
                  "a selector reference neither rebased nor bound");
}
```

and in `main`, after `test_every_category_and_protocol_slot_is_read();` (`:208`):

```c
    test_relative_entries_resolve_through_their_selector_references();
    test_absolute_entries_are_read_as_they_are();
    test_function_starts_admit_every_imp_they_name();
    test_entries_that_cannot_be_made_absolute_are_refused();
    test_selector_references_without_a_rebase_or_bind_are_named_so();
```

- [ ] **Step 3: Run to see it fail**

Run: build.
Expected: `objc_meth_test` does not compile: `unknown type name 'mml_resolver'` (and `mml_entry`).

- [ ] **Step 4: Declare the resolver in `src/objc_meth.h`**

After `#include "image.h"` (`:10`) add `#include "rebase.h"`. Before the final `#endif` (`:44`), after `void mml_walk_free(mml_walk *w);`, add:

```c

/* One method, as the 10.9 runtime reads an absolute entry: the selector's
 * name string, the type string and the implementation (0 for none), each an
 * unslid address in the image. */
typedef struct { uint64_t name, types, imp; } mml_entry;

#define MML_MAX_SEGS 64

typedef struct { uint64_t addr, size; uint32_t offset, flags; } mml_sect;

/* What resolving an entry consults, gathered once per image: the segments
 * in load-command order, every section, the rebase stream's slots and the
 * bind stream's (both sorted), and LC_FUNCTION_STARTS' addresses when the
 * image lists any. */
typedef struct {
    const mi_image *im;
    struct { uint64_t vmaddr, vmsize, fileoff, filesize; } segs[MML_MAX_SEGS];
    int       nsegs;
    mml_sect *sects;
    uint32_t  nsects;
    mrb_set   rebases, binds;
    uint64_t *starts;
    int       nstarts;       /* -1 when there is nothing to check an IMP against */
} mml_resolver;

/* MML_OK, or MML_MALFORMED / MML_NOMEM with why set and nothing to close.
 * An image with no LC_DYLD_INFO[_ONLY] opens with empty rebase and bind sets. */
int  mml_resolver_open(const mi_image *im, mml_resolver *r, char *why, size_t whysz);
void mml_resolver_close(mml_resolver *r);

/* Entry `i` of the list `ref` names. An absolute entry is read. A relative
 * one is resolved and checked: its selector reference is 8-byte aligned,
 * file-backed and rebased, and holds the address of a string NUL-terminated
 * within an S_CSTRING_LITERALS section; its types are such a string; its
 * IMP is 0, or lies in a section of instructions and, when the image lists
 * function starts, is one. MML_OK, or MML_MALFORMED with why set. */
int  mml_entry_at(const mml_resolver *r, const mml_ref *ref, uint32_t i, mml_entry *e,
                  char *why, size_t whysz);

/* The segment whose file bytes hold [va, va + len), or -1. */
int  mml_seg_of(const mml_resolver *r, uint64_t va, uint64_t len);

/* 1 when the 8 bytes at file offset `off` carry a rebase. */
int  mml_off_rebased(const mml_resolver *r, uint64_t off);
```

- [ ] **Step 5: Implement it in `src/objc_meth.c`**

Replace `:8-11`:

```c
#include "objc_meth.h"
#include "mach_compat.h"

#define MML_MAX_SEGS   64
```

with:

```c
#include "objc_meth.h"
#include "grow.h"
#include "ordinals.h"
#include "mach_compat.h"

```

and append, after `mml_walk_free`'s closing `}` (`:276`):

```c

/* ---- resolving entries ---------------------------------------------------- */

static int mml_rfail(char *why, size_t whysz, int code, const char *fmt, ...)
    __attribute__((format(printf, 4, 5)));
static int mml_rfail(char *why, size_t whysz, int code, const char *fmt, ...) {
    va_list ap;
    if (why && whysz) {
        va_start(ap, fmt);
        vsnprintf(why, whysz, fmt, ap);
        va_end(ap);
    }
    return code;
}

typedef struct {
    mml_resolver *r;
    const struct dyld_info_command *di;
    const struct linkedit_data_command *fs;
    int err;
} mml_open_ctx;

static int mml_open_lc(const struct load_command *lc, void *ctx_) {
    mml_open_ctx *c = ctx_;
    mml_resolver *r = c->r;
    if (lc->cmd == LC_DYLD_INFO || lc->cmd == LC_DYLD_INFO_ONLY) {
        c->di = (const struct dyld_info_command *)lc;
    } else if (lc->cmd == LC_FUNCTION_STARTS) {
        c->fs = (const struct linkedit_data_command *)lc;
    } else if (lc->cmd == LC_SEGMENT_64) {
        const struct segment_command_64 *sc = (const struct segment_command_64 *)lc;
        const struct section_64 *s = (const struct section_64 *)(sc + 1);
        if (r->nsegs == MML_MAX_SEGS) { c->err = MML_MALFORMED; return 1; }
        r->segs[r->nsegs].vmaddr = sc->vmaddr;
        r->segs[r->nsegs].vmsize = sc->vmsize;
        r->segs[r->nsegs].fileoff = sc->fileoff;
        r->segs[r->nsegs].filesize = sc->filesize;
        r->nsegs++;
        if (sc->nsects) {
            mml_sect *p = realloc(r->sects, (r->nsects + sc->nsects) * sizeof *p);
            if (!p) { c->err = MML_NOMEM; return 1; }
            r->sects = p;
            for (uint32_t k = 0; k < sc->nsects; k++, r->nsects++) {
                p[r->nsects].addr = s[k].addr;
                p[r->nsects].size = s[k].size;
                p[r->nsects].offset = s[k].offset;
                p[r->nsects].flags = s[k].flags;
            }
        }
    }
    return 0;
}

static void mml_note_bind(const mo_bind_state *st, void *ctx_) {
    mml_open_ctx *c = ctx_;
    uint64_t off = st->offset;
    if (c->err || st->seg < 0 || st->seg > 255) return;
    for (uint64_t k = 0; k < st->count && !c->err; k++, off += 8 + st->skip)
        if (mrb_add(&c->r->binds, (uint8_t)st->seg, 0, off) != 0) c->err = MML_NOMEM;
}

static int mml_fits(uint64_t off, uint64_t len, size_t size) {
    return off <= size && len <= size - off;
}

int mml_resolver_open(const mi_image *im, mml_resolver *r, char *why, size_t whysz) {
    mml_open_ctx c;
    int rc;
    memset(r, 0, sizeof *r);
    memset(&c, 0, sizeof c);
    r->im = im;
    r->nstarts = -1;
    c.r = r;
    mi_each_lc(im, mml_open_lc, &c);
    if (c.err == MML_NOMEM) {
        mml_resolver_close(r);
        return mml_rfail(why, whysz, MML_NOMEM, "out of memory");
    }
    if (c.err) {
        mml_resolver_close(r);
        return mml_rfail(why, whysz, MML_MALFORMED, "more than %d segments", MML_MAX_SEGS);
    }
    if (c.di && c.di->rebase_size) {
        if (!mml_fits(c.di->rebase_off, c.di->rebase_size, im->size)) {
            mml_resolver_close(r);
            return mml_rfail(why, whysz, MML_MALFORMED, "the rebase stream lies outside the file");
        }
        rc = mrb_decode(im->buf + c.di->rebase_off, c.di->rebase_size, r->nsegs, &r->rebases,
                        why, whysz);
        if (rc != MRB_OK) {
            mml_resolver_close(r);
            return rc == MRB_NOMEM ? MML_NOMEM : MML_MALFORMED;
        }
    }
    if (c.di && c.di->bind_size) {
        if (!mml_fits(c.di->bind_off, c.di->bind_size, im->size) ||
            mo_bind_observe(im->buf + c.di->bind_off, c.di->bind_size, "bind",
                            mml_note_bind, &c) != 0) {
            mml_resolver_close(r);
            return mml_rfail(why, whysz, MML_MALFORMED, "the bind stream does not decode");
        }
        if (c.err) {
            mml_resolver_close(r);
            return mml_rfail(why, whysz, MML_NOMEM, "out of memory");
        }
    }
    mrb_sort(&r->rebases);
    mrb_sort(&r->binds);
    if (c.fs && c.fs->datasize) {
        uint64_t base;
        int n;
        if (!mml_fits(c.fs->dataoff, c.fs->datasize, im->size) || mi_image_base(im, &base) != 0) {
            mml_resolver_close(r);
            return mml_rfail(why, whysz, MML_MALFORMED, "LC_FUNCTION_STARTS lies outside the file");
        }
        if (!(r->starts = malloc((size_t)c.fs->datasize * sizeof *r->starts))) {
            mml_resolver_close(r);
            return mml_rfail(why, whysz, MML_NOMEM, "out of memory");
        }
        n = mg_funcstarts_decode(im->buf + c.fs->dataoff, c.fs->datasize, base, r->starts,
                                 (int)c.fs->datasize);
        if (n < 0) {
            mml_resolver_close(r);
            return mml_rfail(why, whysz, MML_MALFORMED, "LC_FUNCTION_STARTS does not decode");
        }
        r->nstarts = n ? n : -1;
    }
    return MML_OK;
}

void mml_resolver_close(mml_resolver *r) {
    free(r->sects);
    free(r->starts);
    mrb_free(&r->rebases);
    mrb_free(&r->binds);
    r->sects = NULL;
    r->starts = NULL;
    r->nsects = 0;
}

int mml_seg_of(const mml_resolver *r, uint64_t va, uint64_t len) {
    for (int i = 0; i < r->nsegs; i++) {
        uint64_t rel = va - r->segs[i].vmaddr;
        if (va < r->segs[i].vmaddr || rel >= r->segs[i].filesize) continue;
        if (len > r->segs[i].filesize - rel ||
            !mml_fits(r->segs[i].fileoff + rel, len, r->im->size)) return -1;
        return i;
    }
    return -1;
}

int mml_off_rebased(const mml_resolver *r, uint64_t off) {
    for (int i = 0; i < r->nsegs; i++)
        if (off >= r->segs[i].fileoff && off - r->segs[i].fileoff < r->segs[i].filesize)
            return mrb_has(&r->rebases, (uint8_t)i, off - r->segs[i].fileoff);
    return 0;
}

static const mml_sect *mml_sect_at(const mml_resolver *r, uint64_t va) {
    for (uint32_t k = 0; k < r->nsects; k++)
        if (va >= r->sects[k].addr && va - r->sects[k].addr < r->sects[k].size) return &r->sects[k];
    return NULL;
}

static int mml_cstring(const mml_resolver *r, uint64_t va) {
    const mml_sect *s = mml_sect_at(r, va);
    if (!s || (s->flags & SECTION_TYPE) != S_CSTRING_LITERALS || !s->offset ||
        !mml_fits(s->offset, s->size, r->im->size)) return 0;
    return memchr(r->im->buf + s->offset + (va - s->addr), 0, s->size - (va - s->addr)) != NULL;
}

int mml_entry_at(const mml_resolver *r, const mml_ref *ref, uint32_t i, mml_entry *e,
                 char *why, size_t whysz) {
    const uint8_t *buf = r->im->buf;
    if (!(ref->header & MML_RELATIVE)) {
        const uint8_t *p = buf + ref->list_off + 8 + (uint64_t)MML_ABS_ENTSIZE * i;
        memcpy(&e->name, p, 8);
        memcpy(&e->types, p + 8, 8);
        memcpy(&e->imp, p + 16, 8);
        return MML_OK;
    }
    uint64_t va = ref->list_va + 8 + (uint64_t)MML_REL_ENTSIZE * i;
    int32_t d[3];
    memcpy(d, buf + ref->list_off + 8 + (uint64_t)MML_REL_ENTSIZE * i, sizeof d);
    uint64_t slot = va + (uint64_t)(int64_t)d[0];
    uint64_t types = va + 4 + (uint64_t)(int64_t)d[1];
    uint64_t imp = d[2] ? va + 8 + (uint64_t)(int64_t)d[2] : 0;
    const unsigned long long lva = (unsigned long long)ref->list_va;
    int si;

    if (slot & 7)
        return mml_rfail(why, whysz, MML_MALFORMED, "entry %u of the method list at 0x%llx names "
                         "a selector reference at 0x%llx, which is not 8-byte aligned",
                         i, lva, (unsigned long long)slot);
    if ((si = mml_seg_of(r, slot, 8)) < 0)
        return mml_rfail(why, whysz, MML_MALFORMED, "entry %u of the method list at 0x%llx names "
                         "a selector reference at 0x%llx, which lies outside the file",
                         i, lva, (unsigned long long)slot);
    uint64_t rel = slot - r->segs[si].vmaddr;
    if (!mrb_has(&r->rebases, (uint8_t)si, rel))
        return mml_rfail(why, whysz, MML_MALFORMED, "entry %u of the method list at 0x%llx names "
                         "the selector reference at 0x%llx, which %s", i, lva, (unsigned long long)slot,
                         mrb_has(&r->binds, (uint8_t)si, rel)
                             ? "is bound to another image, so its name is not in this one"
                             : "carries no rebase");
    memcpy(&e->name, buf + r->segs[si].fileoff + rel, 8);
    if (!mml_cstring(r, e->name))
        return mml_rfail(why, whysz, MML_MALFORMED, "entry %u of the method list at 0x%llx: the "
                         "selector reference at 0x%llx holds 0x%llx, which is not a C string",
                         i, lva, (unsigned long long)slot, (unsigned long long)e->name);
    if (!mml_cstring(r, types))
        return mml_rfail(why, whysz, MML_MALFORMED, "entry %u of the method list at 0x%llx: its "
                         "types at 0x%llx are not a C string", i, lva, (unsigned long long)types);
    if (imp) {
        const mml_sect *s = mml_sect_at(r, imp);
        if (!s || !(s->flags & (S_ATTR_SOME_INSTRUCTIONS | S_ATTR_PURE_INSTRUCTIONS)))
            return mml_rfail(why, whysz, MML_MALFORMED, "entry %u of the method list at 0x%llx: "
                             "its implementation at 0x%llx is not in a section of instructions",
                             i, lva, (unsigned long long)imp);
        if (r->nstarts > 0 && !mg_addr_known(r->starts, r->nstarts, imp))
            return mml_rfail(why, whysz, MML_MALFORMED, "entry %u of the method list at 0x%llx: "
                             "its implementation at 0x%llx is not one of the %d function starts "
                             "in LC_FUNCTION_STARTS", i, lva, (unsigned long long)imp, r->nstarts);
    }
    e->types = types;
    e->imp = imp;
    return MML_OK;
}
```

- [ ] **Step 6: Build and run**

Run: build (rebuild check on `$B/objc_meth_test`), `"$B/objc_meth_test"`.
Expected: `objc_meth_test: 0 failure(s)`. Then the whole suite: all pass (M1's `cli_test` block reads the enlarged fixture the same way).

- [ ] **Step 7: Mutation proof** (file `src/objc_meth.c`; test `$B/objc_meth_test`)

| # | replace | with | must fail |
|---|---|---|---|
| 1 | `if (slot & 7)` | `if (0)` | `test_entries_that_cannot_be_made_absolute_are_refused` ("a misaligned selector reference") |
| 2 | `if ((si = mml_seg_of(r, slot, 8)) < 0)` | `if ((si = mml_seg_of(r, slot, 8)) < -1)` | same test ("a selector reference past the file") |
| 3 | `if (!mrb_has(&r->rebases, (uint8_t)si, rel))` | `if (0)` | same test ("a bound selector reference"); `test_selector_references_without_a_rebase_or_bind_are_named_so` |
| 4 | `? "is bound to another image, so its name is not in this one"` | `? "carries no rebase"` | `test_entries_...` ("a bound selector reference") |
| 5 | `memcpy(&e->name, buf + r->segs[si].fileoff + rel, 8);` | `e->name = slot;` | `test_relative_entries_resolve_through_their_selector_references` |
| 6 | `(s->flags & SECTION_TYPE) != S_CSTRING_LITERALS \|\|` | (delete) | `test_entries_...` ("a selector reference into __objc_const") |
| 7 | `return memchr(r->im->buf + s->offset + (va - s->addr), 0, s->size - (va - s->addr)) != NULL;` | `return 1;` | `test_entries_...` ("types with no NUL in their section") |
| 8 | `if (!s \|\| !(s->flags & (S_ATTR_SOME_INSTRUCTIONS \| S_ATTR_PURE_INSTRUCTIONS)))` | `if (0)` | `test_entries_...` ("an IMP into __objc_methname") |
| 9 | `if (r->nstarts > 0 && !mg_addr_known(` | `if (0 && !mg_addr_known(` | `test_entries_...` ("an IMP that is not a function start") |
| 10 | `uint64_t imp = d[2] ? va + 8 + (uint64_t)(int64_t)d[2] : 0;` | `uint64_t imp = d[2] ? va + (uint64_t)(int64_t)d[2] : 0;` | `test_relative_entries_resolve_through_their_selector_references` |

- [ ] **Step 8: Commit**

```bash
git add tests/relmeth_fixture.h tests/mkrelmeth.c tests/objc_meth_test.c src/objc_meth.h src/objc_meth.c
git commit -m "feat(objc): resolve a relative method entry, or say why not

An entry's name is copied out of its selector reference, which must be
aligned, file-backed and rebased, and hold a C string; its types must be
a C string; its IMP must be 0 or in code, and a function start when the
image lists them. A bound selector reference is named as such.

The fixture grows to hold a bind stream and function starts, and list
A's entries now run beta, alpha, so a conversion that sorts is caught.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 4: The layout — D grows, `__LINKEDIT` moves up behind it (`src/objc_abs.[ch]`, part 1)

**Files:**
- Create: `src/objc_abs.h`, `src/objc_abs.c`
- Modify: `CMakeLists.txt:66` (the `add_library` line: `src/objc_meth.c src/rebase.c)` → `src/objc_meth.c src/rebase.c src/objc_abs.c)`)
- Modify: `tests/relmeth_fixture.h` (edits below), `tests/mkrelmeth.c` (`VARIANTS`)
- Test: `tests/objc_meth_test.c` (includes at `:3`–`:9`; new tests before `int main(void) {`; registration after Task 3's)

**Interfaces:**
- Consumes: `ml_bump_all` (`src/linkedit.h:160`), `mi_each_lc`, `mi_wrap`, `mi_find_segment` (`src/image.h`); `MML_MAX_SEGS` (Task 3).
- Produces (Tasks 5 and 6 use these), in `src/objc_abs.h`:
  - `#define MMA_OK 0`, `MMA_NOTHING 1`, `MMA_REFUSED (-1)`, `MMA_NOMEM (-2)`, `MMA_PAGE 0x1000u`
  - `typedef struct { char name[16]; uint64_t vmaddr, vmsize, fileoff, filesize; uint32_t initprot; } mma_seg;`
  - `typedef struct { int d, l; char dname[16]; uint64_t list_va, insert, z; } mma_layout;`
  - `int mma_segments(const mi_image *im, mma_seg *segs, int max);`
  - `int mma_layout_check(const mma_seg *segs, int n, uint64_t file_size, mma_layout *lay, char *why, size_t whysz);`
  - `int mma_insert(const mi_image *im, const mma_layout *lay, const uint8_t *lists, uint64_t lists_len, uint64_t s, const uint8_t *stream, uint32_t r, uint8_t **out, size_t *outsz, char *why, size_t whysz);`
  - static in `src/objc_abs.c`, used by Task 5: `mma_fail(char *why, size_t whysz, int code, const char *fmt, ...)` and `mma_find_info` (an `mi_each_lc` callback that stores the first `LC_DYLD_INFO[_ONLY]` into a `const struct dyld_info_command **`).
- Fixture variant bits added: `RMF_DYLIB` (1<<18), `RMF_ZEROTAIL` (1<<19), `RMF_DATARO` (1<<20), `RMF_GAP` (1<<21), `RMF_SEGAFTER` (1<<22), `RMF_CODESIG` (1<<23), `RMF_SPLIT` (1<<24), `RMF_PAD16` (1<<25); `RMF_PAD` (16), `RMF_SPLIT_BLOB` 0x2130, `RMF_CODESIG_BLOB` 0x2180, `RMF_CODESIG_SIZE` 0x80; `rmf_data_seg(v)` (1 for a dylib, else 2); `rmf_binds(b, v)` gains its `v`.

**Plan decision:** layout, conversion and verification go in a new `src/objc_abs.[ch]` (`mma_`), while their tests stay in `tests/objc_meth_test.c`. Why: `objc_meth.c` only reads, and this writes, and together they would pass 1,200 lines; the spec's Testing table puts M2's conversion tests in `tests/objc_meth_test.c`, and one test binary per subsystem keeps the fixture in one place.

**Plan decision:** `__LINKEDIT`'s vmsize becomes the page-rounded new filesize when that is larger. Why: the new rebase stream makes `__LINKEDIT`'s file bytes grow by R, and on ReactiveObjC and Squirrel that passes their vmsize (Decision 7's list of changed fields omits vmsize); `__LINKEDIT` is the last segment, so its growth in vm moves nothing.

**Plan decision:** refuse when `__LINKEDIT` does not end the file, and when D, once its zero fill is in the file, does not end on a 4096-byte boundary. Why: bytes past `__LINKEDIT` would have to be moved without anyone saying what they are (`import redirect` refuses the same case), and a `__LINKEDIT` file offset that is not page-aligned cannot be mapped; neither holds on any real image seen.

- [ ] **Step 1: Add the fixture variants**

Apply to `tests/relmeth_fixture.h`, in order (Task 3's edits are already in):

Edit 1. Replace:

```c
 * offsets from RMF_VMBASE throughout, so RMF_VA(off) is off's address. */
```

with:

```c
 * offsets from RMF_VMBASE below __LINKEDIT, so RMF_VA(off) is off's address. */
```

Edit 2. Replace:

```c
#define RMF_FSTARTS_BLOB 0x2120u
```

with:

```c
#define RMF_FSTARTS_BLOB 0x2120u
#define RMF_SPLIT_BLOB   0x2130u
#define RMF_CODESIG_BLOB 0x2180u
#define RMF_CODESIG_SIZE 0x80u
#define RMF_PAD          16u       /* the header pad RMF_DYLIB and RMF_PAD16 leave */
```

Edit 3. Replace:

```c
    RMF_NOSLOTRB = 1u << 17  /* the class ro's baseMethods slot carries no rebase */
};
```

with:

```c
    RMF_NOSLOTRB = 1u << 17, /* the class ro's baseMethods slot carries no rebase */
    RMF_DYLIB    = 1u << 18, /* an MH_DYLIB with no __PAGEZERO and RMF_PAD bytes of header pad */
    RMF_ZEROTAIL = 1u << 19, /* __DATA's last 0x1000 of vm is a __bss with no file bytes */
    RMF_DATARO   = 1u << 20, /* __DATA is read-only */
    RMF_GAP      = 1u << 21, /* __LINKEDIT begins a page past __DATA's end in vm */
    RMF_SEGAFTER = 1u << 22, /* a segment __EXTRA follows __LINKEDIT */
    RMF_CODESIG  = 1u << 23, /* LC_CODE_SIGNATURE over the last RMF_CODESIG_SIZE bytes */
    RMF_SPLIT    = 1u << 24, /* LC_SEGMENT_SPLIT_INFO over 8 bytes at RMF_SPLIT_BLOB */
    RMF_PAD16    = 1u << 25  /* an LC_RPATH fills the header to RMF_PAD bytes of pad */
};

/* __DATA's segment index, which rebase and bind opcodes name. */
static inline uint32_t rmf_data_seg(unsigned v) { return (v & RMF_DYLIB) ? 1 : 2; }
```

Edit 4. Replace:

```c
        b[at++] = REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB | 2;
```

with:

```c
        b[at++] = (uint8_t)(REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB | rmf_data_seg(v));
```

Edit 5. Replace:

```c
static inline uint32_t rmf_binds(uint8_t *b) {
```

with:

```c
static inline uint32_t rmf_binds(uint8_t *b, unsigned v) {
```

Edit 6. Replace:

```c
    b[at++] = BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB | 2;
```

with:

```c
    b[at++] = (uint8_t)(BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB | rmf_data_seg(v));
```

Edit 7. Replace:

```c
            di->bind_size = (rmf_binds(b) + 7) & ~7u;
```

with:

```c
            di->bind_size = (rmf_binds(b, v) + 7) & ~7u;
```

Edit 8. Replace:

```c
/* Lays the image out in b[0, RMF_SIZE) and returns RMF_SIZE. */
```

with:

```c
/* The last load command, sized so exactly RMF_PAD bytes of header pad remain. */
static inline void rmf_fill(uint8_t *b, uint32_t *at, uint32_t cmd, uint32_t name_at,
                            const char *name) {
    struct load_command *lc = rmf_lc(b, at, cmd, RMF_TEXT - RMF_PAD - *at);
    uint32_t off = name_at;
    memcpy((uint8_t *)lc + 8, &off, 4);
    memcpy((uint8_t *)lc + name_at, name, strlen(name) + 1);
}

/* Lays the image out in b[0, RMF_SIZE) and returns RMF_SIZE. */
```

Edit 9. Replace:

```c
    uint32_t at = sizeof *h, cat_methods;
```

with:

```c
    uint32_t at = sizeof *h, cat_methods, data_vmsize = (v & RMF_ZEROTAIL) ? 0x2000 : 0x1000;
    uint64_t linkedit_vm = RMF_VA(RMF_DATA) + data_vmsize + ((v & RMF_GAP) ? 0x1000 : 0);
```

Edit 10. Replace:

```c
    h->filetype = MH_EXECUTE;
    h->flags = MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL | MH_PIE;

    rmf_seg(b, &at, "__PAGEZERO", 0, RMF_VMBASE, 0, 0, 0, VM_PROT_NONE);
```

with:

```c
    h->filetype = (v & RMF_DYLIB) ? MH_DYLIB : MH_EXECUTE;
    h->flags = MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL | ((v & RMF_DYLIB) ? 0 : MH_PIE);

    if (!(v & RMF_DYLIB)) rmf_seg(b, &at, "__PAGEZERO", 0, RMF_VMBASE, 0, 0, 0, VM_PROT_NONE);
```

Edit 11. Replace:

```c
    s = rmf_seg(b, &at, "__DATA", RMF_VA(RMF_DATA), 0x1000, RMF_DATA, 0x1000,
                6 + !!(v & (RMF_NLCLS | RMF_SHAREDRO)) + !!(v & RMF_ALLSLOTS), VM_PROT_READ | VM_PROT_WRITE);
```

with:

```c
    s = rmf_seg(b, &at, "__DATA", RMF_VA(RMF_DATA), data_vmsize, RMF_DATA, 0x1000,
                6 + !!(v & (RMF_NLCLS | RMF_SHAREDRO)) + !!(v & RMF_ALLSLOTS) + !!(v & RMF_ZEROTAIL),
                (v & RMF_DATARO) ? VM_PROT_READ : VM_PROT_READ | VM_PROT_WRITE);
```

Edit 12. Replace:

```c
    rmf_seg(b, &at, "__LINKEDIT", RMF_VA(RMF_LINKEDIT), 0x1000, RMF_LINKEDIT,
            RMF_LINKEDIT_SIZE, 0, VM_PROT_READ);
```

with:

```c
    if (v & RMF_ZEROTAIL) {
        rmf_sect(s, "__bss", RMF_LINKEDIT, 0x1000, S_ZEROFILL);
        ((struct section_64 *)(s + 1))[s->nsects - 1].offset = 0;
    }
    rmf_seg(b, &at, "__LINKEDIT", linkedit_vm, 0x1000, RMF_LINKEDIT,
            RMF_LINKEDIT_SIZE, 0, VM_PROT_READ);
    if (v & RMF_SEGAFTER)
        rmf_seg(b, &at, "__EXTRA", linkedit_vm + 0x1000, 0x1000, 0, 0, 0, VM_PROT_READ);
```

Edit 13. Replace:

```c
        else               memcpy(b + RMF_FSTARTS_BLOB, all, sizeof all);
    }
    return RMF_SIZE;
```

with:

```c
        else               memcpy(b + RMF_FSTARTS_BLOB, all, sizeof all);
    }
    if (v & RMF_SPLIT) {
        struct linkedit_data_command *sp = rmf_lc(b, &at, LC_SEGMENT_SPLIT_INFO, sizeof *sp);
        sp->dataoff = RMF_SPLIT_BLOB;
        sp->datasize = 8;
        memcpy(b + RMF_SPLIT_BLOB, "split!!", 8);
    }
    if (v & RMF_CODESIG) {
        struct linkedit_data_command *cs = rmf_lc(b, &at, LC_CODE_SIGNATURE, sizeof *cs);
        cs->dataoff = RMF_CODESIG_BLOB;
        cs->datasize = RMF_CODESIG_SIZE;
        for (uint32_t i = 0; i < RMF_CODESIG_SIZE; i++) b[RMF_CODESIG_BLOB + i] = (uint8_t)(0x80 + i);
    }
    if (v & RMF_DYLIB)  rmf_fill(b, &at, LC_ID_DYLIB, 24, "/rmf/librmf.dylib");
    if (v & RMF_PAD16)  rmf_fill(b, &at, LC_RPATH, 12, "/rmf/rpath");
    return RMF_SIZE;
```

In `tests/mkrelmeth.c`, replace Task 3's line `    { "fsbad", RMF_FSBAD },     { "noslotrb", RMF_NOSLOTRB },` with:

```c
    { "fsbad", RMF_FSBAD },     { "noslotrb", RMF_NOSLOTRB }, { "dylib", RMF_DYLIB },
    { "zerotail", RMF_ZEROTAIL }, { "dataro", RMF_DATARO },  { "gap", RMF_GAP },
    { "segafter", RMF_SEGAFTER }, { "codesig", RMF_CODESIG }, { "split", RMF_SPLIT },
    { "pad16", RMF_PAD16 },
```

- [ ] **Step 2: Write the failing tests**

In `tests/objc_meth_test.c`, after `#include "objc_meth.h"` (`:3`) add `#include "objc_abs.h"`, and after `#include <string.h>` add `#include <mach-o/loader.h>`. Insert before `int main(void) {`:

```c
/* ---- layout ------------------------------------------------------------------ */

static int layout_of(unsigned variant, void (*poke)(uint8_t *), size_t size, mma_layout *lay,
                     char *why, size_t whysz) {
    mi_image im;
    mma_seg segs[MML_MAX_SEGS];
    rmf_build(fx, variant);
    if (poke) poke(fx);
    if (mi_wrap(fx, RMF_SIZE, &im) != 0) return -99;
    return mma_layout_check(segs, mma_segments(&im, segs, MML_MAX_SEGS), size, lay, why, whysz);
}

static void test_layout_puts_the_lists_at_the_end_of_data(void) {
    mma_layout lay;
    char why[256] = "";
    int rc = layout_of(RMF_PLAIN, NULL, RMF_SIZE, &lay, why, sizeof why);
    CHECK(rc == MMA_OK, "layout plain: rc %d (%s)", rc, why);
    CHECK(lay.d == 2 && lay.l == 3 && strncmp(lay.dname, "__DATA", 16) == 0,
          "layout plain: D %d (%.16s), L %d", lay.d, lay.dname, lay.l);
    CHECK(lay.list_va == RMF_VA(RMF_LINKEDIT) && lay.insert == RMF_LINKEDIT && lay.z == 0,
          "layout plain: lists at %#llx, insert %#llx, z %#llx", (unsigned long long)lay.list_va,
          (unsigned long long)lay.insert, (unsigned long long)lay.z);
    rc = layout_of(RMF_DYLIB, NULL, RMF_SIZE, &lay, why, sizeof why);
    CHECK(rc == MMA_OK && lay.d == 1 && lay.l == 2, "layout dylib: rc %d, D %d, L %d (%s)",
          rc, lay.d, lay.l, why);
    rc = layout_of(RMF_ZEROTAIL, NULL, RMF_SIZE, &lay, why, sizeof why);
    CHECK(rc == MMA_OK && lay.z == 0x1000 && lay.list_va == RMF_VA(RMF_DATA + 0x2000) &&
          lay.insert == RMF_LINKEDIT, "layout zerotail: rc %d, z %#llx, lists at %#llx (%s)", rc,
          (unsigned long long)lay.z, (unsigned long long)lay.list_va, why);
}

static void poke_linkedit_fileoff(uint8_t *b) {
    mi_image im;
    struct segment_command_64 *l;
    if (mi_wrap(b, RMF_SIZE, &im) == 0 && (l = mi_find_segment(&im, "__LINKEDIT"))) l->fileoff += 8;
}
static void poke_data_unaligned(uint8_t *b) {
    mi_image im;
    struct segment_command_64 *d, *l;
    if (mi_wrap(b, RMF_SIZE, &im) != 0) return;
    if ((d = mi_find_segment(&im, "__DATA"))) { d->vmsize -= 8; d->filesize -= 8; }
    if ((l = mi_find_segment(&im, "__LINKEDIT"))) { l->vmaddr -= 8; l->fileoff -= 8; l->filesize += 8; }
}

static void refused_layout(unsigned variant, void (*poke)(uint8_t *), size_t size,
                           const char *want, const char *label) {
    mma_layout lay;
    char why[256] = "";
    int rc = layout_of(variant, poke, size, &lay, why, sizeof why);
    CHECK(rc == MMA_REFUSED, "%s: rc %d, want MMA_REFUSED", label, rc);
    CHECK(strstr(why, want) != NULL, "%s: why '%s' lacks '%s'", label, why, want);
}

static void test_layout_refusals(void) {
    mma_seg segs[18];
    mma_layout lay;
    char why[256] = "";
    int rc;
    refused_layout(RMF_DATARO, NULL, RMF_SIZE, "is not writable", "D read-only");
    refused_layout(RMF_GAP, NULL, RMF_SIZE, "in memory", "a gap in vm before __LINKEDIT");
    refused_layout(RMF_SEGAFTER, NULL, RMF_SIZE, "not the last segment", "a segment after __LINKEDIT");
    refused_layout(RMF_PLAIN, poke_linkedit_fileoff, RMF_SIZE + 8, "file offset", "a gap in the file");
    refused_layout(RMF_PLAIN, NULL, RMF_SIZE + 8, "the image is 0x2208 bytes", "bytes past __LINKEDIT");
    refused_layout(RMF_PLAIN, poke_data_unaligned, RMF_SIZE, "page boundary", "D ends mid-page");
    memset(segs, 0, sizeof segs);
    for (int i = 0; i < 18; i++) {
        snprintf(segs[i].name, sizeof segs[i].name, "__S%d", i);
        segs[i].vmaddr = segs[i].fileoff = 0x1000 * (uint64_t)i;
        segs[i].vmsize = segs[i].filesize = 0x1000;
        segs[i].initprot = VM_PROT_READ | VM_PROT_WRITE;
    }
    memcpy(segs[17].name, "__LINKEDIT", 11);
    rc = mma_layout_check(segs, 18, 0x12000, &lay, why, sizeof why);
    CHECK(rc == MMA_REFUSED && strstr(why, "is segment 16") != NULL,
          "D at segment 16: rc %d, why '%s'", rc, why);
    rc = mma_layout_check(segs + 1, 17, 0x12000, &lay, why, sizeof why);
    CHECK(rc == MMA_OK && lay.d == 15, "D at segment 15: rc %d, D %d (%s)", rc, lay.d, why);
}

/* ---- insertion ----------------------------------------------------------------- */

typedef struct { uint8_t *b; size_t n; mma_layout lay; uint32_t r; } inserted;

static const uint8_t LISTS[40] = "the lists, forty bytes of them, padded.";
static const uint8_t STREAM[16] = { 0x11, 0x22, 0x08, 0x51, 0 };

static int insert_into(unsigned variant, void (*poke)(uint8_t *), inserted *o, char *why, size_t whysz) {
    mi_image im;
    int rc;
    memset(o, 0, sizeof *o);
    if ((rc = layout_of(variant, poke, RMF_SIZE, &o->lay, why, whysz)) != MMA_OK) return rc;
    if (mi_wrap(fx, RMF_SIZE, &im) != 0) return -99;
    o->r = sizeof STREAM;
    return mma_insert(&im, &o->lay, LISTS, sizeof LISTS, MMA_PAGE, STREAM, o->r, &o->b, &o->n,
                      why, whysz);
}

typedef struct { const struct segment_command_64 *d, *l; const struct dyld_info_command *di;
                 const struct symtab_command *st; const struct linkedit_data_command *cs, *sp;
                 int nsegs; } lcs_of;

static int note_lc(const struct load_command *lc, void *ctx_) {
    lcs_of *c = ctx_;
    if (lc->cmd == LC_SEGMENT_64) {
        const struct segment_command_64 *sc = (const struct segment_command_64 *)lc;
        if (strncmp(sc->segname, "__DATA", 16) == 0) c->d = sc;
        if (strncmp(sc->segname, "__LINKEDIT", 16) == 0) c->l = sc;
        c->nsegs++;
    }
    if (lc->cmd == LC_DYLD_INFO_ONLY) c->di = (const struct dyld_info_command *)lc;
    if (lc->cmd == LC_SYMTAB) c->st = (const struct symtab_command *)lc;
    if (lc->cmd == LC_CODE_SIGNATURE) c->cs = (const struct linkedit_data_command *)lc;
    if (lc->cmd == LC_SEGMENT_SPLIT_INFO) c->sp = (const struct linkedit_data_command *)lc;
    return 0;
}

static lcs_of lcs(uint8_t *b, size_t n) {
    lcs_of c;
    mi_image im;
    memset(&c, 0, sizeof c);
    if (mi_wrap(b, n, &im) == 0) mi_each_lc(&im, note_lc, &c);
    return c;
}

static void test_insert_moves_linkedit_up_behind_the_lists(void) {
    inserted o;
    uint8_t in[RMF_SIZE];
    char why[256] = "";
    int rc = insert_into(RMF_CODESIG | RMF_SPLIT, NULL, &o, why, sizeof why);
    uint64_t grow = MMA_PAGE + sizeof STREAM;
    memcpy(in, fx, RMF_SIZE);
    CHECK(rc == MMA_OK && o.n == RMF_SIZE + grow, "insert: rc %d, %zu bytes (%s)", rc, o.n, why);
    if (rc != MMA_OK) return;
    lcs_of was = lcs(in, RMF_SIZE), now = lcs(o.b, o.n);
    CHECK(now.d->vmsize == 0x2000 && now.d->filesize == 0x2000, "insert: D is %#llx/%#llx",
          (unsigned long long)now.d->vmsize, (unsigned long long)now.d->filesize);
    CHECK(now.l->vmaddr == was.l->vmaddr + MMA_PAGE && now.l->fileoff == RMF_LINKEDIT + MMA_PAGE &&
          now.l->filesize == RMF_LINKEDIT_SIZE + sizeof STREAM && now.l->vmsize == was.l->vmsize,
          "insert: __LINKEDIT at %#llx/%#llx, %#llx/%#llx bytes", (unsigned long long)now.l->vmaddr,
          (unsigned long long)now.l->fileoff, (unsigned long long)now.l->vmsize,
          (unsigned long long)now.l->filesize);
    CHECK(memcmp(o.b + sizeof(struct mach_header_64) + ((struct mach_header_64 *)in)->sizeofcmds,
                 in + sizeof(struct mach_header_64) + ((struct mach_header_64 *)in)->sizeofcmds,
                 RMF_LINKEDIT - sizeof(struct mach_header_64) - ((struct mach_header_64 *)in)->sizeofcmds) == 0,
          "insert: a byte between the load commands and __LINKEDIT changed");
    CHECK(memcmp(o.b + RMF_LINKEDIT, LISTS, sizeof LISTS) == 0, "insert: the lists are not at D's old end");
    for (size_t i = RMF_LINKEDIT + sizeof LISTS; i < RMF_LINKEDIT + MMA_PAGE; i++)
        if (o.b[i]) { CHECK(0, "insert: byte %#zx past the lists is %#x", i, o.b[i]); break; }
    CHECK(memcmp(o.b + RMF_LINKEDIT + MMA_PAGE, STREAM, sizeof STREAM) == 0,
          "insert: the stream does not start __LINKEDIT");
    CHECK(now.di->rebase_off == RMF_LINKEDIT + MMA_PAGE && now.di->rebase_size == sizeof STREAM,
          "insert: rebase_off %#x size %u", now.di->rebase_off, now.di->rebase_size);
    for (uint32_t i = 0; i < was.di->rebase_size; i++)
        if (o.b[RMF_REBASE + grow + i]) { CHECK(0, "insert: the old rebase stream is not zeroed"); break; }
    CHECK(memcmp(o.b + RMF_REBASE + grow + was.di->rebase_size, in + RMF_REBASE + was.di->rebase_size,
                 RMF_SIZE - RMF_REBASE - was.di->rebase_size) == 0,
          "insert: the rest of the old __LINKEDIT did not move up intact");
    CHECK(now.st->symoff == was.st->symoff + grow && now.st->stroff == was.st->stroff + grow &&
          now.cs->dataoff == was.cs->dataoff + grow && now.sp->dataoff == was.sp->dataoff + grow,
          "insert: an offset in __LINKEDIT did not move by %#llx", (unsigned long long)grow);
    CHECK(memcmp(o.b + now.cs->dataoff, in + RMF_CODESIG_BLOB, RMF_CODESIG_SIZE) == 0 &&
          memcmp(o.b + now.sp->dataoff, "split!!", 8) == 0,
          "insert: the code signature or split info bytes are not where their offsets say");
    free(o.b);
}

static void test_insert_makes_the_zero_fill_file_bytes(void) {
    inserted o;
    char why[256] = "";
    int rc = insert_into(RMF_ZEROTAIL, NULL, &o, why, sizeof why);
    uint64_t z = 0x1000, grow = z + MMA_PAGE + sizeof STREAM;
    CHECK(rc == MMA_OK && o.n == RMF_SIZE + grow, "zerotail insert: rc %d, %zu bytes (%s)", rc, o.n, why);
    if (rc != MMA_OK) return;
    lcs_of now = lcs(o.b, o.n);
    CHECK(now.d->vmsize == 0x3000 && now.d->filesize == 0x3000, "zerotail: D is %#llx/%#llx",
          (unsigned long long)now.d->vmsize, (unsigned long long)now.d->filesize);
    CHECK(now.l->fileoff == RMF_LINKEDIT + z + MMA_PAGE && now.l->vmaddr == RMF_VA(RMF_DATA + 0x3000),
          "zerotail: __LINKEDIT at %#llx/%#llx", (unsigned long long)now.l->vmaddr,
          (unsigned long long)now.l->fileoff);
    for (size_t i = RMF_LINKEDIT; i < RMF_LINKEDIT + z; i++)
        if (o.b[i]) { CHECK(0, "zerotail: zero-fill byte %#zx is %#x", i, o.b[i]); break; }
    CHECK(memcmp(o.b + RMF_LINKEDIT + z, LISTS, sizeof LISTS) == 0, "zerotail: the lists are not past the zero fill");
    CHECK(now.st->symoff == RMF_SYMS + grow, "zerotail: symoff %#x", now.st->symoff);
    CHECK(now.di->rebase_off == RMF_LINKEDIT + z + MMA_PAGE, "zerotail: rebase_off %#x", now.di->rebase_off);
    free(o.b);
}

static void poke_linkedit_snug(uint8_t *b) {
    mi_image im;
    struct segment_command_64 *l;
    if (mi_wrap(b, RMF_SIZE, &im) == 0 && (l = mi_find_segment(&im, "__LINKEDIT"))) l->vmsize = l->filesize;
}

static void test_insert_grows_linkedit_vm_to_cover_its_file_bytes(void) {
    inserted o;
    char why[256] = "";
    int rc = insert_into(RMF_PLAIN, poke_linkedit_snug, &o, why, sizeof why);
    CHECK(rc == MMA_OK, "snug insert: rc %d (%s)", rc, why);
    if (rc != MMA_OK) return;
    lcs_of now = lcs(o.b, o.n);
    CHECK(now.l->vmsize == MMA_PAGE, "snug: __LINKEDIT vmsize %#llx for %#llx file bytes, want 0x1000",
          (unsigned long long)now.l->vmsize, (unsigned long long)now.l->filesize);
    free(o.b);
}

static void test_insert_never_grows_the_header(void) {
    inserted o;
    char why[256] = "";
    int rc = insert_into(RMF_DYLIB, NULL, &o, why, sizeof why);
    const struct mach_header_64 *was = (const struct mach_header_64 *)fx;
    CHECK(rc == MMA_OK, "dylib insert: rc %d (%s)", rc, why);
    if (rc != MMA_OK) return;
    const struct mach_header_64 *now = (const struct mach_header_64 *)o.b;
    CHECK(now->ncmds == was->ncmds && now->sizeofcmds == was->sizeofcmds &&
          sizeof *now + now->sizeofcmds + RMF_PAD == RMF_TEXT,
          "dylib insert: %u commands in %u bytes, was %u in %u", now->ncmds, now->sizeofcmds,
          was->ncmds, was->sizeofcmds);
    CHECK(memcmp(o.b + RMF_TEXT, fx + RMF_TEXT, RMF_LINKEDIT - RMF_TEXT) == 0,
          "dylib insert: a byte below __LINKEDIT changed");
    free(o.b);
}
```

and in `main`, after `test_selector_references_without_a_rebase_or_bind_are_named_so();`:

```c
    test_layout_puts_the_lists_at_the_end_of_data();
    test_layout_refusals();
    test_insert_moves_linkedit_up_behind_the_lists();
    test_insert_makes_the_zero_fill_file_bytes();
    test_insert_grows_linkedit_vm_to_cover_its_file_bytes();
    test_insert_never_grows_the_header();
```

- [ ] **Step 3: Run to see it fail**

Run: build.
Expected: `'objc_abs.h' file not found`.

- [ ] **Step 4: Write `src/objc_abs.h`**

```c
#ifndef DRYDOCK_OBJC_ABS_H
#define DRYDOCK_OBJC_ABS_H
/*
 * mma_ -- `objc-methods set absolute`: every relative Objective-C method list
 * objc_meth.h's walk reaches becomes an absolute list, appended past the end
 * of D, the segment just before __LINKEDIT, and every slot that named it is
 * repointed. D grows, __LINKEDIT moves up behind it, and no load command is
 * added, so the header pad is never touched.
 */
#include <stddef.h>
#include <stdint.h>

#include "image.h"
#include "objc_meth.h"

#define MMA_OK        0
#define MMA_NOTHING   1
#define MMA_REFUSED (-1)
#define MMA_NOMEM   (-2)

#define MMA_PAGE 0x1000u

typedef struct {
    char     name[16];
    uint64_t vmaddr, vmsize, fileoff, filesize;
    uint32_t initprot;
} mma_seg;

typedef struct {
    int      d, l;         /* segment indices of D and __LINKEDIT */
    char     dname[16];    /* D's segname, not NUL-terminated at 16 */
    uint64_t list_va;      /* D's vm end: the converted lists start here */
    uint64_t insert;       /* __LINKEDIT's file offset: new bytes go in here */
    uint64_t z;            /* D's zero fill, which becomes file bytes */
} mma_layout;

/* The image's LC_SEGMENT_64s in load-command order: their count, or -1 when
 * there are more than `max`. */
int mma_segments(const mi_image *im, mma_seg *segs, int max);

/* Where the lists can go in an image of `file_size` bytes with these
 * segments, or MMA_REFUSED with why set: __LINKEDIT must be the last segment
 * and end the file; D must be segment 15 or lower, writable, end where
 * __LINKEDIT begins in vm and in file, and end on a page boundary once its
 * zero fill is in the file. */
int mma_layout_check(const mma_seg *segs, int n, uint64_t file_size, mma_layout *lay,
                     char *why, size_t whysz);

/* A new image, in *out (malloc'd) of *outsz bytes: `im` with its zero fill
 * made file bytes, `lists_len` bytes of `lists` then zeros to `s` (a whole
 * number of pages) past D's end, and `r` bytes of `stream` (a multiple of 8)
 * at the start of __LINKEDIT, which moves up by s in vm and by z + s in file.
 * D's vmsize grows by s and its filesize becomes its vmsize; __LINKEDIT's
 * filesize grows by r and its vmsize grows to cover it; every other file
 * offset at or past the insertion moves by z + s + r; rebase_off and
 * rebase_size name the new stream and the old one is zeroed. `im` is only
 * read. MMA_OK, MMA_REFUSED or MMA_NOMEM, with why set. */
int mma_insert(const mi_image *im, const mma_layout *lay, const uint8_t *lists,
               uint64_t lists_len, uint64_t s, const uint8_t *stream, uint32_t r,
               uint8_t **out, size_t *outsz, char *why, size_t whysz);

#endif
```

- [ ] **Step 5: Write `src/objc_abs.c` and add it to `CMakeLists.txt:66`**

```c
/* mma_ -- see objc_abs.h. */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach-o/loader.h>

#include "objc_abs.h"
#include "linkedit.h"
#include "mach_compat.h"

static int mma_fail(char *why, size_t whysz, int code, const char *fmt, ...)
    __attribute__((format(printf, 4, 5)));
static int mma_fail(char *why, size_t whysz, int code, const char *fmt, ...) {
    va_list ap;
    if (why && whysz) {
        va_start(ap, fmt);
        vsnprintf(why, whysz, fmt, ap);
        va_end(ap);
    }
    return code;
}

/* ---- layout ------------------------------------------------------------- */

typedef struct { mma_seg *segs; int n, max; } mma_seg_ctx;

static int mma_seg_lc(const struct load_command *lc, void *ctx_) {
    mma_seg_ctx *c = ctx_;
    const struct segment_command_64 *sc = (const struct segment_command_64 *)lc;
    if (lc->cmd != LC_SEGMENT_64) return 0;
    if (c->n == c->max) { c->n = -1; return 1; }
    memcpy(c->segs[c->n].name, sc->segname, 16);
    c->segs[c->n].vmaddr = sc->vmaddr;
    c->segs[c->n].vmsize = sc->vmsize;
    c->segs[c->n].fileoff = sc->fileoff;
    c->segs[c->n].filesize = sc->filesize;
    c->segs[c->n].initprot = (uint32_t)sc->initprot;
    c->n++;
    return 0;
}

int mma_segments(const mi_image *im, mma_seg *segs, int max) {
    mma_seg_ctx c = { segs, 0, max };
    mi_each_lc(im, mma_seg_lc, &c);
    return c.n;
}

static int mma_is_linkedit(const mma_seg *s) { return strncmp(s->name, "__LINKEDIT", 16) == 0; }

int mma_layout_check(const mma_seg *segs, int n, uint64_t file_size, mma_layout *lay,
                     char *why, size_t whysz) {
    int i;
    memset(lay, 0, sizeof *lay);
    if (n < 2 || !mma_is_linkedit(&segs[n - 1])) {
        for (i = 0; i < n; i++)
            if (mma_is_linkedit(&segs[i]))
                return mma_fail(why, whysz, MMA_REFUSED, "__LINKEDIT is not the last segment");
        return mma_fail(why, whysz, MMA_REFUSED, "the image has no __LINKEDIT to follow the lists");
    }
    const mma_seg *d = &segs[n - 2], *l = &segs[n - 1];
    if (n - 2 > 15)
        return mma_fail(why, whysz, MMA_REFUSED, "%.16s, the segment before __LINKEDIT, is segment "
                        "%d, and a rebase opcode names only segments 0 to 15", d->name, n - 2);
    if (!(d->initprot & VM_PROT_WRITE))
        return mma_fail(why, whysz, MMA_REFUSED, "%.16s, the segment before __LINKEDIT, is not "
                        "writable, and the runtime writes into method lists", d->name);
    if (d->filesize > d->vmsize)
        return mma_fail(why, whysz, MMA_REFUSED, "%.16s has more file bytes than vm bytes", d->name);
    if (d->vmaddr + d->vmsize != l->vmaddr)
        return mma_fail(why, whysz, MMA_REFUSED, "%.16s ends at 0x%llx in memory, and __LINKEDIT "
                        "begins at 0x%llx", d->name, (unsigned long long)(d->vmaddr + d->vmsize),
                        (unsigned long long)l->vmaddr);
    if (d->fileoff + d->filesize != l->fileoff)
        return mma_fail(why, whysz, MMA_REFUSED, "%.16s ends at file offset 0x%llx, and __LINKEDIT "
                        "begins at 0x%llx", d->name, (unsigned long long)(d->fileoff + d->filesize),
                        (unsigned long long)l->fileoff);
    if (l->fileoff + l->filesize != file_size)
        return mma_fail(why, whysz, MMA_REFUSED, "__LINKEDIT ends at file offset 0x%llx, and the "
                        "image is 0x%llx bytes", (unsigned long long)(l->fileoff + l->filesize),
                        (unsigned long long)file_size);
    if ((d->vmaddr + d->vmsize) % MMA_PAGE || (l->fileoff + d->vmsize - d->filesize) % MMA_PAGE)
        return mma_fail(why, whysz, MMA_REFUSED, "%.16s does not end on a page boundary", d->name);
    lay->d = n - 2;
    lay->l = n - 1;
    memcpy(lay->dname, d->name, 16);
    lay->list_va = d->vmaddr + d->vmsize;
    lay->insert = l->fileoff;
    lay->z = d->vmsize - d->filesize;
    return MMA_OK;
}

typedef struct {
    const mma_layout *lay;
    uint64_t s, r;
    int idx;
    struct dyld_info_command *di;
} mma_edit_ctx;

static int mma_edit_lc(const struct load_command *lc, void *ctx_) {
    mma_edit_ctx *c = ctx_;
    if (lc->cmd == LC_DYLD_INFO || lc->cmd == LC_DYLD_INFO_ONLY) {
        c->di = (struct dyld_info_command *)lc;
        return 0;
    }
    if (lc->cmd != LC_SEGMENT_64) return 0;
    struct segment_command_64 *sc = (struct segment_command_64 *)lc;
    if (c->idx == c->lay->d) {
        sc->vmsize += c->s;
        sc->filesize = sc->vmsize;
    } else if (c->idx == c->lay->l) {
        uint64_t need;
        sc->vmaddr += c->s;
        sc->fileoff += c->lay->z + c->s;
        sc->filesize += c->r;
        need = (sc->filesize + MMA_PAGE - 1) & ~(uint64_t)(MMA_PAGE - 1);
        if (sc->vmsize < need) sc->vmsize = need;
    }
    c->idx++;
    return 0;
}

static int mma_find_info(const struct load_command *lc, void *ctx_) {
    if (lc->cmd != LC_DYLD_INFO && lc->cmd != LC_DYLD_INFO_ONLY) return 0;
    *(const struct dyld_info_command **)ctx_ = (const struct dyld_info_command *)lc;
    return 1;
}

int mma_insert(const mi_image *im, const mma_layout *lay, const uint8_t *lists,
               uint64_t lists_len, uint64_t s, const uint8_t *stream, uint32_t r,
               uint8_t **out, size_t *outsz, char *why, size_t whysz) {
    const struct dyld_info_command *odi = NULL;
    uint64_t grow = lay->z + s + r, at;
    uint8_t *nb;
    mi_image nim;
    mma_edit_ctx c;

    *out = NULL;
    *outsz = 0;
    if (s % MMA_PAGE || lists_len > s || r % 8)
        return mma_fail(why, whysz, MMA_REFUSED, "internal error: %llu list bytes in %llu, "
                        "%u stream bytes", (unsigned long long)lists_len, (unsigned long long)s, r);
    mi_each_lc(im, mma_find_info, &odi);
    if (!odi)
        return mma_fail(why, whysz, MMA_REFUSED, "no LC_DYLD_INFO: there is no rebase stream to extend");
    if (odi->rebase_size && odi->rebase_off < lay->insert)
        return mma_fail(why, whysz, MMA_REFUSED, "the rebase stream is not in __LINKEDIT");
    if (im->size + grow > UINT32_MAX)
        return mma_fail(why, whysz, MMA_REFUSED, "the image would pass 4GB");
    if (!(nb = calloc(1, im->size + grow)))
        return mma_fail(why, whysz, MMA_NOMEM, "out of memory");
    at = lay->insert;
    memcpy(nb, im->buf, at);
    memcpy(nb + at + lay->z, lists, lists_len);
    memcpy(nb + at + lay->z + s, stream, r);
    memcpy(nb + at + grow, im->buf + at, im->size - at);
    if (mi_wrap(nb, im->size + grow, &nim) != 0) {
        free(nb);
        return mma_fail(why, whysz, MMA_REFUSED, "internal error: the new image does not wrap");
    }
    memset(&c, 0, sizeof c);
    c.lay = lay;
    c.s = s;
    c.r = r;
    mi_each_lc(&nim, mma_edit_lc, &c);
    if (ml_bump_all(&nim, (uint32_t)at, (uint32_t)grow) != 0) {
        free(nb);
        return mma_fail(why, whysz, MMA_REFUSED, "a __LINKEDIT file offset would pass 4GB");
    }
    if (c.di->rebase_size) memset(nb + c.di->rebase_off, 0, c.di->rebase_size);
    c.di->rebase_off = (uint32_t)(at + lay->z + s);
    c.di->rebase_size = r;
    *out = nb;
    *outsz = im->size + grow;
    return MMA_OK;
}
```

- [ ] **Step 6: Build and run**

Run: build (rebuild check on `$B/objc_meth_test`), `"$B/objc_meth_test"`, then the whole suite.
Expected: `objc_meth_test: 0 failure(s)`; all pass.

- [ ] **Step 7: Mutation proof** (file `src/objc_abs.c`; test `$B/objc_meth_test`)

| # | replace | with | must fail |
|---|---|---|---|
| 1 | `sc->fileoff += c->lay->z + c->s;` | `sc->fileoff += c->s;` | `test_insert_makes_the_zero_fill_file_bytes` |
| 2 | `uint64_t grow = lay->z + s + r, at;` | `uint64_t grow = s + r, at;` | `test_insert_makes_the_zero_fill_file_bytes` |
| 3 | `if (sc->vmsize < need) sc->vmsize = need;` | `(void)need;` | `test_insert_grows_linkedit_vm_to_cover_its_file_bytes` |
| 4 | `if (n - 2 > 15)` | `if (n - 2 > 16)` | `test_layout_refusals` ("D at segment 16") |
| 5 | `if (!(d->initprot & VM_PROT_WRITE))` | `if (0)` | `test_layout_refusals` ("D read-only") |
| 6 | `if (d->vmaddr + d->vmsize != l->vmaddr)` | `if (0)` | `test_layout_refusals` ("a gap in vm before __LINKEDIT") |
| 7 | `if (d->fileoff + d->filesize != l->fileoff)` | `if (0)` | `test_layout_refusals` ("a gap in the file") |
| 8 | `if (l->fileoff + l->filesize != file_size)` | `if (0)` | `test_layout_refusals` ("bytes past __LINKEDIT") |
| 9 | `if ((d->vmaddr + d->vmsize) % MMA_PAGE \|\| (l->fileoff + d->vmsize - d->filesize) % MMA_PAGE)` | `if (0)` | `test_layout_refusals` ("D ends mid-page") |
| 10 | the first `for (i = 0; i < n; i++)` in `mma_layout_check` | `for (i = n; i < n; i++)` | `test_layout_refusals` ("a segment after __LINKEDIT") |
| 11 | `if (c.di->rebase_size) memset` | `if (0) memset` | `test_insert_moves_linkedit_up_behind_the_lists` |
| 12 | `sc->filesize = sc->vmsize;` | `sc->filesize += c->s;` | `test_insert_makes_the_zero_fill_file_bytes` |
| 13 | `sc->vmaddr += c->s;` | `;` | `test_insert_moves_linkedit_up_behind_the_lists` |
| 14 | `c.di->rebase_off = (uint32_t)(at + lay->z + s);` | `c.di->rebase_off = (uint32_t)(at + s);` | `test_insert_makes_the_zero_fill_file_bytes` |
| 15 | `if (ml_bump_all(&nim, (uint32_t)at, (uint32_t)grow) != 0) {` | `if (0) {` | `test_insert_moves_linkedit_up_behind_the_lists` |

- [ ] **Step 8: Commit**

```bash
git add src/objc_abs.h src/objc_abs.c CMakeLists.txt tests/relmeth_fixture.h tests/mkrelmeth.c tests/objc_meth_test.c
git commit -m "feat(objc): make room past the segment before __LINKEDIT

D, the segment just before __LINKEDIT, grows by the lists' pages after
its zero fill becomes file bytes; __LINKEDIT moves up behind it with the
new rebase stream at its start, and every __LINKEDIT offset moves by the
same amount. No load command is added, so a dylib with 16 bytes of
header pad takes the lists as readily as an executable. __LINKEDIT's
vmsize grows when its file bytes outgrow it.

Refused: D read-only, D segment 16 or above, a gap before __LINKEDIT in
vm or file, a segment after __LINKEDIT, bytes past its end, and an end
that is not on a page boundary.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 5: The conversion (`mma_build`) and the oracle it is checked against

**Files:**
- Modify: `src/objc_abs.h` (before its final `#endif`), `src/objc_abs.c` (append)
- Modify: `tests/relmeth_fixture.h` (edits below; the oracle goes before the final `#endif`)
- Replace: `tests/mkrelmeth.c` (whole file)
- Test: `tests/objc_meth_test.c`

**Interfaces:**
- Consumes: `mml_walk_image`, `mml_walk`, `mml_ref`, `MML_RELATIVE`, `MML_ABS_ENTSIZE`, `MML_NOWNERS` (M1); `mml_resolver_open/close`, `mml_entry_at`, `mml_off_rebased` (Task 3); `mrb_decode`, `mrb_encode`, `mrb_put`, `mrb_buf`, `mrb_slot` (Task 2); `mma_segments`, `mma_layout_check`, `mma_insert`, `mma_fail`, `mma_find_info` (Task 4).
- Produces (Tasks 6 and 7 use these):
  - `typedef struct { uint32_t lists, methods; uint32_t owners[MML_NOWNERS]; uint32_t rebases; char dname[16]; uint64_t grew, zerofill; uint64_t linkedit_before, linkedit_after; } mma_report;`
  - `typedef struct { uint8_t *buf; size_t size; mma_layout lay; uint64_t s; uint32_t r; mma_report rep; } mma_out;`
  - `int mma_build(const mi_image *im, mma_out *o, char *why, size_t whysz);` → `MMA_OK`, `MMA_NOTHING`, `MMA_REFUSED`, `MMA_NOMEM`
  - `void mma_out_free(mma_out *o);`
  - static in `src/objc_abs.c`, used by Task 6: `mma_firsts(const mml_walk *w, uint32_t *first)` (for each ref, the index of the first ref naming the same list).
  - In the fixture: `static inline int rmf_describe(const uint8_t *b, size_t n, char *out, size_t outsz)` (the oracle); variant `RMF_COMPACT` (1<<26). In `mkrelmeth`: `make A+B OUT` and `entries FILE`.

**Plan decision:** the old rebase stream is copied byte for byte up to its `DONE`, then the new opcodes (`mrb_encode`, which begins with its own `SET_TYPE_IMM`), then `DONE`, zero-padded to a multiple of 8. Why: this is the spec's "old opcodes up to their DONE, then the new ones, then DONE", and copying rather than re-encoding keeps the old stream's exact meaning whatever form ld64 or Drydock gave it; Task 6 decodes the result to prove it.

**Plan decision:** a list named by several slots is counted under the record of the first slot, in walk order, that names it. Why: the log line's per-record counts must add up to the number of lists converted, and walk order is the only order the image gives.

The oracle, `rmf_describe`, lives in the fixture header and reads the image without `src/`: it maps addresses through the load commands itself and follows each of the fixture's nine possible method-list slots by address. A conversion must leave every line it prints as it was, but for `rel` becoming `abs`. Slots are read by address, not file offset, so it still reads correctly after a header grow (Task 8).

- [ ] **Step 1: Add the oracle, `RMF_COMPACT`, and the new `mkrelmeth`**

Apply to `tests/relmeth_fixture.h`, in order:

Edit 1. Replace:

```c
#include <stdint.h>
#include <string.h>
```

with:

```c
#include <stdint.h>
#include <stdio.h>
#include <string.h>
```

Edit 2. Replace:

```c
    RMF_PAD16    = 1u << 25  /* an LC_RPATH fills the header to RMF_PAD bytes of pad */
```

with:

```c
    RMF_PAD16    = 1u << 25, /* an LC_RPATH fills the header to RMF_PAD bytes of pad */
    RMF_COMPACT  = 1u << 26  /* the rebase stream is ld64's compact form, one segment set and
                              * DO_REBASE_ADD_ADDR_ULEB between slots */
```

Edit 3. Replace:

```c
    uint32_t slots[32], n = rmf_rebase_slots(v, slots), at = RMF_REBASE;
    b[at++] = REBASE_OPCODE_SET_TYPE_IMM | REBASE_TYPE_POINTER;
```

with:

```c
    uint32_t slots[32], n = rmf_rebase_slots(v, slots), at = RMF_REBASE;
    b[at++] = REBASE_OPCODE_SET_TYPE_IMM | REBASE_TYPE_POINTER;
    if (v & RMF_COMPACT) {
        b[at++] = (uint8_t)(REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB | rmf_data_seg(v));
        at += rmf_uleb(b + at, slots[0]);
        for (uint32_t i = 0; i + 1 < n; i++) {
            b[at++] = REBASE_OPCODE_DO_REBASE_ADD_ADDR_ULEB;
            at += rmf_uleb(b + at, slots[i + 1] - slots[i] - 8);
        }
        b[at++] = REBASE_OPCODE_DO_REBASE_IMM_TIMES | 1;
        n = 0;
    }
```

Edit 4. Before the final `#endif` of `tests/relmeth_fixture.h`, insert:

```c
/* ---- the oracle -----------------------------------------------------------
 * Reads every method-list slot this fixture can fill, by its fixed address,
 * and resolves the list it names without src/: a relative entry through its
 * selector reference, an absolute one directly. One line per filled slot:
 *   "<slot> <rel|abs> <count>: <name> <types> <imp>; ..."
 * A conversion must leave every line as it was but for rel -> abs. */

static inline int64_t rmf_file(const uint8_t *b, size_t n, uint64_t va, uint64_t len) {
    const struct mach_header_64 *h = (const struct mach_header_64 *)b;
    uint32_t at = sizeof *h;
    if (n < sizeof *h || h->magic != MH_MAGIC_64) return -1;
    for (uint32_t i = 0; i < h->ncmds && at + 8 <= n; i++) {
        const struct load_command *lc = (const struct load_command *)(b + at);
        if (lc->cmd == LC_SEGMENT_64 && at + sizeof(struct segment_command_64) <= n) {
            const struct segment_command_64 *s = (const struct segment_command_64 *)lc;
            if (va >= s->vmaddr && va - s->vmaddr + len <= s->filesize &&
                s->fileoff + (va - s->vmaddr) + len <= n)
                return (int64_t)(s->fileoff + (va - s->vmaddr));
        }
        at += lc->cmdsize;
    }
    return -1;
}

static inline const char *rmf_str(const uint8_t *b, size_t n, uint64_t va) {
    int64_t o = rmf_file(b, n, va, 1);
    if (o < 0 || !memchr(b + o, 0, n - (size_t)o)) return "?";
    return (const char *)b + o;
}

static inline uint64_t rmf_get64(const uint8_t *b, size_t n, uint64_t va) {
    uint64_t v = 0;
    int64_t o = rmf_file(b, n, va, 8);
    if (o >= 0) memcpy(&v, b + o, 8);
    return v;
}

static inline int rmf_describe(const uint8_t *b, size_t n, char *out, size_t outsz) {
    static const struct { const char *name; uint32_t off; } slots[] = {
        { "class",                 RMF_CLASS_RO + 32 },  { "metaclass",       RMF_META_RO + 32 },
        { "category.instance",     RMF_CATEGORY + 16 },  { "category.class",  RMF_CATEGORY + 24 },
        { "category2.instance",    RMF_CATEGORY2 + 16 }, { "protocol.instance", RMF_PROTOCOL + 24 },
        { "protocol.class",        RMF_PROTOCOL + 32 },  { "protocol.optinstance", RMF_PROTOCOL + 40 },
        { "protocol.optclass",     RMF_PROTOCOL + 48 },
    };
    size_t used = 0;
    if (outsz) out[0] = 0;
#define RMF_OUT(...) do { int w_ = snprintf(out + used, outsz - used, __VA_ARGS__); \
    if (w_ < 0 || (size_t)w_ >= outsz - used) return -1; used += (size_t)w_; } while (0)
    for (size_t k = 0; k < sizeof slots / sizeof slots[0]; k++) {
        uint64_t list = rmf_get64(b, n, RMF_VA(slots[k].off));
        uint32_t hdr, count;
        int64_t lo;
        if (!list) continue;
        if ((lo = rmf_file(b, n, list, 8)) < 0) return -1;
        memcpy(&hdr, b + lo, 4);
        memcpy(&count, b + lo + 4, 4);
        RMF_OUT("%s %s %u:", slots[k].name, (hdr & 0x80000000u) ? "rel" : "abs", count);
        for (uint32_t i = 0; i < count; i++) {
            uint64_t name, types, imp;
            if (hdr & 0x80000000u) {
                uint64_t e = list + 8 + 12 * (uint64_t)i;
                int32_t d[3];
                int64_t eo = rmf_file(b, n, e, 12);
                if (eo < 0) return -1;
                memcpy(d, b + eo, 12);
                name = rmf_get64(b, n, e + (uint64_t)(int64_t)d[0]);
                types = e + 4 + (uint64_t)(int64_t)d[1];
                imp = d[2] ? e + 8 + (uint64_t)(int64_t)d[2] : 0;
            } else {
                uint64_t e = list + 8 + 24 * (uint64_t)i;
                name = rmf_get64(b, n, e);
                types = rmf_get64(b, n, e + 8);
                imp = rmf_get64(b, n, e + 16);
            }
            RMF_OUT(" %s %s 0x%llx;", rmf_str(b, n, name), rmf_str(b, n, types),
                    (unsigned long long)imp);
        }
        RMF_OUT("\n");
    }
#undef RMF_OUT
    return (int)used;
}
```

Replace `tests/mkrelmeth.c` with:

```c
/* tests/mkrelmeth.c -- writes one variant of tests/relmeth_fixture.h's image,
 * or prints the oracle's reading of an image's method lists:
 *   mkrelmeth make VARIANT[+VARIANT...] OUT
 *   mkrelmeth entries FILE */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "relmeth_fixture.h"

static const struct { const char *name; unsigned bits; } VARIANTS[] = {
    { "plain", RMF_PLAIN },     { "chained", RMF_CHAINED }, { "direct", RMF_DIRECT },
    { "listlist", RMF_LISTLIST }, { "oob", RMF_OOB },       { "shared", RMF_SHARED },
    { "abscat", RMF_ABSCAT },   { "nlcls", RMF_NLCLS },     { "swift", RMF_SWIFT },
    { "badent", RMF_BADENT },   { "allslots", RMF_ALLSLOTS },
    { "sharedro", RMF_SHAREDRO }, { "catpast", RMF_CATPAST }, { "protopast", RMF_PROTOPAST },
    { "metaout", RMF_METAOUT }, { "selbind", RMF_SELBIND }, { "fstarts", RMF_FSTARTS },
    { "fsbad", RMF_FSBAD },     { "noslotrb", RMF_NOSLOTRB }, { "dylib", RMF_DYLIB },
    { "zerotail", RMF_ZEROTAIL }, { "dataro", RMF_DATARO },  { "gap", RMF_GAP },
    { "segafter", RMF_SEGAFTER }, { "codesig", RMF_CODESIG }, { "split", RMF_SPLIT },
    { "pad16", RMF_PAD16 },     { "compact", RMF_COMPACT },
};

static int bits_of(const char *spec, unsigned *out) {
    char buf[256], *tok, *save = NULL;
    size_t i, nv = sizeof VARIANTS / sizeof VARIANTS[0];
    if (strlen(spec) >= sizeof buf) return -1;
    strcpy(buf, spec);
    *out = 0;
    for (tok = strtok_r(buf, "+", &save); tok; tok = strtok_r(NULL, "+", &save)) {
        for (i = 0; i < nv; i++)
            if (strcmp(tok, VARIANTS[i].name) == 0) break;
        if (i == nv) {
            fprintf(stderr, "mkrelmeth: unknown variant '%s'\n", tok);
            return -1;
        }
        *out |= VARIANTS[i].bits;
    }
    return 0;
}

static int entries(const char *path) {
    FILE *f = fopen(path, "rb");
    uint8_t *b;
    char *out;
    long n;
    int w;
    if (!f) { perror(path); return 1; }
    if (fseek(f, 0, SEEK_END) != 0 || (n = ftell(f)) < 0 || fseek(f, 0, SEEK_SET) != 0) {
        perror(path); fclose(f); return 1;
    }
    b = malloc((size_t)n + 1);
    out = malloc(1 << 16);
    if (!b || !out || fread(b, 1, (size_t)n, f) != (size_t)n) {
        perror(path); fclose(f); free(b); free(out); return 1;
    }
    fclose(f);
    w = rmf_describe(b, (size_t)n, out, 1 << 16);
    if (w < 0) {
        fprintf(stderr, "mkrelmeth: %s: a method list the oracle cannot read\n", path);
        free(b); free(out); return 1;
    }
    fputs(out, stdout);
    free(b); free(out);
    return 0;
}

int main(int argc, char **argv) {
    static uint8_t b[RMF_SIZE];
    unsigned bits;
    size_t n;
    FILE *f;

    if (argc == 3 && strcmp(argv[1], "entries") == 0) return entries(argv[2]);
    if (argc != 4 || strcmp(argv[1], "make") != 0) {
        fprintf(stderr, "usage: mkrelmeth make VARIANT[+VARIANT...] OUT\n"
                        "       mkrelmeth entries FILE\n");
        return 2;
    }
    if (bits_of(argv[2], &bits) != 0) return 2;
    n = rmf_build(b, bits);
    f = fopen(argv[3], "wb");
    if (!f) { perror(argv[3]); return 1; }
    if (fwrite(b, 1, n, f) != n) { perror(argv[3]); fclose(f); return 1; }
    return fclose(f) == 0 ? 0 : 1;
}
```

- [ ] **Step 2: Write the failing tests**

In `tests/objc_meth_test.c`, after `#include "objc_abs.h"` add `#include "mach_compat.h"` (for `CPU_TYPE_ARM64`). Insert before `int main(void) {`:

```c
/* ---- conversion ------------------------------------------------------------ */

static char oracle_before[4096], oracle_after[4096];

/* The oracle's reading of `b`, with every "rel" read as "abs". */
static int oracle(const uint8_t *b, size_t n, char *out, int as_abs) {
    int w = rmf_describe(b, n, out, 4096);
    char *p;
    if (w < 0) return -1;
    while (as_abs && (p = strstr(out, " rel "))) memcpy(p, " abs ", 5);
    return w;
}

static int build(unsigned variant, void (*poke)(uint8_t *), mma_out *o, char *why, size_t whysz) {
    mi_image im;
    rmf_build(fx, variant);
    if (poke) poke(fx);
    if (mi_wrap(fx, RMF_SIZE, &im) != 0) return -99;
    return mma_build(&im, o, why, whysz);
}

static void check_converts_like_the_oracle(unsigned variant, uint32_t lists, uint32_t methods,
                                           const char *label) {
    mma_out o;
    char why[256] = "";
    int rc = build(variant, NULL, &o, why, sizeof why);
    CHECK(rc == MMA_OK, "%s: rc %d (%s)", label, rc, why);
    if (rc != MMA_OK) return;
    CHECK(oracle(fx, RMF_SIZE, oracle_before, 1) > 0 && oracle(o.buf, o.size, oracle_after, 0) > 0,
          "%s: the oracle cannot read an image", label);
    CHECK(strcmp(oracle_before, oracle_after) == 0, "%s: the oracle reads\n%s\nwhere it read\n%s",
          label, oracle_after, oracle_before);
    CHECK(o.rep.lists == lists && o.rep.methods == methods, "%s: converted %u lists (%u methods), "
          "want %u (%u)", label, o.rep.lists, o.rep.methods, lists, methods);
    mma_out_free(&o);
}

static void test_conversion_matches_the_oracle_in_order(void) {
    check_converts_like_the_oracle(RMF_PLAIN, 4, 5, "plain");
    check_converts_like_the_oracle(RMF_ALLSLOTS, 4, 5, "every slot filled");
    check_converts_like_the_oracle(RMF_SWIFT, 4, 5, "Swift-tagged class data");
    check_converts_like_the_oracle(RMF_ZEROTAIL, 4, 5, "a zero-fill tail");
    check_converts_like_the_oracle(RMF_DYLIB, 4, 5, "a dylib with 16 bytes of header pad");
    check_converts_like_the_oracle(RMF_CODESIG | RMF_SPLIT, 4, 5, "a code signature and split info");
    check_converts_like_the_oracle(RMF_FSTARTS, 4, 5, "function starts naming every IMP");
    check_converts_like_the_oracle(RMF_SHARED, 3, 4, "a list two slots share");
    check_converts_like_the_oracle(RMF_ABSCAT, 3, 4, "an absolute list beside relative ones");
    check_converts_like_the_oracle(RMF_COMPACT | RMF_ALLSLOTS, 4, 5, "ld64's compact rebase opcodes");
}

static void test_every_new_pointer_is_rebased(void) {
    mma_out o;
    mrb_set was, now;
    char why[256] = "";
    int rc = build(RMF_PLAIN, NULL, &o, why, sizeof why);
    CHECK(rc == MMA_OK, "rebases: rc %d (%s)", rc, why);
    if (rc != MMA_OK) return;
    lcs_of in = lcs(fx, RMF_SIZE), out = lcs(o.buf, o.size);
    CHECK(mrb_decode(fx + in.di->rebase_off, in.di->rebase_size, 4, &was, NULL, 0) == MRB_OK &&
          mrb_decode(o.buf + out.di->rebase_off, out.di->rebase_size, 4, &now, NULL, 0) == MRB_OK,
          "rebases: a stream does not decode");
    CHECK(mrb_sort(&now) == 0, "rebases: the new stream repeats a slot");
    CHECK(now.n == was.n + 14 && o.rep.rebases == 14, "rebases: %zu, was %zu; reported %u added, want 14",
          now.n, was.n, o.rep.rebases);
    for (size_t k = 0; k < was.n; k++)
        CHECK(mrb_has(&now, was.v[k].seg, was.v[k].off), "rebases: lost (%u, %#llx)",
              was.v[k].seg, (unsigned long long)was.v[k].off);
    /* List A at 0x2000 (D offset 0x1000): two entries, six pointers. List D,
     * last, at 0x2078: one entry whose IMP is 0, so two. */
    for (uint64_t off = 0x1008; off < 0x1038; off += 8)
        CHECK(mrb_has(&now, 2, off), "rebases: list A's pointer at D+%#llx has none", (unsigned long long)off);
    CHECK(mrb_has(&now, 2, 0x1080) && mrb_has(&now, 2, 0x1088) && !mrb_has(&now, 2, 0x1090),
          "rebases: list D's name and types need one each, and its IMP of 0 none");
    CHECK(o.rep.grew == MMA_PAGE && o.rep.zerofill == 0 && o.rep.linkedit_before == RMF_LINKEDIT_SIZE &&
          o.rep.linkedit_after == RMF_LINKEDIT_SIZE + o.r && strncmp(o.rep.dname, "__DATA", 16) == 0,
          "report: grew %#llx, zero fill %#llx, __LINKEDIT %llu -> %llu, D %.16s",
          (unsigned long long)o.rep.grew, (unsigned long long)o.rep.zerofill,
          (unsigned long long)o.rep.linkedit_before, (unsigned long long)o.rep.linkedit_after, o.rep.dname);
    CHECK(o.rep.owners[MML_CLASS] == 1 && o.rep.owners[MML_METACLASS] == 1 &&
          o.rep.owners[MML_CATEGORY] == 1 && o.rep.owners[MML_PROTOCOL] == 1,
          "report: owners %u %u %u %u", o.rep.owners[0], o.rep.owners[1], o.rep.owners[2], o.rep.owners[3]);
    mrb_free(&was);
    mrb_free(&now);
    mma_out_free(&o);
}

static uint64_t slot_value(const uint8_t *b, uint32_t off) { uint64_t v; memcpy(&v, b + off, 8); return v; }

static void test_every_slot_is_repointed_and_absolute_ones_kept(void) {
    mma_out o;
    char why[256] = "";
    int rc = build(RMF_SHARED, NULL, &o, why, sizeof why);
    CHECK(rc == MMA_OK, "shared: rc %d (%s)", rc, why);
    if (rc == MMA_OK) {
        CHECK(slot_value(o.buf, RMF_CLASS_RO + 32) == RMF_VA(RMF_LINKEDIT) &&
              slot_value(o.buf, RMF_CATEGORY + 16) == RMF_VA(RMF_LINKEDIT),
              "shared: the class and category do not both name the one new list");
        mma_out_free(&o);
    }
    rc = build(RMF_ABSCAT, NULL, &o, why, sizeof why);
    CHECK(rc == MMA_OK && slot_value(o.buf, RMF_CATEGORY + 16) == RMF_VA(RMF_ABS_C),
          "abscat: the absolute list's slot moved (rc %d, %s)", rc, why);
    mma_out_free(&o);
}

static void test_a_converted_image_has_nothing_to_convert(void) {
    mma_out o, again;
    mi_image im;
    char why[256] = "";
    int rc = build(RMF_PLAIN, NULL, &o, why, sizeof why);
    CHECK(rc == MMA_OK, "again: rc %d (%s)", rc, why);
    if (rc != MMA_OK) return;
    CHECK(mi_wrap(o.buf, o.size, &im) == 0 && mma_build(&im, &again, why, sizeof why) == MMA_NOTHING &&
          again.buf == NULL, "again: a converted image converts a second time");
    mma_out_free(&o);
}

static void poke_arm64(uint8_t *b)   { ((struct mach_header_64 *)b)->cputype = CPU_TYPE_ARM64; }
static void poke_no_info(uint8_t *b) {
    mi_image im;
    lcs_of c;
    if (mi_wrap(b, RMF_SIZE, &im) != 0) return;
    c = lcs(b, RMF_SIZE);
    ((struct load_command *)(uintptr_t)c.di)->cmd = LC_SOURCE_VERSION;
}

static void refused_build(unsigned variant, void (*poke)(uint8_t *), const char *want, const char *label) {
    mma_out o;
    uint8_t before[RMF_SIZE];
    char why[256] = "";
    int rc;
    rmf_build(before, variant);
    if (poke) poke(before);
    rc = build(variant, poke, &o, why, sizeof why);
    CHECK(rc == MMA_REFUSED, "%s: rc %d, want MMA_REFUSED", label, rc);
    CHECK(strstr(why, want) != NULL, "%s: why '%s' lacks '%s'", label, why, want);
    CHECK(o.buf == NULL, "%s: a refusal handed back an image", label);
    CHECK(memcmp(before, fx, RMF_SIZE) == 0, "%s: the refusal wrote into its input", label);
}

static void test_conversion_refusals_write_nothing(void) {
    refused_build(RMF_CHAINED, NULL, "fixups set classic first", "chained fixups");
    refused_build(RMF_PLAIN, poke_arm64, "not x86_64", "an arm64 image");
    refused_build(RMF_PLAIN, poke_no_info, "no LC_DYLD_INFO", "no rebase stream");
    refused_build(RMF_DATARO, NULL, "is not writable", "D read-only");
    refused_build(RMF_NOSLOTRB, NULL, "file offset 0x1120 carries no rebase", "a method-list slot with no rebase");
    refused_build(RMF_SELBIND, NULL, "is bound to another image", "a bound selector reference");
    refused_build(RMF_FSBAD, NULL, "not one of the 3 function starts", "an IMP that is not a function start");
    refused_build(RMF_OOB, NULL, "runs past its segment", "a list the walk cannot read");
}
```

and in `main`, after `test_insert_never_grows_the_header();`:

```c
    test_conversion_matches_the_oracle_in_order();
    test_every_new_pointer_is_rebased();
    test_every_slot_is_repointed_and_absolute_ones_kept();
    test_a_converted_image_has_nothing_to_convert();
    test_conversion_refusals_write_nothing();
```

The figures pinned in `test_every_new_pointer_is_rebased` come from the plain fixture: four lists (A with two entries, B, C and D with one each), five methods, fifteen pointers less list D's IMP of 0, so 14 new rebases. The lists start at D's old end, `RMF_VA(0x2000)`, which is `__DATA` offset 0x1000: list A's header at 0x1000 and its six pointers at 0x1008–0x1030; list D, last, at 0x1078, its name and types at 0x1080 and 0x1088.

- [ ] **Step 3: Run to see it fail**

Run: build.
Expected: `objc_meth_test` does not compile: `unknown type name 'mma_out'`.

- [ ] **Step 4: Declare the conversion in `src/objc_abs.h`**

Before the final `#endif`, after `mma_insert`'s declaration, add:

```c

/* What a conversion did, in the figures it had in hand while doing it. */
typedef struct {
    uint32_t lists, methods;            /* relative lists converted, and their entries */
    uint32_t owners[MML_NOWNERS];       /* those lists, by the record of the first slot naming each */
    uint32_t rebases;                   /* rebases added */
    char     dname[16];                 /* D's segname, not NUL-terminated at 16 */
    uint64_t grew, zerofill;            /* D grew by `grew` in vm, and `zerofill` more in file */
    uint64_t linkedit_before, linkedit_after;   /* __LINKEDIT's filesize */
} mma_report;

typedef struct {
    uint8_t   *buf;     /* the converted image, malloc'd; NULL unless MMA_OK */
    size_t     size;
    mma_layout lay;
    uint64_t   s;       /* the converted lists' room, a whole number of pages */
    uint32_t   r;       /* the new rebase stream's size, a multiple of 8 */
    mma_report rep;
} mma_out;

/* Converts `im`, which is only read, into o->buf: MMA_OK; MMA_NOTHING when
 * the walk finds no relative list; MMA_REFUSED or MMA_NOMEM with why set.
 * Refuses an image that is not x86_64, has chained fixups, has no
 * LC_DYLD_INFO, fails the walk or the layout, has a method-list slot with no
 * rebase, or has an entry mml_entry_at will not resolve. The new lists keep
 * their entries' order; each carries one rebase per pointer that is not 0. */
int  mma_build(const mi_image *im, mma_out *o, char *why, size_t whysz);
void mma_out_free(mma_out *o);
```

- [ ] **Step 5: Implement it: append to `src/objc_abs.c`**

```c
/* ---- conversion ---------------------------------------------------------- */

typedef struct { uint64_t va; uint32_t i; } mma_pair;

static int mma_pair_cmp(const void *a_, const void *b_) {
    const mma_pair *a = a_, *b = b_;
    if (a->va != b->va) return a->va < b->va ? -1 : 1;
    return a->i < b->i ? -1 : a->i > b->i;
}

/* first[i]: the first ref naming the list ref i names. */
static int mma_firsts(const mml_walk *w, uint32_t *first) {
    mma_pair *p = malloc((w->n ? w->n : 1) * sizeof *p);
    uint32_t i, g;
    if (!p) return -1;
    for (i = 0; i < w->n; i++) { p[i].va = w->refs[i].list_va; p[i].i = i; }
    qsort(p, w->n, sizeof *p, mma_pair_cmp);
    for (i = 0, g = 0; i < w->n; i++) {
        if (i && p[i].va != p[i - 1].va) g = i;
        first[p[i].i] = p[g].i;
    }
    free(p);
    return 0;
}

static void mma_put64(uint8_t *p, uint64_t v) { memcpy(p, &v, 8); }

void mma_out_free(mma_out *o) {
    free(o->buf);
    o->buf = NULL;
    o->size = 0;
}

int mma_build(const mi_image *im, mma_out *o, char *why, size_t whysz) {
    const struct dyld_info_command *di = NULL;
    mma_seg segs[MML_MAX_SEGS];
    mml_walk w;
    mml_resolver res;
    mrb_set old;
    mrb_buf stream;
    mrb_slot *slots = NULL;
    uint32_t *first = NULL, i, e, nslots = 0;
    uint64_t *new_va = NULL, total = 0, at;
    uint8_t *lists = NULL, zero[8] = { 0 };
    int nsegs, rc;

    memset(o, 0, sizeof *o);
    memset(&stream, 0, sizeof stream);
    memset(&old, 0, sizeof old);
    if (im->hdr->cputype != CPU_TYPE_X86_64)
        return mma_fail(why, whysz, MMA_REFUSED, "the image is not x86_64, the only architecture 10.9 runs");
    rc = mml_walk_image(im, &w);
    if (rc != MML_OK)
        return mma_fail(why, whysz, rc == MML_NOMEM ? MMA_NOMEM : MMA_REFUSED, "%s", w.why);
    if (w.relative == 0) {
        mml_walk_free(&w);
        return MMA_NOTHING;
    }
    mi_each_lc(im, mma_find_info, &di);
    if (!di) {
        mml_walk_free(&w);
        return mma_fail(why, whysz, MMA_REFUSED, "no LC_DYLD_INFO: there is no rebase stream to extend");
    }
    nsegs = mma_segments(im, segs, MML_MAX_SEGS);
    if ((rc = mma_layout_check(segs, nsegs, im->size, &o->lay, why, whysz)) != MMA_OK) {
        mml_walk_free(&w);
        return rc;
    }
    if ((rc = mml_resolver_open(im, &res, why, whysz)) != MML_OK) {
        mml_walk_free(&w);
        return rc == MML_NOMEM ? MMA_NOMEM : MMA_REFUSED;
    }
    rc = MMA_NOMEM;
    if (!(first = malloc(w.n * sizeof *first)) || !(new_va = calloc(w.n, sizeof *new_va)) ||
        mma_firsts(&w, first) != 0) {
        mma_fail(why, whysz, MMA_NOMEM, "out of memory");
        goto done;
    }
    rc = MMA_REFUSED;
    for (i = 0; i < w.n; i++) {
        if (!mml_off_rebased(&res, w.refs[i].slot_off)) {
            mma_fail(why, whysz, MMA_REFUSED, "the method-list pointer at file offset 0x%llx "
                     "carries no rebase", (unsigned long long)w.refs[i].slot_off);
            goto done;
        }
        if (first[i] == i && (w.refs[i].header & MML_RELATIVE)) {
            new_va[i] = o->lay.list_va + total;
            total += 8 + (uint64_t)MML_ABS_ENTSIZE * w.refs[i].count;
            nslots += 3 * w.refs[i].count;
        }
    }
    o->s = (total + MMA_PAGE - 1) & ~(uint64_t)(MMA_PAGE - 1);
    rc = MMA_NOMEM;
    if (!(lists = calloc(1, total)) || !(slots = malloc((nslots ? nslots : 1) * sizeof *slots))) {
        mma_fail(why, whysz, MMA_NOMEM, "out of memory");
        goto done;
    }
    rc = MMA_REFUSED;
    nslots = 0;
    for (i = 0; i < w.n; i++) {
        const mml_ref *ref = &w.refs[i];
        if (first[i] != i || !(ref->header & MML_RELATIVE)) continue;
        at = new_va[i] - o->lay.list_va;
        memcpy(lists + at, &(uint32_t){ MML_ABS_ENTSIZE }, 4);
        memcpy(lists + at + 4, &ref->count, 4);
        for (e = 0; e < ref->count; e++) {
            mml_entry ent;
            uint64_t ea = at + 8 + (uint64_t)MML_ABS_ENTSIZE * e;
            uint64_t eoff = new_va[i] + 8 + (uint64_t)MML_ABS_ENTSIZE * e - segs[o->lay.d].vmaddr;
            if (mml_entry_at(&res, ref, e, &ent, why, whysz) != MML_OK) goto done;
            mma_put64(lists + ea, ent.name);
            mma_put64(lists + ea + 8, ent.types);
            mma_put64(lists + ea + 16, ent.imp);
            for (int k = 0; k < 3; k++) {
                if (k == 2 && !ent.imp) continue;
                slots[nslots].seg = (uint8_t)o->lay.d;
                slots[nslots].type = REBASE_TYPE_POINTER;
                slots[nslots].off = eoff + 8 * (uint64_t)k;
                nslots++;
            }
        }
        o->rep.lists++;
        o->rep.methods += ref->count;
        o->rep.owners[ref->owner]++;
    }
    if (di->rebase_size) {
        rc = mrb_decode(im->buf + di->rebase_off, di->rebase_size, nsegs, &old, why, whysz);
        if (rc != MRB_OK) { rc = rc == MRB_NOMEM ? MMA_NOMEM : MMA_REFUSED; goto done; }
        mrb_put(&stream, im->buf + di->rebase_off, old.end);
    }
    rc = mrb_encode(slots, nslots, &stream);
    if (rc != MRB_OK) {
        rc = rc == MRB_NOMEM ? MMA_NOMEM : MMA_REFUSED;
        mma_fail(why, whysz, rc, rc == MMA_NOMEM ? "out of memory" : "internal error: new rebases out of order");
        goto done;
    }
    mrb_put(&stream, zero, 1 + (8 - (stream.n + 1) % 8) % 8);
    if (stream.oom) { rc = mma_fail(why, whysz, MMA_NOMEM, "out of memory"); goto done; }
    o->r = (uint32_t)stream.n;
    rc = mma_insert(im, &o->lay, lists, total, o->s, stream.p, o->r, &o->buf, &o->size, why, whysz);
    if (rc != MMA_OK) goto done;
    for (i = 0; i < w.n; i++)
        if (w.refs[i].header & MML_RELATIVE) mma_put64(o->buf + w.refs[i].slot_off, new_va[first[i]]);
    o->rep.rebases = nslots;
    memcpy(o->rep.dname, o->lay.dname, 16);
    o->rep.grew = o->s;
    o->rep.zerofill = o->lay.z;
    o->rep.linkedit_before = segs[o->lay.l].filesize;
    o->rep.linkedit_after = segs[o->lay.l].filesize + o->r;
done:
    free(first);
    free(new_va);
    free(lists);
    free(slots);
    free(stream.p);
    mrb_free(&old);
    mml_resolver_close(&res);
    mml_walk_free(&w);
    return rc;
}
```

- [ ] **Step 6: Build and run**

Run: build (rebuild check on `$B/objc_meth_test`), `"$B/objc_meth_test"`, then the whole suite.
Expected: `objc_meth_test: 0 failure(s)`; all pass. Then look at the oracle once by hand: `M=$(mktemp -d); cc -O2 -o "$M/mkrelmeth" tests/mkrelmeth.c && "$M/mkrelmeth" make plain "$M/p" && "$M/mkrelmeth" entries "$M/p"`. Expected, exactly:

```
class rel 2: beta v16@0:8 0x100000800; alpha v16@0:8 0x100000804;
metaclass rel 1: gamma v16@0:8 0x100000808;
category.instance rel 1: delta v16@0:8 0x10000080c;
protocol.instance rel 1: alpha v16@0:8 0x0;
```

- [ ] **Step 7: Mutation proof** (file `src/objc_abs.c`; test `$B/objc_meth_test`)

| # | replace | with | must fail |
|---|---|---|---|
| 1 | `if (w.refs[i].header & MML_RELATIVE) mma_put64(o->buf + w.refs[i].slot_off, new_va[first[i]]);` | `if (first[i] == i && (w.refs[i].header & MML_RELATIVE)) mma_put64(o->buf + w.refs[i].slot_off, new_va[first[i]]);` | `test_conversion_matches_the_oracle_in_order` ("every slot filled"); `test_every_slot_is_repointed_and_absolute_ones_kept` |
| 2 | same line | `mma_put64(o->buf + w.refs[i].slot_off, new_va[first[i]]);` | `test_conversion_matches_the_oracle_in_order` ("an absolute list beside relative ones") |
| 3 | `if (k == 2 && !ent.imp) continue;` | `if (k == 2) continue;` | `test_every_new_pointer_is_rebased` |
| 4 | `if (k == 2 && !ent.imp) continue;` | (delete) | `test_every_new_pointer_is_rebased` |
| 5 | `uint64_t ea = at + 8 + (uint64_t)MML_ABS_ENTSIZE * e;` | `uint64_t ea = at + 8 + (uint64_t)MML_ABS_ENTSIZE * (ref->count - 1 - e);` | `test_conversion_matches_the_oracle_in_order` ("plain") |
| 6 | `if (!mml_off_rebased(&res, w.refs[i].slot_off)) {` | `if (0) {` | `test_conversion_refusals_write_nothing` ("a method-list slot with no rebase") |
| 7 | `if (im->hdr->cputype != CPU_TYPE_X86_64)` | `if (0)` | `test_conversion_refusals_write_nothing` ("an arm64 image") |
| 8 | `memcpy(lists + at, &(uint32_t){ MML_ABS_ENTSIZE }, 4);` | `memcpy(lists + at, &(uint32_t){ MML_ABS_ENTSIZE \| MML_RELATIVE }, 4);` | `test_conversion_matches_the_oracle_in_order` |
| 9 | `mrb_put(&stream, im->buf + di->rebase_off, old.end);` | `;` | `test_every_new_pointer_is_rebased` ("lost") |
| 10 | `o->rep.owners[ref->owner]++;` | `o->rep.owners[0]++;` | `test_every_new_pointer_is_rebased` ("report: owners") |
| 11 | `if (!di) {` | `if (0) {` | `test_conversion_refusals_write_nothing` ("no rebase stream") |

- [ ] **Step 8: Commit**

```bash
git add src/objc_abs.h src/objc_abs.c tests/relmeth_fixture.h tests/mkrelmeth.c tests/objc_meth_test.c
git commit -m "feat(objc): convert every relative method list to an absolute one

Each distinct relative list the walk reaches becomes a 24-byte-entry list
past D's end, entries in their order, and every slot that named it is
repointed; absolute lists are left alone. Each new pointer that is not 0
gets a rebase, appended to the old stream's opcodes.

mkrelmeth entries is the oracle: it reads each method-list slot of the
fixture without src/, and a conversion must leave its reading unchanged
but for rel becoming abs.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 6: Verification (Decision 7) and `mma_convert`

**Files:**
- Modify: `src/objc_abs.h` (before its final `#endif`), `src/objc_abs.c` (includes; append)
- Test: `tests/objc_meth_test.c`

**Interfaces:**
- Consumes: everything in Task 5; `ml_each_off` (`src/linkedit.h:172`); `MR_REFUSED`, `MR_FAIL` (`src/rewrite.h:95-96`).
- Produces (Task 7 calls it):
  - `int mma_verify(const mi_image *in, const mma_out *o, char *why, size_t whysz);`
  - `int mma_convert(uint8_t **pbuf, size_t *psize, mma_report *rep);` → 0, `MR_REFUSED` or `MR_FAIL`, the reason on stderr prefixed `drydock-macho-rewrite: objc-methods set absolute: `.

The verifier trusts nothing `mma_build` computed except `o->lay`, `o->s` and `o->r`: it re-walks both images, re-resolves every input entry through a fresh resolver, decodes both rebase streams, re-reads both images' load commands through `ml_each_off`, and compares bytes. It runs `mg_plausible` only through the existing gate in `me_run` (the row declares `MREL_FILE_OFF`, so for this statement alone the gate does not apply; see the reply's spec notes).

**Plan decision:** entries are compared by their three addresses, not by their strings' bytes. Why: equal addresses plus the separate check that every byte below the insertion is unchanged (the strings live there) make the bytes equal; comparing the strings too was a check no mutation could kill independently.

- [ ] **Step 1: Write the failing tests**

In `tests/objc_meth_test.c`, after `#include "mach_compat.h"` add `#include "rewrite.h"`. Insert before `int main(void) {`:

```c
/* ---- verification ------------------------------------------------------------ */

static void test_every_conversion_verifies(void) {
    static const unsigned variants[] = {
        RMF_PLAIN, RMF_ALLSLOTS, RMF_SHARED, RMF_ABSCAT, RMF_SWIFT, RMF_NLCLS, RMF_SHAREDRO,
        RMF_ZEROTAIL, RMF_DYLIB, RMF_CODESIG | RMF_SPLIT, RMF_FSTARTS, RMF_PAD16,
        RMF_COMPACT | RMF_ALLSLOTS,
    };
    for (size_t k = 0; k < sizeof variants / sizeof variants[0]; k++) {
        mma_out o;
        mi_image in;
        char why[512] = "";
        int rc = build(variants[k], NULL, &o, why, sizeof why);
        CHECK(rc == MMA_OK, "variant %#x: build rc %d (%s)", variants[k], rc, why);
        if (rc != MMA_OK) continue;
        mi_wrap(fx, RMF_SIZE, &in);
        rc = mma_verify(&in, &o, why, sizeof why);
        CHECK(rc == MMA_OK, "variant %#x: verify rc %d (%s)", variants[k], rc, why);
        mma_out_free(&o);
    }
}

typedef void (*corrupt_fn)(mma_out *o);

static uint64_t stream_at(const mma_out *o) { return o->lay.insert + o->lay.z + o->s; }

static void c_name(mma_out *o)    { o->buf[o->lay.insert + o->lay.z + 8] ^= 0x10; }
static void c_types(mma_out *o)   { o->buf[o->lay.insert + o->lay.z + 16] ^= 1; }
static void c_imp(mma_out *o)     { o->buf[o->lay.insert + o->lay.z + 24] ^= 4; }
static void c_relative(mma_out *o) { rmf_put64(o->buf, RMF_CLASS_RO + 32, RMF_VA(RMF_LIST_A)); }
static void c_absolute(mma_out *o) { rmf_put64(o->buf, RMF_CATEGORY + 16, RMF_VA(RMF_LINKEDIT)); }
static void c_split(mma_out *o)   {
    /* the category names a byte-for-byte copy of list A, not list A */
    memcpy(o->buf + o->lay.insert + 0x800, o->buf + o->lay.insert, 8 + 2 * 24);
    rmf_put64(o->buf, RMF_CATEGORY + 16, RMF_VA(RMF_LINKEDIT + 0x800));
}
static void c_drop_rebase(mma_out *o) {
    mrb_set set;
    mrb_decode(o->buf + stream_at(o), o->r, 4, &set, NULL, 0);
    o->buf[stream_at(o) + set.end - 1]--;
    mrb_free(&set);
}
static void c_add_rebase(mma_out *o) {
    mrb_set set;
    mrb_decode(o->buf + stream_at(o), o->r, 4, &set, NULL, 0);
    o->buf[stream_at(o) + set.end - 1]++;
    mrb_free(&set);
}
static void c_move_rebase(mma_out *o) {
    /* list D's run, SET_SEGMENT_AND_OFFSET_ULEB 2 0x1080 then two, starts at 0x1078 instead */
    mrb_set set;
    mrb_decode(o->buf + stream_at(o), o->r, 4, &set, NULL, 0);
    o->buf[stream_at(o) + set.end - 3] = 0xf8;
    o->buf[stream_at(o) + set.end - 2] = 0x20;
    mrb_free(&set);
}
static void c_dvmsize(mma_out *o) { lcs_of c = lcs(o->buf, o->size); ((struct segment_command_64 *)(uintptr_t)c.d)->vmsize += MMA_PAGE; }
static void c_lfilesize(mma_out *o) { lcs_of c = lcs(o->buf, o->size); ((struct segment_command_64 *)(uintptr_t)c.l)->filesize -= 8; }
static void c_lvmaddr(mma_out *o) { lcs_of c = lcs(o->buf, o->size); ((struct segment_command_64 *)(uintptr_t)c.l)->vmaddr += MMA_PAGE; }
static void c_truncate(mma_out *o) { o->size -= 8; }
static void c_rebase_size(mma_out *o) { lcs_of c = lcs(o->buf, o->size); ((struct dyld_info_command *)(uintptr_t)c.di)->rebase_size += 8; }
static void c_symoff(mma_out *o)  { lcs_of c = lcs(o->buf, o->size); ((struct symtab_command *)(uintptr_t)c.st)->symoff += 8; }
static void c_nsyms(mma_out *o)   { lcs_of c = lcs(o->buf, o->size); ((struct symtab_command *)(uintptr_t)c.st)->nsyms += 1; }
static void c_below(mma_out *o)   { o->buf[RMF_DATA_TAIL] ^= 0xff; }
static void c_zerofill(mma_out *o) { o->buf[o->lay.insert] = 1; }
static void c_past_lists(mma_out *o) { o->buf[o->lay.insert + o->lay.z + o->s - 1] = 1; }
static void c_linkedit(mma_out *o) { o->buf[o->size - 1] ^= 0xff; }
static void c_old_stream(mma_out *o) { o->buf[RMF_REBASE + o->lay.z + o->s + o->r] = 0x11; }

static void refused_verify(unsigned variant, void (*poke)(uint8_t *), corrupt_fn corrupt,
                           const char *want, const char *label) {
    mma_out o;
    mi_image in;
    char why[512] = "";
    int rc = build(variant, poke, &o, why, sizeof why);
    CHECK(rc == MMA_OK, "%s: build rc %d (%s)", label, rc, why);
    if (rc != MMA_OK) return;
    if (corrupt) corrupt(&o);
    mi_wrap(fx, RMF_SIZE, &in);
    rc = mma_verify(&in, &o, why, sizeof why);
    CHECK(rc == MMA_REFUSED, "%s: verify rc %d, want MMA_REFUSED", label, rc);
    CHECK(strstr(why, want) != NULL, "%s: why '%s' lacks '%s'", label, why, want);
    mma_out_free(&o);
}

static void poke_text_over_data(uint8_t *b) {
    mi_image im;
    struct segment_command_64 *t;
    if (mi_wrap(b, RMF_SIZE, &im) == 0 && (t = mi_find_segment(&im, "__TEXT"))) t->vmsize = 0x2000;
}

static void test_verification_refuses_every_difference(void) {
    refused_verify(RMF_PLAIN, NULL, c_name, "is not the entry it was", "an entry's name");
    refused_verify(RMF_PLAIN, NULL, c_types, "is not the entry it was", "an entry's types");
    refused_verify(RMF_PLAIN, NULL, c_imp, "is not the entry it was", "an entry's IMP");
    refused_verify(RMF_PLAIN, NULL, c_relative, "relative method lists", "a slot back on its relative list");
    refused_verify(RMF_ABSCAT, NULL, c_absolute, "named an absolute list", "an absolute list's slot moved");
    refused_verify(RMF_SHARED, NULL, c_split, "now name two", "a shared list split in two");
    refused_verify(RMF_PLAIN, NULL, c_drop_rebase, "rebases; the old one had", "a new pointer's rebase dropped");
    refused_verify(RMF_PLAIN, NULL, c_move_rebase, "offset 0x1088 has no rebase", "a rebase on the wrong slot");
    refused_verify(RMF_PLAIN, NULL, c_add_rebase, "rebases; the old one had", "a rebase for an IMP of 0");
    refused_verify(RMF_PLAIN, NULL, c_dvmsize, "vmsize/filesize", "D grown too far");
    refused_verify(RMF_PLAIN, NULL, c_lfilesize, "__LINKEDIT's geometry", "__LINKEDIT's size");
    refused_verify(RMF_PLAIN, NULL, c_lvmaddr, "__LINKEDIT's geometry", "__LINKEDIT's address");
    refused_verify(RMF_PLAIN, NULL, c_truncate, "ending the file", "bytes past __LINKEDIT's end");
    refused_verify(RMF_PLAIN, NULL, c_rebase_size, "rebase_off/size", "rebase_size past the stream");
    refused_verify(RMF_PLAIN, NULL, c_symoff, "__LINKEDIT offset", "symoff moved by the wrong amount");
    refused_verify(RMF_PLAIN, NULL, c_nsyms, "load-command byte", "a load-command field nothing edits");
    refused_verify(RMF_PLAIN, NULL, c_below, "below the insertion", "a byte below the insertion");
    refused_verify(RMF_ZEROTAIL, NULL, c_zerofill, "zero-fill byte", "a zero-fill byte");
    refused_verify(RMF_PLAIN, NULL, c_past_lists, "past the lists", "a byte past the lists");
    refused_verify(RMF_CODESIG, NULL, c_linkedit, "is not what it was", "a code-signature byte");
    refused_verify(RMF_PLAIN, NULL, c_old_stream, "the old rebase stream, zeroed", "the old stream left in place");
    refused_verify(RMF_PLAIN, poke_text_over_data, NULL, "overlap in memory", "segments that overlap");
}

static void test_convert_swaps_only_what_verifies(void) {
    uint8_t *buf = malloc(RMF_SIZE), *was;
    size_t size = RMF_SIZE;
    mma_report rep;
    rmf_build(buf, RMF_PLAIN);
    was = buf;
    CHECK(mma_convert(&buf, &size, &rep) == 0 && buf != was && size > RMF_SIZE && rep.lists == 4,
          "convert plain: not replaced (%zu bytes, %u lists)", size, rep.lists);
    was = buf;
    CHECK(mma_convert(&buf, &size, &rep) == 0 && buf == was && rep.lists == 0,
          "convert again: replaced, or %u lists", rep.lists);
    free(buf);
    buf = malloc(RMF_SIZE);
    size = RMF_SIZE;
    rmf_build(buf, RMF_DATARO);
    was = buf;
    CHECK(mma_convert(&buf, &size, &rep) == MR_REFUSED && buf == was && size == RMF_SIZE,
          "convert dataro: not refused, or the image replaced");
    free(buf);
}
```

and in `main`, after `test_conversion_refusals_write_nothing();`:

```c
    test_every_conversion_verifies();
    test_verification_refuses_every_difference();
    test_convert_swaps_only_what_verifies();
```

`c_move_rebase` depends on the plain fixture's last run, `SET_SEGMENT_AND_OFFSET_ULEB 2, 0x1080` (ULEB `0x80 0x21`) then `DO_REBASE_IMM_TIMES 2`: rewriting the ULEB to `0xf8 0x20` (0x1078) moves the run one slot early, so the count stays right and slot 0x1088 loses its rebase.

- [ ] **Step 2: Run to see it fail**

Run: build.
Expected: clang warns `implicit declaration of function 'mma_verify'` (and `'mma_convert'`), then the link fails: `Undefined symbols for architecture x86_64: "_mma_convert" ... "_mma_verify"`.

- [ ] **Step 3: Declare them in `src/objc_abs.h`**

Before the final `#endif`, after `void mma_out_free(mma_out *o);`, add:

```c

/* Checks o->buf against `in`, the image it was built from, and against
 * nothing mma_build computed but o->lay, o->s and o->r: the output's walk
 * finds no relative list, the same slots, and in each converted list the
 * same entries in the same order; its rebases are the input's plus exactly
 * one per new pointer that is not 0; its load commands differ only in D's
 * and __LINKEDIT's geometry and the __LINKEDIT offsets, each by exactly what
 * the layout says; every byte outside the new lists and stream is the
 * input's, moved or not, but for the repointed slots, the zero fill and the
 * zeroed old rebase stream; __LINKEDIT ends the file; no segments overlap.
 * MMA_OK, or MMA_REFUSED / MMA_NOMEM with why set. */
int  mma_verify(const mi_image *in, const mma_out *o, char *why, size_t whysz);

/* The statement: mma_build, then mma_verify, then the image is replaced.
 * 0 with *rep filled (rep->lists == 0 when there was nothing to convert), or
 * MR_REFUSED / MR_FAIL (src/rewrite.h) with the reason on stderr. *pbuf and
 * *psize name the image afterwards either way; on a non-zero return it is
 * the image as it was. */
int  mma_convert(uint8_t **pbuf, size_t *psize, mma_report *rep);
```

- [ ] **Step 4: Implement them in `src/objc_abs.c`**

After `#include "linkedit.h"` add `#include "rewrite.h"`; after `#include "mach_compat.h"` add a blank line and `#define WHAT "drydock-macho-rewrite: objc-methods set absolute"`. Append:

```c
/* ---- verification --------------------------------------------------------- */

/* Every ml_each_off field's value, in order; which one is rebase_off; and,
 * with a mask, which load-command bytes they occupy. */
typedef struct {
    uint32_t *v;
    uint32_t n, cap, rb_at;
    const uint32_t *rb;
    uint8_t *mask;
    const uint8_t *base;
    int oom;
} mma_offs;

static int mma_collect_off(uint32_t *off, uint32_t cmd, int flags, void *ctx_) {
    mma_offs *c = ctx_;
    (void)cmd; (void)flags;
    if (c->mask) memset(c->mask + ((const uint8_t *)off - c->base), 1, 4);
    if (off == c->rb) c->rb_at = c->n;
    if (c->n == c->cap) {
        uint32_t cap = c->cap ? c->cap * 2 : 32;
        uint32_t *v = realloc(c->v, cap * sizeof *v);
        if (!v) { c->oom = 1; return 1; }
        c->v = v;
        c->cap = cap;
    }
    c->v[c->n++] = *off;
    return 0;
}

typedef struct {
    const struct segment_command_64 *seg[MML_MAX_SEGS];
    int n;
    const struct dyld_info_command *di;
} mma_lcs;

static int mma_lcs_lc(const struct load_command *lc, void *ctx_) {
    mma_lcs *c = ctx_;
    if (lc->cmd == LC_SEGMENT_64 && c->n < MML_MAX_SEGS)
        c->seg[c->n++] = (const struct segment_command_64 *)lc;
    if (lc->cmd == LC_DYLD_INFO || lc->cmd == LC_DYLD_INFO_ONLY)
        c->di = (const struct dyld_info_command *)lc;
    return 0;
}

/* The output's walk against the input's, and every new pointer's slot into `added`. */
static int mma_verify_walk(const mml_walk *wi, const mml_walk *wo, const mml_resolver *ri,
                           const mml_resolver *ro, const mma_out *o, uint64_t d_vmaddr,
                           const uint32_t *first, mrb_set *added, uint64_t *used,
                           char *why, size_t whysz) {
    uint32_t i, e;
    if (wo->relative)
        return mma_fail(why, whysz, MMA_REFUSED, "the output still has %u relative method lists",
                        wo->relative);
    if (wo->n != wi->n)
        return mma_fail(why, whysz, MMA_REFUSED, "the output has %u method-list slots, the input %u",
                        wo->n, wi->n);
    for (i = 0; i < wi->n; i++) {
        const mml_ref *a = &wi->refs[i], *b = &wo->refs[i];
        if (a->slot_off != b->slot_off)
            return mma_fail(why, whysz, MMA_REFUSED, "method-list slot %u moved from 0x%llx to 0x%llx",
                            i, (unsigned long long)a->slot_off, (unsigned long long)b->slot_off);
        if (!(a->header & MML_RELATIVE)) {
            if (b->list_va != a->list_va)
                return mma_fail(why, whysz, MMA_REFUSED, "the slot at 0x%llx named an absolute list "
                                "at 0x%llx and now names 0x%llx", (unsigned long long)a->slot_off,
                                (unsigned long long)a->list_va, (unsigned long long)b->list_va);
            continue;
        }
        if (b->list_va != wo->refs[first[i]].list_va)
            return mma_fail(why, whysz, MMA_REFUSED, "the slots at 0x%llx and 0x%llx named one list "
                            "and now name two", (unsigned long long)wi->refs[first[i]].slot_off,
                            (unsigned long long)a->slot_off);
        if (b->list_va < o->lay.list_va || b->list_va - o->lay.list_va >= o->s ||
            b->header != MML_ABS_ENTSIZE || b->count != a->count)
            return mma_fail(why, whysz, MMA_REFUSED, "the slot at 0x%llx names 0x%llx, which is not "
                            "a converted list of %u entries", (unsigned long long)a->slot_off,
                            (unsigned long long)b->list_va, a->count);
        if (first[i] != i) continue;
        for (e = 0; e < a->count; e++) {
            mml_entry x, y;
            uint64_t slot = b->list_va + 8 + (uint64_t)MML_ABS_ENTSIZE * e - d_vmaddr;
            if (mml_entry_at(ri, a, e, &x, why, whysz) != MML_OK ||
                mml_entry_at(ro, b, e, &y, why, whysz) != MML_OK)
                return MMA_REFUSED;
            if (x.name != y.name || x.types != y.types || x.imp != y.imp)
                return mma_fail(why, whysz, MMA_REFUSED, "entry %u of the list the slot at 0x%llx "
                                "names is not the entry it was", e, (unsigned long long)a->slot_off);
            for (int k = 0; k < 3; k++)
                if ((k < 2 || y.imp) &&
                    mrb_add(added, (uint8_t)o->lay.d, REBASE_TYPE_POINTER, slot + 8 * (uint64_t)k) != 0)
                    return mma_fail(why, whysz, MMA_NOMEM, "out of memory");
        }
        if (b->list_va + 8 + (uint64_t)MML_ABS_ENTSIZE * a->count - o->lay.list_va > *used)
            *used = b->list_va + 8 + (uint64_t)MML_ABS_ENTSIZE * a->count - o->lay.list_va;
    }
    return MMA_OK;
}

static int mma_verify_rebases(const mi_image *in, const mma_out *o, const mma_lcs *li,
                              const mma_lcs *lo, mrb_set *added, char *why, size_t whysz) {
    mrb_set was, now;
    int rc = MMA_REFUSED;
    size_t k;
    memset(&was, 0, sizeof was);
    memset(&now, 0, sizeof now);
    if (mrb_decode(in->buf + li->di->rebase_off, li->di->rebase_size, li->n, &was, why, whysz) != MRB_OK ||
        mrb_decode(o->buf + lo->di->rebase_off, lo->di->rebase_size, lo->n, &now, why, whysz) != MRB_OK)
        goto out;
    mrb_sort(&was);
    mrb_sort(added);
    mrb_sort(&now);
    if (now.n != was.n + added->n) {
        mma_fail(why, whysz, MMA_REFUSED, "the new rebase stream has %zu rebases; the old one had %zu "
                 "and %zu pointers are new", now.n, was.n, added->n);
        goto out;
    }
    for (k = 0; k < was.n; k++)
        if (!mrb_has(&now, was.v[k].seg, was.v[k].off)) {
            mma_fail(why, whysz, MMA_REFUSED, "the old rebase of segment %u offset 0x%llx is gone",
                     was.v[k].seg, (unsigned long long)was.v[k].off);
            goto out;
        }
    for (k = 0; k < added->n; k++)
        if (!mrb_has(&now, added->v[k].seg, added->v[k].off)) {
            mma_fail(why, whysz, MMA_REFUSED, "the new pointer at segment %u offset 0x%llx has no rebase",
                     added->v[k].seg, (unsigned long long)added->v[k].off);
            goto out;
        }
    rc = MMA_OK;
out:
    mrb_free(&was);
    mrb_free(&now);
    return rc;
}

static int mma_verify_lcs(const mi_image *in, const mma_out *o, const mma_lcs *li, const mma_lcs *lo,
                          char *why, size_t whysz) {
    const struct mach_header_64 *hi = in->hdr, *ho = (const struct mach_header_64 *)o->buf;
    const struct segment_command_64 *di = li->seg[o->lay.d], *dn = lo->seg[o->lay.d];
    const struct segment_command_64 *l0 = li->seg[o->lay.l], *ln = lo->seg[o->lay.l];
    uint64_t z = o->lay.z, grow = z + o->s + o->r, need;
    mi_image a, b;
    mma_offs oi, on;
    uint8_t *mask;
    uint32_t k;
    int rc = MMA_REFUSED;

    if (memcmp(hi, ho, sizeof *hi) != 0 || lo->n != li->n || !lo->di)
        return mma_fail(why, whysz, MMA_REFUSED, "the mach header or the segment count changed");
    if (dn->vmsize != di->vmsize + o->s || dn->filesize != di->filesize + z + o->s)
        return mma_fail(why, whysz, MMA_REFUSED, "%.16s's vmsize/filesize are 0x%llx/0x%llx; want "
                        "0x%llx/0x%llx", dn->segname, (unsigned long long)dn->vmsize,
                        (unsigned long long)dn->filesize, (unsigned long long)(di->vmsize + o->s),
                        (unsigned long long)(di->filesize + z + o->s));
    need = (l0->filesize + o->r + MMA_PAGE - 1) & ~(uint64_t)(MMA_PAGE - 1);
    if (ln->vmaddr != l0->vmaddr + o->s || ln->fileoff != l0->fileoff + z + o->s ||
        ln->filesize != l0->filesize + o->r || ln->vmsize != (l0->vmsize > need ? l0->vmsize : need))
        return mma_fail(why, whysz, MMA_REFUSED, "__LINKEDIT's geometry is not what the layout says");
    if (lo->n - 1 != o->lay.l || ln->fileoff + ln->filesize != o->size)
        return mma_fail(why, whysz, MMA_REFUSED, "__LINKEDIT is not the last segment ending the file");
    for (int x = 0; x < lo->n; x++)
        for (int y = x + 1; y < lo->n; y++) {
            const struct segment_command_64 *p = lo->seg[x], *q = lo->seg[y];
            if (p->vmsize && q->vmsize && p->vmaddr < q->vmaddr + q->vmsize && q->vmaddr < p->vmaddr + p->vmsize)
                return mma_fail(why, whysz, MMA_REFUSED, "segments %.16s and %.16s overlap in memory",
                                p->segname, q->segname);
        }

    if (!(mask = calloc(1, ho->sizeofcmds)))
        return mma_fail(why, whysz, MMA_NOMEM, "out of memory");
    memset(&oi, 0, sizeof oi);
    memset(&on, 0, sizeof on);
    on.rb = &lo->di->rebase_off;
    on.rb_at = UINT32_MAX;
    on.mask = mask;
    on.base = o->buf + sizeof *ho;
    if (mi_wrap(in->buf, in->size, &a) != 0 || mi_wrap(o->buf, o->size, &b) != 0 ||
        ml_each_off(&a, mma_collect_off, &oi) != 0 || ml_each_off(&b, mma_collect_off, &on) != 0) {
        rc = mma_fail(why, whysz, oi.oom || on.oom ? MMA_NOMEM : MMA_REFUSED, "the __LINKEDIT offsets "
                      "could not be read");
        goto out;
    }
    if (oi.n != on.n) {
        mma_fail(why, whysz, MMA_REFUSED, "the output has %u __LINKEDIT offsets, the input %u", on.n, oi.n);
        goto out;
    }
    for (k = 0; k < oi.n; k++) {
        uint64_t want = oi.v[k] >= o->lay.insert && oi.v[k] ? oi.v[k] + grow : oi.v[k];
        if (k == on.rb_at) continue;
        if (on.v[k] != want) {
            mma_fail(why, whysz, MMA_REFUSED, "__LINKEDIT offset %u is 0x%x; want 0x%llx", k, on.v[k],
                     (unsigned long long)want);
            goto out;
        }
    }
    if (lo->di->rebase_off != o->lay.insert + z + o->s || lo->di->rebase_size != o->r) {
        mma_fail(why, whysz, MMA_REFUSED, "rebase_off/size are 0x%x/0x%x; want 0x%llx/0x%x",
                 lo->di->rebase_off, lo->di->rebase_size,
                 (unsigned long long)(o->lay.insert + z + o->s), o->r);
        goto out;
    }
    memset(mask + ((const uint8_t *)&lo->di->rebase_size - on.base), 1, 4);
    memset(mask + ((const uint8_t *)&dn->vmsize - on.base), 1, 8);
    memset(mask + ((const uint8_t *)&dn->filesize - on.base), 1, 8);
    memset(mask + ((const uint8_t *)&ln->vmaddr - on.base), 1, 8);
    memset(mask + ((const uint8_t *)&ln->vmsize - on.base), 1, 8);
    memset(mask + ((const uint8_t *)&ln->fileoff - on.base), 1, 8);
    memset(mask + ((const uint8_t *)&ln->filesize - on.base), 1, 8);
    for (k = 0; k < ho->sizeofcmds; k++)
        if (!mask[k] && in->buf[sizeof *hi + k] != o->buf[sizeof *ho + k]) {
            mma_fail(why, whysz, MMA_REFUSED, "load-command byte %u changed, and nothing the "
                     "conversion edits lives there", k);
            goto out;
        }
    rc = MMA_OK;
out:
    free(mask);
    free(oi.v);
    free(on.v);
    return rc;
}

static int mma_verify_bytes(const mi_image *in, const mma_out *o, const mml_walk *wi,
                            const mma_lcs *li, uint64_t used, char *why, size_t whysz) {
    uint64_t at = o->lay.insert, z = o->lay.z, grow = z + o->s + o->r, k;
    uint64_t lc_end = sizeof(struct mach_header_64) + in->hdr->sizeofcmds;
    uint64_t old_rb = li->di->rebase_off, old_rb_end = old_rb + li->di->rebase_size;
    uint8_t *slot = calloc(1, at ? at : 1);
    if (!slot) return mma_fail(why, whysz, MMA_NOMEM, "out of memory");
    for (uint32_t i = 0; i < wi->n; i++)
        if ((wi->refs[i].header & MML_RELATIVE) && wi->refs[i].slot_off + 8 <= at)
            memset(slot + wi->refs[i].slot_off, 1, 8);
    for (k = lc_end; k < at; k++)
        if (!slot[k] && o->buf[k] != in->buf[k]) {
            free(slot);
            return mma_fail(why, whysz, MMA_REFUSED, "byte 0x%llx, below the insertion, changed",
                            (unsigned long long)k);
        }
    free(slot);
    for (k = at; k < at + z; k++)
        if (o->buf[k])
            return mma_fail(why, whysz, MMA_REFUSED, "zero-fill byte 0x%llx is not zero",
                            (unsigned long long)k);
    for (k = at + z + used; k < at + z + o->s; k++)
        if (o->buf[k])
            return mma_fail(why, whysz, MMA_REFUSED, "byte 0x%llx, past the lists, is not zero",
                            (unsigned long long)k);
    for (k = at; k < in->size; k++) {
        int in_old_rb = k >= old_rb && k < old_rb_end;
        if (o->buf[k + grow] != (in_old_rb ? 0 : in->buf[k]))
            return mma_fail(why, whysz, MMA_REFUSED, "__LINKEDIT byte 0x%llx is not what it was at "
                            "0x%llx%s", (unsigned long long)(k + grow), (unsigned long long)k,
                            in_old_rb ? ", the old rebase stream, zeroed" : "");
    }
    return MMA_OK;
}

int mma_verify(const mi_image *in, const mma_out *o, char *why, size_t whysz) {
    mi_image out;
    mml_walk wi, wo;
    mml_resolver ri, ro;
    mma_lcs li, lo;
    mrb_set added;
    uint32_t *first = NULL;
    uint64_t used = 0;
    int rc;

    memset(&wi, 0, sizeof wi);
    memset(&wo, 0, sizeof wo);
    memset(&ri, 0, sizeof ri);
    memset(&ro, 0, sizeof ro);
    memset(&li, 0, sizeof li);
    memset(&lo, 0, sizeof lo);
    memset(&added, 0, sizeof added);
    if (mi_wrap(o->buf, o->size, &out) != 0)
        return mma_fail(why, whysz, MMA_REFUSED, "the output is not a readable 64-bit Mach-O");
    mi_each_lc(in, mma_lcs_lc, &li);
    mi_each_lc(&out, mma_lcs_lc, &lo);
    if (!li.di || !lo.di)
        return mma_fail(why, whysz, MMA_REFUSED, "LC_DYLD_INFO is missing");
    rc = MMA_REFUSED;
    if (mml_walk_image(in, &wi) != MML_OK || mml_walk_image(&out, &wo) != MML_OK) {
        mma_fail(why, whysz, MMA_REFUSED, "the walk fails: %s", wo.why[0] ? wo.why : wi.why);
        goto out;
    }
    if (mml_resolver_open(in, &ri, why, whysz) != MML_OK ||
        mml_resolver_open(&out, &ro, why, whysz) != MML_OK)
        goto out;
    if (!(first = malloc((wi.n ? wi.n : 1) * sizeof *first)) || mma_firsts(&wi, first) != 0) {
        rc = mma_fail(why, whysz, MMA_NOMEM, "out of memory");
        goto out;
    }
    if ((rc = mma_verify_walk(&wi, &wo, &ri, &ro, o, li.seg[o->lay.d]->vmaddr, first, &added,
                              &used, why, whysz)) != MMA_OK ||
        (rc = mma_verify_rebases(in, o, &li, &lo, &added, why, whysz)) != MMA_OK ||
        (rc = mma_verify_lcs(in, o, &li, &lo, why, whysz)) != MMA_OK ||
        (rc = mma_verify_bytes(in, o, &wi, &li, used, why, whysz)) != MMA_OK)
        goto out;
    rc = MMA_OK;
out:
    free(first);
    mrb_free(&added);
    mml_resolver_close(&ri);
    mml_resolver_close(&ro);
    mml_walk_free(&wi);
    mml_walk_free(&wo);
    return rc;
}

int mma_convert(uint8_t **pbuf, size_t *psize, mma_report *rep) {
    mi_image im;
    mma_out o;
    char why[512] = "";
    int rc;

    memset(rep, 0, sizeof *rep);
    if (mi_wrap(*pbuf, *psize, &im) != 0) {
        fprintf(stderr, WHAT ": the image is not a readable 64-bit Mach-O\n");
        return MR_REFUSED;
    }
    rc = mma_build(&im, &o, why, sizeof why);
    if (rc == MMA_NOTHING) return 0;
    if (rc == MMA_OK) {
        rc = mma_verify(&im, &o, why, sizeof why);
        if (rc != MMA_OK) {
            mma_out_free(&o);
            if (rc == MMA_REFUSED) {
                fprintf(stderr, WHAT ": verification failed: %s; refusing\n", why);
                return MR_REFUSED;
            }
        }
    }
    if (rc == MMA_NOMEM) {
        fprintf(stderr, WHAT ": out of memory\n");
        return MR_FAIL;
    }
    if (rc != MMA_OK) {
        fprintf(stderr, WHAT ": %s; refusing\n", why);
        return MR_REFUSED;
    }
    *rep = o.rep;
    free(*pbuf);
    *pbuf = o.buf;
    *psize = o.size;
    return 0;
}
```

- [ ] **Step 5: Build and run**

Run: build (rebuild check on `$B/objc_meth_test`), `"$B/objc_meth_test"`, then the whole suite.
Expected: `objc_meth_test: 0 failure(s)` (one expected stderr line from `test_convert_swaps_only_what_verifies`'s read-only refusal); all pass.

- [ ] **Step 6: Mutation proof** (file `src/objc_abs.c`; test `$B/objc_meth_test`; each "…" names the `refused_verify` label that must fail in `test_verification_refuses_every_difference`)

| # | replace | with | must fail |
|---|---|---|---|
| 1 | `    if (wo->relative)` | `    if (0)` | "a slot back on its relative list" |
| 2 | `            if (b->list_va != a->list_va)` | `            if (0)` | "an absolute list's slot moved" |
| 3 | `if (b->list_va != wo->refs[first[i]].list_va)` | `if (0)` | "a shared list split in two" |
| 4 | `if (x.name != y.name \|\| x.types != y.types \|\| x.imp != y.imp)` | `if (x.types != y.types \|\| x.imp != y.imp)` | "an entry's name" |
| 5 | same line | `if (x.name != y.name \|\| x.imp != y.imp)` | "an entry's types" |
| 6 | same line | `if (x.name != y.name \|\| x.types != y.types)` | "an entry's IMP" |
| 7 | `if (now.n != was.n + added->n) {` | `if (0) {` | "a new pointer's rebase dropped", "a rebase for an IMP of 0" |
| 8 | `if (!mrb_has(&now, added->v[k].seg, added->v[k].off)) {` | `if (0) {` | "a rebase on the wrong slot" |
| 9 | `if (dn->vmsize != di->vmsize + o->s \|\| dn->filesize != di->filesize + z + o->s)` | `if (0)` | "D grown too far" |
| 10 | `if (ln->vmaddr != l0->vmaddr + o->s \|\| ln->fileoff` | `if (ln->fileoff` | "__LINKEDIT's address" |
| 11 | `if (lo->n - 1 != o->lay.l \|\| ln->fileoff + ln->filesize != o->size)` | `if (0)` | "bytes past __LINKEDIT's end" |
| 12 | `if (p->vmsize && q->vmsize && p->vmaddr` | `if (0 && p->vmaddr` | "segments that overlap" |
| 13 | `        if (on.v[k] != want) {` | `        if (0) {` | "symoff moved by the wrong amount" |
| 14 | `if (lo->di->rebase_off != o->lay.insert + z + o->s \|\| lo->di->rebase_size != o->r) {` | `if (0) {` | "rebase_size past the stream" |
| 15 | `if (!mask[k] && in->buf` | `if (0 && in->buf` | "a load-command field nothing edits" |
| 16 | `if (!slot[k] && o->buf[k] != in->buf[k]) {` | `if (0) {` | "a byte below the insertion" |
| 17 | the first `        if (o->buf[k])` in `mma_verify_bytes` | `        if (0)` | "a zero-fill byte" |
| 18 | the second `        if (o->buf[k])` | `        if (0)` | "a byte past the lists" |
| 19 | `(in_old_rb ? 0 : in->buf[k])` | `(in_old_rb ? o->buf[k + grow] : in->buf[k])` | "the old stream left in place" |
| 20 | in `mma_convert`'s last refusal, `fprintf(stderr, WHAT ": %s; refusing\n", why);` and the `return MR_REFUSED;` after it | `return 0;` | `test_convert_swaps_only_what_verifies` ("convert dataro") |

- [ ] **Step 7: Commit**

```bash
git add src/objc_abs.h src/objc_abs.c tests/objc_meth_test.c
git commit -m "feat(objc): verify a conversion before handing it back

The output is walked again and must hold no relative list, the same
slots, and in each converted list the same entries in the same order.
Its rebases are decoded and must be the input's plus exactly one per new
pointer that is not 0. Its load commands may differ only in D's and
__LINKEDIT's geometry and the __LINKEDIT offsets, each by what the layout
says; every other byte must be the input's, moved or not. Any difference
refuses and nothing is written.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 7: The statement: row, lowering, log lines, CLI

**Files:**
- Modify: `src/script.h:41-42` (the kind enum, ending `MS_TARGET, MS_IMPORT, MS_MINOS };`)
- Modify: `src/script.c:132` (the last `MS_TABLE_ROWS` row, today `minos if-absent`), `:450-454` (the last value check, today `import redirect`'s)
- Modify: `src/edit.c:37` (`#include "redirect.h"`), after `:240` (`me_log_declared`'s closing `}`), after `:482` (the `MS_FIXUPS` case's closing `}`, just before the switch's `}` at `:483`)
- Test: `tests/script_test.c:381` (`else if (strcmp(kind, "fixups") == 0) a = "classic";`), `:410` (the row count), `:518-520` (the end of `test_disturbs_matches_the_spec_table`), before `:522` (`static void test_import_redirect(void) {`), `:844` (`test_retired_minimum_statements_are_unknown();` in `main`)
- Test: `tests/cli_test.sh:498-499` (the statement count), before `:4943` (`reached_end=1`)

**Interfaces:**
- Consumes: `mma_convert`, `mma_report` (Tasks 5–6); `MML_NOWNERS` (M1); `me_say`, `me_count` (`src/edit.c:53`, `:92`); `MREL_FILE_OFF` (`src/relations.h:40`).
- Produces: the statement `objc-methods set absolute`: `MS_OBJC_METHODS` (kind enum), op `MS_SET`, one operand, disturbs `MREL_FILE_OFF`; the log lines below. M4's `me_expand_10_9` will derive `{ MS_OBJC_METHODS, MS_SET, "absolute" }`.

The row, the enum value, the value check and the `me_apply` case each go **after whatever is currently last**; the line numbers are HEAD `1a4a3da`'s. If a parallel plan has appended since, append after its entry and keep yours last.

**Plan decision:** the log prints its figures with the report's comma grouping (`4,096`), adds a third line only when zero fill became file bytes, and says `nothing to convert` when there was nothing. Why: every other follow-up line in `src/edit.c` goes through `me_count`; the zero-fill line is the one fact the spec's two-line example has no room for; and Decision 6 names the no-op's words. The spec example's "added 13 rebases" does not fit its own four lists and five methods: with one IMP of 0 that is 14, which is what the plain fixture pins.

- [ ] **Step 1: Write the failing tests**

`tests/script_test.c`:
- after `:381` (`        else if (strcmp(kind, "fixups") == 0) a = "classic";`) add `        else if (strcmp(kind, "objc-methods") == 0) a = "absolute";`
- at `:410`, read today's count N from `CHECK(n_rows == N, "the statement table has N rows (got %d)", n_rows);` (N is 18 at `1a4a3da`) and make both N+1 (19).
- at the end of `test_disturbs_matches_the_spec_table`, before its closing `}` (`:520`), add:

```c

    /* The conversion adds no load command and moves no vm address below
     * __LINKEDIT, so neither the pad nor a base-relative value; it inserts
     * bytes where __LINKEDIT began, which moves every __LINKEDIT offset. */
    CHECK(ms_disturbs(MS_OBJC_METHODS, MS_SET) == MREL_FILE_OFF,
          "objc-methods set absolute moves __LINKEDIT's offsets, and nothing else");
```

- before `static void test_import_redirect(void) {` (`:522`) add:

```c
static void test_objc_methods_set_takes_only_absolute(void) {
    ms_script s; char err[256] = {0};
    const char *ok = "objc-methods set absolute\n";
    CHECK(ms_parse(ok, strlen(ok), &s, err, sizeof err) == 0, "objc-methods set absolute rejected: %s", err);
    CHECK(s.n == 1 && s.stmts[0].kind == MS_OBJC_METHODS && s.stmts[0].op == MS_SET &&
          strcmp(s.stmts[0].a, "absolute") == 0, "objc-methods set absolute: wrong kind, op or operand");
    ms_free(&s);

    const char *rel = "objc-methods set relative\n";
    err[0] = 0;
    CHECK(ms_parse(rel, strlen(rel), &s, err, sizeof err) == -1 &&
          strstr(err, "objc-methods set accepts only 'absolute' (got 'relative')") != NULL,
          "objc-methods set relative: %s", err);

    const char *bare = "objc-methods set\n";
    err[0] = 0;
    CHECK(ms_parse(bare, strlen(bare), &s, err, sizeof err) == -1 &&
          strstr(err, "takes 1 argument (got 0)") != NULL, "objc-methods set with no value: %s", err);
}
```

- in `main`, after `    test_retired_minimum_statements_are_unknown();` (`:844`) add `    test_objc_methods_set_takes_only_absolute();`.

`tests/cli_test.sh`:
- at `:498-499`, read today's N from `[ "$n_statements" -eq N ] && [ "$n_unique" -eq N ]` (18 at `1a4a3da`) and make every N in those two lines N+1 (19), message included: `ok "capabilities: exactly 19 unique statement lines"`.
- before `reached_end=1` (`:4943`) insert:

```sh
# ---- objc-methods set absolute ------------------------------------------------
# The fixtures are tests/relmeth_fixture.h's, written by mkrelmeth (built in
# the info block above); `mkrelmeth entries` is the oracle, reading each
# method-list slot without src/.
om() {   # om VARIANT: run `objc-methods set absolute` on relmeth_VARIANT into .out
    rm -f "$T/relmeth_$1.out"
    om_rc=0
    printf 'objc-methods set absolute\n' | "$DRYDOCK_MACHO_REWRITE" "$T/relmeth_$1" "$T/relmeth_$1.out" \
        >"$T/om.out" 2>"$T/om.err" || om_rc=$?
}
for v in shared allslots zerotail dylib codesig+split fstarts dataro gap segafter selbind fsbad noslotrb; do
    "$T/mkrelmeth" make "$v" "$T/relmeth_$v"
done

echo "$caps" | grep -qxF "statement objc-methods set 1" \
    && ok "capabilities: objc-methods set is advertised" \
    || bad "capabilities objc-methods" "no 'statement objc-methods set 1': $(echo "$caps" | grep '^statement objc')"

om_before=$(sha "$T/relmeth_plain")
om plain
[ "$om_rc" -eq 0 ] && [ "$(sha "$T/relmeth_plain")" = "$om_before" ] \
    && ok "objc-methods set absolute: converts, and leaves FILE as it was" \
    || bad "objc-methods plain" "rc $om_rc: $(cat "$T/om.err")"
grep -qxF "      converted 4 relative method lists (5 methods) onto the end of __DATA: 1 class, 1 metaclass, 1 category, 1 protocol" "$T/om.err" \
    && grep -qxF "      added 14 rebases; __DATA grew 4,096 bytes; __LINKEDIT 512 -> 584 bytes, moved up 4,096" "$T/om.err" \
    && ok "objc-methods set absolute: logs what it converted and what moved" \
    || bad "objc-methods log" "$(cat "$T/om.err")"
[ "$(info_ml "$T/relmeth_plain.out")" = "objc-methods: 0 relative, 4 absolute" ] \
    && ok "objc-methods set absolute: info counts every list absolute afterwards" \
    || bad "objc-methods info" "got: '$(info_ml "$T/relmeth_plain.out")'"
"$T/mkrelmeth" entries "$T/relmeth_plain" | sed 's/ rel / abs /' >"$T/om.want"
"$T/mkrelmeth" entries "$T/relmeth_plain.out" >"$T/om.got"
[ -s "$T/om.want" ] && cmp -s "$T/om.want" "$T/om.got" \
    && ok "objc-methods set absolute: the oracle reads the same methods, in the same order" \
    || bad "objc-methods oracle" "$(diff "$T/om.want" "$T/om.got")"
"$DRYDOCK_MACHO_REWRITE" verify "$T/relmeth_plain.out" >/dev/null 2>"$T/om_v.err" \
    && ok "objc-methods set absolute: the output passes verify" \
    || bad "objc-methods verify" "$(cat "$T/om_v.err")"

for v in shared allslots zerotail dylib codesig+split fstarts; do
    om "$v"
    "$T/mkrelmeth" entries "$T/relmeth_$v" | sed 's/ rel / abs /' >"$T/om.want"
    "$T/mkrelmeth" entries "$T/relmeth_$v.out" >"$T/om.got" 2>/dev/null || true
    [ "$om_rc" -eq 0 ] && [ -s "$T/om.want" ] && cmp -s "$T/om.want" "$T/om.got" \
        && ok "objc-methods set absolute: $v converts to what the oracle reads" \
        || bad "objc-methods $v" "rc $om_rc: $(cat "$T/om.err"; diff "$T/om.want" "$T/om.got")"
done
om allslots
grep -qxF "      converted 4 relative method lists (5 methods) onto the end of __DATA: 1 class, 1 metaclass, 2 categories" "$T/om.err" \
    && ok "objc-methods set absolute: counts a list by the record of the first slot naming it" \
    || bad "objc-methods allslots log" "$(cat "$T/om.err")"
om zerotail
grep -qxF "      __DATA's 4,096 bytes of zero fill are file bytes now" "$T/om.err" \
    && ok "objc-methods set absolute: says when a zero-fill tail became file bytes" \
    || bad "objc-methods zerotail log" "$(cat "$T/om.err")"
om dylib
"$DRYDOCK_MACHO_REWRITE" info "$T/relmeth_dylib.out" 2>/dev/null | grep -qxF "header pad: 16 bytes available (LC end=2032, first sect=2048)" \
    && ok "objc-methods set absolute: a dylib with 16 bytes of pad converts, and keeps its 16" \
    || bad "objc-methods dylib pad" "$("$DRYDOCK_MACHO_REWRITE" info "$T/relmeth_dylib.out" 2>&1 | grep '^header pad')"

om_refused() {   # om_refused VARIANT WANT LABEL
    om_was=$(sha "$T/relmeth_$1")
    om "$1"
    [ "$om_rc" -eq 1 ] && [ ! -e "$T/relmeth_$1.out" ] && [ "$(sha "$T/relmeth_$1")" = "$om_was" ] \
        && grep -qF "$2" "$T/om.err" \
        && ok "objc-methods set absolute: refuses $3 (1), writing nothing" \
        || bad "objc-methods refuses $3" "rc $om_rc, want 1 and '$2': $(cat "$T/om.err")"
}
om_refused chained "the image has chained fixups; fixups set classic first" "a chained image"
om_refused dataro "is not writable" "a read-only __DATA"
om_refused gap "and __LINKEDIT begins at" "a gap before __LINKEDIT"
om_refused segafter "__LINKEDIT is not the last segment" "a segment after __LINKEDIT"
om_refused selbind "is bound to another image" "a bound selector reference"
om_refused fsbad "is not one of the 3 function starts" "an IMP that is not a function start"
om_refused noslotrb "carries no rebase" "a method-list slot with no rebase"

cp "$T/relmeth_plain.out" "$T/relmeth_again"
om again
[ "$om_rc" -eq 0 ] && grep -qxF "      nothing to convert" "$T/om.err" && cmp -s "$T/relmeth_again" "$T/relmeth_again.out" \
    && ok "objc-methods set absolute: a converted image has nothing to convert, and is written unchanged" \
    || bad "objc-methods again" "rc $om_rc: $(cat "$T/om.err")"

rc=0; printf 'objc-methods set relative\n' | "$DRYDOCK_MACHO_REWRITE" "$T/relmeth_plain" "$T/om_rel.out" >/dev/null 2>"$T/om_rel.err" || rc=$?
[ "$rc" -eq 2 ] && [ ! -e "$T/om_rel.out" ] && grep -qF "objc-methods set accepts only 'absolute' (got 'relative')" "$T/om_rel.err" \
    && ok "objc-methods set: any value but absolute is a parse error (2)" \
    || bad "objc-methods set relative" "rc $rc: $(cat "$T/om_rel.err")"
```

The expected log figures for the plain fixture: 4 lists, 5 methods, 14 rebases (Task 5); D grows one page; `__LINKEDIT`'s filesize goes from 0x200 (512) by R = 72: the old stream's 54 bytes up to its `DONE` (`SET_TYPE_IMM`, then fifteen `SET_SEGMENT_AND_OFFSET_ULEB` + `DO_REBASE_IMM_TIMES 1` pairs, seven with a one-byte ULEB and eight with two), then 17 new bytes (`SET_TYPE_IMM`, and four runs of 6, 3, 3 and 2 pointers at four bytes each), then `DONE`: 72, already a multiple of 8.

- [ ] **Step 2: Run to see it fail**

Run: build.
Expected: `script_test` does not compile: `use of undeclared identifier 'MS_OBJC_METHODS'`.

- [ ] **Step 3: Add the kind, the row and the value check**

`src/script.h:41-42`: replace

```c
enum { MS_LOAD_COMMAND, MS_SEGMENT, MS_SWIFT_ABI,
       MS_FIXUPS, MS_DYLIB, MS_RPATH, MS_TARGET, MS_IMPORT, MS_MINOS };
```

with

```c
enum { MS_LOAD_COMMAND, MS_SEGMENT, MS_SWIFT_ABI,
       MS_FIXUPS, MS_DYLIB, MS_RPATH, MS_TARGET, MS_IMPORT, MS_MINOS,
       MS_OBJC_METHODS };
```

`src/script.c:132`: give today's last row a ` \` continuation and add after it:

```c
  R("objc-methods", MS_OBJC_METHODS, "set",      MS_SET,          1, NULL,        0,             0, MREL_FILE_OFF)
```

`src/script.c:450-454`: after the last `else if` branch of the value checks (today `import redirect`'s, ending `"import redirect: FROM-LIB and TO-LIB are both '%s'", fields[3]);` and `}`), extend the chain:

```c
            } else if (kind == MS_OBJC_METHODS && op == MS_SET &&
                       strcmp(fields[2], "absolute") != 0) {
                return ms_failf(stmts, text, out, err, errsz, lineno,
                    "objc-methods set accepts only 'absolute' (got '%s')", fields[2]);
            }
```

(that is: the `}` that closed `import redirect`'s branch becomes the `} else if` above).

- [ ] **Step 4: Lower it in `src/edit.c`**

After `#include "redirect.h"` (`:37`) add `#include "objc_abs.h"`. After `me_log_declared`'s closing `}` (`:240`) add:

```c

static void me_log_objc_methods(FILE *log, const mma_report *r) {
    static const char *const one[MML_NOWNERS] = { "class", "metaclass", "category", "protocol" };
    static const char *const many[MML_NOWNERS] = { "classes", "metaclasses", "categories", "protocols" };
    char c1[32], c2[32], c3[32], c4[32], c5[32];
    const char *sep = ": ";
    if (r->lists == 0) {
        me_say(log, "      nothing to convert\n");
        return;
    }
    me_say(log, "      converted %s relative method list%s (%s method%s) onto the end of %.16s",
           me_count(c1, r->lists), r->lists == 1 ? "" : "s", me_count(c2, r->methods),
           r->methods == 1 ? "" : "s", r->dname);
    for (int k = 0; k < MML_NOWNERS; k++) {
        if (!r->owners[k]) continue;
        me_say(log, "%s%s %s", sep, me_count(c1, r->owners[k]), r->owners[k] == 1 ? one[k] : many[k]);
        sep = ", ";
    }
    me_say(log, "\n");
    me_say(log, "      added %s rebase%s; %.16s grew %s bytes; __LINKEDIT %s -> %s bytes, moved up %s\n",
           me_count(c1, r->rebases), r->rebases == 1 ? "" : "s", r->dname, me_count(c2, (long)r->grew),
           me_count(c3, (long)r->linkedit_before), me_count(c4, (long)r->linkedit_after),
           me_count(c5, (long)r->grew));
    if (r->zerofill)
        me_say(log, "      %.16s's %s bytes of zero fill are file bytes now\n", r->dname,
               me_count(c1, (long)r->zerofill));
}
```

In `me_apply`, after the `MS_FIXUPS` case's closing `}` (`:482`) and before the switch's closing `}` (`:483`), add:

```c

    case MS_OBJC_METHODS: {
        mma_report r;
        if (st->op != MS_SET) goto unknown;
        int rc = mma_convert(pbuf, psize, &r);
        if (rc != 0) return rc;
        me_log_objc_methods(log, &r);
        return 0;
    }
```

- [ ] **Step 5: Build and run**

Run: build (rebuild check on `$B/drydock-macho-rewrite` and `$B/script_test`); `"$B/script_test"`; `unset DRYDOCK_MACHO_REWRITE; sh tests/cli_test.sh "$B" 2>&1 | grep -E '^FAIL|objc-methods set|19 unique'`; then the whole suite.
Expected: `script_test: 0 failure(s)`; every `objc-methods set absolute` line `PASS`, `PASS capabilities: exactly 19 unique statement lines`, no `FAIL`; all pass.

- [ ] **Step 6: Mutation proof**

| # | file | replace | with | must fail |
|---|---|---|---|---|
| 1 | `src/script.c` | `strcmp(fields[2], "absolute") != 0) {` | `0) {` | `script_test`: `test_objc_methods_set_takes_only_absolute`; `cli_test`: "objc-methods set: any value but absolute is a parse error (2)" |
| 2 | `src/script.c` | the new row's `MREL_FILE_OFF)` | `MREL_NONE)` | `script_test`: `test_disturbs_matches_the_spec_table` |
| 3 | `src/edit.c` | `        int rc = mma_convert(pbuf, psize, &r);` | `        int rc = 0; memset(&r, 0, sizeof r);` | `cli_test`: "logs what it converted and what moved", "info counts every list absolute afterwards" |
| 4 | `src/edit.c` | `r->owners[k] == 1 ? one[k] : many[k]` | `one[k]` | `cli_test`: "counts a list by the record of the first slot naming it" |
| 5 | `src/edit.c` | `    if (r->zerofill)` | `    if (0)` | `cli_test`: "says when a zero-fill tail became file bytes" |
| 6 | `src/edit.c` | `me_count(c5, (long)r->grew)` | `me_count(c5, (long)r->zerofill)` | `cli_test`: "logs what it converted and what moved" |
| 7 | `src/edit.c` | `"      nothing to convert\n"` | `"      nothing\n"` | `cli_test`: "a converted image has nothing to convert, and is written unchanged" |

- [ ] **Step 7: Commit**

```bash
git add src/script.h src/script.c src/edit.c tests/script_test.c tests/cli_test.sh
git commit -m "feat(edit): objc-methods set absolute

The statement converts every relative Objective-C method list the walk
reaches, verifies the result, and logs what it converted and what moved:

    objc-methods set absolute
        converted 4 relative method lists (5 methods) onto the end of __DATA: 1 class, 1 metaclass, 1 category, 1 protocol
        added 14 rebases; __DATA grew 4,096 bytes; __LINKEDIT 512 -> 584 bytes, moved up 4,096

It declares MREL_FILE_OFF: it adds no load command and moves no address
below __LINKEDIT. 'absolute' is its only value.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 8: A header grow after the conversion still verifies

**Files:**
- Test: `tests/cli_test.sh` (after Task 7's block, before `reached_end=1`)

**Interfaces:**
- Consumes: Task 7's `om` helper and `$T/mkrelmeth` in `tests/cli_test.sh`; `dylib append` (which grows the header through `mg_ensure_pad` when the pad is short); `RMF_PAD16`, `RMF_FSTARTS` (Tasks 3–4); `mkrelmeth entries` (Task 5).
- Produces: nothing new; it pins Decision 1's "How this meets the grow machinery".

This is a characterization of code that already exists (`mg_grow_header` moves every segment after the header, so the lists move with D), so it is expected to pass the first time it runs. Its falsifiability is proved in Step 3 instead.

- [ ] **Step 1: Write the test**

In `tests/cli_test.sh`, after Task 7's block and before `reached_end=1`, insert:

```sh
# CONVERSION, THEN A HEADER GROW. The statement never touches the header, but
# a later statement may grow it, and mg_grow_header moves every segment's file
# bytes up by the grow: the lists past D's last section must move with D.
# pad16+fstarts leaves 16 bytes of pad, so `dylib append` must grow, and
# carries LC_FUNCTION_STARTS, so the run's own gate and `verify` have
# something to check.
"$T/mkrelmeth" make pad16+fstarts "$T/relmeth_grow"
om grow
rm -f "$T/relmeth_grow.grown"
rc=0; printf 'dylib append /usr/lib/libz.1.dylib\n' \
    | "$DRYDOCK_MACHO_REWRITE" "$T/relmeth_grow.out" "$T/relmeth_grow.grown" >/dev/null 2>"$T/om_grow.err" || rc=$?
[ "$om_rc" -eq 0 ] && [ "$rc" -eq 0 ] && grep -q "grew the header pad by 4096 bytes" "$T/om_grow.err" \
    && ok "objc-methods then a grow: dylib append grows the converted image's header" \
    || bad "objc-methods then grow" "rc $om_rc/$rc: $(cat "$T/om.err" "$T/om_grow.err")"
"$T/mkrelmeth" entries "$T/relmeth_grow" | sed 's/ rel / abs /' >"$T/om.want"
"$T/mkrelmeth" entries "$T/relmeth_grow.grown" >"$T/om.got" 2>/dev/null || true
[ -s "$T/om.want" ] && cmp -s "$T/om.want" "$T/om.got" \
    && [ "$(info_ml "$T/relmeth_grow.grown")" = "objc-methods: 0 relative, 4 absolute" ] \
    && ok "objc-methods then a grow: the lists moved with __DATA, and read as they did" \
    || bad "objc-methods then grow: oracle" "$(diff "$T/om.want" "$T/om.got"; info_ml "$T/relmeth_grow.grown")"
"$DRYDOCK_MACHO_REWRITE" verify "$T/relmeth_grow.grown" >/dev/null 2>"$T/om_gv.err" \
    && ok "objc-methods then a grow: verify passes" \
    || bad "objc-methods then grow: verify" "$(cat "$T/om_gv.err")"
```

- [ ] **Step 2: Run it**

Run: `unset DRYDOCK_MACHO_REWRITE; sh tests/cli_test.sh "$B" 2>&1 | grep -E '^FAIL|then a grow'`
Expected: three `PASS objc-methods then a grow: ...` lines and no `FAIL`.

- [ ] **Step 3: Prove it can fail** (a temporary edit of `src/grow.c`, restored before the commit; `src/grow.c` is not committed)

| # | file | replace | with | must fail |
|---|---|---|---|---|
| 1 | `src/grow.c` (`mg_patch_cb`) | `    } else if (seg->fileoff >= ctx->insert) {` | `    } else if (seg->fileoff >= ctx->insert && strncmp(seg->segname, "__DATA", 16) != 0) {` | `cli_test`: "objc-methods then a grow: dylib append grows ...", "... the lists moved with __DATA ...", "... verify passes" |

After restoring, `git status --short src/grow.c` must print nothing.

- [ ] **Step 4: Commit**

```bash
git add tests/cli_test.sh
git commit -m "test(objc): a header grow after the conversion moves the lists with __DATA

The statement never grows the header, but a later dylib append on an
executable with 16 bytes of pad does. The converted lists sit past
__DATA's last section, so they must move with __DATA's file bytes; the
oracle, info and verify all read the grown image as they read the
converted one.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 9: The real-world run on Mantle, ReactiveObjC and Squirrel

**Files:**
- Modify: `docs/superpowers/specs/2026-09-23-objc-method-lists-design.md` — `:6` ("Milestone 1 has landed (439e1cc..9082c8f)."), the "**M2: `objc-methods set absolute`.**" block (`:386`–`:411`), and the "**What real binaries on this host settled (2026-09-25).**" list (Task 1's bullet is its last).

**Interfaces:**
- Consumes: the finished statement; Task 1's probe (`dump` mode) and lowering commands.
- Produces: the spec's record that M2 works on real ld64 output, and M2's commit range.

Like Task 1, a documented local check (the same reasons). It uses the realistic pipeline, both statements in one script on each original framework.

- [ ] **Step 1: Build, and re-create Task 1's scratch if it is gone**

Build (rebuild check on `$B/drydock-macho-rewrite`). If `$W` from Task 1 no longer exists, run Task 1's Steps 1 and 2 again.

- [ ] **Step 2: Convert the three**

```bash
FW="$HOME/Downloads/OpenCode.app/Contents/Frameworks"
for n in Mantle ReactiveObjC Squirrel; do
    rc=0; printf 'fixups set classic\nobjc-methods set absolute\n' \
        | "$B/drydock-macho-rewrite" "$FW/$n.framework/Versions/A/$n" "$W/$n.abs" >/dev/null 2>"$W/$n.abs.log" || rc=$?
    echo "$n rc=$rc"; grep -E '^      (converted|added)' "$W/$n.abs.log"
done
```

Expected, exactly (from the plan's code on this host while the plan was written; a differing figure is a question to answer before recording anything):

```
Mantle rc=0
      converted 22 relative method lists (89 methods) onto the end of __DATA: 4 classes, 4 metaclasses, 14 categories
      added 267 rebases; __DATA grew 4,096 bytes; __LINKEDIT 40,985 -> 44,017 bytes, moved up 4,096
ReactiveObjC rc=0
      converted 137 relative method lists (650 methods) onto the end of __DATA: 56 classes, 42 metaclasses, 39 categories
      added 1,950 rebases; __DATA grew 20,480 bytes; __LINKEDIT 84,517 -> 99,693 bytes, moved up 20,480
Squirrel rc=0
      converted 20 relative method lists (124 methods) onto the end of __DATA: 8 classes, 8 metaclasses, 4 categories
      added 372 rebases; __DATA grew 4,096 bytes; __LINKEDIT 50,208 -> 54,992 bytes, moved up 4,096
```

- [ ] **Step 3: Re-walk, verify, and read every slot a second way**

```bash
for n in Mantle ReactiveObjC Squirrel; do
    "$B/drydock-macho-rewrite" info "$W/$n.abs" | grep '^objc-methods:'
    "$B/drydock-macho-rewrite" verify "$W/$n.abs"
    python3 "$W/objc_methods_probe.py" dump "$W/$n.classic" | sed 's/ rel / abs /' >"$W/$n.want"
    python3 "$W/objc_methods_probe.py" dump "$W/$n.abs" >"$W/$n.got"
    cmp "$W/$n.want" "$W/$n.got" && echo "$n: $(wc -l <"$W/$n.got" | tr -d ' ') slots read the same"
    python3 "$W/objc_methods_probe.py" dump "$W/$n.classic" | grep -c ' rel '
    otool -l "$W/$n.abs" | grep -A4 'segname __LINKEDIT' | grep vmsize
done
```

Expected: `objc-methods: 0 relative, 32 absolute` / `143` / `27`; `...: OK` from each `verify`; `Mantle: 32 slots read the same`, `ReactiveObjC: 143 ...`, `Squirrel: 27 ...`; the `rel` counts in the `.classic` dumps are above 0 (the positive control for the `sed`: without it the dumps differ); `__LINKEDIT` vmsize `0x000000000000b000` (unchanged), `0x0000000000019000` (was 0x15000) and `0x000000000000e000` (was 0xd000).

- [ ] **Step 4: Observe re-signing (recorded, not gated)**

```bash
for f in "$W/Mantle.classic" "$W/Mantle.abs"; do
    cp "$f" "$f.signed"; rc=0; codesign --force --sign - "$f.signed" 2>"$f.cs.err" || rc=$?
    echo "$(basename "$f") codesign rc=$rc: $(grep -o 'not in an order[^:]*' "$f.cs.err")"
done
```

Expected on this host (10.9's `codesign_allocate`): both fail, `Mantle.classic` with `not in an order that can be processed (dyld_info out of place)` and `Mantle.abs` with `... (code signature data out of place)`. `fixups set classic` already appends the rebase and bind streams after the code signature; this statement does not make re-signing possible or impossible. Record whatever it says.

- [ ] **Step 5: Record the results and the milestone in the spec**

Find the range: `first=$(git log --format=%h -1 --grep='every relative entry in the three frameworks resolves')` and `last=$(git rev-parse --short HEAD)`.

- `:6`: replace "Milestone 1 has landed (439e1cc..9082c8f)." with "Milestones 1 and 2 have landed (439e1cc..9082c8f, `$first`..`$last`)." using the two hashes.
- At the end of the "**M2: `objc-methods set absolute`.**" block (after its "Tests: ..." bullet), add a line `**Landed: $first..$last.**` with the two hashes.
- In "**What real binaries on this host settled (2026-09-25).**", after Task 1's bullet, add:

```markdown
- **The statement converts all three** (M2's last task). `fixups set
  classic` then `objc-methods set absolute`, in one script, on each
  original framework: exit 0, the statement's own verification passed,
  `info` then counts 0 relative and 32, 143 and 27 absolute lists,
  `drydock-macho-rewrite verify` says OK, and a second reader written
  apart from `src/` reads every slot's methods the same, in the same
  order, before and after. `__DATA` grew 4,096, 20,480 and 4,096 bytes.
  `__LINKEDIT`'s vmsize grew on ReactiveObjC (0x15000 to 0x19000) and
  Squirrel (0xd000 to 0xe000), because the rewritten rebase stream
  outgrew it. Nothing converted has run on 10.9 yet: that is M3.
- **Re-signing needs more than this statement.** 10.9's `codesign --force
  --sign -` refuses Mantle before the conversion ("dyld_info out of
  place": `fixups set classic` appends its streams after the code
  signature) and after it ("code signature data out of place").
```

If Step 4 printed something else, write what it printed instead of the last bullet.

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs/2026-09-23-objc-method-lists-design.md
git commit -m "docs(spec): M2 converts the three real frameworks, and has landed

fixups set classic then objc-methods set absolute converts Mantle,
ReactiveObjC and Squirrel; the statement's verification, info, verify
and a second reader all agree. Re-signing them is refused by 10.9's
codesign_allocate before and after, for a layout fixups set classic
leaves.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

## Self-review

**Spec coverage (M2 bullets and M2 Testing rows):**

| spec requirement | task |
|---|---|
| `src/rebase.[ch]` (`mrb_`), all nine opcodes, encoder for sorted slots | 2 |
| Decision 1: D grows, zero fill materialized, `__LINKEDIT` moves by S (vm) and Z+S (file), stream at its start, `ml_bump_all`, old stream zeroed, no load command, refusals (read-only, gap vm/file, `__LINKEDIT` not last, index ≥ 16) | 4 |
| Decision 2: refuse chained, refuse no `LC_DYLD_INFO`, one rebase per new non-zero pointer, bound selref refused, repointed slots must already be rebased, opcode set | 3, 5, 2 |
| Decision 3: selref checks, cstring checks, IMP section and function-start checks | 3 |
| Decision 4: order preserved, shared list converted once and every slot repointed, absolute lists untouched, protocols walked | 5 (oracle, `RMF_SHARED`, `RMF_ABSCAT`, `RMF_ALLSLOTS`) |
| Decision 7: re-walk, rebase set equality, layout and bytes, `mg_plausible` through the gate | 6 (the gate: see the reply) |
| The row, `me_apply` lowering, log lines | 7 |
| Fixture variants: dylib with 16 bytes of pad, zerofill tail, D read-only, gap, segment after, code signature, split info, bound selref, IMP not a function start; `mkrelmeth entries` as the oracle | 3, 4, 5 |
| Tests: `tests/rebase_test.c`, `tests/objc_meth_test.c`, `tests/cli_test.sh`, `test_disturbs_matches_the_spec_table` | 2–7 |
| Conversion then a grow still verifies | 8 |
| Owner's answers: M2's first task checks the three frameworks; they are the real-world subjects | 1, 9 |

**Placeholders:** none; `<authoring model>` in commit trailers is the Global Constraints' own wording, filled by whoever commits. The two spec hashes in Task 9 are computed by the commands given.

**Type consistency:** `mml_entry`, `mml_resolver`, `mml_entry_at`, `mml_off_rebased`, `mml_seg_of` (Task 3) are used with those signatures in Tasks 5–6; `mma_seg`, `mma_layout`, `mma_segments`, `mma_layout_check`, `mma_insert`, `mma_fail`, `mma_find_info` (Task 4) in Tasks 5–6; `mma_report`, `mma_out`, `mma_build`, `mma_out_free`, `mma_firsts` (Task 5) in Tasks 6–7; `mma_verify`, `mma_convert` (Task 6) in Task 7. Every code block in this plan was compiled and run, task by task, against HEAD `1a4a3da` while the plan was written: each task's state builds and its tests pass, the whole suite (24 tests) passes at the end, and every mutation in every table was seen to fail its named test.

**Review Focus:** the five lines above each name the test that pins them, in its owning task.
