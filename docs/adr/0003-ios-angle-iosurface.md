# ADR 0003: Use ANGLE, IOSurface and Metal for iOS v1

VirGL's conventional host path targets OpenGL. v1 adapts this through ANGLE's
Metal backend and presents an IOSurface through Metal. Venus/MoltenVK remains
an experiment because its external-memory assumptions do not match iOS.
