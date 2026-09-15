/*
 * machorewrite — one mutating form, driven by a script, beside two read-only
 * queries.
 *
 * The grammar this build implements, verbatim:
 *
 *   machorewrite FILE OUT            statements on stdin; the ONLY way to change
 *                                   anything
 *   machorewrite info FILE
 *   machorewrite verify FILE
 *
 * THERE WAS AN `edit FILE OUT SCRIPT` VERB, and it went with the other eight:
 * spec: docs/superpowers/specs/2026-09-14-script-is-the-only-interface-design.md
 * says `edit` "stops being a verb name and becomes the tool itself", and while
 * the verb survived, the line above claiming the bare form is the only way to
 * change anything was false in its own file. Nothing is lost -- a script that
 * lives in a file is `machorewrite FILE OUT < script`, which is the shell's job
 * and not this binary's.
 *
 * `machorewrite --capabilities` is the machine-readable truth about what this
 * build accepts, so a wrapper and this binary never have to move in lockstep
 * (docs/PROPOSAL.md "Migration"). See print_capabilities() below for the exact
 * format.
 *
 * EIGHT MUTATING VERBS USED TO LIVE HERE -- declassify, segment, retag-swift,
 * minos, lc, dylib, rpath and grow. The first seven were each a thin
 * translation of their own flag grammar into an mr_ops, an mv_add_version_min
 * call or an md_declassify call. Every one of those had an exact statement
 * equivalent, and
 * spec: docs/superpowers/specs/2026-09-14-script-is-the-only-interface-design.md
 * says why keeping both spellings was expensive rather than merely untidy: the
 * verb path applied a SET of operations in one pass and the script path applies
 * a SEQUENCE, one per pass, and the two models disagree on operations naming
 * the same path. They are gone; the statements they mapped onto are what this
 * binary offers instead, and src/edit.c sequences them.
 *
 * `grow FILE OUT N` had no statement equivalent -- `allow-grow` is a directive
 * that PERMITS growth, not a request for a specific number of bytes -- and it
 * went anyway, because one mutation outside the only mutating interface would
 * defeat the design's single claim. It had no production caller (compat/ emits
 * it zero times). What it did cost was crash coverage: `mg_ensure_pad` grows
 * only when `need_end > first_sect_off`, so no script can force a grow of an
 * image whose first section lies PAST the end of the file, where `fsize -
 * insert` once wrapped and killed the tool with SIGSEGV. That regression, and
 * the no-section-data one beside it, now live where the bug always did -- in
 * the library, as tests/grow_test.c's test_grow_refuses_a_section_past_the_image
 * and test_grow_refuses_an_image_with_no_section_data, which call
 * mg_grow_header directly. Both were confirmed by mutation to catch exactly
 * what tests/leaf-tool-crashes.sh's `grow` cases caught.
 *
 * DELEGATION, not reimplementation, is still the rule for what remains.
 * `verify` and `info` call straight into mg_plausible and
 * mi_open/mi_each_lc; the script forms reach ms_parse
 * (src/script.h) and me_run (src/edit.h), which reach the in-memory cores of
 * every rewrite this repo implements -- so the ordinal-renumbering logic that
 * has twice shipped loader-crashing bugs (docs/PROPOSAL.md "verify") is
 * exercised exactly once, however it is reached.
 *
 * NOTHING HERE WRITES ITS INPUT: a mutating form names OUT as the positional
 * right after FILE. bad_out holds the refusals each one makes about OUT before
 * it reads anything.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

/* rewrite.h is here for MR_REFUSED/MR_FAIL alone -- the two typedefs below
 * pin them equal to this file's own exit codes, and me_run hands them back.
 * declassify.h, segname.h, swift_retag.h, version_min.h and relations.h left
 * with the seven mutating verbs that called into them; src/edit.c reaches the
 * same work now, through the statements. */
#include "image.h"
#include "ordinals.h"
#include "grow.h"
#include "lc_kinds.h"
#include "atomic_write.h"
#include "rewrite.h"
#include "mach_compat.h"
#include "script.h"
#include "edit.h"

/* Exit codes. 0 is success, as always. Everything else used to be a flat 1,
 * which meant a caller checking only "did this exit nonzero" (still fully
 * supported -- see below) could not tell "macho9 examined FILE and declined,
 * on purpose, because of what it found" (not a Mach-O, not plausible, a
 * KIND/version/segment name this build doesn't support, mg_grow_header's own
 * designed refusal) apart from "something actually went wrong running macho9 itself"
 * (couldn't open/read/write, malloc failed, a usage error). Refusal is
 * load-bearing throughout this codebase -- "-grow refuses rather than
 * guesses" is a global rule, not an incidental behavior -- so a
 * caller that wants to script around "this file just isn't one machorewrite will
 * touch" (vs. "retry, or investigate an environment problem") deserves a way
 * to tell the two apart without scraping stderr text, which --capabilities
 * already exists to make unnecessary for everything else this binary
 * reports.
 *
 * THE SCHEME IS 0 OK, 1 REFUSED, 2 ERROR -- the reverse of what first
 * shipped (0 ok, 1 failed, 2 refused), and deliberately so. `diff`, `grep`
 * and `cmp` all reserve their HIGHEST code for "the tool could not do its
 * job" and a lower one for "a normal, expected, non-success answer"; the
 * original numbering had that backwards. binutils sets no precedent either
 * way -- it returns a flat 0 or 1 and has no notion of a considered refusal
 * at all, so there was no existing convention this binary owed compatibility
 * to. Nothing outside this repo had ever run the compat wrappers this
 * couples to (see MR_REFUSED's own comment, rewrite.h), so this was the last
 * point at which the numbering could change for free -- after the script
 * form ships, it no longer is.
 *
 * EX_REFUSED is used ONLY at a point where machorewrite itself examined the input
 * and made that call; it is never used for a genuine operational failure (a
 * syscall that failed, a bad number of command-line arguments), save the one
 * allocation fold described below -- EX_FAIL is that catch-all, named the
 * same way as EX_REFUSED so a future change to either touches one place.
 * That includes me_run (src/edit.h), which cmd_script hands back: it draws the
 * SAME line itself, in the shared rewrite vocabulary (rewrite.h's
 * MR_REFUSED/MR_FAIL block states the rule), returning MR_REFUSED
 * (== EX_REFUSED, enforced below) for a considered refusal -- "not a 64-bit
 * Mach-O" in any of its forms, no room to grow, a rewrite's own cross-check
 * failing, and more -- and MR_FAIL (== EX_FAIL, enforced below) for
 * open/fstat/read/write/malloc itself failing. Forwarding either verbatim is
 * exact, not an approximation, with one deliberate exception src/rewrite.c's
 * own comment carries: an allocation failure INSIDE mg_grow_header
 * or mg_plausible (src/grow.c) is folded into MR_REFUSED, same as every
 * other reason either one refuses, not split out to MR_FAIL. The same fold
 * holds on the one verb left that calls either directly -- cmd_verify
 * (mg_plausible) returns EX_REFUSED for any failure of its own. So a failed
 * allocation that is checked at all is
 * EX_FAIL when it is mi_open's or mi_open_slack's, mfat_parse's,
 * wa_write_new's temp-name buffer, or one src/rewrite.c's
 * own drivers make (rewrite.h's MR_FAIL comment names them); EX_REFUSED
 * when it is inside mg_grow_header or mg_plausible, by design (see
 * rewrite.c's comment on the fold for why); and no exit code at all when it
 * is wa_write_new's copy of an extended attribute, which only warns. A
 * caller that only checks "== 0" or "!= 0" still needs no changes;
 * --capabilities documents all three codes (see print_capabilities below)
 * and tests/README.md repeats it for humans. */
#define EX_REFUSED 1
#define EX_FAIL    2

/* MR_REFUSED (rewrite.h) is forwarded verbatim by cmd_script as this binary's
 * own exit code, so it has to equal EX_REFUSED or --capabilities' documented
 * refused=1 would be a lie for every refusal a script run makes. A mismatch
 * here is a build failure, not a hope -- the same device commit 247d09d used
 * for mg_classify/ml_bump_lc's coupling. */
typedef char mr_refused_is_ex_refused[(MR_REFUSED == EX_REFUSED) ? 1 : -1];

/* Same coupling, same reason, for the other half of that vocabulary: every
 * operational failure a script run reports is MR_FAIL (rewrite.h), forwarded
 * verbatim by the same call site, so it has to equal EX_FAIL or
 * --capabilities' documented failed=2 would be a lie for exactly those
 * failures. */
typedef char mr_fail_is_ex_fail[(MR_FAIL == EX_FAIL) ? 1 : -1];

/* THE TWO THINGS OUT MUST NOT BE, once, for the one form that reads FILE and
 * writes OUT. Both are mistakes about what the tool does rather than about
 * this file's content, so both are refused UP FRONT -- before any read, and
 * before whatever else that form validates -- which is the difference between
 * "refused, nothing happened" and a refusal that arrives after the work.
 *
 * OUT MUST NOT BE FILE. wa_write_new refuses that again at the write (a path
 * can change in between), but that answer arrives in atomic_write.c's words,
 * after the rewrite; this one arrives in the verb's own, immediately.
 *
 * OUT MUST NOT BEGIN WITH '-'. Nothing here treats a positional as a flag, so
 * a caller reaching for the old flag-first habit -- from before these forms
 * took an output -- would otherwise CREATE a file named after the flag and
 * exit 0, having done something the caller plainly did not ask for. Silently
 * obeying that is the shape of failure this whole toolkit is written to
 * refuse. A caller who really does mean a file whose name starts with a dash
 * can spell it `./-name`, which the message says. FILE gets no such check: it
 * is only read, and mi_open's own failure names it.
 *
 * ONE function rather than the same lines in each form. There is one form
 * left to call it, so `verb` has one value -- "edit", the prefix src/edit.c's
 * whole report already carries, so a refusal that arrives before the script is
 * read reads like the ones that arrive after it. Both wordings are asserted
 * from the outside (tests/cli_test.sh greps for "never writes its input" and
 * for "which begins with '-'").
 *
 * Returns 1 when it printed a refusal (the caller returns EX_FAIL), else 0. */
static int bad_out(const char *verb, const char *path, const char *out) {
    if (out[0] == '-') {
        fprintf(stderr, "machorewrite %s: OUT is '%s', which begins with '-'; OUT is the "
                        "positional right after FILE, not a flag. Write './%s' if a "
                        "file of that name is really meant.\n", verb, out, out);
        return 1;
    }
    if (wa_is_input(path, out)) {
        fprintf(stderr, "machorewrite %s: %s is %s; machorewrite never writes its input\n", verb, out, path);
        return 1;
    }
    return 0;
}

/* ---- capabilities -------------------------------------------------------
 *
 * Stable, line-oriented, greppable -- shell is the wrapper's own language, so
 * this is not JSON. Contract:
 *
 *   line 1: "format <N>"       -- bump N only if a later build changes this
 *                                  TEXT's shape in a way old parsing breaks.
 *   line 2: "exitcodes ok=0 refused=<N> failed=<M>" -- what this binary's own
 *       exit codes mean: ok=0 always; refused=EX_REFUSED is used wherever
 *       machorewrite (or a shared rewrite driver it calls into) examined FILE and
 *       declined on purpose -- bad magic, implausible, an unsupported KIND/
 *       version, a grow mg_grow_header itself refused, new load commands
 *       that don't fit and can't be grown, an unmatched `fatal-warnings`
 *       statement, and more (rewrite.h's comment on mr_apply_image names the
 *       sites; its MR_REFUSED/MR_FAIL block has the one exception -- an allocation
 *       failure inside mg_grow_header or mg_plausible themselves stays
 *       refused=EX_REFUSED, not failed, same as every other reason either
 *       one refuses, on verify as well as a script run);
 *       failed=EX_FAIL is everything else (syscall/malloc failure, usage
 *       error, an unparseable script -- EX_REFUSED's own comment above has the
 *       exact allocation breakdown). The two numbers are 1 and 2, not the
 *       reverse -- see EX_REFUSED's own comment above for why this repo
 *       deliberately does not match what it originally shipped. A caller
 *       checking only nonzero needs no changes regardless of which way the
 *       numbers run. A script run returns me_run's own code verbatim, and
 *       me_run uses this SAME EX_REFUSED/EX_FAIL split (as MR_REFUSED/MR_FAIL,
 *       rewrite.h, enforced equal to these two by the typedefs above) -- so
 *       its exit codes ARE covered by this line.
 *   line 3: "output positional=2 never-writes-input" -- the shape every
 *       mutating form's positionals take: FILE, then OUT as the positional
 *       right after it, and OUT=FILE (by path, symlink or hard link) is
 *       always refused. `positional=2` is OUT's position counting from 1;
 *       this line exists so a wrapper checks for it instead of assuming the
 *       shape. It holds for the bare `machorewrite FILE OUT` form too: FILE is
 *       argv[1] there rather than argv[2], but OUT is still the positional
 *       right after it, and still never FILE.
 *   line 4: "mutate bare script=stdin" -- the ONE mutating form, and the only
 *       line that names it. `bare` is the grammar: no verb word, FILE and OUT
 *       as the first two positionals (the `output` line above gives their
 *       shape). `script=stdin` is where the statements come from. Without this
 *       line a machine-readable caller could read every `statement` row and
 *       still have no advertised way to send one, which is what
 *       --capabilities looked like while `verb edit` stood here instead.
 *   line 5+: "verb <name> [key=value ...]"
 *       one line per verb this build actually implements. A verb's absence
 *       means "not implemented" -- never advertise one that errors out. Only
 *       the two read-only queries are left. The NINE MUTATING VERBS THAT USED
 *       TO BE LISTED HERE are gone, with their `ops=`, `kinds=`, `versions=`,
 *       `flags=` and `reports=` attributes; `edit` was the last of them, and
 *       the `mutate` line above plus the `statement` lines below are what a
 *       wrapper reads instead.
 *       spec: docs/superpowers/specs/2026-09-14-script-is-the-only-interface-design.md
 *       decided that collapse. No attribute is left in use, so a reader that
 *       parsed them keeps working on a line that no longer carries any.
 *   line N+: "statement <kind> <op> <nargs>"
 *       one line per row of src/script.c's MS_TABLE -- the statement
 *       vocabulary ms_parse accepts, and so the whole mutating surface.
 *       Generated by looping over ms_table_row, the same table ms_parse
 *       matches statements against, so this can never advertise a statement
 *       the parser would refuse, or omit one it accepts. `nargs` is the operand
 *       count after `<kind> <op>`, e.g. "statement dylib replace 2" means `dylib
 *       replace OLD NEW`. One row's second field is a PROFILE rather than an
 *       op -- "statement target 10.9 0" is the `target 10.9` line, and a
 *       wrapper reads which profiles this build knows the same way it reads
 *       which ops each kind takes. Directives (allow-grow, fatal-warnings)
 *       are deliberately not listed here -- that is a later decision. */
static int print_capabilities(void) {
    printf("format 1\n");
    printf("exitcodes ok=0 refused=%d failed=%d\n", EX_REFUSED, EX_FAIL);
    /* Every mutating form reads FILE and writes OUT, the positional right
     * after it, and refuses an OUT that is FILE: machorewrite never writes its
     * input. A wrapper checks for this line rather than assume the shape. */
    printf("output positional=2 never-writes-input\n");
    /* The only mutating form, and NO flags= at all: it accepts none. `output`
     * and `dry-run` were advertised while OUT was a flag and a run could skip
     * its write, and `verbose` while a run could be asked to say nothing; all
     * three are gone, and advertising any of them would tell a wrapper it may
     * pass something this build refuses. */
    printf("mutate bare script=stdin\n");
    printf("verb verify\n");
    printf("verb info\n");
    {
        int i;
        const char *kind, *op, *flag;
        int nargs;
        unsigned modes, disturbs;
        for (i = 0; ms_table_row(i, &kind, &op, &nargs, &flag, &modes, &disturbs); i++)
            printf("statement %s %s %d\n", kind, op, nargs);
    }
    return 0;
}

static void usage(const char *prog) {
    fprintf(stderr,
        "usage: %s --capabilities\n"
        "       %s FILE OUT                                 apply the statements on stdin to FILE,\n"
        "                                                    writing OUT -- the only way to change\n"
        "                                                    anything. FILE is only read; OUT must\n"
        "                                                    not be FILE. A script in a file is\n"
        "                                                    '%s FILE OUT < script'.\n"
        "                                                    --capabilities lists every statement\n"
        "                                                    this build accepts\n"
        "       %s info FILE\n"
        "       %s verify FILE\n",
        prog, prog, prog, prog, prog);
}

/* ---- verify: a thin shell over mg_plausible -----------------------------
 *
 * Exactly what the brief asks Step 2 to prove: dispatch works, and the verb
 * adds no logic of its own beyond opening the file and reporting the result.
 */
static int cmd_verify(const char *path) {
    mi_image im;
    int mo_rc = mi_open(path, &im);
    if (mo_rc == MI_IO_ERROR) {
        fprintf(stderr, "machorewrite verify: %s: cannot open or read\n", path);
        return EX_FAIL;
    }
    if (mo_rc != 0) {
        fprintf(stderr, "machorewrite verify: %s: not a readable 64-bit Mach-O\n", path);
        return EX_REFUSED;
    }
    int rc = mg_plausible(im.buf, im.size);
    printf("%s: %s\n", path, rc == 0 ? "OK" : "FAILED (see above)");
    mi_close(&im);
    return rc == 0 ? 0 : EX_REFUSED;
}

/* ---- info: dump load commands, ordinals, pads ---------------------------
 *
 * No existing tool does this dump, so unlike verify this is new code --
 * but it is a pure reader: everything it walks comes from mi_open/mi_each_lc
 * (image.h) and mo_is_ordinal_lc (ordinals.h), never from re-deriving what
 * "ordinal-bearing" or "the header pad" mean. Output is deliberately stable
 * and greppable: tests/cli_test.sh asserts on it directly, which the task's
 * own host-portability rule endorses over parsing otool/nm. */
struct info_ctx {
    int idx;
    int ordinal;
};

/* dylib_command/rpath_command names are an lc_str offset relative to the
 * command's own start; the bounds check against cmdsize lives once, in
 * mo_lc_str_at (ordinals.h), which change_dylib.c's build_lcs and
 * mo_map_build also call -- so this dump can't drift out of agreement with
 * what the rewriters consider in-bounds, the way it briefly did. */
static const char *lc_str_at(const struct load_command *lc, uint32_t offset) {
    const char *s = mo_lc_str_at(lc, offset);
    return s ? s : "(malformed: offset past cmdsize)";
}

static int info_cb(const struct load_command *lc, void *ctx_) {
    struct info_ctx *ctx = ctx_;
    const char *name = lc_cmd_name(lc->cmd);
    if (name) printf("LC[%d] %s cmdsize=%u\n", ctx->idx, name, lc->cmdsize);
    else      printf("LC[%d] 0x%08x cmdsize=%u\n", ctx->idx, lc->cmd, lc->cmdsize);

    if (lc->cmd == LC_SEGMENT_64) {
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        printf("  segname=%.16s vmaddr=0x%llx vmsize=0x%llx fileoff=%llu filesize=%llu nsects=%u\n",
               seg->segname, (unsigned long long)seg->vmaddr, (unsigned long long)seg->vmsize,
               (unsigned long long)seg->fileoff, (unsigned long long)seg->filesize, seg->nsects);
    }
    if (mo_is_ordinal_lc(lc->cmd)) {
        ctx->ordinal++;
        const struct dylib_command *dc = (const struct dylib_command *)lc;
        printf("  ordinal=%d path=%s\n", ctx->ordinal, lc_str_at(lc, dc->dylib.name.offset));
    }
    if (lc->cmd == LC_RPATH) {
        const struct rpath_command *rc = (const struct rpath_command *)lc;
        printf("  rpath=%s\n", lc_str_at(lc, rc->path.offset));
    }
    if (lc->cmd == LC_VERSION_MIN_MACOSX) {
        const struct version_min_command *vc = (const struct version_min_command *)lc;
        printf("  version=%u.%u.%u sdk=%u.%u.%u\n",
               vc->version >> 16, (vc->version >> 8) & 0xff, vc->version & 0xff,
               vc->sdk >> 16, (vc->sdk >> 8) & 0xff, vc->sdk & 0xff);
    }
    ctx->idx++;
    return 0;   /* prints every command; never needs to stop early */
}

static int cmd_info(const char *path) {
    mi_image im;
    int mo_rc = mi_open(path, &im);
    if (mo_rc == MI_IO_ERROR) {
        fprintf(stderr, "machorewrite info: %s: cannot open or read\n", path);
        return EX_FAIL;
    }
    if (mo_rc != 0) {
        fprintf(stderr, "machorewrite info: %s: not a readable 64-bit Mach-O\n", path);
        return EX_REFUSED;
    }
    printf("%s: %zu bytes, %u load commands, filetype=%u\n",
           path, im.size, im.hdr->ncmds, im.hdr->filetype);
    struct info_ctx ctx = { 0, 0 };
    mi_each_lc(&im, info_cb, &ctx);

    uint32_t first_sect_off = mg_first_sect_off(im.buf, im.size);
    if (first_sect_off == MG_NO_SECTION_DATA) {
        /* Nothing in the image says where the pad ends, so no number would
         * be true; the rewriting verbs refuse such an image for the same
         * reason. */
        printf("header pad: unknown (no section data bounds it)\n");
    } else if (first_sect_off != UINT32_MAX && first_sect_off > im.size) {
        /* The offset is read from the file, and a pad measured to a point
         * past the end of the image would be a number no write could use;
         * the rewriting verbs refuse this image too. */
        printf("header pad: unknown (the first section lies past the end of the image)\n");
    } else if (first_sect_off != UINT32_MAX) {
        uint32_t lc_end = (uint32_t)sizeof(struct mach_header_64) + im.hdr->sizeofcmds;
        uint32_t pad = first_sect_off > lc_end ? first_sect_off - lc_end : 0;
        printf("header pad: %u bytes available (LC end=%u, first sect=%u)\n",
               pad, lc_end, first_sect_off);
    }
    mi_close(&im);
    return 0;
}

/* ---- the bare form: parse the script on stdin and run it through me_run ---
 *
 * `machorewrite FILE OUT`, and there is no other way to change a byte. It
 * takes NO FLAGS and no verb word: its two tokens are FILE and OUT, in that
 * order, and the statements come from stdin. A script that lives in a file is
 * `machorewrite FILE OUT < script` -- the redirection is the shell's job, and
 * an `edit FILE OUT SCRIPT` verb that did it in C was a second mutating
 * interface for no capability at all (it went; see this file's header).
 *
 * `--output` and `--dry-run` were flags while this form still wrote FILE and
 * could be asked to skip its write; `--verbose` was the last one standing,
 * and it went for a different reason: there is no quiet mode to ask out of.
 * The report is what this form is for, it goes to stderr, and `2>/dev/null`
 * silences it without help from us. So a `--`-prefixed token in either
 * position is refused BY NAME rather than opened as a file -- that is what
 * the check below is for, and the answer a caller passing any of those three
 * deserves.
 *
 * A SINGLE dash is not a flag: every historical tool open()ed whatever argv
 * handed it, so a file really named "-dashy" is a file name, and
 * tests/wrapper_test.sh pins `change_dylib -dashy ...` for that reason. A
 * FILE whose real name starts with "--" has no escape here; reference it
 * through a path that doesn't, e.g. "./--name" (the same remedy bad_out
 * already names for an OUT beginning with '-').
 *
 * OUT IS CHECKED BEFORE THE SCRIPT IS READ -- bad_out, before any input is
 * opened. ms_parse then runs, and can fail, before anything is written -- see
 * edit.h's own header comment, which states that as the property this module
 * exists for: nothing is written unless every statement succeeds and the final
 * verify passes. A parse error is reported here, prefixed the way src/edit.c's
 * own diagnostics are, and returns EX_FAIL: an unparseable script is an
 * operational failure (a typo in the script), not a considered refusal about
 * what FILE contains. me_run's own return (0 / MR_REFUSED / MR_FAIL) is
 * forwarded verbatim past that point -- the whole of this binary's mutating
 * exit-code vocabulary now that the nine verbs that forwarded mr_apply_file's
 * and mv_add_version_min's are gone.
 */
enum { ME_READ_OK = 0, ME_READ_IO = -1, ME_READ_MEM = -2 };

/* Reads all of `f` into a malloc'd buffer, growing as needed. There is no
 * size cap -- an edit script can be as long as its author wrote, same as
 * ms_parse's own contract. */
static int me_read_all(FILE *f, uint8_t **out, size_t *outlen) {
    size_t cap = 65536, len = 0;
    uint8_t *buf = malloc(cap);
    if (!buf) return ME_READ_MEM;
    for (;;) {
        if (len == cap) {
            size_t ncap = cap * 2;
            uint8_t *nbuf = realloc(buf, ncap);
            if (!nbuf) { free(buf); return ME_READ_MEM; }
            buf = nbuf;
            cap = ncap;
        }
        size_t n = fread(buf + len, 1, cap - len, f);
        len += n;
        if (n == 0) {
            if (ferror(f)) { free(buf); return ME_READ_IO; }
            break;   /* EOF */
        }
    }
    *out = buf;
    *outlen = len;
    return ME_READ_OK;
}

static int cmd_script(const char *file, const char *out) {
    const char *flag = NULL;
    if (strncmp(file, "--", 2) == 0) flag = file;
    else if (strncmp(out, "--", 2) == 0) flag = out;
    if (flag) {
        fprintf(stderr, "machorewrite edit: unknown flag '%s'\n", flag);
        return EX_FAIL;
    }

    /* Before the script is read, and before FILE is opened -- see bad_out. */
    if (bad_out("edit", file, out)) return EX_FAIL;

    uint8_t *buf = NULL;
    size_t len = 0;
    int rrc = me_read_all(stdin, &buf, &len);
    /* Captured before anything else can touch errno and clobber whatever
     * fread()/ferror() just set for a genuine read failure. */
    int read_errno = errno;
    if (rrc == ME_READ_MEM) {
        fprintf(stderr, "machorewrite edit: stdin: out of memory\n");
        return EX_FAIL;
    }
    if (rrc == ME_READ_IO) {
        fprintf(stderr, "machorewrite edit: stdin: %s\n", strerror(read_errno));
        return EX_FAIL;
    }

    ms_script s;
    char perr[256];
    if (ms_parse((const char *)buf, len, &s, perr, sizeof perr) != 0) {
        fprintf(stderr, "machorewrite edit: stdin: %s\n", perr);
        free(buf);
        return EX_FAIL;
    }
    free(buf);

    me_opts o;
    memset(&o, 0, sizeof o);
    o.log = stderr;

    int rc = me_run(file, out, &s, &o);
    ms_free(&s);
    return rc;
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "--capabilities") == 0)
        return print_capabilities();

    if (argc < 2) { usage(argv[0]); return EX_FAIL; }
    const char *verb = argv[1];

    if (strcmp(verb, "verify") == 0) {
        if (argc != 3) { fprintf(stderr, "usage: %s verify FILE\n", argv[0]); return EX_FAIL; }
        return cmd_verify(argv[2]);
    }
    if (strcmp(verb, "info") == 0) {
        if (argc != 3) { fprintf(stderr, "usage: %s info FILE\n", argv[0]); return EX_FAIL; }
        return cmd_info(argv[2]);
    }
    /* The bare form: `machorewrite FILE OUT`, statements on stdin, and the
     * only way to change anything.
     *
     * It sits below every verb arm, so a verb always wins and this can never
     * shadow one: `machorewrite info f` stays the info query even when a file
     * named `info` is sitting right there. A FILE whose name collides with a
     * verb is spelled `./info`, the same remedy bad_out already names for an
     * OUT beginning with '-'. Reaching here means argv[1] matched no verb, so
     * there is nothing left for it to be but a file name.
     *
     * THE TWO SURVIVING VERB WORDS ARE THE ONLY SHADOWS LEFT. `edit`, `dylib`,
     * `rpath`, `lc`, `minos`, `segment`, `retag-swift`, `grow` and `declassify`
     * shadowed a file of the same name while they were verbs; now `machorewrite
     * dylib out` reads a file named `dylib` and writes `out`, like any other
     * pair. */
    if (argc == 3) return cmd_script(argv[1], argv[2]);

    fprintf(stderr, "machorewrite: unknown verb '%s'\n", verb);
    usage(argv[0]);
    return EX_FAIL;
}
