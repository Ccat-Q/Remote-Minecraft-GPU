#import "RGPURemotePresent.h"
#import <UIKit/UIKit.h>
#include "RGPUANGLEHost.hpp"
#include "RGPUIOSurfaceTarget.hpp"
#include "RGPUVirglPattern.hpp"
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

// Deliberately diagnostic-only: serial ownership excludes future vtest feeds
// until snapshot completion. This is not the A2-A4 steady-state scheduler.
class SingleFrameCopy {
    ANGLEHost& host_;
    EGLContext copy_ = EGL_NO_CONTEXT;
    GLuint read_ = 0;
    GLsync done_ = nullptr;
    RGPUIOSurfaceTarget target_;
    bool closed_ = false;
public:
    explicit SingleFrameCopy(ANGLEHost& host) : host_(host) {}
    void copy(CAMetalLayer *layer, const virgl_renderer_resource_info& info, NSMutableString *report) try {
        // Resource Info is NOT target/sample metadata. This one-shot owns the
        // creation descriptor (pattern::createResource), disallows all others.
        require(info.handle == rgpu::pattern::resource && info.tex_id != 0 &&
            info.virgl_format == rgpu::pattern::format && info.width == rgpu::pattern::width &&
            info.height == rgpu::pattern::height && info.depth == 1 && info.flags == 0,
            "Resource outside the tested 2D/RGBA8/level0/layer0/single-sample profile");
        require(host_.root != EGL_NO_CONTEXT, "VirGL share-group root missing");
        const EGLint attributes[] = {EGL_CONTEXT_MAJOR_VERSION_KHR, 3,
                                    EGL_CONTEXT_MINOR_VERSION_KHR, 0, EGL_NONE};
        copy_ = eglCreateContext(host_.display, host_.config, host_.root, attributes);
        eglCheck(report, "Create shared copy context");
        require(copy_ != EGL_NO_CONTEXT, "Shared EGL context creation failed");
        eglCheck(report, "Query copy context", eglQueryContext(host_.display, copy_, EGL_CONTEXT_CLIENT_VERSION, &major_));
        require(major_ >= 3, "Copy requires real GLES 3.0 core framebuffer blit");
        target_.initialize(host_.display, host_.config, layer, info.width, info.height);
        eglCheck(report, "Bind IOSurface on borrowed EGLDisplay",
            eglMakeCurrent(host_.display, target_.surface, target_.surface, copy_));
        require(glIsTexture(info.tex_id), "VirGL tex_id is NOT visible in shared context");
        [report appendFormat:@"Shared texture visible: YES; GL target=TEXTURE_2D, level=0, layer=0, samples=0 (one sample)\nCopy host: %@ / %@\n",
            glText(GL_VERSION), glText(GL_RENDERER)];
        glGenFramebuffers(1, &read_);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, read_);
        // FBO is private to copy_, attachment is borrowed; never write to it.
        glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, info.tex_id, 0);
        glReadBuffer(GL_COLOR_ATTACHMENT0);
        auto readStatus = glCheckFramebufferStatus(GL_READ_FRAMEBUFFER);
        GLint component = 0, encoding = 0;
        glGetFramebufferAttachmentParameteriv(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
            GL_FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE, &component);
        glGetFramebufferAttachmentParameteriv(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
            GL_FRAMEBUFFER_ATTACHMENT_COLOR_ENCODING, &encoding);
        const GLenum channelSizes[] = {GL_FRAMEBUFFER_ATTACHMENT_RED_SIZE, GL_FRAMEBUFFER_ATTACHMENT_GREEN_SIZE,
            GL_FRAMEBUFFER_ATTACHMENT_BLUE_SIZE, GL_FRAMEBUFFER_ATTACHMENT_ALPHA_SIZE};
        for (auto channel : channelSizes) {
            GLint size = 0;
            glGetFramebufferAttachmentParameteriv(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, channel, &size);
            require(size == 8, "Source is not actual 8-bit RGBA");
        }
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
        auto drawStatus = glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER);
        GLint samples = -1;
        glGetIntegerv(GL_SAMPLES, &samples);
        [report appendFormat:@"Read FBO=0x%x, draw FBO=0x%x, component=0x%x, encoding=0x%x, destination samples=%d\n",
            readStatus, drawStatus, component, encoding, samples];
        require(readStatus == GL_FRAMEBUFFER_COMPLETE && drawStatus == GL_FRAMEBUFFER_COMPLETE,
                "Source or IOSurface framebuffer incomplete");
        require(component == GL_UNSIGNED_NORMALIZED && encoding == GL_LINEAR && samples == 0,
                "Untested source encoding/type or multisampled IOSurface");
        EGLint surfaceWidth = 0, surfaceHeight = 0;
        eglCheck(report, "Query IOSurface width", eglQuerySurface(host_.display, target_.surface, EGL_WIDTH, &surfaceWidth));
        eglCheck(report, "Query IOSurface height", eglQuerySurface(host_.display, target_.surface, EGL_HEIGHT, &surfaceHeight));
        require(surfaceWidth == EGLint(info.width) && surfaceHeight == EGLint(info.height), "IOSurface dimensions mismatch");
        glCheck(report, "Shared FBO attachment validation");
        // GLES 3.0 core blit is selected ONLY after the real attachment checks.
        // Both targets are normalized linear 8-bit color. No format swizzle:
        // GL/ANGLE converts logical RGBA into IOSurface BGRA storage.
        glDisable(GL_SCISSOR_TEST);
        glBlitFramebuffer(0, 0, info.width, info.height, 0, 0, info.width, info.height,
                          GL_COLOR_BUFFER_BIT, GL_NEAREST);
        glCheck(report, "GPU copy glBlitFramebuffer RGBA8 -> BGRA8 IOSurface");
        done_ = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
        require(done_ != nullptr, "GPU copy fence creation failed");
        glFlush();
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
        GLenum status;
        do {
            status = glClientWaitSync(done_, 0, 5'000'000); // Local one-shot wait, NOT a network wait.
            require(status != GL_WAIT_FAILED, "GPU copy fence wait failed");
            require(std::chrono::steady_clock::now() < deadline, "GPU copy fence timeout");
        } while (status != GL_ALREADY_SIGNALED && status != GL_CONDITION_SATISFIED);
        glCheck(report, "GPU copy completion");
        [report appendFormat:@"GPU copy fence complete: 0x%x; source held throughout snapshot\n", status];
        glDeleteSync(done_); done_ = nullptr;
        glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, 0, 0);
        glDeleteFramebuffers(1, &read_); read_ = 0;
        // No more GL writes to IOSurface. Unbind before cross-API consumption.
        host_.resume();
        eglCheck(report, "Restore producer context after snapshot");
    } catch (const std::exception& error) {
        // Capture errors while the failing context is still alive, BEFORE
        // RAII teardown can replace EGL/GL's thread-local error state.
        [report appendFormat:@"Copy failure before teardown: %s; GL=0x%x EGL=0x%x\n",
            error.what(), glGetError(), eglGetError()];
        throw;
    }
    void display(NSMutableString *report) {
        target_.presentAndWait();
        [report appendString:@"Metal command status: COMPLETED; IOSurface retained through consumption\n"];
    }
    bool close() {
        if (closed_) return true;
        bool ok = true;
        if (copy_ != EGL_NO_CONTEXT) {
            // Includes failure paths: drain GPU before dropping borrowed source
            // attachments/IOSurface. glFinish is diagnostic-only, never transport.
            const auto surface = target_.surface != EGL_NO_SURFACE ? target_.surface : host_.surface;
            if (eglMakeCurrent(host_.display, surface, surface, copy_)) {
                glFinish();
                if (done_) { glDeleteSync(done_); done_ = nullptr; }
                if (read_) { glDeleteFramebuffers(1, &read_); read_ = 0; }
            } else ok = false;
            try { host_.resume(); } catch (...) { ok = false; }
            if (!eglDestroyContext(host_.display, copy_)) ok = false;
            else copy_ = EGL_NO_CONTEXT;
        }
        if (!target_.close()) ok = false;
        closed_ = ok;
        return ok;
    }
    ~SingleFrameCopy() { close(); }
private:
    EGLint major_ = 0;
};
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
            copy.copy(layer, info, report);
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
