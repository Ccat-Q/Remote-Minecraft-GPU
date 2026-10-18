/* A1 producer. Built ONLY in Actions. No client-side pixel readback. */
#define _POSIX_C_SOURCE 200809L
#include <GL/glew.h>
#include <GLFW/glfw3.h>
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static void until(double deadline) {
    double left;
    while ((left = deadline - now()) > 0) {
        struct timespec t = {(time_t)left, (long)((left - (time_t)left) * 1e9)};
        if (nanosleep(&t, NULL) && errno != EINTR) break;
    }
}
static void glfw_error(int code, const char *text) {
    fprintf(stderr, "GLFW error %d: %s\n", code, text);
}
static GLuint shader(GLenum type, const char *source) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &source, NULL);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[4096] = {0};
        glGetShaderInfoLog(s, sizeof(log), NULL, log);
        fprintf(stderr, "FAIL: GLSL 120 compile: %s\n", log);
        glDeleteShader(s);
        return 0;
    }
    return s;
}
int main(int argc, char **argv) {
    long frames = 12, corrupt = -1, repeat = -1;
    double fps = 12, hold = 2;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--help")) {
            puts("gl-remote-present [--frames 1..100000] [--fps 0.1..240] [--hold-seconds 0.5..3600]\n"
                 "CI negative fixtures: --test-corrupt-frame N / --test-repeat-frame N (zero-based)");
            return 0;
        }
        if (i + 1 >= argc) return 2;
        const char *option = argv[i++];
        char *end = NULL;
        errno = 0;
        double value = strtod(argv[i], &end);
        if (errno || !end || *end || end == argv[i] || !isfinite(value)) return 2;
        if (!strcmp(option, "--frames") && value >= 1 && value <= 100000 && floor(value) == value) frames = (long)value;
        else if (!strcmp(option, "--fps") && value >= 0.1 && value <= 240) fps = value;
        else if (!strcmp(option, "--hold-seconds") && value >= 0.5 && value <= 3600) hold = value;
        else if (!strcmp(option, "--test-corrupt-frame") && value >= 0 && value <= 99999 && floor(value) == value) corrupt = (long)value;
        else if (!strcmp(option, "--test-repeat-frame") && value >= 1 && value <= 99999 && floor(value) == value) repeat = (long)value;
        else return 2;
    }
    if (corrupt >= frames || repeat >= frames) return 2;
    setvbuf(stdout, NULL, _IOLBF, 0);
    glfwSetErrorCallback(glfw_error);
    if (!glfwInit()) return 3;
    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 2);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 1);
    /* Profiles exist only from 3.2. 2.1 is the legacy compatibility context. */
    glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_ANY_PROFILE);
    glfwWindowHint(GLFW_SAMPLES, 0);
    glfwWindowHint(GLFW_VISIBLE, GLFW_FALSE);
    GLFWwindow *window = glfwCreateWindow(64, 64, "RemoteGPU A1 dynamic", NULL, NULL);
    if (!window) { glfwTerminate(); return 4; }
    glfwMakeContextCurrent(window);
    glewExperimental = GL_TRUE;
    if (glewInit() != GLEW_OK) return 5;
    while (glGetError() != GL_NO_ERROR) {}
    const char *renderer = (const char *)glGetString(GL_RENDERER);
    printf("GL_VERSION=%s\nGLSL_VERSION=%s\nGL_RENDERER=%s\n", (const char *)glGetString(GL_VERSION), (const char *)glGetString(GL_SHADING_LANGUAGE_VERSION), renderer);
    if (!renderer || !strstr(renderer, "virgl")) {
        fputs("FAIL: compute application is not using remote virgl\n", stderr);
        return 6;
    }
    GLuint vs = shader(GL_VERTEX_SHADER, "#version 120\nattribute vec2 position;\nuniform vec2 offset;\nvoid main(){gl_Position=vec4(position+offset,0.0,1.0);}\n");
    GLuint fs = shader(GL_FRAGMENT_SHADER, "#version 120\nuniform vec3 tint;\nvoid main(){gl_FragColor=vec4(tint,1.0);}\n");
    if (!vs || !fs) return 7;
    GLuint program = glCreateProgram();
    glAttachShader(program, vs); glAttachShader(program, fs);
    glBindAttribLocation(program, 0, "position");
    glLinkProgram(program);
    GLint linked = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked) { fputs("FAIL: GLSL 120 link\n", stderr); return 8; }
    glUseProgram(program);
    GLint offset = glGetUniformLocation(program, "offset"), tint = glGetUniformLocation(program, "tint");
    if (offset < 0 || tint < 0) return 9;
    const GLfloat vertices[] = {-0.3f,-0.4f, 0.3f,-0.4f, 0.0f,0.4f};
    GLuint vbo = 0;
    glGenBuffers(1, &vbo);
    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, (void *)0);
    glDisable(GL_DITHER);
    glDisable(GL_BLEND);
    glfwSwapInterval(0);
    int width = 0, height = 0;
    glfwGetFramebufferSize(window, &width, &height);
    if (width != 64 || height != 64) return 10;
    glViewport(0, 0, width, height);
    const double started = now();
    for (long frame = 0; frame < frames; frame++) {
        long value = frame == repeat ? frame - 1 : frame;
        int r = 40 + (int)(value * 37 % 180);
        int g = frame == corrupt ? 0 : 50 + (int)(value * 67 % 170);
        int b = 60 + (int)(value * 97 % 160);
        float x = (float)(value % 5 - 2) * 0.16f;
        float y = (float)(value / 5 % 3 - 1) * 0.12f;
        glClearColor(8/255.0f, 16/255.0f, 24/255.0f, 1);
        glClear(GL_COLOR_BUFFER_BIT);
        glUniform2f(offset, x, y);
        glUniform3f(tint, r/255.0f, g/255.0f, b/255.0f);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        glfwSwapBuffers(window); /* real GLX swap -> existing winsys hook */
        printf("DRAW frame=%ld offset=%.3f,%.3f rgb=%d,%d,%d\n", frame, x, y, r, g, b);
        if (glGetError() != GL_NO_ERROR) return 11;
        until(started + (frame + 1) / fps);
    }
    glFinish();
    printf("HOLD_BEGIN frames=%ld seconds=%.3f resources_alive=1\n", frames, hold);
    /* Keep window, VBO, program and the Mesa/vtest session alive, with NO swaps. */
    until(now() + hold);
    puts("HOLD_END resources_alive=1");
    glDeleteBuffers(1, &vbo);
    glDeleteShader(vs); glDeleteShader(fs); glDeleteProgram(program);
    glfwDestroyWindow(window);
    glfwTerminate();
    puts("PASS: dynamic GLSL 120 draws and final session hold");
    return 0;
}
