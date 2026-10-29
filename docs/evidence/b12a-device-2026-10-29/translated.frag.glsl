#version 300 es
precision highp float;
precision highp int;

uniform highp sampler2D uTex;
uniform highp vec4 uTint;

layout(location=0) out highp vec4 outColor0;
in highp vec2 vUV;

void main()
{
    outColor0 = texture(uTex, vUV) * uTint;
}
