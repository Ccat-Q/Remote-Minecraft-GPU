#import "RGPURemotePresent.h"
#import <UIKit/UIKit.h>
#include "RGPUANGLEHost.hpp"
#include "RGPUIOSurfaceTarget.hpp"
#include "RGPUVirglPattern.hpp"
#include "RGPUFrameCopy.hpp"
#include <chrono>
#include <thread>
#include <sys/utsname.h>

namespace {
void require(bool condition, const char *message) { if (!condition) throw std::runtime_error(message); }
void glCheck(NSMutableString *report, const char *stage) {
    auto error = glGetError();
    [report appendFormat:@"%s: GL error 0x%x\n", stage, error];
    require(error == GL_NO_ERROR, stage);
}
void eglCheck(NSMutableString *report, const char *stage, bool ok = true) {
    auto error = eglGetError();
    [report appendFormat:@"%s: EGL error 0x%x\n", stage, error];
    require(ok && error == EGL_SUCCESS, stage);
}
void feed(ANGLEHost& host, const std::vector<uint8_t>& bytes) {
    require(host.session->feed(bytes.data(), bytes.size()).empty(), "Unexpected vtest reply");
    require(host.session->atCommandBoundary(), "Incomplete vtest fixture");
}
void waitProducer(ANGLEHost& host, uint32_t fence) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (!host.session->isFenceComplete(fence)) {
        require(std::chrono::steady_clock::now() < deadline, "VirGL producer fence timeout");
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}
NSString *glText(GLenum name) {
    auto value = glGetString(name);
    return value ? [NSString stringWithUTF8String:reinterpret_cast<const char *>(value)] : @"unavailable";
}

using rgpu::interop::SingleFrameCopy;
}

@implementation RGPURemotePresent
+ (NSString *)runWithLayer:(CAMetalLayer *)layer
{
    NSMutableString *report = [NSMutableString stringWithString:
        @"A2.0 ONE-SHOT VirGL Resource -> IOSurface -> Metal\nNot a network/continuous PRESENT or Minecraft capability test.\n"];
    struct utsname machine{}; uname(&machine);
    [report appendFormat:@"Device: %s; %@\n", machine.machine, NSProcessInfo.processInfo.operatingSystemVersionString];
    NSURL *manifestURL = [NSBundle.mainBundle URLForResource:@"RGPUProvenance" withExtension:@"json"];
    NSData *manifest = manifestURL ? [NSData dataWithContentsOfURL:manifestURL] : nil;
    [report appendFormat:@"Build provenance: %@\n", manifest ? [[NSString alloc] initWithData:manifest encoding:NSUTF8StringEncoding] : @"MISSING (cannot accept this build)"];
    const char *stage = "initialize";
    try {
        require(manifest != nil, "Build provenance manifest missing");
        {
            ANGLEHost host;
            host.initialize(false); // Decoder forbids every TRANSFER_GET.
            [report appendFormat:@"Host GL: %@\nGLSL: %@\nRenderer: %@\n", glText(GL_VERSION),
                glText(GL_SHADING_LANGUAGE_VERSION), glText(GL_RENDERER)];
            stage = "VirGL pattern commands";
            feed(host, rgpu::pattern::createContext());
            feed(host, rgpu::pattern::createResource(rgpu::pattern::resource));
            feed(host, rgpu::pattern::createResource(rgpu::pattern::scratch));
            feed(host, rgpu::pattern::render());
            const auto fence = host.session->fenceForPresent();
            host.session->retainForPresent(rgpu::pattern::resource);
            // Exercise asynchronous lifetime: guest UNREF happens BEFORE
            // producer completion/copy. The existing pin must keep tex_id live.
            feed(host, rgpu::pattern::message(3, {rgpu::pattern::resource}));
            feed(host, rgpu::pattern::message(3, {rgpu::pattern::scratch}));
            stage = "producer fence";
            waitProducer(host, fence);
            glCheck(report, "VirGL producer completion");
            [report appendFormat:@"Native vtest: CREATE_RENDERER=1 RESOURCE_CREATE=2 SUBMIT_CMD=1; producer fence %u complete\n"
                "VirGL content: 5 GPU CLEARs + 4 RESOURCE_COPY_REGION; no CPU pixel upload\n", fence];
            virgl_renderer_resource_info info{};
            stage = "resource info";
            require(virgl_renderer_resource_get_info(rgpu::pattern::resource, &info) == 0, "VirGL resource_get_info failed");
            [report appendFormat:@"Resource: handle=%u tex_id=%u format=%u width=%u height=%u depth=%u flags=0x%x stride=%u fd=%d\n",
                info.handle, info.tex_id, info.virgl_format, info.width, info.height, info.depth, info.flags, info.stride, info.fd];
            SingleFrameCopy copy(host); // Destroyed before host on ALL exits.
            stage = "shared-context GPU copy";
            copy.copy(layer, info, host.session->resourceDescription(rgpu::pattern::resource), report);
            // Snapshot is now independent of the source. Free/recreate source
            // before Metal displays to catch accidental live-texture display.
            host.session->releaseFromPresent(rgpu::pattern::resource);
            require(virgl_renderer_resource_get_info(rgpu::pattern::resource, &info) != 0,
                    "Final pin release leaked source resource");
            feed(host, rgpu::pattern::createResource(rgpu::pattern::resource));
            feed(host, rgpu::pattern::overwriteReusedSource());
            waitProducer(host, host.session->fenceForPresent());
            glCheck(report, "Later magenta overwrite completion (after snapshot only)");
            feed(host, rgpu::pattern::message(3, {rgpu::pattern::resource}));
            [report appendString:@"Source UNREF/pin/final release: PASS; reused source overwritten MAGENTA before Metal consumption\n"];
            stage = "Metal display";
            copy.display(report);
            stage = "cleanup";
            require(copy.close(), "Copy context/IOSurface cleanup failed");
            eglCheck(report, "Copy context and IOSurface teardown");
            glCheck(report, "Final producer context");
            [report appendString:@"Copy context/FBO/fence and IOSurface released after GPU completion.\n"];
        }
        [report appendString:@"Host/session cleanup returned. Driver leak profiling remains pending.\n"
            "TECHNICAL CHECKS COMPLETED; VISUAL ACCEPTANCE PENDING.\n"
            "Expected: dark 640x360, RED upper-left (tall), GREEN upper-right (short), BLUE lower-left (small), YELLOW lower-right (wide).\n"
            "No display glReadPixels, CPU pixel-buffer mapping/copy, or TRANSFER_GET code path.\n"
            "Local waits are one-shot diagnostics only; no network session or round trips.\n"
            "Share report AND screenshot; do not mark A2.0 PASS until image/color/orientation are confirmed on device.\n"];
    } catch (const std::exception& error) {
        [report appendFormat:@"FAILED at %s: %s\nResidual GL=0x%x EGL=0x%x\nNo CPU fallback attempted. A2.0 NOT accepted.\n",
            stage, error.what(), glGetError(), eglGetError()];
    }
    NSLog(@"%@", report);
    return report;
}
@end
