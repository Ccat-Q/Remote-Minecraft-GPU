#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>

NS_ASSUME_NONNULL_BEGIN

// Device-only host interop gate. Remote vtest replay is a separate gate.
@interface RGPUIOSurfaceProbe : NSObject
@property(nonatomic, readonly) NSString *capabilityReport;
- (nullable instancetype)initWithLayer:(CAMetalLayer *)layer error:(NSError **)error;
- (BOOL)drawTriangleWithError:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
