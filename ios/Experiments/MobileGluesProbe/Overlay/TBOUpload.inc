// Included by gl/buffer.cpp AFTER its format helpers. GPU-to-texture copies only.
// No glTexBuffer reattachment, readback, hidden glGetError or App uniform writes.
namespace {
struct TBOSavedState {
    GLint active = 0, texture = 0, unpack = 0, alignment = 0, row = 0, skipX = 0, skipY = 0;
    TBOSavedState() {
        GLES.glGetIntegerv(GL_ACTIVE_TEXTURE,&active);
        GLES.glActiveTexture(GL_TEXTURE0+15);
        GLES.glGetIntegerv(GL_TEXTURE_BINDING_2D,&texture);
        GLES.glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING,&unpack);
        GLES.glGetIntegerv(GL_UNPACK_ALIGNMENT,&alignment);
        GLES.glGetIntegerv(GL_UNPACK_ROW_LENGTH,&row);
        GLES.glGetIntegerv(GL_UNPACK_SKIP_PIXELS,&skipX);
        GLES.glGetIntegerv(GL_UNPACK_SKIP_ROWS,&skipY);
        GLES.glPixelStorei(GL_UNPACK_ALIGNMENT,1);
        GLES.glPixelStorei(GL_UNPACK_ROW_LENGTH,0);
        GLES.glPixelStorei(GL_UNPACK_SKIP_PIXELS,0);
        GLES.glPixelStorei(GL_UNPACK_SKIP_ROWS,0);
    }
    ~TBOSavedState() {
        GLES.glBindBuffer(GL_PIXEL_UNPACK_BUFFER,unpack);
        GLES.glPixelStorei(GL_UNPACK_ALIGNMENT,alignment);
        GLES.glPixelStorei(GL_UNPACK_ROW_LENGTH,row);
        GLES.glPixelStorei(GL_UNPACK_SKIP_PIXELS,skipX);
        GLES.glPixelStorei(GL_UNPACK_SKIP_ROWS,skipY);
        GLES.glBindTexture(GL_TEXTURE_2D,texture);
        GLES.glActiveTexture(active);
    }
};
bool uploadTBO(const rgpu::tbo::Attachment& edge, bool allocate,
               std::size_t offset = 0, std::size_t count = 0) {
    auto* tex = mgGetTexObjectByID(edge.texture);
    const auto real = find_real_buffer(edge.buffer);
    const auto pixel = get_internal_format_size(edge.format);
    GLenum format = 0, type = 0;
    if (!tex || !real || !pixel || !get_internal_format_transfer(edge.format,&format,&type)) {
        mg_set_gl_error(GL_INVALID_OPERATION); return false;
    }
    TBOSavedState saved;
    GLES.glBindBuffer(GL_PIXEL_UNPACK_BUFFER,real);
    GLint64 byteCount = 0;
    GLES.glGetBufferParameteri64v(GL_PIXEL_UNPACK_BUFFER,GL_BUFFER_SIZE,&byteCount);
    GLint maxSize = 0; GLES.glGetIntegerv(GL_MAX_TEXTURE_SIZE,&maxSize);
    if (byteCount < 0 || maxSize <= 0) { mg_set_gl_error(GL_INVALID_OPERATION); return false; }
    const auto bytes = static_cast<std::size_t>(byteCount), elements = bytes/pixel;
    const auto width = std::min<std::size_t>(elements,std::min(maxSize,8192));
    const auto height = width ? (elements-1)/width+1 : 0;
    if (height > static_cast<std::size_t>(maxSize)) { mg_set_gl_error(GL_OUT_OF_MEMORY); return false; }
    GLES.glBindTexture(GL_TEXTURE_2D,edge.texture);
    if (allocate) {
        GLES.glBindBuffer(GL_PIXEL_UNPACK_BUFFER,0);
        GLES.glTexImage2D(GL_TEXTURE_2D,0,edge.format,static_cast<GLsizei>(width),
                          static_cast<GLsizei>(height),0,format,type,nullptr);
        GLES.glBindBuffer(GL_PIXEL_UNPACK_BUFFER,real);
        GLES.glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);
        GLES.glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
        GLES.glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_BASE_LEVEL,0);
        GLES.glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAX_LEVEL,0);
        tex->internal_format = edge.format; tex->width = width; tex->height = height; tex->depth = 1;
        count = bytes; offset = 0;
    } else if (tex->width != static_cast<GLsizei>(width) || tex->height != static_cast<GLsizei>(height)) {
        mg_set_gl_error(GL_INVALID_OPERATION); return false;
    }
    for (const auto& span : rgpu::tbo::spans(bytes,pixel,width,offset,count))
        GLES.glTexSubImage2D(GL_TEXTURE_2D,0,span.x,span.row,span.count,1,format,type,
                             reinterpret_cast<const void*>(span.byteOffset));
    return true;
}
void refreshTBOs(GLenum target, bool allocate, GLintptr offset = 0, GLsizeiptr count = 0) {
    if (!hardware->emulate_texture_buffer || offset < 0 || count < 0) return;
    const auto buffer = find_bound_buffer_by_target(target);
    if (!buffer) return;
    for (const auto& edge : g_bg->tboAttachments.forBuffer(buffer)) {
        // Invalid SubData must not turn into a second, unrelated upload.
        const auto bytes = get_buffer_data_size(buffer);
        if (!allocate && (static_cast<std::size_t>(offset) > bytes ||
            static_cast<std::size_t>(count) > bytes-static_cast<std::size_t>(offset))) continue;
        uploadTBO(edge,allocate,offset,count);
    }
}
}
void rgpu_tbo_forget_texture(GLuint texture) { g_bg->tboAttachments.eraseTexture(texture); }

void glTexBuffer(GLenum target, GLenum internalformat, GLuint buffer) {
    LOG()
    if (!hardware->emulate_texture_buffer) {
        GLES.glTexBuffer(target,internalformat,find_real_buffer(buffer)); return;
    }
    if (target != GL_TEXTURE_BUFFER) { mg_set_gl_error(GL_INVALID_ENUM); return; }
    auto* tex = mgGetTexObjectByTarget(target);
    if (!tex || !tex->texture) { mg_set_gl_error(GL_INVALID_OPERATION); return; }
    if (!buffer) {
        TBOSavedState saved;
        GLES.glBindBuffer(GL_PIXEL_UNPACK_BUFFER,0);
        GLES.glBindTexture(GL_TEXTURE_2D,tex->texture);
        GLES.glTexImage2D(GL_TEXTURE_2D,0,GL_R8I,0,0,0,GL_RED_INTEGER,GL_BYTE,nullptr);
        tex->width = tex->height = 0;
        g_bg->tboAttachments.eraseTexture(tex->texture); return;
    }
    if (!has_buffer(buffer)) { mg_set_gl_error(GL_INVALID_OPERATION); return; }
    GLenum format = 0, type = 0;
    if (!get_internal_format_size(internalformat) || !get_internal_format_transfer(internalformat,&format,&type)) {
        mg_set_gl_error(GL_INVALID_ENUM); return;
    }
    const rgpu::tbo::Attachment edge{tex->texture,buffer,internalformat};
    if (uploadTBO(edge,true)) g_bg->tboAttachments.attach(edge.texture,edge.buffer,edge.format);
}
