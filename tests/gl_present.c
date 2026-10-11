/* Built only in GitHub Actions. Tests Mesa's presentation hook, not display. */
#include <stdio.h>
#include <string.h>
#include <GL/glew.h>
#include <GLFW/glfw3.h>

int main(int argc, char **argv)
{
    int readback = argc == 2 && strcmp(argv[1], "--readback") == 0;
    if (!glfwInit()) return 2;
    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 2);
    glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);
    GLFWwindow *window = glfwCreateWindow(64, 64, "RemoteGPU Present gate", NULL, NULL);
    if (!window) return 3;
    glfwMakeContextCurrent(window);
    glewExperimental = GL_TRUE;
    if (glewInit() != GLEW_OK) return 4;
    while (glGetError() != GL_NO_ERROR) {}
    for (int frame = 0; frame < 3; frame++) {
        glClearColor(1.0f, 0.0f, 0.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        if (readback && frame == 0) {
            unsigned char pixel[4] = {0};
            glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
            if (pixel[0] < 250 || pixel[1] > 5 || pixel[2] > 5) {
                fprintf(stderr, "FAIL: GPU pixel is %u,%u,%u\n", pixel[0], pixel[1], pixel[2]);
                return 5;
            }
            puts("PASS: application readback red pixel");
        }
        glfwSwapBuffers(window);
        glfwPollEvents();
    }
    glFinish();
    if (glGetError() != GL_NO_ERROR) return 6;
    puts("PASS: three frontbuffer swaps");
    glfwDestroyWindow(window);
    glfwTerminate();
    return 0;
}
