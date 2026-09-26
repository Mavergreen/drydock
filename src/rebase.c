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
        if (type != REBASE_TYPE_POINTER && type != REBASE_TYPE_TEXT_ABSOLUTE32)
            return mrb_fail(out, why, whysz, MRB_MALFORMED,
                            "the rebase at byte %zu has rebase type %u, which dyld does not accept",
                            here, type);
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
                        "the rebase opcode at byte %zu has a ULEB that runs off the stream or "
                        "past 64 bits", here);
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

int mrb_has_type(const mrb_set *s, uint8_t seg, uint64_t off, uint8_t type) {
    const mrb_slot *v = s->v;
    size_t n = s->n, lo = 0, hi = n;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (v[mid].seg < seg || (v[mid].seg == seg && v[mid].off < off)) lo = mid + 1;
        else hi = mid;
    }
    for (; lo < n && v[lo].seg == seg && v[lo].off == off; lo++)
        if (v[lo].type == type) return 1;
    return 0;
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
        if (v[k].type != REBASE_TYPE_POINTER) return MRB_MALFORMED;
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
