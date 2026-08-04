#import "HostApplicationCapture.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>

// iOS 26.4 moved keyboard-host identity into this arbiter callback. Installing
// from +load is intentional: the initial focus event can precede Swift view
// controller initialization. The technique is adapted from the MIT-licensed
// KeyboardHostBundleID project; its notice is retained in THIRD_PARTY_NOTICES.

static NSString *const SPArbiterClientClassName = @"_UIKeyboardArbiterClient";
static NSString *const SPDestinationClassName =
    @"_UIKeyboardArbiterClientInputDestination";
static NSString *const SPEnabledSelectorName = @"enabled";
static NSString *const SPSharedClientSelectorName =
    @"automaticSharedArbiterClient";
static NSString *const SPRefreshSelectorName = @"checkConnection";
static NSString *const SPChangedSelectorName =
    @"queue_keyboardChanged:onComplete:";
static NSString *const SPSourceBundleIdentifierKey =
    @"_sourceBundleIdentifier";

static os_unfair_lock SPHostCaptureLock = OS_UNFAIR_LOCK_INIT;
static NSString *_Nullable SPHostCaptureBundleIdentifier;
static NSString *SPHostCaptureInstallStatus = @"not-installed";
static IMP _Nullable SPOriginalKeyboardChangedImplementation;

static BOOL SPIsObjectType(const char *_Nullable type) {
    if (type == NULL) return NO;
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' ||
           *type == 'O' || *type == 'R' || *type == 'V') {
        type += 1;
    }
    return *type == '@';
}

static BOOL SPIsAcceptableHostBundleIdentifier(NSString *_Nullable value) {
    if (![value isKindOfClass:NSString.class]) return NO;
    NSString *bundleIdentifier = [value
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL hasBundleShape = [bundleIdentifier containsString:@"."] ||
        [bundleIdentifier.lowercaseString isEqualToString:@"pinterest"];
    NSString *ownBundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    NSString *containingBundleIdentifier = ownBundleIdentifier;
    if ([ownBundleIdentifier hasSuffix:@".Keyboard"]) {
        containingBundleIdentifier = [ownBundleIdentifier
            substringToIndex:ownBundleIdentifier.length - @".Keyboard".length];
    }
    if (bundleIdentifier.length == 0 ||
        !hasBundleShape ||
        [bundleIdentifier isEqualToString:@"<null>"] ||
        [bundleIdentifier isEqualToString:@"(null)"] ||
        [bundleIdentifier isEqualToString:ownBundleIdentifier] ||
        [bundleIdentifier isEqualToString:containingBundleIdentifier]) {
        return NO;
    }

    NSString *lowercased = bundleIdentifier.lowercaseString;
    if ([lowercased isEqualToString:@"com.apple.springboard"] ||
        [lowercased isEqualToString:@"com.apple.spotlight"] ||
        [lowercased isEqualToString:@"com.apple.uikitsystemapp"] ||
        [lowercased hasPrefix:@"com.apple.inputmethod."]) {
        return NO;
    }
    return YES;
}

static void SPSetInstallStatus(NSString *status) {
    os_unfair_lock_lock(&SPHostCaptureLock);
    SPHostCaptureInstallStatus = [status copy];
    os_unfair_lock_unlock(&SPHostCaptureLock);
}

static void SPCommitHostBundleIdentifier(NSString *_Nullable value) {
    if (!SPIsAcceptableHostBundleIdentifier(value)) return;
    os_unfair_lock_lock(&SPHostCaptureLock);
    SPHostCaptureBundleIdentifier = [value copy];
    os_unfair_lock_unlock(&SPHostCaptureLock);
}

static void SPSwizzledKeyboardChanged(
    id self,
    SEL selector,
    id _Nullable change,
    id _Nullable completion
) {
    if (change != nil) {
        @try {
            id value = [change valueForKey:SPSourceBundleIdentifierKey];
            if ([value isKindOfClass:NSString.class]) {
                SPCommitHostBundleIdentifier((NSString *)value);
            }
        } @catch (__unused NSException *exception) {
            // The callback must always reach UIKit's original implementation.
        }
    }

    if (SPOriginalKeyboardChangedImplementation != NULL) {
        ((void (*)(id, SEL, id, id))SPOriginalKeyboardChangedImplementation)(
            self,
            selector,
            change,
            completion
        );
    }
}

static BOOL SPAlwaysEnableKeyboardArbiter(
    __unused id self,
    __unused SEL selector
) {
    return YES;
}

static void SPInstallHostCapture(void) {
    Class clientClass = NSClassFromString(SPArbiterClientClassName);
    if (clientClass == Nil) {
        SPSetInstallStatus(@"client-class-missing");
        return;
    }

    SEL enabledSelector = NSSelectorFromString(SPEnabledSelectorName);
    Method enabledMethod = class_getClassMethod(clientClass, enabledSelector);
    if (enabledMethod != NULL) {
        method_setImplementation(
            enabledMethod,
            (IMP)&SPAlwaysEnableKeyboardArbiter
        );
    }

    Class destinationClass = NSClassFromString(SPDestinationClassName);
    if (destinationClass == Nil) {
        SPSetInstallStatus(@"destination-class-missing");
        return;
    }

    SEL changedSelector = NSSelectorFromString(SPChangedSelectorName);
    Method changedMethod = class_getInstanceMethod(
        destinationClass,
        changedSelector
    );
    if (changedMethod == NULL || method_getNumberOfArguments(changedMethod) != 4) {
        SPSetInstallStatus(@"change-callback-missing");
        return;
    }

    char *returnType = method_copyReturnType(changedMethod);
    char *changeType = method_copyArgumentType(changedMethod, 2);
    char *completionType = method_copyArgumentType(changedMethod, 3);
    BOOL signatureMatches = returnType != NULL && returnType[0] == 'v' &&
        SPIsObjectType(changeType) && SPIsObjectType(completionType);
    free(returnType);
    free(changeType);
    free(completionType);
    if (!signatureMatches) {
        SPSetInstallStatus(@"change-callback-signature-rejected");
        return;
    }

    SPOriginalKeyboardChangedImplementation =
        method_getImplementation(changedMethod);
    method_setImplementation(
        changedMethod,
        (IMP)&SPSwizzledKeyboardChanged
    );
    SPSetInstallStatus(@"installed");
}

@interface SPHostApplicationCaptureInstaller : NSObject
@end

@implementation SPHostApplicationCaptureInstaller

+ (void)load {
    if (@available(iOS 26.4, *)) {
        SPInstallHostCapture();
    } else {
        SPSetInstallStatus(@"legacy-ios");
    }
}

@end

NSString *_Nullable SPHostApplicationCaptureLastBundleIdentifier(void) {
    os_unfair_lock_lock(&SPHostCaptureLock);
    NSString *bundleIdentifier = [SPHostCaptureBundleIdentifier copy];
    os_unfair_lock_unlock(&SPHostCaptureLock);
    return SPIsAcceptableHostBundleIdentifier(bundleIdentifier)
        ? bundleIdentifier
        : nil;
}

void SPHostApplicationCaptureRefresh(void) {
    if (@available(iOS 26.4, *)) {
        Class clientClass = NSClassFromString(SPArbiterClientClassName);
        SEL sharedClientSelector =
            NSSelectorFromString(SPSharedClientSelectorName);
        if (clientClass == Nil ||
            ![(id)clientClass respondsToSelector:sharedClientSelector]) {
            return;
        }

        id (*getClient)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id client = getClient((id)clientClass, sharedClientSelector);
        SEL refreshSelector = NSSelectorFromString(SPRefreshSelectorName);
        if (client != nil && [client respondsToSelector:refreshSelector]) {
            void (*refresh)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
            refresh(client, refreshSelector);
        }
    }
}

NSString *SPHostApplicationCaptureStatus(void) {
    os_unfair_lock_lock(&SPHostCaptureLock);
    NSString *status = [SPHostCaptureInstallStatus copy];
    os_unfair_lock_unlock(&SPHostCaptureLock);
    return status;
}
