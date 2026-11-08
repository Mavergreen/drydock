/* objc-runtime-inventory.m -- capture the Objective-C runtime of the host it runs on, schema 1.
 *
 * This is shipyard's own measuring tool, not an analyzed program. It is meant to run once, by
 * hand, on a real clean floor host (Mac OS X 10.9.5, x86_64) through
 * scripts/objc-reference-set.sh capture; the facts it writes become a versioned input that is
 * used off-target. It refuses to measure, exit 4 and no output, when:
 *   - the OS version, build or architecture differs from --os/--build/--arch (a translated
 *     process counts as a different architecture);
 *   - any DYLD_* variable is set in its environment, except DYLD_FRAMEWORK_PATH when it is exactly the
 *     directory of the --override options;
 *   - an --override framework NAME does not load from DIR/NAME.framework/Versions/A/NAME, its file
 *     there lacks the declared SHA-256 or (with --require-signed) Apple-signed code, or NAME is also
 *     loaded from the system;
 *   - an image is loaded from outside /System/Library/ and /usr/lib/, other than the tool itself
 *     and images named by --allow-image (a test hook, accepted only with --diagnostic);
 *   - an image path mentions recaulk, or the Recaulk Objective-C activation root
 *     __recaulk_objc_activate resolves anywhere in the process;
 *   - a method named by --absent already resolves (a preexisting target backfill);
 *   - a --require image fails to load, or does not load under exactly that dyld image name;
 *   - with --require-signed, a system image is not on disk, its on-disk x86_64 UUID differs from
 *     the loaded one, or its code does not validate against "anchor apple";
 *   - a class, selector or encoding carries a byte that cannot go into a TSV field;
 *   - a probed class's +initialize does not return in its probe (below).
 * Every reason found is reported on stderr before exiting; nothing is written. --diagnostic
 * instead writes the capture with each reason as a "check refusal" row and "check mode
 * diagnostic", so an unclean host can be inspected; the reference builder refuses any capture
 * that is not "check mode production" with no refusal row.
 *
 * --runtime-output FILE (TSV) and --cluster-output FILE (JSON) are created exclusively: an
 * existing path is refused, and each is written to a temporary beside it and linked into place
 * only after both are complete. The TSV's first line is "# objc-runtime 1"; the rest is sorted
 * bytewise and unique, seven TAB-separated columns: 1 record, 2 subject, 3 kind, 4 name,
 * 5 value, 6 image, 7 detail. "-" fills an unused column.
 *   identity  KEY        -  -         VALUE                  -            -
 *   check     NAME       -  SUBJECT   RESULT                 -            -
 *             ("check initialize - CLASS changes": a class +initialize changes; see below)
 *   image     ID         -  PATH|-    UUID                   ROLE         SIGNATURE
 *   class     CLASS      -  SUPER|-   ROOT                   IMAGE-ID     -
 *   method    CLASS      +|-  SELECTOR  ENCODING|-           IMPL-IMAGE   active|shadowed
 *   witness   CLASS      +|-  SELECTOR  [+-]IMPLEMENTER|-    IMPL-IMAGE|- ROOT
 *   behavior  CLASS      -  SELECTOR  returns|raises:NAME    -            instance
 *   override  NAME       -  SOURCE    SHA256                 IMAGE-ID     SIGNATURE
 * ENCODING is "-" when the runtime has none and "(empty)" when it has an empty one.
 * Image IDs are dyld image basenames (a collision is cannot-measure); ROLE is self, required,
 * override, fixture or loaded; SIGNATURE is anchor-apple, not-checked, not-on-disk or invalid. An image
 * row names a path only for system images. No addresses, host names or user paths are written.
 * Rows describe each class as a program that messages it sees it, after its +initialize. Every
 * class of a required or fixture image that answers +class is first probed in a forked child,
 * which sends it +class and compares its superclass and own method lists (both kinds) before and
 * after. A class that changes is then sent +class here, before anything is listed, and gets a
 * "check initialize" row; the builder holds that set to a reviewed list. A class that does not
 * change is never initialized here, and one whose +initialize crashes or does not return within
 * 20 seconds is a refusal. (On 10.9.5, +[NSURLSession initialize] moves NSURLSession under
 * CFNetwork's __NSCFURLSession, where its factory methods live; its five siblings move alike.)
 * class rows cover every class the runtime lists. method rows, one per method-list entry, cover
 * classes whose image is required or fixture; the first entry for a selector is the one dispatch
 * uses ("active"), later ones are "shadowed". witness rows give, for every class and each
 * --root-selector, whether a class (+) or instance (-) message resolves through the class's own
 * method lists and superclass chain, read without sending any message, +initialize or
 * resolveInstanceMethod: included: the implementer is the class whose list has it, prefixed by
 * the list's kind (a class message on an NSObject-rooted class finds the root's instance
 * methods last). behavior rows record what an instance of each --behavior-class actually does
 * when sent each --behavior-selector (NSProxy's own methods forward rather than answer); that is
 * the only place this tool sends messages to classes other than the cluster probes below and
 * the +class of the +initialize probes above. Each
 * --behavior-selector must also be a --root-selector, and only description, isKindOfClass:
 * (sent NSObject) and respondsToSelector: (sent description) are accepted. The witness measures
 * every root selector's existence without a send, so a root selector that is unsafe to send to a
 * bare instance (release, performSelector:) never is.
 *
 * An override row records a framework the capture loaded from a private copy instead of the system:
 * the source its binary was copied from (as declared), the SHA-256 the loaded file was checked to
 * have, and its signature status; "check override-reason" says why. The image row is role override.
 *
 * The cluster JSON records, for a fixed reviewed list of NSString and NSMutableString
 * constructions, the concrete class each returns, its superclass chain and every instance
 * selector the chain implements below the public class. A missing public-class method is
 * then not mistaken for a missing method on the object the program really receives.
 *
 * Exit 0 measured, 2 usage, 4 cannot measure. */
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <signal.h>
#include <mach/mach.h>
#include <unistd.h>
#include <libkern/OSByteOrder.h>
#include <CommonCrypto/CommonDigest.h>

extern char **environ;

#define MAX_ARGS 64

struct strings { char **v; size_t n, cap; };
struct image { const char *name; const char *id; const char *role; char uuid[37]; const char *signature; };

static struct strings rows, refusals;
static struct image *images;
static size_t nimages;
static int malformed;
static const char *current_record = "-", *current_subject = "-";

static void die_usage(const char *why) {
    fprintf(stderr, "objc-runtime-inventory: %s\n"
        "usage: objc-runtime-inventory --os VERSION --build BUILD --arch ARCH\n"
        "       --runtime-output FILE --cluster-output FILE --require IMAGE... --root-selector SEL...\n"
        "       [--absent CLASS KIND SELECTOR]... [--behavior-class CLASS --behavior-selector SEL...]...\n"
        "       [--allow-image PATH]...\n"
        "       [--identity KEY VALUE]... [--override NAME DIR SHA256 SOURCE REASON]...\n"
        "       [--require-signed] [--diagnostic]\n", why);
    exit(2);
}
static void oom(void) { fprintf(stderr, "objc-runtime-inventory: out of memory\n"); exit(4); }
static void push(struct strings *s, char *v) {
    if (s->n == s->cap) {
        s->cap = s->cap ? 2 * s->cap : 1024;
        if (!(s->v = realloc(s->v, s->cap * sizeof *s->v))) oom();
    }
    s->v[s->n++] = v;
}
static void refuse(const char *format, ...) {
    va_list ap;
    char *m;
    va_start(ap, format);
    if (vasprintf(&m, format, ap) < 0) oom();
    va_end(ap);
    push(&refusals, m);
}
/* A field must be nonempty printable ASCII (spaces allowed: C++ names reach encodings); anything else would make the TSV
 * ambiguous, so it is a measurement failure, not something to escape silently. */
static const char *field(const char *s) {
    const unsigned char *p;
    if (!s || !*s) {
        if (!malformed) refuse("an empty field in a %s row for %s", current_record, current_subject);
        malformed = 1;
        return "-";
    }
    for (p = (const unsigned char *)s; *p; p++)
        if (*p < 0x20 || *p > 0x7e) {
            if (!malformed) refuse("an unrepresentable field in a %s row for %s: %s", current_record, current_subject, s);
            malformed = 1;
            return "-";
        }
    return s;
}
static void row(const char *rec, const char *subject, const char *kind, const char *name,
                const char *value, const char *image, const char *detail) {
    char *r;
    current_record = rec;
    current_subject = subject && *subject ? subject : "-";
    if (asprintf(&r, "%s\t%s\t%s\t%s\t%s\t%s\t%s", rec, field(subject), field(kind), field(name),
                 field(value), field(image), field(detail)) < 0) oom();
    push(&rows, r);
}
static int bytewise(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

static const char *base_name(const char *path) {
    const char *s = strrchr(path, '/');
    return s ? s + 1 : path;
}
static int system_path(const char *p) { return !strncmp(p, "/System/Library/", 16) || !strncmp(p, "/usr/lib/", 9); }

/* --override NAME DIR SHA256 SOURCE REASON: framework NAME must load from DIR/NAME.framework/Versions/A/NAME. */
struct override_ { const char *name, *dir, *sha, *source, *reason; char expected[PATH_MAX]; const char *signature; int loaded; };
static struct override_ overrides[8];
static size_t noverrides;
static int file_sha256(const char *path, char out[65]) {
    unsigned char buf[65536], md[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_CTX ctx;
    ssize_t n;
    int fd = open(path, O_RDONLY), k;
    if (fd < 0) return 0;
    CC_SHA256_Init(&ctx);
    while ((n = read(fd, buf, sizeof buf)) > 0) CC_SHA256_Update(&ctx, buf, (CC_LONG)n);
    close(fd);
    if (n < 0) return 0;
    CC_SHA256_Final(md, &ctx);
    for (k = 0; k < CC_SHA256_DIGEST_LENGTH; k++) snprintf(out + 2 * k, 3, "%02x", md[k]);
    return 1;
}
static int same_file(const char *a, const char *b) {
    char ra[PATH_MAX], rb[PATH_MAX];
    if (!strcmp(a, b)) return 1;
    return realpath(a, ra) && realpath(b, rb) && !strcmp(ra, rb);
}
static int plain_name(const char *s) {
    if (!*s) return 0;
    for (; *s; s++) if (!((*s >= 'A' && *s <= 'Z') || (*s >= 'a' && *s <= 'z') || (*s >= '0' && *s <= '9'))) return 0;
    return 1;
}
static int hex64(const char *s) {
    size_t k;
    for (k = 0; s[k]; k++) if (!((s[k] >= '0' && s[k] <= '9') || (s[k] >= 'a' && s[k] <= 'f'))) return 0;
    return k == 64;
}

static void format_uuid(const uint8_t *u, char out[37]) {
    snprintf(out, 37, "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
             u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7], u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15]);
}
/* LC_UUID of a mapped Mach-O header (64-bit, host byte order). */
static int header_uuid(const struct mach_header_64 *h, size_t limit, char out[37]) {
    const uint8_t *p = (const uint8_t *)(h + 1);
    size_t off = sizeof *h;
    uint32_t i;
    if (h->magic != MH_MAGIC_64) return 0;
    for (i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (off + sizeof *lc > limit || lc->cmdsize < sizeof *lc || off + lc->cmdsize > limit) return 0;
        if (lc->cmd == LC_UUID && lc->cmdsize >= sizeof(struct uuid_command)) {
            format_uuid(((const struct uuid_command *)lc)->uuid, out);
            return 1;
        }
        p += lc->cmdsize; off += lc->cmdsize;
    }
    return 0;
}
/* LC_UUID of the slice for this process's CPU type in a thin or fat file on disk; -1 when the
 * file does not exist, 0 when it cannot be read as Mach-O. Only the headers are read. */
static int disk_uuid(const char *path, char out[37]) {
    int fd = open(path, O_RDONLY), ok = 0;
    uint8_t head[4096], *cmds;
    uint64_t off = 0;
    struct mach_header_64 h;
    size_t len;
    if (fd < 0) return errno == ENOENT ? -1 : 0;
    if (pread(fd, head, sizeof head, 0) != (ssize_t)sizeof head) { close(fd); return 0; }
    if (OSSwapBigToHostInt32(*(uint32_t *)head) == FAT_MAGIC) {
        uint32_t n = OSSwapBigToHostInt32(((struct fat_header *)head)->nfat_arch), i;
        const struct fat_arch *fa = (const struct fat_arch *)(head + sizeof(struct fat_header));
        int found = 0;
        for (i = 0; i < n && sizeof(struct fat_header) + (i + 1) * sizeof *fa <= sizeof head; i++)
            if ((cpu_type_t)OSSwapBigToHostInt32(fa[i].cputype) == _dyld_get_image_header(0)->cputype) {
                off = OSSwapBigToHostInt32(fa[i].offset);
                found = 1;
            }
        if (!found) { close(fd); return 0; }
    }
    if (pread(fd, &h, sizeof h, (off_t)off) != (ssize_t)sizeof h || h.magic != MH_MAGIC_64 || h.sizeofcmds > (1 << 20)) { close(fd); return 0; }
    len = sizeof h + h.sizeofcmds;
    if (!(cmds = malloc(len))) oom();
    if (pread(fd, cmds, len, (off_t)off) == (ssize_t)len) ok = header_uuid((const struct mach_header_64 *)cmds, len, out);
    free(cmds);
    close(fd);
    return ok;
}
static const char *signature(const char *path) {
    SecStaticCodeRef code = NULL;
    SecRequirementRef req = NULL;
    CFURLRef url;
    OSStatus st;
    url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    if (!url) oom();
    st = SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &code);
    CFRelease(url);
    if (st) return "invalid";
    if (SecRequirementCreateWithString(CFSTR("anchor apple"), kSecCSDefaultFlags, &req)) { CFRelease(code); return "invalid"; }
    /* platform: 10.9.5's own codesign reports "resource envelope is obsolete" for its system
     *           frameworks' bundle resources; only the code is the measured identity here. */
    st = SecStaticCodeCheckValidity(code, kSecCSDoNotValidateResources, req);
    CFRelease(req);
    CFRelease(code);
    return st ? "invalid" : "anchor-apple";
}

static struct image *image_named(const char *name) {
    size_t i;
    if (!name) return NULL;
    for (i = 0; i < nimages; i++) if (!strcmp(images[i].name, name)) return &images[i];
    return NULL;
}
static const char *image_id_of_address(const void *addr) {
    Dl_info info;
    struct image *im;
    if (!addr || !dladdr(addr, &info) || !(im = image_named(info.dli_fname))) return "-";
    return im->id;
}
static const char *image_id_of_class(Class c) {
    struct image *im = image_named(class_getImageName(c));
    return im ? im->id : "-";
}
static Class root_of(Class c) {
    Class s;
    while ((s = class_getSuperclass(c))) c = s;
    return c;
}
/* The first method-list entry for `sel` in `c` alone, or NULL. */
static Method own_method(Class c, SEL sel) {
    unsigned n = 0, i;
    Method *m = class_copyMethodList(c, &n), found = NULL;
    for (i = 0; i < n && !found; i++) if (method_getName(m[i]) == sel) found = m[i];
    free(m);
    return found;
}
/* Resolution through method lists only: for an instance message the class chain; for a class
 * message the metaclass chain, whose root metaclass's superclass is the root class itself. */
static void witness(Class c, int classKind, SEL sel) {
    Class k = classKind ? object_getClass((id)c) : c;
    char implementer[512];
    for (; k; k = class_getSuperclass(k)) {
        Method m = own_method(k, sel);
        if (m) {
            snprintf(implementer, sizeof implementer, "%c%s", class_isMetaClass(k) ? '+' : '-', class_getName(k));
            row("witness", class_getName(c), classKind ? "+" : "-", sel_getName(sel), implementer,
                image_id_of_address((const void *)method_getImplementation(m)), class_getName(root_of(c)));
            return;
        }
    }
    row("witness", class_getName(c), classKind ? "+" : "-", sel_getName(sel), "-", "-", class_getName(root_of(c)));
}
static void methods(Class c, int classKind) {
    unsigned n = 0, i, j;
    Method *m = class_copyMethodList(classKind ? object_getClass((id)c) : c, &n);
    for (i = 0; i < n; i++) {
        int shadowed = 0;
        for (j = 0; j < i; j++) if (method_getName(m[j]) == method_getName(m[i])) shadowed = 1;
        row("method", class_getName(c), classKind ? "+" : "-", sel_getName(method_getName(m[i])),
            !method_getTypeEncoding(m[i]) ? "-" : *method_getTypeEncoding(m[i]) ? method_getTypeEncoding(m[i]) : "(empty)",
            image_id_of_address((const void *)method_getImplementation(m[i])), shadowed ? "shadowed" : "active");
    }
    free(m);
}
static int resolves(Class c, int classKind, SEL sel) {
    Class k = classKind ? object_getClass((id)c) : c;
    for (; k; k = class_getSuperclass(k)) if (own_method(k, sel)) return 1;
    return 0;
}

/* +initialize. What a class's own method lists and superclass are, as one number: a change to any
 * of them changes it (FNV-1a over the pointers, which a forked child shares with its parent). */
static uint64_t dispatch_state(Class c) {
    uint64_t h = 1469598103934665603ULL;
    int kind;
#define MIX(v) do { uint64_t x_ = (uint64_t)(uintptr_t)(v); int b_; for (b_ = 0; b_ < 8; b_++) { h ^= (x_ >> (8 * b_)) & 0xff; h *= 1099511628211ULL; } } while (0)
    MIX(class_getSuperclass(c));
    for (kind = 0; kind < 2; kind++) {
        unsigned n = 0, i;
        Method *m = class_copyMethodList(kind ? object_getClass((id)c) : c, &n);
        MIX(n);
        for (i = 0; i < n; i++) { MIX(sel_getName(method_getName(m[i]))); MIX(method_getImplementation(m[i])); MIX(method_getTypeEncoding(m[i])); }
        free(m);
    }
#undef MIX
    return h;
}
/* A probe child that caught signal N exits 64 + N (the parent reports "signal N"). */
static void probe_exit(int sig) { _exit(64 + sig); }
/* Whether initializing c changes it: 1 yes, 0 no, -1 its +initialize did not return. The class is
 * initialized in a forked child (by +class, the one message it is sent), so a class that does not
 * change is never initialized here, and one that crashes takes only the child with it. */
static int initialize_changes(Class c, int *how) {
    static const int sigs[] = { SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE, SIGALRM };
    int status;
    size_t i;
    pid_t pid;
    fflush(NULL);
    *how = -1;
    if ((pid = fork()) < 0) return -1;
    if (!pid) {
        int null = open("/dev/null", O_WRONLY);
        uint64_t before = dispatch_state(c);
        /* platform: a crash in the child is this tool's measurement, not a report for the user. */
        task_set_exception_ports(mach_task_self(), EXC_MASK_ALL, MACH_PORT_NULL, EXCEPTION_DEFAULT, THREAD_STATE_NONE);
        for (i = 0; i < sizeof sigs / sizeof *sigs; i++) signal(sigs[i], probe_exit);
        if (null >= 0) { dup2(null, 1); dup2(null, 2); }
        alarm(20);
        ((Class (*)(Class, SEL))objc_msgSend)(c, sel_registerName("class"));
        _exit(dispatch_state(c) == before ? 0 : 3);
    }
    while (waitpid(pid, &status, 0) < 0) if (errno != EINTR) return -1;
    *how = WIFEXITED(status) ? (WEXITSTATUS(status) > 64 ? 1000 + WEXITSTATUS(status) - 64 : WEXITSTATUS(status)) :
           WIFSIGNALED(status) ? 1000 + WTERMSIG(status) : -1;
    return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : WIFEXITED(status) && WEXITSTATUS(status) == 3 ? 1 : -1;
}
/* Every class of a required or fixture image that answers +class is probed; each one +initialize
 * changes is then initialized in this process, before anything is listed, and recorded.
 * platform: this runs as soon as those images load, before any code-signing check: a child forked
 *           after Security has validated code crashes in hundreds of AppKit initializers. */
static int probed_image(const char *name, char **require, size_t nrequire, char **allow, size_t nallow) {
    size_t j;
    char real[PATH_MAX];
    if (!name) return 0;
    for (j = 0; j < nrequire; j++) if (!strcmp(name, require[j])) return 1;
    for (j = 0; j < nallow; j++) if (!strcmp(name, allow[j]) || (realpath(allow[j], real) && !strcmp(name, real))) return 1;
    return 0;
}
static void initialize_changed(char **require, size_t nrequire, char **allow, size_t nallow) {
    unsigned n = 0, k;
    Class *cs = objc_copyClassList(&n), *changed;
    size_t nchanged = 0, i;
    SEL cls = sel_registerName("class");
    if (!cs) return;
    if (!(changed = calloc(n ? n : 1, sizeof *changed))) oom();
    for (k = 0; k < n; k++) {
        int r, how;
        if (!probed_image(class_getImageName(cs[k]), require, nrequire, allow, nallow) || !resolves(cs[k], 1, cls)) continue;
        if ((r = initialize_changes(cs[k], &how)) < 0)
            refuse("class %s: +initialize did not return in its probe (%s %d)", class_getName(cs[k]), how >= 1000 ? "signal" : "exit", how >= 1000 ? how - 1000 : how);
        else if (r) changed[nchanged++] = cs[k];
    }
    for (i = 0; i < nchanged; i++) {
        ((Class (*)(Class, SEL))objc_msgSend)(changed[i], cls);
        row("check", "initialize", "-", class_getName(changed[i]), "changes", "-", "-");
    }
    free(changed);
    free(cs);
}

static void behavior(const char *name, char **selectors, size_t nsel) {
    Class c = objc_getClass(name);
    size_t i;
    if (!c) { refuse("behavior class %s is not loaded", name); return; }
    for (i = 0; i < nsel; i++) {
        SEL sel = sel_registerName(selectors[i]);
        id object = class_createInstance(c, 0);
        char outcome[256] = "returns";
        id argument = nil;
        SEL query = NULL;
        if (!object) { refuse("cannot instantiate %s", name); return; }
        if (!strcmp(selectors[i], "isKindOfClass:")) argument = (id)objc_getClass("NSObject");
        else if (!strcmp(selectors[i], "respondsToSelector:")) query = sel_registerName("description");
        @try {
            if (argument) ((void (*)(id, SEL, id))(void (*)(void))objc_msgSend)(object, sel, argument);
            else if (query) ((void (*)(id, SEL, SEL))(void (*)(void))objc_msgSend)(object, sel, query);
            else ((void (*)(id, SEL))(void (*)(void))objc_msgSend)(object, sel);
        } @catch (NSException *e) {
            snprintf(outcome, sizeof outcome, "raises:%s", [[e name] UTF8String]);
        } @catch (id e) {
            snprintf(outcome, sizeof outcome, "raises:%s", object_getClassName(e));
        }
        row("behavior", name, "-", selectors[i], outcome, "-", "instance");
    }
}

/* ---- cluster probes ---------------------------------------------------------------------- */
static void json_string(NSMutableString *out, const char *s) {
    const unsigned char *p;
    [out appendString:@"\""];
    for (p = (const unsigned char *)s; *p; p++) {
        if (*p == '"' || *p == '\\') [out appendFormat:@"\\%c", *p];
        else if (*p < 0x20 || *p > 0x7e) [out appendFormat:@"\\u%04x", *p];
        else [out appendFormat:@"%c", *p];
    }
    [out appendString:@"\""];
}
static int selector_order(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }
static void probe(NSMutableString *out, int first, const char *id_, Class public, id object,
                  const char *const *construction) {
    Class c = object_getClass(object), k;
    struct strings below = {NULL, 0, 0};
    size_t i;
    [out appendString:first ? @"\n    {" : @",\n    {"];
    [out appendString:@"\"id\": "]; json_string(out, id_);
    [out appendString:@", \"class\": "]; json_string(out, class_getName(public));
    [out appendString:@", \"construction\": ["];
    for (i = 0; construction[i]; i++) { if (i) [out appendString:@", "]; json_string(out, construction[i]); }
    [out appendString:@"], \"concrete\": "]; json_string(out, class_getName(c));
    [out appendString:@", \"image\": "]; json_string(out, image_id_of_class(c));
    [out appendString:@", \"chain\": ["];
    for (k = c, i = 0; k; k = class_getSuperclass(k), i++) { if (i) [out appendString:@", "]; json_string(out, class_getName(k)); }
    [out appendString:@"], \"below\": ["];
    for (k = c; k && k != public; k = class_getSuperclass(k)) {
        unsigned n = 0, j;
        Method *m = class_copyMethodList(k, &n);
        for (j = 0; j < n; j++) {
            char *s;
            if (asprintf(&s, "%s %s", sel_getName(method_getName(m[j])), class_getName(k)) < 0) oom();
            push(&below, s);
        }
        free(m);
    }
    if (k != public) refuse("cluster probe %s: %s does not descend from %s", id_, class_getName(c), class_getName(public));
    qsort(below.v, below.n, sizeof *below.v, selector_order);
    for (i = 0; i < below.n; i++) {
        char *sp = strchr(below.v[i], ' ');
        if (i && !strcmp(below.v[i], below.v[i - 1])) continue;
        *sp = 0;
        [out appendString:i ? @", {\"selector\": " : @"{\"selector\": "]; json_string(out, below.v[i]);
        [out appendString:@", \"owner\": "]; json_string(out, sp + 1);
        [out appendString:@"}"];
        *sp = ' ';
    }
    [out appendString:@"]}"];
    for (i = 0; i < below.n; i++) free(below.v[i]);
    free(below.v);
}
/* The reviewed probe list: allocation alone, then each documented initializer and factory with
 * a multi-character argument (a one-character literal can return a cached constant string). */
static NSString *cluster_probes(void) {
    static const char text[] = "mavergreen cluster probe";
    static const char *const alloc_[] = {"+alloc", NULL};
    static const char *const init_[] = {"+alloc", "-initWithUTF8String:", NULL};
    static const char *const factory[] = {"+stringWithUTF8String:", NULL};
    NSMutableString *out = [NSMutableString stringWithString:@"{\n  \"schema\": 1,\n  \"argument\": "];
    Class s = [NSString class], m = [NSMutableString class];
    json_string(out, text);
    [out appendString:@",\n  \"probes\": ["];
    probe(out, 1, "NSString +alloc", s, [NSString alloc], alloc_);
    probe(out, 0, "NSString +alloc -initWithUTF8String:", s, [[NSString alloc] initWithUTF8String:text], init_);
    probe(out, 0, "NSString +stringWithUTF8String:", s, [NSString stringWithUTF8String:text], factory);
    probe(out, 0, "NSMutableString +alloc", m, [NSMutableString alloc], alloc_);
    probe(out, 0, "NSMutableString +alloc -initWithUTF8String:", m, [[NSMutableString alloc] initWithUTF8String:text], init_);
    probe(out, 0, "NSMutableString +stringWithUTF8String:", m, [NSMutableString stringWithUTF8String:text], factory);
    [out appendString:@"\n  ]\n}\n"];
    return out;
}

/* ---- output ------------------------------------------------------------------------------ */
static int write_all(int fd, const char *p, size_t n) {
    while (n) {
        ssize_t w = write(fd, p, n);
        if (w < 0) { if (errno == EINTR) continue; return -1; }
        p += w; n -= (size_t)w;
    }
    return 0;
}
static char *temporary(const char *dest, int *fd) {
    char *t;
    if (asprintf(&t, "%s.tmp.XXXXXX", dest) < 0) oom();
    if ((*fd = mkstemp(t)) < 0) { fprintf(stderr, "objc-runtime-inventory: cannot create beside %s: %s\n", dest, strerror(errno)); exit(4); }
    return t;
}

int main(int argc, char **argv) {
    const char *os = NULL, *build = NULL, *arch = NULL, *runtime_out = NULL, *cluster_out = NULL;
    char *require[MAX_ARGS], *allow[MAX_ARGS], *roots[MAX_ARGS], *behave[MAX_ARGS], *probe[MAX_ARGS], *absent[MAX_ARGS][3], *ident[MAX_ARGS][2];
    size_t nrequire = 0, nallow = 0, nroots = 0, nbehave = 0, nprobe = 0, nabsent = 0, nident = 0, i, j;
    int require_signed = 0, diagnostic = 0, a;
    const char *host_arch;
    char **e;
    struct stat st;
    @autoreleasepool {
    for (a = 1; a < argc; a++) {
        const char *o = argv[a];
        int left = argc - a - 1;
        if (!strcmp(o, "--require-signed")) { require_signed = 1; continue; }
        if (!strcmp(o, "--diagnostic")) { diagnostic = 1; continue; }
        if (left < 1 || argv[a + 1][0] == '-' ) die_usage(o);
        if (!strcmp(o, "--os") && !os) os = argv[++a];
        else if (!strcmp(o, "--build") && !build) build = argv[++a];
        else if (!strcmp(o, "--arch") && !arch) arch = argv[++a];
        else if (!strcmp(o, "--runtime-output") && !runtime_out) runtime_out = argv[++a];
        else if (!strcmp(o, "--cluster-output") && !cluster_out) cluster_out = argv[++a];
        else if (!strcmp(o, "--require") && nrequire < MAX_ARGS) require[nrequire++] = argv[++a];
        else if (!strcmp(o, "--allow-image") && nallow < MAX_ARGS) allow[nallow++] = argv[++a];
        else if (!strcmp(o, "--root-selector") && nroots < MAX_ARGS) roots[nroots++] = argv[++a];
        else if (!strcmp(o, "--behavior-class") && nbehave < MAX_ARGS) behave[nbehave++] = argv[++a];
        else if (!strcmp(o, "--behavior-selector") && nprobe < MAX_ARGS) probe[nprobe++] = argv[++a];
        else if (!strcmp(o, "--absent") && left >= 3 && nabsent < MAX_ARGS) {
            absent[nabsent][0] = argv[++a]; absent[nabsent][1] = argv[++a]; absent[nabsent][2] = argv[++a];
            if (strcmp(absent[nabsent][1], "+") && strcmp(absent[nabsent][1], "-")) die_usage("--absent kind must be + or -");
            nabsent++;
        } else if (!strcmp(o, "--identity") && left >= 2 && nident < MAX_ARGS) {
            ident[nident][0] = argv[++a]; ident[nident][1] = argv[++a]; nident++;
        } else if (!strcmp(o, "--override") && left >= 5 && noverrides < sizeof overrides / sizeof *overrides) {
            struct override_ *ov = &overrides[noverrides++];
            ov->name = argv[++a]; ov->dir = argv[++a]; ov->sha = argv[++a]; ov->source = argv[++a]; ov->reason = argv[++a];
            if (!plain_name(ov->name) || ov->dir[0] != '/' || !hex64(ov->sha) || ov->source[0] != '/' || !*ov->reason)
                die_usage("--override NAME DIR SHA256 SOURCE REASON: a plain name, absolute paths, a lowercase SHA-256, a reason");
            if (noverrides > 1 && strcmp(ov->dir, overrides[0].dir)) die_usage("every --override shares one directory");
            snprintf(ov->expected, sizeof ov->expected, "%s/%s.framework/Versions/A/%s", ov->dir, ov->name, ov->name);
            ov->signature = "not-loaded";
        } else die_usage(o);
    }
    if (!os || !build || !arch || !runtime_out || !cluster_out || !nrequire || !nroots) die_usage("missing a required option");
    if (!nbehave != !nprobe) die_usage("--behavior-class and --behavior-selector go together");
    for (i = 0; i < nprobe; i++) {
        for (j = 0; j < nroots && strcmp(roots[j], probe[i]); j++) ;
        if (j == nroots) die_usage("a --behavior-selector that is not a --root-selector");
        if (strcmp(probe[i], "description") && strcmp(probe[i], "isKindOfClass:") && strcmp(probe[i], "respondsToSelector:"))
            die_usage("a --behavior-selector this tool cannot send safely");
    }
    if (!lstat(runtime_out, &st) || !lstat(cluster_out, &st) || !strcmp(runtime_out, cluster_out)) {
        fprintf(stderr, "objc-runtime-inventory: refusing an existing or shared output path\n");
        return 4;
    }

    /* Identity. */
    {
        NSData *plist = [NSData dataWithContentsOfFile:@"/System/Library/CoreServices/SystemVersion.plist"];
        id v = plist ? [NSPropertyListSerialization propertyListWithData:plist options:0 format:NULL error:NULL] : nil;
        const char *hv = NULL, *hb = NULL;
        int translated = 0;
        size_t tl = sizeof translated;
        if ([v isKindOfClass:[NSDictionary class]]) {
            id pv = [v objectForKey:@"ProductVersion"], pb = [v objectForKey:@"ProductBuildVersion"];
            if ([pv isKindOfClass:[NSString class]]) hv = [pv UTF8String];
            if ([pb isKindOfClass:[NSString class]]) hb = [pb UTF8String];
        }
#if defined(__x86_64__)
        host_arch = "x86_64";
#elif defined(__arm64__)
        host_arch = "arm64";
#else
        host_arch = "unknown";
#endif
        if (!sysctlbyname("sysctl.proc_translated", &translated, &tl, NULL, 0) && translated) host_arch = "translated";
        if (!hv || strcmp(hv, os)) refuse("OS version %s, expected %s", hv ? hv : "(unreadable)", os);
        if (!hb || strcmp(hb, build)) refuse("OS build %s, expected %s", hb ? hb : "(unreadable)", build);
        if (strcmp(host_arch, arch)) refuse("architecture %s, expected %s", host_arch, arch);
        row("identity", "os", "-", "-", hv ? hv : "-", "-", "-");
        row("identity", "build", "-", "-", hb ? hb : "-", "-", "-");
        row("identity", "arch", "-", "-", host_arch, "-", "-");
        for (i = 0; i < nident; i++) row("identity", ident[i][0], "-", "-", ident[i][1], "-", "-");
    }
    /* Environment: the capture must see the OS as it ships, not as a variable rewrote it. */
    {
        size_t dyld = 0, framework = 0;
        for (e = environ; *e; e++)
            if (noverrides && !strncmp(*e, "DYLD_FRAMEWORK_PATH=", 20) && !strcmp(*e + 20, overrides[0].dir)) framework = 1;
            else if (!strncmp(*e, "DYLD_", 5)) {
                char name[128];
                size_t n = strcspn(*e, "=");
                snprintf(name, sizeof name, "%.*s", (int)(n < 100 ? n : 100), *e);
                refuse("dyld environment variable %s is set", name);
                dyld++;
            }
        if (noverrides && !framework) refuse("--override needs DYLD_FRAMEWORK_PATH=%s", overrides[0].dir);
        row("check", "dyld-environment", "-", "-", dyld ? "present" : framework ? "framework-override" : "none", "-", "-");
    }
    for (i = 0; i < nrequire; i++) if (!system_path(require[i])) refuse("required image %s is not a system path", require[i]);
    for (i = 0; i < nrequire; i++)
        if (system_path(require[i]) && !dlopen(require[i], RTLD_NOW | RTLD_GLOBAL)) refuse("required image failed to load: %s", dlerror());
    for (i = 0; i < nallow; i++)
        if (!dlopen(allow[i], RTLD_NOW | RTLD_GLOBAL)) refuse("fixture image failed to load: %s", dlerror());
    initialize_changed(require, nrequire, allow, nallow);

    /* Images. */
    nimages = _dyld_image_count();
    if (!(images = calloc(nimages, sizeof *images))) oom();
    {
        size_t nonsystem = 0, recaulk = 0;
        for (i = 0; i < nimages; i++) {
            struct image *im = &images[i];
            const char *name = _dyld_get_image_name((uint32_t)i);
            char ondisk[37];
            int d;
            if (!name) { refuse("dyld image %zu has no name", i); name = "-"; }
            im->name = name;
            im->id = base_name(name);
            if (!header_uuid((const struct mach_header_64 *)_dyld_get_image_header((uint32_t)i), 1 << 20, im->uuid)) {
                refuse("image %s has no readable LC_UUID", name);
                strcpy(im->uuid, "-");
            }
            if (strcasestr(name, "recaulk")) { refuse("Recaulk image loaded: %s", name); recaulk++; }
            if (i == 0) { im->role = "self"; im->id = "objc-runtime-inventory"; im->signature = "not-checked"; continue; }
            im->role = "loaded";
            for (j = 0; j < nrequire; j++) if (!strcmp(name, require[j])) im->role = "required";
            for (j = 0; j < noverrides; j++) {
                struct override_ *ov = &overrides[j];
                char sum[65];
                if (!same_file(name, ov->expected)) {
                    char frag[256];
                    snprintf(frag, sizeof frag, "/%s.framework/", ov->name);
                    if (system_path(name) && strstr(name, frag) && !strcmp(base_name(name), ov->name))
                        refuse("%s is loaded from the system (%s), not the override", ov->name, name);
                    continue;
                }
                im->role = "override";
                im->id = ov->name;
                ov->loaded = 1;
                d = disk_uuid(name, ondisk);
                if (d <= 0 || strcmp(ondisk, im->uuid)) { im->signature = "invalid"; refuse("override image %s on disk does not match the loaded image", ov->name); }
                else im->signature = require_signed ? signature(name) : "not-checked";
                if (require_signed && strcmp(im->signature, "anchor-apple")) refuse("override image %s is %s, not anchor-apple", ov->name, im->signature);
                if (!file_sha256(name, sum) || strcmp(sum, ov->sha)) refuse("override image %s does not have SHA-256 %s", ov->name, ov->sha);
                ov->signature = im->signature;
            }
            if (!strcmp(im->role, "override")) continue;
            for (j = 0; j < nallow; j++) {
                char real[PATH_MAX];
                if (!strcmp(name, allow[j]) || (realpath(allow[j], real) && !strcmp(name, real))) im->role = "fixture";
            }
            if (strcmp(im->role, "fixture") && !system_path(name)) { refuse("non-system image loaded: %s", name); nonsystem++; }
            if (!strcmp(im->role, "fixture") && !diagnostic) refuse("fixture image loaded outside --diagnostic: %s", name);
            im->signature = "not-checked";
            if (!strcmp(im->role, "fixture") || !system_path(name)) continue;
            d = disk_uuid(name, ondisk);
            if (d < 0) im->signature = "not-on-disk";
            else if (!d || strcmp(ondisk, im->uuid)) {
                im->signature = "invalid";
                refuse("image %s on disk does not match the loaded image", name);
            } else if (require_signed) im->signature = signature(name);
            if (require_signed && strcmp(im->signature, "anchor-apple"))
                refuse("image %s is %s, not anchor-apple", name, im->signature);
        }
        for (i = 0; i < nimages; i++)
            for (j = i + 1; j < nimages; j++)
                if (!strcmp(images[i].id, images[j].id)) refuse("two images share the basename %s", images[i].id);
        for (j = 0; j < nrequire; j++)
            if (!image_named(require[j])) refuse("required image %s did not load under that dyld name", require[j]);
        for (j = 0; j < noverrides; j++) {
            if (!overrides[j].loaded) refuse("override %s did not load from %s", overrides[j].name, overrides[j].expected);
            row("override", overrides[j].name, "-", overrides[j].source, overrides[j].sha, overrides[j].name, overrides[j].signature);
            row("check", "override-reason", "-", overrides[j].name, overrides[j].reason, "-", "-");
        }
        if (dlsym(RTLD_DEFAULT, "__recaulk_objc_activate")) { refuse("the Recaulk activation root __recaulk_objc_activate is loaded"); recaulk++; }
        row("check", "nonsystem-images", "-", "-", nonsystem ? "present" : "none", "-", "-");
        row("check", "fixture-images", "-", "-", nallow ? "present" : "none", "-", "-");
        row("check", "recaulk", "-", "-", recaulk ? "present" : "absent", "-", "-");
        row("check", "signatures", "-", "-", require_signed ? "required" : "not-required", "-", "-");
        for (i = 0; i < nimages; i++)
            row("image", images[i].id, "-", (i && system_path(images[i].name)) ? images[i].name : "-",
                images[i].uuid, images[i].role, images[i].signature);
    }
    for (i = 0; i < nroots; i++) row("check", "root-selector", "-", roots[i], "reviewed", "-", "-");
    for (i = 0; i < nabsent; i++) {
        Class c = objc_getClass(absent[i][0]);
        int present = c && resolves(c, !strcmp(absent[i][1], "+"), sel_registerName(absent[i][2]));
        char subject[512];
        if (!c) refuse("--absent class %s is not loaded", absent[i][0]);
        if (present) refuse("preexisting backfill: %s[%s %s] already resolves", absent[i][1], absent[i][0], absent[i][2]);
        snprintf(subject, sizeof subject, "%s%s", absent[i][1], absent[i][0]);
        row("check", "absent", "-", absent[i][2], present ? "present" : "absent", "-", subject);
    }

    /* Classes, methods, witnesses. */
    {
        unsigned n = 0, k;
        Class *cs = objc_copyClassList(&n);
        if (!cs || !n) refuse("the runtime lists no classes");
        for (k = 0; k < n; k++) {
            Class c = cs[k], s = class_getSuperclass(c);
            struct image *im = image_named(class_getImageName(c));
            /* A class made at run time (objc_allocateClassPair) belongs to no image. */
            row("class", class_getName(c), "-", s ? class_getName(s) : "-", class_getName(root_of(c)),
                im ? im->id : "-", im ? "-" : "runtime-allocated");
            if (im && (!strcmp(im->role, "required") || !strcmp(im->role, "fixture"))) { methods(c, 1); methods(c, 0); }
            for (i = 0; i < nroots; i++) {
                SEL sel = sel_registerName(roots[i]);
                witness(c, 1, sel);
                witness(c, 0, sel);
            }
        }
        free(cs);
    }
    for (i = 0; i < nbehave; i++) behavior(behave[i], probe, nprobe);

    {
        NSString *cluster = cluster_probes();
        const char *cj = [cluster UTF8String];
        int rfd, cfd;
        char *rt, *ct;
        int bad = 0;
        for (i = 0; i < refusals.n; i++) fprintf(stderr, "objc-runtime-inventory: refused: %s\n", refusals.v[i]);
        if (refusals.n && !diagnostic) return 4;
        row("check", "mode", "-", "-", diagnostic ? "diagnostic" : "production", "-", "-");
        for (i = 0; i < refusals.n; i++) {
            char *p;
            for (p = refusals.v[i]; *p; p++) if ((unsigned char)*p < 0x20 || (unsigned char)*p > 0x7e) *p = 0x3f;
            row("check", "refusal", "-", "-", refusals.v[i], "-", "-");
        }
        if (malformed) { fprintf(stderr, "objc-runtime-inventory: refused: a name, encoding or reason is unrepresentable\n"); return 4; }
        qsort(rows.v, rows.n, sizeof *rows.v, bytewise);
        rt = temporary(runtime_out, &rfd);
        ct = temporary(cluster_out, &cfd);
        bad |= write_all(rfd, "# objc-runtime 1\n", 17);
        for (i = 0; i < rows.n && !bad; i++) {
            if (i && !strcmp(rows.v[i], rows.v[i - 1])) continue;
            bad |= write_all(rfd, rows.v[i], strlen(rows.v[i])) | write_all(rfd, "\n", 1);
        }
        bad |= write_all(cfd, cj, strlen(cj));
        bad |= fsync(rfd) | fsync(cfd) | close(rfd) | close(cfd);
        if (bad || link(rt, runtime_out)) { unlink(rt); unlink(ct); fprintf(stderr, "objc-runtime-inventory: cannot write %s: %s\n", runtime_out, strerror(errno)); return 4; }
        if (link(ct, cluster_out)) { unlink(runtime_out); unlink(rt); unlink(ct); fprintf(stderr, "objc-runtime-inventory: cannot write %s: %s\n", cluster_out, strerror(errno)); return 4; }
        unlink(rt); unlink(ct);
    }
    }
    return 0;
}
