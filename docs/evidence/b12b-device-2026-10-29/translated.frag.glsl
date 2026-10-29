#version 300 es
precision highp float;
precision highp int;
uniform highp sampler2D uTex;
uniform highp vec4 uTint;
layout(location=0) out highp vec4 outColor0;
flat in ivec2 vCell;
void main()
{
    outColor0 = texelFetch(uTex, vCell, 0) * uTint;
}
