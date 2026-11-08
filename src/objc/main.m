/* main.m -- the objc-compat analyzer front end: arguments, JSON inputs, the stage pipeline and
 * the schema-1 report. Foundation is used only to parse JSON (manifest, cluster witnesses, build
 * evidence); the report is written by hand so its bytes are canonical on every host. It names no
 * absolute path (the artifact is named relative to the root; references and evidence by hash) and
 * identifies the analyzer by its sources (--analyzer-id), so the same inputs give the same bytes on a
 * Mavericks and an arm64 host.
 *
 *   objc-compat --artifact FILE --root SHIPPED_ROOT --references REF_DIR --report NEW_FILE
 *               [--build-evidence FILE] [--provider-prefix DIR [--source-receipt FILE]] [--mode inventory|strict]
 *               [--exceptions FILE] [--analyzer-id ID]
 *   objc-compat provider-link-args --prefix DIR --link-map FILE           (scripts/objc-provider-link-args.sh)
 *   objc-compat emit-build-evidence --artifact FILE --prestrip FILE --source-root DIR [--link-map FILE
 *               --provider-prefix DIR] --references REF_DIR --output NEW_FILE  (scripts/objc-build-evidence.sh)
 *
 * --provider-prefix loads a provider declaration (load_provider_prefix); its build-evidence record
 * and provider.c decide whether it is active. --source-receipt names the provider body's source receipt
 * (tools/objc-source-inventory.c); source-evidence.c maps it into verified provider code only. Every run recomputes the artifact, reference,
 * evidence, declaration and archive hashes; an earlier report, however clean, is never an input.
 *
 * Exit 0: measured, and in strict mode no blocking finding. 1: strict, and some finding is
 * unsupported or unresolved. 2: misuse -- a missing/unknown/repeated option, an artifact outside
 * the shipped root, or a report destination that already exists in any form (file, symlink,
 * hard link) or whose directory does not. 4: cannot measure -- unreadable or unverifiable
 * inputs, an unsupported reader shape, stale or malformed evidence, a non-system dependency that
 * is not one shipped image inside the root ("The shipped closure" below), malformed UTF-8 anywhere
 * the report would carry it. 4 wins over 1. Strict mode
 * also names each blocking finding on stderr, "objc-compat: blocking: ID VERDICT: PROOF".
 * --exceptions names reviewed objc-api deviation records (the "objc-api scoped deviations" section
 * below): a blocking finding one of them names exactly is marked, reported and no longer blocks.
 *
 * A report is written for 0, 1 and 4 (with complete_within_boundary false and the errors), never
 * for 2 and never in part: it is built in memory, written to a temporary in the destination's
 * directory, flushed to disk and only then hard-linked to the destination name, which fails
 * rather than replace anything that appeared meanwhile. A killed run leaves at most the hidden
 * temporary, never a report. Inputs are bounded: JSON inputs at 16 MiB, the manifest at 1 MiB.
 *
 * Every report whose reference set carries a reviewed R1 witness lists, in accepted_residual_risk,
 * the measured non-implementing floor classes (the R1 amendment: a receiver that R1 closes could be
 * one of them), the reviewed root selectors, per_selector each one's kinds and own measured
 * non-implementing classes (the six, or the strict subset the manifest records for those kinds; a
 * one-kind record gives its selector one entry per kind), and the witness identity -- floor OS, build, arch, the
 * floor-runtime.tsv SHA-256 and the capture tool source -- whether or not R1 closed anything. Next to it,
 * closure_class_roots records the measured fact R1 on receivers of unknown class rests on: how many
 * classes the artifact defines and their roots, run-time class creation sites, dependencies the floor
 * capture did not load, each class or dependency that keeps R1 off, and whether R1 applies. */
#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <fnmatch.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "report.h"

#define JSON_MAX (16u << 20)
#define MANIFEST_MAX (1u << 20)

static int usage(const char *why) {
    fprintf(stderr, "objc-compat: %s\nusage: objc-compat --artifact FILE --root SHIPPED_ROOT --references REF_DIR "
                    "--report NEW_FILE [--build-evidence FILE] [--provider-prefix DIR [--source-receipt FILE]] [--mode inventory|strict] [--exceptions FILE]\n", why);
    return 2;
}

/* ---- hashing ----------------------------------------------------------------------------- */

static int sha256_file(const char *path, char out[65]) {
    FILE *f = fopen(path, "rb");
    CC_SHA256_CTX c;
    unsigned char buf[1 << 16], d[CC_SHA256_DIGEST_LENGTH];
    size_t n;
    int i;
    if (!f) return -1;
    CC_SHA256_Init(&c);
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) CC_SHA256_Update(&c, buf, (CC_LONG)n);
    if (ferror(f)) { fclose(f); return -1; }
    fclose(f);
    CC_SHA256_Final(d, &c);
    for (i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(out + 2 * i, 3, "%02x", d[i]);
    return 0;
}

/* ---- JSON input --------------------------------------------------------------------------- */

static id read_json(ObjcAnalysis *a, const char *path, unsigned max, const char *what) {
    struct stat st;
    NSData *d;
    NSError *err = nil;
    id v;
    if (stat(path, &st) != 0 || !S_ISREG(st.st_mode)) { objc_fail(a, "unreadable-input", NULL, 0, "%s %s: %s", what, path, strerror(errno ? errno : EINVAL)); return nil; }
    if ((unsigned long long)st.st_size > max) { objc_fail(a, "oversized-input", NULL, 0, "%s %s: %lld bytes, limit %u", what, path, (long long)st.st_size, max); return nil; }
    if (!(d = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path] options:0 error:&err]) || [d length] != (NSUInteger)st.st_size) {
        objc_fail(a, "unreadable-input", NULL, 0, "%s %s: read failed", what, path); return nil;
    }
    if (!(v = [NSJSONSerialization JSONObjectWithData:d options:0 error:&err]) || ![v isKindOfClass:[NSDictionary class]]) {
        objc_fail(a, "malformed-input", NULL, 0, "%s %s: not a JSON object (%s)", what, path,
                  err ? [[err localizedDescription] UTF8String] : "wrong type");
        return nil;
    }
    return v;
}

static NSString *str(NSDictionary *d, NSString *k) {
    id v = [d objectForKey:k];
    return [v isKindOfClass:[NSString class]] ? v : nil;
}
static NSArray *arr(NSDictionary *d, NSString *k) {
    id v = [d objectForKey:k];
    return [v isKindOfClass:[NSArray class]] ? v : nil;
}
static NSDictionary *obj(NSDictionary *d, NSString *k) {
    id v = [d objectForKey:k];
    return [v isKindOfClass:[NSDictionary class]] ? v : nil;
}
static const char *cs(NSString *s) { return s ? [s UTF8String] : NULL; }

/* Only these keys may appear; anything else is a newer or mistaken schema, not ignored. */
static int only_keys_as(ObjcAnalysis *a, const char *code, NSDictionary *d, const char *where, NSArray *allowed) {
    for (id k in d)
        if (![allowed containsObject:k]) return objc_fail(a, code, NULL, 0, "%s: unknown key %s", where, [[k description] UTF8String]);
    return OBJC_OK;
}
static int only_keys(ObjcAnalysis *a, NSDictionary *d, const char *where, NSArray *allowed) {
    return only_keys_as(a, "malformed-build-evidence", d, where, allowed);
}

/* The versioned reference set: manifest schema 1, every listed file present (not a symlink) with
 * its SHA-256, nothing unlisted, a captured floor runtime. */
static int load_manifest(ObjcAnalysis *a, const char *dir, NSMutableArray *ref_inputs, char manifest_sha[65]) {
    char path[PATH_MAX];
    NSDictionary *m, *rt;
    NSArray *files;
    NSMutableSet *listed = [NSMutableSet set];
    NSArray *present;
    NSError *err = nil;
    snprintf(path, sizeof path, "%s/manifest.json", dir);
    if (!(m = read_json(a, path, MANIFEST_MAX, "manifest"))) return OBJC_CANNOT_MEASURE;
    if (sha256_file(path, manifest_sha)) return objc_fail(a, "unreadable-reference", NULL, 0, "%s", path);
    if (![[m objectForKey:@"schema"] isEqual:@1] || !(files = arr(m, @"files")))
        return objc_fail(a, "malformed-reference", NULL, 0, "%s: not a schema-1 manifest", path);
    for (NSDictionary *f in files) {
        NSString *name, *want;
        char fp[PATH_MAX], got[65];
        struct stat st;
        if (![f isKindOfClass:[NSDictionary class]] || !(name = str(f, @"name")) || !(want = str(f, @"sha256")) ||
            [name rangeOfString:@"/"].location != NSNotFound || [name hasPrefix:@"."])
            return objc_fail(a, "malformed-reference", NULL, 0, "%s: bad file entry", path);
        snprintf(fp, sizeof fp, "%s/%s", dir, cs(name));
        if (lstat(fp, &st) != 0 || !S_ISREG(st.st_mode)) return objc_fail(a, "unreadable-reference", NULL, 0, "%s missing or not a regular file", fp);
        if (sha256_file(fp, got) || strcmp(got, cs(want))) return objc_fail(a, "reference-hash-mismatch", NULL, 0, "%s does not match the manifest", fp);
        [listed addObject:name];
        [ref_inputs addObject:@{ @"name": name, @"sha256": want }];
    }
    if (!(present = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[NSString stringWithUTF8String:dir] error:&err]))
        return objc_fail(a, "unreadable-reference", NULL, 0, "%s: cannot list", dir);
    for (NSString *p in present)
        if (![p isEqualToString:@"manifest.json"] && ![listed containsObject:p])
            return objc_fail(a, "malformed-reference", NULL, 0, "%s/%s is not in the manifest", dir, cs(p));
    for (NSString *need in @[ @"floor-sdk.tsv", @"floor-signatures.tsv", @"newer-sdk.tsv", @"floor-runtime.tsv", @"cluster-witnesses.json" ])
        if (![listed containsObject:need]) return objc_fail(a, "incomplete-reference", NULL, 0, "%s lacks %s", dir, cs(need));
    if (![str(m, @"runtime_status") isEqualToString:@"captured"] || !(rt = obj(m, @"runtime")))
        return objc_fail(a, "incomplete-reference", NULL, 0, "%s: the floor runtime is not captured", dir);
    if (objc_set_string(&a->runtime_os, cs(str(rt, @"os"))) || objc_set_string(&a->runtime_build, cs(str(rt, @"build"))) ||
        objc_set_string(&a->runtime_arch, cs(str(rt, @"arch"))))
        return objc_fail(a, "out-of-memory", NULL, 0, "manifest");
    for (id r in arr(rt, @"root_selectors") ?: @[])
        if (![r isKindOfClass:[NSString class]] || objc_strv_push(&a->manifest_roots, &a->n_manifest_roots, cs(r)))
            return objc_fail(a, "malformed-reference", NULL, 0, "manifest root_selectors");
    /* The R1 amendment's reviewed residual risk; reference.c holds the witness to it exactly. */
    if ((a->have_manifest_exceptions = arr(rt, @"root_exceptions") != nil))
        for (id r in arr(rt, @"root_exceptions"))
            if (![r isKindOfClass:[NSString class]] || objc_strv_push(&a->manifest_exceptions, &a->n_manifest_exceptions, cs(r)))
                return objc_fail(a, "malformed-reference", NULL, 0, "manifest root_exceptions");
    /* The R1 selector set's per-selector records: a selector whose measured exception set is a strict
     * subset of root_exceptions, its reviewed kinds and that set; reference.c holds each kind to it. */
    if ((a->have_manifest_subsets = arr(rt, @"root_subset_exceptions") != nil))
        for (id e in arr(rt, @"root_subset_exceptions")) {
            NSString *sel = [e isKindOfClass:[NSDictionary class]] && [e count] == 3 ? str(e, @"selector") : nil;
            NSArray *kinds = sel ? arr(e, @"kinds") : nil, *exc = kinds ? arr(e, @"exceptions") : nil;
            NSMutableString *row = [NSMutableString string], *k = [NSMutableString string];
            if (!exc || [sel rangeOfString:@"\t"].location != NSNotFound)
                return objc_fail(a, "malformed-reference", NULL, 0, "manifest root_subset_exceptions");
            for (id x in kinds)
                if (![x isKindOfClass:[NSString class]]) return objc_fail(a, "malformed-reference", NULL, 0, "manifest root_subset_exceptions kinds");
                else [k appendString:x];
            if (![k isEqualToString:@"+-"] && ![k isEqualToString:@"+"] && ![k isEqualToString:@"-"])
                return objc_fail(a, "malformed-reference", NULL, 0, "manifest root_subset_exceptions kinds for %s", cs(sel));
            [row appendFormat:@"%@\t%@\t", sel, k];
            for (NSUInteger i = 0; i < [exc count]; i++) {
                id x = [exc objectAtIndex:i];
                if (![x isKindOfClass:[NSString class]] || ![x length] || [x rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound)
                    return objc_fail(a, "malformed-reference", NULL, 0, "manifest root_subset_exceptions for %s", cs(sel));
                [row appendFormat:@"%s%@", i ? " " : "", x];
            }
            if (objc_strv_push(&a->manifest_subsets, &a->n_manifest_subsets, cs(row)))
                return objc_fail(a, "out-of-memory", NULL, 0, "manifest");
        }
    if (str(rt, @"tool_source_sha256") && objc_set_string(&a->runtime_tool_sha256, cs(str(rt, @"tool_source_sha256"))))
        return objc_fail(a, "out-of-memory", NULL, 0, "manifest");
    snprintf(path, sizeof path, "%s/floor-sdk.tsv", dir);
    if (objc_set_string(&a->facts_path, path)) return OBJC_CANNOT_MEASURE;
    snprintf(path, sizeof path, "%s/floor-signatures.tsv", dir);
    if (objc_set_string(&a->signatures_path, path) || objc_set_string(&a->references_dir, dir)) return OBJC_CANNOT_MEASURE;
    return OBJC_OK;
}

static int load_clusters(ObjcAnalysis *a, const char *dir) {
    char path[PATH_MAX];
    NSDictionary *c;
    snprintf(path, sizeof path, "%s/cluster-witnesses.json", dir);
    if (!(c = read_json(a, path, JSON_MAX, "cluster witnesses"))) return OBJC_CANNOT_MEASURE;
    if (![[c objectForKey:@"schema"] isEqual:@1] || !arr(c, @"probes")) return objc_fail(a, "malformed-reference", NULL, 0, "%s: not schema 1", path);
    for (NSDictionary *p in arr(c, @"probes")) {
        ObjcClusterProbe q;
        char *chain[64], *below[4096];
        NSArray *steps;
        size_t i = 0;
        int rc;
        memset(&q, 0, sizeof q);
        if (![p isKindOfClass:[NSDictionary class]] || !str(p, @"id") || !str(p, @"class") || !str(p, @"concrete") ||
            !(steps = arr(p, @"construction")) || !arr(p, @"chain") || !arr(p, @"below"))
            return objc_fail(a, "malformed-reference", NULL, 0, "%s: bad probe", path);
        q.id = (char *)cs(str(p, @"id")); q.cls = (char *)cs(str(p, @"class")); q.concrete = (char *)cs(str(p, @"concrete"));
        q.construction = (char *)cs([steps componentsJoinedByString:@" "]);
        for (NSString *x in arr(p, @"chain")) { if (i == 64 || ![x isKindOfClass:[NSString class]]) return objc_fail(a, "malformed-reference", NULL, 0, "%s: chain", path); chain[i++] = (char *)cs(x); }
        q.chain = chain; q.nchain = i; i = 0;
        for (NSDictionary *b in arr(p, @"below")) {
            if (i == 4096 || ![b isKindOfClass:[NSDictionary class]] || !str(b, @"selector")) return objc_fail(a, "malformed-reference", NULL, 0, "%s: below", path);
            below[i++] = (char *)cs(str(b, @"selector"));
        }
        q.below = below; q.nbelow = i;
        if ((rc = objc_add_probe(a, &q))) return rc;
    }
    return OBJC_OK;
}

#define S(d, k) cs(str(d, k))
static int load_evidence_providers(ObjcAnalysis *a, NSArray *list);
/* Build evidence, schema 1: hand-reviewed (binding receipt, R2, guards) or written by
 * scripts/objc-build-evidence.sh (prestrip, link map, references, providers), or both. A recorded
 * reference manifest must be the one in use; provider records attach to --provider-prefix's
 * declarations (load them first). */
static int load_build_evidence(ObjcAnalysis *a, const char *path, const char *manifest_sha) {
    NSDictionary *b, *art, *src, *refs;
    size_t i;
    if (!(b = read_json(a, path, JSON_MAX, "build evidence"))) return OBJC_CANNOT_MEASURE;
    if (only_keys(a, b, "build evidence", @[ @"schema", @"kind", @"artifact", @"source", @"crates", @"type_map",
                                              @"type_evidence", @"position_evidence", @"binding_receipt", @"guards", @"prestrip", @"link_map",
                                              @"references", @"providers" ]))
        return OBJC_CANNOT_MEASURE;
    if (![[b objectForKey:@"schema"] isEqual:@1] || ![str(b, @"kind") isEqualToString:@"objc-build-evidence"] ||
        !(art = obj(b, @"artifact")) || !str(art, @"sha256") || !(src = obj(b, @"source")))
        return objc_fail(a, "malformed-build-evidence", NULL, 0, "%s: not schema-1 objc build evidence", path);
    a->have_build_evidence = 1;
    if ((refs = obj(b, @"references")) && (!S(refs, @"manifest_sha256") || strcmp(S(refs, @"manifest_sha256"), manifest_sha)))
        return objc_fail(a, "stale-build-evidence", NULL, 0, "%s was made against reference manifest %s, not %s", path,
                         S(refs, @"manifest_sha256") ? S(refs, @"manifest_sha256") : "(none)", manifest_sha);
    if ([b objectForKey:@"providers"] && (!arr(b, @"providers") || load_evidence_providers(a, arr(b, @"providers"))))
        return a->n_errors ? OBJC_CANNOT_MEASURE : objc_fail(a, "malformed-build-evidence", NULL, 0, "%s: providers is not a list", path);
    if (objc_set_string(&a->be_artifact_sha256, S(art, @"sha256")) || objc_set_string(&a->be_source_revision, S(src, @"revision")) ||
        objc_set_string(&a->be_patches_sha256, S(src, @"patches_sha256")) || objc_set_string(&a->be_features, S(src, @"features")))
        return objc_fail(a, "out-of-memory", NULL, 0, "evidence");
    i = 0;
    for (NSDictionary *c in arr(b, @"crates") ?: @[]) {
        ObjcCrate *g;
        if (![c isKindOfClass:[NSDictionary class]] || !(g = realloc(a->crates, (a->n_crates + 1) * sizeof *g)))
            return objc_fail(a, "malformed-build-evidence", NULL, 0, "crate %zu", i + 1);
        a->crates = g; memset(&g[a->n_crates], 0, sizeof *g); g = &g[a->n_crates++];
        if (objc_set_string(&g->name, S(c, @"name")) || objc_set_string(&g->version, S(c, @"version")) ||
            objc_set_string(&g->checksum, S(c, @"checksum")) || objc_set_string(&g->disambiguator, S(c, @"disambiguator")))
            return objc_fail(a, "out-of-memory", NULL, 0, "crate");
        i++;
    }
    for (NSDictionary *c in arr(b, @"type_map") ?: @[]) {
        ObjcTypeMap *g;
        if (![c isKindOfClass:[NSDictionary class]] || !(g = realloc(a->typemap, (a->n_typemap + 1) * sizeof *g)))
            return objc_fail(a, "malformed-build-evidence", NULL, 0, "type map");
        a->typemap = g; memset(&g[a->n_typemap], 0, sizeof *g); g = &g[a->n_typemap++];
        if (objc_set_string(&g->rust_type, S(c, @"rust_type")) || objc_set_string(&g->cls, S(c, @"class")) ||
            objc_set_string(&g->source, S(c, @"source")))
            return objc_fail(a, "out-of-memory", NULL, 0, "type map");
    }
    for (NSDictionary *c in arr(b, @"type_evidence") ?: @[]) {
        ObjcTypeEvidence *g;
        if (![c isKindOfClass:[NSDictionary class]] || !(g = realloc(a->types, (a->n_types + 1) * sizeof *g)))
            return objc_fail(a, "malformed-build-evidence", NULL, 0, "type evidence");
        a->types = g; memset(&g[a->n_types], 0, sizeof *g); g = &g[a->n_types++];
        if (objc_set_string(&g->id, S(c, @"id")) || objc_set_string(&g->symbol, S(c, @"symbol")) ||
            objc_set_string(&g->rust_type, S(c, @"rust_type")) || objc_set_string(&g->position, S(c, @"position")) ||
            objc_set_string(&g->kind, S(c, @"kind")) || objc_set_string(&g->source, S(c, @"source")))
            return objc_fail(a, "out-of-memory", NULL, 0, "type evidence");
        for (id s in arr(c, @"selectors") ?: @[])
            if (![s isKindOfClass:[NSString class]] || objc_strv_push(&g->selectors, &g->nselectors, cs(s)))
                return objc_fail(a, "malformed-build-evidence", NULL, 0, "type evidence selectors");
    }
    for (NSDictionary *c in arr(b, @"position_evidence") ?: @[]) {
        ObjcPositionEvidence *g;
        NSDictionary *pos;
        if (![c isKindOfClass:[NSDictionary class]] || !(g = realloc(a->positions, (a->n_positions + 1) * sizeof *g)))
            return objc_fail(a, "malformed-build-evidence", NULL, 0, "position evidence");
        a->positions = g; memset(&g[a->n_positions], 0, sizeof *g); g = &g[a->n_positions++];
        pos = obj(c, @"position");
        if (objc_set_string(&g->id, S(c, @"id")) || objc_set_string(&g->symbol, S(c, @"symbol")) ||
            objc_set_string(&g->kind, S(c, @"kind")) || objc_set_string(&g->cls, S(c, @"class")) ||
            objc_set_string(&g->source, S(c, @"source")) ||
            (pos && (objc_set_string(&g->form, S(pos, @"form")) || objc_set_string(&g->position_selector, S(pos, @"selector")) ||
                     objc_set_string(&g->rust_type, S(pos, @"rust_type")) || objc_set_string(&g->field, S(pos, @"field")))))
            return objc_fail(a, "out-of-memory", NULL, 0, "position evidence");
        for (id s in arr(c, @"selectors") ?: @[])
            if (![s isKindOfClass:[NSString class]] || objc_strv_push(&g->selectors, &g->nselectors, cs(s)))
                return objc_fail(a, "malformed-build-evidence", NULL, 0, "position evidence selectors");
    }
    for (NSDictionary *c in arr(b, @"binding_receipt") ?: @[]) {
        ObjcReceiptRow *g;
        if (![c isKindOfClass:[NSDictionary class]] || !(g = realloc(a->receipt, (a->n_receipt + 1) * sizeof *g)))
            return objc_fail(a, "malformed-build-evidence", NULL, 0, "receipt");
        a->receipt = g; memset(&g[a->n_receipt], 0, sizeof *g); g = &g[a->n_receipt++];
        if (objc_set_string(&g->demangled, S(c, @"cache")) || objc_set_string(&g->selector, S(c, @"selector")) ||
            objc_set_string(&g->receiver, S(c, @"receiver")) || objc_set_string(&g->kind, S(c, @"kind")) ||
            objc_set_string(&g->provenance, S(c, @"source")))
            return objc_fail(a, "out-of-memory", NULL, 0, "receipt");
    }
    for (NSDictionary *c in arr(b, @"guards") ?: @[]) {
        ObjcGuardRecord *g;
        NSDictionary *gs, *rv;
        id line;
        if (![c isKindOfClass:[NSDictionary class]] || !(g = realloc(a->guards, (a->n_guards + 1) * sizeof *g)))
            return objc_fail(a, "malformed-build-evidence", NULL, 0, "guard");
        a->guards = g; memset(&g[a->n_guards], 0, sizeof *g); g = &g[a->n_guards++];
        gs = obj(c, @"source") ?: @{}; rv = obj(c, @"review") ?: @{};
        line = [gs objectForKey:@"line"];
        g->source_line = [line isKindOfClass:[NSNumber class]] && [line longLongValue] > 0 ? (uint64_t)[line longLongValue] : 0;
        if (objc_set_string(&g->id, S(c, @"id")) || objc_set_string(&g->symbol, S(c, @"function")) ||
            objc_set_string(&g->selector, S(c, @"selector")) || objc_set_string(&g->guard_selector, S(c, @"guard")) ||
            objc_set_string(&g->fallback, S(c, @"fallback")) || objc_set_string(&g->source_file, S(gs, @"file")) ||
            objc_set_string(&g->source_sha256, S(gs, @"sha256")) || objc_set_string(&g->source_revision, S(gs, @"revision")) ||
            objc_set_string(&g->patches_sha256, S(gs, @"patches_sha256")) || objc_set_string(&g->features, S(gs, @"features")) ||
            objc_set_string(&g->review_status, S(rv, @"status")) || objc_set_string(&g->reviewer, S(rv, @"reviewer")) ||
            objc_set_string(&g->review_reason, S(rv, @"reason")))
            return objc_fail(a, "out-of-memory", NULL, 0, "guard");
    }
    return OBJC_OK;
}

/* ---- provider declarations (provider.c header) ------------------------------------------------- */

static int charset(const char *s, size_t max, int (*first)(int), int (*rest)(int)) {
    size_t i;
    if (!s || !*s || strlen(s) > max || !first((unsigned char)s[0])) return 0;
    for (i = 1; s[i]; i++) if (!rest((unsigned char)s[i])) return 0;
    return 1;
}
static int c_first(int c) { return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_'; }
static int c_rest(int c) { return c_first(c) || (c >= '0' && c <= '9'); }
static int sel_rest(int c) { return c_rest(c) || c == ':'; }
static int id_first(int c) { return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'); }
static int id_rest(int c) { return id_first(c) || c == '.' || c == '-' || c == '_'; }
static int fw_first(int c) { return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'); }
static int enc_char(int c) { return c > 0x20 && c < 0x7f && c != '"' && c != '\\'; }
static int file_char(int c) { return c_rest(c) || c == '.' || c == '-'; }
static int hex64(const char *s) {
    size_t i;
    if (!s || strlen(s) != 64) return 0;
    for (i = 0; i < 64; i++) if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return 0;
    return 1;
}
static int json_int1(id x) {
    return [x isKindOfClass:[NSNumber class]] && CFGetTypeID((CFTypeRef)x) != CFBooleanGetTypeID() &&
           !CFNumberIsFloatType((CFNumberRef)x) && [x isEqual:@1];
}
static int exact_keys(NSDictionary *d, NSArray *keys) {
    return [d isKindOfClass:[NSDictionary class]] && [[NSSet setWithArray:[d allKeys]] isEqualToSet:[NSSet setWithArray:keys]];
}

/* PREFIX/share/recaulk/objc-providers.json, schema 1 as Recaulk's build/objc-provider-manifest.m
 * writes it: every key known, every identifier a plain identifier (nothing a linker or shell could
 * read as more), a strong framework policy, a shipping x86_64 archive whose bytes hash to the
 * declared digest and a source receipt that hashes to its digest. */
static int load_provider_prefix(ObjcAnalysis *a, const char *prefix) {
    char rp[PATH_MAX], decl[PATH_MAX], dsha[65], ash[65], archive[PATH_MAX];
    NSDictionary *d, *b;
    NSArray *ps;
    struct stat st;
    unsigned char rd[CC_SHA256_DIGEST_LENGTH];
    char rsha[65];
    const char *receipt, *ap;
    int i;
    if (!realpath(prefix, rp)) return objc_fail(a, "unreadable-provider", NULL, 0, "%s: %s", prefix, strerror(errno));
    snprintf(decl, sizeof decl, "%s/share/recaulk/objc-providers.json", rp);
    if (!(d = read_json(a, decl, MANIFEST_MAX, "provider declaration"))) return OBJC_CANNOT_MEASURE;
    if (sha256_file(decl, dsha)) return objc_fail(a, "unreadable-provider", NULL, 0, "%s", decl);
    if (!exact_keys(d, @[ @"schema", @"providers", @"build" ]) || !json_int1([d objectForKey:@"schema"]) ||
        !(ps = arr(d, @"providers")) || ![ps count] || !(b = obj(d, @"build")) ||
        !exact_keys(b, @[ @"archive_path", @"archive_sha256", @"architecture", @"artifact_role", @"minimum_macos",
                          @"sdk_settings_sha256", @"compiler_identity", @"source_inputs_receipt", @"source_inputs_sha256" ]))
        return objc_fail(a, "malformed-provider", NULL, 0, "%s: not a schema-1 provider declaration with exactly the known keys", decl);
    ap = S(b, @"archive_path");
    if (!ap || strncmp(ap, "lib/", 4) || !charset(ap + 4, 200, file_char, file_char) || strstr(ap, "..") ||
        strlen(ap) < 7 || strcmp(ap + strlen(ap) - 2, ".a") || ![str(b, @"architecture") isEqualToString:@"x86_64"] ||
        ![str(b, @"artifact_role") isEqualToString:@"shipping"] || ![str(b, @"minimum_macos") isEqualToString:@"10.9"] ||
        !hex64(S(b, @"archive_sha256")) || !hex64(S(b, @"sdk_settings_sha256")) || !hex64(S(b, @"source_inputs_sha256")) ||
        ![str(b, @"compiler_identity") length] || !(receipt = S(b, @"source_inputs_receipt")) || !*receipt)
        return objc_fail(a, "malformed-provider", NULL, 0, "%s: build is not a shipping x86_64 10.9 archive record", decl);
    CC_SHA256(receipt, (CC_LONG)strlen(receipt), rd);
    for (i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(rsha + 2 * i, 3, "%02x", rd[i]);
    if (strcmp(rsha, S(b, @"source_inputs_sha256")))
        return objc_fail(a, "malformed-provider", NULL, 0, "%s: the source receipt does not hash to source_inputs_sha256", decl);
    snprintf(archive, sizeof archive, "%s/%s", rp, ap);
    if (lstat(archive, &st) != 0 || !S_ISREG(st.st_mode) || sha256_file(archive, ash))
        return objc_fail(a, "unreadable-provider", NULL, 0, "%s is missing or not a regular file", archive);
    if (strcmp(ash, S(b, @"archive_sha256")))
        return objc_fail(a, "stale-provider-archive", NULL, 0, "%s is %s; the declaration says %s", archive, ash, S(b, @"archive_sha256"));
    for (NSDictionary *q in ps) {
        ObjcProvider *p;
        NSArray *fws;
        const char *kind;
        if (!exact_keys(q, @[ @"provider_id", @"class", @"method_kind", @"selector", @"encoding", @"implementation_symbol",
                              @"activation_root", @"required_frameworks", @"framework_policy" ]) ||
            !charset(S(q, @"provider_id"), 200, id_first, id_rest) || !charset(S(q, @"class"), 200, c_first, c_rest) ||
            !(kind = S(q, @"method_kind")) || (strcmp(kind, "-") && strcmp(kind, "+")) ||
            !charset(S(q, @"selector"), 400, c_first, sel_rest) || !charset(S(q, @"encoding"), 200, enc_char, enc_char) ||
            !charset(S(q, @"implementation_symbol"), 200, c_first, c_rest) || !charset(S(q, @"activation_root"), 200, c_first, c_rest) ||
            ![str(q, @"framework_policy") isEqualToString:@"strong-linked-before-root"] ||
            !(fws = arr(q, @"required_frameworks")) || ![fws count])
            return objc_fail(a, "malformed-provider", NULL, 0, "%s: a provider entry is not a valid declaration", decl);
        if (objc_add_provider(a, &p)) return OBJC_CANNOT_MEASURE;
        for (id f in fws)
            if (![f isKindOfClass:[NSString class]] || !charset(cs(f), 100, fw_first, c_rest) || objc_strv_push(&p->frameworks, &p->nframeworks, cs(f)))
                return objc_fail(a, "malformed-provider", NULL, 0, "%s: required_frameworks holds a non-identifier", decl);
        if (objc_set_string(&p->provider_id, S(q, @"provider_id")) || objc_set_string(&p->cls, S(q, @"class")) ||
            objc_set_string(&p->method_kind, kind) || objc_set_string(&p->selector, S(q, @"selector")) ||
            objc_set_string(&p->encoding, S(q, @"encoding")) || objc_set_string(&p->impl_symbol, S(q, @"implementation_symbol")) ||
            objc_set_string(&p->root_symbol, S(q, @"activation_root")) || objc_set_string(&p->archive, archive) ||
            objc_set_string(&p->archive_sha256, ash) || objc_set_string(&p->declaration_sha256, dsha) ||
            objc_set_string(&p->sdk_settings_sha256, S(b, @"sdk_settings_sha256")) || objc_set_string(&p->source_inputs, receipt))
            return objc_fail(a, "out-of-memory", NULL, 0, "provider");
    }
    return OBJC_OK;
}

/* The build evidence's provider records, attached to the declarations of the same id. */
static int load_evidence_providers(ObjcAnalysis *a, NSArray *list) {
    for (NSDictionary *c in list) {
        ObjcProvider *p = NULL;
        size_t i;
        if (!exact_keys(c, @[ @"provider_id", @"declaration_sha256", @"archive_sha256", @"members", @"atoms" ]) ||
            !arr(c, @"members") || !arr(c, @"atoms"))
            return objc_fail(a, "malformed-build-evidence", NULL, 0, "a provider record lacks or adds keys");
        for (i = 0; i < a->n_providers; i++) if (S(c, @"provider_id") && !strcmp(a->providers[i].provider_id, S(c, @"provider_id"))) p = &a->providers[i];
        if (!p) continue;   /* no --provider-prefix declares it: nothing to verify against */
        if (p->have_evidence) return objc_fail(a, "malformed-build-evidence", NULL, 0, "provider %s recorded twice", p->provider_id);
        p->have_evidence = 1;
        if (!hex64(S(c, @"declaration_sha256")) || !hex64(S(c, @"archive_sha256")) ||
            objc_set_string(&p->ev_declaration_sha256, S(c, @"declaration_sha256")) || objc_set_string(&p->ev_archive_sha256, S(c, @"archive_sha256")))
            return objc_fail(a, "malformed-build-evidence", NULL, 0, "provider %s digests", p->provider_id);
        for (NSDictionary *m in arr(c, @"members")) {
            ObjcProviderMember *g;
            if (!exact_keys(m, @[ @"name", @"sha256" ]) || !str(m, @"name") || !hex64(S(m, @"sha256")) ||
                !(g = realloc(p->members, (p->n_members + 1) * sizeof *g)))
                return objc_fail(a, "malformed-build-evidence", NULL, 0, "provider %s member", p->provider_id);
            p->members = g; g = &g[p->n_members++]; memset(g, 0, sizeof *g);
            if (objc_set_string(&g->name, S(m, @"name")) || objc_set_string(&g->sha256, S(m, @"sha256"))) return objc_fail(a, "out-of-memory", NULL, 0, "member");
        }
        for (NSDictionary *m in arr(c, @"atoms")) {
            ObjcProviderAtom *g;
            id size = [m objectForKey:@"size"];
            const char *addr = S(m, @"address");
            char *end = NULL;
            unsigned long long va = addr && !strncmp(addr, "0x", 2) ? strtoull(addr + 2, &end, 16) : 0;
            if (!exact_keys(m, @[ @"member", @"symbol", @"address", @"size" ]) || !str(m, @"member") || !str(m, @"symbol") ||
                !end || *end || ![size isKindOfClass:[NSNumber class]] || [size longLongValue] <= 0 ||
                !(g = realloc(p->atoms, (p->n_atoms + 1) * sizeof *g)))
                return objc_fail(a, "malformed-build-evidence", NULL, 0, "provider %s atom", p->provider_id);
            p->atoms = g; g = &g[p->n_atoms++]; memset(g, 0, sizeof *g);
            g->address = va; g->size = (uint64_t)[size longLongValue];
            if (objc_set_string(&g->member, S(m, @"member")) || objc_set_string(&g->symbol, S(m, @"symbol"))) return objc_fail(a, "out-of-memory", NULL, 0, "atom");
        }
    }
    return OBJC_OK;
}

/* ---- the shipped closure --------------------------------------------------------------------
 * The approved design (plan, "Decisions (2026-11-06)", option B): a non-system image the artifact
 * loads is measured by its interface. Each dylib load command whose path is not under /usr/lib/ or
 * /System/Library/ is resolved as dyld would, but inside --root only: @rpath/ through the LC_RPATHs
 * of the loading image and of every image that loaded it, back to the artifact; @loader_path/ from
 * the loading image's directory; @executable_path/ from the artifact's. A run path that is not
 * @loader_path/ or @executable_path/ (an absolute or relative one) could find something outside
 * the shipped root first, and a path that resolves outside the root, through a symlink or `..`,
 * escapes it: both are cannot-measure (escaping-dependency). So is an image found nowhere
 * (missing-dependency), found as two different files (ambiguous-dependency), or loaded weak, lazy or
 * upward (unsupported-dependency): dyld might not load it, or load it late. Each image is hashed,
 * read for its Objective-C metadata, dylib loads and run paths only (metadata_only: its code is
 * never read), and its own non-system loads are resolved in turn. Its class, category and method
 * definitions join the artifact's, tagged with the image, so the artifact's sends into it close
 * against its own implementations and R1 counts its classes (classify.c); its system loads must be
 * in the floor capture like the artifact's. A class defined twice in the closure is cannot-measure
 * (ambiguous-class): which one the runtime uses is not measured. Its own code keeps the exemption
 * its pinned bytes give it, and the report lists each image's SHA-256 as a stated limit. */

#define SHIPPED_MAX 64

static int utf8_ok(const unsigned char *s);

static int system_path(const char *p) { return !strncmp(p, "/usr/lib/", 9) || !strncmp(p, "/System/Library/", 16); }

static const char *image_abs(ObjcAnalysis *a, size_t k) { return k ? a->shipped[k - 1].abs : a->artifact_path; }
static size_t image_ndylibs(ObjcAnalysis *a, size_t k) { return k ? a->shipped[k - 1].n_dylibs : a->n_dylibs; }
static ObjcDylib *image_dylib(ObjcAnalysis *a, size_t k, size_t i) { return k ? &a->shipped[k - 1].dylibs[i] : &a->dylibs[i]; }

static void dir_of(const char *path, char *out, size_t outsz) {
    const char *slash = strrchr(path, '/');
    snprintf(out, outsz, "%.*s", slash ? (int)(slash - path) : 0, path);
}

/* dir/rest into out; 0, or -1 when it does not fit. */
static int under(char *out, size_t outsz, const char *dir, const char *rest) {
    return snprintf(out, outsz, "%s/%s", dir, rest) < (int)outsz ? 0 : -1;
}

/* Every path dyld would try for load path `p` of image k, into cands; 0, or 4 with an error. */
static int candidates(ObjcAnalysis *a, size_t k, const char *p, char (*cands)[PATH_MAX], size_t *nc, size_t max) {
    char dir[PATH_MAX], exe[PATH_MAX];
    dir_of(image_abs(a, k), dir, sizeof dir);
    dir_of(a->artifact_path, exe, sizeof exe);
    *nc = 0;
    if (!strncmp(p, "@loader_path/", 13)) { if (under(cands[(*nc)++], PATH_MAX, dir, p + 13)) return objc_fail(a, "escaping-dependency", NULL, 0, "%s: too long", p); }
    else if (!strncmp(p, "@executable_path/", 17)) { if (under(cands[(*nc)++], PATH_MAX, exe, p + 17)) return objc_fail(a, "escaping-dependency", NULL, 0, "%s: too long", p); }
    else if (!strncmp(p, "@rpath/", 7)) {
        size_t j = k;
        for (;;) {   /* the run paths of the loading image, then of each image that loaded it */
            char **rp = j ? a->shipped[j - 1].rpaths : a->rpaths;
            size_t nrp = j ? a->shipped[j - 1].n_rpaths : a->n_rpaths, i;
            char jdir[PATH_MAX];
            dir_of(image_abs(a, j), jdir, sizeof jdir);
            for (i = 0; i < nrp; i++) {
                char base[PATH_MAX];
                if (*nc == max) return objc_fail(a, "escaping-dependency", NULL, 0, "%s: more than %zu run paths", p, max);
                if (!strncmp(rp[i], "@loader_path/", 13) || !strcmp(rp[i], "@loader_path")) {
                    if (snprintf(base, sizeof base, "%s%s", jdir, rp[i] + 12) >= (int)sizeof base) return objc_fail(a, "escaping-dependency", NULL, 0, "%s: too long", rp[i]);
                } else if (!strncmp(rp[i], "@executable_path/", 17) || !strcmp(rp[i], "@executable_path")) {
                    if (snprintf(base, sizeof base, "%s%s", exe, rp[i] + 16) >= (int)sizeof base) return objc_fail(a, "escaping-dependency", NULL, 0, "%s: too long", rp[i]);
                } else
                    return objc_fail(a, "escaping-dependency", NULL, 0,
                                     "%s: run path %s of %s is not inside the shipped root, so dyld could find the image elsewhere first",
                                     p, rp[i], j ? a->shipped[j - 1].path : a->image_paths[0]);
                if (under(cands[(*nc)++], PATH_MAX, base, p + 7)) return objc_fail(a, "escaping-dependency", NULL, 0, "%s: too long", p);
            }
            if (!j) break;
            j = a->shipped[j - 1].loader;
        }
    } else
        return objc_fail(a, "escaping-dependency", NULL, 0, "%s: a non-system path outside the shipped root", p);
    return OBJC_OK;
}

static int add_shipped(ObjcAnalysis *a, size_t loader, const ObjcDylib *d, const char *found, const char *rroot) {
    ObjcAnalysis *sub;
    ObjcShipped *g, *im;
    char h[65];
    size_t i, k = strlen(rroot), idx;
    int rc;
    if (a->n_shipped == SHIPPED_MAX) return objc_fail(a, "unsupported-dependency", NULL, 0, "more than %d shipped images", SHIPPED_MAX);
    if (!(g = realloc(a->shipped, (a->n_shipped + 1) * sizeof *g))) return objc_fail(a, "out-of-memory", NULL, 0, "shipped image");
    a->shipped = g; im = &g[a->n_shipped]; memset(im, 0, sizeof *im);
    im->loader = loader;
    if (sha256_file(found, h)) return objc_fail(a, "unreadable-dependency", NULL, 0, "%s: %s", found, strerror(errno));
    if (objc_set_string(&im->abs, found) || objc_set_string(&im->path, found + k + (strcmp(rroot, "/") ? 1 : 0)) ||
        objc_set_string(&im->sha256, h) || objc_set_string(&im->install, d->path) || objc_set_string(&im->how, d->how) ||
        objc_strv_push(&a->image_paths, &a->n_image_paths, im->path))
        return objc_fail(a, "out-of-memory", NULL, 0, "shipped image");
    a->n_shipped++;
    idx = a->n_shipped;
    if (!utf8_ok((const unsigned char *)im->path)) return objc_fail(a, "malformed-input", NULL, 0, "a shipped image path is not UTF-8");
    if (!(sub = objc_analysis_create()) || objc_set_string(&sub->artifact_path, found)) { objc_analysis_destroy(sub); return objc_fail(a, "out-of-memory", NULL, 0, "shipped image"); }
    sub->metadata_only = 1;
    rc = objc_collect_artifacts(sub);
    for (i = 0; i < sub->n_errors; i++)
        objc_fail(a, sub->errors[i].code, sub->errors[i].slice, sub->errors[i].address, "shipped image %s: %s", im->path,
                  sub->errors[i].detail ? sub->errors[i].detail : "");
    if (!rc && !sub->n_evidence && !sub->n_dylibs) rc = objc_fail(a, "no-x86_64-slice", NULL, 0, "shipped image %s has no x86_64 slice", im->path);
    for (i = 0; !rc && i < sub->n_evidence; i++) {
        ObjcEvidence e = sub->evidence[i];
        if (e.kind != OBJC_EV_CLASS_DEF && e.kind != OBJC_EV_CATEGORY_DEF && e.kind != OBJC_EV_METHOD_DEF) continue;
        e.image = idx;
        if (objc_add_evidence(a, &e)) rc = OBJC_CANNOT_MEASURE;
        if (e.kind == OBJC_EV_CLASS_DEF) im->classes++;
    }
    for (i = 0; !rc && i < sub->n_dylibs; i++) {
        ObjcDylib *dd = realloc(im->dylibs, (im->n_dylibs + 1) * sizeof *dd);
        if (!dd) { rc = objc_fail(a, "out-of-memory", NULL, 0, "shipped image"); break; }
        im->dylibs = dd; dd = &dd[im->n_dylibs++]; memset(dd, 0, sizeof *dd);
        if (objc_set_string(&dd->slice, sub->dylibs[i].slice) || objc_set_string(&dd->path, sub->dylibs[i].path) ||
            objc_set_string(&dd->how, sub->dylibs[i].how))
            rc = objc_fail(a, "out-of-memory", NULL, 0, "shipped image");
    }
    for (i = 0; !rc && i < sub->n_rpaths; i++)
        if (objc_strv_push(&im->rpaths, &im->n_rpaths, sub->rpaths[i])) rc = objc_fail(a, "out-of-memory", NULL, 0, "shipped image");
    objc_analysis_destroy(sub);
    return rc ? OBJC_CANNOT_MEASURE : OBJC_OK;
}

static int shipped_closure(ObjcAnalysis *a, const char *rroot, const char *rel) {
    size_t k, i, j, nroot = strlen(rroot);
    int status = OBJC_OK;
    if (objc_strv_push(&a->image_paths, &a->n_image_paths, rel)) return objc_fail(a, "out-of-memory", NULL, 0, "image paths");
    for (k = 0; k <= a->n_shipped; k++) {   /* a->n_shipped grows as images are found */
        for (i = 0; i < image_ndylibs(a, k); i++) {
            ObjcDylib *d = image_dylib(a, k, i);
            char cands[32][PATH_MAX], found[PATH_MAX], real[PATH_MAX];
            size_t nc, c, nfound = 0;
            if (!*d->path) { status = objc_fail(a, "unsupported-dependency", d->slice, 0, "(malformed) (%s)", d->how); continue; }
            if (system_path(d->path)) continue;
            if (strcmp(d->how, "load") && strcmp(d->how, "reexport")) {
                status = objc_fail(a, "unsupported-dependency", d->slice, 0, "%s (%s): a shipped image loaded %s may not be loaded, or loaded late",
                                   d->path, d->how, d->how);
                continue;
            }
            if (candidates(a, k, d->path, cands, &nc, 32)) { status = OBJC_CANNOT_MEASURE; continue; }
            for (c = 0; c < nc; c++) {
                struct stat st;
                if (lstat(cands[c], &st) != 0) continue;
                if (!realpath(cands[c], real)) continue;
                if (strncmp(real, rroot, nroot) || (real[nroot] != '/' && strcmp(rroot, "/"))) {
                    status = objc_fail(a, "escaping-dependency", d->slice, 0, "%s: %s is outside the shipped root", d->path, cands[c]);
                    nfound = (size_t)-1;
                    break;
                }
                if (stat(real, &st) != 0 || !S_ISREG(st.st_mode)) continue;
                if (nfound && strcmp(found, real)) {
                    status = objc_fail(a, "ambiguous-dependency", d->slice, 0, "%s: found as %s and as %s", d->path, found, real);
                    nfound = (size_t)-1;
                    break;
                }
                snprintf(found, sizeof found, "%s", real); nfound = 1;
            }
            if (nfound == (size_t)-1) continue;
            if (!nfound) { status = objc_fail(a, "missing-dependency", d->slice, 0, "%s: not found inside the shipped root", d->path); continue; }
            if (!strcmp(found, a->artifact_path)) continue;
            for (j = 0; j < a->n_shipped && strcmp(a->shipped[j].abs, found); j++) ;
            if (j < a->n_shipped) continue;
            if (add_shipped(a, k, d, found, rroot)) status = OBJC_CANNOT_MEASURE;
            if (status && a->n_shipped == SHIPPED_MAX) return status;
        }
    }
    /* One class, one definition: which of two the runtime uses is not measured. */
    for (i = 0; i < a->n_evidence; i++) {
        const ObjcEvidence *x = &a->evidence[i];
        if (x->kind != OBJC_EV_CLASS_DEF || !x->name || !a->n_shipped) continue;
        for (j = i + 1; j < a->n_evidence; j++) {
            const ObjcEvidence *y = &a->evidence[j];
            if (y->kind == OBJC_EV_CLASS_DEF && y->name && !strcmp(x->name, y->name))
                status = objc_fail(a, "ambiguous-class", NULL, 0, "class %s is defined by both %s and %s", x->name,
                                   a->image_paths[x->image], a->image_paths[y->image]);
        }
    }
    return status;
}

/* ---- canonical JSON output ------------------------------------------------------------------ */

typedef struct { char *b; size_t n, cap; int bad; char why[256]; } Out;

static void put(Out *o, const char *s, size_t k) {
    if (o->bad) return;
    if (o->n + k + 1 > o->cap) {
        size_t c = o->cap ? o->cap : 1 << 16;
        char *g;
        while (c < o->n + k + 1) c *= 2;
        if (!(g = realloc(o->b, c))) { o->bad = 1; snprintf(o->why, sizeof o->why, "out of memory"); return; }
        o->b = g; o->cap = c;
    }
    memcpy(o->b + o->n, s, k); o->n += k; o->b[o->n] = 0;
}
static void raw(Out *o, const char *s) { put(o, s, strlen(s)); }
static void fmt(Out *o, const char *f, ...) __attribute__((format(printf, 2, 3)));
static void fmt(Out *o, const char *f, ...) {
    char buf[512];
    va_list ap;
    int k;
    va_start(ap, f); k = vsnprintf(buf, sizeof buf, f, ap); va_end(ap);
    if (k < 0 || k >= (int)sizeof buf) { o->bad = 1; snprintf(o->why, sizeof o->why, "format overflow"); return; }
    put(o, buf, (size_t)k);
}

/* Valid UTF-8 (no overlongs, surrogates or code points past U+10FFFF), or the report refuses. */
static int utf8_ok(const unsigned char *s) {
    while (*s) {
        unsigned c = *s, n, cp, i;
        if (c < 0x80) { s++; continue; }
        if (c >= 0xC2 && c <= 0xDF) { n = 1; cp = c & 0x1F; }
        else if (c >= 0xE0 && c <= 0xEF) { n = 2; cp = c & 0x0F; }
        else if (c >= 0xF0 && c <= 0xF4) { n = 3; cp = c & 0x07; }
        else return 0;
        for (i = 1; i <= n; i++) { if ((s[i] & 0xC0) != 0x80) return 0; cp = (cp << 6) | (s[i] & 0x3F); }
        if ((n == 2 && cp < 0x800) || (n == 3 && cp < 0x10000) || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return 0;
        s += n + 1;
    }
    return 1;
}

static void jstr(Out *o, const char *s) {
    const unsigned char *p;
    if (!s) { raw(o, "null"); return; }
    if (!utf8_ok((const unsigned char *)s)) {
        o->bad = 1; snprintf(o->why, sizeof o->why, "malformed UTF-8 in a reported string");
        return;
    }
    raw(o, "\"");
    for (p = (const unsigned char *)s; *p; p++) {
        if (*p == '"') raw(o, "\\\"");
        else if (*p == '\\') raw(o, "\\\\");
        else if (*p == '\n') raw(o, "\\n");
        else if (*p == '\t') raw(o, "\\t");
        else if (*p < 0x20) fmt(o, "\\u%04x", *p);
        else put(o, (const char *)p, 1);
    }
    raw(o, "\"");
}
static void key(Out *o, const char *k, int first) { if (!first) raw(o, ", "); jstr(o, k); raw(o, ": "); }
static void kstr(Out *o, const char *k, const char *v, int first) { key(o, k, first); jstr(o, v); }
static void kaddr(Out *o, const char *k, uint64_t v, int first) { char b[32]; snprintf(b, sizeof b, "0x%llx", (unsigned long long)v); kstr(o, k, b, first); }

static const char *BOUNDARY =
    "The x86_64 slice of the artifact, read as bytes: conventional Objective-C metadata; objc2 0.6 "
    "CACHED_SEL/CACHED_CLASS statics and their fetch sites; literal sel_registerName/sel_getUid/"
    "NSSelectorFromString/objc_getClass-family producers; every call or jump to objc_msgSend, its _stret/"
    "_fpret/Super forms, objc_alloc and the objc_opt entry points, with receiver/selector/argument operands "
    "and BOOL path conditions from per-function value propagation over direct branches. Receivers close "
    "by measurement, the reviewed binding receipt, R2 type evidence, R3 positional evidence, a provider body's source receipt or downcast "
    "refinement; availability "
    "is the floor runtime capture (10.9.5) with the R1 root-method witness and cluster witnesses; guards "
    "need a measured respondsToSelector: and a reviewed build-bound record.";

#define LIMIT_ALONE "the shipped closure is the artifact alone: a non-system dependency is cannot-measure"
static const char *LIMITS[] = {
    "switch arms reached only through a jump table start with every value unknown",
    "a call a compiler merged from several paths' sends is read once per incoming path only when its block is entered "
    "by direct edges alone and every path names its selector and receiver; its result closes only when every path's does, alike",
    "code holding a frame address is assumed never to write below it",
    "a selector spilled to the frame is followed across a for-in loop's calls on the NSFastEnumeration contract: "
    "countByEnumeratingWithState:objects:count: writes only the state and buffer it is given",
    "no interprocedural tracking: results of out-of-line wrappers are unknown",
    "super sends are not modelled and stay unresolved",
    "classes made or reparented at run time (objc_allocateClassPair and its family) are refused by the reader, not modelled",
    "R1 on a receiver of unknown class counts the classes the artifact defines and those its captured dependencies bring; "
    "classes loaded later (bundles, plug-ins, input methods) are not measured",
    "dynamic method resolution and message forwarding on the floor are not modelled",
    "only the x86_64 slice is read; i386 is refused",
    "a send closed by R2, R3 or downcast does not close the sends that use its result; R3 closes only the sends a row names",
    "a send closed by a source receipt rests on the compiler's line-table attribution of its call instruction",
    LIMIT_ALONE,
    "a provider's registration is attested from its archive member's bytes, relocation targets and strings; "
    "its add-only runtime behaviour is the provider's own tested claim, not re-derived here",
};

/* ---- objc-api scoped deviations ------------------------------------------------------------
 * --exceptions FILE lists, one per line, "EVIDENCE<TAB>RECORD_ID<TAB>REVIEW_REASON": the reviewed
 * exception records that INGREDIENTS.md "- objc-api:<glob>: evidence=<file>#<id> <reason>"
 * declarations name for this artifact (scripts/assert_binary_compatible.sh resolves and scopes them
 * through the common deviation parser and matcher). EVIDENCE is schema 1, {"schema": 1, "kind":
 * "objc-exceptions", "records": [...]}, and the record with RECORD_ID has exactly these keys:
 *   id, artifact_glob             the record's own artifact scope, an fnmatch(3) glob that must
 *                                 also match the artifact path relative to --root and may not be
 *                                 wildcards alone
 *   class, kind, selector         the API: receiver class or null, "+"/"-" or null, selector; no
 *                                 wildcard characters
 *   finding {id, site, function}  the finding's deterministic id, site and function (or null)
 *   evidence {artifact_sha256, build_evidence_sha256, source_revision, patches_sha256}
 *                                 this artifact's digest, and the build evidence's digest and
 *                                 source identity, or null where this run has none
 *   basis {kind, proof}           kind guard, fallback or false-positive, with its proof
 *   reviewer, review_reason, retire_when   non-empty; review_reason is the declared reason
 * Anything else -- a missing, unknown or empty key, a wildcard, another basis, a reason that is not
 * the declared one, an absent record -- is cannot-measure. A record applies only to a blocking
 * (unsupported or unresolved) finding that matches every field; nothing else inherits it. The
 * finding keeps its verdict and is marked with the record id; strict mode no longer counts it as
 * blocking; the report lists every declared record with what it applied to, and stderr says so. */
typedef struct {
    char *evidence, *id, *reason, *glob, *cls, *kind, *sel, *fid, *site, *fn, *asha, *besha, *srcrev, *patches;
    char *basis, *proof, *reviewer, *retire, sha[65];
    char **applied; size_t n_applied;
} ObjcException;
static ObjcException *g_exc;
static size_t g_nexc;
static int g_have_exceptions;

static char *dup_or_null(NSString *s) { return s ? strdup([s UTF8String]) : NULL; }
static int has_wildcard(const char *s) { return strpbrk(s, "*?[") != NULL; }
static int nonempty(NSDictionary *d, NSString *k) { NSString *s = str(d, k); return s && [s length] > 0; }
/* A JSON string, or null when null_ok: 1 when well-formed, the value in *out (NULL for null). */
static int str_or_null(NSDictionary *d, NSString *k, int null_ok, NSString **out) {
    id v = [d objectForKey:k];
    *out = nil;
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) { *out = v; return 1; }
    return null_ok && v == [NSNull null];
}
static int same(const char *x, const char *y) { return (!x && !y) || (x && y && !strcmp(x, y)); }

static int load_exception(ObjcAnalysis *a, ObjcException *e, NSDictionary *r) {
    NSDictionary *fd, *ev, *ba;
    NSString *cls, *kind, *fn, *besha, *srcrev, *patches;
    const char *g;
    if (only_keys_as(a, "malformed-exception", r, "objc-api exception record", @[ @"id", @"artifact_glob", @"class", @"kind", @"selector", @"finding",
                                                         @"evidence", @"basis", @"reviewer", @"review_reason", @"retire_when" ]))
        return OBJC_CANNOT_MEASURE;
    if (!nonempty(r, @"artifact_glob") || !nonempty(r, @"selector") || !nonempty(r, @"reviewer") || !nonempty(r, @"review_reason") ||
        !nonempty(r, @"retire_when") || !str_or_null(r, @"class", 1, &cls) || !str_or_null(r, @"kind", 1, &kind) ||
        !(fd = obj(r, @"finding")) || !(ev = obj(r, @"evidence")) || !(ba = obj(r, @"basis")))
        return objc_fail(a, "malformed-exception", NULL, 0, "%s#%s: a required field is missing, empty or of the wrong type", e->evidence, e->id);
    if (only_keys_as(a, "malformed-exception", fd, "objc-api exception finding", @[ @"id", @"site", @"function" ]) ||
        only_keys_as(a, "malformed-exception", ev, "objc-api exception evidence", @[ @"artifact_sha256", @"build_evidence_sha256", @"source_revision", @"patches_sha256" ]) ||
        only_keys_as(a, "malformed-exception", ba, "objc-api exception basis", @[ @"kind", @"proof" ]))
        return OBJC_CANNOT_MEASURE;
    if (!nonempty(fd, @"id") || !nonempty(fd, @"site") || !str_or_null(fd, @"function", 1, &fn) || !nonempty(ev, @"artifact_sha256") ||
        !str_or_null(ev, @"build_evidence_sha256", 1, &besha) || !str_or_null(ev, @"source_revision", 1, &srcrev) ||
        !str_or_null(ev, @"patches_sha256", 1, &patches) || !nonempty(ba, @"kind") || !nonempty(ba, @"proof"))
        return objc_fail(a, "malformed-exception", NULL, 0, "%s#%s: its finding, evidence or basis is incomplete", e->evidence, e->id);
    if (strcmp(S(ba, @"kind"), "guard") && strcmp(S(ba, @"kind"), "fallback") && strcmp(S(ba, @"kind"), "false-positive"))
        return objc_fail(a, "malformed-exception", NULL, 0, "%s#%s: basis %s is not guard, fallback or false-positive", e->evidence, e->id, S(ba, @"kind"));
    if (kind && strcmp(cs(kind), "+") && strcmp(cs(kind), "-"))
        return objc_fail(a, "malformed-exception", NULL, 0, "%s#%s: kind %s is not + or -", e->evidence, e->id, cs(kind));
    g = S(r, @"artifact_glob");
    if (strspn(g, "*?[]/") == strlen(g) || has_wildcard(S(r, @"selector")) || (cls && has_wildcard(cs(cls))))
        return objc_fail(a, "malformed-exception", NULL, 0, "%s#%s: a wildcard scope or API; a record names one artifact and one finding", e->evidence, e->id);
    if (strcmp(S(r, @"review_reason"), e->reason))
        return objc_fail(a, "malformed-exception", NULL, 0, "%s#%s: its review_reason is not the declared reason \"%s\"", e->evidence, e->id, e->reason);
    e->glob = strdup(g); e->cls = dup_or_null(cls); e->kind = dup_or_null(kind); e->sel = dup_or_null(str(r, @"selector"));
    e->fid = dup_or_null(str(fd, @"id")); e->site = dup_or_null(str(fd, @"site")); e->fn = dup_or_null(fn);
    e->asha = dup_or_null(str(ev, @"artifact_sha256")); e->besha = dup_or_null(besha); e->srcrev = dup_or_null(srcrev);
    e->patches = dup_or_null(patches); e->basis = dup_or_null(str(ba, @"kind")); e->proof = dup_or_null(str(ba, @"proof"));
    e->reviewer = dup_or_null(str(r, @"reviewer")); e->retire = dup_or_null(str(r, @"retire_when"));
    return OBJC_OK;
}

static int load_exceptions(ObjcAnalysis *a, const char *list) {
    FILE *f = fopen(list, "r");
    char line[8192];
    if (!f) return objc_fail(a, "unreadable-input", NULL, 0, "exceptions %s: %s", list, strerror(errno));
    g_have_exceptions = 1;
    while (fgets(line, sizeof line, f)) {
        char *t1, *t2, *nl;
        ObjcException *e;
        NSDictionary *doc;
        NSDictionary *rec = nil;
        size_t n = strlen(line);
        if (!n || line[n - 1] != '\n' || !(t1 = strchr(line, '\t')) || !(t2 = strchr(t1 + 1, '\t')) || strchr(t2 + 1, '\t')) {
            fclose(f); return objc_fail(a, "malformed-input", NULL, 0, "exceptions %s: a line is not EVIDENCE<TAB>ID<TAB>REASON", list);
        }
        nl = line + n - 1; *nl = 0; *t1 = 0; *t2 = 0;
        if (!*line || !t1[1] || !t2[1] || !utf8_ok((const unsigned char *)line) || !utf8_ok((const unsigned char *)t2 + 1)) {
            fclose(f); return objc_fail(a, "malformed-input", NULL, 0, "exceptions %s: an empty or malformed field", list);
        }
        if (!(g_exc = realloc(g_exc, (g_nexc + 1) * sizeof *g_exc))) { fclose(f); return objc_fail(a, "out-of-memory", NULL, 0, "exceptions"); }
        e = &g_exc[g_nexc++];
        memset(e, 0, sizeof *e);
        e->evidence = strdup(line); e->id = strdup(t1 + 1); e->reason = strdup(t2 + 1);
        if (!(doc = read_json(a, e->evidence, JSON_MAX, "objc-api evidence"))) { fclose(f); return OBJC_CANNOT_MEASURE; }
        if (sha256_file(e->evidence, e->sha)) { fclose(f); return objc_fail(a, "unreadable-input", NULL, 0, "objc-api evidence %s", e->evidence); }
        if (only_keys_as(a, "malformed-exception", doc, "objc-api evidence", @[ @"schema", @"kind", @"records" ])) { fclose(f); return OBJC_CANNOT_MEASURE; }
        if (![[doc objectForKey:@"schema"] isEqual:@1] || ![str(doc, @"kind") isEqualToString:@"objc-exceptions"] || !arr(doc, @"records")) {
            fclose(f); return objc_fail(a, "malformed-exception", NULL, 0, "%s: not schema-1 objc-exceptions", e->evidence);
        }
        for (id r in arr(doc, @"records")) {
            if (![r isKindOfClass:[NSDictionary class]] || !str(r, @"id")) { fclose(f); return objc_fail(a, "malformed-exception", NULL, 0, "%s: a record without an id", e->evidence); }
            if (!strcmp(S(r, @"id"), e->id)) {
                if (rec) { fclose(f); return objc_fail(a, "malformed-exception", NULL, 0, "%s: record %s appears twice", e->evidence, e->id); }
                rec = r;
            }
        }
        if (!rec) { fclose(f); return objc_fail(a, "malformed-exception", NULL, 0, "%s has no record %s", e->evidence, e->id); }
        if (load_exception(a, e, rec)) { fclose(f); return OBJC_CANNOT_MEASURE; }
    }
    if (ferror(f)) { fclose(f); return objc_fail(a, "unreadable-input", NULL, 0, "exceptions %s", list); }
    fclose(f);
    return OBJC_OK;
}

/* Mark each blocking finding that a record names exactly; say what applied. */
static int apply_exceptions(ObjcAnalysis *a, const char *rel, const char *be_sha) {
    size_t i, k;
    for (k = 0; k < g_nexc; k++) {
        ObjcException *e = &g_exc[k];
        int scoped = fnmatch(e->glob, rel, 0) == 0;
        int digest = same(e->asha, a->artifact_sha256) && same(e->besha, be_sha) && same(e->srcrev, a->be_source_revision) &&
                     same(e->patches, a->be_patches_sha256);
        for (i = 0; scoped && digest && i < a->n_findings; i++) {
            ObjcFinding *f = &a->findings[i];
            const ObjcSend *s = &a->sends[f->send];
            const ObjcEvidence *ev = &a->evidence[s->evidence];
            char site[32];
            if (f->deviation || (f->verdict != OBJC_UNSUPPORTED && f->verdict != OBJC_UNRESOLVED)) continue;
            snprintf(site, sizeof site, "0x%llx", (unsigned long long)ev->address);
            if (strcmp(f->id, e->fid) || strcmp(site, e->site) || !same(ev->function, e->fn) || !same(s->selector, e->sel) ||
                !same(s->receiver, e->cls) || !same(s->method_kind, e->kind))
                continue;
            if (objc_set_string(&f->deviation, e->id) || objc_strv_push(&e->applied, &e->n_applied, f->id))
                return objc_fail(a, "out-of-memory", NULL, 0, "exceptions");
            fprintf(stderr, "objc-compat: deviation: %s applies to %s (%s, %s, reviewed by %s): %s\n", e->id, f->id,
                    objc_verdict_name(f->verdict), e->basis, e->reviewer, e->reason);
        }
        if (!e->n_applied)
            fprintf(stderr, "objc-compat: deviation: %s applies to no blocking finding (%s)\n", e->id,
                    !scoped ? "its artifact_glob does not match this artifact" : !digest ? "its evidence digests are not this build's"
                                                                                       : "no blocking finding is the one it names");
    }
    return OBJC_OK;
}

static void write_deviations(Out *o) {
    size_t k, i;
    key(o, "deviations", 0); raw(o, "[");
    for (k = 0; k < g_nexc; k++) {
        const ObjcException *e = &g_exc[k];
        raw(o, k ? ",\n  " : "\n  ");
        raw(o, "{"); kstr(o, "id", e->id, 1); kstr(o, "evidence_sha256", e->sha, 0); kstr(o, "artifact_glob", e->glob, 0);
        kstr(o, "basis", e->basis, 0); kstr(o, "proof", e->proof, 0); kstr(o, "reviewer", e->reviewer, 0);
        kstr(o, "review_reason", e->reason, 0); kstr(o, "retire_when", e->retire, 0);
        key(o, "applied_to", 0); raw(o, "[");
        for (i = 0; i < e->n_applied; i++) { if (i) raw(o, ", "); jstr(o, e->applied[i]); }
        raw(o, "]}");
    }
    raw(o, "]");
}

static void write_report(Out *o, ObjcAnalysis *a, const char *mode, const char *artifact_rel,
                         const char *manifest_sha, NSArray *ref_inputs, const char *be_path,
                         const char *be_sha, const char *analyzer_id, int complete) {
    size_t i, j;
    size_t closed[7] = {0}, verdicts[5] = {0}, r1 = 0;
    raw(o, "{"); key(o, "schema", 1); raw(o, "1");
    kstr(o, "mode", mode, 0);
    key(o, "complete_within_boundary", 0); raw(o, complete ? "true" : "false");
    kstr(o, "observation_boundary", BOUNDARY, 0);
    key(o, "limits", 0); raw(o, "[");
    for (i = 0; i < sizeof LIMITS / sizeof *LIMITS; i++) {
        if (i) raw(o, ", ");
        /* A report of one image keeps its bytes; a shipped closure says what it is and what it exempts. */
        if (a->n_shipped && !strcmp(LIMITS[i], LIMIT_ALONE)) {
            jstr(o, "the shipped closure is the artifact and the non-system images it loads, found inside the shipped root "
                    "through @rpath, @loader_path and @executable_path; one missing, outside the root, found twice, or loaded "
                    "weak, lazy or upward is cannot-measure");
            for (j = 0; j < a->n_shipped; j++) {
                char buf[4096];
                snprintf(buf, sizeof buf, "shipped image %s (sha256 %s) is measured by its interface: its classes, categories, "
                         "methods and loads close the artifact's sends into it; its own code is not read, exempt by these pinned bytes",
                         a->shipped[j].path, a->shipped[j].sha256);
                raw(o, ", "); jstr(o, buf);
            }
        } else jstr(o, LIMITS[i]);
    }
    raw(o, "]");
    /* The R1 amendment's accepted residual risk, present whenever a reviewed witness loaded. */
    key(o, "accepted_residual_risk", 0); raw(o, "[");
    if (a->n_r1_exceptions) {
        const char *frs = NULL;
        for (i = 0; i < [ref_inputs count]; i++)
            if ([str([ref_inputs objectAtIndex:i], @"name") isEqualToString:@"floor-runtime.tsv"])
                frs = cs(str([ref_inputs objectAtIndex:i], @"sha256"));
        raw(o, "{"); kstr(o, "kind", "r1-root-method-witness", 1);
        key(o, "witness", 0); raw(o, "{");
        kstr(o, "os", a->runtime_os, 1); kstr(o, "build", a->runtime_build, 0); kstr(o, "arch", a->runtime_arch, 0);
        kstr(o, "floor_runtime_sha256", frs, 0); kstr(o, "tool_source_sha256", a->runtime_tool_sha256, 0);
        raw(o, "}");
        key(o, "root_selectors", 0); raw(o, "[");
        for (i = 0; i < a->n_manifest_roots; i++) { if (i) raw(o, ", "); jstr(o, a->manifest_roots[i]); }
        raw(o, "]");
        key(o, "non_implementing_floor_classes", 0); raw(o, "[");
        for (i = 0; i < a->n_r1_exceptions; i++) { if (i) raw(o, ", "); jstr(o, a->r1_exceptions[i]); }
        raw(o, "]");
        key(o, "per_selector", 0); raw(o, "[");
        /* One entry per selector and set: a one-kind record (+class) splits its selector in two, the
         * recorded kind with its subset and the other kind with the six. */
        for (i = 0, j = 0; i < a->n_manifest_roots; i++) {
            const char *rec = objc_r1_subset_kinds(a, a->manifest_roots[i]), *p;
            const char *groups[2];
            size_t g, ng = 0;
            if (!rec || !strcmp(rec, "+-")) groups[ng++] = "+-";
            else { groups[ng++] = "+"; groups[ng++] = "-"; }
            for (g = 0; g < ng; g++) {
                char set[2048];
                if (j++) raw(o, ", ");
                raw(o, "{"); kstr(o, "selector", a->manifest_roots[i], 1);
                key(o, "kinds", 0); raw(o, "[");
                for (p = groups[g]; *p; p++) { char one[2] = {*p, 0}; if (p != groups[g]) raw(o, ", "); jstr(o, one); }
                raw(o, "]");
                key(o, "non_implementing_floor_classes", 0); raw(o, "[");
                objc_r1_selector_exceptions(a, groups[g][1] ? NULL : groups[g], a->manifest_roots[i], set, sizeof set);
                for (p = set; *p; ) {
                    size_t len = strcspn(p, " ");
                    char c[256];
                    snprintf(c, sizeof c, "%.*s", (int)len, p);
                    if (p != set) raw(o, ", ");
                    jstr(o, c);
                    p += len + (p[len] == ' ');
                }
                raw(o, "]}");
            }
        }
        raw(o, "]");
        kstr(o, "risk", "R1 closes a reviewed root-selector send on a receiver of unknown class from the witness's measured "
             "method existence, only when every class the artifact defines has an NSObject or NSProxy root and every dependency "
             "is in the floor capture (closure_class_roots); that receiver could be an instance of one of these floor classes, "
             "which do not resolve the root selectors", 0);
        raw(o, "}");
    }
    raw(o, "]");
    /* The measured fact R1 (b) rests on: the closure's own classes and their roots (classify.c). */
    key(o, "closure_class_roots", 0); raw(o, "{");
    for (i = 0, j = 0; i < a->n_evidence; i++) if (a->evidence[i].kind == OBJC_EV_CLASS_DEF) j++;
    key(o, "defined_classes", 1); fmt(o, "%zu", j);
    key(o, "roots", 0); raw(o, "{");
    for (i = 0; i < 2; i++) {
        const char *r = i ? "NSProxy" : "NSObject";
        size_t k, n = 0;
        for (k = 0; k < a->n_class_roots; k++) if (!strcmp(strchr(a->class_roots[k], '\t') + 1, r)) n++;
        key(o, r, !i); fmt(o, "%zu", n);
    }
    raw(o, "}");
    for (i = 0, j = 0; i < a->n_errors; i++) if (a->errors[i].code && !strcmp(a->errors[i].code, "runtime-class-creation")) j++;
    key(o, "runtime_class_creation_sites", 0); fmt(o, "%zu", j);
    key(o, "uncaptured_dependencies", 0); raw(o, "[");
    for (i = 0; i < a->n_uncaptured_deps; i++) { if (i) raw(o, ", "); jstr(o, a->uncaptured_deps[i]); }
    raw(o, "]");
    key(o, "blocking", 0); raw(o, "[");
    for (i = 0; i < a->n_roots_blocking; i++) { if (i) raw(o, ", "); jstr(o, a->roots_blocking[i]); }
    raw(o, "]");
    key(o, "r1_unknown_receivers", 0); raw(o, a->r1_unknown ? "true" : "false");
    raw(o, "}");
    key(o, "inputs", 0); raw(o, "{");
    key(o, "artifact", 1); raw(o, "{"); kstr(o, "path", artifact_rel, 1); kstr(o, "sha256", a->artifact_sha256, 0); raw(o, "}");
    if (a->n_shipped) {
        key(o, "shipped_images", 0); raw(o, "[");
        for (i = 0; i < a->n_shipped; i++) {
            if (i) raw(o, ", ");
            raw(o, "{"); kstr(o, "path", a->shipped[i].path, 1); kstr(o, "sha256", a->shipped[i].sha256, 0); raw(o, "}");
        }
        raw(o, "]");
    }
    /* No absolute path: the root, reference directory and evidence location differ between hosts
     * and clones, while the artifact path relative to the root and every hash do not. */
    key(o, "references", 0); raw(o, "{"); kstr(o, "manifest_sha256", manifest_sha[0] ? manifest_sha : NULL, 1);
    key(o, "files", 0); raw(o, "[");
    for (i = 0; i < [ref_inputs count]; i++) {
        NSDictionary *f = [ref_inputs objectAtIndex:i];
        if (i) raw(o, ", ");
        raw(o, "{"); kstr(o, "name", cs(str(f, @"name")), 1); kstr(o, "sha256", cs(str(f, @"sha256")), 0); raw(o, "}");
    }
    raw(o, "]}");
    key(o, "build_evidence", 0);
    if (be_path) { raw(o, "{"); kstr(o, "sha256", be_sha, 1);
                   kstr(o, "source_revision", a->be_source_revision, 0); kstr(o, "patches_sha256", a->be_patches_sha256, 0);
                   kstr(o, "features", a->be_features, 0); raw(o, "}"); }
    else raw(o, "null");
    if (a->src_sha256) { key(o, "source_receipt", 0); raw(o, "{"); kstr(o, "sha256", a->src_sha256, 1); raw(o, "}"); }
    kstr(o, "analyzer", analyzer_id, 0);
    kstr(o, "reader_profile", "objc2-0.6 caches; objc_msgSend family; x86_64", 0);
    key(o, "providers", 0); raw(o, "[");
    for (i = 0; i < a->n_providers; i++) {
        const ObjcProvider *p = &a->providers[i];
        if (i) raw(o, ", ");
        raw(o, "{"); kstr(o, "provider_id", p->provider_id, 1); kstr(o, "declaration_sha256", p->declaration_sha256, 0);
        kstr(o, "archive_sha256", p->archive_sha256, 0); raw(o, "}");
    }
    raw(o, "]");
    raw(o, "}");
    /* Artifacts: the one measured artifact, its dependencies, raw observations and the tallies. */
    for (i = 0; i < a->n_findings; i++) {
        const ObjcFinding *f = &a->findings[i];
        verdicts[f->verdict]++;
        closed[a->sends[f->send].origin]++;
        r1 += f->r1;
    }
    key(o, "artifacts", 0); raw(o, "[{");
    kstr(o, "path", artifact_rel, 1); kstr(o, "sha256", a->artifact_sha256, 0);
    key(o, "slices", 0); raw(o, a->n_evidence || a->n_dylibs ? "[\"x86_64\"]" : "[]");
    key(o, "dependencies", 0); raw(o, "[");
    for (i = 0; i < a->n_dylibs; i++) {
        const char *role = a->rt_image_role ? objc_floor_role(a, a->dylibs[i].path) : NULL;
        if (!role && a->n_shipped && !system_path(a->dylibs[i].path)) role = "shipped";
        raw(o, i ? ",\n    " : "\n    ");
        raw(o, "{"); kstr(o, "path", a->dylibs[i].path, 1); kstr(o, "load", a->dylibs[i].how, 0);
        kstr(o, "floor_runtime", role ? role : "not-captured", 0); raw(o, "}");
    }
    raw(o, "]");
    key(o, "providers", 0); raw(o, "[");
    for (i = 0; i < a->n_providers; i++) {
        const ObjcProvider *p = &a->providers[i];
        raw(o, i ? ",\n    " : "\n    ");
        raw(o, "{"); kstr(o, "provider_id", p->provider_id, 1); kstr(o, "status", p->active ? "active" : "inactive", 0);
        if (p->constructor) kaddr(o, "constructor", p->constructor, 0); else kstr(o, "constructor", NULL, 0);
        key(o, "verified_atoms", 0); fmt(o, "%zu", p->verified);
        kstr(o, "reason", p->reason, 0); raw(o, "}");
    }
    raw(o, "]");
    key(o, "observations", 0); raw(o, "[");
    for (i = 0, j = 0; i < a->n_evidence; i++) {
        const ObjcEvidence *e = &a->evidence[i];
        const char *sel = NULL, *kind = NULL;
        size_t sends = 0, k;
        if (e->kind == OBJC_EV_SEL_CACHE) { sel = e->selector; kind = "sel-cache"; }
        else if (e->kind == OBJC_EV_SEL_REGISTER) { sel = e->selector; kind = "sel-register"; }
        else if (e->kind == OBJC_EV_SELREF) { sel = e->selector; kind = "selref"; }
        else if (e->kind == OBJC_EV_DISPATCH_CALL && e->arg.form == OBJC_VAL_SEL_NSSTRING && e->arg.text) { sel = e->arg.text; kind = "selector-argument"; }
        if (!sel) continue;
        for (k = 0; k < a->n_sends; k++) if (a->sends[k].selector && !strcmp(a->sends[k].selector, sel)) sends++;
        raw(o, j++ ? ",\n    " : "\n    ");
        raw(o, "{"); kaddr(o, "address", e->address, 1); kstr(o, "kind", kind, 0); kstr(o, "selector", sel, 0);
        key(o, "sends_with_selector", 0); fmt(o, "%zu", sends);
        kstr(o, "later_in_newer_sdk", a->nw_later_sel ? objc_map_get(a->nw_later_sel, sel) : NULL, 0);
        raw(o, "}");
    }
    raw(o, "]");
    key(o, "summary", 0); raw(o, "{");
    key(o, "sends", 1); fmt(o, "%zu", a->n_sends);
    key(o, "verdicts", 0); raw(o, "{");
    for (i = 0; i < 5; i++) { key(o, objc_verdict_name((ObjcVerdict)i), !i); fmt(o, "%zu", verdicts[i]); }
    raw(o, "}");
    key(o, "receiver_closure", 0); raw(o, "{");
    key(o, "open", 1); fmt(o, "%zu", closed[OBJC_ORIGIN_OPEN]);
    key(o, "measured", 0); fmt(o, "%zu", closed[OBJC_ORIGIN_MEASURED]);
    key(o, "receipt", 0); fmt(o, "%zu", closed[OBJC_ORIGIN_RECEIPT]);
    key(o, "R2", 0); fmt(o, "%zu", closed[OBJC_ORIGIN_R2]);
    key(o, "downcast", 0); fmt(o, "%zu", closed[OBJC_ORIGIN_DOWNCAST]);
    key(o, "source", 0); fmt(o, "%zu", closed[OBJC_ORIGIN_SOURCE]);
    key(o, "R3", 0); fmt(o, "%zu", closed[OBJC_ORIGIN_R3]);
    raw(o, "}");
    key(o, "R1", 0); fmt(o, "%zu", r1);
    key(o, "unused_type_evidence", 0); raw(o, "[");
    for (i = 0, j = 0; i < a->n_types; i++) if (!a->types[i].used) { if (j++) raw(o, ", "); jstr(o, a->types[i].id); }
    raw(o, "]");
    key(o, "unused_position_evidence", 0); raw(o, "[");
    for (i = 0, j = 0; i < a->n_positions; i++) if (!a->positions[i].used) { if (j++) raw(o, ", "); jstr(o, a->positions[i].id); }
    raw(o, "]");
    key(o, "unused_guard_records", 0); raw(o, "[");
    for (i = 0, j = 0; i < a->n_guards; i++) if (!a->guards[i].used) { if (j++) raw(o, ", "); jstr(o, a->guards[i].id); }
    raw(o, "]");
    key(o, "undecoded_code_bytes", 0); fmt(o, "%llu", (unsigned long long)a->limit_undecoded_bytes);
    raw(o, "}}");
    /* Each shipped image: what loads it and how, its own loads, and its classes; its code is not read. */
    for (i = 0; i < a->n_shipped; i++) {
        const ObjcShipped *d = &a->shipped[i];
        raw(o, ",\n  {"); kstr(o, "path", d->path, 1); kstr(o, "sha256", d->sha256, 0);
        key(o, "slices", 0); raw(o, "[\"x86_64\"]");
        kstr(o, "loaded_by", a->image_paths[d->loader], 0); kstr(o, "load", d->how, 0); kstr(o, "install_name", d->install, 0);
        key(o, "dependencies", 0); raw(o, "[");
        for (j = 0; j < d->n_dylibs; j++) {
            const char *role = a->rt_image_role ? objc_floor_role(a, d->dylibs[j].path) : NULL;
            if (!role && !system_path(d->dylibs[j].path)) role = "shipped";
            raw(o, j ? ",\n    " : "\n    ");
            raw(o, "{"); kstr(o, "path", d->dylibs[j].path, 1); kstr(o, "load", d->dylibs[j].how, 0);
            kstr(o, "floor_runtime", role ? role : "not-captured", 0); raw(o, "}");
        }
        raw(o, "]");
        key(o, "defined_classes", 0); fmt(o, "%zu", d->classes);
        kstr(o, "own_code", "not read: exempt by its pinned bytes", 0);
        raw(o, "}");
    }
    raw(o, "]");
    key(o, "findings", 0); raw(o, "[");
    for (i = 0; i < a->n_findings; i++) {
        const ObjcFinding *f = &a->findings[i];
        const ObjcSend *s = &a->sends[f->send];
        const ObjcEvidence *e = &a->evidence[s->evidence];
        raw(o, i ? ",\n  " : "\n  ");
        raw(o, "{"); kstr(o, "id", f->id, 1); kstr(o, "path", artifact_rel, 0);
        if (a->n_shipped) kstr(o, "image", f->image ? a->image_paths[f->image - 1] : NULL, 0);
        kstr(o, "slice", e->slice, 0);
        kaddr(o, "site", e->address, 0);
        if (e->incoming) kaddr(o, "incoming", e->incoming, 0); else kstr(o, "incoming", NULL, 0);
        kstr(o, "function", e->function, 0);
        kstr(o, "evidence_kind", e->name, 0);
        kstr(o, "receiver", s->receiver, 0);
        key(o, "alternatives", 0);
        if (f->alternatives) {
            char *t = strdup(f->alternatives), *w, *save = NULL;
            int first = 1;
            raw(o, "[");
            for (w = t ? strtok_r(t, " ", &save) : NULL; w; w = strtok_r(NULL, " ", &save)) { if (!first) raw(o, ", "); jstr(o, w); first = 0; }
            raw(o, "]");
            free(t);
        } else raw(o, "[]");
        kstr(o, "method_kind", s->method_kind, 0); kstr(o, "selector", s->selector, 0);
        kstr(o, "framework", f->framework, 0);
        kstr(o, "source_provenance", s->provenance, 0);
        kstr(o, "receiver_closure", f->closure, 0);
        kstr(o, "receiver_basis", s->basis, 0);
        key(o, "r1", 0); raw(o, f->r1 ? "true" : "false");
        kstr(o, "verdict", objc_verdict_name(f->verdict), 0);
        kstr(o, "proof", f->proof, 0);
        if (f->deviation) kstr(o, "deviation", f->deviation, 0);
        raw(o, "}");
    }
    raw(o, "]");
    if (g_have_exceptions) write_deviations(o);
    key(o, "errors", 0); raw(o, "[");
    for (i = 0; i < a->n_errors; i++) {
        raw(o, i ? ",\n  " : "\n  ");
        raw(o, "{"); kstr(o, "code", a->errors[i].code, 1); kstr(o, "slice", a->errors[i].slice, 0);
        kaddr(o, "address", a->errors[i].address, 0); kstr(o, "detail", a->errors[i].detail, 0); raw(o, "}");
    }
    raw(o, "]}\n");
}

/* Exclusive, atomic, durable: a temporary beside the destination, then link(2). */
static int publish(const char *dest, const Out *o) {
    char dir[PATH_MAX], tmp[PATH_MAX];
    const char *slash = strrchr(dest, '/'), *base = slash ? slash + 1 : dest;
    int fd;
    size_t off = 0;
    if (slash) snprintf(dir, sizeof dir, "%.*s", (int)(slash - dest), dest); else snprintf(dir, sizeof dir, ".");
    if (!*dir) snprintf(dir, sizeof dir, "/");
    if (snprintf(tmp, sizeof tmp, "%s/.%s.tmp.XXXXXX", dir, base) >= (int)sizeof tmp) return -1;
    if ((fd = mkstemp(tmp)) < 0) { fprintf(stderr, "objc-compat: cannot create a temporary in %s: %s\n", dir, strerror(errno)); return -1; }
    while (off < o->n) {
        ssize_t w = write(fd, o->b + off, o->n - off);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) { fprintf(stderr, "objc-compat: writing %s: %s\n", tmp, strerror(errno)); close(fd); unlink(tmp); return -1; }
        off += (size_t)w;
    }
    if (fsync(fd) != 0 || close(fd) != 0) { fprintf(stderr, "objc-compat: flushing %s: %s\n", tmp, strerror(errno)); unlink(tmp); return -1; }
    if (link(tmp, dest) != 0) { fprintf(stderr, "objc-compat: %s: %s (not replaced)\n", dest, strerror(errno)); unlink(tmp); return -1; }
    unlink(tmp);
    return 0;
}

/* ---- subcommands ---------------------------------------------------------------------------------- */

/* Parse "--name value" pairs into vals (in the order of names); 2 on misuse. */
static int pairs(int argc, char **argv, const char **names, size_t n, const char **vals, const char *what) {
    int i;
    size_t k;
    for (k = 0; k < n; k++) vals[k] = NULL;
    for (i = 1; i < argc; i += 2) {
        for (k = 0; k < n && strcmp(argv[i], names[k]); k++) ;
        if (k == n || i + 1 >= argc || !*argv[i + 1] || vals[k]) { fprintf(stderr, "objc-compat %s: unknown, repeated or empty option %s\n", what, argv[i]); return 2; }
        vals[k] = argv[i + 1];
    }
    return 0;
}

static int control_free(const char *s) {
    for (; *s; s++) if ((unsigned char)*s < 0x20 || *s == 0x7f) return 0;
    return 1;
}

static void print_errors(ObjcAnalysis *a) {
    size_t k;
    for (k = 0; k < a->n_errors; k++) fprintf(stderr, "objc-compat: %s: %s\n", a->errors[k].code, a->errors[k].detail ? a->errors[k].detail : "");
}

/* provider-link-args --prefix PREFIX --link-map FILE (scripts/objc-provider-link-args.sh). */
static int link_args_main(int argc, char **argv) {
    static const char *NAMES[] = { "--prefix", "--link-map" };
    const char *v[2];
    ObjcAnalysis *a;
    NSMutableArray *out = [NSMutableArray array];
    size_t i, j;
    if (pairs(argc, argv, NAMES, 2, v, "provider-link-args") || !v[0] || !v[1]) {
        fprintf(stderr, "usage: objc-compat provider-link-args --prefix PREFIX --link-map FILE\n");
        return 2;
    }
    if (!control_free(v[0]) || !control_free(v[1]) || !utf8_ok((const unsigned char *)v[0]) || !utf8_ok((const unsigned char *)v[1])) {
        fprintf(stderr, "objc-compat provider-link-args: a path with a control character (CR, LF, ...) or bad UTF-8 cannot be one argument per line\n");
        return 2;
    }
    if (!(a = objc_analysis_create())) return 4;
    if (load_provider_prefix(a, v[0]) || !a->n_providers) {
        print_errors(a);
        if (!a->n_errors) fprintf(stderr, "objc-compat provider-link-args: %s declares no provider\n", v[0]);
        objc_analysis_destroy(a);
        return 4;
    }
    for (i = 0; i < a->n_providers; i++) {
        NSString *x = [NSString stringWithUTF8String:a->providers[i].archive];
        if (!control_free(a->providers[i].archive)) { objc_analysis_destroy(a); return 2; }
        if (![out containsObject:x]) [out addObject:x];
    }
    for (i = 0; i < a->n_providers; i++) {
        NSString *x = [NSString stringWithFormat:@"-Wl,-u,_%s", a->providers[i].root_symbol];
        if (![out containsObject:x]) [out addObject:x];
    }
    {
        NSMutableArray *fws = [NSMutableArray array];
        for (i = 0; i < a->n_providers; i++)
            for (j = 0; j < a->providers[i].nframeworks; j++) {
                NSString *f = [NSString stringWithUTF8String:a->providers[i].frameworks[j]];
                if (![fws containsObject:f]) { [fws addObject:f]; [out addObject:@"-framework"]; [out addObject:f]; }
            }
    }
    [out addObjectsFromArray:@[ @"-Xlinker", @"-map", @"-Xlinker", [NSString stringWithUTF8String:v[1]] ]];
    for (NSString *x in out) printf("%s\n", [x UTF8String]);
    objc_analysis_destroy(a);
    return fflush(stdout) || ferror(stdout) ? 4 : 0;
}

/* The prepared source tree's identity: every entry under dir except .git, sorted, with file
 * contents' SHA-256 and symlink targets; any other file type is refused. */
static int tree_digest(ObjcAnalysis *a, const char *dir, char out[65]) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [NSString stringWithUTF8String:dir];
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
    NSMutableArray *entries = [NSMutableArray array];
    NSString *rel;
    CC_SHA256_CTX c;
    unsigned char d[CC_SHA256_DIGEST_LENGTH];
    int i;
    if (!en) return objc_fail(a, "unreadable-input", NULL, 0, "source root %s", dir);
    while ((rel = [en nextObject])) {
        NSString *full = [root stringByAppendingPathComponent:rel];
        struct stat st;
        char h[65];
        if ([[rel lastPathComponent] isEqualToString:@".git"]) { [en skipDescendants]; continue; }
        if ([entries count] > 1000000) return objc_fail(a, "oversized-input", NULL, 0, "source root %s: over a million entries", dir);
        if (lstat([full fileSystemRepresentation], &st) != 0) return objc_fail(a, "unreadable-input", NULL, 0, "%s", [full UTF8String]);
        if (S_ISDIR(st.st_mode)) [entries addObject:[NSString stringWithFormat:@"d %@", rel]];
        else if (S_ISLNK(st.st_mode)) {
            NSString *t = [fm destinationOfSymbolicLinkAtPath:full error:NULL];
            if (!t) return objc_fail(a, "unreadable-input", NULL, 0, "%s", [full UTF8String]);
            [entries addObject:[NSString stringWithFormat:@"l %@ %@", rel, t]];
        } else if (S_ISREG(st.st_mode)) {
            if (sha256_file([full fileSystemRepresentation], h)) return objc_fail(a, "unreadable-input", NULL, 0, "%s", [full UTF8String]);
            [entries addObject:[NSString stringWithFormat:@"f %@ %s", rel, h]];
        } else return objc_fail(a, "unreadable-input", NULL, 0, "%s is not a file, directory or symlink", [full UTF8String]);
    }
    [entries sortUsingSelector:@selector(compare:)];
    CC_SHA256_Init(&c);
    for (NSString *e in entries) { const char *s = [e UTF8String]; CC_SHA256_Update(&c, s, (CC_LONG)strlen(s)); CC_SHA256_Update(&c, "\n", 1); }
    CC_SHA256_Final(d, &c);
    for (i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(out + 2 * i, 3, "%02x", d[i]);
    return OBJC_OK;
}

/* emit-build-evidence (scripts/objc-build-evidence.sh): schema-1 evidence of what was linked. It
 * records identities and the provider link mapping it checked; it approves nothing -- the
 * analyzer re-verifies all of it against the artifact's bytes. */
static int build_evidence_main(int argc, char **argv) {
    static const char *NAMES[] = { "--artifact", "--prestrip", "--source-root", "--link-map", "--provider-prefix", "--references", "--output" };
    const char *v[7];
    char fsha[65], psha[65], msha[65], tsha[65], manifest_sha[65], dir[PATH_MAX];
    const char *slash;
    struct stat st;
    ObjcAnalysis *a;
    NSMutableArray *ref_inputs = [NSMutableArray array];
    Out o;
    size_t i, j;
    int rc = OBJC_OK;
    if (pairs(argc, argv, NAMES, 7, v, "emit-build-evidence")) return 2;
    for (i = 0; i < 7; i++)
        if (!v[i] && i != 3 && i != 4) { fprintf(stderr, "objc-compat emit-build-evidence: %s is required\n", NAMES[i]); return 2; }
    /* No provider (neither flag): no link map to read and nothing to map. */
    if (!v[3] != !v[4]) { fprintf(stderr, "objc-compat emit-build-evidence: --link-map and --provider-prefix go together\n"); return 2; }
    if (lstat(v[6], &st) == 0 || errno != ENOENT) { fprintf(stderr, "objc-compat emit-build-evidence: %s exists; it is never replaced\n", v[6]); return 2; }
    slash = strrchr(v[6], '/');
    if (slash) snprintf(dir, sizeof dir, "%.*s", (int)(slash - v[6]), v[6]); else snprintf(dir, sizeof dir, ".");
    if (!*dir) snprintf(dir, sizeof dir, "/");
    if (stat(dir, &st) != 0 || !S_ISDIR(st.st_mode)) { fprintf(stderr, "objc-compat emit-build-evidence: %s is not a directory\n", dir); return 2; }
    if (!(a = objc_analysis_create())) return 4;
    if (sha256_file(v[0], fsha)) rc = objc_fail(a, "unreadable-input", NULL, 0, "artifact %s", v[0]);
    else if (sha256_file(v[1], psha)) rc = objc_fail(a, "unreadable-input", NULL, 0, "prestrip %s", v[1]);
    else if (v[3] && sha256_file(v[3], msha)) rc = objc_fail(a, "unreadable-input", NULL, 0, "link map %s: %s", v[3], strerror(errno));
    if (!rc) rc = load_manifest(a, v[5], ref_inputs, manifest_sha);
    if (!rc) rc = tree_digest(a, v[2], tsha);
    if (!rc && v[4]) rc = load_provider_prefix(a, v[4]);
    if (!rc && v[4]) rc = objc_map_provider_link(a, v[0], v[1], v[3]);
    if (rc || a->n_errors) { print_errors(a); objc_analysis_destroy(a); return 4; }
    memset(&o, 0, sizeof o);
    raw(&o, "{"); key(&o, "schema", 1); raw(&o, "1"); kstr(&o, "kind", "objc-build-evidence", 0);
    key(&o, "artifact", 0); raw(&o, "{"); kstr(&o, "sha256", fsha, 1); raw(&o, "}");
    key(&o, "prestrip", 0); raw(&o, "{"); kstr(&o, "sha256", psha, 1); raw(&o, "}");
    if (v[3]) { key(&o, "link_map", 0); raw(&o, "{"); kstr(&o, "sha256", msha, 1); raw(&o, "}"); }
    key(&o, "references", 0); raw(&o, "{"); kstr(&o, "manifest_sha256", manifest_sha, 1); raw(&o, "}");
    key(&o, "source", 0); raw(&o, "{"); kstr(&o, "tree_sha256", tsha, 1); kstr(&o, "revision", NULL, 0);
    kstr(&o, "patches_sha256", NULL, 0); kstr(&o, "features", NULL, 0); raw(&o, "}");
    key(&o, "providers", 0); raw(&o, "[");
    for (i = 0; i < a->n_providers; i++) {
        const ObjcProvider *p = &a->providers[i];
        raw(&o, i ? ",\n " : "\n ");
        raw(&o, "{"); kstr(&o, "provider_id", p->provider_id, 1); kstr(&o, "declaration_sha256", p->declaration_sha256, 0);
        kstr(&o, "archive_sha256", p->archive_sha256, 0);
        key(&o, "members", 0); raw(&o, "[");
        for (j = 0; j < p->n_members; j++) {
            if (j) raw(&o, ", ");
            raw(&o, "{"); kstr(&o, "name", p->members[j].name, 1); kstr(&o, "sha256", p->members[j].sha256, 0); raw(&o, "}");
        }
        raw(&o, "]"); key(&o, "atoms", 0); raw(&o, "[");
        for (j = 0; j < p->n_atoms; j++) {
            raw(&o, j ? ",\n  " : "\n  ");
            raw(&o, "{"); kstr(&o, "member", p->atoms[j].member, 1); kstr(&o, "symbol", p->atoms[j].symbol, 0);
            kaddr(&o, "address", p->atoms[j].address, 0); key(&o, "size", 0); fmt(&o, "%llu", (unsigned long long)p->atoms[j].size);
            raw(&o, "}");
        }
        raw(&o, "]}");
    }
    raw(&o, "]}\n");
    objc_analysis_destroy(a);
    if (o.bad) { fprintf(stderr, "objc-compat emit-build-evidence: %s\n", o.why); free(o.b); return 4; }
    rc = publish(v[6], &o) ? 4 : 0;
    free(o.b);
    return rc;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *artifact = NULL, *root = NULL, *refs = NULL, *report = NULL, *evidence = NULL, *mode = "inventory";
        const char *analyzer_id = "unidentified";
        char rart[PATH_MAX], rroot[PATH_MAX], rrefs[PATH_MAX], manifest_sha[65] = "", be_sha[65] = "";
        const char *rel;
        struct stat st;
        ObjcAnalysis *a;
        NSMutableArray *ref_inputs = [NSMutableArray array];
        int i, rc = OBJC_OK, blocking = 0;
        size_t k;
        Out o;
        int seen[10] = {0};
        const char *prefix = NULL, *receipt = NULL, *exceptions = NULL;
        static const char *OPT[] = { "--artifact", "--root", "--references", "--report", "--build-evidence", "--mode", "--analyzer-id",
                                     "--provider-prefix", "--source-receipt", "--exceptions" };
        if (argc > 1 && !strcmp(argv[1], "provider-link-args")) return link_args_main(argc - 1, argv + 1);
        if (argc > 1 && !strcmp(argv[1], "emit-build-evidence")) return build_evidence_main(argc - 1, argv + 1);
        for (i = 1; i < argc; i++) {
            int n;
            for (n = 0; n < 10 && strcmp(argv[i], OPT[n]); n++) ;
            if (n == 10) return usage("unknown argument");
            if (i + 1 >= argc || !*argv[i + 1]) return usage("option without a value");
            if (seen[n]++) return usage("option given twice");
            switch (n) {
            case 0: artifact = argv[++i]; break;
            case 1: root = argv[++i]; break;
            case 2: refs = argv[++i]; break;
            case 3: report = argv[++i]; break;
            case 4: evidence = argv[++i]; break;
            case 5: mode = argv[++i]; break;
            case 6: analyzer_id = argv[++i]; break;
            case 7: prefix = argv[++i]; break;
            case 8: receipt = argv[++i]; break;
            default: exceptions = argv[++i]; break;
            }
        }
        if (!artifact || !root || !refs || !report) return usage("--artifact, --root, --references and --report are required");
        if (strcmp(mode, "inventory") && strcmp(mode, "strict")) return usage("--mode is inventory or strict");
        if (receipt && (!prefix || !evidence)) return usage("--source-receipt needs --provider-prefix and --build-evidence");
        if (lstat(report, &st) == 0) return usage("the report destination already exists; it is never replaced");
        if (errno != ENOENT) return usage("the report destination's directory is not usable");
        {
            char dir[PATH_MAX];
            const char *slash = strrchr(report, '/');
            if (slash) snprintf(dir, sizeof dir, "%.*s", (int)(slash - report), report); else snprintf(dir, sizeof dir, ".");
            if (!*dir) snprintf(dir, sizeof dir, "/");
            if (stat(dir, &st) != 0 || !S_ISDIR(st.st_mode)) return usage("the report destination's directory does not exist");
        }
        if (!realpath(root, rroot) || stat(rroot, &st) != 0 || !S_ISDIR(st.st_mode)) return usage("--root is not a directory");
        if (!realpath(artifact, rart)) {
            fprintf(stderr, "objc-compat: %s: %s\n", artifact, strerror(errno));
            return errno == ENOENT ? usage("--artifact does not exist") : 4;
        }
        k = strlen(rroot);
        if (strncmp(rart, rroot, k) || (rart[k] != '/' && strcmp(rroot, "/"))) return usage("--artifact is not inside --root");
        rel = rart + k + (strcmp(rroot, "/") ? 1 : 0);
        if (!realpath(refs, rrefs)) return usage("--references is not a directory");
        if (!utf8_ok((const unsigned char *)rart) || !utf8_ok((const unsigned char *)rrefs)) return usage("paths must be UTF-8");

        if (!(a = objc_analysis_create()) || objc_set_string(&a->artifact_path, rart)) { fprintf(stderr, "objc-compat: out of memory\n"); return 4; }
        {
            char h[65];
            if (sha256_file(rart, h)) rc = objc_fail(a, "unreadable-artifact", NULL, 0, "%s: %s", rart, strerror(errno));
            else if (objc_set_string(&a->artifact_sha256, h)) rc = OBJC_CANNOT_MEASURE;
        }
        if (!rc) rc = load_manifest(a, rrefs, ref_inputs, manifest_sha);
        if (!rc) rc = load_clusters(a, rrefs);
        if (!rc && prefix) rc = load_provider_prefix(a, prefix);
        if (!rc && evidence) {
            if (sha256_file(evidence, be_sha)) rc = objc_fail(a, "unreadable-input", NULL, 0, "build evidence %s", evidence);
            else rc = load_build_evidence(a, evidence, manifest_sha);
        }
        if (!rc && receipt) rc = objc_load_source_receipt(a, receipt);
        if (!rc && exceptions) rc = load_exceptions(a, exceptions);
        if (!rc) rc = objc_load_references(a);
        if (!rc) rc = objc_load_reference_set(a);
        if (!rc) rc = objc_collect_artifacts(a);
        if (!rc) rc = shipped_closure(a, rroot, rel);
        if (!rc) {
            /* Providers first: a source receipt maps only into verified provider code. Sends are
             * classified even when verification fails, so the report still lists them. */
            int rv = objc_verify_providers(a);
            rc = objc_classify_findings(a);
            if (!rc) rc = rv;
            if (!rc) rc = objc_provide_findings(a);
        }
        if (!rc && exceptions) rc = apply_exceptions(a, rel, evidence ? be_sha : NULL);
        if (a->n_errors) rc = OBJC_CANNOT_MEASURE;
        for (k = 0; k < a->n_findings; k++)
            if ((a->findings[k].verdict == OBJC_UNSUPPORTED || a->findings[k].verdict == OBJC_UNRESOLVED) && !a->findings[k].deviation) blocking = 1;
        memset(&o, 0, sizeof o);
        write_report(&o, a, mode, rel, manifest_sha, ref_inputs, evidence, evidence ? be_sha : NULL, analyzer_id, rc == OBJC_OK);
        if (o.bad) {
            fprintf(stderr, "objc-compat: no report written: %s\n", o.why);
            free(o.b); objc_analysis_destroy(a);
            return 4;
        }
        if (publish(report, &o)) { free(o.b); objc_analysis_destroy(a); return 4; }
        free(o.b);
        /* Strict names what blocks it, so a caller (scripts/assert_binary_compatible.sh) can say why
         * without parsing the report. */
        if (!strcmp(mode, "strict"))
            for (k = 0; k < a->n_findings; k++)
                if ((a->findings[k].verdict == OBJC_UNSUPPORTED || a->findings[k].verdict == OBJC_UNRESOLVED) && !a->findings[k].deviation)
                    fprintf(stderr, "objc-compat: blocking: %s %s: %s\n", a->findings[k].id, objc_verdict_name(a->findings[k].verdict),
                            a->findings[k].proof ? a->findings[k].proof : "");
        for (k = 0; k < a->n_errors; k++)
            fprintf(stderr, "objc-compat: %s: %s\n", a->errors[k].code, a->errors[k].detail ? a->errors[k].detail : "");
        objc_analysis_destroy(a);
        if (rc) return 4;
        return !strcmp(mode, "strict") && blocking ? 1 : 0;
    }
}
