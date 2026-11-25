/*
 * drydock-resources -- checks, converts and dumps the nibs an app carries, so OS X 10.9 can load them.
 *
 *   drydock-resources dump [--target 10.9] [--references DIR] NIB
 *     prints NIB (a NIBArchive file, or a nib directory's keyedobjects.nib) as Rez-style text a person can read,
 *     diff and edit. Superclass chains come from the reference set: --references DIR, else
 *     <realpath(this binary)>/../../share/drydock/objc/reference when it exists, and from the Mach-O files of the
 *     bundle NIB lies in; with neither, the chains are marked unresolved. A keyed-archive nib dumps with the chains
 *     its archive holds, each marked newer from the reference set.
 *
 *   drydock-resources build [--target 10.9] [--resource-references DIR] [--no-adapt[=RULE]]... TEXT -o NIB
 *     writes the dump TEXT as a keyed-archive nib, replacing NIB whole or leaving it as it was. The adaptation rules
 *     the target needs rewrite it first, each rewrite printed as "TEXT: adapted: RULE (@N KEY)"; --no-adapt turns
 *     them all off, --no-adapt=RULE one. A rule that cannot judge an object (an unreadable frame) is printed as a
 *     finding, and nothing is written. The rules' data is adapt.tsv in --resource-references DIR, else
 *     <realpath(this binary)>/../../share/drydock/resources/reference.
 *
 *   drydock-resources check [--target 10.9] [--references DIR] [--resource-references DIR] [--no-adapt[=RULE]]...
 *                           [--exceptions FILE] [--report NEW_FILE] BUNDLE|NIB|TEXT
 *     prints every finding for every nib of a bundle (any directory: its nib files, nib directories and the nibs of
 *     each .storyboardc), or of one nib, nib directory, .storyboardc or dump TEXT, sorted, one per line as
 *     "NIB: SEVERITY: KIND ITEM (DETAIL)", NIB relative to the bundle. A problem an adaptation rule fixes is
 *     "will-adapt", or with --no-adapt an ordinary "finding". Both reference sets are needed, found as for dump and
 *     build. A nib directory without keyedobjects.nib is checked as its highest-numbered keyedobjects-NNN.nib, and
 *     one with neither is a no-nib finding.
 *
 *   drydock-resources convert [check's options] [--no-strict] BUNDLE|NIB
 *     checks as check does, then rewrites each NIBArchive nib in place as a keyed archive, adapted; a keyed nib is
 *     left byte-identical unless a rule adapts it, and a nib directory without keyedobjects.nib gets one. Strict, the
 *     default: any finding no exception accepts writes nothing at all. --no-strict writes every nib but those a
 *     blocks-write finding holds back, and still exits 1 on a finding. A NIBArchive nib held back, even by an
 *     accepted blocks-write finding, stays NIBArchive, and its nibarchive-format finding becomes an ordinary one.
 *     Every nib is staged beside itself before any is renamed into place, so a nib that cannot be staged leaves every
 *     nib as it was.
 *
 *   --exceptions FILE accepts gaps, one per line as NIB_GLOB<TAB>KIND<TAB>ITEM<TAB>REASON: a finding of KIND and ITEM
 *   in a nib whose bundle-relative path NIB_GLOB matches (fnmatch) is printed "accepted as KIND:ITEM" and no longer
 *   counts; an accepted storyboard covers every finding in its nibs. A line that accepts nothing is said on stderr.
 *   --report NEW_FILE writes the JSON report there, never replacing a file.
 *
 * Every verb takes --target, and 10.9 is the only target. Exit 0 (check and convert: no finding but will-adapt, or
 * accepted ones); 1 findings (a dump build cannot encode or adapt); 2 usage, an unknown rule, or a report file that
 * exists; 4 a nib, dump, exceptions file or reference set that cannot be read or written, or out of memory.
 */
/* platform: realpath and readlink under -std=c99: _XOPEN_SOURCE on glibc, _DARWIN_C_SOURCE keeps the rest visible on a Mac */
#define _XOPEN_SOURCE 700
#define _DARWIN_C_SOURCE
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include "adapt.h"
#include "atomic_write.h"
#include "chains.h"
#include "findings.h"
#include "keyed.h"
#include "nibarchive.h"
#include "json-report.h"
#include "rez.h"
#include "walk.h"

#ifdef __APPLE__
#include <mach-o/dyld.h>
#else
#include <unistd.h>
#endif

#define NIB_MAX ((size_t)1 << 28)

static int usage(void) {
    fprintf(stderr,
            "usage: drydock-resources check|convert|dump|build [--target 10.9] ...\n"
            "       drydock-resources dump [--target 10.9] [--references DIR] NIB\n"
            "       drydock-resources build [--target 10.9] [--resource-references DIR] [--no-adapt[=RULE]]... TEXT -o NIB\n"
            "       drydock-resources check [--target 10.9] [--references DIR] [--resource-references DIR]\n"
            "                               [--no-adapt[=RULE]]... [--exceptions FILE] [--report NEW_FILE] BUNDLE|NIB|TEXT\n"
            "       drydock-resources convert [check's options] [--no-strict] BUNDLE|NIB\n");
    return 2;
}

/* share/drydock/SUB/reference beside the real binary, or NULL when it is not a directory. */
static const char *default_references(const char *sub, char *out, size_t outlen) {
    char self[PATH_MAX], real[PATH_MAX];
    struct stat st;
    char *slash;
    int up, found;
#ifdef __APPLE__
    uint32_t len = sizeof self;
    found = _NSGetExecutablePath(self, &len) == 0;
#else
    /* platform: Linux names the running binary in /proc. */
    ssize_t len = readlink("/proc/self/exe", self, sizeof self - 1);
    if ((found = len > 0)) self[len] = 0;
#endif
    if (found && realpath(self, real)) {
        for (up = 0; up < 2; up++) {
            if (!(slash = strrchr(real, '/'))) break;
            *slash = '\0';
        }
        if (up == 2 && (size_t)snprintf(out, outlen, "%s/share/drydock/%s/reference", real, sub) < outlen &&
            stat(out, &st) == 0 && S_ISDIR(st.st_mode))
            return out;
    }
    return NULL;
}

/* The whole file in a buffer of exactly its size; NULL with a reason printed. */
static uint8_t *read_nib(const char *path, size_t *outn) {
    FILE *f;
    uint8_t *buf = NULL, *more;
    size_t n = 0, cap = 1 << 16;
    if (!(f = fopen(path, "rb"))) {
        fprintf(stderr, "drydock-resources: %s: cannot read: %s\n", path, strerror(errno));
        return NULL;
    }
    for (;;) {
        if (!(more = realloc(buf, cap))) { fprintf(stderr, "drydock-resources: out of memory\n"); goto fail; }
        buf = more;
        n += fread(buf + n, 1, cap - n, f);
        if (n < cap) break;
        if (cap >= NIB_MAX) {
            fprintf(stderr, "drydock-resources: %s: larger than %lu bytes\n", path, (unsigned long)NIB_MAX);
            goto fail;
        }
        cap *= 2;
    }
    if (ferror(f)) { fprintf(stderr, "drydock-resources: %s: cannot read: %s\n", path, strerror(errno)); goto fail; }
    fclose(f);
    *outn = n;
    return buf;
fail:
    free(buf);
    fclose(f);
    return NULL;
}

/* The superclass chains of the reference set at refdir (NULL: none) and of each binary: NULL with the reason printed.
 * A binary the reader refuses is said on stderr and adds nothing. */
static RChainSrc *chain_src(const char *refdir, char **bins, size_t nb) {
    char why[512];
    RChainSrc *s;
    size_t i;
    if (!(s = rc_open(refdir, "10.9"))) {
        if (refdir) fprintf(stderr, "drydock-resources: cannot read the references in %s\n", refdir);
        else fprintf(stderr, "drydock-resources: out of memory\n");
        return NULL;
    }
    for (i = 0; i < nb; i++)
        switch (rc_add_binary(s, bins[i], why, sizeof why)) {
        case 0: break;
        case 1: fprintf(stderr, "drydock-resources: %s: %s; its classes are not used\n", bins[i], why); break;
        default:
            fprintf(stderr, "drydock-resources: out of memory\n");
            rc_close(s);
            return NULL;
        }
    return s;
}

/* buf, the n bytes of the file at path, as a graph in *g: 0, or 4 with the reason printed. A NIBArchive's chains are
 * resolved from s; a keyed archive keeps its own, each marked newer from s. With text set, a dump is read too. */
static int parse(const char *path, const uint8_t *buf, size_t n, RChainSrc *s, int text, RGraph *g) {
    char why[512];
    int rc;
    if (n >= 8 && !memcmp(buf, "bplist00", 8)) rc = ka_read(buf, n, g, why, sizeof why);
    else if (n >= 10 && !memcmp(buf, "NIBArchive", 10)) rc = na_read(buf, n, g, why, sizeof why);
    else if (text && n >= 22 && !memcmp(buf, "drydock-resources dump", 22)) rc = rez_parse((const char *)buf, n, g, why, sizeof why);
    else {
        fprintf(stderr, "drydock-resources: %s: unsupported format\n", path);
        return 4;
    }
    if (rc) { fprintf(stderr, "drydock-resources: %s: %s\n", path, why); return rc; }
    if (g->format == RF_NIBARCHIVE && g->n_chains) return 0;
    if (g->format == RF_KEYED ? rc_mark_newer(s, g) : rc_resolve(s, g)) {
        fprintf(stderr, "drydock-resources: out of memory\n");
        rg_free(g);
        return 4;
    }
    return 0;
}

/* Dumps the nib at arg (a file, or a nib directory's keyedobjects.nib), its chains resolved from the reference set
 * at refdir and the binaries of its enclosing bundle. */
static int dump(const char *arg, const char *refdir) {
    char refs[PATH_MAX], path[PATH_MAX], why[512], *text, **bins;
    size_t textn, n, nb;
    uint8_t *buf;
    RGraph g;
    RNib *nibs;
    RChainSrc *s;
    struct stat st;
    int rc;
    if (!refdir) refdir = default_references("objc", refs, sizeof refs);
    if (stat(arg, &st) == 0 && S_ISDIR(st.st_mode)) {
        if ((size_t)snprintf(path, sizeof path, "%s/keyedobjects.nib", arg) >= sizeof path) {
            fprintf(stderr, "drydock-resources: %s: path too long\n", arg);
            return 4;
        }
        arg = path;
    }
    if (rw_walk(arg, &nibs, &n, &bins, &nb, why, sizeof why)) {
        fprintf(stderr, "drydock-resources: %s\n", why);
        return 4;
    }
    s = chain_src(refdir, bins, nb);
    rw_free(nibs, n, bins, nb);
    if (!s) return 4;
    if (!(buf = read_nib(arg, &n))) { rc_close(s); return 4; }
    rc = parse(arg, buf, n, s, 0, &g);
    free(buf);
    rc_close(s);
    if (rc) return rc;
    if (rez_write(&g, &text, &textn, why, sizeof why)) {
        fprintf(stderr, "drydock-resources: %s: %s\n", arg, why);
        rg_free(&g);
        return 4;
    }
    rg_free(&g);
    rc = fwrite(text, 1, textn, stdout) != textn || fflush(stdout) ? 4 : 0;
    free(text);
    if (rc) fprintf(stderr, "drydock-resources: cannot write the dump\n");
    return rc;
}

/* Which adaptation rules the command line turned off. */
typedef struct { int all; const char **rules; size_t n; } NoAdapt;

/* The rules adapt.tsv in resrefs applies to 10.9, less those turned off; NULL with the reason printed. */
static RAdaptSet *adapt_set(const char *resrefs, const NoAdapt *no) {
    RAdaptSet *a;
    size_t i;
    if (!resrefs) {
        fprintf(stderr, "drydock-resources: no resource references beside drydock-resources: pass --resource-references DIR\n");
        return NULL;
    }
    if (!(a = ra_default(resrefs, "10.9"))) {
        fprintf(stderr, "drydock-resources: cannot read the resource references in %s\n", resrefs);
        return NULL;
    }
    if (no->all) ra_disable(a, NULL);
    for (i = 0; i < no->n; i++) ra_disable(a, no->rules[i]);
    return a;
}

static void print_findings(const RFindings *f, const char *nib) {
    size_t i;
    for (i = 0; i < f->n; i++) {
        const RFinding *x = &f->v[i];
        if (x->sev == RF_ADAPTED) printf("%s: adapted: %s (%s)\n", x->nib ? x->nib : nib, x->item, x->detail);
        else printf("%s: %s: %s %s (%s)\n", x->nib ? x->nib : nib, rf_severity_name(x->sev), x->kind, x->item, x->detail);
    }
}

/* The dump at path as a keyed archive at out: 0; 1 unencodable, or a rule could not judge an object; 2 out is path;
 * 4 unreadable, malformed or unwritable. */
static int build(const char *path, const char *out, const char *resrefs, const NoAdapt *no) {
    char why[512];
    uint8_t *text, *nib;
    size_t n, i;
    RGraph g;
    BpNode *archive;
    RAdaptSet *a = NULL;
    RFindings log = { NULL, 0 };
    int rc;
    if (!no->all && !(a = adapt_set(resrefs, no))) return 4;
    if (!(text = read_nib(path, &n))) { ra_free(a); return 4; }
    rc = rez_parse((const char *)text, n, &g, why, sizeof why);
    free(text);
    if (rc) { fprintf(stderr, "drydock-resources: %s: %s\n", path, why); ra_free(a); return 4; }
    if (a) {
        rc = ra_apply(a, &g, &log);
        ra_free(a);
        print_findings(&log, path);
        for (i = 0; i < log.n; i++)
            if (log.v[i].sev != RF_ADAPTED) rc = rc ? rc : 1;
        rf_free(&log);
        if (fflush(stdout)) rc = 4;
        if (rc) {
            if (rc == 4) fprintf(stderr, "drydock-resources: out of memory\n");
            else fprintf(stderr, "drydock-resources: %s: an adaptation rule cannot judge it; nothing written\n", path);
            rg_free(&g);
            return rc;
        }
    }
    rc = ka_from_graph(&g, &archive, why, sizeof why);
    rg_free(&g);
    if (rc) { fprintf(stderr, "drydock-resources: %s: %s\n", path, why); return rc; }
    rc = bp_write(archive, &nib, &n);
    bp_free(archive);
    if (rc) { fprintf(stderr, "drydock-resources: out of memory\n"); return 4; }
    rc = wa_write_new(path, out, nib, n);
    free(nib);
    return rc == WA_IS_INPUT ? 2 : rc ? 4 : 0;
}

/* What check and convert are told. */
typedef struct {
    int convert, strict;
    const char *refdir, *resrefs, *report, *exceptions;
    const NoAdapt *no;
} Opts;

/* One nib of the walk: what was read, what was built, and whether it went in place. */
typedef struct {
    const char *format;
    char sha_in[65], sha_out[65];
    uint8_t *out;
    size_t outn;
    char *target, *target_rel;
    RFindings log;
    struct wa_staged st;
    int staged, written, read;
} Item;

/* The .storyboardc a storyboard nib's relpath lies in, copied into buf. */
static const char *storyboard_of(const char *relpath, char *buf, size_t bufsz) {
    const char *p = relpath, *hit = NULL;
    while ((p = strstr(p, ".storyboardc/"))) hit = p++;
    if (!hit || (size_t)(hit - relpath) + 12 >= bufsz) return NULL;
    memcpy(buf, relpath, (size_t)(hit - relpath) + 12);
    buf[hit - relpath + 12] = 0;
    return buf;
}

/* path with its last component replaced by "keyedobjects.nib", or NULL out of memory. */
static char *floor_nib(const char *path) {
    const char *slash = strrchr(path, '/');
    size_t len = slash ? (size_t)(slash - path) + 1 : 0;
    char *p = malloc(len + sizeof "keyedobjects.nib");
    if (!p) return NULL;
    memcpy(p, path, len);
    strcpy(p + len, "keyedobjects.nib");
    return p;
}

/* Builds the keyed archive convert would write for g, read from x as buf: into it->out, or nothing when a keyed nib
 * needs no adaptation, or when x has a blocks-write finding. 0, or 4 out of memory. */
static int build_one(const RNib *x, const uint8_t *buf, size_t n, RGraph *g, const RAdaptSet *a, RFindings *f, Item *it) {
    char why[512];
    BpNode *archive;
    size_t i, adapted = 0;
    int rc;
    for (i = 0; i < f->n; i++)
        if (f->v[i].sev == RF_BLOCK_WRITE && f->v[i].nib && !strcmp(f->v[i].nib, x->relpath)) return 0;
    if (ra_apply(a, g, &it->log)) return 4;
    for (i = 0; i < it->log.n; i++) adapted += it->log.v[i].sev == RF_ADAPTED;
    if (g->format == RF_KEYED && !adapted && !x->is_variant) return 0;
    if (g->format == RF_KEYED && !adapted) {
        if (!(it->out = malloc(n ? n : 1))) return 4;
        memcpy(it->out, buf, n);
        it->outn = n;
    } else {
        if ((rc = ka_from_graph(g, &archive, why, sizeof why)) == 4) return 4;
        if (rc)
            return rf_add(f, "unencodable", x->relpath, "keyed-archive", RF_BLOCK_WRITE, "%s",
                          strncmp(why, "unencodable: ", 13) ? why : why + 13) ? 4 : 0;
        rc = bp_write(archive, &it->out, &it->outn);
        bp_free(archive);
        if (rc) return 4;
    }
    rr_sha256(it->out, it->outn, it->sha_out);
    if (x->is_variant && (!(it->target = floor_nib(x->abspath)) || !(it->target_rel = floor_nib(x->relpath)))) return 4;
    return 0;
}

static int items_written(const Item *items, size_t n) {
    size_t i;
    for (i = 0; i < n; i++)
        if (items[i].written) return 1;
    return 0;
}

/* Stages every built output in walk order, then renames each into place; a staging failure removes every temp and
 * writes nothing. A nib with a blocks-write finding has no output: what can't be encoded is never written. 0, or 4
 * with the reason printed. */
static int put_in_place(const RNib *nibs, Item *items, size_t n) {
    size_t i;
    int rc = 0;
    for (i = 0; i < n && !rc; i++) {
        if (!items[i].out) continue;
        if (wa_stage(items[i].target ? items[i].target : nibs[i].abspath, items[i].out, items[i].outn, &items[i].st)) rc = 4;
        else items[i].staged = 1;
    }
    for (i = 0; i < n; i++) {
        if (!items[i].staged) continue;
        items[i].staged = 0;
        if (rc) wa_abort(&items[i].st);
        else if (wa_commit(&items[i].st)) rc = 4;
        else items[i].written = 1;
    }
    if (rc) fprintf(stderr, "drydock-resources: a nib could not be replaced; %s\n",
                    items_written(items, n) ? "the report names those that were" : "nothing written");
    return rc;
}

/* Turns the nibarchive-format finding of each NIBArchive nib convert built nothing for, a blocks-write finding
 * holding it back, into an ordinary finding saying it stays NIBArchive. 0, or 4 out of memory. */
static int held_back(const RNib *nibs, const Item *items, size_t n, RFindings *f) {
    static const char stays[] = "stays NIBArchive: a blocks-write finding holds it back";
    size_t i, j;
    char *d;
    for (i = 0; i < f->n; i++) {
        RFinding *x = &f->v[i];
        if (strcmp(x->kind, "nibarchive-format") || x->sev != RF_WILL_ADAPT || !x->nib) continue;
        for (j = 0; j < n && strcmp(nibs[j].relpath, x->nib); j++) ;
        if (j == n || items[j].out) continue;
        if (!(d = malloc(sizeof stays))) return 4;
        memcpy(d, stays, sizeof stays);
        free(x->detail);
        x->detail = d;
        x->sev = RF_FINDING;
    }
    return 0;
}

/* check and convert of the bundle, nib directory or nib at arg. */
static int bundle(const char *arg, const Opts *o) {
    char refs[PATH_MAX], why[512], sbbuf[PATH_MAX], last_sb[PATH_MAX] = "", **bins = NULL;
    const char *refdir = o->refdir, *sb, *rules[8];
    RAdaptSet *a = NULL;
    RfRefs *r = NULL;
    RChainSrc *s = NULL;
    RFindings f = { NULL, 0 };
    RfExceptions ex = { NULL, 0 };
    RNib *nibs = NULL;
    Item *items = NULL;
    RrNib *rn = NULL;
    size_t n = 0, nb = 0, i, j, n_rules = 0;
    int worst = 0, blocking = 0, rc;
    if (o->report && (rc = rr_check_dest(o->report))) return rc;
    if (o->exceptions && rf_exceptions_read(o->exceptions, &ex, why, sizeof why)) {
        fprintf(stderr, "drydock-resources: %s\n", why);
        return 4;
    }
    if (!refdir && !(refdir = default_references("objc", refs, sizeof refs))) {
        fprintf(stderr, "drydock-resources: no references beside drydock-resources: pass --references DIR\n");
        worst = 4;
        goto done;
    }
    if (!(a = adapt_set(o->resrefs, o->no))) { worst = 4; goto done; }
    if (!(r = rf_open(o->resrefs, refdir))) {
        fprintf(stderr, "drydock-resources: cannot read the references in %s and %s\n", o->resrefs, refdir);
        worst = 4;
        goto done;
    }
    if (rw_walk(arg, &nibs, &n, &bins, &nb, why, sizeof why)) {
        fprintf(stderr, "drydock-resources: %s\n", why);
        worst = 4;
        goto done;
    }
    if (!(s = chain_src(refdir, bins, nb)) || !(items = calloc(n ? n : 1, sizeof *items))
        || !(rn = calloc(n ? n : 1, sizeof *rn))) {
        if (s) fprintf(stderr, "drydock-resources: out of memory\n");
        worst = 4;
        goto done;
    }
    for (i = 0; i < n; i++) {
        const RNib *x = &nibs[i];
        const char *base = strrchr(x->abspath, '/');
        uint8_t *buf;
        size_t len;
        RGraph g;
        if (x->in_storyboard && (sb = storyboard_of(x->relpath, sbbuf, sizeof sbbuf)) && strcmp(sb, last_sb)) {
            if (rf_storyboard(r, sb, "10.9", &f)) { fprintf(stderr, "drydock-resources: out of memory\n"); worst = 4; break; }
            strcpy(last_sb, sb);
        }
        if (x->is_variant && rf_add(&f, "no-floor-nib", x->relpath, "keyedobjects.nib", RF_WILL_ADAPT, "%s stands in for it",
                                    base ? base + 1 : x->abspath)) {
            fprintf(stderr, "drydock-resources: out of memory\n");
            worst = 4;
            break;
        }
        if (x->no_nib) {
            if (rf_add(&f, "no-nib", x->relpath, "keyedobjects.nib", RF_FINDING, "no keyedobjects.nib or keyedobjects-NNN.nib")) {
                fprintf(stderr, "drydock-resources: out of memory\n");
                worst = 4;
                break;
            }
            continue;
        }
        if (!(buf = read_nib(x->abspath, &len))) { worst = 4; continue; }
        items[i].read = 1;
        rr_sha256(buf, len, items[i].sha_in);
        if ((rc = parse(x->relpath, buf, len, s, !o->convert, &g))) { free(buf); worst = 4; continue; }
        items[i].format = g.format == RF_KEYED ? "keyed" : len >= 10 && !memcmp(buf, "NIBArchive", 10) ? "nibarchive" : "dump";
        rc = rf_check(r, &g, x->relpath, "10.9", a, &f) || (o->convert && build_one(x, buf, len, &g, a, &f, &items[i]));
        rg_free(&g);
        free(buf);
        if (rc) { fprintf(stderr, "drydock-resources: out of memory\n"); worst = 4; break; }
    }
    if (o->convert && !worst && held_back(nibs, items, n, &f)) { fprintf(stderr, "drydock-resources: out of memory\n"); worst = 4; }
    rf_sort(&f);
    if (rf_except(&ex, &f)) { fprintf(stderr, "drydock-resources: out of memory\n"); worst = 4; }
    for (i = 0; i < f.n; i++) blocking |= rf_blocks(&f.v[i]);
    if (o->convert && !worst && !(o->strict && blocking)) worst = put_in_place(nibs, items, n);
    for (i = 0; i < n; i++)
        for (j = 0; items[i].written && j < items[i].log.n; j++) {
            const RFinding *x = &items[i].log.v[j];
            if (x->sev == RF_ADAPTED && rf_add(&f, x->kind, items[i].target_rel ? items[i].target_rel : nibs[i].relpath,
                                               x->item, RF_ADAPTED, "%s", x->detail))
                worst = 4;
        }
    rf_sort(&f);
    for (i = 0; i < f.n; i++) {
        const RFinding *x = &f.v[i];
        if (x->sev == RF_ADAPTED) printf("%s: adapted: %s (%s)", x->nib, x->item, x->detail);
        else printf("%s: %s: %s %s (%s)", x->nib, rf_severity_name(x->sev), x->kind, x->item, x->detail);
        if (x->deviation) printf(" accepted as %s", x->deviation);
        printf("\n");
    }
    if (fflush(stdout)) worst = 4;
    for (i = 0; i < ex.n; i++)
        if (!ex.v[i].n_applied) fprintf(stderr, "drydock-resources: unused exception: %s\n", ex.v[i].line);
    rc = worst ? worst : blocking ? 1 : 0;
    if (o->report) {
        for (i = 0; ra_rule(i) && n_rules < sizeof rules / sizeof *rules; i++)
            if (ra_is_on(a, ra_rule(i))) rules[n_rules++] = ra_rule(i);
        for (i = 0; i < n; i++) {
            rn[i].path = items[i].written && items[i].target_rel ? items[i].target_rel : nibs[i].relpath;
            rn[i].format = items[i].format;
            rn[i].sha256_in = items[i].read ? items[i].sha_in : NULL;
            rn[i].sha256_out = items[i].out ? items[i].sha_out : NULL;
            rn[i].written = items[i].written;
        }
        if (rr_write(o->report, "drydock-resources " DRYDOCK_RESOURCES_VERSION, o->convert ? "convert" : "check", "10.9",
                     o->strict, rules, n_rules, rn, n, &f, &ex))
            rc = 4;
    }
    worst = rc;
done:
    for (i = 0; items && i < n; i++) {
        if (items[i].staged) wa_abort(&items[i].st);
        free(items[i].out);
        free(items[i].target);
        free(items[i].target_rel);
        rf_free(&items[i].log);
    }
    free(items);
    free(rn);
    rw_free(nibs, n, bins, nb);
    rc_close(s);
    rf_free(&f);
    rf_exceptions_free(&ex);
    rf_close(r);
    ra_free(a);
    return worst;
}

int main(int argc, char **argv) {
    const char *verb, *refdir = NULL, *resrefs = NULL, *out = NULL, *report = NULL, *exceptions = NULL, **args;
    char resbuf[PATH_MAX];
    NoAdapt no = { 0, NULL, 0 };
    Opts o;
    int i, n = 0, rc, bulk, strict = 1;
    if (argc < 2) return usage();
    verb = argv[1];
    if (strcmp(verb, "check") && strcmp(verb, "convert") && strcmp(verb, "dump") && strcmp(verb, "build")) return usage();
    if (!(args = calloc((size_t)argc, sizeof *args)) || !(no.rules = calloc((size_t)argc, sizeof *no.rules))) {
        free(args);
        fprintf(stderr, "drydock-resources: out of memory\n");
        return 4;
    }
    bulk = !strcmp(verb, "check") || !strcmp(verb, "convert");
    for (i = 2; i < argc; i++) {
        if (!strcmp(verb, "convert") && !strcmp(argv[i], "--no-strict")) { strict = 0; continue; }
        if (bulk && (!strcmp(argv[i], "--report") || !strcmp(argv[i], "--exceptions"))) {
            const char **to = argv[i][2] == 'r' ? &report : &exceptions;
            if (*to || i + 1 >= argc || !*argv[i + 1]) { rc = usage(); goto done; }
            *to = argv[++i];
            continue;
        }
        if (strcmp(verb, "dump") && !strcmp(argv[i], "--no-adapt")) { no.all = 1; continue; }
        if (strcmp(verb, "dump") && !strncmp(argv[i], "--no-adapt=", 11)) {
            if (!ra_known(argv[i] + 11)) {
                fprintf(stderr, "drydock-resources: unknown adaptation rule: %s\n", argv[i] + 11);
                rc = 2;
                goto done;
            }
            no.rules[no.n++] = argv[i] + 11;
            continue;
        }
        if (!strcmp(verb, "build") && !strcmp(argv[i], "-o")) {
            if (out || i + 1 >= argc || !*argv[i + 1]) { rc = usage(); goto done; }
            out = argv[++i];
            continue;
        }
        if (!strcmp(argv[i], "--target") || !strcmp(argv[i], "--references")
            || (strcmp(verb, "dump") && !strcmp(argv[i], "--resource-references"))) {
            if (i + 1 >= argc || !*argv[i + 1]) { rc = usage(); goto done; }
            if (!strcmp(argv[i], "--references")) refdir = argv[++i];
            else if (!strcmp(argv[i], "--resource-references")) resrefs = argv[++i];
            else if (strcmp(argv[++i], "10.9")) {
                fprintf(stderr, "drydock-resources: unsupported target: %s\n", argv[i]);
                rc = 2;
                goto done;
            }
        } else if (argv[i][0] == '-' && argv[i][1]) {
            rc = usage();
            goto done;
        } else
            args[n++] = argv[i];
    }
    if (!resrefs) resrefs = default_references("resources", resbuf, sizeof resbuf);
    if (!strcmp(verb, "build"))
        rc = n != 1 || !out ? usage() : build(args[0], out, resrefs, &no);
    else if (bulk) {
        o.convert = !strcmp(verb, "convert");
        o.strict = strict;
        o.refdir = refdir;
        o.resrefs = resrefs;
        o.report = report;
        o.exceptions = exceptions;
        o.no = &no;
        rc = n != 1 ? usage() : bundle(args[0], &o);
    } else if (n != 1)
        rc = usage();
    else
        rc = dump(args[0], refdir);
done:
    free(args);
    free(no.rules);
    return rc;
}
