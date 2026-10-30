// Vulkan GLSL 450, compiled to SPIR-V in Actions. Never used as a vertex substitute.
layout(location=0) in vec4 vColor[];
layout(location=0) out vec4 gColor;
layout(set=0,binding=0) uniform Parameters { vec4 offset; vec4 tint; } u;
#ifdef CAPTURE
layout(xfb_buffer=0,xfb_stride=32) out;
layout(location=1,xfb_offset=0) out vec4 capturedPosition;
layout(location=2,xfb_offset=16) out vec4 capturedColor;
#endif
void emit(vec2 p, vec4 c) {
    gl_Position=vec4(p,0,1);
    gColor=c;
#ifdef POINT_OUTPUT
    gl_PointSize=1.0;
#endif
#ifdef CAPTURE
    capturedPosition=gl_Position; capturedColor=c;
#endif
    EmitVertex();
}
void main() {
    // Real input position and varying influence every generated primitive.
    vec2 origin=gl_in[0].gl_Position.xy+u.offset.xy;
    vec4 color=vColor[0]*u.tint;
#ifdef INVOCATIONS
    origin.x+=float(gl_InvocationID)*0.875;
    color=gl_InvocationID==0 ? color : color.bgra;
#endif
#ifdef PRIMITIVE_ID
    color=gl_PrimitiveIDIn==0 ? color : color.bgra;
#endif
    for (int j=0; j<OUTPUT_COPIES; ++j) {
        vec2 p=origin+vec2(float(j)*0.875,0);
#ifdef POINT_OUTPUT
        emit(p,color); EndPrimitive();
#elif defined(LINE_OUTPUT)
        emit(p,color); emit(p+vec2(0.5,0),color); EndPrimitive();
#else
        // A strip produces two triangles; EndPrimitive separates the copies.
        for (int i=0;i<4;++i) {
            vec2 corner=vec2(i%2,i/2);
            vec4 c=color;
#ifdef GRADIENT
            c=vec4(corner,0.5,1);
#endif
            emit(p+corner*0.5,c);
        }
        EndPrimitive();
#endif
    }
}
