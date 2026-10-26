#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// 0 = Night Shift, 1 = True Tone. These runtime adapters never change state while probing.
BOOL MWHDisplaySupported(NSInteger kind);
/// Returns -1 when the current state cannot be read.
NSInteger MWHDisplayEnabled(NSInteger kind);
BOOL MWHSetDisplayEnabled(NSInteger kind, BOOL enabled);
NSDictionary<NSString *, NSNumber *> *MWHBluetoothBattery(id device);
NS_ASSUME_NONNULL_END
