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
