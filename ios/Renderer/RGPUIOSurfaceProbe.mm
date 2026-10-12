#import "RGPUIOSurfaceProbe.h"
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <cstring>

static BOOL probeError(NSError **error, NSString *message)
{
    if (error) *error = [NSError errorWithDomain:@"org.remotegpu.interop" code:1
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}

static NSString *glString(GLenum name)
{
    const GLubyte *value = glGetString(name);
    return value ? [NSString stringWithUTF8String:(const char *)value] : @"unavailable";
}

static GLuint compileShader(GLenum type, const char *source, NSError **error)
{
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);
    GLint success = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &success);
    if (!success) {
        char log[4096] = {};
        glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
        probeError(error, [NSString stringWithFormat:@"Shader: %s", log]);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

@implementation RGPUIOSurfaceProbe {
    EGLDisplay _display;
    EGLContext _context;
    EGLSurface _surface;
    IOSurfaceRef _iosurface;
    CVPixelBufferRef _pixelBuffer;
    GLuint _program;
    CAMetalLayer *_layer;
    id<MTLTexture> _texture;
    id<MTLCommandQueue> _queue;
    id<MTLCommandBuffer> _lastDisplay;
}

- (instancetype)initWithLayer:(CAMetalLayer *)layer error:(NSError **)error
{
    self = [super init];
    if (!self) return nil;
    _display = EGL_NO_DISPLAY;
    _context = EGL_NO_CONTEXT;
    _surface = EGL_NO_SURFACE;
    _layer = layer;
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { probeError(error, @"No Metal device"); return nil; }
    layer.device = device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = NO; // The probe copies to the drawable with a GPU blit.
    layer.drawableSize = CGSizeMake(1280, 720);
    _queue = [device newCommandQueue];
    if (!_queue) { probeError(error, @"Cannot create Metal queue"); return nil; }

    auto platformDisplay = (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    const EGLint displayAttributes[] = {
        EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE
    };
    if (!platformDisplay) { probeError(error, @"ANGLE platform API missing"); return nil; }
    _display = platformDisplay(EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, displayAttributes);
    if (_display == EGL_NO_DISPLAY || !eglInitialize(_display, nullptr, nullptr)) {
        probeError(error, @"ANGLE Metal display initialization failed"); return nil;
    }
    const char *extensions = eglQueryString(_display, EGL_EXTENSIONS);
    if (!extensions || !strstr(extensions, "EGL_ANGLE_iosurface_client_buffer")) {
        probeError(error, @"ANGLE IOSurface extension missing"); return nil;
    }
    if (!eglBindAPI(EGL_OPENGL_ES_API)) {
        probeError(error, @"Cannot bind GLES API"); return nil;
    }
    const EGLint configAttributes[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE
    };
    EGLConfig config = nullptr;
    EGLint count = 0;
    if (!eglChooseConfig(_display, configAttributes, &config, 1, &count) || count != 1) {
        probeError(error, @"No GLES3 pbuffer config"); return nil;
    }
    const EGLint contextAttributes[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    _context = eglCreateContext(_display, config, EGL_NO_CONTEXT, contextAttributes);
    if (_context == EGL_NO_CONTEXT) { probeError(error, @"GLES3 context failed"); return nil; }
    NSDictionary *properties = @{
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
        (__bridge NSString *)kCVPixelBufferOpenGLESCompatibilityKey: @YES
    };
    CVReturn allocated = CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720,
                                              kCVPixelFormatType_32BGRA,
                                              (__bridge CFDictionaryRef)properties, &_pixelBuffer);
    if (allocated != kCVReturnSuccess) { probeError(error, @"Pixel buffer allocation failed"); return nil; }
    _iosurface = CVPixelBufferGetIOSurface(_pixelBuffer); // Borrowed; pixelBuffer owns it.
    if (!_iosurface) { probeError(error, @"Pixel buffer is not IOSurface-backed"); return nil; }
    const EGLint surfaceAttributes[] = {
        EGL_WIDTH, 1280, EGL_HEIGHT, 720, EGL_IOSURFACE_PLANE_ANGLE, 0,
        EGL_TEXTURE_TARGET, EGL_TEXTURE_2D, EGL_TEXTURE_FORMAT, EGL_TEXTURE_RGBA,
        EGL_TEXTURE_INTERNAL_FORMAT_ANGLE, GL_BGRA_EXT,
        EGL_TEXTURE_TYPE_ANGLE, GL_UNSIGNED_BYTE, EGL_NONE
    };
    _surface = eglCreatePbufferFromClientBuffer(_display, EGL_IOSURFACE_ANGLE,
                                               (EGLClientBuffer)_iosurface, config, surfaceAttributes);
    if (_surface == EGL_NO_SURFACE || !eglMakeCurrent(_display, _surface, _surface, _context)) {
        probeError(error, [NSString stringWithFormat:@"IOSurface EGL surface failed: 0x%x", eglGetError()]);
        return nil;
    }
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:1280 height:720 mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    _texture = [device newTextureWithDescriptor:descriptor iosurface:_iosurface plane:0];
    if (!_texture) { probeError(error, @"IOSurface Metal texture failed"); return nil; }
    _capabilityReport = [NSString stringWithFormat:@"Host GL: %@\nGLSL: %@\nRenderer: %@\nMetal: %@\nIOSurface: 1280x720 BGRA\n\nThis host GLES probe does not prove guest OpenGL 3.2 Core.", glString(GL_VERSION), glString(GL_SHADING_LANGUAGE_VERSION), glString(GL_RENDERER), device.name];

    const char *vertexSource = "#version 300 es\nconst vec2 p[3]=vec2[3](vec2(-0.7,-0.7),vec2(0.7,-0.7),vec2(0.0,0.7));\nvoid main(){gl_Position=vec4(p[gl_VertexID],0.0,1.0);}";
    const char *fragmentSource = "#version 300 es\nprecision mediump float;\nout vec4 color;\nvoid main(){color=vec4(1.0,0.5,0.1,1.0);}";
    GLuint vertex = compileShader(GL_VERTEX_SHADER, vertexSource, error);
    if (!vertex) return nil;
    GLuint fragment = compileShader(GL_FRAGMENT_SHADER, fragmentSource, error);
    if (!fragment) { glDeleteShader(vertex); return nil; }
    _program = glCreateProgram();
    glAttachShader(_program, vertex);
    glAttachShader(_program, fragment);
    glLinkProgram(_program);
    glDeleteShader(vertex);
    glDeleteShader(fragment);
    GLint linked = 0;
    glGetProgramiv(_program, GL_LINK_STATUS, &linked);
    if (!linked) { probeError(error, @"Triangle program link failed"); return nil; }
    return self;
}

- (BOOL)drawTriangleWithError:(NSError **)error
{
    // One-shot diagnostic rendering. Keep IOSurface ownership until both APIs
    // finish. Production frame scheduling and async fences belong to the
    // remote renderer adapter, not this host interop gate.
    [_lastDisplay waitUntilCompleted];
    if (!eglMakeCurrent(_display, _surface, _surface, _context))
        return probeError(error, @"Cannot make probe context current");
    glViewport(0, 0, 1280, 720);
    glClearColor(0.02f, 0.04f, 0.08f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glUseProgram(_program);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glFinish(); // Host-only interop completion; no network or CPU pixel copy.
    if (glGetError() != GL_NO_ERROR) return probeError(error, @"Triangle draw failed");
    id<CAMetalDrawable> drawable = [_layer nextDrawable];
    if (!drawable) return probeError(error, @"Metal drawable unavailable");
    id<MTLCommandBuffer> commands = [_queue commandBuffer];
    id<MTLBlitCommandEncoder> copy = [commands blitCommandEncoder];
    if (!commands || !copy) return probeError(error, @"Metal blit encoder failed");
    [copy copyFromTexture:_texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
              sourceSize:MTLSizeMake(1280, 720, 1) toTexture:drawable.texture destinationSlice:0
        destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [copy endEncoding];
    [commands presentDrawable:drawable];
    [commands commit];
    _lastDisplay = commands;
    [commands waitUntilCompleted];
    if (commands.status != MTLCommandBufferStatusCompleted)
        return probeError(error, commands.error.localizedDescription ?: @"Metal display command did not complete");
    return YES;
}

- (void)dealloc
{
    [_lastDisplay waitUntilCompleted];
    if (_display != EGL_NO_DISPLAY) {
        if (_context != EGL_NO_CONTEXT && _surface != EGL_NO_SURFACE &&
            eglMakeCurrent(_display, _surface, _surface, _context)) {
            if (_program) glDeleteProgram(_program);
            glFinish();
        }
        eglMakeCurrent(_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (_surface != EGL_NO_SURFACE) eglDestroySurface(_display, _surface);
        if (_context != EGL_NO_CONTEXT) eglDestroyContext(_display, _context);
        eglTerminate(_display);
    }
    if (_pixelBuffer) CVPixelBufferRelease(_pixelBuffer);
}
@end
