#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// block を実行し、Objective-C の例外が出たらつかまえて返す（出なければ nil）。
/// AVFoundation などは失敗を例外で知らせることがあり、Swift からはつかまえられないため。
NSException * _Nullable VJTryCatch(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
