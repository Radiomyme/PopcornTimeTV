#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bridges an @try/@catch block into Swift. Returns YES if `block`
/// completes normally, NO if any NSException is raised.
@interface ObjCExceptionCatcher : NSObject

+ (BOOL)run:(void (^)(void))block;

@end

NS_ASSUME_NONNULL_END
