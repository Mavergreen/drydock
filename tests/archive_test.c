/*
 * tests/archive_test.c -- hermetic tests for src/archive.c.
 *
 * Archives are built in memory in the two layouts the 10.9 tools write:
 * LIBTOOL (libtool -static, ranlib, and ar once it has run ranlib) and BSD
 * (ar -S). The index bytes in libtool_10_9_index_bytes are 10.9 libtool's own.
 */
#include "archive.h"
#include "rewrite.h"

#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static int fails = 0;
#define CHECK(cond, msg, ...) do { if (!(cond)) { \
    printf("FAIL: " msg "\n", ##__VA_ARGS__); fails++; } } while (0)

/* A minimal x86_64 MH_OBJECT: every name in `defs` defined external (N_ABS;
 * "" is n_strx 0), plus a local, a common and an undefined symbol that no
 * index includes. */
static uint8_t *mobj(const char *const *defs, size_t *size) {
    const char *names[16];
    uint8_t types[16];
    uint64_t values[16];
    int n = 0;
    names[n] = "_local"; types[n] = N_ABS; values[n++] = 0;
    for (int i = 0; defs && defs[i]; i++) { names[n] = defs[i]; types[n] = N_ABS | N_EXT; values[n++] = 0; }
    names[n] = "_comm"; types[n] = N_UNDF | N_EXT; values[n++] = 8;
    names[n] = "_undef"; types[n] = N_UNDF | N_EXT; values[n++] = 0;

    size_t lcs = sizeof(struct segment_command_64) + sizeof(struct symtab_command);
    size_t symoff = sizeof(struct mach_header_64) + lcs;
    size_t stroff = symoff + (size_t)n * sizeof(struct nlist_64);
    size_t strsize = 1;
    for (int i = 0; i < n; i++) strsize += strlen(names[i]) + 1;
    strsize = (strsize + 7) & ~(size_t)7;
    *size = stroff + strsize;
    uint8_t *b = calloc(1, *size);
    struct mach_header_64 *h = (struct mach_header_64 *)b;
    h->magic = MH_MAGIC_64; h->cputype = 0x01000007; h->cpusubtype = 3;
    h->filetype = MH_OBJECT; h->ncmds = 2; h->sizeofcmds = (uint32_t)lcs;
    struct segment_command_64 *sg = (struct segment_command_64 *)(b + sizeof *h);
    sg->cmd = LC_SEGMENT_64; sg->cmdsize = sizeof *sg;
    struct symtab_command *st = (struct symtab_command *)(sg + 1);
    st->cmd = LC_SYMTAB; st->cmdsize = sizeof *st;
    st->symoff = (uint32_t)symoff; st->nsyms = (uint32_t)n;
    st->stroff = (uint32_t)stroff; st->strsize = (uint32_t)strsize;
    size_t used = 1;
    for (int i = 0; i < n; i++) {
        struct nlist_64 nl; memset(&nl, 0, sizeof nl);
        nl.n_un.n_strx = names[i][0] ? (uint32_t)used : 0; nl.n_type = types[i]; nl.n_value = values[i];
        memcpy(b + symoff + (size_t)i * sizeof nl, &nl, sizeof nl);
        if (!names[i][0]) continue;
        strcpy((char *)b + stroff + used, names[i]);
        used += strlen(names[i]) + 1;
    }
    return b;
}

typedef struct {
    const char *name;
    const uint8_t *data;
    size_t size;
    const char *syms[4];    /* the defined externals, for the index */
    size_t pad_to;          /* LIBTOOL: data padded with '\n' to this size, if larger */
} mem;

enum { LIBTOOL, BSD };

typedef struct { uint8_t *buf; size_t size; size_t hdr[16]; size_t ihdr; } arc;

static const char *idx_name(int kind) {
    switch (kind) {
    case MAR_IDX_32: return "__.SYMDEF";
    case MAR_IDX_32_SORTED: return "__.SYMDEF SORTED";
    case MAR_IDX_64: return "__.SYMDEF_64";
    case MAR_IDX_64_SORTED: return "__.SYMDEF_64 SORTED";
    default: return NULL;
    }
}

static size_t rnd(size_t v, size_t a) { return (v + a - 1) / a * a; }

static void put_hdr(uint8_t *p, const char *name16, const char *date, const char *uid,
                    const char *gid, size_t size) {
    char h[61];
    snprintf(h, sizeof h, "%-16s%-12s%-6s%-6s%-8s%-10zu`\n", name16, date, uid, gid, "100644", size);
    memcpy(p, h, 60);
}

typedef struct { const char *s; size_t member; size_t seq; } ent;
static int ent_cmp(const void *a, const void *b) {
    const ent *x = a, *y = b;
    int c = strcmp(x->s, y->s);
    return c ? c : (x->seq < y->seq ? -1 : 1);
}

static void put_le(uint8_t *p, uint64_t v, int w) { for (int i = 0; i < w; i++) p[i] = (uint8_t)(v >> (8 * i)); }
static uint64_t get_le(const uint8_t *p, int w) { uint64_t v = 0; for (int i = w - 1; i >= 0; i--) v = v << 8 | p[i]; return v; }

/* Lays the members out as `style` does, with an index of `kind` built the
 * way ranlib builds one. */
static arc build(int style, int kind, const mem *ms, int n) {
    arc a; memset(&a, 0, sizeof a);
    ent es[64]; size_t ne = 0, raw = 0;
    for (int i = 0; i < n; i++)
        for (int j = 0; ms[i].syms[j]; j++) {
            es[ne].s = ms[i].syms[j]; es[ne].member = (size_t)i; es[ne].seq = ne;
            raw += strlen(ms[i].syms[j]) + 1; ne++;
        }
    int w = (kind == MAR_IDX_64 || kind == MAR_IDX_64_SORTED) ? 8 : 4;
    const char *iname = idx_name(kind);
    size_t inl = 0, isize = 0, strsize = 0;
    size_t off = 8;
    if (iname) {
        inl = rnd(strlen(iname), 8) + 4;
        size_t fixed = 8 + 60 + inl + (size_t)w + ne * 2 * (size_t)w + (size_t)w;
        strsize = rnd(fixed + raw, 8) - fixed;
        isize = inl + (size_t)w + ne * 2 * (size_t)w + (size_t)w + strsize;
        a.ihdr = 8;
        off = 8 + 60 + isize;
    }
    size_t sizes[16], nls[16], datas[16], pads[16];
    for (int i = 0; i < n; i++) {
        size_t len = strlen(ms[i].name);
        if (style == LIBTOOL) nls[i] = rnd(len, 8) + 4;
        else nls[i] = (len > 16 || strchr(ms[i].name, ' ')) ? rnd(len, 4) : 0;
        datas[i] = ms[i].size;
        if (style == LIBTOOL) {
            if (ms[i].pad_to > datas[i]) datas[i] = ms[i].pad_to;
            datas[i] = rnd(off + 60 + nls[i] + datas[i], 8) - (off + 60 + nls[i]);
        }
        sizes[i] = nls[i] + datas[i];
        pads[i] = (off + 60 + sizes[i]) % 2;
        a.hdr[i] = off;
        off += 60 + sizes[i] + pads[i];
    }
    a.size = off;
    a.buf = calloc(1, a.size);
    memcpy(a.buf, "!<arch>\n", 8);
    if (iname) {
        uint8_t *p = a.buf + 8;
        char nm[32]; snprintf(nm, sizeof nm, "#1/%zu", inl);
        put_hdr(p, nm, "1791260698", "501", "20", isize);
        memcpy(p + 60, iname, strlen(iname));
        uint8_t *q = p + 60 + inl;
        put_le(q, ne * 2 * (size_t)w, w); q += w;
        size_t strx[64], at = 0;
        for (size_t e = 0; e < ne; e++) { strx[e] = at; at += strlen(es[e].s) + 1; }
        ent sorted[64]; memcpy(sorted, es, sizeof(ent) * ne);
        if (kind == MAR_IDX_32_SORTED || kind == MAR_IDX_64_SORTED) qsort(sorted, ne, sizeof(ent), ent_cmp);
        for (size_t e = 0; e < ne; e++) {
            put_le(q, strx[sorted[e].seq], w); q += w;
            put_le(q, a.hdr[sorted[e].member], w); q += w;
        }
        put_le(q, strsize, w); q += w;
        for (size_t e = 0; e < ne; e++) { strcpy((char *)q, es[e].s); q += strlen(es[e].s) + 1; }
    }
    for (int i = 0; i < n; i++) {
        uint8_t *p = a.buf + a.hdr[i];
        char nm[32];
        if (nls[i]) snprintf(nm, sizeof nm, "#1/%zu", nls[i]); else snprintf(nm, sizeof nm, "%s", ms[i].name);
        put_hdr(p, nm, "1791260693", "501", "0", sizes[i]);
        if (nls[i]) memcpy(p + 60, ms[i].name, strlen(ms[i].name));
        memcpy(p + 60 + nls[i], ms[i].data, ms[i].size);
        memset(p + 60 + nls[i] + ms[i].size, '\n', datas[i] - ms[i].size);
        if (pads[i]) p[60 + sizes[i]] = '\n';
    }
    return a;
}

static int identity(uint8_t **pbuf, size_t *psize, const mar_member *m, void *ctx) {
    (void)pbuf; (void)psize; (void)m;
    if (ctx) (*(int *)ctx)++;
    return 0;
}

static char rewrite_why[256];

static int rewrite_copy(const arc *a, mar_member_fn fn, void *ctx, uint8_t **out, size_t *outsize) {
    uint8_t *b = malloc(a->size);
    memcpy(b, a->buf, a->size);
    size_t s = a->size;
    rewrite_why[0] = '\0';
    int rc = mar_rewrite(&b, &s, fn, ctx, rewrite_why, sizeof rewrite_why);
    *out = b; *outsize = s;
    return rc;
}

/* The objects most tests share. */
static uint8_t *oa, *ob, *oc;
static size_t sa, sb, sc;
static const uint8_t text11[] = "hello\n odd!";   /* 11 bytes: odd */

static void test_parse_sorted_with_long_name(void) {
    mem ms[] = {
        { "a_longer_name.o", oa, sa, { "_a", NULL }, 0 },
        { "b.o", ob, sb, { "_b", NULL }, 0 },
    };
    arc a = build(LIBTOOL, MAR_IDX_32_SORTED, ms, 2);
    mar_archive ar; char why[256] = "";
    int rc = mar_parse(a.buf, a.size, &ar, why, sizeof why);
    CHECK(rc == 0, "parse: rc %d (%s)", rc, why);
    if (rc == 0) {
        CHECK(ar.n == 3, "parse: %zu members", ar.n);
        CHECK(ar.index_kind == MAR_IDX_32_SORTED, "parse: index kind %d", ar.index_kind);
        CHECK(ar.m[0].is_index && strcmp(ar.m[0].name, "__.SYMDEF SORTED") == 0, "parse: index name '%s'", ar.m[0].name);
        CHECK(ar.m[0].hdr_off == 8 && ar.m[0].name_len_inline == 20 && ar.m[0].data_off == 88,
              "parse: index at %zu, N %zu, data %zu", ar.m[0].hdr_off, ar.m[0].name_len_inline, ar.m[0].data_off);
        CHECK(!ar.m[1].is_index && strcmp(ar.m[1].name, "a_longer_name.o") == 0, "parse: member 1 '%s'", ar.m[1].name);
        CHECK(ar.m[1].name_len_inline == 20, "parse: member 1 N %zu", ar.m[1].name_len_inline);
        CHECK(ar.m[1].hdr_off == a.hdr[0] && ar.m[1].data_off == a.hdr[0] + 80,
              "parse: member 1 at %zu data %zu", ar.m[1].hdr_off, ar.m[1].data_off);
        CHECK(ar.m[1].data_size == rnd(sa, 8) && ar.m[1].data_off % 8 == 0,
              "parse: member 1 data size %zu", ar.m[1].data_size);
        CHECK(memcmp(a.buf + ar.m[1].data_off, oa, sa) == 0, "parse: member 1 data");
        CHECK(strcmp(ar.m[2].name, "b.o") == 0 && ar.m[2].name_len_inline == 12 && ar.m[2].hdr_off == a.hdr[1],
              "parse: member 2 '%s' N %zu at %zu", ar.m[2].name, ar.m[2].name_len_inline, ar.m[2].hdr_off);
        mar_free(&ar);
    }
    mem bsd[] = { { "x.o", ob, sb, { NULL }, 0 }, { "odd.txt", text11, 11, { NULL }, 0 } };
    arc b = build(BSD, MAR_IDX_NONE, bsd, 2);
    rc = mar_parse(b.buf, b.size, &ar, why, sizeof why);
    CHECK(rc == 0, "parse bsd: rc %d (%s)", rc, why);
    if (rc == 0) {
        CHECK(ar.n == 2 && ar.index_kind == MAR_IDX_NONE, "parse bsd: %zu members, kind %d", ar.n, ar.index_kind);
        CHECK(strcmp(ar.m[0].name, "x.o") == 0 && ar.m[0].name_len_inline == 0 && ar.m[0].data_off == 68,
              "parse bsd: inline name '%s'", ar.m[0].name);
        CHECK(strcmp(ar.m[1].name, "odd.txt") == 0 && ar.m[1].data_size == 11, "parse bsd: odd member size %zu", ar.m[1].data_size);
        mar_free(&ar);
    }
    free(a.buf); free(b.buf);
}

static void test_odd_member_padding_survives_identity(void) {
    mem ms[] = {
        { "x.o", oa, sa, { "_a", NULL }, 0 },
        { "odd.txt", text11, 11, { NULL }, 0 },
        { "y.o", ob, sb, { "_b", NULL }, 0 },
    };
    arc a = build(BSD, MAR_IDX_32_SORTED, ms, 3);
    CHECK(a.buf[a.hdr[1] + 60 + 11] == '\n' && (a.hdr[1] + 60 + 11) % 2 == 1, "odd: fixture has the pad");
    int calls = 0;
    uint8_t *out; size_t outsize;
    int rc = rewrite_copy(&a, identity, &calls, &out, &outsize);
    CHECK(rc == 0, "odd: rc %d", rc);
    CHECK(calls == 3, "odd: fn called %d times, not on the index", calls);
    CHECK(outsize == a.size && memcmp(out, a.buf, a.size) == 0, "odd: identity rewrite is not byte-identical");
    mar_archive ar; char why[256];
    if (mar_parse(out, outsize, &ar, why, sizeof why) == 0) {
        const uint8_t *ix = out + ar.m[0].data_off;
        CHECK(get_le(ix + 4 + 8 + 4, 4) == a.hdr[2] && a.hdr[2] % 2 == 0,
              "odd: index points _b at %llu, y.o is at %zu", (unsigned long long)get_le(ix + 16, 4), a.hdr[2]);
        mar_free(&ar);
    }
    free(out); free(a.buf);
}

static void test_symdef64_and_no_index_identity(void) {
    mem ms[] = {
        { "averyverylongname_member.o", oa, sa, { "_a", NULL }, 0 },
        { "odd.txt", text11, 11, { NULL }, 0 },
        { "b.o", ob, sb, { "_b", NULL }, 0 },
    };
    for (int kind = MAR_IDX_NONE; kind <= MAR_IDX_64_SORTED; kind++) {
        for (int style = LIBTOOL; style <= BSD; style++) {
            arc a = build(style, kind, ms, 3);
            uint8_t *out; size_t outsize;
            int rc = rewrite_copy(&a, identity, NULL, &out, &outsize);
            CHECK(rc == 0, "identity kind %d style %d: rc %d", kind, style, rc);
            CHECK(outsize == a.size && memcmp(out, a.buf, a.size) == 0,
                  "identity kind %d style %d: not byte-identical", kind, style);
            mar_archive ar; char why[256];
            if (mar_parse(out, outsize, &ar, why, sizeof why) == 0) {
                CHECK(ar.index_kind == kind, "identity kind %d: came back as %d", kind, ar.index_kind);
                CHECK(ar.n == (kind == MAR_IDX_NONE ? 3u : 4u), "identity kind %d: %zu members", kind, ar.n);
                mar_free(&ar);
            }
            free(out); free(a.buf);
        }
    }
}

static int grow_first(uint8_t **pbuf, size_t *psize, const mar_member *m, void *ctx) {
    int *seen = ctx;
    if ((*seen)++ != 0) return 0;
    (void)m;
    uint8_t *nb = realloc(*pbuf, *psize + 13);
    if (!nb) return 99;
    memset(nb + *psize, 'Z', 13);
    *pbuf = nb; *psize += 13;
    return 0;
}

static void test_grow_moves_next_header_and_index(void) {
    for (int style = LIBTOOL; style <= BSD; style++) {
        for (int kind = MAR_IDX_32; kind <= MAR_IDX_64_SORTED; kind++) {
            mem ms[] = {
                { "first_member.o", oa, sa, { "_a", NULL }, 0 },
                { "b.o", ob, sb, { "_b", NULL }, 0 },
                { "c.o", oc, sc, { "_c", NULL }, 0 },
            };
            arc a = build(style, kind, ms, 3);
            mar_archive in; char why[256];
            if (mar_parse(a.buf, a.size, &in, why, sizeof why) != 0) { CHECK(0, "grow: fixture: %s", why); continue; }
            int seen = 0;
            uint8_t *out; size_t outsize;
            int rc = rewrite_copy(&a, grow_first, &seen, &out, &outsize);
            CHECK(rc == 0, "grow style %d kind %d: rc %d", style, kind, rc);
            mar_archive ar;
            rc = mar_parse(out, outsize, &ar, why, sizeof why);
            CHECK(rc == 0, "grow style %d kind %d: output does not parse: %s", style, kind, why);
            if (rc != 0) { mar_free(&in); free(out); free(a.buf); continue; }
            size_t grown = in.m[1].data_size + 13;
            if (style == LIBTOOL) grown = rnd(in.m[1].data_off + grown, 8) - in.m[1].data_off;
            CHECK(ar.m[1].data_size == grown, "grow style %d kind %d: member 1 data %zu, want %zu",
                  style, kind, ar.m[1].data_size, grown);
            CHECK(memcmp(out + ar.m[1].data_off + in.m[1].data_size, "ZZZZZZZZZZZZZ", 13) == 0,
                  "grow style %d kind %d: the 13 bytes", style, kind);
            size_t want2 = ar.m[1].data_off + grown;
            want2 += want2 % 2;
            CHECK(ar.m[2].hdr_off == want2 && ar.m[2].hdr_off != in.m[2].hdr_off,
                  "grow style %d kind %d: member 2 at %zu, want %zu", style, kind, ar.m[2].hdr_off, want2);
            if (style == LIBTOOL) CHECK(ar.m[2].hdr_off % 8 == 0 && ar.m[3].data_off % 8 == 0,
                                        "grow kind %d: libtool alignment lost", kind);
            else CHECK(out[ar.m[2].hdr_off - 1] == '\n', "grow kind %d: odd end not padded with \\n", kind);
            CHECK(memcmp(out + ar.m[2].hdr_off, a.buf + in.m[2].hdr_off, 60) == 0
                  && memcmp(out + ar.m[3].hdr_off, a.buf + in.m[3].hdr_off, 60) == 0,
                  "grow style %d kind %d: unchanged headers changed", style, kind);
            CHECK(memcmp(out + ar.m[2].data_off, a.buf + in.m[2].data_off, in.m[2].data_size) == 0,
                  "grow style %d kind %d: member 2 bytes", style, kind);
            CHECK(memcmp(out + ar.m[1].hdr_off + 16, a.buf + in.m[1].hdr_off + 16, 32) == 0,
                  "grow style %d kind %d: member 1 date/uid/gid/mode", style, kind);
            int w = kind >= MAR_IDX_64 ? 8 : 4;
            const uint8_t *ix = out + ar.m[0].data_off;
            CHECK(get_le(ix, w) == 3u * 2 * w, "grow style %d kind %d: %llu index bytes", style, kind,
                  (unsigned long long)get_le(ix, w));
            for (int e = 0; e < 3; e++) {
                uint64_t o = get_le(ix + w + (size_t)e * 2 * w + w, w);
                CHECK(o == ar.m[e + 1].hdr_off, "grow style %d kind %d: entry %d -> %llu, want %zu",
                      style, kind, e, (unsigned long long)o, ar.m[e + 1].hdr_off);
            }
            mar_free(&ar); mar_free(&in); free(out); free(a.buf);
        }
    }
}

static void test_sorted_index_orders_names(void) {
    uint8_t *x, *y, *z; size_t sx, sy, sz;
    const char *bs[] = { "_b", NULL }, *as[] = { "_a", NULL }, *cs[] = { "_c", "_aa", NULL };
    x = mobj(bs, &sx); y = mobj(as, &sy); z = mobj(cs, &sz);
    for (int kind = MAR_IDX_32; kind <= MAR_IDX_64_SORTED; kind++) {
        mem ms[] = {
            { "x.o", x, sx, { NULL }, 0 },
            { "note.txt", text11, 11, { NULL }, 0 },
            { "y.o", y, sy, { NULL }, 0 },
            { "z.o", z, sz, { NULL }, 0 },
        };
        arc a = build(LIBTOOL, kind, ms, 4);   /* the input index is empty */
        uint8_t *out; size_t outsize;
        int rc = rewrite_copy(&a, identity, NULL, &out, &outsize);
        CHECK(rc == 0, "sort kind %d: rc %d", kind, rc);
        mar_archive ar; char why[256];
        if (rc || mar_parse(out, outsize, &ar, why, sizeof why) != 0) { CHECK(0, "sort kind %d: parse", kind); free(out); free(a.buf); continue; }
        int w = kind >= MAR_IDX_64 ? 8 : 4;
        const uint8_t *ix = out + ar.m[0].data_off;
        size_t ne = (size_t)get_le(ix, w) / (2 * w);
        const uint8_t *strs = ix + w + ne * 2 * w + w;
        size_t strsize = (size_t)get_le(ix + w + ne * 2 * w, w);
        CHECK(ne == 4, "sort kind %d: %zu entries (local, common, undefined and text excluded)", kind, ne);
        CHECK(memcmp(strs, "_b\0_a\0_c\0_aa\0", 13) == 0, "sort kind %d: string pool not in member order", kind);
        CHECK((ar.m[0].data_off + ar.m[0].data_size) % 8 == 0 && strsize >= 13, "sort kind %d: index end not 8-aligned", kind);
        for (size_t i = 13; i < strsize; i++) CHECK(strs[i] == 0, "sort kind %d: pad byte %zu is %u", kind, i, strs[i]);
        int sorted = (kind == MAR_IDX_32_SORTED || kind == MAR_IDX_64_SORTED);
        const char *want_s[] = { "_a", "_aa", "_b", "_c" }, *want_u[] = { "_b", "_a", "_c", "_aa" };
        size_t want_m_s[] = { 3, 4, 1, 4 }, want_m_u[] = { 1, 3, 4, 4 };
        for (size_t e = 0; e < ne && e < 4; e++) {
            const char *s = (const char *)strs + get_le(ix + w + e * 2 * w, w);
            uint64_t o = get_le(ix + w + e * 2 * w + w, w);
            const char *want = sorted ? want_s[e] : want_u[e];
            size_t wm = sorted ? want_m_s[e] : want_m_u[e];
            CHECK(strcmp(s, want) == 0, "sort kind %d: entry %zu is %s, want %s", kind, e, s, want);
            CHECK(o == ar.m[wm].hdr_off, "sort kind %d: entry %zu at %llu", kind, e, (unsigned long long)o);
        }
        mar_free(&ar); free(out); free(a.buf);
    }
    free(x); free(y); free(z);
}

/* Ties keep member order; ranlib itself writes only __.SYMDEF when two
 * members define one name, so a SORTED index never has them from ranlib. */
static void test_sorted_ties_keep_member_order(void) {
    const char *names[] = { "_m", "_dup", "_k", "_dup", "_z", "_dup", "_a", "_dup", "_q", "_dup", "_c", "_dup" };
    uint8_t *objs[12]; size_t sizes[12];
    mem ms[12];
    for (int i = 0; i < 12; i++) {
        const char *d[] = { names[i], NULL };
        objs[i] = mobj(d, &sizes[i]);
        char *nm = malloc(8); snprintf(nm, 8, "m%d.o", i);
        mem m = { nm, objs[i], sizes[i], { NULL }, 0 };
        ms[i] = m;
    }
    for (int kind = MAR_IDX_32_SORTED; kind <= MAR_IDX_64_SORTED; kind += 2) {
        arc a = build(LIBTOOL, kind, ms, 12);
        uint8_t *out; size_t outsize;
        int rc = rewrite_copy(&a, identity, NULL, &out, &outsize);
        mar_archive ar; char why[256];
        if (rc || mar_parse(out, outsize, &ar, why, sizeof why) != 0) { CHECK(0, "ties kind %d: rc %d", kind, rc); free(out); free(a.buf); continue; }
        int w = kind >= MAR_IDX_64 ? 8 : 4;
        const uint8_t *ix = out + ar.m[0].data_off;
        size_t prev = 0;
        for (size_t e = 2; e <= 7; e++) {   /* _a _c, then six _dup */
            uint64_t o = get_le(ix + w + e * 2 * w + w, w);
            CHECK(o > prev, "ties kind %d: _dup entry %zu at %llu is not after %zu", kind, e, (unsigned long long)o, prev);
            prev = (size_t)o;
        }
        mar_free(&ar); free(out); free(a.buf);
    }
    for (int i = 0; i < 12; i++) { free(objs[i]); free((char *)ms[i].name); }
}

static void test_unnamed_symbol_not_indexed(void) {
    const char *d[] = { "", "_a", NULL };
    size_t s; uint8_t *o = mobj(d, &s);
    mem ms[] = { { "a.o", o, s, { "_a", NULL }, 0 } };
    arc a = build(LIBTOOL, MAR_IDX_32_SORTED, ms, 1);
    uint8_t *out; size_t outsize;
    int rc = rewrite_copy(&a, identity, NULL, &out, &outsize);
    CHECK(rc == 0 && outsize == a.size && memcmp(out, a.buf, a.size) == 0,
          "unnamed: an n_strx 0 symbol is not indexed, as ranlib leaves it out (rc %d)", rc);
    free(out); free(a.buf); free(o);
}

/* 10.9 libtool -static of b.o (_b1 _bb2, member size 780), a 26-character
 * name (_a1 _zz, 844) and c.o (_c1 _useh, 788): its index member, header
 * included. The string table's last 4 bytes are left uninitialised by 10.9
 * libtool ("#1/3" here); the rebuild writes zeros there. */
static const uint8_t libtool_index[] = {
        0x23, 0x31, 0x2f, 0x32, 0x30, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20,
        0x20, 0x20, 0x20, 0x20, 0x31, 0x37, 0x39, 0x31, 0x32, 0x36, 0x30, 0x36,
        0x39, 0x38, 0x20, 0x20, 0x35, 0x30, 0x31, 0x20, 0x20, 0x20, 0x32, 0x30,
        0x20, 0x20, 0x20, 0x20, 0x31, 0x30, 0x30, 0x36, 0x34, 0x34, 0x20, 0x20,
        0x31, 0x30, 0x38, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x60, 0x0a,
        0x5f, 0x5f, 0x2e, 0x53, 0x59, 0x4d, 0x44, 0x45, 0x46, 0x20, 0x53, 0x4f,
        0x52, 0x54, 0x45, 0x44, 0x00, 0x00, 0x00, 0x00, 0x30, 0x00, 0x00, 0x00,
        0x09, 0x00, 0x00, 0x00, 0xf8, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xb0, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0xb0, 0x00, 0x00, 0x00,
        0x11, 0x00, 0x00, 0x00, 0x80, 0x07, 0x00, 0x00, 0x15, 0x00, 0x00, 0x00,
        0x80, 0x07, 0x00, 0x00, 0x0d, 0x00, 0x00, 0x00, 0xf8, 0x03, 0x00, 0x00,
        0x20, 0x00, 0x00, 0x00, 0x5f, 0x62, 0x31, 0x00, 0x5f, 0x62, 0x62, 0x32,
        0x00, 0x5f, 0x61, 0x31, 0x00, 0x5f, 0x7a, 0x7a, 0x00, 0x5f, 0x63, 0x31,
        0x00, 0x5f, 0x75, 0x73, 0x65, 0x68, 0x00, 0x00, 0x23, 0x31, 0x2f, 0x33,
};

static void test_libtool_10_9_index_bytes(void) {
    const char *d1[] = { "_b1", "_bb2", NULL }, *d2[] = { "_a1", "_zz", NULL }, *d3[] = { "_c1", "_useh", NULL };
    size_t s1, s2, s3;
    uint8_t *o1 = mobj(d1, &s1), *o2 = mobj(d2, &s2), *o3 = mobj(d3, &s3);
    mem ms[] = {
        { "b.o", o1, s1, { "_b1", "_bb2", NULL }, 780 - 12 },
        { "averyverylongname_member.o", o2, s2, { "_a1", "_zz", NULL }, 844 - 36 },
        { "c.o", o3, s3, { "_c1", "_useh", NULL }, 788 - 12 },
    };
    arc a = build(LIBTOOL, MAR_IDX_32_SORTED, ms, 3);
    CHECK(a.size == 2768 && a.hdr[0] == 176 && a.hdr[1] == 1016 && a.hdr[2] == 1920,
          "libtool: fixture layout %zu %zu %zu %zu", a.size, a.hdr[0], a.hdr[1], a.hdr[2]);
    memcpy(a.buf + 8, libtool_index, sizeof libtool_index);
    uint8_t *out; size_t outsize;
    int rc = rewrite_copy(&a, identity, NULL, &out, &outsize);
    CHECK(rc == 0 && outsize == a.size, "libtool: rc %d size %zu", rc, outsize);
    if (rc == 0 && outsize == a.size) {
        uint8_t want[sizeof libtool_index];
        memcpy(want, libtool_index, sizeof want);
        memset(want + sizeof want - 4, 0, 4);
        CHECK(memcmp(out + 8, want, sizeof want) == 0, "libtool: rebuilt index differs from 10.9 libtool's");
        CHECK(memcmp(out + 176, a.buf + 176, a.size - 176) == 0, "libtool: members changed");
    }
    free(out); free(a.buf); free(o1); free(o2); free(o3);
}

static int fail_second(uint8_t **pbuf, size_t *psize, const mar_member *m, void *ctx) {
    (void)m;
    if ((*(int *)ctx)++ == 1) return 7;
    memset(*pbuf, 0, *psize);
    return 0;
}

static void test_fn_failure_leaves_buffer(void) {
    mem ms[] = { { "a.o", oa, sa, { "_a", NULL }, 0 }, { "b.o", ob, sb, { "_b", NULL }, 0 } };
    arc a = build(LIBTOOL, MAR_IDX_32_SORTED, ms, 2);
    uint8_t *b = malloc(a.size); memcpy(b, a.buf, a.size);
    uint8_t *keep = b; size_t s = a.size;
    int n = 0;
    char why[64] = "";
    int rc = mar_rewrite(&b, &s, fail_second, &n, why, sizeof why);
    CHECK(rc == 7, "fn failure: rc %d, want fn's 7", rc);
    CHECK(b == keep && s == a.size && memcmp(b, a.buf, a.size) == 0, "fn failure: buffer touched");
    free(b); free(a.buf);
}

static void test_member_kinds(void) {
    uint8_t m32[64]; memset(m32, 0, sizeof m32);
    uint32_t magic = MH_MAGIC; memcpy(m32, &magic, 4);
    mem ms[] = { { "a.o", oa, sa, { "_a", NULL }, 0 }, { "i386.o", m32, sizeof m32, { NULL }, 0 } };
    arc a = build(LIBTOOL, MAR_IDX_32_SORTED, ms, 2);
    uint8_t *out; size_t outsize;
    int rc = rewrite_copy(&a, identity, NULL, &out, &outsize);
    CHECK(rc == MR_REFUSED, "32-bit Mach-O member: rc %d, want refused (its symbols would be lost)", rc);
    CHECK(strstr(rewrite_why, "member 'i386.o' is a Mach-O that is not thin 64-bit") != NULL,
          "32-bit Mach-O member: the reason comes back in why: '%s'", rewrite_why);
    free(out); free(a.buf);

    uint8_t broken[64]; memcpy(broken, oa, sizeof broken);
    mem bs[] = { { "a.o", oa, sa, { "_a", NULL }, 0 }, { "cut.o", broken, sizeof broken, { NULL }, 0 } };
    a = build(BSD, MAR_IDX_32, bs, 2);
    rc = rewrite_copy(&a, identity, NULL, &out, &outsize);
    CHECK(rc == MR_REFUSED, "malformed 64-bit member: rc %d, want refused", rc);
    CHECK(strstr(rewrite_why, "member 'cut.o': the symbol table is malformed") != NULL,
          "malformed 64-bit member: the reason comes back in why: '%s'", rewrite_why);
    free(out); free(a.buf);

    const uint8_t bitcode[] = { 'B', 'C', 0xc0, 0xde, 1, 2, 3, 4 };
    mem cs[] = { { "a.o", oa, sa, { "_a", NULL }, 0 }, { "lto.o", bitcode, sizeof bitcode, { NULL }, 0 } };
    a = build(LIBTOOL, MAR_IDX_32_SORTED, cs, 2);
    rc = rewrite_copy(&a, identity, NULL, &out, &outsize);
    CHECK(rc == 0 && outsize == a.size && memcmp(out, a.buf, a.size) == 0,
          "non-Mach-O member: contributes nothing, passes through (rc %d)", rc);
    free(out); free(a.buf);
}

static void expect_refused(const uint8_t *buf, size_t size, const char *what, const char *needle) {
    mar_archive ar; char why[256] = "";
    int rc = mar_parse(buf, size, &ar, why, sizeof why);
    CHECK(rc == MR_REFUSED, "%s: rc %d, want refused", what, rc);
    if (rc == 0) mar_free(&ar);
    if (rc == MR_REFUSED && needle) CHECK(strstr(why, needle) != NULL, "%s: reason '%s' lacks '%s'", what, why, needle);
    uint8_t *b = malloc(size ? size : 1); memcpy(b, buf, size);
    uint8_t *keep = b; size_t s = size;
    char rwhy[256] = "";
    rc = mar_rewrite(&b, &s, identity, NULL, rwhy, sizeof rwhy);
    CHECK(rc == MR_REFUSED && b == keep && s == size, "%s: mar_rewrite rc %d, want refused, buffer untouched", what, rc);
    CHECK(strcmp(rwhy, why) == 0, "%s: mar_rewrite's reason '%s' is mar_parse's '%s'", what, rwhy, why);
    free(b);
}

static void test_refusals(void) {
    mem ms[] = { { "a.o", oa, sa, { "_a", NULL }, 0 }, { "odd.txt", text11, 11, { NULL }, 0 }, { "b.o", ob, sb, { "_b", NULL }, 0 } };
    arc a = build(BSD, MAR_IDX_32_SORTED, ms, 3);
    uint8_t *c = malloc(a.size + 64);
    size_t h1 = a.hdr[0];
    char at1[32]; snprintf(at1, sizeof at1, "offset %zu", h1);

#define FRESH() memcpy(c, a.buf, a.size)
    FRESH(); c[1] = '!';
    expect_refused(c, a.size, "bad global magic", "not an archive");
    FRESH(); c[h1 + 58] = '\'';
    expect_refused(c, a.size, "bad fmag", at1);
    FRESH(); c[h1 + 49] = 'x';
    expect_refused(c, a.size, "size not decimal", at1);
    FRESH(); memcpy(c + h1 + 48, "  12      ", 10);
    expect_refused(c, a.size, "size with leading spaces", at1);
    FRESH(); memcpy(c + h1 + 48, "          ", 10);
    expect_refused(c, a.size, "empty size", at1);
    FRESH(); memcpy(c + a.hdr[2] + 48, "99999     ", 10);
    expect_refused(c, a.size, "size past the end", "past the end");
    FRESH(); memcpy(c + 8, "#1/999          ", 16);
    expect_refused(c, a.size, "#1/N larger than the member", "offset 8");
    FRESH(); memcpy(c + 8, "#1/x            ", 16);
    expect_refused(c, a.size, "#1/ without a length", "offset 8");
    FRESH(); memcpy(c + h1, "/               ", 16);
    expect_refused(c, a.size, "GNU / member", "GNU");
    FRESH(); memcpy(c + h1, "//              ", 16);
    expect_refused(c, a.size, "GNU // member", "GNU");
    FRESH();
    expect_refused(c, a.hdr[1] + 60 + 11, "odd member missing its pad", "pad");
    expect_refused((const uint8_t *)"!<arch>\n", 8, "no members", "no members");
    FRESH(); memcpy(c + h1, "__.SYMDEF       ", 16);
    expect_refused(c, a.size, "a second index", "index");
    FRESH(); memcpy(c + 8 + 60, "__.SYMDEF_32    ", 16);
    expect_refused(c, a.size, "unknown index kind", "index");
    {
        FRESH();
        uint8_t *ix = c + 8 + 60 + 20;
        put_le(ix + 8, a.hdr[0] + 2, 4);
        expect_refused(c, a.size, "index offset not at a member header", "index");
        FRESH(); put_le(ix + 4, 9999, 4);
        expect_refused(c, a.size, "index string index past its table", "index");
        FRESH(); put_le(ix, 7, 4);
        expect_refused(c, a.size, "index byte count not whole entries", "index");
        FRESH(); put_le(ix, 4000, 4);
        expect_refused(c, a.size, "index byte count past the member", "index");
    }
    free(c); free(a.buf);
}

/* Every proper prefix of an indexed archive is refused. Each is placed so it
 * ends against a PROT_NONE page: any read past it faults. */
static void test_truncation(void) {
    mem ms[] = { { "a_longer_name.o", oa, sa, { "_a", NULL }, 0 }, { "odd.txt", text11, 11, { NULL }, 0 },
                 { "b.o", ob, sb, { "_b", NULL }, 0 } };
    for (int style = LIBTOOL; style <= BSD; style++) {
        arc a = build(style, style == BSD ? MAR_IDX_64_SORTED : MAR_IDX_32_SORTED, ms, 3);
        size_t pg = (size_t)getpagesize();
        size_t span = (a.size + pg - 1) / pg * pg;
        uint8_t *region = mmap(NULL, span + pg, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        if (region == MAP_FAILED) { CHECK(0, "truncation: mmap"); free(a.buf); return; }
        mprotect(region + span, pg, PROT_NONE);
        int refused = 0;
        for (size_t len = 0; len < a.size; len++) {
            uint8_t *p = region + span - len;
            memcpy(p, a.buf, len);
            mar_archive ar; char why[128];
            int rc = mar_parse(p, len, &ar, why, sizeof why);
            if (rc == MR_REFUSED) refused++;
            else { CHECK(0, "truncation style %d at %zu: rc %d", style, len, rc); if (rc == 0) mar_free(&ar); }
            uint8_t *b = malloc(len ? len : 1); memcpy(b, a.buf, len);
            size_t s = len;
            rc = mar_rewrite(&b, &s, identity, NULL, why, sizeof why);
            CHECK(rc == MR_REFUSED, "truncation style %d at %zu: mar_rewrite rc %d", style, len, rc);
            free(b);
        }
        CHECK((size_t)refused == a.size, "truncation style %d: %d of %zu refused", style, refused, a.size);
        mar_archive ar; char why[128];
        uint8_t *p = region + span - a.size;
        memcpy(p, a.buf, a.size);
        CHECK(mar_parse(p, a.size, &ar, why, sizeof why) == 0, "truncation style %d: the whole archive: %s", style, why);
        mar_free(&ar);
        munmap(region, span + pg);
        free(a.buf);
    }
}

int main(void) {
    const char *da[] = { "_a", NULL }, *db[] = { "_b", NULL }, *dc[] = { "_c", NULL };
    oa = mobj(da, &sa); ob = mobj(db, &sb); oc = mobj(dc, &sc);
    test_parse_sorted_with_long_name();
    test_odd_member_padding_survives_identity();
    test_symdef64_and_no_index_identity();
    test_grow_moves_next_header_and_index();
    test_sorted_index_orders_names();
    test_sorted_ties_keep_member_order();
    test_unnamed_symbol_not_indexed();
    test_libtool_10_9_index_bytes();
    test_fn_failure_leaves_buffer();
    test_member_kinds();
    test_refusals();
    test_truncation();
    free(oa); free(ob); free(oc);
    if (fails) { printf("%d failure(s)\n", fails); return 1; }
    printf("archive_test: all passed\n");
    return 0;
}
