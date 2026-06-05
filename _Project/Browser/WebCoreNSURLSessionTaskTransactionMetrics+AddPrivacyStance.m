#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSInteger BrowserPrivacyStanceUnknown(__unused id self, __unused SEL _cmd) {
    return 0;
}

@interface BrowserPrivacyStanceShim : NSObject
@end

@implementation BrowserPrivacyStanceShim

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class metricsClass = objc_getClass("WebCoreNSURLSessionTaskTransactionMetrics");
        if (metricsClass == Nil) {
            return;
        }

        SEL privateSelector = NSSelectorFromString(@"_privacyStance");
        SEL publicSelector = NSSelectorFromString(@"privacyStance");
        const char *typeEncoding = "q@:";

        if (class_getInstanceMethod(metricsClass, privateSelector) == NULL) {
            class_addMethod(metricsClass, privateSelector, (IMP)BrowserPrivacyStanceUnknown, typeEncoding);
        }

        if (class_getInstanceMethod(metricsClass, publicSelector) == NULL) {
            class_addMethod(metricsClass, publicSelector, (IMP)BrowserPrivacyStanceUnknown, typeEncoding);
        }
    });
}

@end
