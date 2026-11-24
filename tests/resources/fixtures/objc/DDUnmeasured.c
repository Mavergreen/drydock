extern void *NSApp;

struct class_ro { unsigned flags, instance_start, instance_size, reserved; const void *ivar_layout; const char *name;
                  const void *methods, *protocols, *ivars, *weak_ivar_layout, *properties; };
struct class_t { void *isa; void *superclass; void *cache; void *vtable; const struct class_ro *data; };

static const struct class_ro ro = { 0, 8, 8, 0, 0, "DDUnmeasured", 0, 0, 0, 0, 0 };
__attribute__((section("__DATA,__objc_data"))) struct class_t DDUnmeasured = { 0, &NSApp, 0, 0, &ro };
__attribute__((section("__DATA,__objc_classlist,regular,no_dead_strip"), used))
static struct class_t *const classlist[] = { &DDUnmeasured };
