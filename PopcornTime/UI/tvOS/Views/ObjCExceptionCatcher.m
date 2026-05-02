#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (BOOL)run:(void (^)(void))block {
    @try {
        block();
        return YES;
    }
    @catch (NSException *exception) {
        NSLog(@"[ObjCExceptionCatcher] swallowed %@: %@", exception.name, exception.reason);
        return NO;
    }
}

@end
