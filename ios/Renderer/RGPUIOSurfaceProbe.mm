#import "RGPUIOSurfaceProbe.h"
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <cstring>
#include <memory>
#include "RGPUIOSurfaceTarget.hpp"

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
    std::unique_ptr<RGPUIOSurfaceTarget> _target;
    GLuint _program;

}

- (instancetype)initWithLayer:(CAMetalLayer *)layer error:(NSError **)error
{
    self = [super init];
    if (!self) return nil;
    _display = EGL_NO_DISPLAY;
    _context = EGL_NO_CONTEXT;
    _surface = EGL_NO_SURFACE;
    auto platformDisplay = (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    const EGLint displayAttributes[] = {
        EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE
    };
    if (!platformDisplay) { probeError(error, @"ANGLE platform API missing"); return nil; }
    _display = platformDisplay(EGL_PLATFORM_ANGLE_ANGLE, nullptr, displayAttributes);
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
    try {
        _target = std::make_unique<RGPUIOSurfaceTarget>();
        _target->initialize(_display, config, layer, 1280, 720);
        _surface = _target->surface; // Borrowed from target; target owns destruction.
    } catch (const std::exception& failure) {
        probeError(error, [NSString stringWithUTF8String:failure.what()]); return nil;
    }
    if (!eglMakeCurrent(_display, _surface, _surface, _context)) {
        probeError(error, @"Cannot make IOSurface context current"); return nil;
    }
    _capabilityReport = [NSString stringWithFormat:@"Host GL: %@\nGLSL: %@\nRenderer: %@\nMetal: %@\nIOSurface: 1280x720 BGRA\n\nThis host GLES probe does not prove guest OpenGL 3.2 Core.", glString(GL_VERSION), glString(GL_SHADING_LANGUAGE_VERSION), glString(GL_RENDERER), layer.device.name];

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
    if (!eglMakeCurrent(_display, _surface, _surface, _context))
        return probeError(error, @"Cannot make probe context current");
    glViewport(0, 0, 1280, 720);
    glClearColor(0.02f, 0.04f, 0.08f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glUseProgram(_program);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glFinish(); // Host-only interop completion; no network or CPU pixel copy.
    if (glGetError() != GL_NO_ERROR) return probeError(error, @"Triangle draw failed");
    try { _target->presentAndWait(); }
    catch (const std::exception& failure) {
        return probeError(error, [NSString stringWithUTF8String:failure.what()]);
    }
    return YES;
}

- (void)dealloc
{
    if (_display != EGL_NO_DISPLAY) {
        if (_context != EGL_NO_CONTEXT && _surface != EGL_NO_SURFACE &&
            eglMakeCurrent(_display, _surface, _surface, _context)) {
            if (_program) glDeleteProgram(_program);
            glFinish();
        }
        eglMakeCurrent(_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        _target.reset(); // Unbound, before display/context destruction.
        if (_context != EGL_NO_CONTEXT) eglDestroyContext(_display, _context);
        eglTerminate(_display);
    }
}
@end
