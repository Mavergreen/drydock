#import <Foundation/Foundation.h>

void mrc_unit(NSObject *o);
void mrc_unit(NSObject *o) {
    [[o retain] release];
}
