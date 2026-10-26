#import "MenuBarNativeBridge.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

// The runtime bridge follows Hidden Bar's MIT-licensed native visibility engine.
// See docs/VISUAL_SOURCES.md. Private API failure must leave the bar visible.
static Class MWHConfigurationClass;
static Class MWHAssertionClass;
static BOOL MWHSignature(Class cls, SEL selector, NSUInteger count, char result) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != count) return NO;
    char *type = method_copyReturnType(method);
    BOOL valid = type && type[0] == result;
    if (type) free(type);
    for (unsigned int i = 2; valid && i < count; i++) {
        char *argument = method_copyArgumentType(method, i);
        valid = argument && argument[0] == '@';
        if (argument) free(argument);
    }
    return valid;
}
BOOL MWHMenuBarNativeAvailable(void) {
    if (!dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW | RTLD_LOCAL)) return NO;
    MWHConfigurationClass = NSClassFromString(@"MBAssessmentModeConfiguration");
    MWHAssertionClass = NSClassFromString(@"MBAssessmentModeAssertion");
    return MWHConfigurationClass && MWHAssertionClass
        && MWHSignature(MWHConfigurationClass, NSSelectorFromString(@"initWithAllowedSystemItems:allowedBundleIdentifiers:"), 4, '@')
        && MWHSignature(MWHAssertionClass, NSSelectorFromString(@"activateWithConfiguration:completionHandler:"), 4, 'v')
        && MWHSignature(MWHAssertionClass, NSSelectorFromString(@"invalidate"), 2, 'v');
}
void MWHMenuBarActivate(NSArray<NSString *> *allowedBundles, void (^completion)(id, NSError *)) {
    NSLock *lock = [[NSLock alloc] init];
    __block BOOL completed = NO;
    void (^finish)(id, NSError *) = ^(id handle, NSError *error) {
        [lock lock];
        BOOL wasCompleted = completed;
        completed = YES;
        [lock unlock];
        if (wasCompleted) { if (handle) MWHMenuBarInvalidate(handle); return; }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(handle, error); });
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        finish(nil, [NSError errorWithDomain:@"MacWindowHide.MenuBar" code:3 userInfo:@{NSLocalizedDescriptionKey:@"The menu bar interface did not respond in time."}]);
    });
    if (!MWHMenuBarNativeAvailable()) {
        finish(nil, [NSError errorWithDomain:@"MacWindowHide.MenuBar" code:1 userInfo:@{NSLocalizedDescriptionKey:@"This macOS version does not expose the expected menu bar interface."}]);
        return;
    }
    @try {
        NSMutableArray<NSNumber *> *systemItems = [NSMutableArray array];
        for (NSInteger i = 0; i < 64; i++) [systemItems addObject:@(i)];
        id configuration = ((id (*)(id, SEL, id, id))objc_msgSend)([MWHConfigurationClass alloc], NSSelectorFromString(@"initWithAllowedSystemItems:allowedBundleIdentifiers:"), systemItems, allowedBundles);
        id assertion = [[MWHAssertionClass alloc] init];
        ((void (*)(id, SEL, id, void (^)(NSError *)))objc_msgSend)(assertion, NSSelectorFromString(@"activateWithConfiguration:completionHandler:"), configuration, ^(NSError *error) {
            finish(error ? nil : assertion, error);
        });
    } @catch (NSException *exception) {
        finish(nil, [NSError errorWithDomain:@"MacWindowHide.MenuBar" code:2 userInfo:@{NSLocalizedDescriptionKey:exception.reason ?: @"Menu bar interface failed."}]);
    }
}
void MWHMenuBarInvalidate(id assertion) {
    @try {
        if ([assertion respondsToSelector:NSSelectorFromString(@"invalidate")]) {
            ((void (*)(id, SEL))objc_msgSend)(assertion, NSSelectorFromString(@"invalidate"));
        }
    } @catch (NSException *exception) {
        NSLog(@"MacWindowHide menu bar release failed: %@", exception.reason);
    }
}
