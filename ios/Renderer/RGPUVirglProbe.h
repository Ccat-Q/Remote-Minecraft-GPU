#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Native initialization/capset gate, not guest GL_VERSION or remote display.
@interface RGPUVirglProbe : NSObject
+ (nullable NSString *)runWithError:(NSError **)error NS_SWIFT_NAME(run());
@end

// Capability-only network endpoint. Serial calls may migrate between threads;
// each call restores its EGL context and unbinds it before returning.
@interface RGPUVTestEndpoint : NSObject
@property(nonatomic, readonly) NSString *hostReport;
+ (nullable instancetype)createWithError:(NSError **)error NS_SWIFT_NAME(create());
- (nullable NSArray<NSData *> *)submitVTest:(NSData *)bytes error:(NSError **)error NS_SWIFT_NAME(submit(_:));
@end
NS_ASSUME_NONNULL_END
