/* Fixture: a switch whose bound check is followed by SSE arithmetic before its jump table's lea, as
 * the pinned clang22 writes it at -O3 (checked when this fixture was written):
 *     cmp idx, N-1 ; ja default ; divsd ; divsd ; mov ; lea R, [rip + table] ;
 *     movsxd D, dword [R + I*4] ; add D, R ; jmp D
 * the shape of upstream iTerm2 3.0.15's +[PseudoTerminal drawArrangementPreview:screenFrames:]
 * (movapd/divpd between its ja and lea). tests/objc/objc-reader-test.sh links it with
 * -no_data_in_code_info, as iTerm2 ships (an empty LC_DATA_IN_CODE), so no data-in-code entry marks
 * the table. Each case sends to the dictionary argument (rdx), which a case knows only from the
 * state at the jmp. Never run. */
#import <Foundation/Foundation.h>

@interface Probe : NSObject
+ (void)preview:(NSDictionary *)d kind:(int)k a:(NSPoint)a b:(NSPoint)b;
@end

@implementation Probe
+ (void)preview:(NSDictionary *)d kind:(int)k a:(NSPoint)a b:(NSPoint)b {
    NSPoint s = NSMakePoint(a.x / b.x, a.y / b.y);
    switch (k) {
    case 0: [d objectForKey:@"zero"]; NSLog(@"%f", s.x); break;
    case 1: [d objectForKey:@"one"]; NSLog(@"%f", s.y); break;
    case 2: [d description]; NSLog(@"%f %f", s.x, s.y); break;
    case 3: [d count]; NSLog(@"%f", s.x + s.y); break;
    case 4: [d allKeys]; NSLog(@"%f", s.x * s.y); break;
    case 5: [d allValues]; NSLog(@"%f", s.x - s.y); break;
    }
}
@end

int main(int argc, char **argv) {
    (void)argv;
    [Probe preview:nil kind:argc a:NSMakePoint(1, 2) b:NSMakePoint(3, 4)];
    return 0;
}
