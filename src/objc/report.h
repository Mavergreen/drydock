/* report.h -- the analysis records every objc-compat module shares, and their lifetime.
 *
 * Stage entry points return 0 when the stage measured, 4 after appending a cannot-measure
 * error; strict policy's 1 for blocking findings is the front end's (main.m). The reader and
 * binding adapter produce observations (evidence), binding mappings and cannot-measure errors;
 * the reference loader the versioned facts; classify.c one finding with a verdict per send.
 *
 * Every stored string is a heap copy owned by the ObjcAnalysis. Unknown values are NULL,
 * never a guessed name. */
#ifndef OBJC_COMPAT_REPORT_H
#define OBJC_COMPAT_REPORT_H
#include <stddef.h>
#include <stdint.h>

#define OBJC_OK            0
#define OBJC_CANNOT_MEASURE 4

typedef enum {
    /* Conventional Objective-C metadata. */
    OBJC_EV_CLASS_DEF,       /* __objc_classlist entry: name=class, owner=superclass or NULL; symbol "root"
                              * when the superclass slot is a measured null, "unmeasured" when unreadable */
    OBJC_EV_CATEGORY_DEF,    /* __objc_catlist entry: name=category, owner=target class */
    OBJC_EV_METHOD_DEF,      /* owner=class, method_kind=+/-, selector; name=category or NULL */
    OBJC_EV_SELREF,          /* __objc_selrefs slot at address: selector */
    OBJC_EV_CLASSREF,        /* __objc_classrefs/__objc_superrefs slot: name=class */
    OBJC_EV_METADATA_USE,    /* code at address reads a selref/classref slot at target */
    /* objc2 lazily cached producers. */
    OBJC_EV_SEL_CACHE,       /* static at address, symbol; selector from its fetch site bytes */
    OBJC_EV_CLASS_CACHE,     /* static at address, symbol; name=class from its fetch site */
    OBJC_EV_CACHE_FETCH,     /* code at address passes cache target + literal to fetch */
    OBJC_EV_CACHE_USE,       /* code at address references cache target other than to fetch */
    /* Runtime registration/lookup with a recovered literal argument. */
    OBJC_EV_SEL_REGISTER,    /* call at address; name=callee; selector=literal */
    OBJC_EV_CLASS_LOOKUP,    /* call at address; name=callee; owner=literal class */
    /* Dispatch/allocation entry points (receiver/selector proof is a later stage). */
    OBJC_EV_DISPATCH_CALL,   /* call/jump at address to name=callee */
    /* A runtime method registration (class_addMethod) call at address; name=callee. It must lie
     * in code provider.c attests, or the artifact is cannot-measure. */
    OBJC_EV_METHOD_REGISTRATION
} ObjcEvidenceKind;

/* Where a register value at a dispatch site came from, as the reader's per-function value
 * propagation measured it. `ref` is the cache static, reference slot, literal, producing call
 * site or argument register (0 rdi .. 5 r9) the form names; `text` the recovered name, if any. */
typedef enum {
    OBJC_VAL_NONE,          /* the entry point takes no such operand (objc_alloc's selector) */
    OBJC_VAL_UNKNOWN,       /* nothing this reader models: a field, a computed value, a merge */
    OBJC_VAL_ARGUMENT,      /* the enclosing function's incoming argument register ref */
    OBJC_VAL_SEL_CACHE,     /* loaded from, or fetched into, objc2 selector cache ref */
    OBJC_VAL_CLASS_CACHE,   /* loaded from, or fetched into, objc2 class cache ref */
    OBJC_VAL_SELREF,        /* loaded from __objc_selrefs slot ref */
    OBJC_VAL_CLASSREF,      /* loaded from __objc_classrefs slot ref */
    OBJC_VAL_SEL_LITERAL,   /* sel_registerName/Sel::register_unchecked of the C string at ref */
    OBJC_VAL_CLASS_LITERAL, /* objc_getClass-family lookup of the C string at ref */
    OBJC_VAL_SEL_NSSTRING,  /* NSSelectorFromString(NSString::from_str(bytes at ref, len)) */
    OBJC_VAL_RESULT         /* the return value of the dispatch call at site ref */
} ObjcValueForm;

typedef struct {
    ObjcValueForm form;
    uint64_t ref;
    char *text;
} ObjcValue;

/* A path condition at a dispatch site: on every direct path the reader follows to the site, the
 * BOOL result of the dispatch at `site` was tested (`test al, al` then je/jne) and found `value`
 * (1 YES, 0 NO), and that dispatch has not run again since. Blocks reached only indirectly carry
 * none; a merge keeps only the conditions every predecessor carries. */
typedef struct { uint64_t site; int value; } ObjcCond;
#define OBJC_MAX_CONDS 8

typedef struct {
    ObjcEvidenceKind kind;
    char *slice;        /* lipo-style arch of the slice, e.g. "x86_64" */
    uint64_t address;   /* VM address of the record or code site */
    uint64_t target;    /* referenced slot/cache, 0 when none */
    char *owner;
    char *method_kind;  /* "+", "-" or NULL */
    char *selector;
    char *name;
    char *symbol;       /* raw symbol naming the record, or NULL */
    /* OBJC_EV_DISPATCH_CALL only: the receiver, selector and first argument operands. */
    ObjcValue receiver, sel, arg;
    char *function;     /* the symbol of the function containing a code site, or NULL */
    ObjcCond conds[OBJC_MAX_CONDS]; size_t nconds;   /* OBJC_EV_DISPATCH_CALL only */
    /* OBJC_EV_DISPATCH_CALL only: 0 for a call measured once; for one call a compiler merged from
     * several sends (macho-reader.c, split per incoming path), the address of the instruction that
     * ends this record's predecessor path -- one record per path, each with that path's operands. */
    uint64_t incoming;
    /* The image the record was read from: 0 the artifact, k a shipped image (shipped[k - 1]). Only
     * class, category and method definitions come from shipped images (main.m "The shipped closure"). */
    size_t image;
} ObjcEvidence;

/* A dylib load command of a measured slice: how is load, weak, reexport, lazy or upward. */
typedef struct { char *slice, *path, *how; } ObjcDylib;

/* A non-system image the artifact loads, found inside the shipped root and read for its interface
 * only (main.m "The shipped closure"): its classes, categories, methods, loads and run paths. */
typedef struct {
    char *path;          /* realpath, relative to the shipped root */
    char *abs;           /* realpath */
    char *sha256;
    char *install;       /* the load command's path that first named it */
    char *how;           /* that load command's kind: load or reexport */
    size_t loader;       /* the image that loads it: 0 the artifact, k shipped[k - 1] */
    ObjcDylib *dylibs; size_t n_dylibs;
    char **rpaths; size_t n_rpaths;
    size_t classes;      /* class definitions read from it */
} ObjcShipped;

/* A cache static mapped through the binding adapter. Values come from the demangled symbol
 * and, only when a binding receipt supplies them, the source-declared class and kind. */
typedef struct {
    size_t evidence;    /* index of the OBJC_EV_SEL_CACHE / OBJC_EV_CLASS_CACHE record */
    char *form;         /* inherent-method, trait-method, free-fn or closure */
    char *crate;
    char *rust_owner;   /* impl self type or enclosing path, display form */
    char *rust_fn;
    char *demangled;
    char *receiver;     /* from a receipt only; NULL means unknown */
    char *method_kind;  /* from a receipt only */
    char *provenance;   /* the receipt's source column, or NULL */
} ObjcBinding;

typedef struct {
    char *code;         /* stable reason, e.g. "computed-selector-producer" */
    char *slice;        /* NULL when the failure is not slice-specific */
    uint64_t address;
    char *detail;
} ObjcError;

/* A declared result, from the SDK signature companion (tools/objc-sdk-inventory.c header). */
typedef struct {
    char *record, *owner, *method_kind, *selector, *result_kind, *result_class, *source;
} ObjcSignature;

/* An interface and its declared superclass ("-" for a root), from the eleven-column facts. */
typedef struct { char *name, *super; } ObjcClassFact;

/* One dispatch site's receiver/use closure. Closed: receiver and method_kind set, reason NULL.
 * Open: receiver NULL (never guessed) and reason says what is missing. */
typedef enum {
    OBJC_ORIGIN_OPEN,       /* receiver unknown */
    OBJC_ORIGIN_MEASURED,   /* class operand, allocation or declared result, binary only */
    OBJC_ORIGIN_RECEIPT,    /* the reviewed binding receipt */
    OBJC_ORIGIN_R2,         /* reviewed Rust monomorphized type evidence (source-evidence.c) */
    OBJC_ORIGIN_DOWNCAST,   /* a proven isKindOfClass: YES on the same value (classify.c) */
    OBJC_ORIGIN_SOURCE,     /* a provider body's source receipt, by its line table (source-evidence.c) */
    OBJC_ORIGIN_R3          /* a reviewed positional row (source-evidence.c) */
} ObjcOrigin;

/* Where an open receiver comes from, as far as the reader models it (binding.c): R3 checks a row's
 * stated position against it. */
typedef enum { OBJC_RECV_OTHER, OBJC_RECV_RESULT, OBJC_RECV_ARGUMENT, OBJC_RECV_UNMODELLED } ObjcRecvFrom;

typedef struct {
    size_t evidence;    /* index of the OBJC_EV_DISPATCH_CALL record */
    char *selector;     /* NULL when the selector itself is unresolved */
    char *receiver;
    char *method_kind;
    char *basis;        /* how the receiver was closed, or the chain that failed */
    char *reason;
    ObjcOrigin origin;
    int allocated;      /* the receiver is the direct result of +alloc of `receiver` */
    int exact;          /* receiver is exactly that class (a class operand), not a subclass */
    char *provenance;   /* source citation of a receipt/R2/R3 row, or NULL */
    ObjcRecvFrom recv_from;   /* an open receiver's modelled origin */
    size_t recv_send;         /* OBJC_RECV_RESULT: the dispatch evidence whose result it is */
} ObjcSend;

/* ---- reference set (reference.c) ---- */
typedef struct ObjcMap ObjcMap;   /* string -> string, owned; see reference.c */
ObjcMap *objc_map_create(void);
void objc_map_destroy(ObjcMap *m);
/* 0 stored, 1 key already present (value left), -1 out of memory. */
int objc_map_put(ObjcMap *m, const char *key, const char *value);
const char *objc_map_get(const ObjcMap *m, const char *key);

typedef struct { char *name, *super, *root, *image; } ObjcRtClass;
typedef struct {
    char *id, *cls, *construction, *concrete;   /* construction: space-joined steps */
    char **chain; size_t nchain;
    char **below; size_t nbelow;                /* selectors resolving below `cls` */
} ObjcClusterProbe;

/* ---- source receipt (tools/objc-source-inventory.c writes it, source-evidence.c reads it) ---- */
typedef struct { char *label, *sha256; } ObjcSourceInput;
typedef struct {
    char *file, *form, *kind, *selector, *receiver, *type, *owner;
    uint32_t sl, sc, el, ec;            /* the expression's extent */
    uint32_t *anchors; size_t nanchors; /* line, column pairs of enclosing statement starts */
} ObjcSourceRow;
/* One row of an archive member's line table at its final address, inside the verified atom [lo, hi). */
typedef struct { uint64_t addr, lo, hi; char *file; uint32_t line, col; } ObjcLine;

/* ---- build evidence (main.m parses it, source-evidence.c checks it) ---- */
typedef struct { char *demangled, *selector, *receiver, *kind, *provenance; } ObjcReceiptRow;
typedef struct { char *name, *version, *checksum, *disambiguator; } ObjcCrate;
typedef struct { char *rust_type, *cls, *source; } ObjcTypeMap;
typedef struct {
    char *id, *symbol, *rust_type, *position, *kind, *source;
    char **selectors; size_t nselectors;
    int used;
} ObjcTypeEvidence;
/* R3: a reviewed positional row (build evidence `position_evidence`; source-evidence.c header). */
typedef struct {
    char *id, *symbol, *kind, *cls, *form, *position_selector, *rust_type, *field, *source;
    char **selectors; size_t nselectors;
    int used;
} ObjcPositionEvidence;
typedef struct {
    char *id, *symbol, *selector, *guard_selector, *fallback;
    char *source_file, *source_sha256, *source_revision, *patches_sha256, *features;
    uint64_t source_line;
    char *review_status, *reviewer, *review_reason;
    int used;
} ObjcGuardRecord;

typedef enum { OBJC_FLOOR_SUPPORTED, OBJC_PROVIDED, OBJC_GUARDED, OBJC_UNSUPPORTED, OBJC_UNRESOLVED } ObjcVerdict;
typedef struct {
    char *id;
    size_t send;        /* index into sends */
    ObjcVerdict verdict;
    char *framework;    /* image/framework of the implementation or later declaration, or NULL */
    char *closure;      /* measured | receipt | R1 | R2 | downcast | source | NULL (receiver open) */
    char *proof;        /* the basis of the verdict, or why it is unresolved */
    char *alternatives; /* space-joined classes a receiver could still be, or NULL */
    int r1;             /* availability rests on the R1 root-method witness */
    size_t image;       /* the image whose code closed it: 0 none (the floor, or nothing), 1 the
                         * artifact, k + 1 shipped[k - 1] */
    char *deviation;    /* the objc-api deviation record excusing this blocking finding, or NULL (main.m) */
} ObjcFinding;

typedef struct {
    char *artifact_path;
    char *binding_receipt_path;   /* optional */
    char *signatures_path;        /* optional: companion signatures, schema 1 */
    char *facts_path;             /* optional: eleven-column SDK facts, for superclasses */
    uint64_t limit_undecoded_bytes; /* code bytes the decoder could not walk (sweep-checked) */
    ObjcEvidence *evidence; size_t n_evidence, cap_evidence;
    ObjcBinding *bindings;  size_t n_bindings, cap_bindings;
    ObjcError *errors;      size_t n_errors, cap_errors;
    ObjcSignature *signatures; size_t n_signatures, cap_signatures;
    ObjcClassFact *classes; size_t n_classes, cap_classes;
    ObjcSend *sends;        size_t n_sends, cap_sends;
    int references_loaded;
    /* Analyzer pipeline (main.m) only; the reader driver leaves these empty. */
    int findings_mode;            /* open sends become unresolved findings, not errors */
    int metadata_only;            /* read only load commands and Objective-C metadata, no code */
    char **rpaths; size_t n_rpaths;               /* the measured slice's LC_RPATHs */
    ObjcShipped *shipped; size_t n_shipped;       /* the shipped closure beyond the artifact (main.m) */
    char **image_paths; size_t n_image_paths;     /* 0 the artifact's path relative to the root, k shipped[k - 1]'s */
    ObjcDylib *dylibs;      size_t n_dylibs, cap_dylibs;
    char *references_dir;         /* versioned set: runtime/newer/cluster facts load from here */
    char *runtime_os, *runtime_build, *runtime_arch;   /* the manifest's runtime identity */
    char **manifest_roots; size_t n_manifest_roots;     /* the manifest's root_selectors */
    char **manifest_exceptions; size_t n_manifest_exceptions; int have_manifest_exceptions;  /* root_exceptions */
    /* root_subset_exceptions: "SELECTOR\tKINDS\tCLASS CLASS ..." per entry, KINDS "+-", "+" or "-" */
    char **manifest_subsets; size_t n_manifest_subsets; int have_manifest_subsets;
    char *runtime_tool_sha256;    /* the capture tool source the manifest names (the witness identity) */
    char **r1_exceptions; size_t n_r1_exceptions;  /* measured non-implementing classes; set only when they are the reviewed ones */
    /* The classes the analyzed closure defines (classify.c objc_measure_class_roots): "CLASS\tROOT" per
     * measured class, a reason naming each class or dependency that keeps R1 off receivers of unknown
     * class, and whether R1 applies to them (the reader refuses run-time class creation outright). */
    char **class_roots; size_t n_class_roots;
    char **roots_blocking; size_t n_roots_blocking;
    char **uncaptured_deps; size_t n_uncaptured_deps;
    int r1_unknown;
    ObjcRtClass *rt_classes; size_t n_rt_classes, cap_rt_classes;
    ObjcMap *rt_class, *rt_method, *rt_witness, *rt_behavior, *rt_image_role, *rt_override;
    ObjcMap *nw_method, *nw_class, *fl_method, *fl_class, *nw_later_sel;
    char **root_selectors; size_t n_root_selectors;
    size_t n_witness;
    ObjcClusterProbe *probes; size_t n_probes;
    /* Build evidence, schema 1 (NULL/0 when none was given). */
    int have_build_evidence;
    char *be_artifact_sha256, *be_source_revision, *be_patches_sha256, *be_features;
    char *artifact_sha256;        /* measured by the front end */
    ObjcReceiptRow *receipt; size_t n_receipt;
    ObjcCrate *crates; size_t n_crates;
    ObjcTypeMap *typemap; size_t n_typemap;
    ObjcTypeEvidence *types; size_t n_types;
    ObjcPositionEvidence *positions; size_t n_positions;
    ObjcGuardRecord *guards; size_t n_guards;
    /* A source receipt (--source-receipt), and whether it was given. */
    char *src_path, *src_sha256, *src_sdk, *src_libclang;
    ObjcSourceInput *src_inputs; size_t n_src_inputs;
    ObjcSourceRow *src_rows; size_t n_src_rows;
    ObjcFinding *findings;  size_t n_findings, cap_findings;
    /* Providers (provider.c): declarations from --provider-prefix, their build evidence and what
     * verification found. */
    struct ObjcProvider *providers; size_t n_providers;
    ObjcMap *nw_encoding;         /* newer SDK: "class\tkind\tselector" -> type encoding */
} ObjcAnalysis;

ObjcAnalysis *objc_analysis_create(void);
void objc_analysis_destroy(ObjcAnalysis *a);
/* Copies the strings. Return 0, or -1 when out of memory (which also records an error). */
int objc_set_string(char **slot, const char *value);
int objc_add_evidence(ObjcAnalysis *a, const ObjcEvidence *ev);
int objc_add_binding(ObjcAnalysis *a, const ObjcBinding *b);
/* Always returns OBJC_CANNOT_MEASURE, so a stage can `return objc_fail(...)`. */
int objc_fail(ObjcAnalysis *a, const char *code, const char *slice, uint64_t address,
              const char *fmt, ...) __attribute__((format(printf, 5, 6)));

/* Stage entry point: reads artifact_path's x86_64 code and metadata, then maps cache symbols
 * through the binding adapter. 0 = measured, 4 = at least one cannot-measure error. */
int objc_collect_artifacts(ObjcAnalysis *a);

/* binding.c, used by the reader. */
typedef enum { OBJC_FETCH_NONE, OBJC_FETCH_SEL, OBJC_FETCH_CLASS, OBJC_WRAP_SEL_CSTR,
               OBJC_WRAP_NSSTRING } ObjcFetchForm;
/* Whether `symbol` names a supported objc2 producer function: CachedSel/CachedClass::fetch
 * (objc2 0.6), Sel::register_unchecked (a selector from a C string; also the out-of-line body an
 * inlined fetch calls), or objc2-foundation 0.3's NSString::from_str (bytes + length). Anything
 * else, including an unparsable symbol, is OBJC_FETCH_NONE. */
ObjcFetchForm objc_binding_fetch_form(const char *symbol);
/* Whether `symbol` is an objc2 cache static (...::CACHED_SEL / ...::CACHED_CLASS):
 * 1 selector cache, 2 class cache, 0 neither. Mach-O suffixes like ".llvm.N" are ignored. */
int objc_binding_cache_kind(const char *symbol);
/* Maps every cache record in `a` through its symbol and the optional receipt. */
int objc_bind_caches(ObjcAnalysis *a);
/* Display demangling for diagnostics/tests; returns a malloc'd string or NULL. */
char *objc_binding_demangle(const char *symbol, char *why, size_t whysz);

/* reference.c: loads signatures_path and facts_path when set. 0 = loaded (or nothing asked),
 * 4 = unreadable or malformed. */
int objc_load_references(ObjcAnalysis *a);
int objc_add_signature(ObjcAnalysis *a, const ObjcSignature *s);
int objc_add_class_fact(ObjcAnalysis *a, const ObjcClassFact *c);
int objc_add_send(ObjcAnalysis *a, const ObjcSend *s);
/* Receiver/use closure (binding.c) over collected evidence, bindings and loaded references:
 * one ObjcSend per dispatch call. 0 = every send closed, 4 = at least one stays open. */
int objc_close_sends(ObjcAnalysis *a);

int objc_add_dylib(ObjcAnalysis *a, const char *slice, const char *path, const char *how);
int objc_add_finding(ObjcAnalysis *a, const ObjcFinding *f);
/* Duplicate a string array element-wise into *out; -1 out of memory. */
int objc_strv_push(char ***v, size_t *n, const char *s);

/* reference.c: the versioned set's runtime capture, newer-SDK catalog and floor declarations,
 * from references_dir (manifest already verified by the front end). 0 or 4. */
int objc_load_reference_set(ObjcAnalysis *a);
/* R1's reviewed root methods: whether KIND SEL is one (either kind of a root selector); the kinds
 * SEL's recorded subset covers ("+-", "+", "-", or NULL without a record); and the measured
 * non-implementing classes for KIND SEL, space-separated: the recorded subset when it covers KIND,
 * else the reviewed six. KIND NULL asks for both kinds at once, their union, so a one-kind record
 * (+class) gives the six. */
int objc_r1_reviewed(const ObjcAnalysis *a, const char *kind, const char *sel);
void objc_r1_selector_exceptions(const ObjcAnalysis *a, const char *kind, const char *sel, char *out, size_t outsz);
const char *objc_r1_subset_kinds(const ObjcAnalysis *a, const char *sel);
int objc_add_probe(ObjcAnalysis *a, const ObjcClusterProbe *p);

/* binding.c: the v0 helpers source-evidence.c needs. objc_binding_impl_types writes the
 * display text of an impl's self type and every generic argument in `symbol`'s path,
 * NUL-separated, into buf; and crates "name=disambiguator" pairs, NUL-separated, into cbuf.
 * 0 parsed, -1 refused (why set). */
int objc_binding_symbol_types(const char *symbol, char *buf, size_t bufsz, char *cbuf, size_t cbufsz,
                              char *why, size_t whysz);

/* source-evidence.c: R2 and guard records against the artifact. 0 or 4. */
int objc_check_build_evidence(ObjcAnalysis *a);
/* R3: close open sends by reviewed positional rows, after downcast refinement. 0 or 4. */
int objc_apply_position_evidence(ObjcAnalysis *a);
int objc_apply_type_evidence(ObjcAnalysis *a);
/* The source receipt: parse it (0 or 4), and close open sends in verified provider code with it. */
int objc_load_source_receipt(ObjcAnalysis *a, const char *path);
int objc_apply_source_receipt(ObjcAnalysis *a);
/* DWARF 2-5 .debug_line of one object, rows at object addresses; see source-evidence.c. */
typedef struct { uint64_t addr; char *file; uint32_t line, col; int end; } ObjcDwarfRow;
/* `reloc` says whether the operand at a section offset is a supported address relocation and
 * gives its object address; 0 yes, -1 no. 0 parsed, -1 refused (why set). */
int objc_dwarf_lines(const uint8_t *sect, size_t size, const uint8_t *line_str, size_t line_str_size,
                     int (*reloc)(void *ctx, uint64_t off, uint64_t *addr), void *ctx,
                     ObjcDwarfRow **rows, size_t *nrows, char *why, size_t whysz);
/* The reviewed guard record for the dispatch evidence at index `ev` (its function and
 * selector), or NULL. */
const ObjcGuardRecord *objc_guard_record(ObjcAnalysis *a, size_t ev);

/* classify.c: closure (open sends become findings), R2, downcast refinement, then one verdict
 * per send. 0 measured, 4 cannot-measure. */
int objc_classify_findings(ObjcAnalysis *a);
const char *objc_verdict_name(ObjcVerdict v);
/* The floor capture's role for a dependency path (required, loaded, override...), or NULL when the
 * capture did not load it. */
const char *objc_floor_role(const ObjcAnalysis *a, const char *path);

/* ---- a read-only view of a linked image's x86_64 slice (macho-reader.c) ----
 * The same bounded load-command, symbol, stub/GOT and bind tables the reader uses, kept open for
 * provider.c. Opening records failures as cannot-measure errors in `a` and no dylibs. */
typedef struct ObjcImage ObjcImage;
int objc_image_open(ObjcAnalysis *a, const char *path, ObjcImage **out);
void objc_image_close(ObjcImage *im);
/* File bytes for [va, va+len) inside one section with file backing, or NULL. */
const uint8_t *objc_image_bytes(const ObjcImage *im, uint64_t va, uint64_t len);
size_t objc_image_nsections(const ObjcImage *im);
/* Section i: "SEG,SECT" name, address, size and flags. */
const char *objc_image_section(const ObjcImage *im, size_t i, uint64_t *addr, uint64_t *size, uint32_t *flags);
/* The section holding va (as objc_image_section), or NULL. */
const char *objc_image_section_of(const ObjcImage *im, uint64_t va, uint64_t *addr, uint64_t *size, uint32_t *flags);
/* The imported symbol a stub, GOT or lazy pointer at va stands for, or NULL. */
const char *objc_image_import_at(const ObjcImage *im, uint64_t va);
/* The symbol a data slot at va is bound to, or NULL. */
const char *objc_image_bound_at(const ObjcImage *im, uint64_t va);
/* The library a stub, GOT or lazy pointer (import_lib) or a bound data slot (bound_lib) at va binds
 * its symbol to: the install name of the dylib its two-level ordinal names, or a parenthesized
 * account of a special lookup ("(flat lookup)", "(the main executable)", ...); NULL when nothing is
 * there. */
const char *objc_image_import_lib_at(const ObjcImage *im, uint64_t va);
const char *objc_image_bound_lib_at(const ObjcImage *im, uint64_t va);
/* 1 when a defined symbol `name` is at `va`, else 0. */
int objc_image_has_symbol(const ObjcImage *im, const char *name, uint64_t va);

/* ---- providers (provider.c; main.m parses their JSON) ---- */
typedef struct { char *member, *symbol; uint64_t address, size; } ObjcProviderAtom;
typedef struct { char *name, *sha256; } ObjcProviderMember;
typedef struct ObjcProvider {
    /* The validated declaration (PREFIX/share/recaulk/objc-providers.json). */
    char *provider_id, *cls, *method_kind, *selector, *encoding, *impl_symbol, *root_symbol;
    char **frameworks; size_t nframeworks;
    char *archive;              /* PREFIX/build.archive_path, resolved */
    char *archive_sha256;       /* measured, and equal to the declared digest */
    char *declaration_sha256;   /* measured */
    char *sdk_settings_sha256;   /* declared: the SDK the archive was built against */
    char *source_inputs;         /* declared source_inputs_receipt: `SHA256  LABEL` lines */
    /* Its build evidence; have_evidence 0 when none names this provider. */
    int have_evidence;
    char *ev_declaration_sha256, *ev_archive_sha256;
    ObjcProviderMember *members; size_t n_members;
    ObjcProviderAtom *atoms; size_t n_atoms;
    /* Verification. */
    int active;
    char *reason;               /* why inactive, or what made it active */
    uint64_t constructor;       /* final address of the attested constructor, or 0 */
    size_t verified;            /* atoms verified byte for byte */
    uint64_t *ranges; size_t n_ranges;   /* [lo, hi) pairs of verified provider code and data */
    ObjcLine *lines; size_t n_lines;     /* line rows of the linked members, by final address (with a receipt) */
} ObjcProvider;

int objc_add_provider(ObjcAnalysis *a, ObjcProvider **out);
/* Verify every provider against the artifact and refuse unattested method registrations; with a
 * source receipt, also map each linked member's line table to final addresses. 0 or 4. */
int objc_verify_providers(ObjcAnalysis *a);
/* After classification: turn the unsupported sends an active provider answers into `provided`. */
int objc_provide_findings(ObjcAnalysis *a);
/* The build-evidence side: map each provider's archive members through a link map, cross-checked
 * against the prestrip image's symbols, after proving the final and prestrip images carry the
 * same section bytes. Fills members/atoms (none when the archive is not in the link). 0 or 4. */
int objc_map_provider_link(ObjcAnalysis *a, const char *final, const char *prestrip, const char *link_map);
#endif
