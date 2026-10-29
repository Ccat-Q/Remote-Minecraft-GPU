#version 300 es
precision highp float;
precision highp int;
uniform vec2 uScale;
uniform vec2 uOffset;
uniform vec2 uStep;
flat out ivec2 vCell;
in vec2 aPosition;
void main()
{
    vCell = ivec2(gl_InstanceID % 2, gl_InstanceID / 2);
    gl_Position = vec4(((aPosition * uScale) + uOffset) + (vec2(vCell) * uStep), 0.0, 1.0);
}
