#version 300 es
#extension GL_EXT_texture_buffer : require
precision highp float;
precision highp int;
uniform int uBias;
uniform highp samplerBuffer uBuffer;
layout(location=0) out highp vec4 outColor0;
void main()
{
    int cell = (int(gl_FragCoord.x) / 8) + (2 * (int(gl_FragCoord.y) / 8));
    int index = (cell + uBias) % 4;
    outColor0 = texelFetch(uBuffer, index);
}
