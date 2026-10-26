#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
BOOL MWHMenuBarNativeAvailable(void);
void MWHMenuBarActivate(NSArray<NSString *> *allowedBundles,
                        void (^completion)(id _Nullable assertion, NSError * _Nullable error));
void MWHMenuBarInvalidate(id assertion);
NS_ASSUME_NONNULL_END
