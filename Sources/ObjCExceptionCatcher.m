#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (BOOL)try:(void (NS_NOESCAPE ^)(void))block error:(NSError * _Nullable * _Nullable)error {
    @try {
        block();
        return YES;
    }
    @catch (NSException *exception) {
        if (error) {
            NSString *message = [NSString stringWithFormat:@"%@: %@",
                                 exception.name, exception.reason ?: @""];
            *error = [NSError errorWithDomain:@"ObjCException"
                                         code:0
                                     userInfo:@{NSLocalizedDescriptionKey: message}];
        }
        return NO;
    }
}

@end
