/* Built only in GitHub Actions. Tests Mesa's presentation hook, not display. */
#include <stdio.h>
#include <string.h>
#include <GL/glew.h>
#include <GLFW/glfw3.h>

static void glfw_error(int code, const char *description)
{
    fprintf(stderr, "GLFW error %d: %s\n", code, description);
}

static GLuint make_shader(GLenum type, const char *source)
{
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    GLint ok = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[2048] = {0};
        glGetShaderInfoLog(shader, sizeof(log), NULL, log);
        fprintf(stderr, "FAIL: shader compilation: %s\n", log);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

int main(int argc, char **argv)
{
    int readback = argc == 2 && strcmp(argv[1], "--readback") == 0;
    glfwSetErrorCallback(glfw_error);
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
    GLuint vertex = make_shader(GL_VERTEX_SHADER,
        "#version 150\nconst vec2 p[3]=vec2[3](vec2(-0.7,-0.7),vec2(0.7,-0.7),vec2(0,0.7));\n"
        "void main(){gl_Position=vec4(p[gl_VertexID],0,1);}");
    GLuint fragment = make_shader(GL_FRAGMENT_SHADER,
        "#version 150\nout vec4 color;\nvoid main(){color=vec4(1,0,0,1);}");
    if (!vertex || !fragment) return 7;
    GLuint program = glCreateProgram();
    glAttachShader(program, vertex);
    glAttachShader(program, fragment);
    glLinkProgram(program);
    glDeleteShader(vertex);
    glDeleteShader(fragment);
    GLint linked = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked) { fputs("FAIL: triangle program link\n", stderr); return 8; }
    GLuint vao = 0;
    glGenVertexArrays(1, &vao);
    glBindVertexArray(vao);
    glUseProgram(program);
    glViewport(0, 0, 64, 64);
    for (int frame = 0; frame < 3; frame++) {
        glClearColor(0.02f, 0.04f, 0.08f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        if (readback && frame == 0) {
            unsigned char pixel[4] = {0};
            glReadPixels(32, 32, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
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
    glDeleteVertexArrays(1, &vao);
    glDeleteProgram(program);
    glfwDestroyWindow(window);
    glfwTerminate();
    return 0;
}
