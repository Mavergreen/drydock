/* redirect.c -- `import redirect`. See redirect.h. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

#include "redirect.h"
#include "image.h"
#include "ordinals.h"
#include "rewrite.h"
#include "uleb.h"
#include "mach_compat.h"

#define WHAT "drydock-macho-rewrite: import redirect"

typedef struct { mo_bind_state *v; size_t n, cap; int oom; } mrd_events;

static void mrd_collect(const mo_bind_state *st, void *ctx) {
    mrd_events *e = ctx;
    if (e->oom) return;
    if (e->n == e->cap) {
        size_t cap = e->cap ? e->cap * 2 : 64;
        mo_bind_state *v = realloc(e->v, cap * sizeof *v);
        if (!v) { e->oom = 1; return; }
        e->v = v; e->cap = cap;
    }
    e->v[e->n++] = *st;
}

static int mrd_walk(const uint8_t *buf, uint32_t off, uint32_t size, const char *what,
                    mrd_events *e) {
    memset(e, 0, sizeof *e);
    if (size == 0) return 0;
    if (mo_bind_observe(buf + off, size, what, mrd_collect, e) != 0) return MR_REFUSED;
    if (e->oom) { fprintf(stderr, WHAT ": out of memory\n"); return MR_FAIL; }
    return 0;
}

typedef struct {
    const char *names[MO_MAX_DYLIBS + 1];
    int n, lazy_load, chained;
    struct dyld_info_command *di;
    struct symtab_command *st;
    struct segment_command_64 *linkedit;
} mrd_slice;

static int mrd_lc(const struct load_command *lc, void *ctx) {
    mrd_slice *s = ctx;
    if (mo_is_ordinal_lc(lc->cmd) && s->n < MO_MAX_DYLIBS) {
        const struct dylib_command *dc = (const struct dylib_command *)lc;
        s->names[++s->n] = mo_lc_str_at(lc, dc->dylib.name.offset);
    } else if (lc->cmd == LC_LAZY_LOAD_DYLIB) {
        s->lazy_load = 1;
    } else if (lc->cmd == LC_DYLD_CHAINED_FIXUPS) {
        s->chained = 1;
    } else if (lc->cmd == LC_DYLD_INFO || lc->cmd == LC_DYLD_INFO_ONLY) {
        s->di = (struct dyld_info_command *)lc;
    } else if (lc->cmd == LC_SYMTAB) {
        s->st = (struct symtab_command *)lc;
    } else if (lc->cmd == LC_SEGMENT_64) {
        struct segment_command_64 *sc = (struct segment_command_64 *)lc;
        if (strncmp(sc->segname, "__LINKEDIT", 16) == 0) s->linkedit = sc;
    }
    return 0;
}

typedef struct {
    const char *symbol;
    const unsigned char *from;
    int n;
} mrd_sel;

static int mrd_moved(const mrd_sel *sel, const mo_bind_state *b) {
    return b->symbol && strcmp(b->symbol, sel->symbol) == 0 &&
           b->ordinal >= 1 && b->ordinal <= sel->n && sel->from[b->ordinal];
}

static int mrd_encode_width(uint8_t *p, int ord, uint32_t width) {
    if (width == 1) {
        if (ord > BIND_IMMEDIATE_MASK) return 0;
        p[0] = (uint8_t)(BIND_OPCODE_SET_DYLIB_ORDINAL_IMM | ord);
        return 1;
    }
    p[0] = BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB;
    return mu_encode_fixed(p + 1, (uint64_t)ord, (int)width - 1);
}

static uint32_t mrd_encode_min(uint8_t *p, int ord) {
    uint32_t w = ord <= BIND_IMMEDIATE_MASK ? 1 : 1 + (uint32_t)mu_minlen((uint64_t)ord);
    mrd_encode_width(p, ord, w);
    return w;
}

typedef struct { uint8_t *p; size_t n, cap; int oom; } mrd_buf;

static void mrd_put(mrd_buf *b, const uint8_t *src, size_t n) {
    if (b->oom || n == 0) return;
    if (b->n + n > b->cap) {
        size_t cap = b->cap ? b->cap : 256;
        while (cap < b->n + n) cap *= 2;
        uint8_t *p = realloc(b->p, cap);
        if (!p) { b->oom = 1; return; }
        b->p = p; b->cap = cap;
    }
    memcpy(b->p + b->n, src, n);
    b->n += n;
}

/* spec: src/redirect.h -- every byte but the ordinal opcodes is copied, so the
 * ordinal in effect in the OUTPUT at each bind is tracked: the input's own,
 * unless an opcode written here since the input's last one says otherwise. */
static int mrd_rewrite_bind(const uint8_t *in, uint32_t size, const mrd_events *e,
                            const mrd_sel *sel, int to, mrd_buf *out, size_t *live) {
    const uint8_t *cur = in;
    int out_ord = 0;
    uint8_t enc[16];
    size_t i, j;
    memset(out, 0, sizeof *out);
    *live = 0;
    for (i = 0; i < e->n; i++) {
        const mo_bind_state *b = &e->v[i];
        int moved = mrd_moved(sel, b);
        int fresh = b->ord_at && (i == 0 || b->ord_at > e->v[i - 1].at);
        if (fresh) {
            int all = 1, any = 0;
            for (j = i; j < e->n && e->v[j].ord_at == b->ord_at; j++) {
                if (mrd_moved(sel, &e->v[j])) any = 1; else all = 0;
            }
            if (any && all) {
                mrd_put(out, cur, (size_t)(b->ord_at - cur));
                mrd_put(out, enc, mrd_encode_min(enc, to));
                cur = b->ord_at + b->ord_len;
                out_ord = to;
            } else {
                out_ord = b->ordinal;
            }
        }
        int want = moved ? to : b->ordinal;
        if (want != out_ord) {
            if (!moved && !b->ord_at) {
                fprintf(stderr, WHAT ": the bind stream binds %s before it names any "
                                "library; refusing\n", b->symbol ? b->symbol : "a symbol");
                free(out->p);
                return MR_REFUSED;
            }
            mrd_put(out, cur, (size_t)(b->at - cur));
            if (moved) mrd_put(out, enc, mrd_encode_min(enc, to));
            else       mrd_put(out, b->ord_at, b->ord_len);
            cur = b->at;
            out_ord = want;
        }
        if (i + 1 == e->n) *live = out->n + (size_t)(b->at - cur) + b->len;
    }
    mrd_put(out, cur, (size_t)(in + size - cur));
    mrd_put(out, (const uint8_t *)"", 1);
    out->n--;
    if (out->oom) {
        free(out->p);
        fprintf(stderr, WHAT ": out of memory\n");
        return MR_FAIL;
    }
    return 0;
}

/* spec: tests/import_redirect_test.sh "verification" -- `same_place` is the
 * lazy stream's invariant: the stub helpers address each program by offset. */
static int mrd_same(const char *what, const mrd_events *before, const uint8_t *b0,
                    const mrd_events *after, const uint8_t *a0, const mrd_sel *sel,
                    int to, int same_place) {
    size_t i;
    if (before->n != after->n) {
        fprintf(stderr, WHAT ": verification failed: the %s stream had %zu binds and "
                        "now has %zu; refusing\n", what, before->n, after->n);
        return MR_REFUSED;
    }
    for (i = 0; i < before->n; i++) {
        const mo_bind_state *x = &before->v[i], *y = &after->v[i];
        int want = mrd_moved(sel, x) ? to : x->ordinal;
        int same_sym = (!x->symbol && !y->symbol) ||
                       (x->symbol && y->symbol && strcmp(x->symbol, y->symbol) == 0);
        if (!same_sym || x->weak != y->weak || x->seg != y->seg || x->type != y->type ||
            x->offset != y->offset || x->addend != y->addend || x->count != y->count ||
            x->skip != y->skip || x->len != y->len || memcmp(x->at, y->at, x->len) != 0 ||
            y->ordinal != want || (same_place && (x->at - b0) != (y->at - a0))) {
            fprintf(stderr, WHAT ": verification failed: %s bind %zu (%s) is not what "
                            "the redirect meant it to be; refusing\n",
                    what, i, x->symbol ? x->symbol : "-");
            return MR_REFUSED;
        }
    }
    return 0;
}

static int mrd_nlist_selected(const uint8_t *buf, const struct symtab_command *st,
                              const struct nlist_64 *n, const mrd_sel *sel) {
    uint8_t type = n->n_type & N_TYPE;
    int ord = GET_LIBRARY_ORDINAL(n->n_desc);
    if ((n->n_type & N_STAB) || (type != N_UNDF && type != N_PBUD)) return 0;
    if (ord < 1 || ord > sel->n || !sel->from[ord]) return 0;
    if ((uint64_t)n->n_un.n_strx >= st->strsize) return 0;
    const char *name = (const char *)buf + st->stroff + n->n_un.n_strx;
    size_t room = st->strsize - n->n_un.n_strx, len = strlen(sel->symbol);
    return room > len && memcmp(name, sel->symbol, len + 1) == 0;
}

static void mrd_free3(mrd_events *a, mrd_events *b, mrd_events *c) {
    free(a->v); free(b->v); free(c->v);
}

int mrd_redirect(uint8_t **pbuf, size_t *psize, const char *symbol,
                 const char *from, const char *to, mrd_report *rep) {
    uint8_t *buf = *pbuf;
    size_t size = *psize;
    mi_image im;
    mrd_slice s;
    unsigned char isfrom[MO_MAX_DYLIBS + 1];
    int i, nfrom = 0;

    memset(rep, 0, sizeof *rep);
    if (mi_wrap(buf, size, &im) != 0) {
        fprintf(stderr, WHAT ": the image is not a readable 64-bit Mach-O\n");
        return MR_REFUSED;
    }
    memset(&s, 0, sizeof s);
    mi_each_lc(&im, mrd_lc, &s);
    if (s.chained) {
        fprintf(stderr, WHAT ": the image uses LC_DYLD_CHAINED_FIXUPS; put "
                        "`fixups set classic` before this statement\n");
        return MR_REFUSED;
    }
    if (s.lazy_load) {
        fprintf(stderr, WHAT ": LC_LAZY_LOAD_DYLIB present; its place in the ordinal "
                        "sequence has never been established, so refusing rather "
                        "than guessing which library an ordinal names\n");
        return MR_REFUSED;
    }
    memset(isfrom, 0, sizeof isfrom);
    for (i = 1; i <= s.n; i++) {
        if (!s.names[i]) {
            fprintf(stderr, WHAT ": dylib load command %d has a name offset past its "
                            "cmdsize; refusing\n", i);
            return MR_REFUSED;
        }
        if (!rep->to && strcmp(s.names[i], to) == 0) rep->to = i;
        if (strcmp(s.names[i], from) == 0) { isfrom[i] = 1; nfrom++; if (!rep->from) rep->from = i; }
    }
    if (!rep->to) {
        fprintf(stderr, WHAT ": %s is not a library this image loads; a statement "
                        "before this one must add it (dylib append %s)\n", to, to);
        return MR_REFUSED;
    }
    if (!(im.hdr->flags & MH_TWOLEVEL)) {
        fprintf(stderr, WHAT ": flat namespace: no import names a library, so there "
                        "is none to redirect\n");
        return MR_REFUSED;
    }
    if (nfrom == 0) return 0;
    if (!s.di) {
        fprintf(stderr, WHAT ": no LC_DYLD_INFO: this image binds through relocation "
                        "entries, which import redirect does not rewrite\n");
        return MR_REFUSED;
    }
    const struct dyld_info_command *di = s.di;
    if (!mo_fits(di->bind_off, di->bind_size, size) ||
        !mo_fits(di->lazy_bind_off, di->lazy_bind_size, size) ||
        !mo_fits(di->weak_bind_off, di->weak_bind_size, size)) {
        fprintf(stderr, WHAT ": a bind stream does not fit within the %zu-byte image; "
                        "refusing\n", size);
        return MR_REFUSED;
    }
    if (s.st && (!mo_fits(s.st->symoff, (uint64_t)s.st->nsyms * sizeof(struct nlist_64), size) ||
                 !mo_fits(s.st->stroff, s.st->strsize, size))) {
        fprintf(stderr, WHAT ": LC_SYMTAB does not fit within the %zu-byte image; "
                        "refusing\n", size);
        return MR_REFUSED;
    }

    mrd_sel sel = { symbol, isfrom, s.n };
    mrd_events bind, lazy, weak;
    int rc;
    memset(&bind, 0, sizeof bind); memset(&lazy, 0, sizeof lazy); memset(&weak, 0, sizeof weak);
    if ((rc = mrd_walk(buf, di->bind_off, di->bind_size, "bind", &bind)) != 0 ||
        (rc = mrd_walk(buf, di->lazy_bind_off, di->lazy_bind_size, "lazy bind", &lazy)) != 0 ||
        (rc = mrd_walk(buf, di->weak_bind_off, di->weak_bind_size, "weak bind", &weak)) != 0) {
        mrd_free3(&bind, &lazy, &weak);
        return rc;
    }
    size_t k, j;
    for (k = 0; k < weak.n; k++)
        if (weak.v[k].symbol && strcmp(weak.v[k].symbol, symbol) == 0) rep->weak += (long)weak.v[k].count;
    for (k = 0; k < bind.n; k++)
        if (mrd_moved(&sel, &bind.v[k])) rep->bind += (long)bind.v[k].count;
    for (k = 0; k < lazy.n; k++)
        if (mrd_moved(&sel, &lazy.v[k])) rep->lazy += (long)lazy.v[k].count;

    /* spec: README.md "Statements" -- a lazy program cannot move or grow. */
    for (k = 0; k < lazy.n; k++) {
        const mo_bind_state *b = &lazy.v[k];
        if (!mrd_moved(&sel, b)) continue;
        if (!b->ord_at || (b->done_at && b->ord_at < b->done_at)) {
            fprintf(stderr, WHAT ": the lazy bind of %s sets no library ordinal of its "
                            "own; refusing\n", symbol);
            mrd_free3(&bind, &lazy, &weak);
            return MR_REFUSED;
        }
        for (j = 0; j < lazy.n; j++) {
            if (lazy.v[j].ord_at == b->ord_at && !mrd_moved(&sel, &lazy.v[j])) {
                fprintf(stderr, WHAT ": cannot redirect the lazy bind of %s without also "
                                "redirecting %s: they share one library-ordinal opcode; "
                                "refusing\n", symbol,
                        lazy.v[j].symbol ? lazy.v[j].symbol : "a bind with no symbol");
                mrd_free3(&bind, &lazy, &weak);
                return MR_REFUSED;
            }
        }
        uint8_t probe[16];
        if (!mrd_encode_width(probe, rep->to, b->ord_len)) {
            fprintf(stderr, WHAT ": cannot encode ordinal %d in the %u-byte ordinal "
                            "opcode of %s's lazy bind; a lazy program cannot grow, "
                            "because the stub helpers address each one by its offset; "
                            "refusing\n", rep->to, b->ord_len, symbol);
            mrd_free3(&bind, &lazy, &weak);
            return MR_REFUSED;
        }
    }

    rep->bind_before = rep->bind_after = di->bind_size;
    rep->bind_off_before = rep->bind_off_after = di->bind_off;
    rep->linkedit_before = rep->linkedit_after = s.linkedit ? s.linkedit->filesize : 0;

    mrd_buf nbind;
    size_t live = 0, place_len = 0;
    int grow = 0;
    memset(&nbind, 0, sizeof nbind);
    if (rep->bind) {
        if ((rc = mrd_rewrite_bind(buf + di->bind_off, di->bind_size, &bind, &sel,
                                   rep->to, &nbind, &live)) != 0) {
            mrd_free3(&bind, &lazy, &weak);
            return rc;
        }
        if (nbind.n <= di->bind_size) {
            place_len = nbind.n;
        } else if (live + 1 <= di->bind_size) {
            place_len = live + 1;
            nbind.p[live] = BIND_OPCODE_DONE;
        } else {
            grow = 1;
            place_len = live + 1;
            nbind.p[live] = BIND_OPCODE_DONE;
        }
    }

    size_t nsize = size, new_off = 0, padded = 0;
    if (grow) {
        if (!s.linkedit || s.linkedit->fileoff + s.linkedit->filesize != size) {
            fprintf(stderr, WHAT ": the bind stream must grow, and it can only grow at "
                            "the end of __LINKEDIT, which does not end the image; "
                            "refusing\n");
            free(nbind.p); mrd_free3(&bind, &lazy, &weak);
            return MR_REFUSED;
        }
        new_off = (size + 7) & ~(size_t)7;
        padded = (place_len + 7) & ~(size_t)7;
        nsize = new_off + padded;
        if (nsize > UINT32_MAX) {
            fprintf(stderr, WHAT ": the image would pass 4GB; refusing\n");
            free(nbind.p); mrd_free3(&bind, &lazy, &weak);
            return MR_REFUSED;
        }
    }

    uint8_t *nb = malloc(nsize);
    if (!nb) {
        fprintf(stderr, WHAT ": out of memory\n");
        free(nbind.p); mrd_free3(&bind, &lazy, &weak);
        return MR_FAIL;
    }
    memcpy(nb, buf, size);
    memset(nb + size, 0, nsize - size);
    mi_image nim;
    mrd_slice ns;
    if (mi_wrap(nb, nsize, &nim) != 0) {
        fprintf(stderr, WHAT ": internal error: the copy is not a Mach-O\n");
        free(nb); free(nbind.p); mrd_free3(&bind, &lazy, &weak);
        return MR_FAIL;
    }
    memset(&ns, 0, sizeof ns);
    mi_each_lc(&nim, mrd_lc, &ns);
    struct dyld_info_command *ndi = ns.di;

    for (k = 0; k < lazy.n; k++) {
        const mo_bind_state *b = &lazy.v[k];
        if (mrd_moved(&sel, b))
            mrd_encode_width(nb + (b->ord_at - buf), rep->to, b->ord_len);
    }
    if (rep->bind) {
        if (grow) {
            memset(nb + di->bind_off, 0, di->bind_size);
            memcpy(nb + new_off, nbind.p, place_len);
            ndi->bind_off = (uint32_t)new_off;
            ndi->bind_size = (uint32_t)padded;
            uint64_t fs = nsize - ns.linkedit->fileoff;
            uint64_t vs = (fs + 0xFFF) & ~(uint64_t)0xFFF;
            ns.linkedit->filesize = fs;
            if (vs > ns.linkedit->vmsize) ns.linkedit->vmsize = vs;
        } else {
            memset(nb + di->bind_off, 0, di->bind_size);
            memcpy(nb + di->bind_off, nbind.p, place_len);
        }
    }
    free(nbind.p);
    if (s.st) {
        struct nlist_64 *syms = (struct nlist_64 *)(nb + s.st->symoff);
        for (uint32_t q = 0; q < s.st->nsyms; q++) {
            if (!mrd_nlist_selected(nb, s.st, &syms[q], &sel)) continue;
            uint16_t d = syms[q].n_desc;
            SET_LIBRARY_ORDINAL(d, (uint8_t)rep->to);
            syms[q].n_desc = d;
            rep->nlist++;
        }
    }

    mrd_events nbind_ev, nlazy_ev, nweak_ev;
    memset(&nbind_ev, 0, sizeof nbind_ev); memset(&nlazy_ev, 0, sizeof nlazy_ev);
    memset(&nweak_ev, 0, sizeof nweak_ev);
    rc = 0;
    if (ndi->lazy_bind_size != di->lazy_bind_size || ndi->lazy_bind_off != di->lazy_bind_off ||
        ndi->weak_bind_size != di->weak_bind_size || ndi->weak_bind_off != di->weak_bind_off ||
        memcmp(nb + di->weak_bind_off, buf + di->weak_bind_off, di->weak_bind_size) != 0) {
        fprintf(stderr, WHAT ": verification failed: the lazy or weak-bind stream moved; "
                        "refusing\n");
        rc = MR_REFUSED;
    }
    if (!rc) rc = mrd_walk(nb, ndi->bind_off, ndi->bind_size, "bind", &nbind_ev);
    if (!rc) rc = mrd_walk(nb, ndi->lazy_bind_off, ndi->lazy_bind_size, "lazy bind", &nlazy_ev);
    if (!rc) rc = mrd_same("bind", &bind, buf + di->bind_off, &nbind_ev,
                           nb + ndi->bind_off, &sel, rep->to, 0);
    if (!rc) rc = mrd_same("lazy bind", &lazy, buf + di->lazy_bind_off, &nlazy_ev,
                           nb + ndi->lazy_bind_off, &sel, rep->to, 1);
    if (!rc && s.st) {
        const struct nlist_64 *was = (const struct nlist_64 *)(buf + s.st->symoff);
        const struct nlist_64 *now = (const struct nlist_64 *)(nb + s.st->symoff);
        for (uint32_t q = 0; q < s.st->nsyms && !rc; q++) {
            struct nlist_64 expect = was[q];
            if (mrd_nlist_selected(buf, s.st, &was[q], &sel)) {
                uint16_t d = expect.n_desc;
                SET_LIBRARY_ORDINAL(d, (uint8_t)rep->to);
                expect.n_desc = d;
            }
            if (memcmp(&expect, &now[q], sizeof expect) != 0) {
                fprintf(stderr, WHAT ": verification failed: symbol-table entry %u is "
                                "not what the redirect meant it to be; refusing\n", q);
                rc = MR_REFUSED;
            }
        }
    }
    mrd_free3(&nbind_ev, &nlazy_ev, &nweak_ev);
    mrd_free3(&bind, &lazy, &weak);
    if (rc) { free(nb); return rc; }

    rep->bind_after = ndi->bind_size;
    rep->bind_off_after = ndi->bind_off;
    rep->linkedit_after = ns.linkedit ? ns.linkedit->filesize : 0;
    free(buf);
    *pbuf = nb;
    *psize = nsize;
    return 0;
}
