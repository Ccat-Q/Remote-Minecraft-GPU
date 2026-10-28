#pragma once
#include "RGPUANGLEHost.hpp"
#include "RGPUIOSurfaceTarget.hpp"
#include <chrono>
#include <functional>

namespace rgpu::interop {
inline void require(bool condition, const char *message) { if (!condition) throw std::runtime_error(message); }
inline void glCheck(NSMutableString *report, const char *stage) {
    auto error = glGetError();
    [report appendFormat:@"%s: GL error 0x%x\n", stage, error];
    require(error == GL_NO_ERROR, stage);
}
inline void eglCheck(NSMutableString *report, const char *stage, bool ok = true) {
    auto error = eglGetError();
    [report appendFormat:@"%s: EGL error 0x%x\n", stage, error];
    require(ok && error == EGL_SUCCESS, stage);
}
inline NSString *glText(GLenum name) {
    auto value = glGetString(name);
    return value ? [NSString stringWithUTF8String:reinterpret_cast<const char *>(value)] : @"unavailable";
}
// Shared GPU-copy primitive: A2 uses diagnostic blocking wrappers, A3.1 uses
// begin/poll. The owner excludes future vtest until this single slot retires.
class SingleFrameCopy {
    ANGLEHost& host_;
    EGLContext copy_ = EGL_NO_CONTEXT;
    GLuint read_ = 0;
    GLsync done_ = nullptr;
    RGPUIOSurfaceTarget target_;
    bool closed_ = false;
    bool copied_ = false;
    std::function<bool()> cancelled_;
    void checkCancellation() { require(!cancelled_ || !cancelled_(), "Snapshot cancelled"); }
public:
    explicit SingleFrameCopy(ANGLEHost& host, std::function<bool()> cancelled = {})
        : host_(host), cancelled_(std::move(cancelled)) {}
    void beginCopy(CAMetalLayer *layer, const virgl_renderer_resource_info& info, const rgpu::ResourceDescription& desc,
              NSMutableString *report, bool galliumWindowRows = false) try {
        checkCancellation();
        require(copy_ == EGL_NO_CONTEXT && !closed_, "Snapshot already allocated/closed");
        require(desc.target == 2 && desc.depth == 1 && desc.arraySize == 1 && desc.lastLevel == 0 && desc.samples <= 1,
            "Unsupported source target/mip/layer/array/sample count");
        require(info.tex_id && (info.virgl_format == 67 || info.virgl_format == 1) && info.flags == 0 &&
            info.virgl_format == desc.format && info.width == desc.width && info.height == desc.height &&
            info.width >= 1 && info.width <= 1280 && info.height >= 1 && info.height <= 720 && info.depth == 1,
            "Unsupported source info: only linear RGBA8/BGRA8 2D, flags=0, up to 1280x720");
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
        [report appendFormat:@"Shared texture visible: YES; GL target=TEXTURE_2D, level=0, layer=0, creation samples=%u (single sample)\nCopy host: %@ / %@\n",
            desc.samples, glText(GL_VERSION), glText(GL_RENDERER)];
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
        // A1's window rows are Gallium top-left, unlike A2.0's raw-GL fixture.
        // Normalize source rows here; keep the accepted IOSurface/Metal shader
        // unchanged. Resource flags alone do NOT identify the producer's rows.
        [report appendFormat:@"Source rows=%@; GPU source-Y normalization=%@; Metal orientation shader unchanged\n",
            galliumWindowRows ? @"A1 Gallium window top-left" : @"A2.0 raw GL bottom-left",
            galliumWindowRows ? @"FLIP" : @"NONE"];
        glBlitFramebuffer(0, galliumWindowRows ? info.height : 0, info.width, galliumWindowRows ? 0 : info.height,
                          0, 0, info.width, info.height,
                          GL_COLOR_BUFFER_BIT, GL_NEAREST);
        glCheck(report, "GPU copy glBlitFramebuffer RGBA8 -> BGRA8 IOSurface");
        done_ = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
        require(done_ != nullptr, "GPU copy fence creation failed");
        glFlush();
        host_.resume(); // No context remains current across owner-queue jobs.
    } catch (const std::exception& error) {
        [report appendFormat:@"Copy failure before teardown: %s; GL=0x%x EGL=0x%x\n",
            error.what(), glGetError(), eglGetError()];
        throw;
    }
    bool pollCopy(NSMutableString *report) {
        checkCancellation();
        require(done_ && copy_ != EGL_NO_CONTEXT && !closed_, "No pending GPU copy");
        require(eglMakeCurrent(host_.display, target_.surface, target_.surface, copy_),
                "Cannot resume shared copy context");
        const auto status = glClientWaitSync(done_, 0, 0); // Zero CPU wait, A3 timer drives progress.
        require(status != GL_WAIT_FAILED, "GPU copy fence poll failed");
        if (status == GL_TIMEOUT_EXPIRED) { host_.resume(); return false; }
        require(status == GL_ALREADY_SIGNALED || status == GL_CONDITION_SATISFIED, "Unexpected GPU fence status");
        glCheck(report, "GPU copy completion");
        [report appendFormat:@"GPU copy fence complete: 0x%x; source held throughout snapshot\n", status];
        glDeleteSync(done_); done_ = nullptr;
        glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, 0, 0);
        glDeleteFramebuffers(1, &read_); read_ = 0;
        // No more GL writes to IOSurface. Unbind before cross-API consumption.
        host_.resume();
        eglCheck(report, "Restore producer context after snapshot");
        copied_ = true;
        return true;
    }
    void copy(CAMetalLayer *layer, const virgl_renderer_resource_info& info, const rgpu::ResourceDescription& desc,
              NSMutableString *report, bool galliumWindowRows = false) {
        beginCopy(layer, info, desc, report, galliumWindowRows);
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
        while (!pollCopy(report)) {
            require(std::chrono::steady_clock::now() < deadline, "GPU copy fence timeout");
            std::this_thread::sleep_for(std::chrono::milliseconds(1)); // A2 diagnostic ONLY.
        }
    }
    void beginDisplay() { checkCancellation(); require(copied_, "Snapshot incomplete"); target_.presentAsync(); }
    bool pollDisplay() { checkCancellation(); return target_.presentationComplete(); }
    void display(NSMutableString *report) {
        checkCancellation();
        target_.presentAndWait(cancelled_);
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
                // Cancellation/error drain ONLY. Successful A2/A3 frames have
                // observed their copy fence, so steady-state never glFinish.
                if (!copied_) glFinish();
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
