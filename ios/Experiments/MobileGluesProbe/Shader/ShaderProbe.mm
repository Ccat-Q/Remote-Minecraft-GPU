#include "ShaderProbe.h"
#include "DrawFixtures.hpp"
#include "InstanceFixtures.hpp"
#include "RasterFixtures.hpp"
#include <GLES3/gl32.h>
#include <algorithm>
#include <cstddef>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>
#include <chrono>
#include <thread>
#include <memory>

namespace {
void require(bool ok, const char *reason) { if (!ok) throw std::runtime_error(reason); }
struct GL {
    const std::function<void*(const char*)>& resolver;
#define ENTRY(name) decltype(&::name) name = reinterpret_cast<decltype(&::name)>(resolver(#name))
    ENTRY(glCreateShader); ENTRY(glShaderSource); ENTRY(glCompileShader); ENTRY(glGetShaderiv);
    ENTRY(glGetShaderInfoLog); ENTRY(glDeleteShader); ENTRY(glCreateProgram); ENTRY(glAttachShader);
    ENTRY(glBindAttribLocation); ENTRY(glLinkProgram); ENTRY(glGetProgramiv); ENTRY(glGetProgramInfoLog);
    ENTRY(glUseProgram); ENTRY(glDeleteProgram); ENTRY(glGetUniformLocation); ENTRY(glUniform1i);
    ENTRY(glUniform2f); ENTRY(glUniform4fv); ENTRY(glGenVertexArrays); ENTRY(glBindVertexArray);
    ENTRY(glDeleteVertexArrays); ENTRY(glGenBuffers); ENTRY(glBindBuffer); ENTRY(glBufferData);
    ENTRY(glDeleteBuffers); ENTRY(glVertexAttribPointer); ENTRY(glEnableVertexAttribArray);
    ENTRY(glGenTextures); ENTRY(glBindTexture); ENTRY(glActiveTexture); ENTRY(glTexImage2D);
    ENTRY(glTexParameteri); ENTRY(glDeleteTextures); ENTRY(glGenFramebuffers); ENTRY(glBindFramebuffer);
    ENTRY(glFramebufferTexture2D); ENTRY(glCheckFramebufferStatus); ENTRY(glDeleteFramebuffers);
    ENTRY(glViewport); ENTRY(glDisable); ENTRY(glColorMask); ENTRY(glPixelStorei);
    ENTRY(glClearColor); ENTRY(glClear); ENTRY(glDrawArrays); ENTRY(glReadPixels); ENTRY(glGetError);
#undef ENTRY
    using BindFrag = void (*)(GLuint, GLuint, const GLchar*);
    BindFrag glBindFragDataLocation = reinterpret_cast<BindFrag>(resolver("glBindFragDataLocation"));
    explicit GL(const std::function<void*(const char*)>& lookup) : resolver(lookup) {}
    void check(NSMutableString *report, const char *phase) {
        const auto error = glGetError();
        [report appendFormat:@"B12_GL phase=%s error=0x%x\n", phase, error];
        require(error == GL_NO_ERROR, phase);
    }
};
struct Backend {
    const std::function<void*(const char*)>& resolver;
#define ENTRY(name) decltype(&::name) name = reinterpret_cast<decltype(&::name)>(resolver(#name))
    ENTRY(glGetShaderiv); ENTRY(glGetShaderSource); ENTRY(glGetShaderInfoLog);
    ENTRY(glGetProgramiv); ENTRY(glGetProgramInfoLog); ENTRY(glGetError);
#undef ENTRY
    explicit Backend(const std::function<void*(const char*)>& lookup) : resolver(lookup) {}
};
#if RGPU_B12_FEATURE_PROBE
struct FeatureGL {
    const std::function<void*(const char*)>& resolver;
#define ENTRY(name) decltype(&::name) name = reinterpret_cast<decltype(&::name)>(resolver(#name))
    ENTRY(glDrawArraysInstanced); ENTRY(glFenceSync); ENTRY(glClientWaitSync);
    ENTRY(glDeleteSync); ENTRY(glIsSync); ENTRY(glGetSynciv); ENTRY(glFlush);
#undef ENTRY
    explicit FeatureGL(const std::function<void*(const char*)>& lookup) : resolver(lookup) {}
};
void completeFence(FeatureGL& sync, GL& gl, NSMutableString *report, int test) {
    static_assert(GL_ALREADY_SIGNALED == 0x911a && GL_CONDITION_SATISFIED == 0x911c && GL_TIMEOUT_EXPIRED == 0x911b);
    struct Lease {
        FeatureGL& api;
        GLsync object;
        ~Lease() { if (object) api.glDeleteSync(object); }
    } lease{sync,sync.glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE,0)};
    gl.check(report,"create same-context producer fence after instanced draw");
    require(lease.object && sync.glIsSync(lease.object) == GL_TRUE,"Fence allocation/identity failed");
    sync.glFlush();
    const auto started = std::chrono::steady_clock::now();
    unsigned polls = 0; GLenum result = GL_TIMEOUT_EXPIRED;
    do {
        result = sync.glClientWaitSync(lease.object,0,0); ++polls; // nonblocking GL query
        const auto error = gl.glGetError();
        if (polls <= 8 || polls%100 == 0 || result != GL_TIMEOUT_EXPIRED || error != GL_NO_ERROR)
            [report appendFormat:@"B12B_FENCE_POLL case=%d observation=%u result=0x%x GL=0x%x\n",test,polls,result,error];
        require(error == GL_NO_ERROR,"Fence observation GL error");
        if (rgpu::b12::fenceComplete(result)) break;
        require(std::chrono::steady_clock::now()-started < std::chrono::seconds(5),"Fence diagnostic deadline exceeded");
        std::this_thread::sleep_for(std::chrono::milliseconds(1)); // Probe owner only, not render scheduling
    } while (true);
    GLint status = 0; GLsizei returned = 0;
    sync.glGetSynciv(lease.object,GL_SYNC_STATUS,1,&returned,&status);
    gl.check(report,"query observed fence status");
    require(returned == 1 && status == GL_SIGNALED,"Fence query did not confirm completion");
    const double observed = std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-started).count();
    [report appendFormat:@"B12B_FENCE case=%d polls=%u wait_result=0x%x sync_status=0x%x observed_ms=%.3f clock=local_monotonic NOT_GPU_TIMESTAMP_NOT_NETWORK_LATENCY\n",test,polls,result,status,observed];
    GLsync retired = lease.object; sync.glDeleteSync(retired); lease.object = nullptr;
    require(sync.glIsSync(retired) == GL_FALSE,"Retired fence still has live identity");
    gl.check(report,"delete completed fence before pixel read");
    [report appendFormat:@"B12B_FENCE_RELEASE case=%d live=NO\n",test];
}
#endif
#if RGPU_B12_RASTER_PROBE
struct RasterGL {
    const std::function<void*(const char*)>& resolver;
#define ENTRY(name) decltype(&::name) name = reinterpret_cast<decltype(&::name)>(resolver(#name))
    ENTRY(glGenRenderbuffers); ENTRY(glBindRenderbuffer); ENTRY(glRenderbufferStorage);
    ENTRY(glFramebufferRenderbuffer); ENTRY(glDeleteRenderbuffers); ENTRY(glGetRenderbufferParameteriv);
    ENTRY(glEnable); ENTRY(glDepthFunc); ENTRY(glDepthMask); ENTRY(glClearStencil);
    ENTRY(glStencilFunc); ENTRY(glStencilOp); ENTRY(glStencilMask); ENTRY(glUniform1f);
    ENTRY(glBlendFuncSeparate); ENTRY(glBlendEquationSeparate);
#undef ENTRY
    using ClearDepth = void (*)(double); // desktop entry, not glClearDepthf substituted by the App
    ClearDepth glClearDepth = reinterpret_cast<ClearDepth>(resolver("glClearDepth"));
    explicit RasterGL(const std::function<void*(const char*)>& lookup) : resolver(lookup) {}
};
void drawRasterCase(GL& gl,RasterGL& state,NSMutableString *report,int test,
                    GLint offset,GLint scale,GLint tint,GLint depth) {
    auto draw = [&](int left,int bottom,int w,int h,float z,std::array<float,4> color) {
        gl.glUniform2f(offset,float(2*left+w)/16-1,float(2*bottom+h)/16-1);
        gl.glUniform2f(scale,float(w)/16,float(h)/16);
        gl.glUniform4fv(tint,1,color.data()); state.glUniform1f(depth,z);
        gl.glDrawArrays(GL_TRIANGLES,0,6);
    };
    gl.glDisable(GL_BLEND); gl.glDisable(GL_DEPTH_TEST); gl.glDisable(GL_STENCIL_TEST);
    gl.glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE);
    state.glDepthMask(GL_TRUE); state.glStencilMask(0xff);
    state.glClearDepth(1.0); state.glClearStencil(0);
    gl.glClearColor(0,0,test == 3 ? 1 : 0,1);
    gl.glClear(GL_COLOR_BUFFER_BIT|GL_DEPTH_BUFFER_BIT|GL_STENCIL_BUFFER_BIT);
    if (test <= 1) {
        state.glEnable(GL_DEPTH_TEST); state.glDepthFunc(GL_LESS);
        draw(2,2,12,12,-0.5f,{1,0,0,1});
        draw(4,4,8,8,0.5f,{0,0,1,1}); // far layer must not overwrite red
        state.glDepthMask(test == 0 ? GL_TRUE : GL_FALSE);
        draw(6,6,4,4,-0.75f,{0,1,0,1});
        if (test == 1) {
            state.glDepthMask(GL_TRUE);
            draw(6,6,4,4,-0.625f,{1,1,0,1}); // wins only if green did NOT write depth
        }
    } else if (test == 2) {
        state.glEnable(GL_STENCIL_TEST); state.glStencilMask(0x0f);
        state.glStencilFunc(GL_ALWAYS,0xa5,0xff); state.glStencilOp(GL_KEEP,GL_KEEP,GL_REPLACE);
        gl.glColorMask(GL_FALSE,GL_FALSE,GL_FALSE,GL_FALSE);
        draw(2,2,6,12,0,{0,0,1,1}); // only low bits 0x05 are stored
        gl.glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE); state.glStencilMask(0);
        state.glStencilFunc(GL_EQUAL,5,0xff); state.glStencilOp(GL_KEEP,GL_KEEP,GL_INCR);
        draw(0,0,16,16,0,{1,0,0,1}); // INCR must NOT modify stencil with mask zero
        state.glStencilFunc(GL_NOTEQUAL,5,0xff); state.glStencilOp(GL_KEEP,GL_KEEP,GL_KEEP);
        draw(0,0,16,16,0,{0,1,0,1});
    } else {
        require(test == 3,"Unknown raster case");
        state.glEnable(GL_BLEND); state.glBlendEquationSeparate(GL_FUNC_ADD,GL_FUNC_ADD);
        state.glBlendFuncSeparate(GL_SRC_ALPHA,GL_ONE_MINUS_SRC_ALPHA,GL_ONE,GL_ONE_MINUS_SRC_ALPHA);
        draw(1,1,10,10,0,{1,0,0,0.5f});
        draw(5,5,10,10,0,{0,1,0,0.25f});
    }
    gl.check(report,"actual raster-state draw sequence");
    [report appendFormat:@"B12C_OPERATIONS case=%d name=%s; compare full output, NOT state-query-only acceptance\n",test,rgpu::b12::rasterNames[test]];
}
#endif
constexpr GLint maxText = 16384;
template<class Fetch>
std::string textResult(GLint length, Fetch fetch) {
    require(length >= 0 && length <= maxText, "Shader log/source exceeds diagnostic bound");
    std::vector<GLchar> buffer(static_cast<size_t>(std::max(length, GLint(1))), 0);
    GLsizei written = 0; fetch(static_cast<GLsizei>(buffer.size()), &written, buffer.data());
    require(written >= 0 && written < static_cast<GLsizei>(buffer.size()), "Invalid shader log/source length");
    return std::string(buffer.data(), static_cast<size_t>(written));
}
struct Resources {
    GL& gl;
    NSMutableString *report;
    GLuint vertex = 0, fragment = 0, program = 0, vao = 0, buffer = 0, fbo = 0;
    GLuint textures[2]{};
    bool closed = false;
    std::function<void()> additionalCleanup;
    bool close() {
        if (closed) return true;
        closed = true;
        if (additionalCleanup) additionalCleanup();
        // Current root context is retained by the caller until this returns.
        gl.glUseProgram(0); gl.glBindVertexArray(0); gl.glBindBuffer(GL_ARRAY_BUFFER,0);
        gl.glBindFramebuffer(GL_FRAMEBUFFER,0);
        if (program) gl.glDeleteProgram(program);
        if (vertex) gl.glDeleteShader(vertex);
        if (fragment) gl.glDeleteShader(fragment);
        if (fbo) gl.glDeleteFramebuffers(1,&fbo);
        if (vao) gl.glDeleteVertexArrays(1,&vao);
        if (buffer) gl.glDeleteBuffers(1,&buffer);
        gl.glDeleteTextures(2,textures);
        gl.glActiveTexture(GL_TEXTURE0);
        const auto error = gl.glGetError();
        [report appendFormat:@"B12_CLEANUP shader/program/VAO/VBO/FBO/textures release calls returned GL=0x%x; driver leak profiling NOT TESTED\n", error];
        return error == GL_NO_ERROR;
    }
};
void compile(GL& gl, Backend& backend, NSMutableString *report, GLuint shader, const char *source, const char *stage) {
    require(shader != 0, "Cannot allocate shader");
    [report appendFormat:@"B12_SHADER stage=%s original_desktop_source_BEGIN\n%soriginal_desktop_source_END\n", stage, source];
    gl.glShaderSource(shader,1,&source,nullptr); // exact #version 150; never rewritten by the App
    gl.check(report,"submit desktop shader source");
    GLint length = 0;
    backend.glGetShaderiv(shader,GL_SHADER_SOURCE_LENGTH,&length);
    const auto translated = textResult(length,[&](GLsizei n, GLsizei *used, GLchar *text) {
        backend.glGetShaderSource(shader,n,used,text);
    });
    const auto sourceError = backend.glGetError();
    [report appendFormat:@"B12_SHADER stage=%s backend_uploaded_source_BEGIN\n%s\nbackend_uploaded_source_END error=0x%x\n",
        stage, translated.c_str(), sourceError];
    require(sourceError == GL_NO_ERROR && !translated.empty(), "No actual backend shader source captured");
    require(translated != source, "Desktop source was not translated for the GLES backend");
    gl.glCompileShader(shader);
    GLint frontStatus = 0, backStatus = 0, frontLength = 0;
    gl.glGetShaderiv(shader,GL_COMPILE_STATUS,&frontStatus);
    backend.glGetShaderiv(shader,GL_COMPILE_STATUS,&backStatus);
    gl.glGetShaderiv(shader,GL_INFO_LOG_LENGTH,&frontLength);
    const auto frontLog = textResult(frontLength,[&](GLsizei n, GLsizei *used, GLchar *text) {
        gl.glGetShaderInfoLog(shader,n,used,text);
    });
    backend.glGetShaderiv(shader,GL_INFO_LOG_LENGTH,&length);
    const auto backendLog = textResult(length,[&](GLsizei n, GLsizei *used, GLchar *text) {
        backend.glGetShaderInfoLog(shader,n,used,text);
    });
    [report appendFormat:@"B12_COMPILE stage=%s frontend=%d backend=%d frontend_log_BEGIN\n%s\nfrontend_log_END backend_log_BEGIN\n%s\nbackend_log_END\n",
        stage, frontStatus, backStatus, frontLog.c_str(), backendLog.c_str()];
    gl.check(report,"actual shader compilation");
    require(frontStatus == GL_TRUE && backStatus == GL_TRUE, "Real shader compilation failed (see logs)");
}
void linkProgram(GL& gl,Backend& backend,NSMutableString *report,Resources& resources,GLuint geometry = 0) {
    resources.program = gl.glCreateProgram();
    require(resources.program != 0,"Cannot allocate program");
    gl.glAttachShader(resources.program,resources.vertex); gl.glAttachShader(resources.program,resources.fragment);
    if (geometry) gl.glAttachShader(resources.program,geometry);
    gl.glBindAttribLocation(resources.program,0,"aPosition"); gl.glBindAttribLocation(resources.program,1,"aUV");
    gl.glBindFragDataLocation(resources.program,0,"outColor0");
    gl.glLinkProgram(resources.program);
    GLint status = 0, rawStatus = 0, length = 0;
    gl.glGetProgramiv(resources.program,GL_LINK_STATUS,&status);
    backend.glGetProgramiv(resources.program,GL_LINK_STATUS,&rawStatus);
    gl.glGetProgramiv(resources.program,GL_INFO_LOG_LENGTH,&length);
    const auto frontLog = textResult(length,[&](GLsizei n,GLsizei *used,GLchar *text) {
        gl.glGetProgramInfoLog(resources.program,n,used,text);
    });
    backend.glGetProgramiv(resources.program,GL_INFO_LOG_LENGTH,&length);
    const auto rawLog = textResult(length,[&](GLsizei n,GLsizei *used,GLchar *text) {
        backend.glGetProgramInfoLog(resources.program,n,used,text);
    });
    [report appendFormat:@"B12_LINK frontend=%d backend=%d frontend_log_BEGIN\n%s\nfrontend_log_END backend_log_BEGIN\n%s\nbackend_log_END\n",
        status,rawStatus,frontLog.c_str(),rawLog.c_str()];
    gl.check(report,"actual program link");
    require(status == GL_TRUE && rawStatus == GL_TRUE,"Real program link failed (see logs)");
}
}

static void runDrawProbe(NSMutableString *report,
    const std::function<void*(const char*)>& frontend,
    const std::function<void*(const char*)>& backendResolver, bool instanced,bool raster = false) {
    using namespace rgpu::b12;
    require(!(instanced && raster),"Conflicting draw probe modes");
    [report appendString:raster ? @"B12C_STAGE DEPTH_STENCIL_BLEND\nNOT complete raster semantics, full B1.2 or guest acceptance.\n" :
        instanced ? @"B12B_STAGE INSTANCING_AND_SAME_CONTEXT_FENCE\nNOT full B1.2, cross-context synchronization or guest acceptance.\n" :
        @"B12_STAGE GLSL150_VERTEX_FRAGMENT_DYNAMIC_FBO\nScope: representative shader/VAO/VBO/FBO/texture/uniform/varying checks only. NOT full B1.2 or guest GL acceptance.\n"];
    GL gl(frontend); Backend backend(backendResolver);
#if RGPU_B12_RASTER_PROBE
    std::unique_ptr<RasterGL> rasterState;
    GLuint depthStencil = 0;
#endif
    Resources resources{gl,report};
    try {
#if RGPU_B12_RASTER_PROBE
        if (raster) {
            rasterState = std::make_unique<RasterGL>(frontend);
            resources.additionalCleanup = [&] {
                gl.glDisable(GL_DEPTH_TEST); gl.glDisable(GL_STENCIL_TEST); gl.glDisable(GL_BLEND);
                gl.glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE);
                rasterState->glDepthMask(GL_TRUE); rasterState->glStencilMask(0xff);
                rasterState->glBindRenderbuffer(GL_RENDERBUFFER,0);
                if (depthStencil) { rasterState->glDeleteRenderbuffers(1,&depthStencil); depthStencil = 0; }
                [report appendString:@"B12C_CLEANUP depth/stencil renderbuffer release and state restore calls returned; GL status follows\n"];
            };
        }
#endif
        gl.check(report,"shader probe entry (prior errors are not discarded)");
        resources.vertex = gl.glCreateShader(GL_VERTEX_SHADER);
        compile(gl,backend,report,resources.vertex,raster ? rasterVertex : instanced ? instanceVertex : vertexSource,"vertex");
        resources.fragment = gl.glCreateShader(GL_FRAGMENT_SHADER);
        compile(gl,backend,report,resources.fragment,instanced ? instanceFragment : fragmentSource,"fragment");
        linkProgram(gl,backend,report,resources);
        gl.glUseProgram(resources.program);
        auto uniform = [&](const char *name) { GLint location = gl.glGetUniformLocation(resources.program,name);
            [report appendFormat:@"B12_UNIFORM name=%s location=%d\n", name,location];
            require(location >= 0,"Required active uniform missing"); return location; };
        const auto offset = uniform("uOffset"), scale = uniform("uScale"), tint = uniform("uTint"), sampler = uniform("uTex");
        const GLint depth = raster ? uniform("uDepth") : -1;
        (void)depth; // used only by the isolated raster target
        if (instanced) gl.glUniform2f(uniform("uStep"),1,1);
        gl.glGenVertexArrays(1,&resources.vao); gl.glBindVertexArray(resources.vao);
        gl.glGenBuffers(1,&resources.buffer); gl.glBindBuffer(GL_ARRAY_BUFFER,resources.buffer);
        require(resources.vao && resources.buffer,"VAO/VBO allocation failed");
        gl.glBufferData(GL_ARRAY_BUFFER,sizeof(vertices),vertices.data(),GL_STATIC_DRAW);
        gl.glVertexAttribPointer(0,2,GL_FLOAT,GL_FALSE,sizeof(Vertex),reinterpret_cast<void*>(offsetof(Vertex,x)));
        gl.glVertexAttribPointer(1,2,GL_FLOAT,GL_FALSE,sizeof(Vertex),reinterpret_cast<void*>(offsetof(Vertex,u)));
        gl.glEnableVertexAttribArray(0); gl.glEnableVertexAttribArray(1);
        gl.glBindVertexArray(0); gl.glBindBuffer(GL_ARRAY_BUFFER,0); gl.glBindVertexArray(resources.vao);
        gl.glGenTextures(2,resources.textures);
        require(resources.textures[0] && resources.textures[1],"Shader texture allocation failed");
        gl.glActiveTexture(GL_TEXTURE0); gl.glBindTexture(GL_TEXTURE_2D,resources.textures[0]);
        gl.glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,width,height,0,GL_RGBA,GL_UNSIGNED_BYTE,nullptr);
        gl.glGenFramebuffers(1,&resources.fbo); gl.glBindFramebuffer(GL_FRAMEBUFFER,resources.fbo);
        require(resources.fbo != 0,"Shader FBO allocation failed");
        gl.glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,resources.textures[0],0);
#if RGPU_B12_RASTER_PROBE
        if (raster) {
            rasterState->glGenRenderbuffers(1,&depthStencil);
            require(depthStencil != 0,"Depth/stencil renderbuffer allocation failed");
            rasterState->glBindRenderbuffer(GL_RENDERBUFFER,depthStencil);
            rasterState->glRenderbufferStorage(GL_RENDERBUFFER,GL_DEPTH24_STENCIL8,width,height);
            rasterState->glFramebufferRenderbuffer(GL_FRAMEBUFFER,GL_DEPTH_STENCIL_ATTACHMENT,GL_RENDERBUFFER,depthStencil);
            GLint depthBits = 0, stencilBits = 0;
            rasterState->glGetRenderbufferParameteriv(GL_RENDERBUFFER,GL_RENDERBUFFER_DEPTH_SIZE,&depthBits);
            rasterState->glGetRenderbufferParameteriv(GL_RENDERBUFFER,GL_RENDERBUFFER_STENCIL_SIZE,&stencilBits);
            gl.check(report,"allocate actual packed depth/stencil attachment");
            [report appendFormat:@"B12C_ATTACHMENT format=DEPTH24_STENCIL8 depth_bits=%d stencil_bits=%d\n",depthBits,stencilBits];
            require(depthBits >= 24 && stencilBits >= 8,"Requested depth/stencil storage unavailable");
        }
#endif
        const auto complete = gl.glCheckFramebufferStatus(GL_FRAMEBUFFER);
        [report appendFormat:@"B12_FBO format=RGBA8 size=%dx%d status=0x%x\n",width,height,complete];
        require(complete == GL_FRAMEBUFFER_COMPLETE,"Shader test FBO incomplete");
        for (const auto cap : {GL_BLEND,GL_DEPTH_TEST,GL_STENCIL_TEST,GL_SCISSOR_TEST,GL_CULL_FACE,GL_DITHER}) gl.glDisable(cap);
        gl.glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE); gl.glPixelStorei(GL_PACK_ALIGNMENT,1); gl.glPixelStorei(GL_UNPACK_ALIGNMENT,1);
        gl.glViewport(0,0,width,height); gl.glUniform2f(scale,scaleX,instanced ? scaleX : scaleY);
        gl.check(report,"shader draw resources and state");
        for (int index = 0; index < (raster ? rasterCases : instanced ? instanceCases : cases); ++index) {
            const auto& input = raster ? rasterInput : instanced ? instanceInputs[index] : inputs[index];
            gl.glActiveTexture(GL_TEXTURE0 + input.textureUnit); gl.glBindTexture(GL_TEXTURE_2D,resources.textures[1]);
            gl.glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);
            gl.glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
            gl.glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);
            gl.glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
            gl.glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,2,2,0,GL_RGBA,GL_UNSIGNED_BYTE,input.texture.data());
            gl.glUniform1i(sampler,input.textureUnit); gl.glUniform2f(offset,input.offsetX,input.offsetY);
            gl.glUniform4fv(tint,1,input.tint.data());
            gl.glClearColor(0,0,0,1); gl.glClear(GL_COLOR_BUFFER_BIT);
            if (raster) {
#if RGPU_B12_RASTER_PROBE
                drawRasterCase(gl,*rasterState,report,index,offset,scale,tint,depth);
#else
                throw std::runtime_error("Raster probe not compiled for this target");
#endif
            } else if (instanced) {
#if RGPU_B12_FEATURE_PROBE
                FeatureGL features(frontend);
                features.glDrawArraysInstanced(GL_TRIANGLES,0,6,instanceCounts[index]);
                gl.check(report,"actual instanced draw submission");
                completeFence(features,gl,report,index);
#else
                throw std::runtime_error("Instancing probe was not compiled for this target");
#endif
            } else { gl.glDrawArrays(GL_TRIANGLES,0,6); }
            std::array<Pixel,width*height> actual{};
            gl.glReadPixels(0,0,width,height,GL_RGBA,GL_UNSIGNED_BYTE,actual.data());
            gl.check(report,"dynamic GLSL150 draw and local diagnostic read");
            int mismatches = 0;
            for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
                const auto expected = raster ? expectedRasterPixel(index,x,y) : instanced ? expectedInstancePixel(index,x,y) : expectedPixel(input,x,y);
                const auto& pixel = actual[y*width+x];
                if (!matches(pixel,expected)) {
                    if (mismatches < 8) [report appendFormat:@"B12_MISMATCH case=%d x=%d y=%d actual=%u,%u,%u,%u expected=%u,%u,%u,%u\n",
                        index,x,y,pixel[0],pixel[1],pixel[2],pixel[3],expected[0],expected[1],expected[2],expected[3]];
                    ++mismatches;
                }
            }
            // Retain the entire small actual image in the report, bottom row
            // first. A test oracle is not a CPU display/transport implementation.
            [report appendFormat:@"%s_ACTUAL_RGBA8 case=%d rows_bottom_to_top_BEGIN\n",raster ? "B12C" : instanced ? "B12B" : "B12",index];
            for (int y = 0; y < height; ++y) {
                for (int x = 0; x < width; ++x) { const auto& p = actual[y*width+x];
                    [report appendFormat:@"%02x%02x%02x%02x ",p[0],p[1],p[2],p[3]]; }
                [report appendString:@"\n"];
            }
            if (raster) [report appendFormat:@"rows_bottom_to_top_END\nB12C_CASE case=%d name=%s checked_pixels=%d mismatches=%d rgb_tolerance=1 alpha_tolerance=0\n",
                index,rasterNames[index],width*height,mismatches];
            else if (instanced) [report appendFormat:@"rows_bottom_to_top_END\nB12B_CASE case=%d instance_count=%d checked_pixels=%d mismatches=%d rgb_tolerance=1 alpha_tolerance=0\n",
                index,instanceCounts[index],width*height,mismatches];
            else [report appendFormat:@"rows_bottom_to_top_END\nB12_CASE case=%d texture_unit=%d rect=%d,%d,6,12 checked_pixels=%d mismatches=%d rgb_tolerance=1 alpha_tolerance=0\n",
                index,input.textureUnit,input.left,input.bottom,width*height,mismatches];
            require(mismatches == 0,"Dynamic shader output mismatch (actual pixels retained)");
        }
        require(resources.close(),"Shader probe cleanup GL error");
        if (raster) [report appendString:@"PASS: B1.2c representative depth LESS/occlusion/write-mask, stencil compare/ops/write-mask and separate RGB/Alpha blending ONLY. NOT all raster semantics, TextureBuffer, Geometry, full B1.2 or guest acceptance.\n"];
        else if (instanced) [report appendString:@"PASS: B1.2b representative glDrawArraysInstanced/gl_InstanceID/flat varying/texelFetch and same-context producer Fence completion before pixel read ONLY. NOT cross-context ordering, slow-GPU cancellation or sustained performance. Depth/Stencil/Blending/TextureBuffer/Geometry and guest NOT TESTED.\n"];
        else [report appendString:@"PASS: B1.2a GLSL150 vertex/fragment translation, actual compile/link, VAO/VBO/FBO, sampled texture, uniforms and varying over three dynamic inputs ONLY.\nB1.2 remaining Instancing/Depth/Stencil/Blending/TextureBuffer/Sync/Geometry NOT TESTED; guest/VirGL/Minecraft NOT TESTED.\n"];
    } catch (...) { resources.close(); throw; }
}
void RGPURunShaderDrawProbe(NSMutableString *report,const std::function<void*(const char*)>& frontend,
                          const std::function<void*(const char*)>& backend) {
    runDrawProbe(report,frontend,backend,false);
}
#if RGPU_B12_RASTER_PROBE
void RGPURunRasterProbe(NSMutableString *report,const std::function<void*(const char*)>& frontend,
                       const std::function<void*(const char*)>& backend) {
    runDrawProbe(report,frontend,backend,false,true);
}
#endif
#if RGPU_B12_FEATURE_PROBE
void RGPURunInstancingSyncProbe(NSMutableString *report,const std::function<void*(const char*)>& frontend,
                              const std::function<void*(const char*)>& backend) {
    runDrawProbe(report,frontend,backend,true);
}
#endif

#if RGPU_B12_CORE_PROBE
namespace {
template<class Oracle>
int capabilityPixels(GL& gl,NSMutableString *report,const char *feature,int test,const char *operation,Oracle oracle) {
    using namespace rgpu::b12;
    std::array<Pixel,width*height> pixels{};
    gl.glReadPixels(0,0,width,height,GL_RGBA,GL_UNSIGNED_BYTE,pixels.data());
    gl.check(report,"B1.2d local diagnostic output read");
    int mismatches = 0;
    [report appendFormat:@"B12D_ACTUAL_RGBA8 feature=%s case=%d operation=%s rows_bottom_to_top_BEGIN\n",feature,test,operation];
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const auto& p = pixels[y*width+x];
            [report appendFormat:@"%02x%02x%02x%02x ",p[0],p[1],p[2],p[3]];
        }
        [report appendString:@"\n"];
    }
    [report appendString:@"rows_bottom_to_top_END\n"];
    for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
        const auto& p = pixels[y*width+x]; const auto expected = oracle(x,y);
        if (!matches(p,expected)) {
            if (mismatches < 8) [report appendFormat:@"B12D_MISMATCH feature=%s case=%d x=%d y=%d actual=%u,%u,%u,%u expected=%u,%u,%u,%u\n",
                feature,test,x,y,p[0],p[1],p[2],p[3],expected[0],expected[1],expected[2],expected[3]];
            ++mismatches;
        }
    }
    [report appendFormat:@"B12D_CASE feature=%s case=%d operation=%s checked_pixels=%d mismatches=%d rgb_tolerance=1 alpha_tolerance=0\n",
        feature,test,operation,width*height,mismatches];
    return mismatches;
}
}
void RGPURunCapabilityProbe(NSMutableString *report,const std::function<void*(const char*)>& frontend,
    const std::function<void*(const char*)>& backendResolver,rgpu::b12::Capability kind) {
    using namespace rgpu::b12;
    const bool geometry = kind == Capability::Geometry;
    const char *feature = capabilityNames[static_cast<size_t>(kind)];
    [report appendFormat:@"B12D_STAGE feature=%s; fresh unshared context; NOT full capability conformance\n",feature];
    GL gl(frontend); Backend backend(backendResolver);
    GLuint geometryShader = 0, dataBuffer = 0; bool bufferTextureBound = false;
    Resources resources{gl,report};
    resources.additionalCleanup = [&] {
        gl.glActiveTexture(GL_TEXTURE0);
        if (bufferTextureBound) gl.glBindTexture(GL_TEXTURE_BUFFER,0);
        if (dataBuffer) { gl.glDeleteBuffers(1,&dataBuffer); dataBuffer = 0; }
        if (geometryShader) { gl.glDeleteShader(geometryShader); geometryShader = 0; }
        [report appendFormat:@"B12D_CLEANUP feature=%s extra buffer/geometry shader release calls returned; GL status follows\n",feature];
    };
    try {
        gl.check(report,"B1.2d feature entry (prior errors not discarded)");
        if (geometry) {
            [report appendFormat:@"B12D_GEOMETRY original_desktop_source_BEGIN\n%soriginal_desktop_source_END\n",geometrySource];
            geometryShader = gl.glCreateShader(GL_GEOMETRY_SHADER);
            const auto frontError = gl.glGetError(), rawError = backend.glGetError();
            [report appendFormat:@"B12D_CREATE_GEOMETRY object=%u frontend_GL=0x%x backend_GL=0x%x\n",geometryShader,frontError,rawError];
            require(geometryShader && frontError == GL_NO_ERROR && rawError == GL_NO_ERROR,
                "Geometry shader creation rejected; compilation/link/draw NOT RUN (see actual creation errors)");
            compile(gl,backend,report,geometryShader,geometrySource,"geometry");
        }
        resources.vertex = gl.glCreateShader(GL_VERTEX_SHADER);
        compile(gl,backend,report,resources.vertex,capabilityVertex,"vertex");
        resources.fragment = gl.glCreateShader(GL_FRAGMENT_SHADER);
        compile(gl,backend,report,resources.fragment,geometry ? geometryFragment :
            kind == Capability::SignedBuffer ? signedBufferFragment : floatBufferFragment,"fragment");
        linkProgram(gl,backend,report,resources,geometryShader);
        gl.glUseProgram(resources.program);
        auto uniform = [&](const char *name) {
            const auto location = gl.glGetUniformLocation(resources.program,name);
            [report appendFormat:@"B12D_UNIFORM feature=%s name=%s location=%d\n",feature,name,location];
            require(location >= 0,"Required B1.2d uniform missing"); return location;
        };
        gl.glGenVertexArrays(1,&resources.vao); gl.glBindVertexArray(resources.vao);
        gl.glGenBuffers(1,&resources.buffer); gl.glBindBuffer(GL_ARRAY_BUFFER,resources.buffer);
        require(resources.vao && resources.buffer,"B1.2d VAO/VBO allocation failed");
        gl.glBufferData(GL_ARRAY_BUFFER,sizeof(vertices),vertices.data(),GL_STATIC_DRAW);
        gl.glVertexAttribPointer(0,2,GL_FLOAT,GL_FALSE,sizeof(Vertex),reinterpret_cast<void*>(offsetof(Vertex,x)));
        gl.glEnableVertexAttribArray(0);
        gl.glGenTextures(2,resources.textures);
        require(resources.textures[0] && resources.textures[1],"B1.2d texture allocation failed");
        gl.glActiveTexture(GL_TEXTURE0); gl.glBindTexture(GL_TEXTURE_2D,resources.textures[0]);
        gl.glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,width,height,0,GL_RGBA,GL_UNSIGNED_BYTE,nullptr);
        gl.glGenFramebuffers(1,&resources.fbo); gl.glBindFramebuffer(GL_FRAMEBUFFER,resources.fbo);
        require(resources.fbo != 0,"B1.2d FBO allocation failed");
        gl.glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,resources.textures[0],0);
        const auto complete = gl.glCheckFramebufferStatus(GL_FRAMEBUFFER);
        [report appendFormat:@"B12D_FBO feature=%s format=RGBA8 size=16x16 status=0x%x\n",feature,complete];
        require(complete == GL_FRAMEBUFFER_COMPLETE,"B1.2d FBO incomplete");
        for (const auto cap : {GL_BLEND,GL_DEPTH_TEST,GL_STENCIL_TEST,GL_SCISSOR_TEST,GL_CULL_FACE,GL_DITHER}) gl.glDisable(cap);
        gl.glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE);
        gl.glPixelStorei(GL_PACK_ALIGNMENT,1); gl.glPixelStorei(GL_UNPACK_ALIGNMENT,1);
        gl.glViewport(0,0,width,height);
        gl.check(report,"B1.2d actual draw resources/state");
        int mismatches = 0;
        if (geometry) {
            const auto scale = uniform("uScale"), offset = uniform("uOffset"), color = uniform("uColor");
            gl.glUniform2f(scale,0.375f,0.75f);
            for (int test = 0; test < geometryCases; ++test) {
                gl.glUniform2f(offset,test == 0 ? -0.5f : 0.5f,0);
                const std::array<float,4> tint = test == 0 ? std::array<float,4>{1,0.25f,0,1} : std::array<float,4>{0,0.5f,1,1};
                gl.glUniform4fv(color,1,tint.data());
                gl.glClearColor(0,0,0,1); gl.glClear(GL_COLOR_BUFFER_BIT);
                gl.glDrawArrays(GL_TRIANGLES,0,6);
                gl.check(report,"actual geometry shader draw");
                mismatches += capabilityPixels(gl,report,feature,test,"GEOMETRY_DYNAMIC_DRAW",
                    [&](int x,int y) { return expectedGeometryPixel(test,x,y); });
            }
        } else {
            const auto texBuffer = reinterpret_cast<decltype(&::glTexBuffer)>(frontend("glTexBuffer"));
            const auto subData = reinterpret_cast<decltype(&::glBufferSubData)>(frontend("glBufferSubData"));
            gl.glUniform1i(uniform("uBuffer"),0); const auto bias = uniform("uBias");
            gl.glGenBuffers(1,&dataBuffer); require(dataBuffer != 0,"Texture buffer allocation failed");
            // Generic ARRAY_BUFFER storage is legal desktop GL. The additional
            // TEXTURE_BUFFER buffer-binding target itself is not accepted here.
            gl.glBindBuffer(GL_ARRAY_BUFFER,dataBuffer);
            if (kind == Capability::SignedBuffer) gl.glBufferData(GL_ARRAY_BUFFER,sizeof(signedInitial),signedInitial.data(),GL_DYNAMIC_DRAW);
            else gl.glBufferData(GL_ARRAY_BUFFER,sizeof(floatInitial),floatInitial.data(),GL_DYNAMIC_DRAW);
            gl.glBindTexture(GL_TEXTURE_BUFFER,resources.textures[1]); bufferTextureBound = true;
            const GLenum format = kind == Capability::SignedBuffer ? GL_R8I : GL_RGBA32F;
            texBuffer(GL_TEXTURE_BUFFER,format,dataBuffer);
            gl.check(report,"actual desktop Texture Buffer attachment");
            for (int test = 0; test < bufferCases; ++test) {
                if (test == 1) {
                    if (kind == Capability::SignedBuffer) subData(GL_ARRAY_BUFFER,0,sizeof(signedUpdated),signedUpdated.data());
                    else subData(GL_ARRAY_BUFFER,0,sizeof(floatUpdated),floatUpdated.data());
                    // Intentionally NO reattachment: live buffer storage changes
                    // must become visible to the already attached texture.
                } else if (test == 2) {
                    // Separate diagnostic, NEVER counted as fixing case 1.
                    texBuffer(GL_TEXTURE_BUFFER,format,dataBuffer);
                }
                gl.glUniform1i(bias,test == 0 ? 0 : 1);
                const char *operation = test == 0 ? "INITIAL_ATTACH" : test == 1 ? "SUBDATA_WITHOUT_REATTACH" : "EXPLICIT_REATTACH_DIAGNOSTIC";
                [report appendFormat:@"B12D_OPERATIONS feature=%s case=%d operation=%s\n",feature,test,operation];
                gl.glClearColor(0,0,0,1); gl.glClear(GL_COLOR_BUFFER_BIT);
                gl.glDrawArrays(GL_TRIANGLES,0,6);
                gl.check(report,"actual Texture Buffer shader draw/update");
                mismatches += capabilityPixels(gl,report,feature,test,operation,
                    [&](int x,int y) { return expectedBufferPixel(kind,test,x,y); });
            }
        }
        require(resources.close(),"B1.2d feature cleanup GL error");
        require(mismatches == 0,"B1.2d actual output mismatch; all attempted cases/images retained, reattach cannot waive failed update semantics");
    } catch (...) { resources.close(); throw; }
}
#endif
