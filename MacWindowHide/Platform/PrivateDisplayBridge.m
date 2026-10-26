#import "PrivateDisplayBridge.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

// ABI observed on macOS 15–27. Reject a changed return/argument encoding before invocation.
typedef struct { int hour; int minute; } MWHTime;
typedef struct { MWHTime start; MWHTime end; } MWHSchedule;
typedef struct { BOOL active; BOOL enabled; BOOL locationPermission; int mode; MWHSchedule schedule; unsigned long long disableFlags; BOOL available; } MWHBlueLightStatus;

static BOOL MWHMethod(id object, NSString *name, const char *returnType, NSUInteger count) {
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    return signature && signature.numberOfArguments == count && strcmp(signature.methodReturnType, returnType) == 0;
}
static id MWHClient(NSInteger kind) {
    static id blueLight;
    static id adaptation;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY | RTLD_LOCAL);
        if (!handle) return;
        Class blue = NSClassFromString(@"CBBlueLightClient");
        Class tone = NSClassFromString(@"CBAdaptationClient");
        if (blue) blueLight = [[blue alloc] init];
        if (tone) adaptation = [[tone alloc] init];
    });
    return kind == 0 ? blueLight : kind == 1 ? adaptation : nil;
}
BOOL MWHDisplaySupported(NSInteger kind) {
    @try {
        id client = MWHClient(kind);
        if (!MWHMethod(client, @"supported", @encode(BOOL), 2)) return NO;
        if (!((BOOL (*)(id, SEL))objc_msgSend)(client, NSSelectorFromString(@"supported"))) return NO;
        return MWHMethod(client, @"setEnabled:", @encode(BOOL), 3);
    } @catch (NSException *exception) { return NO; }
}
NSInteger MWHDisplayEnabled(NSInteger kind) {
    @try {
        id client = MWHClient(kind);
        if (!MWHDisplaySupported(kind)) return -1;
        if (kind == 1) {
            if (!MWHMethod(client, @"getEnabled", @encode(BOOL), 2)) return -1;
            return ((BOOL (*)(id, SEL))objc_msgSend)(client, NSSelectorFromString(@"getEnabled")) ? 1 : 0;
        }
        SEL selector = NSSelectorFromString(@"getBlueLightStatus:");
        if (!MWHMethod(client, @"getBlueLightStatus:", @encode(BOOL), 3)) return -1;
        NSMethodSignature *signature = [client methodSignatureForSelector:selector];
        const char *argument = [signature getArgumentTypeAtIndex:2];
        if (argument[0] != '^') return -1;
        NSUInteger size = 0, alignment = 0;
        NSGetSizeAndAlignment(argument + 1, &size, &alignment);
        if (size != sizeof(MWHBlueLightStatus) || alignment != _Alignof(MWHBlueLightStatus)) return -1;
        MWHBlueLightStatus status = {0};
        if (!((BOOL (*)(id, SEL, MWHBlueLightStatus *))objc_msgSend)(client, selector, &status)) return -1;
        return status.enabled ? 1 : 0;
    } @catch (NSException *exception) { return -1; }
}
BOOL MWHSetDisplayEnabled(NSInteger kind, BOOL enabled) {
    @try {
        id client = MWHClient(kind);
        if (!MWHDisplaySupported(kind) || MWHDisplayEnabled(kind) < 0) return NO;
        NSMethodSignature *signature = [client methodSignatureForSelector:NSSelectorFromString(@"setEnabled:")];
        if (strcmp([signature getArgumentTypeAtIndex:2], @encode(BOOL)) != 0) return NO;
        return ((BOOL (*)(id, SEL, BOOL))objc_msgSend)(client, NSSelectorFromString(@"setEnabled:"), enabled);
    } @catch (NSException *exception) { return NO; }
}
NSDictionary<NSString *, NSNumber *> *MWHBluetoothBattery(id device) {
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    NSDictionary *selectors = @{@"Left": @"batteryPercentLeft", @"Right": @"batteryPercentRight", @"Case": @"batteryPercentCase", @"Battery": @"batteryPercentSingle"};
    @try {
        for (NSString *label in selectors) {
            SEL selector = NSSelectorFromString(selectors[label]);
            NSMethodSignature *signature = [device methodSignatureForSelector:selector];
            if (!signature || signature.numberOfArguments != 2 || signature.methodReturnLength > sizeof(uint64_t)) continue;
            const char *type = signature.methodReturnType;
            if (!strchr("cCsSiIlLqQ", type[0])) continue;
            NSInvocation *call = [NSInvocation invocationWithMethodSignature:signature];
            call.target = device;
            call.selector = selector;
            [call invoke];
            uint64_t number = 0;
            [call getReturnValue:&number];
            if (number <= 100) values[label] = @(number);
        }
    } @catch (NSException *exception) { return @{}; }
    return values;
}
