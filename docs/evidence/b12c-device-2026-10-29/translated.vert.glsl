#version 300 es
precision highp float;
precision highp int;
uniform vec2 uScale;
uniform vec2 uOffset;
uniform float uDepth;
in vec2 aPosition;
out vec2 vUV;
in vec2 aUV;
void main()
{
    gl_Position = vec4((aPosition * uScale) + uOffset, uDepth, 1.0);
    vUV = aUV;
}
