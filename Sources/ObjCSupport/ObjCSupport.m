#import "ObjCSupport.h"

NSException * _Nullable VJTryCatch(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *e) {
        return e;
    }
}
