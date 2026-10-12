#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Native initialization/capset gate, not guest GL_VERSION or remote display.
@interface RGPUVirglProbe : NSObject
+ (nullable NSString *)runWithError:(NSError **)error NS_SWIFT_NAME(run());
@end
NS_ASSUME_NONNULL_END
