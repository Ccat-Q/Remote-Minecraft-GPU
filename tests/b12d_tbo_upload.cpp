// Executes actual TBOUpload.inc against a recording backend, NOT OpenGL/GPU.
#define GL_GLEXT_PROTOTYPES
#include <GL/glcorearb.h>
#include "TBOAttachments.hpp"
#include <cassert>
#include <map>
#include <tuple>
#include <iostream>
#define LOG()
struct Texture { GLuint texture; GLenum internal_format; GLsizei width=0,height=0,depth=0; };
std::map<GLuint,Texture> textures{{11,{11,0}},{12,{12,0}}};
struct { bool emulate_texture_buffer=true; } hw;
auto* hardware = &hw;
struct { rgpu::tbo::Attachments tboAttachments; } group;
auto* g_bg = &group;
GLenum observedError = 0;
void mg_set_gl_error(GLenum e) { observedError=e; }
Texture* mgGetTexObjectByID(GLuint t) { const auto it=textures.find(t); return it==textures.end()?nullptr:&it->second; }
Texture* mgGetTexObjectByTarget(GLenum) { return mgGetTexObjectByID(11); }
GLuint find_real_buffer(GLuint b) { return b==7 ? 107 : b==8 ? 108 : 0; }
bool has_buffer(GLuint b) { return find_real_buffer(b)!=0; }
GLuint find_bound_buffer_by_target(GLenum) { return 7; }
std::size_t get_buffer_data_size(GLuint) { return 64; }
GLuint get_internal_format_size(GLenum f) { return f==GL_R8I?1:f==GL_RGBA32F?16:0; }
bool get_internal_format_transfer(GLenum f,GLenum* format,GLenum* type) {
    *format=f==GL_R8I?GL_RED_INTEGER:GL_RGBA; *type=f==GL_R8I?GL_BYTE:GL_FLOAT;
    return get_internal_format_size(f)!=0;
}
struct Fake {
    std::map<GLenum,GLint> state{{GL_ACTIVE_TEXTURE,GL_TEXTURE0+3},{GL_TEXTURE_BINDING_2D,99},
        {GL_PIXEL_UNPACK_BUFFER_BINDING,88},{GL_UNPACK_ALIGNMENT,8},{GL_UNPACK_ROW_LENGTH,17},
        {GL_UNPACK_SKIP_PIXELS,5},{GL_UNPACK_SKIP_ROWS,6}};
    std::vector<std::tuple<GLint,GLint,GLsizei,std::size_t>> uploads;
    unsigned allocations=0;
    void glGetIntegerv(GLenum t,GLint* v) { *v=t==GL_MAX_TEXTURE_SIZE?8192:state.at(t); }
    void glGetBufferParameteri64v(GLenum,GLenum,GLint64* v) { *v=64; }
    void glActiveTexture(GLenum unit) { state[GL_ACTIVE_TEXTURE]=unit; }
    void glBindBuffer(GLenum t,GLuint id) { assert(t==GL_PIXEL_UNPACK_BUFFER); state[GL_PIXEL_UNPACK_BUFFER_BINDING]=id; }
    void glBindTexture(GLenum t,GLuint id) { assert(t==GL_TEXTURE_2D); state[GL_TEXTURE_BINDING_2D]=id; }
    void glPixelStorei(GLenum t,GLint v) { state[t]=v; }
    void glTexParameteri(GLenum,GLenum,GLint) {}
    void glTexImage2D(GLenum,GLint,GLint,GLsizei,GLsizei,GLint,GLenum,GLenum,const void*) {
        assert(state[GL_PIXEL_UNPACK_BUFFER_BINDING]==0); ++allocations;
    }
    void glTexSubImage2D(GLenum,GLint,GLint x,GLint y,GLsizei w,GLsizei h,GLenum,GLenum,const void* offset) {
        assert(h==1 && state[GL_PIXEL_UNPACK_BUFFER_BINDING]==107);
        assert(state[GL_UNPACK_ALIGNMENT]==1 && state[GL_UNPACK_ROW_LENGTH]==0);
        assert(state[GL_UNPACK_SKIP_PIXELS]==0 && state[GL_UNPACK_SKIP_ROWS]==0);
        uploads.emplace_back(x,y,w,reinterpret_cast<std::size_t>(offset));
    }
    void glTexBuffer(GLenum,GLenum,GLuint) { assert(false); }
} GLES;
#include "TBOUpload.inc"
int main() {
    const auto saved=GLES.state;
    glTexBuffer(GL_TEXTURE_BUFFER,GL_RGBA32F,7);
    assert(!observedError && GLES.state==saved && GLES.allocations==1);
    assert(textures[11].width==4 && textures[11].height==1);
    assert(group.tboAttachments.forBuffer(7).size()==1);
    GLES.uploads.clear(); refreshTBOs(GL_ARRAY_BUFFER,false,17,1);
    assert(GLES.state==saved && GLES.allocations==1 && GLES.uploads.size()==1);
    assert(std::get<0>(GLES.uploads[0])==1 && std::get<2>(GLES.uploads[0])==1 && std::get<3>(GLES.uploads[0])==16);
    assert(uploadTBO({12,7,GL_R8I},true)); group.tboAttachments.attach(12,7,GL_R8I);
    GLES.uploads.clear(); refreshTBOs(GL_ARRAY_BUFFER,false,0,64);
    assert(GLES.uploads.size()==2 && GLES.state==saved);
    rgpu_tbo_forget_texture(12); assert(group.tboAttachments.forBuffer(7).size()==1);
    group.tboAttachments.eraseBuffer(7); GLES.uploads.clear(); refreshTBOs(GL_ARRAY_BUFFER,false,0,64);
    assert(GLES.uploads.empty());
    assert(!uploadTBO({999,7,GL_R8I},true)); assert(observedError==GL_INVALID_OPERATION && GLES.state==saved);
    observedError=0; glTexBuffer(GL_TEXTURE_BUFFER,GL_RGBA32F,0);
    assert(!observedError && textures[11].width==0 && GLES.state==saved);
    std::cout << "PASS: actual TBO upload/partial update/dependency/state restore on recording backend; NOT GPU execution\n";
}
