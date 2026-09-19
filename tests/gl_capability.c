/*
 * Build this on the Ubuntu compute client after Mesa virpipe is installed.
 * It deliberately fails before Minecraft if the remote renderer does not
 * expose the minimum OpenGL 3.2 Core profile required by modern Minecraft.
 */
#include <stdio.h>
#include <stdlib.h>
#include <GL/glew.h>
#include <GLFW/glfw3.h>

static int at_least_32(const char *version) {
    int major = 0, minor = 0;
    return sscanf(version, "%d.%d", &major, &minor) == 2 &&
           (major > 3 || (major == 3 && minor >= 2));
}

int main(void) {
    if (!glfwInit()) return 2;
    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 2);
    glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);
    glfwWindowHint(GLFW_VISIBLE, GLFW_FALSE);
    GLFWwindow *window = glfwCreateWindow(64, 64, "RemoteGPU capability gate", NULL, NULL);
    if (!window) { fputs("FAIL: cannot create OpenGL 3.2 Core context\n", stderr); return 3; }
    glfwMakeContextCurrent(window);
    glewExperimental = GL_TRUE;
    if (glewInit() != GLEW_OK) { fputs("FAIL: GLEW initialization\n", stderr); return 4; }
    const char *version = (const char *)glGetString(GL_VERSION);
    const char *glsl = (const char *)glGetString(GL_SHADING_LANGUAGE_VERSION);
    GLint profile = 0;
    glGetIntegerv(GL_CONTEXT_PROFILE_MASK, &profile);
    printf("GL_VERSION=%s\nGLSL_VERSION=%s\nPROFILE_MASK=0x%x\n", version, glsl, profile);
    if (!version || !at_least_32(version) || !(profile & GL_CONTEXT_CORE_PROFILE_BIT)) {
        fputs("FAIL: RemoteGPU requires OpenGL >= 3.2 Core\n", stderr);
        return 5;
    }
    if (!GLEW_ARB_framebuffer_object || !GLEW_ARB_vertex_array_object ||
        !GLEW_ARB_draw_instanced || !GLEW_ARB_sync || !GLEW_ARB_timer_query) {
        fputs("FAIL: required Minecraft capability is absent\n", stderr);
        return 6;
    }
    puts("PASS: RemoteGPU GL capability gate");
    glfwDestroyWindow(window);
    glfwTerminate();
    return 0;
}
