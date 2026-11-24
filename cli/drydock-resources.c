/*
 * drydock-resources -- checks, converts and dumps the nibs an app carries, so OS X 10.9 can load them.
 *
 *   drydock-resources dump [--target 10.9] [--references DIR] NIB
 *     prints NIB (a NIBArchive file, or a nib directory's keyedobjects.nib) as Rez-style text a person can read,
 *     diff and edit. Superclass chains come from the reference set: --references DIR, else
 *     <realpath(this binary)>/../../share/drydock/objc/reference when it exists; with neither, the
 *     chains are marked unresolved. A keyed-archive nib dumps with the chains its archive holds.
 *
 *   drydock-resources build [--target 10.9] [--resource-references DIR] [--no-adapt[=RULE]]... TEXT -o NIB
 *     writes the dump TEXT as a keyed-archive nib, replacing NIB whole or leaving it as it was. The adaptation rules
 *     the target needs rewrite it first, each rewrite printed as "TEXT: adapted: RULE (@N KEY)"; --no-adapt turns
 *     them all off, --no-adapt=RULE one. A rule that cannot judge an object (an unreadable frame) is printed as a
 *     finding, and nothing is written. The rules' data is adapt.tsv in --resource-references DIR, else
 *     <realpath(this binary)>/../../share/drydock/resources/reference.
 *
 *   drydock-resources check [--target 10.9] [--references DIR] [--resource-references DIR] [--no-adapt[=RULE]]...
 *                           NIB|TEXT
 *     prints every finding for one nib (file or nib directory), each nib of a .storyboardc, or a dump TEXT, one per
 *     line as "NIB: SEVERITY: KIND ITEM (DETAIL)"; a problem an adaptation rule fixes is "will-adapt", or with
 *     --no-adapt an ordinary "finding". Both reference sets are needed, found as for dump and build.
 *
 * Every verb takes --target, and 10.9 is the only target. Exit 0 (check: only will-adapt findings); 1 findings (a
 * dump build cannot encode or adapt); 2 usage, or an unknown rule; 4 a nib, dump or reference set that cannot be read
 * or written, or out of memory.
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
#include <dirent.h>
#include "adapt.h"
#include "atomic_write.h"
#include "chains.h"
#include "findings.h"
#include "keyed.h"
#include "nibarchive.h"
#include "rez.h"

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
            "                               [--no-adapt[=RULE]]... NIB|TEXT\n");
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

/* The graph of the nib at arg (a file, or a nib directory's keyedobjects.nib) into *g: 0, or 4 with the reason
 * printed. A NIBArchive's chains are resolved from the reference set at refdir (none: unresolved); a keyed archive
 * keeps its own. With text set, a dump is read too. */
static int load(const char *arg, const char *refdir, int text, RGraph *g) {
    char path[PATH_MAX], why[512];
    struct stat st;
    uint8_t *buf;
    size_t n;
    RChainSrc *s;
    int rc;
    if (stat(arg, &st) == 0 && S_ISDIR(st.st_mode)) {
        if ((size_t)snprintf(path, sizeof path, "%s/keyedobjects.nib", arg) >= sizeof path) {
            fprintf(stderr, "drydock-resources: %s: path too long\n", arg);
            return 4;
        }
        arg = path;
    }
    if (!(buf = read_nib(arg, &n))) return 4;
    if (n >= 8 && !memcmp(buf, "bplist00", 8)) rc = ka_read(buf, n, g, why, sizeof why);
    else if (n >= 10 && !memcmp(buf, "NIBArchive", 10)) rc = na_read(buf, n, g, why, sizeof why);
    else if (text && n >= 22 && !memcmp(buf, "drydock-resources dump", 22)) rc = rez_parse((const char *)buf, n, g, why, sizeof why);
    else {
        fprintf(stderr, "drydock-resources: %s: unsupported format\n", arg);
        free(buf);
        return 4;
    }
    free(buf);
    if (rc) { fprintf(stderr, "drydock-resources: %s: %s\n", arg, why); return rc; }
    if (g->format != RF_NIBARCHIVE || g->n_chains) return 0;
    if (!(s = rc_open(refdir, "10.9"))) {
        if (refdir) fprintf(stderr, "drydock-resources: cannot read the references in %s\n", refdir);
        else fprintf(stderr, "drydock-resources: out of memory\n");
        rg_free(g);
        return 4;
    }
    rc = rc_resolve(s, g);
    rc_close(s);
    if (rc) {
        fprintf(stderr, "drydock-resources: out of memory\n");
        rg_free(g);
        return 4;
    }
    return 0;
}

static int dump(const char *arg, const char *refdir) {
    char refs[PATH_MAX], why[512], *text;
    size_t textn;
    RGraph g;
    int rc;
    if (!refdir) refdir = default_references("objc", refs, sizeof refs);
    if ((rc = load(arg, refdir, 0, &g))) return rc;
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

static int name_cmp(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

/* The nibs a .storyboardc holds, sorted bytewise: 0, or 4 with the reason printed. */
static int storyboard_nibs(const char *dir, char ***out, size_t *n) {
    DIR *d;
    struct dirent *e;
    char **v = NULL, **more;
    size_t len;
    *n = 0;
    if (!(d = opendir(dir))) {
        fprintf(stderr, "drydock-resources: %s: cannot read: %s\n", dir, strerror(errno));
        return 4;
    }
    while ((e = readdir(d))) {
        len = strlen(e->d_name);
        if (len < 5 || strcmp(e->d_name + len - 4, ".nib")) continue;
        if (!(more = realloc(v, (*n + 1) * sizeof *v)) || !(more[*n] = malloc(strlen(dir) + len + 2))) {
            if (more) v = more;
            while (*n) free(v[--*n]);
            free(v);
            closedir(d);
            fprintf(stderr, "drydock-resources: out of memory\n");
            return 4;
        }
        v = more;
        sprintf(v[(*n)++], "%s/%s", dir, e->d_name);
    }
    closedir(d);
    if (*n) qsort(v, *n, sizeof *v, name_cmp);
    *out = v;
    return 0;
}

/* Prints every finding for arg: 0 none but will-adapt; 1 findings; 4 something could not be measured. */
static int check(const char *arg, const char *refdir, const char *resrefs, const NoAdapt *no) {
    char refs[PATH_MAX];
    RAdaptSet *a;
    RfRefs *r;
    RFindings f = { NULL, 0 };
    char **nibs = NULL, *one[1];
    size_t n = 1, i, len = strlen(arg);
    int rc = 0, worst = 0;
    struct stat st;
    if (!refdir && !(refdir = default_references("objc", refs, sizeof refs))) {
        fprintf(stderr, "drydock-resources: no references beside drydock-resources: pass --references DIR\n");
        return 4;
    }
    if (!(a = adapt_set(resrefs, no))) return 4;
    if (!(r = rf_open(resrefs, refdir))) {
        fprintf(stderr, "drydock-resources: cannot read the references in %s and %s\n", resrefs, refdir);
        ra_free(a);
        return 4;
    }
    one[0] = (char *)arg;
    if (len > 12 && !strcmp(arg + len - 12, ".storyboardc") && stat(arg, &st) == 0 && S_ISDIR(st.st_mode)) {
        if ((rc = rf_storyboard(r, arg, "10.9", &f)) || (rc = storyboard_nibs(arg, &nibs, &n))) worst = 4;
    } else
        nibs = one;
    for (i = 0; !worst && i < n; i++) {
        RGraph g;
        if (load(nibs[i], refdir, 1, &g)) { worst = 4; break; }
        rc = rf_check(r, &g, nibs[i], "10.9", a, &f);
        rg_free(&g);
        if (rc) { fprintf(stderr, "drydock-resources: out of memory\n"); worst = 4; }
    }
    print_findings(&f, arg);
    for (i = 0; !worst && i < f.n; i++)
        if (f.v[i].sev == RF_FINDING || f.v[i].sev == RF_BLOCK_WRITE) worst = 1;
    if (fflush(stdout)) worst = 4;
    if (nibs != one) {
        for (i = 0; i < n; i++) free(nibs[i]);
        free(nibs);
    }
    rf_free(&f);
    rf_close(r);
    ra_free(a);
    return worst;
}

int main(int argc, char **argv) {
    const char *verb, *refdir = NULL, *resrefs = NULL, *out = NULL, **args;
    char resbuf[PATH_MAX];
    NoAdapt no = { 0, NULL, 0 };
    int i, n = 0, rc;
    if (argc < 2) return usage();
    verb = argv[1];
    if (strcmp(verb, "check") && strcmp(verb, "convert") && strcmp(verb, "dump") && strcmp(verb, "build")) return usage();
    if (!(args = calloc((size_t)argc, sizeof *args)) || !(no.rules = calloc((size_t)argc, sizeof *no.rules))) {
        free(args);
        fprintf(stderr, "drydock-resources: out of memory\n");
        return 4;
    }
    for (i = 2; i < argc; i++) {
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
    else if (!strcmp(verb, "check"))
        rc = n != 1 ? usage() : check(args[0], refdir, resrefs, &no);
    else if (strcmp(verb, "dump")) {
        fprintf(stderr, "drydock-resources: %s is not implemented yet\n", verb);
        rc = 2;
    } else if (n != 1)
        rc = usage();
    else
        rc = dump(args[0], refdir);
done:
    free(args);
    free(no.rules);
    return rc;
}
