/* demangle-v0.h -- the Rust v0 symbol parser (demangle-v0.c), shared by binding.c and resolve. */
#ifndef DRYDOCK_OBJC_DEMANGLE_V0_H
#define DRYDOCK_OBJC_DEMANGLE_V0_H
#include <stddef.h>
#include <stdint.h>

typedef struct V0Path {
    char kind, ns;               /* C N M X Y I */
    const char *ident;
    uint64_t dis;
    struct V0Path *parent;       /* N, I: the inner path */
    struct V0Path *impl_path;    /* M, X: where the impl lives */
    struct V0Path *self_type;    /* M, X, Y: the self type when it is a path, else NULL */
    const char *self_text;       /* M, X, Y: the self type's display text */
    const char *text;
} V0Path;

typedef struct V0Block V0Block;
typedef struct {
    const char *s; size_t n, pos;
    V0Block *blocks;
    unsigned depth, steps;
    int in_type;                 /* generic args print "<..>" in a type, "::<..>" in a value path */
    int rust;                    /* print as rustc-demangle's "{:#}" does (v0_parse_rust) */
    uint64_t bound;              /* rust: late-bound lifetimes in scope */
    size_t used;                 /* rust: arena bytes, bounded */
    size_t top_end;              /* where the symbol's own path ends, before any instantiating crate */
    int ncrates_top;             /* crates[] entries the symbol's own path names */
    char why[160];
    struct { const char *id; uint64_t dis; } crates[64];   /* every crate root parsed */
    int ncrates, crates_overflow;
} V0;

/* Parse `symbol` (Mach-O form "__R..." or "_R..."); a trailing ".suffix" (LLVM's ".llvm.N",
 * ".0") and an instantiating-crate path are accepted and ignored. NULL with p->why on refusal. */
V0Path *v0_parse(V0 *p, const char *symbol);
/* The same, printing paths as rustc-demangle 0.1's alternate form does. */
V0Path *v0_parse_rust(V0 *p, const char *symbol);
void v0_release(V0 *p);
const char *v0_ns_text(V0 *p, char ns, const char *id, uint64_t dis);
/* The crate root a path is defined under, or NULL. */
const V0Path *v0_crate_root(const V0Path *q);
/* A disambiguator as rustc spells it between "s" and "_" (base-62, offset by one); "" for none. */
void v0_dis_text(uint64_t dis, char *out, size_t outsz);

#endif
