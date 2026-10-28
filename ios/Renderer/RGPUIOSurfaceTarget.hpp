#pragma once
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <cstring>
#include <stdexcept>
#include <cstdio>
#include <functional>
#include <chrono>
#include <thread>

// Borrows the caller's EGLDisplay/config; never creates a display or context.
// Caller unbinds this surface before close(), and keeps the display alive.
// CPU storage is allocated but NEVER locked, mapped or copied by this helper.
class RGPUIOSurfaceTarget {
    EGLDisplay display_ = EGL_NO_DISPLAY;
    CVPixelBufferRef pixels_ = nullptr;
    id<MTLTexture> texture_;
    id<MTLCommandQueue> queue_;
    id<MTLRenderPipelineState> pipeline_;
    id<MTLCommandBuffer> completion_;
    CAMetalLayer *layer_;
public:
    EGLSurface surface = EGL_NO_SURFACE;
    RGPUIOSurfaceTarget() = default;
    RGPUIOSurfaceTarget(const RGPUIOSurfaceTarget&) = delete;
    RGPUIOSurfaceTarget& operator=(const RGPUIOSurfaceTarget&) = delete;
    void initialize(EGLDisplay display, EGLConfig config, CAMetalLayer *layer, unsigned width, unsigned height) {
        display_ = display;
        layer_ = layer;
        auto extensions = eglQueryString(display, EGL_EXTENSIONS);
        if (!extensions || !std::strstr(extensions, "EGL_ANGLE_iosurface_client_buffer"))
            throw std::runtime_error("EGL_ANGLE_iosurface_client_buffer missing");
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) throw std::runtime_error("Metal device unavailable");
        layer.device = device;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = YES;
        layer.drawableSize = CGSizeMake(width, height);
        queue_ = [device newCommandQueue];
        id<MTLLibrary> library = [device newDefaultLibrary];
        if (!queue_ || !library) throw std::runtime_error("Metal queue/default.metallib unavailable");
        MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = [library newFunctionWithName:@"displayVertex"];
        descriptor.fragmentFunction = [library newFunctionWithName:@"displayFragment"];
        descriptor.colorAttachments[0].pixelFormat = layer.pixelFormat;
        NSError *error = nil;
        pipeline_ = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if (!pipeline_) throw std::runtime_error(error.localizedDescription.UTF8String ?: "Metal pipeline failed");
        NSDictionary *properties = @{
            (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
            (__bridge NSString *)kCVPixelBufferOpenGLESCompatibilityKey: @YES
        };
        if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                               (__bridge CFDictionaryRef)properties, &pixels_) != kCVReturnSuccess)
            throw std::runtime_error("IOSurface-backed CVPixelBuffer allocation failed");
        IOSurfaceRef iosurface = CVPixelBufferGetIOSurface(pixels_); // pixels_ owns it.
        if (!iosurface) throw std::runtime_error("CVPixelBuffer has no IOSurface");
        const EGLint attributes[] = {
            EGL_WIDTH, EGLint(width), EGL_HEIGHT, EGLint(height), EGL_IOSURFACE_PLANE_ANGLE, 0,
            EGL_TEXTURE_TARGET, EGL_TEXTURE_2D, EGL_TEXTURE_FORMAT, EGL_TEXTURE_RGBA,
            EGL_TEXTURE_INTERNAL_FORMAT_ANGLE, GL_BGRA_EXT, EGL_TEXTURE_TYPE_ANGLE, GL_UNSIGNED_BYTE, EGL_NONE
        };
        surface = eglCreatePbufferFromClientBuffer(display_, EGL_IOSURFACE_ANGLE,
                    (EGLClientBuffer)iosurface, config, attributes);
        if (surface == EGL_NO_SURFACE) {
            char message[128];
            std::snprintf(message, sizeof(message), "IOSurface EGL pbuffer failed: EGL 0x%x", eglGetError());
            throw std::runtime_error(message);
        }
        MTLTextureDescriptor *texture = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
            width:width height:height mipmapped:NO];
        texture.storageMode = MTLStorageModeShared;
        texture.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        texture_ = [device newTextureWithDescriptor:texture iosurface:iosurface plane:0];
        if (!texture_) throw std::runtime_error("IOSurface MTLTexture allocation failed");
    }
    void presentAsync() {
        // EGL GPU completion must precede this call. Keep
        // pixels_/texture_ alive through Metal completion (including failures).
        if (completion_ && completion_.status >= MTLCommandBufferStatusCommitted &&
            completion_.status < MTLCommandBufferStatusCompleted)
            throw std::runtime_error("Previous Metal consumption is still pending");
        id<CAMetalDrawable> drawable = [layer_ nextDrawable];
        if (!drawable) throw std::runtime_error("Metal drawable unavailable");
        completion_ = [queue_ commandBuffer];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.02, 0.04, 0.08, 1);
        id<MTLRenderCommandEncoder> encoder = [completion_ renderCommandEncoderWithDescriptor:pass];
        if (!completion_ || !encoder) throw std::runtime_error("Metal display encoder failed");
        [encoder setRenderPipelineState:pipeline_];
        [encoder setFragmentTexture:texture_ atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
        [completion_ presentDrawable:drawable];
        // Independent backing-store lease: cancellation/timeout may destroy
        // this helper before Metal finishes. No GL/display/context is captured.
        // Command buffers also retain their resources, but keep CVPixelBuffer
        // explicitly until actual consumption, not until the CPU wait returns.
        CVPixelBufferRef lease = CVPixelBufferRetain(pixels_);
        id<MTLTexture> heldTexture = texture_;
        [completion_ addCompletedHandler:^(id<MTLCommandBuffer>) {
            (void)heldTexture; // Strong capture until the completion handler retires.
            CVPixelBufferRelease(lease);
        }];
        [completion_ commit];
    }
    bool presentationComplete() {
        if (!completion_) throw std::runtime_error("No Metal presentation submitted");
        if (completion_.status == MTLCommandBufferStatusError)
            throw std::runtime_error(completion_.error.localizedDescription.UTF8String ?: "Metal completion failed");
        return completion_.status == MTLCommandBufferStatusCompleted;
    }
    void presentAndWait(std::function<bool()> cancelled = {}) {
        presentAsync();
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
        while (!presentationComplete()) {
            if (cancelled && cancelled())
                throw std::runtime_error("Metal wait cancelled; IOSurface lease retained until GPU completion");
            if (std::chrono::steady_clock::now() >= deadline)
                throw std::runtime_error("Metal wait timed out; IOSurface lease retained until GPU completion");
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    }
    bool close() {
        // Successful path has consumed Metal already. On cancel/timeout the
        // completion block independently retains the IOSurface backing store.
        if (surface != EGL_NO_SURFACE) {
            if (!eglDestroySurface(display_, surface)) return false;
            surface = EGL_NO_SURFACE;
        }
        texture_ = nil;
        if (pixels_) { CVPixelBufferRelease(pixels_); pixels_ = nullptr; }
        return true;
    }
    ~RGPUIOSurfaceTarget() { close(); }
};
