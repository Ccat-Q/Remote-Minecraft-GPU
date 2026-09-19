# ADR 0002: Hook Mesa's vtest winsys presentation path

GLFW does not know VirGL resource handles. The vtest winsys frontbuffer flush
does. RemoteGPU changes that layer so presentation emits an ordered marker
instead of copying a frontbuffer to an Ubuntu displaytarget.
