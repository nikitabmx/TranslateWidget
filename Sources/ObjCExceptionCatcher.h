#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bridges Objective-C `@try/@catch` into Swift. AVAudioEngine raises
/// uncatchable-from-Swift `NSException`s on bad formats/state; wrapping the
/// risky call here turns those into a thrown Swift error instead of `abort()`.
@interface ObjCExceptionCatcher : NSObject
+ (BOOL)try:(void (NS_NOESCAPE ^)(void))block error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
