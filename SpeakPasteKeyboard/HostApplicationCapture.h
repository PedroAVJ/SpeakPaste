#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The host application most recently reported by UIKit's keyboard arbiter.
FOUNDATION_EXPORT NSString * _Nullable
SPHostApplicationCaptureLastBundleIdentifier(void);

/// Ask UIKit's keyboard arbiter to publish its current destination again.
FOUNDATION_EXPORT void SPHostApplicationCaptureRefresh(void);

/// A non-sensitive diagnostic describing whether the early hook installed.
FOUNDATION_EXPORT NSString *SPHostApplicationCaptureStatus(void);

NS_ASSUME_NONNULL_END
