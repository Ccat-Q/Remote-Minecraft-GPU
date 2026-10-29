#version 300 es
precision highp float;
precision highp int;
uniform int uBias;
uniform highp isampler2D uBuffer;
uniform int u_BufferTexWidth;
uniform int u_BufferTexHeight;
layout(location=0) out highp vec4 outColor0;
void main()
{
    int cell = (int(gl_FragCoord.x) / 8) + (2 * (int(gl_FragCoord.y) / 8));
    int index = (cell + uBias) % 4;
    int value = texelFetch(uBuffer, ivec2(index % u_BufferTexWidth, index / u_BufferTexWidth), 0).x;
    outColor0 = vec4(float(value + 128) / 255.0, 0.25, 0.75, 1.0);
}
