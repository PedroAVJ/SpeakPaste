#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The host application most recently reported by UIKit's keyboard arbiter.
FOUNDATION_EXPORT NSString * _Nullable
SPHostApplicationCaptureLastBundleIdentifier(void);

/// Atomically copy the latest host and its generation under the same lock.
FOUNDATION_EXPORT NSString * _Nullable
SPHostApplicationCaptureCopySnapshot(uint64_t * _Nullable generation);

/// Monotonically increases whenever UIKit publishes an acceptable host.
FOUNDATION_EXPORT uint64_t SPHostApplicationCaptureGeneration(void);

/// Ask UIKit's keyboard arbiter to publish its current destination again.
/// Returns whether the lazy client existed and `checkConnection` was invoked.
FOUNDATION_EXPORT BOOL SPHostApplicationCaptureRefresh(void);

/// Drop the process-local value when this keyboard leaves its current host.
/// A durable bundle+PID record remains available through the App Group.
/// Returns the invalidation generation from the same locked operation.
FOUNDATION_EXPORT uint64_t SPHostApplicationCaptureInvalidate(void);

/// A non-sensitive diagnostic describing whether the early hook installed.
FOUNDATION_EXPORT NSString *SPHostApplicationCaptureStatus(void);

NS_ASSUME_NONNULL_END
