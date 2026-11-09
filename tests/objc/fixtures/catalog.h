__attribute__((objc_root_class, availability(macos,introduced=10.0)))
@interface OldBase
+ (long)sharedName;
- (long)sharedName;
- (void)oldMethod;
- (long)scalar:(long)value;
@end

__attribute__((availability(macos,introduced=10.10)))
@interface LaterClass : OldBase
@property(readonly) long reading;
@property(getter=currentValue, setter=updateValue:) long value;
@end

@interface OldBase (Extras)
- (void)futureMethod __attribute__((availability(macos,introduced=10.12)));
- (void)deprecatedMethod __attribute__((availability(macos,introduced=10.1,deprecated=10.8)));
- (void)unavailableMethod __attribute__((unavailable));
@end

@protocol ProbeProtocol
@optional
- (void)maybe;
@end

@interface Adopter : OldBase <ProbeProtocol>
@end

@class ForwardOnly;
@protocol ForwardProtocol;

@protocol ParentProtocol
- (void)requiredMethod;
@end
@protocol ChildProtocol <ParentProtocol>
@property(readonly) long protocolReading;
@end

/* Parameter facts: each declared parameter's SysV x86_64 GPRs, and variadic. */
typedef struct _NSRange { unsigned long location; unsigned long length; } NSRange;
typedef struct { double x; double y; } DDPoint;
typedef struct { long a; long b; long c; } DDTriple;
typedef struct { long l; double d; } DDMixed;
typedef union { long l; double d; } DDEither;
typedef struct { unsigned int low : 4; unsigned int high : 4; } DDBits;
@interface Probe : OldBase
- (void)r:(NSRange)r;
- (void)d:(double)d;
- (id)f:(id)fmt, ...;
- (void)point:(DDPoint)p;
- (void)triple:(DDTriple)t;
- (void)mixed:(DDMixed)m;
- (void)either:(DDEither)e;
- (void)bits:(DDBits)b;
- (void)wide:(long double)w;
- (void)o:(id)o at:(NSRange)r count:(int)n flag:(signed char)b;
@property(readonly) long probeReading;
@end

void dd_fatal(const char *, int) __attribute__((noreturn));
void dd_fatal(const char *, int) __attribute__((noreturn));
_Noreturn void dd_c11(int code);
int dd_log(const char *, ...);
int dd_twice();
int dd_twice(int a, int b);
double dd_round(double x);
void dd_none(void);

/* Classifier cases: each parameter's GPRs, and a C function's hidden sret pointer. */
typedef enum { DDRed, DDGreen } DDColor;
typedef enum : __int128 { DDHuge = 1 } DDWideEnum;
typedef struct { struct { int a; int b; } s; long c; } DDNested;
typedef struct { double d; int i; } DDDoubleInt;
typedef struct __attribute__((packed)) { char c; long l; } DDPacked;
@interface Probe (Classes)
- (void)flag:(_Bool)b;
- (void)color:(DDColor)c;
- (void)wideEnum:(DDWideEnum)e;
- (void)i128:(__int128)i;
- (void)block:(void (^)(int))b;
- (void)array:(id [])objects;
- (void)nested:(DDNested)n;
- (void)doubleInt:(DDDoubleInt)d;
- (void)packed:(DDPacked)p;
- (DDTriple)bigResult:(int)n;
@end
struct big { long a; long b; long c; };
struct big dd_big(int n);
NSRange dd_range(void);
void dd_array(int a[4]);
